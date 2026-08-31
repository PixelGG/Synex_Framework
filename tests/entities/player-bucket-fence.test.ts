import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';

const fencePath = path.join(
  process.cwd(), 'resources', 'synex_entities', 'server', 'player_bucket_fence.lua',
);

test('entity service resolves only session- and generation-fenced player buckets', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await engine.doString(await readFile(fencePath, 'utf8'));
    const result = await engine.doString(String.raw`
      local session = { id = 'session_0001', source = 41, sourceGeneration = 9,
        characterId = 'character_0001', state = 'ACTIVE' }
      local actualBucket = 77
      local state = {
        buckets = { [77] = { generation = 'bucket_generation_77', destroying = false,
          entities = {}, players = { [41] = true } } },
        playerMemberships = { [41] = { bucket = 77,
          generation = 'bucket_generation_77', sessionId = 'session_0001',
          sourceGeneration = 9 } },
      }
      local foundation = {
        failure = function(code, message, retryable, context)
          return nil, { code = code, message = message, retryable = retryable == true,
            traceId = context and context.traceId }
        end,
        getCaller = function() return 'synex_interact' end,
        takeRateLimit = function() return true end,
        protect = function(_, handler)
          local values = table.pack(pcall(handler))
          return table.unpack(values, 1, values.n)
        end,
        isCallable = function(value)
          return type(value) == 'function' or type(value) == 'table'
            and getmetatable(value) and type(getmetatable(value).__call) == 'function'
        end,
        tableCount = function(value)
          local count = 0; for _ in pairs(value or {}) do count = count + 1 end
          return count
        end,
      }
      local validation = {
        isPlainTable = function(value)
          return type(value) == 'table' and getmetatable(value) == nil
        end,
        isInteger = function(value, minimum, maximum)
          return type(value) == 'number' and math.type(value) == 'integer'
            and value >= (minimum or -9007199254740991)
            and value <= (maximum or 9007199254740991)
        end,
        token = function(value, minimum, maximum)
          return type(value) == 'string' and #value >= minimum and #value <= maximum
            and value:match('^[A-Za-z0-9][A-Za-z0-9_.:%-]*$') ~= nil
        end,
      }
      local fence = SynexEntityPlayerBucketFence.create({
        coreRef = { value = { Players = {
          getBySource = function(source)
            assert(source == 41)
            return session
          end,
        } } }, validation = validation, foundation = foundation, state = state,
        ports = { getPlayerRoutingBucket = function() return actualBucket end },
      })
      local request = { source = 41, sessionId = 'session_0001', sourceGeneration = 9 }
      local context = { caller = 'synex_interact', traceId = 'trace_bucket_fence_001' }
      local managed = assert(fence.resolve(request, context))
      assert(managed.bucket.bucket == 77
        and managed.bucket.generation == 'bucket_generation_77'
        and managed.sourceGeneration == 9)

      session = { id = 'session_0002', source = 41, sourceGeneration = 10,
        characterId = 'character_0002', state = 'ACTIVE' }
      local stale, staleError = fence.resolve(request, context)
      assert(stale == nil and staleError.code == 'STALE_RESOURCE')

      session = { id = 'session_0001', source = 41, sourceGeneration = 9,
        characterId = 'character_0001', state = 'ACTIVE' }
      state.playerMemberships[41].generation = 'wrong_generation'
      local wrongBucket, wrongBucketError = fence.resolve(request, context)
      assert(wrongBucket == nil and wrongBucketError.code == 'STALE_BUCKET')

      actualBucket, state.playerMemberships[41] = 0, nil
      local default = assert(fence.resolve(request, context))
      assert(default.bucket.bucket == 0 and default.bucket.generation == 0)
      return table.concat({ managed.bucket.bucket, staleError.code,
        wrongBucketError.code, default.bucket.bucket }, ':')
    `) as string;
    assert.equal(result, '77:STALE_RESOURCE:STALE_BUCKET:0');
  } finally {
    engine.global.close();
  }
});

test('entity service exposes the fence only under the existing query capability', async () => {
  const runtime = await readFile(path.join(
    process.cwd(), 'resources', 'synex_entities', 'server', 'runtime.lua',
  ), 'utf8');
  assert.match(runtime,
    /getPlayerBucketFence = publicMethod\(service\.getPlayerBucketFence\)/u);
  assert.match(runtime, /getPlayerBucketFence = 'synex\.entities\.query'/u);
});
