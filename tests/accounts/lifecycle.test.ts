import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';
import { accountsRoot, bootstrapDomain, preload } from './helpers.js';

test('owner lifecycle summaries count nonzero balances, live holds, and grants while detecting drift', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrapDomain(engine);
    await preload(
      engine,
      'server.persistence.lifecycle_groups',
      'resources/synex_accounts/server/persistence/lifecycle_groups.lua',
    );
    await preload(
      engine,
      'server.persistence.lifecycle',
      'resources/synex_accounts/server/persistence/lifecycle.lua',
    );
    const result = await engine.doString(`
      local accountRows = {{
        id = 1, public_id = '11111111-1111-4111-8111-111111111111',
        status = 'active', version = 2, booked_minor = '0', ledger_minor = '0'
      }}
      local function many(sql, parameters)
        assert(parameters[1] == 'group' and parameters[2] == 'group:police')
        if sql:find('booked_minor_total', 1, true) then
          return {{ booked_minor_total = '0' }}
        end
        if sql:find('synex_account_holds', 1, true) then return {{ id = 9 }} end
        if sql:find('synex_account_access_grants', 1, true) then
          return {{ id = 10 }, { id = 11 }}
        end
        if sql:find('synex_accounts', 1, true) then return accountRows end
        error('unexpected lifecycle query: ' .. sql)
      end
      local context = {
        foundation = Foundation,
        domainError = Foundation.domainError,
        jsonEncode = function() return '{}' end,
        jsonDecode = function() return {} end,
        random = function() return 1 end,
        uuidV4 = Foundation.uuidV4,
        one = function() return nil end,
        many = many,
        withRetriableTransaction = function() return false, nil end
      }
      local port = {}
      require('server.persistence.lifecycle')(port, context)
      local summary = assert(port:getGroupLifecycleSummary('group:police'))
      assert(summary.accounts == 1 and summary.openAccounts == 1)
      assert(summary.nonzeroAccounts == 0 and summary.nonterminalHolds == 1)
      assert(summary.activeGrants == 2 and summary.bookedMinorTotal == '0')

      accountRows[1].ledger_minor = '1'
      local drift, driftError = port:getGroupLifecycleSummary('group:police')
      assert(drift == nil and driftError.code == 'INTEGRITY_VIOLATION')
      return table.concat({ summary.accounts, summary.nonterminalHolds,
        summary.activeGrants, driftError.code }, ':')
    `);
    assert.equal(result, '1:1:2:INTEGRITY_VIOLATION');
  } finally {
    engine.global.close();
  }
});

test('character and group lifecycle providers block live funds and holds before anonymization', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrapDomain(engine);
    await preload(
      engine,
      'server.lifecycle',
      'resources/synex_accounts/server/lifecycle.lua',
    );
    const result = await engine.doString(`
      local mode = 'holds'
      local repository = {}
      function repository:getCharacterLifecycleSummary()
        if mode == 'holds' then return { accounts = 1, nonterminalHolds = 1,
          nonzeroAccounts = 0, activeGrants = 0, bookedMinorTotal = '0' } end
        if mode == 'balance' then return { accounts = 1, nonterminalHolds = 0,
          nonzeroAccounts = 1, activeGrants = 0, bookedMinorTotal = '10' } end
        return { accounts = 1, nonterminalHolds = 0,
          nonzeroAccounts = 0, activeGrants = 1, bookedMinorTotal = '0' }
      end
      function repository:getGroupLifecycleSummary()
        return self:getCharacterLifecycleSummary()
      end
      function repository:applyCharacterDeletion() return { completed = true } end
      function repository:applyGroupDeletion() return { completed = true } end
      local lifecycle = require('server.lifecycle')(Foundation)({
        repository = repository, random = function() return 7 end
      })
      local character = lifecycle:characterParticipant()
      local holds = assert(character.deletePreflight({ character = { id = 'character:42' } }))
      assert(holds.action == 'block' and holds.code == 'CHARACTER_ACCOUNTS_HAVE_HOLDS')
      mode = 'balance'
      local balance = assert(character.deletePreflight({ character = { id = 'character:42' } }))
      assert(balance.action == 'block' and balance.code == 'CHARACTER_ACCOUNTS_HAVE_BALANCE')
      mode = 'clear'
      local allowed = assert(character.deletePreflight({ character = { id = 'character:42' } }))
      assert(allowed.action == 'anonymize' and allowed.metadata.ledgerHistory == 'retain')

      local group = lifecycle:groupProvider()
      mode = 'holds'
      local groupHolds = assert(group.preflight({ domain = 'group', subjectId = 'group:police' }))
      assert(groupHolds.decision == 'block' and groupHolds.metadata.activeHolds == 1)
      mode = 'balance'
      local groupBalance = assert(group.preflight({ domain = 'group', subjectId = 'group:police' }))
      assert(groupBalance.decision == 'block' and groupBalance.metadata.transferRequired)
      mode = 'clear'
      local groupAllowed = assert(group.preflight({ domain = 'group', subjectId = 'group:police' }))
      assert(groupAllowed.decision == 'anonymize' and groupAllowed.metadata.ledgerHistory == 'retain')
      return table.concat({ holds.code, balance.code, allowed.action,
        groupHolds.decision, groupBalance.decision, groupAllowed.decision }, ':')
    `);
    assert.equal(
      result,
      'CHARACTER_ACCOUNTS_HAVE_HOLDS:CHARACTER_ACCOUNTS_HAVE_BALANCE:anonymize:block:block:anonymize',
    );
  } finally {
    engine.global.close();
  }
});

test('lifecycle persistence revokes authority, closes ownership, retains ledger rows, and journals replay', async () => {
  const persistence = (await Promise.all([
    'lifecycle.lua',
    'lifecycle_groups.lua',
  ].map((name) => readFile(
    path.join(accountsRoot, 'server', 'persistence', name),
    'utf8',
  )))).join('\n');
  assert.match(persistence, /CHARACTER_ACCOUNTS_HAVE_HOLDS/u);
  assert.match(persistence, /CHARACTER_ACCOUNTS_HAVE_BALANCE/u);
  assert.match(persistence, /GROUP_ACCOUNTS_HAVE_HOLDS/u);
  assert.match(persistence, /GROUP_ACCOUNTS_REQUIRE_TRANSFER/u);
  assert.match(persistence, /bookedMinor ~= ledgerMinor[\s\S]*?INTEGRITY_VIOLATION/u);
  assert.match(persistence, /SET `grant`\.`status` = 'revoked'|`grant`\.`status` = 'revoked'/u);
  assert.match(persistence, /SET `account`\.`status` = 'closed'/u);
  assert.match(persistence, /UPDATE `synex_account_owners`[\s\S]*?SET `owner_ref` = \?/u);
  assert.match(persistence, /INSERT INTO `synex_account_audit`/u);
  assert.match(persistence, /INSERT INTO `synex_account_outbox`/u);
  assert.match(persistence, /WHERE `caller_resource` = \?[\s\S]*?`caller_principal_kind` = 'resource'[\s\S]*?`caller_principal_ref` = \?[\s\S]*?`operation_name` = \?[\s\S]*?`idempotency_key` = \?[\s\S]*?FOR UPDATE/u);
  assert.match(persistence, /journal\.state == 'completed'/u);
  assert.doesNotMatch(persistence, /DELETE\s+FROM\s+`synex_(?:ledger|account)/iu);
  assert.doesNotMatch(persistence, /`synex_groups`|`synex_group_[a-z0-9_]+`/u);
});

test('lifecycle pseudonymizes bounded durable JSON evidence and every V2 archive reference', async () => {
  const persistence = (await Promise.all([
    'lifecycle.lua',
    'lifecycle_groups.lua',
  ].map((name) => readFile(
    path.join(accountsRoot, 'server', 'persistence', name),
    'utf8',
  )))).join('\n');
  for (const [table, column] of [
    ['synex_account_operations', 'response_json'],
    ['synex_account_audit', 'snapshot_json'],
    ['synex_account_outbox', 'payload_json'],
  ] as const) {
    const start = persistence.indexOf(`UPDATE \`${table}\``);
    assert.notEqual(start, -1);
    const block = persistence.slice(start, start + 700);
    assert.ok(block.includes(`SET \`${column}\` = REPLACE(`));
    assert.ok(block.includes(`\`${column}\`, JSON_QUOTE(?), JSON_QUOTE(?))`));
    assert.ok(block.includes(`JSON_VALID(\`${column}\`) = 1`));
    assert.ok(block.includes(`OCTET_LENGTH(\`${column}\`) <= ?`));
    assert.ok(block.includes(`LOCATE(JSON_QUOTE(?), \`${column}\`) > 0`));
  }
  assert.match(persistence, /MAX_DURABLE_JSON_BYTES = 32768/u);
  assert.equal(
    (persistence.match(/OCTET_LENGTH\(REPLACE\(`(?:response_json|snapshot_json|payload_json)`,\s*JSON_QUOTE\(\?\), JSON_QUOTE\(\?\)\)\) > \?/gu) ?? []).length,
    3,
  );
  assert.match(
    persistence,
    /UPDATE `synex_financial_transaction_archive_v2`[\s\S]*?`reference_id` = CASE WHEN `reference_type` = \? AND `reference_id` = \?[\s\S]*?THEN \? ELSE `reference_id` END[\s\S]*?OR \(`reference_type` = \? AND `reference_id` = \?\)/u,
  );
  assert.doesNotMatch(
    persistence,
    /REPLACE\(`(?:response_json|snapshot_json|payload_json)`,\s*\?,\s*\?\)/u,
  );

  const ownerRef = 'character:private-owner-0001';
  const anonymousRef = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  const evidence = JSON.stringify({
    owner_ref: ownerRef,
    nested: [ownerRef, `prefix:${ownerRef}`],
    amount_minor: '9007199254740991',
  });
  const rewritten = evidence.replaceAll(JSON.stringify(ownerRef), JSON.stringify(anonymousRef));
  assert.deepEqual(JSON.parse(rewritten), {
    owner_ref: anonymousRef,
    nested: [anonymousRef, `prefix:${ownerRef}`],
    amount_minor: '9007199254740991',
  });
  assert.equal(
    rewritten.replaceAll(JSON.stringify(ownerRef), JSON.stringify(anonymousRef)),
    rewritten,
  );
});
