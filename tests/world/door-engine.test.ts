import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import { LuaFactory, type LuaEngine } from 'wasmoon';

async function load(engine: LuaEngine, path: string): Promise<void> {
  await engine.doString(await readFile(path, 'utf8'));
}

async function runtime(loadRepository = false): Promise<LuaEngine> {
  const engine = await new LuaFactory().createEngine();
  await load(engine, 'resources/synex_world/shared/limits.lua');
  await load(engine, 'resources/synex_world/shared/validation.lua');
  if (loadRepository) await load(engine, 'resources/synex_world/server/repository.lua');
  await load(engine, 'resources/synex_world/server/door_engine.lua');
  await engine.doString(String.raw`
    function WorldDoorEncode(value)
      local kind = type(value)
      if kind == 'nil' then return 'null' end
      if kind == 'boolean' then return value and 'true' or 'false' end
      if kind == 'number' then return tostring(value) end
      if kind == 'string' then return '"' .. value:gsub('"', '\\"') .. '"' end
      local keys, result = {}, {}
      for key in pairs(value) do keys[#keys + 1] = key end
      table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
      for index, key in ipairs(keys) do
        result[index] = WorldDoorEncode(tostring(key)) .. ':' .. WorldDoorEncode(value[key])
      end
      return '{' .. table.concat(result, ',') .. '}'
    end
  `);
  return engine;
}

test('logical door groups keep one server-authoritative state with OCC and provenance', async () => {
  const engine = await runtime();
  try {
    const result = await engine.doString(String.raw`
      local definitions = {
        ['synex_test:front_door'] = {
          kind = 'door', key = 'synex_test:front_door', revision = 5,
          defaultState = 'LOCKED', persistent = false, leaves = {{ id = 'left' }, { id = 'right' }}
        },
        ['synex_test:armory_door'] = {
          kind = 'door', key = 'synex_test:armory_door', revision = 5,
          defaultState = 'LOCKED', persistent = true, leaves = {{ id = 'main' }}
        }
      }
      local persisted, captured
      local persistenceCalls, changedCalls = 0, 0
      local repository = {}
      function repository:getDoorState() return persisted end
      function repository:setDoorState(command)
        persistenceCalls = persistenceCalls + 1
        captured = command
        return { key = command.doorKey, schemaVersion = command.schemaVersion,
          state = command.state, version = command.expectedVersion + 1, persistent = true,
          replayed = persistenceCalls > 1 }
      end
      local ids = 0
      local doors = SynexWorldDoorEngine.create({
        repository = repository,
        resolveDefinition = function(key) return definitions[key] end,
        newId = function() ids = ids + 1; return ('world_%030d'):format(ids) end,
        nowIso = function() return '2026-08-27T12:00:00Z' end,
        scheduler = {
          after = function() error('relock schedule was not expected') end,
          cancel = function() return true end,
        },
        onChanged = function() changedCalls = changedCalls + 1 end
      })
      local initial = assert(doors:get({ key = 'synex_test:front_door' }))
      assert(initial.state == 'LOCKED' and initial.version == 0 and initial.defaulted == true)
      local opened = assert(doors:setState({
        key = 'synex_test:front_door', state = 'UNLOCKED', expectedVersion = 0,
        idempotencyKey = 'door_runtime_0001', reasonCode = 'door.opened'
      }, { caller = 'synex_test', traceId = 'trace_door_0001' }))
      assert(opened.version == 1 and opened.state == 'UNLOCKED'
        and opened.provenance.sourceResource == 'synex_test')
      definitions['synex_test:front_door'].revision = 6
      local replaced, replacedError = doors:setState({
        key = 'synex_test:front_door', expectedDefinitionRevision = 5,
        state = 'LOCKED', expectedVersion = 1,
        idempotencyKey = 'door_revision_0001', reasonCode = 'door.closed'
      }, { caller = 'synex_test', traceId = 'trace_door_revision_0001' })
      assert(replaced == nil and replacedError.code == 'STALE_WORLD_REF')
      definitions['synex_test:front_door'].revision = 5
      local stale, staleError = doors:setState({
        key = 'synex_test:front_door', state = 'LOCKED', expectedVersion = 0,
        idempotencyKey = 'door_runtime_0002', reasonCode = 'door.closed'
      }, { caller = 'synex_test', traceId = 'trace_door_0002' })
      assert(stale == nil and staleError.code == 'CONCURRENT_MODIFICATION')
      local invalid, invalidError = doors:setState({
        key = 'synex_test:front_door', state = 'AJAR', expectedVersion = 1,
        idempotencyKey = 'door_runtime_0003', reasonCode = 'door.changed'
      }, { caller = 'synex_test', traceId = 'trace_door_0003' })
      assert(invalid == nil and invalidError.code == 'DOOR_STATE_INVALID')
      local durable = assert(doors:setState({
        key = 'synex_test:armory_door', state = 'DISABLED', expectedVersion = 0,
        idempotencyKey = 'door_persist_0001', reasonCode = 'door.maintenance'
      }, { caller = 'synex_test', traceId = 'trace_door_0004',
        actor = { type = 'character', ref = 'character:42' } }))
      assert(durable.persistent == true and captured.provenance.actorType == 'character')
      local replay = assert(doors:setState({
        key = 'synex_test:armory_door', state = 'DISABLED', expectedVersion = 0,
        idempotencyKey = 'door_persist_0001', reasonCode = 'door.maintenance'
      }, { caller = 'synex_test', traceId = 'trace_door_0004',
        actor = { type = 'character', ref = 'character:42' } }))
      assert(replay.replayed == true and changedCalls == 2)
      persisted = { key = 'synex_test:armory_door', schemaVersion = 2,
        state = 'LOCKED', version = 4, persistent = true }
      assert(doors:purgeRuntime('synex_test:armory_door'))
      local drifted, driftError = doors:get({ key = 'synex_test:armory_door' })
      assert(drifted == nil and driftError.code == 'STATE_SCHEMA_MISMATCH')
      local purged = assert(doors:purgeRuntime('synex_test:front_door'))
      assert(purged.removed == 1 and purged.persistentPreserved == true)
      return table.concat({ opened.state, replacedError.code, staleError.code, invalidError.code,
        captured.provenance.actorType, driftError.code, purged.removed, changedCalls }, ':')
    `);
    assert.equal(result,
      'UNLOCKED:STALE_WORLD_REF:CONCURRENT_MODIFICATION:DOOR_STATE_INVALID:character:STATE_SCHEMA_MISMATCH:1:2');
  } finally {
    engine.global.close();
  }
});

test('persistent door state restores into a fresh engine and preserves OCC continuity', async () => {
  const engine = await runtime();
  try {
    const result = await engine.doString(String.raw`
      local definition = {
        kind = 'door', key = 'synex_test:restart_door', revision = 9,
        defaultState = 'LOCKED', persistent = true, leaves = {{ id = 'main' }}
      }
      local stored, reads, writes, ids = nil, 0, 0, 0
      local repository = {}
      function repository:getDoorState(key)
        reads = reads + 1
        assert(key == definition.key)
        return stored and SynexWorldValidation.copy(stored) or nil
      end
      function repository:setDoorState(command)
        local currentVersion = stored and stored.version or 0
        assert(command.expectedVersion == currentVersion)
        writes = writes + 1
        stored = {
          key = command.doorKey, schemaVersion = command.schemaVersion,
          state = command.state, version = currentVersion + 1,
          persistent = true, defaulted = false,
        }
        return SynexWorldValidation.copy(stored)
      end
      local function createEngine()
        return SynexWorldDoorEngine.create({
          repository = repository,
          resolveDefinition = function(key)
            if key == definition.key then return definition end
          end,
          newId = function()
            ids = ids + 1
            return ('world_%030d'):format(ids)
          end,
          nowIso = function() return '2026-08-27T12:00:00Z' end,
          scheduler = {
            after = function() error('relock schedule was not expected') end,
            cancel = function() return true end,
          },
        })
      end

      local beforeRestart = createEngine()
      local opened = assert(beforeRestart:setState({
        key = definition.key, state = 'UNLOCKED', expectedVersion = 0,
        idempotencyKey = 'door_restart_0001', reasonCode = 'door.opened',
      }, { caller = 'synex_test', traceId = 'trace_door_restart_0001' }))
      assert(opened.state == 'UNLOCKED' and opened.version == 1)

      local afterRestart = createEngine()
      local restored = assert(afterRestart:get({ key = definition.key }))
      assert(restored.key == definition.key and restored.state == 'UNLOCKED')
      assert(restored.version == 1 and restored.schemaVersion == 1)
      assert(restored.definitionRevision == 9 and restored.persistent == true)
      assert(restored.defaulted ~= true and reads == 1)

      local closed = assert(afterRestart:setState({
        key = definition.key, state = 'LOCKED', expectedVersion = 1,
        idempotencyKey = 'door_restart_0002', reasonCode = 'door.closed',
      }, { caller = 'synex_test', traceId = 'trace_door_restart_0002' }))
      assert(closed.state == 'LOCKED' and closed.version == 2)
      assert(afterRestart:get({ key = definition.key }).version == 2 and reads == 1)
      return table.concat({ restored.state, restored.version, closed.state,
        closed.version, reads, writes }, ':')
    `);
    assert.equal(result, 'UNLOCKED:1:LOCKED:2:1:2');
  } finally {
    engine.global.close();
  }
});

test('repository persists semantic door state and outbox event atomically without physics data', async () => {
  const engine = await runtime(true);
  try {
    const result = await engine.doString(String.raw`
      local statements, parameters = {}, {}
      local database = {}
      function database:read() return {} end
      function database:transaction(request, handler)
        local tx = {}
        function tx.affected(sql, values)
          statements[#statements + 1], parameters[#parameters + 1] = sql, values
          if sql:find('synex_world_door_states', 1, true)
            or sql:find('synex_world_outbox', 1, true) then return 1 end
          error('cross-domain SQL')
        end
        function tx.one() return nil end
        local called, value, operationError = pcall(handler, tx)
        if not called then return nil, value end
        return value, operationError, { replayed = false }
      end
      local repository = SynexWorldRepository.create({
        database = database, jsonEncode = WorldDoorEncode,
        jsonDecode = function() error('decode not expected') end
      })
      local changed = assert(repository:setDoorState({
        doorKey = 'synex_test:front_door', schemaVersion = 1, state = 'LOCKED',
        expectedVersion = 0, idempotencyKey = 'door_atomic_0001',
        eventId = 'world_000000000000000000000000000001',
        provenance = { actorType = 'resource', actorRef = 'synex_test',
          sourceResource = 'synex_test', reasonCode = 'door.locked',
          traceId = 'trace_door_0010', timestamp = '2026-08-27T12:00:00Z' }
      }))
      assert(changed.state == 'LOCKED' and changed.version == 1 and #statements == 2)
      assert(statements[1]:find('synex_world_door_states', 1, true)
        and statements[2]:find('synex_world_outbox', 1, true))
      local combined = table.concat(statements, '\n')
      assert(not combined:find('ratio', 1, true) and not combined:find('hinge', 1, true)
        and not combined:find('velocity', 1, true))
      return changed.state .. ':' .. changed.version .. ':' .. #statements
    `);
    assert.equal(result, 'LOCKED:1:2');
  } finally {
    engine.global.close();
  }
});

test('auto relock uses bounded one-shot schedules without violating replay or OCC fences', async () => {
  const engine = await runtime();
  try {
    const result = await engine.doString(String.raw`
      local definitions = {
        ['synex_test:runtime_door'] = {
          kind = 'door', key = 'synex_test:runtime_door', revision = 7,
          defaultState = 'LOCKED', persistent = false, autoRelockSeconds = 2,
          leaves = {{ id = 'main' }}
        },
        ['synex_test:persistent_door'] = {
          kind = 'door', key = 'synex_test:persistent_door', revision = 9,
          defaultState = 'LOCKED', persistent = true, autoRelockSeconds = 3,
          leaves = {{ id = 'main' }}
        }
      }
      local stored, replayByKey = {}, {}
      local repository = {}
      function repository:getDoorState(key)
        return stored[key] and SynexWorldValidation.copy(stored[key]) or nil
      end
      function repository:setDoorState(command)
        local replay = replayByKey[command.idempotencyKey]
        if replay then
          local value = SynexWorldValidation.copy(replay)
          value.replayed = true
          return value
        end
        local current = stored[command.doorKey]
        local version = current and current.version or 0
        if version ~= command.expectedVersion then
          return SynexWorldValidation.failure('CONCURRENT_MODIFICATION',
            'stale door mutation', true)
        end
        local value = { key = command.doorKey, schemaVersion = command.schemaVersion,
          state = command.state, version = version + 1, persistent = true,
          provenance = { actor = { type = command.provenance.actorType,
            ref = command.provenance.actorRef },
            sourceResource = command.provenance.sourceResource,
            reasonCode = command.provenance.reasonCode,
            traceId = command.provenance.traceId,
            timestamp = command.provenance.timestamp } }
        stored[command.doorKey] = SynexWorldValidation.copy(value)
        replayByKey[command.idempotencyKey] = SynexWorldValidation.copy(value)
        value.replayed = false
        return value
      end

      local callbacks, delays, cancelled = {}, {}, {}
      local scheduleCalls, cancelCalls, schedulerFailures = 0, 0, 0
      local failNextSchedule = false
      local scheduler = {}
      function scheduler.after(delay, handler, options)
        scheduleCalls = scheduleCalls + 1
        assert(delay >= 1000 and delay <= 86400000)
        assert(options.name == 'synex_world.door_auto_relock')
        if failNextSchedule then
          failNextSchedule = false
          return nil, { code = 'SCHEDULER_LIMIT' }
        end
        local token = ('schedule_%04d'):format(scheduleCalls)
        callbacks[token], delays[token] = handler, delay
        return token
      end
      function scheduler.cancel(token)
        cancelCalls = cancelCalls + 1
        cancelled[token] = true
        return true
      end
      local ids, changedCalls = 0, 0
      local doors = SynexWorldDoorEngine.create({
        repository = repository,
        resolveDefinition = function(key) return definitions[key] end,
        newId = function() ids = ids + 1; return ('world_%030d'):format(ids) end,
        nowIso = function() return '2026-08-27T12:00:00Z' end,
        scheduler = scheduler,
        onSchedulerError = function(failure)
          schedulerFailures = schedulerFailures + 1
          assert(failure.operation == 'schedule' and failure.code == 'SCHEDULER_LIMIT')
        end,
        onChanged = function() changedCalls = changedCalls + 1 end,
      })

      local opened = assert(doors:setState({ key = 'synex_test:runtime_door',
        state = 'UNLOCKED', expectedVersion = 0, idempotencyKey = 'runtime_open_0001',
        reasonCode = 'door.opened' },
        { caller = 'synex_test', traceId = 'trace_runtime_open_0001' }))
      assert(opened.version == 1 and delays.schedule_0001 == 2000)
      assert(callbacks.schedule_0001() == true)
      local relocked = assert(doors:get({ key = 'synex_test:runtime_door' }))
      assert(relocked.state == 'LOCKED' and relocked.version == 2)

      assert(doors:setState({ key = 'synex_test:runtime_door', state = 'UNLOCKED',
        expectedVersion = 2, idempotencyKey = 'runtime_open_0002',
        reasonCode = 'door.opened' },
        { caller = 'synex_test', traceId = 'trace_runtime_open_0002' }))
      assert(doors:setState({ key = 'synex_test:runtime_door', state = 'LOCKED',
        expectedVersion = 3, idempotencyKey = 'runtime_lock_0001',
        reasonCode = 'door.locked' },
        { caller = 'synex_test', traceId = 'trace_runtime_lock_0001' }))
      assert(cancelled.schedule_0002 == true and callbacks.schedule_0002() == false)
      local fenced = assert(doors:get({ key = 'synex_test:runtime_door' }))
      assert(fenced.state == 'LOCKED' and fenced.version == 4)

      local persistent = assert(doors:setState({ key = 'synex_test:persistent_door',
        state = 'UNLOCKED', expectedVersion = 0, idempotencyKey = 'persist_open_0001',
        reasonCode = 'door.opened' },
        { caller = 'synex_test', traceId = 'trace_persist_open_0001' }))
      local replay = assert(doors:setState({ key = 'synex_test:persistent_door',
        state = 'UNLOCKED', expectedVersion = 0, idempotencyKey = 'persist_open_0001',
        reasonCode = 'door.opened' },
        { caller = 'synex_test', traceId = 'trace_persist_open_0001' }))
      assert(persistent.version == 1 and replay.replayed == true and scheduleCalls == 3)
      assert(callbacks.schedule_0003() == true)
      local durableRelock = assert(doors:get({ key = 'synex_test:persistent_door' }))
      assert(durableRelock.state == 'LOCKED' and durableRelock.version == 2)

      failNextSchedule = true
      local committed = assert(doors:setState({ key = 'synex_test:persistent_door',
        state = 'UNLOCKED', expectedVersion = 2, idempotencyKey = 'persist_open_0002',
        reasonCode = 'door.opened' },
        { caller = 'synex_test', traceId = 'trace_persist_open_0002' }))
      assert(committed.state == 'UNLOCKED' and committed.version == 3)
      assert(schedulerFailures == 1 and changedCalls == 7 and cancelCalls == 1)
      return table.concat({ scheduleCalls, cancelCalls, schedulerFailures,
        committed.state, committed.version, changedCalls }, ':')
    `);
    assert.equal(result, '4:1:1:UNLOCKED:3:7');
  } finally {
    engine.global.close();
  }
});

test('persistent door read-through cache bounds repeated client slice projections', async () => {
  const engine = await runtime();
  try {
    const result = await engine.doString(String.raw`
      local definitions, reads = {}, 0
      for index = 1, 64 do
        local key = ('synex_test:cached_door_%02d'):format(index)
        definitions[key] = { kind = 'door', key = key, revision = 1,
          defaultState = 'LOCKED', persistent = true, leaves = {{ id = 'main' }} }
      end
      local repository = {}
      function repository:getDoorState() reads = reads + 1; return nil end
      function repository:setDoorState(command)
        return { key = command.doorKey, schemaVersion = command.schemaVersion,
          state = command.state, version = command.expectedVersion + 1,
          persistent = true }
      end
      local ids = 0
      local doors = SynexWorldDoorEngine.create({
        repository = repository,
        resolveDefinition = function(key) return definitions[key] end,
        newId = function() ids = ids + 1; return ('world_%030d'):format(ids) end,
        nowIso = function() return '2026-08-27T12:00:00Z' end,
        scheduler = { after = function() error('not expected') end,
          cancel = function() return true end },
      })
      for pass = 1, 3 do
        for index = 1, 64 do
          assert(doors:get({ key = ('synex_test:cached_door_%02d'):format(index) }))
        end
      end
      assert(reads == 64, 'repeated projections caused ' .. reads .. ' database reads')
      local first = 'synex_test:cached_door_01'
      assert(doors:setState({ key = first, state = 'DISABLED', expectedVersion = 0,
        idempotencyKey = 'cached_door_write_0001', reasonCode = 'world.test' },
        { caller = 'synex_test', traceId = 'trace_cached_door_0001' }))
      assert(doors:get({ key = first }).state == 'DISABLED' and reads == 64)
      assert(doors:purgeRuntime(first))
      assert(doors:get({ key = first }).state == 'LOCKED' and reads == 65)
      return reads
    `);
    assert.equal(result, 65);
  } finally {
    engine.global.close();
  }
});

test('persistent door idempotency replay cannot regress a newer cached version', async () => {
  const engine = await runtime();
  try {
    const result = await engine.doString(String.raw`
      local definition = { kind = 'door', key = 'synex_test:replay_door', revision = 1,
        defaultState = 'LOCKED', persistent = true, leaves = {{ id = 'main' }} }
      local receipts, reads = {}, 0
      local repository = {}
      function repository:getDoorState() reads = reads + 1; return nil end
      function repository:setDoorState(command)
        local replay = receipts[command.idempotencyKey]
        if replay then
          replay = SynexWorldValidation.copy(replay)
          replay.replayed = true
          return replay
        end
        local record = { key = command.doorKey, schemaVersion = command.schemaVersion,
          state = command.state, version = command.expectedVersion + 1,
          persistent = true, replayed = false }
        receipts[command.idempotencyKey] = SynexWorldValidation.copy(record)
        return record
      end
      local ids = 0
      local doors = SynexWorldDoorEngine.create({
        repository = repository, resolveDefinition = function() return definition end,
        newId = function() ids = ids + 1; return ('world_%030d'):format(ids) end,
        nowIso = function() return '2026-08-27T12:00:00Z' end,
        scheduler = { after = function() error('not expected') end,
          cancel = function() return true end },
      })
      local first = assert(doors:setState({ key = definition.key, state = 'UNLOCKED', expectedVersion = 0,
        idempotencyKey = 'door_replay_cache_0001', reasonCode = 'world.test' },
        { caller = 'synex_test', traceId = 'trace_door_replay_0001' }))
      assert(first.version == 1)
      local second = assert(doors:setState({ key = definition.key, state = 'LOCKED', expectedVersion = 1,
        idempotencyKey = 'door_replay_cache_0002', reasonCode = 'world.test' },
        { caller = 'synex_test', traceId = 'trace_door_replay_0002' }))
      assert(second.version == 2)
      local replay = assert(doors:setState({ key = definition.key, state = 'UNLOCKED',
        expectedVersion = 0, idempotencyKey = 'door_replay_cache_0001',
        reasonCode = 'world.test' },
        { caller = 'synex_test', traceId = 'trace_door_replay_0003' }))
      assert(replay.version == 1 and replay.replayed == true)
      local current = assert(doors:get({ key = definition.key }))
      assert(current.version == 2 and current.state == 'LOCKED' and reads == 0)
      return replay.version .. ':' .. current.version .. ':' .. current.state
    `);
    assert.equal(result, '1:2:LOCKED');
  } finally {
    engine.global.close();
  }
});
