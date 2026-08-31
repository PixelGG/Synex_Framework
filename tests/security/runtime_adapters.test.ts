import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';

const root = process.cwd();
const files = [
  'resources/synex_security/shared/limits.lua',
  'resources/synex_security/shared/validation.lua',
  'resources/synex_security/server/runtime_adapters.lua',
] as const;

async function run<T>(source: string): Promise<T> {
  const engine = await new LuaFactory().createEngine();
  try {
    for (const file of files) {
      await engine.doString(await readFile(path.join(root, file), 'utf8'));
    }
    return await engine.doString(source) as T;
  } finally {
    engine.global.close();
  }
}

test('runtime adapters expose only native-owned player state and lifecycle context', async () => {
  const result = await run<Record<string, unknown>>(`
    local clock, ped, dead, bucket = 1000, 10, false, 0
    local adapter = SynexSecurityRuntimeAdapters.create({
      now = function() return clock end,
      ports = {
        getPlayerPed = function() return ped end,
        doesEntityExist = function() return true end,
        isEntityDead = function() return dead end,
        getEntityModel = function() return -1 end,
        getEntityMaxHealth = function() return 250 end,
      },
    })
    local session = { source = 7, sourceGeneration = 2 }
    local expected = adapter.expectedPlayerState(session)
    local first = adapter.movementContext(session, bucket)
    clock, dead = 1100, true
    adapter.movementContext(session, bucket)
    clock, dead, ped, bucket = 1200, false, 11, 5
    local respawn = adapter.movementContext(session, bucket)
    return {
      model = expected.model, health = expected.maximumHealth,
      noWeaponAuthority = expected.weapon == nil,
      firstSpawn = first.spawning,
      respawn = respawn.respawning,
      bucketTransition = respawn.instanceTransition,
    }
  `);
  assert.deepEqual(result, {
    model: 4294967295, health: 250, noWeaponAuthority: true,
    firstSpawn: true, respawn: true, bucketTransition: true,
  });
});

test('spawn provenance is bounded, exact, expiring, and bucket-aware', async () => {
  const result = await run<Record<string, unknown>>(`
    local clock = 1000
    local adapter = SynexSecurityRuntimeAdapters.create({
      now = function() return clock end, intentTtlMs = 500, maximumIntents = 16,
    })
    assert(adapter.recordSpawnIntent({ caller = 'synex_entities', request = {
      model = -1, entityType = 'vehicle', bucket = 7,
    }}))
    local unmatched = adapter.authorizeEntity({ creator = 0, model = 5,
      entityType = 2, bucket = 7 })
    local matched = adapter.authorizeEntity({ creator = 0, model = 4294967295,
      entityType = 2, bucket = 9 })
    assert(adapter.recordSpawnIntent({ caller = 'synex_entities', request = {
      model = 10, entityType = 'object', bucket = 0,
    }}))
    clock = 2000
    local expired = adapter.authorizeEntity({ creator = 0, model = 10,
      entityType = 3, bucket = 0 })
    return { unmatched = unmatched == nil, expired = expired == nil,
      resource = matched.authorityResource, targetBucket = matched.targetBucket,
      noSynchronousBucketFence = matched.expectedBucket == nil,
      deterministic = matched.deterministic, matched = matched.provenanceMatched }
  `);
  assert.deepEqual(result, {
    unmatched: true, expired: true, resource: 'synex_entities',
    targetBucket: 7, noSynchronousBucketFence: true,
    deterministic: true, matched: true,
  });
});

test('bucket observations never invent lockdown authority', async () => {
  const result = await run<Record<string, unknown>>(`
    local adapter = SynexSecurityRuntimeAdapters.create({ now = function() return 1 end })
    assert(adapter.observeBucket(4))
    assert(adapter.observeDomainEvent({ bucket = {
      id = 2, entityLockdown = 'strict', managed = true,
    }}))
    local buckets = adapter.buckets()
    return { first = buckets[1].id, firstMode = buckets[1].mode,
      firstControlled = buckets[1].controlled, second = buckets[2].id,
      secondMode = buckets[2].mode, secondControlled = buckets[2].controlled }
  `);
  assert.deepEqual(result, {
    first: 2, firstMode: 'strict', firstControlled: true,
    second: 4, secondMode: 'unknown', secondControlled: false,
  });
});

test('bucket observation memory has deterministic capacity eviction', async () => {
  const result = await run<Record<string, unknown>>(`
    local clock = 0
    local adapter = SynexSecurityRuntimeAdapters.create({
      now = function() clock = clock + 1 return clock end,
      maximumBuckets = 32,
    })
    for id = 0, 63 do assert(adapter.observeBucket(id)) end
    local buckets = adapter.buckets()
    return { count = #buckets, first = buckets[1].id, last = buckets[#buckets].id }
  `);
  assert.deepEqual(result, { count: 32, first: 32, last: 63 });
});

test('default Cfx policy is explicit and risk-off', async () => {
  const config = JSON.parse(await readFile(path.join(root,
    'resources/synex_security/config/default.json'), 'utf8'));
  assert.deepEqual(config.cfxPolicy.deniedModels, []);
  assert.deepEqual(config.cfxPolicy.deniedExplosions, []);
  assert.ok(Object.values(config.cfxPolicy.burstMitigation)
    .every((value) => value === false));
  assert.deepEqual(config.cfxPolicy.cancellation, {
    startProjectileEvent: { supported: false, liveVerified: false },
    ptFxEvent: { supported: false, liveVerified: false },
  });
});
