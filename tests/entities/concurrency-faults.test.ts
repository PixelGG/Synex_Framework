import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';

const root = path.join(process.cwd(), 'resources', 'synex_entities');
const authorityPaths = [
  'server/authority_recovery_repository.lua',
  'server/authority_inspection_repository.lua',
  'server/authority_diagnostics_repository.lua',
  'server/authority_repository.lua',
] as const;

async function runAuthorityLua<T>(source: string): Promise<T> {
  const engine = await new LuaFactory().createEngine();
  try {
    for (const relative of authorityPaths) {
      await engine.doString(await readFile(path.join(root, relative), 'utf8'));
    }
    return await engine.doString(source) as T;
  } finally {
    engine.global.close();
  }
}

test('entity mutation lanes serialize delete/checkpoint and bucket/delete races', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await engine.doString(await readFile(
      path.join(root, 'server', 'mutation_lanes.lua'), 'utf8'));
    const result = await engine.doString(String.raw`
      local now = 1000
      local lanes = SynexEntityMutationLanes.create({
        foundation = {
          failure = function(code, message, retryable, context)
            return nil, { code = code, message = message, retryable = retryable,
              traceId = context and context.traceId }
          end,
          isCallable = function(value) return type(value) == 'function' end,
        },
        maximumLanes = 8,
        ports = { getGameTimer = function() return now end },
        timeoutMs = 100,
      })
      local key = assert(lanes.entityKey('entity_race_0001'))
      local conflicts = 0
      for _, pair in ipairs({
        { 'delete', 'checkpoint' },
        { 'checkpoint', 'delete' },
        { 'bucket_move', 'delete' },
        { 'delete', 'bucket_move' },
      }) do
        assert(lanes.with(key, pair[1], { traceId = 'trace_lane_outer' }, function()
          local value, operationError = lanes.with(
            key, pair[2], { traceId = 'trace_lane_inner' }, function() return true end)
          assert(value == nil and operationError.code == 'CONCURRENT_MODIFICATION')
          conflicts = conflicts + 1
          local parallelKey = assert(lanes.entityKey('entity_race_0002'))
          assert(lanes.with(parallelKey, 'checkpoint', {}, function() return true end))
          return true
        end))
      end
      local raised = pcall(function()
        lanes.with(key, 'fault_injection', {}, function() error('injected failure') end)
      end)
      assert(not raised and lanes.snapshot().count == 0)
      assert(lanes.with(key, 'retry', {}, function() return true end))
      assert(lanes.snapshot().count == 0)
      return tostring(conflicts)
    `) as string;
    assert.equal(result, '4');
  } finally {
    engine.global.close();
  }
});

test('visible persistent-key and binding conflicts return stable domain errors', async () => {
  const result = await runAuthorityLua<string>(String.raw`
    local entitiesById, entityByKey, bindingByRef = {}, {}, {}
    local writes, leaseWrites = 0, 0
    local repository = SynexEntityAuthorityRepository.create({
      database = {
        maintenance = function(_, handler)
          local value, operationError = handler({
            one = function(sql, parameters)
              if sql:find('synex_entities', 1, true) then
                if #parameters == 1 then return entitiesById[parameters[1]] end
                local entityId = entityByKey[parameters[1] .. ':' .. parameters[2]]
                return entityId and { entity_id = entityId } or nil
              end
              if sql:find('synex_entity_bindings', 1, true) then
                local entityId = bindingByRef[parameters[1] .. ':' .. parameters[2]]
                return entityId and { entity_id = entityId } or nil
              end
              error('unexpected SELECT')
            end,
            update = function(sql, parameters)
              writes = writes + 1
              if sql:find('INSERT INTO', 1, true)
                and sql:find('synex_entities', 1, true) then
                local key = parameters[14] .. ':' .. parameters[2]
                if entitiesById[parameters[1]] or entityByKey[key] then return 0 end
                entitiesById[parameters[1]] = {
                  resource_owner = parameters[14], persistent_key = parameters[2],
                }
                entityByKey[key] = parameters[1]
                return 1
              elseif sql:find('INSERT INTO', 1, true)
                and sql:find('synex_entity_bindings', 1, true) then
                local key = parameters[2] .. ':' .. parameters[3]
                if bindingByRef[key] then return 0 end
                bindingByRef[key] = parameters[1]
                return 1
              elseif sql:find('synex_entity_authority_leases', 1, true) then
                leaseWrites = leaseWrites + 1
              end
              return 1
            end,
          })
          if value == nil and operationError ~= nil then error(operationError, 0) end
          return value
        end,
        query = function() error('query must not run') end,
        update = function() error('direct update must not run') end,
      },
      foundation = {
        failure = function(code, message, retryable)
          return nil, { code = code, message = message, retryable = retryable }
        end,
        reportUnexpected = function() error('unexpected persistence failure') end,
      },
      health = {},
    })
    local authority = {
      instanceId = 'instance_0001', leaseSeconds = 30, resourceEpoch = 4,
      serverScope = 'roleplay-main', token = 'authority_0001',
    }
    local function request(key, binding)
      return {
        binding = binding,
        bucket = 0, doorFlag = false, entityType = 'vehicle', heading = 0,
        model = 12345, owner = { type = 'resource', id = 'synex_world' },
        persistencePolicy = 'persistent', persistentKey = key,
        position = { x = 0, y = 0, z = 0 }, reasonCode = 'synex.entities.spawn',
        recoveryPolicy = 'manual', vehicleType = 'automobile',
      }
    end
    assert(repository.reserve(request('claim:primary', {
      namespace = 'synex_world.vehicle', ref = 'VEHICLE-PRIMARY',
    }), 'entity_claim_0001', 'synex_world', authority, nil,
      { traceId = 'trace_claim_first' }))
    assert(writes == 3 and leaseWrites == 1)
    local duplicateKey, keyError = repository.reserve(request('claim:primary'),
      'entity_claim_0002', 'synex_world', authority, nil,
      { traceId = 'trace_claim_key' })
    assert(duplicateKey == nil and keyError.code == 'ENTITY_ALREADY_MATERIALIZED')
    local duplicateBinding, bindingError = repository.reserve(request('claim:secondary', {
      namespace = 'synex_world.vehicle', ref = 'VEHICLE-PRIMARY',
    }), 'entity_claim_0003', 'synex_world', authority, nil,
      { traceId = 'trace_claim_binding' })
    assert(duplicateBinding == nil and bindingError.code == 'BINDING_CONFLICT')
    assert(writes == 6 and leaseWrites == 1)
    return keyError.code .. ':' .. bindingError.code
  `);
  assert.equal(result, 'ENTITY_ALREADY_MATERIALIZED:BINDING_CONFLICT');
});

test('a live foreign authority lease blocks a second instance claim and expired authority is fenced', async () => {
  const result = await runAuthorityLua<string>(String.raw`
    local foreignLive = true
    local updates = {}
    local row = {
      archetype_namespace = nil, bucket_id = 0, created_at = '2026-01-01',
      deleted_at = nil, door_flag = 0, entity_id = 'entity_claim_lease',
      entity_type = 'vehicle', generation = 3, heading = 0, model = 12345,
      owner_id = 'synex_world', owner_type = 'resource', ped_type = nil,
      persistence_policy = 'persistent', persistent_key = 'claim:lease',
      position_x = 0, position_y = 0, position_z = 0,
      recovery_circuit_state = 'closed', recovery_policy = 'automatic',
      resource_owner = 'synex_world', server_scope = 'roleplay-main',
      status = 'dormant', vehicle_type = 'automobile', version = 9,
    }
    local repository = SynexEntityAuthorityRepository.create({
      database = {
        maintenance = function(operation, handler)
          assert(operation == 'entities.claim_materialization')
          local value, operationError = handler({
            one = function(sql)
              if sql:find('FROM', 1, true)
                and sql:find('synex_entities', 1, true) then return row end
              if sql:find('synex_entity_authority_leases', 1, true) then
                return {
                  authority_token = 'authority_instance_a', instance_id = 'instance_a',
                  lease_generation = 5, lease_live = foreignLive and 1 or 0,
                  lease_state = 'active', resource_epoch = 7, version = 11,
                }
              end
              error('unexpected SELECT')
            end,
            update = function(sql, parameters)
              updates[#updates + 1] = { sql = sql, parameters = parameters }
              return 1
            end,
          })
          if value == nil and operationError ~= nil then error(operationError, 0) end
          return value
        end,
        query = function() error('query must not run') end,
        update = function() error('direct update must not run') end,
      },
      foundation = {
        failure = function(code, message, retryable)
          return nil, { code = code, message = message, retryable = retryable }
        end,
        reportUnexpected = function() error('unexpected persistence failure') end,
      },
      health = {},
    })
    local instanceB = {
      instanceId = 'instance_b', leaseSeconds = 30, resourceEpoch = 8,
      serverScope = 'roleplay-main', token = 'authority_instance_b',
    }
    local claimed, claimError = repository.claimMaterialization(
      row.entity_id, 'synex_world', instanceB, true,
      { traceId = 'trace_foreign_claim' })
    assert(claimed == nil and claimError.code == 'AUTHORITY_LEASE_CONFLICT')
    assert(#updates == 0)

    foreignLive = false
    local recovered = assert(repository.claimMaterialization(
      row.entity_id, 'synex_world', instanceB, true,
      { traceId = 'trace_expired_claim' }))
    assert(recovered.generation == 4 and recovered.leaseGeneration == 6)
    assert(recovered.status == 'recovering' and recovered.version == 10)
    assert(#updates == 2)
    assert(updates[1].sql:find('WHERE', 1, true)
      and updates[1].sql:find('entity_id', 1, true)
      and updates[1].sql:find('version', 1, true))
    assert(updates[2].sql:find('AND', 1, true)
      and updates[2].sql:find('status', 1, true))
    assert(updates[1].parameters[2] == 'instance_b'
      and updates[1].parameters[3] == 'authority_instance_b')
    return claimError.code .. ':' .. recovered.leaseGeneration
  `);
  assert.equal(result, 'AUTHORITY_LEASE_CONFLICT:6');
});

test('activation loses cleanly to a concurrent delete before any state update', async () => {
  const result = await runAuthorityLua<string>(String.raw`
    local writes = 0
    local repository = SynexEntityAuthorityRepository.create({
      database = {
        maintenance = function(operation, handler)
          assert(operation == 'entities.activate')
          local value, operationError = handler({
            one = function(sql)
              assert(sql:find("IN ('spawning', 'recovering')", 1, true))
              return nil
            end,
            update = function() writes = writes + 1 return 1 end,
          })
          if value == nil and operationError ~= nil then error(operationError, 0) end
          return value
        end,
        query = function() error('query must not run') end,
        update = function() error('direct update must not run') end,
      },
      foundation = {
        failure = function(code, message, retryable)
          return nil, { code = code, message = message, retryable = retryable }
        end,
        reportUnexpected = function() error('unexpected persistence failure') end,
      },
      health = {},
    })
    local activated, operationError = repository.activate(
      'entity_spawn_delete', 1, 1, 1, 0, {
        instanceId = 'instance_0001', leaseSeconds = 30, resourceEpoch = 4,
        serverScope = 'roleplay-main', token = 'authority_0001',
      }, { traceId = 'trace_spawn_delete' })
    assert(activated == nil and operationError.code == 'CONCURRENT_MODIFICATION')
    assert(writes == 0)
    return operationError.code
  `);
  assert.equal(result, 'CONCURRENT_MODIFICATION');
});

test('database exceptions become bounded retryable persistence failures', async () => {
  const result = await runAuthorityLua<string>(String.raw`
    local reported = 0
    local health = {}
    local repository = SynexEntityAuthorityRepository.create({
      database = {
        maintenance = function() error('injected database failure') end,
        query = function() error('query must not run') end,
        update = function() error('direct update must not run') end,
      },
      foundation = {
        failure = function(code, message, retryable, context)
          return nil, { code = code, message = message, retryable = retryable,
            traceId = context and context.traceId }
        end,
        reportUnexpected = function(component, caught)
          reported = reported + 1
          assert(component == 'authority.repository')
          assert(type(caught) == 'string' and caught:find('injected database failure', 1, true))
        end,
      },
      health = health,
    })
    local value, operationError = repository.reserve({}, 'entity_db_failure',
      'synex_world', {}, nil, { traceId = 'trace_database_failure' })
    assert(value == nil and operationError.code == 'PERSISTENCE_UNAVAILABLE')
    assert(operationError.retryable and operationError.traceId == 'trace_database_failure')
    assert(health.persistence == 'UNAVAILABLE' and reported == 1)
    return operationError.code
  `);
  assert.equal(result, 'PERSISTENCE_UNAVAILABLE');
});

test('static race defenses retain database uniqueness, CAS, authority, and owner-epoch fences', async () => {
  const [migration2, migration3, authority, lifecycle, bucket] = await Promise.all([
    readFile(path.join(root, 'migrations', '002_entity_lifecycle_authority.sql'), 'utf8'),
    readFile(path.join(root, 'migrations', '003_entity_extensions.sql'), 'utf8'),
    readFile(path.join(root, 'server', 'authority_service.lua'), 'utf8'),
    readFile(path.join(root, 'server', 'authority_lifecycle.lua'), 'utf8'),
    readFile(path.join(root, 'server', 'bucket_service.lua'), 'utf8'),
  ]);
  assert.match(migration2,
    /UNIQUE INDEX IF NOT EXISTS `uq_synex_entities_resource_persistent_key`[\s\S]*?`resource_owner`, `persistent_key`/u);
  assert.match(migration3,
    /UNIQUE KEY `uq_synex_entity_bindings_active_ref`[\s\S]*?`binding_namespace`, `binding_ref`, `active_marker`/u);
  assert.match(authority, /foundation\.withOwnerEpoch\(invokingResource/u);
  assert.match(authority,
    /lanes\.with\(lanes\.entityKey\(entityRef\.entityId\), 'checkpoint'/u);
  assert.match(authority, /lanes\.with\(lanes\.entityKey\(record\.entityId\), 'delete'/u);
  assert.match(lifecycle, /lanes\.with\(lanes\.entityKey\(entityRef\.entityId\),[\s\S]*?'dematerialize'/u);
  assert.match(bucket,
    /lanes\.with\([\s\S]*?lanes\.entityKey\(request\.entityId\), 'bucket_move'/u);
});
