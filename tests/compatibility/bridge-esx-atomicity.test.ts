import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import test from "node:test";
import { LuaFactory } from "wasmoon";

const root = process.cwd();

test("ESX rejects combined job and duty mutation before every native write", async () => {
  const engine = await new LuaFactory().createEngine();
  const source = await readFile(
    join(root, "resources", "synex_bridge_esx", "server.lua"),
    "utf8",
  );
  try {
    await engine.doString(String.raw`
      registered = {}
      calls = {
        playerRead = 0, moneyRead = 0, groupsRead = 0,
        permissionRead = 0,
        groupWrite = 0, dutyWrite = 0, moneyWrite = 0,
        unsupported = {},
      }
      snapshot = {
        source = 42,
        identity = { identifier = 'legacy-42' },
        character = { id = 'character-42', firstName = 'Ada', lastName = 'Lovelace' },
        money = { cash = 125, bank = 900 },
        accountDefinitions = {
          cash = { alias = 'cash', name = 'money', label = 'Cash',
            round = true, minorUnit = 0 },
          bank = { alias = 'bank', name = 'bank', label = 'Bank',
            round = true, minorUnit = 0 },
        },
        fence = {
          sessionId = 'session-42', sourceGeneration = 7, characterId = 'character-42',
        },
        metadata = {}, metadataVersions = {},
        groups = { items = { {
          is_primary = true,
          group = { key = 'police', type = 'job', name = 'Police' },
          grade = { key = 'sergeant', name = 'Sergeant', rank = 3 },
          roles = {}, duty = { counts_as_on_duty = true },
        } }, truncated = false },
      }

      local adapter = {}
      function adapter:authorize() return { traceId = 'fixture' }, nil end
      function adapter:trace(_, _, _, handler) return handler() end
      function adapter:readPlayer(_, playerSource)
        assert(playerSource == 42)
        calls.playerRead = calls.playerRead + 1
        return snapshot, nil
      end
      function adapter:readPlayerFenced(_, playerSource, fence)
        assert(playerSource == 42 and fence.sourceGeneration == 7)
        calls.playerRead = calls.playerRead + 1
        return snapshot, nil
      end
      function adapter:readMoneyFenced(_, playerSource, fence)
        assert(playerSource == 42 and fence.sourceGeneration == 7)
        calls.moneyRead = calls.moneyRead + 1
        return {
          money = snapshot.money,
          accountDefinitions = snapshot.accountDefinitions,
        }, nil
      end
      function adapter:readCustomAccountsFenced(_, playerSource, fence)
        assert(playerSource == 42 and fence.sourceGeneration == 7)
        calls.moneyRead = calls.moneyRead + 1
        return {
          money = snapshot.money,
          accountDefinitions = snapshot.accountDefinitions,
        }, nil
      end
      function adapter:readGroupsFenced(_, playerSource, fence)
        assert(playerSource == 42 and fence.sourceGeneration == 7)
        calls.groupsRead = calls.groupsRead + 1
        return { groups = snapshot.groups }, nil
      end
      function adapter:readPermissionGroups(_, playerSource, fence)
        assert(playerSource == 42 and fence.sourceGeneration == 7)
        calls.permissionRead = calls.permissionRead + 1
        return { groups = { 'admin' }, primary = 'admin', fallback = 'user' }, nil
      end
      function adapter:unsupported(_, operation, message)
        calls.unsupported[#calls.unsupported + 1] = operation
        return nil, { code = 'COMPAT_API_UNSUPPORTED', message = message, retryable = false }
      end
      function adapter:setGroup()
        calls.groupWrite = calls.groupWrite + 1
        return true, nil
      end
      function adapter:setDuty()
        calls.dutyWrite = calls.dutyWrite + 1
        return true, nil
      end
      function adapter:changeMoney()
        calls.moneyWrite = calls.moneyWrite + 1
        return true, nil
      end
      function adapter:setMoney()
        calls.moneyWrite = calls.moneyWrite + 1
        return true, nil
      end
      function adapter:setMetadata() return true, nil end
      function adapter:registerCallback() return true, nil end
      function adapter:invokeCompatibilityAdapter() return true, nil end
      function adapter:usageSnapshot() return { framework = 'esx', entries = {} } end
      function adapter:registerLifecycle(mapper)
        assert(type(mapper(snapshot)) == 'table')
        return 'lifecycle-token', nil
      end

      SynexBridgeNative = { create = function() return adapter end }
      exports = setmetatable({ synex_bridge = {} }, {
        __call = function(_, name, handler) registered[name] = handler end,
      })
      GetInvokingResource = function() return 'legacy_consumer' end
      AddEventHandler = function() end
    `);
    await engine.doString(source);
    const result = await engine.doString(String.raw`
      local player = assert(registered.GetPlayerFromId(42))
      assert(calls.playerRead == 1)

      local changed, combinedError = player.setJob('police', 4, true)
      assert(changed == false and combinedError.code == 'COMPAT_API_UNSUPPORTED')
      assert(calls.groupWrite == 0 and calls.dutyWrite == 0 and calls.groupsRead == 0)
      assert(calls.unsupported[1] == 'job.set_with_duty')

      assert(player.setJob('police', 4) == true)
      assert(calls.groupWrite == 1 and calls.dutyWrite == 0 and calls.groupsRead == 0)

      assert(player.getMoney() == 125)
      assert(player.getAccount('bank').money == 900)
      assert(#player.getAccounts() == 2)
      assert(calls.moneyRead == 3 and calls.playerRead == 1)

      assert(player.getJob().name == 'police')
      assert(calls.groupsRead == 1 and calls.playerRead == 1)

      local custom, customReadError = player.getAccount('crypto')
      assert(custom == nil and customReadError.code == 'COMPAT_API_UNSUPPORTED')
      local customChanged, customWriteError = player.addAccountMoney('crypto', 5)
      assert(customChanged == false and customWriteError.code == 'COMPAT_API_UNSUPPORTED')
      local permissionGroup, permissionError = player.getGroup()
      assert(permissionGroup == 'admin' and permissionError == nil)
      assert(calls.permissionRead == 1)
      assert(calls.moneyWrite == 0)
      assert(calls.unsupported[2] == 'accounts.custom')
      assert(calls.unsupported[3] == 'accounts.custom')
      return 'ok'
    `);
    assert.equal(result, "ok");
  } finally {
    engine.global.close();
  }
});
