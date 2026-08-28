import assert from 'node:assert/strict';
import test from 'node:test';
import { runInteractLua } from './helpers.ts';

test('leases enforce slot exclusivity and session generation', async () => {
  const result = await runInteractLua<string>(String.raw`
    local clock, sequence = 1000, 0
    local engine = SynexInteractLeaseEngine.create({
      now = function() return clock end,
      nextId = function()
        sequence = sequence + 1
        return 'lease_' .. tostring(sequence)
      end
    })
    local first = assert(engine.acquire({
      source = 11, sessionId = 'session_a', sourceGeneration = 3,
      objectKey = 'synex_test:door', actionKey = 'synex_test:open',
      ownerResource = 'synex_test', slot = 'door', ttlSeconds = 5
    }))
    local _, busyError = engine.acquire({
      source = 12, sessionId = 'session_b', sourceGeneration = 1,
      objectKey = 'synex_test:door', actionKey = 'synex_test:open',
      ownerResource = 'synex_test', slot = 'door', ttlSeconds = 5
    })
    assert(busyError.code == 'INTERACT_SLOT_BUSY')
    local _, staleError = engine.verify(first.id, {
      source = 11, sessionId = 'session_a', sourceGeneration = 4,
      objectKey = 'synex_test:door', actionKey = 'synex_test:open'
    })
    assert(staleError.code == 'INTERACT_LEASE_STALE')
    return busyError.code .. ':' .. staleError.code
  `);
  assert.equal(result, 'INTERACT_SLOT_BUSY:INTERACT_LEASE_STALE');
});

test('leases expire and cap renewals', async () => {
  const result = await runInteractLua<string>(String.raw`
    local clock, sequence = 0, 0
    local engine = SynexInteractLeaseEngine.create({
      now = function() return clock end,
      nextId = function()
        sequence = sequence + 1
        return 'lease_' .. tostring(sequence)
      end
    })
    local lease = assert(engine.acquire({
      source = 21, sessionId = 'session_c', sourceGeneration = 2,
      objectKey = 'synex_test:bench', actionKey = 'synex_test:sit',
      ownerResource = 'synex_test', slot = 'seat.1', ttlSeconds = 1
    }))
    local expected = { source = 21, sessionId = 'session_c', sourceGeneration = 2 }
    for _ = 1, SynexInteractLimits.maximumLeaseRenewals do assert(engine.renew(lease.id, expected, 1)) end
    local _, renewalError = engine.renew(lease.id, expected, 1)
    assert(renewalError.code == 'INTERACT_LEASE_RENEWAL_LIMIT')
    clock = clock + 1001
    local _, expiredError = engine.verify(lease.id, expected)
    assert(expiredError.code == 'INTERACT_LEASE_EXPIRED')
    return renewalError.code .. ':' .. expiredError.code
  `);
  assert.equal(result, 'INTERACT_LEASE_RENEWAL_LIMIT:INTERACT_LEASE_EXPIRED');
});
