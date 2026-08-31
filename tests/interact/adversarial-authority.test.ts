import assert from 'node:assert/strict';
import test from 'node:test';

import { interactBundleFactory, runInteractLua } from './helpers.js';

const authorityFixture = `${interactBundleFactory}
  function __authorityFixture(bundle)
    local clock, serial, validationCalls = 1000, 0, 0
    local registry = SynexInteractRegistry.create({ compiler = SynexInteractCompiler,
      isOwnerCurrent = function(owner, epoch)
        return owner == 'fixture' and epoch == 1
      end })
    assert(registry.register('fixture', 1, bundle or __interactBundle()))
    local slots = SynexInteractSlots.create({ now = function() return clock end })
    local sessions = SynexInteractSessions.create({ now = function() return clock end })
    local authority = SynexInteractAuthority.create({ registry = registry, slots = slots,
      sessions = sessions, locks = SynexInteractActorLocks.create(),
      now = function() return clock end,
      nextId = function(namespace)
        serial = serial + 1
        return namespace .. '-' .. string.format('%08d', serial)
      end,
      validateTarget = function(_, _, _, context)
        validationCalls = validationCalls + 1
        return { distance = context.serverDistance or 1.0, revision = 1,
          position = { x = 10, y = 20, z = 30 } }
      end,
      observability = { denied = function() end, increment = function() end,
        trace = function() end, event = function() end, audit = function() end,
        observe = function() end },
    })
    authority.setGraphRuntime({
      start = function() return { executionId = 'execution-0001', state = 'RUNNING' } end,
      cancel = function() return true end,
      cancelOwner = function() return 0 end,
    })
    authority.reconcileSlots()
    local function context(source, distance)
      local generation = source + 1
      local session = { source = source, sourceGeneration = generation, state = 'ACTIVE',
        id = 'identity-' .. string.format('%08d', source),
        characterId = 'character-' .. string.format('%08d', source),
        userId = 'user-' .. string.format('%08d', source) }
      return { source = source, sourceGeneration = generation, session = session,
        traceId = 'trace-' .. tostring(source), serverDistance = distance }
    end
    local function request(target, actorContext, intent, slotKey)
      return authority.requestLease({
        intent = intent or { key = 'fixture:inspect', revision = 1 },
        target = target,
        clientRevision = registry.currentRevision(),
        slotKey = slotKey,
      }, actorContext)
    end
    return { authority = authority, registry = registry, slots = slots,
      sessions = sessions, context = context, request = request,
      clock = function(value) if value ~= nil then clock = value end return clock end,
      validationCalls = function() return validationCalls end }
  end
`;

test('hostile target, coordinate, intent, and slot claims fail closed without leaked state', async () => {
  const result = await runInteractLua<{
    wrongTarget: string;
    extraTarget: string;
    coordinates: string;
    missingIntent: string;
    staleIntent: string;
    foreignSlot: string;
    mismatchedSlot: string;
    validations: number;
    leases: number;
    sessions: number;
    reservations: number;
  }>(`${authorityFixture}
    local bundle = __interactBundle()
    bundle.smartObjects[1].slots[2] = { key = 'observer', capacity = 1,
      interactionRadius = 2.0, facingTolerance = 90,
      tags = { 'fixture.slot.observer' } }
    local fixture = __authorityFixture(bundle)
    local _, wrongTarget = fixture.request({ kind = 'static',
      bindingKey = 'fixture:forged', position = { x = 10, y = 20, z = 30 } },
      fixture.context(10, 1))
    local _, extraTarget = fixture.request({ kind = 'static',
      bindingKey = 'fixture:terminal', position = { x = 10, y = 20, z = 30 },
      authority = true }, fixture.context(11, 1))
    local _, coordinates = fixture.request({ kind = 'static',
      bindingKey = 'fixture:terminal', position = { x = 10, y = 20, z = 30 } },
      fixture.context(12, 9))
    local _, missingIntent = fixture.request({ kind = 'static',
      bindingKey = 'fixture:terminal' }, fixture.context(13, 1),
      { key = 'fixture:missing', revision = 1 })
    local _, staleIntent = fixture.request({ kind = 'static',
      bindingKey = 'fixture:terminal' }, fixture.context(14, 1),
      { key = 'fixture:inspect', revision = 2 })
    local _, foreignSlot = fixture.request({ kind = 'static',
      bindingKey = 'fixture:terminal' }, fixture.context(15, 1), nil, 'foreign')
    local _, mismatchedSlot = fixture.request({ kind = 'static',
      bindingKey = 'fixture:terminal' }, fixture.context(16, 1), nil, 'observer')
    return { wrongTarget = wrongTarget.code, extraTarget = extraTarget.code,
      coordinates = coordinates.code, missingIntent = missingIntent.code,
      staleIntent = staleIntent.code, foreignSlot = foreignSlot.code,
      mismatchedSlot = mismatchedSlot.code,
      validations = fixture.validationCalls(),
      leases = fixture.authority.snapshot().activeLeases,
      sessions = fixture.sessions.snapshot().active,
      reservations = fixture.slots.snapshot().reservations }
  `);

  assert.deepEqual(result, {
    wrongTarget: 'INTERACT_TARGET_INVALID',
    extraTarget: 'INTERACT_TARGET_INVALID',
    coordinates: 'INTERACT_LEASE_DENIED',
    missingIntent: 'INTERACT_INTENT_NOT_FOUND',
    staleIntent: 'INTERACT_INTENT_STALE',
    foreignSlot: 'INTERACT_SLOT_NOT_FOUND',
    mismatchedSlot: 'INTERACT_LEASE_DENIED',
    validations: 1,
    leases: 0,
    sessions: 0,
    reservations: 0,
  });
});

test('foreign, modified, expired, stale, and replayed leases cannot activate', async () => {
  const result = await runInteractLua<{
    modifiedId: string;
    foreignActor: string;
    modifiedNonce: string;
    expired: string;
    accepted: boolean;
    replayed: string;
    staleDefinition: string;
    finalLeases: number;
    finalSessions: number;
    finalReservations: number;
  }>(`${authorityFixture}
    local fixture = __authorityFixture()
    local owner = fixture.context(10, 1)
    local target = { kind = 'static', bindingKey = 'fixture:terminal' }
    local first = assert(fixture.request(target, owner))
    local _, modifiedId = fixture.authority.activateLease({
      leaseId = 'interact_lease-forged', nonce = first.nonce }, owner)
    local _, foreignActor = fixture.authority.activateLease({
      leaseId = first.leaseId, nonce = first.nonce }, fixture.context(11, 1))
    local _, modifiedNonce = fixture.authority.activateLease({
      leaseId = first.leaseId, nonce = 'interact_nonce-forged' }, owner)
    fixture.clock(first.expiresAt + 1)
    local _, expired = fixture.authority.activateLease({
      leaseId = first.leaseId, nonce = first.nonce }, owner)

    local second = assert(fixture.request(target, owner))
    local accepted = assert(fixture.authority.activateLease({
      leaseId = second.leaseId, nonce = second.nonce }, owner))
    local _, replayed = fixture.authority.activateLease({
      leaseId = second.leaseId, nonce = second.nonce }, owner)
    fixture.authority.cleanupSource(10, 'BETWEEN_CASES')

    local staleOwner = fixture.context(12, 1)
    local third = assert(fixture.request(target, staleOwner))
    local replacement = __interactBundle()
    replacement.revision = 2
    assert(fixture.registry.replace('fixture', 1, replacement, 1))
    local _, staleDefinition = fixture.authority.activateLease({
      leaseId = third.leaseId, nonce = third.nonce }, staleOwner)
    fixture.authority.cleanupSource(12, 'TEST_COMPLETE')
    return { modifiedId = modifiedId.code, foreignActor = foreignActor.code,
      modifiedNonce = modifiedNonce.code, expired = expired.code,
      accepted = accepted.accepted, replayed = replayed.code,
      staleDefinition = staleDefinition.code,
      finalLeases = fixture.authority.snapshot().activeLeases,
      finalSessions = fixture.sessions.snapshot().active,
      finalReservations = fixture.slots.snapshot().reservations }
  `);

  assert.deepEqual(result, {
    modifiedId: 'INTERACT_LEASE_STALE',
    foreignActor: 'INTERACT_LEASE_STALE',
    modifiedNonce: 'INTERACT_LEASE_REPLAYED',
    expired: 'INTERACT_LEASE_EXPIRED',
    accepted: true,
    replayed: 'INTERACT_LEASE_REPLAYED',
    staleDefinition: 'INTERACT_INTENT_STALE',
    finalLeases: 0,
    finalSessions: 0,
    finalReservations: 0,
  });
});

test('commit authority revalidates active session, locks, slots, policy, and target revision', async () => {
  const result = await runInteractLua<{
    accepted: boolean;
    stale: string;
  }>(`${interactBundleFactory}
    local clock, serial, targetRevision = 1000, 0, 1
    local registry = SynexInteractRegistry.create({ compiler = SynexInteractCompiler,
      isOwnerCurrent = function(owner, epoch) return owner == 'fixture' and epoch == 1 end })
    assert(registry.register('fixture', 1, __interactBundle()))
    local slots = SynexInteractSlots.create({ now = function() return clock end })
    local sessions = SynexInteractSessions.create({ now = function() return clock end })
    local locks = SynexInteractActorLocks.create()
    local authority = SynexInteractAuthority.create({ registry = registry, slots = slots,
      sessions = sessions, locks = locks, now = function() return clock end,
      nextId = function(namespace) serial = serial + 1
        return namespace .. '-' .. string.format('%08d', serial) end,
      validateTarget = function()
        return { distance = 1, revision = targetRevision }
      end,
      checkPolicy = function() return true end,
      observability = { denied = function() end, increment = function() end,
        trace = function() end, event = function() end, audit = function() end,
        observe = function() end },
    })
    local execution
    authority.setGraphRuntime({ start = function(session, resolved, lease, context)
      assert(sessions.setExecution(session.id, 'execution-commit'))
      assert(locks.claim(lease.actorKey, { 'actor.hands' },
        session.id, 'execution-commit'))
      execution = { id = 'execution-commit', sessionId = session.id,
        leaseId = lease.id, intentKey = resolved.intent.key,
        graphKey = resolved.graph.key, ownerResource = resolved.bundle.ownerResource,
        ownerEpoch = resolved.bundle.ownerEpoch,
        bundleRevision = resolved.bundle.revision,
        target = lease.target, traceId = context.traceId,
        lockChannels = { 'actor.hands' } }
      return { executionId = execution.id, state = 'RUNNING' }
    end, cancel = function() return true end })
    authority.reconcileSlots()
    local playerSession = { source = 10, sourceGeneration = 1, state = 'ACTIVE',
      id = 'identity-commit-0001', characterId = 'character-commit-0001' }
    local context = { source = 10, sourceGeneration = 1,
      session = playerSession, traceId = 'trace-commit-0001' }
    assert(authority.setCurrentSessionResolver(function() return playerSession end))
    local issued = assert(authority.requestLease({
      intent = { key = 'fixture:inspect', revision = 1 },
      target = { kind = 'static', bindingKey = 'fixture:terminal' },
      clientRevision = registry.currentRevision(), slotKey = 'operator' }, context))
    assert(authority.activateLease({ leaseId = issued.leaseId,
      nonce = issued.nonce }, context))
    local accepted = authority.validateExecutionCommit(execution)
    targetRevision = 2
    local _, stale = authority.validateExecutionCommit(execution)
    return { accepted = accepted == true, stale = stale.code }
  `);

  assert.deepEqual(result, {
    accepted: true,
    stale: 'INTERACT_TARGET_STALE',
  });
});
