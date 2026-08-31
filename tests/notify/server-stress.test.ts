import assert from 'node:assert/strict';
import { performance } from 'node:perf_hooks';
import test from 'node:test';
import { notifyServerHarness, runNotifyLua } from './helpers.js';

test('1k server lifecycle operations keep records, history, budgets, and transport evidence bounded', async () => {
  const started = performance.now();
  const result = await runNotifyLua<string>(`${notifyServerHarness}
    for _, policy in pairs(SynexNotifyLimits.rateLimits) do
      policy.capacity = 100000
      policy.refillPerSecond = 0
    end
    __notifyTest.addSession(51, 1)
    local registry = __notifyTest.makeRegistry()
    for index = 1, 1000 do
      local handle = assert(registry.send('consumer.lifecycle', 1,
        __notifyTest.target(51), { title = ('Lifecycle %d'):format(index) },
        { operation = 'notify.send' }))
      assert(__notifyTest.lastCommand().command == 'show')
      assert(registry.dismiss('consumer.lifecycle', 1, handle, 'dismissed',
        { operation = 'notify.dismiss' }))
      assert(__notifyTest.lastCommand().command == 'dismiss')
      __notifyTest.deliveries = {}
    end
    local snapshot = registry.snapshot()
    assert(snapshot.active == 0 and snapshot.actionTokens == 0)
    assert(snapshot.ownerCount == 0 and #snapshot.history == 128)
    assert(snapshot.budgetBuckets <= 4)
    assert(__notifyTest.deliveryCount == 2000)
    return table.concat({ snapshot.active, #snapshot.history,
      snapshot.budgetBuckets, __notifyTest.deliveryCount }, ':')
  `);
  const elapsed = performance.now() - started;
  assert.equal(result, '0:128:4:2000');
  assert.ok(elapsed < 15_000, `1k lifecycle run took ${elapsed.toFixed(1)} ms`);
});

test('10k notification storm saturates at the per-owner bound without unbounded growth', async () => {
  const started = performance.now();
  const result = await runNotifyLua<string>(`${notifyServerHarness}
    for _, policy in pairs(SynexNotifyLimits.rateLimits) do
      policy.capacity = 100000
      policy.refillPerSecond = 0
    end
    __notifyTest.addSession(52, 1)
    local registry = __notifyTest.makeRegistry()
    local accepted, rejected = 0, 0
    for index = 1, 10000 do
      local handle, operationError = registry.send('consumer.storm', 1,
        __notifyTest.target(52), { title = ('Storm %d'):format(index) },
        { operation = 'notify.send' })
      if handle then
        accepted = accepted + 1
        assert(__notifyTest.lastCommand().command == 'show')
      else
        assert(operationError.code == 'NOTIFY_QUEUE_FULL')
        rejected = rejected + 1
      end
    end
    local saturated = registry.snapshot()
    assert(accepted == SynexNotifyLimits.maximumOwnerNotifications)
    assert(rejected == 10000 - SynexNotifyLimits.maximumOwnerNotifications)
    assert(saturated.active == SynexNotifyLimits.maximumOwnerNotifications)
    assert(saturated.active <= saturated.maximumRecords)
    assert(#saturated.history <= SynexNotifyLimits.maximumHistory)
    local cleanup = assert(registry.cleanupOwner('consumer.storm', 1))
    assert(__notifyTest.lastCommand().command == 'owner_stop')
    local final = registry.snapshot()
    assert(cleanup.removed == SynexNotifyLimits.maximumOwnerNotifications)
    assert(final.active == 0 and final.actionTokens == 0)
    assert(#final.history == SynexNotifyLimits.maximumHistory)
    return table.concat({ accepted, rejected, saturated.active,
      cleanup.removed, final.active, #final.history }, ':')
  `);
  const elapsed = performance.now() - started;
  assert.equal(result, '256:9744:256:256:0:128');
  assert.ok(elapsed < 20_000, `10k storm run took ${elapsed.toFixed(1)} ms`);
});
