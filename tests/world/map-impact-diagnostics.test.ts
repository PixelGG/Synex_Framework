import assert from 'node:assert/strict';
import test from 'node:test';
import { runWorldLua } from './helpers.ts';

const files = [
  'shared/limits.lua',
  'shared/validation.lua',
  'server/map_registry.lua',
  'server/diagnostics.lua',
  'server/control_provider.lua',
] as const;

test('Control and Doctor expose the same bounded map outage impact', async () => {
  const result = await runWorldLua<string>(String.raw`
    local package = { kind = 'map_package', key = 'synex_test:map',
      resourceName = 'synex_map_asset', expectedResourceState = 'started', required = true,
      locations = { 'synex_test:location' }, dependencies = {},
      bundleKey = 'synex_test:maps', revision = 4 }
    local location = { kind = 'location', key = 'synex_test:location',
      bundleKey = 'synex_test:semantic', revision = 4 }
    local anchor = { kind = 'anchor', key = 'synex_test:anchor',
      parent = location.key, bundleKey = 'synex_test:semantic', revision = 4 }
    local door = { kind = 'door', key = 'synex_test:door',
      parent = location.key, bundleKey = 'synex_test:doors', revision = 4 }
    local objects = { [package.key] = package, [location.key] = location,
      [anchor.key] = anchor, [door.key] = door }
    local registry = {
      objects = function() return objects end,
      graph = function() return { children = {
        [location.key] = { anchor.key, door.key },
      } } end,
      currentRevision = function() return 4 end,
      get = function(key, kind)
        local value = objects[key]
        if value and (kind == nil or value.kind == kind) then return value end
        return SynexWorldValidation.failure('WORLD_NOT_FOUND', 'missing')
      end,
      bundles = function() return { ['synex_test:maps'] = {
        key = 'synex_test:maps', dependencies = {} } } end,
      listObjects = function(kind)
        return kind == 'map_package' and { package } or {}, nil
      end,
      listBundles = function() return {}, nil end,
      children = function() return {} end,
      bundleCount = function() return 1 end,
      objectCount = function() return 4 end,
      spatial = function() return { diagnostics = function()
        return { maximumCandidates = 0 }
      end } end,
    }
    local maps = SynexWorldMapRegistry.create({ registry = registry,
      getResourceState = function(resource)
        return resource == 'synex_map_asset' and 'stopped' or 'started'
      end })
    local instances = {
      list = function() return {}, nil end,
      summary = function() return { total = 0 } end,
    }
    local diagnostics = SynexWorldDiagnostics.create({
      foundation = {
        healthSnapshot = function() return { state = 'READY' } end,
        utc = function() return '2026-08-27T00:00:00Z' end,
      }, registry = registry, mapRegistry = maps, instances = instances,
      slices = { summary = function() return { bytes = 0, clients = 0 } end },
      outbox = { status = function() return { dead = 0 } end },
      database = {},
      getResourceState = function(resource)
        return resource == 'synex_map_asset' and 'stopped' or 'started'
      end,
    })
    local report = assert(diagnostics.doctor({ limit = 10, includePersistence = false }))
    assert(#report.items == 1 and report.items[1].code == 'MAP_RESOURCE_UNAVAILABLE')
    local doctorImpact = report.items[1].details.impact
    assert(doctorImpact.bundles.count == 3 and doctorImpact.locations.count == 1
      and doctorImpact.anchors.count == 1 and doctorImpact.doors.count == 1)

    local provider = SynexWorldControlProvider.create({ foundation = {}, registry = registry,
      mapRegistry = maps, instances = instances, diagnostics = diagnostics,
      contextResolver = {}, project = function(object) return { key = object.key } end })
    local page = assert(provider.operations.list({ view = 'map_packages', limit = 25 }))
    local controlImpact = page.items[1].impact
    assert(controlImpact.bundles.count == doctorImpact.bundles.count
      and controlImpact.locations.count == doctorImpact.locations.count
      and controlImpact.anchors.count == doctorImpact.anchors.count
      and controlImpact.doors.count == doctorImpact.doors.count)
    assert(#controlImpact.bundles.samples <= 8 and not controlImpact.traversalTruncated)
    return table.concat({ controlImpact.bundles.count, controlImpact.locations.count,
      controlImpact.anchors.count, controlImpact.doors.count }, ':')
  `, files);
  assert.equal(result, '3:1:1:1');
});
