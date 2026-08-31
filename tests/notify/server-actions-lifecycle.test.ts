import assert from 'node:assert/strict';
import test from 'node:test';
import { notifyServerHarness, runNotifyLua } from './helpers.js';

test('server actions are target-bound, revision-bound, expiring, and single-use', async () => {
  const result = await runNotifyLua<string>(`${notifyServerHarness}
    for _, policy in pairs(SynexNotifyLimits.rateLimits) do
      policy.capacity = 256
      policy.refillPerSecond = 0
    end
    __notifyTest.addSession(3, 8)
    __notifyTest.addSession(4, 2)
    local registry = __notifyTest.makeRegistry()

    local function actionable(title)
      local handle = assert(registry.send('consumer.actions', 5, __notifyTest.target(3), {
        title = title,
        actions = {{ id = 'accept', label = 'Accept', ttlMs = 1000 }},
      }, { operation = 'notify.send' }))
      local token = assert(__notifyTest.lastCommand().payload.actions[1].token)
      return handle, token
    end

    local callbackCalls, callbackAction = 0, nil
    local first, firstToken = actionable('Invoke once')
    assert(registry.onAction(first.notificationId, 'consumer.actions', 5,
      'accept', function(value)
        callbackCalls = callbackCalls + 1
        callbackAction = value.actionId
      end))
    local accepted = assert(registry.invokeAction({
      token = firstToken, notificationId = first.notificationId, revision = first.revision,
    }, { source = 3, session = __notifyTest.sessions[3], traceId = 'trace-action' }))
    assert(accepted.accepted and accepted.actionId == 'accept')
    assert(callbackCalls == 1 and callbackAction == 'accept')
    local firstUpdated = assert(registry.update('consumer.actions', 5, first, {
      message = 'Consumed action remains absent',
    }, { operation = 'notify.update' }))
    assert(firstUpdated.revision == 2)
    assert(#__notifyTest.lastCommand().payload.actions == 0)
    local _, replayError = registry.invokeAction({
      token = firstToken, notificationId = first.notificationId, revision = first.revision,
    }, { source = 3, session = __notifyTest.sessions[3] })
    assert(replayError.code == 'NOTIFY_ACTION_REPLAYED')

    local targetBound, targetToken = actionable('Session bound')
    local _, targetError = registry.invokeAction({
      token = targetToken, notificationId = targetBound.notificationId,
      revision = targetBound.revision,
    }, { source = 4, session = __notifyTest.sessions[4] })
    assert(targetError.code == 'NOTIFY_TARGET_STALE')

    local revisionBound, revisionToken = actionable('Revision bound')
    local revised = assert(registry.update('consumer.actions', 5, revisionBound, {
      message = 'Revision advanced',
    }, { operation = 'notify.update' }))
    local _, revisionError = registry.invokeAction({
      token = revisionToken, notificationId = revised.notificationId,
      revision = revisionBound.revision,
    }, { source = 3, session = __notifyTest.sessions[3] })
    assert(revisionError.code == 'NOTIFY_NOTIFICATION_STALE')

    local expiring, expiringToken = actionable('Expires')
    __notifyTest.now = __notifyTest.now + 1001
    local _, expiryError = registry.invokeAction({
      token = expiringToken, notificationId = expiring.notificationId,
      revision = expiring.revision,
    }, { source = 3, session = __notifyTest.sessions[3] })
    assert(expiryError.code == 'NOTIFY_ACTION_EXPIRED')
    local metrics = registry.snapshot().metrics
    assert(metrics.actions == 1 and metrics.actionReplayed == 1
      and metrics.actionExpired == 1)
    return table.concat({ replayError.code, targetError.code,
      revisionError.code, expiryError.code, callbackCalls }, ':')
  `);
  assert.equal(
    result,
    'NOTIFY_ACTION_REPLAYED:NOTIFY_TARGET_STALE:NOTIFY_NOTIFICATION_STALE:'
      + 'NOTIFY_ACTION_EXPIRED:1',
  );
});

test('expired record actions cannot undercount the hard global action capacity', async () => {
  const result = await runNotifyLua<string>(`${notifyServerHarness}
    for _, policy in pairs(SynexNotifyLimits.rateLimits) do
      policy.capacity = 256
      policy.refillPerSecond = 0
    end
    SynexNotifyLimits.maximumActionTokens = 4
    __notifyTest.addSession(5, 1)
    local registry = __notifyTest.makeRegistry()
    local victim = assert(registry.send('consumer.victim', 1, __notifyTest.target(5), {
      kind = 'persistent', title = 'Expiring actions', actions = {
        { id = 'first', label = 'First', ttlMs = 1000 },
        { id = 'second', label = 'Second', ttlMs = 1000 },
      },
    }, { operation = 'notify.send' }))
    __notifyTest.now = __notifyTest.now + 1000
    assert(registry.expire().actions == 2)
    assert(registry.snapshot().actionTokens == 0)

    for index = 1, 2 do
      assert(registry.send('consumer.fill', 1, __notifyTest.target(5), {
        kind = 'persistent', title = ('Fill %d'):format(index), actions = {
          { id = 'first', label = 'First' },
          { id = 'second', label = 'Second' },
        },
      }, { operation = 'notify.send' }))
    end
    assert(registry.snapshot().actionTokens == 4)
    local updated, capacityError = registry.update('consumer.victim', 1, victim, {
      actions = {
        { id = 'replacement-a', label = 'Replacement A' },
        { id = 'replacement-b', label = 'Replacement B' },
      },
    }, { operation = 'notify.update' })
    assert(updated == nil and capacityError.code == 'NOTIFY_RATE_LIMITED')
    assert(registry.snapshot().actionTokens == 4)
    return capacityError.code .. ':' .. registry.snapshot().actionTokens
  `);
  assert.equal(result, 'NOTIFY_RATE_LIMITED:4');
});

test('action deadlines are clipped to presentation lifetime and revived surfaces receive fresh tokens', async () => {
  const result = await runNotifyLua<string>(`${notifyServerHarness}
    for _, policy in pairs(SynexNotifyLimits.rateLimits) do
      policy.capacity = 256
      policy.refillPerSecond = 0
    end
    __notifyTest.addSession(14, 1)
    local registry = __notifyTest.makeRegistry()
    local handle = assert(registry.send('consumer.action-window', 1,
      __notifyTest.target(14), {
        title = 'Bounded action window', durationMs = 1500, maxLifetimeMs = 10000,
        actions = {
          { id = 'before', label = 'Before', ttlMs = 30000 },
          { id = 'boundary', label = 'Boundary', ttlMs = 30000 },
        },
      }, { operation = 'notify.send' }))
    local firstPayload = __notifyTest.lastCommand().payload
    assert(firstPayload.actions[1].ttlMs == 1500 and firstPayload.actions[2].ttlMs == 1500)
    local beforeToken, boundaryToken = firstPayload.actions[1].token,
      firstPayload.actions[2].token
    __notifyTest.now = 2499
    assert(registry.invokeAction({ token = beforeToken,
      notificationId = handle.notificationId, revision = handle.revision },
      { source = 14, session = __notifyTest.sessions[14] }))
    __notifyTest.now = 2500
    local _, boundaryError = registry.invokeAction({ token = boundaryToken,
      notificationId = handle.notificationId, revision = handle.revision },
      { source = 14, session = __notifyTest.sessions[14] })
    assert(boundaryError.code == 'NOTIFY_ACTION_EXPIRED')

    local revived = assert(registry.update('consumer.action-window', 1, handle, {
      message = 'Revived with a fresh action',
      actions = {{ id = 'again', label = 'Again', ttlMs = 30000 }},
    }, { operation = 'notify.update' }))
    local revivedPayload = __notifyTest.lastCommand().payload
    assert(revived.revision == 2 and revivedPayload.actions[1].ttlMs == 1500)
    local revivedToken = revivedPayload.actions[1].token
    __notifyTest.now = 3999
    assert(registry.invokeAction({ token = revivedToken,
      notificationId = revived.notificationId, revision = revived.revision },
      { source = 14, session = __notifyTest.sessions[14] }))
    return table.concat({ boundaryError.code, revived.revision,
      revivedPayload.actions[1].ttlMs }, ':')
  `);
  assert.equal(result, 'NOTIFY_ACTION_EXPIRED:2:1500');
});

test('action-capacity rejection does not debit the shared send budget', async () => {
  const result = await runNotifyLua<string>(`${notifyServerHarness}
    SynexNotifyLimits.maximumActionTokens = 1
    for _, policy in pairs(SynexNotifyLimits.rateLimits) do
      policy.capacity = 100
      policy.refillPerSecond = 0
    end
    SynexNotifyLimits.rateLimits.global = { capacity = 2, refillPerSecond = 0 }
    __notifyTest.addSession(16, 1)
    local registry = __notifyTest.makeRegistry()
    assert(registry.send('consumer.capacity', 1, __notifyTest.target(16), {
      kind = 'toast', title = 'Consumes one token',
      actions = {{ id = 'hold', label = 'Hold' }},
    }, { operation = 'notify.send' }))
    local rejected, capacityError = registry.send('consumer.capacity', 1,
      __notifyTest.target(16), {
        title = 'Rejected before budget debit',
        actions = {{ id = 'blocked', label = 'Blocked' }},
      }, { operation = 'notify.send' })
    assert(rejected == nil and capacityError.code == 'NOTIFY_RATE_LIMITED')
    local accepted = assert(registry.send('consumer.capacity', 1,
      __notifyTest.target(16), { title = 'Remaining shared token' },
      { operation = 'notify.send' }))
    assert(accepted.revision == 1 and registry.snapshot().active == 2)
    return capacityError.code .. ':' .. registry.snapshot().active
  `);
  assert.equal(result, 'NOTIFY_RATE_LIMITED:2');
});

test('identifier and transport failures preserve budgets and planned pressure victims', async () => {
  const result = await runNotifyLua<string>(`${notifyServerHarness}
    SynexNotifyLimits.maximumServerNotifications = 1
    SynexNotifyLimits.maximumOwnerNotifications = 1
    for _, policy in pairs(SynexNotifyLimits.rateLimits) do
      policy.capacity = 100
      policy.refillPerSecond = 0
    end
    SynexNotifyLimits.rateLimits.global = { capacity = 2, refillPerSecond = 0 }
    __notifyTest.addSession(18, 1)

    local recordIdRegistry = __notifyTest.makeRegistry()
    assert(recordIdRegistry.send('consumer.record-id', 1,
      __notifyTest.target(18), { title = 'Retained record', durationMs = 1500 },
      { operation = 'notify.send' }))
    __notifyTest.now = 2500
    local failRecordId = true
    __notifyTest.nextId = function(namespace)
      if namespace == 'notify' and failRecordId then
        failRecordId = false
        return nil, { code = 'NOTIFY_UNAVAILABLE', retryable = true }
      end
      __notifyTest.serial = __notifyTest.serial + 1
      return ('%s-%08d'):format(namespace, __notifyTest.serial)
    end
    local beforeRecordFailure = __notifyTest.deliveryCount
    local missingId, missingIdError = recordIdRegistry.send('consumer.record-id', 1,
      __notifyTest.target(18), { title = 'Missing record ID' },
      { operation = 'notify.send' })
    assert(missingId == nil and missingIdError.code == 'NOTIFY_UNAVAILABLE')
    assert(recordIdRegistry.snapshot().active == 1)
    assert(__notifyTest.deliveryCount == beforeRecordFailure)
    __notifyTest.nextId = nil
    assert(recordIdRegistry.send('consumer.record-id', 1,
      __notifyTest.target(18), { title = 'Budget remained available' },
      { operation = 'notify.send' }))
    assert(recordIdRegistry.snapshot().active == 1)

    __notifyTest.now = 1000
    local actionIdRegistry = __notifyTest.makeRegistry()
    assert(actionIdRegistry.send('consumer.action-id', 1,
      __notifyTest.target(18), { title = 'Retained action predecessor', durationMs = 1500 },
      { operation = 'notify.send' }))
    __notifyTest.now = 2500
    local actionIds = 0
    __notifyTest.nextId = function(namespace)
      if namespace == 'notify_action' then
        actionIds = actionIds + 1
        if actionIds == 2 then
          return nil, { code = 'NOTIFY_UNAVAILABLE', retryable = true }
        end
      end
      __notifyTest.serial = __notifyTest.serial + 1
      return ('%s-%08d'):format(namespace, __notifyTest.serial)
    end
    local beforeActionFailure = __notifyTest.deliveryCount
    local missingAction, missingActionError = actionIdRegistry.send(
      'consumer.action-id', 1, __notifyTest.target(18), {
        title = 'Missing second action ID',
        actions = {
          { id = 'first', label = 'First' },
          { id = 'second', label = 'Second' },
        },
      }, { operation = 'notify.send' })
    assert(missingAction == nil and missingActionError.code == 'NOTIFY_UNAVAILABLE')
    assert(actionIdRegistry.snapshot().active == 1)
    assert(__notifyTest.deliveryCount == beforeActionFailure)
    __notifyTest.nextId = nil
    assert(actionIdRegistry.send('consumer.action-id', 1,
      __notifyTest.target(18), { title = 'Action failure spent no budget' },
      { operation = 'notify.send' }))
    assert(actionIdRegistry.snapshot().active == 1)

    __notifyTest.now = 1000
    local transportRegistry = __notifyTest.makeRegistry()
    assert(transportRegistry.send('consumer.transport', 1,
      __notifyTest.target(18), { title = 'Retained transport predecessor', durationMs = 1500 },
      { operation = 'notify.send' }))
    __notifyTest.now = 2500
    __notifyTest.transportFailure = true
    local failedTransport, transportError = transportRegistry.send(
      'consumer.transport', 1, __notifyTest.target(18), {
        title = 'Transport failure keeps predecessor',
      }, { operation = 'notify.send' })
    assert(failedTransport == nil and transportError.code == 'NOTIFY_UNAVAILABLE')
    assert(transportRegistry.snapshot().active == 1)
    __notifyTest.transportFailure = false
    assert(transportRegistry.send('consumer.transport', 1,
      __notifyTest.target(18), { title = 'Transport failure spent no budget' },
      { operation = 'notify.send' }))
    assert(transportRegistry.snapshot().active == 1)
    return table.concat({ missingIdError.code, missingActionError.code,
      transportError.code }, ':')
  `);
  assert.equal(result, 'NOTIFY_UNAVAILABLE:NOTIFY_UNAVAILABLE:NOTIFY_UNAVAILABLE');
});

test('inactive retained records are evicted oldest-first under server registry pressure', async () => {
  const result = await runNotifyLua<string>(`${notifyServerHarness}
    SynexNotifyLimits.maximumServerNotifications = 2
    SynexNotifyLimits.maximumOwnerNotifications = 2
    for _, policy in pairs(SynexNotifyLimits.rateLimits) do
      policy.capacity = 100
      policy.refillPerSecond = 0
    end
    __notifyTest.addSession(17, 1)
    local registry = __notifyTest.makeRegistry()
    local oldest = assert(registry.send('consumer.retention', 1,
      __notifyTest.target(17), { title = 'Oldest', durationMs = 1500 },
      { operation = 'notify.send' }))
    assert(registry.send('consumer.retention', 1, __notifyTest.target(17), {
      title = 'Second', durationMs = 1500,
    }, { operation = 'notify.send' }))
    __notifyTest.now = 2500
    local newest = assert(registry.send('consumer.retention', 1,
      __notifyTest.target(17), { title = 'Newest', durationMs = 1500 },
      { operation = 'notify.send' }))
    local snapshot = registry.snapshot()
    assert(snapshot.active == 2 and snapshot.presenting == 1 and snapshot.retained == 1)
    local _, evictedError = registry.update('consumer.retention', 1, oldest, {
      message = 'Oldest handle was pressure-evicted',
    }, { operation = 'notify.update' })
    assert(evictedError.code == 'NOTIFY_NOTIFICATION_NOT_FOUND')
    assert(newest.revision == 1)
    return table.concat({ snapshot.active, snapshot.presenting,
      snapshot.retained, evictedError.code }, ':')
  `);
  assert.equal(result, '2:1:1:NOTIFY_NOTIFICATION_NOT_FOUND');
});

test('explicit progress duration becomes dormant and a later authoritative update revives it', async () => {
  const result = await runNotifyLua<string>(`${notifyServerHarness}
    for _, policy in pairs(SynexNotifyLimits.rateLimits) do
      policy.capacity = 256
      policy.refillPerSecond = 0
    end
    __notifyTest.addSession(15, 1)
    local registry = __notifyTest.makeRegistry()
    local handle = assert(registry.send('consumer.progress-duration', 1,
      __notifyTest.target(15), {
        kind = 'progress', title = 'Bounded progress', durationMs = 1500,
        progress = { state = 'RUNNING', mode = 'indeterminate' },
      }, { operation = 'notify.send' }))
    local deliveries = __notifyTest.deliveryCount
    __notifyTest.now = __notifyTest.now + 1500
    local expired = registry.expire()
    local dormant = registry.snapshot()
    assert(expired.presentations == 1 and expired.notifications == 0)
    assert(dormant.active == 1 and dormant.presenting == 0 and dormant.retained == 1)
    local updated = assert(registry.update('consumer.progress-duration', 1,
      handle, { message = 'Authoritative revival' }, { operation = 'notify.update' }))
    assert(updated.revision == 2 and __notifyTest.deliveryCount == deliveries + 1)
    local revived = registry.snapshot()
    assert(revived.active == 1 and revived.presenting == 1 and revived.retained == 0)
    return table.concat({ expired.presentations, updated.revision,
      revived.presenting, revived.retained }, ':')
  `);
  assert.equal(result, '1:2:1:0');
});

test('owner stop, player drop, and expiry remove records and action tokens deterministically', async () => {
  const result = await runNotifyLua<string>(`${notifyServerHarness}
    for _, policy in pairs(SynexNotifyLimits.rateLimits) do
      policy.capacity = 256
      policy.refillPerSecond = 0
    end
    __notifyTest.addSession(12, 1)
    __notifyTest.addSession(13, 1)
    local registry = __notifyTest.makeRegistry()

    local ownerHandle = assert(registry.send('consumer.cleanup', 2,
      __notifyTest.target(12), {
        title = 'Owner cleanup', actions = {{ id = 'open', label = 'Open' }},
      }, { operation = 'notify.send' }))
    local ownerToken = __notifyTest.lastCommand().payload.actions[1].token
    local cleanup = assert(registry.cleanupOwner('consumer.cleanup', 2))
    assert(cleanup.removed == 1)
    local _, cleanedActionError = registry.invokeAction({
      token = ownerToken, notificationId = ownerHandle.notificationId,
      revision = ownerHandle.revision,
    }, { source = 12, session = __notifyTest.sessions[12] })
    assert(cleanedActionError.code == 'NOTIFY_ACTION_NOT_FOUND')
    assert(__notifyTest.lastCommand().command == 'owner_stop')

    local dropped = assert(registry.send('consumer.drop', 1, __notifyTest.target(13), {
      title = 'Player drop', actions = {{ id = 'open', label = 'Open' }},
    }, { operation = 'notify.send' }))
    local droppedToken = __notifyTest.lastCommand().payload.actions[1].token
    assert(registry.playerDropped(13) == 1)
    local _, droppedActionError = registry.invokeAction({
      token = droppedToken, notificationId = dropped.notificationId,
      revision = dropped.revision,
    }, { source = 13, session = __notifyTest.sessions[13] })
    assert(droppedActionError.code == 'NOTIFY_ACTION_NOT_FOUND')

    local expiring = assert(registry.send('consumer.expiry', 1, __notifyTest.target(12), {
      title = 'Hard lifetime', maxLifetimeMs = 3000,
    }, { operation = 'notify.send' }))
    assert(expiring.revision == 1)
    __notifyTest.now = __notifyTest.now + 3001
    local expired = registry.expire()
    assert(expired.notifications == 1 and registry.snapshot().active == 0)
    local dismissal = __notifyTest.lastCommand()
    assert(dismissal.command == 'dismiss' and dismissal.revision == 2)
    assert(dismissal.payload.reason == 'expired')
    local history = registry.snapshot().history
    assert(#history <= SynexNotifyLimits.maximumHistory)
    assert(history[#history].state == 'EXPIRED')
    assert(history[#history].reason == 'max_lifetime')
    return table.concat({ cleanup.removed, cleanedActionError.code,
      droppedActionError.code, expired.notifications }, ':')
  `);
  assert.equal(
    result,
    '1:NOTIFY_ACTION_NOT_FOUND:NOTIFY_ACTION_NOT_FOUND:1',
  );
});

test('transport failure is fail-closed and leaves no server registry residue', async () => {
  const result = await runNotifyLua<string>(`${notifyServerHarness}
    __notifyTest.addSession(6, 1)
    __notifyTest.transportFailure = true
    local registry = __notifyTest.makeRegistry()
    local _, deliveryError = registry.send('consumer.transport', 1,
      __notifyTest.target(6), {
        title = 'Must roll back', actions = {{ id = 'retry', label = 'Retry' }},
      }, { operation = 'notify.send' })
    local snapshot = registry.snapshot()
    assert(deliveryError.code == 'NOTIFY_UNAVAILABLE')
    assert(snapshot.active == 0 and snapshot.actionTokens == 0)
    assert(snapshot.metrics.transportFailures == 1)
    return deliveryError.code .. ':' .. snapshot.active .. ':' .. snapshot.actionTokens
  `);
  assert.equal(result, 'NOTIFY_UNAVAILABLE:0:0');
});
