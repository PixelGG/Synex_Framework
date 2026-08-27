import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';

const root = path.join(process.cwd(), 'resources', 'synex_entities');

async function runLua<T>(assertions: string): Promise<T> {
  const engine = await new LuaFactory().createEngine();
  try {
    for (const file of [
      path.join(root, 'shared', 'validation.lua'),
      path.join(root, 'server', 'extension_schema.lua'),
      path.join(root, 'server', 'component_lifecycle.lua'),
    ]) {
      await engine.doString(await readFile(file, 'utf8'));
    }
    return await engine.doString(String.raw`
      local projected = {}
      local snapshot = {
        components = {{
          namespace = 'synex_vehicles.runtime', ownerResource = 'synex_vehicles',
          payloadJson = '{"locked":true}', persistenceMode = 'replicated',
          schemaVersion = 3,
        }},
        states = {{
          authority = 'server', key = 'synex_vehicles:locked',
          ownerResource = 'synex_vehicles', replication = 'scoped',
          schemaVersion = 4, valueJson = 'true',
        }},
      }
      local foundation = {
        failure = function(code, message, retryable, context)
          return nil, { code = code, message = message, retryable = retryable,
            traceId = context and context.traceId }
        end,
        isCallable = function(value) return type(value) == 'function' end,
        protect = function(_, handler)
          local ok, value = pcall(handler)
          return ok, value
        end,
      }
      local registry = {
        getComponentSchema = function(namespace)
          if namespace ~= 'synex_vehicles.runtime' then return nil end
          return { maximumBytes = 256, maximumDepth = 4, namespace = namespace,
            ownerResource = 'synex_vehicles', persistenceMode = 'replicated',
            schema = { type = 'object' }, schemaVersion = 3 }
        end,
        getStateSchema = function(key)
          if key ~= 'synex_vehicles:locked' then return nil end
          return { authority = 'server', key = key, maximumBytes = 32,
            ownerResource = 'synex_vehicles', replication = 'scoped',
            schema = { type = 'boolean' }, schemaVersion = 4 }
        end,
      }
      local jsonValues = {
        decode = function(encoded)
          if encoded == 'true' then return true end
          if encoded == '{"locked":true}' then return { locked = true } end
          return nil, { message = 'invalid' }
        end,
        validate = function(_, value) return value, nil, 'canonical' end,
      }
      local repository = {
        getHydrationSnapshot = function(entityId, generation)
          assert(entityId == 'entity_component_0001' and generation == 2)
          return snapshot
        end,
      }
      local lifecycle = SynexEntityComponentLifecycle.create({
        extensionRegistry = registry,
        foundation = foundation,
        jsonValues = jsonValues,
        ports = { setEntityState = function(handle, key, value, replicated)
          projected[#projected + 1] = { handle = handle, key = key,
            replicated = replicated, value = value }
        end },
        repository = repository,
        validation = SynexEntityValidation,
      })
      ${assertions}
    `) as T;
  } finally {
    engine.global.close();
  }
}

test('runtime cleanup is fenced by entity generation', async () => {
  const result = await runLua<string>(String.raw`
    lifecycle.putRuntime('entity_component_0001', 'synex_vehicles.session', {
      generation = 2, ownerEpoch = 7, ownerResource = 'synex_vehicles', version = 1,
    })
    assert(lifecycle.countRuntime() == 1)
    lifecycle.putRuntime('entity_component_0001', 'synex_vehicles.session', {
      generation = 2, ownerEpoch = 7, ownerResource = 'synex_vehicles', version = 2,
    })
    assert(lifecycle.countRuntime() == 1)
    local stale = assert(lifecycle.cleanupEntity(
      'entity_component_0001', 1, 'entity_removed', { traceId = 'trace_stale_cleanup' }))
    assert(stale.runtimeRemoved == 0)
    assert(lifecycle.getRuntime(
      'entity_component_0001', 2, 'synex_vehicles.session').version == 2)
    local current = assert(lifecycle.cleanupEntity(
      'entity_component_0001', 2, 'dematerialize', { traceId = 'trace_current_cleanup' }))
    assert(current.runtimeRemoved == 1)
    assert(lifecycle.getRuntime(
      'entity_component_0001', 2, 'synex_vehicles.session') == nil)
    assert(lifecycle.countRuntime() == 0)
    return stale.runtimeRemoved .. ':' .. current.runtimeRemoved
  `);
  assert.equal(result, '0:1');
});

test('hydration reprojects only schema-matched replicated and scoped values', async () => {
  const result = await runLua<string>(String.raw`
    local hydrated = assert(lifecycle.hydrate({
      entityId = 'entity_component_0001', generation = 2, handle = 9901,
    }, { traceId = 'trace_hydration_0001' }))
    assert(hydrated.components == 1 and hydrated.states == 1 and hydrated.projected == 2)
    assert(projected[1].key == 'synex:component:synex_vehicles.runtime')
    assert(projected[2].key == 'synex_vehicles:locked')
    assert(projected[1].replicated and projected[2].replicated)
    snapshot.states[1].schemaVersion = 5
    local rejected, rejection = lifecycle.hydrate({
      entityId = 'entity_component_0001', generation = 2, handle = 9902,
    }, { traceId = 'trace_hydration_0002' })
    assert(rejected == nil and rejection.code == 'STATE_SCHEMA_MISMATCH')
    assert(#projected == 2)
    return projected[1].key .. ':' .. projected[2].key
  `);
  assert.equal(result,
    'synex:component:synex_vehicles.runtime:synex_vehicles:locked');
});

test('hydration repository reads are bounded and exclude non-replicated rows', async () => {
  const source = await readFile(
    path.join(root, 'server', 'extension_repository.lua'),
    'utf8',
  );
  assert.match(source, /`persistence_mode` = 'replicated'/u);
  assert.match(source, /`replication_mode` = 'scoped'/u);
  const hydration = source.slice(
    source.indexOf('function repository.getHydrationSnapshot'),
    source.indexOf('function repository.setComponent'),
  );
  assert.equal((hydration.match(/ORDER BY [`a-z_]+ LIMIT 65/gu) ?? []).length, 2);
});
