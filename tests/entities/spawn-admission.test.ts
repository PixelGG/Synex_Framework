import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';

const resource = path.join(process.cwd(), 'resources', 'synex_entities');
const modules = [
  ['shared', 'validation.lua'],
  ['server', 'ordered_index.lua'],
  ['server', 'spatial_index.lua'],
  ['server', 'registry.lua'],
  ['server', 'spawn_admission.lua'],
  ['server', 'control_provider_support.lua'],
  ['server', 'control_provider_inspect.lua'],
  ['server', 'control_provider.lua'],
] as const;

const fixture = String.raw`
  local clock = 1000
  local metrics = {}
  local function config(overrides)
    local value = {
      maxBucketEntities = 100, maxEntities = 100,
      maxBucketPlayers = 100, maxBuckets = 100,
      maxLogicalOwnerEntities = 100, maxOwnerEntities = 100,
      maxOwnerBuckets = 100,
      maxPersistentEntities = 100,
      maxTypeEntities = { object = 100, ped = 100, vehicle = 100 },
      spawnRateLimits = { object = 100, ped = 100, vehicle = 100 },
      spawnRateMaxEntries = 10000, spawnRateMaxScopes = 100, spawnRateWindowMs = 1000,
    }
    for key, item in pairs(overrides or {}) do value[key] = item end
    return value
  end
  local function admission(state, overrides)
    return SynexEntitySpawnAdmission.create({
      config = config(overrides),
      observability = {
        audit = function() return true end,
        increment = function(name, labels, amount)
          metrics[#metrics + 1] = { amount = amount, name = name, scope = labels.scope }
        end,
      },
      ports = { getGameTimer = function() return clock end },
      registry = state.entities,
      state = state,
    })
  end
  local function candidate(overrides)
    local value = {
      bucket = 0, entityType = 'vehicle', owner = { type = 'resource', id = 'synex_vehicles' },
      persistent = false,
    }
    for key, item in pairs(overrides or {}) do value[key] = item end
    return value
  end
  local function insert(state, index, overrides)
    local value = {
      bucket = 0, entityId = ('entity_quota_%04d'):format(index), entityType = 'vehicle',
      generation = 1, handle = 1000 + index, netId = index,
      owner = { type = 'resource', id = 'synex_jobs' }, persistent = false,
      position = { x = index, y = 0, z = 0 }, resourceOwner = 'synex_jobs',
      status = 'active',
    }
    for key, item in pairs(overrides or {}) do value[key] = item end
    return assert(state.entities.insert(value))
  end
`;

async function runLua<T>(assertions: string): Promise<T> {
  const engine = await new LuaFactory().createEngine();
  try {
    for (const [directory, filename] of modules) {
      await engine.doString(await readFile(path.join(resource, directory, filename), 'utf8'));
    }
    return await engine.doString(`${fixture}\n${assertions}`) as T;
  } finally {
    engine.global.close();
  }
}

test('every live quota dimension denies with bounded safe details', async () => {
  const scopes = await runLua<string>(String.raw`
    local results = {}
    local function denied(overrides, existing, request, createsPersistent, managedLimit)
      local state = SynexEntityRegistry.newState({ spatial = { cellSize = 32 } })
      insert(state, 1, existing)
      if managedLimit then
        state.buckets[request.bucket] = { maxEntities = managedLimit }
      end
      local service = admission(state, overrides)
      local value, operationError = service.withReservation(
        'synex_vehicles', candidate(request), {}, function() return true end,
        createsPersistent == true)
      assert(value == nil and operationError.code == 'ENTITY_QUOTA_EXCEEDED')
      assert(type(operationError.details.limit) == 'number')
      assert(type(operationError.details.scope) == 'string')
      assert(operationError.details.caller == nil and operationError.details.bucket == nil)
      results[#results + 1] = operationError.details.scope
    end
    denied({ maxEntities = 1 }, {}, {})
    denied({ maxOwnerEntities = 1 }, { resourceOwner = 'synex_vehicles' }, {})
    denied({ maxLogicalOwnerEntities = 1 }, {
      owner = { type = 'character', id = 'character_shared' },
    }, { owner = { type = 'character', id = 'character_shared' } })
    denied({}, { bucket = 7 }, { bucket = 7 }, false, 1)
    denied({ maxTypeEntities = { object = 100, ped = 100, vehicle = 1 } }, {}, {})
    denied({ maxPersistentEntities = 1 }, { persistent = true }, {}, true)
    assert(#metrics == 12)
    local stable, compatibility = 0, 0
    for _, metric in ipairs(metrics) do
      if metric.name == 'quota_denials' then stable = stable + 1 end
      if metric.name == 'quota_denials_total' then compatibility = compatibility + 1 end
    end
    assert(stable == 6 and compatibility == 6)
    return table.concat(results, ',')
  `);
  assert.equal(scopes,
    'global_live,resource_live,logical_owner_live,bucket_live,entity_type_live,persistent_total');
});

test('a destroying bucket is stale rather than a quota denial', async () => {
  const result = await runLua<string>(String.raw`
    local state = SynexEntityRegistry.newState({ spatial = { cellSize = 32 } })
    state.buckets[7] = { destroying = true, maxEntities = 100 }
    local service = admission(state)
    local value, operationError = service.withReservation(
      'synex_vehicles', candidate({ bucket = 7 }), {}, function() return true end)
    assert(value == nil and operationError.code == 'STALE_BUCKET')
    assert(#metrics == 0)
    return operationError.code
  `);
  assert.equal(result, 'STALE_BUCKET');
});

test('spawn rate windows are isolated by resource, type and bucket', async () => {
  const result = await runLua<string>(String.raw`
    local state = SynexEntityRegistry.newState({ spatial = { cellSize = 32 } })
    local service = admission(state, {
      spawnRateLimits = { object = 2, ped = 2, vehicle = 2 },
      spawnRateMaxScopes = 8, spawnRateWindowMs = 1000,
    })
    local vehicle = candidate()
    assert(service.withReservation('synex_vehicles', vehicle, {}, function() return true end))
    assert(service.withReservation('synex_vehicles', vehicle, {}, function() return true end))
    local denied, rateError = service.withReservation(
      'synex_vehicles', vehicle, {}, function() return true end)
    assert(denied == nil and rateError.code == 'SPAWN_RATE_LIMITED')
    assert(rateError.details.scope == 'resource_type_bucket_window')
    assert(rateError.details.limit == 2)
    assert(service.withReservation('synex_jobs', vehicle, {}, function() return true end))
    assert(service.withReservation('synex_vehicles', candidate({ bucket = 1 }), {},
      function() return true end))
    assert(service.withReservation('synex_vehicles', candidate({ entityType = 'ped' }), {},
      function() return true end))
    clock = clock + 1000
    assert(service.withReservation('synex_vehicles', vehicle, {}, function() return true end))
    return rateError.code .. ':' .. service.snapshot().trackedRateScopes
  `);
  assert.equal(result, 'SPAWN_RATE_LIMITED:4');
});

test('pending reservations close quota races and always release their counters', async () => {
  const result = await runLua<string>(String.raw`
    local state = SynexEntityRegistry.newState({ spatial = { cellSize = 32 } })
    local service = admission(state, { maxEntities = 1 })
    local innerCode
    assert(service.withReservation('synex_vehicles', candidate(), {}, function()
      local nested, nestedError = service.withReservation(
        'synex_jobs', candidate({ owner = { type = 'resource', id = 'synex_jobs' } }), {},
        function() return true end)
      assert(nested == nil)
      innerCode = nestedError.code
      return true
    end))
    assert(service.snapshot().pending == 0)
    local raised = pcall(function()
      service.withReservation('synex_vehicles', candidate(), {}, function()
        error('expected handler failure')
      end)
    end)
    assert(not raised and service.snapshot().pending == 0)
    assert(service.withReservation('synex_vehicles', candidate(), {}, function() return true end))
    return innerCode
  `);
  assert.equal(result, 'ENTITY_QUOTA_EXCEEDED');
});

test('quota snapshots report bounded live usage and in-flight reservations by authority scope', async () => {
  const result = await runLua<string>(String.raw`
    local state = SynexEntityRegistry.newState({ spatial = { cellSize = 32 } })
    state.buckets[7] = {
      id = 7, resourceOwner = 'synex_vehicles', maxEntities = 4, maxPlayers = 4,
      entities = {}, players = { [10] = true },
    }
    state.buckets[8] = {
      id = 8, resourceOwner = 'synex_jobs', maxEntities = 4, maxPlayers = 4,
      entities = {}, players = {},
    }
    insert(state, 1, {
      bucket = 7, owner = { type = 'character', id = 'character_one' },
      persistent = true, resourceOwner = 'synex_vehicles',
    })
    insert(state, 2, {
      bucket = 7, entityType = 'object', handle = 2002, netId = 102,
      owner = { type = 'character', id = 'character_one' },
      resourceOwner = 'synex_vehicles',
    })
    insert(state, 3, {
      bucket = 8, entityType = 'ped', handle = 2003, netId = 103,
      owner = { type = 'resource', id = 'synex_jobs' },
    })
    local quotaConfig = config({
      maxBucketEntities = 4, maxBucketPlayers = 4, maxBuckets = 4,
      maxEntities = 10, maxLogicalOwnerEntities = 4, maxOwnerBuckets = 2,
      maxOwnerEntities = 4, maxPersistentEntities = 4,
      maxTypeEntities = { object = 4, ped = 4, vehicle = 4 },
    })
    local service = SynexEntitySpawnAdmission.create({
      config = quotaConfig,
      observability = {
        audit = function() return true end,
        increment = function() return true end,
      },
      ports = { getGameTimer = function() return clock end },
      registry = state.entities,
      state = state,
    })
    local captured
    assert(service.withReservation('synex_vehicles', candidate({
      bucket = 7, owner = { type = 'character', id = 'character_one' },
    }), {}, function()
      captured = service.quotaSnapshot(10)
      return true
    end, true))
    assert(captured.global.current == 3 and captured.global.pending == 1)
    assert(captured.global.usagePercent == 40 and captured.global.remaining == 6)
    assert(captured.persistent.current == 1 and captured.persistent.pending == 1)
    assert(captured.persistent.usagePercent == 50)
    assert(captured.reservations.pending == 1
      and captured.reservations.pendingPersistent == 1)
    assert(captured.managedBuckets.current == 2 and captured.managedBuckets.limit == 4)
    assert(#captured.entityTypes == 3)
    assert(captured.entityTypes[3].entityType == 'vehicle')
    assert(captured.entityTypes[3].current == 1 and captured.entityTypes[3].pending == 1)
    assert(captured.resources.total == 2 and captured.resources.truncated == false)
    assert(captured.resources.items[2].resourceOwner == 'synex_vehicles')
    assert(captured.resources.items[2].current == 2
      and captured.resources.items[2].pending == 1)
    assert(captured.resources.items[2].managedBuckets == 1)
    assert(captured.logicalOwners.total == 2)
    assert(captured.logicalOwners.items[1].ownerType == 'character')
    assert(captured.logicalOwners.items[1].current == 2
      and captured.logicalOwners.items[1].pending == 1)
    assert(captured.routingBuckets.total == 2)
    assert(captured.routingBuckets.items[1].bucket == 7)
    assert(captured.routingBuckets.items[1].current == 2
      and captured.routingBuckets.items[1].pending == 1)
    assert(captured.routingBuckets.items[1].players == 1
      and captured.routingBuckets.items[1].playerUsagePercent == 25)
    local bounded = service.quotaSnapshot(1)
    assert(bounded.resources.returned == 1 and bounded.resources.truncated == true)
    assert(bounded.logicalOwners.returned == 1 and bounded.logicalOwners.truncated == true)
    assert(bounded.routingBuckets.returned == 1 and bounded.routingBuckets.truncated == true)
    local operations
    local provider = SynexEntityControlProvider.create({
      authorityRepository = {}, bucketPolicy = {}, config = quotaConfig,
      coreRef = { value = { ownerEpoch = 1 } }, database = {},
      foundation = {
        failure = function(code, message, retryable)
          return nil, { code = code, message = message, retryable = retryable }
        end,
        isCallable = function(value) return type(value) == 'function' end,
        reportUnexpected = function() error('unexpected quota provider failure') end,
      },
      queryOperations = {}, registry = state.entities, service = {},
      spawnAdmission = service, state = state,
    })
    assert(provider.register({ ControlProviders = { register = function(definition)
      operations = definition.operations
      return { namespace = definition.namespace }
    end } }))
    local exposed = assert(operations.summary({ view = 'quotas', limit = 1 }, {
      traceId = 'entity_quota_control',
    }))
    assert(exposed.global.current == 3 and exposed.resources.truncated == true)
    assert(exposed.networkOwnerPolicy.authoritative == false)
    assert(service.snapshot().pending == 0)
    return captured.resources.items[2].resourceOwner
  `);
  assert.equal(result, 'synex_vehicles');
});

test('tracked spawn-rate scope storage is bounded without a cleanup tick', async () => {
  const result = await runLua<string>(String.raw`
    local state = SynexEntityRegistry.newState({ spatial = { cellSize = 32 } })
    local service = admission(state, {
      spawnRateMaxScopes = 2,
      spawnRateLimits = { object = 5, ped = 5, vehicle = 5 },
    })
    assert(service.withReservation('synex_vehicles', candidate({ bucket = 1 }), {},
      function() return true end))
    assert(service.withReservation('synex_vehicles', candidate({ bucket = 2 }), {},
      function() return true end))
    local denied, operationError = service.withReservation(
      'synex_vehicles', candidate({ bucket = 3 }), {}, function() return true end)
    assert(denied == nil and operationError.code == 'SPAWN_RATE_LIMITED')
    assert(operationError.details.scope == 'tracked_spawn_scopes')
    assert(service.snapshot().trackedRateScopes == 2)
    clock = clock + 1000
    assert(service.withReservation('synex_vehicles', candidate({ bucket = 3 }), {},
      function() return true end))
    return operationError.code
  `);
  assert.equal(result, 'SPAWN_RATE_LIMITED');
});

test('tracked spawn timestamps have an independent global memory bound', async () => {
  const result = await runLua<string>(String.raw`
    local state = SynexEntityRegistry.newState({ spatial = { cellSize = 32 } })
    local service = admission(state, {
      spawnRateMaxEntries = 2,
      spawnRateLimits = { object = 5, ped = 5, vehicle = 5 },
    })
    assert(service.withReservation('synex_vehicles', candidate({ bucket = 1 }), {},
      function() return true end))
    assert(service.withReservation('synex_vehicles', candidate({ bucket = 2 }), {},
      function() return true end))
    local denied, operationError = service.withReservation(
      'synex_vehicles', candidate({ bucket = 3 }), {}, function() return true end)
    assert(denied == nil and operationError.code == 'SPAWN_RATE_LIMITED')
    assert(operationError.details.scope == 'tracked_spawn_entries')
    assert(service.snapshot().trackedRateEntries == 2)
    clock = clock + 1000
    assert(service.withReservation('synex_vehicles', candidate({ bucket = 3 }), {},
      function() return true end))
    return operationError.details.scope
  `);
  assert.equal(result, 'tracked_spawn_entries');
});

test('spawn admission is wired into all creation paths and declared contracts', async () => {
  const [manifest, server, legacy, authority, lifecycle, contracts, bootstrap] = await Promise.all([
    readFile(path.join(resource, 'fxmanifest.lua'), 'utf8'),
    readFile(path.join(resource, 'server', 'server.lua'), 'utf8'),
    readFile(path.join(resource, 'server', 'entity_service.lua'), 'utf8'),
    readFile(path.join(resource, 'server', 'authority_service.lua'), 'utf8'),
    readFile(path.join(resource, 'server', 'authority_lifecycle.lua'), 'utf8'),
    readFile(path.join(resource, 'contracts', 'entities.contracts.json'), 'utf8'),
    readFile(path.join(resource, 'server', 'bootstrap_config.lua'), 'utf8'),
  ]);
  assert.match(manifest, /server\/spawn_admission\.lua/u);
  assert.match(server, /SynexEntitySpawnAdmission\.create/u);
  assert.match(legacy, /spawnAdmission\.withReservation/u);
  assert.match(authority, /spawnAdmission\.withReservation/u);
  assert.ok((lifecycle.match(/spawnAdmission\.withReservation/gu) ?? []).length >= 2);
  assert.ok((contracts.match(/SPAWN_RATE_LIMITED/gu) ?? []).length >= 2);
  for (const name of [
    'maxLogicalOwnerEntities', 'maxPersistentEntities', 'maxTypeEntities',
    'spawnRateLimits', 'spawnRateMaxEntries', 'spawnRateMaxScopes', 'spawnRateWindowMs',
  ]) {
    assert.ok(bootstrap.includes(name), `${name} must be bounded in bootstrap config`);
  }
});
