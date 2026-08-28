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
  await load(engine, 'resources/synex_world/server/state_engine.lua');
  await engine.doString(String.raw`
    function WorldTestEncode(value)
      local kind = type(value)
      if kind == 'nil' then return 'null' end
      if kind == 'boolean' then return value and 'true' or 'false' end
      if kind == 'number' then return tostring(value) end
      if kind == 'string' then return '"' .. value:gsub('\\', '\\\\'):gsub('"', '\\"') .. '"' end
      if kind ~= 'table' then error('unsupported JSON value') end
      local containerKind = SynexWorldValidation.jsonContainerKind(value)
      local isArray, maximum, count = true, 0, 0
      for key in pairs(value) do
        count = count + 1
        if type(key) ~= 'number' then isArray = false else maximum = math.max(maximum, key) end
      end
      if containerKind == 'array' and count == 0
        or isArray and maximum == count and count > 0 then
        local result = {}
        for index = 1, count do result[index] = WorldTestEncode(value[index]) end
        return '[' .. table.concat(result, ',') .. ']'
      end
      local keys = {}
      for key in pairs(value) do keys[#keys + 1] = key end
      table.sort(keys)
      local result = {}
      for index, key in ipairs(keys) do
        result[index] = WorldTestEncode(key) .. ':' .. WorldTestEncode(value[key])
      end
      return '{' .. table.concat(result, ',') .. '}'
    end
  `);
  return engine;
}

test('runtime World state enforces schemas, provenance, and optimistic concurrency', async () => {
  const engine = await runtime();
  try {
    const result = await engine.doString(String.raw`
      local definitions = {
        ['synex_test:power'] = {
          kind = 'world_state_definition', key = 'synex_test:power', revision = 7,
          stateType = 'boolean', scope = 'global', persistence = 'runtime',
          schemaVersion = 1, default = false
        },
        ['synex_test:temperature'] = {
          kind = 'world_state_definition', key = 'synex_test:temperature', revision = 7,
          stateType = 'integer', scope = 'location', persistence = 'runtime',
          schemaVersion = 2, minimum = -20, maximum = 80, default = 20
        },
        ['synex_test:mode'] = {
          kind = 'world_state_definition', key = 'synex_test:mode', revision = 7,
          stateType = 'enum', scope = 'global', persistence = 'runtime', schemaVersion = 1,
          allowed = {'active', 'inactive'}, default = 'inactive'
        },
        ['synex_test:label'] = {
          kind = 'world_state_definition', key = 'synex_test:label', revision = 7,
          stateType = 'string', scope = 'global', persistence = 'runtime',
          schemaVersion = 1, maxLength = 32, default = 'safe'
        },
        ['synex_test:small'] = {
          kind = 'world_state_definition', key = 'synex_test:small', revision = 7,
          stateType = 'structured', scope = 'global', persistence = 'runtime', schemaVersion = 1,
          structuredSchema = { type = 'object', maximumBytes = 128,
            maximumDepth = 3, maximumEntries = 8,
            properties = {
              enabled = { type = 'boolean' },
              count = { type = 'integer', minimum = 0, maximum = 10 },
              label = { type = 'string', maxLength = 8 },
              mode = { type = 'enum', allowed = { 'active', 'idle' } },
              flags = { type = 'array', maximumItems = 2,
                items = { type = 'boolean' } },
            }, required = { 'enabled', 'count' }, additionalProperties = false },
          default = { enabled = false, count = 0 }
        }
      }
      local ids = 0
      local repository = {
        getState = function() error('runtime state must not read the database') end,
        setState = function() error('runtime state must not write the database') end
      }
      local state = SynexWorldStateEngine.create({
        repository = repository,
        resolveDefinition = function(key) return definitions[key] end,
        jsonEncode = WorldTestEncode,
        newId = function() ids = ids + 1; return ('world_%030d'):format(ids) end,
        nowIso = function() return '2026-08-27T12:00:00Z' end
      })
      local initial = assert(state:get({ key = 'synex_test:power' }))
      assert(initial.value == false and initial.version == 0 and initial.defaulted == true)
      local changed = assert(state:set({
        key = 'synex_test:power', value = true, expectedVersion = 0,
        idempotencyKey = 'state_runtime_0001', reasonCode = 'world.test'
      }, { caller = 'synex_test', traceId = 'trace_state_0001' }))
      assert(changed.value == true and changed.version == 1 and changed.persistent == false)
      assert(changed.provenance.actor.type == 'resource'
        and changed.provenance.actor.ref == 'synex_test')
      local stale, staleError = state:set({
        key = 'synex_test:power', value = false, expectedVersion = 0,
        idempotencyKey = 'state_runtime_0002', reasonCode = 'world.test'
      }, { caller = 'synex_test', traceId = 'trace_state_0002' })
      assert(stale == nil and staleError.code == 'CONCURRENT_MODIFICATION')

      local decimal, decimalError = state:set({
        key = 'synex_test:temperature', scopeRef = 'synex_test:mrpd', value = 1.5,
        expectedVersion = 0, idempotencyKey = 'state_runtime_0003', reasonCode = 'world.test'
      }, { caller = 'synex_test', traceId = 'trace_state_0003' })
      assert(decimal == nil and decimalError.code == 'WORLD_STATE_VALUE_INVALID')
      local enum, enumError = state:set({
        key = 'synex_test:mode', value = 'unknown', expectedVersion = 0,
        idempotencyKey = 'state_runtime_0004', reasonCode = 'world.test'
      }, { caller = 'synex_test', traceId = 'trace_state_0004' })
      assert(enum == nil and enumError.code == 'WORLD_STATE_VALUE_INVALID')
      local c0, c0Error = state:set({
        key = 'synex_test:label', value = 'bad' .. string.char(1), expectedVersion = 0,
        idempotencyKey = 'state_runtime_c0_01', reasonCode = 'world.test'
      }, { caller = 'synex_test', traceId = 'trace_state_c0_001' })
      assert(c0 == nil and c0Error.code == 'WORLD_STATE_VALUE_INVALID')
      local del, delError = state:set({
        key = 'synex_test:label', value = 'bad' .. string.char(127), expectedVersion = 0,
        idempotencyKey = 'state_runtime_del_1', reasonCode = 'world.test'
      }, { caller = 'synex_test', traceId = 'trace_state_del_01' })
      assert(del == nil and delError.code == 'WORLD_STATE_VALUE_INVALID')
      local structured = assert(state:set({
        key = 'synex_test:small', value = { enabled = true, count = 2 }, expectedVersion = 0,
        idempotencyKey = 'state_runtime_0005', reasonCode = 'world.test'
      }, { caller = 'synex_test', traceId = 'trace_state_0005' }))
      assert(structured.value.enabled == true and structured.value.count == 2)
      local oversized, oversizedError = state:set({
        key = 'synex_test:small', value = { a = 1, b = 2, c = 3, d = 4, e = 5 },
        expectedVersion = 1, idempotencyKey = 'state_runtime_0006', reasonCode = 'world.test'
      }, { caller = 'synex_test', traceId = 'trace_state_0006' })
      assert(oversized == nil and oversizedError.code == 'WORLD_STATE_VALUE_INVALID')
      local missing, missingError = state:set({
        key = 'synex_test:small', value = { enabled = true }, expectedVersion = 1,
        idempotencyKey = 'state_runtime_0008', reasonCode = 'world.test'
      }, { caller = 'synex_test', traceId = 'trace_state_0008' })
      assert(missing == nil and missingError.code == 'WORLD_STATE_VALUE_INVALID')
      local wrong, wrongError = state:set({
        key = 'synex_test:small', value = { enabled = true, count = 2,
          flags = { true, false, true } }, expectedVersion = 1,
        idempotencyKey = 'state_runtime_0009', reasonCode = 'world.test'
      }, { caller = 'synex_test', traceId = 'trace_state_0009' })
      assert(wrong == nil and wrongError.code == 'WORLD_STATE_VALUE_INVALID')
      local spoofed, spoofedError = state:set({
        key = 'synex_test:power', value = false, expectedVersion = 1,
        idempotencyKey = 'state_runtime_0007', reasonCode = 'world.test'
      }, { caller = 'synex_test', traceId = 'trace_state_0007',
        actor = { type = 'resource', ref = 'synex_other' } })
      assert(spoofed == nil and spoofedError.code == 'INVALID_ARGUMENT')
      local purged = assert(state:purgeRuntime('synex_test:power'))
      assert(purged.removed == 1 and purged.persistentPreserved == true)
      return table.concat({ changed.version, staleError.code, decimalError.code,
        enumError.code, oversizedError.code, spoofedError.code, purged.removed }, ':')
    `);
    assert.equal(result,
      '1:CONCURRENT_MODIFICATION:WORLD_STATE_VALUE_INVALID:WORLD_STATE_VALUE_INVALID:'
      + 'WORLD_STATE_VALUE_INVALID:INVALID_ARGUMENT:1');
  } finally {
    engine.global.close();
  }
});

test('persistent World state is resolved by definition and rejects stored schema drift', async () => {
  const engine = await runtime();
  try {
    const result = await engine.doString(String.raw`
      local stored
      local captured
      local persistenceCalls, changedCalls = 0, 0
      local definition = {
        kind = 'world_state_definition', key = 'synex_test:alarm', revision = 11,
        stateType = 'enum', scope = 'location', persistence = 'persistent', schemaVersion = 3,
        allowed = {'active', 'inactive'}, default = 'inactive'
      }
      local repository = {}
      function repository:getState() return stored end
      function repository:setState(command)
        persistenceCalls = persistenceCalls + 1
        captured = command
        return {
          key = command.stateKey, scope = { type = command.scopeType, ref = command.scopeRef },
          schemaVersion = command.schemaVersion, valueType = command.valueType,
          value = command.value, version = command.expectedVersion + 1,
          persistent = true, replayed = persistenceCalls > 1,
          provenance = { actor = { type = command.provenance.actorType,
            ref = command.provenance.actorRef } }
        }
      end
      local state = SynexWorldStateEngine.create({
        repository = repository,
        resolveDefinition = function() return definition end,
        jsonEncode = WorldTestEncode,
        newId = function() return 'world_000000000000000000000000000001' end,
        nowIso = function() return '2026-08-27T12:00:00Z' end,
        onChanged = function() changedCalls = changedCalls + 1 end
      })
      local default = assert(state:get({ key = definition.key, scopeRef = 'synex_test:mrpd' }))
      assert(default.version == 0 and default.value == 'inactive' and default.persistent == true)
      local changed = assert(state:set({
        key = definition.key, scopeRef = 'synex_test:mrpd', value = 'active',
        expectedVersion = 0, idempotencyKey = 'state_persist_0001', reasonCode = 'alarm.enabled'
      }, { caller = 'synex_test', traceId = 'trace_state_0010',
        actor = { type = 'character', ref = 'character:42' } }))
      assert(changed.definitionRevision == 11 and captured.schemaVersion == 3)
      assert(captured.provenance.sourceResource == 'synex_test'
        and captured.provenance.actorType == 'character')
      local replay = assert(state:set({
        key = definition.key, scopeRef = 'synex_test:mrpd', value = 'active',
        expectedVersion = 0, idempotencyKey = 'state_persist_0001', reasonCode = 'alarm.enabled'
      }, { caller = 'synex_test', traceId = 'trace_state_0010',
        actor = { type = 'character', ref = 'character:42' } }))
      assert(replay.replayed == true and changedCalls == 1)
      stored = {
        key = definition.key, scope = { type = 'location', ref = 'synex_test:mrpd' },
        schemaVersion = 2, valueType = 'enum', value = 'active', version = 4,
        persistent = true
      }
      assert(state:purgeRuntime(definition.key))
      local drifted, driftError = state:get({ key = definition.key,
        scopeRef = 'synex_test:mrpd' })
      assert(drifted == nil and driftError.code == 'STATE_SCHEMA_MISMATCH')
      return changed.value .. ':' .. captured.provenance.actorType .. ':'
        .. driftError.code .. ':' .. changedCalls
    `);
    assert.equal(result, 'active:character:STATE_SCHEMA_MISMATCH:1');
  } finally {
    engine.global.close();
  }
});

test('persistent World state restores into a fresh engine and preserves OCC continuity', async () => {
  const engine = await runtime();
  try {
    const result = await engine.doString(String.raw`
      local definition = {
        kind = 'world_state_definition', key = 'synex_test:restart_alarm', revision = 7,
        stateType = 'boolean', scope = 'location', persistence = 'persistent',
        schemaVersion = 3, default = false,
      }
      local stored, reads, writes, ids = nil, 0, 0, 0
      local repository = {}
      function repository:getState(key, scopeType, scopeRef)
        reads = reads + 1
        assert(key == definition.key and scopeType == 'location'
          and scopeRef == 'synex_test:mrpd')
        return stored and SynexWorldValidation.copy(stored) or nil
      end
      function repository:setState(command)
        local currentVersion = stored and stored.version or 0
        assert(command.expectedVersion == currentVersion)
        writes = writes + 1
        stored = {
          key = command.stateKey,
          scope = { type = command.scopeType, ref = command.scopeRef },
          schemaVersion = command.schemaVersion, valueType = command.valueType,
          value = command.value, version = currentVersion + 1,
          persistent = true, defaulted = false,
        }
        return SynexWorldValidation.copy(stored)
      end
      local function createEngine()
        return SynexWorldStateEngine.create({
          repository = repository,
          resolveDefinition = function(key)
            if key == definition.key then return definition end
          end,
          jsonEncode = WorldTestEncode,
          newId = function()
            ids = ids + 1
            return ('world_%030d'):format(ids)
          end,
          nowIso = function() return '2026-08-27T12:00:00Z' end,
        })
      end

      local beforeRestart = createEngine()
      local activated = assert(beforeRestart:set({
        key = definition.key, scopeRef = 'synex_test:mrpd', value = true,
        expectedVersion = 0, idempotencyKey = 'state_restart_0001',
        reasonCode = 'alarm.enabled',
      }, { caller = 'synex_test', traceId = 'trace_state_restart_0001' }))
      assert(activated.value == true and activated.version == 1)

      local afterRestart = createEngine()
      local restored = assert(afterRestart:get({
        key = definition.key, scopeRef = 'synex_test:mrpd',
      }))
      assert(restored.key == definition.key and restored.scope.type == 'location')
      assert(restored.scope.ref == 'synex_test:mrpd' and restored.value == true)
      assert(restored.valueType == 'boolean' and restored.schemaVersion == 3)
      assert(restored.version == 1 and restored.definitionRevision == 7)
      assert(restored.persistent == true and restored.defaulted ~= true and reads == 1)

      local cleared = assert(afterRestart:set({
        key = definition.key, scopeRef = 'synex_test:mrpd', value = false,
        expectedVersion = 1, idempotencyKey = 'state_restart_0002',
        reasonCode = 'alarm.cleared',
      }, { caller = 'synex_test', traceId = 'trace_state_restart_0002' }))
      assert(cleared.value == false and cleared.version == 2)
      assert(afterRestart:get({ key = definition.key,
        scopeRef = 'synex_test:mrpd' }).version == 2 and reads == 1)
      return table.concat({ tostring(restored.value), restored.version,
        tostring(cleared.value), cleared.version, reads, writes }, ':')
    `);
    assert.equal(result, 'true:1:false:2:1:2');
  } finally {
    engine.global.close();
  }
});

test('Cfx empty object and array kinds survive database validation, persistence, and replay', async () => {
  const engine = await runtime(true);
  try {
    const result = await engine.doString(String.raw`
      local objectKey, arrayKey = 'synex_test:empty_object', 'synex_test:empty_array'
      local encodedValues, receipts, ids = {}, {}, 0
      local rows = {
        [objectKey] = '{}', [arrayKey] = '[]',
      }
      local function row(key)
        return { state_key = key, scope_type = 'global', scope_ref = 'global',
          schema_version = 1, value_type = 'structured', value_json = rows[key], version = 1,
          updated_by_type = 'resource', updated_by_ref = 'synex_test',
          source_resource = 'synex_test', reason_code = 'world.seed',
          trace_id = 'trace_empty_seed_0001', updated_at = '2026-08-27T12:00:00Z' }
      end
      local database = {}
      function database:read(_, parameters) return { row(parameters[1]) } end
      function database:transaction(request, handler)
        local identity = request.operation .. ':' .. request.idempotencyKey
        if receipts[identity] then
          return SynexWorldValidation.copy(receipts[identity]), nil, { replayed = true }
        end
        local tx = {}
        function tx.affected(sql, parameters)
          if sql:find('synex_world_state', 1, true) then
            encodedValues[request.idempotencyKey] = parameters[3]
          end
          return 1
        end
        function tx.one() return nil end
        local value, operationError = handler(tx)
        assert(value and operationError == nil)
        receipts[identity] = SynexWorldValidation.copy(value)
        return value, nil, { replayed = false }
      end
      local decoder = SynexWorldValidation.createJsonDecoder({
        decode = function(encoded, _, _, objectMeta, arrayMeta)
          if encoded == '{}' then return setmetatable({}, objectMeta) end
          if encoded == '[]' then return setmetatable({}, arrayMeta) end
          error('unexpected JSON')
        end,
      })
      local repository = SynexWorldRepository.create({ database = database,
        jsonEncode = WorldTestEncode, jsonDecode = decoder })
      local definitions = {
        [objectKey] = { kind = 'world_state_definition', key = objectKey, revision = 1,
          stateType = 'structured', scope = 'global', persistence = 'persistent',
          schemaVersion = 1, structuredSchema = { type = 'object', maximumBytes = 64,
            maximumDepth = 2, maximumEntries = 2, properties = {}, required = {},
            additionalProperties = false } },
        [arrayKey] = { kind = 'world_state_definition', key = arrayKey, revision = 1,
          stateType = 'structured', scope = 'global', persistence = 'persistent',
          schemaVersion = 1, structuredSchema = { type = 'array', maximumBytes = 64,
            maximumDepth = 2, maximumEntries = 2, maximumItems = 2,
            items = { type = 'boolean' } } },
      }
      local state = SynexWorldStateEngine.create({ repository = repository,
        resolveDefinition = function(key) return definitions[key] end,
        jsonEncode = WorldTestEncode,
        newId = function() ids = ids + 1; return ('world_%030d'):format(ids) end,
        nowIso = function() return '2026-08-27T12:00:00Z' end })
      local object = assert(state:get({ key = objectKey }))
      local array = assert(state:get({ key = arrayKey }))
      assert(SynexWorldValidation.jsonContainerKind(object.value) == 'object'
        and SynexWorldValidation.jsonContainerKind(array.value) == 'array')
      local function persist(key, value, idempotencyKey)
        local request = { key = key, value = value, expectedVersion = 1,
          idempotencyKey = idempotencyKey, reasonCode = 'world.empty_kind' }
        local context = { caller = 'synex_test', traceId = 'trace_empty_kind_0001' }
        local changed = assert(state:set(request, context))
        local replay = assert(state:set(request, context))
        assert(changed.replayed == false and replay.replayed == true)
      end
      persist(objectKey, object.value, 'empty_object_0001')
      persist(arrayKey, array.value, 'empty_array_0001')
      assert(encodedValues.empty_object_0001 == '{}'
        and encodedValues.empty_array_0001 == '[]')

      local hostile = SynexWorldRepository.create({ database = database,
        jsonEncode = WorldTestEncode,
        jsonDecode = function() return setmetatable({}, { __jsontype = 'object' }) end })
      local hostileValue, hostileError = hostile:getState(objectKey, 'global', 'global')
      assert(hostileValue == nil and hostileError.code == 'DATABASE_RESULT_INVALID')
      return encodedValues.empty_object_0001 .. ':' .. encodedValues.empty_array_0001
    `);
    assert.equal(result, '{}:[]');
  } finally {
    engine.global.close();
  }
});

test('instance-scoped state cleanup removes bounded runtime and persistent values', async () => {
  const engine = await runtime();
  try {
    const result = await engine.doString(String.raw`
      local definitions = {
        ['synex_test:instance_mode'] = {
          kind = 'world_state_definition', key = 'synex_test:instance_mode', revision = 1,
          stateType = 'enum', scope = 'instance', persistence = 'runtime', schemaVersion = 1,
          allowed = {'active', 'inactive'}, default = 'inactive'
        }
      }
      local purgedType, purgedRef
      local repository = {
        getState = function() error('runtime state must not read persistence') end,
        setState = function() error('runtime state must not write persistence') end,
        purgeStateScope = function(_, scopeType, scopeRef)
          purgedType, purgedRef = scopeType, scopeRef
          return { removed = 2 }
        end,
      }
      local state = SynexWorldStateEngine.create({
        repository = repository,
        resolveDefinition = function(key) return definitions[key] end,
        resolveScope = function() return true end,
        jsonEncode = WorldTestEncode,
        newId = function() return 'world_000000000000000000000000000003' end,
        nowIso = function() return '2026-08-27T12:00:00Z' end,
      })
      local instanceId = 'world_instance_00000001'
      assert(state:set({
        key = 'synex_test:instance_mode', scopeRef = instanceId, value = 'active',
        expectedVersion = 0, idempotencyKey = 'instance_state_0001',
        reasonCode = 'world.test',
      }, { caller = 'synex_test', traceId = 'trace_state_0030' }))
      local cleanup = assert(state:purgeScope('instance', instanceId))
      assert(cleanup.runtimeRemoved == 1 and cleanup.persistentRemoved == 2)
      assert(purgedType == 'instance' and purgedRef == instanceId)
      local default = assert(state:get({ key = 'synex_test:instance_mode', scopeRef = instanceId }))
      assert(default.defaulted == true and default.value == 'inactive')
      return cleanup.runtimeRemoved .. ':' .. cleanup.persistentRemoved
    `);
    assert.equal(result, '1:2');
  } finally {
    engine.global.close();
  }
});

test('persistent World state read-through cache bounds repeated slice-style reads', async () => {
  const engine = await runtime();
  try {
    const result = await engine.doString(String.raw`
      local definitions, reads = {}, 0
      for index = 1, 64 do
        local key = ('synex_test:cached_state_%02d'):format(index)
        definitions[key] = { kind = 'world_state_definition', key = key, revision = 1,
          stateType = 'boolean', scope = 'global', persistence = 'persistent',
          schemaVersion = 1, default = false }
      end
      local repository = {}
      function repository:getState() reads = reads + 1; return nil end
      function repository:setState(command)
        return { key = command.stateKey,
          scope = { type = command.scopeType, ref = command.scopeRef },
          schemaVersion = command.schemaVersion, valueType = command.valueType,
          value = command.value, version = command.expectedVersion + 1,
          persistent = true }
      end
      local ids = 0
      local state = SynexWorldStateEngine.create({
        repository = repository,
        resolveDefinition = function(key) return definitions[key] end,
        jsonEncode = WorldTestEncode,
        newId = function() ids = ids + 1; return ('world_%030d'):format(ids) end,
        nowIso = function() return '2026-08-27T12:00:00Z' end,
      })
      for pass = 1, 3 do
        for index = 1, 64 do
          assert(state:get({ key = ('synex_test:cached_state_%02d'):format(index) }))
        end
      end
      assert(reads == 64, 'repeated projections caused ' .. reads .. ' database reads')
      local first = 'synex_test:cached_state_01'
      assert(state:set({ key = first, value = true, expectedVersion = 0,
        idempotencyKey = 'cached_state_write_0001', reasonCode = 'world.test' },
        { caller = 'synex_test', traceId = 'trace_cached_state_0001' }))
      assert(state:get({ key = first }).value == true and reads == 64)
      assert(state:purgeRuntime(first))
      assert(state:get({ key = first }).value == false and reads == 65)
      return reads
    `);
    assert.equal(result, 65);
  } finally {
    engine.global.close();
  }
});

test('persistent state idempotency replay cannot regress a newer cached version', async () => {
  const engine = await runtime();
  try {
    const result = await engine.doString(String.raw`
      local definition = { kind = 'world_state_definition', key = 'synex_test:replay_state',
        revision = 1, stateType = 'boolean', scope = 'global',
        persistence = 'persistent', schemaVersion = 1, default = false }
      local receipts, reads = {}, 0
      local repository = {}
      function repository:getState() reads = reads + 1; return nil end
      function repository:setState(command)
        local replay = receipts[command.idempotencyKey]
        if replay then
          replay = SynexWorldValidation.copy(replay)
          replay.replayed = true
          return replay
        end
        local record = { key = command.stateKey,
          scope = { type = command.scopeType, ref = command.scopeRef },
          schemaVersion = command.schemaVersion, valueType = command.valueType,
          value = command.value, version = command.expectedVersion + 1,
          persistent = true, replayed = false }
        receipts[command.idempotencyKey] = SynexWorldValidation.copy(record)
        return record
      end
      local ids = 0
      local state = SynexWorldStateEngine.create({
        repository = repository, resolveDefinition = function() return definition end,
        jsonEncode = WorldTestEncode,
        newId = function() ids = ids + 1; return ('world_%030d'):format(ids) end,
        nowIso = function() return '2026-08-27T12:00:00Z' end,
      })
      local first = assert(state:set({ key = definition.key, value = true, expectedVersion = 0,
        idempotencyKey = 'state_replay_cache_0001', reasonCode = 'world.test' },
        { caller = 'synex_test', traceId = 'trace_state_replay_0001' }))
      assert(first.version == 1)
      local second = assert(state:set({ key = definition.key, value = false, expectedVersion = 1,
        idempotencyKey = 'state_replay_cache_0002', reasonCode = 'world.test' },
        { caller = 'synex_test', traceId = 'trace_state_replay_0002' }))
      assert(second.version == 2)
      local replay = assert(state:set({ key = definition.key, value = true, expectedVersion = 0,
        idempotencyKey = 'state_replay_cache_0001', reasonCode = 'world.test' },
        { caller = 'synex_test', traceId = 'trace_state_replay_0003' }))
      assert(replay.version == 1 and replay.replayed == true)
      local current = assert(state:get({ key = definition.key }))
      assert(current.version == 2 and current.value == false and reads == 0)
      return replay.version .. ':' .. current.version .. ':' .. tostring(current.value)
    `);
    assert.equal(result, '1:2:false');
  } finally {
    engine.global.close();
  }
});

test('repository writes state and its outbox event in one fenced World transaction', async () => {
  const engine = await runtime(true);
  try {
    const result = await engine.doString(String.raw`
      local statements, commits, rollbacks, receipt = {}, 0, 0, nil
      local database = {}
      function database:read() return {} end
      local cleanupSql, cleanupParameters
      function database:write(sql, parameters)
        cleanupSql, cleanupParameters = sql, parameters
        return { affectedRows = 2 }
      end
      function database:transaction(request, handler)
        if receipt then return SynexWorldValidation.copy(receipt), nil, { replayed = true } end
        local tx = {}
        function tx.affected(sql)
          statements[#statements + 1] = sql
          if sql:find('synex_world_state', 1, true) then return 1 end
          if sql:find('synex_world_outbox', 1, true) then return 1 end
          error('cross-domain SQL')
        end
        function tx.one() return nil end
        local called, value, operationError = pcall(handler, tx)
        if not called then rollbacks = rollbacks + 1; return nil, value end
        commits = commits + 1
        receipt = SynexWorldValidation.copy(value)
        return value, operationError, { replayed = false }
      end
      local repository = SynexWorldRepository.create({
        database = database, jsonEncode = WorldTestEncode,
        jsonDecode = function() error('decode not expected') end
      })
      local command = {
        stateKey = 'synex_test:power', scopeType = 'global', scopeRef = 'global',
        schemaVersion = 1, valueType = 'boolean', value = true, expectedVersion = 0,
        idempotencyKey = 'state_atomic_0001', eventId = 'world_000000000000000000000000000001',
        provenance = { actorType = 'resource', actorRef = 'synex_test',
          sourceResource = 'synex_test', reasonCode = 'world.test',
          traceId = 'trace_state_0020', timestamp = '2026-08-27T12:00:00Z' }
      }
      local changed = assert(repository:setState(command))
      assert(changed.version == 1 and changed.eventId ~= nil and commits == 1 and rollbacks == 0)
      assert(#statements == 2 and statements[1]:find('synex_world_state', 1, true)
        and statements[2]:find('synex_world_outbox', 1, true))
      for _, sql in ipairs(statements) do
        for tableName in sql:gmatch('(synex_[a-z0-9_]+)') do
          assert(tableName == 'synex_world_state' or tableName == 'synex_world_outbox')
        end
      end
      local originalEventId = changed.eventId
      command.eventId = 'world_000000000000000000000000000002'
      local replay = assert(repository:setState(command))
      assert(replay.replayed == true and replay.eventId == originalEventId and #statements == 2)
      local cleanup = assert(repository:purgeStateScope('instance', 'world_instance_00000001'))
      assert(cleanup.removed == 2 and cleanup.scope.type == 'instance')
      assert(cleanupSql:find('DELETE FROM', 1, true)
        and cleanupSql:find('synex_world_state', 1, true))
      assert(cleanupParameters[1] == 'instance'
        and cleanupParameters[2] == 'world_instance_00000001')
      return table.concat({ #statements, commits, changed.version,
        changed.persistent and 1 or 0, replay.replayed and 1 or 0, cleanup.removed }, ':')
    `);
    assert.equal(result, '2:1:1:1:1:2');
  } finally {
    engine.global.close();
  }
});

test('persistent World receipts use collision-free external-caller transaction namespaces', async () => {
  const engine = await runtime(true);
  try {
    const result = await engine.doString(String.raw`
      local receipts, operations, executions = {}, {}, 0
      local database = {}
      function database:read() return {} end
      function database:write() return { affectedRows = 0 } end
      function database:transaction(request, handler)
        operations[#operations + 1] = request.operation
        local namespace = request.operation .. ':' .. request.idempotencyKey
        local fingerprint = WorldTestEncode(request.request)
        local receipt = receipts[namespace]
        if receipt then
          if receipt.fingerprint ~= fingerprint then
            return nil, { code = 'IDEMPOTENCY_CONFLICT', retryable = false }
          end
          return SynexWorldValidation.copy(receipt.value), nil, { replayed = true }
        end
        executions = executions + 1
        local tx = {
          affected = function() return 1 end,
          one = function() return nil end,
        }
        local called, value, operationError = pcall(handler, tx)
        if not called then return nil, value end
        receipts[namespace] = {
          fingerprint = fingerprint, value = SynexWorldValidation.copy(value),
        }
        return value, operationError, { replayed = false }
      end
      local repository = SynexWorldRepository.create({
        database = database, jsonEncode = WorldTestEncode,
        jsonDecode = function() error('decode not expected') end,
      })
      local function command(caller, value, eventId)
        return {
          stateKey = 'synex_test:power', scopeType = 'global', scopeRef = 'global',
          schemaVersion = 1, valueType = 'boolean', value = value, expectedVersion = 0,
          idempotencyKey = 'shared-caller-key-0001', eventId = eventId,
          provenance = { actorType = 'resource', actorRef = caller,
            sourceResource = caller, reasonCode = 'world.test',
            traceId = 'trace_state_caller_01', timestamp = '2026-08-27T12:00:00Z' },
        }
      end
      local first = assert(repository:setState(command('synex_alpha', true,
        'world_000000000000000000000000000001')))
      local replay = assert(repository:setState(command('synex_alpha', true,
        'world_000000000000000000000000000002')))
      assert(first.provenance.sourceResource == 'synex_alpha' and replay.replayed == true
        and replay.eventId == first.eventId and executions == 1)
      local foreign = assert(repository:setState(command('synex_beta', true,
        'world_000000000000000000000000000003')))
      assert(foreign.provenance.sourceResource == 'synex_beta' and executions == 2
        and operations[1] ~= operations[3])
      local conflict, conflictError = repository:setState(command('synex_alpha', false,
        'world_000000000000000000000000000004'))
      assert(conflict == nil and conflictError.code == 'IDEMPOTENCY_CONFLICT'
        and executions == 2)
      local longCaller = 'synex_' .. string.rep('a', 27) .. '__' .. string.rep('b', 29)
      assert(#longCaller == 64)
      assert(repository:setState(command(longCaller, true,
        'world_000000000000000000000000000005')))
      assert(#operations[5] <= 64 and operations[5]:match('^ws%.[a-z0-9]+$') ~= nil
        and operations[1]:match('^ws%.[a-z0-9]+$') ~= nil)

      local function doorCommand(caller, eventId)
        return {
          doorKey = 'synex_test:front_door', schemaVersion = 1, state = 'LOCKED',
          expectedVersion = 0, idempotencyKey = 'shared-door-key-000001', eventId = eventId,
          provenance = { actorType = 'resource', actorRef = caller,
            sourceResource = caller, reasonCode = 'door.test',
            traceId = 'trace_door_caller_001', timestamp = '2026-08-27T12:00:00Z' },
        }
      end
      local firstDoor = assert(repository:setDoorState(doorCommand('synex_alpha',
        'world_000000000000000000000000000006')))
      local replayDoor = assert(repository:setDoorState(doorCommand('synex_alpha',
        'world_000000000000000000000000000007')))
      local foreignDoor = assert(repository:setDoorState(doorCommand('synex_beta',
        'world_000000000000000000000000000008')))
      assert(firstDoor.provenance.sourceResource == 'synex_alpha'
        and replayDoor.replayed == true
        and foreignDoor.provenance.sourceResource == 'synex_beta'
        and operations[6]:match('^wd%.[a-z0-9]+$') ~= nil
        and operations[6] == operations[7] and operations[6] ~= operations[8])
      return table.concat({ executions, replay.replayed and 1 or 0,
        replayDoor.replayed and 1 or 0, conflictError.code, #operations[5] }, ':')
    `) as string;
    assert.match(result, /^5:1:1:IDEMPOTENCY_CONFLICT:[1-6][0-9]$/u);
  } finally {
    engine.global.close();
  }
});
