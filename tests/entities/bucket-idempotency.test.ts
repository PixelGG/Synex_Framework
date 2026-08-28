import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';

const resourceRoot = path.join(process.cwd(), 'resources', 'synex_entities');

test('bucket v2 creation, movement and destruction replay through durable Core idempotency', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    const [idempotency, lifecycle, service] = await Promise.all([
      readFile(path.join(resourceRoot, 'server', 'bucket_idempotency.lua'), 'utf8'),
      readFile(path.join(resourceRoot, 'server', 'bucket_lifecycle.lua'), 'utf8'),
      readFile(path.join(resourceRoot, 'server', 'bucket_service.lua'), 'utf8'),
    ]);
    await engine.doString(idempotency);
    await engine.doString(lifecycle);
    await engine.doString(service);
    const result = await engine.doString(String.raw`
      local buckets, memberships = {}, {}
      local receipts, operationsSeen = {}, {}
      local generationCalls, moveCalls = 0, 0
      local connected = true
      local routes = { [41] = 0 }

      local function requestFingerprint(value)
        local request = value.request or {}
        local capacity = request.capacity or {}
        return table.concat({
          tostring(value.caller), tostring(value.version),
          tostring(request.bucket), tostring(request.bucketGeneration),
          tostring(request.generation), tostring(request.profile),
          tostring(request.purpose), tostring(request.source),
          tostring(capacity.maxPlayers), tostring(capacity.maxEntities),
        }, '|')
      end

      local idempotency = {
        run = function(operation, key, request, handler)
          operationsSeen[#operationsSeen + 1] = operation
          local namespace = operation .. ':' .. key
          local fingerprint = requestFingerprint(request)
          local receipt = receipts[namespace]
          if receipt then
            if receipt.fingerprint ~= fingerprint then
              return nil, { code = 'IDEMPOTENCY_CONFLICT', retryable = false }
            end
            return receipt.value
          end
          local value, operationError = handler()
          if value == nil then return nil, operationError end
          receipts[namespace] = { fingerprint = fingerprint, value = value }
          return value
        end,
      }
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
          if not ok then return false, nil, first end
          return true, first, second
        end,
        setHealth = function() end,
        tableCount = function(value)
          local count = 0
          for _ in pairs(value) do count = count + 1 end
          return count
        end,
        takeRateLimit = function() return true end,
        withOwnerMutation = function(_, _, handler) return handler() end,
      }
      local policy = {
        isExpired = function() return false end,
        normalizeCreate = function(request, context)
          if type(request) ~= 'table' then
            return nil, { code = 'INVALID_ARGUMENT' }
          end
          if context.version == '1.0.0' then
            return { capacity = { maxPlayers = 8, maxEntities = 8 },
              lockdown = 'strict', populationEnabled = false,
              profile = 'isolated_strict', purpose = request.purpose or 'unspecified' }
          end
          if request.profile ~= 'session' or type(request.purpose) ~= 'string' then
            return nil, { code = 'INVALID_ARGUMENT' }
          end
          return { capacity = { maxPlayers = 8, maxEntities = 8 },
            lockdown = 'strict', populationEnabled = false,
            profile = request.profile, purpose = request.purpose }
        end,
        snapshot = function(bucket)
          return {
            bucket = { bucket = bucket.id, generation = bucket.generation },
            capacity = { maxEntities = bucket.maxEntities, maxPlayers = bucket.maxPlayers },
            createdAt = bucket.createdAt, entities = 0, health = bucket.health,
            lockdown = bucket.lockdown, ownerResource = bucket.resourceOwner,
            players = 0, populationEnabled = bucket.populationEnabled,
            profile = bucket.profile, purpose = bucket.purpose,
          }
        end,
      }
      local operations = SynexEntityBucketOperations.create({
        authorityRepository = {},
        config = { bucketMin = 1000, bucketMax = 1099, maxBuckets = 16,
          maxOwnerBuckets = 8, bucketCleanupTimeoutMs = 5000 },
        coreRef = { value = {
          Idempotency = idempotency,
          Ids = { next = function()
            generationCalls = generationCalls + 1
            return 'bucket_generation_' .. tostring(generationCalls)
          end },
          Players = { getBySource = function(source)
            if not connected then return nil end
            return { id = 'session_00000001', source = source, sourceGeneration = 1 }
          end },
        } },
        entityRuntime = {
          resolveBucket = function(bucket, generation, owner)
            if bucket == 0 then return { id = 0, generation = 0, resourceOwner = owner } end
            local value = buckets[bucket]
            if not value then return nil, { code = 'BUCKET_NOT_FOUND' } end
            if value.generation ~= generation then return nil, { code = 'STALE_BUCKET' } end
            if value.resourceOwner ~= owner then return nil, { code = 'FOREIGN_BUCKET' } end
            return value
          end,
        },
        foundation = foundation,
        getAuthority = function() return nil end,
        lanes = {
          entityKey = function(value) return 'entity:' .. value end,
          with = function(_, _, _, handler) return handler() end,
        },
        observability = {
          audit = function() end, before = function() return true end,
          event = function() end, gauge = function() end,
          increment = function() end, lifecycle = function() end,
        },
        policy = policy,
        ports = {
          getGameTimer = function() return 100 end,
          getPlayerName = function() return connected and 'Player' or nil end,
          getPlayerRoutingBucket = function(source) return routes[source] end,
          setPlayerRoutingBucket = function(source, bucket)
            moveCalls = moveCalls + 1
            routes[source] = bucket
          end,
          setRoutingBucketEntityLockdownMode = function() end,
          setRoutingBucketPopulationEnabled = function() end,
        },
        registry = {
          forBucket = function() return {} end,
        },
        state = { buckets = buckets, playerMemberships = memberships },
        validation = {
          validateBucketGeneration = function(value) return value end,
          validateBucketReference = function(bucket, generation)
            if type(bucket) ~= 'number' or type(generation) ~= 'string' then
              return nil, { code = 'INVALID_ARGUMENT' }
            end
            return { id = bucket, generation = generation }
          end,
        },
      })

      local request = { profile = 'session', purpose = 'world:instance' }
      local missing, missingError = operations.create(request, {
        caller = 'synex_world', version = '2.0.0'
      })
      assert(missing == nil and missingError.code == 'INVALID_ARGUMENT')
      local invalid, invalidError = operations.create(request, {
        caller = 'synex_world', idempotencyKey = 'short', version = '2.0.0'
      })
      assert(invalid == nil and invalidError.code == 'INVALID_ARGUMENT')

      local context = { caller = 'synex_world',
        idempotencyKey = 'world-create-instance-0001', version = '2.0.0' }
      local created = assert(operations.create(request, context))
      local bucketId, generation = created.bucket.bucket, created.bucket.generation
      -- Simulate a response that was committed downstream but lost upstream.
      local replay = assert(operations.create(request, context))
      assert(replay.bucket.bucket == bucketId and replay.bucket.generation == generation)
      assert(generationCalls == 1)

      local conflict, conflictError = operations.create({
        profile = 'session', purpose = 'world:other'
      }, context)
      assert(conflict == nil and conflictError.code == 'IDEMPOTENCY_CONFLICT')

      local foreignContext = { caller = 'synex_fixture',
        idempotencyKey = context.idempotencyKey, version = '2.0.0' }
      local foreign = assert(operations.create(request, foreignContext))
      assert(foreign.bucket.bucket ~= bucketId
        and foreign.ownerResource == 'synex_fixture' and generationCalls == 2)
      assert(operationsSeen[1] ~= operationsSeen[4]
        and operationsSeen[1]:match('^bc%.[a-z0-9]+$') ~= nil
        and operationsSeen[4]:match('^bc%.[a-z0-9]+$') ~= nil)

      local longCaller = 'synex_' .. string.rep('a', 27) .. '__' .. string.rep('b', 29)
      assert(#longCaller == 64)
      local long = assert(operations.create(request, {
        caller = longCaller, idempotencyKey = 'world-create-long-caller-01',
        version = '2.0.0'
      }))
      assert(long.ownerResource == longCaller and #operationsSeen[5] <= 64
        and operationsSeen[5]:match('^bc%.[a-z0-9]+$') ~= nil)

      local moveRequest = { bucket = bucketId, bucketGeneration = generation, source = 41 }
      local moveContext = { caller = 'synex_world',
        idempotencyKey = 'world-move-player-000001', version = '1.0.0' }
      assert(operations.movePlayer(moveRequest, moveContext))
      assert(moveCalls == 1 and routes[41] == bucketId)
      connected = false
      assert(operations.movePlayer(moveRequest, moveContext))
      assert(moveCalls == 1)
      local leaked, leakedError = operations.movePlayer(moveRequest, {
        caller = 'synex_fixture', idempotencyKey = moveContext.idempotencyKey,
        version = '1.0.0'
      })
      assert(leaked == nil and leakedError.code == 'NOT_FOUND')

      connected = true
      local destroyRequest = { bucket = bucketId, generation = generation }
      local destroyContext = { caller = 'synex_world',
        idempotencyKey = 'world-destroy-bucket-0001', version = '1.0.0' }
      local destroyed = assert(operations.destroy(destroyRequest, destroyContext))
      assert(destroyed.destroyed == true and buckets[bucketId] == nil)
      local destroyedReplay = assert(operations.destroy(destroyRequest, destroyContext))
      assert(destroyedReplay.destroyed == true)
      local destroyConflict, destroyConflictError = operations.destroy({
        bucket = bucketId, generation = 'bucket_generation_changed'
      }, destroyContext)
      assert(destroyConflict == nil
        and destroyConflictError.code == 'IDEMPOTENCY_CONFLICT')

      local legacy = assert(operations.create({ purpose = 'legacy' }, {
        caller = 'synex_world', version = '1.0.0'
      }))
      assert(type(legacy.bucket) == 'number' and generationCalls == 4)
      return tostring(bucketId) .. ':' .. tostring(moveCalls)
    `) as string;
    assert.equal(result, '1000:2');
  } finally {
    engine.global.close();
  }
});

test('only bucket create v2 advertises mandatory replay semantics', async () => {
  const collection = JSON.parse(await readFile(
    path.join(resourceRoot, 'contracts', 'entities.contracts.json'), 'utf8',
  )) as { contracts: Array<{ name: string; version: string; idempotent: boolean }> };
  const definitions = collection.contracts.filter(
    (candidate) => candidate.name === 'synex.entities.bucket.create',
  );
  assert.deepEqual(definitions.map(({ version, idempotent }) => ({ version, idempotent })), [
    { version: '1.0.0', idempotent: false },
    { version: '2.0.0', idempotent: true },
  ]);
});
