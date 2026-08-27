import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';

const repositoryPath = path.join(
  process.cwd(), 'resources', 'synex_entities', 'server', 'authority_repository.lua',
);
const repositoryDependencies = [
  'authority_recovery_repository.lua',
  'authority_inspection_repository.lua',
  'authority_diagnostics_repository.lua',
].map((name) => path.join(process.cwd(), 'resources', 'synex_entities', 'server', name));

test('reservation duplicate paths use atomic no-op inserts and locked readback', async () => {
  const source = await readFile(repositoryPath, 'utf8');
  const reserve = source.slice(
    source.indexOf('function repository.reserve'),
    source.indexOf('function repository.getById'),
  );
  assert.equal((reserve.match(/ON DUPLICATE KEY UPDATE/gu) ?? []).length, 2);
  assert.match(reserve, /ON DUPLICATE KEY UPDATE `entity_id` = `entity_id`/u);
  assert.match(reserve, /ON DUPLICATE KEY UPDATE `binding_id` = `binding_id`/u);
  assert.match(reserve, /WHERE `entity_id` = \? LIMIT 1 FOR UPDATE/u);
  assert.match(reserve, /WHERE `resource_owner` = \? AND `persistent_key` = \?[\s\S]*?FOR UPDATE/u);
  assert.match(reserve, /bound\.entity_id ~= entityId/u);
});

test('persistent-key and binding races return structured public conflicts', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    for (const dependency of repositoryDependencies) {
      await engine.doString(await readFile(dependency, 'utf8'));
    }
    await engine.doString(await readFile(repositoryPath, 'utf8'));
    const result = await engine.doString(String.raw`
      local request = {
        archetype = nil, binding = {
          namespace = 'synex_vehicles.garage', ref = 'slot_001',
        },
        bucket = 0, doorFlag = nil, entityType = 'vehicle', heading = 0,
        model = 12345, owner = { type = 'resource', id = 'synex_vehicles' },
        pedType = nil, persistencePolicy = 'persistent',
        persistentKey = 'garage:slot_001', position = { x = 1, y = 2, z = 3 },
        reasonCode = 'synex.entities.test_reserve', recoveryPolicy = 'manual',
        vehicleType = 'automobile',
      }
      local authority = {
        instanceId = 'instance_001', leaseSeconds = 30, resourceEpoch = 4,
        serverScope = 'roleplay-main', token = 'authority_001',
      }
      local function create(mode)
        return SynexEntityAuthorityRepository.create({
          database = {
            maintenance = function(_, handler)
              local tx = {}
              function tx.update(sql)
                if sql:find('INSERT INTO', 1, true)
                  and sql:find('synex_entities', 1, true) then
                  return mode == 'persistent_collision' and 0 or 1
                end
                if sql:find('INSERT INTO', 1, true)
                  and sql:find('synex_entity_bindings', 1, true) then
                  return mode == 'binding_collision' and 0 or 1
                end
                if sql:find('INSERT INTO', 1, true)
                  and sql:find('synex_entity_authority_leases', 1, true) then
                  return 1
                end
                error('unexpected reservation update')
              end
              function tx.one(sql)
                local plain = sql:gsub(string.char(96), '')
                if plain:find('FROM synex_entities WHERE entity_id', 1, true) then
                  if mode == 'persistent_collision' then return nil end
                  return {
                    persistent_key = 'garage:slot_001',
                    resource_owner = 'synex_vehicles',
                  }
                end
                if plain:find('resource_owner = ?', 1, true) then
                  return mode == 'persistent_collision'
                    and { entity_id = 'entity_existing' } or nil
                end
                if sql:find('FROM', 1, true)
                  and sql:find('synex_entity_bindings', 1, true) then
                  return { entity_id = mode == 'binding_collision'
                    and 'entity_existing' or 'entity_new' }
                end
                error('unexpected reservation readback')
              end
              local value, operationError = handler(tx)
              if not value then error(operationError, 0) end
              return value
            end,
            query = function() error('query should not run') end,
            update = function() error('direct update should not run') end,
          },
          foundation = {
            failure = function(code, message, retryable, context)
              return nil, { code = code, message = message, retryable = retryable,
                traceId = context and context.traceId }
            end,
            reportUnexpected = function() error('public conflict leaked as persistence failure') end,
          },
          health = {},
        })
      end

      local value1, keyError = create('persistent_collision').reserve(
        request, 'entity_new', 'synex_vehicles', authority, nil,
        { traceId = 'trace_reserve_key_001' })
      assert(value1 == nil and keyError.code == 'ENTITY_ALREADY_MATERIALIZED')
      assert(keyError.retryable == false and keyError.traceId == 'trace_reserve_key_001')

      local value2, bindingError = create('binding_collision').reserve(
        request, 'entity_new', 'synex_vehicles', authority, nil,
        { traceId = 'trace_reserve_binding_001' })
      assert(value2 == nil and bindingError.code == 'BINDING_CONFLICT')
      assert(bindingError.retryable == false and bindingError.traceId == 'trace_reserve_binding_001')

      local reserved = assert(create('success').reserve(
        request, 'entity_new', 'synex_vehicles', authority, nil,
        { traceId = 'trace_reserve_success_001' }))
      assert(reserved.entityId == 'entity_new' and reserved.leaseGeneration == 1)
      return keyError.code .. ':' .. bindingError.code .. ':' .. reserved.status
    `) as string;
    assert.equal(result,
      'ENTITY_ALREADY_MATERIALIZED:BINDING_CONFLICT:spawning');
  } finally {
    engine.global.close();
  }
});
