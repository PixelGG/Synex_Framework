import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';

const kernel = path.join(process.cwd(), 'libraries', 'synex_bridge', 'kernel');

async function createKernel() {
  const engine = await new LuaFactory().createEngine();
  await engine.doString(await readFile(path.join(kernel, 'foundation.lua'), 'utf8'));
  await engine.doString(await readFile(path.join(kernel, 'catalogs.lua'), 'utf8'));
  await engine.doString(await readFile(path.join(kernel, 'mappings.lua'), 'utf8'));
  return engine;
}

test('bridge adapter registry is owner-bound, versioned, bounded, and executable', async () => {
  const engine = await createKernel();
  try {
    const result = await engine.doString(String.raw`
      local adapters = SynexBridgeKernel.Catalogs.createAdapters({
        maximumEntries = 2, maximumEntriesPerOwner = 2, maximumOwners = 2,
      })
      local definition = {
        name = 'qb.player', version = '1.0.0', provider = 'qb', domain = 'identity',
        status = 'PARTIAL', operations = { 'read', 'write' },
      }
      local implementation = {
        read = function(value) return 'read:' .. value end,
        write = setmetatable({ prefix = 'write:' }, {
          __call = function(self, value) return self.prefix .. value end,
        }),
      }
      local registered, registrationError = adapters:register(
        'synex_bridge', 1, definition, implementation
      )
      assert(registered and registrationError == nil)
      definition.status = 'CERTIFIED'
      assert(adapters:get('qb.player', 1).status == 'PARTIAL')
      local handler, resolved = adapters:resolve('qb.player', 1, 'write')
      assert(handler('value') == 'write:value' and resolved.version == '1.0.0')

      local _, ownerError = adapters:register('foreign_resource', 1, {
        name = 'qb.player', version = '1.1.0', provider = 'qb', domain = 'identity',
        status = 'PARTIAL', operations = { 'read', 'write' },
      }, implementation)
      assert(ownerError.code == 'COMPAT_OWNER_CONFLICT')
      local _, versionError = adapters:register('synex_bridge', 0, definition, implementation)
      assert(versionError.code == 'COMPAT_INVALID_ARGUMENT')

      local upgraded = {
        name = 'qb.player', version = '1.1.0', provider = 'qb', domain = 'identity',
        status = 'COMPATIBLE', operations = { 'read', 'write' },
      }
      assert(adapters:register('synex_bridge', 2, upgraded, implementation))
      assert(adapters:cleanup('synex_bridge', 1) == 0)
      assert(adapters:resolve('qb.player', 1, 'read')('x') == 'read:x')
      assert(adapters:cleanup('synex_bridge', 2) == 1)
      local _, missingError = adapters:resolve('qb.player', 1, 'read')
      assert(missingError.code == 'COMPAT_ADAPTER_MISSING')
      return 'ok'
    `);
    assert.equal(result, 'ok');
  } finally {
    engine.global.close();
  }
});

test('bridge mapping registries reject ambiguity and reserved metadata', async () => {
  const engine = await createKernel();
  try {
    const result = await engine.doString(String.raw`
      local mappings = SynexBridgeKernel.Mappings.create({ limits = {
        maximumEntries = 8, maximumEntriesPerOwner = 8, maximumOwners = 2,
      } })
      local identity = {
        id = 'qb.identity', version = '1.0.0', provider = 'qb', entityKind = 'character',
        legacyId = 'citizen-1', nativeId = 'character-1', status = 'PARTIAL',
      }
      assert(mappings.identity:register('synex_bridge', 4, identity))
      identity.nativeId = 'mutated'
      assert(mappings:resolveIdentity('qb', 'character', 'legacy', 'citizen-1').nativeId
        == 'character-1')
      local _, conflict = mappings.identity:register('other_bridge', 1, {
        id = 'qb.other', version = '1.0.0', provider = 'qb', entityKind = 'character',
        legacyId = 'citizen-1', nativeId = 'character-2', status = 'PARTIAL',
      })
      assert(conflict.code == 'COMPAT_IDENTITY_CONFLICT')
      assert(SynexBridgeKernel.Foundation.isIdentifier('cash'))
      assert(SynexBridgeKernel.Foundation.isIdentifier('wallet'))
      assert(SynexBridgeKernel.Foundation.isBoundedString('USD', 3, 3, '^[A-Z][A-Z][A-Z]$'))

      local account, accountError = mappings.accounts:register('synex_bridge', 4, {
        id = 'qb.cash', version = '2.0.0', provider = 'qb', alias = 'cash',
        currencyCode = 'usd', accountKey = 'cash', accountRole = 'asset',
        minorUnit = 0, status = 'PARTIAL',
        fundingPolicy = { kind = 'deny' }, sinkPolicy = { kind = 'deny' },
      })
      assert(account, accountError and accountError.code)
      local resolvedAccount = mappings:resolveAccount('qb', 'cash')
      assert(resolvedAccount.currencyCode == 'usd'
        and resolvedAccount.accountKey == 'cash'
        and resolvedAccount.accountRole == 'asset'
        and resolvedAccount.minorUnit == 0)
      local _, ambiguousAccount = mappings.accounts:register('synex_bridge', 4, {
        id = 'qb.wallet', version = '2.0.0', provider = 'qb', alias = 'wallet',
        currencyCode = 'usd', accountKey = 'cash', accountRole = 'asset',
        minorUnit = 0, status = 'PARTIAL',
        fundingPolicy = { kind = 'deny' }, sinkPolicy = { kind = 'deny' },
      })
      assert(ambiguousAccount.code == 'COMPAT_MAPPING_AMBIGUOUS')
      local group, groupError = mappings.groups:register('synex_bridge', 4, {
        id = 'qb.police', version = '1.0.0', provider = 'qb', legacyType = 'job',
        legacyName = 'police', nativeGroupKey = 'police', nativeGroupType = 'job',
        grades = { { legacyGrade = 0, gradeKey = 'recruit' } },
        dutySupported = true, dutyState = 'active', status = 'PARTIAL',
      })
      assert(group, groupError and groupError.code)
      assert(mappings:resolveGroup('qb', 'job', 'police').nativeGroupKey == 'police')
      local _, ambiguousGrade = mappings.groups:register('synex_bridge', 4, {
        id = 'qb.ambiguous_grade', version = '1.0.0', provider = 'qb',
        legacyType = 'job', legacyName = 'ambulance',
        nativeGroupKey = 'ambulance', nativeGroupType = 'job',
        grades = {
          { legacyGrade = 0, gradeKey = 'employee' },
          { legacyGrade = 1, gradeKey = 'employee' },
        },
        dutySupported = true, dutyState = 'active', status = 'PARTIAL',
      })
      assert(ambiguousGrade.code == 'COMPAT_MAPPING_AMBIGUOUS')
      local qbxJob, qbxJobError = mappings.groups:register('synex_bridge', 4, {
        id = 'qbx.police_job', version = '1.0.0', provider = 'qbx',
        legacyType = 'job', legacyName = 'police',
        nativeGroupKey = 'police', nativeGroupType = 'job',
        grades = { { legacyGrade = 0, gradeKey = 'recruit' } },
        dutySupported = true, dutyState = 'active', status = 'PARTIAL',
      })
      assert(qbxJob, qbxJobError and qbxJobError.code)
      local _, ambiguousQboxGroup = mappings.groups:register('synex_bridge', 4, {
        id = 'qbx.police_gang', version = '1.0.0', provider = 'qbx',
        legacyType = 'gang', legacyName = 'police',
        nativeGroupKey = 'police', nativeGroupType = 'gang',
        grades = { { legacyGrade = 0, gradeKey = 'member' } },
        dutySupported = false, status = 'PARTIAL',
      })
      assert(ambiguousQboxGroup.code == 'COMPAT_MAPPING_AMBIGUOUS')
      local _, forbidden = mappings.metadata:register('synex_bridge', 4, {
        id = 'qb.license', version = '1.0.0', provider = 'qb', key = 'license',
        valueType = 'string', storageKey = 'safe.value', status = 'PARTIAL', sensitive = false,
      })
      assert(forbidden.code == 'COMPAT_METADATA_FORBIDDEN')
      local _, forbiddenStorage = mappings.metadata:register('synex_bridge', 4, {
        id = 'qb.safe', version = '1.0.0', provider = 'qb', key = 'safe',
        valueType = 'string', maxLength = 64, storageKey = 'password',
        status = 'PARTIAL', sensitive = false,
      })
      assert(forbiddenStorage.code == 'COMPAT_METADATA_FORBIDDEN')
      local metadata, metadataError = mappings.metadata:register('synex_bridge', 4, {
        id = 'qb.hunger', version = '1.0.0', provider = 'qb', key = 'hunger',
        valueType = 'integer', minimum = 0, maximum = 100,
        storageKey = 'needs.hunger', status = 'PARTIAL', sensitive = false,
      })
      assert(metadata, metadataError and metadataError.code)
      assert(mappings:resolveMetadata('qb', 'hunger').maximum == 100)
      local _, denied = mappings:resolveMetadata('qb', 'tokens')
      assert(denied.code == 'COMPAT_METADATA_FORBIDDEN')
      assert(mappings:cleanup('synex_bridge', 3) == 0)
      assert(mappings:cleanup('synex_bridge', 4) == 5)
      local _, missing = mappings:resolveIdentity('qb', 'character', 'legacy', 'citizen-1')
      assert(missing.code == 'COMPAT_MAPPING_MISSING')
      return 'ok'
    `);
    assert.equal(result, 'ok');
  } finally {
    engine.global.close();
  }
});

test('bridge catalog registry requires revisions and exact executable surfaces', async () => {
  const engine = await createKernel();
  try {
    const result = await engine.doString(String.raw`
      local catalogs = SynexBridgeKernel.Catalogs.createCatalogs()
      assert(table.concat(SynexBridgeKernel.Catalogs.domainInterfaces(), ',')
        == 'accounts,banking,groups,identity,interaction,inventory,metadata,notifications,provider,ui,vehicles')
      local definition = {
        name = 'provider.catalog', version = '1.0.0', provider = 'all',
        domain = 'provider', status = 'UNKNOWN', authority = 'domain', revision = 1,
        operations = { 'lookup' },
      }
      local registered = catalogs:register('synex_bridge', 1, definition, {
        lookup = function() return 'value' end,
      })
      assert(registered and catalogs:count() == 1)
      local handler = catalogs:resolve('provider.catalog', 1, 'lookup', 1)
      assert(handler() == 'value')
      local _, staleRevision = catalogs:resolve('provider.catalog', 1, 'lookup', 2)
      assert(staleRevision.code == 'COMPAT_VERSION_CONFLICT')
      local _, missingRevision = catalogs:resolve('provider.catalog', 1, 'lookup')
      assert(missingRevision.code == 'COMPAT_INVALID_ARGUMENT')
      local _, missingCatalog = catalogs:resolve('missing.catalog', 1, 'lookup', 1)
      assert(missingCatalog.code == 'COMPAT_CATALOG_UNAVAILABLE')
      local _, extraError = catalogs:register('synex_bridge', 1, definition, {
        lookup = function() end, extra = function() end,
      })
      assert(extraError.code == 'COMPAT_INVALID_ARGUMENT')
      local _, missingDefinitionRevision = catalogs:register('synex_bridge', 1, {
        name = 'other.catalog', version = '1.0.0', provider = 'all',
        domain = 'provider', status = 'UNKNOWN', authority = 'domain',
        operations = { 'lookup' },
      }, { lookup = function() end })
      assert(missingDefinitionRevision.code == 'COMPAT_INVALID_ARGUMENT')
      local _, unknownDomain = catalogs:register('synex_bridge', 1, {
        name = 'unknown.catalog', version = '1.0.0', provider = 'all',
        domain = 'invented', status = 'UNKNOWN', authority = 'domain', revision = 1,
        operations = { 'lookup' },
      }, { lookup = function() end })
      assert(unknownDomain.code == 'COMPAT_INVALID_ARGUMENT')
      local _, invalidAuthority = catalogs:register('synex_bridge', 1, {
        name = 'static.catalog', version = '1.0.0', provider = 'all',
        domain = 'provider', status = 'PARTIAL', authority = 'static', revision = 1,
        operations = { 'lookup' },
      }, { lookup = function() end })
      assert(invalidAuthority.code == 'COMPAT_INVALID_ARGUMENT')
      local static = assert(catalogs:register('synex_bridge_static', 1, {
        name = 'static.catalog', version = '1.0.0', provider = 'qb',
        domain = 'provider', status = 'PARTIAL',
        authority = 'compatibility/static', revision = 1,
        operations = { 'lookup' },
      }, { lookup = function() return 'static-value' end }))
      assert(static.authority == 'compatibility/static')
      local staticHandler = assert(catalogs:resolve(
        'static.catalog', 1, 'lookup', 1))
      assert(staticHandler() == 'static-value')
      local _, unchangedRevision = catalogs:register('synex_bridge', 1, definition, {
        lookup = function() return 'same' end,
      })
      assert(unchangedRevision.code == 'COMPAT_VERSION_CONFLICT')
      definition.revision = 2
      assert(catalogs:register('synex_bridge', 1, definition, {
        lookup = function() return 'updated' end,
      }))
      local _, oldRevision = catalogs:resolve('provider.catalog', 1, 'lookup', 1)
      assert(oldRevision.code == 'COMPAT_VERSION_CONFLICT')
      local updated = assert(catalogs:resolve('provider.catalog', 1, 'lookup', 2))
      assert(updated() == 'updated')
      assert(catalogs:cleanup('synex_bridge', 1) == 1)
      assert(catalogs:cleanup('synex_bridge_static', 1) == 1)
      assert(catalogs:register('synex_bridge', 1, definition, {
        lookup = function() return 'restarted' end,
      }))
      local restarted = assert(catalogs:resolve(
        'provider.catalog', 1, 'lookup', 2))
      assert(restarted() == 'restarted')
      return 'ok'
    `);
    assert.equal(result, 'ok');
  } finally {
    engine.global.close();
  }
});
