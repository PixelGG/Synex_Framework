import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

import { interactBundleFactory, runInteractLua } from './helpers.js';

const viabilityFixture = `${interactBundleFactory}
  function __viabilityFixture()
    local clock, serial = 1000, 0
    local pedBySource, healthByPed, sessionsBySource = {}, {}, {}
    local cancellationMetrics, cancelledSessions = 0, {}
    local registry = SynexInteractRegistry.create({ compiler = SynexInteractCompiler,
      isOwnerCurrent = function(owner, epoch)
        return owner == 'fixture' and epoch == 1
      end })
    assert(registry.register('fixture', 1, __interactBundle()))
    local slots = SynexInteractSlots.create({ now = function() return clock end })
    local sessions = SynexInteractSessions.create({ now = function() return clock end })
    local locks = SynexInteractActorLocks.create()
    local executions = {}

    local function context(source)
      local session = sessionsBySource[source]
      if not session then
        session = { source = source, sourceGeneration = 1, state = 'ACTIVE',
          id = 'identity-' .. string.format('%08d', source),
          characterId = 'character-' .. string.format('%08d', source),
          userId = 'user-' .. string.format('%08d', source) }
        sessionsBySource[source] = session
      end
      local ped = 1000 + source
      pedBySource[source], healthByPed[ped] = ped, healthByPed[ped] or 200
      return { source = source, sourceGeneration = session.sourceGeneration,
        session = session, traceId = 'trace-' .. tostring(source) }
    end

    local authority = SynexInteractAuthority.create({ registry = registry, slots = slots,
      sessions = sessions, locks = locks, now = function() return clock end,
      nextId = function(namespace)
        serial = serial + 1
        return namespace .. '-' .. string.format('%08d', serial)
      end,
      validateTarget = function()
        return { distance = 1, revision = 1,
          position = { x = 10, y = 20, z = 30 } }
      end,
      validateActorViability = function(actor)
        local ped = pedBySource[actor.source] or 0
        local exists = ped > 0 and healthByPed[ped] ~= nil
        local health = exists and healthByPed[ped] or 0
        if not exists or type(health) ~= 'number' or health <= 0 then
          return false, { reason = 'ACTOR_DIED' }
        end
        return true
      end,
      checkPolicy = function() return true end,
      observability = {
        denied = function() end,
        increment = function(name, labels)
          if name == 'cancellation_total' and labels.reason == 'ACTOR_DIED' then
            cancellationMetrics = cancellationMetrics + 1
          end
        end,
        trace = function() end, event = function() end, audit = function() end,
        observe = function() end,
      },
    })
    assert(authority.setCurrentSessionResolver(function(source)
      return sessionsBySource[source]
    end))
    authority.setGraphRuntime({
      start = function(session, resolved, lease, actorContext)
        local executionId = 'execution-' .. string.format('%08d', lease.source)
        assert(sessions.setExecution(session.id, executionId))
        assert(locks.claim(lease.actorKey, { 'actor.hands' }, session.id, executionId))
        executions[session.id] = {
          id = executionId, sessionId = session.id, leaseId = lease.id,
          intentKey = resolved.intent.key, graphKey = resolved.graph.key,
          ownerResource = resolved.bundle.ownerResource,
          ownerEpoch = resolved.bundle.ownerEpoch,
          bundleRevision = resolved.bundle.revision,
          target = lease.target, traceId = actorContext.traceId,
          lockChannels = { 'actor.hands' },
        }
        return { executionId = executionId, state = 'RUNNING' }
      end,
      cancel = function(sessionId, reason)
        cancelledSessions[sessionId] = reason
        return true
      end,
      cancelOwner = function() return 0 end,
    })
    authority.reconcileSlots()

    local function issue(source)
      local actorContext = context(source)
      local issued, issueError = authority.requestLease({
        intent = { key = 'fixture:inspect', revision = 1 },
        target = { kind = 'static', bindingKey = 'fixture:terminal' },
        clientRevision = registry.currentRevision(), slotKey = 'operator',
      }, actorContext)
      return issued, issueError, actorContext
    end

    local function activate(source)
      local issued, issueError, actorContext = issue(source)
      if not issued then return nil, issueError, actorContext end
      local activated, activationError = authority.activateLease({
        leaseId = issued.leaseId, nonce = issued.nonce,
      }, actorContext)
      return { issued = issued, activated = activated,
        execution = executions[issued.sessionId] }, activationError, actorContext
    end

    local function setHealth(source, health)
      local ped = pedBySource[source] or 1000 + source
      pedBySource[source], healthByPed[ped] = ped, health
    end

    local function snapshot()
      return { leases = authority.snapshot().activeLeases,
        sessions = sessions.snapshot().active,
        reservations = slots.snapshot().reservations,
        locks = locks.snapshot().active }
    end

    return { authority = authority, context = context, issue = issue,
      activate = activate, setHealth = setHealth, snapshot = snapshot,
      cancelledSessions = cancelledSessions,
      cancellationMetrics = function() return cancellationMetrics end,
      clock = function(value) if value ~= nil then clock = value end return clock end }
  end
`;

test('server actor viability fences request, activation, renewal, and pre-commit', async () => {
  const result = await runInteractLua<{
    request: string;
    activation: string;
    renewal: string;
    commit: string;
    afterActivation: Record<string, number>;
    afterRenewal: Record<string, number>;
    afterCommit: Record<string, number>;
  }>(`${viabilityFixture}
    local fixture = __viabilityFixture()

    fixture.context(10)
    fixture.setHealth(10, 0)
    local _, requestError = fixture.issue(10)

    fixture.setHealth(11, 200)
    local activationLease, _, activationContext = fixture.issue(11)
    fixture.setHealth(11, 0)
    local _, activationError = fixture.authority.activateLease({
      leaseId = activationLease.leaseId, nonce = activationLease.nonce,
    }, activationContext)
    local afterActivation = fixture.snapshot()

    fixture.setHealth(12, 200)
    local renewalState, renewalSetupError, renewalContext = fixture.activate(12)
    assert(renewalState and not renewalSetupError)
    fixture.setHealth(12, 0)
    local _, renewalError = fixture.authority.renewLease(
      renewalState.issued.leaseId, 1000, renewalContext)
    local afterRenewal = fixture.snapshot()

    fixture.setHealth(13, 200)
    local commitState, commitSetupError = fixture.activate(13)
    assert(commitState and not commitSetupError)
    fixture.setHealth(13, 0)
    local _, commitError = fixture.authority.validateExecutionCommit(
      commitState.execution)
    local afterCommit = fixture.snapshot()

    return { request = requestError.code, activation = activationError.code,
      renewal = renewalError.code, commit = commitError.code,
      afterActivation = afterActivation, afterRenewal = afterRenewal,
      afterCommit = afterCommit }
  `);

  assert.deepEqual(result, {
    request: 'INTERACT_LEASE_DENIED',
    activation: 'INTERACT_LEASE_REVOKED',
    renewal: 'INTERACT_LEASE_REVOKED',
    commit: 'INTERACT_LEASE_REVOKED',
    afterActivation: { leases: 0, sessions: 0, reservations: 0, locks: 0 },
    afterRenewal: { leases: 0, sessions: 0, reservations: 0, locks: 0 },
    afterCommit: { leases: 0, sessions: 0, reservations: 0, locks: 0 },
  });
});

test('bounded server sweep cleans actor death without a client cancellation', async () => {
  const result = await runInteractLua<{
    before: Record<string, number>;
    after: Record<string, number>;
    repeated: Record<string, number>;
    reason: string;
    metrics: number;
    expired: number;
  }>(`${viabilityFixture}
    local fixture = __viabilityFixture()
    fixture.setHealth(20, 200)
    local active, setupError = fixture.activate(20)
    assert(active and not setupError)
    local before = fixture.snapshot()
    fixture.setHealth(20, 0)
    local expired = fixture.authority.expire(fixture.clock())
    local after = fixture.snapshot()
    fixture.authority.expire(fixture.clock())
    local repeated = fixture.snapshot()
    return { before = before, after = after, repeated = repeated,
      reason = fixture.cancelledSessions[active.issued.sessionId],
      metrics = fixture.cancellationMetrics(), expired = expired }
  `);

  assert.deepEqual(result, {
    before: { leases: 1, sessions: 1, reservations: 1, locks: 1 },
    after: { leases: 0, sessions: 0, reservations: 0, locks: 0 },
    repeated: { leases: 0, sessions: 0, reservations: 0, locks: 0 },
    reason: 'ACTOR_DIED',
    metrics: 1,
    expired: 0,
  });
});

test('actor viability sweep is capped by the shared per-tick budget', async () => {
  const authoritySource = await readFile(
    'resources/synex_interact/server/authority.lua', 'utf8');
  const serverSource = await readFile(
    'resources/synex_interact/server/server.lua', 'utf8');
  assert.match(authoritySource,
    /checked < Limits\.maximumActorViabilityChecksPerTick/u);
  assert.doesNotMatch(authoritySource, /while true do[\s\S]*?actorViable/u);
  assert.match(authoritySource,
    /assert\(options\.validateActorViability/u);
  assert.match(serverSource, /GetPlayerPed\(actor\.source\)/u);
  assert.match(serverSource, /GetEntityHealth\(ped\)/u);
});
