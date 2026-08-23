import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';

const root = process.cwd();

const identityModules = [
  'core/synex_core/shared/protocol.lua',
  'core/synex_core/server/factories.lua',
  'core/synex_core/server/foundation.lua',
  'core/synex_core/server/registries.lua',
  'core/synex_core/server/identity_common.lua',
  'core/synex_core/server/identity_session_fencing.lua',
  'core/synex_core/server/identity_repository.lua',
  'core/synex_core/server/identity_character_deletion_reconciliation.lua',
  'core/synex_core/server/identity_character_unloads.lua',
  'core/synex_core/server/identity_characters.lua',
  'core/synex_core/server/identity_connection_replacement.lua',
  'core/synex_core/server/identity_connection_claims.lua',
  'core/synex_core/server/identity_connection_authority.lua',
  'core/synex_core/server/identity_connection_ingress.lua',
  'core/synex_core/server/identity_connection_terminals.lua',
  'core/synex_core/server/identity_connection_join.lua',
  'core/synex_core/server/identity_connection_connecting.lua',
  'core/synex_core/server/identity_connection_heartbeat.lua',
  'core/synex_core/server/identity_connection_maintenance.lua',
  'core/synex_core/server/identity_connections.lua',
  'core/synex_core/server/identity.lua',
];

async function createIdentityEngine() {
  const engine = await new LuaFactory().createEngine();
  for (const relativePath of identityModules) {
    await engine.doString(await readFile(path.join(root, relativePath), 'utf8'));
  }
  return engine;
}

test('session persistence is atomically fenced by the current boot and cluster lease', async () => {
  const engine = await createIdentityEngine();
  try {
    const result = await engine.doString(`
      local currentBoot, calls, writes = 'boot-b', {}, 0
      local platform = {
        nowGame = function() return 1000 end, random = function() return 11 end,
        print = function() end, jsonEncode = function() return '{}' end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      local database = {
        withTransaction = function(_, handler)
          local committed = handler(function(sql, parameters)
            calls[#calls + 1] = { sql = sql, parameters = parameters }
            if sql:find('synex_instances', 1, true) then return {{ status = 'ready' }} end
            if sql:find('synex_instance_boots', 1, true) then
              return parameters[2] == currentBoot and {{ boot_id = currentBoot }} or {}
            end
            if sql:find('UPDATE \`synex_cluster_leases\`', 1, true) then
              return { affectedRows = 1 }
            end
            if sql:find('synex_cluster_leases', 1, true) then
              local name = parameters[1]
              return {{ owner_id = 'instance-a:session-a',
                fencing_token = name == 'admission:user-a' and 4 or 9, valid = 1 }}
            end
            assert(sql:find('INSERT INTO', 1, true) and sql:find('synex_sessions', 1, true))
            writes = writes + 1
            return 1
          end)
          return committed, committed and nil or { code = 'TRANSACTION_REJECTED' }
        end
      }
      local repositories = SynexCoreFactories.identityRepository({
        platform = platform, foundation = foundation, database = database,
        players = registries.players, config = {}, instanceId = 'instance-a',
        normalizeIdentifiers = function() return {} end
      })
      local session = {
        id = 'session-a', userId = 'user-a', source = 42, sourceGeneration = 7,
        state = 'SELECTING_CHARACTER', version = 2,
        clusterLease = {
          name = 'session:user-a', owner = 'instance-a:session-a', fencingToken = 9,
          requesterInstanceId = 'instance-a', requesterBootId = 'boot-a'
        },
        admissionGateLease = {
          name = 'admission:user-a', owner = 'instance-a:session-a', fencingToken = 4,
          requesterInstanceId = 'instance-a', requesterBootId = 'boot-a'
        }
      }
      local created, createError = repositories.sessions:create(session)
      assert(created == nil and createError.code == 'ADMISSION_GATE_LOST')
      assert(#calls == 2 and calls[1].sql:find("'ready'", 1, true)
        and calls[1].sql:find('FOR UPDATE', 1, true))
      assert(calls[2].sql:find('synex_instance_boots', 1, true)
        and calls[2].sql:find('FOR UPDATE', 1, true))
      session.clusterLease.requesterBootId = 'boot-b'
      session.admissionGateLease.requesterBootId = 'boot-b'
      local persisted, persistenceError = repositories.sessions:create(session)
      assert(persisted, persistenceError and persistenceError.code)
      assert(#calls == 10 and calls[3].sql:find('synex_instances', 1, true)
        and calls[4].sql:find('synex_instance_boots', 1, true)
        and calls[5].sql:find('synex_cluster_leases', 1, true)
        and calls[5].sql:find('FOR UPDATE', 1, true)
        and calls[8].parameters[1] == session.clusterLease.name
        and calls[9].sql:find('INSERT INTO', 1, true)
        and calls[9].sql:find('synex_sessions', 1, true)
        and calls[10].sql:find('UPDATE', 1, true)
        and calls[10].parameters[1] == session.admissionGateLease.name)
      assert(calls[5].parameters[1] == session.admissionGateLease.name
        and calls[9].parameters[1] == session.id and calls[9].parameters[3] == 'instance-a')
      local missing = foundation.copy(session)
      missing.clusterLease.requesterBootId = nil
      local rejected, missingError = repositories.sessions:create(missing)
      assert(rejected == nil and missingError.code == 'LEASE_LOST' and writes == 1 and #calls == 10)
      return table.concat({calls[4].parameters[2], calls[5].parameters[1],
        calls[9].parameters[1], writes}, ':')
    `);
    assert.equal(result, 'boot-b:admission:user-a:session-a:1');
  } finally {
    engine.global.close();
  }
});

test('connection terminal ownership is exactly once across an acceptance cleanup interleave', async () => {
  const engine = await createIdentityEngine();
  try {
    const result = await engine.doString(`
      local events, cancellation = {}, nil
      local platform = {
        nowGame = function() return 1000 end, random = function() return 13 end,
        print = function() end,
        defer = function() events[#events + 1] = 'tick' end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      local terminals = nil
      terminals = SynexCoreFactories.identityConnectionTerminals({
        platform = platform,
        foundation = foundation,
        acceptanceRejection = function()
          events[#events + 1] = 'acceptance-check'
          cancellation = terminals:cancelAll()
          return nil, nil
        end,
        logConnectionStage = function(_, stage, code)
          events[#events + 1] = stage .. ':' .. tostring(code)
        end
      })
      local terminal = assert(terminals:open({ id = 'connection-a', receivedAt = 1000 }, {
        done = function(...)
          events[#events + 1] = 'done:' .. tostring(select(1, ...))
        end
      }))
      assert(terminal:arm())
      local completed = terminal:finish()
      assert(completed == true and cancellation.cancelled == 1
        and cancellation.pending == 1 and cancellation.failures == 0)
      assert(terminal.state == 'rejected' and terminal.attempted == true and terminal.acceptance == false)
      assert(terminals:count() == 0 and terminal:finish() == false)
      local doneCalls = 0
      for _, event in ipairs(events) do if event:find('done:', 1, true) == 1 then doneCalls = doneCalls + 1 end end
      assert(doneCalls == 1 and events[1] == 'tick' and events[2] == 'acceptance-check')
      assert(events[3]:find('[CORE_STOPPING]', 1, true))
      return table.concat(events, '|')
    `);
    assert.match(result, /^tick\|acceptance-check\|done:Synex \[CORE_STOPPING\]/u);
  } finally {
    engine.global.close();
  }
});

test('connection terminals accept Cfx-style callable funcrefs and userdata', async () => {
  const engine = await createIdentityEngine();
  await engine.global.set('cfxDeferrals', {});
  await engine.global.set('cfxDoneRef', {});
  try {
    const result = await engine.doString(`
      local doneCalls, updateCalls, completionReason = 0, 0, nil
      local platform = {
        nowGame = function() return 1000 end, random = function() return 13 end,
        print = function() end, defer = function() end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      local terminals = SynexCoreFactories.identityConnectionTerminals({
        platform = platform, foundation = foundation,
        acceptanceRejection = function() return nil, nil end,
        logConnectionStage = function() end
      })
      local updateRef = setmetatable({ __cfx_functionReference = 'fixture-update' }, {
        __call = function(_, message)
          updateCalls = updateCalls + 1
          assert(message == 'Synex: checking connection...')
        end
      })
      debug.setmetatable(cfxDoneRef, {
        __metatable = 'protected-cfx-funcref',
        __call = function(_, reason)
          doneCalls = doneCalls + 1
          completionReason = reason
        end
      })
      debug.setmetatable(cfxDeferrals, {
        __metatable = 'protected-cfx-deferrals',
        __index = { update = updateRef, done = cfxDoneRef }
      })

      assert(type(cfxDeferrals) == 'userdata' and type(cfxDoneRef) == 'userdata')
      assert(type(getmetatable(cfxDeferrals)) == 'string'
        and type(getmetatable(cfxDoneRef)) == 'string')
      local terminal, terminalError = terminals:open({ id = 'connection-cfx' }, cfxDeferrals)
      assert(terminal ~= nil and terminalError == nil)
      assert(terminal:arm())
      assert(terminal:update('Synex: checking connection...'))
      assert(terminal:arm())
      assert(terminal:finish('Please reconnect.', 'FIXTURE_REJECTED'))
      assert(doneCalls == 1 and updateCalls == 1 and terminals:count() == 0)
      assert(terminal.state == 'rejected' and terminal:finish() == false)
      assert(completionReason:find('[FIXTURE_REJECTED]', 1, true))

      local invalidTable, invalidTableError = terminals:open(
        { id = 'connection-invalid-table' }, { done = {} })
      assert(invalidTable == nil and invalidTableError.code == 'INVALID_CONNECTION_TERMINAL')
      debug.setmetatable(cfxDoneRef, { __metatable = 'protected-noncallable-userdata' })
      local invalidUserdata, invalidUserdataError = terminals:open(
        { id = 'connection-invalid-userdata' }, { done = cfxDoneRef })
      assert(invalidUserdata == nil and invalidUserdataError.code == 'INVALID_CONNECTION_TERMINAL')
      local privateAccessor = setmetatable({}, {
        __index = function() error('fixture-private-terminal-accessor') end
      })
      local invoked, inaccessible, inaccessibleError = foundation.safeCall(
        terminals.open, terminals, { id = 'connection-inaccessible' }, privateAccessor)
      assert(invoked == true and inaccessible == nil
        and inaccessibleError.code == 'INVALID_CONNECTION_TERMINAL')
      assert(not tostring(inaccessibleError.message):find('fixture-private', 1, true))
      assert(terminals:count() == 0)
      return table.concat({type(cfxDeferrals), type(cfxDoneRef), doneCalls, updateCalls}, ':')
    `);
    assert.equal(result, 'userdata:userdata:1:1');
  } finally {
    engine.global.close();
  }
});

test('connection terminal open failures stay structured and finalize the deferred join', async () => {
  const engine = await createIdentityEngine();
  try {
    const result = await engine.doString(`
      local tickCalls, cfxDeferCalls, doneCalls, cleanupCalls = 0, 0, 0, 0
      local completionReason = nil
      local platform = {
        nowGame = function() return 1000 end, random = function() return 29 end,
        print = function() end, defer = function() tickCalls = tickCalls + 1 end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('terminal-open-failure-test')
      local expectedError = foundation.error('CONNECTION_TERMINAL_EXISTS',
        'The connection already owns a terminal.')
      local handleConnecting = SynexCoreFactories.identityConnectionConnecting({
        platform = platform, foundation = foundation,
        players = {
          getPending = function() return nil end,
          removePending = function() return nil end
        },
        lifecycle = { core = { canAdmitPlayers = function() return true end } },
        config = { pendingTtlMs = 120000 },
        ingress = {
          begin = function(_, _, deferrals, checkpoint)
            checkpoint('ingress_deferral')
            deferrals.defer()
            checkpoint('ingress_reservation')
            return {'license:fixture'}, nil
          end
        },
        terminals = { open = function() return nil, expectedError end },
        authority = { isQuiesced = function() return false end },
        normalizeIdentifiers = function() return {} end,
        identifierFingerprint = function() return 'fixture-fingerprint' end,
        userRepository = {}, accessRepository = {},
        connectionPriority = function() return 0 end,
        syncPending = function() return true, nil end,
        waitForQueue = function() return true, nil end,
        releaseAdmission = function() end,
        abandonConnection = function() cleanupCalls = cleanupCalls + 1 end,
        orderedGates = function() return {} end,
        invokeOwned = function() return true, true, nil end,
        releaseConnectionLease = function() return true, nil end,
        replacements = {}, duplicatePolicy = 'deny_new',
        logConnectionStage = function() end,
        pendingIsCurrent = function() return true end,
        aceAllowed = function() return false end
      })
      local connected, connectionError = handleConnecting(-22, 'Private Player', {
        defer = function() cfxDeferCalls = cfxDeferCalls + 1 end,
        update = function() end,
        done = function(reason)
          doneCalls = doneCalls + 1
          completionReason = reason
        end
      })
      assert(connected == nil and connectionError == expectedError
        and connectionError.code == 'CONNECTION_TERMINAL_EXISTS')
      assert(cfxDeferCalls == 1 and tickCalls == 1 and cleanupCalls == 1 and doneCalls == 1)
      assert(completionReason:find('[CONNECTION_TERMINAL_EXISTS]', 1, true))
      assert(not completionReason:find('Private Player', 1, true))
      return table.concat({connectionError.code, cfxDeferCalls, tickCalls, cleanupCalls, doneCalls}, ':')
    `);
    assert.equal(result, 'CONNECTION_TERMINAL_EXISTS:1:1:1:1');
  } finally {
    engine.global.close();
  }
});

test('connection terminals reject queued updates and recover when a finish tick cannot be scheduled', async () => {
  const engine = await createIdentityEngine();
  try {
    const result = await engine.doString(`
      local doneCalls, updateCalls = 0, 0
      local platform = {
        nowGame = function() return 1000 end, random = function() return 13 end,
        print = function() end,
        defer = function() error('fixture-private-defer-error') end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      local terminals = SynexCoreFactories.identityConnectionTerminals({
        platform = platform, foundation = foundation,
        acceptanceRejection = function() return nil, nil end,
        logConnectionStage = function() end
      })
      local terminal = assert(terminals:open({ id = 'connection-a' }, {
        update = function() updateCalls = updateCalls + 1 end,
        done = function(reason)
          doneCalls = doneCalls + 1
          assert(type(reason) == 'string' and reason:find('[FIXTURE_REJECTED]', 1, true))
        end
      }))
      assert(terminal:arm())
      local finished, finishError = terminal:finish('Please reconnect.', 'FIXTURE_REJECTED')
      assert(finished == true and finishError == nil)
      assert(doneCalls == 1 and terminals:count() == 0 and terminal.state == 'rejected')

      platform.defer = function() end
      local queued = assert(terminals:open({ id = 'connection-b' }, {
        update = function() updateCalls = updateCalls + 1 end,
        done = function() doneCalls = doneCalls + 1 end
      }))
      assert(queued:arm())
      assert(terminals:quiesce())
      assert(queued:update('must not be emitted') == false and updateCalls == 0)
      platform.defer()
      local drained = assert(terminals:flushQuiesced())
      assert(drained.completed == 1 and drained.remaining == 0 and doneCalls == 2)

      local failingTerminals = SynexCoreFactories.identityConnectionTerminals({
        platform = platform, foundation = foundation,
        acceptanceRejection = function() return nil, nil end,
        logConnectionStage = function() end
      })
      local failing = assert(failingTerminals:open({ id = 'connection-c' }, {
        done = function() error('fixture-private-terminal-error') end
      }))
      assert(failing:arm() and failingTerminals:quiesce())
      local failedFlush = assert(failingTerminals:flushReadyQuiesced())
      assert(failedFlush.completed == 0 and failedFlush.failures == 1
        and failedFlush.remaining == 0 and failing.state == 'failed')
      return table.concat({doneCalls, updateCalls, terminal.state, queued.state,
        failedFlush.failures}, ':')
    `);
    assert.equal(result, '2:0:rejected:rejected:1');
  } finally {
    engine.global.close();
  }
});

test('quiesced deferral terminals flush only after their required tick barrier', async () => {
  const engine = await createIdentityEngine();
  try {
    const result = await engine.doString(`
      local doneCalls, inTick, doneDuringTick = 0, false, false
      local platform = {
        nowGame = function() return 1000 end, random = function() return 17 end,
        print = function() end,
        defer = function() inTick = true; inTick = false end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      local terminals = SynexCoreFactories.identityConnectionTerminals({
        platform = platform, foundation = foundation,
        acceptanceRejection = function() return nil, nil end,
        logConnectionStage = function() end
      })
      local terminal = assert(terminals:open({ id = 'connection-a' }, {
        done = function()
          doneCalls = doneCalls + 1
          doneDuringTick = doneDuringTick or inTick
        end
      }))
      local requested = terminals:quiesce()
      assert(requested.requested == 1 and requested.pending == 1)
      assert(doneCalls == 0 and terminals:count() == 1)
      platform.defer()
      local flushed = assert(terminals:flushQuiesced())
      assert(flushed.completed == 1 and flushed.failures == 0 and flushed.remaining == 0)
      assert(doneCalls == 1 and doneDuringTick == false and terminal.state == 'rejected')

      local late = assert(terminals:open({ id = 'connection-b' }, {
        done = function() doneCalls = doneCalls + 1 end
      }))
      local emptyFlush = assert(terminals:flushQuiesced())
      assert(emptyFlush.completed == 0 and emptyFlush.remaining == 1 and doneCalls == 1)
      platform.defer()
      assert(late:afterTick())
      assert(doneCalls == 2 and late.state == 'rejected' and terminals:count() == 0)
      return table.concat({requested.requested, flushed.completed, emptyFlush.remaining, doneCalls}, ':')
    `);
    assert.equal(result, '1:1:1:2');
  } finally {
    engine.global.close();
  }
});

test('replace_old fences a reused player source before dropping the previous authority', async () => {
  const engine = await createIdentityEngine();
  try {
    const result = await engine.doString(`
      local now, released, acquired, purged = 1000, 0, 0, 0
      local blockedCharacterMutations, joinFlagObserved = 0, false
      local dropped, completed, completionCalls, completionArity = {}, nil, 0, nil
      local stages = {}
      local platform = {
        nowGame = function() now = now + 1 return now end,
        random = function(_, maximum) return math.min(maximum or 1, 17) end,
        print = function() end,
        jsonEncode = function() return '{}' end,
        jsonDecode = function() return {} end,
        getPlayerIdentifiers = function() return {'license:fixture'} end,
        wait = function(delay) now = now + delay end,
        defer = function() end,
        dropPlayer = function(playerSource, reason) dropped[playerSource] = reason end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('identity-test')
      function foundation.logger:write(_, message, fields)
        if message == 'connection stage' then
          assert(type(fields.correlationId) == 'string' and fields.correlationId ~= '')
          assert(fields.source == nil and fields.userId == nil and fields.identifiers == nil
            and fields.playerName == nil and fields.error == nil)
          stages[#stages + 1] = fields.stage
        end
      end
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      local players, owners = registries.players, registries.owners
      owners:activate('synex_core')
      assert(players:createPending(-1, { sessionId = 'old-session' }))
      assert(players:bindJoined(-1, 41, {
        id = 'old-session', userId = 'user-fixture', state = 'SELECTING_CHARACTER',
        version = 2, persistedVersion = 2, persistedSource = 41,
        persistedSourceGeneration = 1,
        clusterLease = { leaseName = 'session:user-fixture', owner = 'old-owner', fencingToken = 1 },
        clusterLeaseDeadlineAt = 26000, authorityDeadlineAt = 26000
      }))

      local identity, currentLease = nil, nil
      local database = {}
      function database:query(sql)
        if sql:find('SELECT DISTINCT', 1, true) then
          return {{
            id = 'user-fixture', status = 'active', locale = 'en',
            metadata_json = '{}', version = 1
          }}, nil
        end
        return {}, nil
      end
      function database:update(sql)
        if sql:find('INSERT INTO \`synex_sessions\`', 1, true) then
          local visible = assert(players:getBySource(42))
          assert(visible.persistencePending == true)
          joinFlagObserved = true
          local _, createError = identity.characters:create(visible.id, {})
          local _, deleteError = identity.characters:delete(visible.id, 'character-fixture')
          local _, selectError = identity.characters:select(visible.id, 'character-fixture')
          assert(createError.code == 'SESSION_PERSISTENCE_PENDING')
          assert(deleteError.code == 'SESSION_PERSISTENCE_PENDING')
          assert(selectError.code == 'SESSION_PERSISTENCE_PENDING')
          blockedCharacterMutations = blockedCharacterMutations + 3
        end
        return 1, nil
      end
      function database:insert()
        return 1, nil
      end
      function database:withTransaction(handler)
        local committed = handler(function(sql, parameters)
          if sql:find('synex_instances', 1, true) then return {{ status = 'ready' }} end
          if sql:find('synex_instance_boots', 1, true) then return {{ boot_id = 'boot-a' }} end
          if sql:find('UPDATE \`synex_cluster_leases\`', 1, true) then
            return { affectedRows = 1 }
          end
          if sql:find('synex_cluster_leases', 1, true) then
            return {{ owner_id = currentLease.owner, fencing_token = currentLease.fencingToken, valid = 1 }}
          end
          if sql:find('SELECT', 1, true) and sql:find('synex_sessions', 1, true) then
            return {{ id = 'old-session', user_id = 'user-fixture',
              server_instance_id = 'instance-a', source_value = 41,
              source_generation = 1, closed_at = nil }}
          end
          return assert(database:update(sql, parameters))
        end)
        return committed, committed and nil or { code = 'TRANSACTION_REJECTED' }
      end

      local leases = {}
      function leases:acquire(name, owner, ttl, requesterInstanceId, requesterBootId)
        acquired = acquired + 1
        currentLease = { leaseName = name, owner = owner, fencingToken = 2, ttl = ttl,
          requesterInstanceId = requesterInstanceId, requesterBootId = requesterBootId }
        return currentLease
      end
      function leases:release()
        released = released + 1
        return true, nil
      end
      function leases:renew(lease) return lease, nil end

      local instances = {}
      function instances:bootId() return 'boot-a', nil end
      function instances:requestRemoteKicks() return 0, nil end
      function instances:hasOpenUserSessions() return false, nil end
      function instances:touchSessions() return true, nil end
      function instances:heartbeat() return {}, nil end
      function instances:pendingLocalControls() return {}, nil end
      function instances:completeControl() return true, nil end

      local config = {
        duplicatePolicy = 'replace_old', allowlistRequired = false, queueEnabled = false,
        pendingTtlMs = 120000, gateTimeoutMs = 10000, clusterSessionLeaseSeconds = 45
      }
      local rateLimiter = {
        consume = function() return true, nil end,
        purge = function() end
      }
      local function purgeSource(_, source, generation)
        purged = purged + 1
        if source == 41 then
          local previous = assert(players:getSession('old-session'))
          assert(players:getBySource(source) == nil and previous.source == nil)
          assert(previous.sourceGeneration > generation)
          assert(players:createPending(-99, { sessionId = 'replacement-session' }))
          assert(players:bindJoined(-99, source, {
            id = 'replacement-session', userId = 'replacement-user', state = 'ACTIVE',
            version = 1, persistedVersion = 1
          }))
        end
      end
      identity = SynexCoreFactories.identity({
        platform = platform,
        foundation = foundation,
        database = database,
        players = players,
        owners = owners,
        lifecycle = { core = { canAdmitPlayers = function() return true end } },
        messaging = { network = { purgeSource = purgeSource } },
        config = config,
        instanceId = 'instance-a',
        coreResource = 'synex_core',
        leases = leases,
        instances = instances,
        rateLimiter = rateLimiter,
        sha256 = function(value)
          local hash = 2166136261
          for index = 1, #value do hash = ((hash ~ value:byte(index)) * 16777619) & 0xffffffff end
          return string.rep(('%08x'):format(hash), 8)
        end
      })
      identity.connections:handleConnecting(-2, 'Fixture', {
        defer = function() end,
        update = function() end,
        done = function(...)
          completionCalls = completionCalls + 1
          completionArity = select('#', ...)
          local reason = ...
          completed = reason == nil and '<accepted>' or reason
        end
      })

      if completed ~= '<accepted>' then error('completed:' .. tostring(completed)) end
      if completionCalls ~= 1 or completionArity ~= 0 then
        error('completion:' .. tostring(completionCalls) .. ':' .. tostring(completionArity))
      end
      assert(players:getSession('old-session') == nil, 'old-session-retained')
      assert(type(dropped[41]) == 'string' and players:getBySource(41).userId == 'replacement-user',
        'replacement-source-invalid')
      assert(released == 1 and acquired == 2 and purged == 1,
        ('counts:%s:%s:%s'):format(released, acquired, purged))
      local pending = assert(players:getPending(-2))
      assert(pending.state == 'AUTHENTICATED', 'pending-state:' .. tostring(pending.state))
      assert(pending.clusterLease.fencingToken == 2,
        'pending-token:' .. tostring(pending.clusterLease.fencingToken))
      local joined = assert(identity.connections:handleJoining(42, -2))
      assert(joined.persistencePending == nil)
      assert(players:getBySource(42).state == 'SELECTING_CHARACTER')
      assert(players:getBySource(42).persistencePending == nil)
      assert(joinFlagObserved and blockedCharacterMutations == 3)
      local expectedStages = {
        'received', 'identity_ok', 'access_ok', 'lease_acquired', 'deferral_accepted',
        'player_joining_received', 'join_identity_verified', 'join_lease_verified', 'session_opened'
      }
      for index, stage in ipairs(expectedStages) do assert(stages[index] == stage) end

      config.duplicatePolicy = 'allow'
      function foundation.logger:write() error('fixture-post-terminal-logger') end
      function foundation.metrics:increment() error('fixture-post-terminal-metric') end
      function foundation.metrics:observe() error('fixture-post-terminal-metric') end
      function foundation.metrics:gauge() error('fixture-post-terminal-metric') end
      local secondArity = nil
      assert(identity.connections:handleConnecting(-3, 'Fixture', {
        defer = function() end, update = function() end,
        done = function(...) secondArity = select('#', ...) end
      }))
      assert(secondArity == 0 and players:getPending(-3) ~= nil)
      now = now + config.pendingTtlMs + 1
      assert(identity.connections:purgeExpired(1) == 1)
      assert(players:getPending(-3) == nil and released == 3 and acquired == 4)
      return table.concat({completed, released, acquired, purged,
        blockedCharacterMutations, tostring(joinFlagObserved)}, ':')
    `);
    assert.equal(result, '<accepted>:3:4:1:3:true');
  } finally {
    engine.global.close();
  }
});

test('replace_old retains failed durable closes for bounded heartbeat reconciliation', async () => {
  const engine = await createIdentityEngine();
  try {
    const result = await engine.doString(`
      local function runCase(kind)
        local now, released, acquired, unloads, closes, renewals = 1000, 0, 0, 0, 0, 0
        local workerCalls, dropCalls = 0, 0
        local closeFails = kind == 'close' or kind == 'quiesce'
        local connection, releaseHook = nil, nil
        local completion = nil
        local platform = {
          nowGame = function() now = now + 1 return now end,
          random = function(_, maximum) return math.min(maximum or 1, 19) end,
          print = function() end, jsonEncode = function() return '{}' end,
          getPlayerIdentifiers = function() return {'license:fixture'} end,
          wait = function(delay) now = now + delay end, defer = function() end,
          dropPlayer = function() dropCalls = dropCalls + 1 end
        }
        local foundation = SynexCoreFactories.foundation({ platform = platform })
        foundation.configureIds('replace-failure-' .. kind)
        local registries = SynexCoreFactories.registries({ foundation = foundation })
        local players, owners = registries.players, registries.owners
        owners:activate('synex_core')
        assert(players:createPending(-1, { sessionId = 'old-' .. kind }))
        assert(players:bindJoined(-1, 41, {
          id = 'old-' .. kind, userId = 'user-fixture', state = 'ACTIVE',
          characterId = 'character-' .. kind, version = 2, persistedVersion = 2,
          clusterLease = { name = 'session:user-fixture', owner = 'old-owner',
            fencingToken = 1, ttlSeconds = 45 },
          clusterLeaseDeadlineAt = now + 25000, authorityDeadlineAt = now + 25000
        }))
        local characters = {}
        function characters:unload(sessionId)
          unloads = unloads + 1
          local detached = assert(players:getSession(sessionId))
          assert(detached.source == nil and players:getBySource(41) == nil)
          assert(players:createPending(-99, { sessionId = 'replacement-' .. kind }))
          assert(players:bindJoined(-99, 41, {
            id = 'replacement-' .. kind, userId = 'replacement-user', state = 'ACTIVE',
            version = 1, persistedVersion = 1
          }))
          if kind == 'unload' then
            return nil, foundation.error('UNLOAD_FAILED', 'fixture unload failure')
          end
          return true, nil
        end
        connection = SynexCoreFactories.identityConnections({
          platform = platform, foundation = foundation, players = players, owners = owners,
          lifecycle = { core = {
            canAdmitPlayers = function() return true end,
            setHealth = function() end
          } },
          messaging = { network = { purgeSource = function() end } },
          config = { duplicatePolicy = 'replace_old', queueEnabled = false,
            pendingTtlMs = 120000, clusterSessionLeaseSeconds = 45 },
          instanceId = 'instance-a',
          leases = {
            acquire = function(_, name, owner, ttl, requesterInstanceId, requesterBootId)
              acquired = acquired + 1
              return { name = name, owner = owner, fencingToken = acquired,
                ttlSeconds = ttl, requesterInstanceId = requesterInstanceId,
                requesterBootId = requesterBootId }, nil
            end,
            release = function()
              released = released + 1
              if releaseHook then local hook = releaseHook; releaseHook = nil; hook() end
              return true, nil
            end,
            renew = function()
              renewals = renewals + 1
              return true, nil
            end
          },
          instances = {
            bootId = function() workerCalls = workerCalls + 1 return 'boot-a', nil end,
            requestRemoteKicks = function() workerCalls = workerCalls + 1 return 0, nil end,
            hasOpenUserSessions = function() workerCalls = workerCalls + 1 return false, nil end,
            touchSessions = function() workerCalls = workerCalls + 1 return true, nil end,
            heartbeat = function() workerCalls = workerCalls + 1 return {}, nil end,
            pendingLocalControls = function() workerCalls = workerCalls + 1 return {}, nil end,
            completeControl = function() workerCalls = workerCalls + 1 return true, nil end
          },
          characters = characters,
          userRepository = {
            authenticate = function() return { id = 'user-fixture', status = 'active' }, nil end,
            findByIdentifiers = function() return { id = 'user-fixture', status = 'active' }, nil end
          },
          sessionRepository = {
            create = function() return true, nil end,
            close = function()
              closes = closes + 1
              if kind == 'quiesce' and closes == 2 then
                closeFails = false
                assert(connection:quiesce())
                return true, nil
              end
              if closeFails then
                return nil, foundation.error('CLOSE_FAILED', 'fixture close failure')
              end
              return true, nil
            end
          },
          accessRepository = { check = function() return true, nil end },
          rateLimiter = { consume = function() return true, nil end, purge = function() end },
          invokeOwned = function() return true, true, nil end,
          normalizeIdentifiers = function()
            return {{ type = 'license', value = 'fixture', normalized = 'license:fixture' }}
          end,
          sha256 = function(value)
            local hash = 2166136261
            for index = 1, #value do hash = ((hash ~ value:byte(index)) * 16777619) & 0xffffffff end
            return string.rep(('%08x'):format(hash), 8)
          end,
          sessionTransitions = { ACTIVE = { DISCONNECTING = true } },
          transition = function(session, target) session.state = target return session, nil end
        })
        assert(connection:handleConnecting(-2, 'Fixture', {
          defer = function() end, update = function() end,
          done = function(reason) completion = reason end
        }))
        assert(type(completion) == 'string'
          and completion:find('[SESSION_REPLACE_FAILED]', 1, true))
        assert(players:getBySource(41).id == 'replacement-' .. kind)
        assert(players:getPending(-2) == nil)
        assert(acquired == 1 and unloads == 1 and closes == 1)
        if kind == 'unload' then
          assert(players:getSession('old-' .. kind) == nil and released == 2)
          return kind .. ':' .. released .. ':' .. players:getBySource(41).userId
        end

        local tombstone = assert(players:getSession('old-' .. kind))
        assert(tombstone.source == nil and tombstone.replacementClosePending == true)
        assert(tombstone.clusterLease.owner == 'old-owner' and released == 1)
        if kind == 'quiesce' then
          local dropsBeforeHeartbeat = dropCalls
          local heartbeatHealthy, heartbeatError = connection:heartbeat()
          assert(heartbeatHealthy, heartbeatError and heartbeatError.code)
          assert(connection:snapshot().quiesced == true and closes == 2,
            table.concat({tostring(connection:snapshot().quiesced), closes}, ':'))
          assert(players:getSession('old-quiesce').replacementClosePending == true,
            'quiesce tombstone missing')
          assert(released == 1 and renewals == 0 and workerCalls == 1
            and dropCalls == dropsBeforeHeartbeat,
            table.concat({released, renewals, workerCalls, dropCalls, dropsBeforeHeartbeat}, ':'))
          assert(connection:heartbeat())
          assert(closes == 2 and released == 1 and renewals == 0 and workerCalls == 1)
          return kind .. ':' .. closes .. ':' .. renewals .. ':' .. workerCalls
        end
        local heartbeatHealthy, heartbeatError = connection:heartbeat()
        assert(heartbeatHealthy, heartbeatError and heartbeatError.code)
        tombstone = assert(players:getSession('old-close'))
        assert(tombstone.source == nil and tombstone.replacementClosePending == true)
        assert(closes == 2 and renewals == 1 and released == 1)
        assert(players:getBySource(41).id == 'replacement-close')

        closeFails = false
        releaseHook = function() assert(connection:heartbeat()) end
        assert(connection:heartbeat())
        assert(players:getSession('old-close') == nil and released == 2)
        assert(players:getBySource(41).id == 'replacement-close')
        assert(closes == 3 and renewals == 1)
        assert(connection:heartbeat())
        assert(closes == 3 and renewals == 1 and released == 2)
        return kind .. ':' .. released .. ':' .. closes .. ':' .. renewals .. ':'
          .. players:getBySource(41).userId
      end
      return runCase('unload') .. '|' .. runCase('close') .. '|' .. runCase('quiesce')
    `);
    assert.equal(result,
      'unload:2:replacement-user|close:2:3:1:replacement-user|quiesce:2:0:1');
  } finally {
    engine.global.close();
  }
});

test('replacement cleanup treats an absent durable session row as already closed', async () => {
  const engine = await createIdentityEngine();
  try {
    const result = await engine.doString(`
      local releases, closes, reads = 0, 0, 0
      local platform = {
        nowGame = function() return 1000 end, random = function() return 23 end,
        print = function() end, dropPlayer = function() end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      local players = registries.players
      assert(players:createPending(-1, { sessionId = 'old-missing' }))
      local old = assert(players:bindJoined(-1, 41, {
        id = 'old-missing', userId = 'user-missing', state = 'SELECTING_CHARACTER',
        version = 2, persistedVersion = 2,
        clusterLease = { name = 'session:user-missing', owner = 'old-owner',
          fencingToken = 4, ttlSeconds = 45 },
        clusterLeaseDeadlineAt = 26000, authorityDeadlineAt = 26000
      }))
      local replacement = SynexCoreFactories.identityConnectionReplacement({
        platform = platform, foundation = foundation, players = players,
        messaging = { network = { purgeSource = function(_, source, generation)
          assert(source == 41 and generation == old.sourceGeneration)
          assert(players:getBySource(41) == nil)
          assert(players:createPending(-2, { sessionId = 'new-source-owner' }))
          assert(players:bindJoined(-2, 41, {
            id = 'new-source-owner', userId = 'replacement-user', state = 'ACTIVE',
            version = 1, persistedVersion = 1
          }))
        end } },
        characters = {},
        sessionRepository = {
          close = function()
            closes = closes + 1
            return nil, foundation.error('SESSION_CONFLICT', 'fixture conflict', { retryable = true })
          end,
          getState = function()
            reads = reads + 1
            return nil, foundation.error('SESSION_NOT_FOUND', 'fixture missing')
          end
        },
        releaseConnectionLease = function(session)
          releases = releases + 1
          assert(session.id == 'old-missing' and session.source == nil)
          return true, nil
        end
      })
      assert(replacement:replace('user-missing'))
      assert(players:getSession('old-missing') == nil)
      assert(players:getBySource(41).id == 'new-source-owner')
      local report = assert(replacement:reconcile(1))
      assert(report.examined == 0 and report.pending == 0)
      return table.concat({releases, closes, reads, players:getBySource(41).userId}, ':')
    `);
    assert.equal(result, '1:1:1:replacement-user');
  } finally {
    engine.global.close();
  }
});

test('replacement cleanup stops every local side effect when quiesce wins a yielded boundary', async () => {
  const engine = await createIdentityEngine();
  try {
    const result = await engine.doString(`
      local function runCase(kind)
        local quiesced = false
        local purges, drops, unloads, closes, releases = 0, 0, 0, 0, 0
        local platform = {
          nowGame = function() return 1000 end, random = function() return 31 end,
          print = function() end,
          dropPlayer = function() drops = drops + 1 end
        }
        local foundation = SynexCoreFactories.foundation({ platform = platform })
        local players = SynexCoreFactories.registries({ foundation = foundation }).players
        local function bind(tempSource, source, id)
          assert(players:createPending(tempSource, { sessionId = id }))
          assert(players:bindJoined(tempSource, source, {
            id = id, userId = 'user-old', state = 'ACTIVE', version = 1, persistedVersion = 1,
            clusterLease = { name = 'session:user-old:' .. id, owner = id,
              fencingToken = 1, ttlSeconds = 45 },
            clusterLeaseDeadlineAt = 26000, authorityDeadlineAt = 26000
          }))
        end
        bind(-1, 41, 'a-old')
        bind(-2, 42, 'b-old')
        local replacement = SynexCoreFactories.identityConnectionReplacement({
          platform = platform, foundation = foundation, players = players,
          messaging = { network = { purgeSource = function()
            purges = purges + 1
            if kind == 'purge' then
              assert(players:createPending(-3, { sessionId = 'new-source-owner' }))
              assert(players:bindJoined(-3, 41, {
                id = 'new-source-owner', userId = 'user-new', state = 'ACTIVE',
                version = 1, persistedVersion = 1
              }))
              quiesced = true
            end
          end } },
          characters = { unload = function()
            unloads = unloads + 1
            if kind == 'unload' then quiesced = true end
            return true, nil
          end },
          sessionRepository = { close = function()
            closes = closes + 1
            if kind == 'close' then quiesced = true end
            return true, nil
          end },
          releaseConnectionLease = function() releases = releases + 1 return true, nil end,
          isQuiesced = function() return quiesced end
        })
        local replaced, replaceError = replacement:replace('user-old')
        assert(replaced == nil and replaceError.code == 'CORE_STOPPING')
        assert(players:getBySource(42).id == 'b-old')
        if kind == 'purge' then
          assert(players:getBySource(41).id == 'new-source-owner')
          assert(purges == 1 and drops == 0 and unloads == 0 and closes == 0 and releases == 0)
        elseif kind == 'unload' then
          assert(players:getBySource(41) == nil)
          assert(purges == 1 and drops == 1 and unloads == 1 and closes == 0 and releases == 0)
        else
          assert(players:getBySource(41) == nil)
          assert(purges == 1 and drops == 1 and unloads == 1 and closes == 1 and releases == 0)
        end
        return table.concat({kind, purges, drops, unloads, closes, releases}, ':')
      end
      return runCase('purge') .. '|' .. runCase('unload') .. '|' .. runCase('close')
    `);
    assert.equal(result, 'purge:1:0:0:0:0|unload:1:1:1:0:0|close:1:1:1:1:0');
  } finally {
    engine.global.close();
  }
});

test('replacement close tombstones reject every character mutation while reconciliation is pending', async () => {
  const engine = await createIdentityEngine();
  try {
    const result = await engine.doString(`
      local platform = {
        nowGame = function() return 1000 end, random = function() return 29 end,
        print = function() end, jsonEncode = function() return '{}' end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      local players, owners = registries.players, registries.owners
      owners:activate('synex_core')
      assert(players:createPending(-1, { sessionId = 'replacement-tombstone' }))
      assert(players:bindJoined(-1, 41, {
        id = 'replacement-tombstone', userId = 'user-tombstone',
        state = 'SELECTING_CHARACTER', version = 2, persistedVersion = 2,
        replacementClosePending = true
      }))
      local characters = SynexCoreFactories.identityCharacters({
        platform = platform, foundation = foundation, database = {},
        players = players, owners = owners,
        messaging = { hooks = {}, events = {} }, coreResource = 'synex_core',
        characterRepository = {}, sessionRepository = {},
        invokeOwned = function() error('fixture mutation escaped tombstone guard') end,
        transition = function() error('fixture mutation escaped tombstone guard') end,
        leases = {}, instances = { bootId = function() return 'boot-a', nil end },
        instanceId = 'instance-a'
      })
      local _, createError = characters:create('replacement-tombstone', {})
      local _, deleteError = characters:delete('replacement-tombstone', 'character-a')
      local _, selectError = characters:select('replacement-tombstone', 'character-a')
      assert(players:bindCharacter('replacement-tombstone', 'character-a'))
      assert(players:updateSession('replacement-tombstone', function(candidate)
        candidate.state = 'ACTIVE'
      end))
      local _, unloadError = characters:unload('replacement-tombstone', 'fixture')
      assert(createError.code == 'SESSION_PERSISTENCE_PENDING')
      assert(deleteError.code == 'SESSION_PERSISTENCE_PENDING')
      assert(selectError.code == 'SESSION_PERSISTENCE_PENDING')
      assert(unloadError.code == 'SESSION_PERSISTENCE_PENDING')
      return table.concat({
        createError.code, deleteError.code, selectError.code, unloadError.code
      }, ':')
    `);
    assert.equal(result, [
      'SESSION_PERSISTENCE_PENDING', 'SESSION_PERSISTENCE_PENDING',
      'SESSION_PERSISTENCE_PENDING', 'SESSION_PERSISTENCE_PENDING',
    ].join(':'));
  } finally {
    engine.global.close();
  }
});

test('connection exceptions reject once with a stable code and release pending authority', async () => {
  const engine = await createIdentityEngine();
  try {
    const result = await engine.doString(`
      local now, completionCalls, completionArity, completionReason, released = 1000, 0, nil, nil, 0
      local deferCalls = 0
      local failureLogs = {}
      local platform = {
        nowGame = function() now = now + 1 return now end,
        random = function(_, maximum) return math.min(maximum or 1, 19) end,
        print = function() end, jsonEncode = function() return '{}' end,
        getPlayerIdentifiers = function() return {'license:fixture'} end,
        wait = function(delay) now = now + delay end,
        defer = function() deferCalls = deferCalls + 1 end,
        dropPlayer = function() end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('connection-failure-test')
      function foundation.logger:write(_, message, fields)
        if message == 'connection stage' then
          assert(type(fields.correlationId) == 'string')
          assert(fields.source == nil and fields.userId == nil and fields.identifiers == nil
            and fields.playerName == nil and fields.error == nil)
        elseif message == 'connection pipeline failed' then
          failureLogs[#failureLogs + 1] = foundation.copy(fields)
        end
      end
      local function assertFailureLog(fields, expectedStage)
        local allowed = { correlationId = true, code = true, stage = true, failureType = true }
        local count = 0
        for key, value in pairs(fields) do
          count = count + 1
          assert(allowed[key] == true)
          local rendered = tostring(value)
          assert(not rendered:find('fixture-private', 1, true)
            and not rendered:find('license:fixture', 1, true)
            and not rendered:find('Fixture', 1, true))
        end
        assert(count == 4 and type(fields.correlationId) == 'string')
        assert(fields.code == 'CONNECTION_PIPELINE_FAILED')
        assert(fields.stage == expectedStage and fields.failureType == 'string')
      end
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      local players, owners = registries.players, registries.owners
      local epoch = owners:activate('synex_core')
      local leases = {
        acquire = function(_, name, owner, ttl, requesterInstanceId, requesterBootId)
          return { leaseName = name, owner = owner, fencingToken = 1, ttl = ttl,
            requesterInstanceId = requesterInstanceId, requesterBootId = requesterBootId }, nil
        end,
        release = function() released = released + 1 return true, nil end
      }
      local connection = SynexCoreFactories.identityConnections({
        platform = platform, foundation = foundation, players = players, owners = owners,
        lifecycle = { core = { canAdmitPlayers = function() return true end } },
        messaging = { network = { purgeSource = function() end } },
        config = { duplicatePolicy = 'deny_new', queueEnabled = false, pendingTtlMs = 120000,
          gateTimeoutMs = 10000, clusterSessionLeaseSeconds = 45 },
        leases = leases, instanceId = 'instance-a', characters = {},
        rateLimiter = { consume = function() return true, nil end, purge = function() end },
        sha256 = function(value)
          local hash = 2166136261
          for index = 1, #value do hash = ((hash ~ value:byte(index)) * 16777619) & 0xffffffff end
          return string.rep(('%08x'):format(hash), 8)
        end,
        instances = {
          bootId = function() return 'boot-a', nil end,
          requestRemoteKicks = function() return 0, nil end,
          hasOpenUserSessions = function() return false, nil end
        },
        userRepository = { authenticate = function() return { id = 'user-fixture' }, nil end },
        sessionRepository = {}, accessRepository = { check = function() return true, nil end },
        invokeOwned = function() error('fixture-private-database-error') end,
        normalizeIdentifiers = function() return {{ type = 'license', value = 'fixture' }} end,
        sessionTransitions = {}, transition = function() return true, nil end
      })
      assert(connection:registerGate('synex_core', epoch, {
        name = 'fixture gate', priority = 0, timeoutMs = 1000, run = function() return true end
      }))
      local connected, connectionError = connection:handleConnecting(-2, 'Fixture', {
        defer = function() end, update = function() end,
        done = function(...)
          completionCalls = completionCalls + 1
          completionArity = select('#', ...)
          completionReason = ...
        end
      })
      assert(connected == nil and connectionError.code == 'CONNECTION_PIPELINE_FAILED')
      assert(completionCalls == 1 and completionArity == 1)
      assert(completionReason:find('[CONNECTION_PIPELINE_FAILED]', 1, true))
      assert(not completionReason:find('fixture-private', 1, true))
      assert(players:getPending(-2) == nil and released == 0)
      assert(connection:snapshot().admissionReservations == 0)
      assert(#failureLogs == 1)
      assertFailureLog(failureLogs[1], 'connection_gates')

      local beforeUpdateFailure = deferCalls
      completionCalls, completionArity, completionReason = 0, nil, nil
      local updateConnected, updateError = connection:handleConnecting(-3, 'Fixture', {
        defer = function() end,
        update = function() error('fixture-private-update-error') end,
        done = function(...)
          completionCalls = completionCalls + 1
          completionArity = select('#', ...)
          completionReason = ...
        end
      })
      assert(updateConnected == nil and updateError.code == 'CONNECTION_PIPELINE_FAILED')
      assert(completionCalls == 1 and completionArity == 1)
      assert(completionReason:find('[CONNECTION_PIPELINE_FAILED]', 1, true))
      assert(not completionReason:find('fixture-private', 1, true))
      assert(deferCalls - beforeUpdateFailure == 2)
      assert(players:getPending(-3) == nil and released == 0)
      assert(connection:snapshot().openDeferrals == 0
        and connection:snapshot().admissionReservations == 0)
      assert(#failureLogs == 2)
      assertFailureLog(failureLogs[2], 'deferral_authentication_update')

      return completionReason
    `);
    assert.match(result, /\[CONNECTION_PIPELINE_FAILED\]/);
    assert.doesNotMatch(result, /fixture-private/);
  } finally {
    engine.global.close();
  }
});

test('a failed accepted deferral terminal is attempted once and retained only until pending TTL cleanup', async () => {
  const engine = await createIdentityEngine();
  try {
    const result = await engine.doString(`
      local now, doneCalls, released = 1000, 0, 0
      local platform = {
        nowGame = function() return now end,
        random = function() return 23 end,
        print = function() end, jsonEncode = function() return '{}' end,
        getPlayerIdentifiers = function() return {'license:fixture'} end,
        wait = function(delay) now = now + delay end, defer = function() end,
        dropPlayer = function() end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('deferral-terminal-test')
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      registries.owners:activate('synex_core')
      local players = registries.players
      local connection = SynexCoreFactories.identityConnections({
        platform = platform, foundation = foundation, players = players, owners = registries.owners,
        instanceId = 'instance-a',
        lifecycle = { core = { canAdmitPlayers = function() return true end } },
        messaging = { network = { purgeSource = function() end } },
        config = { duplicatePolicy = 'deny_new', queueEnabled = false, pendingTtlMs = 120000,
          clusterSessionLeaseSeconds = 45, clusterHeartbeatMs = 10000 },
        leases = {
          acquire = function(_, name, owner, ttl, requesterInstanceId, requesterBootId)
            return { name = name, owner = owner, fencingToken = 1, ttlSeconds = ttl,
              requesterInstanceId = requesterInstanceId, requesterBootId = requesterBootId }, nil
          end,
          release = function() released = released + 1 return true, nil end,
          renew = function() return true, nil end
        },
        rateLimiter = { consume = function() return true, nil end, purge = function() end },
        sha256 = function(value)
          local hash = 2166136261
          for index = 1, #value do hash = ((hash ~ value:byte(index)) * 16777619) & 0xffffffff end
          return string.rep(('%08x'):format(hash), 8)
        end,
        instances = {
          bootId = function() return 'boot-a', nil end,
          requestRemoteKicks = function() return 0, nil end,
          hasOpenUserSessions = function() return false, nil end
        }, characters = {},
        userRepository = { authenticate = function() return { id = 'user-fixture', status = 'active' }, nil end },
        sessionRepository = {}, accessRepository = { check = function() return true, nil end },
        invokeOwned = function() return true, true, nil end,
        normalizeIdentifiers = function() return {{ type = 'license', value = 'fixture' }} end,
        sessionTransitions = {}, transition = function() return true, nil end
      })
      local connected, connectionError = connection:handleConnecting(-2, 'Fixture', {
        defer = function() end, update = function() end,
        done = function(...)
          doneCalls = doneCalls + 1
          assert(select('#', ...) == 0)
          error('fixture-private-terminal-error')
        end
      })
      assert(connected == nil and connectionError.code == 'DEFERRAL_TERMINATION_FAILED')
      assert(doneCalls == 1 and players:getPending(-2) ~= nil and released == 0)
      now = now + 120001
      assert(connection:purgeExpired(1) == 1)
      assert(players:getPending(-2) == nil and released == 2)
      return table.concat({doneCalls, released, connectionError.code}, ':')
    `);
    assert.equal(result, '1:2:DEFERRAL_TERMINATION_FAILED');
  } finally {
    engine.global.close();
  }
});

test('playerJoining rejects cross-pending hijack, replay, and source-local floods without consuming victim authority', async () => {
  const engine = await createIdentityEngine();
  try {
    const result = await engine.doString(`
      local now, released, persisted, identityReads = 1000, 0, 0, 0
      local sourceIdentities, lookupReuse, renewReuse, releaseReuse = {}, nil, nil, nil
      local sameIdentityReuse, sameIdentityResult = nil, nil
      local drops, dropOwners, rateBuckets, purgedRateKeys = {}, {}, {}, {}
      local function identityFor(source)
        if sourceIdentities[source] then return sourceIdentities[source] end
        if source == 99 then return 'attacker' end
        if source == 98 then return 'alternate' end
        return 'victim'
      end
      local platform = {
        nowGame = function() return now end, random = function() return 29 end,
        print = function() end, jsonEncode = function() return '{}' end,
        getPlayerIdentifiers = function(source) return {'license:' .. identityFor(source)} end,
        wait = function(delay) now = now + delay end, defer = function() end,
        dropPlayer = function(source, reason)
          drops[source] = drops[source] or {}
          drops[source][#drops[source] + 1] = reason
          dropOwners[source] = dropOwners[source] or {}
          dropOwners[source][#dropOwners[source] + 1] = identityFor(source)
        end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('join-boundary-test')
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      registries.owners:activate('synex_core')
      local players = registries.players
      local rateLimiter = {}
      function rateLimiter:consume(key)
        rateBuckets[key] = (rateBuckets[key] or 0) + 1
        if rateBuckets[key] > 4 then return nil, { code = 'RATE_LIMITED' } end
        return true, nil
      end
      function rateLimiter:purge(prefix) purgedRateKeys[#purgedRateKeys + 1] = prefix end
      local config = { duplicatePolicy = 'deny_new', queueEnabled = false, pendingTtlMs = 120000,
        clusterSessionLeaseSeconds = 45, clusterHeartbeatMs = 10000 }
      local connection = nil
      local userRepository = {}
      function userRepository:authenticate(raw)
        return { id = raw[1]:find('attacker', 1, true) and 'user-attacker' or 'user-victim', status = 'active' }, nil
      end
      function userRepository:findByIdentifiers(identifiers)
        identityReads = identityReads + 1
        local resolved = {
          id = identifiers[1].value == 'attacker' and 'user-attacker' or 'user-victim',
          status = 'active'
        }
        if lookupReuse then sourceIdentities[lookupReuse] = 'attacker'; lookupReuse = nil end
        if sameIdentityReuse then
          local reusedSource = sameIdentityReuse
          sameIdentityReuse = nil
          connection:handleDropped(reusedSource, 'same identity source reuse')
          local replacement, replacementError = connection:handleJoining(reusedSource, -3)
          sameIdentityResult = assert(replacement, replacementError and replacementError.code)
        end
        return resolved, nil
      end
      local function normalize(values)
        local value = values[1]:match('^[^:]+:(.+)$')
        return {{ type = 'license', value = value, normalized = 'license:' .. value }}
      end
      connection = SynexCoreFactories.identityConnections({
        platform = platform, foundation = foundation, players = players, owners = registries.owners,
        instanceId = 'instance-a',
        lifecycle = { core = {
          canAdmitPlayers = function() return true end, setHealth = function() end
        } },
        messaging = { network = { purgeSource = function() end } },
        config = config,
        leases = {
          acquire = function(_, name, owner, ttl, requesterInstanceId, requesterBootId)
            return { name = name, owner = owner, fencingToken = 7, ttlSeconds = ttl,
              requesterInstanceId = requesterInstanceId, requesterBootId = requesterBootId }, nil
          end,
          release = function()
            released = released + 1
            if releaseReuse then sourceIdentities[releaseReuse] = 'attacker'; releaseReuse = nil end
            return true, nil
          end,
          renew = function()
            if renewReuse then sourceIdentities[renewReuse] = 'attacker'; renewReuse = nil end
            return true, nil
          end
        },
        rateLimiter = rateLimiter,
        sha256 = function(value)
          local hash = 2166136261
          for index = 1, #value do hash = ((hash ~ value:byte(index)) * 16777619) & 0xffffffff end
          return string.rep(('%08x'):format(hash), 8)
        end,
        instances = {
          bootId = function() return 'boot-a', nil end,
          requestRemoteKicks = function() return 0, nil end,
          hasOpenUserSessions = function() return false, nil end
        }, characters = {},
        userRepository = userRepository,
        sessionRepository = {
          create = function() persisted = persisted + 1 return true, nil end,
          close = function() return true, nil end
        },
        accessRepository = { check = function() return true, nil end },
        invokeOwned = function() return true, true, nil end, normalizeIdentifiers = normalize,
        sessionTransitions = { SELECTING_CHARACTER = { DISCONNECTING = true } },
        transition = function(session, target)
          session.state = target
          session.version = (session.version or 0) + 1
          return session, nil
        end
      })
      local doneArity = nil
      local connected, connectError = connection:handleConnecting(-2, 'Victim', {
        defer = function() end, update = function() end,
        done = function(...) doneArity = select('#', ...) end
      })
      assert(connected, connectError and connectError.code)
      local accepted = assert(players:getPending(-2))
      assert(doneArity == 0 and accepted.userId == 'user-victim')

      local sameUser, sameUserError = connection:handleJoining(98, -2)
      assert(sameUser == nil and sameUserError.code == 'JOIN_IDENTITY_MISMATCH')
      assert(players:getPending(-2).id == accepted.id and #drops[98] == 1 and identityReads == 0)

      for attempt = 1, 4 do
        local joined, joinError = connection:handleJoining(99, -2)
        assert(joined == nil and joinError.code == 'JOIN_IDENTITY_MISMATCH')
        local preserved = assert(players:getPending(-2))
        assert(preserved.id == accepted.id and preserved.clusterLease.fencingToken == 7)
        assert(players:getBySource(99) == nil and released == 0)
      end
      local limited, limitedError = connection:handleJoining(99, -2)
      assert(limited == nil and limitedError.code == 'JOIN_RATE_LIMITED')
      assert(identityReads == 0 and #drops[99] == 5 and players:getPending(-2).id == accepted.id)

      config.duplicatePolicy = 'allow'
      local replacementAccepted = nil
      assert(connection:handleConnecting(-3, 'Replacement', {
        defer = function() end, update = function() end,
        done = function(reason) replacementAccepted = reason == nil end
      }))
      local replacementPending = assert(players:getPending(-3))
      assert(replacementAccepted and replacementPending.userId == accepted.userId)
      sameIdentityReuse = 95
      local sameIdentityStale, sameIdentityError = connection:handleJoining(95, -2)
      assert(sameIdentityStale == nil and sameIdentityError.code == 'JOIN_SOURCE_CHANGED')
      assert(sameIdentityResult.id == replacementPending.sessionId)
      assert(players:getBySource(95).id == replacementPending.sessionId and drops[95] == nil)
      assert(players:getPending(-2).id == accepted.id)
      connection:handleDropped(95, 'replacement fixture cleanup')
      assert(players:getBySource(95) == nil and released == 1)

      sourceIdentities[97], lookupReuse = 'victim', 97
      local lookupStale, lookupStaleError = connection:handleJoining(97, -2)
      assert(lookupStale == nil and lookupStaleError.code == 'JOIN_SOURCE_CHANGED')
      assert(drops[97] == nil and players:getPending(-2).id == accepted.id and released == 1)

      sourceIdentities[96], renewReuse = 'victim', 96
      local renewStale, renewStaleError = connection:handleJoining(96, -2)
      assert(renewStale == nil and renewStaleError.code == 'JOIN_SOURCE_CHANGED')
      assert(drops[96] == nil and players:getPending(-2).id == accepted.id and released == 1)

      local joined = assert(connection:handleJoining(42, -2))
      assert(joined.userId == 'user-victim' and players:getPending(-2) == nil)
      assert(players:getBySource(42).id == accepted.sessionId and persisted == 2 and identityReads == 5)
      local replay, replayError = connection:handleJoining(42, -2)
      assert(replay == nil and replayError.code == 'SOURCE_ALREADY_BOUND' and drops[42] == nil)
      connection:handleDropped(42, 'fixture')
      assert(released == 2 and purgedRateKeys[#purgedRateKeys] == 'join:42:')

      sourceIdentities[77], releaseReuse = 'victim', 77
      assert(players:createPending(-5, {
        id = 'expired-connection', sessionId = 'expired-session', tempSource = -5,
        state = 'AUTHENTICATED', userId = 'user-victim', receivedAt = now - 1,
        expiresAt = now, identityFingerprint = 'unused',
        clusterLease = { owner = 'expired-owner', fencingToken = 8, ttlSeconds = 45 },
        clusterLeaseDeadlineAt = now + 25000, authorityDeadlineAt = now + 25000
      }))
      local expired, expiredError = connection:handleJoining(77, -5)
      assert(expired == nil and expiredError.code == 'PENDING_CONNECTION_EXPIRED')
      assert(dropOwners[77][1] == 'victim' and sourceIdentities[77] == 'attacker')
      assert(players:getPending(-5) == nil and released == 3)
      return table.concat({#drops[99], identityReads, persisted, released, replayError.code}, ':')
    `);
    assert.equal(result, '5:5:2:3:SOURCE_ALREADY_BOUND');
  } finally {
    engine.global.close();
  }
});

test('playerJoining compensates transition, bind, persistence, and disconnect races exactly once', async () => {
  const engine = await createIdentityEngine();
  try {
    const result = await engine.doString(`
      local function runCase(kind)
        local now, released, dropped, closeCalls, renewCalls, opened = 1000, 0, {}, 0, 0, 0
        local leaseTaken = false
        local sourceIdentity = 'victim'
        local platform = {
          nowGame = function() return now end, random = function() return 31 end,
          print = function() end, jsonEncode = function() return '{}' end,
          getPlayerIdentifiers = function() return {'license:' .. sourceIdentity} end,
          dropPlayer = function(source, reason) dropped[#dropped + 1] = { source = source, reason = reason } end
        }
        local foundation = SynexCoreFactories.foundation({ platform = platform })
        foundation.configureIds('join-failure-' .. kind)
        function foundation.logger:write(_, message, fields)
          if message == 'connection stage' and fields.stage == 'session_opened' then opened = opened + 1 end
        end
        local registries = SynexCoreFactories.registries({ foundation = foundation })
        registries.owners:activate('synex_core')
        local players = registries.players
        assert(players:createPending(-2, {
          id = 'connection-' .. kind, sessionId = 'session-' .. kind,
          tempSource = -2, receivedAt = now, expiresAt = now + 120000,
          state = 'AUTHENTICATED', userId = 'user-victim',
          identityFingerprint = 'fixture-hash',
          clusterLease = { name = 'session:user-victim', owner = 'instance-a:session-' .. kind,
            fencingToken = 9, ttlSeconds = 45 },
          admissionGateLease = { name = 'admission:user-victim',
            owner = 'instance-a:session-' .. kind, fencingToken = 4, ttlSeconds = 45 },
          clusterLeaseDeadlineAt = now + 25000,
          admissionGateDeadlineAt = now + 25000,
          authorityDeadlineAt = now + 25000
        }))
        local originalBind = players.bindJoined
        if kind == 'bind' then
          players.bindJoined = function(self, ...)
            assert(originalBind(self, ...))
            error('fixture-private-bind-error')
          end
        end
        if kind == 'cancelled' then
          players.isCurrent = function(self, sessionId)
            self:removeSession(sessionId)
            return false
          end
        end
        local connection = SynexCoreFactories.identityConnections({
          platform = platform, foundation = foundation, players = players, owners = registries.owners,
          instanceId = 'instance-a',
          lifecycle = { core = { canAdmitPlayers = function() return true end } },
          messaging = { network = { purgeSource = function() end } },
          config = { duplicatePolicy = 'deny_new', pendingTtlMs = 120000,
            clusterSessionLeaseSeconds = 45, clusterHeartbeatMs = 10000 },
          leases = {
            release = function() released = released + 1 return true, nil end,
            renew = function()
              renewCalls = renewCalls + 1
              if leaseTaken then
                return nil, { code = 'LEASE_LOST' }
              end
              return true, nil
            end
          },
          rateLimiter = { consume = function() return true, nil end, purge = function() end },
          sha256 = function() return 'fixture-hash' end,
          instances = { bootId = function() return 'boot-a', nil end }, characters = {},
          userRepository = {
            findByIdentifiers = function() return { id = 'user-victim', status = 'active' }, nil end
          },
          sessionRepository = {
            create = function()
              if kind == 'persistence' then error('fixture-private-persistence-error') end
              if kind == 'lease_after_create' then leaseTaken = true end
              if kind == 'reused' then
                local previous = assert(players:getBySource(42))
                assert(players:removeSession(previous.id))
                assert(players:createPending(-99, { sessionId = 'replacement-session' }))
                assert(players:bindJoined(-99, 42, {
                  id = 'replacement-session', userId = 'replacement-user', state = 'ACTIVE',
                  version = 1, persistedVersion = 1
                }))
                sourceIdentity = 'attacker'
              end
              return true, nil
            end,
            close = function() closeCalls = closeCalls + 1 return true, nil end
          },
          accessRepository = {}, invokeOwned = function() return true, true, nil end,
          normalizeIdentifiers = function()
            return {{ type = 'license', value = 'victim', normalized = 'license:victim' }}
          end,
          sessionTransitions = {},
          transition = function(session, target)
            if kind == 'transition' then error('fixture-private-transition-error') end
            session.state = target
            session.version = session.version + 1
            return session, nil
          end
        })
        local joined, joinError = connection:handleJoining(42, -2)
        local expectedCode = kind == 'lease_after_create' and 'JOIN_LEASE_LOST'
          or ((kind == 'cancelled' or kind == 'reused') and 'CONNECTION_CANCELLED'
          or 'JOIN_PIPELINE_FAILED')
        assert(joined == nil and joinError.code == expectedCode)
        if kind == 'cancelled' or kind == 'reused' then
          assert(#dropped == 0)
        else
          assert(#dropped == 1 and dropped[1].source == 42)
          assert(dropped[1].reason:find('[' .. expectedCode .. ']', 1, true))
          assert(not dropped[1].reason:find('fixture-private', 1, true))
        end
        assert(players:getPending(-2) == nil and players:getSession('session-' .. kind) == nil)
        if kind == 'reused' then
          assert(players:getBySource(42).userId == 'replacement-user')
        else
          assert(players:getBySource(42) == nil)
        end
        assert(released == (kind == 'lease_after_create' and 1 or 2),
          kind .. ':' .. tostring(released))
        if kind == 'persistence' or kind == 'cancelled' or kind == 'reused'
          or kind == 'lease_after_create' then
          assert(closeCalls == 1)
        else
          assert(closeCalls == 0)
        end
        if kind == 'lease_after_create' then assert(renewCalls == 3 and leaseTaken) end
        assert(opened == 0)
        return kind .. ':' .. tostring(closeCalls)
      end
      return table.concat({
        runCase('transition'), runCase('bind'), runCase('persistence'), runCase('cancelled'),
        runCase('reused'), runCase('lease_after_create')
      }, '|')
    `);
    assert.equal(result,
      'transition:0|bind:0|persistence:1|cancelled:1|reused:1|lease_after_create:1');
  } finally {
    engine.global.close();
  }
});

test('remote kick controls remain pending until the exact player drop is accepted', async () => {
  const engine = await createIdentityEngine();
  try {
    const result = await engine.doString(`
      local dropCalls, completionCalls, completed = 0, 0, false
      local health = nil
      local platform = {
        nowGame = function() return 1000 end, random = function() return 33 end,
        print = function() end, wait = function() end,
        dropPlayer = function(source)
          assert(source == 42)
          dropCalls = dropCalls + 1
          if dropCalls == 1 then return false end
          if dropCalls == 2 then error('fixture drop failure') end
        end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('remote-control-dispatch')
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      local players = registries.players
      assert(players:createPending(-1, { sessionId = 'target-session' }))
      assert(players:bindJoined(-1, 42, {
        id = 'target-session', userId = 'target-user', state = 'ACTIVE',
        version = 1, persistedVersion = 1
      }))
      local control = {
        request_id = 'control-a', target_session_id = 'target-session',
        target_instance_id = 'instance-a', action = 'kick', reason = 'replacement'
      }
      local maintenance = SynexCoreFactories.identityConnectionMaintenance({
        platform = platform, foundation = foundation, players = players,
        lifecycle = { core = { setHealth = function(_, _, status) health = status end } },
        messaging = { network = { purgeSource = function() end } },
        config = { clusterSessionLeaseSeconds = 45, clusterHeartbeatMs = 10000 },
        leases = { renew = function() return true, nil end },
        instances = {
          touchSessions = function() return true, nil end,
          heartbeat = function() return {}, nil end,
          pendingLocalControls = function()
            return completed and {} or { control }, nil
          end,
          completeControl = function(_, candidate, dropAccepted)
            assert(candidate == control and dropAccepted == true)
            completionCalls = completionCalls + 1
            completed = true
            return true, nil
          end
        },
        characters = {}, sessionRepository = {}, sessionTransitions = {},
        transition = function() return true, nil end,
        rateLimiter = { purge = function() end },
        joinClaims = { invalidate = function() end },
        logConnectionStage = function() end,
        releaseAdmission = function() end,
        releaseConnectionLease = function() end,
        refreshLeaseDeadline = function() return 26000 end,
        clearQueueEntry = function() end,
        recordReconnectGrace = function() end,
        purgeReconnectGrace = function() end,
        isQuiesced = function() return false end
      })
      local first, firstError = maintenance:heartbeat()
      assert(first == false and firstError.code == 'PLAYER_DROP_FAILED')
      assert(dropCalls == 1 and completionCalls == 0 and health == 'DEGRADED')
      local second, secondError = maintenance:heartbeat()
      assert(second == false and secondError.code == 'PLAYER_DROP_FAILED')
      assert(dropCalls == 2 and completionCalls == 0 and health == 'DEGRADED')
      local third, thirdError = maintenance:heartbeat()
      assert(third == true and thirdError == nil)
      assert(dropCalls == 3 and completionCalls == 1 and health == 'HEALTHY')
      assert(maintenance:heartbeat() == true and dropCalls == 3 and completionCalls == 1)
      return table.concat({dropCalls, completionCalls, tostring(completed), health}, ':')
    `);
    assert.equal(result, '3:1:true:HEALTHY');
  } finally {
    engine.global.close();
  }
});

test('playerDropped detaches and purges before yielded cleanup can observe a reused owner', async () => {
  const engine = await createIdentityEngine();
  try {
    const result = await engine.doString(`
      local now, releases, purges, completedControls, health = 1000, 0, 0, 0, {}
      local drops = {}
      local platform = {
        nowGame = function() return now end, random = function() return 35 end,
        print = function() end, jsonEncode = function() return '{}' end,
        wait = function(delay) now = now + delay end,
        dropPlayer = function(source) drops[source] = (drops[source] or 0) + 1 end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('drop-source-reuse')
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      registries.owners:activate('synex_core')
      local players = registries.players
      assert(players:createPending(-2, { sessionId = 'old-session' }))
      local old = assert(players:bindJoined(-2, 42, {
        id = 'old-session', userId = 'old-user', state = 'ACTIVE', characterId = 'old-character',
        version = 2, persistedVersion = 2,
        clusterLease = { owner = 'old-owner', fencingToken = 1, ttlSeconds = 45 },
        clusterLeaseDeadlineAt = now + 25000, authorityDeadlineAt = now + 25000
      }))
      local connection = nil
      local characters = {}
      function characters:unload(sessionId)
        local detached = assert(players:getSession(old.id))
        assert(sessionId == old.id and players:getBySource(42) == nil and purges == 1)
        assert(detached.source == nil and detached.sourceGeneration > old.sourceGeneration)
        assert(players:createPending(-99, { sessionId = 'replacement-session' }))
        assert(players:bindJoined(-99, 42, {
          id = 'replacement-session', userId = 'replacement-user', state = 'ACTIVE',
          version = 1, persistedVersion = 1
        }))
        local healthy, heartbeatError = connection:heartbeat()
        assert(healthy == false and heartbeatError.code == 'SESSION_LEASE_RENEW_FAILED')
        return true, nil
      end
      connection = SynexCoreFactories.identityConnections({
        platform = platform, foundation = foundation, players = players, owners = registries.owners,
        instanceId = 'instance-a',
        lifecycle = { core = {
          canAdmitPlayers = function() return true end,
          setHealth = function(_, component, status) health[component] = status end
        } },
        messaging = { network = { purgeSource = function() purges = purges + 1 end } },
        config = { duplicatePolicy = 'allow', pendingTtlMs = 120000,
          clusterSessionLeaseSeconds = 45, clusterHeartbeatMs = 10000 },
        leases = {
          release = function() releases = releases + 1 return true, nil end,
          renew = function() return nil, { code = 'LEASE_LOST' } end
        },
        rateLimiter = { consume = function() return true, nil end, purge = function() end },
        sha256 = function(value)
          local hash = 2166136261
          for index = 1, #value do hash = ((hash ~ value:byte(index)) * 16777619) & 0xffffffff end
          return string.rep(('%08x'):format(hash), 8)
        end,
        instances = {
          bootId = function() return 'boot-a', nil end,
          touchSessions = function() return true, nil end,
          heartbeat = function() return {}, nil end,
          pendingLocalControls = function() return {{
            target_session_id = old.id, target_instance_id = 'instance-a',
            action = 'kick', request_id = 'stale-control', reason = 'stale'
          }}, nil end,
          completeControl = function(_, control, dropAccepted)
            assert(control.request_id == 'stale-control' and dropAccepted == false)
            completedControls = completedControls + 1
            return true, nil
          end
        },
        characters = characters, userRepository = {}, accessRepository = {},
        sessionRepository = { close = function() return true, nil end },
        invokeOwned = function() return true, true, nil end,
        normalizeIdentifiers = function() return {} end,
        sessionTransitions = { ACTIVE = { DISCONNECTING = true } },
        transition = function(session, target) session.state = target return session, nil end
      })
      local report = assert(connection:handleDropped(42, 'old connection closed'))
      assert(report.closed and #report.failures == 0)
      assert(players:getSession(old.id) == nil)
      assert(players:getBySource(42).userId == 'replacement-user')
      assert(drops[42] == nil and releases == 1 and purges == 1 and completedControls == 1)
      assert(health.cluster == 'DEGRADED' and health['disconnect-cleanup'] == 'HEALTHY')
      return table.concat({releases, purges, completedControls, health.cluster,
        players:getBySource(42).userId}, ':')
    `);
    assert.equal(result, '1:1:1:DEGRADED:replacement-user');
  } finally {
    engine.global.close();
  }
});

test('pending lease heartbeat preserves delayed join authority and fails closed on renewal loss', async () => {
  const engine = await createIdentityEngine();
  try {
    const result = await engine.doString(`
      local function fixture(label)
        local now, authorities, renewCalls, releaseCalls, renewFails = 1000, {}, 0, 0, false
        local renewHook, releaseHook = nil, nil
        local drops, health = {}, nil
        local platform = {
          nowGame = function() return now end, random = function() return 37 end,
          print = function() end, jsonEncode = function() return '{}' end,
          getPlayerIdentifiers = function() return {'license:victim'} end,
          wait = function(delay) now = now + delay end, defer = function() end,
          dropPlayer = function(source, reason) drops[source] = reason end
        }
        local foundation = SynexCoreFactories.foundation({ platform = platform })
        foundation.configureIds('lease-heartbeat-' .. label)
        local registries = SynexCoreFactories.registries({ foundation = foundation })
        registries.owners:activate('synex_core')
        local leases = {}
        function leases:acquire(name, owner, ttl, requesterInstanceId, requesterBootId)
          local authority = authorities[name]
          if authority and authority.expiresAt > now and authority.owner ~= owner then
            return nil, { code = 'LEASE_BUSY' }
          end
          local token = authority and authority.fencingToken + 1 or 1
          authority = { name = name, owner = owner, fencingToken = token,
            ttlSeconds = ttl, expiresAt = now + ttl * 1000 }
          authorities[name] = authority
          return { name = name, owner = owner, fencingToken = token, ttlSeconds = ttl,
            requesterInstanceId = requesterInstanceId, requesterBootId = requesterBootId }, nil
        end
        function leases:renew(lease)
          renewCalls = renewCalls + 1
          if renewHook then
            local callback = renewHook
            renewHook = nil
            callback()
          end
          local authority = authorities[lease.name]
          if renewFails or not authority or authority.expiresAt <= now
            or authority.owner ~= lease.owner or authority.fencingToken ~= lease.fencingToken then
            return nil, { code = 'LEASE_LOST' }
          end
          authority.expiresAt = now + lease.ttlSeconds * 1000
          return true, nil
        end
        function leases:release(lease)
          releaseCalls = releaseCalls + 1
          if releaseHook then
            local callback = releaseHook
            releaseHook = nil
            callback()
          end
          local authority = authorities[lease.name]
          if authority and authority.owner == lease.owner and authority.fencingToken == lease.fencingToken then
            authority.expiresAt = now
          end
          return true, nil
        end
        local userRepository = {
          authenticate = function() return { id = 'user-victim', status = 'active' }, nil end,
          findByIdentifiers = function() return { id = 'user-victim', status = 'active' }, nil end
        }
        local connection = SynexCoreFactories.identityConnections({
          platform = platform, foundation = foundation, instanceId = 'instance-a',
          players = registries.players, owners = registries.owners,
          lifecycle = { core = {
            canAdmitPlayers = function() return true end,
            setHealth = function(_, _, status) health = status end
          } },
          messaging = { network = { purgeSource = function() end } },
          config = { duplicatePolicy = 'deny_new', queueEnabled = false, pendingTtlMs = 120000,
            clusterSessionLeaseSeconds = 45, clusterHeartbeatMs = 10000 },
          leases = leases,
          rateLimiter = { consume = function() return true, nil end, purge = function() end },
          sha256 = function(value)
            local hash = 2166136261
            for index = 1, #value do hash = ((hash ~ value:byte(index)) * 16777619) & 0xffffffff end
            return string.rep(('%08x'):format(hash), 8)
          end,
          instances = {
            bootId = function() return 'boot-a', nil end,
            requestRemoteKicks = function() return 0, nil end,
            hasOpenUserSessions = function() return false, nil end,
            touchSessions = function() return true, nil end,
            heartbeat = function() return {}, nil end,
            pendingLocalControls = function() return {}, nil end,
            completeControl = function() return true, nil end
          },
          characters = {}, userRepository = userRepository,
          sessionRepository = {
            create = function(_, session)
              local gate = authorities[session.admissionGateLease.name]
              if gate then gate.expiresAt = now end
              return true, nil
            end,
            close = function() return true, nil end
          },
          accessRepository = { check = function() return true, nil end },
          invokeOwned = function() return true, true, nil end,
          normalizeIdentifiers = function()
            return {{ type = 'license', value = 'victim', normalized = 'license:victim' }}
          end,
          sessionTransitions = {},
          transition = function(session, target)
            session.state = target
            session.version = session.version + 1
            return session, nil
          end
        })
        return {
          connection = connection, players = registries.players, drops = drops,
          connect = function(tempSource)
            local completion = nil
            local connected, connectError = connection:handleConnecting(tempSource, 'Victim', {
              defer = function() end, update = function() end,
              done = function(reason) completion = reason == nil and '<accepted>' or reason end
            })
            return completion, connected, connectError
          end,
          advance = function(ms) now = now + ms end,
          setRenewFailure = function(value) renewFails = value end,
          setReleaseHook = function(callback) releaseHook = callback end,
          replaceSourceOnRenew = function(source)
            renewHook = function()
              local previous = registries.players:getBySource(source)
              assert(previous and registries.players:removeSession(previous.id))
              assert(registries.players:createPending(-99, { sessionId = 'replacement-session' }))
              assert(registries.players:bindJoined(-99, source, {
                id = 'replacement-session', userId = 'replacement-user', state = 'ACTIVE',
                version = 1, persistedVersion = 1
              }))
            end
          end,
          stats = function()
            return now, authorities['session:user-victim'], renewCalls, releaseCalls, health
          end
        }
      end

      local delayed = fixture('delayed')
      local delayedCompletion, delayedConnected, delayedError = delayed.connect(-2)
      assert(delayedCompletion == '<accepted>' and delayedConnected,
        delayedError and delayedError.code)
      for _ = 1, 6 do delayed.advance(10000); assert(delayed.connection:heartbeat()) end
      assert(delayed.connection:handleJoining(42, -2))
      assert(delayed.players:getBySource(42).userId == 'user-victim')
      local duplicate = delayed.connect(-3)
      assert(duplicate:find('[DUPLICATE_SESSION]', 1, true))
      for _ = 1, 3 do delayed.advance(10000); assert(delayed.connection:heartbeat()) end
      local delayedNow, authority, renewed = delayed.stats()
      assert(delayedNow >= 91000 and authority.expiresAt > delayedNow and renewed >= 9)
      delayed.setRenewFailure(true)
      delayed.advance(10000)
      local sessionHealthy, sessionHeartbeatError = delayed.connection:heartbeat()
      local _, _, _, _, sessionHealth = delayed.stats()
      assert(sessionHealthy == false and sessionHeartbeatError.code == 'SESSION_LEASE_RENEW_FAILED')
      assert(sessionHealth == 'DEGRADED')
      assert(delayed.drops[42]:find('authority was lost', 1, true))

      local stale = fixture('stale')
      local staleCompletion, staleConnected, staleConnectError = stale.connect(-2)
      assert(staleCompletion == '<accepted>' and staleConnected,
        staleConnectError and staleConnectError.code)
      assert(stale.connection:handleJoining(42, -2))
      stale.setRenewFailure(true)
      stale.replaceSourceOnRenew(42)
      stale.advance(10000)
      local staleHealthy, staleHeartbeatError = stale.connection:heartbeat()
      assert(staleHealthy == false and staleHeartbeatError.code == 'SESSION_LEASE_RENEW_FAILED')
      assert(stale.players:getBySource(42).userId == 'replacement-user')
      assert(stale.drops[42] == nil)

      local cleanup = fixture('cleanup')
      local cleanupNow = select(1, cleanup.stats())
      assert(cleanup.players:createPending(-2, {
        id = 'expired-a', sessionId = 'expired-session-a', tempSource = -2,
        state = 'AUTHENTICATED', receivedAt = cleanupNow - 1, expiresAt = cleanupNow,
        clusterLease = { owner = 'a', fencingToken = 1, ttlSeconds = 45 },
        clusterLeaseDeadlineAt = cleanupNow + 25000,
        authorityDeadlineAt = cleanupNow + 25000
      }))
      assert(cleanup.players:createPending(-3, {
        id = 'expired-b', sessionId = 'expired-session-b', tempSource = -3,
        state = 'AUTHENTICATED', receivedAt = cleanupNow - 1, expiresAt = cleanupNow,
        clusterLease = { owner = 'b', fencingToken = 1, ttlSeconds = 45 },
        clusterLeaseDeadlineAt = cleanupNow + 25000,
        authorityDeadlineAt = cleanupNow + 25000
      }))
      cleanup.setReleaseHook(function()
        assert(cleanup.players:removePending(-3).id == 'expired-b')
        assert(cleanup.players:createPending(-3, {
          id = 'replacement-pending', sessionId = 'replacement-pending-session', tempSource = -3,
          state = 'AUTHENTICATED', receivedAt = cleanupNow, expiresAt = cleanupNow + 120000
        }))
      end)
      assert(cleanup.connection:purgeExpired(2) == 1)
      assert(cleanup.players:getPending(-2) == nil)
      assert(cleanup.players:getPending(-3).id == 'replacement-pending')

      local failed = fixture('failed')
      local failedCompletion, failedConnected, failedConnectError = failed.connect(-2)
      assert(failedCompletion == '<accepted>' and failedConnected,
        failedConnectError and failedConnectError.code)
      failed.setRenewFailure(true)
      failed.advance(10000)
      local healthy, heartbeatError = failed.connection:heartbeat()
      local _, _, _, failedReleases, failedHealth = failed.stats()
      assert(healthy == false and heartbeatError.code == 'PENDING_LEASE_RENEW_FAILED')
      assert(failed.players:getPending(-2) == nil and failed.connection:snapshot().admissionReservations == 0)
      assert(failedReleases == 2 and failedHealth == 'DEGRADED')
      local joined, joinError = failed.connection:handleJoining(42, -2)
      assert(joined == nil and joinError.code == 'PENDING_CONNECTION_NOT_FOUND')
      assert(failed.drops[42]:find('[PENDING_CONNECTION_NOT_FOUND]', 1, true))
      return table.concat({renewed, failedReleases, failedHealth, joinError.code}, ':')
    `);
    assert.match(result, /^\d+:2:DEGRADED:PENDING_CONNECTION_NOT_FOUND$/u);
  } finally {
    engine.global.close();
  }
});

test('connection quiesce rejects pending acceptance and invalidates an in-flight join', async () => {
  const engine = await createIdentityEngine();
  try {
    const result = await engine.doString(`
      local function fixture(quiesceDuringJoin, closeDuringJoin, closeDuringAcceptance,
          quiesceBeforeAuthentication, closeBeforeAuthentication, quiesceBeforeFirstTick)
        local now, connection, admitting = 1000, nil, true
        local deferCalls, leaseReleases, workerCalls = 0, 0, 0
        local authenticateCalls, gateCalls = 0, 0
        local completions, drops, leaseRequester, leaseBootId = {}, {}, nil, nil
        local order, inTick, doneDuringTick = {}, false, false
        local platform = {
          nowGame = function() now = now + 1 return now end,
          random = function() return 37 end,
          print = function() end,
          jsonEncode = function() return '{}' end,
          getPlayerIdentifiers = function() return {'license:victim'} end,
          wait = function(delay) now = now + delay end,
          defer = function()
            deferCalls = deferCalls + 1
            order[#order + 1] = 'tick'
            inTick = true
            if deferCalls == 1 and quiesceBeforeFirstTick then
              assert(connection:quiesce())
            elseif deferCalls == 2 then
              if quiesceBeforeAuthentication then
                assert(connection:quiesce())
              elseif closeBeforeAuthentication then
                admitting = false
              end
            elseif deferCalls == 3 then
              if closeDuringAcceptance then
                admitting = false
              elseif not quiesceDuringJoin and not closeBeforeAuthentication then
                assert(connection:quiesce())
              end
            end
            inTick = false
          end,
          dropPlayer = function(source, reason) drops[source] = reason end
        }
        local foundation = SynexCoreFactories.foundation({ platform = platform })
        foundation.configureIds(quiesceDuringJoin and 'join-quiesce' or 'accept-quiesce')
        local registries = SynexCoreFactories.registries({ foundation = foundation })
        registries.owners:activate('synex_core')
        local instances = {
          bootId = function() return 'boot-a', nil end,
          requestRemoteKicks = function() workerCalls = workerCalls + 1 return 0, nil end,
          hasOpenUserSessions = function() return false, nil end,
          touchSessions = function() workerCalls = workerCalls + 1 return true, nil end,
          heartbeat = function() workerCalls = workerCalls + 1 return {}, nil end,
          pendingLocalControls = function() workerCalls = workerCalls + 1 return {}, nil end,
          completeControl = function() workerCalls = workerCalls + 1 return true, nil end
        }
        local leases = {
          acquire = function(_, name, owner, ttl, requester, requesterBootId)
            leaseRequester = requester
            leaseBootId = requesterBootId
            return { name = name, owner = owner, fencingToken = 1, ttlSeconds = ttl,
              requesterInstanceId = requester, requesterBootId = requesterBootId }, nil
          end,
          release = function()
            leaseReleases = leaseReleases + 1
            return true, nil
          end,
          renew = function(_, lease) return lease, nil end
        }
        local userRepository = {
          authenticate = function()
            authenticateCalls = authenticateCalls + 1
            return { id = 'user-victim', status = 'active' }, nil
          end,
          findByIdentifiers = function()
            if quiesceDuringJoin then
              assert(connection:quiesce())
            elseif closeDuringJoin then
              admitting = false
            end
            return { id = 'user-victim', status = 'active' }, nil
          end
        }
        connection = SynexCoreFactories.identityConnections({
          platform = platform, foundation = foundation, instanceId = 'instance-a',
          players = registries.players, owners = registries.owners,
          lifecycle = { core = {
            canAdmitPlayers = function() return admitting end,
            setHealth = function() end
          } },
          messaging = { network = { purgeSource = function() end } },
          config = { duplicatePolicy = 'deny_new', queueEnabled = false,
            pendingTtlMs = 120000, clusterSessionLeaseSeconds = 45 },
          leases = leases, instances = instances, characters = {},
          userRepository = userRepository,
          sessionRepository = {
            create = function() return true, nil end,
            close = function() return true, nil end
          },
          accessRepository = { check = function() return true, nil end },
          rateLimiter = { consume = function() return true, nil end, purge = function() end },
          invokeOwned = function() return true, true, nil end,
          normalizeIdentifiers = function()
            return {{ type = 'license', value = 'victim', normalized = 'license:victim' }}
          end,
          sha256 = function() return string.rep('f', 64) end,
          sessionTransitions = {},
          transition = function(session, target)
            session.state = target
            session.version = session.version + 1
            return session, nil
          end
        })
        return {
          connection = connection,
          players = registries.players,
          connect = function()
            return connection:handleConnecting(-2, 'Victim', {
              defer = function() order[#order + 1] = 'defer' end,
              update = function() end,
              done = function(...)
                doneDuringTick = doneDuringTick or inTick
                order[#order + 1] = 'done'
                completions[#completions + 1] = {
                  arity = select('#', ...), reason = select(1, ...)
                }
              end
            })
          end,
          seedPending = function()
            return registries.players:createPending(-2, {
              id = 'pending-a', sessionId = 'session-a', userId = 'user-victim',
              tempSource = -2, state = 'AUTHENTICATED', receivedAt = now,
              expiresAt = now + 120000, identityFingerprint = string.rep('f', 64),
              clusterLease = { name = 'session:user-victim', owner = 'instance-a:session-a',
                fencingToken = 1, ttlSeconds = 45 },
              admissionGateLease = { name = 'admission:user-victim',
                owner = 'instance-a:session-a', fencingToken = 1, ttlSeconds = 45 },
              clusterLeaseDeadlineAt = now + 25000,
              admissionGateDeadlineAt = now + 25000,
              authorityDeadlineAt = now + 25000
            })
          end,
          closeAdmission = function() admitting = false end,
          registerGate = function()
            return connection:registerGate('synex_core', 1, {
              name = 'quiesce fixture', priority = 0, timeoutMs = 100,
              run = function() gateCalls = gateCalls + 1 return true end
            })
          end,
          state = function()
            return completions, drops, leaseReleases, workerCalls, leaseRequester, leaseBootId,
              authenticateCalls, gateCalls, table.concat(order, ','), doneDuringTick
          end
        }
      end

      local acceptance = fixture(false)
      assert(acceptance.connect())
      assert(acceptance.connection:releaseQuiescedLeases())
      local completions, drops, releases, workers = acceptance.state()
      assert(#completions == 1 and completions[1].arity == 1)
      assert(completions[1].reason:find('[CORE_STOPPING]', 1, true))
      assert(acceptance.players:getPending(-2) == nil)
      assert(acceptance.connection:snapshot().quiesced == true)
      assert(acceptance.connection:snapshot().admissionReservations == 0)
      assert(releases == 2)
      assert(select(10, acceptance.state()) == false)
      assert(select(5, acceptance.state()) == 'instance-a')
      assert(select(6, acceptance.state()) == 'boot-a')
      local repeated = assert(acceptance.connection:quiesce())
      assert(repeated.removedPending == 1 and repeated.releasedLeases == 1)
      assert(acceptance.connection:heartbeat())
      workers = select(4, acceptance.state())
      assert(workers == 0)
      local joinedAfterStop, stoppedError = acceptance.connection:handleJoining(42, -2)
      assert(joinedAfterStop == nil and stoppedError.code == 'CORE_STOPPING')
      drops = select(2, acceptance.state())
      assert(drops[42]:find('[CORE_STOPPING]', 1, true))

      local preStopped = fixture(true)
      assert(preStopped.connection:quiesce())
      assert(preStopped.connect())
      local preCompletions = select(1, preStopped.state())
      assert(#preCompletions == 1 and preCompletions[1].reason:find('[CORE_STOPPING]', 1, true))
      assert(select(7, preStopped.state()) == 0 and select(9, preStopped.state()) == 'defer,tick,done')
      assert(select(10, preStopped.state()) == false
        and preStopped.connection:snapshot().openDeferrals == 0)

      local firstTickStopped = fixture(false, false, false, false, false, true)
      assert(firstTickStopped.connect())
      local firstTickCompletions = select(1, firstTickStopped.state())
      assert(#firstTickCompletions == 1
        and firstTickCompletions[1].reason:find('[CORE_STOPPING]', 1, true))
      assert(select(9, firstTickStopped.state()) == 'defer,tick,done'
        and select(10, firstTickStopped.state()) == false)
      assert(firstTickStopped.connection:snapshot().openDeferrals == 0)

      local authBlocked = fixture(false, false, false, true)
      assert(authBlocked.connect())
      local authCompletions = select(1, authBlocked.state())
      assert(#authCompletions == 1 and authCompletions[1].reason:find('[CORE_STOPPING]', 1, true))
      assert(select(7, authBlocked.state()) == 0 and select(8, authBlocked.state()) == 0)
      assert(authBlocked.players:getPending(-2) == nil)

      local authDegraded = fixture(false, false, false, false, true)
      assert(authDegraded.connect())
      local authDegradedCompletions = select(1, authDegraded.state())
      assert(#authDegradedCompletions == 1
        and authDegradedCompletions[1].reason:find('[CORE_NOT_READY]', 1, true))
      assert(select(3, authDegraded.state()) == 0
        and select(7, authDegraded.state()) == 0 and select(8, authDegraded.state()) == 0)
      assert(authDegraded.players:getPending(-2) == nil
        and authDegraded.connection:snapshot().admissionReservations == 0)

      local joining = fixture(true)
      assert(joining.seedPending())
      local joined, joinError = joining.connection:handleJoining(43, -2)
      assert(joined == nil and joinError.code == 'CORE_STOPPING')
      assert(joining.connection:releaseQuiescedLeases())
      local _, joinDrops, joinReleases = joining.state()
      assert(joinDrops[43] == nil)
      assert(joinReleases == 2 and joining.players:getPending(-2) == nil)
      assert(joining.players:getBySource(43) == nil)

      local captured = fixture(false)
      assert(captured.registerGate())
      assert(captured.connect())
      local capturedCompletions, _, capturedReleases = captured.state()
      assert(#capturedCompletions == 1)
      assert(capturedCompletions[1].reason:find('[CORE_STOPPING]', 1, true))
      assert(select(8, captured.state()) == 0)
      assert(capturedReleases == 0)
      local capturedReport = assert(captured.connection:releaseQuiescedLeases())
      capturedReleases = select(3, captured.state())
      assert(capturedReport.removedPending == 1 and capturedReport.releasedLeases == 0)
      assert(capturedReleases == 0)

      local unavailable = fixture(false)
      assert(unavailable.seedPending())
      unavailable.closeAdmission()
      local unavailableJoin, unavailableError = unavailable.connection:handleJoining(44, -2)
      assert(unavailableJoin == nil and unavailableError.code == 'CORE_NOT_READY')
      local _, unavailableDrops, unavailableReleases = unavailable.state()
      assert(unavailableDrops[44]:find('[CORE_NOT_READY]', 1, true))
      assert(unavailableReleases == 2 and unavailable.players:getPending(-2) == nil)
      assert(unavailable.connection:snapshot().admissionReservations == 0)

      local degraded = fixture(false, true)
      assert(degraded.seedPending())
      local degradedJoin, degradedError = degraded.connection:handleJoining(45, -2)
      assert(degradedJoin == nil and degradedError.code == 'CORE_NOT_READY')
      local _, degradedDrops, degradedReleases = degraded.state()
      assert(degradedDrops[45]:find('[CORE_NOT_READY]', 1, true))
      assert(degradedReleases == 2 and degraded.players:getPending(-2) == nil)
      assert(degraded.players:getBySource(45) == nil)

      local lateDegraded = fixture(false, false, true)
      assert(lateDegraded.connect())
      local lateCompletions, _, lateReleases = lateDegraded.state()
      assert(#lateCompletions == 1 and lateCompletions[1].arity == 1)
      assert(lateCompletions[1].reason:find('[CORE_NOT_READY]', 1, true))
      assert(lateReleases == 2 and lateDegraded.players:getPending(-2) == nil)
      assert(lateDegraded.connection:snapshot().quiesced == false)
      assert(lateDegraded.connection:snapshot().admissionReservations == 0)
      return table.concat({stoppedError.code, joinError.code, unavailableError.code,
        degradedError.code, releases, joinReleases, capturedReleases,
        unavailableReleases, degradedReleases, lateReleases}, ':')
    `);
    assert.equal(result, 'CORE_STOPPING:CORE_STOPPING:CORE_NOT_READY:CORE_NOT_READY:2:2:0:2:2:2');
  } finally {
    engine.global.close();
  }
});

test('bootstrap subscribes to the built-in playerJoining event without exposing it to clients', async () => {
  const source = await readFile(path.join(root, 'core/synex_core/server/bootstrap_resource_events.lua'), 'utf8');
  const subscription = source.indexOf("platform.addEventHandler('playerJoining'");
  assert.doesNotMatch(source, /(?:platform\.(?:registerNetEvent|onNet)|\bRegisterNetEvent)\s*\(\s*['"]playerJoining['"]/u,
    'the built-in server event must not be network registered');
  assert.ok(subscription >= 0, 'playerJoining must have a local server handler');
  assert.equal(source.match(/platform\.addEventHandler\('playerJoining'/gu)?.length, 1);
  const handler = source.slice(subscription, source.indexOf("platform.addEventHandler('playerDropped'", subscription));
  assert.doesNotMatch(handler, /platform\.dropPlayer/u,
    'the outer join boundary cannot prove final-source ownership after an unexpected yield');
});
