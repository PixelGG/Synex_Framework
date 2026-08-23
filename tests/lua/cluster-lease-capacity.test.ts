import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';

const root = process.cwd();

async function createPersistenceEngine() {
  const engine = await new LuaFactory().createEngine();
  for (const relativePath of [
    'core/synex_core/server/factories.lua',
    'core/synex_core/server/foundation.lua',
    'core/synex_core/server/persistence.lua',
  ]) {
    await engine.doString(await readFile(path.join(root, relativePath), 'utf8'));
  }
  return engine;
}

test('cluster lease acquire enforces retained global and kind capacity without charging existing names', async () => {
  const engine = await createPersistenceEngine();
  try {
    const result = await engine.doString(`
      local platform = {
        nowGame = function() return 1000 end,
        random = function() return 7 end,
        wait = function() end,
        print = function() end,
        jsonEncode = function() return '{}' end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('lease-capacity-fixture')

      local state, failureStage, raceOwner, concurrentRow
      local exactReads, capacityQueries = 0, 0
      local function clone(value)
        if type(value) ~= 'table' then return value end
        local copy = {}
        for key, item in pairs(value) do copy[key] = clone(item) end
        return copy
      end
      local function kindFor(name)
        if name == 'schema_migrations' then return nil end
        if name:sub(1, 8) == 'session:' then return 'session' end
        if name:sub(1, 10) == 'admission:' then return 'admission' end
        if name:sub(1, 5) == 'saga:' then return 'saga' end
        if name:sub(1, 17) == 'character-delete:' then return 'character' end
        return 'other'
      end
      local function reset(globalCount, globalLimit)
        state = {
          global = { entry_count = globalCount, global_limit = globalLimit },
          kinds = {}, leases = {}
        }
        for _, kind in ipairs({ 'session', 'admission', 'saga', 'character', 'other' }) do
          state.kinds[kind] = { entry_count = 0, kind_limit = globalLimit }
        end
        failureStage, raceOwner, concurrentRow = nil, nil, nil
        exactReads, capacityQueries = 0, 0
      end
      local function exactRow(name)
        return state.leases[name]
          or (concurrentRow and concurrentRow.name == name and concurrentRow or nil)
      end

      local function execute(sql, parameters)
        parameters = parameters or {}
        if sql:find('synex_instances', 1, true) then return {{ status = 'ready' }} end
        if sql:find('synex_instance_boots', 1, true) then return {{ boot_id = parameters[2] }} end
        if sql:find('SELECT', 1, true) and sql:find('synex_cluster_leases', 1, true) then
          exactReads = exactReads + 1
          if failureStage == 'verify' and exactReads >= 2 then return {} end
          local row = exactRow(parameters[1])
          return row and {{
            owner_id = row.owner_id, fencing_token = row.fencing_token,
            valid = row.valid, lease_capacity_kind = row.lease_capacity_kind
          }} or {}
        end
        if sql:find('INSERT IGNORE INTO', 1, true)
            and sql:find('synex_cluster_leases', 1, true) then
          local name, owner = parameters[1], parameters[2]
          if failureStage == 'candidate_result' then return { affectedRows = 2 } end
          if raceOwner then
            concurrentRow = {
              name = name, owner_id = raceOwner, fencing_token = 1,
              valid = 1, lease_capacity_kind = kindFor(name)
            }
            raceOwner = nil
            return { affectedRows = 0 }
          end
          if exactRow(name) then return { affectedRows = 0 } end
          state.leases[name] = {
            name = name, owner_id = owner, fencing_token = 1,
            valid = 1, lease_capacity_kind = kindFor(name)
          }
          return { affectedRows = 1 }
        end
        if sql:find('UPDATE', 1, true) and sql:find('synex_cluster_leases', 1, true) then
          local owner, name, expectedOwner = parameters[3], parameters[5], parameters[6]
          local row = exactRow(name)
          if not row or (row.valid == 1 and row.owner_id ~= expectedOwner) then
            return { affectedRows = 0 }
          end
          row.owner_id, row.fencing_token, row.valid = owner, row.fencing_token + 1, 1
          return { affectedRows = 1 }
        end
        if sql:find('FROM', 1, true) and sql:find('synex_cluster_lease_capacity', 1, true) then
          capacityQueries = capacityQueries + 1
          return { clone(state.global) }
        end
        if sql:find('FROM', 1, true)
            and sql:find('synex_cluster_lease_kind_capacity', 1, true) then
          capacityQueries = capacityQueries + 1
          local kind = parameters[1]
          local row = state.kinds[kind]
          return row and {{
            lease_capacity_kind = kind, entry_count = row.entry_count,
            kind_limit = row.kind_limit
          }} or {}
        end
        if sql:find('UPDATE', 1, true)
            and sql:find('synex_cluster_lease_capacity', 1, true) then
          capacityQueries = capacityQueries + 1
          if failureStage == 'global_increment'
              or state.global.entry_count ~= parameters[1]
              or state.global.entry_count >= state.global.global_limit then
            return { affectedRows = 0 }
          end
          state.global.entry_count = state.global.entry_count + 1
          return { affectedRows = 1 }
        end
        if sql:find('UPDATE', 1, true)
            and sql:find('synex_cluster_lease_kind_capacity', 1, true) then
          capacityQueries = capacityQueries + 1
          local kind, expected = parameters[1], parameters[2]
          local row = state.kinds[kind]
          if failureStage == 'kind_increment' or not row
              or row.entry_count ~= expected or row.entry_count >= row.kind_limit then
            return { affectedRows = 0 }
          end
          row.entry_count = row.entry_count + 1
          return { affectedRows = 1 }
        end
        error('unexpected lease-capacity SQL: ' .. sql)
      end

      local adapter = {
        query = function() return {} end,
        scalar = function() return nil end,
        insert = function() return 0 end,
        update = function() return 0 end,
        transaction = function() return true end
      }
      function adapter.startTransaction(handler)
        local before = clone(state)
        concurrentRow = nil
        local ok, accepted = pcall(handler, execute)
        if ok and accepted == true then
          concurrentRow = nil
          return true, nil
        end
        local winner = concurrentRow and clone(concurrentRow) or nil
        state = before
        concurrentRow = nil
        if winner then
          state.leases[winner.name] = winner
          state.global.entry_count = state.global.entry_count + 1
          local kind = winner.lease_capacity_kind
          state.kinds[kind].entry_count = state.kinds[kind].entry_count + 1
        end
        if not ok then error(accepted) end
        return false, nil
      end
      local leases = SynexCoreFactories.persistence({
        platform = platform, foundation = foundation, db = adapter,
        instanceId = 'instance-a', config = { deadlockRetries = 1 }
      }).leases

      reset(0, 10)
      local other = assert(leases:acquire('custom:alpha', 'worker-a', 45))
      assert(other.fencingToken == 1 and state.global.entry_count == 1
        and state.kinds.other.entry_count == 1
        and state.leases['custom:alpha'].lease_capacity_kind == 'other')

      reset(0, 10)
      local session = assert(leases:acquire(
        'session:user-a', 'instance-a:worker', 45, 'instance-a', 'boot-a'))
      assert(session.fencingToken == 1 and state.global.entry_count == 1
        and state.kinds.session.entry_count == 1
        and state.leases['session:user-a'].lease_capacity_kind == 'session')

      reset(1, 1)
      state.kinds.other.entry_count, state.kinds.other.kind_limit = 1, 1
      local globalDenied, globalError = leases:acquire('custom:global-cap', 'worker-a', 45)
      assert(globalDenied == nil and globalError.code == 'LEASE_CAPACITY_EXCEEDED'
        and globalError.retryable and globalError.details.scope == 'global'
        and state.leases['custom:global-cap'] == nil and state.global.entry_count == 1)

      reset(1, 10)
      state.kinds.other.entry_count, state.kinds.other.kind_limit = 1, 1
      local kindDenied, kindError = leases:acquire('custom:kind-cap', 'worker-a', 45)
      assert(kindDenied == nil and kindError.code == 'LEASE_CAPACITY_EXCEEDED'
        and kindError.details.scope == 'other' and state.leases['custom:kind-cap'] == nil
        and state.global.entry_count == 1 and state.kinds.other.entry_count == 1)

      reset(1, 1)
      state.kinds.other.entry_count, state.kinds.other.kind_limit = 1, 1
      state.leases['custom:existing'] = {
        name = 'custom:existing', owner_id = 'worker-a', fencing_token = 3,
        valid = 1, lease_capacity_kind = 'other'
      }
      local existing = assert(leases:acquire('custom:existing', 'worker-a', 45))
      assert(existing.fencingToken == 4 and state.global.entry_count == 1
        and state.kinds.other.entry_count == 1)
      state.leases['custom:existing'].owner_id = 'worker-b'
      local foreign, foreignError = leases:acquire('custom:existing', 'worker-a', 45)
      assert(foreign == nil and foreignError.code == 'LEASE_BUSY'
        and state.global.entry_count == 1 and state.kinds.other.entry_count == 1)
      state.leases['custom:existing'].valid = 0
      local expired = assert(leases:acquire('custom:existing', 'worker-a', 45))
      assert(expired.fencingToken == 5 and state.global.entry_count == 1
        and state.kinds.other.entry_count == 1)

      for _, stage in ipairs({ 'kind_increment', 'verify', 'candidate_result' }) do
        reset(0, 10)
        failureStage = stage
        local failed, failure = leases:acquire('custom:rollback-' .. stage, 'worker-a', 45)
        assert(failed == nil and failure.code == 'LEASE_CAPACITY_INVALID'
          and state.global.entry_count == 0 and state.kinds.other.entry_count == 0
          and state.leases['custom:rollback-' .. stage] == nil)
      end

      reset(0, 10)
      state.kinds.other.entry_count = 1
      local drift, driftError = leases:acquire('custom:drift', 'worker-a', 45)
      assert(drift == nil and driftError.code == 'LEASE_CAPACITY_INVALID'
        and state.leases['custom:drift'] == nil and state.global.entry_count == 0)

      reset(0, 10)
      raceOwner = 'worker-b'
      local raced, raceError = leases:acquire('custom:race', 'worker-a', 45)
      assert(raced == nil and raceError.code == 'LEASE_BUSY'
        and state.leases['custom:race'].owner_id == 'worker-b'
        and state.global.entry_count == 1 and state.kinds.other.entry_count == 1,
        'a READ COMMITTED same-name loser must not add a second capacity charge')
      local winnerReplay = assert(leases:acquire('custom:race', 'worker-b', 45))
      assert(winnerReplay.fencingToken == 2 and state.global.entry_count == 1
        and state.kinds.other.entry_count == 1)

      reset(0, 10)
      local migrationLease = assert(leases:acquire(
        'schema_migrations', 'instance-a:migrations', 45))
      assert(migrationLease.fencingToken == 1 and capacityQueries == 0
        and state.global.entry_count == 0 and state.leases.schema_migrations)

      local beforeInvalid = exactReads
      local invalid, invalidError = leases:acquire('custom:bad\\nname', 'worker-a', 45)
      assert(invalid == nil and invalidError.code == 'INVALID_LEASE'
        and exactReads == beforeInvalid)
      return table.concat({ other.fencingToken, session.fencingToken,
        globalError.details.scope, kindError.details.scope, existing.fencingToken,
        foreignError.code, expired.fencingToken, driftError.code, raceError.code,
        winnerReplay.fencingToken, migrationLease.fencingToken }, ':')
    `);
    assert.equal(
      result,
      '1:1:global:other:4:LEASE_BUSY:5:LEASE_CAPACITY_INVALID:LEASE_BUSY:2:1',
    );
  } finally {
    engine.global.close();
  }
});

test('terminal cluster lease compaction decrements exact counters atomically and retries from clean state', async () => {
  const engine = await createPersistenceEngine();
  try {
    const result = await engine.doString(`
      local platform = {
        nowGame = function() return 1000 end,
        random = function() return 9 end,
        wait = function() end,
        print = function() end,
        jsonEncode = function() return '{}' end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      local state, failureStage, successfulLocks, deadlockOnce
      local attemptLocks = {}
      local function clone(value)
        if type(value) ~= 'table' then return value end
        local copy = {}
        for key, item in pairs(value) do copy[key] = clone(item) end
        return copy
      end
      local function reset()
        state = {
          global = { entry_count = 4, global_limit = 100 },
          kinds = {
            other = { entry_count = 2, kind_limit = 100 },
            session = { entry_count = 2, kind_limit = 100 }
          },
          leases = {
            ['other:active'] = { kind = 'other', marker = nil },
            ['other:terminal'] = { kind = 'other', marker = 'old' },
            ['session:active'] = { kind = 'session', marker = nil },
            ['session:terminal'] = { kind = 'session', marker = 'old' },
            ['schema_migrations'] = { kind = nil, marker = 'old' }
          }
        }
        failureStage, successfulLocks, deadlockOnce = nil, nil, false
        attemptLocks = {}
      end
      local function candidates(maximum)
        local names = {}
        for name, row in pairs(state.leases) do
          if row.marker and row.kind and name ~= 'schema_migrations' then
            names[#names + 1] = name
          end
        end
        table.sort(names)
        local rows = {}
        for index = 1, math.min(maximum, #names) do
          local name = names[index]
          rows[index] = { lease_name = name, lease_capacity_kind = state.leases[name].kind }
        end
        return rows
      end
      local function execute(sql, parameters)
        parameters = parameters or {}
        if sql:find('SELECT', 1, true) and sql:find('synex_cluster_leases', 1, true) then
          return candidates(parameters[1])
        end
        if sql:find('FROM', 1, true) and sql:find('synex_cluster_lease_capacity', 1, true) then
          attemptLocks[#attemptLocks + 1] = 'global'
          return { clone(state.global) }
        end
        if sql:find('FROM', 1, true)
            and sql:find('synex_cluster_lease_kind_capacity', 1, true) then
          local kind = parameters[1]
          attemptLocks[#attemptLocks + 1] = kind
          local row = state.kinds[kind]
          return row and {{
            lease_capacity_kind = kind, entry_count = row.entry_count,
            kind_limit = row.kind_limit
          }} or {}
        end
        if sql:find('DELETE FROM', 1, true) and sql:find('synex_cluster_leases', 1, true) then
          if failureStage == 'delete' then return { affectedRows = 0 } end
          local deleted = 0
          for _, name in ipairs(parameters) do
            local row = state.leases[name]
            if row and row.marker and row.kind and name ~= 'schema_migrations' then
              state.leases[name] = nil
              deleted = deleted + 1
            end
          end
          return { affectedRows = deleted }
        end
        if sql:find('UPDATE', 1, true) and sql:find('synex_cluster_lease_capacity', 1, true) then
          if failureStage == 'global' or state.global.entry_count ~= parameters[2]
              or state.global.entry_count < parameters[3] then return { affectedRows = 0 } end
          state.global.entry_count = state.global.entry_count - parameters[1]
          return { affectedRows = 1 }
        end
        if sql:find('UPDATE', 1, true)
            and sql:find('synex_cluster_lease_kind_capacity', 1, true) then
          local release, kind, expected = parameters[1], parameters[2], parameters[3]
          local row = state.kinds[kind]
          if failureStage == 'kind' or not row or row.entry_count ~= expected
              or row.entry_count < parameters[4] then return { affectedRows = 0 } end
          row.entry_count = row.entry_count - release
          return { affectedRows = 1 }
        end
        error('unexpected lease compaction SQL: ' .. sql)
      end
      local adapter = {
        query = function() return {} end,
        scalar = function() return nil end,
        insert = function() return 0 end,
        update = function() return 0 end,
        transaction = function() return true end
      }
      function adapter.startTransaction(handler)
        local before = clone(state)
        attemptLocks = {}
        local ok, accepted = pcall(handler, execute)
        if deadlockOnce then
          deadlockOnce = false
          state = before
          state.leases['session:terminal'].marker = nil
          return nil, { code = 'ER_LOCK_DEADLOCK', message = 'fixture deadlock' }
        end
        if ok and accepted == true then
          successfulLocks = clone(attemptLocks)
          return true, nil
        end
        state = before
        if not ok then error(accepted) end
        return false, nil
      end
      local leases = SynexCoreFactories.persistence({
        platform = platform, foundation = foundation, db = adapter,
        config = { deadlockRetries = 1 }
      }).leases

      reset()
      local invalid, invalidError = leases:compactTerminal(1001)
      assert(invalid == nil and invalidError.code == 'INVALID_ARGUMENT')
      for _, stage in ipairs({ 'delete', 'global', 'kind' }) do
        failureStage = stage
        local failed, failure = leases:compactTerminal(2)
        assert(failed == nil and failure.code == 'LEASE_CAPACITY_INVALID'
          and state.global.entry_count == 4 and state.kinds.other.entry_count == 2
          and state.kinds.session.entry_count == 2
          and state.leases['other:terminal'] and state.leases['session:terminal'])
      end
      failureStage = nil
      local report = assert(leases:compactTerminal(2))
      assert(report.selected == 2 and report.deleted == 2 and report.maximum == 2)
      assert(state.global.entry_count == 2 and state.kinds.other.entry_count == 1
        and state.kinds.session.entry_count == 1
        and state.leases['other:terminal'] == nil
        and state.leases['session:terminal'] == nil
        and state.leases.schema_migrations ~= nil)
      assert(table.concat(successfulLocks, ',') == 'global,other,session')

      reset()
      state.global.entry_count = 1
      local drifted, driftError = leases:compactTerminal(2)
      assert(drifted == nil and driftError.code == 'LEASE_CAPACITY_INVALID'
        and state.leases['other:terminal'] and state.leases['session:terminal'])

      reset()
      deadlockOnce = true
      local retried = assert(leases:compactTerminal(2))
      assert(retried.selected == 1 and retried.deleted == 1,
        'retry-visible report fields must not leak from the rolled-back deadlock attempt')
      assert(state.global.entry_count == 3 and state.kinds.other.entry_count == 1
        and state.kinds.session.entry_count == 2
        and state.leases['other:terminal'] == nil
        and state.leases['session:terminal'] ~= nil)
      return table.concat({ invalidError.code, report.deleted,
        table.concat(successfulLocks, ','), driftError.code,
        retried.selected, retried.deleted }, ':')
    `);
    assert.equal(
      result,
      'INVALID_ARGUMENT:2:global,other:LEASE_CAPACITY_INVALID:1:1',
    );
  } finally {
    engine.global.close();
  }
});

test('cluster lease capacity runtime keeps fixed labels and row-before-counter lock order', async () => {
  const source = await readFile(
    path.join(root, 'core/synex_core/server/persistence.lua'),
    'utf8',
  );
  const acquire = source.match(
    /function leases:acquire\(name, owner, ttlSeconds, requesterInstanceId, requesterBootId\)([\s\S]*?)\n    end\n    function leases:renew/u,
  )?.[1];
  const compactor = source.match(
    /function leases:compactTerminal\(maximum\)([\s\S]*?)\n    end/u,
  )?.[1];
  assert.ok(acquire && compactor);
  assert.ok(acquire.indexOf('synex_instances') < acquire.indexOf('synex_instance_boots'));
  assert.ok(acquire.indexOf('synex_instance_boots') < acquire.indexOf('lockExactLease'));
  assert.ok(acquire.indexOf('INSERT IGNORE INTO `synex_cluster_leases`')
    < acquire.indexOf('FROM `synex_cluster_lease_capacity`'));
  assert.ok(acquire.indexOf('FROM `synex_cluster_lease_capacity`')
    < acquire.indexOf('FROM `synex_cluster_lease_kind_capacity`'));
  assert.match(acquire, /insertedRows == 0[\s\S]*?rows = lockExactLease\(\)/u);
  assert.match(acquire, /LEASE_CAPACITY_EXCEEDED/u);
  assert.match(source, /if name == 'schema_migrations' then return nil end/u);
  assert.match(compactor, /LIMIT \? FOR UPDATE/u);
  assert.match(compactor, /table\.sort\(kinds\)/u);
  assert.ok(compactor.indexOf('FROM `synex_cluster_lease_capacity`')
    < compactor.indexOf('FROM `synex_cluster_lease_kind_capacity`'));
  assert.ok(compactor.indexOf('DELETE FROM `synex_cluster_leases`')
    < compactor.indexOf('UPDATE `synex_cluster_lease_capacity`'));
  assert.match(source, /leaseCapacityKinds = \{ 'admission', 'character', 'other', 'saga', 'session' \}/u);
  for (const metric of [
    'synex_cluster_lease_capacity_entries',
    'synex_cluster_lease_capacity_limit',
    'synex_cluster_lease_capacity_utilization',
    'synex_cluster_lease_capacity_utilization_high_watermark',
    'synex_cluster_lease_capacity_denials_total',
  ]) assert.match(source, new RegExp(metric, 'u'));
});
