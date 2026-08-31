import assert from 'node:assert/strict';
import test from 'node:test';

import { interactBundleFactory, runInteractLua } from './helpers.js';

test('slot reservations are atomic, capacity-aware, expiring, and leak-free', async () => {
  const result = await runInteractLua<{
    firstState: string;
    rollbackCode: string;
    secondAfterRollback: string;
    occupiedUnits: number;
    expired: number;
    finalReservations: number;
  }>(`
    local clock = 1000
    local slots = SynexInteractSlots.create({ now = function() return clock end })
    local bundle = { ownerResource = 'fixture', ownerEpoch = 1, revision = 1 }
    local object = { key = 'fixture:bench', slotOrder = { 'operator', 'assistant' }, slots = {
      operator = { key = 'operator', capacity = 2, initialState = 'FREE' },
      assistant = { key = 'assistant', capacity = 1, initialState = 'FREE' },
    } }
    slots.reconcile({ { bundle = bundle, object = object } })
    assert(slots.reserve({ reservationId = 'reservation-0001', sessionId = 'session-0001',
      actorKey = '1:1', slotClaims = {
        { objectKey = 'fixture:bench', slotKey = 'operator', units = 2 },
      }, expiresAt = 1500, ownerResource = 'fixture', ownerEpoch = 1, bundleRevision = 1 }))
    local first = slots.list(0, 10).items[2]

    local _, rollbackError = slots.reserve({ reservationId = 'reservation-0002',
      sessionId = 'session-0002', actorKey = '2:1', slotClaims = {
        { objectKey = 'fixture:bench', slotKey = 'assistant' },
        { objectKey = 'fixture:bench', slotKey = 'operator' },
      }, expiresAt = 1500, ownerResource = 'fixture', ownerEpoch = 1, bundleRevision = 1 })
    local listed = slots.list(0, 10).items
    local assistant = listed[1]
    assert(slots.occupy('reservation-0001', 'session-0001'))
    listed = slots.list(0, 10).items
    local operator = listed[2]
    clock = 1600
    local expired = slots.expire(clock)
    return { firstState = first.state, rollbackCode = rollbackError.code,
      secondAfterRollback = assistant.state, occupiedUnits = operator.occupied,
      expired = expired, finalReservations = slots.snapshot().reservations }
  `);

  assert.deepEqual(result, {
    firstState: 'RESERVED',
    rollbackCode: 'INTERACT_SLOT_BUSY',
    secondAfterRollback: 'FREE',
    occupiedUnits: 2,
    expired: 1,
    finalReservations: 0,
  });
});

test('exclusive Smart Objects reject foreign sessions across different slots', async () => {
  const result = await runInteractLua<{
    foreign: string;
    sameSession: boolean;
    reservations: number;
  }>(`
    local slots = SynexInteractSlots.create({ now = function() return 100 end })
    slots.reconcile({{ bundle = { ownerResource = 'fixture', ownerEpoch = 1, revision = 1 },
      object = { key = 'fixture:exclusive', slotOrder = { 'left', 'right' },
        availabilityPolicy = { enabled = true },
        concurrencyPolicy = { mode = 'exclusive' }, slots = {
          left = { key = 'left', capacity = 1, initialState = 'FREE',
            availabilityPolicy = { enabled = true } },
          right = { key = 'right', capacity = 1, initialState = 'FREE',
            availabilityPolicy = { enabled = true } },
        } } }})
    local function reserve(id, sessionId, slotKey)
      return slots.reserve({ reservationId = id, sessionId = sessionId,
        actorKey = sessionId == 'session-0001' and '1:1' or '2:1',
        slotClaims = {{ objectKey = 'fixture:exclusive', slotKey = slotKey }},
        expiresAt = 1000, ownerResource = 'fixture', ownerEpoch = 1,
        bundleRevision = 1 })
    end
    assert(reserve('reservation-0001', 'session-0001', 'left'))
    local _, foreignError = reserve('reservation-0002', 'session-0002', 'right')
    local sameSession = reserve('reservation-0003', 'session-0001', 'right')
    return { foreign = foreignError.code, sameSession = sameSession ~= nil,
      reservations = slots.snapshot().reservations }
  `);

  assert.deepEqual(result, {
    foreign: 'INTERACT_SLOT_BUSY',
    sameSession: true,
    reservations: 2,
  });
});

test('multi-actor authority reserves every declared role slot atomically and occupies at the ready barrier', async () => {
  const result = await runInteractLua<{
    blocked: string;
    rollbackOperator: string;
    rollbackAssistant: string;
    reservationsAfterRollback: number;
    sharedReservation: boolean;
    firstState: string;
    secondState: string;
    occupied: number;
    reservationsAfterFinish: number;
  }>(`${interactBundleFactory}
    local clock, serial = 1000, 0
    local bundle = __interactBundle()
    bundle.smartObjects[1].slots = {
      { key = 'operator', capacity = 1, interactionRadius = 2.0,
        facingTolerance = 90, tags = {} },
      { key = 'assistant', capacity = 1, interactionRadius = 2.0,
        facingTolerance = 90, tags = {} },
      { key = 'target', capacity = 1, interactionRadius = 2.0,
        facingTolerance = 90, tags = {} },
    }
    bundle.intents[1].participants = {
      { role = 'operator', required = true, slotKey = 'operator',
        capacity = 1, lossPolicy = 'ABORT' },
      { role = 'assistant', required = true, slotKey = 'assistant',
        capacity = 1, lossPolicy = 'ABORT' },
      { role = 'target', required = true, slotKey = 'target',
        capacity = 1, lossPolicy = 'ABORT' },
    }
    local registry = SynexInteractRegistry.create({ compiler = SynexInteractCompiler,
      isOwnerCurrent = function(owner, epoch) return owner == 'fixture' and epoch == 1 end })
    assert(registry.register('fixture', 1, bundle))
    local slots = SynexInteractSlots.create({ now = function() return clock end })
    local sessions = SynexInteractSessions.create({ now = function() return clock end })
    local authority = SynexInteractAuthority.create({ registry = registry, slots = slots,
      sessions = sessions, locks = SynexInteractActorLocks.create(),
      now = function() return clock end,
      nextId = function(namespace) serial = serial + 1
        return namespace .. '-' .. string.format('%08d', serial) end,
      validateTarget = function() return { distance = 1.0, revision = 1 } end,
      checkPolicy = function() return true end,
      observability = { denied = function() end, increment = function() end,
        trace = function() end, event = function() end, audit = function() end,
        observe = function() end },
    })
    authority.setGraphRuntime({
      start = function(session)
        assert(sessions.setExecution(session.id, 'execution-multi'))
        return { executionId = 'execution-multi', state = 'RUNNING' }
      end,
      cancel = function() return true end,
    })
    authority.reconcileSlots()
    assert(slots.reserve({ reservationId = 'blocker-reservation-0001',
      sessionId = 'blocker-session-0001', actorKey = '99:1',
      slotClaims = {{ objectKey = 'fixture:terminal', slotKey = 'target' }},
      expiresAt = 4000, ownerResource = 'fixture', ownerEpoch = 1,
      bundleRevision = 1 }))

    local function player(source, name)
      local session = { source = source, sourceGeneration = 1, state = 'ACTIVE',
        id = 'identity-' .. name, characterId = 'character-' .. name }
      return { source = source, sourceGeneration = 1, session = session,
        traceId = 'trace-' .. name }
    end
    local operatorContext = player(10, 'operator')
    local request = { intent = { key = 'fixture:inspect', revision = 1 },
      target = { kind = 'static', bindingKey = 'fixture:terminal' },
      clientRevision = registry.currentRevision(), slotKey = 'operator' }
    local _, blocked = authority.requestLease(request, operatorContext)
    local rollback = {}
    for _, slot in ipairs(slots.list(0, 10).items) do rollback[slot.key] = slot.state end
    local reservationsAfterRollback = slots.snapshot().reservations
    assert(slots.release('blocker-reservation-0001'))

    local operator = assert(authority.requestLease(request, operatorContext))
    local assistantContext = player(11, 'assistant')
    local targetContext = player(12, 'target')
    local players = { [10] = operatorContext.session, [11] = assistantContext.session,
      [12] = targetContext.session }
    assert(authority.setCurrentSessionResolver(function(source) return players[source] end))
    local assistantInvite = assert(authority.inviteSession({
      sessionId = operator.sessionId, role = 'assistant', source = 11 }, 'fixture', 1))
    local targetInvite = assert(authority.inviteSession({
      sessionId = operator.sessionId, role = 'target', source = 12 }, 'fixture', 1))
    local assistant = assert(authority.joinSession({ sessionId = operator.sessionId,
      role = 'assistant', invitationId = assistantInvite.invitationId }, assistantContext))
    local target = assert(authority.joinSession({ sessionId = operator.sessionId,
      role = 'target', invitationId = targetInvite.invitationId }, targetContext))
    local operatorLease = assert(authority.getLease(operator.leaseId))
    local assistantLease = assert(authority.getLease(assistant.leaseId))
    local targetLease = assert(authority.getLease(target.leaseId))
    local sharedReservation = operatorLease.reservationId == assistantLease.reservationId
      and assistantLease.reservationId == targetLease.reservationId
    local first = assert(authority.activateLease({ leaseId = operator.leaseId,
      nonce = operator.nonce }, operatorContext))
    local second = assert(authority.activateLease({ leaseId = assistant.leaseId,
      nonce = assistant.nonce }, assistantContext))
    local beforeBarrier = slots.snapshot()
    assert(beforeBarrier.reserved == 3 and beforeBarrier.occupied == 0)
    assert(authority.activateLease({ leaseId = target.leaseId,
      nonce = target.nonce }, targetContext))
    local occupied = slots.snapshot().occupied
    assert(authority.finishExecution({ sessionId = operator.sessionId }, 'COMPLETED'))
    return { blocked = blocked.code, rollbackOperator = rollback.operator,
      rollbackAssistant = rollback.assistant,
      reservationsAfterRollback = reservationsAfterRollback,
      sharedReservation = sharedReservation, firstState = first.state,
      secondState = second.state, occupied = occupied,
      reservationsAfterFinish = slots.snapshot().reservations }
  `);

  assert.deepEqual(result, {
    blocked: 'INTERACT_SLOT_BUSY',
    rollbackOperator: 'FREE',
    rollbackAssistant: 'FREE',
    reservationsAfterRollback: 1,
    sharedReservation: true,
    firstState: 'WAITING',
    secondState: 'WAITING',
    occupied: 3,
    reservationsAfterFinish: 0,
  });
});

test('optional roles do not block start and join running graphs only when explicitly enabled', async () => {
  const result = await runInteractLua<{
    requestSucceeded: boolean;
    blockedOptional: string;
    nonLate: string;
    separateReservation: boolean;
    graphAdmissions: number;
    occupied: number;
    finalReservations: number;
  }>(`${interactBundleFactory}
    local clock, serial, graphAdmissions = 1000, 0, 0
    local bundle = __interactBundle()
    bundle.smartObjects[1].slots = {
      { key = 'operator', capacity = 1, interactionRadius = 2,
        facingTolerance = 90, tags = {} },
      { key = 'assistant', capacity = 1, interactionRadius = 2,
        facingTolerance = 90, tags = {} },
      { key = 'observer', capacity = 1, interactionRadius = 2,
        facingTolerance = 90, tags = {} },
    }
    bundle.intents[1].participants = {
      { role = 'operator', required = true, slotKey = 'operator',
        capacity = 1, lossPolicy = 'ABORT' },
      { role = 'assistant', required = false, slotKey = 'assistant',
        capacity = 1, lossPolicy = 'CONTINUE', lateJoin = true },
      { role = 'observer', required = false, slotKey = 'observer',
        capacity = 1, lossPolicy = 'CONTINUE' },
    }
    local registry = SynexInteractRegistry.create({ compiler = SynexInteractCompiler,
      isOwnerCurrent = function(owner, epoch) return owner == 'fixture' and epoch == 1 end })
    assert(registry.register('fixture', 1, bundle))
    local slots = SynexInteractSlots.create({ now = function() return clock end })
    local sessions = SynexInteractSessions.create({ now = function() return clock end })
    local authority = SynexInteractAuthority.create({ registry = registry, slots = slots,
      sessions = sessions, locks = SynexInteractActorLocks.create(),
      now = function() return clock end,
      nextId = function(namespace) serial = serial + 1
        return namespace .. '-' .. string.format('%08d', serial) end,
      validateTarget = function() return { distance = 1, revision = 1 } end,
      checkPolicy = function() return true end,
      observability = { denied = function() end, increment = function() end,
        trace = function() end, event = function() end, audit = function() end,
        observe = function() end },
    })
    authority.setGraphRuntime({
      start = function(session)
        assert(sessions.setExecution(session.id, 'execution-optional'))
        return { executionId = 'execution-optional', state = 'RUNNING' }
      end,
      participantJoined = function() graphAdmissions = graphAdmissions + 1; return true end,
      cancel = function() return true end,
    })
    authority.reconcileSlots()
    assert(slots.reserve({ reservationId = 'reservation-blocker',
      sessionId = 'session-blocker', actorKey = '99:1',
      slotClaims = {{ objectKey = 'fixture:terminal', slotKey = 'assistant' }},
      expiresAt = 5000, ownerResource = 'fixture', ownerEpoch = 1,
      bundleRevision = 1 }))
    local function context(source, role)
      return { source = source, sourceGeneration = 1,
        session = { source = source, sourceGeneration = 1, state = 'ACTIVE',
          id = 'identity-' .. role, characterId = 'character-' .. role },
        traceId = 'trace-' .. role }
    end
    local operatorContext = context(10, 'operator')
    local operator = assert(authority.requestLease({
      intent = { key = 'fixture:inspect', revision = 1 },
      target = { kind = 'static', bindingKey = 'fixture:terminal' },
      clientRevision = registry.currentRevision(), slotKey = 'operator',
    }, operatorContext))
    assert(authority.activateLease({ leaseId = operator.leaseId,
      nonce = operator.nonce }, operatorContext))
    local assistantContext = context(11, 'assistant')
    local observerContext = context(12, 'observer')
    local players = { [10] = operatorContext.session, [11] = assistantContext.session,
      [12] = observerContext.session }
    assert(authority.setCurrentSessionResolver(function(source) return players[source] end))
    local blockedInvite = assert(authority.inviteSession({
      sessionId = operator.sessionId, role = 'assistant', source = 11 }, 'fixture', 1))
    local _, blockedOptional = authority.joinSession({
      sessionId = operator.sessionId, role = 'assistant',
      invitationId = blockedInvite.invitationId }, assistantContext)
    local _, nonLate = authority.joinSession({ sessionId = operator.sessionId,
      role = 'observer', invitationId = 'invitation-not-used-0001' }, observerContext)
    assert(slots.release('reservation-blocker'))
    local assistantInvite = assert(authority.inviteSession({
      sessionId = operator.sessionId, role = 'assistant', source = 11 }, 'fixture', 1))
    local assistant = assert(authority.joinSession({
      sessionId = operator.sessionId, role = 'assistant',
      invitationId = assistantInvite.invitationId }, assistantContext))
    local operatorLease = assert(authority.getLease(operator.leaseId))
    local assistantLease = assert(authority.getLease(assistant.leaseId))
    assert(authority.activateLease({ leaseId = assistant.leaseId,
      nonce = assistant.nonce }, assistantContext))
    local occupied = slots.snapshot().occupied
    assert(authority.finishExecution({ sessionId = operator.sessionId }, 'COMPLETED'))
    return { requestSucceeded = operator ~= nil, blockedOptional = blockedOptional.code,
      nonLate = nonLate.code,
      separateReservation = operatorLease.reservationId ~= assistantLease.reservationId,
      graphAdmissions = graphAdmissions, occupied = occupied,
      finalReservations = slots.snapshot().reservations }
  `);

  assert.deepEqual(result, {
    requestSucceeded: true,
    blockedOptional: 'INTERACT_SLOT_BUSY',
    nonLate: 'INTERACT_PARTICIPANT_DENIED',
    separateReservation: true,
    graphAdmissions: 1,
    occupied: 2,
    finalReservations: 0,
  });
});

test('replacement pauses do not bypass explicit late-join policy', async () => {
  const result = await runInteractLua<{
    pausedState: string;
    ordinaryOptional: string;
    explicitLate: boolean;
    replacement: boolean;
  }>(`
    local clock = 1000
    local sessions = SynexInteractSessions.create({ now = function() return clock end })
    local session = assert(sessions.create({ sessionId = 'session-replacement-policy',
      ownerResource = 'fixture', ownerEpoch = 1, bundleKey = 'fixture:bundle',
      bundleRevision = 1, intentKey = 'fixture:inspect',
      target = { kind = 'static', bindingKey = 'fixture:terminal' },
      reservationId = 'reservation-required', expiresAt = 5000,
      roles = {
        { role = 'operator', required = true, capacity = 1,
          lossPolicy = 'REPLACE' },
        { role = 'observer', required = false, capacity = 1,
          lossPolicy = 'CONTINUE' },
        { role = 'assistant', required = false, capacity = 1,
          lossPolicy = 'CONTINUE', lateJoin = true },
      },
    }))
    local operator = { source = 10, sourceGeneration = 1,
      sessionIdentity = 'identity-operator' }
    assert(sessions.join(session.id, operator, 'operator',
      'lease-operator', 'reservation-required'))
    assert(sessions.markReady(session.id, '10:1'))
    assert(sessions.setExecution(session.id, 'execution-running'))
    local left = assert(sessions.leave(session.id, '10:1', 'PARTICIPANT_LEFT'))
    local _, ordinaryError = sessions.join(session.id,
      { source = 11, sourceGeneration = 1, sessionIdentity = 'identity-observer' },
      'observer', 'lease-observer', 'reservation-observer')
    local explicitLate = sessions.join(session.id,
      { source = 12, sourceGeneration = 1, sessionIdentity = 'identity-assistant' },
      'assistant', 'lease-assistant', 'reservation-assistant')
    local replacement = sessions.join(session.id,
      { source = 13, sourceGeneration = 1, sessionIdentity = 'identity-replacement' },
      'operator', 'lease-replacement', 'reservation-required')
    return { pausedState = left.state, ordinaryOptional = ordinaryError.code,
      explicitLate = explicitLate ~= nil, replacement = replacement ~= nil }
  `);

  assert.deepEqual(result, {
    pausedState: 'WAITING',
    ordinaryOptional: 'INTERACT_PARTICIPANT_DENIED',
    explicitLate: true,
    replacement: true,
  });
});

test('actor locks and multi-actor ready barriers enforce deterministic ownership', async () => {
  const result = await runInteractLua<{
    conflict: string;
    firstReady: boolean;
    secondReady: boolean;
    lossState: string;
    remainingLocks: number;
  }>(`
    local locks = SynexInteractActorLocks.create()
    assert(locks.claim('1:1', { 'actor.hands' }, 'session-0001', 'execution-0001'))
    assert(locks.claim('1:1', { 'actor.hands' }, 'session-0001', 'execution-0001'))
    assert(locks.snapshot().active == 1)
    local _, conflict = locks.claim('1:1', { 'actor.hands' },
      'session-0002', 'execution-0002')
    local sessions = SynexInteractSessions.create({ now = function() return 1000 end })
    assert(sessions.create({ sessionId = 'session-0001', ownerResource = 'fixture',
      ownerEpoch = 1, bundleKey = 'fixture:bundle', bundleRevision = 1,
      intentKey = 'fixture:intent', target = { kind = 'static', bindingKey = 'fixture:target' },
      expiresAt = 5000, roles = {{ role = 'operator', required = true,
        capacity = 2, lossPolicy = 'ABORT' }} }))
    assert(sessions.join('session-0001', { source = 1, sourceGeneration = 1,
      sessionIdentity = 'identity-0001' }, 'operator', 'lease-0001', 'reservation-0001'))
    assert(sessions.join('session-0001', { source = 2, sourceGeneration = 1,
      sessionIdentity = 'identity-0002' }, 'operator', 'lease-0002', 'reservation-0002'))
    local first = assert(sessions.markReady('session-0001', '1:1'))
    local second = assert(sessions.markReady('session-0001', '2:1'))
    assert(sessions.setExecution('session-0001', 'execution-0001'))
    local lost = assert(sessions.leave('session-0001', '2:1', 'PARTICIPANT_LOST'))
    locks.release('session-0001', 'execution-0001')
    return { conflict = conflict.code, firstReady = first.ready,
      secondReady = second.ready, lossState = lost.state,
      remainingLocks = locks.snapshot().active }
  `);

  assert.deepEqual(result, {
    conflict: 'INTERACT_ACTOR_BUSY',
    firstReady: false,
    secondReady: true,
    lossState: 'CANCELLING',
    remainingLocks: 0,
  });
});

test('participant loss policies distinguish abort, continue, and explicit replacement', async () => {
  const result = await runInteractLua<{
    continueState: string;
    replacementState: string;
    lateJoin: string;
  }>(`
    local sessions = SynexInteractSessions.create({ now = function() return 1000 end })
    assert(sessions.create({ sessionId = 'session-continue', ownerResource = 'fixture',
      ownerEpoch = 1, bundleKey = 'fixture:bundle', bundleRevision = 1,
      intentKey = 'fixture:intent', target = { kind = 'static', bindingKey = 'fixture:target' },
      expiresAt = 5000, roles = {{ role = 'operator', required = true,
        capacity = 2, lossPolicy = 'CONTINUE' }} }))
    assert(sessions.join('session-continue', { source = 1, sourceGeneration = 1,
      sessionIdentity = 'identity-0001' }, 'operator', 'lease-0001', 'reservation-0001'))
    assert(sessions.join('session-continue', { source = 2, sourceGeneration = 1,
      sessionIdentity = 'identity-0002' }, 'operator', 'lease-0002', 'reservation-0002'))
    assert(sessions.markReady('session-continue', '1:1'))
    assert(sessions.markReady('session-continue', '2:1'))
    assert(sessions.setExecution('session-continue', 'execution-0001'))
    local continued = assert(sessions.leave('session-continue', '2:1', 'PARTICIPANT_LOST'))
    local _, lateJoin = sessions.join('session-continue', { source = 3, sourceGeneration = 1,
      sessionIdentity = 'identity-0003' }, 'operator', 'lease-0003', 'reservation-0003')

    assert(sessions.create({ sessionId = 'session-replace', ownerResource = 'fixture',
      ownerEpoch = 1, bundleKey = 'fixture:bundle', bundleRevision = 1,
      intentKey = 'fixture:intent', target = { kind = 'static', bindingKey = 'fixture:target' },
      expiresAt = 5000, roles = {{ role = 'assistant', required = true,
        capacity = 1, lossPolicy = 'REPLACE' }} }))
    assert(sessions.join('session-replace', { source = 4, sourceGeneration = 1,
      sessionIdentity = 'identity-0004' }, 'assistant', 'lease-0004', 'reservation-0004'))
    assert(sessions.markReady('session-replace', '4:1'))
    assert(sessions.setExecution('session-replace', 'execution-0002'))
    local replaced = assert(sessions.leave('session-replace', '4:1', 'PARTICIPANT_LOST'))
    return { continueState = continued.state, replacementState = replaced.state,
      lateJoin = lateJoin.code }
  `);

  assert.deepEqual(result, {
    continueState: 'RUNNING',
    replacementState: 'WAITING',
    lateJoin: 'INTERACT_PARTICIPANT_DENIED',
  });
});

test('session expiry and owner revocation clean reservations even without remaining leases', async () => {
  const result = await runInteractLua<{
    expiredSessions: number;
    expiredReservations: number;
    revoked: number;
    revokedSessions: number;
    revokedReservations: number;
  }>(`${interactBundleFactory}
    local clock = 1000
    local registry = SynexInteractRegistry.create({ compiler = SynexInteractCompiler,
      isOwnerCurrent = function(owner, epoch) return owner == 'fixture' and epoch == 1 end })
    assert(registry.register('fixture', 1, __interactBundle()))
    local slots = SynexInteractSlots.create({ now = function() return clock end })
    local sessions = SynexInteractSessions.create({ now = function() return clock end })
    local authority = SynexInteractAuthority.create({ registry = registry, slots = slots,
      sessions = sessions, locks = SynexInteractActorLocks.create(),
      now = function() return clock end,
      nextId = function() return 'unused-identifier' end,
      validateTarget = function() return { distance = 1, revision = 1 } end,
      observability = { denied = function() end, increment = function() end,
        trace = function() end, event = function() end, audit = function() end,
        observe = function() end },
    })
    authority.reconcileSlots()
    local function createWaiting(suffix, expiresAt)
      local sessionId = 'waiting-session-' .. suffix
      local reservationId = 'waiting-reservation-' .. suffix
      assert(sessions.create({ sessionId = sessionId, ownerResource = 'fixture',
        ownerEpoch = 1, bundleKey = 'fixture:terminal', bundleRevision = 1,
        intentKey = 'fixture:inspect',
        target = { kind = 'static', bindingKey = 'fixture:terminal' },
        reservationId = reservationId,
        slotClaims = {{ objectKey = 'fixture:terminal', slotKey = 'operator' }},
        expiresAt = expiresAt, roles = {{ role = 'operator', required = true,
          capacity = 1, lossPolicy = 'ABORT', slotKey = 'operator' }} }))
      assert(slots.reserve({ reservationId = reservationId, sessionId = sessionId,
        actorKey = '10:1',
        slotClaims = {{ objectKey = 'fixture:terminal', slotKey = 'operator' }},
        expiresAt = expiresAt, ownerResource = 'fixture', ownerEpoch = 1,
        bundleRevision = 1 }))
    end
    createWaiting('expiry', 1500)
    clock = 1600
    authority.expire(clock)
    local expiredSessions = sessions.snapshot().active
    local expiredReservations = slots.snapshot().reservations
    createWaiting('owner', 5000)
    local revoked = authority.revokeOwner('fixture', 1, 'OWNER_STOPPED')
    return { expiredSessions = expiredSessions,
      expiredReservations = expiredReservations, revoked = revoked,
      revokedSessions = sessions.snapshot().active,
      revokedReservations = slots.snapshot().reservations }
  `);

  assert.deepEqual(result, {
    expiredSessions: 0,
    expiredReservations: 0,
    revoked: 1,
    revokedSessions: 0,
    revokedReservations: 0,
  });
});

test('lease authority rejects stale discovery, source generations, range, and replayed activation', async () => {
  const result = await runInteractLua<{
    stale: string;
    generation: string;
    range: string;
    wrongNonce: string;
    activated: boolean;
    replay: string;
    graphReleased: number;
    activeLeases: number;
  }>(`${interactBundleFactory}
    local clock, serial = 1000, 0
    local registry = SynexInteractRegistry.create({ compiler = SynexInteractCompiler,
      isOwnerCurrent = function(owner, epoch) return owner == 'fixture' and epoch == 1 end })
    assert(registry.register('fixture', 1, __interactBundle()))
    local slots = SynexInteractSlots.create({ now = function() return clock end })
    local locks = SynexInteractActorLocks.create()
    local sessions = SynexInteractSessions.create({ now = function() return clock end })
    local observability = {
      denied = function() end, increment = function() end, trace = function() end,
      event = function() end, audit = function() end, observe = function() end,
    }
    local authority = SynexInteractAuthority.create({ registry = registry, slots = slots,
      sessions = sessions, locks = locks, now = function() return clock end,
      nextId = function(namespace) serial = serial + 1
        return namespace .. '-' .. string.format('%08d', serial) end,
      validateTarget = function(_, _, _, context)
        return { distance = context.claimDistance or 1.0, revision = 1 }
      end,
      checkPolicy = function() return true end, observability = observability,
    })
    local releaseFromGraph
    authority.setGraphRuntime({
      start = function() return { executionId = 'execution-0001', state = 'RUNNING' } end,
      cancel = function() return true end,
      setLeaseReleaser = function(handler) releaseFromGraph = handler; return true end,
    })
    authority.reconcileSlots()
    local session = { source = 10, sourceGeneration = 2, state = 'ACTIVE',
      id = 'identity-0001', characterId = 'character-0001', userId = 'user-0001' }
    local context = { source = 10, sourceGeneration = 2, session = session,
      traceId = 'trace-0001', claimDistance = 1.0 }
    local request = { intent = { key = 'fixture:inspect', revision = 1 },
      target = { kind = 'static', bindingKey = 'fixture:terminal' },
      clientRevision = registry.currentRevision(), slotKey = 'operator' }

    local staleRequest = SynexInteractValidation.copy(request)
    staleRequest.clientRevision = staleRequest.clientRevision - 1
    local _, stale = authority.requestLease(staleRequest, context)
    local staleContext = SynexInteractValidation.copy(context)
    staleContext.sourceGeneration = 1
    local _, generation = authority.requestLease(request, staleContext)
    local farContext = SynexInteractValidation.copy(context)
    farContext.claimDistance = 10
    local _, range = authority.requestLease(request, farContext)
    local issued = assert(authority.requestLease(request, context))
    local _, wrongNonce = authority.activateLease({ leaseId = issued.leaseId,
      nonce = 'wrong-nonce' }, context)
    local activated = assert(authority.activateLease({ leaseId = issued.leaseId,
      nonce = issued.nonce }, context))
    local _, replay = authority.activateLease({ leaseId = issued.leaseId,
      nonce = issued.nonce }, context)
    local graphReleased = assert(releaseFromGraph(
      issued.sessionId, issued.leaseId, 'GRAPH_RELEASED'))
    return { stale = stale.code, generation = generation.code, range = range.code,
      wrongNonce = wrongNonce.code, activated = activated.accepted,
      replay = replay.code, graphReleased = graphReleased.released,
      activeLeases = authority.snapshot().activeLeases }
  `);

  assert.deepEqual(result, {
    stale: 'INTERACT_INTENT_STALE',
    generation: 'INTERACT_LEASE_STALE',
    range: 'INTERACT_LEASE_DENIED',
    wrongNonce: 'INTERACT_LEASE_REPLAYED',
    activated: true,
    replay: 'INTERACT_LEASE_REPLAYED',
    graphReleased: 1,
    activeLeases: 0,
  });
});

test('lease authority rejects hostile entity-bone claims before target validation', async () => {
  const result = await runInteractLua<{
    managed: string;
    ambient: string;
    calls: number;
    accepted: boolean;
  }>(`${interactBundleFactory}
    local clock, serial, validationCalls = 1000, 0, 0
    local bundle = __interactBundle()
    bundle.smartObjects[1].binding = {
      type = 'entityBone', model = 900, bone = 'boot',
    }
    local registry = SynexInteractRegistry.create({ compiler = SynexInteractCompiler,
      isOwnerCurrent = function(owner, epoch) return owner == 'fixture' and epoch == 1 end })
    assert(registry.register('fixture', 1, bundle))
    local slots = SynexInteractSlots.create({ now = function() return clock end })
    local authority = SynexInteractAuthority.create({ registry = registry, slots = slots,
      sessions = SynexInteractSessions.create({ now = function() return clock end }),
      locks = SynexInteractActorLocks.create(), now = function() return clock end,
      nextId = function(namespace) serial = serial + 1
        return namespace .. '-' .. string.format('%08d', serial) end,
      validateTarget = function()
        validationCalls = validationCalls + 1
        return { distance = 1.0, revision = 3 }
      end,
      observability = { denied = function() end, increment = function() end,
        trace = function() end, event = function() end, audit = function() end,
        observe = function() end },
    })
    authority.reconcileSlots()
    local session = { source = 10, sourceGeneration = 2, state = 'ACTIVE',
      id = 'identity-0001', characterId = 'character-0001', userId = 'user-0001' }
    local context = { source = 10, sourceGeneration = 2, session = session,
      traceId = 'trace-hostile-bone' }
    local function request(target)
      return authority.requestLease({ intent = { key = 'fixture:inspect', revision = 1 },
        target = target, clientRevision = registry.currentRevision(), slotKey = 'operator' },
        context)
    end
    local _, managedError = request({ kind = 'entity', bone = 'door_dside_f',
      entityRef = { entityId = 'entity_exact_001', generation = 3 } })
    local _, ambientError = request({ kind = 'ambient', bone = 'door_dside_f',
      netId = 17, model = 900 })
    assert(validationCalls == 0)
    local issued = assert(request({ kind = 'entity', bone = 'boot',
      entityRef = { entityId = 'entity_exact_001', generation = 3 } }))
    return { managed = managedError.code, ambient = ambientError.code,
      calls = validationCalls, accepted = issued.state == 'ISSUED' }
  `);

  assert.deepEqual(result, {
    managed: 'INTERACT_TARGET_INVALID',
    ambient: 'INTERACT_TARGET_INVALID',
    calls: 2,
    accepted: true,
  });
});

test('lease renewal revalidates actor session, dependencies, target, policy, and definition fences', async () => {
  const result = await runInteractLua<{
    renewedUntil: number;
    staleActor: string;
    activeAfterStaleActor: number;
    targetChanged: string;
    cancelledAfterTargetChange: number;
    definitionChanged: string;
    dependenciesChecked: number;
    targetsChecked: number;
    policiesChecked: number;
    activeLeases: number;
  }>(`${interactBundleFactory}
    local clock, serial, targetRevision = 1000, 0, 1
    local dependencyChecks, targetChecks, policyChecks, cancelled = 0, 0, 0, 0
    local registry = SynexInteractRegistry.create({ compiler = SynexInteractCompiler,
      isOwnerCurrent = function(owner, epoch) return owner == 'fixture' and epoch == 1 end })
    assert(registry.register('fixture', 1, __interactBundle()))
    local originalDependencies = registry.validateRuntimeDependencies
    registry.validateRuntimeDependencies = function(resolved)
      dependencyChecks = dependencyChecks + 1
      return originalDependencies(resolved)
    end
    local slots = SynexInteractSlots.create({ now = function() return clock end })
    local locks = SynexInteractActorLocks.create()
    local sessions = SynexInteractSessions.create({ now = function() return clock end })
    local observability = {
      denied = function() end, increment = function() end, trace = function() end,
      event = function() end, audit = function() end, observe = function() end,
    }
    local authority = SynexInteractAuthority.create({ registry = registry, slots = slots,
      sessions = sessions, locks = locks, now = function() return clock end,
      nextId = function(namespace) serial = serial + 1
        return namespace .. '-' .. string.format('%08d', serial) end,
      validateTarget = function(_, _, _, context)
        targetChecks = targetChecks + 1
        return { distance = context.claimDistance or 1.0, revision = targetRevision }
      end,
      checkPolicy = function()
        policyChecks = policyChecks + 1
        return true
      end,
      observability = observability,
    })
    authority.setGraphRuntime({
      start = function() return { executionId = 'execution-renew', state = 'RUNNING' } end,
      cancel = function() cancelled = cancelled + 1; return true end,
    })
    authority.reconcileSlots()
    local session = { source = 10, sourceGeneration = 2, state = 'ACTIVE',
      id = 'identity-0001', characterId = 'character-0001', userId = 'user-0001' }
    local context = { source = 10, sourceGeneration = 2, session = session,
      traceId = 'trace-renew', claimDistance = 1.0 }
    assert(authority.setCurrentSessionResolver(function(source)
      assert(source == 10)
      return session
    end))
    local function issue(revision)
      local request = { intent = { key = 'fixture:inspect', revision = revision },
        target = { kind = 'static', bindingKey = 'fixture:terminal' },
        clientRevision = registry.currentRevision(), slotKey = 'operator' }
      local issued = assert(authority.requestLease(request, context))
      assert(authority.activateLease({ leaseId = issued.leaseId, nonce = issued.nonce }, context))
      return issued
    end

    local first = issue(1)
    clock = 1500
    local renewed = assert(authority.renewLease(first.leaseId, 3000, {
      traceId = context.traceId, claimDistance = context.claimDistance,
    }))
    local staleContext = SynexInteractValidation.copy(context)
    staleContext.sourceGeneration = 3
    local _, staleActor = authority.renewLease(first.leaseId, 1000, staleContext)
    local activeAfterStaleActor = authority.snapshot().activeLeases
    targetRevision = 2
    local _, targetChanged = authority.renewLease(first.leaseId, 1000, context)
    local cancelledAfterTargetChange = cancelled

    targetRevision = 1
    local second = issue(1)
    local replacement = __interactBundle()
    replacement.revision = 2
    assert(registry.replace('fixture', 1, replacement, 1))
    local _, definitionChanged = authority.renewLease(second.leaseId, 1000, context)
    return {
      renewedUntil = renewed.expiresAt,
      staleActor = staleActor.code,
      activeAfterStaleActor = activeAfterStaleActor,
      targetChanged = targetChanged.code,
      cancelledAfterTargetChange = cancelledAfterTargetChange,
      definitionChanged = definitionChanged.code,
      dependenciesChecked = dependencyChecks,
      targetsChecked = targetChecks,
      policiesChecked = policyChecks,
      activeLeases = authority.snapshot().activeLeases,
    }
  `);

  assert.deepEqual(result, {
    renewedUntil: 4500,
    staleActor: 'INTERACT_LEASE_STALE',
    activeAfterStaleActor: 1,
    targetChanged: 'INTERACT_TARGET_STALE',
    cancelledAfterTargetChange: 1,
    definitionChanged: 'INTERACT_INTENT_STALE',
    dependenciesChecked: 11,
    targetsChecked: 11,
    policiesChecked: 5,
    activeLeases: 0,
  });
});

test('lease renewal policy loss follows the declared participant loss policy', async () => {
  const result = await runInteractLua<{
    denied: string;
    participantPolicy: string;
    graphCancelled: number;
    activeLeases: number;
  }>(`${interactBundleFactory}
    local clock, serial, policyAllowed = 1000, 0, true
    local bundle = __interactBundle()
    bundle.intents[1].participants[1].lossPolicy = 'CONTINUE'
    local registry = SynexInteractRegistry.create({ compiler = SynexInteractCompiler,
      isOwnerCurrent = function(owner, epoch) return owner == 'fixture' and epoch == 1 end })
    assert(registry.register('fixture', 1, bundle))
    local slots = SynexInteractSlots.create({ now = function() return clock end })
    local locks = SynexInteractActorLocks.create()
    local sessions = SynexInteractSessions.create({ now = function() return clock end })
    local authority = SynexInteractAuthority.create({ registry = registry, slots = slots,
      sessions = sessions, locks = locks, now = function() return clock end,
      nextId = function(namespace) serial = serial + 1
        return namespace .. '-' .. string.format('%08d', serial) end,
      validateTarget = function() return { distance = 1.0, revision = 1 } end,
      checkPolicy = function()
        if policyAllowed then return true end
        return SynexInteractValidation.failure('INTERACT_LEASE_DENIED',
          'The actor capability was revoked.')
      end,
      observability = { denied = function() end, increment = function() end,
        trace = function() end, event = function() end, audit = function() end,
        observe = function() end },
    })
    local participantPolicy, graphCancelled = nil, 0
    authority.setGraphRuntime({
      start = function() return { executionId = 'execution-policy', state = 'RUNNING' } end,
      cancel = function() graphCancelled = graphCancelled + 1; return true end,
      participantLeft = function(_, _, policy) participantPolicy = policy; return true end,
    })
    authority.reconcileSlots()
    local playerSession = { source = 10, sourceGeneration = 2, state = 'ACTIVE',
      id = 'identity-0001', characterId = 'character-0001', userId = 'user-0001' }
    local context = { source = 10, sourceGeneration = 2, session = playerSession,
      traceId = 'trace-policy' }
    local issued = assert(authority.requestLease({
      intent = { key = 'fixture:inspect', revision = 1 },
      target = { kind = 'static', bindingKey = 'fixture:terminal' },
      clientRevision = registry.currentRevision(), slotKey = 'operator',
    }, context))
    assert(authority.activateLease({ leaseId = issued.leaseId,
      nonce = issued.nonce }, context))
    policyAllowed = false
    local _, denied = authority.renewLease(issued.leaseId, 1000, context)
    return { denied = denied.code, participantPolicy = participantPolicy,
      graphCancelled = graphCancelled,
      activeLeases = authority.snapshot().activeLeases }
  `);

  assert.deepEqual(result, {
    denied: 'INTERACT_LEASE_DENIED',
    participantPolicy: 'CONTINUE',
    graphCancelled: 0,
    activeLeases: 0,
  });
});

test('running graphs renew active leases server-side without a client heartbeat', async () => {
  const result = await runInteractLua<{
    before: number;
    after: number;
    activeLeases: number;
  }>(`${interactBundleFactory}
    local clock, serial = 1000, 0
    local registry = SynexInteractRegistry.create({ compiler = SynexInteractCompiler,
      isOwnerCurrent = function(owner, epoch) return owner == 'fixture' and epoch == 1 end })
    assert(registry.register('fixture', 1, __interactBundle()))
    local slots = SynexInteractSlots.create({ now = function() return clock end })
    local sessions = SynexInteractSessions.create({ now = function() return clock end })
    local authority = SynexInteractAuthority.create({ registry = registry, slots = slots,
      sessions = sessions, locks = SynexInteractActorLocks.create(),
      now = function() return clock end,
      nextId = function(namespace) serial = serial + 1
        return namespace .. '-' .. string.format('%08d', serial) end,
      validateTarget = function() return { distance = 1, revision = 1 } end,
      checkPolicy = function() return true end,
      observability = { denied = function() end, increment = function() end,
        trace = function() end, event = function() end, audit = function() end,
        observe = function() end },
    })
    authority.setGraphRuntime({ start = function(session)
      assert(sessions.setExecution(session.id, 'execution-renewal'))
      return { executionId = 'execution-renewal', state = 'RUNNING' }
    end, cancel = function() return true end })
    authority.reconcileSlots()
    local playerSession = { source = 10, sourceGeneration = 1, state = 'ACTIVE',
      id = 'identity-renewal-0001', characterId = 'character-renewal-0001' }
    local context = { source = 10, sourceGeneration = 1,
      session = playerSession, traceId = 'trace-renewal-0001' }
    assert(authority.setCurrentSessionResolver(function() return playerSession end))
    local issued = assert(authority.requestLease({
      intent = { key = 'fixture:inspect', revision = 1 },
      target = { kind = 'static', bindingKey = 'fixture:terminal' },
      clientRevision = registry.currentRevision(), slotKey = 'operator' }, context))
    assert(authority.activateLease({ leaseId = issued.leaseId,
      nonce = issued.nonce }, context))
    local before = assert(authority.getLease(issued.leaseId)).expiresAt
    clock = before - 500
    authority.expire(clock)
    local after = assert(authority.getLease(issued.leaseId)).expiresAt
    return { before = before, after = after,
      activeLeases = authority.snapshot().activeLeases }
  `);

  assert.deepEqual(result, {
    before: 3500,
    after: 5500,
    activeLeases: 1,
  });
});

test('joined participant leases bind the canonical target revision before renewal', async () => {
  const result = await runInteractLua<{
    targetRevision: number;
    renewed: boolean;
    activeLeases: number;
  }>(`${interactBundleFactory}
    local clock, serial = 1000, 0
    local bundle = __interactBundle()
    bundle.smartObjects[1].slots[2] = { key = 'assistant', capacity = 1,
      interactionRadius = 2.0, facingTolerance = 90, tags = {} }
    bundle.intents[1].participants[2] = { role = 'assistant', required = false,
      slotKey = 'assistant', capacity = 1, lossPolicy = 'CONTINUE' }
    local registry = SynexInteractRegistry.create({ compiler = SynexInteractCompiler,
      isOwnerCurrent = function(owner, epoch) return owner == 'fixture' and epoch == 1 end })
    assert(registry.register('fixture', 1, bundle))
    local slots = SynexInteractSlots.create({ now = function() return clock end })
    local sessions = SynexInteractSessions.create({ now = function() return clock end })
    local authority = SynexInteractAuthority.create({ registry = registry, slots = slots,
      sessions = sessions, locks = SynexInteractActorLocks.create(),
      now = function() return clock end,
      nextId = function(namespace) serial = serial + 1
        return namespace .. '-' .. string.format('%08d', serial) end,
      validateTarget = function() return { distance = 1.0, revision = 7 } end,
      checkPolicy = function() return true end,
      observability = { denied = function() end, increment = function() end,
        trace = function() end, event = function() end, audit = function() end,
        observe = function() end },
    })
    authority.setGraphRuntime({ start = function()
      return { executionId = 'execution-joined', state = 'RUNNING' }
    end, cancel = function() return true end })
    authority.reconcileSlots()
    local operatorSession = { source = 10, sourceGeneration = 1, state = 'ACTIVE',
      id = 'identity-operator', characterId = 'character-operator' }
    local assistantSession = { source = 11, sourceGeneration = 1, state = 'ACTIVE',
      id = 'identity-assistant', characterId = 'character-assistant' }
    local operatorContext = { source = 10, sourceGeneration = 1,
      session = operatorSession, traceId = 'trace-operator' }
    local assistantContext = { source = 11, sourceGeneration = 1,
      session = assistantSession, traceId = 'trace-assistant' }
    local players = { [10] = operatorSession, [11] = assistantSession }
    assert(authority.setCurrentSessionResolver(function(source) return players[source] end))
    local operator = assert(authority.requestLease({
      intent = { key = 'fixture:inspect', revision = 1 },
      target = { kind = 'static', bindingKey = 'fixture:terminal' },
      clientRevision = registry.currentRevision(), slotKey = 'operator',
    }, operatorContext))
    local invitation = assert(authority.inviteSession({ sessionId = operator.sessionId,
      role = 'assistant', source = 11 }, 'fixture', 1))
    local assistant = assert(authority.joinSession({ sessionId = operator.sessionId,
      role = 'assistant', invitationId = invitation.invitationId }, assistantContext))
    assert(authority.activateLease({ leaseId = assistant.leaseId,
      nonce = assistant.nonce }, assistantContext))
    assert(authority.activateLease({ leaseId = operator.leaseId,
      nonce = operator.nonce }, operatorContext))
    local bound = assert(authority.getLease(assistant.leaseId)).targetRevision
    local renewed = assert(authority.renewLease(
      assistant.leaseId, 1000, assistantContext))
    return { targetRevision = bound, renewed = renewed.expiresAt > clock,
      activeLeases = authority.snapshot().activeLeases }
  `);

  assert.deepEqual(result, {
    targetRevision: 7,
    renewed: true,
    activeLeases: 2,
  });
});

test('pending admissions and activating state close yielding lease races', async () => {
  const result = await runInteractLua<{
    pending: string;
    replay: string;
    accepted: boolean;
    activeLeases: number;
  }>(`${interactBundleFactory}
    local clock, serial, shouldYield = 1000, 0, true
    local registry = SynexInteractRegistry.create({ compiler = SynexInteractCompiler,
      isOwnerCurrent = function(owner, epoch) return owner == 'fixture' and epoch == 1 end })
    assert(registry.register('fixture', 1, __interactBundle()))
    local slots = SynexInteractSlots.create({ now = function() return clock end })
    local sessions = SynexInteractSessions.create({ now = function() return clock end })
    local authority = SynexInteractAuthority.create({ registry = registry, slots = slots,
      sessions = sessions, locks = SynexInteractActorLocks.create(),
      now = function() return clock end,
      nextId = function(namespace) serial = serial + 1
        return namespace .. '-' .. string.format('%08d', serial) end,
      validateTarget = function() return { distance = 1, revision = 1 } end,
      checkPolicy = function()
        if shouldYield then coroutine.yield('policy-yield') end
        return true
      end,
      observability = { denied = function() end, increment = function() end,
        trace = function() end, event = function() end, audit = function() end,
        observe = function() end },
    })
    authority.setGraphRuntime({ start = function()
      return { executionId = 'execution-race', state = 'RUNNING' }
    end, cancel = function() return true end })
    authority.reconcileSlots()
    local context = { source = 10, sourceGeneration = 1,
      session = { source = 10, sourceGeneration = 1, state = 'ACTIVE',
        id = 'identity-race-0001', characterId = 'character-race-0001' },
      traceId = 'trace-race-0001' }
    local request = { intent = { key = 'fixture:inspect', revision = 1 },
      target = { kind = 'static', bindingKey = 'fixture:terminal' },
      clientRevision = registry.currentRevision(), slotKey = 'operator' }
    local previousMaximum = SynexInteractLimits.maximumActorLeases
    SynexInteractLimits.maximumActorLeases = 1
    local issued, issueError
    local first = coroutine.create(function()
      issued, issueError = authority.requestLease(request, context)
    end)
    assert(coroutine.resume(first))
    local _, pending = authority.requestLease(request, context)
    shouldYield = false
    assert(coroutine.resume(first))
    assert(issued and not issueError)

    shouldYield = true
    local activation, activationError
    local activating = coroutine.create(function()
      activation, activationError = authority.activateLease({
        leaseId = issued.leaseId, nonce = issued.nonce }, context)
    end)
    assert(coroutine.resume(activating))
    local _, replay = authority.activateLease({
      leaseId = issued.leaseId, nonce = issued.nonce }, context)
    shouldYield = false
    assert(coroutine.resume(activating))
    SynexInteractLimits.maximumActorLeases = previousMaximum
    assert(activation and not activationError)
    return { pending = pending.code, replay = replay.code,
      accepted = activation.accepted,
      activeLeases = authority.snapshot().activeLeases }
  `);

  assert.deepEqual(result, {
    pending: 'INTERACT_ACTOR_BUSY',
    replay: 'INTERACT_LEASE_REPLAYED',
    accepted: true,
    activeLeases: 1,
  });
});

test('participant invitations are actor-bound, role-bound, expiring, and one-time', async () => {
  const result = await runInteractLua<{
    theft: string;
    wrongRole: string;
    wrongGeneration: string;
    replay: string;
    expired: string;
    invitations: number;
  }>(`${interactBundleFactory}
    local clock, serial = 1000, 0
    local bundle = __interactBundle()
    bundle.smartObjects[1].slots[2] = { key = 'assistant', capacity = 1,
      interactionRadius = 2, facingTolerance = 90, tags = {} }
    bundle.smartObjects[1].slots[3] = { key = 'observer', capacity = 1,
      interactionRadius = 2, facingTolerance = 90, tags = {} }
    bundle.intents[1].participants[2] = { role = 'assistant', required = false,
      slotKey = 'assistant', capacity = 1, lossPolicy = 'CONTINUE' }
    bundle.intents[1].participants[3] = { role = 'observer', required = false,
      slotKey = 'observer', capacity = 1, lossPolicy = 'CONTINUE' }
    local registry = SynexInteractRegistry.create({ compiler = SynexInteractCompiler,
      isOwnerCurrent = function(owner, epoch) return owner == 'fixture' and epoch == 1 end })
    assert(registry.register('fixture', 1, bundle))
    local sessions = SynexInteractSessions.create({ now = function() return clock end })
    local authority = SynexInteractAuthority.create({ registry = registry,
      slots = SynexInteractSlots.create({ now = function() return clock end }),
      sessions = sessions, locks = SynexInteractActorLocks.create(),
      now = function() return clock end,
      nextId = function(namespace) serial = serial + 1
        return namespace .. '-' .. string.format('%08d', serial) end,
      validateTarget = function() return { distance = 1, revision = 1 } end,
      checkPolicy = function() return true end,
      observability = { denied = function() end, increment = function() end,
        trace = function() end, event = function() end, audit = function() end,
        observe = function() end },
    })
    authority.reconcileSlots()
    local function player(source, generation, name)
      local session = { source = source, sourceGeneration = generation,
        state = 'ACTIVE', id = 'identity-' .. name,
        characterId = 'character-' .. name }
      return { source = source, sourceGeneration = generation,
        session = session, traceId = 'trace-' .. name }
    end
    local operator = player(10, 1, 'operator')
    local assistant = player(11, 1, 'assistant')
    local attacker = player(12, 1, 'attacker')
    local players = { [10] = operator.session, [11] = assistant.session,
      [12] = attacker.session }
    assert(authority.setCurrentSessionResolver(function(source) return players[source] end))
    local issued = assert(authority.requestLease({
      intent = { key = 'fixture:inspect', revision = 1 },
      target = { kind = 'static', bindingKey = 'fixture:terminal' },
      clientRevision = registry.currentRevision(), slotKey = 'operator' }, operator))
    local invitation = assert(authority.inviteSession({ sessionId = issued.sessionId,
      role = 'assistant', source = 11 }, 'fixture', 1))
    local _, theft = authority.joinSession({ sessionId = issued.sessionId,
      role = 'assistant', invitationId = invitation.invitationId }, attacker)
    local _, wrongRole = authority.joinSession({ sessionId = issued.sessionId,
      role = 'observer', invitationId = invitation.invitationId }, assistant)
    local staleAssistant = player(11, 2, 'assistant-new')
    local _, wrongGeneration = authority.joinSession({ sessionId = issued.sessionId,
      role = 'assistant', invitationId = invitation.invitationId }, staleAssistant)
    assert(authority.joinSession({ sessionId = issued.sessionId,
      role = 'assistant', invitationId = invitation.invitationId }, assistant))
    local _, replay = authority.joinSession({ sessionId = issued.sessionId,
      role = 'assistant', invitationId = invitation.invitationId }, assistant)
    local expiring = assert(authority.inviteSession({ sessionId = issued.sessionId,
      role = 'observer', source = 12, ttlMs = 500 }, 'fixture', 1))
    clock = clock + 501
    local _, expired = authority.joinSession({ sessionId = issued.sessionId,
      role = 'observer', invitationId = expiring.invitationId }, attacker)
    return { theft = theft.code, wrongRole = wrongRole.code,
      wrongGeneration = wrongGeneration.code, replay = replay.code,
      expired = expired.code, invitations = sessions.snapshot().invitations }
  `);

  assert.deepEqual(result, {
    theft: 'INTERACT_PARTICIPANT_DENIED',
    wrongRole: 'INTERACT_PARTICIPANT_DENIED',
    wrongGeneration: 'INTERACT_PARTICIPANT_DENIED',
    replay: 'INTERACT_PARTICIPANT_DENIED',
    expired: 'INTERACT_PARTICIPANT_DENIED',
    invitations: 0,
  });
});

test('target evidence is reacquired after yielding policy checks', async () => {
  const result = await runInteractLua<{
    requestRace: string;
    activationRace: string;
    activeLeases: number;
  }>(`${interactBundleFactory}
    local clock, serial, targetRevision, mutate = 1000, 0, 1, true
    local registry = SynexInteractRegistry.create({ compiler = SynexInteractCompiler,
      isOwnerCurrent = function(owner, epoch) return owner == 'fixture' and epoch == 1 end })
    assert(registry.register('fixture', 1, __interactBundle()))
    local authority = SynexInteractAuthority.create({ registry = registry,
      slots = SynexInteractSlots.create({ now = function() return clock end }),
      sessions = SynexInteractSessions.create({ now = function() return clock end }),
      locks = SynexInteractActorLocks.create(), now = function() return clock end,
      nextId = function(namespace) serial = serial + 1
        return namespace .. '-' .. string.format('%08d', serial) end,
      validateTarget = function()
        return { distance = 1, revision = targetRevision }
      end,
      checkPolicy = function()
        if mutate then targetRevision = targetRevision + 1 end
        return true
      end,
      observability = { denied = function() end, increment = function() end,
        trace = function() end, event = function() end, audit = function() end,
        observe = function() end },
    })
    authority.reconcileSlots()
    local context = { source = 10, sourceGeneration = 1,
      session = { source = 10, sourceGeneration = 1, state = 'ACTIVE',
        id = 'identity-toctou-0001', characterId = 'character-toctou-0001' },
      traceId = 'trace-toctou-0001' }
    local request = { intent = { key = 'fixture:inspect', revision = 1 },
      target = { kind = 'static', bindingKey = 'fixture:terminal' },
      clientRevision = registry.currentRevision(), slotKey = 'operator' }
    local _, requestRace = authority.requestLease(request, context)
    mutate, targetRevision = false, 1
    local issued = assert(authority.requestLease(request, context))
    mutate = true
    local _, activationRace = authority.activateLease({
      leaseId = issued.leaseId, nonce = issued.nonce }, context)
    return { requestRace = requestRace.code,
      activationRace = activationRace.code,
      activeLeases = authority.snapshot().activeLeases }
  `);

  assert.deepEqual(result, {
    requestRace: 'INTERACT_TARGET_STALE',
    activationRace: 'INTERACT_TARGET_STALE',
    activeLeases: 0,
  });
});
