import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory, type LuaEngine } from 'wasmoon';

const root = process.cwd();

type Provider = 'qb' | 'qbx' | 'esx';

async function createProvider(provider: Provider): Promise<LuaEngine> {
  const engine = await new LuaFactory().createEngine();
  try {
    await engine.doString(String.raw`
      registered, calls, lifecycle = {}, {}, {}
      snapshot = {
        source = 42,
        identity = { identifier = 'legacy-identity-42' },
        character = {
          id = 'character_fixture_0001', slot = 2,
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
          sessionId = 'session_fixture_0001', sourceGeneration = 7,
          characterId = 'character_fixture_0001',
        },
        metadata = { hunger = 40 }, metadataVersions = { hunger = 3 },
        groups = { items = {
          {
            membership_id = 'membership_job_fixture', status = 'ACTIVE',
            is_primary = true, roles = {}, roles_truncated = false,
            group = {
              group_id = 'group_job_fixture', key = 'police', type = 'job',
              name = 'Police', label = 'Police Department',
            },
            grade = { key = 'sergeant', name = 'Sergeant', rank = 3 },
            duty = { counts_as_on_duty = true },
          },
          {
            membership_id = 'membership_gang_fixture', status = 'ACTIVE',
            is_primary = true, roles = {}, roles_truncated = false,
            group = {
              group_id = 'group_gang_fixture', key = 'ballas', type = 'gang',
              name = 'Ballas', label = 'Ballas',
            },
            grade = { key = 'member', name = 'Member', rank = 1 },
            duty = { counts_as_on_duty = false },
          },
        }, truncated = false },
      }

      local adapter = {}
      function adapter:authorize() return { traceId = 'trace-fixture' }, nil end
      function adapter:trace(_, _, _, handler) return handler() end
      function adapter:readPlayer() return snapshot, nil end
      function adapter:readPlayerFenced() return snapshot, nil end
      function adapter:readMoney() return snapshot, nil end
      function adapter:readMoneyFenced() return snapshot, nil end
      function adapter:readGroups() return snapshot, nil end
      function adapter:readGroupsFenced() return snapshot, nil end
      function adapter:readMetadata() return snapshot, nil end
      function adapter:readMetadataFenced() return snapshot, nil end
      function adapter:unsupported() return nil, { code = 'COMPAT_API_UNSUPPORTED' } end
      function adapter:changeMoney() return true, nil end
      function adapter:setMoney() return true, nil end
      function adapter:setGroup() return true, nil end
      function adapter:setDuty() return true, nil end
      function adapter:setMetadata() return true, nil end
      function adapter:registerCallback() return 'callback-token', nil end
      function adapter:invokeCompatibilityAdapter() return {}, nil end
      function adapter:usageSnapshot() return { framework = '${provider}', entries = {} } end
      function adapter:registerLifecycle(mapper, handlers)
        lifecycle.mapper, lifecycle.handlers = mapper, handlers
        return 'lifecycle-token', nil
      end
      SynexBridgeNative = {
        create = function() return adapter end,
        isCallable = function(value) return type(value) == 'function' end,
      }
      local coordinator = {}
      function coordinator:ResolveCompatibilityCatalog() return {}, nil end
      function coordinator:InvokeCompatibilityCatalog() return {}, nil end
      exports = setmetatable({ synex_bridge = coordinator }, {
        __call = function(_, name, handler) registered[name] = handler end,
      })
      GetInvokingResource = function() return 'legacy_consumer' end
      AddEventHandler = function() end
      TriggerEvent = function(name, ...)
        calls[#calls + 1] = { side = 'server', name = name, args = table.pack(...) }
      end
      TriggerClientEvent = function(name, target, ...)
        calls[#calls + 1] = {
          side = 'client', name = name, target = target, args = table.pack(...),
        }
      end

      function clearCalls() calls = {} end
      function family(qbc, qbx, esx, surfacesOverride)
        local surfaces = surfacesOverride or {
          ['qb.shared.job_update_events'] = qbc == true,
          ['qb.shared.gang_update_events'] = qbc == true,
          ['qb.shared.duty_update_events'] = qbc == true,
          ['qb.shared.money_update_events'] = qbc == true,
          ['qbx.shared.group_update_events'] = qbx == true,
          ['qbx.shared.duty_update_events'] = qbx == true,
          ['qbx.shared.money_update_events'] = qbx == true,
          ['esx.shared.job_update_events'] = esx == true,
          ['esx.shared.account_update_events'] = esx == true,
        }
        return { consumer = 'legacy_consumer', families = {
          qbc = qbc == true, qbx = qbx == true, esx = esx == true,
        }, surfaces = surfaces, clientAccess = {
          playerData = { 'legacy_consumer' },
          callbacks = '${provider}' == 'qbx' and {} or { 'legacy_consumer' },
        } }
      end
      function lifecycleContext(previous, current, publication, resync)
        return {
          source = 42, consumer = 'legacy_consumer', publication = publication,
          snapshot = snapshot, previousPlayerData = previous, playerData = current,
          resync = resync == true,
        }
      end
      function mapped() return lifecycle.mapper(snapshot) end
      function callAt(index, side, name, arity)
        local call = assert(calls[index], ('missing call %d'):format(index))
        assert(call.side == side and call.name == name,
          ('unexpected call %d: %s/%s'):format(index, call.side, call.name))
        if arity ~= nil then assert(call.args.n == arity) end
        if side == 'client' then assert(call.target == 42) end
        return call
      end
      function countCalls(name)
        local count = 0
        for _, call in ipairs(calls) do
          if call.name == name then count = count + 1 end
        end
        return count
      end
      function assertNoCallables(value, seen)
        assert(type(value) ~= 'function', 'broadcast payload contains a callable')
        if type(value) ~= 'table' then return true end
        seen = seen or {}
        if seen[value] then return true end
        seen[value] = true
        for key, item in pairs(value) do
          assertNoCallables(key, seen)
          assertNoCallables(item, seen)
        end
        return true
      end
    `);
    const source = await readFile(
      path.join(root, 'resources', `synex_bridge_${provider}`, 'server.lua'),
      'utf8',
    );
    await engine.doString(source);
    return engine;
  } catch (error) {
    engine.global.close();
    throw error;
  }
}

test('QB lifecycle matches upstream load, update, unload signatures and ordering', async () => {
  const engine = await createProvider('qb');
  try {
    const result = await engine.doString(String.raw`
      local publication = family(true, false, false)
      local initial = mapped()
      assert(lifecycle.handlers.loaded(lifecycleContext(nil, initial, publication)))
      assert(#calls == 6)
      local private = callAt(1, 'client', 'synex_bridge_qb:client:projection', 3)
      assert(private.args[1] == 'replace' and type(private.args[2]) == 'table')
      assert(private.args[3].playerData[1] == 'legacy_consumer'
        and private.args[3].callbacks[1] == 'legacy_consumer'
        and private.args[2].fence == nil)
      local loaded = callAt(2, 'server', 'QBCore:Server:PlayerLoaded', 1)
      assert(type(loaded.args[1].PlayerData) == 'table')
      assert(loaded.args[1].Functions == nil)
      assertNoCallables(loaded.args[1])
      loaded.args[1].PlayerData.money.cash = -1
      assert(initial.money.cash == 120)
      callAt(3, 'server', 'QBCore:Player:SetPlayerData', 1)
      local serverUpdated = callAt(4, 'server', 'QBCore:Server:OnPlayerUpdated', 3)
      assert(serverUpdated.args[1] == 42 and serverUpdated.args[2] == 'all')
      local clientUpdated = callAt(5, 'client', 'QBCore:Client:OnPlayerUpdated', 2)
      assert(clientUpdated.args[1] == 'all')
      callAt(6, 'client', 'QBCore:Client:OnPlayerLoaded', 0)

      local previous = mapped()
      snapshot.money.cash, snapshot.money.bank = 145, 875
      snapshot.groups.items[1].grade = {
        key = 'lieutenant', name = 'Lieutenant', rank = 4,
      }
      snapshot.groups.items[1].duty.counts_as_on_duty = false
      snapshot.groups.items[2].grade = { key = 'enforcer', name = 'Enforcer', rank = 2 }
      local current = mapped()
      clearCalls()
      assert(lifecycle.handlers.updated(lifecycleContext(previous, current, publication)))
      assert(#calls == 15)
      callAt(1, 'client', 'synex_bridge_qb:client:projection', 3)
      local expected = {
        'QBCore:Server:OnPlayerUpdated', 'QBCore:Client:OnPlayerUpdated',
        'QBCore:Server:OnJobUpdate', 'QBCore:Client:OnJobUpdate',
        'QBCore:Server:OnPlayerUpdated', 'QBCore:Client:OnPlayerUpdated',
        'QBCore:Server:OnGangUpdate', 'QBCore:Client:OnGangUpdate',
        'QBCore:Server:OnPlayerUpdated', 'QBCore:Client:OnPlayerUpdated',
        'QBCore:Client:OnMoneyChange', 'QBCore:Server:OnMoneyChange',
        'QBCore:Client:OnMoneyChange', 'QBCore:Server:OnMoneyChange',
      }
      for index, name in ipairs(expected) do assert(calls[index + 1].name == name) end
      assert(calls[2].args[2] == 'job' and calls[6].args[2] == 'gang')
      assert(calls[10].args[2] == 'money')
      assert(calls[12].args[1] == 'bank' and calls[12].args[2] == 25
        and calls[12].args[3] == 'remove')
      assert(calls[14].args[1] == 'cash' and calls[14].args[2] == 25
        and calls[14].args[3] == 'add')
      assert(countCalls('QBCore:Server:SetDuty') == 0)
      assert(countCalls('QBCore:Client:SetDuty') == 0)

      clearCalls()
      assert(lifecycle.handlers.unloaded(lifecycleContext(current, nil, publication)))
      assert(#calls == 3)
      callAt(1, 'client', 'synex_bridge_qb:client:projection', 1)
      callAt(2, 'client', 'QBCore:Client:OnPlayerUnload', 0)
      local serverUnload = callAt(3, 'server', 'QBCore:Server:OnPlayerUnload', 1)
      assert(serverUnload.args[1] == 42)
      return 'ok'
    `);
    assert.equal(result, 'ok');
  } finally {
    engine.global.close();
  }
});

test('Qbox owns native group, duty, and logout events without duplicating QBCore globals', async () => {
  const engine = await createProvider('qbx');
  try {
    const result = await engine.doString(String.raw`
      local qbxOnly = family(false, true, false)
      local previous = mapped()
      assert(lifecycle.handlers.loaded(lifecycleContext(nil, previous, qbxOnly)))
      assert(#calls == 1)
      callAt(1, 'client', 'synex_bridge_qbx:client:projection', 3)
      assert(countCalls('QBCore:Server:PlayerLoaded') == 0)
      assert(countCalls('QBCore:Client:OnPlayerLoaded') == 0)

      snapshot.groups.items[1].duty.counts_as_on_duty = false
      local duty = mapped()
      clearCalls()
      assert(lifecycle.handlers.updated(lifecycleContext(previous, duty, qbxOnly)))
      assert(#calls == 3)
      callAt(1, 'client', 'synex_bridge_qbx:client:projection', 3)
      local serverDuty = callAt(2, 'server', 'QBCore:Server:SetDuty', 2)
      assert(serverDuty.args[1] == 42 and serverDuty.args[2] == false)
      local clientDuty = callAt(3, 'client', 'QBCore:Client:SetDuty', 1)
      assert(clientDuty.args[1] == false)

      snapshot.groups.items[1].grade = {
        key = 'lieutenant', name = 'Lieutenant', rank = 4,
      }
      local promoted = mapped()
      clearCalls()
      assert(lifecycle.handlers.updated(lifecycleContext(duty, promoted, qbxOnly)))
      assert(#calls == 3)
      callAt(1, 'client', 'synex_bridge_qbx:client:projection', 3)
      local groupServer = callAt(2, 'server', 'qbx_core:server:onGroupUpdate', 3)
      assert(groupServer.args[1] == 42 and groupServer.args[2] == 'police'
        and groupServer.args[3] == 4)
      local groupClient = callAt(3, 'client', 'qbx_core:client:onGroupUpdate', 2)
      assert(groupClient.args[1] == 'police' and groupClient.args[2] == 4)
      assert(countCalls('QBCore:Player:SetPlayerData') == 0)

      clearCalls()
      assert(lifecycle.handlers.unloaded(lifecycleContext(promoted, nil, qbxOnly)))
      assert(#calls == 3)
      callAt(1, 'client', 'synex_bridge_qbx:client:projection', 1)
      callAt(2, 'client', 'qbx_core:client:playerLoggedOut', 0)
      local serverLogout = callAt(3, 'server', 'qbx_core:server:playerLoggedOut', 1)
      assert(serverLogout.args[1] == 42)

      local qbcOwner = family(true, true, false)
      clearCalls()
      assert(lifecycle.handlers.loaded(lifecycleContext(nil, promoted, qbcOwner)))
      assert(#calls == 5)
      callAt(2, 'server', 'QBCore:Player:SetPlayerData', 1)
      callAt(3, 'client', 'QBCore:Player:SetPlayerData', 1)
      local loaded = callAt(4, 'server', 'QBCore:Server:PlayerLoaded', 1)
      assert(type(loaded.args[1].PlayerData) == 'table')
      assert(loaded.args[1].Functions == nil)
      assertNoCallables(loaded.args[1])
      callAt(5, 'client', 'QBCore:Client:OnPlayerLoaded', 0)
      return 'ok'
    `);
    assert.equal(result, 'ok');
  } finally {
    engine.global.close();
  }
});

test('ESX lifecycle preserves upstream server/client signatures and conservative isNew semantics', async () => {
  const engine = await createProvider('esx');
  try {
    const result = await engine.doString(String.raw`
      local publication = family(false, false, true)
      local previous = mapped()
      assert(lifecycle.handlers.loaded(lifecycleContext(nil, previous, publication)))
      assert(#calls == 3)
      callAt(1, 'client', 'synex_bridge_esx:client:projection', 3)
      local serverLoaded = callAt(2, 'server', 'esx:playerLoaded', 3)
      assert(serverLoaded.args[1] == 42 and type(serverLoaded.args[2]) == 'table'
        and serverLoaded.args[3] == false)
      assertNoCallables(serverLoaded.args[2])
      assert(serverLoaded.args[2].addMoney == nil
        and serverLoaded.args[2].setMeta == nil
        and serverLoaded.args[2].setJob == nil)
      local clientLoaded = callAt(3, 'client', 'esx:playerLoaded', 3)
      assert(type(clientLoaded.args[1]) == 'table' and clientLoaded.args[2] == false
        and clientLoaded.args[3] == nil)

      snapshot.money.cash, snapshot.money.bank = 140, 850
      snapshot.groups.items[1].grade = {
        key = 'lieutenant', name = 'Lieutenant', rank = 4,
      }
      local current = mapped()
      clearCalls()
      assert(lifecycle.handlers.updated(lifecycleContext(previous, current, publication)))
      assert(#calls == 7)
      callAt(1, 'client', 'synex_bridge_esx:client:projection', 3)
      local setJobServer = callAt(2, 'server', 'esx:setJob', 3)
      assert(setJobServer.args[1] == 42 and setJobServer.args[2].grade == 4
        and setJobServer.args[3].grade == 3)
      local setJobClient = callAt(3, 'client', 'esx:setJob', 2)
      assert(setJobClient.args[1].grade == 4 and setJobClient.args[2].grade == 3)
      callAt(4, 'client', 'esx:setAccountMoney', 1)
      callAt(5, 'server', 'esx:removeAccountMoney', 4)
      callAt(6, 'client', 'esx:setAccountMoney', 1)
      callAt(7, 'server', 'esx:addAccountMoney', 4)
      assert(calls[5].args[2] == 'bank' and calls[5].args[3] == 50)
      assert(calls[7].args[2] == 'money' and calls[7].args[3] == 20)

      clearCalls()
      assert(lifecycle.handlers.unloaded(lifecycleContext(current, nil, publication)))
      assert(#calls == 3)
      callAt(1, 'client', 'synex_bridge_esx:client:projection', 1)
      local logout = callAt(2, 'server', 'esx:playerLogout', 2)
      assert(logout.args[1] == 42 and type(logout.args[2]) == 'function')
      callAt(3, 'client', 'esx:onPlayerLogout', 0)
      return 'ok'
    `);
    assert.equal(result, 'ok');
  } finally {
    engine.global.close();
  }
});

test('provider update events remain silent when companion surfaces are omitted', async () => {
  const cases = {
    qb: String.raw`
      local previous = mapped()
      snapshot.money.cash = 140
      snapshot.groups.items[1].grade = {
        key = 'lieutenant', name = 'Lieutenant', rank = 4,
      }
      snapshot.groups.items[2].grade = { key = 'enforcer', name = 'Enforcer', rank = 2 }
      local current = mapped()
      local publication = family(true, false, false, {
        ['qb.shared.job_update_events'] = false,
        ['qb.shared.gang_update_events'] = false,
        ['qb.shared.duty_update_events'] = false,
        ['qb.shared.money_update_events'] = false,
      })
      assert(lifecycle.handlers.updated(lifecycleContext(previous, current, publication)))
      assert(#calls == 1)
      assert(countCalls('QBCore:Server:OnJobUpdate') == 0)
      assert(countCalls('QBCore:Server:OnGangUpdate') == 0)
      assert(countCalls('QBCore:Server:OnMoneyChange') == 0)
    `,
    qbx: String.raw`
      local previous = mapped()
      snapshot.money.cash = 140
      snapshot.groups.items[1].grade = {
        key = 'lieutenant', name = 'Lieutenant', rank = 4,
      }
      local current = mapped()
      local publication = family(true, true, false, {
        ['qbx.shared.group_update_events'] = false,
        ['qbx.shared.duty_update_events'] = false,
        ['qbx.shared.money_update_events'] = false,
      })
      assert(lifecycle.handlers.updated(lifecycleContext(previous, current, publication)))
      assert(countCalls('qbx_core:server:onGroupUpdate') == 0)
      assert(countCalls('QBCore:Server:OnJobUpdate') == 0)
      assert(countCalls('QBCore:Server:SetDuty') == 0)
      assert(countCalls('QBCore:Server:OnMoneyChange') == 0)
    `,
    esx: String.raw`
      local previous = mapped()
      snapshot.money.cash = 140
      snapshot.groups.items[1].grade = {
        key = 'lieutenant', name = 'Lieutenant', rank = 4,
      }
      local current = mapped()
      local publication = family(false, false, true, {
        ['esx.shared.job_update_events'] = false,
        ['esx.shared.account_update_events'] = false,
      })
      assert(lifecycle.handlers.updated(lifecycleContext(previous, current, publication)))
      assert(#calls == 1)
      assert(countCalls('esx:setJob') == 0)
      assert(countCalls('esx:setAccountMoney') == 0)
    `,
  } as const;

  for (const provider of ['qb', 'qbx', 'esx'] as const) {
    const engine = await createProvider(provider);
    try {
      const result = await engine.doString(`${cases[provider]}\nreturn 'ok'`);
      assert.equal(result, 'ok');
    } finally {
      engine.global.close();
    }
  }
});

test('global lifecycle listeners never inherit a configured consumer authority', async () => {
  for (const provider of ['qb', 'qbx', 'esx'] as const) {
    const engine = await createProvider(provider);
    try {
      const result = await engine.doString(provider === 'esx' ? String.raw`
        local data = mapped()
        assert(lifecycle.handlers.loaded(lifecycleContext(
          nil, data, family(false, false, true))))
        local loaded = callAt(2, 'server', 'esx:playerLoaded', 3)
        local publicPlayer = loaded.args[2]
        assertNoCallables(publicPlayer)
        assert(publicPlayer.addMoney == nil and publicPlayer.removeMoney == nil)
        assert(publicPlayer.setMoney == nil and publicPlayer.setAccountMoney == nil)
        assert(publicPlayer.setMeta == nil and publicPlayer.setJob == nil)
        publicPlayer.accounts[1].money = -1
        assert(snapshot.money.cash == 120 and snapshot.money.bank == 900)
        return 'safe'
      ` : provider === 'qbx' ? String.raw`
        local data = mapped()
        assert(lifecycle.handlers.loaded(lifecycleContext(
          nil, data, family(true, true, false))))
        local loaded = callAt(4, 'server', 'QBCore:Server:PlayerLoaded', 1)
        local publicPlayer = loaded.args[1]
        assertNoCallables(publicPlayer)
        assert(publicPlayer.Functions == nil)
        publicPlayer.PlayerData.money.cash = -1
        assert(snapshot.money.cash == 120)
        return 'safe'
      ` : String.raw`
        local data = mapped()
        assert(lifecycle.handlers.loaded(lifecycleContext(
          nil, data, family(true, false, false))))
        local loaded = callAt(2, 'server', 'QBCore:Server:PlayerLoaded', 1)
        local publicPlayer = loaded.args[1]
        assertNoCallables(publicPlayer)
        assert(publicPlayer.Functions == nil)
        publicPlayer.PlayerData.money.cash = -1
        assert(snapshot.money.cash == 120)
        return 'safe'
      `);
      assert.equal(result, 'safe', provider);
    } finally {
      engine.global.close();
    }
  }
});

test('provider restart resync refreshes private client state without replaying public loaded events', async () => {
  const privateEvents: Record<Provider, string> = {
    qb: 'synex_bridge_qb:client:projection',
    qbx: 'synex_bridge_qbx:client:projection',
    esx: 'synex_bridge_esx:client:projection',
  };
  for (const provider of ['qb', 'qbx', 'esx'] as const) {
    const engine = await createProvider(provider);
    try {
      const result = await engine.doString(String.raw`
        local publication = family(true, true, true)
        assert(lifecycle.handlers.loaded(lifecycleContext(
          nil, mapped(), publication, true)))
        assert(#calls == 1)
        local private = callAt(1, 'client', '${privateEvents[provider]}', 3)
        assert(private.args[1] == 'replace' and type(private.args[2]) == 'table'
          and type(private.args[3]) == 'table')
        return 'ok'
      `);
      assert.equal(result, 'ok');
    } finally {
      engine.global.close();
    }
  }
});

test('callback-only lifecycle input fails closed without sending player data', async () => {
  for (const provider of ['qb', 'esx'] as const) {
    const engine = await createProvider(provider);
    try {
      const result = await engine.doString(String.raw`
        local publication = family(false, false, false)
        publication.clientAccess = {
          playerData = {}, callbacks = { 'legacy_consumer' },
        }
        assert(lifecycle.handlers.loaded(lifecycleContext(
          nil, mapped(), publication, true)))
        assert(#calls == 1)
        local private = callAt(1, 'client',
          'synex_bridge_${provider}:client:projection', 1)
        assert(private.args[1] == 'clear' and private.args[2] == nil)
        return 'ok'
      `);
      assert.equal(result, 'ok');
    } finally {
      engine.global.close();
    }
  }

  const qbx = await createProvider('qbx');
  try {
    const result = await qbx.doString(String.raw`
      local publication = family(false, false, false)
      publication.clientAccess = { playerData = {}, callbacks = {} }
      assert(lifecycle.handlers.loaded(lifecycleContext(
        nil, mapped(), publication, true)))
      assert(#calls == 1)
      local private = callAt(1, 'client',
        'synex_bridge_qbx:client:projection', 1)
      assert(private.args[1] == 'clear' and private.args[2] == nil)
      return 'ok'
    `);
    assert.equal(result, 'ok');
  } finally {
    qbx.global.close();
  }
});

test('polyglot QB and Qbox ownership emits each shared QBCore load event exactly once', async () => {
  const qb = await createProvider('qb');
  const qbx = await createProvider('qbx');
  try {
    const qbCounts = String(await qb.doString(String.raw`
      local data = mapped()
      assert(lifecycle.handlers.loaded(lifecycleContext(
        nil, data, family(true, false, false))))
      return table.concat({
        countCalls('QBCore:Server:PlayerLoaded'),
        countCalls('QBCore:Client:OnPlayerLoaded'),
      }, ':')
    `));
    const qbxCounts = String(await qbx.doString(String.raw`
      local data = mapped()
      assert(lifecycle.handlers.loaded(lifecycleContext(
        nil, data, family(false, true, false))))
      return table.concat({
        countCalls('QBCore:Server:PlayerLoaded'),
        countCalls('QBCore:Client:OnPlayerLoaded'),
      }, ':')
    `));
    assert.equal(qbCounts, '1:1');
    assert.equal(qbxCounts, '0:0');

    const coordinator = await readFile(
      path.join(root, 'libraries', 'synex_bridge', 'server.lua'),
      'utf8',
    );
    assert.match(
      coordinator,
      /qbcOwner\s*=\s*qbCandidate\s*and\s*'qb'\s*or\s*\(qbxCandidate\s*and\s*'qbx'\s*or\s*nil\)/u,
    );
  } finally {
    qb.global.close();
    qbx.global.close();
  }
});

test('client facades accept only private server projections and detach every returned value', async () => {
  for (const provider of ['qb', 'qbx', 'esx'] as const) {
    const engine = await new LuaFactory().createEngine();
    try {
      await engine.doString(String.raw`
        handlers, registered = {}, {}
        invoking = 'legacy_consumer'
        source = 0
        SynexBridgeClient = { create = function()
          return { triggerCallback = function() return 'callback-id' end }
        end }
        RegisterNetEvent = function(name, handler) handlers[name] = handler end
        exports = setmetatable({}, {
          __call = function(_, name, handler) registered[name] = handler end,
        })
        GetInvokingResource = function() return invoking end
      `);
      const source = `${await readFile(
        path.join(root, 'libraries', 'synex_bridge', 'compatibility_notify.lua'),
        'utf8',
      )}\n${await readFile(
        path.join(root, 'resources', `synex_bridge_${provider}`, 'client.lua'),
        'utf8',
      )}`;
      await engine.doString(source);
      const eventName = `synex_bridge_${provider}:client:projection`;
      const publicLoaded = provider === 'esx'
        ? 'esx:playerLoaded'
        : 'QBCore:Client:OnPlayerLoaded';
      const result = await engine.doString(String.raw`
        assert(type(handlers['${eventName}']) == 'function')
        assert(handlers['${publicLoaded}'] == nil)
        local payload = { money = { cash = 10 }, name = 'fixture' }
        local access = {
          playerData = { 'legacy_consumer' },
          callbacks = ${provider === 'qbx' ? '{}' : "{ 'legacy_consumer' }"},
        }
        source = 17
        handlers['${eventName}']('replace', payload, access)
        assert(registered.GetPlayerData() == nil)
        source = 65535
        handlers['${eventName}']('replace', payload, access)
        payload.money.cash = 999
        local first = registered.GetPlayerData()
        assert(first.money.cash == 10)
        first.money.cash = -1
        assert(registered.GetPlayerData().money.cash == 10)
        handlers['${eventName}']('clear')
        assert(registered.GetPlayerData() == nil)
        return 'ok'
      `);
      assert.equal(result, 'ok');
    } finally {
      engine.global.close();
    }
  }
});

async function createNativeLifecycle(): Promise<LuaEngine> {
  const engine = await new LuaFactory().createEngine();
  try {
    await engine.doString(String.raw`
      handlers, subscriptions, timers, registeredExports = {}, {}, {}, {}
      lifecycleEvents = { loaded = {}, updated = {}, unloaded = {} }
      lifecycleRegistrations, metricWrites, lastMetric = 0, 0, nil
      metadataWrites = 0
      lifecycleAllowed = true
      lifecyclePeerCoversQbc = false
      lifecycleFamilyOwned = true
      primaryLifecycleActive, alternateLifecycleActive = true, false
      gameTimer = 1000
      currentCash, currentBank, currentDuty, currentGrade = 120, 900, true, 3
      currentHunger, currentMetadataVersion = 40, 1
      secondarySession, secondaryCharacter = nil, nil
      secondaryCash, secondaryBank, secondaryDuty, secondaryGrade = 220, 800, false, 2
      secondaryHunger, secondaryMetadataVersion = 60, 1
      serviceReads = {}
      connectedPlayerSources = {}
      session = {
        id = 'session_fixture_0001', source = 42, sourceGeneration = 7,
        characterId = 'character_fixture_0001', state = 'ACTIVE',
      }
      character = {
        id = 'character_fixture_0001', slot = 1,
        firstName = 'Ada', lastName = 'Lovelace', dateOfBirth = '1815-12-10',
      }

      function detached(value, seen)
        if type(value) ~= 'table' then return value end
        seen = seen or {}
        if seen[value] then error('cycle') end
        seen[value] = true
        local result = {}
        for key, item in pairs(value) do result[detached(key, seen)] = detached(item, seen) end
        seen[value] = nil
        return result
      end
      SynexBridgeKernel = { Foundation = {
        copyDto = function(value) return detached(value), nil end,
      } }
      json = {
        encode = function() return '{}' end,
        decode = function() return {} end,
      }
      print = function() end
      GetCurrentResourceName = function() return 'synex_bridge_qb' end
      GetInvokingResource = function() return 'legacy_consumer' end
      GetGameTimer = function() return gameTimer end
      GetResourceState = function(resource)
        if resource == 'legacy_consumer' then
          return primaryLifecycleActive and 'started' or 'stopped'
        end
        if resource == 'legacy_consumer_alt' then
          return alternateLifecycleActive and 'started' or 'stopped'
        end
        if resource == 'synex_core' or resource == 'synex_bridge' then
          return 'started'
        end
        return 'stopped'
      end
      GetResourceMetadata = function() return nil end
      GetPlayerName = function(value)
        if tostring(value) == '42' then return 'fixture-player' end
        if secondarySession and tostring(value) == tostring(secondarySession.source) then
          return 'fixture-player-secondary'
        end
        return nil
      end
      GetPlayers = function() return detached(connectedPlayerSources) end
      AddEventHandler = function(name, handler) handlers[name] = handler end
      RegisterNetEvent = function(name, handler) handlers[name] = handler end
      TriggerClientEvent = function() end
      SetTimeout = function(milliseconds, handler)
        timers[#timers + 1] = { milliseconds = milliseconds, handler = handler }
      end
      function runTimers()
        local iterations = 0
        while #timers > 0 do
          iterations = iterations + 1
          assert(iterations <= 32, 'timer loop did not converge')
          local current = timers
          timers = {}
          for _, timer in ipairs(current) do
            gameTimer = gameTimer + timer.milliseconds
            timer.handler()
          end
        end
      end

      local function account(ownerCharacter, alias, value, sequence, uuid)
        return {
          account_id = uuid, owner_kind = 'character', owner_ref = ownerCharacter.id,
          currency_code = 'usd', account_key = alias .. '_' .. ownerCharacter.id,
          account_role = 'asset', minor_unit = 0, booked_minor = value,
          sequence = sequence, status = 'active',
        }
      end
      local function groupSnapshot(characterId)
        local grade, duty = currentGrade, currentDuty
        if secondaryCharacter and characterId == secondaryCharacter.id then
          grade, duty = secondaryGrade, secondaryDuty
        end
        return { items = { {
          membership_id = 'membership_fixture_0001', status = 'ACTIVE',
          is_primary = true, roles = {}, roles_truncated = false,
          group = {
            group_id = 'group_fixture_0001', key = 'police', type = 'job',
            name = 'Police', label = 'Police Department',
          },
          grade = { key = 'sergeant', name = 'Sergeant', rank = grade },
          duty = { counts_as_on_duty = duty },
        } }, truncated = false, next_cursor = nil }
      end

      local api = {
        Tracing = { run = function(context, handler)
          return handler(context.traceId)
        end },
        Players = { getBySource = function(playerSource)
          if playerSource == 42 then return detached(session), nil end
          if secondarySession and playerSource == secondarySession.source then
            return detached(secondarySession), nil
          end
          return nil, { code = 'SESSION_NOT_FOUND' }
        end },
        Characters = {
          getActive = function(playerSource)
            if playerSource == 42 then return detached(character), nil end
            if secondarySession and secondaryCharacter
              and playerSource == secondarySession.source then
              return detached(secondaryCharacter), nil
            end
            return nil, { code = 'CHARACTER_NOT_FOUND' }
          end,
          registerLifecycleParticipant = function(definition)
            lifecycleRegistrations = lifecycleRegistrations + 1
            lifecycleParticipant = definition
            return ('lifecycle-token-%d'):format(lifecycleRegistrations), nil
          end,
        },
        Services = { call = function(service, _, operation, request)
          if service == 'synex.accounts' and operation == 'list_by_owner' then
            local owner = request.owner_ref == character.id and character
              or secondaryCharacter and request.owner_ref == secondaryCharacter.id
                and secondaryCharacter or nil
            assert(owner ~= nil)
            local cash, bank = currentCash, currentBank
            if secondaryCharacter and owner.id == secondaryCharacter.id then
              cash, bank = secondaryCash, secondaryBank
            end
            serviceReads[owner.id] = serviceReads[owner.id]
              or { accounts = 0, groups = 0 }
            serviceReads[owner.id].accounts = serviceReads[owner.id].accounts + 1
            return { items = {
              account(owner, 'cash', cash, cash,
                owner == character and '11111111-1111-4111-8111-111111111111'
                  or '33333333-3333-4333-8333-333333333333'),
              account(owner, 'bank', bank, bank,
                owner == character and '22222222-2222-4222-8222-222222222222'
                  or '44444444-4444-4444-8444-444444444444'),
            }, next_cursor = nil }, nil
          end
          if service == 'synex.groups' and operation == 'compatibility_snapshot' then
            local characterId = request.actor_character_id
            serviceReads[characterId] = serviceReads[characterId]
              or { accounts = 0, groups = 0 }
            serviceReads[characterId].groups = serviceReads[characterId].groups + 1
            return groupSnapshot(characterId), nil
          end
          error(('unexpected service call %s/%s'):format(service, operation))
        end },
        Events = { subscribe = function(topic, handler)
          subscriptions[topic] = handler
          return 'subscription:' .. topic, nil
        end },
        Capabilities = { checkResource = function() return true, nil end },
        Metrics = {
          increment = function(name, labels)
            metricWrites = metricWrites + 1
            lastMetric = { name = name, labels = detached(labels or {}) }
          end,
          observe = function(name, labels)
            metricWrites = metricWrites + 1
            lastMetric = { name = name, labels = detached(labels or {}) }
          end,
        },
      }

      local bridge = {}
      bridge.ShouldPublishLifecycle = function(request)
        assert(request.provider == 'qb' and request.providerResource == 'synex_bridge_qb')
        if not lifecycleAllowed then
          if lifecyclePeerCoversQbc then
            return {
              standby = true,
              coveredFamilies = { qbc = true, qbx = false, esx = false },
            }, nil
          end
          return nil, { code = 'COMPAT_PROVIDER_DISABLED', retryable = false }
        end
        local consumer
        if primaryLifecycleActive
          and request.excludedConsumer ~= 'legacy_consumer' then
          consumer = 'legacy_consumer'
        elseif alternateLifecycleActive
          and request.excludedConsumer ~= 'legacy_consumer_alt' then
          consumer = 'legacy_consumer_alt'
        end
        if not consumer then
          return nil, { code = 'COMPAT_PROVIDER_DISABLED', retryable = false }
        end
        return {
          consumer = consumer, traceId = 'trace-lifecycle-fixture',
          authorizationOperation = 'lifecycle.publish',
          families = {
            qbc = lifecycleFamilyOwned, qbx = false, esx = false,
          },
          clientAccess = {
            playerData = { consumer }, callbacks = { consumer },
          },
          surfaces = {
            ['qb.shared.job_update_events'] = true,
            ['qb.shared.gang_update_events'] = true,
            ['qb.shared.duty_update_events'] = true,
            ['qb.shared.money_update_events'] = true,
          },
        }, nil
      end
      bridge.AuthorizeCompatibilityConsumer = function(request)
        assert(request.consumer == 'legacy_consumer'
          or request.consumer == 'legacy_consumer_alt')
        return {
          authority = 'operator_registry', mode = 'compat',
          traceId = 'trace-lifecycle-fixture',
        }, nil
      end
      bridge.ResolveCompatibilityAccountMapping = function(request)
        assert(request.alias == 'cash' or request.alias == 'bank')
        return {
          alias = request.alias, id = 'mapping.' .. request.alias, version = '1.0.0',
          currencyCode = 'usd', accountKey = request.alias,
          accountRole = 'asset', minorUnit = 0, status = 'PARTIAL',
        }, nil
      end
      bridge.ProjectCompatibilityGroups = function(request)
        return detached(request.groups), nil
      end
      bridge.ResolveCompatibilityIdentity = function(request)
        return { identifier = request.characterId == character.id
          and 'legacy-identity-42' or 'legacy-identity-43' }, nil
      end
      bridge.GetCompatibilityMetadata = function(request)
        if request.characterId == character.id then
          return { values = { hunger = currentHunger },
            versions = { hunger = currentMetadataVersion } }, nil
        end
        assert(secondaryCharacter and request.characterId == secondaryCharacter.id)
        return { values = { hunger = secondaryHunger },
          versions = { hunger = secondaryMetadataVersion } }, nil
      end
      bridge.ResolveMetadataMapping = function(request)
        assert(request.key == 'hunger' and request.operation == 'write')
        return { allowed = true, nativeKey = 'hunger' }, nil
      end
      bridge.SetCompatibilityMetadata = function(request)
        metadataWrites = metadataWrites + 1
        if request.characterId == character.id then
          assert(request.expectedVersion == currentMetadataVersion)
          currentHunger = request.value
          currentMetadataVersion = currentMetadataVersion + 1
          return { version = currentMetadataVersion }, nil
        end
        assert(secondaryCharacter and request.characterId == secondaryCharacter.id)
        assert(request.expectedVersion == secondaryMetadataVersion)
        secondaryHunger = request.value
        secondaryMetadataVersion = secondaryMetadataVersion + 1
        return { version = secondaryMetadataVersion }, nil
      end

      exports = setmetatable({
        synex_core = { GetAPI = function(_, range)
          assert(range == '^1.0.0')
          return api, nil
        end },
        synex_bridge = bridge,
      }, { __call = function(_, name, handler) registeredExports[name] = handler end })
    `);
    const native = await readFile(
      path.join(root, 'libraries', 'synex_bridge', 'native_server.lua'),
      'utf8',
    );
    await engine.doString(native);
    await engine.doString(String.raw`
      adapter = SynexBridgeNative.create({
        framework = 'qb', capabilityPrefix = 'synex.compat.qb',
        requestEvent = 'fixture:request', responseEvent = 'fixture:response',
        historicalResource = 'qb-core', moneyAliases = { 'cash', 'bank' },
      })
      local token, lifecycleError = adapter:registerLifecycle(function(snapshot)
        local membership = snapshot.groups.items[1]
        return {
          source = snapshot.source,
          cash = snapshot.money.cash,
          bank = snapshot.money.bank,
          grade = membership.grade.rank,
          duty = membership.duty.counts_as_on_duty,
          hunger = snapshot.metadata.hunger,
        }
      end, {
        loaded = function(context)
          lifecycleEvents.loaded[#lifecycleEvents.loaded + 1] = {
            source = context.source, consumer = context.consumer,
            publication = detached(context.publication),
            playerData = detached(context.playerData),
            fence = detached(context.fence),
            resync = context.resync == true,
          }
          return true
        end,
        updated = function(context)
          lifecycleEvents.updated[#lifecycleEvents.updated + 1] = {
            source = context.source, consumer = context.consumer,
            publication = detached(context.publication),
            previousPlayerData = detached(context.previousPlayerData),
            playerData = detached(context.playerData), topics = detached(context.topics),
            fence = detached(context.fence),
          }
          return true
        end,
        unloaded = function(context)
          lifecycleEvents.unloaded[#lifecycleEvents.unloaded + 1] = {
            source = context.source, consumer = context.consumer,
            publication = detached(context.publication),
            previousPlayerData = detached(context.previousPlayerData),
            fence = detached(context.fence),
          }
          return true
        end,
      })
      assert(token and lifecycleError == nil)
      assert(lifecycleRegistrations == 1)
    `);
    return engine;
  } catch (error) {
    engine.global.close();
    throw error;
  }
}

test('native lifecycle is event-driven, deduplicated, generation-fenced, and restart-safe', async () => {
  const engine = await createNativeLifecycle();
  try {
    const result = await engine.doString(String.raw`
      local prepared = assert(lifecycleParticipant.prepare({ session = session }))
      local committed, commitError = lifecycleParticipant.commit(prepared)
      assert(committed, type(commitError) == 'table'
        and (commitError.code .. ':' .. commitError.message) or tostring(commitError))
      assert(#lifecycleEvents.loaded == 1 and #lifecycleEvents.updated == 0)
      assert(lifecycleEvents.loaded[1].fence.sessionId == 'session_fixture_0001')
      assert(lifecycleEvents.loaded[1].playerData.cash == 120)

      -- Repeated commits for one exact session/source-generation reconcile but
      -- never deliver a second loaded event.
      assert(lifecycleParticipant.commit(prepared))
      assert(#lifecycleEvents.loaded == 1 and #lifecycleEvents.updated == 0)

      currentCash, currentDuty = 145, false
      assert(subscriptions['synex.accounts.transaction.posted']())
      assert(subscriptions['synex.groups.duty.updated']())
      assert(#timers == 1)
      runTimers()
      assert(#lifecycleEvents.updated == 1,
        ('expected one update, got %d (metrics=%d, last=%s/%s)'):format(
          #lifecycleEvents.updated, metricWrites,
          lastMetric and lastMetric.name or 'nil',
          lastMetric and lastMetric.labels and lastMetric.labels.code or 'nil'))
      local update = lifecycleEvents.updated[1]
      assert(update.previousPlayerData.cash == 120 and update.playerData.cash == 145,
        ('cash %s -> %s'):format(tostring(update.previousPlayerData.cash),
          tostring(update.playerData.cash)))
      assert(update.previousPlayerData.duty == true and update.playerData.duty == false,
        ('duty %s -> %s'):format(tostring(update.previousPlayerData.duty),
          tostring(update.playerData.duty)))
      assert(#update.topics == 2, 'unexpected topic count ' .. tostring(#update.topics))
      assert(update.topics[1] == 'synex.accounts.transaction.posted')
      assert(update.topics[2] == 'synex.groups.duty.updated')

      -- A canonical event whose projection is unchanged is intentionally silent.
      assert(subscriptions['synex.accounts.transaction.posted']())
      runTimers()
      assert(#lifecycleEvents.updated == 1)

      -- A queued refresh cannot cross a reused source generation.
      currentCash = 170
      assert(subscriptions['synex.accounts.transaction.posted']())
      assert(#timers == 1)
      session.id, session.sourceGeneration = 'session_fixture_0002', 8
      runTimers()
      assert(#lifecycleEvents.updated == 1)

      -- Committing the reused source unloads its stale generation before load.
      local secondPrepared = assert(lifecycleParticipant.prepare({ session = session }))
      assert(lifecycleParticipant.commit(secondPrepared))
      assert(#lifecycleEvents.unloaded == 1 and #lifecycleEvents.loaded == 2)
      assert(lifecycleEvents.unloaded[1].fence.sourceGeneration == 7)
      assert(lifecycleEvents.loaded[2].fence.sourceGeneration == 8)
      assert(lifecycleEvents.loaded[2].playerData.cash == 170)

      -- A Core outage clears the projection; a successful fenced rebind
      -- republishes it as a fresh load rather than an update.
      handlers.onResourceStop('synex_core')
      assert(#lifecycleEvents.unloaded == 2)
      handlers.onResourceStart('synex_core')
      runTimers()
      assert(lifecycleRegistrations == 2)
      assert(#lifecycleEvents.loaded == 3 and #lifecycleEvents.updated == 1)
      assert(lifecycleEvents.loaded[3].fence.sourceGeneration == 8)
      currentBank = 950
      assert(subscriptions['synex.accounts.transaction.posted']())
      runTimers()
      assert(#lifecycleEvents.updated == 2)
      assert(lifecycleEvents.updated[2].previousPlayerData.bank == 900)
      assert(lifecycleEvents.updated[2].playerData.bank == 950)

      local activeParticipant = lifecycleParticipant
      assert(activeParticipant.unload({ session = session }))
      assert(#lifecycleEvents.unloaded == 3)
      assert(activeParticipant.unload({ session = session }))
      assert(#lifecycleEvents.unloaded == 3)
      assert(#timers == 0)
      return 'ok'
    `);
    assert.equal(result, 'ok');
  } finally {
    engine.global.close();
  }
});

test('metadata mutation schedules exactly one generation-fenced private lifecycle update', async () => {
  const engine = await createNativeLifecycle();
  try {
    const result = await engine.doString(String.raw`
      local prepared = assert(lifecycleParticipant.prepare({ session = session }))
      assert(lifecycleParticipant.commit(prepared))
      assert(#lifecycleEvents.loaded == 1 and lifecycleEvents.loaded[1].playerData.hunger == 40)

      local fence = lifecycleEvents.loaded[1].fence
      local changed, changeError = adapter:setMetadata(
        'legacy_consumer', 42, 'hunger', 55, fence, 1)
      assert(changed and changeError == nil and changed.version == 2,
        changeError and (changeError.code .. ':' .. tostring(changeError.message))
          or 'metadata mutation returned an invalid result')
      assert(metadataWrites == 1 and #timers == 1)
      runTimers()
      assert(#lifecycleEvents.updated == 1)
      local update = lifecycleEvents.updated[1]
      assert(update.source == 42)
      assert(update.previousPlayerData.hunger == 40 and update.playerData.hunger == 55)
      assert(#update.topics == 1
        and update.topics[1] == 'synex.compat.metadata.changed')

      local staleChanged, staleChangeError = adapter:setMetadata(
        'legacy_consumer', 42, 'hunger', 60, fence, 2)
      assert(staleChanged and staleChangeError == nil and staleChanged.version == 3)
      assert(metadataWrites == 2 and #timers == 1)
      session.id, session.sourceGeneration = 'session_fixture_0002', 8
      runTimers()
      assert(#lifecycleEvents.updated == 1)
      return 'ok'
    `);
    assert.equal(result, 'ok');
  } finally {
    engine.global.close();
  }
});

test('account and group events refresh only the safely identified character source', async () => {
  const engine = await createNativeLifecycle();
  try {
    const result = await engine.doString(String.raw`
      secondarySession = {
        id = 'session_fixture_0002', source = 43, sourceGeneration = 4,
        characterId = 'character_fixture_0002', state = 'ACTIVE',
      }
      secondaryCharacter = {
        id = 'character_fixture_0002', slot = 2,
        firstName = 'Grace', lastName = 'Hopper', dateOfBirth = '1906-12-09',
      }
      local firstPrepared = assert(lifecycleParticipant.prepare({ session = session }))
      local secondPrepared = assert(lifecycleParticipant.prepare({ session = secondarySession }))
      assert(lifecycleParticipant.commit(firstPrepared))
      assert(lifecycleParticipant.commit(secondPrepared))
      assert(#lifecycleEvents.loaded == 2 and #lifecycleEvents.updated == 0)
      assert(serviceReads[character.id].accounts == 1
        and serviceReads[character.id].groups == 1)
      assert(serviceReads[secondaryCharacter.id].accounts == 1
        and serviceReads[secondaryCharacter.id].groups == 1)

      currentCash, currentDuty = 145, false
      assert(subscriptions['synex.accounts.account.created']({
        owner_kind = 'character', owner_ref = character.id,
      }))
      assert(subscriptions['synex.groups.duty.updated']({
        character_id = character.id,
      }))
      assert(#timers == 1)
      runTimers()
      assert(#lifecycleEvents.updated == 1)
      assert(lifecycleEvents.updated[1].source == 42)
      assert(lifecycleEvents.updated[1].playerData.cash == 145
        and lifecycleEvents.updated[1].playerData.duty == false)
      assert(#lifecycleEvents.updated[1].topics == 2)
      assert(serviceReads[character.id].accounts == 2
        and serviceReads[character.id].groups == 2)
      assert(serviceReads[secondaryCharacter.id].accounts == 1
        and serviceReads[secondaryCharacter.id].groups == 1)
      local retainedSecondary = assert(adapter:readPlayer('legacy_consumer', 43))
      assert(retainedSecondary.money.cash == 220)
      assert(serviceReads[secondaryCharacter.id].accounts == 1
        and serviceReads[secondaryCharacter.id].groups == 1)

      secondaryCash = 240
      assert(subscriptions['synex.accounts.transaction.posted']({}))
      runTimers()
      assert(#lifecycleEvents.updated == 2)
      assert(lifecycleEvents.updated[2].source == 43
        and lifecycleEvents.updated[2].playerData.cash == 240)
      assert(serviceReads[character.id].accounts == 3
        and serviceReads[character.id].groups == 3)
      assert(serviceReads[secondaryCharacter.id].accounts == 2
        and serviceReads[secondaryCharacter.id].groups == 2)
      return 'ok'
    `);
    assert.equal(result, 'ok');
  } finally {
    engine.global.close();
  }
});

test('consumer stop clears lifecycle state and restart waits for renewed authorization', async () => {
  const engine = await createNativeLifecycle();
  try {
    const result = await engine.doString(String.raw`
      local prepared = assert(lifecycleParticipant.prepare({ session = session }))
      assert(lifecycleParticipant.commit(prepared))
      assert(#lifecycleEvents.loaded == 1 and #lifecycleEvents.unloaded == 0)

      lifecycleAllowed = false
      handlers.onResourceStop('legacy_consumer')
      runTimers()
      assert(#lifecycleEvents.unloaded == 1)
      assert(#lifecycleEvents.loaded == 1 and #lifecycleEvents.updated == 0)

      lifecycleAllowed = true
      handlers.onResourceStart('legacy_consumer')
      runTimers()
      assert(#lifecycleEvents.loaded == 2 and #lifecycleEvents.updated == 0)
      assert(lifecycleEvents.loaded[2].fence.sessionId == 'session_fixture_0001')
      return 'ok'
    `);
    assert.equal(result, 'ok');
  } finally {
    engine.global.close();
  }
});

test('consumer lifecycle authority fails over without global unload and load flapping', async () => {
  const engine = await createNativeLifecycle();
  try {
    const result = await engine.doString(String.raw`
      local prepared = assert(lifecycleParticipant.prepare({ session = session }))
      assert(lifecycleParticipant.commit(prepared))
      assert(#lifecycleEvents.loaded == 1 and #lifecycleEvents.unloaded == 0)
      assert(lifecycleEvents.loaded[1].consumer == 'legacy_consumer')

      alternateLifecycleActive = true
      primaryLifecycleActive = false
      handlers.onResourceStop('legacy_consumer')
      runTimers()
      assert(#lifecycleEvents.loaded == 1 and #lifecycleEvents.unloaded == 0)
      assert(#lifecycleEvents.updated == 1)
      assert(lifecycleEvents.updated[1].consumer == 'legacy_consumer_alt')

      currentCash = 155
      assert(subscriptions['synex.accounts.transaction.posted']())
      runTimers()
      assert(#lifecycleEvents.updated == 2)
      assert(lifecycleEvents.updated[2].consumer == 'legacy_consumer_alt')

      alternateLifecycleActive = false
      handlers.onResourceStop('legacy_consumer_alt')
      runTimers()
      assert(#lifecycleEvents.unloaded == 1,
        ('expected one unload after final consumer stopped, got %d'):format(
          #lifecycleEvents.unloaded))
      assert(lifecycleEvents.unloaded[1].consumer == 'legacy_consumer_alt')

      primaryLifecycleActive = true
      handlers.onResourceStart('legacy_consumer')
      runTimers()
      assert(#lifecycleEvents.loaded == 2 and #lifecycleEvents.unloaded == 1,
        ('expected 2/1 load/unload after restart, got %d/%d'):format(
          #lifecycleEvents.loaded, #lifecycleEvents.unloaded))
      assert(lifecycleEvents.loaded[2].consumer == 'legacy_consumer')
      return 'ok'
    `);
    assert.equal(result, 'ok');
  } finally {
    engine.global.close();
  }
});

test('QB to QBX family handoff stays globally loaded until the real disconnect', async () => {
  const engine = await createNativeLifecycle();
  try {
    const result = await engine.doString(String.raw`
      local prepared = assert(lifecycleParticipant.prepare({ session = session }))
      assert(lifecycleParticipant.commit(prepared))
      assert(#lifecycleEvents.loaded == 1 and #lifecycleEvents.unloaded == 0)
      assert(lifecycleEvents.loaded[1].publication.families.qbc == true)

      -- QB loses authorization while an authorized QBX provider covers the
      -- shared QBC family. The local provider fences its delivery, but the
      -- public family remains globally loaded and therefore receives no fake
      -- unload.
      lifecycleAllowed = false
      lifecyclePeerCoversQbc = true
      handlers.onResourceStop('legacy_consumer')
      runTimers()
      assert(#lifecycleEvents.loaded == 1 and #lifecycleEvents.unloaded == 1)
      assert(lifecycleEvents.unloaded[1].publication.families.qbc == false)

      -- QB returns and deterministically regains ownership. Rehydration is a
      -- private projection refresh; it must not replay the global QBC load.
      lifecycleAllowed = true
      lifecyclePeerCoversQbc = false
      handlers.onResourceStart('legacy_consumer')
      runTimers()
      assert(#lifecycleEvents.loaded == 2 and #lifecycleEvents.unloaded == 1)
      assert(lifecycleEvents.loaded[2].publication.families.qbc == false)

      handlers.onResourceStart('legacy_consumer')
      runTimers()
      assert(#lifecycleEvents.loaded == 2 and #lifecycleEvents.unloaded == 1)

      local publicLoads, publicUnloads = 0, 0
      for _, event in ipairs(lifecycleEvents.loaded) do
        if event.publication.families.qbc == true then
          publicLoads = publicLoads + 1
        end
      end
      for _, event in ipairs(lifecycleEvents.unloaded) do
        if event.publication.families.qbc == true then
          publicUnloads = publicUnloads + 1
        end
      end
      assert(publicLoads == 1 and publicUnloads == 0)

      assert(lifecycleParticipant.unload({ session = session }))
      assert(#lifecycleEvents.unloaded == 2)
      assert(lifecycleEvents.unloaded[2].publication.families.qbc == true)
      publicUnloads = publicUnloads + 1
      assert(publicLoads == 1 and publicUnloads == 1)
      return 'load:handoff:return:disconnect'
    `);
    assert.equal(result, 'load:handoff:return:disconnect');
  } finally {
    engine.global.close();
  }
});

test('provider restart rehydrates active clients only after an authorized consumer starts', async () => {
  const engine = await createNativeLifecycle();
  try {
    const result = await engine.doString(String.raw`
      connectedPlayerSources = { '42' }
      lifecycleAllowed = false
      handlers.onResourceStart('legacy_consumer')
      runTimers()
      assert(#lifecycleEvents.loaded == 0)

      lifecycleAllowed = true
      handlers.onResourceStart('legacy_consumer')
      runTimers()
      assert(#lifecycleEvents.loaded == 1)
      assert(lifecycleEvents.loaded[1].resync == true)
      assert(lifecycleEvents.loaded[1].fence.characterId == character.id)

      handlers.onResourceStart('legacy_consumer')
      runTimers()
      assert(#lifecycleEvents.loaded == 1 and #lifecycleEvents.updated == 0)
      return 'ok'
    `);
    assert.equal(result, 'ok');
  } finally {
    engine.global.close();
  }
});

test('native lifecycle uses canonical event subscriptions without polling loops', async () => {
  const source = await readFile(
    path.join(root, 'libraries', 'synex_bridge', 'native_server.lua'),
    'utf8',
  );
  assert.match(source, /events\.subscribe/u);
  assert.match(source, /SetTimeout\(0,\s*function\(\)\s*refreshLifecycleSource/u);
  assert.doesNotMatch(source, /CreateThread\s*\(/u);
  assert.doesNotMatch(source, /while\s+true\s+do/u);
});
