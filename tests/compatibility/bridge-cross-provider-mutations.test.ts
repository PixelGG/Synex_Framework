import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import test from "node:test";
import { LuaFactory } from "wasmoon";

const root = process.cwd();

test("QB, Qbox, and ESX mutations converge on one fenced authoritative state", async () => {
  const providers = ["qb", "qbx", "esx"] as const;
  const sources = await Promise.all(providers.map((provider) => readFile(
    join(root, "resources", `synex_bridge_${provider}`, "server.lua"),
    "utf8",
  )));
  const engine = await new LuaFactory().createEngine();
  try {
    await engine.doString(String.raw`
      providerExports = { qb = {}, qbx = {}, esx = {} }
      invoking, loadingProvider = 'legacy_consumer', nil
      authority = {
        source = 42,
        generation = 7,
        money = { cash = 100, bank = 900 },
        job = {
          key = 'police', label = 'Police Department',
          grade = 3, gradeKey = 'sergeant', gradeLabel = 'Sergeant',
          onDuty = true,
        },
      }
      calls = {
        providers = {}, moneyWrites = 0, groupWrites = 0, dutyWrites = 0,
      }

      local function copy(value, seen)
        if type(value) ~= 'table' then return value end
        seen = seen or {}
        if seen[value] then return nil end
        seen[value] = true
        local result = {}
        for key, item in pairs(value) do result[key] = copy(item, seen) end
        seen[value] = nil
        return result
      end

      local function bridgeError(code, message)
        return { code = code, message = message, retryable = false }
      end

      local function currentSnapshot()
        return {
          source = authority.source,
          identity = { identifier = 'legacy-character-42' },
          character = {
            id = 'character-42', slot = 1,
            firstName = 'Ada', lastName = 'Lovelace', dateOfBirth = '1815-12-10',
          },
          money = copy(authority.money),
          accountDefinitions = {
            cash = { alias = 'cash', name = 'money', label = 'Cash',
              round = true, minorUnit = 0 },
            bank = { alias = 'bank', name = 'bank', label = 'Bank',
              round = true, minorUnit = 0 },
          },
          fence = {
            sessionId = 'session-42', sourceGeneration = authority.generation,
            characterId = 'character-42',
          },
          metadata = { hunger = 40 }, metadataVersions = { hunger = 1 },
          groups = { items = { {
            membership_id = 'membership-job-42', status = 'ACTIVE', is_primary = true,
            roles = {}, roles_truncated = false,
            group = {
              group_id = 'group-job-42', key = authority.job.key, type = 'job',
              name = authority.job.label, label = authority.job.label,
            },
            grade = {
              key = authority.job.gradeKey, name = authority.job.gradeLabel,
              rank = authority.job.grade,
            },
            duty = { counts_as_on_duty = authority.job.onDuty },
          } }, truncated = false },
        }
      end

      local function validateSource(playerSource)
        if playerSource ~= authority.source then
          return nil, bridgeError('COMPAT_PLAYER_UNAVAILABLE', 'Player unavailable.')
        end
        return true, nil
      end

      local function validateFence(playerSource, fence)
        local validSource, sourceError = validateSource(playerSource)
        if not validSource then return nil, sourceError end
        if type(fence) ~= 'table' or fence.sessionId ~= 'session-42'
          or fence.characterId ~= 'character-42'
          or fence.sourceGeneration ~= authority.generation then
          return nil, bridgeError('COMPAT_STALE_SESSION', 'Source generation is stale.')
        end
        return true, nil
      end

      local function adapterFor(framework)
        local adapter = {}
        function adapter:authorize()
          return { traceId = 'cross-provider-' .. framework }, nil
        end
        function adapter:trace(_, _, _, handler) return handler() end
        function adapter:readPlayer(_, playerSource)
          local valid, operationError = validateSource(playerSource)
          if not valid then return nil, operationError end
          return currentSnapshot(), nil
        end
        function adapter:readPlayerFenced(_, playerSource, fence)
          local valid, operationError = validateFence(playerSource, fence)
          if not valid then return nil, operationError end
          return currentSnapshot(), nil
        end
        function adapter:readMoney(_, playerSource)
          local valid, operationError = validateSource(playerSource)
          if not valid then return nil, operationError end
          return currentSnapshot(), nil
        end
        function adapter:readMoneyFenced(_, playerSource, fence)
          local valid, operationError = validateFence(playerSource, fence)
          if not valid then return nil, operationError end
          return currentSnapshot(), nil
        end
        function adapter:readCustomAccountsFenced(_, playerSource, fence)
          local valid, operationError = validateFence(playerSource, fence)
          if not valid then return nil, operationError end
          return currentSnapshot(), nil
        end
        function adapter:readGroups(_, playerSource)
          local valid, operationError = validateSource(playerSource)
          if not valid then return nil, operationError end
          return currentSnapshot(), nil
        end
        function adapter:readGroupsFenced(_, playerSource, fence)
          local valid, operationError = validateFence(playerSource, fence)
          if not valid then return nil, operationError end
          return currentSnapshot(), nil
        end
        function adapter:changeMoney(_, playerSource, moneyType, direction, amount, _, fence)
          local valid, operationError = validateFence(playerSource, fence)
          if not valid then return nil, operationError end
          if (moneyType ~= 'cash' and moneyType ~= 'bank') or type(amount) ~= 'number'
            or math.type(amount) ~= 'integer' or amount <= 0 then
            return nil, bridgeError('COMPAT_INVALID_ARGUMENT', 'Money mutation is invalid.')
          end
          if direction == 'add' then
            authority.money[moneyType] = authority.money[moneyType] + amount
          elseif direction == 'remove' and authority.money[moneyType] >= amount then
            authority.money[moneyType] = authority.money[moneyType] - amount
          else
            return nil, bridgeError('COMPAT_INVALID_ARGUMENT', 'Money direction is invalid.')
          end
          calls.moneyWrites = calls.moneyWrites + 1
          return true, nil
        end
        function adapter:setMoney()
          return nil, bridgeError('COMPAT_API_UNSUPPORTED', 'SetMoney is unavailable.')
        end
        function adapter:setGroup(_, playerSource, groupType, name, grade, _, fence)
          local valid, operationError = validateFence(playerSource, fence)
          if not valid then return nil, operationError end
          if groupType ~= 'job' or type(name) ~= 'string' or type(grade) ~= 'number'
            or math.type(grade) ~= 'integer' then
            return nil, bridgeError('COMPAT_INVALID_ARGUMENT', 'Group mutation is invalid.')
          end
          authority.job.key = name
          authority.job.label = name == 'ambulance' and 'Ambulance' or name
          authority.job.grade = grade
          authority.job.gradeKey = 'grade_' .. tostring(grade)
          authority.job.gradeLabel = 'Grade ' .. tostring(grade)
          calls.groupWrites = calls.groupWrites + 1
          return true, nil
        end
        function adapter:setDuty(_, playerSource, onDuty, _, fence)
          local valid, operationError = validateFence(playerSource, fence)
          if not valid then return nil, operationError end
          if type(onDuty) ~= 'boolean' then
            return nil, bridgeError('COMPAT_INVALID_ARGUMENT', 'Duty mutation is invalid.')
          end
          authority.job.onDuty = onDuty
          calls.dutyWrites = calls.dutyWrites + 1
          return true, nil
        end
        function adapter:setMetadata() return true, nil end
        function adapter:registerCallback() return true, nil end
        function adapter:invokeCompatibilityAdapter() return true, nil end
        function adapter:usageSnapshot()
          return { framework = framework, entries = {} }
        end
        function adapter:unsupported(_, _, message)
          return nil, bridgeError('COMPAT_API_UNSUPPORTED', message)
        end
        function adapter:registerLifecycle(mapper)
          assert(type(mapper(currentSnapshot())) == 'table')
          return framework .. '-lifecycle', nil
        end
        return adapter
      end

      SynexBridgeNative = {
        create = function(options)
          calls.providers[options.framework] = (calls.providers[options.framework] or 0) + 1
          return adapterFor(options.framework)
        end,
      }
      exports = setmetatable({ synex_bridge = {} }, {
        __call = function(_, name, handler)
          assert(type(loadingProvider) == 'string')
          assert(providerExports[loadingProvider][name] == nil)
          providerExports[loadingProvider][name] = handler
        end,
      })
      GetInvokingResource = function() return invoking end
      AddEventHandler = function() end
    `);

    for (let index = 0; index < providers.length; index += 1) {
      await engine.doString(`loadingProvider = '${providers[index]}'`);
      await engine.doString(sources[index]!);
    }

    const result = await engine.doString(String.raw`
      assert(calls.providers.qb == 1 and calls.providers.qbx == 1
        and calls.providers.esx == 1)
      assert(type(providerExports.qb.GetPlayer) == 'function')
      assert(type(providerExports.qbx.GetPlayer) == 'function')
      assert(type(providerExports.esx.GetPlayerFromId) == 'function')
      assert(providerExports.qb.GetPlayer ~= providerExports.qbx.GetPlayer)

      local qbPlayer = assert(providerExports.qb.GetPlayer(42))
      qbPlayer.PlayerData.money.cash = 999999
      qbPlayer.PlayerData.job.name = 'tampered'
      assert(authority.money.cash == 100 and authority.job.key == 'police')

      assert(qbPlayer.Functions.AddMoney('cash', 25, 'cross-provider') == true)
      assert(authority.money.cash == 125 and calls.moneyWrites == 1)
      assert(providerExports.qbx.GetMoney(42, 'cash') == 125)

      local esxPlayer = assert(providerExports.esx.GetPlayerFromId(42))
      assert(esxPlayer.getAccount('money').money == 125)
      assert(esxPlayer.setJob('ambulance', 2) == true)
      assert(authority.job.key == 'ambulance' and authority.job.grade == 2)
      assert(calls.groupWrites == 1)

      local qbAfterJob = assert(providerExports.qb.GetPlayer(42))
      local qbxAfterJob = assert(providerExports.qbx.GetPlayer(42))
      assert(qbAfterJob.PlayerData.job.name == 'ambulance')
      assert(qbAfterJob.PlayerData.job.grade.level == 2)
      assert(qbxAfterJob.PlayerData.job.name == 'ambulance')
      assert(qbxAfterJob.PlayerData.job.grade.level == 2)

      qbxAfterJob.PlayerData.job.name = 'detached-tamper'
      qbxAfterJob.PlayerData.money.bank = -1
      assert(authority.job.key == 'ambulance' and authority.money.bank == 900)

      assert(qbxAfterJob.Functions.SetJobDuty(false) == true)
      assert(authority.job.onDuty == false and calls.dutyWrites == 1)
      local qbAfterDuty = assert(providerExports.qb.GetPlayer(42))
      assert(qbAfterDuty.PlayerData.job.onduty == false)
      assert(esxPlayer.getJob().onDuty == false)

      authority.generation = authority.generation + 1
      local moneyBeforeStale = authority.money.cash
      local staleMoneyChanged, staleMoneyError = qbPlayer.Functions.AddMoney(
        'cash', 5, 'stale-source')
      assert(staleMoneyChanged == false and staleMoneyError.code == 'COMPAT_STALE_SESSION')
      assert(authority.money.cash == moneyBeforeStale and calls.moneyWrites == 1)

      local staleAccount, staleAccountError = esxPlayer.getAccount('bank')
      assert(staleAccount == nil and staleAccountError.code == 'COMPAT_STALE_SESSION')
      local staleDutyChanged, staleDutyError = qbxAfterJob.Functions.SetJobDuty(true)
      assert(staleDutyChanged == false and staleDutyError.code == 'COMPAT_STALE_SESSION')
      assert(authority.job.onDuty == false and calls.dutyWrites == 1)
      return 'ok'
    `);
    assert.equal(result, "ok");
  } finally {
    engine.global.close();
  }
});
