import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { LuaFactory } from "wasmoon";

const root = process.cwd();

test("ESX identifier lookup and bounded enumeration preserve native read semantics", async () => {
  const engine = await new LuaFactory().createEngine();
  const source = await readFile(
    path.join(root, "resources", "synex_bridge_esx", "server.lua"),
    "utf8",
  );
  try {
    await engine.doString(String.raw`
      invoking, registered = 'legacy_consumer', {}
      calls = {
        identifiers = {}, reads = {}, listings = 0,
        customReads = 0, mutations = {},
      }

      local function group(name, rank, primary)
        return {
          is_primary = primary == true,
          group = { key = name, type = 'job', label = name },
          grade = { key = 'grade_' .. rank, name = 'Grade ' .. rank, rank = rank },
          roles = {}, duty = { counts_as_on_duty = false },
        }
      end

      local function snapshot(playerSource, identifier, job, rank)
        return {
          source = playerSource,
          identity = { identifier = identifier },
          character = {
            id = 'character-' .. playerSource, slot = playerSource,
            firstName = 'Player', lastName = tostring(playerSource),
          },
          money = {
            cash = playerSource, bank = playerSource * 10,
            illicit = playerSource + 5,
          },
          accountDefinitions = {
            cash = {
              alias = 'cash', name = 'money', label = 'Cash',
              round = true, minorUnit = 0,
            },
            bank = {
              alias = 'bank', name = 'bank', label = 'Bank',
              round = true, minorUnit = 0,
            },
            illicit = {
              alias = 'illicit', name = 'black_money', legacyName = 'black_money',
              label = 'Dirty Money',
              round = false, minorUnit = 0,
            },
          },
          fence = {
            sessionId = 'session-' .. playerSource, sourceGeneration = 2,
            characterId = 'character-' .. playerSource,
          },
          metadata = {}, metadataVersions = {},
          groups = { items = { group(job, rank, true) }, truncated = false },
        }
      end

      snapshots = {
        [10] = snapshot(10, 'license:alpha', 'police', 2),
        [20] = snapshot(20, 'license:beta', 'police', 4),
        [30] = snapshot(30, 'license:gamma', 'ambulance', 3),
      }

      local adapter = {}
      function adapter:authorize()
        return { traceId = 'trace-esx-safe-remainders' }, nil
      end
      function adapter:trace(_, _, _, handler) return handler() end
      function adapter:readPlayer(consumer, playerSource)
        calls.reads[#calls.reads + 1] = { consumer, playerSource }
        return snapshots[playerSource], nil
      end
      function adapter:readPlayerFenced(consumer, playerSource, fence)
        assert(fence.sessionId == 'session-' .. playerSource)
        return snapshots[playerSource], nil
      end
      function adapter:readMoneyFenced(consumer, playerSource, fence)
        assert(fence.sourceGeneration == 2)
        return snapshots[playerSource], nil
      end
      function adapter:readCustomAccountsFenced(consumer, playerSource, fence)
        assert(consumer == 'legacy_consumer' or consumer == 'actual_consumer')
        assert(fence.sourceGeneration == 2)
        calls.customReads = calls.customReads + 1
        return snapshots[playerSource], nil
      end
      function adapter:readGroupsFenced(consumer, playerSource, fence)
        return snapshots[playerSource], nil
      end
      function adapter:readPlayerByIdentifier(consumer, identifier)
        calls.identifiers[#calls.identifiers + 1] = { consumer, identifier }
        for _, item in pairs(snapshots) do
          if item.identity.identifier == identifier then return item, nil end
        end
        return false, nil
      end
      function adapter:listPlayerSources(consumer)
        calls.listings = calls.listings + 1
        calls.listConsumer = consumer
        return { 10, 20, 30 }, nil
      end
      function adapter:changeMoney(consumer, playerSource, alias, direction,
        amount, reason, fence)
        calls.mutations[#calls.mutations + 1] = {
          consumer, playerSource, alias, direction, amount, reason, fence,
        }
        return true, nil
      end
      function adapter:setMoney(consumer, playerSource, alias, amount, reason, fence)
        calls.mutations[#calls.mutations + 1] = {
          consumer, playerSource, alias, 'set', amount, reason, fence,
        }
        return true, nil
      end
      function adapter:registerLifecycle() return 'esx-lifecycle', nil end
      function adapter:registerCallback() return true, nil end
      function adapter:unsupported(_, operation, message)
        return nil, { code = 'COMPAT_API_UNSUPPORTED', operation = operation,
          message = message, retryable = false }
      end
      function adapter:usageSnapshot() return { framework = 'esx' } end

      SynexBridgeNative = { create = function() return adapter end }
      exports = setmetatable({ synex_bridge = {} }, {
        __call = function(_, name, handler) registered[name] = handler end,
      })
      GetInvokingResource = function() return invoking end
      AddEventHandler = function() end
      TriggerEvent = function() end
      TriggerClientEvent = function() end
    `);
    await engine.doString(source);
    const result = await engine.doString(String.raw`
      local alpha = assert(registered.GetPlayerFromIdentifier('license:alpha'))
      assert(alpha.source == 10 and alpha.getIdentifier() == 'license:alpha')
      assert(calls.identifiers[1][1] == 'legacy_consumer')

      assert(registered.GetPlayerIdFromIdentifier('license:beta') == 20)
      local missing, missingError = registered.GetPlayerFromIdentifier('license:missing')
      assert(missing == nil and missingError == nil)

      local players = assert(registered.GetPlayers())
      assert(#players == 3 and players[1] == 10 and players[3] == 30)
      assert(calls.listConsumer == 'legacy_consumer')
      players[1] = 999
      assert(registered.GetPlayers()[1] == 10)

      local shared = assert(registered.getSharedObject())
      assert(shared.GetPlayerFromIdentifier('license:gamma').source == 30)
      assert(shared.GetPlayerIdFromIdentifier('license:alpha') == 10)
      assert(shared.GetPlayers()[2] == 20)

      local all = assert(registered.GetExtendedPlayers())
      assert(#all == 3 and all[1].source == 10 and all[3].source == 30)
      local allMinimal = assert(registered.GetExtendedPlayers(nil, nil, true))
      assert(#allMinimal == 3 and allMinimal[2] == 20)

      local identifier = assert(registered.GetExtendedPlayers(
        'identifier', 'license:beta'))
      assert(#identifier == 1 and identifier[1].source == 20)
      local identifiers = assert(registered.GetExtendedPlayers(
        'identifier', { 'license:gamma', 'license:alpha', 'license:missing' }, true))
      assert(#identifiers['license:gamma'] == 1
        and identifiers['license:gamma'][1] == 30)
      assert(#identifiers['license:alpha'] == 1
        and identifiers['license:alpha'][1] == 10)
      assert(#identifiers['license:missing'] == 0)

      local police = assert(registered.GetExtendedPlayers('job', 'police'))
      assert(#police == 2 and police[1].source == 10 and police[2].source == 20)
      local jobs = assert(registered.GetExtendedPlayers(
        'job', { 'ambulance', 'police', 'mechanic' }, true))
      assert(#jobs.ambulance == 1 and jobs.ambulance[1] == 30)
      assert(#jobs.police == 2 and jobs.police[1] == 10 and jobs.police[2] == 20)
      assert(#jobs.mechanic == 0)

      local custom = assert(alpha.getAccount('black_money'))
      assert(custom.name == 'black_money' and custom.label == 'Dirty Money')
      assert(custom.money == 15 and custom.round == false)
      custom.money = -1
      assert(alpha.getAccount('black_money').money == 15)
      local projected = assert(alpha.getAccounts())
      assert(#projected == 3 and projected[1].name == 'bank')
      assert(projected[2].name == 'black_money' and projected[3].name == 'money')
      local minimalAccounts = assert(alpha.getAccounts(true))
      assert(minimalAccounts.money == 10 and minimalAccounts.bank == 100
        and minimalAccounts.black_money == 15)
      assert(calls.customReads == 4)

      assert(alpha.addAccountMoney('black_money', 7, 'fixture') == true)
      assert(alpha.removeAccountMoney('black_money', 2, 'fixture') == true)
      assert(alpha.setAccountMoney('black_money', 20, 'fixture') == true)
      assert(#calls.mutations == 3)
      assert(calls.mutations[1][3] == 'illicit'
        and calls.mutations[1][4] == 'add')
      assert(calls.mutations[2][3] == 'illicit'
        and calls.mutations[2][4] == 'remove')
      assert(calls.mutations[3][3] == 'illicit'
        and calls.mutations[3][4] == 'set')

      snapshots[10].money.shadow = 99
      snapshots[10].accountDefinitions.shadow = {
        alias = 'shadow', name = 'black_money', legacyName = 'black_money',
        label = 'Ambiguous', round = false, minorUnit = 0,
      }
      local ambiguous, ambiguousError = alpha.getAccount('black_money')
      assert(ambiguous == nil and ambiguousError.code == 'COMPAT_MAPPING_AMBIGUOUS')
      local ambiguousMutation, ambiguousMutationError = alpha.addAccountMoney(
        'black_money', 1, 'fixture')
      assert(ambiguousMutation == false
        and ambiguousMutationError.code == 'COMPAT_MAPPING_AMBIGUOUS')
      assert(#calls.mutations == 3)
      snapshots[10].money.shadow = nil
      snapshots[10].accountDefinitions.shadow = nil

      local accepted = {}
      for index = 1, 32 do accepted[index] = 'job_' .. index end
      local bounded = assert(registered.GetExtendedPlayers('job', accepted, true))
      assert(#bounded.job_1 == 0 and #bounded.job_32 == 0)

      local oversized = {}
      for index = 1, 33 do oversized[index] = 'job_' .. index end
      local beforeInvalid = calls.listings
      local invalid, invalidError = registered.GetExtendedPlayers('job', oversized)
      assert(invalid == nil and invalidError.code == 'COMPAT_ARGUMENT_INVALID')
      assert(calls.listings == beforeInvalid)

      local sparse, sparseError = registered.GetExtendedPlayers(
        'job', { [2] = 'police' })
      assert(sparse == nil and sparseError.code == 'COMPAT_ARGUMENT_INVALID')
      local duplicate, duplicateError = registered.GetExtendedPlayers(
        'job', { 'police', 'police' })
      assert(duplicate == nil and duplicateError.code == 'COMPAT_ARGUMENT_INVALID')
      local forged, forgedError = registered.GetExtendedPlayers(
        'job', setmetatable({ 'police' }, { __index = {} }))
      assert(forged == nil and forgedError.code == 'COMPAT_ARGUMENT_INVALID')
      local unsupported, unsupportedError = registered.GetExtendedPlayers(
        'metadata', 'hunger')
      assert(unsupported == nil and unsupportedError.code == 'COMPAT_API_UNSUPPORTED')
      local valueOnly, valueOnlyError = registered.GetExtendedPlayers(nil, 'police')
      assert(valueOnly == nil and valueOnlyError.code == 'COMPAT_ARGUMENT_INVALID')
      local badMinimal, badMinimalError = registered.GetExtendedPlayers(
        'job', 'police', 'yes')
      assert(badMinimal == nil and badMinimalError.code == 'COMPAT_ARGUMENT_INVALID')
      local longJob, longJobError = registered.GetExtendedPlayers(
        'job', string.rep('a', 65))
      assert(longJob == nil and longJobError.code == 'COMPAT_ARGUMENT_INVALID')
      local longIdentifier, longIdentifierError = registered.GetExtendedPlayers(
        'identifier', string.rep('a', 192))
      assert(longIdentifier == nil
        and longIdentifierError.code == 'COMPAT_ARGUMENT_INVALID')

      invoking = 'es_extended'
      assert(registered.GetPlayerFromIdentifierForConsumer(
        'actual_consumer', 'license:alpha').source == 10)
      assert(calls.identifiers[#calls.identifiers][1] == 'actual_consumer')
      assert(registered.GetPlayersForConsumer('actual_consumer')[3] == 30)
      assert(calls.listConsumer == 'actual_consumer')
      local forwarded = assert(registered.GetExtendedPlayersForConsumer(
        'actual_consumer', 'job', 'ambulance', true))
      assert(#forwarded == 1 and forwarded[1] == 30)

      invoking = 'attacker'
      local denied, deniedError = registered.GetPlayerFromIdentifierForConsumer(
        'victim', 'license:alpha')
      assert(denied == nil and deniedError.code == 'COMPAT_CONSUMER_DENIED')
      return 'ok'
    `);
    assert.equal(result, "ok");
  } finally {
    engine.global.close();
  }
});

test("historical es_extended facade forwards safe lookup and enumeration exports", async () => {
  const facade = await readFile(
    path.join(root, "compat", "facades", "es_extended", "server.lua"),
    "utf8",
  );
  for (const name of [
    "GetPlayerFromIdentifier",
    "GetPlayerIdFromIdentifier",
    "GetPlayers",
    "GetExtendedPlayers",
  ]) {
    assert.match(facade, new RegExp(`exports\\('${name}'`, "u"));
    assert.match(facade, new RegExp(`${name}ForConsumer`, "u"));
  }
});
