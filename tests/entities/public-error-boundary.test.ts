import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory, type LuaEngine } from 'wasmoon';

const root = process.cwd();

async function load(engine: LuaEngine, relativePath: string): Promise<void> {
  await engine.doString(await readFile(path.join(root, relativePath), 'utf8'));
}

async function coreEngine(): Promise<LuaEngine> {
  const engine = await new LuaFactory().createEngine();
  await load(engine, 'core/synex_core/shared/protocol.lua');
  await load(engine, 'core/synex_core/server/factories.lua');
  for (const module of [
    'foundation', 'registries', 'lifecycle', 'contracts', 'security', 'messaging',
  ]) await load(engine, `core/synex_core/server/${module}.lua`);
  await load(engine, 'resources/synex_entities/server/public_errors.lua');
  return engine;
}

test('Entity public errors strip private fields and preserve bounded quota details', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await load(engine, 'resources/synex_entities/server/public_errors.lua');
    const result = await engine.doString(`
      local normalize = SynexEntityPublicErrors.compile({{
        name = 'synex.entities.spawn', version = '1.0.0',
        errors = {'ENTITY_QUOTA_EXCEEDED', 'FORBIDDEN', 'UNAVAILABLE'},
      }})
      local quota = normalize('synex.entities.spawn', {
        code = 'ENTITY_QUOTA_EXCEEDED', message = 'Quota exceeded', retryable = false,
        traceId = 'private_trace', details = { scope = 'resource', limit = 32 },
      }, { version = '1.0.0', traceId = 'contract_trace' })
      assert(quota.code == 'ENTITY_QUOTA_EXCEEDED' and quota.traceId == nil)
      assert(quota.details.scope == 'resource' and quota.details.limit == 32)
      local denied = normalize('synex.entities.spawn', {
        code = 'CAPABILITY_DENIED', message = 'private capability detail', traceId = 'private',
      }, { version = '1.0.0' })
      assert(denied.code == 'FORBIDDEN' and denied.traceId == nil and denied.details == nil)
      local dependency = normalize('synex.entities.spawn', {
        code = 'PERSISTENCE_UNAVAILABLE', message = 'private database detail',
      }, { version = '1.0.0' })
      assert(dependency.code == 'UNAVAILABLE' and dependency.retryable == true)
      return quota.code .. ':' .. denied.code .. ':' .. dependency.code
    `) as string;
    assert.equal(result, 'ENTITY_QUOTA_EXCEEDED:FORBIDDEN:UNAVAILABLE');
  } finally {
    engine.global.close();
  }
});

test('normalized Entity errors cross the real Core messaging provider boundary', async () => {
  const engine = await coreEngine();
  try {
    const result = await engine.doString(`
      local platform = {
        nowGame = function() return 1000 end,
        random = function() return 1 end,
        print = function() end,
        jsonEncode = function() return '{}' end,
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('entity-public-errors')
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      local owners = registries.owners
      local coreEpoch = owners:activate('synex_core')
      local lifecycle = SynexCoreFactories.lifecycle({
        platform = platform, foundation = foundation, owners = owners,
      })
      for _, state in ipairs({
        'CONFIGURING', 'DATABASE_CONNECTING', 'MIGRATING', 'DISCOVERING_RESOURCES',
        'VALIDATING_CONTRACTS', 'VALIDATING_CAPABILITIES', 'STARTING_SERVICES', 'READY',
      }) do assert(lifecycle.core:transition(state, 'fixture')) end
      local contracts = SynexCoreFactories.contracts({
        foundation = foundation, protocol = SynexProtocol,
      })
      local security = SynexCoreFactories.security({
        platform = platform, foundation = foundation, coreResource = 'synex_core',
      })
      local messaging = SynexCoreFactories.messaging({
        platform = platform, foundation = foundation, contracts = contracts,
        security = security, owners = owners, players = {}, lifecycle = lifecycle,
        dependencies = lifecycle.dependencies, protocol = SynexProtocol,
        config = { burst = 24, rate = 24 }, coreResource = 'synex_core',
      })
      local definition = {
        name = 'synex.entities.boundary_fixture', version = '1.0.0',
        provider = 'synex_core', kind = 'rpc', stability = 'experimental', network = 'none',
        errors = {'ENTITY_QUOTA_EXCEEDED', 'UNAVAILABLE'},
        input = { type = 'object', additionalProperties = false, properties = {} },
        output = { type = 'object', additionalProperties = false, properties = {} },
      }
      local normalize = SynexEntityPublicErrors.compile({ definition })
      assert(messaging.gateway:register('synex_core', coreEpoch, definition, function(_, context)
        return nil, normalize(definition.name, {
          code = 'ENTITY_QUOTA_EXCEEDED', message = 'Quota exceeded', retryable = false,
          traceId = 'must_not_cross', details = { scope = 'global', limit = 1024 },
        }, context)
      end))
      local value, operationError = messaging.gateway:invoke(
        'synex_core', coreEpoch, definition.name, definition.version, {}, {})
      assert(value == nil and operationError.code == 'ENTITY_QUOTA_EXCEEDED')
      assert(operationError.traceId ~= nil and operationError.traceId ~= 'must_not_cross')
      assert(operationError.details.scope == 'global' and operationError.details.limit == 1024)
      return operationError.code
    `) as string;
    assert.equal(result, 'ENTITY_QUOTA_EXCEEDED');
  } finally {
    engine.global.close();
  }
});
