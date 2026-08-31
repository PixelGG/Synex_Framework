import assert from 'node:assert/strict';
import test from 'node:test';

import { interactBundleFactory, runInteractLua } from './helpers.js';

test('registry accepts the documented smart-object and owner-bundle bounds and rejects overflow', async () => {
  const result = await runInteractLua<{
    smartObjects: number;
    intents: number;
    ownerBundles: number;
    objectOverflow: string;
    bundleOverflow: string;
  }>(`${interactBundleFactory}
    local function scaleBundle(bundleIndex, objectCount)
      local bundle = __interactBundle()
      local prefix = ('fixture:scale.%03d'):format(bundleIndex)
      bundle.key = prefix .. '.bundle'
      bundle.graphs[1].key = prefix .. '.graph'
      bundle.smartObjects, bundle.intents = {}, {}
      for index = 1, objectCount do
        local objectKey = prefix .. ('.object.%03d'):format(index)
        local intentKey = prefix .. ('.intent.%03d'):format(index)
        bundle.smartObjects[index] = {
          key = objectKey,
          binding = { type = 'staticTransform',
            position = { x = index % 20, y = math.floor(index / 20), z = 0 } },
          slots = {{ key = 'operator', capacity = 1, interactionRadius = 2,
            facingTolerance = 90 }},
          activities = { intentKey },
        }
        bundle.intents[index] = {
          key = intentKey, smartObjectKey = objectKey,
          verb = 'inspect', label = 'Inspect', basePriority = 0, specificity = 1,
          trigger = 'primary', slotSelector = 'operator', visibilityConditions = {},
          executionPolicy = { maximumDistance = 2, leaseTtlMs = 2500,
            maximumLifetimeMs = 10000, lockChannels = {} },
          actionGraphRef = bundle.graphs[1].key, presentation = {},
          participants = {{ role = 'operator', required = true,
            slotKey = 'operator', capacity = 1, lossPolicy = 'ABORT' }},
        }
      end
      return bundle
    end

    local registry = SynexInteractRegistry.create({ compiler = SynexInteractCompiler,
      isOwnerCurrent = function(owner, epoch) return owner == 'fixture' and epoch == 1 end })
    assert(registry.register('fixture', 1,
      scaleBundle(1, SynexInteractLimits.maximumBundleSmartObjects)))
    local snapshot = registry.snapshot()
    local _, objectOverflow = registry.register('fixture', 1,
      scaleBundle(2, SynexInteractLimits.maximumBundleSmartObjects + 1))

    local ownerRegistry = SynexInteractRegistry.create({ compiler = SynexInteractCompiler,
      isOwnerCurrent = function(owner, epoch) return owner == 'fixture' and epoch == 1 end })
    for index = 1, SynexInteractLimits.maximumOwnerBundles do
      assert(ownerRegistry.register('fixture', 1, scaleBundle(index, 1)))
    end
    local _, bundleOverflow = ownerRegistry.register('fixture', 1,
      scaleBundle(SynexInteractLimits.maximumOwnerBundles + 1, 1))
    return { smartObjects = snapshot.smartObjects, intents = snapshot.intents,
      ownerBundles = ownerRegistry.snapshot().bundles,
      objectOverflow = objectOverflow.code, bundleOverflow = bundleOverflow.code }
  `);

  assert.deepEqual(result, {
    smartObjects: 128,
    intents: 128,
    ownerBundles: 32,
    objectOverflow: 'INTERACT_BUNDLE_INVALID',
    bundleOverflow: 'INTERACT_BUNDLE_CONFLICT',
  });
});

test('client discovery caps candidates and expensive evaluation at the production limits', async () => {
  const result = await runInteractLua<{
    discovered: number;
    candidates: number;
    expensive: number;
    topSummaries: number;
    firstProviderCalls: number;
    overflowProviderCalls: number;
  }>(`
    local clock, firstProviderCalls, overflowProviderCalls = 1000, 0, 0
    local ports = {
      playerPed = function() return 1 end,
      entityExists = function(entity) return entity == 1 end,
      entityCoords = function() return { x = 0, y = 0, z = 0 } end,
      entityVelocity = function() return { x = 0, y = 0, z = 0 } end,
      entityHeading = function() return 0 end,
      vehicleForPed = function() return 0 end,
      pedDead = function() return false end,
      pedRagdoll = function() return false end,
      pedArmed = function() return false end,
      cameraPosition = function() return { x = 0, y = -1, z = 0 } end,
      cameraRotation = function() return { x = 0, y = 0, z = 0 } end,
      startLosProbe = function() return 1 end,
      shapeTestResult = function() return 1 end,
    }
    local function dynamicObject(suffix, provider)
      return { key = 'fixture:object.' .. suffix, revision = 1,
        binding = { type = 'dynamic', provider = provider,
          bindingKey = 'dynamic-' .. suffix }, tags = {},
        slots = {{ key = 'slot', localTransform = { position = { x = 0, y = 0, z = 0 } },
          interactionRadius = 20, facingTolerance = 180, tags = {}, initialState = 'FREE' }},
        intents = {{ key = 'fixture:intent.' .. suffix, revision = 1,
          verb = 'Use', label = 'Use', basePriority = 0, specificity = 0,
          trigger = 'primary', visibilityConditions = {}, presentation = {} }},
        presentation = {} }
    end
    local function providerItems(bindingKey)
      local values = {}
      for index = 1, SynexInteractLimits.maximumCandidateBatch do
        values[index] = { bindingKey = bindingKey,
          position = { x = (index % 10) * 0.05,
            y = 1 + math.floor(index / 10) * 0.05, z = 0 },
          netId = index, model = 1 }
      end
      return values
    end
    local sensor = SynexInteractSensor.create({ now = function() return clock end,
      ports = ports, world = { getContext = function() return {} end,
        nearbyAnchors = function() return {} end } })
    assert(sensor.replaceDiscovery({ schemaVersion = 1, revision = 2,
      unchanged = false, objects = {
        dynamicObject('a', 'provider_a:nearby'),
        dynamicObject('b', 'provider_b:nearby'),
      } }))
    assert(sensor.registerProvider('provider_a', 1,
      { key = 'provider_a:nearby', kind = 'dynamic' }, function()
        firstProviderCalls = firstProviderCalls + 1
        return providerItems('dynamic-a')
      end))
    assert(sensor.registerProvider('provider_b', 1,
      { key = 'provider_b:nearby', kind = 'dynamic' }, function()
        overflowProviderCalls = overflowProviderCalls + 1
        return providerItems('dynamic-b')
      end))
    local _, candidates, metadata = assert(sensor.sample())
    local snapshot = sensor.snapshot()
    return { discovered = snapshot.objects, candidates = #candidates,
      expensive = metadata.expensiveCandidateCount,
      topSummaries = #snapshot.topCandidates,
      firstProviderCalls = firstProviderCalls,
      overflowProviderCalls = overflowProviderCalls }
  `, [
    'resources/synex_interact/shared/limits.lua',
    'resources/synex_interact/shared/validation.lua',
    'resources/synex_interact/client/cancellation.lua',
    'resources/synex_interact/client/sensor.lua',
  ]);

  assert.deepEqual({ ...result, topSummaries: undefined }, {
    discovered: 2,
    candidates: 128,
    expensive: 8,
    topSummaries: undefined,
    firstProviderCalls: 1,
    overflowProviderCalls: 0,
  });
  assert.ok(result.topSummaries > 0 && result.topSummaries <= 8);
});

test('reservation, session, and lease stores reject capacity overflow and fully recover', async () => {
  const result = await runInteractLua<{
    reservationPeak: number;
    reservationOverflow: string;
    reservationFinal: number;
    sessionPeak: number;
    sessionOverflow: string;
    sessionFinal: number;
    leasePeak: number;
    leaseSessions: number;
    leaseReservations: number;
    leaseOverflow: string;
    expired: number;
    leaseFinal: number;
    leaseSessionFinal: number;
    leaseReservationFinal: number;
  }>(`${interactBundleFactory}
    local clock = 1000

    SynexInteractLimits.maximumReservations = 16
    local slots = SynexInteractSlots.create({ now = function() return clock end })
    slots.reconcile({{ bundle = { ownerResource = 'fixture', ownerEpoch = 1, revision = 1 },
      object = { key = 'fixture:capacity', slotOrder = { 'operator' }, slots = {
        operator = { key = 'operator', capacity = 32, initialState = 'FREE' },
      } } }})
    for index = 1, 16 do
      assert(slots.reserve({ reservationId = ('reservation-%04d'):format(index),
        sessionId = ('session-%04d'):format(index), actorKey = index .. ':1',
        slotClaims = {{ objectKey = 'fixture:capacity', slotKey = 'operator' }},
        expiresAt = 5000, ownerResource = 'fixture', ownerEpoch = 1,
        bundleRevision = 1 }))
    end
    local reservationPeak = slots.snapshot().reservations
    local _, reservationOverflow = slots.reserve({ reservationId = 'reservation-9999',
      sessionId = 'session-9999', actorKey = '999:1',
      slotClaims = {{ objectKey = 'fixture:capacity', slotKey = 'operator' }},
      expiresAt = 5000, ownerResource = 'fixture', ownerEpoch = 1, bundleRevision = 1 })
    for index = 1, 16 do slots.release(('reservation-%04d'):format(index)) end

    SynexInteractLimits.maximumActiveSessions = 16
    local sessions = SynexInteractSessions.create({ now = function() return clock end })
    local function sessionRequest(index)
      return { sessionId = ('session-%04d'):format(index), ownerResource = 'fixture',
        ownerEpoch = 1, bundleKey = 'fixture:bundle', bundleRevision = 1,
        intentKey = 'fixture:intent', target = { kind = 'static', bindingKey = 'fixture:target' },
        expiresAt = 5000, roles = {{ role = 'operator', required = true,
          capacity = 1, lossPolicy = 'ABORT' }} }
    end
    for index = 1, 16 do assert(sessions.create(sessionRequest(index))) end
    local sessionPeak = sessions.snapshot().active
    local _, sessionOverflow = sessions.create(sessionRequest(17))
    for index = 1, 16 do sessions.remove(('session-%04d'):format(index)) end

    SynexInteractLimits.maximumReservations = 32
    SynexInteractLimits.maximumActiveSessions = 32
    SynexInteractLimits.maximumActiveLeases = 16
    local registry = SynexInteractRegistry.create({ compiler = SynexInteractCompiler,
      isOwnerCurrent = function(owner, epoch) return owner == 'fixture' and epoch == 1 end })
    local bundle = __interactBundle()
    bundle.smartObjects[1].slots[1].capacity = 32
    assert(registry.register('fixture', 1, bundle))
    local leaseSlots = SynexInteractSlots.create({ now = function() return clock end })
    local leaseSessions = SynexInteractSessions.create({ now = function() return clock end })
    local serial = 0
    local authority = SynexInteractAuthority.create({ registry = registry, slots = leaseSlots,
      sessions = leaseSessions, locks = SynexInteractActorLocks.create(),
      now = function() return clock end,
      nextId = function(namespace)
        serial = serial + 1
        return namespace .. '-' .. ('%08d'):format(serial)
      end,
      validateTarget = function()
        return { distance = 1, revision = 1, position = { x = 10, y = 20, z = 30 } }
      end,
      observability = { denied = function() end, increment = function() end,
        trace = function() end, event = function() end, audit = function() end,
        observe = function() end },
    })
    authority.reconcileSlots()
    local function actor(index)
      local source = 100 + index
      return { source = source, sourceGeneration = 1, traceId = ('trace-%04d'):format(index),
        session = { source = source, sourceGeneration = 1, state = 'ACTIVE',
          id = ('identity-%04d'):format(index), characterId = ('character-%04d'):format(index),
          userId = ('user-%04d'):format(index) } }
    end
    local function request(index)
      return authority.requestLease({ intent = { key = 'fixture:inspect', revision = 1 },
        target = { kind = 'static', bindingKey = 'fixture:terminal' },
        clientRevision = registry.currentRevision() }, actor(index))
    end
    for index = 1, 16 do assert(request(index)) end
    local leasePeak = authority.snapshot().activeLeases
    local leaseSessionPeak = leaseSessions.snapshot().active
    local leaseReservationPeak = leaseSlots.snapshot().reservations
    local _, leaseOverflow = request(17)
    clock = 4000
    local expired = authority.expire(clock)
    return { reservationPeak = reservationPeak,
      reservationOverflow = reservationOverflow.code,
      reservationFinal = slots.snapshot().reservations,
      sessionPeak = sessionPeak, sessionOverflow = sessionOverflow.code,
      sessionFinal = sessions.snapshot().active,
      leasePeak = leasePeak, leaseSessions = leaseSessionPeak,
      leaseReservations = leaseReservationPeak, leaseOverflow = leaseOverflow.code,
      expired = expired, leaseFinal = authority.snapshot().activeLeases,
      leaseSessionFinal = leaseSessions.snapshot().active,
      leaseReservationFinal = leaseSlots.snapshot().reservations }
  `);

  assert.deepEqual(result, {
    reservationPeak: 16,
    reservationOverflow: 'INTERACT_SLOT_BUSY',
    reservationFinal: 0,
    sessionPeak: 16,
    sessionOverflow: 'INTERACT_SESSION_LIMIT',
    sessionFinal: 0,
    leasePeak: 16,
    leaseSessions: 16,
    leaseReservations: 16,
    leaseOverflow: 'INTERACT_ACTOR_BUSY',
    expired: 16,
    leaseFinal: 0,
    leaseSessionFinal: 0,
    leaseReservationFinal: 0,
  });
});
