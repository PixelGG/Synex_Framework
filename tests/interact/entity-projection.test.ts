import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';

const root = process.cwd();

async function projectionEngine() {
  const engine = await new LuaFactory().createEngine();
  for (const relativePath of [
    'resources/synex_interact/shared/limits.lua',
    'resources/synex_interact/shared/validation.lua',
    'resources/synex_interact/server/target_selector.lua',
    'resources/synex_interact/server/entity_projection.lua',
  ]) {
    await engine.doString(await readFile(path.join(root, relativePath), 'utf8'));
  }
  return engine;
}

test('server entity discovery projects only selected managed entities behind all fences', async () => {
  const engine = await projectionEngine();
  try {
    const result = await engine.doString(String.raw`
      local session = { id = 'session_0001', source = 41, sourceGeneration = 7,
        characterId = 'character_0001', state = 'ACTIVE' }
      local queryRequest
      local definitions = {
        { object = { binding = { type = 'entityRef',
          entityId = 'entity_exact_001', generation = 3 } } },
        { object = { binding = { type = 'entityArchetype',
          archetype = 'synex.vehicle' } } },
        { object = { binding = { type = 'entityBone', model = 900, bone = 'boot' } } },
        { object = { binding = { type = 'entityArchetype',
          archetype = 'synex.combined', model = 700 } } },
      }
      local entities = {
        { entity = { entityId = 'entity_exact_001', generation = 3,
          entityType = 'object', model = 100, archetype = 'synex.prop',
          bucket = 77, materialized = true, netId = 11 } },
        { entity = { entityId = 'entity_arch_001', generation = 4,
          entityType = 'vehicle', model = 200, archetype = 'synex.vehicle',
          bucket = 77, materialized = true, netId = 12 } },
        { entity = { entityId = 'entity_model_001', generation = 5,
          entityType = 'vehicle', model = 900, archetype = 'synex.other',
          bucket = 77, materialized = true, netId = 13 } },
        { entity = { entityId = 'entity_other_001', generation = 6,
          entityType = 'ped', model = 333, archetype = 'synex.other',
          bucket = 77, materialized = true, netId = 14 } },
        { entity = { entityId = 'entity_partial_001', generation = 7,
          entityType = 'object', model = 701, archetype = 'synex.combined',
          bucket = 77, materialized = true, netId = 15 } },
      }
      local projection = SynexInteractEntityProjection.create({
        registry = {
          currentRevision = function() return 9 end,
          slotDefinitions = function() return definitions end,
        },
        getSession = function(source) assert(source == 41); return session end,
        actorSnapshot = function(source)
          assert(source == 41)
          return { position = { x = 0, y = 0, z = 0 }, bucket = 77 }
        end,
        getBucketFence = function(request)
          assert(request.source == 41 and request.sessionId == 'session_0001'
            and request.sourceGeneration == 7)
          return { source = 41, sessionId = 'session_0001', sourceGeneration = 7,
            bucket = { bucket = 77, generation = 'bucket_generation_77' } }
        end,
        queryNearby = function(request)
          queryRequest = request
          return { items = entities, truncated = true }
        end,
        inspectEntity = function(netId)
          return { bucket = 77, model = netId == 11 and 100
            or netId == 12 and 200 or netId == 13 and 900 or 333,
            entityType = netId == 11 and 'object' or netId == 14 and 'ped' or 'vehicle',
            position = { x = netId - 10, y = 0, z = 0 }, heading = 90 }
        end,
      })
      local context = { source = 41, sourceGeneration = 7, session = session,
        traceId = 'trace_entity_projection_001' }
      local snapshot = assert(projection.snapshot({ discoveryRevision = 9 }, context))
      assert(queryRequest.radius == SynexInteractLimits.maximumDiscoveryRadius
        and queryRequest.limit == SynexInteractLimits.maximumEntityProjection
        and queryRequest.bucket.bucket == 77
        and queryRequest.bucket.generation == 'bucket_generation_77'
        and queryRequest.filters.materialized == true)
      assert(snapshot.discoveryRevision == 9 and snapshot.sourceGeneration == 7
        and snapshot.bucket == 77 and snapshot.truncated == true
        and #snapshot.entities == 3)
      for _, entity in ipairs(snapshot.entities) do
        assert(entity.entityRef and entity.netId ~= 14 and entity.bucket == 77)
      end
      local stale, staleError = projection.snapshot({ discoveryRevision = 8 }, context)
      assert(stale == nil and staleError.code == 'INTERACT_DISCOVERY_STALE')
      return table.concat({ #snapshot.entities, snapshot.bucket,
        snapshot.projectionRevision, staleError.code }, ':')
    `) as string;
    assert.equal(result, '3:77:1:INTERACT_DISCOVERY_STALE');
  } finally {
    engine.global.close();
  }
});

test('entity selectors reject forged bones, ambient archetypes, and runtime identity drift', async () => {
  const engine = await projectionEngine();
  try {
    const result = await engine.doString(String.raw`
      local boneBinding = { type = 'entityBone', model = 900, bone = 'boot' }
      local managedTarget = { kind = 'entity', bone = 'boot',
        entityRef = { entityId = 'entity_exact_001', generation = 3 } }
      local forgedBone = SynexInteractValidation.copy(managedTarget)
      forgedBone.bone = 'door_dside_f'
      assert(SynexInteractTargetSelector.matchesTarget(
        boneBinding, 'fixture:bone', managedTarget))
      assert(not SynexInteractTargetSelector.matchesTarget(
        boneBinding, 'fixture:bone', forgedBone))
      assert(not SynexInteractTargetSelector.matchesAmbient(
        { type = 'entityArchetype', archetype = 'synex.vehicle' },
        { kind = 'ambient', netId = 17, model = 900 },
        { entityType = 'vehicle', model = 900 }))
      assert(not SynexInteractTargetSelector.matchesAmbient(
        boneBinding, { kind = 'ambient', netId = 17, model = 900, bone = 'boot' },
        { entityType = 'unknown', model = 900 }))
      assert(SynexInteractTargetSelector.matchesAmbient(
        boneBinding, { kind = 'ambient', netId = 17, model = 900, bone = 'boot' },
        { entityType = 'vehicle', model = 900 }))

      local session = { id = 'session_0001', source = 41, sourceGeneration = 7,
        characterId = 'character_0001', state = 'ACTIVE' }
      local runtimeType = 'vehicle'
      local projection = SynexInteractEntityProjection.create({
        registry = { currentRevision = function() return 1 end,
          slotDefinitions = function() return {} end },
        getSession = function() return session end,
        actorSnapshot = function()
          return { position = { x = 0, y = 0, z = 0 }, bucket = 77 }
        end,
        getBucketFence = function()
          return { source = 41, sessionId = 'session_0001', sourceGeneration = 7,
            bucket = { bucket = 77, generation = 'bucket_generation_77' } }
        end,
        queryNearby = function()
          return { truncated = false, items = {{ entity = {
            entityId = 'entity_exact_001', generation = 3, netId = 17,
            entityType = 'vehicle', model = 900, archetype = 'synex.vehicle',
            bucket = 77, materialized = true,
          } }} }
        end,
        inspectEntity = function()
          return { entityType = runtimeType, model = 900, bucket = 77,
            position = { x = 1, y = 0, z = 0 }, heading = 0 }
        end,
      })
      local context = { source = 41, sourceGeneration = 7, session = session,
        traceId = 'trace_entity_selector_001' }
      local resolved = assert(projection.resolveManaged(
        managedTarget.entityRef, 2.0, context))
      assert(SynexInteractTargetSelector.matchesManaged(
        { type = 'entityBone', model = 900, archetype = 'synex.vehicle', bone = 'boot' },
        managedTarget, resolved.entity))
      runtimeType = 'object'
      local stale, staleError = projection.resolveManaged(
        managedTarget.entityRef, 2.0, context)
      assert(stale == nil and staleError.code == 'INTERACT_TARGET_STALE')
      return table.concat({ resolved.entity.entityType, resolved.entity.archetype,
        staleError.code }, ':')
    `) as string;
    assert.equal(result, 'vehicle:synex.vehicle:INTERACT_TARGET_STALE');
  } finally {
    engine.global.close();
  }
});

test('server entity discovery aborts when source generation changes across the query', async () => {
  const engine = await projectionEngine();
  try {
    const result = await engine.doString(String.raw`
      local session = { id = 'session_0001', source = 5, sourceGeneration = 2,
        characterId = 'character_0001', state = 'ACTIVE' }
      local projection = SynexInteractEntityProjection.create({
        registry = { currentRevision = function() return 4 end,
          slotDefinitions = function() return {{ object = { binding = {
            type = 'entityArchetype', model = 10 } } }} end },
        getSession = function() return session end,
        actorSnapshot = function()
          return { position = { x = 0, y = 0, z = 0 }, bucket = 0 }
        end,
        getBucketFence = function()
          return { source = 5, sessionId = 'session_0001', sourceGeneration = 2,
            bucket = { bucket = 0, generation = 0 } }
        end,
        queryNearby = function()
          session = { id = 'session_0002', source = 5, sourceGeneration = 3,
            characterId = 'character_0002', state = 'ACTIVE' }
          return { items = {}, truncated = false }
        end,
        inspectEntity = function() return nil end,
      })
      local value, operationError = projection.snapshot({ discoveryRevision = 4 }, {
        source = 5, sourceGeneration = 2,
        session = { id = 'session_0001', sourceGeneration = 2,
          characterId = 'character_0001' }, traceId = 'trace_projection_stale_001',
      })
      assert(value == nil and operationError.code == 'INTERACT_LEASE_STALE')
      return operationError.code
    `) as string;
    assert.equal(result, 'INTERACT_LEASE_STALE');
  } finally {
    engine.global.close();
  }
});

test('entity projection source and contracts stay bounded and client-authority free', async () => {
  const [source, contracts] = await Promise.all([
    readFile(path.join(root,
      'resources/synex_interact/server/entity_projection.lua'), 'utf8'),
    readFile(path.join(root,
      'resources/synex_interact/contracts/interact.contracts.json'), 'utf8'),
  ]);
  assert.doesNotMatch(source, /GetGamePool|GlobalState|Player\([^)]*\)\.state/u);
  assert.match(source, /maximumEntityProjection/u);
  assert.match(source, /queryNearby/u);
  const collection = JSON.parse(contracts) as {
    contracts: Array<{ name: string; input: { properties: Record<string, unknown> } }>;
  };
  const contract = collection.contracts.find(
    (entry) => entry.name === 'synex.interact.discovery.entities',
  );
  assert.ok(contract);
  assert.deepEqual(Object.keys(contract.input.properties), ['discoveryRevision']);
});
