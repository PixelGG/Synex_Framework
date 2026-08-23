import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory, type LuaEngine } from 'wasmoon';

const root = process.cwd();

async function load(engine: LuaEngine, relativePath: string): Promise<void> {
  await engine.doString(await readFile(path.join(root, relativePath), 'utf8'));
}

async function createEngine(files: string[], generated = false): Promise<LuaEngine> {
  const engine = await new LuaFactory().createEngine();
  await load(engine, 'core/synex_core/shared/protocol.lua');
  if (generated) await load(engine, 'core/synex_core/shared/generated_contracts.lua');
  await load(engine, 'core/synex_core/server/factories.lua');
  for (const file of files) await load(engine, `core/synex_core/server/${file}.lua`);
  return engine;
}

test('resource restart invalidates manifests, capabilities, contracts, consumer edges, and stale API epochs', async () => {
  const engine = await createEngine([
    'foundation',
    'registries',
    'lifecycle',
    'security',
    'bootstrap_discovery',
    'bootstrap_api',
    'bootstrap_restart',
    'bootstrap_resource_events',
    'bootstrap_lifecycle',
  ]);
  try {
    const result = await engine.doString(`
      local mode = 'v1'
      local states = { synex_fixture = 'started' }
      local handlers, exports, captures, restores = {}, {}, 0, 0
      local timeouts, restoreUnavailable = {}, 0
      local restartDuringRestore, restoreConflict = false, 0
      local function runTimeouts()
        local runs = 0
        while #timeouts > 0 do
          runs = runs + 1
          assert(runs <= 32, 'state handoff retries must remain bounded')
          local callback = table.remove(timeouts, 1)
          callback()
        end
        return runs
      end
      local manifests = {
        v1 = {
          name = 'synex_fixture', critical = true,
          capabilities = { request = {'synex.runtime.read', 'synex.fixture.a'} },
          contracts = { provide = {'synex.fixture.old'}, consume = {} },
          events = { publish = {'synex.fixture.old'}, subscribe = {} },
          hooks = { register = {}, run = {'synex.fixture.old'} },
          services = { provide = {}, require = {'synex.alpha@1'}, optional = {} },
          dependencies = { required = {}, optional = {}, development = {} },
          migrations = {}, stateSnapshot = { supported = true, schemaVersion = 1 }
        },
        v2 = {
          name = 'synex_fixture', critical = true,
          capabilities = { request = {'synex.runtime.read', 'synex.fixture.b'} },
          contracts = { provide = {'synex.fixture.new'}, consume = {} },
          events = { publish = {'synex.fixture.new'}, subscribe = {} },
          hooks = { register = {}, run = {'synex.fixture.new'} },
          services = { provide = {}, require = {'synex.beta@2'}, optional = {} },
          dependencies = { required = {}, optional = {}, development = {} },
          migrations = {}, stateSnapshot = { supported = true, schemaVersion = 1 }
        }
      }
      local platform = {
        nowGame = function() return 1000 end,
        random = function() return 17 end,
        print = function() end,
        jsonEncode = function() return '{}' end,
        jsonDecode = function(raw)
          if raw == 'invalid-json' then error('invalid JSON fixture') end
          return manifests[mode]
        end,
        resourceState = function(name) return states[name] or 'missing' end,
        resourceMetadata = function(name, key)
          if name == 'synex_fixture' and key == 'synex_manifest' and mode ~= 'missing' then
            return 'synex.resource.json'
          end
        end,
        loadResourceFile = function()
          if mode == 'invalid-json' then return 'invalid-json' end
          return 'manifest'
        end,
        addEventHandler = function(name, handler) handlers[name] = handler end,
        export = function(name, handler) exports[name] = handler end,
        getPlayers = function() return {} end,
        dropPlayer = function() error('fixture has no players') end,
        setTimeout = function(_, callback) timeouts[#timeouts + 1] = callback end,
        wait = function() end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('resource-restart-capabilities')
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      local lifecycle = SynexCoreFactories.lifecycle({
        platform = platform, foundation = foundation, owners = registries.owners
      })
      local security = SynexCoreFactories.security({
        platform = platform, foundation = foundation, coreResource = 'synex_core',
        policy = {
          default = { allow = {}, deny = {} },
          resources = { synex_fixture = {
            allow = {'synex.runtime.read', 'synex.fixture.a', 'synex.fixture.b'}, deny = {}
          } }
        }
      })
      local stateService = {
        captureOwner = function(_, owner, epoch)
          captures = captures + 1
          return {
            schemaVersion = 1, owner = owner, ownerEpoch = epoch,
            capturedAt = '2026-08-23T00:00:00.000Z', values = {}
          }, nil
        end,
        restoreOwner = function(_, owner, epoch, snapshot)
          restores = restores + 1
          if restartDuringRestore then
            restartDuringRestore = false
            states.synex_fixture = 'stopped'
            handlers.onResourceStop('synex_fixture')
            states.synex_fixture = 'started'
            handlers.onResourceStart('synex_fixture')
            return nil, foundation.error('REQUEST_ABORTED', 'fixture owner restarted')
          end
          if restoreConflict > 0 then
            restoreConflict = restoreConflict - 1
            return nil, foundation.error('STATE_WRITE_CONFLICT',
              'fixture concurrent write must remain authoritative')
          end
          if restoreUnavailable > 0 then
            restoreUnavailable = restoreUnavailable - 1
            return nil, foundation.error('SNAPSHOT_STATE_UNAVAILABLE',
              'fixture definitions are not ready')
          end
          assert(snapshot.ownerEpoch + 2 == epoch)
          return { restored = 1, fromEpoch = snapshot.ownerEpoch, toEpoch = epoch }, nil
        end,
        purgeAllPlayers = function()
          return { players = 0, cleared = 0, replicated = 0, skipped = 0, failures = {} }, nil
        end
      }
      local runtimeGate = {
        requireAvailable = function() return true, nil end,
        beginBoot = function() end, open = function() end,
        fail = function() end, stop = function() end
      }
      local discovered = {}
      local discovery = SynexCoreFactories.bootstrapDiscovery({
        platform = platform, foundation = foundation,
        resourceManifest = { validate = function()
          if mode == 'invalid-manifest' then
            return nil, foundation.error('INVALID_RESOURCE_MANIFEST', 'invalid fixture manifest')
          end
          return true, nil
        end },
        security = security, registries = registries, lifecycle = lifecycle,
        stateService = stateService, manifests = discovered, runtimeGate = runtimeGate
      })
      local runtime = { doctor = function() return { healthy = true }, nil end }
      local messaging = {
        network = { bind = function() return true end },
        gateway = {}, events = {}, hooks = {}, services = {}
      }
      local identity = {
        connections = {
          snapshot = function() return { quiesced = false } end,
          handleConnecting = function() return true, nil end,
          handleJoining = function() return true, nil end,
          handleDropped = function() return true, nil end
        },
        characters = {}
      }
      local facadeCache = {}
      local api = SynexCoreFactories.bootstrapApi({
        platform = platform, foundation = foundation, registries = registries,
        security = security, identity = identity, contractSystem = {}, messaging = messaging,
        coreResource = 'synex_core', runtime = runtime, stateService = stateService,
        lifecycle = lifecycle, reliability = {}, sagaRuntime = {}, defaultConfig = {},
        facadeCache = facadeCache, runtimeGate = runtimeGate, ensureOwner = discovery.ensureOwner
      })
      SynexCoreFactories.commands = function()
        return { bind = function() return true end }
      end
      local reloadSnapshots = {}
      SynexCoreFactories.bootstrapLifecycle({
        runtime = runtime, platform = platform, foundation = foundation,
        coreResource = 'synex_core', api = api, messaging = messaging, identity = identity,
        discovery = discovery, reloadSnapshots = reloadSnapshots, registries = registries,
        lifecycle = lifecycle, facadeCache = facadeCache, defaultConfig = {},
        persistence = {}, manifests = discovered, reliability = {}, sagaRuntime = {},
        retention = {}, security = security, stateService = stateService, runtimeGate = runtimeGate
      })
      assert(runtime:bind())

      local v1Facade = assert(api.getAPIForCaller('synex_fixture', '^1.0.0'))
      local v1Epoch = registries.owners:epoch('synex_fixture')
      local earlyCleanup = 0
      assert(registries.owners:track('synex_fixture', v1Epoch, 'fixture', 'early-start', function()
        earlyCleanup = earlyCleanup + 1
      end))
      handlers.onResourceStart('synex_fixture')
      assert(registries.owners:epoch('synex_fixture') == v1Epoch and earlyCleanup == 0)
      assert(security.capabilities:check('synex_fixture', 'synex.fixture.a', {}))
      assert(security.capabilities:providesContract('synex_fixture', 'synex.fixture.old'))
      local v1Graph = lifecycle.dependencies:snapshot()
      assert(v1Graph.consumers.synex_fixture['synex.alpha'].range == '^1.0.0')

      states.synex_fixture = 'stopped'
      handlers.onResourceStop('synex_fixture')
      assert(captures == 1 and earlyCleanup == 1 and discovered.synex_fixture == nil)
      assert(registries.resources:get('synex_fixture').manifest == nil)
      assert(lifecycle.dependencies:snapshot().consumers.synex_fixture == nil)
      assert(not security.capabilities:providesContract('synex_fixture', 'synex.fixture.old'))
      local criticalTombstone = discovery.validateActive('synex_fixture', true)
      assert(#criticalTombstone == 1
        and criticalTombstone[1].code == 'RESOURCE_MANIFEST_UNAVAILABLE'
        and criticalTombstone[1].severity == 'error')
      local stale, staleError = v1Facade.Diagnostics.run()
      assert(stale == nil and staleError.code == 'STALE_RESOURCE')

      mode = 'v2'
      states.synex_fixture = 'started'
      restoreUnavailable = 1
      handlers.onResourceStart('synex_fixture')
      local v2Facade = assert(api.getAPIForCaller('synex_fixture', '^1.0.0'))
      local v2Epoch = registries.owners:epoch('synex_fixture')
      assert(#timeouts == 1 and runTimeouts() == 2)
      assert(v2Facade ~= v1Facade and v2Epoch > v1Epoch and restores == 2)
      local oldCapability, oldCapabilityError = security.capabilities:check(
        'synex_fixture', 'synex.fixture.a', {})
      assert(oldCapability == nil and oldCapabilityError.code == 'CAPABILITY_UNDECLARED')
      assert(security.capabilities:check('synex_fixture', 'synex.fixture.b', {}))
      assert(not security.capabilities:providesContract('synex_fixture', 'synex.fixture.old'))
      assert(security.capabilities:providesContract('synex_fixture', 'synex.fixture.new'))
      local v2Graph = lifecycle.dependencies:snapshot()
      assert(v2Graph.consumers.synex_fixture['synex.alpha'] == nil)
      assert(v2Graph.consumers.synex_fixture['synex.beta'].range == '^2.0.0')

      states.synex_fixture = 'stopped'
      handlers.onResourceStop('synex_fixture')

      -- Stop the next epoch before its queued restore callback. The pending
      -- envelope must survive, be retargeted, and restore only in the next
      -- current owner epoch; the stale callback must be harmless.
      states.synex_fixture = 'started'
      handlers.onResourceStart('synex_fixture')
      local interruptedEpoch = registries.owners:epoch('synex_fixture')
      assert(#timeouts == 1)
      states.synex_fixture = 'stopped'
      handlers.onResourceStop('synex_fixture')
      assert(captures == 3)
      states.synex_fixture = 'started'
      handlers.onResourceStart('synex_fixture')
      local recoveredEpoch = registries.owners:epoch('synex_fixture')
      assert(recoveredEpoch == interruptedEpoch + 2 and #timeouts == 2)
      assert(runTimeouts() == 2 and restores == 3)

      -- A restore that yields across stop/start must lose its claim before it
      -- can report an error. Its stale completion cannot quarantine the new
      -- epoch's claim.
      states.synex_fixture = 'stopped'
      handlers.onResourceStop('synex_fixture')
      restartDuringRestore = true
      states.synex_fixture = 'started'
      handlers.onResourceStart('synex_fixture')
      assert(runTimeouts() == 2 and restores == 5)
      assert(reloadSnapshots.synex_fixture == nil)

      -- A write conflict proves that newer state won the CAS. Retrying the old
      -- envelope would overwrite that authoritative write, so the handoff is
      -- quarantined after exactly one attempt.
      states.synex_fixture = 'stopped'
      handlers.onResourceStop('synex_fixture')
      restoreConflict = 1
      states.synex_fixture = 'started'
      handlers.onResourceStart('synex_fixture')
      assert(runTimeouts() == 1 and restores == 6 and #timeouts == 0)
      assert(reloadSnapshots.synex_fixture.state == 'quarantined'
        and reloadSnapshots.synex_fixture.lastErrorCode == 'STATE_WRITE_CONFLICT')

      -- A discovery failure must not consume the only pending envelope.
      states.synex_fixture = 'stopped'
      handlers.onResourceStop('synex_fixture')
      mode = 'invalid-json'
      states.synex_fixture = 'started'
      handlers.onResourceStart('synex_fixture')
      local invalidJson, invalidJsonError = api.getAPIForCaller('synex_fixture', '^1.0.0')
      assert(invalidJson == nil and invalidJsonError.code == 'RESOURCE_MANIFEST_INVALID_JSON')
      mode = 'v2'
      handlers.onResourceStart('synex_fixture')
      assert(runTimeouts() == 1 and restores == 7)
      states.synex_fixture = 'stopped'
      handlers.onResourceStop('synex_fixture')

      mode = 'missing'
      states.synex_fixture = 'started'
      handlers.onResourceStart('synex_fixture')
      local missing, missingError = api.getAPIForCaller('synex_fixture', '^1.0.0')
      assert(missing == nil and missingError.code == 'RESOURCE_NOT_REGISTERED')
      assert(discovered.synex_fixture == nil)
      assert(registries.resources:get('synex_fixture').manifest == nil)
      assert(lifecycle.dependencies:snapshot().consumers.synex_fixture == nil)
      assert(not security.capabilities:providesContract('synex_fixture', 'synex.fixture.new'))

      mode = 'invalid-manifest'
      handlers.onResourceStart('synex_fixture')
      local invalidManifest, invalidManifestError = api.getAPIForCaller('synex_fixture', '^1.0.0')
      assert(invalidManifest == nil and invalidManifestError.code == 'INVALID_RESOURCE_MANIFEST')
      assert(discovered.synex_fixture == nil)

      return table.concat({
        v1Epoch, v2Epoch, captures, restores, staleError.code,
        oldCapabilityError.code, missingError.code,
        invalidJsonError.code, invalidManifestError.code
      }, ':')
    `);
    assert.match(
      String(result),
      /^1:[2-9][0-9]*:8:7:STALE_RESOURCE:CAPABILITY_UNDECLARED:RESOURCE_NOT_REGISTERED:/,
    );
    assert.match(String(result), /RESOURCE_MANIFEST_INVALID_JSON:INVALID_RESOURCE_MANIFEST$/);
  } finally {
    engine.global.close();
  }
});

test('runtime status history and contract stay bounded and schema-complete', async () => {
  const engine = await createEngine(['foundation', 'registries', 'lifecycle', 'contracts'], true);
  try {
    const result = await engine.doString(`
      local platform = {
        nowGame = function() return 1000 end,
        random = function() return 29 end,
        print = function() end,
        jsonEncode = function() return '{}' end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      registries.owners:activate('synex_core')
      local lifecycle = SynexCoreFactories.lifecycle({
        platform = platform, foundation = foundation, owners = registries.owners
      })
      for _, target in ipairs({
        'CONFIGURING', 'DATABASE_CONNECTING', 'MIGRATING', 'DISCOVERING_RESOURCES',
        'VALIDATING_CONTRACTS', 'VALIDATING_CAPABILITIES', 'STARTING_SERVICES', 'READY'
      }) do assert(lifecycle.core:transition(target, 'fixture')) end
      for iteration = 1, 40 do
        assert(lifecycle.core:transition('DEGRADED', 'fixture degrade ' .. iteration))
        assert(lifecycle.core:transition('READY', 'fixture recover ' .. iteration))
      end
      local snapshot = lifecycle.core:snapshot()
      assert(snapshot.revision == 88 and #snapshot.recentTransitions == 64)
      assert(snapshot.recentTransitions[1].revision == 25)
      assert(snapshot.recentTransitions[64].revision == 88)
      assert(type(snapshot.playerAdmission) == 'boolean')

      local contracts = SynexCoreFactories.contracts({
        foundation = foundation, protocol = SynexProtocol, generated = SynexGeneratedContracts
      })
      local versionOne = assert(contracts.registry:resolve('synex.runtime.status', '1.0.0'))
      local legacy = foundation.copy(snapshot)
      legacy.playerAdmission = nil
      assert(contracts.registry:validateOutput(versionOne, legacy))
      local legacyFull, legacyFullError = contracts.registry:validateOutput(versionOne, snapshot)
      assert(legacyFull == nil and legacyFullError.code == 'INVALID_PROVIDER_RESPONSE')

      local versionTwo = assert(contracts.registry:resolve('synex.runtime.status', '2.0.0'))
      assert(contracts.registry:validateOutput(versionTwo, snapshot))
      local incomplete = foundation.copy(snapshot)
      incomplete.playerAdmission = nil
      local valid, validationError = contracts.registry:validateOutput(versionTwo, incomplete)
      assert(valid == nil and validationError.code == 'INVALID_PROVIDER_RESPONSE')
      return table.concat({
        snapshot.revision, #snapshot.recentTransitions,
        snapshot.recentTransitions[1].revision,
        snapshot.recentTransitions[64].revision,
        legacyFullError.code, validationError.code
      }, ':')
    `);
    assert.equal(result, '88:64:25:88:INVALID_PROVIDER_RESPONSE:INVALID_PROVIDER_RESPONSE');
  } finally {
    engine.global.close();
  }
});

test('runtime status registers compatible v1 and extended v2 handlers', async () => {
  const engine = await createEngine(['foundation', 'registries', 'bootstrap_api'], true);
  try {
    const result = await engine.doString(`
      local platform = {
        nowGame = function() return 1000 end,
        random = function() return 31 end,
        print = function() end,
        jsonEncode = function() return '{}' end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      registries.owners:activate('synex_core')
      local registered = {}
      local contractSystem = {
        registry = {
          resolve = function(_, name, version)
            return { name = name, version = version, provider = 'synex_core' }, nil
          end
        }
      }
      local messaging = {
        gateway = {
          register = function(_, owner, _, contract, handler)
            assert(owner == 'synex_core')
            registered[contract.name .. '@' .. contract.version] = handler
            return contract.version, nil
          end
        }
      }
      local lifecycle = {
        core = {
          snapshot = function()
            return {
              state = 'READY', revision = 8, operational = true,
              playerAdmission = false, reasons = {}, recentTransitions = {}
            }
          end
        }
      }
      local api = SynexCoreFactories.bootstrapApi({
        platform = platform, foundation = foundation, registries = registries,
        security = {}, identity = {}, contractSystem = contractSystem,
        messaging = messaging, coreResource = 'synex_core', runtime = {},
        stateService = {}, lifecycle = lifecycle, reliability = {}, sagaRuntime = {},
        facadeCache = {}, runtimeGate = {}, ensureOwner = function() return 1 end,
        defaultConfig = {}
      })
      assert(api.registerCoreContracts())
      local versionOne = assert(registered['synex.runtime.status@1.0.0'])(
        {}, { version = '1.0.0' })
      local versionTwo = assert(registered['synex.runtime.status@2.0.0'])(
        {}, { version = '2.0.0' })
      assert(versionOne.playerAdmission == nil)
      assert(versionTwo.playerAdmission == false)
      local count = 0
      for _ in pairs(registered) do count = count + 1 end
      return table.concat({ count, versionOne.revision, tostring(versionTwo.playerAdmission) }, ':')
    `);
    assert.equal(result, '7:8:false');
  } finally {
    engine.global.close();
  }
});
