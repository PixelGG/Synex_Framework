import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';

const root = process.cwd();

async function loadCore(engine: Awaited<ReturnType<LuaFactory['createEngine']>>): Promise<void> {
  for (const relativePath of [
    'core/synex_core/server/factories.lua',
    'core/synex_core/server/platform.lua',
    'core/synex_core/server/foundation.lua',
    'core/synex_core/server/reliability.lua',
  ]) {
    await engine.doString(await readFile(path.join(root, relativePath), 'utf8'));
  }
}

test('platform stabilizes constructor-less Cfx decoder metadata across decode calls', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await loadCore(engine);
    const result = await engine.doString(`
      json = {
        decode = function(value, position, nullValue, objectMeta, arrayMeta)
          assert(value == 'fixture-context')
          assert(position == nil or position == 1)
          assert(nullValue == nil)
          objectMeta = objectMeta or { __jsontype = 'object' }
          arrayMeta = arrayMeta or { __jsontype = 'array' }
          return setmetatable({
            emptyObject = setmetatable({}, objectMeta),
            emptyArray = setmetatable({}, arrayMeta),
            nodes = setmetatable({
              setmetatable({ id = 'node-a' }, objectMeta)
            }, arrayMeta)
          }, objectMeta)
        end,
        encode = function(value)
          assert(type(value) == 'table' and next(value) == nil)
          local metatable = debug.getmetatable(value)
          if rawget(metatable, '__jsontype') == 'object' then return '{}' end
          if rawget(metatable, '__jsontype') == 'array' then return '[]' end
          error('fixture received an untagged empty table')
        end
      }
      assert(json.object == nil and json.array == nil)

      local bareFirst = json.decode('fixture-context')
      local bareSecond = json.decode('fixture-context')
      assert(not rawequal(debug.getmetatable(bareFirst), debug.getmetatable(bareSecond)))
      assert(not rawequal(debug.getmetatable(bareFirst.emptyArray),
        debug.getmetatable(bareSecond.emptyArray)))

      local platform = SynexCoreFactories.platform({
        nowGame = function() return 1000 end,
        random = function() return 5 end,
        print = function() end
      })
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      local trustedFirst = platform.jsonDecode('fixture-context')
      local trustedSecond = platform.jsonDecode('fixture-context')
      assert(platform.jsonContainerKind(bareFirst) == nil)
      assert(platform.jsonContainerKind(trustedFirst) == 'object')
      assert(platform.jsonContainerKind(trustedFirst.emptyObject) == 'object')
      assert(platform.jsonContainerKind(trustedFirst.emptyArray) == 'array')
      assert(platform.jsonContainerKind(trustedFirst.nodes) == 'array')
      assert(rawequal(debug.getmetatable(trustedFirst), debug.getmetatable(trustedSecond)))
      assert(rawequal(debug.getmetatable(trustedFirst.emptyArray),
        debug.getmetatable(trustedSecond.emptyArray)))

      local copied = foundation.copy(trustedFirst)
      assert(platform.jsonContainerKind(copied) == 'object')
      assert(platform.jsonContainerKind(copied.emptyObject) == 'object')
      assert(platform.jsonContainerKind(copied.emptyArray) == 'array')
      assert(platform.jsonEncode(copied.emptyObject) == '{}')
      assert(platform.jsonEncode(copied.emptyArray) == '[]')
      assert(platform.jsonContainerKind(setmetatable({}, { __jsontype = 'object' })) == nil)
      return table.concat({
        platform.jsonContainerKind(copied),
        platform.jsonContainerKind(copied.emptyArray),
        platform.jsonEncode(copied.emptyObject),
        platform.jsonEncode(copied.emptyArray)
      }, ':')
    `);
    assert.equal(result, 'object:array:{}:[]');
  } finally {
    engine.global.close();
  }
});

test('constructor-less Cfx JSON retention policy reaches outbox compaction and remains fail-closed', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await loadCore(engine);
    const result = await engine.doString(`
      json = {
        decode = function(value, position, nullValue, objectMeta, arrayMeta)
          assert(position == nil or position == 1)
          assert(nullValue == nil)
          objectMeta = objectMeta or { __jsontype = 'object' }
          arrayMeta = arrayMeta or { __jsontype = 'array' }
          if value == 'retention-array' then
            return setmetatable({
              publishedPayloadAfterDays = 30, deadPayloadAfterDays = 365
            }, arrayMeta)
          end
          return setmetatable({
            retention = setmetatable({
              outbox = setmetatable({
                publishedPayloadAfterDays = 30, deadPayloadAfterDays = 365
              }, objectMeta)
            }, objectMeta)
          }, objectMeta)
        end,
        encode = function() return '{}' end
      }
      assert(json.object == nil and json.array == nil)

      local rawFirst = json.decode('retention-config')
      local rawSecond = json.decode('retention-config')
      assert(not rawequal(debug.getmetatable(rawFirst), debug.getmetatable(rawSecond)))
      assert(not rawequal(debug.getmetatable(rawFirst.retention.outbox),
        debug.getmetatable(rawSecond.retention.outbox)))

      local platform = SynexCoreFactories.platform({
        nowGame = function() return 1000 end,
        random = function() return 11 end,
        print = function() end
      })
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('outbox-cfx-retention')
      local updates = 0
      local database = { update = function()
        updates = updates + 1
        return 0, nil
      end }
      local reliability = SynexCoreFactories.reliability({
        platform = platform, foundation = foundation, database = database,
        instanceId = 'outbox-cfx-retention', features = { durableEvents = true }
      })

      local decoded = platform.jsonDecode('retention-config')
      local policy = decoded.retention.outbox
      assert(platform.jsonContainerKind(policy) == 'object')
      local compacted = assert(reliability.outbox:compactTerminal(25, policy))
      assert(compacted.compacted == 0 and updates == 2)

      local foreignPairs = 0
      local foreign = setmetatable({
        publishedPayloadAfterDays = 30, deadPayloadAfterDays = 365
      }, {
        __jsontype = 'object',
        __pairs = function() foreignPairs = foreignPairs + 1 error('foreign pairs trap') end
      })
      local foreignResult, foreignError = reliability.outbox:compactTerminal(25, foreign)
      assert(foreignResult == nil and foreignError.code == 'INVALID_OUTBOX_RETENTION')
      assert(foreignPairs == 0 and updates == 2)

      local arrayPolicy = platform.jsonDecode('retention-array')
      assert(platform.jsonContainerKind(arrayPolicy) == 'array')
      local arrayResult, arrayError = reliability.outbox:compactTerminal(25, arrayPolicy)
      assert(arrayResult == nil and arrayError.code == 'INVALID_OUTBOX_RETENTION')

      policy.unknown = true
      local unknownResult, unknownError = reliability.outbox:compactTerminal(25, policy)
      assert(unknownResult == nil and unknownError.code == 'INVALID_OUTBOX_RETENTION')
      policy.unknown = nil
      policy.publishedPayloadAfterDays = 0
      local ageResult, ageError = reliability.outbox:compactTerminal(25, policy)
      assert(ageResult == nil and ageError.code == 'INVALID_OUTBOX_RETENTION')
      assert(updates == 2)

      return table.concat({
        platform.jsonContainerKind(policy), compacted.compacted,
        foreignError.code, arrayError.code, unknownError.code, ageError.code, updates
      }, ':')
    `);
    assert.equal(result,
      'object:0:INVALID_OUTBOX_RETENTION:INVALID_OUTBOX_RETENTION:'
        + 'INVALID_OUTBOX_RETENTION:INVALID_OUTBOX_RETENTION:2');
  } finally {
    engine.global.close();
  }
});

test('Cfx JSON container identities survive trusted copies and reject metatable lookalikes', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await loadCore(engine);
    const result = await engine.doString(`
      local objectMeta = { __jsontype = 'object' }
      local arrayMeta = { __jsontype = 'array' }
      local trapCalls = 0
      json = {
        object = function() return setmetatable({}, objectMeta) end,
        array = function() return setmetatable({}, arrayMeta) end,
        decode = function(value, position, nullValue, decoderObjectMeta, decoderArrayMeta)
          assert(value == 'hybrid-context' and position == 1 and nullValue == nil)
          return setmetatable({
            emptyArray = setmetatable({}, decoderArrayMeta)
          }, decoderObjectMeta)
        end,
        encode = function(value)
          if next(value) ~= nil then return 'populated' end
          local metatable = debug.getmetatable(value)
          if rawequal(metatable, objectMeta) then return '{}' end
          if rawequal(metatable, arrayMeta) then return '[]' end
          return 'plain'
        end
      }
      local platform = SynexCoreFactories.platform({
        nowGame = function() return 1000 end,
        random = function() return 7 end,
        print = function() end
      })
      local foundation = SynexCoreFactories.foundation({ platform = platform })

      local decoded = platform.jsonDecode('hybrid-context')
      assert(platform.jsonContainerKind(decoded) == 'object')
      assert(platform.jsonContainerKind(decoded.emptyArray) == 'array')

      local source = setmetatable({
        emptyObject = setmetatable({}, objectMeta),
        emptyArray = setmetatable({}, arrayMeta),
        values = setmetatable({ 1, 2 }, arrayMeta)
      }, objectMeta)
      local copied = foundation.copy(source)
      assert(platform.jsonContainerKind(copied) == 'object')
      assert(platform.jsonContainerKind(copied.emptyObject) == 'object')
      assert(platform.jsonContainerKind(copied.emptyArray) == 'array')
      assert(platform.jsonContainerKind(copied.values) == 'array')
      assert(platform.jsonEncode(copied.emptyObject) == '{}')
      assert(platform.jsonEncode(copied.emptyArray) == '[]')

      local redacted = foundation.redact(source)
      assert(platform.jsonContainerKind(redacted) == 'object')
      assert(platform.jsonContainerKind(redacted.emptyObject) == 'object')
      assert(platform.jsonContainerKind(redacted.emptyArray) == 'array')
      assert(platform.jsonEncode(redacted.emptyObject) == '{}')
      assert(platform.jsonEncode(redacted.emptyArray) == '[]')

      local plainSecrets = {
        'token:plain-secret', 'identifier:plain-secret', 'password:plain-secret'
      }
      local taggedSecrets = setmetatable({
        'token:tagged-secret', 'identifier:tagged-secret', 'password:tagged-secret'
      }, arrayMeta)
      local redactedPlainSecrets = foundation.redact(plainSecrets)
      local redactedTaggedSecrets = foundation.redact(taggedSecrets)
      for index = 1, 3 do
        assert(redactedPlainSecrets[index] == '[REDACTED]')
        assert(redactedTaggedSecrets[index] == '[REDACTED]')
      end
      assert(platform.jsonContainerKind(redactedPlainSecrets) == 'plain')
      assert(platform.jsonContainerKind(redactedTaggedSecrets) == 'array')

      local oversized = {}
      for index = 1, 4096 do oversized[index] = 'secret-' .. index end
      local redactedOversized = foundation.redact(setmetatable(oversized, arrayMeta))
      assert(platform.jsonContainerKind(redactedOversized) == 'array')
      assert(#redactedOversized == 1 and redactedOversized[1] == '[TRUNCATED_ITEMS]')
      local redactedNestedOversized = foundation.redact(setmetatable({
        values = oversized
      }, objectMeta))
      assert(platform.jsonContainerKind(redactedNestedOversized) == 'object')
      assert(platform.jsonContainerKind(redactedNestedOversized.values) == 'array')
      assert(#redactedNestedOversized.values == 1)
      assert(redactedNestedOversized.values[1] == '[TRUNCATED_ITEMS]')

      local markerOnly = setmetatable({}, {
        __jsontype = 'object',
        __pairs = function() trapCalls = trapCalls + 1 error('marker trap') end
      })
      local protectedSpoof = setmetatable({}, {
        __metatable = objectMeta,
        __pairs = function() trapCalls = trapCalls + 1 error('protected trap') end
      })
      assert(platform.jsonContainerKind(markerOnly) == nil)
      assert(getmetatable(protectedSpoof) == objectMeta)
      assert(platform.jsonContainerKind(protectedSpoof) == nil)
      assert(foundation.redact(markerOnly) == '[UNSAFE_TABLE]')
      assert(foundation.redact(protectedSpoof) == '[UNSAFE_TABLE]')
      objectMeta.__jsontype = 'array'
      assert(platform.jsonContainerKind(source) == nil)
      objectMeta.__jsontype = 'object'
      assert(platform.jsonContainerKind(source) == 'object')
      objectMeta.__pairs = function() trapCalls = trapCalls + 1 error('shared trap') end
      local rawCopied = foundation.copy(source)
      assert(platform.jsonContainerKind(rawCopied) == 'object')
      objectMeta.__pairs = nil
      assert(trapCalls == 0)
      return table.concat({
        platform.jsonContainerKind(copied),
        platform.jsonEncode(copied.emptyObject),
        platform.jsonEncode(copied.emptyArray),
        trapCalls
      }, ':')
    `);
    assert.equal(result, 'object:{}:[]:0');
  } finally {
    engine.global.close();
  }
});

test('constructor-less Cfx JSON saga context survives persistence and executes once', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await loadCore(engine);
    await engine.doString(await readFile(
      path.join(root, 'core/synex_core/server/saga_runtime.lua'),
      'utf8',
    ));
    const result = await engine.doString(`
      local snapshots = {}
      local snapshotCounter, decodeCalls, suppliedDecodeCalls = 0, 0, 0
      local decoderObjectMeta, decoderArrayMeta = nil, nil

      local function freeze(value, active)
        if type(value) ~= 'table' then return value end
        active = active or {}
        assert(not active[value], 'fixture cannot encode a cycle')
        active[value] = true
        local metatable = debug.getmetatable(value)
        local kind = type(metatable) == 'table' and rawget(metatable, '__jsontype') or nil
        if kind ~= 'object' and kind ~= 'array' then
          local count, maximumIndex = 0, 0
          kind = 'array'
          for key in next, value do
            if type(key) ~= 'number' or math.type(key) ~= 'integer' or key < 1 then
              kind = 'object'
              break
            end
            count = count + 1
            maximumIndex = math.max(maximumIndex, key)
          end
          if maximumIndex ~= count then kind = 'object' end
        end
        local snapshot = { kind = kind }
        if kind == 'array' then
          snapshot.values = {}
          for index = 1, rawlen(value) do
            snapshot.values[index] = freeze(rawget(value, index), active)
          end
        else
          snapshot.entries = {}
          for key, child in next, value do
            snapshot.entries[#snapshot.entries + 1] = {
              key = key, value = freeze(child, active)
            }
          end
        end
        active[value] = nil
        return snapshot
      end

      local function thaw(snapshot, objectMeta, arrayMeta)
        if type(snapshot) ~= 'table' then return snapshot end
        local value = setmetatable({}, snapshot.kind == 'object' and objectMeta or arrayMeta)
        if snapshot.kind == 'array' then
          for index, child in ipairs(snapshot.values) do
            rawset(value, index, thaw(child, objectMeta, arrayMeta))
          end
        else
          for _, entry in ipairs(snapshot.entries) do
            rawset(value, entry.key, thaw(entry.value, objectMeta, arrayMeta))
          end
        end
        return value
      end

      local fixtureContext = {
        kind = 'object', entries = {
          { key = 'emptyObject', value = { kind = 'object', entries = {} } },
          { key = 'emptyArray', value = { kind = 'array', values = {} } },
          { key = 'nodes', value = { kind = 'array', values = {{
            kind = 'object', entries = {{ key = 'id', value = 'node-a' }}
          }} } }
        }
      }

      json = {
        decode = function(value, position, nullValue, ...)
          decodeCalls = decodeCalls + 1
          assert(position == nil or position == 1)
          assert(nullValue == nil)
          local objectMeta, arrayMeta
          if select('#', ...) > 0 then
            assert(select('#', ...) == 2)
            objectMeta, arrayMeta = ...
            assert(type(objectMeta) == 'table' and rawget(objectMeta, '__jsontype') == 'object')
            assert(type(arrayMeta) == 'table' and rawget(arrayMeta, '__jsontype') == 'array')
            suppliedDecodeCalls = suppliedDecodeCalls + 1
            if decoderObjectMeta ~= nil then
              assert(rawequal(objectMeta, decoderObjectMeta))
              assert(rawequal(arrayMeta, decoderArrayMeta))
            else
              decoderObjectMeta, decoderArrayMeta = objectMeta, arrayMeta
            end
          else
            objectMeta = { __jsontype = 'object' }
            arrayMeta = { __jsontype = 'array' }
          end
          local snapshot
          if value == 'fixture-context' then snapshot = fixtureContext
          elseif value == '{}' then snapshot = { kind = 'object', entries = {} }
          elseif value == '[]' then snapshot = { kind = 'array', values = {} }
          else snapshot = snapshots[value] end
          assert(snapshot ~= nil, 'fixture received unknown encoded JSON')
          return thaw(snapshot, objectMeta, arrayMeta)
        end,
        encode = function(value)
          local snapshot = freeze(value)
          if snapshot.kind == 'object' and #snapshot.entries == 0 then return '{}' end
          if snapshot.kind == 'array' and #snapshot.values == 0 then return '[]' end
          snapshotCounter = snapshotCounter + 1
          local token = 'fixture-json-' .. snapshotCounter
          snapshots[token] = snapshot
          return token
        end
      }
      assert(json.object == nil and json.array == nil)

      local platform = SynexCoreFactories.platform({
        nowGame = function() return 1000 end,
        random = function() return 13 end,
        print = function() end
      })
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('cfx-json-saga-dispatch')

      local seedContext = platform.jsonDecode('fixture-context')
      local sagaRow = {
        id = 91, public_id = 'saga_fixture', owner_resource = 'synex_fixture',
        saga_type = 'fixture.workflow', correlation_id = 'correlation-a',
        state = 'pending', current_step = 0, version = 1,
        context_json = platform.jsonEncode(seedContext), last_error_json = nil,
        deadline_at = nil, deadline_expired = 0, age_ms = 0
      }
      local stepRows, terminalLeaseWrites = {}, 0
      local tick = string.char(96)
      local database = {}
      function database:query(sql)
        if sql:find('FROM ' .. tick .. 'synex_saga_steps' .. tick, 1, true) then
          return stepRows, nil
        end
        if sql:find('FROM ' .. tick .. 'synex_sagas' .. tick, 1, true) then
          return {{
            id = sagaRow.id, public_id = sagaRow.public_id,
            owner_resource = sagaRow.owner_resource, saga_type = sagaRow.saga_type,
            correlation_id = sagaRow.correlation_id, state = sagaRow.state,
            current_step = sagaRow.current_step, version = sagaRow.version,
            context_json = sagaRow.context_json, last_error_json = sagaRow.last_error_json,
            deadline_at = sagaRow.deadline_at, deadline_expired = sagaRow.deadline_expired,
            age_ms = sagaRow.age_ms
          }}, nil
        end
        error('unexpected saga load SQL')
      end
      function database:withTransaction(handler)
        local accepted = handler(function(sql, parameters)
          parameters = parameters or {}
          if sql:find('FOR UPDATE', 1, true) then
            return {{
              id = sagaRow.id, state = sagaRow.state,
              current_step = sagaRow.current_step, version = sagaRow.version
            }}
          end
          if sql:find('INSERT INTO ' .. tick .. 'synex_saga_steps' .. tick, 1, true) then
            stepRows[#stepRows + 1] = {
              sequence_no = parameters[2], step_name = parameters[3],
              event_type = parameters[4], attempt = parameters[5],
              payload_json = parameters[6], error_json = parameters[7],
              occurred_at = '2026-08-24 12:00:00.000000'
            }
            return { affectedRows = 1 }
          end
          if sql:find('UPDATE ' .. tick .. 'synex_sagas' .. tick, 1, true) then
            assert(parameters[7] == sagaRow.id)
            assert(parameters[8] == sagaRow.version)
            assert(parameters[9] == sagaRow.owner_resource)
            sagaRow.state = parameters[1]
            sagaRow.current_step = parameters[2]
            sagaRow.context_json = parameters[3]
            if parameters[4] == 1 then sagaRow.last_error_json = nil
            elseif parameters[5] ~= nil then sagaRow.last_error_json = parameters[5] end
            sagaRow.version = sagaRow.version + 1
            return { affectedRows = 1 }
          end
          if sql:find('UPDATE ' .. tick .. 'synex_cluster_leases' .. tick, 1, true) then
            terminalLeaseWrites = terminalLeaseWrites + 1
            return { affectedRows = 1 }
          end
          error('unexpected saga transaction SQL')
        end)
        return accepted == true, accepted == true and nil
          or foundation.error('TRANSACTION_REJECTED', 'fixture rollback')
      end

      local sagas = SynexCoreFactories.reliability({
        platform = platform, foundation = foundation, database = database,
        instanceId = 'instance-a', features = { sagas = true }
      }).sagas
      function sagas:candidates(_, selectors)
        assert(#selectors == 1 and selectors[1].ownerResource == sagaRow.owner_resource)
        assert(selectors[1].sagaType == sagaRow.saga_type)
        return {{
          publicId = sagaRow.public_id, ownerResource = sagaRow.owner_resource,
          sagaType = sagaRow.saga_type, state = sagaRow.state, version = sagaRow.version
        }}, nil
      end

      local owners = {}
      function owners:isCurrent(owner, epoch)
        return owner == 'synex_fixture' and epoch == 1
      end
      function owners:track() return 'tracked', nil end
      function owners:beginOperation() return 'operation', nil end
      function owners:finishOperation() return true end
      local leases = {}
      function leases:acquire(name, owner, ttl, requesterInstanceId, requesterBootId)
        return {
          name = name, owner = owner, fencingToken = 1, ttlSeconds = ttl,
          requesterInstanceId = requesterInstanceId, requesterBootId = requesterBootId
        }, nil
      end
      function leases:renew() return true, nil end
      function leases:release() return true, nil end
      local handlerCalls, handlerContext = 0, nil
      local runtime = SynexCoreFactories.sagaRuntime({
        foundation = foundation, platform = platform, sagas = sagas,
        audit = { append = function() return { eventId = 'audit-a' }, nil end },
        leases = leases, owners = owners,
        instances = { bootId = function() return 'boot-a', nil end },
        instanceId = 'instance-a', enabled = true
      })
      assert(runtime:register('synex_fixture', 1, {
        name = 'fixture.workflow', steps = {{
          name = 'fixture.step',
          run = function(context)
            handlerCalls = handlerCalls + 1
            handlerContext = context
            assert(platform.jsonContainerKind(context) == 'object')
            assert(platform.jsonContainerKind(context.emptyObject) == 'object')
            assert(platform.jsonContainerKind(context.emptyArray) == 'array')
            assert(platform.jsonContainerKind(context.nodes) == 'array')
            assert(context.nodes[1].id == 'node-a')
            context.completed = true
            return { context = context, output = { accepted = true } }, nil
          end,
          compensate = function() return { output = {} }, nil end
        }}
      }))
      local report, dispatchError = runtime:dispatchBatch(1)
      assert(dispatchError == nil and report.processed == 1 and report.failed == 0)
      assert(handlerCalls == 1 and #stepRows == 2 and terminalLeaseWrites == 1)
      assert(stepRows[1].event_type == 'started' and stepRows[2].event_type == 'succeeded')
      assert(sagaRow.state == 'completed' and sagaRow.current_step == 2 and sagaRow.version == 3)

      local reloaded = assert(sagas:load(sagaRow.public_id, sagaRow.owner_resource))
      assert(reloaded.context ~= handlerContext and reloaded.context.completed == true)
      assert(platform.jsonContainerKind(reloaded.context) == 'object')
      assert(platform.jsonContainerKind(reloaded.context.emptyObject) == 'object')
      assert(platform.jsonContainerKind(reloaded.context.emptyArray) == 'array')
      assert(platform.jsonContainerKind(reloaded.context.nodes) == 'array')
      assert(platform.jsonEncode(reloaded.context.emptyObject) == '{}')
      assert(platform.jsonEncode(reloaded.context.emptyArray) == '[]')
      assert(#reloaded.steps == 2)
      assert(reloaded.steps[1].event == 'started' and reloaded.steps[2].event == 'succeeded')
      assert(decodeCalls == 5 and suppliedDecodeCalls == decodeCalls)

      local objectMeta = debug.getmetatable(reloaded.context)
      local arrayMeta = debug.getmetatable(reloaded.context.emptyArray)
      local persistedSteps, persistedVersion = #stepRows, sagaRow.version
      local persistedLeaseWrites = terminalLeaseWrites
      local hostile = setmetatable({}, { __jsontype = 'object' })
      local rejected, rejection = sagas:appendRuntimeEvent({
        ownerResource = sagaRow.owner_resource, publicId = sagaRow.public_id,
        expectedVersion = sagaRow.version, stepName = 'fixture.rejected',
        eventType = 'started', attempt = 1, nextState = 'running',
        terminal = false, payload = {}, context = { nested = hostile }
      })
      assert(rejected == nil and rejection.code == 'INVALID_JSON_VALUE')

      local trapCalls = 0
      local cyclic = setmetatable({}, objectMeta)
      cyclic.self = cyclic
      local invalidContexts = {
        setmetatable({ [1] = 'numeric' }, objectMeta),
        setmetatable({ key = 'string' }, arrayMeta),
        setmetatable({ [1] = 'one', [3] = 'three' }, arrayMeta),
        { [1] = 'value', key = 'value' },
        cyclic,
        { value = 0 / 0 },
        { value = math.huge },
        { value = function() end },
        { value = coroutine.create(function() end) },
        { value = setmetatable({}, {
          __jsontype = 'object',
          __pairs = function() trapCalls = trapCalls + 1 error('validator trap') end
        }) }
      }
      for index, invalidContext in ipairs(invalidContexts) do
        local value, failure = sagas:appendRuntimeEvent({
          ownerResource = sagaRow.owner_resource, publicId = sagaRow.public_id,
          expectedVersion = sagaRow.version, stepName = 'fixture.invalid.' .. index,
          eventType = 'started', attempt = 1, nextState = 'running',
          terminal = false, payload = {}, context = invalidContext
        })
        assert(value == nil and failure.code == 'INVALID_JSON_VALUE', index)
      end
      assert(#stepRows == persistedSteps and sagaRow.version == persistedVersion)
      assert(terminalLeaseWrites == persistedLeaseWrites and trapCalls == 0)
      return table.concat({
        sagaRow.state, handlerCalls, #stepRows,
        stepRows[1].event_type, stepRows[2].event_type,
        rejection.code, trapCalls, decodeCalls
      }, ':')
    `);
    assert.equal(result, 'completed:1:2:started:succeeded:INVALID_JSON_VALUE:0:5');
  } finally {
    engine.global.close();
  }
});

test('contract runtime distinguishes canonical empty Cfx objects and arrays', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await loadCore(engine);
    for (const relativePath of [
      'core/synex_core/shared/protocol.lua',
      'core/synex_core/server/contracts.lua',
    ]) {
      await engine.doString(await readFile(path.join(root, relativePath), 'utf8'));
    }
    const result = await engine.doString(`
      local objectMeta = { __jsontype = 'object' }
      local arrayMeta = { __jsontype = 'array' }
      json = {
        object = function() return setmetatable({}, objectMeta) end,
        array = function() return setmetatable({}, arrayMeta) end,
        decode = function() error('fixture decoder is not used') end,
        encode = function() return '{}' end
      }
      local platform = SynexCoreFactories.platform({
        nowGame = function() return 1000 end, random = function() return 17 end,
        print = function() end
      })
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      local contracts = SynexCoreFactories.contracts({
        foundation = foundation, protocol = SynexProtocol
      })
      local contract = { input = {
        type = 'object', additionalProperties = false,
        required = { 'objectValue', 'arrayValue' },
        properties = {
          objectValue = { type = 'object', additionalProperties = false },
          arrayValue = { type = 'array', maxItems = 0 }
        }
      } }
      local tagged = setmetatable({
        objectValue = setmetatable({}, objectMeta),
        arrayValue = setmetatable({}, arrayMeta)
      }, objectMeta)
      assert(contracts.registry:validateInput(contract, tagged))
      local swapped, swappedError = contracts.registry:validateInput(contract, setmetatable({
        objectValue = setmetatable({}, arrayMeta),
        arrayValue = setmetatable({}, objectMeta)
      }, objectMeta))
      assert(swapped == nil and swappedError.code == 'VALIDATION_FAILED')
      local hostile, hostileError = contracts.registry:validateInput(contract, {
        objectValue = setmetatable({}, { __jsontype = 'object' }),
        arrayValue = setmetatable({}, arrayMeta)
      })
      assert(hostile == nil and hostileError.code == 'VALIDATION_FAILED')
      local arrayAsObject, arrayAsObjectError = contracts.registry:validateInput({ input = {
        type = 'object', additionalProperties = false
      } }, setmetatable({}, arrayMeta))
      assert(arrayAsObject == nil and arrayAsObjectError.code == 'VALIDATION_FAILED')
      local objectAsArray, objectAsArrayError = contracts.registry:validateInput({ input = {
        type = 'array', maxItems = 0
      } }, setmetatable({}, objectMeta))
      assert(objectAsArray == nil and objectAsArrayError.code == 'VALIDATION_FAILED')
      local trapCalls = 0
      objectMeta.__index = function() trapCalls = trapCalls + 1 error('object index trap') end
      objectMeta.__pairs = function() trapCalls = trapCalls + 1 error('object pairs trap') end
      local missing, missingError = contracts.registry:validateInput({ input = {
        type = 'object', additionalProperties = false, required = { 'missing' }
      } }, setmetatable({}, objectMeta))
      assert(missing == nil and missingError.code == 'VALIDATION_FAILED')
      assert(trapCalls == 0)
      return table.concat({ platform.jsonContainerKind(tagged.objectValue),
        platform.jsonContainerKind(tagged.arrayValue), swappedError.code,
        hostileError.code, arrayAsObjectError.code, objectAsArrayError.code, trapCalls }, ':')
    `);
    assert.equal(result,
      'object:array:VALIDATION_FAILED:VALIDATION_FAILED:VALIDATION_FAILED:VALIDATION_FAILED:0');
  } finally {
    engine.global.close();
  }
});

test('character deletion accepts decoder-tagged plans but rejects marker-only metadata', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await loadCore(engine);
    await engine.doString(await readFile(path.join(
      root,
      'core/synex_core/server/identity_character_deletion_reconciliation.lua',
    ), 'utf8'));
    const result = await engine.doString(`
      local objectMeta = { __jsontype = 'object' }
      local arrayMeta = { __jsontype = 'array' }
      json = {
        object = function() return setmetatable({}, objectMeta) end,
        array = function() return setmetatable({}, arrayMeta) end,
        decode = function() error('fixture decoder is not used') end,
        encode = function() return '{}' end
      }
      local platform = SynexCoreFactories.platform({
        nowGame = function() return 1000 end, random = function() return 19 end,
        print = function() end
      })
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      local service = SynexCoreFactories.identityCharacterDeletionReconciliation({
        platform = platform, foundation = foundation, database = {}, leases = {}, instances = {},
        owners = {}, messaging = {}, stateService = {}, instanceId = 'instance-a',
        coreResource = 'synex_core', invokeParticipant = function() end,
        findParticipant = function() end
      })
      local plan = setmetatable({
        schema = 1, characterId = 'character-a',
        actions = setmetatable({ setmetatable({
          owner = 'synex_fixture', participant = 'fixture.deletion', action = 'anonymize',
          metadata = setmetatable({
            emptyObject = setmetatable({}, objectMeta),
            emptyArray = setmetatable({}, arrayMeta)
          }, objectMeta)
        }, objectMeta) }, arrayMeta)
      }, objectMeta)
      local trapCalls = 0
      objectMeta.__index = function() trapCalls = trapCalls + 1 error('object index trap') end
      objectMeta.__pairs = function() trapCalls = trapCalls + 1 error('object pairs trap') end
      arrayMeta.__len = function() trapCalls = trapCalls + 1 error('array length trap') end
      arrayMeta.__index = function() trapCalls = trapCalls + 1 error('array index trap') end
      assert(service:validate(plan))
      plan.actions[1].metadata = setmetatable({}, { __jsontype = 'object' })
      local accepted, failure = service:validate(plan)
      assert(accepted == nil and failure.code == 'INVALID_DELETE_PLAN')
      assert(trapCalls == 0)
      return table.concat({ platform.jsonContainerKind(plan),
        platform.jsonContainerKind(plan.actions), failure.code, trapCalls }, ':')
    `);
    assert.equal(result, 'object:array:INVALID_DELETE_PLAN:0');
  } finally {
    engine.global.close();
  }
});

test('durable event publication accepts Cfx-decoded payloads without trusting spoofed markers', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await loadCore(engine);
    for (const relativePath of [
      'core/synex_core/shared/protocol.lua',
      'core/synex_core/server/registries.lua',
      'core/synex_core/server/lifecycle.lua',
      'core/synex_core/server/contracts.lua',
      'core/synex_core/server/security.lua',
      'core/synex_core/server/messaging.lua',
    ]) {
      await engine.doString(await readFile(path.join(root, relativePath), 'utf8'));
    }
    const result = await engine.doString(`
      local objectMeta = { __jsontype = 'object' }
      local arrayMeta = { __jsontype = 'array' }
      local trapCalls = 0
      json = {
        object = function() return setmetatable({}, objectMeta) end,
        array = function() return setmetatable({}, arrayMeta) end,
        decode = function() error('fixture decoder is not used') end,
        encode = function() return '{}' end
      }
      local platform = SynexCoreFactories.platform({
        nowGame = function() return 1000 end, random = function() return 23 end,
        print = function() end, setTimeout = function(_, callback) callback() end
      })
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('cfx-json-outbox')
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      local owners = registries.owners
      local publisherEpoch = owners:activate('synex_core')
      local consumerEpoch = owners:activate('synex_consumer')
      local lifecycle = SynexCoreFactories.lifecycle({
        platform = platform, foundation = foundation, owners = owners
      })
      local security = SynexCoreFactories.security({
        platform = platform, foundation = foundation, coreResource = 'synex_core',
        policy = { default = { allow = {}, deny = {} }, resources = {} }
      })
      security.capabilities:registerManifest('synex_core', {
        capabilities = { request = {} },
        events = { publish = { 'synex.fixture.*' }, subscribe = {} }
      })
      security.capabilities:registerManifest('synex_consumer', {
        capabilities = { request = {} },
        events = { publish = {}, subscribe = { 'synex.fixture.changed' } }
      })
      local contracts = SynexCoreFactories.contracts({
        foundation = foundation, protocol = SynexProtocol
      })
      local messaging = SynexCoreFactories.messaging({
        platform = platform, foundation = foundation, contracts = contracts,
        security = security, owners = owners, players = registries.players,
        lifecycle = lifecycle, dependencies = lifecycle.dependencies,
        protocol = SynexProtocol, config = {}, coreResource = 'synex_core'
      })
      local delivered = 0
      assert(messaging.events:subscribe(
        'synex_consumer', consumerEpoch, 'synex.fixture.changed', function(payload)
          delivered = delivered + 1
          assert(platform.jsonContainerKind(payload) == 'object')
          assert(platform.jsonContainerKind(payload.emptyObject) == 'object')
          assert(platform.jsonContainerKind(payload.emptyArray) == 'array')
          return true, nil
        end))
      local payload = setmetatable({
        emptyObject = setmetatable({}, objectMeta),
        emptyArray = setmetatable({}, arrayMeta)
      }, objectMeta)
      local report = assert(messaging.events:publishOutbox(
        'synex_core', publisherEpoch, 'synex.fixture.changed', payload, {
          eventId = 'event-cfx-json-01', aggregateId = 'aggregate-a', schemaVersion = 1
        }))
      assert(report.delivered == 1 and report.failed == 0 and delivered == 1)

      local hostile = setmetatable({}, {
        __jsontype = 'object',
        __pairs = function() trapCalls = trapCalls + 1 error('hostile pairs') end
      })
      local rejected, rejection = messaging.events:publishOutbox(
        'synex_core', publisherEpoch, 'synex.fixture.changed', hostile, {
          eventId = 'event-cfx-json-02', aggregateId = 'aggregate-a', schemaVersion = 1
        })
      assert(rejected == nil and rejection.code == 'INVALID_EVENT')
      assert(delivered == 1 and trapCalls == 0)
      return table.concat({ report.delivered, delivered, rejection.code, trapCalls }, ':')
    `);
    assert.equal(result, '1:1:INVALID_EVENT:0');
  } finally {
    engine.global.close();
  }
});
