import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory, type LuaEngine } from 'wasmoon';

const root = process.cwd();

async function load(engine: LuaEngine, relativePath: string): Promise<void> {
  await engine.doString(await readFile(path.join(root, relativePath), 'utf8'));
}

test('pending handoffs preserve unseen values, overlay current writes, and fence tombstones by restore success', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await load(engine, 'core/synex_core/shared/protocol.lua');
    for (const file of [
      'factories',
      'foundation',
      'registries',
      'lifecycle',
      'contracts',
      'security',
      'state',
      'bootstrap_resource_events',
      'bootstrap_lifecycle',
    ]) {
      await load(engine, `core/synex_core/server/${file}.lua`);
    }

    const result = await engine.doString(`
      local resource = 'synex_fixture'
      local states = { [resource] = 'started' }
      local handlers, timeouts = {}, {}
      local captureCalls, restoreCalls = 0, 0

      local function encodedSize(value, active)
        local kind = type(value)
        if kind == 'string' then return #value + 2 end
        if kind == 'number' then return #tostring(value) end
        if kind == 'boolean' then return value and 4 or 5 end
        if kind == 'nil' then return 4 end
        assert(kind == 'table', 'fixture encoder only accepts JSON-compatible values')
        active = active or {}
        assert(not active[value], 'fixture encoder rejects cycles')
        active[value] = true
        local count, maximum, array = 0, 0, true
        for key in pairs(value) do
          count = count + 1
          if type(key) ~= 'number' or math.type(key) ~= 'integer' or key < 1 then
            array = false
          else
            maximum = math.max(maximum, key)
          end
        end
        array = array and maximum == count
        local size, entries = 2, 0
        for key, item in pairs(value) do
          if entries > 0 then size = size + 1 end
          entries = entries + 1
          if not array then size = size + #tostring(key) + 3 end
          size = size + encodedSize(item, active)
        end
        active[value] = nil
        return size
      end

      local platform = {
        nowGame = function() return 1000 end,
        random = function() return 31 end,
        print = function() end,
        resourceState = function(name) return states[name] or 'missing' end,
        addEventHandler = function(name, handler) handlers[name] = handler end,
        export = function() end,
        invokingResource = function() return resource end,
        getPlayers = function() return {} end,
        dropPlayer = function() end,
        cancelEvent = function() end,
        setTimeout = function(_, callback) timeouts[#timeouts + 1] = callback end,
        wait = function() end,
        jsonEncode = function(value) return string.rep('x', encodedSize(value)) end,
        jsonDecode = function() return {} end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('state-handoff-retarget-race')
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      registries.owners:activate('synex_core')
      local lifecycle = SynexCoreFactories.lifecycle({
        platform = platform, foundation = foundation, owners = registries.owners
      })
      local contracts = SynexCoreFactories.contracts({
        foundation = foundation, protocol = SynexProtocol
      })
      local security = SynexCoreFactories.security({
        platform = platform,
        foundation = foundation,
        coreResource = 'synex_core',
        policy = { default = { allow = {}, deny = {} }, resources = {} }
      })
      local stateService = SynexCoreFactories.state({
        platform = platform,
        foundation = foundation,
        contracts = contracts,
        owners = registries.owners,
        security = security,
        coreResource = 'synex_core',
        replicate = function() return true end
      })

      local function runNextTimeout()
        local callback = table.remove(timeouts, 1)
        assert(callback, 'expected a queued restore callback')
        callback()
      end
      local function runAllTimeouts()
        local runs = 0
        while #timeouts > 0 do
          runs = runs + 1
          assert(runs <= 16, 'restore callbacks must remain bounded')
          runNextTimeout()
        end
        return runs
      end

      local manifest = { name = resource, stateSnapshot = { supported = true, schemaVersion = 1 } }
      local manifests = {}
      local function ensureOwner(name)
        local currentEpoch = registries.owners:epoch(name)
        if registries.owners:isCurrent(name, currentEpoch) then return currentEpoch, nil end
        local epoch = registries.owners:activate(name)
        registries.resources:upsert(name, manifest, 'DISCOVERED')
        manifests[name] = manifest
        return epoch, nil
      end
      local discovery = {
        discoverResource = function(name)
          manifests[name] = manifest
          registries.resources:upsert(name, manifest, 'DISCOVERED')
          return manifest, nil
        end,
        invalidateResource = function(name) manifests[name] = nil return true end,
        discoverAll = function() return manifests, nil end,
        validateActive = function() return {} end,
        ensureOwner = ensureOwner,
        supportsStateHandoff = function(name) return name == resource end,
        captureStateHandoff = function(owner, epoch)
          captureCalls = captureCalls + 1
          return stateService:captureOwner(owner, epoch, {
            maximumBytes = 65536, maximumValues = 512
          })
        end,
        restoreStateHandoff = function(owner, epoch, snapshot)
          restoreCalls = restoreCalls + 1
          return stateService:restoreOwner(owner, epoch, snapshot, {
            maximumBytes = 65536, maximumValues = 512
          })
        end
      }
      local runtimeGate = {
        requireAvailable = function() return true, nil end,
        stop = function() end
      }
      local runtime = {}
      local api = {
        getAPIForCaller = function() return {} end,
        invokeForCaller = function() return true, nil end,
        guarded = function(_, _, _, _, handler) return handler() end,
        registerCoreContracts = function() return true end,
        registerCoreServices = function() return true end
      }
      local identity = { connections = {
        snapshot = function() return { quiesced = false } end,
        handleConnecting = function() return true, nil end,
        handleJoining = function() return true, nil end,
        handleDropped = function() return true, nil end,
        quiesce = function() return {}, nil end
      } }
      SynexCoreFactories.commands = function()
        return { bind = function() return true end }
      end
      SynexCoreFactories.bootstrapRestart = function()
        return {
          prepare = function() return {}, nil end,
          handleRawStop = function() return {}, nil end
        }
      end
      local reloadSnapshots = {}
      SynexCoreFactories.bootstrapLifecycle({
        runtime = runtime,
        platform = platform,
        foundation = foundation,
        coreResource = 'synex_core',
        api = api,
        messaging = { network = { bind = function() return true end } },
        identity = identity,
        discovery = discovery,
        reloadSnapshots = reloadSnapshots,
        registries = registries,
        lifecycle = lifecycle,
        facadeCache = {},
        defaultConfig = {},
        persistence = {},
        manifests = manifests,
        reliability = {},
        sagaRuntime = {},
        retention = {},
        security = security,
        stateService = stateService,
        runtimeGate = runtimeGate
      })
      assert(runtime:bind())

      local function definition(name, scope)
        return {
          name = resource .. '.' .. name,
          scope = scope or 'global',
          authority = 'owner',
          schema = { type = 'integer' },
          persistent = true,
          sensitive = false,
          replicated = false
        }
      end
      local function define(epoch, name, scope)
        return assert(stateService:define(resource, epoch, definition(name, scope)))
      end
      local function start()
        states[resource] = 'started'
        handlers.onResourceStart(resource)
        return registries.owners:epoch(resource)
      end
      local function stop()
        states[resource] = 'stopped'
        handlers.onResourceStop(resource)
      end

      -- Gen1 captures A=1. Gen2 has no A definition, so its failed restore and
      -- empty real capture cannot prove that A was deleted.
      local epoch = start()
      define(epoch, 'a')
      assert(stateService:set(resource, epoch, resource .. '.a', nil, 1))
      stop()
      epoch = start()
      runNextTimeout()
      assert(restoreCalls == 1 and #timeouts == 1)
      stop()
      epoch = start()
      define(epoch, 'a')
      assert(runAllTimeouts() == 2)
      assert(stateService:get(resource, epoch, resource .. '.a', nil) == 1)

      -- While the next predecessor is pending, current entries overlay by key:
      -- A=2 replaces A=1 and the new B=3 is carried alongside it.
      stop()
      epoch = start()
      define(epoch, 'a')
      define(epoch, 'b')
      assert(stateService:set(resource, epoch, resource .. '.a', nil, 2))
      assert(stateService:set(resource, epoch, resource .. '.b', nil, 3))
      assert(#timeouts == 1)
      stop()
      epoch = start()
      define(epoch, 'a')
      define(epoch, 'b')
      assert(runAllTimeouts() == 2)
      assert(stateService:get(resource, epoch, resource .. '.a', nil) == 2)
      assert(stateService:get(resource, epoch, resource .. '.b', nil) == 3)

      -- An explicit Gen2 set followed by clear is a captured tombstone. It
      -- removes predecessor A while untouched predecessor B remains present.
      stop()
      epoch = start()
      define(epoch, 'a')
      define(epoch, 'b')
      assert(stateService:set(resource, epoch, resource .. '.a', nil, 4))
      local cleared = assert(stateService:clear(
        resource, epoch, resource .. '.a', nil))
      assert(cleared.cleared == true)
      assert(#timeouts == 1)
      stop()
      epoch = start()
      define(epoch, 'a')
      define(epoch, 'b')
      assert(runAllTimeouts() == 2)
      assert(stateService:get(resource, epoch, resource .. '.a', nil) == nil)
      assert(stateService:get(resource, epoch, resource .. '.b', nil) == 3)

      -- The predecessor was consumed successfully. A later set/clear is now
      -- represented by absence in an independent full capture and must win.
      assert(stateService:set(resource, epoch, resource .. '.a', nil, 5))
      cleared = assert(stateService:clear(
        resource, epoch, resource .. '.a', nil))
      assert(cleared.cleared == true)
      stop()
      epoch = start()
      define(epoch, 'a')
      define(epoch, 'b')
      assert(runAllTimeouts() == 1)
      assert(stateService:get(resource, epoch, resource .. '.a', nil) == nil)
      assert(stateService:get(resource, epoch, resource .. '.b', nil) == 3)

      -- A 512-value predecessor plus one new current key cannot be merged.
      -- Both bounded candidates remain quarantined instead of losing either.
      assert(stateService:clear(resource, epoch, resource .. '.b', nil))
      define(epoch, 'many', 'character')
      for index = 1, 512 do
        assert(stateService:set(resource, epoch, resource .. '.many',
          ('character_%03d'):format(index), index))
      end
      stop()
      epoch = start()
      define(epoch, 'new_value')
      assert(stateService:set(resource, epoch,
        resource .. '.new_value', nil, 9))
      assert(#timeouts == 1)
      stop()
      local quarantined = assert(reloadSnapshots[resource])
      assert(quarantined.state == 'quarantined'
        and quarantined.lastErrorCode == 'SNAPSHOT_TOO_LARGE')
      assert(#quarantined.snapshot.values == 512)
      assert(type(quarantined.currentSnapshot) == 'table'
        and #quarantined.currentSnapshot.values == 1)
      runNextTimeout()
      assert(restoreCalls == 5 and #timeouts == 0)

      return table.concat({ captureCalls, restoreCalls,
        quarantined.lastErrorCode,
        #quarantined.snapshot.values,
        #quarantined.currentSnapshot.values }, ':')
    `);

    assert.equal(result, '9:5:SNAPSHOT_TOO_LARGE:512:1');
  } finally {
    engine.global.close();
  }
});
