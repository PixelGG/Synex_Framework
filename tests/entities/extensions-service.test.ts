import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';

const root = path.join(process.cwd(), 'resources', 'synex_entities');
const modules = [
  ['shared', 'validation.lua'],
  ['server', 'ordered_index.lua'],
  ['server', 'spatial_index.lua'],
  ['server', 'registry.lua'],
  ['server', 'foundation.lua'],
  ['server', 'extension_schema.lua'],
  ['server', 'extension_registry.lua'],
  ['server', 'json_values.lua'],
  ['server', 'archetypes.lua'],
  ['server', 'component_lifecycle.lua'],
  ['server', 'extensions.lua'],
] as const;

const fixture = String.raw`
  local clock = 1000
  local projected = {}
  local componentStore, stateStore, tags = {}, {}, {}
  local persistenceCalls = { component = 0, state = 0, tags = 0 }
  local jsonDocuments = {
    ['{}'] = function() return {} end,
    ['{"type":"object"}'] = function() return { type = 'object' } end,
    ['{"type":"object","additionalProperties":false,"required":["locked"],"properties":{"locked":{"type":"boolean"}}}'] = function()
      return { type = 'object', additionalProperties = false, required = { 'locked' },
        properties = { locked = { type = 'boolean' } } }
    end,
    ['{"unknown":true}'] = function() return { unknown = true } end,
    ['{"locked":true}'] = function() return { locked = true } end,
    ['{"locked":"yes"}'] = function() return { locked = 'yes' } end,
    ['true'] = function() return true end,
    ['false'] = function() return false end,
    ['"wrong"'] = function() return 'wrong' end,
  }
  local function jsonDecode(encoded)
    local factory = jsonDocuments[encoded]
    if not factory then error('unsupported JSON fixture') end
    return factory()
  end
  local function jsonEncode(value)
    if value == true then return 'true' end
    if value == false then return 'false' end
    if type(value) == 'string' then return '"' .. value .. '"' end
    if type(value) == 'table' and value.locked == true then return '{"locked":true}' end
    if type(value) == 'table' and value.locked == 'yes' then return '{"locked":"yes"}' end
    if type(value) == 'table' and next(value) == nil then return '{}' end
    error('unsupported encode fixture')
  end

  local state = SynexEntityRegistry.newState({ spatial = { cellSize = 32 } })
  local registry = state.entities
  local health = {}
  local ports = {
    getGameTimer = function() clock = clock + 10 return clock end,
    getResourceState = function() return 'started' end,
    jsonDecode = jsonDecode,
    jsonEncode = jsonEncode,
    setEntityState = function(handle, key, value, replicated)
      projected[#projected + 1] = {
        cleared = value == nil, handle = handle, key = key,
        replicated = replicated, value = value,
      }
    end,
  }
  local foundation = SynexEntityFoundation.create({
    errorSink = function() end,
    health = health,
    limits = { maxEntities = 32, maxOwnerEntities = 32, maxBucketEntities = 32 },
    ports = ports,
    registry = registry,
    resourceName = 'synex_entities',
    state = state,
    validation = SynexEntityValidation,
  })
  local coreRef = { value = { Capabilities = {
    checkResource = function() return true end,
  } } }
  local definitionRegistry = SynexEntityExtensionRegistry.create()
  local jsonValues = SynexEntityJsonValues.create({
    foundation = foundation, ports = ports, maximumBytes = 32768,
    maximumDepth = 16, maximumNodes = 512,
  })
  local archetypes = SynexEntityArchetypes.create({
    extensionRegistry = definitionRegistry, foundation = foundation,
    jsonValues = jsonValues, ports = ports, validation = SynexEntityValidation,
  })
  local repository = {}
  function repository.getComponent(entityId, namespace)
    local value = componentStore[entityId .. ':' .. namespace]
    if not value then return nil, { code = 'COMPONENT_NOT_FOUND', message = 'missing' } end
    return value
  end
  function repository.setComponent(entityId, generation, caller, definition, payload, expected)
    persistenceCalls.component = persistenceCalls.component + 1
    local key = entityId .. ':' .. definition.namespace
    local current = componentStore[key]
    if (current and current.version or 0) ~= expected then
      return nil, { code = 'CONCURRENT_MODIFICATION', message = 'stale', retryable = true }
    end
    componentStore[key] = { namespace = definition.namespace, ownerResource = caller,
      payloadJson = payload, persistenceMode = definition.persistenceMode,
      schemaVersion = definition.schemaVersion, version = expected + 1 }
    return { version = expected + 1 }
  end
  function repository.removeComponent(entityId, generation, caller, namespace, expected)
    local key, current = entityId .. ':' .. namespace, componentStore[entityId .. ':' .. namespace]
    if not current then return nil, { code = 'COMPONENT_NOT_FOUND', message = 'missing' } end
    if current.version ~= expected then
      return nil, { code = 'CONCURRENT_MODIFICATION', message = 'stale', retryable = true }
    end
    componentStore[key] = nil
    return { removed = true }
  end
  function repository.getState(entityId, key)
    local value = stateStore[entityId .. ':' .. key]
    if not value then return nil, { code = 'STATE_NOT_FOUND', message = 'missing' } end
    return value
  end
  function repository.setState(entityId, generation, caller, definition, payload, expected)
    persistenceCalls.state = persistenceCalls.state + 1
    local storeKey = entityId .. ':' .. definition.key
    local current = stateStore[storeKey]
    if (current and current.version or 0) ~= expected then
      return nil, { code = 'CONCURRENT_MODIFICATION', message = 'stale', retryable = true }
    end
    stateStore[storeKey] = { key = definition.key, ownerResource = caller,
      schemaVersion = definition.schemaVersion, valueJson = payload, version = expected + 1 }
    return { version = expected + 1 }
  end
  function repository.mutateTags(entityId, generation, caller, values, mode)
    persistenceCalls.tags = persistenceCalls.tags + 1
    tags[entityId] = tags[entityId] or {}
    local changed = false
    for _, tag in ipairs(values) do
      if mode == 'add' and not tags[entityId][tag] then tags[entityId][tag], changed = caller, true end
      if mode == 'remove' and tags[entityId][tag] then tags[entityId][tag], changed = nil, true end
    end
    local result = {}
    for tag in pairs(tags[entityId]) do result[#result + 1] = tag end
    table.sort(result)
    return { changed = changed, tags = result }
  end
  local service = SynexEntityExtensions.create({
    archetypes = archetypes,
    coreRef = coreRef,
    currentAuthority = function()
      return { instanceId = 'instance-test', resourceEpoch = 1,
        serverScope = 'test', token = 'authority-test' }
    end,
    extensionRegistry = definitionRegistry,
    foundation = foundation,
    jsonValues = jsonValues,
    ports = ports,
    registry = registry,
    repository = repository,
    validation = SynexEntityValidation,
  })
  local entity = assert(registry.insert({
    bucket = 0, entityId = 'entity_extension_0001', generation = 1,
    handle = 9001, netId = 91, position = { x = 0, y = 0, z = 0 },
    authorityLeaseGeneration = 1,
    resourceOwner = 'synex_vehicles', status = 'active',
  }))
  local context = { caller = 'synex_vehicles', callerEpoch = 1, traceId = 'trace_extension_0001' }
`;

async function runLua<T>(assertions: string): Promise<T> {
  const engine = await new LuaFactory().createEngine();
  try {
    for (const [directory, filename] of modules) {
      await engine.doString(await readFile(path.join(root, directory, filename), 'utf8'));
    }
    return await engine.doString(`${fixture}\n${assertions}`) as T;
  } finally {
    engine.global.close();
  }
}

test('extension registrations are caller-owned, epoch-bound and idempotent', async () => {
  const total = await runLua<number>(String.raw`
    local archetypeRequest = {
      allowedModels = { 100, 200 }, descriptorJson = '{}', entityType = 'vehicle',
      name = 'synex_vehicles.standard', persistencePolicy = 'persistent',
      reasonCode = 'synex_vehicles.register', recoveryPolicy = 'automatic', version = 1,
      spawnDefaults = { model = 100, vehicleType = 'automobile' },
      defaultTags = {}, componentSchemas = {}, stateSchemas = {},
    }
    assert(service.registerArchetype(archetypeRequest, context))
    assert(service.registerArchetype(archetypeRequest, context))
    assert(service.registerComponentSchema({
      maximumBytes = 1024, maximumDepth = 4,
      namespace = 'synex_vehicles.runtime', persistenceMode = 'replicated',
      reasonCode = 'synex_vehicles.register', schemaJson = '{"type":"object"}',
      schemaVersion = 1,
    }, context))
    assert(service.registerStateSchema({
      authority = 'server', constraintsJson = '{}', key = 'synex_vehicles:locked',
      maximumBytes = 32, reasonCode = 'synex_vehicles.register',
      replication = 'scoped', schemaVersion = 1, valueType = 'boolean',
    }, context))
    local foreign, foreignError = service.registerComponentSchema({
      maximumBytes = 128, maximumDepth = 2, namespace = 'synex_jobs.runtime',
      persistenceMode = 'runtime', reasonCode = 'synex_vehicles.register',
      schemaJson = '{}', schemaVersion = 1,
    }, context)
    assert(foreign == nil and foreignError.code == 'FORBIDDEN')
    local invalid, invalidError = service.registerComponentSchema({
      maximumBytes = 128, maximumDepth = 2, namespace = 'synex_vehicles.invalid',
      persistenceMode = 'runtime', reasonCode = 'synex_vehicles.register',
      schemaJson = '{"unknown":true}', schemaVersion = 1,
    }, context)
    assert(invalid == nil and invalidError.code == 'COMPONENT_SCHEMA_INVALID')
    local stale, staleError = service.registerArchetype(archetypeRequest, {
      caller = 'synex_vehicles', callerEpoch = 0, traceId = 'trace_stale_0001'
    })
    assert(stale == nil and staleError.code == 'STALE_RESOURCE')
    return definitionRegistry.snapshot().total
  `);
  assert.equal(total, 3);
});

test('state registration rejects unsupported and unsafe replication policies', async () => {
  const result = await runLua<string>(String.raw`
    local ownerMode, ownerModeError = service.registerStateSchema({
      authority = 'server', constraintsJson = '{}', key = 'synex_vehicles:owner_only',
      maximumBytes = 32, reasonCode = 'synex_vehicles.register',
      replication = 'owner', schemaVersion = 1, valueType = 'boolean',
    }, context)
    assert(ownerMode == nil and ownerModeError.code == 'STATE_SCHEMA_INVALID')
    local unscopedObserved, observedError = service.registerStateSchema({
      authority = 'client_observed', constraintsJson = '{}',
      key = 'synex_vehicles:observed', maximumBytes = 32,
      reasonCode = 'synex_vehicles.register', replication = 'none',
      schemaVersion = 1, valueType = 'boolean',
    }, context)
    assert(unscopedObserved == nil and observedError.code == 'STATE_SCHEMA_INVALID')
    return ownerModeError.code .. ':' .. observedError.code
  `);
  assert.equal(result, 'STATE_SCHEMA_INVALID:STATE_SCHEMA_INVALID');
});

test('client-observed state remains a server-mediated scoped write', async () => {
  const result = await runLua<string>(String.raw`
    assert(service.registerStateSchema({
      authority = 'client_observed', constraintsJson = '{}',
      key = 'synex_vehicles:door_observed', maximumBytes = 32,
      reasonCode = 'synex_vehicles.register', replication = 'scoped',
      schemaVersion = 1, valueType = 'boolean',
    }, context))
    local stored = assert(service.setState({
      entity = { entityId = entity.entityId, generation = 1 },
      expectedVersion = 0, idempotencyKey = 'state:observed:0001',
      key = 'synex_vehicles:door_observed',
      reasonCode = 'synex_vehicles.observation_validated',
      schemaVersion = 1, valueJson = 'true',
    }, context))
    assert(stored.version == 1 and persistenceCalls.state == 1)
    assert(#projected == 1 and projected[1].handle == 9001)
    assert(projected[1].key == 'synex_vehicles:door_observed')
    assert(projected[1].value == true and projected[1].replicated == true)
    local fetched = assert(service.getState({
      entity = { entityId = entity.entityId, generation = 1 },
      key = 'synex_vehicles:door_observed',
    }, context))
    return fetched.valueJson .. ':' .. fetched.version
  `);
  assert.equal(result, 'true:1');
});

test('persistent and replicated components enforce schemas and optimistic versions', async () => {
  const result = await runLua<string>(String.raw`
    assert(service.registerComponentSchema({
      maximumBytes = 256, maximumDepth = 4,
      namespace = 'synex_vehicles.runtime', persistenceMode = 'replicated',
      reasonCode = 'synex_vehicles.register',
      schemaJson = '{"type":"object","additionalProperties":false,"required":["locked"],"properties":{"locked":{"type":"boolean"}}}',
      schemaVersion = 1,
    }, context))
    local request = {
      entity = { entityId = entity.entityId, generation = 1 }, expectedVersion = 0,
      idempotencyKey = 'component:set:0001', namespace = 'synex_vehicles.runtime',
      payloadJson = '{"locked":true}', reasonCode = 'synex_vehicles.update',
      schemaVersion = 1,
    }
    local stored = assert(service.setComponent(request, context))
    assert(stored.version == 1 and persistenceCalls.component == 1)
    assert(#projected == 1 and projected[1].handle == 9001)
    assert(projected[1].key == 'synex:component:synex_vehicles.runtime')
    local fetched = assert(service.getComponent({
      entity = request.entity, namespace = request.namespace,
    }, context))
    assert(fetched.version == 1 and fetched.payloadJson == '{"locked":true}')
    local stale, staleError = service.setComponent(request, context)
    assert(stale == nil and staleError.code == 'CONCURRENT_MODIFICATION')
    local invalid = {
      entity = request.entity, expectedVersion = 1, idempotencyKey = 'component:set:0002',
      namespace = request.namespace, payloadJson = '{"locked":"yes"}',
      reasonCode = request.reasonCode, schemaVersion = 1,
    }
    local rejected, rejectedError = service.setComponent(invalid, context)
    assert(rejected == nil and rejectedError.code == 'COMPONENT_SCHEMA_MISMATCH')
    assert(persistenceCalls.component == 2)
    local removed = assert(service.removeComponent({
      entity = request.entity, expectedVersion = 1,
      idempotencyKey = 'component:remove:0001', namespace = request.namespace,
      reasonCode = 'synex_vehicles.remove',
    }, context))
    assert(removed.removed and #projected == 2 and projected[2].cleared)
    return staleError.code
  `);
  assert.equal(result, 'CONCURRENT_MODIFICATION');
});

test('state writes are schema-fenced and scoped projection is server-authored', async () => {
  const result = await runLua<number>(String.raw`
    assert(service.registerStateSchema({
      authority = 'server', constraintsJson = '{}', key = 'synex_vehicles:locked',
      maximumBytes = 32, reasonCode = 'synex_vehicles.register',
      replication = 'scoped', schemaVersion = 3, valueType = 'boolean',
    }, context))
    local request = {
      entity = { entityId = entity.entityId, generation = 1 }, expectedVersion = 0,
      idempotencyKey = 'state:set:0001', key = 'synex_vehicles:locked',
      reasonCode = 'synex_vehicles.update', schemaVersion = 3, valueJson = 'true',
    }
    local stored = assert(service.setState(request, context))
    assert(stored.version == 1 and persistenceCalls.state == 1)
    assert(#projected == 1 and projected[1].key == request.key)
    assert(projected[1].value == true and projected[1].replicated == true)
    local fetched = assert(service.getState({ entity = request.entity, key = request.key }, context))
    assert(fetched.valueJson == 'true' and fetched.version == 1)
    local wrongType = {
      entity = request.entity, expectedVersion = 1, idempotencyKey = 'state:set:0002',
      key = request.key, reasonCode = request.reasonCode,
      schemaVersion = 3, valueJson = '"wrong"',
    }
    local rejected, rejectedError = service.setState(wrongType, context)
    assert(rejected == nil and rejectedError.code == 'STATE_SCHEMA_MISMATCH')
    assert(persistenceCalls.state == 1)
    return stored.version
  `);
  assert.equal(result, 1);
});

test('runtime components and tag batches clean up with their owner epoch', async () => {
  const result = await runLua<number>(String.raw`
    assert(service.registerComponentSchema({
      maximumBytes = 256, maximumDepth = 3,
      namespace = 'synex_vehicles.session', persistenceMode = 'runtime',
      reasonCode = 'synex_vehicles.register', schemaJson = '{"type":"object"}',
      schemaVersion = 1,
    }, context))
    local componentRequest = {
      entity = { entityId = entity.entityId, generation = 1 }, expectedVersion = 0,
      idempotencyKey = 'runtime:set:0001', namespace = 'synex_vehicles.session',
      payloadJson = '{"locked":true}', reasonCode = 'synex_vehicles.update', schemaVersion = 1,
    }
    assert(service.setComponent(componentRequest, context).version == 1)
    assert(persistenceCalls.component == 0 and #projected == 0)
    local added = assert(service.addTags({
      entity = componentRequest.entity, idempotencyKey = 'tags:add:0001',
      reasonCode = 'synex_vehicles.classify',
      tags = { 'synex_vehicles.vehicle', 'synex_vehicles.managed' },
    }, context))
    assert(added.changed and persistenceCalls.tags == 1 and #added.tags == 2)
    assert(#entity.tags == 2 and entity.tags[1] == 'synex_vehicles.managed'
      and entity.tags[2] == 'synex_vehicles.vehicle')
    local removed = assert(service.removeTags({
      entity = componentRequest.entity, idempotencyKey = 'tags:remove:0001',
      reasonCode = 'synex_vehicles.classify', tags = { 'synex_vehicles.managed' },
    }, context))
    assert(removed.changed and persistenceCalls.tags == 2)
    assert(#entity.tags == 1 and entity.tags[1] == 'synex_vehicles.vehicle')
    assert(service.cleanupOwner('synex_vehicles', 1) == 1)
    local missing, missingError = service.getComponent({
      entity = componentRequest.entity, namespace = componentRequest.namespace,
    }, context)
    assert(missing == nil and missingError.code == 'COMPONENT_SCHEMA_NOT_FOUND')
    return persistenceCalls.tags
  `);
  assert.equal(result, 2);
});

test('implicit cleanup is limited to the last observed owner epoch', async () => {
  const result = await runLua<number>(String.raw`
    local function request(name)
      return {
        allowedModels = { 100 }, descriptorJson = '{}', entityType = 'vehicle',
        name = name, persistencePolicy = 'temporary',
        reasonCode = 'synex_vehicles.register', recoveryPolicy = 'none', version = 1,
        spawnDefaults = { model = 100, vehicleType = 'automobile' },
        defaultTags = {}, componentSchemas = {}, stateSchemas = {},
      }
    end
    assert(service.registerArchetype(request('synex_vehicles.first'), context))
    assert(service.ownerEpoch('synex_vehicles') == 1)
    local nextContext = {
      caller = 'synex_vehicles', callerEpoch = 2, traceId = 'trace_extension_0002',
    }
    assert(service.registerArchetype(request('synex_vehicles.second'), nextContext))
    assert(service.ownerEpoch('synex_vehicles') == 2)
    assert(service.cleanupOwner('synex_vehicles', 1) == 0)
    assert(definitionRegistry.get('archetype', 'synex_vehicles.second'))
    assert(service.cleanupOwner('synex_vehicles') == 1)
    assert(service.ownerEpoch('synex_vehicles') == nil)
    return definitionRegistry.snapshot().total
  `);
  assert.equal(result, 0);
});
