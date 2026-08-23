import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory, type LuaEngine } from 'wasmoon';

const root = process.cwd();

async function load(engine: LuaEngine, relativePath: string): Promise<void> {
  await engine.doString(await readFile(path.join(root, relativePath), 'utf8'));
}

async function coreEngine(modules: string[]): Promise<LuaEngine> {
  const engine = await new LuaFactory().createEngine();
  await load(engine, 'core/synex_core/shared/protocol.lua');
  await load(engine, 'core/synex_core/server/factories.lua');
  for (const module of modules) {
    await load(engine, `core/synex_core/server/${module}.lua`);
  }
  return engine;
}

async function connectionEngine(): Promise<LuaEngine> {
  return coreEngine([
    'foundation', 'registries', 'identity_connection_replacement',
    'identity_connection_claims', 'identity_connection_authority',
    'identity_connection_ingress', 'identity_connection_terminals',
    'identity_connection_join', 'identity_connection_connecting', 'identity_connection_heartbeat',
    'identity_connection_maintenance', 'identity_connections',
  ]);
}

const connectionFixture = String.raw`
  local function newConnectionFixture(options)
    options = options or {}
    local now = options.now or 1000
    local waits = 0
    local waitHook = nil
    local completions = {}
    local completionOrder = {}
    local staffSources = {}
    local timers = {}
    local timerSequence = 0
    local function drainTimers()
      while true do
        local selectedIndex, selected = nil, nil
        for index, timer in ipairs(timers) do
          if timer.deadline <= now and (selected == nil or timer.deadline < selected.deadline
              or (timer.deadline == selected.deadline and timer.sequence < selected.sequence)) then
            selectedIndex, selected = index, timer
          end
        end
        if not selected then return end
        table.remove(timers, selectedIndex)
        selected.handler()
      end
    end
    local platform = {
      nowGame = function() return now end,
      random = function() return 1 end,
      print = function() end,
      jsonEncode = function() return '{}' end,
      getPlayerIdentifiers = function(source) return {'license:' .. tostring(source)} end,
      isPlayerAceAllowed = function(source, ace)
        return staffSources[source] == true and ace == 'synex.queue.staff'
      end,
      defer = function() end,
      setTimeout = function(delay, handler)
        timerSequence = timerSequence + 1
        timers[#timers + 1] = {
          deadline = now + math.max(0, delay or 0), sequence = timerSequence, handler = handler
        }
      end,
      wait = function(delay)
        now = now + delay
        drainTimers()
        waits = waits + 1
        if waitHook then waitHook(waits, delay) end
        drainTimers()
      end,
      dropPlayer = function() end
    }
    local foundation = SynexCoreFactories.foundation({ platform = platform })
    foundation.configureIds(options.id or 'queue-arbiter-fixture')
    local registries = SynexCoreFactories.registries({ foundation = foundation })
    local players, owners = registries.players, registries.owners
    owners:activate('synex_core')
    local config = {
      duplicatePolicy = 'allow', allowlistRequired = false, queueEnabled = true,
      pendingTtlMs = 120000, gateTimeoutMs = 10000, clusterSessionLeaseSeconds = 45,
      queueUpdateMs = options.queueUpdateMs or 250,
      queueTimeoutMs = options.queueTimeoutMs or 10000,
      maximumActiveSessions = options.maximumActiveSessions or 2,
      maximumQueued = options.maximumQueued or 16,
      queueReservedSlots = options.queueReservedSlots or 0,
      queueStaffPriority = 1000, queueStaffAce = 'synex.queue.staff', maintenanceMode = false
    }
    local leases = {
      acquire = function(_, name, owner, ttl)
        return { name = name, owner = owner, fencingToken = 1, ttlSeconds = ttl }, nil
      end,
      release = function() return true, nil end,
      renew = function() return true, nil end
    }
    local instances = {
      bootId = function() return 'boot-a', nil end,
      requestRemoteKicks = function() return 0, nil end,
      hasOpenUserSessions = function() return false, nil end,
      touchSessions = function() return true, nil end,
      heartbeat = function() return {}, nil end,
      pendingLocalControls = function() return {}, nil end,
      completeControl = function() return true, nil end
    }
    local connection = SynexCoreFactories.identityConnections({
      platform = platform, foundation = foundation, players = players, owners = owners,
      lifecycle = { core = {
        canAdmitPlayers = function() return true end,
        setHealth = function() end
      } },
      messaging = { network = { purgeSource = function() end } }, config = config,
      instanceId = 'instance-a', coreResource = 'synex_core', leases = leases,
      instances = instances,
      rateLimiter = { consume = function() return true, nil end, purge = function() end },
      sha256 = function(value)
        local hash = 2166136261
        for index = 1, #value do hash = ((hash ~ value:byte(index)) * 16777619) & 0xffffffff end
        return string.rep(('%08x'):format(hash), 8)
      end,
      characters = {},
      userRepository = {
        authenticate = function(_, identifiers)
          return { id = tostring(identifiers[1]):gsub('[^A-Za-z0-9_-]', '_'), status = 'active' }, nil
        end
      },
      sessionRepository = {}, accessRepository = { check = function() return true, nil end },
      invokeOwned = function() return true, true, nil end,
      normalizeIdentifiers = function(values)
        return {{ type = 'license', value = values[1], normalized = values[1] }}
      end,
      sessionTransitions = {}, transition = function() return true, nil end
    })
    local function deferrals(source)
      return {
        defer = function() end,
        update = function() end,
        done = function(reason)
          completions[source] = reason == nil and '<accepted>' or reason
          if reason == nil then completionOrder[#completionOrder + 1] = source end
        end
      }
    end
    local fixture = {}
    function fixture:connect(source)
      return connection:handleConnecting(source, 'Player ' .. tostring(source), deferrals(source))
    end
    function fixture:onWait(handler) waitHook = handler end
    function fixture:advance(milliseconds) now = now + milliseconds end
    function fixture:setStaff(source, value) staffSources[source] = value == true end
    function fixture:completion(source) return completions[source] end
    function fixture:completionOrder() return completionOrder end
    function fixture:waits() return waits end
    function fixture:players() return players end
    function fixture:connection() return connection end
    function fixture:snapshot() return connection:snapshot() end
    return fixture
  end
`;

test('player registry maintains an exact O(1) active-session counter across lifecycle mutations', async () => {
  const engine = await coreEngine(['foundation', 'registries']);
  try {
    const result = await engine.doString(`
      local platform = { nowGame = function() return 1000 end, random = function() return 1 end }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      local players = SynexCoreFactories.registries({ foundation = foundation }).players
      assert(players:activeCount() == 0)
      assert(players:createPending(-1, { sessionId = 'session-a' }))
      local first = assert(players:bindJoined(-1, 41, {
        id = 'session-a', userId = 'user-a', state = 'SELECTING_CHARACTER'
      }))
      assert(players:activeCount() == 1)
      assert(players:updateSession(first.id, function(candidate) candidate.state = 'ACTIVE' end))
      assert(players:activeCount() == 1)
      assert(players:detachSource(first.id, first.source, first.sourceGeneration))
      assert(players:activeCount() == 1)

      assert(players:createPending(-2, { sessionId = 'session-a' }))
      local duplicate, duplicateError = players:bindJoined(-2, 42, {
        id = 'session-a', userId = 'user-b', state = 'SELECTING_CHARACTER'
      })
      assert(duplicate == nil and duplicateError.code == 'SESSION_ALREADY_BOUND')
      assert(players:activeCount() == 1)
      assert(players:removeSession(first.id))
      assert(players:activeCount() == 0 and players:removeSession(first.id) == nil)
      return table.concat({duplicateError.code, players:activeCount(), players:summary().activeSessions}, ':')
    `);
    assert.equal(result, 'SESSION_ALREADY_BOUND:0:0');
  } finally {
    engine.global.close();
  }
});

test('queue arbiter skips blocked nonstaff, preserves immutable staff class, and caches ranks', async () => {
  const engine = await connectionEngine();
  try {
    const result = await engine.doString(`${connectionFixture}
      local fixture = newConnectionFixture({
        id = 'queue-priority', maximumActiveSessions = 2, queueReservedSlots = 1
      })
      local players = fixture:players()
      assert(players:createPending(-99, { sessionId = 'occupied' }))
      assert(players:bindJoined(-99, 99, {
        id = 'occupied', userId = 'occupied-user', state = 'SELECTING_CHARACTER'
      }))
      local observedBlocked = false
      fixture:onWait(function(attempt)
        if attempt == 1 then
          assert(players:updatePending(-2, function(candidate) candidate.staff = true end))
        elseif attempt == 2 then
          local beforeStaff = fixture:snapshot()
          assert(beforeStaff.queued == 1 and beforeStaff.granted == 0)
          observedBlocked = true
          fixture:setStaff(-3, true)
          assert(fixture:connect(-3))
          local during = fixture:snapshot()
          assert(fixture:completion(-3) == '<accepted>')
          assert(fixture:completion(-2) == nil)
          assert(during.queued == 1 and during.granted == 0
            and during.admissionReservations == 1 and during.activeSessions == 1)
          fixture:connection():handleDropped(-3, 'fixture cancellation')
          assert(players:removeSession('occupied'))
        end
      end)
      assert(fixture:connect(-2))
      local snapshot = fixture:snapshot()
      local order = fixture:completionOrder()
      assert(observedBlocked and order[1] == -3 and order[2] == -2)
      assert(snapshot.queued == 0 and snapshot.granted == 0)
      assert(snapshot.admitted == 2 and snapshot.peak == 2)
      assert(snapshot.arbiterRuns == 4 and snapshot.queueSorts == 3 and fixture:waits() == 4)
      return table.concat({order[1], order[2], snapshot.admitted,
        snapshot.arbiterRuns, snapshot.queueSorts}, ':')
    `);
    assert.equal(result, '-3:-2:2:4:3');
  } finally {
    engine.global.close();
  }
});

test('expired queue grants release their reservation and record timeout exactly once', async () => {
  const engine = await connectionEngine();
  try {
    const result = await engine.doString(`${connectionFixture}
      local fixture = newConnectionFixture({ id = 'queue-timeout', queueTimeoutMs = 1000 })
      local players = fixture:players()
      local originalGetPending = players.getPending
      local advanced = false
      players.getPending = function(self, source)
        local current = originalGetPending(self, source)
        if not advanced and fixture:snapshot().granted == 1 then
          advanced = true
          fixture:advance(1001)
        end
        return current
      end
      assert(fixture:connect(-1))
      local snapshot = fixture:snapshot()
      assert(advanced and fixture:completion(-1):find('[QUEUE_TIMEOUT]', 1, true))
      assert(snapshot.queued == 0 and snapshot.granted == 0
        and snapshot.admissionReservations == 0)
      assert(snapshot.timedOut == 1 and snapshot.admitted == 0)
      return table.concat({snapshot.timedOut, snapshot.admitted,
        snapshot.admissionReservations, snapshot.queueSorts}, ':')
    `);
    assert.equal(result, '1:0:0:1');
  } finally {
    engine.global.close();
  }
});

test('quiesce atomically revokes a grant before stale waiter consumption', async () => {
  const engine = await connectionEngine();
  try {
    const result = await engine.doString(`${connectionFixture}
      local fixture = newConnectionFixture({ id = 'queue-quiesce' })
      local players = fixture:players()
      local originalGetPending = players.getPending
      local triggered, report = false, nil
      players.getPending = function(self, source)
        local current = originalGetPending(self, source)
        if not triggered and fixture:snapshot().granted == 1 then
          triggered = true
          report = assert(fixture:connection():quiesce())
        end
        return current
      end
      assert(fixture:connect(-1))
      local snapshot = fixture:snapshot()
      assert(triggered and report.removedPending == 1)
      assert(fixture:completion(-1):find('[CORE_STOPPING]', 1, true))
      assert(players:getPending(-1) == nil)
      assert(snapshot.quiesced and snapshot.queued == 0 and snapshot.granted == 0)
      assert(snapshot.admissionReservations == 0 and snapshot.admitted == 0)
      return table.concat({report.removedPending, snapshot.admissionReservations,
        snapshot.admitted, tostring(snapshot.quiesced)}, ':')
    `);
    assert.equal(result, '1:0:0:true');
  } finally {
    engine.global.close();
  }
});

test('multiple waiters invoke only one arbiter and one sort inside one queue interval', async () => {
  const engine = await connectionEngine();
  try {
    const result = await engine.doString(`${connectionFixture}
      local fixture = newConnectionFixture({
        id = 'queue-throttle', maximumActiveSessions = 1, queueUpdateMs = 250
      })
      local players = fixture:players()
      assert(players:createPending(-99, { sessionId = 'occupied' }))
      assert(players:bindJoined(-99, 99, {
        id = 'occupied', userId = 'occupied-user', state = 'SELECTING_CHARACTER'
      }))
      fixture:onWait(function(attempt, delay)
        fixture:advance(-delay)
        if attempt == 1 then
          assert(fixture:connect(-2))
        elseif attempt == 2 then
          assert(fixture:connection():quiesce())
        end
      end)
      assert(fixture:connect(-1))
      local snapshot = fixture:snapshot()
      assert(snapshot.quiesced and snapshot.queued == 0 and snapshot.granted == 0)
      assert(snapshot.peak == 2 and snapshot.arbiterRuns == 1 and snapshot.queueSorts == 1)
      assert(snapshot.admissionReservations == 0)
      return table.concat({snapshot.peak, snapshot.arbiterRuns,
        snapshot.queueSorts, snapshot.admissionReservations}, ':')
    `);
    assert.equal(result, '2:1:1:0');
  } finally {
    engine.global.close();
  }
});
