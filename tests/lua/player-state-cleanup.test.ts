import { readFile } from 'node:fs/promises';
import path from 'node:path';
import assert from 'node:assert/strict';
import test from 'node:test';
import { LuaFactory, type LuaEngine } from 'wasmoon';

const root = process.cwd();

async function load(engine: LuaEngine, relativePath: string): Promise<void> {
  const source = await readFile(path.join(root, relativePath), 'utf8');
  await engine.doString(source);
}

async function createEngine(): Promise<LuaEngine> {
  const engine = await new LuaFactory().createEngine();
  await load(engine, 'core/synex_core/shared/protocol.lua');
  await load(engine, 'core/synex_core/server/factories.lua');
  for (const file of [
    'foundation',
    'registries',
    'contracts',
    'security',
    'state',
    'identity_connection_replacement',
    'identity_connection_heartbeat',
    'identity_connection_maintenance',
    'bootstrap_restart',
  ]) {
    await load(engine, `core/synex_core/server/${file}.lua`);
  }
  await engine.doString(`
    local now = 1000
    FakePlatform = {
      nowGame = function() now = now + 1 return now end,
      random = function(_, maximum) return math.min(maximum or 1, 123456) end,
      print = function() end,
      jsonEncode = function() return '{}' end,
      jsonDecode = function() return {} end,
      loadResourceFile = function() return nil end,
      setTimeout = function(_, callback) callback() end
    }

    function BindPlayer(players, temporarySource, source, sessionId, userId)
      assert(players:createPending(temporarySource, {
        id = 'connection-' .. sessionId,
        tempSource = temporarySource,
        sessionId = sessionId
      }))
      return assert(players:bindJoined(temporarySource, source, {
        id = sessionId,
        userId = userId,
        state = 'ACTIVE',
        source = source,
        sourceGeneration = 0
      }))
    end

    function PlayerStateContext(session)
      return {
        sessionId = assert(session.id),
        sourceGeneration = assert(session.sourceGeneration)
      }
    end

    function CurrentPlayerStateContext(players, source)
      return PlayerStateContext(assert(players:getBySource(source)))
    end

    function NewPlayerStateFixture(replicate, limits)
      limits = limits or {}
      local foundation = SynexCoreFactories.foundation({ platform = FakePlatform })
      foundation.configureIds('player-state-cleanup')
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      registries.owners:activate('synex_core')
      local ownerEpoch = registries.owners:activate('synex_fixture')
      local contracts = SynexCoreFactories.contracts({
        foundation = foundation,
        protocol = SynexProtocol
      })
      local security = SynexCoreFactories.security({
        platform = FakePlatform,
        foundation = foundation,
        coreResource = 'synex_core',
        policy = { default = { allow = {}, deny = {} }, resources = {} }
      })
      local state = SynexCoreFactories.state({
        platform = FakePlatform,
        foundation = foundation,
        contracts = contracts,
        owners = registries.owners,
        players = registries.players,
        security = security,
        coreResource = 'synex_core',
        replicate = replicate,
        maximumReplicationRepairs = limits.maximumReplicationRepairs,
        maximumReplicationRepairBytes = limits.maximumReplicationRepairBytes
      })
      return {
        foundation = foundation,
        registries = registries,
        owners = registries.owners,
        players = registries.players,
        ownerEpoch = ownerEpoch,
        state = state
      }
    end
  `);
  return engine;
}

test('purgePlayer removes only the requested source generation', async () => {
  const engine = await createEngine();
  const result = await engine.doString(`
    local native = {}
    local fixture = NewPlayerStateFixture(function(_, subject, snapshot)
      native[tonumber(subject)] = native[tonumber(subject)] or {}
      native[tonumber(subject)][snapshot.name] = snapshot.value
      return true
    end)
    local definition = {
      name = 'synex_fixture.mode',
      scope = 'player',
      authority = 'owner',
      schema = { type = 'string', minLength = 1 },
      replicated = true
    }
    assert(fixture.state:define('synex_fixture', fixture.ownerEpoch, definition))
    local old = BindPlayer(fixture.players, 100, 42, 'session-old', 'user-old')
    assert(fixture.state:set('synex_fixture', fixture.ownerEpoch, definition.name, 42, 'old',
      PlayerStateContext(old)))
    local detached = assert(fixture.players:detachSource(old.id, 42, old.sourceGeneration))
    local current = BindPlayer(fixture.players, 101, 42, 'session-new', 'user-new')
    assert(current.sourceGeneration > detached.sourceGeneration)
    native[42][definition.name] = 'new-native'

    local report = assert(fixture.state:purgePlayer(42, detached.sourceGeneration))
    assert(report.cleared == 1 and report.replicated == 0 and report.skipped == 1)
    assert(#report.failures == 0 and native[42][definition.name] == 'new-native')

    assert(fixture.state:set('synex_fixture', fixture.ownerEpoch, definition.name, 42, 'new-core',
      PlayerStateContext(current)))
    local staleSet, staleSetError = fixture.state:set(
      'synex_fixture', fixture.ownerEpoch, definition.name, 42, 'stale-write',
      PlayerStateContext(old))
    local staleGet, staleGetError = fixture.state:get(
      'synex_fixture', fixture.ownerEpoch, definition.name, 42, PlayerStateContext(old))
    local staleClear, staleClearError = fixture.state:clear(
      'synex_fixture', fixture.ownerEpoch, definition.name, 42, PlayerStateContext(old))
    assert(staleSet == nil and staleSetError.code == 'STALE_PLAYER_SESSION')
    assert(staleGet == nil and staleGetError.code == 'STALE_PLAYER_SESSION')
    assert(staleClear == nil and staleClearError.code == 'STALE_PLAYER_SESSION')
    local stale = assert(fixture.state:purgePlayer(42, detached.sourceGeneration))
    assert(stale.cleared == 0 and native[42][definition.name] == 'new-core')
    assert(fixture.state:get('synex_fixture', fixture.ownerEpoch, definition.name, 42,
      PlayerStateContext(current)) == 'new-core')
    local invalid, invalidError = fixture.state:purgePlayer(42, 0)
    assert(invalid == nil and invalidError.code == 'INVALID_ARGUMENT')
    return table.concat({report.cleared, report.skipped, current.sourceGeneration}, ':')
  `);
  assert.equal(result, '1:1:3');
  engine.global.close();
});

test('stale replicated writes cannot roll back a replacement session value', async () => {
  const engine = await createEngine();
  const result = await engine.doString(`
    local fixture, replacement, raced = nil, nil, false
    fixture = NewPlayerStateFixture(function(_, _, snapshot)
      if snapshot.value == 'from-a' and not raced then
        raced = true
        local first = assert(fixture.players:getBySource(42))
        assert(fixture.players:detachSource(first.id, 42, first.sourceGeneration))
        replacement = BindPlayer(
          fixture.players, 102, 42, 'session-race-b', 'user-race-b')
        assert(fixture.state:set('synex_fixture', fixture.ownerEpoch,
          'synex_fixture.race', 42, 'from-b', PlayerStateContext(replacement)))
      end
      return true
    end)
    assert(fixture.state:define('synex_fixture', fixture.ownerEpoch, {
      name = 'synex_fixture.race',
      scope = 'player',
      authority = 'owner',
      schema = { type = 'string', minLength = 1 },
      replicated = true
    }))
    local first = BindPlayer(fixture.players, 101, 42, 'session-race-a', 'user-race-a')
    local written, writeError = fixture.state:set('synex_fixture', fixture.ownerEpoch,
      'synex_fixture.race', 42, 'from-a', PlayerStateContext(first))
    assert(written == nil and writeError.code == 'STALE_PLAYER_SESSION')
    assert(fixture.state:get('synex_fixture', fixture.ownerEpoch,
      'synex_fixture.race', 42, PlayerStateContext(replacement)) == 'from-b')
    return table.concat({writeError.code, replacement.sourceGeneration}, ':')
  `);
  assert.equal(result, 'STALE_PLAYER_SESSION:3');
  engine.global.close();
});

test('reentrant global replication cannot be overwritten by stale accounting finalization', async () => {
  const engine = await createEngine();
  const result = await engine.doString(`
    local fixture, nested = nil, false
    fixture = NewPlayerStateFixture(function(_, _, snapshot)
      if snapshot.value == 'a' and not nested then
        nested = true
        assert(fixture.state:set('synex_fixture', fixture.ownerEpoch,
          'synex_fixture.global_race', nil, 'newer-b'))
      end
      return true
    end)
    assert(fixture.state:define('synex_fixture', fixture.ownerEpoch, {
      name = 'synex_fixture.global_race',
      scope = 'global',
      authority = 'owner',
      schema = { type = 'string', minLength = 1 },
      replicated = true,
      maximumBytes = 1024
    }))
    assert(fixture.state:set('synex_fixture', fixture.ownerEpoch,
      'synex_fixture.global_race', nil, string.rep('x', 100)))
    local stale, staleError = fixture.state:set('synex_fixture', fixture.ownerEpoch,
      'synex_fixture.global_race', nil, 'a')
    assert(stale == nil and staleError.code == 'STATE_WRITE_CONFLICT')
    assert(fixture.state:get('synex_fixture', fixture.ownerEpoch,
      'synex_fixture.global_race', nil) == 'newer-b')
    return staleError.code
  `);
  assert.equal(result, 'STATE_WRITE_CONFLICT');
  engine.global.close();
});

test('owner restore fencing preserves a concurrent write on direct and later rollback conflicts', async () => {
  const engine = await createEngine();
  const result = await engine.doString(`
    local fixture, phase, nested = nil, 'seed', false
    fixture = NewPlayerStateFixture(function(_, _, snapshot)
      if phase == 'direct-race' and snapshot.name == 'synex_fixture.first'
        and snapshot.value == 'snapshot-first' and not nested then
        nested = true
        assert(fixture.state:set('synex_fixture', fixture.ownerEpoch + 2,
          'synex_fixture.first', nil, 'concurrent-direct'))
      elseif phase == 'later-failure' and snapshot.name == 'synex_fixture.second'
        and snapshot.value == 'snapshot-second' and not nested then
        nested = true
        assert(fixture.state:set('synex_fixture', fixture.ownerEpoch + 2,
          'synex_fixture.first', nil, 'concurrent-later'))
        return nil, { code = 'FIXTURE_REPLICATION_FAILED' }
      end
      return true
    end)
    local function definition(name)
      return {
        name = name,
        scope = 'global',
        authority = 'owner',
        schema = { type = 'string', minLength = 1 },
        replicated = true,
        persistent = true,
        sensitive = false
      }
    end
    assert(fixture.state:define('synex_fixture', fixture.ownerEpoch,
      definition('synex_fixture.first')))
    assert(fixture.state:define('synex_fixture', fixture.ownerEpoch,
      definition('synex_fixture.second')))
    assert(fixture.state:set('synex_fixture', fixture.ownerEpoch,
      'synex_fixture.first', nil, 'snapshot-first'))
    assert(fixture.state:set('synex_fixture', fixture.ownerEpoch,
      'synex_fixture.second', nil, 'snapshot-second'))
    local snapshot = assert(fixture.state:captureOwner(
      'synex_fixture', fixture.ownerEpoch))
    assert(#fixture.owners:purge('synex_fixture', fixture.ownerEpoch, 'direct race').errors == 0)
    local nextEpoch = fixture.owners:activate('synex_fixture')
    assert(nextEpoch == fixture.ownerEpoch + 2)
    assert(fixture.state:define('synex_fixture', nextEpoch,
      definition('synex_fixture.first')))
    assert(fixture.state:define('synex_fixture', nextEpoch,
      definition('synex_fixture.second')))

    phase, nested = 'direct-race', false
    local direct, directError = fixture.state:restoreOwner(
      'synex_fixture', nextEpoch, snapshot)
    assert(direct == nil and directError.code == 'STATE_WRITE_CONFLICT')
    assert(fixture.state:get('synex_fixture', nextEpoch,
      'synex_fixture.first', nil) == 'concurrent-direct')

    assert(fixture.state:clear('synex_fixture', nextEpoch,
      'synex_fixture.first', nil))
    phase, nested = 'later-failure', false
    local later, laterError = fixture.state:restoreOwner(
      'synex_fixture', nextEpoch, snapshot)
    assert(later == nil and laterError.code == 'STATE_REPLICATION_FAILED')
    assert(fixture.state:get('synex_fixture', nextEpoch,
      'synex_fixture.first', nil) == 'concurrent-later')
    assert(fixture.state:get('synex_fixture', nextEpoch,
      'synex_fixture.second', nil) == nil)
    return directError.code .. ':' .. laterError.code
  `);
  assert.equal(result, 'STATE_WRITE_CONFLICT:STATE_REPLICATION_FAILED');
  engine.global.close();
});

test('failed replicated cleanup remains bounded, hidden, retryable, and supersedable', async () => {
  const engine = await createEngine();
  const result = await engine.doString(`
    local failClear = true
    local native = {}
    local fixture = NewPlayerStateFixture(function(_, _, snapshot)
      if snapshot.value == nil and failClear then
        return nil, { code = 'FIXTURE_REPLICATION_FAILED' }
      end
      native[snapshot.name] = snapshot.value
      return true
    end)
    local function definition(name)
      return {
        name = name,
        scope = 'global',
        authority = 'owner',
        schema = { type = 'string', minLength = 1 },
        replicated = true
      }
    end
    assert(fixture.state:define('synex_fixture', fixture.ownerEpoch,
      definition('synex_fixture.retry')))
    assert(fixture.state:define('synex_fixture', fixture.ownerEpoch,
      definition('synex_fixture.supersede')))
    assert(fixture.state:set('synex_fixture', fixture.ownerEpoch,
      'synex_fixture.retry', nil, 'stale-retry'))
    assert(fixture.state:set('synex_fixture', fixture.ownerEpoch,
      'synex_fixture.supersede', nil, 'stale-supersede'))
    local cleanup = fixture.owners:purge(
      'synex_fixture', fixture.ownerEpoch, 'replication retry')
    assert(#cleanup.errors == 0)
    local pending = fixture.state:snapshot().storage
    assert(pending.values == 2 and pending.replicationCleanupPending == 2)

    local first = assert(fixture.state:retryReplicationCleanup(1))
    assert(first.inspected == 1 and #first.failures == 1 and first.remaining == 2)
    local second = assert(fixture.state:retryReplicationCleanup(1))
    assert(second.inspected == 1 and #second.failures == 1 and second.remaining == 2)

    local nextEpoch = fixture.owners:activate('synex_fixture')
    assert(fixture.state:define('synex_fixture', nextEpoch,
      definition('synex_fixture.supersede')))
    assert(fixture.state:set('synex_fixture', nextEpoch,
      'synex_fixture.supersede', nil, 'current'))
    assert(fixture.state:get('synex_fixture', nextEpoch,
      'synex_fixture.supersede', nil) == 'current')
    failClear = false
    local recovered = assert(fixture.state:retryReplicationCleanup(2))
    assert(recovered.cleared == 1 and recovered.remaining == 0)
    local final = fixture.state:snapshot().storage
    assert(final.values == 1 and final.replicationCleanupPending == 0)
    assert(native['synex_fixture.retry'] == nil
      and native['synex_fixture.supersede'] == 'current')
    return table.concat({first.remaining, second.remaining,
      recovered.cleared, final.values}, ':')
  `);
  assert.equal(result, '2:2:1:1');
  engine.global.close();
});

test('pending cleanup tombstones survive failed overwrite rollback and gate local supersession', async () => {
  const engine = await createEngine();
  const result = await engine.doString(`
    local phase = 'seed'
    local native = {}
    local replicatedFixture = NewPlayerStateFixture(function(_, _, snapshot)
      if phase == 'purge-failure' and snapshot.value == nil then
        return nil, { code = 'FIXTURE_CLEAR_FAILED' }
      end
      if phase == 'write-failure' and snapshot.value == 'replacement' then
        return nil, { code = 'FIXTURE_WRITE_FAILED' }
      end
      native[snapshot.name] = snapshot.value
      return true
    end)
    local function definition(name, replicated)
      return {
        name = name,
        scope = 'global',
        authority = 'owner',
        schema = { type = 'string', minLength = 1 },
        replicated = replicated
      }
    end
    local rollbackName = 'synex_fixture.rollback_tombstone'
    assert(replicatedFixture.state:define('synex_fixture',
      replicatedFixture.ownerEpoch, definition(rollbackName, true)))
    assert(replicatedFixture.state:set('synex_fixture',
      replicatedFixture.ownerEpoch, rollbackName, nil, 'stale'))
    phase = 'purge-failure'
    assert(#replicatedFixture.owners:purge('synex_fixture',
      replicatedFixture.ownerEpoch, 'fixture restart').errors == 0)
    local rollbackEpoch = replicatedFixture.owners:activate('synex_fixture')
    assert(replicatedFixture.state:define('synex_fixture',
      rollbackEpoch, definition(rollbackName, true)))
    phase = 'write-failure'
    local replaced, replaceError = replicatedFixture.state:set(
      'synex_fixture', rollbackEpoch, rollbackName, nil, 'replacement')
    assert(replaced == nil and replaceError.code == 'STATE_REPLICATION_FAILED')
    local rollbackStorage = replicatedFixture.state:snapshot().storage
    assert(rollbackStorage.values == 1
      and rollbackStorage.replicationCleanupPending == 1)
    assert(replicatedFixture.state:get('synex_fixture',
      rollbackEpoch, rollbackName, nil) == nil)
    phase = 'recover'
    local recovered = assert(replicatedFixture.state:retryReplicationCleanup(1))
    assert(recovered.cleared == 1 and recovered.remaining == 0)
    assert(native[rollbackName] == nil)

    local localPhase = 'seed'
    local localNative = {}
    local localFixture = NewPlayerStateFixture(function(_, _, snapshot)
      if localPhase == 'clear-failure' and snapshot.value == nil then
        return nil, { code = 'FIXTURE_CLEAR_FAILED' }
      end
      localNative[snapshot.name] = snapshot.value
      return true
    end)
    local localName = 'synex_fixture.local_supersession'
    assert(localFixture.state:define('synex_fixture', localFixture.ownerEpoch,
      definition(localName, true)))
    assert(localFixture.state:set('synex_fixture', localFixture.ownerEpoch,
      localName, nil, 'remote-stale'))
    localPhase = 'clear-failure'
    assert(#localFixture.owners:purge('synex_fixture', localFixture.ownerEpoch,
      'fixture restart').errors == 0)
    local localEpoch = localFixture.owners:activate('synex_fixture')
    assert(localFixture.state:define('synex_fixture', localEpoch,
      definition(localName, false)))
    local blocked, blockedError = localFixture.state:set(
      'synex_fixture', localEpoch, localName, nil, 'local-only')
    assert(blocked == nil and blockedError.code == 'STATE_REPLICATION_FAILED')
    assert(localFixture.state:snapshot().storage.replicationCleanupPending == 1)
    assert(localNative[localName] == 'remote-stale')
    localPhase = 'recover'
    assert(localFixture.state:set('synex_fixture', localEpoch,
      localName, nil, 'local-only'))
    assert(localFixture.state:get('synex_fixture', localEpoch,
      localName, nil) == 'local-only')
    assert(localFixture.state:snapshot().storage.replicationCleanupPending == 0)
    assert(localNative[localName] == nil)
    return table.concat({replaceError.code, blockedError.code,
      recovered.cleared}, ':')
  `);
  assert.equal(result, 'STATE_REPLICATION_FAILED:STATE_REPLICATION_FAILED:1');
  engine.global.close();
});

test('local supersession revalidates player authority after yielding cleanup', async () => {
  const engine = await createEngine();
  const result = await engine.doString(`
    local phase = 'seed'
    local fixture, replacement = nil, nil
    fixture = NewPlayerStateFixture(function(_, _, snapshot)
      if phase == 'purge-failure' and snapshot.value == nil then
        return nil, { code = 'FIXTURE_CLEAR_FAILED' }
      end
      if phase == 'replace-during-clear' and snapshot.value == nil then
        phase = 'replaced'
        local current = assert(fixture.players:getBySource(42))
        assert(fixture.players:detachSource(
          current.id, 42, current.sourceGeneration))
        replacement = BindPlayer(
          fixture.players, 101, 42, 'session-replacement', 'user-replacement')
      end
      return true
    end)
    local stateName = 'synex_fixture.player_supersession'
    local function definition(replicated)
      return {
        name = stateName,
        scope = 'player',
        authority = 'owner',
        schema = { type = 'string', minLength = 1 },
        replicated = replicated
      }
    end
    local old = BindPlayer(fixture.players, 100, 42, 'session-old', 'user-old')
    local oldContext = PlayerStateContext(old)
    assert(fixture.state:define(
      'synex_fixture', fixture.ownerEpoch, definition(true)))
    assert(fixture.state:set('synex_fixture', fixture.ownerEpoch,
      stateName, 42, 'stale-value', oldContext))
    phase = 'purge-failure'
    assert(#fixture.owners:purge(
      'synex_fixture', fixture.ownerEpoch, 'fixture restart').errors == 0)
    local currentEpoch = fixture.owners:activate('synex_fixture')
    assert(fixture.state:define(
      'synex_fixture', currentEpoch, definition(false)))
    phase = 'replace-during-clear'
    local written, writeError = fixture.state:set(
      'synex_fixture', currentEpoch, stateName, 42, 'must-not-store', oldContext)
    assert(written == nil and writeError.code == 'STALE_PLAYER_SESSION')
    assert(phase == 'replaced' and replacement ~= nil
      and fixture.players:getBySource(42).id == replacement.id)
    assert(fixture.state:get('synex_fixture', currentEpoch, stateName, 42,
      PlayerStateContext(replacement)) == nil)
    local recovered = assert(fixture.state:retryReplicationCleanup(1))
    local storage = fixture.state:snapshot().storage
    assert(recovered.cleared == 1 and recovered.remaining == 0
      and storage.values == 0 and storage.replicationCleanupPending == 0)
    return table.concat({writeError.code, recovered.cleared,
      replacement.sourceGeneration}, ':')
  `);
  assert.equal(result, 'STALE_PLAYER_SESSION:1:3');
  engine.global.close();
});

test('purgePlayer uses mutation and generation CAS across reentrant source replacement', async () => {
  const engine = await createEngine();
  const result = await engine.doString(`
    local fixture, replacement = nil, nil
    local raced = false
    local native = {}
    fixture = NewPlayerStateFixture(function(_, subject, snapshot)
      native[tonumber(subject)] = native[tonumber(subject)] or {}
      native[tonumber(subject)][snapshot.name] = snapshot.value
      if snapshot.value == nil and not raced then
        raced = true
        local previous = assert(fixture.players:getBySource(42))
        assert(fixture.players:detachSource(
          previous.id, 42, previous.sourceGeneration))
        replacement = BindPlayer(
          fixture.players, 111, 42, 'session-purge-b', 'user-purge-b')
        assert(fixture.state:set('synex_fixture', fixture.ownerEpoch,
          'synex_fixture.purge_race', 42, 'replacement',
          PlayerStateContext(replacement)))
      end
      return true
    end)
    assert(fixture.state:define('synex_fixture', fixture.ownerEpoch, {
      name = 'synex_fixture.purge_race',
      scope = 'player',
      authority = 'owner',
      schema = { type = 'string', minLength = 1 },
      replicated = true
    }))
    local previous = BindPlayer(
      fixture.players, 110, 42, 'session-purge-a', 'user-purge-a')
    assert(fixture.state:set('synex_fixture', fixture.ownerEpoch,
      'synex_fixture.purge_race', 42, 'previous', PlayerStateContext(previous)))
    local report = assert(fixture.state:purgePlayer(42, previous.sourceGeneration))
    assert(report.cleared == 0 and report.replicated == 0
      and report.superseded == 1 and #report.failures == 0)
    assert(fixture.state:get('synex_fixture', fixture.ownerEpoch,
      'synex_fixture.purge_race', 42, PlayerStateContext(replacement)) == 'replacement')
    assert(native[42]['synex_fixture.purge_race'] == 'replacement')
    return table.concat({report.cleared, report.superseded,
      replacement.sourceGeneration}, ':')
  `);
  assert.equal(result, '0:1:3');
  engine.global.close();
});

test('player cleanup retry fails closed when the exact source generation is absent', async () => {
  const engine = await createEngine();
  const result = await engine.doString(`
    local clearCalls = 0
    local failClear = true
    local fixture = NewPlayerStateFixture(function(_, _, snapshot)
      if snapshot.value == nil then
        clearCalls = clearCalls + 1
        if failClear then return nil, { code = 'FIXTURE_CLEAR_FAILED' } end
      end
      return true
    end)
    assert(fixture.state:define('synex_fixture', fixture.ownerEpoch, {
      name = 'synex_fixture.retry_generation',
      scope = 'player',
      authority = 'owner',
      schema = { type = 'boolean' },
      replicated = true
    }))
    local session = BindPlayer(
      fixture.players, 120, 24, 'session-retry-generation', 'user-retry-generation')
    assert(fixture.state:set('synex_fixture', fixture.ownerEpoch,
      'synex_fixture.retry_generation', 24, true, PlayerStateContext(session)))
    local purge = assert(fixture.state:purgePlayer(24, session.sourceGeneration))
    assert(#purge.failures == 1 and clearCalls == 1)
    assert(fixture.players:detachSource(session.id, 24, session.sourceGeneration))
    failClear = false
    local retry = assert(fixture.state:retryReplicationCleanup(1))
    assert(retry.cleared == 1 and retry.remaining == 0 and clearCalls == 1)
    assert(fixture.state:snapshot().storage.replicationCleanupPending == 0)
    return table.concat({purge.failures[1].code, retry.cleared, clearCalls}, ':')
  `);
  assert.equal(result, 'FIXTURE_CLEAR_FAILED:1:1');
  engine.global.close();
});

test('failed restore compensation is retained in the bounded replication repair queue', async () => {
  const engine = await createEngine();
  const result = await engine.doString(`
    local phase = 'seed'
    local secondFailed = false
    local remote = {}
    local fixture = NewPlayerStateFixture(function(_, _, snapshot)
      if phase == 'restore' and snapshot.name == 'synex_fixture.repair_second'
        and snapshot.value == 'snapshot-second' then
        secondFailed = true
        return nil, { code = 'FIXTURE_RESTORE_FAILED' }
      end
      if phase == 'restore' and secondFailed
        and snapshot.name == 'synex_fixture.repair_first'
        and snapshot.value == nil then
        return nil, { code = 'FIXTURE_COMPENSATION_FAILED' }
      end
      remote[snapshot.name] = snapshot.value
      return true
    end, {
      maximumReplicationRepairs = 1,
      maximumReplicationRepairBytes = 1024
    })
    local function definition(name)
      return {
        name = name,
        scope = 'global',
        authority = 'owner',
        schema = { type = 'string', minLength = 1 },
        replicated = true,
        persistent = true,
        sensitive = false
      }
    end
    assert(fixture.state:define('synex_fixture', fixture.ownerEpoch,
      definition('synex_fixture.repair_first')))
    assert(fixture.state:define('synex_fixture', fixture.ownerEpoch,
      definition('synex_fixture.repair_second')))
    assert(fixture.state:set('synex_fixture', fixture.ownerEpoch,
      'synex_fixture.repair_first', nil, 'snapshot-first'))
    assert(fixture.state:set('synex_fixture', fixture.ownerEpoch,
      'synex_fixture.repair_second', nil, 'snapshot-second'))
    local snapshot = assert(fixture.state:captureOwner(
      'synex_fixture', fixture.ownerEpoch))
    assert(#fixture.owners:purge('synex_fixture', fixture.ownerEpoch,
      'fixture restart').errors == 0)
    local nextEpoch = fixture.owners:activate('synex_fixture')
    assert(fixture.state:define('synex_fixture', nextEpoch,
      definition('synex_fixture.repair_first')))
    assert(fixture.state:define('synex_fixture', nextEpoch,
      definition('synex_fixture.repair_second')))
    phase = 'restore'
    local restored, restoreError = fixture.state:restoreOwner(
      'synex_fixture', nextEpoch, snapshot)
    assert(restored == nil and restoreError.code == 'STATE_REPLICATION_FAILED')
    assert(fixture.state:get('synex_fixture', nextEpoch,
      'synex_fixture.repair_first', nil) == nil)
    assert(remote['synex_fixture.repair_first'] == 'snapshot-first')
    local queued = fixture.state:snapshot().storage
    assert(queued.replicationRepairPending == 1
      and queued.replicationRepairBytes == 0
      and queued.limits.replicationRepairs == 1)
    phase = 'repair'
    local repaired = assert(fixture.state:retryReplicationCleanup(1))
    assert(repaired.repaired == 1 and repaired.remaining == 0)
    assert(remote['synex_fixture.repair_first'] == nil)
    local final = fixture.state:snapshot().storage
    assert(final.replicationRepairPending == 0
      and final.replicationRepairBytes == 0)
    return table.concat({restoreError.code, queued.replicationRepairPending,
      repaired.repaired}, ':')
  `);
  assert.equal(result, 'STATE_REPLICATION_FAILED:1:1');
  engine.global.close();
});

test('owner handoff neither clears nor restores player state across source reuse', async () => {
  const engine = await createEngine();
  const result = await engine.doString(`
    local native = {}
    local fixture = NewPlayerStateFixture(function(_, subject, snapshot)
      native[tonumber(subject)] = native[tonumber(subject)] or {}
      native[tonumber(subject)][snapshot.name] = snapshot.value
      return true
    end)
    local definition = {
      name = 'synex_fixture.presence',
      scope = 'player',
      authority = 'owner',
      schema = { type = 'string', minLength = 1 },
      replicated = true,
      persistent = true,
      sensitive = false
    }
    assert(fixture.state:define('synex_fixture', fixture.ownerEpoch, definition))
    local old = BindPlayer(fixture.players, 200, 17, 'session-before-restart', 'user-before')
    assert(fixture.state:set('synex_fixture', fixture.ownerEpoch, definition.name, 17, 'before',
      PlayerStateContext(old)))
    local snapshot = assert(fixture.state:captureOwner('synex_fixture', fixture.ownerEpoch))
    assert(snapshot.values[1].sourceGeneration == old.sourceGeneration)

    assert(fixture.players:detachSource(old.id, 17, old.sourceGeneration))
    local current = BindPlayer(fixture.players, 201, 17, 'session-after-restart', 'user-after')
    native[17][definition.name] = 'new-native'
    local cleanup = fixture.owners:purge('synex_fixture', fixture.ownerEpoch, 'owner restart')
    assert(#cleanup.errors == 0 and native[17][definition.name] == 'new-native')

    local nextEpoch = fixture.owners:activate('synex_fixture')
    assert(nextEpoch == fixture.ownerEpoch + 2)
    assert(fixture.state:define('synex_fixture', nextEpoch, definition))
    local restored = assert(fixture.state:restoreOwner('synex_fixture', nextEpoch, snapshot))
    assert(restored.restored == 0 and restored.skipped == 1)
    assert(native[17][definition.name] == 'new-native')
    assert(fixture.state:get('synex_fixture', nextEpoch, definition.name, 17,
      PlayerStateContext(current)) == nil)
    return table.concat({restored.restored, restored.skipped, current.sourceGeneration}, ':')
  `);
  assert.equal(result, '0:1:3');
  engine.global.close();
});

test('purgeAllPlayers clears current state and failed first writes leave no bucket', async () => {
  const engine = await createEngine();
  const result = await engine.doString(`
    local native = {}
    local fail = false
    local fixture = NewPlayerStateFixture(function(_, subject, snapshot)
      if fail then return nil, { code = 'STATE_BAG_UNAVAILABLE' } end
      native[tonumber(subject)] = native[tonumber(subject)] or {}
      native[tonumber(subject)][snapshot.name] = snapshot.value
      return true
    end)
    local definition = {
      name = 'synex_fixture.ready',
      scope = 'player',
      authority = 'owner',
      schema = { type = 'boolean' },
      replicated = true
    }
    assert(fixture.state:define('synex_fixture', fixture.ownerEpoch, definition))
    local eight = BindPlayer(fixture.players, 300, 8, 'session-eight', 'user-eight')
    local nine = BindPlayer(fixture.players, 301, 9, 'session-nine', 'user-nine')
    assert(fixture.state:set('synex_fixture', fixture.ownerEpoch, definition.name, 8, false,
      PlayerStateContext(eight)))
    fail = true
    local failedUpdate, failedUpdateError = fixture.state:set(
      'synex_fixture', fixture.ownerEpoch, definition.name, 8, true, PlayerStateContext(eight))
    assert(failedUpdate == nil and failedUpdateError.code == 'STATE_REPLICATION_FAILED')
    assert(fixture.state:get('synex_fixture', fixture.ownerEpoch, definition.name, 8,
      PlayerStateContext(eight)) == false)
    local rejected, rejectError = fixture.state:set(
      'synex_fixture', fixture.ownerEpoch, definition.name, 9, true, PlayerStateContext(nine))
    assert(rejected == nil and rejectError.code == 'STATE_REPLICATION_FAILED')
    assert(fixture.state:snapshot().counts.player == 1)

    fail = false
    assert(fixture.state:set('synex_fixture', fixture.ownerEpoch, definition.name, 9, true,
      PlayerStateContext(nine)))
    local report = assert(fixture.state:purgeAllPlayers())
    assert(report.players == 2 and report.cleared == 2 and report.replicated == 2)
    assert(report.skipped == 0 and #report.failures == 0)
    assert(fixture.state:snapshot().counts.player == 0)
    assert(native[8][definition.name] == nil and native[9][definition.name] == nil)
    return table.concat({report.players, report.cleared, report.replicated}, ':')
  `);
  assert.equal(result, '2:2:2');
  engine.global.close();
});

test('disconnect detaches authority before state and network generation cleanup', async () => {
  const engine = await createEngine();
  const result = await engine.doString(`
    local function defineState(fixture, name)
      assert(fixture.state:define('synex_fixture', fixture.ownerEpoch, {
        name = name,
        scope = 'player',
        authority = 'owner',
        schema = { type = 'string', minLength = 1 },
        replicated = true
      }))
    end

    local dropOrder = {}
    local dropFixture
    dropFixture = NewPlayerStateFixture(function(_, subject, snapshot)
      if snapshot.value == nil then
        local current = assert(dropFixture.players:getSession('session-drop'))
        assert(current.source == nil)
        dropOrder[#dropOrder + 1] = 'state'
      end
      return true
    end)
    defineState(dropFixture, 'synex_fixture.drop_state')
    local dropping = BindPlayer(dropFixture.players, 400, 31, 'session-drop', 'user-drop')
    assert(dropFixture.state:set(
      'synex_fixture', dropFixture.ownerEpoch, 'synex_fixture.drop_state', 31, 'active',
      PlayerStateContext(dropping)))
    local maintenance = SynexCoreFactories.identityConnectionMaintenance({
      platform = FakePlatform,
      foundation = dropFixture.foundation,
      players = dropFixture.players,
      lifecycle = { core = { setHealth = function() end } },
      messaging = { network = { purgeSource = function()
        dropOrder[#dropOrder + 1] = 'network'
        return true
      end } },
      stateService = dropFixture.state,
      leases = {},
      instances = {},
      characters = { unload = function() return true end },
      sessionRepository = { close = function() return true end },
      sessionTransitions = { ACTIVE = { DISCONNECTING = true } },
      transition = function(session, target) session.state = target return true end,
      rateLimiter = { purge = function() return true end },
      joinClaims = { invalidate = function() return true end },
      logConnectionStage = function() end,
      releaseAdmission = function() return true end,
      releaseConnectionLease = function() return true end,
      refreshLeaseDeadline = function() return 26000 end,
      clearQueueEntry = function() end,
      recordReconnectGrace = function() end,
      purgeReconnectGrace = function() end,
      isQuiesced = function() return false end
    })
    local dropped = assert(maintenance:handleDropped(31, 'test disconnect'))
    assert(#dropped.failures == 0 and dropFixture.players:getSession(dropping.id) == nil)
    assert(table.concat(dropOrder, ',') == 'network')
    assert(dropFixture.state:snapshot().counts.player == 0)

    local replaceOrder = {}
    local replaceFixture
    replaceFixture = NewPlayerStateFixture(function(_, subject, snapshot)
      if snapshot.value == nil then
        local current = assert(replaceFixture.players:getBySource(tonumber(subject)))
        assert(current.id == 'session-replace')
        replaceOrder[#replaceOrder + 1] = 'state'
      end
      return true
    end)
    defineState(replaceFixture, 'synex_fixture.replace_state')
    local replacing = BindPlayer(
      replaceFixture.players, 401, 32, 'session-replace', 'user-replace')
    assert(replaceFixture.state:set(
      'synex_fixture', replaceFixture.ownerEpoch, 'synex_fixture.replace_state', 32, 'active',
      PlayerStateContext(replacing)))
    local replacement = SynexCoreFactories.identityConnectionReplacement({
      platform = {
        dropPlayer = function()
          replaceOrder[#replaceOrder + 1] = 'drop'
          return true
        end
      },
      foundation = replaceFixture.foundation,
      players = replaceFixture.players,
      messaging = { network = { purgeSource = function()
        replaceOrder[#replaceOrder + 1] = 'network'
        return true
      end } },
      stateService = replaceFixture.state,
      characters = { unload = function() return true end },
      sessionRepository = { close = function() return true end },
      releaseConnectionLease = function() return true end,
      isQuiesced = function() return false end
    })
    assert(replacement:replace('user-replace'))
    assert(table.concat(replaceOrder, ',') == 'state,network,drop')
    assert(replaceFixture.state:snapshot().counts.player == 0)

    local failureFixture
    failureFixture = NewPlayerStateFixture(function(_, _, snapshot)
      if snapshot.value == nil then
        return nil, failureFixture.foundation.error(
          'FIXTURE_REPLICATION_FAILED', 'fixture replication failure')
      end
      return true
    end)
    defineState(failureFixture, 'synex_fixture.failed_replace_state')
    local failedReplacing = BindPlayer(
      failureFixture.players, 402, 33, 'session-failed-replace', 'user-failed-replace')
    assert(failureFixture.state:set(
      'synex_fixture', failureFixture.ownerEpoch,
      'synex_fixture.failed_replace_state', 33, 'active',
      PlayerStateContext(failedReplacing)))
    local failingReplacement = SynexCoreFactories.identityConnectionReplacement({
      platform = { dropPlayer = function() return true end },
      foundation = failureFixture.foundation,
      players = failureFixture.players,
      messaging = { network = { purgeSource = function() return true end } },
      stateService = failureFixture.state,
      characters = { unload = function() return true end },
      sessionRepository = { close = function() return true end },
      releaseConnectionLease = function() return true end,
      isQuiesced = function() return false end
    })
    local failedReplacement, failedReplacementError = failingReplacement:replace('user-failed-replace')
    assert(failedReplacement == nil and failedReplacementError.code == 'PLAYER_STATE_PURGE_FAILED')
    assert(failedReplacementError.retryable == true
      and failedReplacementError.details.failures == 1)
    return table.concat(dropOrder, ',') .. ':' .. table.concat(replaceOrder, ',')
      .. ':' .. failedReplacementError.code
  `);
  assert.equal(result, 'network:state,network,drop:PLAYER_STATE_PURGE_FAILED');
  engine.global.close();
});

test('playerDropped without a session purges unauthenticated ingress and pending authority', async () => {
  const engine = await createEngine();
  const result = await engine.doString(`
    local fixture = NewPlayerStateFixture(function() return true end)
    assert(fixture.players:createPending(77, {
      id = 'pending-drop',
      tempSource = 77,
      sessionId = 'pending-session',
      userId = 'pending-user'
    }))
    local ingressSource, ingressGeneration = nil, 'not-called'
    local queueClears, admissions, leases = 0, 0, 0
    local maintenance = SynexCoreFactories.identityConnectionMaintenance({
      platform = FakePlatform,
      foundation = fixture.foundation,
      players = fixture.players,
      lifecycle = { core = { setHealth = function() end } },
      messaging = { network = { purgeSource = function(_, source, generation)
        ingressSource, ingressGeneration = source, generation
        return true
      end } },
      stateService = { purgePlayer = function() error('must not purge authenticated state') end },
      leases = {},
      instances = {},
      characters = {},
      sessionRepository = {},
      sessionTransitions = {},
      transition = function() end,
      rateLimiter = { purge = function() return true end },
      joinClaims = { invalidate = function() return true end },
      logConnectionStage = function() end,
      releaseAdmission = function() admissions = admissions + 1 return true end,
      releaseConnectionLease = function() leases = leases + 1 return true end,
      refreshLeaseDeadline = function() return 26000 end,
      clearQueueEntry = function() queueClears = queueClears + 1 end,
      recordReconnectGrace = function() end,
      purgeReconnectGrace = function() end,
      isQuiesced = function() return false end
    })
    maintenance:handleDropped(77, 'pending disconnect')
    assert(ingressSource == 77 and ingressGeneration == nil)
    assert(fixture.players:getPending(77) == nil)
    assert(queueClears == 1 and admissions == 1 and leases == 1)
    return table.concat({ingressSource, queueClears, admissions, leases}, ':')
  `);
  assert.equal(result, '77:1:1:1');
  engine.global.close();
});

test('prepared and raw core stops clear replicated player state before player eviction', async () => {
  const engine = await createEngine();
  const result = await engine.doString(`
    local order = {}
    local fixture = NewPlayerStateFixture(function(_, _, snapshot)
      if snapshot.value == nil then order[#order + 1] = 'state' end
      return true
    end)
    assert(fixture.state:define('synex_fixture', fixture.ownerEpoch, {
      name = 'synex_fixture.restart_state',
      scope = 'player',
      authority = 'owner',
      schema = { type = 'boolean' },
      replicated = true
    }))
    local restarting = BindPlayer(
      fixture.players, 500, 55, 'session-restart', 'user-restart')
    assert(fixture.state:set(
      'synex_fixture', fixture.ownerEpoch, 'synex_fixture.restart_state', 55, true,
      PlayerStateContext(restarting)))

    local lifecycleState = 'READY'
    local controller = SynexCoreFactories.bootstrapRestart({
      foundation = fixture.foundation,
      runtimeGate = { stop = function() return true end },
      lifecycle = { core = {
        get = function() return lifecycleState end,
        setCriticalFoundationsValidated = function() end,
        transition = function(_, target) lifecycleState = target return 1 end
      } },
      identity = { connections = {
        quiesce = function() return { quiesced = true } end,
        flushReadyQuiescedTerminals = function()
          return { failures = 0, remaining = 0 }
        end
      } },
      persistence = {},
      registries = { owners = { list = function() return {} end } },
      facadeCache = {},
      stateService = fixture.state,
      coreResource = 'synex_core',
      evictConnectedPlayers = function()
        order[#order + 1] = 'evict'
        return 1, nil
      end,
      drainQuiescedTerminals = function() return { failures = 0 }, nil end
    })
    local report = assert(controller:handleRawStop())
    assert(report.failures == 0 and table.concat(order, ',') == 'state,evict')
    assert(fixture.state:snapshot().counts.player == 0)

    local preparedOrder = {}
    local preparedFixture = NewPlayerStateFixture(function(_, _, snapshot)
      if snapshot.value == nil then preparedOrder[#preparedOrder + 1] = 'state' end
      return true
    end)
    assert(preparedFixture.state:define('synex_fixture', preparedFixture.ownerEpoch, {
      name = 'synex_fixture.prepared_restart_state',
      scope = 'player',
      authority = 'owner',
      schema = { type = 'boolean' },
      replicated = true
    }))
    local preparedRestarting = BindPlayer(
      preparedFixture.players, 501, 56, 'session-prepared-restart', 'user-prepared-restart')
    assert(preparedFixture.state:set('synex_fixture', preparedFixture.ownerEpoch,
      'synex_fixture.prepared_restart_state', 56, true,
      PlayerStateContext(preparedRestarting)))
    local preparedLifecycleState = 'READY'
    local preparedController = SynexCoreFactories.bootstrapRestart({
      foundation = preparedFixture.foundation,
      runtimeGate = { stop = function() return true end },
      lifecycle = { core = {
        get = function() return preparedLifecycleState end,
        setCriticalFoundationsValidated = function() end,
        transition = function(_, target) preparedLifecycleState = target return 1 end
      }, reload = { quiesce = function() return { abortErrors = {}, cleanup = { errors = {} } } end } },
      identity = { connections = {
        quiesce = function() return { quiesced = true } end,
        releaseQuiescedLeases = function()
          return { leaseReleaseFailures = 0 }
        end
      } },
      persistence = { instances = {
        setStatus = function() return true end,
        terminateLocalSessions = function() return true end
      } },
      registries = { owners = { list = function() return {} end } },
      facadeCache = {},
      stateService = preparedFixture.state,
      coreResource = 'synex_core',
      evictConnectedPlayers = function()
        preparedOrder[#preparedOrder + 1] = 'evict'
        return 1, nil
      end,
      drainQuiescedTerminals = function() return { failures = 0 }, nil end
    })
    local prepared = assert(preparedController:prepare())
    assert(prepared.state == 'prepared' and prepared.playerState.cleared == 1)
    assert(table.concat(preparedOrder, ',') == 'state,evict')
    assert(preparedFixture.state:snapshot().counts.player == 0)
    return table.concat(order, ',') .. ':' .. table.concat(preparedOrder, ',')
  `);
  assert.equal(result, 'state,evict:state,evict');
  engine.global.close();
});
