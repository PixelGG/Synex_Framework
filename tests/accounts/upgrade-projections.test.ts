import assert from 'node:assert/strict';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';
import { preload } from './helpers.js';

const holdId = '11111111-1111-4111-8111-111111111111';
const transactionId = '22222222-2222-4222-8222-222222222222';
const accountId = '33333333-3333-4333-8333-333333333333';
const captureAccountId = '44444444-4444-4444-8444-444444444444';

test('V2 hold reads normalize legacy provenance without changing canonical provenance', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await preload(
      engine,
      'server.persistence.holds_v2',
      'resources/synex_accounts/server/persistence/holds_v2.lua',
    );
    const result = await engine.doString(`
      local row = {
        public_id = '${holdId}', account_id = '${accountId}',
        capture_account_id = '${captureAccountId}', currency_code = 'syn',
        amount_minor = 100, captured_minor = 0, released_minor = 0,
        remaining_minor = 100, state = 'active', capture_policy = 'single',
        reason_code = 'synex_accounts.hold', source_resource = 'legacy',
        trace_id = nil, actor_kind = 'migration', actor_ref = 'migration:011',
        metadata_json = '{}', expires_at = '2026-08-27 00:00:00.000000',
        created_at = '2026-08-26 00:00:00.000000', version = 1,
        event_id = '${transactionId}', event_occurred_at = '2026-08-26 00:00:00.000000',
        is_expired = 0,
      }
      local port = {
        getAccount = function() return {} end,
      }
      require('server.persistence.holds_v2')(port, {
        foundation = {}, domain = {}, engine = {},
        domainError = function(code, message) return { code = code, message = message } end,
        uuidV4 = function() return '${holdId}' end,
        random = function() return 1 end,
        one = function() return row end,
        many = function() return {} end,
        txRows = function() return {} end,
        txOne = function() return nil end,
        jsonEncode = function() return '{}' end,
      })

      local legacy = assert(port:getHoldV2('${holdId}', {}))
      assert(legacy.trace_id == 'legacy:${holdId}')
      assert(legacy.actor_kind == 'resource')
      assert(legacy.actor_ref == 'synex_accounts')

      row.trace_id = 'trace_existing_01'
      row.actor_kind = 'character'
      row.actor_ref = 'character:42'
      local canonical = assert(port:getHoldV2('${holdId}', {}))
      assert(canonical.trace_id == 'trace_existing_01')
      assert(canonical.actor_kind == 'character')
      assert(canonical.actor_ref == 'character:42')
      return legacy.trace_id .. ':' .. legacy.actor_kind .. ':' .. legacy.actor_ref
    `);
    assert.equal(result, `legacy:${holdId}:resource:synex_accounts`);
  } finally {
    engine.global.close();
  }
});

test('V2 hold release rejects an allowlist policy without hold.release before writing', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await preload(
      engine,
      'server.persistence.holds_v2',
      'resources/synex_accounts/server/persistence/holds_v2.lua',
    );
    const result = await engine.doString(`
      local writes, allowedLookup = 0, false
      local hold = {
        id = 7, public_id = '${holdId}', account_public_id = '${accountId}',
        capture_account_public_id = '${captureAccountId}', state = 'active',
        remaining_minor = 100, released_minor = 0, captured_minor = 0,
        amount_minor = 100, version = 3, is_expired = 0,
      }
      local Engine = {
        mutation = function(_, _, _, handler)
          return handler({}, 91)
        end,
        loadAccounts = function()
          return { ['${accountId}'] = {
            id = 9, public_id = '${accountId}', booked_minor = 100,
          } }, nil
        end,
        requireAccess = function() return true, nil end,
        requireReason = function() return true, nil end,
        appendSnapshot = function() error('a denied release must not append a snapshot') end,
        writeEvent = function() error('a denied release must not publish an event') end,
      }
      local port = {}
      require('server.persistence.holds_v2')(port, {
        foundation = {},
        domain = {
          holdTransition = function()
            return { releasedMinor = 100, remainingMinor = 0,
              state = 'released', nextVersion = 4 }, nil
          end,
        },
        engine = Engine,
        domainError = function(code, message) return { code = code, message = message } end,
        uuidV4 = function() return '${transactionId}' end,
        random = function() return 1 end,
        one = function() return nil end,
        many = function() return {} end,
        txRows = function()
          writes = writes + 1
          return {}
        end,
        txOne = function(_, sql, values)
          if sql:find('synex_account_policy_allowed_operations', 1, true) then
            allowedLookup = true
            assert(values[1] == 9 and values[2] == 'hold.release')
            return nil
          end
          if sql:find('synex_account_policies', 1, true) then
            assert(values[1] == 9)
            return { operation_mode = 'allowlist' }
          end
          if sql:find('FROM \`synex_account_holds\`', 1, true) then return hold end
          error('unexpected hold release query')
        end,
        jsonEncode = function() return '{}' end,
      })

      local value, failure = port:releaseHoldV2({
        holdId = '${holdId}', reasonCode = 'synex_accounts.hold',
        authority = { callerResource = 'synex_test', principalKind = 'resource',
          principalRef = 'synex_test', traceId = 'trace_release_01' },
      })
      assert(value == nil and failure.code == 'OPERATION_NOT_ALLOWED')
      assert(allowedLookup == true and writes == 0)
      return failure.code .. ':' .. tostring(writes)
    `);
    assert.equal(result, 'OPERATION_NOT_ALLOWED:0');
  } finally {
    engine.global.close();
  }
});

test('V2 transaction reads and lists normalize only missing legacy provenance', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await preload(
      engine,
      'server.persistence.transaction_reads',
      'resources/synex_accounts/server/persistence/transaction_reads.lua',
    );
    const result = await engine.doString(`
      local row = {
        id = 1, public_id = '${transactionId}', currency_code = 'syn',
        transaction_kind = 'transfer', reason_code = 'synex_accounts.transfer',
        source_resource = 'legacy', trace_id = nil, actor_kind = 'migration',
        actor_ref = 'migration:007', status = 'posted',
        occurred_at = '2026-08-26 00:00:00.000000', entry_count = 2,
      }
      local entries = {
        { entry_id = '${holdId}', account_id = '${accountId}', sequence = 1,
          amount_minor = -100, metadata_json = '{}' },
        { entry_id = '${captureAccountId}', account_id = '${captureAccountId}', sequence = 2,
          amount_minor = 100, metadata_json = '{}' },
      }
      local port = {
        getAccount = function() return {} end,
      }
      require('server.persistence.transaction_reads')(port, {
        foundation = {
          MAX_MINOR = 9007199254740991,
          isUuid = function() return true end,
        },
        domain = {}, engine = {},
        domainError = function(code, message) return { code = code, message = message } end,
        uuidV4 = function() return '${transactionId}' end,
        random = function() return 1 end,
        one = function() return row end,
        many = function(sql)
          if sql:find('SELECT \`entry\`.\`public_id\`', 1, true) then return entries end
          return { row }
        end,
        txRows = function() return {} end,
        txOne = function() return nil end,
      })

      local legacy = assert(port:getTransaction('${transactionId}', {}, '${accountId}'))
      assert(legacy.trace_id == 'legacy:${transactionId}')
      assert(legacy.actor_kind == 'resource')
      assert(legacy.actor_ref == 'synex_accounts')
      local listed = assert(port:listTransactions({ accountId = '${accountId}', authority = {} }))
      assert(listed.items[1].trace_id == 'legacy:${transactionId}')

      row.trace_id = 'trace_existing_02'
      row.actor_kind = 'resource'
      row.actor_ref = 'synex_banking'
      local canonical = assert(port:getTransaction('${transactionId}', {}, '${accountId}'))
      assert(canonical.trace_id == 'trace_existing_02')
      assert(canonical.actor_kind == 'resource')
      assert(canonical.actor_ref == 'synex_banking')
      return legacy.trace_id .. ':' .. listed.items[1].trace_id
    `);
    assert.equal(
      result,
      `legacy:${transactionId}:legacy:${transactionId}`,
    );
  } finally {
    engine.global.close();
  }
});
