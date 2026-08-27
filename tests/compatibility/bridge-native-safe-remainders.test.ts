import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';

const root = process.cwd();
const foundationPath = path.join(
  root, 'libraries', 'synex_bridge', 'kernel', 'foundation.lua',
);
const nativeServerPath = path.join(
  root, 'libraries', 'synex_bridge', 'native_server.lua',
);

async function createFixture() {
  const engine = await new LuaFactory().createEngine();
  await engine.doString(String.raw`
    source = 0
    registeredEvents, registeredExports = {}, {}
    connectedPlayers, playerNames, sessions, characters = {}, {}, {}, {}
    identitiesByIdentifier, identifiersByCharacter = {}, {}
    accountCatalog = { items = {}, truncated = false }
    permissionCatalog = { items = {}, truncated = false }
    permissionAnswers, permissionChecks = {}, {}
    characterGetCalls, accountCatalogCalls, permissionCatalogCalls = 0, 0, 0
    capabilityChecks, deniedCapability = {}, nil

    json = {
      encode = function() return '{}' end,
      decode = function() return {} end,
    }
    print = function() end
    GetGameTimer = function() return 1000 end
    GetCurrentResourceName = function() return 'synex_bridge_qb' end
    GetResourceState = function(resource)
      if resource == 'legacy_consumer' then return 'started' end
      return 'missing'
    end
    GetResourceMetadata = function() return nil end
    GetPlayers = function() return connectedPlayers end
    GetPlayerName = function(playerSource) return playerNames[tostring(playerSource)] end
    RegisterNetEvent = function(name, handler) registeredEvents[name] = handler end
    AddEventHandler = function(name, handler) registeredEvents[name] = handler end
    SetTimeout = function() end
    TriggerClientEvent = function() end

    local function activeCharacter(playerSource)
      local session = sessions[playerSource]
      return session and characters[session.characterId] or nil
    end

    local api = {
      Capabilities = {
        checkResource = function(resource, capability, reason)
          capabilityChecks[#capabilityChecks + 1] = {
            resource = resource, capability = capability, reason = reason,
          }
          if capability == deniedCapability then
            return nil, { code = 'CAPABILITY_DENIED', retryable = false }
          end
          return true, nil
        end,
      },
      Tracing = {
        run = function(_, handler) return handler() end,
      },
      Events = {
        subscribe = function(topic) return 'subscription:' .. topic, nil end,
      },
      Players = {
        getBySource = function(playerSource) return sessions[playerSource], nil end,
      },
      Characters = {
        getActive = function(playerSource) return activeCharacter(playerSource), nil end,
        get = function(characterId)
          characterGetCalls = characterGetCalls + 1
          return characters[characterId], nil
        end,
      },
      Services = {
        call = function(service, _, operation, request)
          if service == 'synex.accounts' and operation == 'list_by_owner' then
            local items = {}
            for index, mapping in ipairs(accountCatalog.items) do
              items[index] = {
                account_id = ('00000000-0000-4000-8000-%012d'):format(index),
                owner_kind = 'character', owner_ref = request.owner_ref,
                currency_code = mapping.currencyCode,
                account_key = mapping.accountKey .. '_'
                  .. request.owner_ref:gsub('%-', ''),
                account_role = mapping.accountRole,
                minor_unit = mapping.minorUnit,
                booked_minor = index * 100 + 25,
                sequence = index,
                status = 'active',
              }
            end
            return { items = items }, nil
          end
          if service == 'synex.groups'
            and operation == 'compatibility_snapshot' then
            return { items = {}, truncated = false }, nil
          end
          return nil, { code = 'UNEXPECTED_SERVICE_CALL' }
        end,
      },
      Permissions = {
        check = function(subject, permission)
          permissionChecks[#permissionChecks + 1] = {
            subject = subject, permission = permission,
          }
          local answer = permissionAnswers[permission]
          if type(answer) == 'table' then return nil, answer end
          return answer == true, nil
        end,
      },
      Metrics = {}, RPC = {},
    }

    exports = setmetatable({
      synex_core = {
        GetAPI = function(_, range)
          assert(range == '^1.0.0')
          return api, nil
        end,
      },
      synex_bridge = {
        AuthorizeCompatibilityConsumer = function(request)
          assert(request.provider == 'qb')
          assert(request.providerResource == 'synex_bridge_qb')
          assert(request.consumer == 'legacy_consumer')
          return {
            authority = 'operator_registry', mode = 'compat',
            traceId = 'trace-native-safe-remainders',
          }, nil
        end,
        FindCompatibilityIdentity = function(request)
          local identity = identitiesByIdentifier[request.identifier]
          return identity or false, nil
        end,
        ResolveCompatibilityIdentity = function(request)
          local identifier = identifiersByCharacter[request.characterId]
          if not identifier then return nil, { code = 'IDENTITY_NOT_FOUND' } end
          return {
            provider = 'qb', identifierType = 'citizenid',
            identifier = identifier, characterId = request.characterId,
          }, nil
        end,
        GetCompatibilityMetadata = function()
          return { values = {}, versions = {} }, nil
        end,
        ProjectCompatibilityGroups = function(request)
          return { items = request.groups.items, truncated = false }, nil
        end,
        ListCompatibilityAccountMappings = function(request)
          assert(request.provider == 'qb')
          accountCatalogCalls = accountCatalogCalls + 1
          return accountCatalog, nil
        end,
        ListCompatibilityPermissionMappings = function(request)
          assert(request.provider == 'qb')
          permissionCatalogCalls = permissionCatalogCalls + 1
          return permissionCatalog, nil
        end,
      },
    }, {
      __call = function(_, name, handler) registeredExports[name] = handler end,
    })

    function setIdentity(identifier, characterId)
      identitiesByIdentifier[identifier] = {
        provider = 'qb', identifierType = 'citizenid',
        identifier = identifier, characterId = characterId,
      }
      identifiersByCharacter[characterId] = identifier
    end

    function setCharacter(characterId, firstName)
      characters[characterId] = {
        id = characterId, slot = 1, firstName = firstName,
        lastName = 'Fixture', dateOfBirth = '2000-01-01',
      }
    end

    function setSession(playerSource, state, characterId)
      sessions[playerSource] = {
        id = 'session-' .. tostring(playerSource), state = state,
        sourceGeneration = 1, characterId = characterId,
      }
      playerNames[tostring(playerSource)] = 'Fixture ' .. tostring(playerSource)
    end
  `);
  await engine.doString(await readFile(foundationPath, 'utf8'));
  await engine.doString(await readFile(nativeServerPath, 'utf8'));
  await engine.doString(String.raw`
    adapter = SynexBridgeNative.create({
      framework = 'qb', capabilityPrefix = 'synex.compat.qb',
      requestEvent = 'fixture:request', responseEvent = 'fixture:response',
      discoverAccountMappings = true,
    })
  `);
  return engine;
}

test('native identifier lookup resolves one active authority and discovered account definitions', async () => {
  const engine = await createFixture();
  try {
    const result = await engine.doString(String.raw`
      accountCatalog = { items = {
        {
          id = 'qb.account.bank', version = '1.0.0', alias = 'bank',
          currencyCode = 'usd', accountKey = 'bank', accountRole = 'asset',
          minorUnit = 2, legacyName = 'bank', label = 'Bank Account',
          round = false, status = 'COMPATIBLE',
        },
        {
          id = 'qb.account.cash', version = '1.0.0', alias = 'cash',
          currencyCode = 'usd', accountKey = 'wallet', accountRole = 'asset',
          minorUnit = 0, legacyName = 'money', label = 'Cash',
          round = true, status = 'CERTIFIED',
        },
      }, truncated = false }
      setCharacter('character-online', 'Online')
      setCharacter('character-other', 'Other')
      setIdentity('citizen-online', 'character-online')
      setIdentity('citizen-other', 'character-other')
      setSession(8, 'ACTIVE', 'character-online')
      setSession(9, 'ACTIVE', 'character-other')
      setSession(4, 'CONNECTING', 'character-pending')
      connectedPlayers = { '9', '4', '8' }

      local snapshot, lookupError = adapter:readPlayerByIdentifier(
        'legacy_consumer', 'citizen-online')
      assert(snapshot and lookupError == nil)
      assert(snapshot.source == 8 and snapshot.identity.identifier == 'citizen-online')
      assert(snapshot.identity.characterId == 'character-online')
      assert(snapshot.money.bank == 125 and snapshot.money.cash == 225)
      assert(snapshot.accountDefinitions.bank.name == 'bank')
      assert(snapshot.accountDefinitions.bank.label == 'Bank Account')
      assert(snapshot.accountDefinitions.bank.round == false)
      assert(snapshot.accountDefinitions.bank.minorUnit == 2)
      assert(snapshot.accountDefinitions.cash.name == 'money')
      assert(snapshot.accountDefinitions.cash.label == 'Cash')
      assert(snapshot.accountDefinitions.cash.round == true)
      assert(snapshot.accountDefinitions.cash.minorUnit == 0)
      assert(accountCatalogCalls == 1)

      local missing, missingError = adapter:readPlayerByIdentifier(
        'legacy_consumer', 'citizen-missing')
      assert(missing == false and missingError == nil)
      local invalid, invalidError = adapter:readPlayerByIdentifier(
        'legacy_consumer', string.rep('x', 192))
      assert(invalid == nil and invalidError.code == 'COMPAT_INVALID_ARGUMENT')

      sessions[9].characterId = 'character-online'
      local duplicate, duplicateError = adapter:readPlayerByIdentifier(
        'legacy_consumer', 'citizen-online')
      assert(duplicate == nil)
      assert(duplicateError.code == 'COMPAT_IDENTITY_AMBIGUOUS')
      return table.concat({ snapshot.source, snapshot.money.bank,
        snapshot.accountDefinitions.cash.name }, ':')
    `);
    assert.equal(result, '8:125:money');
  } finally {
    engine.global.close();
  }
});

test('domain projections do not require unrelated account authority', async () => {
  const engine = await createFixture();
  try {
    const result = await engine.doString(String.raw`
      setCharacter('character-domain', 'Domain')
      setIdentity('citizen-domain', 'character-domain')
      setSession(12, 'ACTIVE', 'character-domain')
      connectedPlayers = { '12' }
      deniedCapability = 'synex.accounts.read'

      local groups, groupsError = adapter:readGroups('legacy_consumer', 12)
      assert(groups and groupsError == nil)
      assert(groups.character.id == 'character-domain')
      assert(groups.groups.truncated == false)

      local metadata, metadataError = adapter:readMetadata('legacy_consumer', 12)
      assert(metadata and metadataError == nil)
      assert(metadata.character.id == 'character-domain')
      assert(type(metadata.metadata) == 'table')

      local sawIdentity, sawGroups = false, false
      for _, check in ipairs(capabilityChecks) do
        assert(check.capability ~= 'synex.accounts.read')
        if check.capability == 'synex.identity.read' then sawIdentity = true end
        if check.capability == 'synex.groups.read' then sawGroups = true end
      end
      assert(sawIdentity and sawGroups)
      return 'ok'
    `);
    assert.equal(result, 'ok');
  } finally {
    engine.global.close();
  }
});

test('native player enumeration is sorted, active-only, duplicate-safe, and hard bounded', async () => {
  const engine = await createFixture();
  try {
    const result = await engine.doString(String.raw`
      setSession(19, 'ACTIVE', 'character-nineteen')
      setSession(7, 'ACTIVE', 'character-seven')
      setSession(4, 'CONNECTING', 'character-four')
      connectedPlayers = { '19', '4', '11', '7' }
      local sources, listError = adapter:listPlayerSources('legacy_consumer')
      assert(listError == nil and #sources == 2)
      assert(sources[1] == 7 and sources[2] == 19)

      connectedPlayers = {}
      for index = 1, 257 do connectedPlayers[index] = tostring(index) end
      local oversized, oversizedError = adapter:listPlayerSources('legacy_consumer')
      assert(oversized == nil)
      assert(oversizedError.code == 'COMPAT_PLAYER_ENUMERATION_LIMIT')

      connectedPlayers = { '7', '7' }
      local duplicate, duplicateError = adapter:listPlayerSources('legacy_consumer')
      assert(duplicate == nil)
      assert(duplicateError.code == 'COMPAT_PLAYER_ENUMERATION_INVALID')
      return table.concat(sources, ':')
    `);
    assert.equal(result, '7:19');
  } finally {
    engine.global.close();
  }
});

test('native offline lookup returns a detached read-only projection without active-session authority', async () => {
  const engine = await createFixture();
  try {
    const result = await engine.doString(String.raw`
      accountCatalog = { items = { {
        id = 'qb.account.cash', version = '1.0.0', alias = 'cash',
        currencyCode = 'usd', accountKey = 'wallet', accountRole = 'asset',
        minorUnit = 0, legacyName = 'cash', label = 'Cash',
        round = true, status = 'CERTIFIED',
      } }, truncated = false }
      setCharacter('character-offline', 'Offline')
      setIdentity('citizen-offline', 'character-offline')
      setCharacter('character-online', 'Online')
      setSession(12, 'ACTIVE', 'character-online')
      connectedPlayers = { '12' }

      local snapshot, offlineError = adapter:readOfflinePlayerByIdentifier(
        'legacy_consumer', 'citizen-offline')
      assert(snapshot and offlineError == nil and snapshot.offline == true)
      assert(snapshot.source == nil and snapshot.fence == nil)
      assert(snapshot.character.id == 'character-offline')
      assert(snapshot.money.cash == 125)
      assert(snapshot.accountDefinitions.cash.name == 'cash')
      assert(characterGetCalls == 1)
      snapshot.character.firstName = 'Tampered'
      snapshot.money.cash = 999999
      assert(characters['character-offline'].firstName == 'Offline')

      identitiesByIdentifier['citizen-invalid-character'] = {
        provider = 'qb', identifierType = 'citizenid',
        identifier = 'citizen-invalid-character', characterId = 'character-invalid',
      }
      identifiersByCharacter['character-invalid'] = 'citizen-invalid-character'
      characters['character-invalid'] = {
        id = 'different-character', slot = 2, firstName = 'Invalid',
      }
      local invalid, invalidError = adapter:readOfflinePlayerByIdentifier(
        'legacy_consumer', 'citizen-invalid-character')
      assert(invalid == nil and invalidError.code == 'INVALID_CHARACTER_SNAPSHOT')
      return table.concat({ snapshot.character.id, snapshot.money.cash,
        characterGetCalls }, ':')
    `);
    assert.equal(result, 'character-offline:999999:2');
  } finally {
    engine.global.close();
  }
});

test('native permission projection selects one reviewed priority and fails closed', async () => {
  const engine = await createFixture();
  try {
    const result = await engine.doString(String.raw`
      setCharacter('character-permission', 'Permission')
      setSession(42, 'ACTIVE', 'character-permission')
      connectedPlayers = { '42' }
      permissionCatalog = { items = {
        { legacyGroup = 'owner', nativePermission = 'synex.owner',
          priority = 100, fallback = false },
        { legacyGroup = 'admin', nativePermission = 'synex.admin',
          priority = 50, fallback = false },
        { legacyGroup = 'moderator', nativePermission = 'synex.moderator',
          priority = 10, fallback = false },
        { legacyGroup = 'user', nativePermission = 'synex.user',
          priority = 0, fallback = true },
      }, truncated = false }
      permissionAnswers = {
        ['synex.owner'] = false, ['synex.admin'] = true,
        ['synex.moderator'] = true,
      }

      local projection, projectionError = adapter:readPermissionGroups(
        'legacy_consumer', 42)
      assert(projection and projectionError == nil)
      assert(projection.primary == 'admin' and projection.fallback == 'user')
      assert(#projection.groups == 2)
      assert(projection.groups[1] == 'admin' and projection.groups[2] == 'moderator')
      assert(#permissionChecks == 3)
      for _, checked in ipairs(permissionChecks) do
        assert(checked.subject == 'character:character-permission')
      end

      local checksBeforeStale = #permissionChecks
      local stale, staleError = adapter:readPermissionGroups(
        'legacy_consumer', 42, {
          sessionId = 'session-42', sourceGeneration = 2,
          characterId = 'character-permission',
        })
      assert(stale == nil and staleError.code == 'COMPAT_STALE_SESSION')
      assert(#permissionChecks == checksBeforeStale)

      permissionCatalog = { items = {
        { legacyGroup = 'admin', nativePermission = 'synex.admin',
          priority = 50, fallback = false },
      }, truncated = false }
      local noFallback, noFallbackError = adapter:readPermissionGroups(
        'legacy_consumer', 42)
      assert(noFallback == nil and noFallbackError.code == 'COMPAT_MAPPING_MISSING')

      permissionCatalog = { items = {
        { legacyGroup = 'admin', nativePermission = 'synex.admin',
          priority = 50, fallback = false },
        { legacyGroup = 'owner', nativePermission = 'synex.owner',
          priority = 50, fallback = false },
        { legacyGroup = 'user', nativePermission = 'synex.user',
          priority = 0, fallback = true },
      }, truncated = false }
      permissionAnswers['synex.owner'] = true
      local tied, tiedError = adapter:readPermissionGroups('legacy_consumer', 42)
      assert(tied == nil and tiedError.code == 'COMPAT_MAPPING_AMBIGUOUS')

      permissionCatalog = { items = {
        { legacyGroup = 'user', nativePermission = 'synex.user',
          priority = 'zero', fallback = true },
      }, truncated = false }
      local malformed, malformedError = adapter:readPermissionGroups(
        'legacy_consumer', 42)
      assert(malformed == nil)
      assert(malformedError.code == 'COMPAT_PERMISSION_MAPPING_INVALID')

      deniedCapability = 'synex.permissions.read'
      local catalogCallsBeforeDenial = permissionCatalogCalls
      local denied, deniedError = adapter:readPermissionGroups('legacy_consumer', 42)
      assert(denied == nil and deniedError.code == 'CAPABILITY_DENIED')
      assert(permissionCatalogCalls == catalogCallsBeforeDenial)
      return table.concat({ projection.primary, projection.fallback,
        #projection.groups }, ':')
    `);
    assert.equal(result, 'admin:user:2');
  } finally {
    engine.global.close();
  }
});
