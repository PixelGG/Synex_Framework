import assert from 'node:assert/strict';
import test from 'node:test';
import { runWorldLua } from './helpers.ts';

const files = [
  'shared/limits.lua',
  'shared/validation.lua',
  'server/geometry.lua',
  'server/graph.lua',
  'server/spatial_index.lua',
  'server/compiler.lua',
  'server/registry.lua',
  'server/bundle_loader.lua',
] as const;

test('bundle discovery retries dependency order and reconciles manifest removal atomically', async () => {
  const result = await runWorldLua<string>(String.raw`
    local alpha = {
      schema = 1, key = 'synex_alpha:world', version = '1.0.0',
      dependencies = { 'synex_beta' }, objects = {
        { kind = 'location', key = 'synex_alpha:station',
          parent = 'synex_beta:region',
          geometry = { type = 'sphere', center = { x = 0, y = 0, z = 0 }, radius = 10 } },
      },
    }
    local beta = {
      schema = 1, key = 'synex_beta:world', version = '1.0.0', dependencies = {},
      objects = {
        { kind = 'region', key = 'synex_beta:region',
          geometry = { type = 'sphere', center = { x = 0, y = 0, z = 0 }, radius = 100 } },
      },
    }
    local records = {
      { name = 'synex_alpha', state = 'STARTED', epoch = 3,
        manifest = { worldBundles = { 'world/alpha.world.json' } } },
      { name = 'synex_beta', state = 'STARTED', epoch = 4,
        manifest = { worldBundles = { 'world/beta.world.json' } } },
    }
    local encoded = { synex_alpha = 'alpha-bundle', synex_beta = 'beta-bundle' }
    local registry = SynexWorldRegistry.create({})
    local audits, failures = 0, 0
    local loader = SynexWorldBundleLoader.create({
      registry = registry,
      getRuntimeSnapshot = function() return { resources = records } end,
      checkCapability = function() return true end,
      loadResourceFile = function(resource) return encoded[resource] end,
      decode = function(value)
        if value == 'alpha-bundle' then return SynexWorldValidation.copy(alpha) end
        if value == 'beta-bundle' then return SynexWorldValidation.copy(beta) end
        error('unexpected fixture')
      end,
      getResourceState = function() return 'started' end,
      foundation = {},
      observability = {
        increment = function() failures = failures + 1 end,
        audit = function() audits = audits + 1 end,
      },
    })
    local discovered = assert(loader.discoverAll({ traceId = 'world_loader_test' }))
    assert(#discovered.unresolved == 0 and #discovered.resources == 2)
    assert(registry.objectCount() == 2 and registry.bundleCount() == 2)
    assert(registry.get('synex_alpha:station', 'location'))
    assert(audits == 2 and failures == 1)

    records[1].manifest.worldBundles = {}
    local removed = assert(loader.discoverResource('synex_alpha',
      { traceId = 'world_loader_remove' }))
    assert(removed.loaded == 0 and #removed.failures == 0)
    assert(registry.get('synex_alpha:station') == nil and registry.bundleCount() == 1)
    assert(loader.pathForBundle('synex_alpha', 'synex_alpha:world') == nil)

    local _, dotError = loader.load('synex_beta', 'world/./beta.world.json', false, 4, {})
    local _, separatorError = loader.load('synex_beta', 'world//beta.world.json', false, 4, {})
    assert(dotError.code == 'WORLD_BUNDLE_INVALID'
      and separatorError.code == 'WORLD_BUNDLE_INVALID')
    return table.concat({ #discovered.resources, registry.bundleCount(), audits,
      dotError.code, separatorError.code }, ':')
  `, files);
  assert.equal(result, '2:1:2:WORLD_BUNDLE_INVALID:WORLD_BUNDLE_INVALID');
});

test('bundle replacement preserves the active path on denial or invalid replacement', async () => {
  const result = await runWorldLua<string>(String.raw`
    local candidate = {
      schema = 1, key = 'synex_fixture:world', version = '1.0.0', dependencies = {},
      objects = {
        { kind = 'region', key = 'synex_fixture:region',
          geometry = { type = 'sphere', center = { x = 0, y = 0, z = 0 }, radius = 5 } },
      },
    }
    local record = { name = 'synex_fixture', state = 'STARTED', epoch = 8,
      manifest = { worldBundles = { 'world/base.world.json' } } }
    local allow, current = true, candidate
    local registry = SynexWorldRegistry.create({})
    local loader = SynexWorldBundleLoader.create({
      registry = registry,
      getRuntimeSnapshot = function() return { resources = { record } } end,
      checkCapability = function()
        if allow then return true end
        return SynexWorldValidation.failure('WORLD_ACCESS_DENIED', 'Denied.')
      end,
      loadResourceFile = function() return 'fixture-bundle' end,
      decode = function() return SynexWorldValidation.copy(current) end,
      getResourceState = function() return 'started' end,
      foundation = {},
      observability = { increment = function() end, audit = function() end },
    })
    local active = assert(loader.load('synex_fixture', 'world/base.world.json', false, 8, {}))
    assert(active.revision == 1)

    allow = false
    local denied, deniedError = loader.load(
      'synex_fixture', 'world/base.world.json', true, 8, {})
    assert(denied == nil and deniedError.code == 'WORLD_ACCESS_DENIED')
    assert(registry.get('synex_fixture:region').revision == 1)

    allow = true
    current = SynexWorldValidation.copy(candidate)
    current.objects[1].parent = 'synex_fixture:missing'
    local invalid, invalidError = loader.load(
      'synex_fixture', 'world/base.world.json', true, 8, {})
    assert(invalid == nil and invalidError.code == 'WORLD_REFERENCE_INVALID')
    assert(registry.get('synex_fixture:region').revision == 1)
    assert(loader.pathForBundle('synex_fixture', 'synex_fixture:world')
      == 'world/base.world.json')
    return deniedError.code .. ':' .. invalidError.code .. ':'
      .. registry.currentRevision()
  `, files);
  assert.equal(result, 'WORLD_ACCESS_DENIED:WORLD_REFERENCE_INVALID:1');
});

test('discovery stops immediately when an unresolved pass makes no progress', async () => {
  const result = await runWorldLua<string>(String.raw`
    local checks, reads = 0, 0
    local record = { name = 'synex_blocked', state = 'STARTED', epoch = 1,
      manifest = { worldBundles = { 'world/blocked.world.json' } } }
    local loader = SynexWorldBundleLoader.create({
      registry = SynexWorldRegistry.create({}),
      getRuntimeSnapshot = function() return { resources = { record } } end,
      checkCapability = function()
        checks = checks + 1
        return SynexWorldValidation.failure('WORLD_ACCESS_DENIED', 'Denied.')
      end,
      loadResourceFile = function() reads = reads + 1; return '{}' end,
      decode = function() return {} end,
      getResourceState = function() return 'started' end,
      foundation = {},
      observability = { increment = function() end, audit = function() end },
    })
    local report = assert(loader.discoverAll({ traceId = 'bounded_discovery' }))
    assert(#report.resources == 0 and #report.unresolved == 1
      and report.unresolved[1] == 'synex_blocked')
    assert(checks == 1 and reads == 0)
    return table.concat({ checks, reads, #report.unresolved }, ':')
  `, files);
  assert.equal(result, '1:0:1');
});

test('manifest and explicit removal purge transitively deactivated foreign path mappings for restart recovery', async () => {
  const result = await runWorldLua<string>(String.raw`
    local alpha = { schema = 1, key = 'synex_alpha:bundle', version = '1.0.0',
      dependencies = {}, objects = {
        { kind = 'region', key = 'synex_alpha:region',
          geometry = { type = 'sphere', center = { x = 0, y = 0, z = 0 }, radius = 100 } },
      } }
    local beta = { schema = 1, key = 'synex_beta:bundle', version = '1.0.0',
      dependencies = { 'synex_alpha' }, objects = {
        { kind = 'location', key = 'synex_beta:location', parent = 'synex_alpha:region',
          geometry = { type = 'sphere', center = { x = 0, y = 0, z = 0 }, radius = 50 } },
      } }
    local records = {
      { name = 'synex_beta', state = 'STARTED', epoch = 2,
        manifest = { worldBundles = { 'world/beta.world.json' } } },
      { name = 'synex_alpha', state = 'STARTED', epoch = 1,
        manifest = { worldBundles = { 'world/alpha.world.json' } } },
    }
    local registry = SynexWorldRegistry.create({})
    local loader = SynexWorldBundleLoader.create({
      registry = registry,
      getRuntimeSnapshot = function() return { resources = records } end,
      checkCapability = function() return true end,
      loadResourceFile = function(resource)
        return resource == 'synex_alpha' and 'alpha' or 'beta'
      end,
      decode = function(encoded)
        return SynexWorldValidation.copy(encoded == 'alpha' and alpha or beta)
      end,
      getResourceState = function() return 'started' end,
      foundation = {},
      observability = { increment = function() end, audit = function() end },
    })
    assert(loader.discoverAll({ traceId = 'initial' }))
    assert(registry.bundleCount() == 2)

    records[2].manifest.worldBundles = {}
    local manifestRemoval = assert(loader.discoverResource('synex_alpha',
      { traceId = 'manifest_removal' }))
    assert(#manifestRemoval.failures == 0 and registry.bundleCount() == 0)
    assert(loader.pathForBundle('synex_alpha', 'synex_alpha:bundle') == nil
      and loader.pathForBundle('synex_beta', 'synex_beta:bundle') == nil)

    records[2].manifest.worldBundles = { 'world/alpha.world.json' }
    local recovered = assert(loader.discoverAll({ traceId = 'dependency_recovered' }))
    assert(#recovered.unresolved == 0 and registry.bundleCount() == 2)
    assert(loader.pathForBundle('synex_alpha', 'synex_alpha:bundle')
      == 'world/alpha.world.json')
    assert(loader.pathForBundle('synex_beta', 'synex_beta:bundle')
      == 'world/beta.world.json')

    local explicit = assert(loader.unload('synex_alpha', 'synex_alpha:bundle', 1,
      { traceId = 'explicit_removal' }))
    assert(#explicit.removed == 2 and registry.bundleCount() == 0)
    assert(loader.pathForBundle('synex_alpha', 'synex_alpha:bundle') == nil
      and loader.pathForBundle('synex_beta', 'synex_beta:bundle') == nil)
    return table.concat({ manifestRemoval.loaded, #recovered.unresolved,
      #explicit.removed, registry.bundleCount() }, ':')
  `, files);
  assert.equal(result, '0:0:2:0');
});
