import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';

const root = path.join(process.cwd(), 'resources', 'synex_entities', 'server');
const contractsPath = path.join(process.cwd(), 'resources', 'synex_entities',
  'contracts', 'entities.contracts.json');

async function luaSource(name: string): Promise<string> {
  return readFile(path.join(root, name), 'utf8');
}

test('bucket creation v2 extends rather than mutates the stable v1 contract', async () => {
  const collection = JSON.parse(await readFile(contractsPath, 'utf8')) as {
    contracts: Array<Record<string, any>>;
  };
  const definitions = collection.contracts.filter(
    (contract) => contract.name === 'synex.entities.bucket.create',
  );
  assert.deepEqual(definitions.map((contract) => contract.version), ['1.0.0', '2.0.0']);
  assert.deepEqual(Object.keys(definitions[0]!.input.properties), ['purpose']);
  assert.equal(definitions[0]!.network, 'none');
  const v2 = definitions[1]!;
  assert.equal(v2.network, 'none');
  assert.equal(v2.input.additionalProperties, false);
  assert.deepEqual(v2.input.properties.profile.enum,
    ['isolated_strict', 'session', 'character_selection', 'custom']);
  assert.equal(v2.input.properties.capacity.additionalProperties, false);
  assert.ok(v2.errors.includes('BUCKET_CAPACITY_EXCEEDED'));
});

test('public bucket failures are structured and closed by their contracts', async () => {
  const collection = JSON.parse(await readFile(contractsPath, 'utf8')) as {
    contracts: Array<Record<string, any>>;
  };
  const expected = new Map<string, string[]>([
    ['synex.entities.spawn@1.0.0', ['BUCKET_NOT_FOUND', 'FOREIGN_BUCKET']],
    ['synex.entities.materialize@1.0.0', ['BUCKET_NOT_FOUND', 'FOREIGN_BUCKET']],
    ['synex.entities.bucket.destroy@1.0.0', ['BUCKET_NOT_FOUND', 'FOREIGN_BUCKET']],
    ['synex.entities.bucket.move_entity@1.0.0', ['BUCKET_NOT_FOUND', 'FOREIGN_BUCKET']],
    ['synex.entities.bucket.move_player@1.0.0', ['BUCKET_NOT_FOUND', 'FOREIGN_BUCKET']],
    ['synex.entities.query.by_bucket@1.0.0', ['BUCKET_NOT_FOUND', 'STALE_BUCKET']],
    ['synex.entities.query.nearby@1.0.0', ['BUCKET_NOT_FOUND', 'STALE_BUCKET']],
    ['synex.entities.bucket.get@1.0.0', ['BUCKET_NOT_FOUND', 'STALE_BUCKET']],
  ]);
  for (const [key, errors] of expected) {
    const [name, version] = key.split('@');
    const contract = collection.contracts.find(
      (candidate) => candidate.name === name && candidate.version === version,
    );
    assert.ok(contract, `missing contract ${key}`);
    for (const error of errors) {
      assert.ok(contract.errors.includes(error), `${key} does not declare ${error}`);
    }
  }

  const [entityRuntime, bucketLifecycle, bucketService] = await Promise.all([
    luaSource('entity_runtime.lua'),
    luaSource('bucket_lifecycle.lua'),
    luaSource('bucket_service.lua'),
  ]);
  assert.match(entityRuntime, /failure\('BUCKET_NOT_FOUND', 'Routing bucket is not managed/u);
  assert.match(entityRuntime, /failure\('FOREIGN_BUCKET', 'Routing bucket belongs/u);
  assert.match(bucketLifecycle, /failure\('BUCKET_NOT_FOUND'/u);
  assert.match(bucketLifecycle, /failure\('FOREIGN_BUCKET'/u);
  assert.match(bucketService, /failure\('FOREIGN_BUCKET'/u);
});

test('bucket profiles, custom policy, capacities and expiry are closed and bounded', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await engine.doString(await luaSource('bucket_policy.lua'));
    const result = await engine.doString(String.raw`
      local foundation = {
        failure = function(code, message, retryable)
          return nil, { code = code, message = message, retryable = retryable }
        end,
        tableCount = function(value) local count = 0; for _ in pairs(value) do count = count + 1 end; return count end,
      }
      local policy = SynexEntityBucketPolicy.create({
        config = { maxBucketPlayers = 64, maxBucketEntities = 128 },
        foundation = foundation,
        utcNow = function() return '2026-08-26T12:00:00Z' end,
      })
      for _, profile in ipairs({ 'isolated_strict', 'session', 'character_selection' }) do
        local value = assert(policy.normalizeCreate({
          profile = profile, purpose = 'fixture'
        }, { version = '2.0.0' }))
        assert(value.lockdown == 'strict' and value.populationEnabled == false)
      end
      local custom = assert(policy.normalizeCreate({
        profile = 'custom', purpose = 'fixture', lockdown = 'relaxed',
        populationEnabled = true, capacity = { maxPlayers = 4, maxEntities = 8 },
        expiresAt = '2026-08-26T12:00:01Z'
      }, { version = '2.0.0' }))
      assert(custom.capacity.maxPlayers == 4 and custom.capacity.maxEntities == 8)
      local invalid, invalidError = policy.normalizeCreate({
        profile = 'custom', purpose = 'fixture', lockdown = 'strict',
        populationEnabled = false, capacity = { maxPlayers = 65, maxEntities = 8 }
      }, { version = '2.0.0' })
      assert(invalid == nil and invalidError.code == 'BUCKET_CAPACITY_EXCEEDED')
      local expired, expiredError = policy.normalizeCreate({
        profile = 'session', purpose = 'fixture', expiresAt = '2026-08-26T11:59:59Z'
      }, { version = '2.0.0' })
      assert(expired == nil and expiredError.code == 'INVALID_ARGUMENT')
      return custom.profile .. ':' .. custom.lockdown
    `) as string;
    assert.equal(result, 'custom:relaxed');
  } finally {
    engine.global.close();
  }
});

test('bucket moves are lease-fenced, capacity-bound, event-authorized and source-reuse-safe', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await engine.doString(await luaSource('bucket_idempotency.lua'));
    await engine.doString(await luaSource('bucket_lifecycle.lua'));
    await engine.doString(await luaSource('bucket_service.lua'));
    const result = await engine.doString(String.raw`
      local health, hooks, events, audits, persisted = {}, {}, {}, {}, {}
      local blockNextLane = false
      local failPersistence = false
      local entityBuckets, playerBuckets = { [101] = 0, [102] = 0 }, { [41] = 0 }
      local sessions = { [41] = { id = 'session_0001', source = 41, sourceGeneration = 1 } }
      local records = {
        entity_0001 = {
          authorityLeaseGeneration = 2, bucket = 0, entityId = 'entity_0001',
          entityType = 'vehicle', generation = 1, handle = 101, model = 1, netId = 11,
          persistent = true, resourceOwner = 'synex_fixture', resourceCycle = 1, version = 5,
        },
        entity_0002 = {
          bucket = 0, entityId = 'entity_0002', entityType = 'object', generation = 1,
          handle = 102, model = 2, netId = 12, persistent = false,
          resourceOwner = 'synex_fixture', resourceCycle = 1, version = 1,
        },
      }
      local state = { buckets = {}, playerMemberships = {} }
      local foundation = {
        currentOwnerCycle = function() return 1 end,
        failure = function(code, message, retryable, context)
          return nil, { code = code, message = message, retryable = retryable,
            traceId = context and context.traceId }
        end,
        getCaller = function(context) return context.caller end,
        isCallable = function(value) return type(value) == 'function' end,
        protect = function(_, handler)
          local ok, first, second = pcall(handler)
          if not ok then return false end
          return true, first, second
        end,
        setHealth = function(_, reason) health[#health + 1] = reason end,
        tableCount = function(value) local count = 0; for _ in pairs(value) do count = count + 1 end; return count end,
        takeRateLimit = function() return true end,
        withOwnerMutation = function(_, _, handler) return handler() end,
      }
      local registry = {
        all = function() local out = {}; for _, record in pairs(records) do out[#out + 1] = record end; return out end,
        byHandle = function(handle) for _, record in pairs(records) do if record.handle == handle then return record end end end,
        count = function() local total = 0; for _ in pairs(records) do total = total + 1 end; return total end,
        forBucket = function(bucket) local out = {}; for _, record in pairs(records) do if record.bucket == bucket then out[#out + 1] = record end end; return out end,
        remove = function(entityId) records[entityId] = nil; return true end,
      }
      local runtime = {
        assignBucket = function(record, bucket)
          if record.bucket > 0 and state.buckets[record.bucket] then state.buckets[record.bucket].entities[record.entityId] = nil end
          record.bucket = bucket
          if bucket > 0 then state.buckets[bucket].entities[record.entityId] = true end
          return true
        end,
        delete = function(record) records[record.entityId] = nil; return true end,
        inspect = function(record)
          if entityBuckets[record.handle] ~= record.bucket then return nil, { code = 'STALE_ENTITY' } end
          return { networkOwner = -1 }
        end,
        observeBucket = function(handle) return entityBuckets[handle] end,
        resolveBucket = function(bucket, generation, owner)
          if bucket == 0 then return { id = 0, generation = 0, resourceOwner = owner } end
          local target = state.buckets[bucket]
          if not target then return nil, { code = 'BUCKET_NOT_FOUND' } end
          if target.generation ~= generation then return nil, { code = 'STALE_BUCKET' } end
          if target.resourceOwner ~= owner then return nil, { code = 'FOREIGN_BUCKET' } end
          return target
        end,
        resolveOwned = function(request, owner)
          local record = records[request.entityId]
          if not record or record.generation ~= request.generation then return nil, { code = 'STALE_ENTITY' } end
          if record.resourceOwner ~= owner then return nil, { code = 'FORBIDDEN' } end
          return record, { networkOwner = -1 }
        end,
        snapshot = function(record) return { bucket = record.bucket, entityId = record.entityId,
          entityType = record.entityType, generation = record.generation, model = record.model,
          netId = record.netId, networkOwner = -1, persistent = record.persistent } end,
      }
      local lanes = {
        entityKey = function(id) return 'entity:' .. id end,
        with = function(_, _, _, handler)
          if blockNextLane then
            blockNextLane = false
            return nil, { code = 'CONCURRENT_MODIFICATION', retryable = true }
          end
          return handler()
        end,
      }
      local observability = {
        audit = function(action) audits[#audits + 1] = action; return true end,
        before = function(name) hooks[#hooks + 1] = name; return true end,
        event = function(name) events[#events + 1] = name; return true end,
        gauge = function() return true end,
        increment = function() return true end,
        lifecycle = function(action)
          events[#events + 1] = 'synex.entities.' .. action
          audits[#audits + 1] = 'entities.' .. action
          return true
        end,
      }
      local operations = SynexEntityBucketOperations.create({
        authorityRepository = { moveBucket = function(...)
          local args = { ... }; persisted[#persisted + 1] = args
          if failPersistence then
            return nil, { code = 'AUTHORITY_LEASE_CONFLICT', retryable = true }
          end
          assert(args[1] == 'entity_0001' and args[4] == 2)
          if args[6] == 77 then return { changed = true, version = 6 } end
          assert(args[6] == 0)
          return { changed = true, version = 7 }
        end },
        config = { bucketMin = 1000, bucketMax = 2000, maxBuckets = 10,
          maxOwnerBuckets = 4, bucketCleanupTimeoutMs = 5000 },
        coreRef = { value = {
          Ids = { next = function() return 'bucket_generation_01' end },
          Players = { getBySource = function(source) return sessions[source] end },
        } },
        entityRuntime = runtime, foundation = foundation,
        getAuthority = function() return { instanceId = 'instance_01' } end,
        lanes = lanes, observability = observability,
        policy = { normalizeCreate = function() error('not used') end,
          isExpired = function() return false end, snapshot = function(value) return value end },
        ports = {
          getGameTimer = function() return 100 end,
          getPlayerName = function() return 'Player' end,
          getPlayerRoutingBucket = function(source) return playerBuckets[source] end,
          setEntityRoutingBucket = function(handle, bucket) entityBuckets[handle] = bucket end,
          setPlayerRoutingBucket = function(source, bucket) playerBuckets[source] = bucket end,
          setRoutingBucketEntityLockdownMode = function() end,
          setRoutingBucketPopulationEnabled = function() end,
        },
        registry = registry, state = state,
        validation = {
          validateBucketGeneration = function(value) return value end,
          validateBucketReference = function(bucket, generation) return { id = bucket, generation = generation } end,
        },
      })
      state.buckets[77] = {
        id = 77, generation = 'bucket_gen_77', entities = {}, players = {},
        maxEntities = 1, maxPlayers = 1, resourceOwner = 'synex_fixture',
        resourceCycle = 1, lockdown = 'strict', populationEnabled = false,
        profile = 'session', purpose = 'fixture', createdAt = '2026-08-26T12:00:00Z',
      }
      state.buckets[78] = {
        id = 78, generation = 'bucket_gen_78', entities = {}, players = {},
        maxEntities = 1, maxPlayers = 1, resourceOwner = 'synex_foreign',
        resourceCycle = 1, lockdown = 'strict', populationEnabled = false,
        profile = 'session', purpose = 'foreign', createdAt = '2026-08-26T12:00:00Z',
      }
      local context = { caller = 'synex_fixture', traceId = 'trace_bucket', version = '2.0.0' }
      local missing, missingError = operations.moveEntity({
        entityId = 'entity_0001', generation = 1,
        bucket = 79, bucketGeneration = 'bucket_gen_79'
      }, context)
      assert(missing == nil and missingError.code == 'BUCKET_NOT_FOUND')
      local foreign, foreignError = operations.moveEntity({
        entityId = 'entity_0001', generation = 1,
        bucket = 78, bucketGeneration = 'bucket_gen_78'
      }, context)
      assert(foreign == nil and foreignError.code == 'FOREIGN_BUCKET')
      local moved = assert(operations.moveEntity({
        entityId = 'entity_0001', generation = 1,
        bucket = 77, bucketGeneration = 'bucket_gen_77'
      }, context))
      assert(moved.bucket == 77 and records.entity_0001.version == 6 and #persisted == 1)
      assert(hooks[1] == 'synex.entities.before_entity_bucket_move')
      assert(events[1] == 'synex.entities.bucket.changed')
      assert(operations.observeEntityBucketChange(101, 77, context) == true)
      entityBuckets[101] = 99
      assert(operations.observeEntityBucketChange(101, 99, context) == true)
      assert(entityBuckets[101] == 77 and records.entity_0001.bucket == 77)
      blockNextLane = true
      local concurrent, concurrentError = operations.moveEntity({
        entityId = 'entity_0002', generation = 1,
        bucket = 77, bucketGeneration = 'bucket_gen_77'
      }, context)
      assert(concurrent == nil and concurrentError.code == 'CONCURRENT_MODIFICATION')
      local denied, deniedError = operations.moveEntity({
        entityId = 'entity_0002', generation = 1,
        bucket = 77, bucketGeneration = 'bucket_gen_77'
      }, context)
      assert(denied == nil and deniedError.code == 'BUCKET_CAPACITY_EXCEEDED')

      assert(operations.movePlayer({ source = 41, bucket = 77,
        bucketGeneration = 'bucket_gen_77' }, context))
      assert(state.playerMemberships[41].sessionId == 'session_0001'
        and state.playerMemberships[41].sourceGeneration == 1)
      assert(operations.observePlayerBucketChange(41, 77, context))
      sessions[41] = { id = 'session_0002', source = 41, sourceGeneration = 2 }
      playerBuckets[41] = 88
      assert(operations.observePlayerBucketChange(41, 88, context))
      assert(playerBuckets[41] == 0 and state.playerMemberships[41] == nil)
      assert(operations.movePlayer({ source = 41, bucket = 77,
        bucketGeneration = 'bucket_gen_77' }, context))
      assert(state.playerMemberships[41].sessionId == 'session_0002')
      assert(operations.playerDropped(41, context) == false)
      assert(state.playerMemberships[41].sessionId == 'session_0002')
      failPersistence = true
      local failed, failedError = operations.moveEntity({
        entityId = 'entity_0001', generation = 1,
        bucket = 0, bucketGeneration = 0
      }, context)
      assert(failed == nil and failedError.code == 'AUTHORITY_LEASE_CONFLICT')
      assert(records.entity_0001.bucket == 77 and entityBuckets[101] == 77
        and records.entity_0001.version == 6)
      failPersistence = false
      records.entity_0002.bucket = 77
      entityBuckets[102] = 77
      state.buckets[77].entities.entity_0002 = true
      local destroyed = assert(operations.destroy({
        bucket = 77, generation = 'bucket_gen_77'
      }, context))
      assert(destroyed.destroyed == true and state.buckets[77] == nil)
      assert(records.entity_0001.bucket == 0 and records.entity_0001.version == 7)
      assert(records.entity_0002 == nil and playerBuckets[41] == 0)
      return tostring(#audits) .. ':' .. tostring(#events)
    `) as string;
    assert.match(result, /^[1-9][0-9]*:[1-9][0-9]*$/u);
  } finally {
    engine.global.close();
  }
});

test('persistent bucket storage requires the complete authority and optimistic fence', async () => {
  const repository = await luaSource('authority_repository.lua');
  const move = repository.slice(
    repository.indexOf('function repository.moveBucket'),
    repository.indexOf('function repository.release'),
  );
  assert.match(move, /`entity_id` = \? AND `generation` = \? AND `version` = \?/u);
  assert.match(move, /`server_scope` = \? AND `instance_id` = \?/u);
  assert.match(move, /`authority_token` = \? AND `resource_epoch` = \?/u);
  assert.match(move, /`lease_generation` = \? AND `lease_state` = 'active'/u);
  assert.match(move, /`lease_until` > CURRENT_TIMESTAMP\(6\) FOR UPDATE/u);
  assert.match(move, /AND `status` = 'active' AND `resource_owner` = \?/u);
  assert.match(move, /AUTHORITY_LEASE_CONFLICT/u);
  assert.match(move, /CONCURRENT_MODIFICATION/u);
  assert.doesNotMatch(move, /repository\.updateBucket/u);
});

test('bucket destruction fences in-flight spawn reservations before cleanup', async () => {
  const [admission, lifecycle] = await Promise.all([
    luaSource('spawn_admission.lua'),
    luaSource('bucket_lifecycle.lua'),
  ]);
  assert.match(admission, /bucket\.destroying/u);
  assert.match(admission, /bucket\.pendingSpawns\s*=\s*\(bucket\.pendingSpawns or 0\) \+ 1/u);
  assert.match(admission, /bucket\.pendingSpawns\s*=\s*math\.max\(0,/u);
  assert.match(lifecycle, /\(bucket\.pendingSpawns or 0\) > 0/u);
  assert.match(lifecycle, /Routing bucket spawn reservations are still active/u);
});
