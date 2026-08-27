import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory, type LuaEngine } from 'wasmoon';

const root = process.cwd();
const diagnosticsPath = path.join(
  root,
  'resources',
  'synex_groups',
  'server',
  'persistence',
  'diagnostics.lua',
);
const observabilityPath = path.join(
  root,
  'resources',
  'synex_groups',
  'server',
  'persistence',
  'observability.lua',
);

async function bootstrap(engine: LuaEngine): Promise<void> {
  const foundation = await readFile(
    path.join(root, 'resources', 'synex_groups', 'server', 'foundation.lua'),
    'utf8',
  );
  const diagnostics = await readFile(diagnosticsPath, 'utf8');
  await engine.doString(`
    Foundation = assert(load(${JSON.stringify(foundation)}, '@server/foundation.lua'))()
    Diagnostics = assert(load(${JSON.stringify(diagnostics)},
      '@server/persistence/diagnostics.lua'))()(Foundation)

    function diagnosticsRuntime()
      local runtime = {
        registries = {
          groupTypes = { stats = function() return { count = 2, revision = 3 } end },
          dutyStates = { stats = function() return { count = 4, revision = 5 } end }
        },
        cache = { snapshot = function() return { size = 7, hits = 11 } end },
        definitionCache = { snapshot = function()
          return { size = 2, hits = 5, misses = 3, invalidations = 1 }
        end },
        runtimeIndex = { snapshot = function()
          return { characters = 3, memberships = 5, dutySessions = 2 }
        end }
      }
      function runtime.authorize(_, groupId, characterId, capability, scope)
        assert(groupId == 'group_alpha_0001')
        assert(characterId == 'character_actor_0001')
        assert(capability == 'synex.groups.history.read' and scope == 'group')
        return { id = 21, public_id = 'membership_actor_0001' }
      end
      function runtime.jsonDecode(encoded)
        if encoded == '{"before":1}' then return { before = 1 } end
        if encoded == '{"after":2}' then return { after = 2 } end
        error('unexpected JSON fixture: ' .. tostring(encoded))
      end
      return runtime
    end
  `);
}

test('history pagination binds cursors to one authorized group and returns a stable cursor', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`
      local tx = {}
      function tx.one(sql, parameters)
        assert(sql:find('event_id = ? AND group_public_id = ?', 1, true))
        assert(parameters[1] == 'history_cursor_0001')
        assert(parameters[2] == 'group_alpha_0001')
        return { id = 80 }
      end
      function tx.many(sql, parameters)
        assert(sql:find('group_public_id = ?', 1, true))
        assert(sql:find('aggregate_type = ?', 1, true))
        assert(sql:find('aggregate_id = ?', 1, true))
        assert(sql:find('id < ?', 1, true))
        assert(parameters[1] == 'group_alpha_0001')
        assert(parameters[2] == 'membership')
        assert(parameters[3] == 'membership_target_0001')
        assert(parameters[4] == 80 and parameters[5] == 3)
        local function row(index)
          return {
            event_id = 'history_event_000' .. index,
            aggregate_type = 'membership', aggregate_id = 'membership_target_0001',
            aggregate_version = 6 - index, event_type = 'membership.changed',
            source_resource = 'synex_groups', actor_kind = 'character',
            actor_ref = 'character_actor_0001', reason_code = 'test_history',
            correlation_id = 'trace_history_0001', before_json = '{"before":1}',
            after_json = '{"after":2}', occurred_at = '2026-08-25T10:00:00.000000Z'
          }
        end
        return { row(1), row(2), row(3) }
      end
      local value, failure = Diagnostics.read.history_list(tx, {
        actor_character_id = 'character_actor_0001', group_id = 'group_alpha_0001',
        entity_type = 'membership', entity_id = 'membership_target_0001',
        cursor = 'history_cursor_0001', limit = 2
      }, diagnosticsRuntime())
      assert(failure == nil and #value.items == 2 and value.truncated == true)
      assert(value.next_cursor == 'history_event_0002')
      assert(value.items[1].before.before == 1 and value.items[1].after.after == 2)
      assert(value.items[1].actor.kind == 'character')
      return value.next_cursor
    `);
    assert.equal(result, 'history_event_0002');
  } finally {
    engine.global.close();
  }
});

test('a cursor from another group fails before reading any history rows', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`
      local reads = 0
      local tx = {
        one = function() return nil end,
        many = function() reads = reads + 1 return {} end
      }
      local value, failure = Diagnostics.read.history_list(tx, {
        actor_character_id = 'character_actor_0001', group_id = 'group_alpha_0001',
        cursor = 'history_from_bravo_0001', limit = 20
      }, diagnosticsRuntime())
      assert(value == nil and failure.code == 'VALIDATION_FAILED' and reads == 0)
      return failure.code
    `);
    assert.equal(result, 'VALIDATION_FAILED');
  } finally {
    engine.global.close();
  }
});

test('doctor is bounded, deterministic, and escalates warnings without hiding checks', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`
      local calls = 0
      local tx = {}
      function tx.one(sql)
        calls = calls + 1
        if sql:find('expired_role_still_active', 1, true) then return { count = 1 } end
        if sql:find('valid_until IS NOT NULL', 1, true)
            and sql:find('synex_group_membership_roles', 1, true) then
          return { count = 2 }
        end
        return { count = 0 }
      end
      local runtime = diagnosticsRuntime()
      -- Doctor has no actor request and therefore does not call group authorization.
      local value, failure = Diagnostics.read.doctor(tx, {}, runtime)
      assert(failure == nil and value.status == 'WARN')
      assert(calls == #value.checks and calls >= 18)
      assert(value.cache.size == 7 and value.cache.definitions.size == 2
        and value.cache.definitions.hits == 5 and value.registries.groupTypes.count == 2)
      assert(value.runtimeIndex.characters == 3
        and value.runtimeIndex.memberships == 5
        and value.runtimeIndex.dutySessions == 2)
      local found = false
      for _, check in ipairs(value.checks) do
        if check.key == 'expired_role_still_active' then
          assert(check.status == 'WARN' and check.count == 2)
          found = true
        end
      end
      assert(found)
      return value.status .. ':' .. tostring(calls)
    `);
    assert.match(String(result), /^WARN:\d+$/u);
  } finally {
    engine.global.close();
  }
});

test('doctor detects active participants and duty sessions left behind by expired assignments', async () => {
  const source = await readFile(diagnosticsPath, 'utf8');
  assert.match(
    source,
    /assignment_member\.status = 'active'[\s\S]*?assignment\.status\s*<>\s*'active'/u,
  );
  assert.match(
    source,
    /duty\.status = 'open'[\s\S]*?assignment/u,
    'open duty linked to a terminal or expired assignment must be diagnosed',
  );
});

test('character lifecycle reads use the canonical primary-by-type model', async () => {
  const source = await readFile(observabilityPath, 'utf8');
  const listEnd = source.indexOf('function port:getCharacterLifecycleSummary');
  const summaryEnd = source.indexOf('function port:applyCharacterDeletion');
  const list = source.slice(0, listEnd);
  const summary = source.slice(listEnd, summaryEnd);
  assert.match(list, /synex_group_primary_memberships_by_type/u);
  assert.match(summary, /synex_group_primary_memberships_by_type/u);
  assert.match(
    summary,
    /`profile`.`lifecycle_state` = 'ACTIVE'/u,
    'active membership summaries must not count materialized workflow pre-states',
  );

  const deletion = source.slice(summaryEnd);
  assert.match(
    deletion,
    /SELECT[\s\S]*?FROM `synex_group_primary_memberships_by_type`[\s\S]*?character_id` = \? FOR UPDATE/u,
  );
});

test('control-plane membership metrics use canonical lifecycle states', async () => {
  const source = await readFile(observabilityPath, 'utf8');
  const summaryStart = source.indexOf('function port:getControlSummary');
  assert.notEqual(summaryStart, -1);
  const summary = source.slice(summaryStart);
  assert.match(summary, /synex_group_membership_profiles`[\s\S]*?lifecycle_state` = 'ACTIVE'/u);
  assert.match(summary, /profile`.`lifecycle_state` AS `status`/u);
  assert.match(summary, /COUNT\(`profile`.`membership_id`\) AS `active_memberships`/u);
  assert.doesNotMatch(
    summary,
    /synex_group_memberships` WHERE `status` = 'active'/u,
  );
});

test('character deletion anonymizes actor references globally and does not retain nested PII', async () => {
  const source = await readFile(observabilityPath, 'utf8');
  const deletionStart = source.indexOf('function port:applyCharacterDeletion');
  assert.notEqual(deletionStart, -1);
  const deletion = source.slice(deletionStart);

  assert.match(
    deletion,
    /UPDATE `synex_group_membership_attributes`[\s\S]*?SET `updated_by_ref` = \?[\s\S]*?WHERE `updated_by_ref` = \?/u,
  );
  assert.match(
    deletion,
    /UPDATE `synex_group_membership_transition_policies`[\s\S]*?SET `updated_by_ref` = \?[\s\S]*?WHERE `updated_by_ref` = \?/u,
  );
  assert.match(
    deletion,
    /UPDATE `synex_group_membership_events`[\s\S]*?WHERE `actor_ref` = \?/u,
  );
  assert.match(
    deletion,
    /UPDATE `synex_group_membership_grades`[\s\S]*?WHERE `assigned_by_ref` = \?/u,
  );
  assert.match(
    deletion,
    /UPDATE `synex_group_primary_membership_events`[\s\S]*?WHERE `actor_ref` = \?/u,
  );
  assert.match(
    deletion,
    /UPDATE `synex_group_creation_requests` AS `request`[\s\S]*?APPROVER_DELETED[\s\S]*?status` IN \('pending', 'approved'\)/u,
  );
  assert.match(
    deletion,
    /UPDATE `synex_group_creation_requests`[\s\S]*?CHARACTER_DELETED[\s\S]*?JSON_SEARCH\(`request_json`, 'one', \?\)/u,
  );
  assert.match(
    deletion,
    /UPDATE `synex_group_creation_approvals`[\s\S]*?SET `approver_character_ref` = \?[\s\S]*?WHERE `approver_character_ref` = \?/u,
  );

  const historyStart = deletion.indexOf('UPDATE `synex_group_domain_history`');
  const archiveStart = deletion.indexOf('UPDATE `synex_group_domain_history_archive`');
  const outboxStart = deletion.indexOf('UPDATE `synex_group_outbox`');
  assert.ok(historyStart >= 0 && archiveStart > historyStart && outboxStart > archiveStart);
  const history = deletion.slice(historyStart, archiveStart);
  const archive = deletion.slice(archiveStart, outboxStart);
  const outbox = deletion.slice(outboxStart);
  for (const statement of [history, archive]) {
    assert.match(statement, /JSON_SEARCH/u);
    assert.doesNotMatch(
      statement,
      /JSON_REPLACE\(`(?:before|after)_json`, '\$\.(?:character_id|actor_character_id)'/u,
      'top-level-only replacement leaves nested character identifiers behind',
    );
  }
  assert.match(outbox, /JSON_SEARCH/u);
  assert.doesNotMatch(
    outbox,
    /JSON_REPLACE\([\s\S]*?'\$\.(?:character_id|actor_character_id)'/u,
    'pending outbox payloads must not keep nested identifiers after deletion',
  );
});
