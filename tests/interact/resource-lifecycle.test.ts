import assert from 'node:assert/strict';
import test from 'node:test';

import {
  interactBundleFactory,
  interactServerFiles,
  runInteractLua,
} from './helpers.js';

const lifecycleFiles = [
  ...interactServerFiles,
  'resources/synex_interact/server/runtime.lua',
] as const;

test('owner restart removes runtime authority and stale extension tokens cannot mutate the new epoch', async () => {
  const result = await runInteractLua<{
    beforeLeases: number;
    beforeReservations: number;
    removedBundles: number;
    afterLeases: number;
    afterSessions: number;
    afterReservations: number;
    oldTokenRejected: boolean;
    providerCurrent: boolean;
    secondLeaseIssued: boolean;
  }>(`${interactBundleFactory}
    local clock, serial = 1000, 0
    local epochs = { fixture = 1 }
    local registry = SynexInteractRegistry.create({ compiler = SynexInteractCompiler,
      isOwnerCurrent = function(owner, epoch) return epochs[owner] == epoch end })
    assert(registry.register('fixture', 1, __interactBundle()))
    local oldProvider = assert(registry.registerProvider('fixture', 1,
      { key = 'fixture:nearby', timeoutMs = 16 }, function() return {} end))
    assert(registry.registerEvaluator('fixture', 1,
      { key = 'fixture:visible', timeoutMs = 8 }, function() return true end))
    assert(registry.registerAdapter('fixture', 1,
      { key = 'fixture:domain', timeoutMs = 20 }, function() return true end))

    local slots = SynexInteractSlots.create({ now = function() return clock end })
    local sessions = SynexInteractSessions.create({ now = function() return clock end })
    local locks = SynexInteractActorLocks.create()
    local authority = SynexInteractAuthority.create({ registry = registry, slots = slots,
      sessions = sessions, locks = locks, now = function() return clock end,
      nextId = function(namespace)
        serial = serial + 1
        return namespace .. '-' .. string.format('%08d', serial)
      end,
      validateTarget = function() return { distance = 1, revision = 1 } end,
      checkPolicy = function() return true end,
      observability = { denied = function() end, increment = function() end,
        trace = function() end, event = function() end, audit = function() end,
        observe = function() end },
    })
    authority.reconcileSlots()
    local context = { source = 10, sourceGeneration = 1,
      session = { source = 10, sourceGeneration = 1, state = 'ACTIVE',
        id = 'identity-operator', characterId = 'character-operator' },
      traceId = 'trace-owner-restart' }
    local first = assert(authority.requestLease({
      intent = { key = 'fixture:inspect', revision = 1 },
      target = { kind = 'static', bindingKey = 'fixture:terminal' },
      clientRevision = registry.currentRevision(), slotKey = 'operator',
    }, context))
    assert(first.leaseId ~= nil)
    local beforeLeases = authority.snapshot().activeLeases
    local beforeReservations = slots.snapshot().reservations

    assert(authority.revokeOwner('fixture', 1, 'OWNER_STOPPED') >= 1)
    local removedBundles = registry.cleanupOwner('fixture', 1)
    authority.reconcileSlots()
    epochs.fixture = 2
    assert(registry.register('fixture', 2, __interactBundle()))
    local newProvider = assert(registry.registerProvider('fixture', 2,
      { key = 'fixture:nearby', timeoutMs = 16 }, function() return {} end))
    local oldTokenRejected = oldProvider.unregister() == false
    authority.reconcileSlots()
    local second = assert(authority.requestLease({
      intent = { key = 'fixture:inspect', revision = 1 },
      target = { kind = 'static', bindingKey = 'fixture:terminal' },
      clientRevision = registry.currentRevision(), slotKey = 'operator',
    }, context))

    return { beforeLeases = beforeLeases, beforeReservations = beforeReservations,
      removedBundles = removedBundles,
      afterLeases = authority.snapshot().activeLeases,
      afterSessions = sessions.snapshot().active,
      afterReservations = slots.snapshot().reservations,
      oldTokenRejected = oldTokenRejected,
      providerCurrent = registry.getProvider('fixture:nearby') ~= nil
        and newProvider ~= nil,
      secondLeaseIssued = second.leaseId ~= nil }
  `);

  assert.deepEqual(result, {
    beforeLeases: 1,
    beforeReservations: 1,
    removedBundles: 1,
    afterLeases: 1,
    afterSessions: 1,
    afterReservations: 1,
    oldTokenRejected: true,
    providerCurrent: true,
    secondLeaseIssued: true,
  });
});

test('Core stop revokes every runtime owner before rebinding', async () => {
  const result = await runInteractLua<{
    revoked: string[];
    cleaned: string[];
    reconciled: number;
    ownersRemaining: number;
    coreCleared: boolean;
    ready: boolean;
  }>(`
    local revoked, cleaned, reconciled = {}, {}, 0
    local ownerEpochs = { fixture = 3, synex_interact = 7 }
    local coreRef = { value = { stale = true } }
    local authority = {
      revokeOwner = function(owner, epoch, reason)
        revoked[#revoked + 1] = owner .. ':' .. epoch .. ':' .. reason
        return 1
      end,
      reconcileSlots = function() reconciled = reconciled + 1 end,
    }
    local registry = {
      cleanupOwner = function(owner, epoch)
        cleaned[#cleaned + 1] = owner .. ':' .. epoch
        return 1
      end,
    }
    local application = SynexInteractApplication.create({
      resourceName = 'synex_interact', coreResource = 'synex_core',
      coreRef = coreRef, ownerEpochs = ownerEpochs,
      registry = registry, authority = authority, graph = {}, service = {},
      diagnostics = {}, controlProvider = {}, bundleLoader = {},
      observability = {}, compatibility = {},
      registerBridgeAdapter = function() return true end,
      acquireCore = function() return nil end,
      loadResourceFile = function() return nil end,
      decode = function() return nil end,
      getResourceState = function() return 'stopped' end,
      wait = function() end, createThread = function() end,
    })
    assert(application.resourceStopped('synex_core'))
    local ownersRemaining = 0
    for _ in pairs(ownerEpochs) do ownersRemaining = ownersRemaining + 1 end
    return { revoked = revoked, cleaned = cleaned, reconciled = reconciled,
      ownersRemaining = ownersRemaining, coreCleared = coreRef.value == nil,
      ready = application.isReady() }
  `, lifecycleFiles);

  assert.deepEqual(result, {
    revoked: [
      'fixture:3:CORE_STOPPED',
      'synex_interact:7:CORE_STOPPED',
    ],
    cleaned: ['fixture:3', 'synex_interact:7'],
    reconciled: 1,
    ownersRemaining: 0,
    coreCleared: true,
    ready: false,
  });
});

test('Core service health preserves an unhealthy Interaction diagnosis', async () => {
  const result = await runInteractLua<{
    initialFence: string;
    bootstrap: string;
    periodic: string;
  }>(`
    local healthCalls, worker = {}, nil
    local api = {
      ownerEpoch = 9,
      Runtime = { getSnapshot = function() return { resources = {} } end },
      Services = {
        provide = function() return { token = 'service' } end,
        setHealth = function(_, _, state)
          healthCalls[#healthCalls + 1] = state
          return true
        end,
        call = function() return true end,
      },
      RPC = {
        registerServer = function() return { token = 'server' } end,
        registerNetwork = function() return { token = 'network' } end,
        call = function() return true end,
      },
      Scheduler = { every = function(_, callback)
        worker = callback
        return { token = 'worker' }
      end },
      Ids = { next = function() return 'id-00000001' end },
      Players = { getBySource = function() return nil end },
      Capabilities = { checkResource = function() return true end },
      Permissions = { check = function() return true end },
      ControlProviders = { register = function() return { token = 'control' } end },
      Metrics = { increment = function() return true end },
      Audit = { append = function() return true end },
      Events = { publish = function() return true end },
    }
    local contracts = {}
    for index = 1, 12 do
      contracts[index] = { name = 'fixture.contract.' .. index,
        version = '1.0.0', network = 'server-only' }
    end
    local authority = {
      expire = function() return true end,
      revokeOwner = function() return 0 end,
      reconcileSlots = function() return true end,
    }
    local diagnostics = {
      health = function() return { state = 'UNHEALTHY', status = 'UNHEALTHY' } end,
      doctor = function() return { status = 'UNHEALTHY', findings = {} } end,
      summary = function() return { activeLeases = 0, activeSessions = 0,
        activeExecutions = 0, reservations = 0 } end,
    }
    local application = SynexInteractApplication.create({
      resourceName = 'synex_interact', coreResource = 'synex_core',
      coreRef = {}, ownerEpochs = {}, registry = {
        cleanupOwner = function() return 0 end,
        currentRevision = function() return 0 end,
      },
      authority = authority, graph = {},
      service = {
        serviceDefinition = function() return {} end,
        contractHandler = function() return function() return true end end,
      },
      diagnostics = diagnostics,
      controlProvider = { register = function() return { token = 'control' } end },
      bundleLoader = { discoverAll = function()
        return { resources = {}, unresolved = {} }
      end },
      observability = { gauge = function() return true end,
        event = function() return true end, denied = function() end },
      compatibility = { definition = function() return {} end,
        implementation = function() return {} end },
      registerBridgeAdapter = function() return { token = 'bridge' } end,
      acquireCore = function() return api end,
      loadResourceFile = function() return '{}' end,
      decode = function() return { schema = 1, domain = 'synex.interact',
        contracts = contracts } end,
      getResourceState = function(resource)
        return resource == 'synex_bridge' and 'stopped' or 'started'
      end,
      wait = function() end,
      createThread = function(callback) callback() end,
      now = function() return 100 end,
    })
    assert(application.start())
    assert(worker ~= nil)
    for _ = 1, 120 do worker() end
    return { initialFence = healthCalls[1], bootstrap = healthCalls[2],
      periodic = healthCalls[#healthCalls] }
  `, lifecycleFiles);

  assert.deepEqual(result, {
    initialFence: 'UNHEALTHY',
    bootstrap: 'UNHEALTHY',
    periodic: 'UNHEALTHY',
  });
});
