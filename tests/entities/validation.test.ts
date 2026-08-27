import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';

const validationPath = path.join(
  process.cwd(),
  'resources',
  'synex_entities',
  'shared',
  'validation.lua',
);
const databasePath = path.join(
  process.cwd(),
  'resources',
  'synex_entities',
  'server',
  'database.lua',
);
const orderedIndexPath = path.join(
  process.cwd(),
  'resources',
  'synex_entities',
  'server',
  'ordered_index.lua',
);
const registryPath = path.join(
  process.cwd(),
  'resources',
  'synex_entities',
  'server',
  'registry.lua',
);
const foundationPath = path.join(
  process.cwd(),
  'resources',
  'synex_entities',
  'server',
  'foundation.lua',
);
const repositoryPath = path.join(
  process.cwd(),
  'resources',
  'synex_entities',
  'server',
  'repository.lua',
);

async function runLua<T>(assertions: string): Promise<T> {
  const engine = await new LuaFactory().createEngine();
  try {
    await engine.doString(await readFile(validationPath, 'utf8'));
    await engine.doString(await readFile(orderedIndexPath, 'utf8'));
    await engine.doString(await readFile(registryPath, 'utf8'));
    return await engine.doString(assertions) as T;
  } finally {
    engine.global.close();
  }
}

test('entity spawn validation normalizes hashes and enforces type boundaries', async () => {
  const result = await runLua<string>(String.raw`
    local normalized = assert(SynexEntityValidation.validateSpawn({
      entityType = 'vehicle',
      model = -1,
      position = { x = 10.5, y = -2.0, z = 30.0 },
      heading = -90.0,
      bucket = 0,
      bucketGeneration = 0,
      vehicleType = 'automobile',
      owner = { type = 'resource', id = 'synex_example' }
    }))
    assert(normalized.model == 4294967295)
    assert(normalized.heading == 270.0)
    assert(normalized.bucketGeneration == 0)

    local mixedCaseKey, mixedCaseError = SynexEntityValidation.validatePersistentKey('Garage:Primary')
    assert(mixedCaseKey == nil and mixedCaseError.code == 'INVALID_ARGUMENT')

    local invalid, invalidError = SynexEntityValidation.validateSpawn({
      entityType = 'vehicle',
      model = 1,
      position = { x = 0, y = 0, z = 0 },
      vehicleType = 'automobile',
      pedType = 4,
      owner = { type = 'resource', id = 'synex_example' }
    })
    assert(invalid == nil)
    assert(invalidError.code == 'INVALID_ARGUMENT')
    return invalidError.code
  `);
  assert.equal(result, 'INVALID_ARGUMENT');
});

test('managed bucket references require a matching nonzero generation', async () => {
  const result = await runLua<string>(String.raw`
    local defaultBucket = assert(SynexEntityValidation.validateBucketReference(0, 0, true))
    assert(defaultBucket.id == 0 and defaultBucket.generation == 0)

    local missingGeneration, missingError = SynexEntityValidation.validateBucketReference(1200, 0, true)
    assert(missingGeneration == nil and missingError.code == 'INVALID_ARGUMENT')

    local managed = assert(SynexEntityValidation.validateBucketReference(1200, 'bucket_epoch_0007', false))
    assert(managed.id == 1200 and managed.generation == 'bucket_epoch_0007')
    return missingError.code
  `);
  assert.equal(result, 'INVALID_ARGUMENT');
});

test('registry indexes reject net ID reuse and stale or foreign generations', async () => {
  const result = await runLua<string>(String.raw`
    local registry = SynexEntityValidation.newRegistry()
    local record = assert(registry.insert({
      entityId = 'entity_00000001',
      generation = 2,
      netId = 41,
      persistentKey = 'garage:primary',
      resourceOwner = 'synex_garages'
    }))
    assert(registry.count() == 1)
    assert(registry.byNetworkId(41) == record)
    assert(registry.byPersistentKey('garage:primary', 'synex_garages') == record)

    local stale, staleError = registry.resolve(record.entityId, 1, 'synex_garages')
    assert(stale == nil and staleError.code == 'STALE_ENTITY')
    local foreign, foreignError = registry.resolve(record.entityId, 2, 'synex_jobs')
    assert(foreign == nil and foreignError.code == 'FOREIGN_RESOURCE_OWNER')

    local duplicate, duplicateError = registry.insert({
      entityId = 'entity_00000002',
      generation = 1,
      netId = 41,
      resourceOwner = 'synex_jobs'
    })
    assert(duplicate == nil and duplicateError.code == 'CONFLICT')
    assert(registry.remove(record.entityId, 2) == record)
    assert(registry.count() == 0)
    return duplicateError.code
  `);
  assert.equal(result, 'CONFLICT');
});

test('token bucket is deterministic and refills against monotonic time', async () => {
  const accepted = await runLua<number>(String.raw`
    local limiter = SynexEntityValidation.newTokenBucket(2, 1)
    local accepted = 0
    if limiter.take('synex_jobs', 1, 1000) then accepted = accepted + 1 end
    if limiter.take('synex_jobs', 1, 1000) then accepted = accepted + 1 end
    assert(not limiter.take('synex_jobs', 1, 1000))
    if limiter.take('synex_jobs', 1, 2000) then accepted = accepted + 1 end
    return accepted
  `);
  assert.equal(accepted, 3);
});

test('database port is injectable and preserves positional parameters', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await engine.doString(await readFile(databasePath, 'utf8'));
    const result = await engine.doString(String.raw`
      local observed
      local adapter = SynexEntityDatabase.createOxmysqlAdapter({
        query = {
          await = function(statement, parameters)
            observed = { statement = statement, first = parameters[1] }
            return { { entity_id = 'entity_00000001' } }
          end
        },
        update = {
          await = function(_, parameters)
            return parameters[1]
          end
        }
      })
      local rows = adapter.query('SELECT entity_id WHERE persistent_key = ?', { 'garage:primary' })
      assert(rows[1].entity_id == 'entity_00000001')
      assert(observed.statement:find('?', 1, true))
      assert(observed.first == 'garage:primary')
      return adapter.update('UPDATE', { 1 })
    `) as number;
    assert.equal(result, 1);
  } finally {
    engine.global.close();
  }
});

test('unexpected failures reach a structured sink without exposing the caught value', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    for (const file of [validationPath, orderedIndexPath, registryPath, foundationPath]) {
      await engine.doString(await readFile(file, 'utf8'));
    }
    const result = await engine.doString(String.raw`
      local state = SynexEntityRegistry.newState()
      local events = {}
      local foundation = SynexEntityFoundation.create({
        errorSink = function(event) events[#events + 1] = event end,
        health = {},
        limits = { maxEntities = 8, maxOwnerEntities = 4, maxBucketEntities = 4 },
        ports = {
          getGameTimer = function() return 1000 end,
          getResourceState = function() return 'started' end
        },
        registry = state.entities,
        resourceName = 'synex_entities',
        state = state,
        validation = SynexEntityValidation
      })
      local ok = foundation.protect('repository.query', function()
        error('mysql://operator:secret@private-host/database')
      end, { traceId = 'trace_0001' })
      assert(not ok and #events == 1)
      local event = events[1]
      assert(event.code == 'UNEXPECTED_FAILURE')
      assert(event.detail == '[REDACTED]')
      assert(event.errorType == 'string')
      assert(event.operation == 'repository.query')
      assert(event.traceId == 'trace_0001')
      for _, value in pairs(event) do
        assert(not tostring(value):find('secret', 1, true))
        assert(not tostring(value):find('private-host', 1, true))
      end
      return event.detail
    `) as string;
    assert.equal(result, '[REDACTED]');
  } finally {
    engine.global.close();
  }
});

test('entity Core consumers recognize protected Cfx-callable tables and userdata', async () => {
  const engine = await new LuaFactory().createEngine();
  await engine.global.set('cfxCallable', {});
  try {
    for (const file of [validationPath, orderedIndexPath, registryPath, foundationPath]) {
      await engine.doString(await readFile(file, 'utf8'));
    }
    const result = await engine.doString(String.raw`
      local state = SynexEntityRegistry.newState()
      local foundation = SynexEntityFoundation.create({
        errorSink = function() error('error sink should not run') end,
        health = {},
        limits = { maxEntities = 8, maxOwnerEntities = 4, maxBucketEntities = 4 },
        ports = {
          getGameTimer = function() return 1000 end,
          getResourceState = function() return 'started' end
        },
        registry = state.entities,
        resourceName = 'synex_entities',
        state = state,
        validation = SynexEntityValidation
      })
      local tableRef = setmetatable({ __cfx_functionReference = 'table-fixture' }, {
        __metatable = 'protected-cfx-table',
        __call = function(_, value) return 'table:' .. value end
      })
      debug.setmetatable(cfxCallable, {
        __metatable = 'protected-cfx-userdata',
        __call = function(_, value) return 'userdata:' .. value end
      })
      assert(foundation.isCallable(function() end))
      assert(foundation.isCallable(tableRef) and tableRef('ok') == 'table:ok')
      assert(type(cfxCallable) == 'userdata')
      assert(foundation.isCallable(cfxCallable) and cfxCallable('ok') == 'userdata:ok')
      assert(not foundation.isCallable({ __cfx_functionReference = 'marker-only' }))
      assert(not foundation.isCallable(setmetatable({}, {
        __metatable = 'protected-invalid-call', __call = true
      })))
      debug.setmetatable(cfxCallable, { __metatable = 'protected-noncallable-userdata' })
      assert(not foundation.isCallable(cfxCallable))
      return type(tableRef) .. ':' .. type(cfxCallable)
    `) as string;
    assert.equal(result, 'table:userdata');
  } finally {
    engine.global.close();
  }
});

test('repository fails closed on nil, scalar, sparse, and non-table DB results', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    for (const file of [
      validationPath, orderedIndexPath, registryPath, foundationPath, repositoryPath,
    ]) {
      await engine.doString(await readFile(file, 'utf8'));
    }
    const result = await engine.doString(String.raw`
      local state = SynexEntityRegistry.newState()
      local health = { persistence = 'UNKNOWN', state = 'STARTING' }
      local events = {}
      local foundation = SynexEntityFoundation.create({
        errorSink = function(event) events[#events + 1] = event end,
        health = health,
        limits = { maxEntities = 8, maxOwnerEntities = 4, maxBucketEntities = 4 },
        ports = {
          getGameTimer = function() return 1000 end,
          getResourceState = function() return 'started' end
        },
        registry = state.entities,
        resourceName = 'synex_entities',
        state = state,
        validation = SynexEntityValidation
      })

      local queryResult = nil
      local updateResult = nil
      local repository = SynexEntityRepository.create({
        database = {
          query = function() return queryResult end,
          update = function() return updateResult end
        },
        foundation = foundation,
        health = health
      })

      local rows, nilError = repository.findPersistentByKey('garage:primary')
      assert(rows == nil and nilError.code == 'UNAVAILABLE')
      assert(health.persistence == 'UNAVAILABLE')
      queryResult = 7
      local scalarRows, scalarError = repository.findPersistentByKey('garage:primary')
      assert(scalarRows == nil and scalarError.code == 'UNAVAILABLE')
      queryResult = { [1] = {}, [3] = {} }
      local sparseRows, sparseError = repository.listForRehydrate(4)
      assert(sparseRows == nil and sparseError.code == 'UNAVAILABLE')
      queryResult = { 9 }
      local malformedRows, malformedError = repository.listForRehydrate(4)
      assert(malformedRows == nil and malformedError.code == 'UNAVAILABLE')

      updateResult = nil
      local nilUpdate, nilUpdateError = repository.beginDelete('entity_00000001', 1)
      assert(nilUpdate == nil and nilUpdateError.code == 'UNAVAILABLE')
      assert(health.persistence == 'UNAVAILABLE')
      updateResult = {}
      local tableUpdate, tableUpdateError = repository.beginDelete('entity_00000001', 1)
      assert(tableUpdate == nil and tableUpdateError.code == 'UNAVAILABLE')
      updateResult = 1
      assert(repository.beginDelete('entity_00000001', 1) == 1)

      assert(health.persistence == 'READY')
      assert(#events == 6)
      return nilUpdateError.retryable and tableUpdateError.retryable and 'UNAVAILABLE' or 'FAILED'
    `) as string;
    assert.equal(result, 'UNAVAILABLE');
  } finally {
    engine.global.close();
  }
});

test('spawn reservations and owner lifecycle changes remain race-safe', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    for (const file of [validationPath, orderedIndexPath, registryPath, foundationPath]) {
      await engine.doString(await readFile(file, 'utf8'));
    }
    const result = await engine.doString(String.raw`
      local state = SynexEntityRegistry.newState()
      local health = {}
      local cleaned = 0
      local foundation = SynexEntityFoundation.create({
        errorSink = function() error('error sink should not run') end,
        health = health,
        limits = { maxEntities = 1, maxOwnerEntities = 1, maxBucketEntities = 1 },
        ports = {
          getGameTimer = function() return 1000 end,
          getResourceState = function() return 'started' end
        },
        registry = state.entities,
        resourceName = 'synex_entities',
        state = state,
        validation = SynexEntityValidation
      })
      foundation.setCleanupOwner(function(owner, cycle)
        assert(owner == 'synex_jobs' and cycle == 0)
        cleaned = cleaned + 1
      end)

      local nestedCode
      assert(foundation.withSpawnReservation('synex_jobs', 0, {}, function()
        local nested, nestedError = foundation.withSpawnReservation('synex_jobs', 0, {}, function()
          return true
        end)
        assert(nested == nil)
        nestedCode = nestedError.code
        return true
      end))
      assert(nestedCode == 'UNAVAILABLE')

      local value, lifecycleError = foundation.withOwnerMutation('synex_jobs', {}, function()
        local stoppedCycle, inFlight = foundation.advanceOwnerCycle('synex_jobs')
        assert(stoppedCycle == 0 and inFlight)
        return true
      end)
      assert(value == nil and lifecycleError.code == 'STALE_RESOURCE')
      assert(cleaned == 1)
      return nestedCode .. ':' .. lifecycleError.code
    `) as string;
    assert.equal(result, 'UNAVAILABLE:STALE_RESOURCE');
  } finally {
    engine.global.close();
  }
});
