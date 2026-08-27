import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';

const root = process.cwd();

test('QBX identifier, offline, group-filter, and primary-group exports stay bounded and authoritative', async () => {
  const engine = await new LuaFactory().createEngine();
  const source = await readFile(
    path.join(root, 'resources', 'synex_bridge_qbx', 'server.lua'),
    'utf8',
  );
  try {
    await engine.doString(String.raw`
      invoking, registered, last = 'legacy_consumer', {}, {}
      snapshot = {
        source = 42,
        identity = { identifier = 'citizen-42' },
        character = {
          id = 'character-42', slot = 1, firstName = 'Ada', lastName = 'Lovelace',
        },
        money = { cash = 25, bank = 400 },
        metadata = { hunger = 20 }, metadataVersions = { hunger = 1 },
        fence = { sessionId = 'session-42', sourceGeneration = 2, characterId = 'character-42' },
        groups = { items = {
          {
            is_primary = true,
            group = { key = 'police', type = 'job', label = 'Police' },
            grade = { key = 'sergeant', name = 'Sergeant', rank = 3 },
            roles = {}, duty = { counts_as_on_duty = true },
          },
          {
            is_primary = false,
            group = { key = 'ballas', type = 'gang', label = 'Ballas' },
            grade = { key = 'member', name = 'Member', rank = 2 },
            roles = {},
          },
        }, truncated = false },
      }
      offlineSnapshot = {
        offline = true,
        identity = { identifier = 'citizen-offline' },
        character = {
          id = 'character-offline', slot = 2, firstName = 'Grace', lastName = 'Hopper',
        },
        money = { cash = 10, bank = 800 },
        metadata = { hunger = 30 }, metadataVersions = { hunger = 4 },
        groups = { items = {}, truncated = false },
      }

      local adapter = {}
      function adapter:readPlayer(consumer, source) return snapshot, nil end
      function adapter:readGroups(consumer, source)
        last.groupsConsumer, last.groupsSource = consumer, source
        if source == 'citizen-offline' then return false, nil end
        return snapshot, nil
      end
      function adapter:readMoney(consumer, source)
        last.moneyConsumer, last.moneySource = consumer, source
        if source == 'citizen-offline' then return false, nil end
        return snapshot, nil
      end
      function adapter:readMetadata(consumer, source)
        last.metadataConsumer, last.metadataSource = consumer, source
        if source == 'citizen-offline' then return false, nil end
        return snapshot, nil
      end
      function adapter:readPlayerByIdentifier(consumer, identifier)
        last.identifierConsumer, last.identifier = consumer, identifier
        if identifier == 'citizen-42' then return snapshot, nil end
        return false, nil
      end
      function adapter:readOfflinePlayerByIdentifier(consumer, identifier)
        last.offlineConsumer, last.offlineIdentifier = consumer, identifier
        if identifier == 'citizen-offline' then return offlineSnapshot, nil end
        return false, nil
      end
      function adapter:setGroup(consumer, source, kind, name, grade, reason, fence)
        if source == 'citizen-offline' then
          return nil, { code = 'COMPAT_OFFLINE_MUTATION_UNSUPPORTED' }
        end
        last.setGroup = { consumer, source, kind, name, grade, reason, fence }
        return true, nil
      end
      function adapter:changeMoney(consumer, source, moneyType, direction, amount, reason, fence)
        if source == 'citizen-offline' then
          return nil, { code = 'COMPAT_OFFLINE_MUTATION_UNSUPPORTED' }
        end
        last.changeMoney = { consumer, source, moneyType, direction, amount, reason, fence }
        return true, nil
      end
      function adapter:setMoney(consumer, source, moneyType, amount, reason, fence)
        if source == 'citizen-offline' then
          return nil, { code = 'COMPAT_OFFLINE_MUTATION_UNSUPPORTED' }
        end
        last.setMoney = { consumer, source, moneyType, amount, reason, fence }
        return true, nil
      end
      function adapter:setMetadata(consumer, source, key, value, fence, version)
        if source == 'citizen-offline' then
          return nil, { code = 'COMPAT_OFFLINE_MUTATION_UNSUPPORTED' }
        end
        last.setMetadata = { consumer, source, key, value, fence, version }
        return { version = (version or 0) + 1 }, nil
      end
      function adapter:setDuty(consumer, source, onDuty, reason, fence)
        if source == 'citizen-offline' then
          return nil, { code = 'COMPAT_OFFLINE_MUTATION_UNSUPPORTED' }
        end
        last.setDuty = { consumer, source, onDuty, reason, fence }
        return true, nil
      end
      function adapter:setPrimaryGroup(consumer, source, kind, name)
        if source == 'citizen-offline' then
          return nil, { code = 'COMPAT_OFFLINE_MUTATION_UNSUPPORTED' }
        end
        if name == 'ambulance' then
          return nil, { code = 'COMPAT_GROUP_MEMBERSHIP_REQUIRED' }
        end
        last.setPrimaryGroup = { consumer, source, kind, name }
        return true, nil
      end
      function adapter:registerLifecycle(mapper, handlers)
        last.lifecycle = { mapper = mapper, handlers = handlers }
        return 'lifecycle-token', nil
      end
      SynexBridgeNative = { create = function() return adapter end }
      exports = setmetatable({ synex_bridge = {} }, {
        __call = function(_, name, handler) registered[name] = handler end,
      })
      GetInvokingResource = function() return invoking end
    `);
    await engine.doString(source);
    const result = await engine.doString(String.raw`
      local online = assert(registered.GetPlayerByCitizenId('citizen-42'),
        'safe-online-identifier')
      assert(online.Offline == false and online.PlayerData.source == 42,
        'safe-online-player')
      assert(last.identifierConsumer == 'legacy_consumer')
      local byIdentifier = assert(registered.GetPlayer('citizen-42'),
        'safe-get-player-reference')
      assert(byIdentifier.PlayerData.citizenid == 'citizen-42')

      assert(registered.GetMoney('citizen-42', 'bank') == 400, 'safe-money-read')
      assert(registered.AddMoney('citizen-42', 'cash', 5, 'fixture') == true,
        'safe-money-add')
      assert(last.changeMoney[1] == 'legacy_consumer'
        and last.changeMoney[2] == 'citizen-42')
      assert(last.changeMoney[4] == 'add' and last.changeMoney[5] == 5)
      assert(last.changeMoney[7] == nil)
      assert(registered.SetMoney(42, 'bank', 450, 'fixture') == true)
      assert(last.setMoney[2] == 42 and last.setMoney[4] == 450)
      assert(registered.GetMetadata('citizen-42', 'hunger') == 20)
      assert(registered.SetMetadata('citizen-42', 'hunger', 21) == true)
      assert(last.setMetadata[2] == 'citizen-42'
        and last.setMetadata[3] == 'hunger')
      assert(last.setMetadata[5] == nil and last.setMetadata[6] == nil)

      assert(registered.SetJob('citizen-42', 'police', 3) == true)
      assert(last.setGroup[2] == 'citizen-42' and last.setGroup[3] == 'job')
      assert(last.setGroup[4] == 'police' and last.setGroup[5] == 3)
      assert(registered.SetGang(42, 'ballas', 2) == true)
      assert(last.setGroup[3] == 'gang' and last.setGroup[4] == 'ballas')
      assert(registered.SetJobDuty('citizen-42', false) == true)
      assert(last.setDuty[2] == 'citizen-42' and last.setDuty[3] == false)

      local offlineMoney, offlineMoneyError = registered.AddMoney(
        'citizen-offline', 'cash', 5, 'fixture')
      assert(offlineMoney == false)
      assert(offlineMoneyError.code == 'COMPAT_OFFLINE_MUTATION_UNSUPPORTED')
      local offlineGroup, offlineGroupError = registered.SetJob(
        'citizen-offline', 'police', 3)
      assert(offlineGroup == false)
      assert(offlineGroupError.code == 'COMPAT_OFFLINE_MUTATION_UNSUPPORTED')

      local offline = assert(registered.GetOfflinePlayer('citizen-offline'))
      assert(offline.Offline == true and offline.PlayerData.source == nil)
      assert(offline.Functions.GetMoney('bank') == 800)
      assert(offline.Functions.GetMetaData('hunger') == 30)
      for _, name in ipairs({
        'AddMoney', 'RemoveMoney', 'SetMoney', 'SetMetaData',
        'SetJob', 'SetGang', 'SetJobDuty',
      }) do
        local changed, mutationError = offline.Functions[name]()
        assert(changed == false)
        assert(mutationError.code == 'COMPAT_OFFLINE_MUTATION_UNSUPPORTED')
      end

      assert(registered.HasGroup(42, 'police') == true)
      assert(registered.HasGroup(42, { 'missing', 'ballas' }) == true)
      assert(registered.HasGroup(42, { police = 3 }) == true)
      assert(registered.HasGroup(42, { police = 4 }) == false)
      assert(registered.HasGroup(42, 'citizen-42') == true)
      assert(registered.HasPrimaryGroup(42, 'police') == true)
      assert(registered.HasPrimaryGroup(42, 'ballas') == false)
      local sparse, sparseError = registered.HasGroup(42, { [2] = 'police' })
      assert(sparse == false and sparseError.code == 'COMPAT_DTO_INVALID')
      local forged, forgedError = registered.HasGroup(
        42, setmetatable({ 'police' }, { __index = {} }))
      assert(forged == false and forgedError.code == 'COMPAT_DTO_INVALID')

      assert(registered.SetPlayerPrimaryJob('citizen-42', 'police') == true)
      assert(last.setPrimaryGroup[1] == 'legacy_consumer'
        and last.setPrimaryGroup[2] == 'citizen-42')
      assert(last.setPrimaryGroup[3] == 'job'
        and last.setPrimaryGroup[4] == 'police')
      assert(registered.SetPlayerPrimaryGang('citizen-42', 'ballas') == true)
      assert(last.setPrimaryGroup[3] == 'gang'
        and last.setPrimaryGroup[4] == 'ballas')
      local missing, missingError = registered.SetPlayerPrimaryJob('citizen-42', 'ambulance')
      assert(missing == false and missingError.code == 'COMPAT_GROUP_MEMBERSHIP_REQUIRED')
      local unavailable, unavailableError = registered.SetPlayerPrimaryJob(
        'citizen-offline', 'police')
      assert(unavailable == false)
      assert(unavailableError.code == 'COMPAT_OFFLINE_MUTATION_UNSUPPORTED')
      return 'ok'
    `);
    assert.equal(result, 'ok');
  } finally {
    engine.global.close();
  }
});

test('historical qbx_core facade forwards only authenticated consumer-aware exports', async () => {
  const facade = await readFile(
    path.join(root, 'compat', 'facades', 'qbx_core', 'server.lua'),
    'utf8',
  );
  for (const name of [
    'GetPlayerByCitizenId',
    'GetOfflinePlayer',
    'HasGroup',
    'HasPrimaryGroup',
    'SetPlayerPrimaryJob',
    'SetPlayerPrimaryGang',
    'SetJob',
    'SetGang',
    'SetJobDuty',
  ]) {
    assert.match(facade, new RegExp(`exports\\('${name}'`, 'u'));
    assert.match(facade, new RegExp(`${name}ForConsumer`, 'u'));
  }
  assert.doesNotMatch(facade, /AddPlayerToGroup|RemovePlayerFromGroup/u);
});
