import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import test from "node:test";
import { LuaFactory } from "wasmoon";

const root = process.cwd();
const foundationPath = join(root, "libraries", "synex_bridge", "kernel", "foundation.lua");
const nativeServerPath = join(root, "libraries", "synex_bridge", "native_server.lua");

type Provider = "qb" | "qbx" | "esx";

async function fuzzProvider(provider: Provider) {
  const engine = await new LuaFactory().createEngine();
  const resourceName = `synex_bridge_${provider}`;
  const historicalResource = provider === "qb"
    ? "qb-core"
    : provider === "qbx" ? "qbx_core" : "es_extended";
  try {
    await engine.doString(String.raw`
      fixtureProvider = '${provider}'
      fixtureResource = '${resourceName}'
      historicalResource = '${historicalResource}'
      invoking = 'hostile_consumer'
      source = 0
      now = 1000
      registered, handlers, subscriptions = {}, {}, {}
      domainReads, domainMutations, metadataWrites = 0, 0, 0
      coordinatorAdapterCalls, coordinatorCatalogCalls = 0, 0
      metricWrites, capabilityChecks = 0, 0

      json = {
        encode = function() return '{}' end,
        decode = function() return {} end,
      }
      print = function() end
      GetGameTimer = function() return now end
      GetCurrentResourceName = function() return fixtureResource end
      GetInvokingResource = function() return invoking end
      GetResourceState = function(name)
        if name == 'hostile_consumer' or name == 'victim_consumer'
          or name == 'synex_core' then return 'started' end
        return 'missing'
      end
      GetResourceMetadata = function() return nil end
      GetPlayerName = function(playerSource)
        return tonumber(playerSource) == 10 and 'Fixture Player' or nil
      end
      GetPlayers = function() return {} end
      RegisterNetEvent = function(name, handler) handlers[name] = handler end
      AddEventHandler = function(name, handler) handlers[name] = handler end
      SetTimeout = function() end
      TriggerEvent = function() end
      TriggerClientEvent = function() end

      local function characterId(playerSource)
        return ('character_%d'):format(playerSource)
      end

      local api = {
        Tracing = { run = function(context, handler)
          return handler(context.traceId)
        end },
        Capabilities = {
          checkResource = function(resource, capability)
            capabilityChecks = capabilityChecks + 1
            assert(resource == 'hostile_consumer' or resource == 'victim_consumer')
            assert(type(capability) == 'string' and #capability <= 128)
            return true, nil
          end,
        },
        Players = {
          getBySource = function(playerSource)
            return {
              id = ('session_%d'):format(playerSource), state = 'ACTIVE',
              source = playerSource, sourceGeneration = 1,
              characterId = characterId(playerSource),
            }, nil
          end,
        },
        Characters = {
          getActive = function(playerSource)
            return {
              id = characterId(playerSource), slot = 1,
              firstName = 'Fuzz', lastName = 'Fixture',
            }, nil
          end,
          registerLifecycleParticipant = function(definition)
            assert(type(definition) == 'table')
            return 'lifecycle-token', nil
          end,
        },
        Events = {
          subscribe = function(topic, handler)
            subscriptions[topic] = handler
            return 'subscription:' .. topic, nil
          end,
        },
        Services = {
          call = function(name, _, method, request)
            if name == 'synex.accounts' and method == 'list_by_owner' then
              domainReads = domainReads + 1
              local suffix = request.owner_ref:gsub('%-', '')
              return { items = {
                {
                  account_id = '11111111-1111-4111-8111-111111111111',
                  currency_code = 'usd', account_key = 'cash_' .. suffix,
                  minor_unit = 0, account_role = 'asset',
                  owner_kind = 'character', owner_ref = request.owner_ref,
                  status = 'active', booked_minor = 100, sequence = 1,
                },
                {
                  account_id = '22222222-2222-4222-8222-222222222222',
                  currency_code = 'usd', account_key = 'bank_' .. suffix,
                  minor_unit = 0, account_role = 'asset',
                  owner_kind = 'character', owner_ref = request.owner_ref,
                  status = 'active', booked_minor = 500, sequence = 1,
                },
              } }, nil
            end
            if name == 'synex.groups' and method == 'compatibility_snapshot' then
              domainReads = domainReads + 1
              return { items = {}, truncated = false }, nil
            end
            domainMutations = domainMutations + 1
            return nil, { code = 'UNEXPECTED_DOMAIN_MUTATION' }
          end,
        },
        RPC = {
          call = function()
            domainMutations = domainMutations + 1
            return nil, { code = 'UNEXPECTED_DOMAIN_MUTATION' }
          end,
        },
        Metrics = {
          increment = function()
            metricWrites = metricWrites + 1
            return true
          end,
          observe = function()
            metricWrites = metricWrites + 1
            return true
          end,
        },
      }

      local core = {}
      function core:GetAPI() return api, nil end

      local function finalArgument(...)
        local arguments = table.pack(...)
        return arguments[arguments.n]
      end

      local bridge = {}
      bridge.AuthorizeCompatibilityConsumer = function(...)
        local request = finalArgument(...)
        assert(type(request) == 'table' and request.provider == fixtureProvider
          and request.providerResource == fixtureResource)
        return {
          authority = 'operator_registry', mode = 'compat',
          traceId = 'trace-provider-fuzz',
        }, nil
      end
      bridge.ResolveCompatibilityAccountMapping = function(...)
        local request = finalArgument(...)
        if type(request) ~= 'table'
          or (request.alias ~= 'cash' and request.alias ~= 'bank') then
          return nil, { code = 'COMPAT_MAPPING_MISSING' }
        end
        return {
          id = fixtureProvider .. '.' .. request.alias,
          version = '2.0.0', alias = request.alias,
          currencyCode = 'usd', accountKey = request.alias,
          accountRole = 'asset', minorUnit = 0, status = 'PARTIAL',
        }, nil
      end
      bridge.ListCompatibilityAccountMappings = function(...)
        local request = finalArgument(...)
        assert(type(request) == 'table' and request.provider == fixtureProvider)
        local function mapping(alias, legacyName, label)
          return {
            id = fixtureProvider .. '.' .. alias,
            version = '2.0.0', alias = alias,
            currencyCode = 'usd', accountKey = alias,
            accountRole = 'asset', minorUnit = 0,
            legacyName = legacyName, label = label, round = true,
            status = 'PARTIAL',
          }
        end
        return { truncated = false, items = {
          mapping('bank', 'bank', 'Bank'),
          mapping('cash', fixtureProvider == 'esx' and 'money' or 'cash', 'Cash'),
        } }, nil
      end
      bridge.ProjectCompatibilityGroups = function(...)
        local request = finalArgument(...)
        return {
          items = type(request) == 'table' and type(request.groups) == 'table'
            and request.groups.items or {},
          truncated = false,
        }, nil
      end
      bridge.ResolveCompatibilityIdentity = function()
        return {
          identifier = fixtureProvider .. '-identity-10',
          identifierType = fixtureProvider == 'esx' and 'identifier' or 'citizenid',
          importSource = 'fuzz-fixture',
        }, nil
      end
      bridge.GetCompatibilityMetadata = function()
        return { values = { hunger = 50 }, versions = { hunger = 1 } }, nil
      end
      bridge.ResolveMoneyPolicy = function()
        return {
          action = 'transfer',
          accountId = '33333333-3333-4333-8333-333333333333',
          reasonCode = 'compat.fuzz', policyId = 'fuzz.policy',
          policyVersion = '1.0.0',
        }, nil
      end
      bridge.ResolveCompatibilityGroupMapping = function(...)
        local request = finalArgument(...)
        if type(request) ~= 'table' or request.legacyName ~= 'police'
          or request.legacyGrade ~= 1 then
          return nil, { code = 'COMPAT_MAPPING_MISSING' }
        end
        return {
          id = fixtureProvider .. '.job.police.1', version = '1.0.0',
          legacyType = request.legacyType, legacyName = 'police', legacyGrade = 1,
          nativeGroupType = request.legacyType, nativeGroupKey = 'police',
          gradeKey = 'officer', dutySupported = true, dutyState = 'active',
          status = 'PARTIAL',
        }, nil
      end
      bridge.ResolveMetadataMapping = function(...)
        local request = finalArgument(...)
        if type(request) ~= 'table' or request.key ~= 'hunger' then
          return nil, { code = 'COMPAT_METADATA_UNSUPPORTED' }
        end
        return { allowed = true, nativeKey = 'needs.hunger' }, nil
      end
      bridge.SetCompatibilityMetadata = function(...)
        local request = finalArgument(...)
        if type(request) ~= 'table' or type(request.value) ~= 'number'
          or request.value ~= request.value or math.type(request.value) ~= 'integer'
          or request.value < 0 or request.value > 100 then
          return nil, { code = 'COMPAT_DTO_INVALID' }
        end
        metadataWrites = metadataWrites + 1
        return { version = 2 }, nil
      end
      bridge.InvokeCompatibilityAdapter = function()
        coordinatorAdapterCalls = coordinatorAdapterCalls + 1
        return nil, { code = 'COMPAT_INVALID_ARGUMENT' }
      end
      bridge.ResolveCompatibilityCatalog = function()
        coordinatorCatalogCalls = coordinatorCatalogCalls + 1
        return nil, { code = 'COMPAT_CATALOG_UNAVAILABLE' }
      end
      bridge.InvokeCompatibilityCatalog = bridge.ResolveCompatibilityCatalog

      exports = setmetatable({ synex_core = core, synex_bridge = bridge }, {
        __call = function(_, name, handler) registered[name] = handler end,
      })
    `);
    await engine.doString(await readFile(foundationPath, "utf8"));
    await engine.doString(await readFile(nativeServerPath, "utf8"));
    await engine.doString(await readFile(
      join(root, "resources", resourceName, "server.lua"),
      "utf8",
    ));

    const result = await engine.doString(String.raw`
      local function call(label, handler, ...)
        local result = table.pack(pcall(handler, ...))
        assert(result[1], label .. ': escaped provider boundary')
        if result[2] == nil or result[2] == false then
          assert(result[3] == nil or type(result[3]) == 'table',
            label .. ': returned an unstructured failure')
        end
        return result[2], result[3]
      end

      local cyclic = {}; cyclic.self = cyclic
      local hostileTable = setmetatable({ marker = true }, {
        __index = function() error('hostile __index executed') end,
      })
      local invalidSources = {
        { value = nil }, { value = false }, { value = 0 }, { value = -1 },
        { value = 1.5 }, { value = 0 / 0 }, { value = math.huge },
        { value = 65535 }, { value = '10' }, { value = {} },
        { value = hostileTable }, { value = function() end },
      }
      local invalidAmounts = {
        { value = nil }, { value = false }, { value = -1 }, { value = 0 },
        { value = 1.5 }, { value = 0 / 0 }, { value = math.huge },
        { value = 9007199254740992 }, { value = '1' }, { value = {} },
        { value = cyclic }, { value = function() end },
      }
      local invalidTargets = {
        { value = nil }, { value = false }, { value = -1 }, { value = 1.5 },
        { value = 0 / 0 }, { value = math.huge },
        { value = 9007199254740992 }, { value = '1' }, { value = {} },
      }
      local invalidAliases = {
        { value = nil }, { value = false }, { value = 'crypto' },
        { value = '../cash' }, { value = string.rep('a', 33) },
        { value = {} }, { value = cyclic }, { value = function() end },
      }
      local invalidNames = {
        { value = nil }, { value = false }, { value = '' },
        { value = 'Police' }, { value = '../police' },
        { value = string.rep('p', 65) }, { value = {} }, { value = cyclic },
      }
      local invalidGrades = {
        { value = nil }, { value = false }, { value = -1 }, { value = 1.5 },
        { value = 0 / 0 }, { value = 65536 }, { value = '1' }, { value = {} },
      }
      local invalidMetadata = {
        { value = nil }, { value = false }, { value = -1 }, { value = 101 },
        { value = 1.5 }, { value = 0 / 0 }, { value = math.huge },
        { value = string.rep('x', 2048) }, { value = {} },
        { value = cyclic }, { value = function() end },
      }

      local player, shared, coreObject
      if fixtureProvider == 'qb' then
        player = assert(registered.GetPlayer(10))
        coreObject = assert(registered.GetCoreObject())
      elseif fixtureProvider == 'qbx' then
        player = assert(registered.GetPlayer(10))
      else
        player = assert(registered.GetPlayerFromId(10))
        shared = assert(registered.getSharedObject())
      end
      assert(domainReads > 0)
      domainMutations, metadataWrites = 0, 0

      for index, fixture in ipairs(invalidSources) do
        if fixtureProvider == 'qb' then
          call('qb.GetPlayer.' .. index, registered.GetPlayer, fixture.value)
          call('qb.Core.GetPlayer.' .. index,
            coreObject.Functions.GetPlayer, fixture.value)
        elseif fixtureProvider == 'qbx' then
          call('qbx.GetPlayer.' .. index, registered.GetPlayer, fixture.value)
          call('qbx.GetMoney.' .. index,
            registered.GetMoney, fixture.value, 'cash')
          call('qbx.GetMetadata.' .. index,
            registered.GetMetadata, fixture.value, 'hunger')
          call('qbx.GetGroups.' .. index, registered.GetGroups, fixture.value)
          call('qbx.AddMoney.source.' .. index,
            registered.AddMoney, fixture.value, 'cash', 1, 'fuzz')
          call('qbx.RemoveMoney.source.' .. index,
            registered.RemoveMoney, fixture.value, 'cash', 1, 'fuzz')
          call('qbx.SetMoney.source.' .. index,
            registered.SetMoney, fixture.value, 'cash', 1, 'fuzz')
          call('qbx.SetMetadata.source.' .. index,
            registered.SetMetadata, fixture.value, 'hunger', 50)
        else
          call('esx.GetPlayerFromId.' .. index,
            registered.GetPlayerFromId, fixture.value)
          call('esx.shared.GetPlayerFromId.' .. index,
            shared.GetPlayerFromId, fixture.value)
        end
      end

      for index, fixture in ipairs(invalidAmounts) do
        if fixtureProvider == 'qb' or fixtureProvider == 'qbx' then
          call(fixtureProvider .. '.player.AddMoney.' .. index,
            player.Functions.AddMoney, 'cash', fixture.value, 'fuzz')
          call(fixtureProvider .. '.player.RemoveMoney.' .. index,
            player.Functions.RemoveMoney, 'cash', fixture.value, 'fuzz')
          if fixtureProvider == 'qbx' then
            call('qbx.AddMoney.amount.' .. index,
              registered.AddMoney, 10, 'cash', fixture.value, 'fuzz')
            call('qbx.RemoveMoney.amount.' .. index,
              registered.RemoveMoney, 10, 'cash', fixture.value, 'fuzz')
          end
        else
          call('esx.addMoney.' .. index, player.addMoney, fixture.value, 'fuzz')
          call('esx.removeMoney.' .. index,
            player.removeMoney, fixture.value, 'fuzz')
        end
      end
      for index, fixture in ipairs(invalidTargets) do
        if fixtureProvider == 'qb' or fixtureProvider == 'qbx' then
          call(fixtureProvider .. '.player.SetMoney.' .. index,
            player.Functions.SetMoney, 'cash', fixture.value, 'fuzz')
          if fixtureProvider == 'qbx' then
            call('qbx.SetMoney.amount.' .. index,
              registered.SetMoney, 10, 'cash', fixture.value, 'fuzz')
          end
        else
          call('esx.setMoney.' .. index, player.setMoney, fixture.value, 'fuzz')
        end
      end

      for index, fixture in ipairs(invalidAliases) do
        if fixtureProvider == 'qb' or fixtureProvider == 'qbx' then
          call(fixtureProvider .. '.GetMoney.alias.' .. index,
            player.Functions.GetMoney, fixture.value)
          call(fixtureProvider .. '.AddMoney.alias.' .. index,
            player.Functions.AddMoney, fixture.value, 1, 'fuzz')
          call(fixtureProvider .. '.RemoveMoney.alias.' .. index,
            player.Functions.RemoveMoney, fixture.value, 1, 'fuzz')
          call(fixtureProvider .. '.SetMoney.alias.' .. index,
            player.Functions.SetMoney, fixture.value, 1, 'fuzz')
          if fixtureProvider == 'qbx' then
            call('qbx.direct.AddMoney.alias.' .. index,
              registered.AddMoney, 10, fixture.value, 1, 'fuzz')
          end
        else
          call('esx.getAccount.' .. index, player.getAccount, fixture.value)
          call('esx.addAccountMoney.' .. index,
            player.addAccountMoney, fixture.value, 1, 'fuzz')
          call('esx.removeAccountMoney.' .. index,
            player.removeAccountMoney, fixture.value, 1, 'fuzz')
          call('esx.setAccountMoney.' .. index,
            player.setAccountMoney, fixture.value, 1, 'fuzz')
        end
      end

      for index, fixture in ipairs(invalidMetadata) do
        if fixtureProvider == 'qb' or fixtureProvider == 'qbx' then
          call(fixtureProvider .. '.SetMetaData.value.' .. index,
            player.Functions.SetMetaData, 'hunger', fixture.value)
          if fixtureProvider == 'qbx' then
            call('qbx.SetMetadata.value.' .. index,
              registered.SetMetadata, 10, 'hunger', fixture.value)
          end
        else
          call('esx.setMeta.value.' .. index,
            player.setMeta, 'hunger', fixture.value)
        end
      end
      for index, fixture in ipairs(invalidNames) do
        if fixtureProvider == 'qb' or fixtureProvider == 'qbx' then
          call(fixtureProvider .. '.SetJob.name.' .. index,
            player.Functions.SetJob, fixture.value, 1)
          call(fixtureProvider .. '.SetGang.name.' .. index,
            player.Functions.SetGang, fixture.value, 1)
        else
          call('esx.setJob.name.' .. index, player.setJob, fixture.value, 1)
        end
      end
      for index, fixture in ipairs(invalidGrades) do
        if fixtureProvider == 'qb' or fixtureProvider == 'qbx' then
          call(fixtureProvider .. '.SetJob.grade.' .. index,
            player.Functions.SetJob, 'police', fixture.value)
          call(fixtureProvider .. '.SetGang.grade.' .. index,
            player.Functions.SetGang, 'police', fixture.value)
        else
          call('esx.setJob.grade.' .. index,
            player.setJob, 'police', fixture.value)
        end
      end
      if fixtureProvider == 'qb' or fixtureProvider == 'qbx' then
        for index, value in ipairs({ 0, 1, 'true', {}, cyclic }) do
          call(fixtureProvider .. '.SetJobDuty.' .. index,
            player.Functions.SetJobDuty, value)
        end
      else
        call('esx.setJob.atomic-duty', player.setJob, 'police', 1, true)
      end

      local invalidCallbacks = {
        { name = '', handler = function() end },
        { name = string.rep('c', 97), handler = function() end },
        { name = '../callback', handler = function() end },
        { name = 'valid.callback', handler = false },
        { name = 'valid.callback', handler = {} },
        { name = 'valid.callback', handler = {
          __cfx_functionReference = 'marker-only',
        } },
      }
      if fixtureProvider == 'qb' then
        for index, fixture in ipairs(invalidCallbacks) do
          call('qb.CreateCallback.' .. index,
            coreObject.Functions.CreateCallback, fixture.name, fixture.handler)
        end
      elseif fixtureProvider == 'esx' then
        for index, fixture in ipairs(invalidCallbacks) do
          call('esx.RegisterServerCallback.' .. index,
            registered.RegisterServerCallback, fixture.name, fixture.handler)
          call('esx.shared.RegisterServerCallback.' .. index,
            shared.RegisterServerCallback, fixture.name, fixture.handler)
        end
      end

      if fixtureProvider == 'qb' then
        local tooMany = {}
        for index = 1, 9 do tooMany[index] = 'Field' .. index end
        local filters = {
          false, 'Functions', tooMany,
          { [2] = 'Functions' }, { 'Functions', 'Functions' },
          { string.rep('f', 33) }, { [1] = 'Functions', extra = true },
        }
        for index, fixture in ipairs(filters) do
          call('qb.GetCoreObject.filter.' .. index,
            registered.GetCoreObject, fixture)
        end
      end

      local malformedRequests = {
        { value = nil }, { value = false }, { value = 'request' },
        { value = {} }, { value = cyclic },
        { value = { operation = 'UPPER!' } },
        { value = { operation = string.rep('o', 129) } },
      }
      for index, fixture in ipairs(malformedRequests) do
        call(fixtureProvider .. '.InvokeCompatibilityAdapter.' .. index,
          registered.InvokeCompatibilityAdapter, fixture.value)
        call(fixtureProvider .. '.ResolveCompatibilityCatalog.' .. index,
          registered.ResolveCompatibilityCatalog, fixture.value)
        call(fixtureProvider .. '.InvokeCompatibilityCatalog.' .. index,
          registered.InvokeCompatibilityCatalog, fixture.value)
      end

      invoking = 'attacker_resource'
      local denied, deniedError
      if fixtureProvider == 'qb' then
        denied, deniedError = registered.GetCoreObjectForConsumer('victim_consumer')
        assert(denied == nil and deniedError.code == 'COMPAT_CONSUMER_DENIED')
        denied, deniedError = registered.GetPlayerForConsumer('victim_consumer', 10)
      elseif fixtureProvider == 'qbx' then
        denied, deniedError = registered.AddMoneyForConsumer(
          'victim_consumer', 10, 'cash', 1, 'fuzz')
        assert(denied == nil and deniedError.code == 'COMPAT_CONSUMER_DENIED')
        denied, deniedError = registered.GetPlayerForConsumer('victim_consumer', 10)
      else
        denied, deniedError = registered.RegisterServerCallbackForConsumer(
          'victim_consumer', 'valid.callback', function() end)
        assert(denied == nil and deniedError.code == 'COMPAT_CONSUMER_DENIED')
        denied, deniedError = registered.GetPlayerFromIdForConsumer(
          'victim_consumer', 10)
      end
      assert(denied == nil and deniedError.code == 'COMPAT_CONSUMER_DENIED')
      invoking = 'hostile_consumer'

      local usage = assert(registered.GetCompatibilityUsage())
      assert(type(usage.entries) == 'table' and #usage.entries <= 512)
      assert(type(usage.health) == 'table'
        and usage.health.usageCapacity == 512
        and usage.health.usageEntries == #usage.entries
        and usage.truncated == false)
      assert(domainMutations == 0, 'hostile input reached a domain mutation')
      assert(metadataWrites == 0, 'hostile input reached a metadata mutation')
      assert(coordinatorAdapterCalls == 0,
        'invalid adapter requests reached coordinator invocation')
      assert(coordinatorCatalogCalls == #malformedRequests * 2,
        'catalog requests must delegate exactly once to central validation')
      assert(capabilityChecks > 0 and metricWrites > 0)
      return table.concat({ fixtureProvider, domainMutations, metadataWrites,
        #usage.entries }, ':')
    `);
    assert.match(String(result), new RegExp(`^${provider}:0:0:[0-9]+$`, "u"));
  } finally {
    engine.global.close();
  }
}

for (const provider of ["qb", "qbx", "esx"] as const) {
  test(`${provider.toUpperCase()} public legacy surfaces contain hostile input without domain mutation`, async () => {
    await fuzzProvider(provider);
  });
}
