import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';

const root = process.cwd();

async function runProvider(provider: 'qb' | 'qbx' | 'esx', assertions: string) {
  const engine = await new LuaFactory().createEngine();
  const source = await readFile(
    path.join(root, 'resources', `synex_bridge_${provider}`, 'server.lua'),
    'utf8',
  );
  try {
    await engine.doString(String.raw`
      invoking = 'legacy_consumer'
      registered, last = {}, {}
      stale = false
      snapshot = {
        source = 42,
        identity = { identifier = 'legacy-identity-42' },
        character = {
          id = 'internal-character-id', slot = 2,
          firstName = 'Ada', lastName = 'Lovelace', dateOfBirth = '1815-12-10',
        },
        money = { cash = 120, bank = 900 },
        accountDefinitions = {
          cash = { alias = 'cash', name = 'money', label = 'Cash',
            round = true, minorUnit = 0 },
          bank = { alias = 'bank', name = 'bank', label = 'Bank',
            round = true, minorUnit = 0 },
        },
        fence = {
          sessionId = 'internal-session-id', sourceGeneration = 7,
          characterId = 'internal-character-id',
        },
        metadata = { hunger = 40 },
        metadataVersions = { hunger = 3 },
        groups = { items = { {
          membership_id = 'membership-1', is_primary = true,
          group = {
            group_id = 'internal-group-id', key = 'police', type = 'job',
            name = 'Police', label = 'Police Department',
          },
          grade = { key = 'sergeant', name = 'Sergeant', rank = 3 },
          roles = {}, duty = { counts_as_on_duty = true },
        } }, truncated = false },
      }
      local adapter = {}
      deniedOperation, authorizedOperations = nil, {}
      function adapter:authorize(consumer, suffix, operation)
        last.authorizedConsumer = consumer
        authorizedOperations[#authorizedOperations + 1] = operation
        if operation == deniedOperation then
          return nil, { code = 'COMPAT_API_UNSUPPORTED' }
        end
        return { traceId = 'trace' }, nil
      end
      function adapter:trace(_, consumer, legacyApi, handler)
        last.traceConsumer, last.traceApi = consumer, legacyApi
        return handler()
      end
      function adapter:readPlayer(consumer, playerSource)
        last.readConsumer, last.readSource = consumer, playerSource
        return snapshot, nil
      end
      function adapter:readPlayerFenced(consumer, playerSource, fence)
        last.fencedConsumer, last.fencedSource, last.fence = consumer, playerSource, fence
        if stale then return nil, { code = 'COMPAT_STALE_SESSION' } end
        assert(fence.sessionId == snapshot.fence.sessionId)
        assert(fence.sourceGeneration == snapshot.fence.sourceGeneration)
        return snapshot, nil
      end
      function adapter:readPlayerByIdentifier(consumer, identifier)
        last.identifierConsumer, last.identifier = consumer, identifier
        if identifier == snapshot.identity.identifier then return snapshot, nil end
        return false, nil
      end
      function adapter:readMoney(consumer, playerSource)
        last.moneyReadConsumer, last.moneyReadSource = consumer, playerSource
        return snapshot, nil
      end
      function adapter:readMoneyFenced(consumer, playerSource, fence)
        last.moneyFencedConsumer, last.moneyFencedSource, last.moneyFence =
          consumer, playerSource, fence
        if stale then return nil, { code = 'COMPAT_STALE_SESSION' } end
        assert(fence.sessionId == snapshot.fence.sessionId)
        assert(fence.sourceGeneration == snapshot.fence.sourceGeneration)
        return snapshot, nil
      end
      function adapter:readCustomAccountsFenced(consumer, playerSource, fence)
        last.customAccountsConsumer, last.customAccountsSource,
          last.customAccountsFence = consumer, playerSource, fence
        if stale then return nil, { code = 'COMPAT_STALE_SESSION' } end
        assert(fence.sessionId == snapshot.fence.sessionId)
        assert(fence.sourceGeneration == snapshot.fence.sourceGeneration)
        return snapshot, nil
      end
      function adapter:readGroups(consumer, playerSource)
        last.groupsReadConsumer, last.groupsReadSource = consumer, playerSource
        return snapshot, nil
      end
      function adapter:readGroupsFenced(consumer, playerSource, fence)
        last.groupsFencedConsumer, last.groupsFencedSource, last.groupsFence =
          consumer, playerSource, fence
        if stale then return nil, { code = 'COMPAT_STALE_SESSION' } end
        assert(fence.sessionId == snapshot.fence.sessionId)
        assert(fence.sourceGeneration == snapshot.fence.sourceGeneration)
        return snapshot, nil
      end
      function adapter:readMetadata(consumer, playerSource)
        last.metadataReadConsumer, last.metadataReadSource = consumer, playerSource
        return snapshot, nil
      end
      function adapter:readMetadataFenced(consumer, playerSource, fence)
        last.metadataFencedConsumer, last.metadataFencedSource = consumer, playerSource
        if stale then return nil, { code = 'COMPAT_STALE_SESSION' } end
        assert(fence.sessionId == snapshot.fence.sessionId)
        return snapshot, nil
      end
      function adapter:unsupported(consumer, operation)
        last.unsupportedConsumer, last.unsupportedOperation = consumer, operation
        return nil, { code = 'COMPAT_API_UNSUPPORTED' }
      end
      function adapter:changeMoney(consumer, playerSource, moneyType, direction, amount, reason, fence)
        last.money = { consumer, playerSource, moneyType, direction, amount, reason, fence }
        return true, nil
      end
      function adapter:setMoney(consumer, playerSource, moneyType, amount, reason, fence)
        last.setMoney = { consumer, playerSource, moneyType, amount, reason, fence }
        return nil, { code = 'COMPAT_API_UNSUPPORTED' }
      end
      function adapter:setMetadata(consumer, playerSource, key, value, fence, version)
        last.metadata = { consumer, playerSource, key, value, fence, version }
        return { version = version + 1 }, nil
      end
      function adapter:registerCallback(consumer, name, handler)
        last.callback = { consumer, name, handler }
        return true, nil
      end
      function adapter:invokeCompatibilityAdapter(consumer, request)
        last.adapterInvocation = { consumer = consumer, request = request }
        return { handled = true, provider = '${provider}' }, nil
      end
      function adapter:usageSnapshot() return { framework = '${provider}', entries = {} } end
      function adapter:registerLifecycle(mapper, events)
        last.lifecycleData, last.lifecycleEvents = mapper(snapshot), events
        return 'lifecycle-token', nil
      end
      SynexBridgeNative = {
        create = function(options) last.options = options; return adapter end,
        isCallable = function(value) return type(value) == 'function' end,
      }
      local coordinator = {}
      function coordinator:ResolveCompatibilityCatalog(consumer, request)
        last.catalogResolve = { consumer = consumer, request = request }
        return {
          schemaVersion = 1, operation = request.operation,
          catalog = { name = 'registered.catalog', revision = 4 },
        }, nil
      end
      function coordinator:InvokeCompatibilityCatalog(consumer, request)
        last.catalogInvoke = { consumer = consumer, request = request }
        if request.operation == 'fixture.fail' then
          return false, { code = 'COMPAT_CATALOG_UNAVAILABLE' }
        end
        if request.operation == 'fixture.empty' then return false, nil end
        return { handled = true, provider = '${provider}' }, nil
      end
      exports = setmetatable({ synex_bridge = coordinator }, {
        __call = function(_, name, handler) registered[name] = handler end,
      })
      GetInvokingResource = function() return invoking end
      AddEventHandler = function() end

      function containsInternal(value, seen)
        if type(value) ~= 'table' then
          return value == 'internal-character-id' or value == 'internal-session-id'
            or value == 'internal-group-id'
        end
        seen = seen or {}
        if seen[value] then return false end
        seen[value] = true
        for key, item in pairs(value) do
          if key == 'fence' or key == 'session' or key == 'accountIds'
            or key == 'metadataVersions' or key == 'synex'
            or containsInternal(item, seen) then return true end
        end
        return false
      end
    `);
    await engine.doString(source);
    await engine.doString(String.raw`
      if '${provider}' == 'esx' then
        assert(last.options.discoverAccountMappings == true)
        assert(last.options.moneyAliases == nil)
      else
        assert(#last.options.moneyAliases == 2)
        assert(last.options.moneyAliases[1] == 'cash')
        assert(last.options.moneyAliases[2] == 'bank')
      end
      assert(last.options.moneyMappings == nil)
      local adapterResult = assert(registered.InvokeCompatibilityAdapter({
        surface = '${provider}.fixture.surface', operation = 'fixture.read', payload = {},
      }))
      assert(adapterResult.handled == true and adapterResult.provider == '${provider}'
        and last.adapterInvocation.consumer == 'legacy_consumer')
      local catalogMetadata = assert(registered.ResolveCompatibilityCatalog({
        surface = '${provider}.fixture.catalog', operation = 'fixture.read',
      }))
      assert(catalogMetadata.catalog.name == 'registered.catalog'
        and last.catalogResolve.consumer == 'legacy_consumer')
      local catalogResult = assert(registered.InvokeCompatibilityCatalog({
        surface = '${provider}.fixture.catalog', operation = 'fixture.read', payload = {},
      }))
      assert(catalogResult.handled == true and catalogResult.provider == '${provider}'
        and last.catalogInvoke.consumer == 'legacy_consumer')
      local failed, failedError = registered.InvokeCompatibilityCatalog({
        surface = '${provider}.fixture.catalog', operation = 'fixture.fail', payload = {},
      })
      assert(failed == nil and failedError.code == 'COMPAT_CATALOG_UNAVAILABLE')
      local empty, emptyError = registered.InvokeCompatibilityCatalog({
        surface = '${provider}.fixture.catalog', operation = 'fixture.empty', payload = {},
      })
      assert(empty == nil and emptyError.code == 'COMPAT_RESOLUTION_FAILED')
      local usage = assert(registered.GetCompatibilityUsage())
      assert(usage.framework == '${provider}' and last.traceConsumer == 'legacy_consumer'
        and last.traceApi == 'GetCompatibilityUsage')
      invoking = 'attacker_resource'
      local _, deniedCatalog = registered.ResolveCompatibilityCatalogForConsumer(
        'victim_resource', {
          surface = '${provider}.fixture.catalog', operation = 'fixture.read',
        })
      assert(deniedCatalog.code == 'COMPAT_CONSUMER_DENIED')
      invoking = '${provider === 'qb' ? 'qb-core' : provider === 'qbx' ? 'qbx_core' : 'es_extended'}'
      assert(registered.InvokeCompatibilityCatalogForConsumer('victim_resource', {
        surface = '${provider}.fixture.catalog', operation = 'fixture.read', payload = {},
      }))
      assert(last.catalogInvoke.consumer == 'victim_resource')
      invoking = 'legacy_consumer'
    `);
    return await engine.doString(assertions);
  } finally {
    engine.global.close();
  }
}

test('QB core-object filters require their companion compatibility surface', async () => {
  const result = await runProvider('qb', String.raw`
    deniedOperation = 'core_object.filter'
    local denied, deniedError = registered.GetCoreObject({ 'Functions' })
    assert(denied == nil and deniedError.code == 'COMPAT_API_UNSUPPORTED')
    assert(authorizedOperations[#authorizedOperations - 1] == 'core_object.read')
    assert(authorizedOperations[#authorizedOperations] == 'core_object.filter')

    deniedOperation = nil
    local filtered = assert(registered.GetCoreObject({ 'Functions' }))
    assert(type(filtered.Functions) == 'table')
    assert(filtered.Shared == nil)
    assert(authorizedOperations[#authorizedOperations - 1] == 'core_object.read')
    assert(authorizedOperations[#authorizedOperations] == 'core_object.filter')

    local unfiltered = assert(registered.GetCoreObject())
    assert(type(unfiltered.Functions) == 'table')
    assert(authorizedOperations[#authorizedOperations] == 'core_object.read')
    return 'ok'
  `);
  assert.equal(result, 'ok');
});

test('QB provider returns clean stable identity DTOs and fences every player method', async () => {
  const result = await runProvider('qb', String.raw`
    local player = assert(registered.GetPlayer(42))
    assert(player.PlayerData.citizenid == 'legacy-identity-42')
    assert(player.PlayerData.job.name == 'police')
    assert(player.PlayerData.job.grade.level == 3 and player.PlayerData.job.onduty == true)
    assert(player.PlayerData.metadata.hunger == 40)
    assert(not containsInternal(player.PlayerData))
    assert(player.Functions.GetName() == 'Ada Lovelace')
    assert(player.Functions.GetMoney('cash') == 120)
    assert(last.moneyFence.sessionId == snapshot.fence.sessionId)
    assert(last.moneyFencedConsumer == 'legacy_consumer')
    local core = assert(registered.GetCoreObject())
    assert(last.traceConsumer == 'legacy_consumer' and last.traceApi == 'GetCoreObject')
    local byIdentifier = assert(core.Functions.GetPlayerByCitizenId(
      'legacy-identity-42'))
    assert(byIdentifier.PlayerData.source == 42)
    assert(core.Functions.GetPlayerByCitizenId('legacy-id') == nil)
    assert(player.Functions.AddMoney('cash', 5, 'fixture') == true)
    assert(last.money[1] == 'legacy_consumer' and last.money[7].sourceGeneration == 7)
    assert(player.Functions.SetMetaData('hunger', 30) == true)
    assert(last.metadata[6] == 3 and last.metadata[5].characterId == snapshot.fence.characterId)
    stale = true
    local _, staleNameError = player.Functions.GetName()
    assert(staleNameError.code == 'COMPAT_STALE_SESSION')
    local _, staleError = player.Functions.GetMoney('cash')
    assert(staleError.code == 'COMPAT_STALE_SESSION')
    invoking = 'attacker_resource'
    local _, denied = registered.GetCoreObjectForConsumer('victim_resource')
    assert(denied.code == 'COMPAT_CONSUMER_DENIED')
    invoking = 'qb-core'
    local filtered = assert(registered.GetCoreObjectForConsumer(
      'victim_resource', { 'Functions' }))
    assert(type(filtered.Functions) == 'table' and filtered.Shared == nil)
    local sharedOnly = assert(registered.GetCoreObjectForConsumer(
      'victim_resource', { 'Shared' }))
    assert(sharedOnly.Functions == nil and sharedOnly.Shared == nil)
    local invalidFilter, invalidFilterError = registered.GetCoreObjectForConsumer(
      'victim_resource', { [2] = 'Functions' })
    assert(invalidFilter == nil and invalidFilterError.code == 'COMPAT_DTO_INVALID')
    assert(last.authorizedConsumer == 'victim_resource')
    return 'ok'
  `);
  assert.equal(result, 'ok');
});

test('Qbox provider keeps export semantics separate and projects bounded native groups', async () => {
  const result = await runProvider('qbx', String.raw`
    assert(registered.GetCoreObject == nil, 'qbx-no-core-object')
    local player = assert(registered.GetPlayer(42))
    assert(player.PlayerData.citizenid == 'legacy-identity-42', 'qbx-citizen')
    assert(player.PlayerData.groups.police == 3)
    assert(player.PlayerData.job.name == 'police' and player.PlayerData.job.onduty == true)
    assert(not containsInternal(player.PlayerData))
    assert(registered.GetMoney(42, 'bank') == 900, 'qbx-money')
    assert(last.moneyReadConsumer == 'legacy_consumer')
    local groups = registered.GetGroups(42)
    assert(groups.police == 3)
    assert(last.groupsReadConsumer == 'legacy_consumer')
    local byIdentifier = assert(registered.GetPlayerByCitizenId('legacy-identity-42'))
    assert(byIdentifier.PlayerData.source == 42)
    local missingByIdentifier = registered.GetPlayerByCitizenId('legacy-id')
    assert(missingByIdentifier == nil, 'qbx-missing-identifier')
    assert(registered.AddMoney(42, 'cash', 1, 'direct-fixture') == true,
      'qbx-direct-money')
    assert(last.money[2] == 42 and last.money[7] == nil)
    assert(player.Functions.AddMoney('bank', 10, 'fixture') == true,
      'qbx-player-money')
    assert(last.money[7].sessionId == snapshot.fence.sessionId)
    invoking = 'attacker_resource'
    local _, denied = registered.GetPlayerForConsumer('victim_resource', 42)
    assert(denied.code == 'COMPAT_CONSUMER_DENIED')
    invoking = 'qbx_core'
    assert(registered.GetPlayerForConsumer('victim_resource', 42))
    assert(last.readConsumer == 'victim_resource')
    return 'ok'
  `);
  assert.equal(result, 'ok');
});

test('ESX provider uses stable identifiers and fenced xPlayer account and job methods', async () => {
  const result = await runProvider('esx', String.raw`
    local player = assert(registered.GetPlayerFromId(42))
    assert(player.getIdentifier() == 'legacy-identity-42')
    local job = player.getJob()
    assert(job.name == 'police' and job.grade == 3 and job.onDuty == true)
    assert(player.getMoney() == 120)
    assert(last.fence.sessionId == snapshot.fence.sessionId)
    assert(player.addAccountMoney('bank', 10, 'fixture') == true)
    assert(last.money[7].sourceGeneration == 7)
    assert(not containsInternal(last.lifecycleData))
    stale = true
    local _, identifierError = player.getIdentifier()
    assert(identifierError.code == 'COMPAT_STALE_SESSION')
    local _, staleError = player.getAccount('bank')
    assert(staleError.code == 'COMPAT_STALE_SESSION')
    invoking = 'attacker_resource'
    local _, denied = registered.GetSharedObjectForConsumer('victim_resource')
    assert(denied.code == 'COMPAT_CONSUMER_DENIED')
    invoking = 'es_extended'
    assert(registered.GetSharedObjectForConsumer('victim_resource'))
    assert(last.authorizedConsumer == 'victim_resource'
      and last.traceConsumer == 'victim_resource' and last.traceApi == 'getSharedObject')
    return 'ok'
  `);
  assert.equal(result, 'ok');
});

test('historical facades are explicit TCB code and forward only their observed caller', async () => {
  const facades = [
    { name: 'qb-core', provider: 'synex_bridge_qb' },
    { name: 'qbx_core', provider: 'synex_bridge_qbx' },
    { name: 'es_extended', provider: 'synex_bridge_esx' },
  ] as const;
  for (const facade of facades) {
    const directory = path.join(root, 'compat', 'facades', facade.name);
    const manifest = await readFile(path.join(directory, 'fxmanifest.lua'), 'utf8');
    const server = await readFile(path.join(directory, 'server.lua'), 'utf8');
    const client = await readFile(path.join(directory, 'client.lua'), 'utf8');
    assert.match(manifest, new RegExp(`name '${facade.name}'`, 'u'));
    assert.match(manifest, new RegExp(`dependency '${facade.provider}'`, 'u'));
    assert.match(manifest, /synex_compatibility_facade 'true'/u);
    for (const source of [server, client]) {
      assert.match(source, /GetInvokingResource\(\)/u);
      assert.match(source, /ForConsumer/u);
      assert.doesNotMatch(source, /RegisterNetEvent/u);
      assert.doesNotMatch(source, /function\s*\(consumer[,)]/u);
    }
  }
});

test('server facades forward the actual Cfx caller exactly once', async () => {
  const cases = [
    {
      facade: 'qb-core', provider: 'synex_bridge_qb',
      facadeExport: 'GetPlayer', providerExport: 'GetPlayerForConsumer',
    },
    {
      facade: 'qbx_core', provider: 'synex_bridge_qbx',
      facadeExport: 'GetPlayer', providerExport: 'GetPlayerForConsumer',
    },
    {
      facade: 'es_extended', provider: 'synex_bridge_esx',
      facadeExport: 'GetPlayerFromId', providerExport: 'GetPlayerFromIdForConsumer',
    },
  ] as const;

  for (const entry of cases) {
    const engine = await new LuaFactory().createEngine();
    const source = await readFile(
      path.join(root, 'compat', 'facades', entry.facade, 'server.lua'),
      'utf8',
    );
    try {
      await engine.doString(String.raw`
        invoking = 'real_legacy_consumer'
        registered, providerCall = {}, nil
        local provider = {}
        setmetatable(provider, {
          __index = function(_, name)
            return function(first, ...)
              local forwarded = { ... }
              local consumer
              if first == provider then consumer = forwarded[1]
              else consumer = first end
              providerCall = { name = name, consumer = consumer }
              return 'provider-sentinel'
            end
          end,
        })
        exports = setmetatable({}, {
          __call = function(_, name, handler) registered[name] = handler end,
          __index = function(_, resource)
            assert(resource == '${entry.provider}')
            return provider
          end,
        })
        GetInvokingResource = function() return invoking end
        AddEventHandler = function() end
      `);
      await engine.doString(source);
      const result = await engine.doString(String.raw`
        assert(registered['${entry.facadeExport}'](42) == 'provider-sentinel')
        assert(providerCall.name == '${entry.providerExport}')
        assert(providerCall.consumer == 'real_legacy_consumer')
        providerCall = nil
        invoking = 'x'
        assert(registered['${entry.facadeExport}'](42) == nil)
        assert(providerCall == nil)
        return 'ok'
      `);
      assert.equal(result, 'ok');
    } finally {
      engine.global.close();
    }
  }
});

test('provider manifests load strict Foundation before Native without registry privilege', async () => {
  for (const provider of ['qb', 'qbx', 'esx'] as const) {
    const directory = path.join(root, 'resources', `synex_bridge_${provider}`);
    const manifest = await readFile(path.join(directory, 'fxmanifest.lua'), 'utf8');
    const descriptor = JSON.parse(
      await readFile(path.join(directory, 'synex.resource.json'), 'utf8'),
    ) as { capabilities: { request: string[] } };
    const foundation = manifest.indexOf("'@synex_bridge/kernel/foundation.lua'");
    const native = manifest.indexOf("'@synex_bridge/native_server.lua'");
    assert.ok(foundation >= 0 && native > foundation);
    assert.ok(!descriptor.capabilities.request.includes('synex.compat.adapter.register'));
  }
});
