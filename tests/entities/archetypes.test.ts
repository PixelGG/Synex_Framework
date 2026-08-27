import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';

const root = path.join(process.cwd(), 'resources', 'synex_entities');

async function runLua<T>(assertions: string): Promise<T> {
  const engine = await new LuaFactory().createEngine();
  try {
    for (const relative of [
      'shared/validation.lua',
      'server/extension_registry.lua',
      'server/archetypes.lua',
    ]) {
      await engine.doString(await readFile(path.join(root, relative), 'utf8'));
    }
    return await engine.doString(String.raw`
      local capturedDescriptor
      local active = { synex_vehicles = true, synex_jobs = true }
      local foundation = {
        failure = function(code, message, retryable, context)
          return nil, { code = code, message = message, retryable = retryable == true,
            traceId = context and context.traceId or nil }
        end,
        isResourceActive = function(resource) return active[resource] == true end,
        protect = function(_, handler)
          local ok, value = pcall(handler)
          return ok, value
        end,
      }
      local ports = {
        jsonEncode = function(value)
          capturedDescriptor = value
          return '{"frozen":true}'
        end,
      }
      local jsonValues = {
        decode = function(value, expected)
          if value ~= '{}' or expected ~= 'object' then
            return nil, { code = 'INVALID_JSON_VALUE', message = 'invalid JSON' }
          end
          return { marker = 'original' }
        end,
      }
      local registry = SynexEntityExtensionRegistry.create()
      assert(registry.beginOwner('synex_vehicles', 7))
      assert(registry.registerComponentSchema('synex_vehicles', 7, {
        namespace = 'synex_vehicles.runtime', schemaVersion = 2,
      }))
      assert(registry.registerStateSchema('synex_vehicles', 7, {
        key = 'synex_vehicles:locked', namespace = 'synex_vehicles:locked',
        schemaVersion = 3,
      }))
      local service = SynexEntityArchetypes.create({
        extensionRegistry = registry, foundation = foundation,
        jsonValues = jsonValues, ports = ports, validation = SynexEntityValidation,
      })
      local context = { traceId = 'trace_archetype_0001' }
      local function request(name)
        return {
          allowedModels = { 200, 100 },
          componentSchemas = {
            { namespace = 'synex_vehicles.runtime', schemaVersion = 2 },
          },
          defaultTags = { 'synex_vehicles.managed', 'synex_vehicles.vehicle' },
          descriptorJson = '{}', entityType = 'vehicle', name = name,
          persistencePolicy = 'persistent', reasonCode = 'synex_vehicles.register',
          recoveryPolicy = 'on_demand',
          spawnDefaults = {
            heading = -90, model = 100, timeoutMs = 800,
            vehicleType = 'automobile',
          },
          stateSchemas = {
            { key = 'synex_vehicles:locked', schemaVersion = 3 },
          },
          version = 4,
        }
      end
      ${assertions}
    `) as T;
  } finally {
    engine.global.close();
  }
}

test('archetypes apply only missing defaults and strictly reject explicit type/model conflicts', async () => {
  const result = await runLua<string>(String.raw`
    assert(service.registerOwned(request('synex_vehicles.standard'),
      'synex_vehicles', 7, context))
    local prepared, definition = assert(service.prepareSpawn({
      archetype = { namespace = 'synex_vehicles.standard', version = 4 },
      owner = { type = 'resource', id = 'synex_vehicles' },
      persistentKey = 'vehicle_001', position = { x = 1, y = 2, z = 3 },
    }, 'synex_vehicles', context))
    assert(definition.schemaVersion == 4 and prepared.entityType == 'vehicle')
    assert(prepared.model == 100 and prepared.vehicleType == 'automobile')
    assert(prepared.heading == 270 and prepared.timeoutMs == 800)
    assert(prepared.persistencePolicy == 'persistent')
    assert(prepared.recoveryPolicy == 'on_demand' and #prepared.tags == 2)

    local explicit = assert(service.prepareSpawn({
      archetype = { namespace = 'synex_vehicles.standard', version = 4 },
      entityType = 'vehicle', heading = 22, model = 200, tags = {},
      vehicleType = 'bike',
    }, 'synex_vehicles', context))
    assert(explicit.heading == 22 and explicit.model == 200)
    assert(explicit.vehicleType == 'bike' and #explicit.tags == 0)

    local wrongType, _, typeError = service.prepareSpawn({
      archetype = { namespace = 'synex_vehicles.standard', version = 4 },
      entityType = 'ped',
    }, 'synex_vehicles', context)
    assert(wrongType == nil and typeError.code == 'INVALID_ENTITY_TYPE')
    local wrongModel, _, modelError = service.prepareSpawn({
      archetype = { namespace = 'synex_vehicles.standard', version = 4 },
      model = 999,
    }, 'synex_vehicles', context)
    assert(wrongModel == nil and modelError.code == 'INVALID_MODEL')
    return prepared.entityType .. ':' .. prepared.model .. ':' .. prepared.recoveryPolicy
  `);
  assert.equal(result, 'vehicle:100:on_demand');
});

test('archetype registration rejects foreign namespaces, stale epochs and stale schema ownership', async () => {
  const result = await runLua<string>(String.raw`
    local foreignRequest = request('synex_jobs.stolen')
    local foreign, foreignError = service.registerOwned(
      foreignRequest, 'synex_vehicles', 7, context)
    assert(foreign == nil and foreignError.code == 'FORBIDDEN')

    local staleRequest = request('synex_vehicles.stale')
    staleRequest.componentSchemas = {}
    staleRequest.stateSchemas = {}
    local stale, staleError = service.registerOwned(
      staleRequest, 'synex_vehicles', 6, context)
    assert(stale == nil and staleError.code == 'STALE_RESOURCE')

    assert(registry.beginOwner('synex_jobs', 1))
    assert(registry.registerComponentSchema('synex_jobs', 1, {
      namespace = 'synex_jobs.runtime', schemaVersion = 1,
    }))
    local refRequest = request('synex_vehicles.foreign_ref')
    refRequest.componentSchemas = {
      { namespace = 'synex_jobs.runtime', schemaVersion = 1 },
    }
    refRequest.stateSchemas = {}
    local foreignRef, refError = service.registerOwned(
      refRequest, 'synex_vehicles', 7, context)
    assert(foreignRef == nil and refError.code == 'FORBIDDEN')
    return foreignError.code .. ':' .. staleError.code .. ':' .. refError.code
  `);
  assert.equal(result, 'FORBIDDEN:STALE_RESOURCE:FORBIDDEN');
});

test('persistent descriptors are frozen while restart cleanup invalidates only live registration', async () => {
  const result = await runLua<string>(String.raw`
    local registration = request('synex_vehicles.frozen')
    assert(service.registerOwned(registration, 'synex_vehicles', 7, context))
    registration.allowedModels[1] = 999
    registration.spawnDefaults.model = 999
    registration.defaultTags[1] = 'synex_vehicles.mutated'

    local prepared, definition = assert(service.prepareSpawn({
      archetype = { namespace = 'synex_vehicles.frozen', version = 4 },
      owner = { type = 'resource', id = 'synex_vehicles' },
      persistentKey = 'frozen_001', position = { x = 0, y = 0, z = 0 },
    }, 'synex_vehicles', context))
    assert(prepared.model == 100 and definition.allowedModels[1] == 100)
    assert(service.descriptorJson(prepared, definition, context) == '{"frozen":true}')
    assert(capturedDescriptor.archetype.version == 4)
    assert(capturedDescriptor.archetype.ownerResource == 'synex_vehicles')
    assert(capturedDescriptor.archetype.spawnDefaults.model == 100)
    assert(capturedDescriptor.archetype.descriptor.marker == 'original')

    assert(registry.cleanup('synex_vehicles', 7) == 3)
    local missing, _, missingError = service.prepareSpawn({
      archetype = { namespace = 'synex_vehicles.frozen', version = 4 },
    }, 'synex_vehicles', context)
    assert(missing == nil and missingError.code == 'ARCHETYPE_NOT_FOUND')
    assert(capturedDescriptor.archetype.version == 4)
    return capturedDescriptor.archetype.namespace .. ':'
      .. capturedDescriptor.archetype.spawnDefaults.model
  `);
  assert.equal(result, 'synex_vehicles.frozen:100');
});

test('archetype source contract exposes bounded defaults, schema references and on-demand recovery', async () => {
  const source = await readFile(
    path.join(root, 'contracts', 'entities.contracts.json'), 'utf8',
  );
  const contracts = (JSON.parse(source) as { contracts: Array<{
    input: { properties?: Record<string, unknown>; required?: string[] };
    name: string;
  }> }).contracts;
  const registration = contracts.find(({ name }) => name === 'synex.entities.archetype.register');
  assert.ok(registration);
  for (const field of [
    'persistencePolicy', 'recoveryPolicy', 'spawnDefaults', 'defaultTags',
    'componentSchemas', 'stateSchemas',
  ]) {
    assert.ok(registration.input.required?.includes(field), `${field} must be required`);
    assert.ok(registration.input.properties?.[field], `${field} schema is missing`);
  }
  const materialize = contracts.find(({ name }) => name === 'synex.entities.materialize') as unknown as {
    input: { properties: { spawnContext: { properties: { recoveryMode: { enum: string[] } } } } };
  };
  assert.ok(materialize.input.properties.spawnContext.properties.recoveryMode.enum
    .includes('on_demand'));
});
