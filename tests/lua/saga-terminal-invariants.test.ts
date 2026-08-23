import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';

const root = process.cwd();

test('public saga recording locks state and never revives a terminal saga', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    for (const relativePath of [
      'core/synex_core/server/factories.lua',
      'core/synex_core/server/foundation.lua',
      'core/synex_core/server/reliability.lua',
    ]) {
      await engine.doString(await readFile(path.join(root, relativePath), 'utf8'));
    }
    const result = await engine.doString(`
      local platform = {
        nowGame = function() return 1000 end, random = function() return 3 end,
        print = function() end, jsonEncode = function() return '{}' end,
        jsonDecode = function() return {} end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      local row = { id = 41, state = 'failed', current_step = 4, version = 9 }
      local stepWrites, sagaWrites, leaseRetirements, sawLock, terminalSql = 0, 0, 0, false, nil
      local database = {}
      function database:withTransaction(handler)
        local before = foundation.copy(row)
        local committed = handler(function(sql, parameters)
          if sql:find('FROM ' .. string.char(96) .. 'synex_sagas' .. string.char(96), 1, true)
            and sql:find('FOR UPDATE', 1, true) then
            sawLock = true
            return { foundation.copy(row) }
          end
          if sql:find('INSERT INTO ' .. string.char(96) .. 'synex_saga_steps'
            .. string.char(96), 1, true) then
            stepWrites = stepWrites + 1
            return { affectedRows = 1 }
          end
          if sql:find('UPDATE ' .. string.char(96) .. 'synex_sagas'
            .. string.char(96), 1, true) then
            terminalSql = sql
            if row.version ~= parameters[6]
              or row.state == 'completed' or row.state == 'failed' or row.state == 'cancelled' then
              return { affectedRows = 0 }
            end
            sagaWrites = sagaWrites + 1
            row.state, row.current_step = parameters[1], parameters[2]
            row.version = row.version + 1
            return { affectedRows = 1 }
          end
          if sql:find('UPDATE ' .. string.char(96) .. 'synex_cluster_leases'
            .. string.char(96), 1, true) then
            leaseRetirements = leaseRetirements + 1
            assert(parameters[1] == 'saga:saga_running')
            assert(sql:find('terminal_compaction_at', 1, true))
            return { affectedRows = 0 }
          end
          error('unexpected saga transaction SQL')
        end)
        if committed ~= true then
          row = before
          return nil, foundation.error('TRANSACTION_REJECTED', 'fixture rollback')
        end
        return true, nil
      end
      local sagas = SynexCoreFactories.reliability({
        foundation = foundation, database = database, platform = platform,
        instanceId = 'instance-a', sha256 = function() return string.rep('a', 64) end,
        features = { sagas = true }
      }).sagas

      for _, state in ipairs({'failed', 'completed', 'cancelled'}) do
        row = { id = 41, state = state, current_step = 4, version = 9 }
        local recorded, recordError = sagas:record(
          'synex_fixture', 'saga_terminal', 9, 'fixture.step', 'succeeded', {})
        assert(recorded == nil and recordError.code == 'SAGA_TERMINAL')
        assert(row.state == state and row.version == 9 and row.current_step == 4)
      end
      assert(sawLock and stepWrites == 0 and sagaWrites == 0)

      row = { id = 42, state = 'running', current_step = 2, version = 7 }
      local failed = assert(sagas:record(
        'synex_fixture', 'saga_running', 7, 'fixture.step', 'failed', {},
        { code = 'FIXTURE_FAILED' }))
      assert(failed.state == 'failed' and failed.version == 8
        and row.state == 'failed' and row.version == 8)
      assert(stepWrites == 1 and sagaWrites == 1)
      assert(leaseRetirements == 1)
      assert(terminalSql:find("AND " .. string.char(96) .. "state" .. string.char(96)
        .. " IN ('pending', 'running', 'compensating')", 1, true))
      assert(terminalSql:find('completed_at', 1, true)
        and terminalSql:find("WHEN ? = 'failed'", 1, true))
      return table.concat({stepWrites, sagaWrites, leaseRetirements,
        row.state, row.version}, ':')
    `);
    assert.equal(result, '1:1:1:failed:8');
  } finally {
    engine.global.close();
  }
});

test('saga handlers never run when their execution-lease heartbeat failed to start', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    for (const relativePath of [
      'core/synex_core/server/factories.lua',
      'core/synex_core/server/foundation.lua',
      'core/synex_core/server/registries.lua',
      'core/synex_core/server/saga_runtime.lua',
    ]) {
      await engine.doString(await readFile(path.join(root, relativePath), 'utf8'));
    }
    const result = await engine.doString(`
      local platform = {
        nowGame = function() return 1000 end, random = function() return 7 end,
        print = function() end, jsonEncode = function() return '{}' end,
        createThread = function() error('fixture thread creation failed') end,
        wait = function() end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('saga-dead-heartbeat')
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      local epoch = registries.owners:activate('synex_fixture')
      local saga = {
        publicId = 'saga-dead-heartbeat', ownerResource = 'synex_fixture',
        sagaType = 'fixture.dead-heartbeat', correlationId = 'fixture-correlation',
        state = 'running', currentStep = 1, version = 2, context = {},
        ageMs = 100000, deadlineExpired = false,
        steps = {{
          sequence = 1, name = 'apply', event = 'started', attempt = 1,
          payload = { phase = 'forward' }
        }}
      }
      local handlerRuns, appendWrites = 0, 0
      local acquired, renewed, released = 0, 0, 0
      local store = {}
      function store:candidates()
        return {{
          publicId = saga.publicId, ownerResource = saga.ownerResource,
          sagaType = saga.sagaType, state = saga.state, version = saga.version
        }}, nil
      end
      function store:load(publicId, ownerResource)
        assert(publicId == saga.publicId and ownerResource == saga.ownerResource)
        return foundation.copy(saga), nil
      end
      function store:appendRuntimeEvent()
        appendWrites = appendWrites + 1
        error('a dead execution lease must not append saga history')
      end
      function store:snapshot() return { enabled = true, total = 1 }, nil end
      local leases = {
        acquire = function(_, name, owner, ttl, requesterInstanceId, requesterBootId)
          acquired = acquired + 1
          assert(name == 'saga:' .. saga.publicId and ttl == 300
            and requesterInstanceId == 'instance-a' and requesterBootId == 'boot-a')
          return {
            name = name, owner = owner, fencingToken = acquired, ttlSeconds = ttl,
            requesterInstanceId = requesterInstanceId, requesterBootId = requesterBootId
          }, nil
        end,
        renew = function() renewed = renewed + 1 return true, nil end,
        release = function() released = released + 1 return true, nil end
      }
      local runtime = SynexCoreFactories.sagaRuntime({
        foundation = foundation, platform = platform, sagas = store,
        audit = { append = function() error('unexpected audit write') end },
        leases = leases, owners = registries.owners,
        instances = { bootId = function() return 'boot-a', nil end },
        instanceId = 'instance-a', enabled = true
      })
      assert(runtime:register('synex_fixture', epoch, {
        name = saga.sagaType,
        steps = {{
          name = 'apply',
          run = function() handlerRuns = handlerRuns + 1 return { output = {} }, nil end,
          compensate = function() return { output = {} }, nil end
        }}
      }))
      for _ = 1, 2 do
        local report, dispatchError = runtime:dispatchBatch(1)
        assert(report and report.failed == 1 and report.processed == 0)
        assert(dispatchError and dispatchError.code == 'SAGA_LEASE_LOST')
      end
      assert(handlerRuns == 0 and appendWrites == 0 and renewed == 0)
      assert(acquired == 2 and released == 2)
      return table.concat({handlerRuns, appendWrites, renewed, acquired, released}, ':')
    `);
    assert.equal(result, '0:0:0:2:2');
  } finally {
    engine.global.close();
  }
});
