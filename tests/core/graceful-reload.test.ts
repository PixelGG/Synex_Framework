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
    'lifecycle',
    'contracts',
    'security',
    'messaging',
    'state',
  ]) {
    await load(engine, `core/synex_core/server/${file}.lua`);
  }
  await engine.doString(`
    local now = 0
    local function measure(value, seen)
      local kind = type(value)
      if kind == 'nil' then return 4 end
      if kind == 'boolean' then return value and 4 or 5 end
      if kind == 'number' or kind == 'string' then return #tostring(value) + 2 end
      if kind ~= 'table' then error('unsupported JSON value') end
      seen = seen or {}
      if seen[value] then error('cyclic JSON value') end
      seen[value] = true
      local size = 2
      for key, item in pairs(value) do
        size = size + measure(key, seen) + measure(item, seen) + 2
      end
      seen[value] = nil
      return size
    end

    FakePlatform = {
      nowGame = function() return now end,
      random = function(_, maximum) return math.min(maximum or 1, 123456) end,
      print = function() end,
      jsonEncode = function(value) return string.rep('x', measure(value)) end,
      jsonDecode = function() return {} end,
      loadResourceFile = function() return nil end,
      setTimeout = function(_, callback) callback() end,
      wait = function(delay)
        now = now + delay
        if FakePlatform.onWait then FakePlatform.onWait(delay) end
      end
    }

    function NewReloadFixture()
      local foundation = SynexCoreFactories.foundation({ platform = FakePlatform })
      foundation.configureIds('reload-test')
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      local coreEpoch = registries.owners:activate('synex_core')
      local lifecycle = SynexCoreFactories.lifecycle({
        platform = FakePlatform,
        foundation = foundation,
        owners = registries.owners
      })
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
        security = security,
        coreResource = 'synex_core',
        replicate = function() return true end
      })
      return {
        foundation = foundation,
        registries = registries,
        owners = registries.owners,
        coreEpoch = coreEpoch,
        lifecycle = lifecycle,
        contracts = contracts,
        security = security,
        state = state
      }
    end
  `);
  return engine;
}

test('quiesce drains pending work and restores reconstructable state into the next owner epoch', async () => {
  const engine = await createEngine();
  const restored = await engine.doString(`
    local fixture = NewReloadFixture()
    local owner = 'synex_fixture'
    local epoch = fixture.owners:activate(owner)
    assert(fixture.state:define(owner, epoch, {
      name = 'synex_fixture.counter',
      scope = 'global',
      authority = 'owner',
      schema = { type = 'integer', minimum = 0 },
      persistent = true,
      replicated = false,
      sensitive = false
    }))
    assert(fixture.state:set(owner, epoch, 'synex_fixture.counter', nil, 7))

    local operation = assert(fixture.owners:beginOperation(owner, epoch))
    FakePlatform.onWait = function()
      FakePlatform.onWait = nil
      assert(fixture.owners:finishOperation(owner, epoch, operation))
    end
    local report = assert(fixture.lifecycle.reload:quiesce(owner, epoch, {
      timeoutMs = 50,
      pollMs = 10,
      reason = 'test restart',
      capture = function(captureOwner, captureEpoch)
        return fixture.state:captureOwner(captureOwner, captureEpoch)
      end
    }))
    assert(report.drained and not report.timedOut)
    assert(report.pendingAtStart == 1 and report.aborted == 0)
    assert(report.cleanup.cleaned == 1 and #report.cleanup.errors == 0)
    assert(report.snapshot.ownerEpoch == epoch and #report.snapshot.values == 1)

    local nextEpoch = fixture.owners:activate(owner)
    assert(nextEpoch == epoch + 2)
    assert(fixture.state:define(owner, nextEpoch, {
      name = 'synex_fixture.counter',
      scope = 'global',
      authority = 'owner',
      schema = { type = 'integer', minimum = 0 },
      persistent = true,
      replicated = false,
      sensitive = false
    }))
    local result = assert(fixture.lifecycle.reload:restore(owner, nextEpoch, report.snapshot,
      function(restoreOwner, restoreEpoch, snapshot)
        return fixture.state:restoreOwner(restoreOwner, restoreEpoch, snapshot)
      end))
    assert(result.restored == 1 and result.fromEpoch == epoch and result.toEpoch == nextEpoch)
    return assert(fixture.state:get(owner, nextEpoch, 'synex_fixture.counter', nil))
  `);
  assert.equal(restored, 7);
  engine.global.close();
});

test('quiesce enforces a bounded timeout and aborts pending owner work', async () => {
  const engine = await createEngine();
  const result = await engine.doString(`
    local fixture = NewReloadFixture()
    local owner = 'synex_timeout'
    local epoch = fixture.owners:activate(owner)
    local aborts = 0
    local reason = nil
    local operation = assert(fixture.owners:beginOperation(owner, epoch, function(value)
      aborts = aborts + 1
      reason = value
    end))
    local report = assert(fixture.lifecycle.reload:quiesce(owner, epoch, {
      timeoutMs = 25,
      pollMs = 10,
      reason = 'bounded timeout test'
    }))
    assert(not report.drained and report.timedOut)
    assert(report.durationMs == 25)
    assert(report.pendingAtStart == 1 and report.aborted == 1)
    assert(aborts == 1 and reason == 'bounded timeout test')
    assert(fixture.owners:pendingCount(owner, epoch) == 0)
    assert(not fixture.owners:finishOperation(owner, epoch, operation))
    assert(not fixture.owners:isEpoch(owner, epoch))
    local nextEpoch = fixture.owners:activate(owner)
    local staleCleanup = fixture.owners:purge(owner, epoch, 'late cleanup')
    assert(staleCleanup.stale == true)
    assert(fixture.owners:isCurrent(owner, nextEpoch))
    return report.durationMs
  `);
  assert.equal(result, 25);
  engine.global.close();
});

test('restore rejects malformed and replayed snapshots without partial mutation', async () => {
  const engine = await createEngine();
  const code = await engine.doString(`
    local fixture = NewReloadFixture()
    local owner = 'synex_broken'
    local epoch = fixture.owners:activate(owner)
    local definition = {
      name = 'synex_broken.enabled',
      scope = 'global',
      authority = 'owner',
      schema = { type = 'boolean' },
      persistent = true,
      replicated = false,
      sensitive = false
    }
    assert(fixture.state:define(owner, epoch, definition))
    assert(fixture.state:set(owner, epoch, definition.name, nil, false))
    local report = assert(fixture.lifecycle.reload:quiesce(owner, epoch, {
      timeoutMs = 0,
      capture = function(captureOwner, captureEpoch)
        return fixture.state:captureOwner(captureOwner, captureEpoch)
      end
    }))
    local nextEpoch = fixture.owners:activate(owner)
    assert(fixture.state:define(owner, nextEpoch, definition))
    assert(fixture.state:set(owner, nextEpoch, definition.name, nil, true))

    local broken = fixture.foundation.copy(report.snapshot)
    broken.unexpected = true
    local rejected, rejectError = fixture.lifecycle.reload:restore(owner, nextEpoch, broken,
      function(restoreOwner, restoreEpoch, snapshot)
        return fixture.state:restoreOwner(restoreOwner, restoreEpoch, snapshot)
      end)
    assert(rejected == nil and rejectError.code == 'INVALID_STATE_SNAPSHOT')
    assert(fixture.state:get(owner, nextEpoch, definition.name, nil) == true)

    assert(fixture.lifecycle.reload:restore(owner, nextEpoch, report.snapshot,
      function(restoreOwner, restoreEpoch, snapshot)
        return fixture.state:restoreOwner(restoreOwner, restoreEpoch, snapshot)
      end))
    assert(fixture.state:get(owner, nextEpoch, definition.name, nil) == false)
    local replayed, replayError = fixture.lifecycle.reload:restore(owner, nextEpoch, report.snapshot,
      function(restoreOwner, restoreEpoch, snapshot)
        return fixture.state:restoreOwner(restoreOwner, restoreEpoch, snapshot)
      end)
    assert(replayed == nil and replayError.code == 'SNAPSHOT_REPLAYED')
    return replayError.code
  `);
  assert.equal(code, 'SNAPSHOT_REPLAYED');
  engine.global.close();
});

test('reconstructable state survives many same-core owner restarts without stale epochs', async () => {
  const engine = await createEngine();
  const value = await engine.doString(`
    local fixture = NewReloadFixture()
    local owner = 'synex_restarts'
    local epoch = fixture.owners:activate(owner)
    local definition = {
      name = 'synex_restarts.counter',
      scope = 'global',
      authority = 'owner',
      schema = { type = 'integer', minimum = 0 },
      persistent = true,
      replicated = false,
      sensitive = false
    }
    assert(fixture.state:define(owner, epoch, definition))
    assert(fixture.state:set(owner, epoch, definition.name, nil, 1))
    for iteration = 1, 40 do
      local oldEpoch = epoch
      local report = assert(fixture.lifecycle.reload:quiesce(owner, oldEpoch, {
        timeoutMs = 0,
        capture = function(captureOwner, captureEpoch)
          return fixture.state:captureOwner(captureOwner, captureEpoch)
        end
      }))
      assert(report.drained and report.cleanup.cleaned == 1)
      epoch = fixture.owners:activate(owner)
      assert(epoch == oldEpoch + 2)
      assert(fixture.state:define(owner, epoch, definition))
      local restored = assert(fixture.lifecycle.reload:restore(owner, epoch, report.snapshot,
        function(restoreOwner, restoreEpoch, snapshot)
          return fixture.state:restoreOwner(restoreOwner, restoreEpoch, snapshot)
        end))
      assert(restored.restored == 1)
      assert(fixture.state:get(owner, epoch, definition.name, nil) == iteration)
      assert(fixture.state:set(owner, epoch, definition.name, nil, iteration + 1))
      assert(fixture.owners:pendingCount(owner, epoch) == 0)
    end
    return assert(fixture.state:get(owner, epoch, definition.name, nil))
  `);
  assert.equal(value, 41);
  engine.global.close();
});

test('Core-mediated service requests receive an owner-epoch abort signal', async () => {
  const engine = await createEngine();
  const code = await engine.doString(`
    local fixture = NewReloadFixture()
    local provider = 'synex_provider'
    local providerEpoch = fixture.owners:activate(provider)
    local messaging = SynexCoreFactories.messaging({
      platform = FakePlatform,
      foundation = fixture.foundation,
      contracts = fixture.contracts,
      security = fixture.security,
      owners = fixture.owners,
      players = fixture.registries.players,
      lifecycle = fixture.lifecycle,
      dependencies = fixture.lifecycle.dependencies,
      protocol = SynexProtocol,
      config = {},
      coreResource = 'synex_core'
    })
    assert(messaging.services:provide(provider, providerEpoch, {
      name = 'synex.abort_fixture',
      version = '1.0.0',
      methods = {
        run = function()
          assert(fixture.owners:beginQuiesce(provider, providerEpoch, 'provider restart'))
          local report = fixture.owners:abortPending(provider, providerEpoch, 'provider restart')
          assert(report.aborted == 1)
          return { completed = true }
        end
      }
    }))
    local value, err = messaging.services:call(
      'synex_core', fixture.coreEpoch, 'synex.abort_fixture', '^1.0.0', 'run', {}, {}
    )
    assert(value == nil and err.code == 'REQUEST_ABORTED')
    assert(fixture.owners:pendingCount(provider, providerEpoch) == 0)
    assert(fixture.owners:pendingCount('synex_core', fixture.coreEpoch) == 0)
    fixture.owners:purge(provider, providerEpoch, 'test cleanup')
    return err.code
  `);
  assert.equal(code, 'REQUEST_ABORTED');
  engine.global.close();
});
