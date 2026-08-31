import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';

const root = process.cwd();

async function createEngine() {
  const engine = await new LuaFactory().createEngine();
  for (const relativePath of [
    'core/synex_core/shared/protocol.lua',
    'core/synex_core/server/factories.lua',
    'core/synex_core/server/foundation.lua',
    'core/synex_core/server/resource_manifest.lua',
  ]) {
    await engine.doString(await readFile(path.join(root, relativePath), 'utf8'));
  }
  await engine.doString(`
    FakePlatform = { print = function() end, random = function() return 1 end }
    function ValidManifest()
      return {
        schema = 1, name = 'synex_fixture', version = '0.1.0', synex = '^1.0.0', critical = false,
        capabilities = { request = {} },
        services = { provide = {}, require = {}, optional = {} },
        contracts = { provide = {}, consume = {} },
        events = { publish = {}, subscribe = {} },
        hooks = { register = {}, run = {} },
        dependencies = { required = {}, optional = {}, development = {} },
        migrations = {},
        dataOwnership = { tables = {}, characterDelete = 'none' },
        stateSnapshot = { supported = false, schemaVersion = 1 }
      }
    end
  `);
  return engine;
}

test('runtime resource manifest validation accepts the exact canonical shape', async () => {
  const engine = await createEngine();
  try {
    const result = await engine.doString(`
      local foundation = SynexCoreFactories.foundation({ platform = FakePlatform })
      local validator = SynexCoreFactories.resourceManifest({ foundation = foundation })
      assert(validator:validate('synex_fixture', ValidManifest()))
      return true
    `);
    assert.equal(result, true);
  } finally {
    engine.global.close();
  }
});

test('runtime resource manifest validation matches world bundle path constraints', async () => {
  const engine = await createEngine();
  try {
    const result = await engine.doString(`
      local foundation = SynexCoreFactories.foundation({ platform = FakePlatform })
      local validator = SynexCoreFactories.resourceManifest({ foundation = foundation })

      local valid = ValidManifest()
      valid.worldBundles = { 'world/city/base.world.json', 'world/interiors/mrpd-1.world.json' }
      assert(validator:validate('synex_fixture', valid))

      local traversal = ValidManifest()
      traversal.worldBundles = { 'world/../outside.world.json' }
      local _, traversalError = validator:validate('synex_fixture', traversal)
      assert(traversalError.code == 'INVALID_RESOURCE_MANIFEST')

      local dotSegment = ValidManifest()
      dotSegment.worldBundles = { 'world/city/./base.world.json' }
      local _, dotSegmentError = validator:validate('synex_fixture', dotSegment)
      assert(dotSegmentError.code == 'INVALID_RESOURCE_MANIFEST')

      local duplicateSeparator = ValidManifest()
      duplicateSeparator.worldBundles = { 'world/city//base.world.json' }
      local _, duplicateSeparatorError = validator:validate('synex_fixture', duplicateSeparator)
      assert(duplicateSeparatorError.code == 'INVALID_RESOURCE_MANIFEST')

      local wrongRoot = ValidManifest()
      wrongRoot.worldBundles = { 'bundles/base.world.json' }
      local _, wrongRootError = validator:validate('synex_fixture', wrongRoot)
      assert(wrongRootError.code == 'INVALID_RESOURCE_MANIFEST')

      local duplicate = ValidManifest()
      duplicate.worldBundles = { 'world/base.world.json', 'world/base.world.json' }
      local _, duplicateError = validator:validate('synex_fixture', duplicate)
      assert(duplicateError.code == 'INVALID_RESOURCE_MANIFEST')
      return true
    `);
    assert.equal(result, true);
  } finally {
    engine.global.close();
  }
});

test('runtime resource manifest validation matches interaction bundle path constraints', async () => {
  const engine = await createEngine();
  try {
    const result = await engine.doString(`
      local foundation = SynexCoreFactories.foundation({ platform = FakePlatform })
      local validator = SynexCoreFactories.resourceManifest({ foundation = foundation })

      local valid = ValidManifest()
      valid.interactionBundles = {
        'interactions/terminal.interact.json',
        'interactions/vehicles/trunk-1.interact.json'
      }
      assert(validator:validate('synex_fixture', valid))

      local traversal = ValidManifest()
      traversal.interactionBundles = { 'interactions/../outside.interact.json' }
      local _, traversalError = validator:validate('synex_fixture', traversal)
      assert(traversalError.code == 'INVALID_RESOURCE_MANIFEST')

      local dotSegment = ValidManifest()
      dotSegment.interactionBundles = { 'interactions/vehicles/./trunk.interact.json' }
      local _, dotSegmentError = validator:validate('synex_fixture', dotSegment)
      assert(dotSegmentError.code == 'INVALID_RESOURCE_MANIFEST')

      local duplicateSeparator = ValidManifest()
      duplicateSeparator.interactionBundles = { 'interactions/vehicles//trunk.interact.json' }
      local _, duplicateSeparatorError = validator:validate('synex_fixture', duplicateSeparator)
      assert(duplicateSeparatorError.code == 'INVALID_RESOURCE_MANIFEST')

      local wrongRoot = ValidManifest()
      wrongRoot.interactionBundles = { 'world/terminal.interact.json' }
      local _, wrongRootError = validator:validate('synex_fixture', wrongRoot)
      assert(wrongRootError.code == 'INVALID_RESOURCE_MANIFEST')

      local wrongSuffix = ValidManifest()
      wrongSuffix.interactionBundles = { 'interactions/terminal.json' }
      local _, wrongSuffixError = validator:validate('synex_fixture', wrongSuffix)
      assert(wrongSuffixError.code == 'INVALID_RESOURCE_MANIFEST')

      local duplicate = ValidManifest()
      duplicate.interactionBundles = {
        'interactions/terminal.interact.json',
        'interactions/terminal.interact.json'
      }
      local _, duplicateError = validator:validate('synex_fixture', duplicate)
      assert(duplicateError.code == 'INVALID_RESOURCE_MANIFEST')
      return true
    `);
    assert.equal(result, true);
  } finally {
    engine.global.close();
  }
});

test('runtime control provider validation accepts canonical access, search, numeric-string, and boolean fields', async () => {
  const engine = await createEngine();
  try {
    const result = await engine.doString(`
      local foundation = SynexCoreFactories.foundation({ platform = FakePlatform })
      local validator = SynexCoreFactories.resourceManifest({ foundation = foundation })
      local valid = ValidManifest()
      valid.controlProvider = {
        schemaVersion = 1,
        namespace = 'fixture',
        label = 'Fixture',
        category = 'system',
        version = '1.0.0',
        operations = { 'summary', 'health', 'search' },
        views = {
          { id = 'summary', label = 'Summary', operation = 'summary', presentation = 'key-value', accessClass = 'general' },
          { id = 'health', label = 'Health', operation = 'health', presentation = 'metrics', accessClass = 'audit' },
          {
            id = 'search', label = 'Search', operation = 'search', presentation = 'table', accessClass = 'identifiers',
            search = { kinds = { { id = 'fixture', modes = { 'exact', 'prefix' }, accessClass = 'identifiers' } } },
            input = { fields = {
              { key = 'identifier', label = 'Identifier', source = 'filter', type = 'string', format = 'numeric-string', required = true, minLength = 1, maxLength = 32 },
              { key = 'enabled', label = 'Enabled', source = 'filter', type = 'boolean', format = 'boolean', required = false }
            } }
          }
        }
      }
      assert(validator:validate('synex_fixture', valid))

      local invalidStringBoolean = ValidManifest()
      invalidStringBoolean.controlProvider = valid.controlProvider
      invalidStringBoolean.controlProvider.views[3].input.fields[1].format = 'boolean'
      local _, stringBooleanError = validator:validate('synex_fixture', invalidStringBoolean)
      assert(stringBooleanError.code == 'INVALID_RESOURCE_MANIFEST')
      valid.controlProvider.views[3].input.fields[1].format = 'numeric-string'

      local invalidAccess = ValidManifest()
      invalidAccess.controlProvider = valid.controlProvider
      invalidAccess.controlProvider.views[1].accessClass = 'root'
      local _, accessError = validator:validate('synex_fixture', invalidAccess)
      assert(accessError.code == 'INVALID_RESOURCE_MANIFEST')

      valid.controlProvider.views[1].accessClass = 'general'
      local invalidSearch = ValidManifest()
      invalidSearch.controlProvider = valid.controlProvider
      invalidSearch.controlProvider.views[1].search = valid.controlProvider.views[3].search
      local _, searchError = validator:validate('synex_fixture', invalidSearch)
      assert(searchError.code == 'INVALID_RESOURCE_MANIFEST')
      return true
    `);
    assert.equal(result, true);
  } finally {
    engine.global.close();
  }
});

test('runtime resource manifest validation rejects unknown keys, traversal, duplicates, and non-canonical versions', async () => {
  const engine = await createEngine();
  try {
    const result = await engine.doString(`
      local foundation = SynexCoreFactories.foundation({ platform = FakePlatform })
      local validator = SynexCoreFactories.resourceManifest({ foundation = foundation })

      local unknown = ValidManifest()
      unknown.capabilities.implicitGrant = true
      local _, unknownError = validator:validate('synex_fixture', unknown)
      assert(unknownError.code == 'INVALID_RESOURCE_MANIFEST')

      local traversal = ValidManifest()
      traversal.migrations = {{ id = '001_escape', path = 'migrations/../escape.sql', transactional = false }}
      local _, traversalError = validator:validate('synex_fixture', traversal)
      assert(traversalError.code == 'INVALID_RESOURCE_MANIFEST')

      local duplicate = ValidManifest()
      duplicate.dependencies.required = {{ name = 'oxmysql', version = '>=2.14.1' }}
      duplicate.dependencies.optional = {{ name = 'oxmysql', version = '>=2.14.1' }}
      local _, duplicateError = validator:validate('synex_fixture', duplicate)
      assert(duplicateError.code == 'INVALID_RESOURCE_MANIFEST')

      local service = ValidManifest()
      service.services.provide = {'synex.fixture..read@1'}
      local _, serviceError = validator:validate('synex_fixture', service)
      assert(serviceError.code == 'INVALID_RESOURCE_MANIFEST')

      local version = ValidManifest()
      version.version = '01.0.0'
      local _, versionError = validator:validate('synex_fixture', version)
      assert(versionError.code == 'INVALID_RESOURCE_MANIFEST')

      local foreignEvent = ValidManifest()
      foreignEvent.events.publish = {'synex.accounts.changed'}
      local _, foreignEventError = validator:validate('synex_fixture', foreignEvent)
      assert(foreignEventError.code == 'INVALID_RESOURCE_MANIFEST')

      local malformedWildcard = ValidManifest()
      malformedWildcard.events.subscribe = {'synex.*.changed'}
      local _, malformedWildcardError = validator:validate('synex_fixture', malformedWildcard)
      assert(malformedWildcardError.code == 'INVALID_RESOURCE_MANIFEST')

      local ownedEvent = ValidManifest()
      ownedEvent.events.publish = {'synex.fixture.*'}
      assert(validator:validate('synex_fixture', ownedEvent))

      local foreignHookRun = ValidManifest()
      foreignHookRun.hooks.run = {'synex.characters.before_create'}
      local _, foreignHookRunError = validator:validate('synex_fixture', foreignHookRun)
      assert(foreignHookRunError.code == 'INVALID_RESOURCE_MANIFEST')

      local extensionHook = ValidManifest()
      extensionHook.hooks.register = {'synex.characters.before_create'}
      assert(validator:validate('synex_fixture', extensionHook))

      local malformedHook = ValidManifest()
      malformedHook.hooks.register = {'synex.characters.*.before_create'}
      local _, malformedHookError = validator:validate('synex_fixture', malformedHook)
      assert(malformedHookError.code == 'INVALID_RESOURCE_MANIFEST')
      return table.concat({ unknownError.code, traversalError.code, duplicateError.code, serviceError.code,
        versionError.code, foreignEventError.code, malformedWildcardError.code,
        foreignHookRunError.code, malformedHookError.code }, ':')
    `);
    assert.equal(result, [
      'INVALID_RESOURCE_MANIFEST',
      'INVALID_RESOURCE_MANIFEST',
      'INVALID_RESOURCE_MANIFEST',
      'INVALID_RESOURCE_MANIFEST',
      'INVALID_RESOURCE_MANIFEST',
      'INVALID_RESOURCE_MANIFEST',
      'INVALID_RESOURCE_MANIFEST',
      'INVALID_RESOURCE_MANIFEST',
      'INVALID_RESOURCE_MANIFEST',
    ].join(':'));
  } finally {
    engine.global.close();
  }
});
