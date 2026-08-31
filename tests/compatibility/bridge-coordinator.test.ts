import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory, type LuaEngine } from 'wasmoon';

const bridgeRoot = path.join(process.cwd(), 'libraries', 'synex_bridge');
const modulePaths = [
  path.join(bridgeRoot, 'kernel', 'foundation.lua'),
  path.join(bridgeRoot, 'kernel', 'certification.lua'),
  path.join(bridgeRoot, 'kernel', 'catalogs.lua'),
  path.join(bridgeRoot, 'kernel', 'mappings.lua'),
  path.join(bridgeRoot, 'kernel', 'telemetry.lua'),
  path.join(bridgeRoot, 'kernel', 'resolver.lua'),
  path.join(bridgeRoot, 'kernel', 'runtime.lua'),
  path.join(bridgeRoot, 'identity_store.lua'),
  path.join(bridgeRoot, 'control_provider.lua'),
];
const coordinatorPath = path.join(bridgeRoot, 'server.lua');

test('bridge coordinator releases every owner-bound registry on resource stop', async () => {
  const coordinator = await readFile(coordinatorPath, 'utf8');
  assert.match(coordinator, /runtime:cleanup\(stoppedResource, CONFIG_EPOCH\)/u);
});

type CoordinatorOptions = {
  configuredConsumer?: boolean;
  configuredSecondQbConsumer?: boolean;
  configuredQbxConsumer?: boolean;
  missingConfiguration?: boolean;
  profileStatus?: 'PARTIAL' | 'CERTIFIED';
  testedVersion?: string | null;
  installedVersion?: string | null;
  certificationEvidence?: boolean;
  targetFrameworkApiRange?: string;
  catalogTargetFrameworkApiRange?: string;
  domainAdapter?: boolean;
  domainCatalog?: boolean;
  coreObjectFiltering?: boolean;
  updateEvents?: boolean;
  clientPlayerData?: boolean;
  clientCallbacks?: boolean;
  clientNotifications?: boolean;
  lifecycleSurface?: boolean;
  secondUpdateEvents?: boolean;
  secondClientPlayerData?: boolean;
  qbProviderState?: 'started' | 'stopped';
  qbxProviderState?: 'started' | 'stopped';
};

function fixtureConfiguration(options: CoordinatorOptions): string {
  const consumerEntries: string[] = [];
  if (options.configuredConsumer === true) {
    consumerEntries.push(String.raw`{
        resource = 'legacy_consumer', provider = 'qb', mode = 'compat',
        profileId = 'qb.fixture', failurePolicy = 'warn', enabled = true,
      }`);
  }
  if (options.configuredSecondQbConsumer === true) {
    consumerEntries.push(String.raw`{
        resource = 'legacy_consumer_b', provider = 'qb', mode = 'compat',
        profileId = 'qb.fixture.b', failurePolicy = 'warn', enabled = true,
      }`);
  }
  if (options.configuredQbxConsumer === true) {
    consumerEntries.push(String.raw`{
        resource = 'qbx_consumer', provider = 'qbx', mode = 'compat',
        profileId = 'qbx.fixture', failurePolicy = 'warn', enabled = true,
      }`);
  }
  const consumers = `{${consumerEntries.join(',')}}`;
  const profileStatus = options.profileStatus ?? 'PARTIAL';
  const testedVersion = options.testedVersion == null
    ? ''
    : `, testedVersion = '${options.testedVersion}'`;
  const evidenceFile = options.certificationEvidence === false
    ? ''
    : "['compatibility/evidence/qb-fixture.test.json'] = 'fixture evidence',";
  const qbxEvidenceFile = options.configuredQbxConsumer === true
    ? "['compatibility/evidence/qbx-fixture.test.json'] = 'fixture evidence',"
    : '';
  const qbxProfile = options.configuredQbxConsumer === true
    ? String.raw`, {
          id = 'qbx.fixture', version = '1.0.0', provider = 'qbx',
          mode = 'compat', status = 'PARTIAL', failurePolicy = 'warn',
          providerVersion = '0.1.0', targetFrameworkApiRange = '^1.0.0',
          certificationArtifact = 'compatibility/certifications/qbx.fixture.json',
          script = { name = 'qbx_consumer' },
          evidence = {
            tests = { 'compatibility/evidence/qbx-fixture.test.json' },
            sourceUrls = { 'https://example.invalid/qbx-fixture' },
          },
          requiredSurfaces = {{
            name = 'qbx.shared.lifecycle_events',
            acceptedStatuses = { 'PARTIAL' },
          }},
          requiredAdapters = {}, requiredCatalogs = {},
        }`
    : '';
  const secondQbProfile = options.configuredSecondQbConsumer === true
    ? String.raw`, {
          id = 'qb.fixture.b', version = '1.0.0', provider = 'qb',
          mode = 'compat', status = 'PARTIAL', failurePolicy = 'warn',
          providerVersion = '0.1.0', targetFrameworkApiRange = '^7.0.0',
          certificationArtifact = 'compatibility/certifications/qb.fixture.b.json',
          script = { name = 'legacy_consumer_b' },
          evidence = {
            tests = { 'compatibility/evidence/qb-fixture.test.json' },
            sourceUrls = { 'https://example.invalid/qb-fixture' },
          },
          requiredSurfaces = {{
            name = 'qb.shared.lifecycle_events', acceptedStatuses = { 'PARTIAL' },
          }${options.secondUpdateEvents === true ? String.raw`, {
            name = 'qb.shared.job_update_events', acceptedStatuses = { 'PARTIAL' },
          }` : ''}${options.secondClientPlayerData === true ? String.raw`, {
            name = 'qb.client.player_data', acceptedStatuses = { 'PARTIAL' },
          }` : ''}},
          requiredAdapters = {}, requiredCatalogs = {},
        }`
    : '';
  const domainRequirement = options.domainAdapter === true
    ? String.raw`, {
            name = 'qb.inventory.item_lookup', acceptedStatuses = { 'PARTIAL' },
          }`
    : '';
  const domainAdapters = options.domainAdapter === true
    ? String.raw`{ { name = 'qb.inventory', versionRange = '^1.0.0' } }`
    : '{}';
  const domainSurface = options.domainAdapter === true
    ? String.raw`, {
          name = 'qb.inventory.item_lookup', status = 'PARTIAL',
          requiredCapability = 'synex.compat.qb.read',
          requiredAdapter = 'qb.inventory',
          adapterOperations = {
            { name = 'item.get', nativeCapabilities = {
              'synex.inventory.read', 'synex.identity.read',
            } },
            { name = 'item.fail', nativeCapabilities = {
              'synex.inventory.read', 'synex.identity.read',
            } },
            { name = 'item.throw', nativeCapabilities = {
              'synex.inventory.read', 'synex.identity.read',
            } },
            { name = 'item.large', nativeCapabilities = {
              'synex.inventory.read', 'synex.identity.read',
            } },
            { name = 'item.callable', nativeCapabilities = {
              'synex.inventory.read', 'synex.identity.read',
            } },
          },
          modes = { 'compat' }, deprecated = true,
        }`
    : '';
  const catalogRequirement = options.domainCatalog === true
    ? String.raw`, {
            name = 'qb.inventory.catalog_lookup', acceptedStatuses = { 'PARTIAL' },
          }`
    : '';
  const domainCatalogs = options.domainCatalog === true
    ? String.raw`{ {
          name = 'inventory.items', versionRange = '^1.0.0',
          domain = 'inventory', revision = 7,
        } }`
    : '{}';
  const catalogSurface = options.domainCatalog === true
    ? String.raw`, {
          name = 'qb.inventory.catalog_lookup', status = 'PARTIAL',
          requiredCapability = 'synex.compat.qb.read',
          requiredCatalog = 'inventory.items',
          adapterOperations = {},
          catalogOperations = {
            { name = 'item.lookup', nativeCapabilities = {
              'synex.inventory.read', 'synex.identity.read',
            } },
            { name = 'item.fail', nativeCapabilities = {
              'synex.inventory.read', 'synex.identity.read',
            } },
            { name = 'item.throw', nativeCapabilities = {
              'synex.inventory.read', 'synex.identity.read',
            } },
            { name = 'item.large', nativeCapabilities = {
              'synex.inventory.read', 'synex.identity.read',
            } },
            { name = 'item.callable', nativeCapabilities = {
              'synex.inventory.read', 'synex.identity.read',
            } },
          },
          modes = { 'compat' }, deprecated = false,
        }`
    : '';
  const filterRequirement = options.coreObjectFiltering === true
    ? String.raw`, {
            name = 'qb.server.core_object_filtering', acceptedStatuses = { 'PARTIAL' },
          }, {
            name = 'qb.server.core_object', acceptedStatuses = { 'PARTIAL' },
          }`
    : '';
  const updateEventRequirement = options.updateEvents === true
    ? String.raw`, {
            name = 'qb.shared.job_update_events', acceptedStatuses = { 'PARTIAL' },
          }`
    : '';
  const clientPlayerDataRequirement = options.clientPlayerData === true
    ? String.raw`, {
            name = 'qb.client.player_data', acceptedStatuses = { 'PARTIAL' },
          }`
    : '';
  const clientCallbackRequirement = options.clientCallbacks === true
    ? String.raw`, {
            name = 'qb.client.callback_invocation', acceptedStatuses = { 'PARTIAL' },
          }, {
            name = 'qb.server.callback_registration', acceptedStatuses = { 'PARTIAL' },
          }`
    : '';
  const clientNotificationRequirement = options.clientNotifications === true
    ? String.raw`, {
            name = 'qb.client.notification', acceptedStatuses = { 'PARTIAL' },
          }`
    : '';
  const lifecycleRequirement = options.lifecycleSurface === false
    ? ''
    : String.raw`, {
            name = 'qb.shared.lifecycle_events', acceptedStatuses = { 'PARTIAL' },
          }`;

  return String.raw`
    fixtureConfig = {
      ['compatibility/profiles.json'] = {
        schema = 1, kind = 'synex-compatibility-profiles',
        profiles = {{
          id = 'qb.fixture', version = '1.0.0', provider = 'qb',
          mode = 'compat', status = '${profileStatus}', failurePolicy = 'warn',
          providerVersion = '0.1.0',
          targetFrameworkApiRange = '${options.targetFrameworkApiRange ?? '^7.0.0'}',
          certificationArtifact = 'compatibility/certifications/qb.fixture.json',
          script = { name = 'legacy_consumer'${testedVersion} },
          evidence = {
            tests = { 'compatibility/evidence/qb-fixture.test.json' },
            sourceUrls = { 'https://example.invalid/qb-fixture' },
          },
          requiredSurfaces = {{
            name = 'qb.server.player_lookup', acceptedStatuses = { 'PARTIAL' },
          }${lifecycleRequirement}${domainRequirement}${catalogRequirement}${filterRequirement}${updateEventRequirement}${clientPlayerDataRequirement}${clientCallbackRequirement}${clientNotificationRequirement}},
          requiredAdapters = ${domainAdapters},
          requiredCatalogs = ${domainCatalogs},
        }${secondQbProfile}${qbxProfile}},
      },
      ['compatibility/consumers.json'] = {
        schema = 1, kind = 'synex-compatibility-consumers',
        defaultMode = 'strict', consumers = ${consumers},
      },
      ['compatibility/mappings.json'] = {
        schema = 1, kind = 'synex-compatibility-mappings',
        identity = {{
          id = 'qb.fixture.identity', version = '1.0.0', provider = 'qb',
          entityKind = 'character', legacyId = 'QB-CITIZEN-42',
          nativeId = 'character_fixture_0001', status = 'PARTIAL',
        }},
        accounts = {{
          id = 'qb.fixture.cash', version = '2.0.0', provider = 'qb',
          alias = 'cash', currencyCode = 'usd', accountKey = 'cash',
          accountRole = 'asset', minorUnit = 0,
          status = 'PARTIAL',
          fundingPolicy = {
            kind = 'account', accountRef = '11111111-1111-4111-8111-111111111111',
          },
          sinkPolicy = { kind = 'deny' },
        }},
        groups = {{
          id = 'qb.fixture.police', version = '1.0.0', provider = 'qb',
          legacyType = 'job', legacyName = 'police', nativeGroupKey = 'lspd',
          nativeGroupType = 'job', grades = {{ legacyGrade = 4, gradeKey = 'chief' }},
          bossRoles = { 'boss' }, dutySupported = true, dutyState = 'active',
          status = 'PARTIAL',
        }},
        metadata = {{
          id = 'qb.fixture.hunger', version = '1.0.0', provider = 'qb',
          key = 'hunger', valueType = 'integer', minimum = 0, maximum = 100,
          storageKey = 'bridge_hunger', status = 'PARTIAL', sensitive = false,
        }},
      },
      ['compatibility/money-policies.json'] = {
        schema = 1, kind = 'synex-compatibility-money-policies', policies = {{
            id = 'qb.fixture.cash.add', version = '1.0.0', provider = 'qb',
            consumer = 'legacy_consumer', moneyAlias = 'cash', direction = 'add',
            legacyReason = 'fixture', action = 'transfer',
            accountId = '11111111-1111-4111-8111-111111111111',
            nativeReasonCode = 'compat.fixture.cash.add', status = 'ACTIVE',
          }, {
            id = 'qb.fixture.cash.mint', version = '1.0.0', provider = 'qb',
            consumer = 'legacy_consumer', moneyAlias = 'cash', direction = 'add',
            legacyReason = 'explicit_mint', action = 'mint',
            nativeReasonCode = 'compat.fixture.cash.mint', status = 'ACTIVE',
          }, {
            id = 'qb.fixture.cash.burn', version = '1.0.0', provider = 'qb',
            consumer = 'legacy_consumer', moneyAlias = 'cash', direction = 'remove',
            legacyReason = 'explicit_burn', action = 'burn',
            nativeReasonCode = 'compat.fixture.cash.burn', status = 'ACTIVE',
        }},
      },
      ${evidenceFile}
      ${qbxEvidenceFile}
      ['compatibility/surfaces/qb.json'] = {
        schema = 1, kind = 'synex-compatibility-surfaces', provider = 'qb',
        providerResource = 'synex_bridge_qb', providerVersion = '0.1.0',
        targetFrameworkApiRange = '${options.catalogTargetFrameworkApiRange ?? '^7.0.0'}',
        surfaces = {{
          name = 'qb.server.player_lookup', status = 'PARTIAL',
          requiredCapability = 'synex.compat.qb.read',
          adapterOperations = {}, modes = { 'compat' }, deprecated = false,
        }, {
          name = 'qb.shared.lifecycle_events', status = 'PARTIAL',
          requiredCapability = 'synex.compat.qb.read',
          adapterOperations = {}, modes = { 'compat' }, deprecated = true,
        }, {
          name = 'qb.server.core_object_filtering', status = 'PARTIAL',
          requiredCapability = 'synex.compat.qb.read',
          adapterOperations = {}, modes = { 'compat' }, deprecated = true,
        }, {
          name = 'qb.server.core_object', status = 'PARTIAL',
          requiredCapability = 'synex.compat.qb.read',
          adapterOperations = {}, modes = { 'compat' }, deprecated = true,
        }, {
          name = 'qb.shared.job_update_events', status = 'PARTIAL',
          requiredCapability = 'synex.compat.qb.read',
          adapterOperations = {}, modes = { 'compat' }, deprecated = true,
        }, {
          name = 'qb.client.player_data', status = 'PARTIAL',
          requiredCapability = 'synex.compat.qb.read',
          adapterOperations = {}, modes = { 'compat' }, deprecated = true,
        }, {
          name = 'qb.client.callback_invocation', status = 'PARTIAL',
          requiredCapability = 'synex.compat.qb.callbacks',
          adapterOperations = {}, modes = { 'compat' }, deprecated = true,
        }, {
          name = 'qb.server.callback_registration', status = 'PARTIAL',
          requiredCapability = 'synex.compat.qb.callbacks',
          adapterOperations = {}, modes = { 'compat' }, deprecated = true,
        }, {
          name = 'qb.client.notification', status = 'PARTIAL',
          requiredCapability = 'synex.compat.qb.read',
          adapterOperations = {}, modes = { 'compat' }, deprecated = true,
        }${domainSurface}${catalogSurface}},
      },
      ['compatibility/surfaces/qbx.json'] = {
        schema = 1, kind = 'synex-compatibility-surfaces', provider = 'qbx',
        providerResource = 'synex_bridge_qbx', providerVersion = '0.1.0',
        targetFrameworkApiRange = '^1.0.0',
        surfaces = ${options.configuredQbxConsumer === true ? String.raw`{{
          name = 'qbx.shared.lifecycle_events', status = 'PARTIAL',
          requiredCapability = 'synex.compat.qbx.read',
          adapterOperations = {}, modes = { 'compat' }, deprecated = true,
        }}` : '{}'},
      },
      ['compatibility/surfaces/esx.json'] = {
        schema = 1, kind = 'synex-compatibility-surfaces', provider = 'esx',
        providerResource = 'synex_bridge_esx', providerVersion = '0.1.0',
        surfaces = {},
      },
    }
  `;
}

async function createCoordinator(options: CoordinatorOptions = {}): Promise<LuaEngine> {
  const engine = await new LuaFactory().createEngine();
  try {
    await engine.doString(String.raw`
      handlers, exported = {}, {}
      invokingResource = 'synex_bridge_qb'
      controlRegistrations, lifecycleRegistrations = 0, 0
      controlDefinition, lifecycleDefinition = nil, nil
      databaseFailureCode = nil
      capabilityChecks, traceSequence, traceContexts = {}, 0, {}
      deniedCapability = nil
      deniedResource = nil
      traceFailureCode = nil
      resourceStates = {
        legacy_consumer = '${options.configuredConsumer === true ? 'started' : 'stopped'}',
        legacy_consumer_b = '${options.configuredSecondQbConsumer === true ? 'started' : 'stopped'}',
        qbx_consumer = '${options.configuredQbxConsumer === true ? 'started' : 'stopped'}',
        synex_bridge_qb = '${options.qbProviderState ?? 'started'}',
        synex_bridge_qbx = '${options.qbxProviderState ?? 'started'}',
        synex_bridge_esx = 'started',
      }
      ${fixtureConfiguration(options)}

      print = function() end
      GetCurrentResourceName = function() return 'synex_bridge' end
      GetInvokingResource = function() return invokingResource end
      GetGameTimer = function() return 1000 + traceSequence end
      GetResourceState = function(resource)
        return resourceStates[resource] or 'stopped'
      end
      GetResourceMetadata = function(resource, key, index)
        assert(key == 'version' and index == 0)
        if resource == 'synex_bridge_qb' then return '0.1.0' end
        if resource == 'synex_bridge_qbx' then return '0.1.0' end
        assert(resource == 'legacy_consumer' or resource == 'legacy_consumer_b'
          or resource == 'qbx_consumer')
        return ${options.installedVersion == null ? 'nil' : `'${options.installedVersion}'`}
      end
      LoadResourceFile = function(_, resourcePath)
        if ${options.missingConfiguration === true ? 'true' : 'false'} then return nil end
        if fixtureConfig[resourcePath] == nil then return nil end
        return resourcePath
      end
      json = {
        decode = function(value) return fixtureConfig[value] or {} end,
        encode = function() return '{}' end,
      }
      AddEventHandler = function(name, handler) handlers[name] = handler end
      SetTimeout = function(_, callback) callback() end

      local api = {
        Ids = { next = function()
          traceSequence = traceSequence + 1
          return ('compat_trace_fixture_%04d'):format(traceSequence)
        end },
        Capabilities = { checkResource = function(resource, capability, operation)
          capabilityChecks[#capabilityChecks + 1] = {
            resource = resource, capability = capability, operation = operation,
          }
          if capability == deniedCapability then
            return nil, { code = 'CAPABILITY_DENIED', retryable = false }
          end
          if resource == deniedResource then
            return nil, { code = 'CAPABILITY_DENIED', retryable = false }
          end
          return true, nil
        end },
        Tracing = { run = function(context, handler)
          traceContexts[#traceContexts + 1] = context
          if traceFailureCode ~= nil then
            return nil, { code = traceFailureCode, retryable = false }
          end
          return handler(context.traceId)
        end },
        ControlProviders = { register = function(definition)
          controlRegistrations = controlRegistrations + 1
          controlDefinition = definition
          return { namespace = definition.namespace }, nil
        end },
        Database = {
          read = function() return {}, nil end,
          write = function() return { affectedRows = 1 }, nil end,
          transaction = function(_, handler)
          if databaseFailureCode ~= nil then
            return nil, { code = databaseFailureCode, retryable = true }
          end
          return handler({ affected = function() return 0 end })
          end,
        },
        Characters = { registerLifecycleParticipant = function(definition)
          lifecycleRegistrations = lifecycleRegistrations + 1
          lifecycleDefinition = definition
          return ('lifecycle-token-%d'):format(lifecycleRegistrations), nil
        end },
      }
      exports = setmetatable({
        synex_core = { GetAPI = function(_, apiRange)
          assert(apiRange == '^1.0.0')
          return api, nil
        end },
      }, { __call = function(_, name, handler) exported[name] = handler end })
    `);
    for (const modulePath of modulePaths) {
      await engine.doString(await readFile(modulePath, 'utf8'));
    }
    await engine.doString(`SynexBridgeKernel.Certification.verify = function()
      return ${options.certificationEvidence === false ? 'false' : 'true'}
    end`);
    await engine.doString(await readFile(coordinatorPath, 'utf8'));
    return engine;
  } catch (error) {
    engine.global.close();
    throw error;
  }
}

test('bridge coordinator fails closed for missing configuration and absent consumers', async () => {
  await assert.rejects(
    createCoordinator({ missingConfiguration: true }),
    /COMPAT_CONFIGURATION_INVALID/u,
  );

  const engine = await createCoordinator();
  try {
    const result = await engine.doString(String.raw`
      local authorized, authorizationError = exported.AuthorizeCompatibilityConsumer({
        provider = 'qb', providerResource = 'synex_bridge_qb',
        consumer = 'legacy_consumer', capability = 'synex.compat.qb.read',
        operation = 'player.read',
      })
      assert(authorized == nil and authorizationError.code == 'COMPAT_CONSUMER_DENIED')

      local publish, publishError = exported.ShouldPublishLifecycle({
        provider = 'qb', providerResource = 'synex_bridge_qb',
      })
      assert(publish == nil and publishError.code == 'COMPAT_PROVIDER_DISABLED')

      invokingResource = 'legacy_consumer'
      local status, statusError = exported.GetCompatibilityConsumerStatus('legacy_consumer')
      assert(status == nil and statusError.code == 'COMPAT_CONSUMER_DENIED')
      return table.concat({
        authorizationError.code, publishError.code, statusError.code,
      }, ':')
    `);
    assert.equal(
      result,
      'COMPAT_CONSUMER_DENIED:COMPAT_PROVIDER_DISABLED:COMPAT_CONSUMER_DENIED',
    );
  } finally {
    engine.global.close();
  }
});

test('QBC lifecycle ownership follows started and authorized QB-family providers', async () => {
  const engine = await createCoordinator({
    configuredConsumer: true,
    configuredQbxConsumer: true,
    qbProviderState: 'stopped',
  });
  try {
    const result = await engine.doString(String.raw`
      invokingResource = 'synex_bridge_qbx'
      local qbxFallback = assert(exported.ShouldPublishLifecycle({
        provider = 'qbx', providerResource = 'synex_bridge_qbx',
      }))
      assert(qbxFallback.consumer == 'qbx_consumer')
      assert(qbxFallback.families.qbc == true
        and qbxFallback.families.qbx == true)

      invokingResource = 'synex_bridge_qb'
      local stoppedQb = assert(exported.ShouldPublishLifecycle({
        provider = 'qb', providerResource = 'synex_bridge_qb',
      }))
      assert(stoppedQb.standby == true
        and stoppedQb.coveredFamilies.qbc == true)

      resourceStates.synex_bridge_qb = 'started'
      deniedResource = 'legacy_consumer'
      invokingResource = 'synex_bridge_qbx'
      local qbxAuthorized = assert(exported.ShouldPublishLifecycle({
        provider = 'qbx', providerResource = 'synex_bridge_qbx',
      }))
      assert(qbxAuthorized.families.qbc == true)

      invokingResource = 'synex_bridge_qb'
      local deniedQb = assert(exported.ShouldPublishLifecycle({
        provider = 'qb', providerResource = 'synex_bridge_qb',
      }))
      assert(deniedQb.standby == true
        and deniedQb.coveredFamilies.qbc == true)

      deniedResource = nil
      local qbReturned = assert(exported.ShouldPublishLifecycle({
        provider = 'qb', providerResource = 'synex_bridge_qb',
      }))
      assert(qbReturned.families.qbc == true)

      invokingResource = 'synex_bridge_qbx'
      local qbxStandbyFamily = assert(exported.ShouldPublishLifecycle({
        provider = 'qbx', providerResource = 'synex_bridge_qbx',
      }))
      assert(qbxStandbyFamily.families.qbc == false
        and qbxStandbyFamily.families.qbx == true)

      resourceStates.synex_bridge_qb = 'stopped'
      local qbxReacquired = assert(exported.ShouldPublishLifecycle({
        provider = 'qbx', providerResource = 'synex_bridge_qbx',
      }))
      assert(qbxReacquired.families.qbc == true)
      return table.concat({
        qbxFallback.consumer, stoppedQb.standby and 'standby' or 'active',
        deniedQb.standby and 'denied' or 'active',
        qbReturned.consumer, qbxReacquired.consumer,
      }, ':')
    `);
    assert.equal(
      result,
      'qbx_consumer:standby:denied:legacy_consumer:qbx_consumer',
    );
  } finally {
    engine.global.close();
  }
});

test('bridge coordinator gates core filtering and update-event publication by profile surfaces', async () => {
  const baseOnly = await createCoordinator({ configuredConsumer: true });
  try {
    const result = await baseOnly.doString(String.raw`
      invokingResource = 'synex_bridge_qb'
      local filtered, filterError = exported.AuthorizeCompatibilityConsumer({
        provider = 'qb', providerResource = 'synex_bridge_qb',
        consumer = 'legacy_consumer', capability = 'synex.compat.qb.read',
        operation = 'core_object.filter',
      })
      assert(filtered == nil and filterError.code == 'COMPAT_API_UNSUPPORTED')
      local publication = assert(exported.ShouldPublishLifecycle({
        provider = 'qb', providerResource = 'synex_bridge_qb',
      }))
      assert(publication.surfaces['qb.shared.job_update_events'] == false)
      assert(#publication.clientAccess.playerData == 0
        and #publication.clientAccess.callbacks == 0)
      return filterError.code
    `);
    assert.equal(result, 'COMPAT_API_UNSUPPORTED');
  } finally {
    baseOnly.global.close();
  }

  const companions = await createCoordinator({
    configuredConsumer: true,
    coreObjectFiltering: true,
    updateEvents: true,
  });
  try {
    const result = await companions.doString(String.raw`
      invokingResource = 'synex_bridge_qb'
      local filtered = assert(exported.AuthorizeCompatibilityConsumer({
        provider = 'qb', providerResource = 'synex_bridge_qb',
        consumer = 'legacy_consumer', capability = 'synex.compat.qb.read',
        operation = 'core_object.filter',
      }))
      assert(filtered.surface == 'qb.server.core_object_filtering')
      local publication = assert(exported.ShouldPublishLifecycle({
        provider = 'qb', providerResource = 'synex_bridge_qb',
      }))
      assert(publication.surfaces['qb.shared.job_update_events'] == true)
      return filtered.surface
    `);
    assert.equal(result, 'qb.server.core_object_filtering');
  } finally {
    companions.global.close();
  }
});

test('bridge coordinator publishes client access only for authorized client surfaces', async () => {
  const engine = await createCoordinator({
    configuredConsumer: true,
    lifecycleSurface: false,
    clientPlayerData: true,
    clientCallbacks: true,
  });
  try {
    const result = await engine.doString(String.raw`
      invokingResource = 'synex_bridge_qb'
      local publication = assert(exported.ShouldPublishLifecycle({
        provider = 'qb', providerResource = 'synex_bridge_qb',
      }))
      assert(publication.consumer == 'legacy_consumer')
      assert(publication.authorizationOperation == 'client.player_data.read')
      assert(publication.families.qbc == false
        and publication.families.qbx == false
        and publication.families.esx == false)
      assert(#publication.clientAccess.playerData == 1
        and publication.clientAccess.playerData[1] == 'legacy_consumer')
      assert(#publication.clientAccess.callbacks == 1
        and publication.clientAccess.callbacks[1] == 'legacy_consumer')

      local excluded, excludedError = exported.ShouldPublishLifecycle({
        provider = 'qb', providerResource = 'synex_bridge_qb',
        excludedConsumer = 'legacy_consumer',
      })
      assert(excluded == nil and excludedError.code == 'COMPAT_PROVIDER_DISABLED')
      return publication.authorizationOperation
    `);
    assert.equal(result, 'client.player_data.read');
  } finally {
    engine.global.close();
  }
});

test('bridge coordinator supports notification-only consumers and checks native Notify authority', async () => {
  const engine = await createCoordinator({
    configuredConsumer: true,
    lifecycleSurface: false,
    clientNotifications: true,
  });
  try {
    const result = await engine.doString(String.raw`
      invokingResource = 'synex_bridge_qb'
      local publication = assert(exported.ShouldPublishLifecycle({
        provider = 'qb', providerResource = 'synex_bridge_qb',
      }))
      assert(publication.authorizationOperation == 'client.notification.send')
      assert(#publication.clientAccess.playerData == 0
        and #publication.clientAccess.callbacks == 0
        and #publication.clientAccess.notifications == 1
        and publication.clientAccess.notifications[1] == 'legacy_consumer')
      local checked = false
      for _, entry in ipairs(capabilityChecks) do
        if entry.resource == 'legacy_consumer'
          and entry.capability == 'synex.notify.send' then checked = true end
      end
      assert(checked == true)
      deniedCapability = 'synex.notify.send'
      local denied, deniedError = exported.ShouldPublishLifecycle({
        provider = 'qb', providerResource = 'synex_bridge_qb',
      })
      assert(denied == nil, 'notification denial returned a publication')
      assert(deniedError.code == 'COMPAT_PROVIDER_DISABLED', deniedError.code)
      return publication.authorizationOperation
    `);
    assert.equal(result, 'client.notification.send');
  } finally {
    engine.global.close();
  }
});

test('bridge coordinator rejects callback-only and update-event-only projection profiles', async () => {
  await assert.rejects(
    createCoordinator({
      configuredConsumer: true,
      lifecycleSurface: false,
      clientCallbacks: true,
    }),
    /COMPAT_PROFILE_INCOMPLETE/u,
  );
  await assert.rejects(
    createCoordinator({
      configuredConsumer: true,
      lifecycleSurface: false,
      updateEvents: true,
    }),
    /COMPAT_PROFILE_INCOMPLETE/u,
  );
});

test('bridge coordinator enables global update events for any authorized active consumer', async () => {
  const engine = await createCoordinator({
    configuredConsumer: true,
    configuredSecondQbConsumer: true,
    secondUpdateEvents: true,
  });
  try {
    const result = await engine.doString(String.raw`
      invokingResource = 'synex_bridge_qb'
      local publication = assert(exported.ShouldPublishLifecycle({
        provider = 'qb', providerResource = 'synex_bridge_qb',
      }))
      assert(publication.consumer == 'legacy_consumer')
      assert(publication.surfaces['qb.shared.job_update_events'] == true)

      resourceStates.legacy_consumer_b = 'stopped'
      local withoutSecond = assert(exported.ShouldPublishLifecycle({
        provider = 'qb', providerResource = 'synex_bridge_qb',
      }))
      assert(withoutSecond.consumer == 'legacy_consumer')
      assert(withoutSecond.surfaces['qb.shared.job_update_events'] == false)
      return publication.consumer
    `);
    assert.equal(result, 'legacy_consumer');
  } finally {
    engine.global.close();
  }
});

test('bridge coordinator returns every active authorized client-state consumer in sorted order', async () => {
  const engine = await createCoordinator({
    configuredConsumer: true,
    configuredSecondQbConsumer: true,
    clientPlayerData: true,
    secondClientPlayerData: true,
  });
  try {
    const result = await engine.doString(String.raw`
      invokingResource = 'synex_bridge_qb'
      local publication = assert(exported.ShouldPublishLifecycle({
        provider = 'qb', providerResource = 'synex_bridge_qb',
      }))
      assert(#publication.clientAccess.playerData == 2)
      assert(publication.clientAccess.playerData[1] == 'legacy_consumer')
      assert(publication.clientAccess.playerData[2] == 'legacy_consumer_b')
      resourceStates.legacy_consumer = 'stopped'
      local remaining = assert(exported.ShouldPublishLifecycle({
        provider = 'qb', providerResource = 'synex_bridge_qb',
      }))
      assert(#remaining.clientAccess.playerData == 1
        and remaining.clientAccess.playerData[1] == 'legacy_consumer_b')
      return table.concat(publication.clientAccess.playerData, ':')
    `);
    assert.equal(result, 'legacy_consumer:legacy_consumer_b');
  } finally {
    engine.global.close();
  }
});

test('bridge character deletion cleanup is required and propagates database failure', async () => {
  const engine = await createCoordinator();
  try {
    const result = await engine.doString(String.raw`
      assert(type(lifecycleDefinition) == 'table')
      assert(lifecycleDefinition.name == 'synex_bridge.persistence')
      assert(lifecycleDefinition.required == true)
      assert(type(lifecycleDefinition.deletePreflight) == 'function')
      assert(type(lifecycleDefinition.deleteCommit) == 'function')
      local plan = assert(lifecycleDefinition.deletePreflight({}))
      assert(plan.action == 'delete')

      databaseFailureCode = 'DATABASE_UNAVAILABLE'
      local deleted, deleteError = lifecycleDefinition.deleteCommit({
        planId = 'delete_plan_fixture_0001',
        plan = { characterId = 'character_fixture_0001' },
      })
      assert(deleted == nil and deleteError.code == 'DATABASE_UNAVAILABLE')
      return 'required:' .. deleteError.code
    `);
    assert.equal(result, 'required:DATABASE_UNAVAILABLE');
  } finally {
    engine.global.close();
  }
});

test('bridge coordinator binds callers to providers and resolves only matching capability operations', async () => {
  const engine = await createCoordinator({ configuredConsumer: true });
  try {
    const result = await engine.doString(String.raw`
      local request = {
        provider = 'qb', providerResource = 'synex_bridge_qb',
        consumer = 'legacy_consumer', capability = 'synex.compat.qb.read',
        operation = 'player.read',
      }

      invokingResource = 'foreign_resource'
      local foreign, foreignError = exported.AuthorizeCompatibilityConsumer(request)
      assert(foreign == nil and foreignError.code == 'COMPAT_CONSUMER_DENIED')

      invokingResource = 'synex_bridge_qb'
      local crossed, crossedError = exported.AuthorizeCompatibilityConsumer({
        provider = 'qbx', providerResource = 'synex_bridge_qbx',
        consumer = 'legacy_consumer', capability = 'synex.compat.qbx.read',
        operation = 'player.read',
      })
      assert(crossed == nil and crossedError.code == 'COMPAT_FRAMEWORK_CONFLICT')
      local spoofed, spoofedError = exported.AuthorizeCompatibilityConsumer({
        provider = 'qb', providerResource = 'synex_bridge_esx',
        consumer = 'legacy_consumer', capability = 'synex.compat.qb.read',
        operation = 'player.read',
      })
      assert(spoofed == nil and spoofedError.code == 'COMPAT_FRAMEWORK_CONFLICT')

      local authorized, authorizationError = exported.AuthorizeCompatibilityConsumer(request)
      assert(authorized and authorizationError == nil)
      assert(authorized.authority == 'core' and authorized.mode == 'compat')
      assert(authorized.surface == 'qb.server.player_lookup'
        and authorized.status == 'PARTIAL')
      assert(#capabilityChecks == 4)
      assert(capabilityChecks[1].capability == 'synex.compat.qb.read')
      assert(capabilityChecks[2].capability == 'synex.identity.read')
      assert(capabilityChecks[3].capability == 'synex.accounts.read')
      assert(capabilityChecks[4].capability == 'synex.groups.read')

      deniedCapability = 'synex.accounts.read'
      local nativeDenied, nativeDeniedError = exported.AuthorizeCompatibilityConsumer(request)
      assert(nativeDenied == nil and nativeDeniedError.code == 'CAPABILITY_DENIED')
      deniedCapability = 'synex.compat.qb.read'
      local compatibilityDenied, compatibilityDeniedError =
        exported.AuthorizeCompatibilityConsumer(request)
      assert(compatibilityDenied == nil
        and compatibilityDeniedError.code == 'CAPABILITY_DENIED')
      deniedCapability = nil
      assert(#capabilityChecks == 8)

      capabilityChecks = {}
      local groupRead, groupReadError = exported.AuthorizeCompatibilityConsumer({
        provider = 'qb', providerResource = 'synex_bridge_qb',
        consumer = 'legacy_consumer', capability = 'synex.compat.qb.read',
        operation = 'groups.read',
      })
      assert(groupRead and groupReadError == nil)
      assert(groupRead.surface == 'qb.server.player_lookup')
      assert(#capabilityChecks == 3)
      assert(capabilityChecks[1].capability == 'synex.compat.qb.read')
      assert(capabilityChecks[2].capability == 'synex.identity.read')
      assert(capabilityChecks[3].capability == 'synex.groups.read')

      local wrongCapability, capabilityError = exported.AuthorizeCompatibilityConsumer({
        provider = 'qb', providerResource = 'synex_bridge_qb',
        consumer = 'legacy_consumer', capability = 'synex.compat.qb.write',
        operation = 'player.read',
      })
      assert(wrongCapability == nil and capabilityError.code == 'COMPAT_API_UNSUPPORTED')
      local missingSurface, surfaceError = exported.AuthorizeCompatibilityConsumer({
        provider = 'qb', providerResource = 'synex_bridge_qb',
        consumer = 'legacy_consumer', capability = 'synex.compat.qb.write',
        operation = 'money.add',
      })
      assert(missingSurface == nil and surfaceError.code == 'COMPAT_API_UNSUPPORTED')
      local unknown, unknownError = exported.AuthorizeCompatibilityConsumer({
        provider = 'qb', providerResource = 'synex_bridge_qb',
        consumer = 'legacy_consumer', capability = 'synex.compat.qb.read',
        operation = 'unknown.call',
      })
      assert(unknown == nil and unknownError.code == 'COMPAT_API_UNSUPPORTED')

      invokingResource = 'legacy_consumer'
      local status = assert(exported.GetCompatibilityConsumerStatus('legacy_consumer'))
      status.enabled = false
      local second = assert(exported.GetCompatibilityConsumerStatus('legacy_consumer'))
      assert(second.enabled == true and second.provider == 'qb')
      return table.concat({
        foreignError.code, crossedError.code, spoofedError.code,
        authorized.surface, capabilityError.code, surfaceError.code,
        unknownError.code, nativeDeniedError.code, compatibilityDeniedError.code,
      }, ':')
    `);
    assert.equal(
      result,
      'COMPAT_CONSUMER_DENIED:COMPAT_FRAMEWORK_CONFLICT:COMPAT_FRAMEWORK_CONFLICT:'
        + 'qb.server.player_lookup:COMPAT_API_UNSUPPORTED:COMPAT_API_UNSUPPORTED:'
        + 'COMPAT_API_UNSUPPORTED:CAPABILITY_DENIED:CAPABILITY_DENIED',
    );
  } finally {
    engine.global.close();
  }
});

test('bridge coordinator binds certified profiles to provider, target API, artifact, and script versions', async () => {
  const certified = await createCoordinator({
    configuredConsumer: true,
    profileStatus: 'CERTIFIED',
    testedVersion: '2.0.0-beta.1',
    installedVersion: '2.0.0-beta.1',
  });
  try {
    const authority = await certified.doString(String.raw`
      local result = assert(exported.AuthorizeCompatibilityConsumer({
        provider = 'qb', providerResource = 'synex_bridge_qb',
        consumer = 'legacy_consumer', capability = 'synex.compat.qb.read',
        operation = 'player.read',
      }))
      return result.authority
    `);
    assert.equal(authority, 'core');
  } finally {
    certified.global.close();
  }

  const independentTargetRange = await createCoordinator({
    configuredConsumer: true,
    profileStatus: 'CERTIFIED',
    testedVersion: '2.0.0',
    installedVersion: '2.0.0',
    targetFrameworkApiRange: '^9.0.0',
    catalogTargetFrameworkApiRange: '^9.0.0',
  });
  try {
    const authority = await independentTargetRange.doString(String.raw`
      return assert(exported.AuthorizeCompatibilityConsumer({
        provider = 'qb', providerResource = 'synex_bridge_qb',
        consumer = 'legacy_consumer', capability = 'synex.compat.qb.read',
        operation = 'player.read',
      })).authority
    `);
    assert.equal(authority, 'core');
  } finally {
    independentTargetRange.global.close();
  }
  await assert.rejects(createCoordinator({
    configuredConsumer: true,
    targetFrameworkApiRange: '^8.0.0',
    catalogTargetFrameworkApiRange: '^7.0.0',
  }), /COMPAT_PROFILE_INCOMPLETE/u);

  for (const options of [
    {
      profileStatus: 'CERTIFIED' as const,
      testedVersion: null,
      installedVersion: null,
    },
    {
      profileStatus: 'CERTIFIED' as const,
      testedVersion: '2.0.0',
      installedVersion: '2.0.1',
    },
    {
      profileStatus: 'CERTIFIED' as const,
      testedVersion: '2.0.0',
      installedVersion: '2.0.0',
      certificationEvidence: false,
    },
  ]) {
    const engine = await createCoordinator({ configuredConsumer: true, ...options });
    try {
      const code = await engine.doString(String.raw`
        local result, compatError = exported.AuthorizeCompatibilityConsumer({
          provider = 'qb', providerResource = 'synex_bridge_qb',
          consumer = 'legacy_consumer', capability = 'synex.compat.qb.read',
          operation = 'player.read',
        })
        assert(result == nil)
        return compatError.code
      `);
      assert.equal(code, 'COMPAT_PROFILE_INCOMPLETE');
    } finally {
      engine.global.close();
    }
  }
});

test('bridge coordinator enforces identity, metadata, and money mapping policy boundaries', async () => {
  const engine = await createCoordinator({ configuredConsumer: true });
  try {
    const result = await engine.doString(String.raw`
      invokingResource = 'synex_bridge_qb'
      local identity = assert(exported.ResolveCompatibilityIdentity({
        provider = 'qb', identifierType = 'citizenid',
        characterId = 'character_fixture_0001',
      }))
      assert(identity.identifier == 'QB-CITIZEN-42'
        and identity.importSource == 'static_registry')

      local metadata = assert(exported.ResolveMetadataMapping({
        provider = 'qb', consumer = 'legacy_consumer', key = 'hunger',
        operation = 'write',
      }))
      assert(metadata.allowed == true and metadata.nativeKey == 'bridge_hunger')
      assert(metadata.valueType == 'integer' and metadata.minimum == 0
        and metadata.maximum == 100)
      local metadataRead, metadataReadError = exported.ResolveMetadataMapping({
        provider = 'qb', consumer = 'legacy_consumer', key = 'hunger',
        operation = 'read',
      })
      assert(metadataRead == nil and metadataReadError.code == 'COMPAT_API_UNSUPPORTED')
      local forbidden, forbiddenError = exported.ResolveMetadataMapping({
        provider = 'qb', consumer = 'legacy_consumer', key = 'license',
        operation = 'write',
      })
      assert(forbidden == nil and forbiddenError.code == 'COMPAT_METADATA_FORBIDDEN')
      local oversized, oversizedError = exported.SetCompatibilityMetadata({
        provider = 'qb', characterId = 'character_fixture_0001',
        key = 'bridge_hunger', value = 101, consumer = 'legacy_consumer',
      })
      assert(oversized == nil and oversizedError.code == 'COMPAT_DTO_LIMIT')

      local groups = assert(exported.ProjectCompatibilityGroups({
        provider = 'qb', groups = {
          items = {{
            membership_id = 'membership_fixture_0001', status = 'ACTIVE',
            is_primary = true,
            group = { group_id = 'group_fixture_0001', type = 'job', key = 'lspd' },
            grade = { key = 'chief', rank = 90 },
            roles = {{ key = 'boss' }}, roles_truncated = false,
            duty = { counts_as_on_duty = true },
          }},
          truncated = false,
        },
      }))
      assert(groups.items[1].group.key == 'police'
        and groups.items[1].grade.rank == 4
        and groups.items[1].compatibility_is_boss == true
        and groups.items[1].duty.counts_as_on_duty == true)
      local unmapped, unmappedError = exported.ProjectCompatibilityGroups({
        provider = 'qb', groups = {
          items = {{
            membership_id = 'membership_fixture_0002', status = 'ACTIVE',
            is_primary = false,
            group = { group_id = 'group_fixture_0002', type = 'job', key = 'unknown' },
            roles = {}, roles_truncated = false,
          }},
          truncated = false,
        },
      })
      assert(unmapped == nil and unmappedError.code == 'COMPAT_MAPPING_MISSING')

      local funding = assert(exported.ResolveMoneyPolicy({
        provider = 'qb', consumer = 'legacy_consumer', moneyAlias = 'cash',
        direction = 'add', legacyReason = 'fixture',
      }))
      assert(funding.action == 'transfer'
        and funding.accountId == '11111111-1111-4111-8111-111111111111')
      local mint = assert(exported.ResolveMoneyPolicy({
        provider = 'qb', consumer = 'legacy_consumer', moneyAlias = 'cash',
        direction = 'add', legacyReason = 'explicit_mint',
      }))
      assert(mint.action == 'mint' and mint.accountId == nil)
      local burn = assert(exported.ResolveMoneyPolicy({
        provider = 'qb', consumer = 'legacy_consumer', moneyAlias = 'cash',
        direction = 'remove', legacyReason = 'explicit_burn',
      }))
      assert(burn.action == 'burn' and burn.accountId == nil)
      local accountMapping = assert(exported.ResolveCompatibilityAccountMapping({
        provider = 'qb', alias = 'cash',
      }))
      assert(accountMapping.alias == 'cash'
        and accountMapping.currencyCode == 'usd'
        and accountMapping.accountKey == 'cash'
        and accountMapping.accountRole == 'asset'
        and accountMapping.minorUnit == 0
        and accountMapping.status == 'PARTIAL')
      local sink, sinkError = exported.ResolveMoneyPolicy({
        provider = 'qb', consumer = 'legacy_consumer', moneyAlias = 'cash',
        direction = 'remove', legacyReason = 'fixture',
      })
      assert(sink == nil and sinkError.code == 'COMPAT_MONEY_POLICY_DENIED')
      local invalid, invalidError = exported.ResolveMoneyPolicy({
        provider = 'qb', consumer = 'legacy_consumer', moneyAlias = 'cash',
        direction = 'set', legacyReason = 'fixture',
      })
      assert(invalid == nil and invalidError.code == 'COMPAT_INVALID_ARGUMENT')
      local missing, missingError = exported.ResolveMoneyPolicy({
        provider = 'qb', consumer = 'legacy_consumer', moneyAlias = 'crypto',
        direction = 'add', legacyReason = 'fixture',
      })
      assert(missing == nil and missingError.code == 'COMPAT_MAPPING_MISSING')
      return table.concat({
        identity.importSource, metadata.nativeKey, metadataReadError.code,
        forbiddenError.code, oversizedError.code, groups.items[1].group.key,
        tostring(groups.items[1].compatibility_is_boss), unmappedError.code,
        funding.action, mint.action, burn.action, accountMapping.currencyCode,
        sinkError.code, invalidError.code, missingError.code,
      }, ':')
    `);
    assert.equal(
      result,
      'static_registry:bridge_hunger:COMPAT_API_UNSUPPORTED:'
        + 'COMPAT_METADATA_FORBIDDEN:COMPAT_DTO_LIMIT:police:true:'
        + 'COMPAT_MAPPING_MISSING:transfer:mint:burn:usd:'
        + 'COMPAT_MONEY_POLICY_DENIED:COMPAT_INVALID_ARGUMENT:COMPAT_MAPPING_MISSING',
    );
  } finally {
    engine.global.close();
  }
});

test('bridge coordinator rejects oversized DTOs and returns detached bounded matrix snapshots', async () => {
  const engine = await createCoordinator({ configuredConsumer: true });
  try {
    const result = await engine.doString(String.raw`
      invokingResource = 'synex_bridge_qb'
      local unknownField, unknownFieldError = exported.AuthorizeCompatibilityConsumer({
        provider = 'qb', providerResource = 'synex_bridge_qb',
        consumer = 'legacy_consumer', capability = 'synex.compat.qb.read',
        operation = 'player.read', secret = true,
      })
      assert(unknownField == nil and unknownFieldError.code == 'COMPAT_DTO_INVALID')
      local longValue, longValueError = exported.AuthorizeCompatibilityConsumer({
        provider = 'qb', providerResource = 'synex_bridge_qb',
        consumer = string.rep('a', 4097), capability = 'synex.compat.qb.read',
        operation = 'player.read',
      })
      assert(longValue == nil and longValueError.code == 'COMPAT_DTO_LIMIT')

      local cyclic = {}
      cyclic.self = cyclic
      local cycleValue, cycleError = exported.SetCompatibilityMetadata({
        provider = 'qb', characterId = 'character_fixture_0001',
        key = 'bridge_hunger', value = cyclic, consumer = 'legacy_consumer',
      })
      assert(cycleValue == nil and cycleError.code == 'COMPAT_DTO_CYCLE')

      local first = assert(exported.GetCompatibilityMatrix())
      assert(first.qb['qb.server.player_lookup'] == 'partial')
      first.qb['qb.server.player_lookup'] = 'certified'
      first.unsupported[1] = 'mutated'
      local second = assert(exported.GetCompatibilityMatrix())
      assert(second.qb['qb.server.player_lookup'] == 'partial')
      assert(second.unsupported[1] == 'authorization-equivalence')
      return table.concat({
        unknownFieldError.code, longValueError.code, cycleError.code,
        second.qb['qb.server.player_lookup'], second.unsupported[1],
      }, ':')
    `);
    assert.equal(
      result,
      'COMPAT_DTO_INVALID:COMPAT_DTO_LIMIT:COMPAT_DTO_CYCLE:'
        + 'partial:authorization-equivalence',
    );
  } finally {
    engine.global.close();
  }
});

test('official providers invoke only resolved and fully authorized domain adapters', async () => {
  const engine = await createCoordinator({ configuredConsumer: true, domainAdapter: true });
  try {
    const result = await engine.doString(String.raw`
      local handlerCalls = 0
      local definition = {
        name = 'qb.inventory', version = '1.0.0', provider = 'qb',
        domain = 'inventory', status = 'PARTIAL',
        operations = { 'item.get', 'item.fail', 'item.throw', 'item.large', 'item.callable' },
      }
      local implementation = {
        ['item.get'] = function(context, payload)
          handlerCalls = handlerCalls + 1
          assert(context.schemaVersion == 1 and context.provider == 'qb'
            and context.providerResource == 'synex_bridge_qb'
            and context.consumer == 'legacy_consumer'
            and context.profile.id == 'qb.fixture'
            and context.surface.name == 'qb.inventory.item_lookup'
            and context.adapter.name == 'qb.inventory'
            and context.adapter.domain == 'inventory'
            and context.operation == 'item.get')
          payload.touched = true
          return { item = payload.item, handled = true }
        end,
        ['item.fail'] = function()
          handlerCalls = handlerCalls + 1
          return nil, {
            code = 'COMPAT_ADAPTER_MISSING', message = 'private adapter detail',
            retryable = true,
          }
        end,
        ['item.throw'] = function()
          handlerCalls = handlerCalls + 1
          error('private thrown detail')
        end,
        ['item.large'] = function()
          handlerCalls = handlerCalls + 1
          return { value = string.rep('x', 5000) }
        end,
        ['item.callable'] = function()
          handlerCalls = handlerCalls + 1
          return { leak = function() end }
        end,
      }
      local function invoke(operation, payload)
        invokingResource = 'synex_bridge_qb'
        return exported.InvokeCompatibilityAdapter('legacy_consumer', {
          surface = 'qb.inventory.item_lookup', operation = operation,
          payload = payload or {},
        })
      end
      local function registerAdapter()
        invokingResource = 'synex_inventory_adapter'
        return exported.RegisterCompatibilityAdapter(definition, implementation)
      end

      local missing, missingError = invoke('item.get', { item = 'water' })
      assert(missing == nil and missingError.code == 'COMPAT_ADAPTER_MISSING')
      assert(registerAdapter())

      local original = { item = 'water' }
      local success, successError = invoke('item.get', original)
      assert(success and successError == nil and success.item == 'water'
        and success.handled == true and original.touched == nil and handlerCalls == 1)
      local adapterTrace = traceContexts[#traceContexts]
      assert(adapterTrace.operation == 'compat.qb.InvokeAdapter'
        and adapterTrace.compatProvider == 'qb'
        and adapterTrace.consumer == 'legacy_consumer'
        and adapterTrace.legacyApi == 'InvokeAdapter'
        and adapterTrace.payload == nil and adapterTrace.request == nil)

      traceFailureCode = 'CAPABILITY_DENIED'
      local traceDenied, traceDeniedError = invoke('item.get', {})
      assert(traceDenied == nil and traceDeniedError.code == 'CAPABILITY_DENIED'
        and handlerCalls == 1)
      traceFailureCode = nil

      local wrongConsumer, wrongConsumerError = exported.InvokeCompatibilityAdapter(
        'unknown_consumer', {
          surface = 'qb.inventory.item_lookup', operation = 'item.get', payload = {},
        })
      assert(wrongConsumer == nil
        and wrongConsumerError.code == 'COMPAT_CONSUMER_DENIED')
      invokingResource = 'synex_bridge_qb'
      local wrongSurface, wrongSurfaceError = exported.InvokeCompatibilityAdapter(
        'legacy_consumer', {
          surface = 'qb.inventory.unknown', operation = 'item.get', payload = {},
        })
      assert(wrongSurface == nil and wrongSurfaceError.code == 'COMPAT_API_UNSUPPORTED')
      local wrongOperation, wrongOperationError = invoke('item.delete', {})
      assert(wrongOperation == nil
        and wrongOperationError.code == 'COMPAT_API_UNSUPPORTED')
      invokingResource = 'synex_bridge_esx'
      local wrongProvider, wrongProviderError = exported.InvokeCompatibilityAdapter(
        'legacy_consumer', {
          surface = 'qb.inventory.item_lookup', operation = 'item.get', payload = {},
        })
      assert(wrongProvider == nil
        and wrongProviderError.code == 'COMPAT_FRAMEWORK_CONFLICT')
      invokingResource = 'foreign_provider'
      local unofficial, unofficialError = exported.InvokeCompatibilityAdapter(
        'legacy_consumer', {
          surface = 'qb.inventory.item_lookup', operation = 'item.get', payload = {},
        })
      assert(unofficial == nil and unofficialError.code == 'COMPAT_CONSUMER_DENIED')

      invokingResource = 'synex_bridge_qb'
      local underclaimed, underclaimedError = exported.InvokeCompatibilityAdapter(
        'legacy_consumer', {
          surface = 'qb.inventory.item_lookup', operation = 'item.get', payload = {},
          nativeCapabilities = {},
        })
      assert(underclaimed == nil and underclaimedError.code == 'COMPAT_DTO_INVALID')

      capabilityChecks = {}
      deniedCapability = 'synex.compat.qb.read'
      local compatDenied, compatDeniedError = invoke('item.get', {})
      assert(compatDenied == nil and compatDeniedError.code == 'CAPABILITY_DENIED'
        and #capabilityChecks == 1 and handlerCalls == 1)
      capabilityChecks = {}
      deniedCapability = 'synex.inventory.read'
      local nativeDenied, nativeDeniedError = invoke('item.get', {})
      assert(nativeDenied == nil and nativeDeniedError.code == 'CAPABILITY_DENIED'
        and #capabilityChecks == 2
        and capabilityChecks[1].capability == 'synex.compat.qb.read'
        and capabilityChecks[2].capability == 'synex.inventory.read'
        and handlerCalls == 1)
      capabilityChecks = {}
      deniedCapability = 'synex.identity.read'
      local finalGate, finalGateError = invoke('item.get', {})
      assert(finalGate == nil and finalGateError.code == 'CAPABILITY_DENIED'
        and #capabilityChecks == 3
        and capabilityChecks[3].capability == 'synex.identity.read'
        and handlerCalls == 1)
      deniedCapability = nil

      local failed, failedError = invoke('item.fail', {})
      assert(failed == nil and failedError.code == 'COMPAT_ADAPTER_MISSING'
        and failedError.message ~= 'private adapter detail')
      local thrown, thrownError = invoke('item.throw', {})
      assert(thrown == nil and thrownError.code == 'COMPAT_INTERNAL'
        and not thrownError.message:find('private thrown detail', 1, true))
      local oversizedPayload, oversizedPayloadError = invoke(
        'item.get', { value = string.rep('x', 5000) })
      assert(oversizedPayload == nil
        and oversizedPayloadError.code == 'COMPAT_DTO_LIMIT')
      local oversizedResult, oversizedResultError = invoke('item.large', {})
      assert(oversizedResult == nil
        and oversizedResultError.code == 'COMPAT_DTO_LIMIT')
      local callableResult, callableResultError = invoke('item.callable', {})
      assert(callableResult == nil
        and callableResultError.code == 'COMPAT_DTO_INVALID')
      local metatablePayload, metatablePayloadError = invoke(
        'item.get', setmetatable({}, { __index = {} }))
      assert(metatablePayload == nil
        and metatablePayloadError.code == 'COMPAT_DTO_INVALID')

      handlers.onResourceStop('synex_inventory_adapter')
      local cleaned, cleanedError = invoke('item.get', {})
      assert(cleaned == nil and cleanedError.code == 'COMPAT_ADAPTER_MISSING')
      assert(registerAdapter())
      local restarted = assert(invoke('item.get', { item = 'bread' }))
      assert(restarted.item == 'bread')
      return table.concat({
        missingError.code, wrongConsumerError.code, wrongSurfaceError.code,
        wrongOperationError.code, wrongProviderError.code, unofficialError.code,
        underclaimedError.code, compatDeniedError.code, nativeDeniedError.code,
        finalGateError.code, failedError.code, thrownError.code,
        oversizedPayloadError.code, oversizedResultError.code,
        callableResultError.code, metatablePayloadError.code,
        cleanedError.code, handlerCalls,
      }, ':')
    `);
    assert.equal(
      result,
      'COMPAT_ADAPTER_MISSING:COMPAT_CONSUMER_DENIED:COMPAT_API_UNSUPPORTED:'
        + 'COMPAT_API_UNSUPPORTED:COMPAT_FRAMEWORK_CONFLICT:COMPAT_CONSUMER_DENIED:'
        + 'COMPAT_DTO_INVALID:CAPABILITY_DENIED:CAPABILITY_DENIED:CAPABILITY_DENIED:'
        + 'COMPAT_ADAPTER_MISSING:COMPAT_INTERNAL:COMPAT_DTO_LIMIT:COMPAT_DTO_LIMIT:'
        + 'COMPAT_DTO_INVALID:COMPAT_DTO_INVALID:COMPAT_ADAPTER_MISSING:6',
    );
  } finally {
    engine.global.close();
  }
});

test('official providers resolve and invoke only revision-fenced authorized catalogs', async () => {
  const engine = await createCoordinator({ configuredConsumer: true, domainCatalog: true });
  try {
    const result = await engine.doString(String.raw`
      local handlerCalls = 0
      local definition = {
        name = 'inventory.items', version = '1.2.0', provider = 'all',
        domain = 'inventory', status = 'PARTIAL', authority = 'domain', revision = 7,
        operations = { 'item.lookup', 'item.fail', 'item.throw', 'item.large',
          'item.callable' },
      }
      local implementation = {
        ['item.lookup'] = function(context, payload)
          handlerCalls = handlerCalls + 1
          assert(context.schemaVersion == 1 and context.provider == 'qb'
            and context.providerResource == 'synex_bridge_qb'
            and context.consumer == 'legacy_consumer'
            and context.profile.id == 'qb.fixture'
            and context.surface.name == 'qb.inventory.catalog_lookup'
            and context.catalog.name == 'inventory.items'
            and context.catalog.domain == 'inventory'
            and context.catalog.authority == 'domain'
            and context.catalog.revision == 7
            and context.operation == 'item.lookup')
          payload.touched = true
          return { item = payload.item, revision = context.catalog.revision }
        end,
        ['item.fail'] = function()
          handlerCalls = handlerCalls + 1
          return nil, {
            code = 'COMPAT_CATALOG_UNAVAILABLE', message = 'private catalog detail',
            retryable = true,
          }
        end,
        ['item.throw'] = function()
          handlerCalls = handlerCalls + 1
          error('private catalog throw')
        end,
        ['item.large'] = function()
          handlerCalls = handlerCalls + 1
          return { value = string.rep('x', 5000) }
        end,
        ['item.callable'] = function()
          handlerCalls = handlerCalls + 1
          return { leak = function() end }
        end,
      }
      local function resolve(operation)
        invokingResource = 'synex_bridge_qb'
        return exported.ResolveCompatibilityCatalog('legacy_consumer', {
          surface = 'qb.inventory.catalog_lookup', operation = operation,
        })
      end
      local function invoke(operation, payload)
        invokingResource = 'synex_bridge_qb'
        return exported.InvokeCompatibilityCatalog('legacy_consumer', {
          surface = 'qb.inventory.catalog_lookup', operation = operation,
          payload = payload or {},
        })
      end
      local function registerCatalog()
        invokingResource = 'synex_inventory'
        return exported.RegisterCompatibilityCatalog(definition, implementation)
      end

      local missing, missingError = resolve('item.lookup')
      assert(missing == nil and missingError.code == 'COMPAT_CATALOG_UNAVAILABLE'
        and handlerCalls == 0)
      deniedCapability = 'synex.compat.catalog.register'
      local registrationDenied, registrationDeniedError = registerCatalog()
      assert(registrationDenied == nil
        and registrationDeniedError.code == 'CAPABILITY_DENIED')
      deniedCapability = nil
      assert(registerCatalog())

      local metadata = assert(resolve('item.lookup'))
      assert(metadata.catalog.name == 'inventory.items'
        and metadata.catalog.version == '1.2.0'
        and metadata.catalog.revision == 7
        and metadata.catalog.authority == 'domain')
      local resolveTrace = traceContexts[#traceContexts]
      assert(resolveTrace.operation == 'compat.qb.ResolveCatalog'
        and resolveTrace.compatProvider == 'qb'
        and resolveTrace.consumer == 'legacy_consumer'
        and resolveTrace.legacyApi == 'ResolveCatalog'
        and resolveTrace.payload == nil and resolveTrace.request == nil)
      local original = { item = 'water' }
      local success = assert(invoke('item.lookup', original))
      assert(success.item == 'water' and success.revision == 7
        and original.touched == nil and handlerCalls == 1)
      local invokeTrace = traceContexts[#traceContexts]
      assert(invokeTrace.operation == 'compat.qb.InvokeCatalog'
        and invokeTrace.compatProvider == 'qb'
        and invokeTrace.consumer == 'legacy_consumer'
        and invokeTrace.legacyApi == 'InvokeCatalog'
        and invokeTrace.payload == nil and invokeTrace.request == nil)

      capabilityChecks = {}
      deniedCapability = 'synex.compat.qb.read'
      local compatDenied, compatDeniedError = invoke('item.lookup', {})
      assert(compatDenied == nil and compatDeniedError.code == 'CAPABILITY_DENIED'
        and #capabilityChecks == 1 and handlerCalls == 1)
      capabilityChecks = {}
      deniedCapability = 'synex.inventory.read'
      local nativeDenied, nativeDeniedError = invoke('item.lookup', {})
      assert(nativeDenied == nil and nativeDeniedError.code == 'CAPABILITY_DENIED'
        and #capabilityChecks == 2
        and capabilityChecks[1].capability == 'synex.compat.qb.read'
        and capabilityChecks[2].capability == 'synex.inventory.read'
        and handlerCalls == 1)
      capabilityChecks = {}
      deniedCapability = 'synex.identity.read'
      local finalDenied, finalDeniedError = invoke('item.lookup', {})
      assert(finalDenied == nil and finalDeniedError.code == 'CAPABILITY_DENIED'
        and #capabilityChecks == 3
        and capabilityChecks[3].capability == 'synex.identity.read'
        and handlerCalls == 1)
      deniedCapability = nil

      local wrongOperation, wrongOperationError = invoke('item.delete', {})
      assert(wrongOperation == nil
        and wrongOperationError.code == 'COMPAT_API_UNSUPPORTED')
      local extraField, extraFieldError = exported.InvokeCompatibilityCatalog(
        'legacy_consumer', {
          surface = 'qb.inventory.catalog_lookup', operation = 'item.lookup',
          payload = {}, revision = 7,
        })
      assert(extraField == nil and extraFieldError.code == 'COMPAT_DTO_INVALID')
      local failed, failedError = invoke('item.fail', {})
      assert(failed == nil and failedError.code == 'COMPAT_CATALOG_UNAVAILABLE'
        and failedError.message ~= 'private catalog detail')
      local thrown, thrownError = invoke('item.throw', {})
      assert(thrown == nil and thrownError.code == 'COMPAT_INTERNAL'
        and not thrownError.message:find('private catalog throw', 1, true))
      local oversizedPayload, oversizedPayloadError = invoke(
        'item.lookup', { value = string.rep('x', 5000) })
      assert(oversizedPayload == nil
        and oversizedPayloadError.code == 'COMPAT_DTO_LIMIT')
      local oversizedResult, oversizedResultError = invoke('item.large', {})
      assert(oversizedResult == nil
        and oversizedResultError.code == 'COMPAT_DTO_LIMIT')
      local callableResult, callableResultError = invoke('item.callable', {})
      assert(callableResult == nil
        and callableResultError.code == 'COMPAT_DTO_INVALID')

      invokingResource = 'synex_inventory'
      local unchanged, unchangedError = exported.RegisterCompatibilityCatalog(
        definition, implementation)
      assert(unchanged == nil and unchangedError.code == 'COMPAT_VERSION_CONFLICT')
      definition.revision = 8
      assert(exported.RegisterCompatibilityCatalog(definition, implementation))
      local stale, staleError = invoke('item.lookup', {})
      assert(stale == nil and staleError.code == 'COMPAT_VERSION_CONFLICT'
        and handlerCalls == 5)

      handlers.onResourceStop('synex_inventory')
      definition.revision = 7
      assert(registerCatalog())
      local restarted = assert(invoke('item.lookup', { item = 'bread' }))
      assert(restarted.item == 'bread' and handlerCalls == 6)

      local usage = assert(controlDefinition.operations.list({
        view = 'catalog_usage', limit = 20,
      }))
      assert(usage.registeredCatalogs == 1 and usage.observedCalls >= 10
        and #usage.items == 2 and usage.evidenceTruncated == false)
      local unsupportedCalls = 0
      for _, item in ipairs(usage.items) do
        unsupportedCalls = unsupportedCalls + item.unsupported
      end
      assert(unsupportedCalls >= 2)
      assert(usage.items[1].consumerResource == 'legacy_consumer'
        and usage.items[2].consumerResource == 'legacy_consumer')
      handlers.onResourceStop('legacy_consumer')
      local cleared = assert(controlDefinition.operations.list({
        view = 'catalog_usage', limit = 20,
      }))
      assert(cleared.registeredCatalogs == 1 and cleared.observedCalls == 0
        and #cleared.items == 0)
      return table.concat({
        missingError.code, registrationDeniedError.code,
        compatDeniedError.code, nativeDeniedError.code,
        finalDeniedError.code, wrongOperationError.code, extraFieldError.code,
        failedError.code, thrownError.code, oversizedPayloadError.code,
        oversizedResultError.code, callableResultError.code, unchangedError.code,
        staleError.code, handlerCalls,
      }, ':')
    `);
    assert.equal(
      result,
      'COMPAT_CATALOG_UNAVAILABLE:CAPABILITY_DENIED:CAPABILITY_DENIED:'
        + 'CAPABILITY_DENIED:CAPABILITY_DENIED:COMPAT_API_UNSUPPORTED:COMPAT_DTO_INVALID:'
        + 'COMPAT_CATALOG_UNAVAILABLE:COMPAT_INTERNAL:COMPAT_DTO_LIMIT:'
        + 'COMPAT_DTO_LIMIT:COMPAT_DTO_INVALID:COMPAT_VERSION_CONFLICT:'
        + 'COMPAT_VERSION_CONFLICT:6',
    );
  } finally {
    engine.global.close();
  }
});

test('bridge coordinator cleans owner registries and rebinds Core integrations on restart', async () => {
  const engine = await createCoordinator({ configuredConsumer: true });
  try {
    const result = await engine.doString(String.raw`
      assert(controlRegistrations == 1 and lifecycleRegistrations == 1)
      invokingResource = 'adapter_owner'
      local adapterDefinition = {
        name = 'fixture.shared', version = '1.0.0', provider = 'qb',
        domain = 'identity', status = 'PARTIAL', operations = { 'read' },
      }
      assert(exported.RegisterCompatibilityAdapter(
        adapterDefinition, { read = function(value) return value end }))

      invokingResource = 'synex_bridge_qbx'
      local conflict, conflictError = exported.RegisterCompatibilityAdapter({
        name = 'fixture.shared', version = '1.0.0', provider = 'qbx',
        domain = 'identity', status = 'PARTIAL', operations = { 'read' },
      }, { read = function(value) return value end })
      assert(conflict == nil and conflictError.code == 'COMPAT_OWNER_CONFLICT')
      handlers.onResourceStop('adapter_owner')
      assert(exported.RegisterCompatibilityAdapter({
        name = 'fixture.shared', version = '1.0.0', provider = 'qbx',
        domain = 'identity', status = 'PARTIAL', operations = { 'read' },
      }, { read = function(value) return value end }))

      invokingResource = 'catalog_owner'
      assert(exported.RegisterCompatibilityCatalog({
        name = 'fixture.catalog', version = '1.0.0', provider = 'all',
        domain = 'identity', status = 'PARTIAL', authority = 'domain', revision = 1,
        operations = { 'read' },
      }, { read = function(value) return value end }))
      invokingResource = 'catalog_other'
      local catalogConflict, catalogConflictError = exported.RegisterCompatibilityCatalog({
        name = 'fixture.catalog', version = '1.0.0', provider = 'all',
        domain = 'identity', status = 'PARTIAL', authority = 'domain', revision = 1,
        operations = { 'read' },
      }, { read = function(value) return value end })
      assert(catalogConflict == nil
        and catalogConflictError.code == 'COMPAT_OWNER_CONFLICT')
      handlers.onResourceStop('catalog_owner')
      assert(exported.RegisterCompatibilityCatalog({
        name = 'fixture.catalog', version = '1.0.0', provider = 'all',
        domain = 'identity', status = 'PARTIAL', authority = 'domain', revision = 1,
        operations = { 'read' },
      }, { read = function(value) return value end }))

      invokingResource = 'synex_bridge_qb'
      assert(exported.ShouldPublishLifecycle({
        provider = 'qb', providerResource = 'synex_bridge_qb',
      }))
      handlers.onResourceStop('synex_core')
      handlers.onResourceStart('synex_core')
      assert(controlRegistrations == 2 and lifecycleRegistrations == 2)
      assert(#capabilityChecks == 10)
      return table.concat({
        conflictError.code, catalogConflictError.code,
        controlRegistrations, lifecycleRegistrations, #capabilityChecks,
      }, ':')
    `);
    assert.equal(result, 'COMPAT_OWNER_CONFLICT:COMPAT_OWNER_CONFLICT:2:2:10');
  } finally {
    engine.global.close();
  }
});
