import assert from 'node:assert/strict';
import test from 'node:test';

import {
  interactBundleFactory,
  interactServerFiles,
  runInteractLua,
} from './helpers.js';

test('authority object inspection is redacted and lease expiry is counted once', async () => {
  const result = await runInteractLua<{
    activeLeases: number;
    activeActors: number;
    leaseState: string;
    role: string;
    identityLeaked: boolean;
    expired: number;
    expiredMetric: number;
    remainingLeases: number;
  }>(`${interactBundleFactory}
    local clock, serial, metricCounts = 100, 0, {}
    local observability = {
      increment = function(name, _, amount)
        metricCounts[name] = (metricCounts[name] or 0) + (amount or 1)
        return true
      end,
      denied = function() return true end,
      trace = function() return true end,
    }
    local registry = SynexInteractRegistry.create({
      compiler = SynexInteractCompiler,
      isOwnerCurrent = function(owner, epoch)
        return owner == 'fixture' and epoch == 1
      end,
    })
    assert(registry.register('fixture', 1, __interactBundle()))
    local slots = SynexInteractSlots.create({ now = function() return clock end })
    slots.reconcile(registry.slotDefinitions())
    local sessions = SynexInteractSessions.create({ now = function() return clock end })
    local authority = SynexInteractAuthority.create({
      registry = registry,
      slots = slots,
      sessions = sessions,
      locks = SynexInteractActorLocks.create(),
      now = function() return clock end,
      nextId = function(namespace)
        serial = serial + 1
        return namespace .. '-00000' .. tostring(serial)
      end,
      validateTarget = function()
        return { distance = 1.0, revision = 1,
          position = { x = 10, y = 20, z = 30 } }
      end,
      checkPolicy = function() return true end,
      observability = observability,
    })
    local context = { source = 10, sourceGeneration = 2, traceId = 'trace-0001',
      session = { id = 'identity-0001', state = 'ACTIVE', source = 10,
        sourceGeneration = 2, characterId = 'character-0001' } }
    local lease = assert(authority.requestLease({
      intent = { key = 'fixture:inspect', revision = 1 },
      target = { kind = 'static', bindingKey = 'fixture:terminal',
        position = { x = 10, y = 20, z = 30 } },
      clientRevision = registry.currentRevision(),
    }, context))
    local inspected = assert(authority.inspectObject('fixture:terminal'))
    local sessionLease = assert(authority.inspectSessionLeases(lease.sessionId))
    local identityLeaked = inspected.actorKey ~= nil or inspected.source ~= nil
      or inspected.characterId ~= nil or inspected.actors ~= nil
    clock = lease.expiresAt
    local expired = authority.expire(clock)
    local after = assert(authority.inspectObject('fixture:terminal'))
    return {
      activeLeases = inspected.activeLeaseCount,
      activeActors = inspected.activeActorCount,
      leaseState = sessionLease.state,
      role = inspected.roles[1].role,
      identityLeaked = identityLeaked,
      expired = expired,
      expiredMetric = metricCounts.lease_expired_total or 0,
      remainingLeases = after.activeLeaseCount,
    }
  `, interactServerFiles);

  assert.deepEqual(result, {
    activeLeases: 1,
    activeActors: 1,
    leaseState: 'ISSUED',
    role: 'operator',
    identityLeaked: false,
    expired: 1,
    expiredMetric: 1,
    remainingLeases: 0,
  });
});
