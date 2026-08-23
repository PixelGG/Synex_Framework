import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory, type LuaEngine } from 'wasmoon';

const root = process.cwd();

const modules = [
  'core/synex_core/shared/protocol.lua',
  'core/synex_core/server/factories.lua',
  'core/synex_core/server/foundation.lua',
  'core/synex_core/server/registries.lua',
  'core/synex_core/server/security.lua',
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
];

async function createEngine(): Promise<LuaEngine> {
  const engine = await new LuaFactory().createEngine();
  for (const relativePath of modules) {
    await engine.doString(await readFile(path.join(root, relativePath), 'utf8'));
  }
  await engine.doString(`
    function IngressTestDigest(value)
      local hash = 2166136261
      for index = 1, #value do
        hash = ((hash ~ value:byte(index)) * 16777619) & 0xffffffff
      end
      return string.rep(('%08x'):format(hash), 8)
    end

    function NewIngressFixture(options)
      options = options or {}
      local now, pipeline = 1000, nil
      local identifiers, reasons, doneCalls = {}, {}, {}
      local observedKeys, logs = {}, {}
      local databaseCalls, leaseReleases = 0, 0
      local nextTickHook, doneObserver = nil, nil
      local function cfxFunctionReference(handler)
        return setmetatable({ __cfx_functionReference = 'fixture' }, {
          __call = function(_, ...) return handler(...) end
        })
      end
      local platform = {
        nowGame = function() return now end,
        random = function() return 41 end,
        print = function() end,
        jsonEncode = function() return '{}' end,
        getPlayerIdentifiers = function(source) return identifiers[source] or {} end,
        isPlayerAceAllowed = function() return false end,
        setTimeout = function(delay, handler)
          now = now + math.max(0, delay or 0)
          handler()
        end,
        wait = function(delay) now = now + (delay or 0) end,
        defer = function()
          local hook = nextTickHook
          nextTickHook = nil
          if hook then hook() end
        end,
        dropPlayer = function() end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('connection-ingress-fixture')
      function foundation.logger:write(level, message, fields)
        logs[#logs + 1] = {
          level = level, message = message, fields = foundation.copy(fields or {})
        }
      end
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      registries.owners:activate('synex_core')
      local security = SynexCoreFactories.security({
        platform = platform, foundation = foundation, coreResource = 'synex_core',
        policy = { default = { allow = {}, deny = {} }, resources = {} },
        rateLimiterMaximum = options.rateLimiterMaximum or 8192,
        rateLimiterTtlMs = options.rateLimiterTtlMs or 300000
      })
      local limiter = security.rateLimiter
      local observedLimiter = {}
      function observedLimiter:consume(key, ...)
        observedKeys[#observedKeys + 1] = key
        return limiter:consume(key, ...)
      end
      function observedLimiter:purge(...) return limiter:purge(...) end

      local leases = {}
      function leases:acquire(name, owner, ttl, requesterInstanceId, requesterBootId)
        return {
          name = name, owner = owner, fencingToken = 1, ttlSeconds = ttl,
          requesterInstanceId = requesterInstanceId, requesterBootId = requesterBootId
        }, nil
      end
      function leases:release()
        leaseReleases = leaseReleases + 1
        return true, nil
      end
      function leases:renew(lease) return lease, nil end

      local instances = {
        bootId = function() return 'boot-a', nil end,
        requestRemoteKicks = function() return 0, nil end,
        hasOpenUserSessions = function() return false, nil end,
        touchSessions = function() return true, nil end,
        heartbeat = function() return {}, nil end,
        pendingLocalControls = function() return {}, nil end,
        completeControl = function() return true, nil end
      }
      local userRepository = {}
      function userRepository:authenticate()
        databaseCalls = databaseCalls + 1
        if options.authMode == 'throw' then error('private authentication failure') end
        if options.authMode == 'throw_table' then
          error({ code = 'PRIVATE_AUTHENTICATION_FAILURE', identifiers = {'license:private'},
            playerName = 'Private Player Name' })
        end
        if options.authMode ~= 'accept' then
          return nil, foundation.error('IDENTIFIER_REQUIRED', 'fixture rejection')
        end
        return { id = 'user-fixture', status = 'active' }, nil
      end
      function userRepository:findByIdentifiers()
        databaseCalls = databaseCalls + 1
        return { id = 'user-fixture', status = 'active' }, nil
      end
      local accessRepository = {}
      function accessRepository:check()
        databaseCalls = databaseCalls + 1
        return true, nil
      end
      local sessionRepository = {}
      function sessionRepository:create()
        databaseCalls = databaseCalls + 1
        return true, nil
      end
      function sessionRepository:close()
        databaseCalls = databaseCalls + 1
        return true, nil
      end

      pipeline = SynexCoreFactories.identityConnections({
        platform = platform, foundation = foundation,
        players = registries.players, owners = registries.owners,
        lifecycle = { core = {
          canAdmitPlayers = function() return true end,
          setHealth = function() end
        } },
        messaging = { network = { purgeSource = function() return true end } },
        config = {
          duplicatePolicy = 'deny_new', pendingTtlMs = 120000,
          clusterSessionLeaseSeconds = 45, clusterHeartbeatMs = 10000,
          queueEnabled = options.queueEnabled == true,
          queueUpdateMs = 250, queueTimeoutMs = 10000,
          maximumQueued = options.maximumQueued or 4,
          maximumActiveSessions = options.maximumActiveSessions or 4,
          maximumConcurrentConnections = options.maximumConcurrentConnections or 4,
          connectionRate = options.connectionRate or 100,
          connectionBurst = options.connectionBurst or 100,
          queueReservedSlots = 0
        },
        instanceId = 'instance-a', leases = leases, instances = instances,
        characters = { unload = function() return true, nil end },
        userRepository = userRepository, accessRepository = accessRepository,
        sessionRepository = sessionRepository, rateLimiter = observedLimiter,
        invokeOwned = function() return true, true, nil end,
        normalizeIdentifiers = function(raw)
          local normalized = {}
          for _, candidate in ipairs(raw or {}) do
            local value = type(candidate) == 'string' and candidate:match('^license:(.+)$') or nil
            if value then
              normalized[#normalized + 1] = {
                type = 'license', value = value:lower(), normalized = 'license:' .. value:lower()
              }
            end
          end
          return normalized
        end,
        sha256 = IngressTestDigest,
        sessionTransitions = { SELECTING_CHARACTER = { DISCONNECTING = true } },
        transition = function(session, target)
          session.state = target
          session.version = (session.version or 0) + 1
          return session, nil
        end
      })

      local fixture = {}
      function fixture:setIdentifiers(source, values) identifiers[source] = values end
      function fixture:onNextTick(handler) nextTickHook = handler end
      function fixture:onDone(handler) doneObserver = handler end
      function fixture:advance(milliseconds) now = now + milliseconds end
      function fixture:connect(source, values, doneThrows)
        identifiers[source] = values
        local defer = function()
          if options.ingressDeferMode == 'throw' then
            error('private ingress deferral failure')
          end
        end
        local update = function() end
        local done = function(...)
          doneCalls[source] = (doneCalls[source] or 0) + 1
          reasons[source] = select('#', ...) == 0 and '<accepted>' or select(1, ...)
          if doneObserver then doneObserver(source, reasons[source]) end
          if doneThrows then error('private deferral terminal failure') end
        end
        if options.cfxDeferralFuncrefs == true then
          defer = cfxFunctionReference(defer)
          update = cfxFunctionReference(update)
          done = cfxFunctionReference(done)
        end
        return pipeline:handleConnecting(source, 'Private Player Name', {
          defer = defer, update = update, done = done
        })
      end
      function fixture:pipeline() return pipeline end
      function fixture:players() return registries.players end
      function fixture:databaseCalls() return databaseCalls end
      function fixture:reason(source) return reasons[source] end
      function fixture:doneCalls(source) return doneCalls[source] or 0 end
      function fixture:keys() return observedKeys end
      function fixture:logs() return logs end
      function fixture:limiterSnapshot() return limiter:snapshot() end
      function fixture:leaseReleases() return leaseReleases end
      return fixture
    end
  `);
  return engine;
}

test('pre-auth concurrency is capped before terminals, pending state, and database work', async () => {
  const engine = await createEngine();
  try {
    const result = await engine.doString(`
      local fixture = NewIngressFixture({
        maximumConcurrentConnections = 2,
        connectionRate = 100, connectionBurst = 100
      })
      local peak = nil
      fixture:onDone(function(source)
        if source == -3 then
          peak = {
            snapshot = fixture:pipeline():snapshot(),
            pending = fixture:players():summary().pendingConnections
          }
        end
      end)
      fixture:onNextTick(function()
        fixture:onNextTick(function()
          assert(fixture:connect(-3, {'license:secret-c', 'ip:203.0.113.30'}))
        end)
        assert(fixture:connect(-2, {'license:secret-b', 'ip:203.0.113.20'}))
      end)
      assert(fixture:connect(-1, {'license:secret-a', 'ip:203.0.113.10'}))

      assert(fixture:databaseCalls() == 2)
      assert(fixture:reason(-3):find('[CONNECTION_CAPACITY_REACHED]', 1, true))
      assert(peak.snapshot.preAuth.active == 2 and peak.snapshot.openDeferrals == 2)
      assert(peak.pending == 0)
      local final = fixture:pipeline():snapshot()
      assert(final.preAuth.active == 0 and final.openDeferrals == 0)
      assert(fixture:players():summary().pendingConnections == 0)
      assert(#fixture:keys() == 2)
      for _, key in ipairs(fixture:keys()) do
        assert(key:match('^connection_ingress:[0-9a-f]+$') and #key == 83)
        assert(not key:find('secret', 1, true) and not key:find('203.0.113', 1, true))
      end
      local function assertPrivate(value)
        if type(value) == 'string' then
          assert(not value:find('secret-', 1, true) and not value:find('203.0.113', 1, true)
            and not value:find('Private Player Name', 1, true))
        elseif type(value) == 'table' then
          for key, item in pairs(value) do assertPrivate(key); assertPrivate(item) end
        end
      end
      assertPrivate(final)
      assertPrivate(fixture:logs())
      return table.concat({fixture:databaseCalls(), peak.snapshot.preAuth.active,
        peak.snapshot.openDeferrals, peak.pending, final.preAuth.active}, ':')
    `);
    assert.equal(result, '2:2:2:0:0');
  } finally {
    engine.global.close();
  }
});

test('a drop in the first deferral yield cancels the exact ingress generation', async () => {
  const engine = await createEngine();
  try {
    const result = await engine.doString(`
      local fixture = NewIngressFixture({
        maximumConcurrentConnections = 1,
        connectionRate = 1000, connectionBurst = 1000
      })
      for index = 1, 96 do
        local source = -1000 - index
        fixture:onNextTick(function()
          fixture:pipeline():handleDropped(source, 'dropped during first deferral tick')
        end)
        assert(fixture:connect(source, {'license:cancelled-' .. index}))
        assert(fixture:doneCalls(source) == 1)
        assert(fixture:reason(source):find('[CONNECTION_CANCELLED]', 1, true))
        assert(fixture:players():summary().pendingConnections == 0)
        local snapshot = fixture:pipeline():snapshot()
        assert(snapshot.preAuth.active == 0 and snapshot.openDeferrals == 0)
      end
      assert(fixture:databaseCalls() == 0)
      local final = fixture:pipeline():snapshot()
      return table.concat({fixture:databaseCalls(), final.preAuth.active,
        final.openDeferrals, fixture:doneCalls(-1096)}, ':')
    `);
    assert.equal(result, '0:0:0:1');
  } finally {
    engine.global.close();
  }
});

test('per-identity buckets rate-limit, expire, and remain globally bounded', async () => {
  const engine = await createEngine();
  try {
    const result = await engine.doString(`
      local fixture = NewIngressFixture({
        maximumConcurrentConnections = 1,
        connectionRate = 0.01, connectionBurst = 2,
        rateLimiterMaximum = 64, rateLimiterTtlMs = 1000
      })
      assert(fixture:connect(-1, {'license:stable', 'ip:198.51.100.1'}))
      assert(fixture:connect(-2, {'license:stable', 'ip:198.51.100.1'}))
      assert(fixture:connect(-3, {'license:stable', 'ip:198.51.100.1'}))
      assert(fixture:databaseCalls() == 2)
      assert(fixture:reason(-3):find('[CONNECTION_RATE_LIMITED]', 1, true))
      assert(fixture:connect(-4, {'license:other', 'ip:198.51.100.1'}))
      assert(fixture:databaseCalls() == 3)
      local keys = fixture:keys()
      assert(keys[1] == keys[2] and keys[2] == keys[3] and keys[4] ~= keys[1])
      fixture:advance(1001)
      assert(fixture:connect(-5, {'license:stable', 'ip:198.51.100.1'}))
      assert(fixture:databaseCalls() == 4 and fixture:limiterSnapshot().buckets == 1)
      fixture:advance(1001)
      assert(fixture:limiterSnapshot().buckets == 0)

      local bounded = NewIngressFixture({
        maximumConcurrentConnections = 1,
        connectionRate = 100, connectionBurst = 1,
        rateLimiterMaximum = 64, rateLimiterTtlMs = 300000
      })
      for index = 1, 70 do
        assert(bounded:connect(-100 - index, {
          'license:rotating-' .. index, 'ip:192.0.2.' .. index
        }))
      end
      assert(bounded:databaseCalls() == 64)
      assert(bounded:limiterSnapshot().buckets == 64)
      assert(bounded:pipeline():snapshot().preAuth.active == 0)
      return table.concat({fixture:databaseCalls(), #keys,
        bounded:databaseCalls(), bounded:limiterSnapshot().buckets}, ':')
    `);
    assert.equal(result, '4:5:64:64');
  } finally {
    engine.global.close();
  }
});

test('ingress reservations release on join, drop, quiesce, and pipeline exceptions without breaking queue admission', async () => {
  const engine = await createEngine();
  try {
    const result = await engine.doString(`
      local fixture = NewIngressFixture({
        authMode = 'accept', queueEnabled = true,
        maximumQueued = 2, maximumActiveSessions = 2,
        maximumConcurrentConnections = 1,
        connectionRate = 100, connectionBurst = 100
      })
      assert(fixture:connect(-1, {'license:joined'}))
      assert(fixture:pipeline():snapshot().preAuth.active == 1)
      fixture:setIdentifiers(41, {'license:joined'})
      local joined = assert(fixture:pipeline():handleJoining(41, -1))
      assert(joined.source == 41 and fixture:pipeline():snapshot().preAuth.active == 0)
      assert(fixture:pipeline():handleDropped(41, 'fixture drop').closed == true)

      assert(fixture:connect(-2, {'license:pending'}))
      local beforeCapDatabase = fixture:databaseCalls()
      assert(fixture:connect(-3, {'license:blocked'}))
      assert(fixture:databaseCalls() == beforeCapDatabase)
      assert(fixture:reason(-3):find('[CONNECTION_CAPACITY_REACHED]', 1, true))
      local queue = fixture:pipeline():snapshot()
      assert(queue.queued == 0 and queue.peak == 1 and queue.preAuth.active == 1)
      fixture:pipeline():handleDropped(-2, 'pending drop')
      assert(fixture:pipeline():snapshot().preAuth.active == 0)
      assert(fixture:connect(-4, {'license:after-drop'}))
      assert(fixture:pipeline():snapshot().preAuth.active == 1)
      assert(fixture:pipeline():quiesce())
      local stopped = fixture:pipeline():snapshot()
      assert(stopped.preAuth.active == 0 and stopped.preAuth.quiesced == true)
      assert(fixture:players():summary().pendingConnections == 0)

      local failed = NewIngressFixture({
        authMode = 'throw', maximumConcurrentConnections = 1,
        connectionRate = 100, connectionBurst = 100
      })
      local connected, connectionError = failed:connect(-9, {'license:exception'})
      assert(connected == nil and connectionError.code == 'CONNECTION_PIPELINE_FAILED')
      local failureSnapshot = failed:pipeline():snapshot()
      assert(failureSnapshot.preAuth.active == 0 and failureSnapshot.openDeferrals == 0)
      assert(failed:players():summary().pendingConnections == 0)
      assert(failed:reason(-9):find('[CONNECTION_PIPELINE_FAILED]', 1, true))

      local function failureLog(fixture)
        local matched = nil
        for _, record in ipairs(fixture:logs()) do
          if record.message == 'connection pipeline failed' then
            assert(matched == nil)
            matched = record
          end
        end
        return assert(matched)
      end
      local function assertSafeFailure(fixture, stage, failureType)
        local record = failureLog(fixture)
        local allowed = { correlationId = true, code = true, stage = true, failureType = true }
        local count = 0
        for key, value in pairs(record.fields) do
          count = count + 1
          assert(allowed[key] == true)
          local rendered = tostring(value)
          assert(not rendered:find('private', 1, true)
            and not rendered:find('license:', 1, true)
            and not rendered:find('Private Player Name', 1, true))
        end
        assert(count == 4 and record.level == 'error')
        assert(record.fields.code == 'CONNECTION_PIPELINE_FAILED')
        assert(record.fields.stage == stage and record.fields.failureType == failureType)
      end
      assertSafeFailure(failed, 'identity_authentication', 'string')

      local ingressFailed = NewIngressFixture({
        ingressDeferMode = 'throw', maximumConcurrentConnections = 1,
        connectionRate = 100, connectionBurst = 100
      })
      local ingressConnected, ingressError = ingressFailed:connect(-10, {'license:ingress-private'})
      assert(ingressConnected == nil and ingressError.code == 'CONNECTION_PIPELINE_FAILED')
      local ingressSnapshot = ingressFailed:pipeline():snapshot()
      assert(ingressSnapshot.preAuth.active == 0 and ingressSnapshot.openDeferrals == 0)
      assert(ingressFailed:players():summary().pendingConnections == 0)
      assert(ingressFailed:databaseCalls() == 0 and ingressFailed:doneCalls(-10) == 0)
      assertSafeFailure(ingressFailed, 'ingress_deferral', 'string')

      local tableFailed = NewIngressFixture({
        authMode = 'throw_table', maximumConcurrentConnections = 1,
        connectionRate = 100, connectionBurst = 100
      })
      local tableConnected, tableError = tableFailed:connect(-11, {'license:table-private'})
      assert(tableConnected == nil and tableError.code == 'CONNECTION_PIPELINE_FAILED')
      assert(tableFailed:pipeline():snapshot().preAuth.active == 0)
      assert(tableFailed:players():summary().pendingConnections == 0)
      assertSafeFailure(tableFailed, 'identity_authentication', 'table')
      return table.concat({joined.source, queue.peak, stopped.preAuth.active,
        failureSnapshot.preAuth.active, failed:doneCalls(-9)}, ':')
    `);
    assert.equal(result, '41:1:0:0:1');
  } finally {
    engine.global.close();
  }
});

test('Cfx callable deferral funcrefs complete and release the connection lifecycle', async () => {
  const engine = await createEngine();
  try {
    const result = await engine.doString(`
      local callable = NewIngressFixture({
        authMode = 'accept', cfxDeferralFuncrefs = true,
        maximumConcurrentConnections = 1,
        connectionRate = 100, connectionBurst = 100
      })
      local connected, connectionError = callable:connect(-20, {'license:callable'})
      assert(connected == true and connectionError == nil)
      local callableSnapshot = callable:pipeline():snapshot()
      assert(callable:doneCalls(-20) == 1 and callable:reason(-20) == '<accepted>')
      assert(callableSnapshot.openDeferrals == 0 and callableSnapshot.preAuth.active == 1)
      assert(callable:players():summary().pendingConnections == 1)
      for _, record in ipairs(callable:logs()) do
        assert(record.message ~= 'connection pipeline failed')
      end
      callable:pipeline():handleDropped(-20, 'fixture cleanup')
      local releasedSnapshot = callable:pipeline():snapshot()
      assert(releasedSnapshot.preAuth.active == 0 and releasedSnapshot.openDeferrals == 0
        and releasedSnapshot.admissionReservations == 0)
      assert(callable:players():summary().pendingConnections == 0)
      return table.concat({callable:doneCalls(-20), callableSnapshot.openDeferrals,
        callableSnapshot.preAuth.active, releasedSnapshot.preAuth.active}, ':')
    `);
    assert.equal(result, '1:0:1:0');
  } finally {
    engine.global.close();
  }
});
