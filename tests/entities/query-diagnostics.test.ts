import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';

const resource = path.join(process.cwd(), 'resources', 'synex_entities');

async function source(relativePath: string): Promise<string> {
  return readFile(path.join(resource, relativePath), 'utf8');
}

async function runQuery<T>(assertions: string): Promise<T> {
  const engine = await new LuaFactory().createEngine();
  try {
    await engine.doString(await source('server/diagnostics_analyzer.lua'));
    await engine.doString(await source('server/query_service.lua'));
    return await engine.doString(assertions) as T;
  } finally {
    engine.global.close();
  }
}

test('owner, resource, and bucket queries merge durable definitions with live runtime views', async () => {
  const result = await runQuery<string>(String.raw`
    local calls = {}
    local definitions = {
      {
        entityId = 'entity_0001', generation = 4, entityType = 'vehicle',
        model = 100, bucket = 0, owner = { type = 'group', id = 'group_001' },
        persistent = true, persistencePolicy = 'persistent',
        resourceOwner = 'synex_vehicles', status = 'dormant'
      },
      {
        entityId = 'entity_0002', generation = 7, entityType = 'object',
        model = 200, bucket = 44, owner = { type = 'group', id = 'group_001' },
        persistent = true, persistencePolicy = 'owner_lifetime',
        resourceOwner = 'synex_world', status = 'active'
      }
    }
    local repository = {
      queryDefinitions = function(filter)
        calls[#calls + 1] = filter
        return { items = definitions }
      end,
      bindingFor = function(entityId)
        return { namespace = 'synex.test', ref = entityId }
      end,
    }
    local active = {
      archetype = nil, binding = { namespace = 'synex.test', ref = 'entity_0002' },
      bucket = 44, entityId = 'entity_0002', entityType = 'object', generation = 7,
      model = 200, netId = 22, owner = { type = 'group', id = 'group_001' },
      persistent = true, resourceOwner = 'synex_world', status = 'active', tags = {}
    }
    local service = SynexEntityQueryService.create({
      authorityRepository = repository,
      extensionRepository = {
        listTags = function()
          return { { tag = 'synex.test' } }
        end,
      },
      extensionRegistry = {
        getComponentSchema = function() return nil end,
        getStateSchema = function() return nil end,
      },
      foundation = {
        failure = function(code, message, retryable)
          return nil, { code = code, message = message, retryable = retryable }
        end,
        getCaller = function() return 'synex_control' end,
        takeRateLimit = function() return true end,
      },
      validation = {
        validateOwner = function(owner) return owner end,
        validateCaller = function(resource) return resource end,
        validatePosition = function(position) return position end,
        validateBucketReference = function(bucket, generation)
          return { id = bucket, generation = generation }
        end,
      },
      registry = {
        byEntityId = function(entityId, generation)
          if entityId == 'entity_0002' and generation == 7 then return active end
          return nil, { code = 'NOT_FOUND' }
        end,
      },
      entityRuntime = {
        inspect = function(record)
          assert(record == active)
          return { networkOwner = 12 }
        end,
      },
      bucketPolicy = { snapshot = function(bucket) return bucket end },
      state = { buckets = {
        [44] = { id = 44, generation = 'bucket_gen_44' }
      } },
      ports = {},
      config = {},
    })
    local context = { caller = 'synex_control', traceId = 'trace_query_merge_001' }
    local ownerPage = assert(service.byOwner({
      owner = { type = 'group', id = 'group_001' }, limit = 4,
      filters = { persistent = true, tags = { 'synex.test' } }
    }, context))
    assert(#ownerPage.items == 2 and ownerPage.truncated == false)
    assert(ownerPage.items[1].status == 'DORMANT'
      and ownerPage.items[1].materialized == false)
    assert(ownerPage.items[2].status == 'ACTIVE'
      and ownerPage.items[2].materialized == true
      and ownerPage.items[2].netId == 22)
    assert(calls[1].ownerType == 'group' and calls[1].ownerId == 'group_001')
    assert(calls[1].persistent == true and calls[1].limit <= 100)

    assert(service.byResource({ resource = 'synex_vehicles', limit = 2 }, context))
    assert(calls[2].resourceOwner == 'synex_vehicles')
    assert(service.byBucket({
      bucket = { bucket = 44, generation = 'bucket_gen_44' }, limit = 2
    }, context))
    assert(calls[3].bucket == 44)
    local missingPage, missingPageError = service.byBucket({
      bucket = { bucket = 45, generation = 'bucket_gen_45' }, limit = 2
    }, context)
    assert(missingPage == nil and missingPageError.code == 'BUCKET_NOT_FOUND')
    local missingNearby, missingNearbyError = service.nearby({
      position = { x = 0, y = 0, z = 0 }, radius = 10, limit = 2,
      bucket = { bucket = 45, generation = 'bucket_gen_45' }
    }, context)
    assert(missingNearby == nil and missingNearbyError.code == 'BUCKET_NOT_FOUND')
    local missingBucket, missingBucketError = service.bucketGet({
      bucket = { bucket = 45, generation = 'bucket_gen_45' }
    }, context)
    assert(missingBucket == nil and missingBucketError.code == 'BUCKET_NOT_FOUND')
    local invalid, invalidError = service.byOwner({
      owner = { type = 'group', id = 'group_001' }, limit = 2, smuggled = true
    }, context)
    assert(invalid == nil and invalidError.code == 'INVALID_ARGUMENT')
    return ownerPage.items[1].status .. ':' .. ownerPage.items[2].status
  `);
  assert.equal(result, 'DORMANT:ACTIVE');
});

test('entity inspection and diagnostics are bounded, redacted, and read-only', async () => {
  const result = await runQuery<string>(String.raw`
    local inspectCalls = {}
    local repository = {
      inspectEntity = function(entityId)
        inspectCalls[#inspectCalls + 1] = 'entity'
        return {
          binding = { namespace = 'synex.test', ref = 'vehicle_001' },
          checkpoint = { version = 2 },
          counts = { components = 1, states = 2, tags = 1 },
          definition = {
            entityId = entityId, generation = 3, entityType = 'vehicle', model = 100,
            bucket = 77, owner = { type = 'group', id = 'group_001' },
            persistent = true, resourceOwner = 'synex_vehicles', status = 'active'
          }
        }
      end,
      inspectAuthority = function()
        inspectCalls[#inspectCalls + 1] = 'authority'
        return {
          entity_id = 'entity_0001', server_scope = 'roleplay-main',
          instance_id = 'instance_001', authority_token = 'secret_fence_token',
          resource_epoch = 4, lease_generation = 9, lease_state = 'active',
          lease_live = 1, lease_until = '2026-08-26 18:00:00.000000', version = 5
        }
      end,
      inspectRecovery = function(_, limit)
        inspectCalls[#inspectCalls + 1] = 'recovery:' .. limit
        return { { recovery_id = 11, outcome = 'failed' } }
      end,
      diagnosticSnapshot = function(request, authority)
        assert(request.limit == 10 and request.recoveryAttemptThreshold == 3)
        assert(authority.instanceId == 'instance_001' and authority.resourceEpoch == 4)
        return {
          counts = {
            definitions = 95, active_bindings = 4, components = 5, states = 6,
            tags = 7, checkpoints = 8, live_leases = 2, recovery_history = 9
          },
          definitions = {
            {
              entity_id = 'entity_0001', generation = 3, status = 'active',
              resource_owner = 'synex_vehicles', bucket_id = 77
            },
            {
              entity_id = 'entity_0002', generation = 4, status = 'orphaned',
              resource_owner = 'synex_world', bucket_id = 0
            }
          },
          duplicateBindings = { { binding_namespace = 'synex.test', total = 2 } },
          duplicatePersistentKeys = {}, invalidOwners = {},
          leaseConflicts = { { entity_id = 'entity_0001' } },
          recovery = { { entity_id = 'entity_0002', recovery_attempt_count = 3 } },
          staleBindings = {}, truncated = false,
        }
      end,
    }
    local service = SynexEntityQueryService.create({
      authorityRepository = repository,
      extensionRepository = {
        listTags = function() return { { tag = 'synex.test' } } end,
      },
      extensionRegistry = {
        getComponentSchema = function() return nil end,
        getStateSchema = function() return nil end,
      },
      foundation = {
        failure = function(code, message, retryable)
          return nil, { code = code, message = message, retryable = retryable }
        end,
        getCaller = function() return 'synex_control' end,
        isCallable = function(value) return type(value) == 'function' end,
        protect = function(_, handler)
          local ok, value = pcall(handler)
          return ok, value
        end,
        takeRateLimit = function() return true end,
      },
      validation = {},
      registry = {
        byEntityId = function() return nil, { code = 'NOT_FOUND' } end,
        all = function() return {} end,
      },
      entityRuntime = { inspect = function() return nil end },
      bucketPolicy = { snapshot = function(bucket) return bucket end },
      state = { buckets = {} },
      ports = {
        getResourceState = function() return 'stopped' end,
      },
      config = { maxEntities = 100, recoveryMaxAttempts = 5 },
    })
    local context = { caller = 'synex_control', traceId = 'trace_diagnostic_001' }
    local inspected = assert(service.inspectEntity({
      entityId = 'entity_0001', recoveryLimit = 5
    }, context))
    assert(table.concat(inspectCalls, ',') == 'entity,authority,recovery:5')
    assert(inspected.authority.authorityToken == nil
      and inspected.authority.instanceId == 'instance_001')
    assert(#inspected.recovery == 1 and inspected.counts.components == 1)

    local diagnostics = assert(service.diagnosticSnapshot({
      limit = 10, recoveryAttemptThreshold = 3
    }, {
      state = 'ACTIVE', serverScope = 'roleplay-main', instanceId = 'instance_001',
      resourceEpoch = 4
    }, context))
    assert(diagnostics.status == 'DEGRADED' and diagnostics.counts.entityPressure == 0.95)
    assert(#diagnostics.staleMappings == 1 and #diagnostics.orphaned == 1)
    assert(#diagnostics.resourceLeaks == 1 and #diagnostics.bucketLeaks == 1)
    assert(#diagnostics.duplicateBindings == 1 and #diagnostics.leaseConflicts == 1)
    return diagnostics.status .. ':' .. #diagnostics.staleMappings
  `);
  assert.equal(result, 'DEGRADED:1');
});

test('synex.entities service exposes bounded diagnostics under existing read capabilities', async () => {
  const [runtime, manifest, diagnosticsRepository] = await Promise.all([
    source('server/runtime.lua'),
    source('fxmanifest.lua'),
    source('server/authority_diagnostics_repository.lua'),
  ]);
  for (const method of [
    'getDiagnosticSnapshot', 'inspectEntity',
    'queryByBucket', 'queryByOwner', 'queryByResource',
  ]) {
    assert.match(runtime, new RegExp(
      `${method} = (?:publicMethod\\()?service\\.${method}\\)?`, 'u'));
  }
  assert.match(runtime, /getDiagnosticSnapshot = 'synex\.entities\.read'/u);
  assert.match(runtime, /inspectEntity = 'synex\.entities\.read'/u);
  assert.match(runtime, /queryByOwner = 'synex\.entities\.query'/u);
  assert.ok(manifest.indexOf("'server/authority_diagnostics_repository.lua'")
    < manifest.indexOf("'server/authority_repository.lua'"));
  assert.doesNotMatch(diagnosticsRepository, /UPDATE|INSERT|DELETE FROM/iu);
  assert.match(diagnosticsRepository, /LIMIT \?/u);
});
