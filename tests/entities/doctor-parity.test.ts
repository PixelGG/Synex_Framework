import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';

const resource = path.join(process.cwd(), 'resources', 'synex_entities');

async function runAnalyzer<T>(body: string): Promise<T> {
  const engine = await new LuaFactory().createEngine();
  try {
    await engine.doString(await readFile(
      path.join(resource, 'server', 'diagnostics_analyzer.lua'), 'utf8'));
    return await engine.doString(body) as T;
  } finally {
    engine.global.close();
  }
}

const emptySnapshot = String.raw`{
  counts = { definitions = 1, spawn_outcomes = 0, failed_spawns = 0 },
  definitions = {}, duplicateBindings = {}, duplicatePersistentKeys = {},
  invalidOwners = {}, leaseConflicts = {}, recovery = {}, staleBindings = {},
  componentSchemas = {}, stateSchemas = {}, knownRuntimeEntities = {},
  truncated = false
}`;

test('stale bindings independently degrade the entity Doctor status', async () => {
  const result = await runAnalyzer<string>(String.raw`
    local analyzer = SynexEntityDiagnosticsAnalyzer.create({
      config = { maxEntities = 100 },
      entityRuntime = { inspect = function() return nil end },
      extensionRegistry = {
        getComponentSchema = function() return nil end,
        getStateSchema = function() return nil end,
      },
      foundation = {
        isCallable = function(value) return type(value) == 'function' end,
        protect = function(_, handler)
          local ok, value = pcall(handler)
          return ok, value
        end,
      },
      ports = { getConvar = function(name) return name == 'onesync' and 'on' or 'strict' end },
      registry = { all = function() return {} end },
      state = { buckets = {}, playerMemberships = {} },
    })
    local snapshot = ${emptySnapshot}
    snapshot.staleBindings = { { entity_id = 'entity_deleted_001' } }
    local result = analyzer.analyze(snapshot, 10, {})
    assert(result.status == 'DEGRADED' and #result.staleBindings == 1)
    return result.status
  `);
  assert.equal(result, 'DEGRADED');
});

test('Doctor reports explicit runtime, identity, bucket, schema and spawn-rate findings', async () => {
  const result = await runAnalyzer<string>(String.raw`
    local records = {
      { entityId = 'entity_0001', generation = 2, handle = 11, netId = 101,
        bucket = 7, persistent = true, resourceOwner = 'synex_foreign' },
      { entityId = 'entity_0003', generation = 1, handle = 13, netId = 103,
        bucket = 0, persistent = true, resourceOwner = 'synex_world' },
      { entityId = 'entity_runtime_only', generation = 1, handle = 12, netId = 102,
        bucket = 9, persistent = true, resourceOwner = 'synex_foreign' },
    }
    local byId = {}
    for _, record in ipairs(records) do byId[record.entityId] = record end
    local analyzer = SynexEntityDiagnosticsAnalyzer.create({
      config = { maxEntities = 100 },
      entityRuntime = {
        inspect = function(record)
          if record.entityId == 'entity_0003' then return { bucket = 0 } end
          return nil, { code = 'STALE_ENTITY' }
        end,
      },
      extensionRegistry = {
        getComponentSchema = function(namespace)
          if namespace == 'synex_world.health' then
            return { schemaVersion = 1, ownerResource = 'synex_world' }
          end
          return nil
        end,
        getStateSchema = function() return nil end,
      },
      foundation = {
        isCallable = function(value) return type(value) == 'function' end,
        protect = function(_, handler)
          local ok, value = pcall(handler)
          return ok, value
        end,
      },
      ports = {
        doesEntityExist = function() return true end,
        getConvar = function(name) return name == 'onesync' and 'on' or 'strict' end,
        getResourceState = function() return 'started' end,
        networkGetNetworkIdFromEntity = function(handle)
          return handle == 13 and 999 or handle + 90
        end,
      },
      registry = {
        all = function() return records end,
        byEntityId = function(entityId) return byId[entityId] end,
      },
      state = {
        buckets = {
          [7] = { resourceOwner = 'synex_world', entities = {
            entity_0001 = true, ghost_entity = true,
          } },
          [9] = { resourceOwner = 'synex_world', entities = {
            entity_runtime_only = true,
          } },
        },
        playerMemberships = {
          [42] = { bucket = 7, resourceOwner = 'synex_foreign' },
        },
      },
    })
    local sampled = analyzer.runtimeEntityIds(2)
    assert(#sampled == 3 and sampled[3] == 'entity_runtime_only')
    local snapshot = {
      counts = { definitions = 5, spawn_outcomes = 4, failed_spawns = 1 },
      definitions = {
        { entity_id = 'entity_0001', generation = 1, status = 'active',
          resource_owner = 'synex_world', bucket_id = 7 },
        { entity_id = 'entity_0002', generation = 1, status = 'active',
          resource_owner = 'synex_world', bucket_id = 0 },
        { entity_id = 'entity_0003', generation = 1, status = 'active',
          resource_owner = 'synex_world', bucket_id = 0 },
        { entity_id = 'entity_0004', generation = 1, status = 'failed',
          resource_owner = 'synex_world', bucket_id = 0 },
      },
      knownRuntimeEntities = {
        { entity_id = 'entity_0001' }, { entity_id = 'entity_0003' },
      },
      sampledRuntimeEntityIds = {
        'entity_0001', 'entity_0003', 'entity_runtime_only',
      },
      componentSchemas = {
        { entity_id = 'entity_0003', component_namespace = 'synex_world.health',
          owner_resource = 'synex_world', schema_version = 2 },
      },
      stateSchemas = {
        { entity_id = 'entity_0003', state_key = 'synex_world.locked',
          owner_resource = 'synex_world', schema_version = 1 },
      },
      duplicateBindings = {}, duplicatePersistentKeys = {}, invalidOwners = {},
      leaseConflicts = {}, recovery = {}, staleBindings = {}, truncated = false,
      schemaInspectionTruncated = true,
    }
    local result = analyzer.analyze(snapshot, 10, {})
    assert(result.status == 'DEGRADED')
    assert(#result.generationMismatches == 1)
    assert(#result.staleMappings == 1)
    assert(#result.netIdMismatches == 1)
    assert(#result.runtimeOrphans == 1)
    assert(#result.bucketOwnerConflicts == 4)
    assert(#result.componentSchemaMismatches == 1)
    assert(result.componentSchemaMismatches[1].code == 'COMPONENT_SCHEMA_MISMATCH')
    assert(#result.stateSchemaMismatches == 1)
    assert(result.stateSchemaMismatches[1].code == 'STATE_SCHEMA_NOT_REGISTERED')
    assert(result.schemaInspectionTruncated == true)
    assert(result.spawnFailureRate.failures == 1
      and result.spawnFailureRate.observations == 4
      and result.spawnFailureRate.rate == 0.25)
    local bounded = analyzer.analyze(snapshot, 2, {})
    assert(#bounded.bucketOwnerConflicts <= 2
      and #bounded.componentSchemaMismatches <= 2
      and bounded.bucketInspectionTruncated == true)
    return result.status .. ':' .. tostring(#result.bucketOwnerConflicts)
  `);
  assert.equal(result, 'DEGRADED:4');
});

test('Doctor repository additions remain bounded and read-only', async () => {
  const repository = await readFile(path.join(
    resource, 'server', 'authority_diagnostics_repository.lua'), 'utf8');
  assert.doesNotMatch(repository, /\b(?:UPDATE|INSERT|DELETE)\b/iu);
  assert.match(repository, /componentSchemas = transaction\.many/iu);
  assert.match(repository, /stateSchemas = transaction\.many/iu);
  assert.match(repository, /#values > 51/iu);
  assert.match(repository, /runtimeEntityIds/iu);
});
