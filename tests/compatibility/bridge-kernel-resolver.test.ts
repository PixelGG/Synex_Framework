import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';

const kernel = path.join(process.cwd(), 'libraries', 'synex_bridge', 'kernel');
const modules = [
  'foundation.lua', 'catalogs.lua', 'mappings.lua',
  'telemetry.lua', 'resolver.lua', 'runtime.lua',
];

async function createKernel() {
  const engine = await new LuaFactory().createEngine();
  for (const moduleName of modules) {
    await engine.doString(await readFile(path.join(kernel, moduleName), 'utf8'));
  }
  return engine;
}

test('bridge telemetry handles timer wrap, epochs, warning-once, bounds, and cleanup', async () => {
  const engine = await createKernel();
  try {
    const result = await engine.doString(String.raw`
      local tick, timerEpoch, warnings = 14, 'boot-a', 0
      local telemetry = SynexBridgeKernel.Telemetry.create({
        timerModulus = 16, maximumOwners = 2, maximumSeries = 2,
        maximumSeriesPerOwner = 1, maximumWarningKeys = 2,
        clock = function() return tick end,
        clockEpoch = function() return timerEpoch end,
        warningSink = function(event)
          warnings = warnings + 1
          assert(event.error.code == 'COMPAT_API_DEPRECATED')
        end,
      })
      local token = assert(telemetry:start('legacy_resource', 7, 'QBCore.GetPlayer'))
      tick = 2
      assert(telemetry:finish(token, 'success') == 4)
      local snapshot = assert(telemetry:snapshot('legacy_resource', 7))
      assert(snapshot.count == 1 and snapshot.series[1].count == 1
        and snapshot.truncated == false)
      assert(snapshot.series[1].latency.totalMs == 4)
      assert(snapshot.series[1].outcomes.success == 1)
      assert(telemetry:warnOnce('legacy_resource', 7, 'compat.deprecated',
        'COMPAT_API_DEPRECATED', { surface = 'QBCore.GetPlayer' }) == true)
      assert(telemetry:warnOnce('legacy_resource', 7, 'compat.deprecated',
        'COMPAT_API_DEPRECATED') == false)
      assert(warnings == 1)

      local stale = assert(telemetry:start('legacy_resource', 7, 'QBCore.GetPlayer'))
      timerEpoch = 'boot-b'
      local _, staleError = telemetry:finish(stale, 'success')
      assert(staleError.code == 'COMPAT_STALE_SESSION')
      local _, limitError = telemetry:record(
        'legacy_resource', 7, 'QBCore.Other', 'error', 0
      )
      assert(limitError.code == 'COMPAT_REGISTRY_LIMIT')
      assert(telemetry:snapshot().truncated == true)
      assert(telemetry:cleanup('legacy_resource', 6) == 0)
      assert(telemetry:cleanup('legacy_resource', 7) == 2)
      local cleaned = assert(telemetry:snapshot())
      assert(cleaned.count == 0 and cleaned.truncated == true)
      assert(SynexBridgeKernel.Foundation.saturatingAdd(
        SynexBridgeKernel.Foundation.MAX_SAFE_INTEGER, 1
      ) == SynexBridgeKernel.Foundation.MAX_SAFE_INTEGER)
      return 'ok'
    `);
    assert.equal(result, 'ok');
  } finally {
    engine.global.close();
  }
});

test('bridge resolver follows consumer, provider, profile, surface, and adapter policy', async () => {
  const engine = await createKernel();
  try {
    const result = await engine.doString(String.raw`
      local warnings = 0
      local runtime = SynexBridgeKernel.Runtime.create({
        telemetry = {
          warningSink = function() warnings = warnings + 1 end,
        },
      })
      assert(runtime.adapters:register('synex_bridge', 3, {
        name = 'qb.player', version = '1.0.0', provider = 'qb', domain = 'identity',
        status = 'PARTIAL', operations = { 'read' },
      }, { read = function(value) return 'native:' .. value end }))
      local configured, configureError = runtime.resolver:configure('synex_bridge', 3, {
        defaultMode = 'strict',
        providers = { qb = true, qbx = false, esx = false },
        profiles = { {
          id = 'qb.default', version = '1.0.0', provider = 'qb', status = 'PARTIAL',
          mode = 'compat', failurePolicy = 'warn',
          providerVersion = '0.1.0', targetFrameworkApiRange = '^7.0.0',
          script = { name = 'legacy_resource' },
          evidence = {
            tests = { 'compatibility/evidence/qb-player.test.json' },
            sourceUrls = { 'https://example.invalid/qb-player' },
          },
          requiredSurfaces = { {
            name = 'QBCore.Functions.GetPlayer', acceptedStatuses = { 'PARTIAL' },
          } },
          requiredAdapters = { { name = 'qb.player', versionRange = '^1.0.0' } },
        }, {
          id = 'qb.strict', version = '1.0.0', provider = 'qb', status = 'PARTIAL',
          mode = 'strict', failurePolicy = 'disable',
          providerVersion = '0.1.0', targetFrameworkApiRange = '^7.0.0',
          script = { name = 'strict_resource' },
          evidence = {
            tests = { 'compatibility/evidence/qb-player.test.json' },
            sourceUrls = { 'https://example.invalid/qb-player' },
          },
          requiredSurfaces = { {
            name = 'QBCore.Functions.GetPlayer', acceptedStatuses = { 'PARTIAL' },
          } },
          requiredAdapters = { { name = 'qb.player', versionRange = nil } },
        }, {
          id = 'qb.silent', version = '1.0.0', provider = 'qb', status = 'PARTIAL',
          mode = 'silent', failurePolicy = 'warn',
          providerVersion = '0.1.0', targetFrameworkApiRange = '^7.0.0',
          script = { name = 'silent_resource' },
          evidence = {
            tests = { 'compatibility/evidence/qb-player.test.json' },
            sourceUrls = { 'https://example.invalid/qb-player' },
          },
          requiredSurfaces = { {
            name = 'QBCore.Functions.GetPlayer', acceptedStatuses = { 'PARTIAL' },
          } },
          requiredAdapters = { { name = 'qb.player', versionRange = '*' } },
        } },
        surfaces = { {
          name = 'QBCore.Functions.GetPlayer', provider = 'qb', status = 'PARTIAL',
          modes = { 'compat', 'silent' }, deprecated = true,
          requiredCapability = 'synex.compat.qb.read', requiredAdapter = 'qb.player',
          adapterOperations = { {
            name = 'read', nativeCapabilities = { 'synex.identity.read' },
          } },
        } },
        consumers = {
          { resource = 'legacy_resource', provider = 'qb', mode = 'compat',
            profileId = 'qb.default', failurePolicy = 'warn', enabled = true },
          { resource = 'strict_resource', provider = 'qb',
            profileId = 'qb.strict', failurePolicy = 'disable', enabled = true },
          { resource = 'silent_resource', provider = 'qb', mode = 'silent',
            profileId = 'qb.silent', failurePolicy = 'warn', enabled = true },
        },
      })
      assert(configured and configureError == nil and configured.consumers == 3)
      local resolution, resolveError, action = runtime.resolver:resolve(
        'legacy_resource', 'QBCore.Functions.GetPlayer', 'read'
      )
      assert(resolution and resolveError == nil and action == nil)
      assert(resolution.handler('character') == 'native:character')
      assert(resolution.mode == 'compat' and resolution.adapter.version == '1.0.0')
      assert(warnings == 1)
      assert(runtime.resolver:resolve(
        'legacy_resource', 'QBCore.Functions.GetPlayer', 'read'
      ))
      assert(warnings == 1)
      assert(runtime.resolver:resolve(
        'silent_resource', 'QBCore.Functions.GetPlayer', 'read'
      ))
      assert(warnings == 1)

      local _, strictError, strictAction = runtime.resolver:resolve(
        'strict_resource', 'QBCore.Functions.GetPlayer', 'read'
      )
      assert(strictError.code == 'COMPAT_PROFILE_INCOMPLETE' and strictAction == 'disable')
      local _, disabledError = runtime.resolver:resolve(
        'strict_resource', 'QBCore.Functions.GetPlayer', 'read'
      )
      assert(disabledError.code == 'COMPAT_PROVIDER_DISABLED')
      local _, deniedError, deniedAction = runtime.resolver:resolve(
        'unknown_resource', 'QBCore.Functions.GetPlayer', 'read'
      )
      assert(deniedError.code == 'COMPAT_CONSUMER_DENIED' and deniedAction == 'fail_start')
      assert(runtime:cleanup('synex_bridge', 2).resolver == 0)
      local removed = assert(runtime:cleanup('synex_bridge', 3))
      assert(removed.resolver == 3 and removed.adapters == 1)
      return 'ok'
    `);
    assert.equal(result, 'ok');
  } finally {
    engine.global.close();
  }
});

test('bridge resolver binds catalogs to consumer policy and exact revisions', async () => {
  const engine = await createKernel();
  try {
    const result = await engine.doString(String.raw`
      local runtime = SynexBridgeKernel.Runtime.create()
      assert(runtime.catalogs:register('synex_inventory', 4, {
        name = 'inventory.items', version = '1.2.0', provider = 'all',
        domain = 'inventory', status = 'PARTIAL', authority = 'domain',
        revision = 7, operations = { 'item.lookup' },
      }, {
        ['item.lookup'] = function(_, payload) return { item = payload.item } end,
      }))
      local config = {
        providers = { qb = true },
        profiles = { {
          id = 'qb.catalog', version = '1.0.0', provider = 'qb', status = 'PARTIAL',
          mode = 'compat', failurePolicy = 'fail_start',
          providerVersion = '0.1.0', targetFrameworkApiRange = '^7.0.0',
          script = { name = 'legacy_resource' },
          evidence = {
            tests = { 'compatibility/evidence/qb-catalog.test.json' },
            sourceUrls = { 'https://example.invalid/qb-catalog' },
          },
          requiredSurfaces = { {
            name = 'qb.inventory.catalog', acceptedStatuses = { 'PARTIAL' },
          } },
          requiredAdapters = {},
          requiredCatalogs = { {
            name = 'inventory.items', versionRange = '^1.0.0',
            domain = 'inventory', revision = 7,
          } },
        } },
        surfaces = { {
          name = 'qb.inventory.catalog', provider = 'qb', status = 'PARTIAL',
          modes = { 'compat' }, deprecated = false,
          requiredCapability = 'synex.compat.qb.read', requiredAdapter = nil,
          adapterOperations = {}, requiredCatalog = 'inventory.items',
          catalogOperations = { {
            name = 'item.lookup', nativeCapabilities = {
              'synex.inventory.read', 'synex.identity.read',
            },
          } },
        } },
        consumers = { {
          resource = 'legacy_resource', provider = 'qb', mode = 'compat',
          profileId = 'qb.catalog', failurePolicy = 'fail_start', enabled = true,
        } },
      }
      assert(runtime.resolver:configure('synex_bridge', 4, config))
      local resolved = assert(runtime.resolver:resolve(
        'legacy_resource', 'qb.inventory.catalog', 'item.lookup'))
      assert(resolved.catalog.name == 'inventory.items'
        and resolved.catalog.version == '1.2.0' and resolved.catalog.revision == 7
        and resolved.catalog.authority == 'domain'
        and resolved.catalogOperation.nativeCapabilities[1] == 'synex.inventory.read')
      assert(resolved.catalogHandler({}, { item = 'water' }).item == 'water')
      local _, operationError = runtime.resolver:resolve(
        'legacy_resource', 'qb.inventory.catalog', 'item.delete')
      assert(operationError.code == 'COMPAT_API_UNSUPPORTED')

      local stale = SynexBridgeKernel.Runtime.create()
      assert(stale.catalogs:register('synex_inventory', 4, {
        name = 'inventory.items', version = '1.2.0', provider = 'all',
        domain = 'inventory', status = 'PARTIAL', authority = 'domain',
        revision = 8, operations = { 'item.lookup' },
      }, { ['item.lookup'] = function() return {} end }))
      config.profiles[1].requiredCatalogs[1].revision = 7
      assert(stale.resolver:configure('synex_bridge', 4, config))
      local _, revisionError = stale.resolver:resolve(
        'legacy_resource', 'qb.inventory.catalog', 'item.lookup')
      assert(revisionError.code == 'COMPAT_VERSION_CONFLICT')

      local strict = SynexBridgeKernel.Runtime.create()
      assert(strict.catalogs:register('synex_inventory', 4, {
        name = 'inventory.items', version = '1.2.0', provider = 'all',
        domain = 'inventory', status = 'PARTIAL', authority = 'domain',
        revision = 7, operations = { 'item.lookup' },
      }, { ['item.lookup'] = function() return {} end }))
      config.profiles[1].status = 'COMPATIBLE'
      config.profiles[1].mode = 'strict'
      config.profiles[1].requiredSurfaces[1].acceptedStatuses = { 'COMPATIBLE' }
      config.surfaces[1].status = 'COMPATIBLE'
      config.surfaces[1].modes = { 'strict' }
      config.consumers[1].mode = 'strict'
      assert(strict.resolver:configure('synex_bridge', 4, config))
      local _, strictCatalogError = strict.resolver:resolve(
        'legacy_resource', 'qb.inventory.catalog', 'item.lookup')
      assert(strictCatalogError.code == 'COMPAT_CATALOG_UNAVAILABLE')

      config.profiles[1].status = 'PARTIAL'
      config.profiles[1].mode = 'compat'
      config.profiles[1].requiredSurfaces[1].acceptedStatuses = { 'PARTIAL' }
      config.surfaces[1].status = 'PARTIAL'
      config.surfaces[1].modes = { 'compat' }
      config.consumers[1].mode = 'compat'

      config.surfaces[1].requiredAdapter = 'qb.inventory'
      local invalid = SynexBridgeKernel.Runtime.create()
      local _, dualError = invalid.resolver:configure('synex_bridge', 4, config)
      assert(dualError.code == 'COMPAT_INVALID_ARGUMENT')
      config.surfaces[1].requiredAdapter = nil
      config.profiles[1].requiredCatalogs[1].domain = 'invented'
      local invalidDomain = SynexBridgeKernel.Runtime.create()
      local _, domainError = invalidDomain.resolver:configure(
        'synex_bridge', 4, config)
      assert(domainError.code == 'COMPAT_INVALID_ARGUMENT')
      local removed = assert(runtime:cleanup('synex_inventory', 4))
      assert(removed.catalogs == 1 and removed.catalogTelemetry == 0)
      return 'ok'
    `);
    assert.equal(result, 'ok');
  } finally {
    engine.global.close();
  }
});

test('bridge resolver fails closed for missing adapters and provider conflicts', async () => {
  const engine = await createKernel();
  try {
    const result = await engine.doString(String.raw`
      local runtime = SynexBridgeKernel.Runtime.create()
      assert(runtime.resolver:configure('synex_bridge', 1, {
        providers = { qb = true },
        profiles = { {
          id = 'qb.default', version = '1.0.0', provider = 'qb', status = 'PARTIAL',
          mode = 'compat', failurePolicy = 'fail_start',
          providerVersion = '0.1.0', targetFrameworkApiRange = '^7.0.0',
          script = { name = 'legacy_resource' },
          evidence = {
            tests = { 'compatibility/evidence/qb-player.test.json' },
            sourceUrls = { 'https://example.invalid/qb-player' },
          },
          requiredSurfaces = { {
            name = 'QBCore.Functions.GetPlayer', acceptedStatuses = { 'PARTIAL' },
          } },
          requiredAdapters = { { name = 'qb.player', versionRange = '~1.0.0' } },
        } },
        surfaces = { {
          name = 'QBCore.Functions.GetPlayer', provider = 'qb', status = 'PARTIAL',
          modes = { 'compat' }, deprecated = false,
          requiredCapability = 'synex.compat.qb.read', requiredAdapter = 'qb.player',
          adapterOperations = { {
            name = 'read', nativeCapabilities = { 'synex.identity.read' },
          } },
        } },
        consumers = { {
          resource = 'legacy_resource', provider = 'qb', mode = 'compat',
          profileId = 'qb.default', failurePolicy = 'fail_start', enabled = true,
        } },
      }))
      local _, adapterError, action = runtime.resolver:resolve(
        'legacy_resource', 'QBCore.Functions.GetPlayer', 'read'
      )
      assert(adapterError.code == 'COMPAT_ADAPTER_MISSING' and action == 'fail_start')
      local _, ownerError = runtime.resolver:configure('other_bridge', 1, {
        providers = { qb = true }, profiles = {}, surfaces = {}, consumers = { {
          resource = 'legacy_resource', provider = 'qb', profileId = 'qb.default',
          failurePolicy = 'warn', enabled = true,
        } },
      })
      assert(ownerError.code == 'COMPAT_OWNER_CONFLICT')
      return 'ok'
    `);
    assert.equal(result, 'ok');
  } finally {
    engine.global.close();
  }
});

test('bridge resolver downgrades unverified certification and honors bounded adapter ranges', async () => {
  const engine = await createKernel();
  try {
    const result = await engine.doString(String.raw`
      local runtime = SynexBridgeKernel.Runtime.create()
      assert(runtime.adapters:register('adapter_v1', 1, {
        name = 'qb.player', version = '1.4.0', provider = 'qb', domain = 'identity',
        status = 'PARTIAL', operations = { 'read' },
      }, { read = function() return 'v1' end }))
      assert(runtime.adapters:register('adapter_v2', 1, {
        name = 'qb.player', version = '2.1.0', provider = 'qb', domain = 'identity',
        status = 'PARTIAL', operations = { 'read' },
      }, { read = function() return 'v2' end }))

      local function configuration(verified, range)
        return {
          providers = { qb = true },
          profiles = { {
            id = 'qb.certified', version = '1.0.0-beta.1', provider = 'qb',
            mode = 'compat', status = 'CERTIFIED', failurePolicy = 'fail_start',
            providerVersion = '0.1.0', targetFrameworkApiRange = '^7.0.0',
            certificationArtifact = 'compatibility/certifications/qb.certified.json',
            script = { name = 'legacy_resource', testedVersion = '2.0.0' },
            evidence = {
              tests = { 'compatibility/evidence/qb-player.test.json' },
              sourceUrls = { 'https://example.invalid/qb-player' },
            },
            certificationVerified = verified,
            requiredSurfaces = { {
              name = 'QBCore.Functions.GetPlayer', acceptedStatuses = { 'PARTIAL' },
            } },
            requiredAdapters = { { name = 'qb.player', versionRange = range } },
          } },
          surfaces = { {
            name = 'QBCore.Functions.GetPlayer', provider = 'qb', status = 'PARTIAL',
            modes = { 'compat' }, deprecated = false,
            requiredCapability = 'synex.compat.qb.read', requiredAdapter = 'qb.player',
            adapterOperations = { {
              name = 'read', nativeCapabilities = { 'synex.identity.read' },
            } },
          } },
          consumers = { {
            resource = 'legacy_resource', provider = 'qb', mode = 'compat',
            profileId = 'qb.certified', failurePolicy = 'fail_start', enabled = true,
          } },
        }
      end

      assert(runtime.resolver:configure('synex_bridge', 1,
        configuration(false, '^1.0.0 || >=2.0.0 <3.0.0')))
      local denied, deniedError = runtime.resolver:resolve(
        'legacy_resource', 'QBCore.Functions.GetPlayer', 'read')
      assert(denied == nil and deniedError.code == 'COMPAT_PROFILE_INCOMPLETE')

      assert(runtime.resolver:configure('synex_bridge', 2,
        configuration(true, '^1.0.0 || >=2.0.0 <3.0.0')))
      local selected = assert(runtime.resolver:resolve(
        'legacy_resource', 'QBCore.Functions.GetPlayer', 'read'))
      assert(selected.adapter.version == '2.1.0' and selected.handler() == 'v2')

      assert(runtime.resolver:configure('synex_bridge', 3,
        configuration(true, nil)))
      local unbounded = assert(runtime.resolver:resolve(
        'legacy_resource', 'QBCore.Functions.GetPlayer', 'read'))
      assert(unbounded.adapter.version == '2.1.0')
      return deniedError.code .. ':' .. selected.adapter.version
    `);
    assert.equal(result, 'COMPAT_PROFILE_INCOMPLETE:2.1.0');
  } finally {
    engine.global.close();
  }
});
