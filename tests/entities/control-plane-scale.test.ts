import assert from 'node:assert/strict';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';
import { source } from '../control/helpers.js';

test('Entity runtime and bucket Control pages use bounded maintained keyset indexes', async () => {
  const [validationSource, orderedIndexSource, registrySource, supportSource,
    inspectSource, providerSource] = await Promise.all([
    source('resources/synex_entities/shared/validation.lua'),
    source('resources/synex_entities/server/ordered_index.lua'),
    source('resources/synex_entities/server/registry.lua'),
    source('resources/synex_entities/server/control_provider_support.lua'),
    source('resources/synex_entities/server/control_provider_inspect.lua'),
    source('resources/synex_entities/server/control_provider.lua'),
  ]);
  assert.doesNotMatch(providerSource, /registry\.all\(\)/u);
  assert.doesNotMatch(providerSource, /pairs\(state\.buckets\)/u);

  const engine = await new LuaFactory().createEngine();
  try {
    const result = await engine.doString(`
      assert(load(${JSON.stringify(validationSource)}, '@validation'))()
      assert(load(${JSON.stringify(orderedIndexSource)}, '@ordered_index'))()
      assert(load(${JSON.stringify(registrySource)}, '@registry'))()
      assert(load(${JSON.stringify(supportSource)}, '@control_support'))()
      assert(load(${JSON.stringify(inspectSource)}, '@control_inspect'))()
      assert(load(${JSON.stringify(providerSource)}, '@control_provider'))()

      local state = SynexEntityRegistry.newState({ spatial = false })
      for ordinal = 1, 20000 do
        assert(state.entities.insert({
          bucket = 0,
          entityId = ('entity_%08d'):format(ordinal),
          entityType = 'object',
          generation = 1,
          model = 1,
          netId = ordinal,
          persistent = false,
          resourceOwner = 'synex_fixture',
          status = 'active',
        }))
        state.buckets[ordinal] = {
          entities = {}, generation = 1, id = ordinal, players = {},
          resourceOwner = 'synex_fixture',
        }
      end

      local runtimeSample, runtimeStats = state.entities.page(nil, 26)
      local bucketSample, bucketStats = state.bucketIndex.page(nil, 26)
      assert(#runtimeSample == 26 and runtimeStats.materialized == 26
        and runtimeStats.visited == 26 and runtimeStats.total == 20000)
      assert(#bucketSample == 26 and bucketStats.materialized == 26
        and bucketStats.visited == 26 and bucketStats.total == 20000)

      state.entities.all = function() error('runtime full scan is forbidden') end
      getmetatable(state.buckets).__pairs = function()
        error('bucket full scan is forbidden')
      end

      local operations
      local provider = SynexEntityControlProvider.create({
        authorityRepository = {},
        bucketPolicy = { snapshot = function(bucket)
          return { generation = bucket.generation, id = bucket.id }
        end },
        config = {},
        coreRef = { value = { ownerEpoch = 1 } },
        database = {},
        foundation = {
          failure = function(code, message, retryable)
            return nil, { code = code, message = message, retryable = retryable == true }
          end,
          isCallable = function(value) return type(value) == 'function' end,
          reportUnexpected = function(_, caught) error(caught) end,
        },
        queryOperations = {},
        registry = state.entities,
        service = {},
        spawnAdmission = {},
        state = state,
      })
      assert(provider.register({ ControlProviders = { register = function(definition)
        operations = definition.operations
        return { namespace = definition.namespace }
      end } }))

      local runtimeFirst = assert(operations.list({
        view = 'runtime', limit = 25, filters = {}, sort = {},
      }, { traceId = 'runtime_scale_first' }))
      local runtimeNext = assert(operations.list({
        view = 'runtime', cursor = runtimeFirst.nextCursor,
        limit = 25, filters = {}, sort = {},
      }, { traceId = 'runtime_scale_next' }))
      local runtimeLast = assert(operations.list({
        view = 'runtime', cursor = 'entity_00019975',
        limit = 25, filters = {}, sort = {},
      }, { traceId = 'runtime_scale_last' }))
      assert(#runtimeFirst.items == 25 and runtimeFirst.nextCursor == 'entity_00000025')
      assert(runtimeNext.items[1].entityId == 'entity_00000026')
      assert(#runtimeLast.items == 25 and runtimeLast.items[25].entityId == 'entity_00020000'
        and runtimeLast.hasMore == false and runtimeLast.nextCursor == nil)

      local bucketFirst = assert(operations.list({
        view = 'buckets', limit = 25, filters = {}, sort = {},
      }, { traceId = 'bucket_scale_first' }))
      local bucketNext = assert(operations.list({
        view = 'buckets', cursor = bucketFirst.nextCursor,
        limit = 25, filters = {}, sort = {},
      }, { traceId = 'bucket_scale_next' }))
      local bucketLast = assert(operations.list({
        view = 'buckets', cursor = '19975', limit = 25, filters = {}, sort = {},
      }, { traceId = 'bucket_scale_last' }))
      assert(#bucketFirst.items == 25 and bucketFirst.nextCursor == '25')
      assert(bucketNext.items[1].id == 26)
      assert(#bucketLast.items == 25 and bucketLast.items[25].id == 20000
        and bucketLast.hasMore == false and bucketLast.nextCursor == nil)

      assert(state.entities.remove('entity_00000100', 1))
      state.buckets[100] = nil
      local runtimeAfterRemoval = assert(state.entities.page('entity_00000098', 3))
      local bucketsAfterRemoval = assert(state.bucketIndex.page(98, 3))
      assert(runtimeAfterRemoval[1].entityId == 'entity_00000099'
        and runtimeAfterRemoval[2].entityId == 'entity_00000101'
        and runtimeAfterRemoval[3].entityId == 'entity_00000102')
      assert(bucketsAfterRemoval[1].id == 99 and bucketsAfterRemoval[2].id == 101
        and bucketsAfterRemoval[3].id == 102)

      local fresh = SynexEntityRegistry.newState({ spatial = false })
      local freshRuntime, freshRuntimeStats = fresh.entities.page(nil, 1)
      local freshBuckets, freshBucketStats = fresh.bucketIndex.page(nil, 1)
      assert(#freshRuntime == 0 and freshRuntimeStats.total == 0)
      assert(#freshBuckets == 0 and freshBucketStats.total == 0)
      return table.concat({ runtimeFirst.nextCursor, bucketFirst.nextCursor,
        runtimeStats.visited, bucketStats.visited }, ':')
    `);
    assert.equal(result, 'entity_00000025:25:26:26');
  } finally {
    engine.global.close();
  }
});
