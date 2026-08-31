import assert from 'node:assert/strict';
import test from 'node:test';
import { notifyServerHarness, runNotifyLua } from './helpers.js';

test('server delivery is session-generation fenced and owner handles are epoch scoped', async () => {
  const result = await runNotifyLua<string>(`${notifyServerHarness}
    __notifyTest.addSession(7, 3)
    local registry = __notifyTest.makeRegistry()
    local handle = assert(registry.send('consumer.alpha', 11, __notifyTest.target(7), {
      title = 'Generation-bound delivery',
    }, { operation = 'notify.send' }))
    assert(handle.ownerResource == 'consumer.alpha' and handle.ownerEpoch == 11)
    local delivered = __notifyTest.lastDelivery()
    local command = __notifyTest.command(delivered)
    assert(delivered.source == 7 and delivered.source ~= -1)
    assert(command.target.sourceGeneration == 3)
    assert(command.ownerEpoch == 11 and command.revision == 1)

    local _, wrongOwnerError = registry.update('consumer.beta', 11, handle, {
      title = 'Must not cross owners',
    }, { operation = 'notify.update' })
    local _, staleEpochError = registry.update('consumer.alpha', 12, handle, {
      title = 'Must not cross epochs',
    }, { operation = 'notify.update' })
    assert(wrongOwnerError.code == 'NOTIFY_OWNER_STALE')
    assert(staleEpochError.code == 'NOTIFY_OWNER_STALE')

    __notifyTest.sessions[7] = {
      source = 7, id = 'session-0007-0004', sourceGeneration = 4, state = 'ACTIVE',
    }
    local deliveriesBefore = __notifyTest.deliveryCount
    local _, targetError = registry.update('consumer.alpha', 11, handle, {
      title = 'Old generation must not receive this',
    }, { operation = 'notify.update' })
    assert(targetError.code == 'NOTIFY_TARGET_STALE')
    assert(__notifyTest.deliveryCount == deliveriesBefore)
    local cleanup = assert(registry.cleanupOwner('consumer.alpha', 11))
    assert(cleanup.removed == 1 and registry.snapshot().active == 0)
    return table.concat({ wrongOwnerError.code, staleEpochError.code, targetError.code }, ':')
  `);
  assert.equal(
    result,
    'NOTIFY_OWNER_STALE:NOTIFY_OWNER_STALE:NOTIFY_TARGET_STALE',
  );
});

test('server presentation payloads round-trip through the exact client transport schema', async () => {
  const result = await runNotifyLua<string>(`${notifyServerHarness}
    __notifyTest.addSession(8, 2)
    local registry = __notifyTest.makeRegistry()
    assert(registry.send('consumer.roundtrip', 3, __notifyTest.target(8), {
      title = 'Canonical server delivery', sound = true,
      history = false, maxRefreshCount = 2,
      dedupeKey = 'roundtrip.transport', dedupePolicy = 'refresh',
    }, { operation = 'notify.send' }))
    local delivery = assert(__notifyTest.lastDelivery())
    local command = __notifyTest.command(delivery)
    local presentation, presentationError = SynexNotifyValidation.canonicalPresentation(
      command.payload, {
        authority = 'SERVER', ownerResource = command.ownerResource,
      })
    assert(presentation, presentationError and presentationError.code)
    assert(presentation.notificationId == command.notificationId)
    assert(presentation.revision == command.revision)
    assert(presentation.sound == true and presentation.history == false)
    assert(presentation.maxRefreshCount == 2)
    return presentation.notificationId
  `);
  assert.match(result, /^notify-/);
});

test('server presentation size failures preserve registry state and rate budgets', async () => {
  const result = await runNotifyLua<string>(`${notifyServerHarness}
    for _, policy in pairs(SynexNotifyLimits.rateLimits) do
      policy.capacity = 1
      policy.refillPerSecond = 0
    end
    __notifyTest.addSession(18, 1)
    local registry = __notifyTest.makeRegistry()
    local request = { title = 'Presentation overhead boundary' }
    local canonical = assert(SynexNotifyValidation.canonicalNotification(
      request, { authority = 'SERVER' }))
    local requestBytes = assert(SynexNotifyValidation.payloadBytes(canonical))
    SynexNotifyLimits.maximumPayloadBytes = requestBytes + 5
    local oversized, oversizedError = registry.send('consumer.payload', 1,
      __notifyTest.target(18), request, { operation = 'notify.send' })
    assert(oversized == nil and oversizedError.code == 'NOTIFY_PAYLOAD_TOO_LARGE')
    assert(registry.snapshot().active == 0 and __notifyTest.deliveryCount == 0)

    SynexNotifyLimits.maximumPayloadBytes = 4096
    local accepted = assert(registry.send('consumer.payload', 1,
      __notifyTest.target(18), request, { operation = 'notify.send' }))
    assert(accepted.revision == 1 and registry.snapshot().active == 1)
    assert(__notifyTest.deliveryCount == 1)
    return oversizedError.code .. ':' .. accepted.revision
  `);
  assert.equal(result, 'NOTIFY_PAYLOAD_TOO_LARGE:1');
});

test('oversized merged server updates roll back and do not consume update budget', async () => {
  const result = await runNotifyLua<string>(`${notifyServerHarness}
    for _, policy in pairs(SynexNotifyLimits.rateLimits) do
      policy.capacity = 100
      policy.refillPerSecond = 0
    end
    SynexNotifyLimits.rateLimits.update = { capacity = 1, refillPerSecond = 0 }
    __notifyTest.addSession(19, 1)
    local registry = __notifyTest.makeRegistry()
    local handle = assert(registry.send('consumer.payload-update', 1,
      __notifyTest.target(19), { title = 'Update payload boundary' },
      { operation = 'notify.send' }))
    local message = ('\\\\'):rep(720)
    local normalizedPatch = assert(SynexNotifyValidation.notificationPatch({
      message = message,
    }, { authority = 'SERVER' }))
    local patchBytes = assert(SynexNotifyValidation.payloadBytes(normalizedPatch))
    local projected = SynexNotifyFoundation.copy(__notifyTest.lastCommand().payload)
    projected.message = message
    projected.revision = 2
    local normalizedProjection = assert(SynexNotifyValidation.canonicalPresentation(
      projected, { authority = 'SERVER' }))
    local projectionBytes = assert(SynexNotifyValidation.payloadBytes(normalizedProjection))
    assert(projectionBytes > patchBytes)
    SynexNotifyLimits.maximumPayloadBytes = projectionBytes - 1

    local rejected, rejectedError = registry.update('consumer.payload-update', 1,
      handle, { message = message }, { operation = 'notify.update' })
    assert(rejected == nil and rejectedError.code == 'NOTIFY_PAYLOAD_TOO_LARGE')
    local unchanged = registry.records()[handle.notificationId]
    assert(unchanged.revision == 1 and unchanged.message == nil)
    assert(__notifyTest.deliveryCount == 1)

    SynexNotifyLimits.maximumPayloadBytes = 4096
    local accepted = assert(registry.update('consumer.payload-update', 1,
      handle, { message = 'Small update' }, { operation = 'notify.update' }))
    assert(accepted.revision == 2 and __notifyTest.deliveryCount == 2)
    return rejectedError.code .. ':' .. accepted.revision
  `);
  assert.equal(result, 'NOTIFY_PAYLOAD_TOO_LARGE:2');
});

test('server privilege matrix gates send, high, critical, banner, and broadcast independently', async () => {
  const result = await runNotifyLua<string>(`${notifyServerHarness}
    __notifyTest.addSession(1, 1)

    local function denied(capability, payload, broadcast)
      __notifyTest.denied = { [capability] = true }
      local registry = __notifyTest.makeRegistry()
      if broadcast then
        local _, operationError = registry.broadcast(
          'consumer.security', 1, payload, { operation = 'notify.broadcast' })
        return operationError
      end
      local _, operationError = registry.send('consumer.security', 1,
        __notifyTest.target(1), payload, { operation = 'notify.send' })
      return operationError
    end

    local sendError = denied('synex.notify.send', { title = 'Send denied' })
    local highError = denied('synex.notify.priority.high', {
      title = 'High denied', priority = 'high',
    })
    local criticalError = denied('synex.notify.priority.critical', {
      title = 'Critical denied', priority = 'critical',
    })
    local bannerError = denied('synex.notify.banner', {
      title = 'Banner denied', kind = 'banner',
    })
    local broadcastError = denied('synex.notify.broadcast', {
      title = 'Broadcast denied',
    }, true)
    assert(sendError.code == 'NOTIFY_OWNER_INVALID')
    assert(highError.code == 'NOTIFY_PRIORITY_DENIED')
    assert(criticalError.code == 'NOTIFY_PRIORITY_DENIED')
    assert(bannerError.code == 'NOTIFY_OWNER_INVALID')
    assert(broadcastError.code == 'NOTIFY_OWNER_INVALID')
    assert(__notifyTest.deliveryCount == 0)
    return table.concat({ sendError.code, highError.code, criticalError.code,
      bannerError.code, broadcastError.code }, ':')
  `);
  assert.equal(
    result,
    'NOTIFY_OWNER_INVALID:NOTIFY_PRIORITY_DENIED:NOTIFY_PRIORITY_DENIED:'
      + 'NOTIFY_OWNER_INVALID:NOTIFY_OWNER_INVALID',
  );
});

test('sendMany and broadcast stay bounded and broadcasts enumerate exact active sources', async () => {
  const result = await runNotifyLua<string>(`${notifyServerHarness}
    for _, policy in pairs(SynexNotifyLimits.rateLimits) do
      policy.capacity = 512
      policy.refillPerSecond = 0
    end
    __notifyTest.addSession(1, 1)
    local registry = __notifyTest.makeRegistry()
    local targets = {}
    for index = 1, SynexNotifyLimits.maximumSendMany do
      targets[index] = __notifyTest.target(1)
    end
    local batch = assert(registry.sendMany('consumer.batch', 1, targets, {
      title = 'Bounded batch',
    }, { operation = 'notify.send_many' }))
    assert(batch.sent == 32 and batch.failed == 0 and #batch.handles == 32)
    targets[33] = __notifyTest.target(1)
    local _, tooManyError = registry.sendMany('consumer.batch', 1, targets, {
      title = 'Oversized batch',
    }, { operation = 'notify.send_many' })
    assert(tooManyError.code == 'NOTIFY_INVALID_REQUEST')

    __notifyTest.players = {}
    __notifyTest.sessions = {}
    for source = 1, SynexNotifyLimits.maximumBroadcastTargets + 1 do
      __notifyTest.addSession(source, 1)
    end
    local _, broadcastBoundError = registry.broadcast('consumer.broadcast', 1, {
      title = 'Oversized broadcast',
    }, { operation = 'notify.broadcast' })
    assert(broadcastBoundError.code == 'NOTIFY_QUEUE_FULL')

    __notifyTest.players = { '41', '42', '43' }
    __notifyTest.sessions = {
      [41] = { source = 41, id = 'session-0041-0001', sourceGeneration = 1, state = 'ACTIVE' },
      [42] = { source = 42, id = 'session-0042-0001', sourceGeneration = 1, state = 'ACTIVE' },
      [43] = { source = 43, id = 'session-0043-0001', sourceGeneration = 1, state = 'CLOSED' },
    }
    local before = __notifyTest.deliveryCount
    local broadcast = assert(registry.broadcast('consumer.broadcast', 1, {
      title = 'Exact active targets',
    }, { operation = 'notify.broadcast' }))
    assert(broadcast.sent == 2 and broadcast.failed == 0)
    assert(__notifyTest.deliveryCount == before + 2)
    assert(__notifyTest.deliveries[before + 1].source == 41)
    assert(__notifyTest.deliveries[before + 2].source == 42)
    assert(__notifyTest.deliveries[before + 1].source ~= -1)
    assert(#__notifyTest.audits == 1)
    return table.concat({ batch.sent, tooManyError.code,
      broadcastBoundError.code, broadcast.sent }, ':')
  `);
  assert.equal(result, '32:NOTIFY_INVALID_REQUEST:NOTIFY_QUEUE_FULL:2');
});

test('server send budgets are atomic across global, owner, kind, and priority buckets', async () => {
  const result = await runNotifyLua<string>(`${notifyServerHarness}
    SynexNotifyLimits.rateLimits.global = { capacity = 1, refillPerSecond = 0 }
    SynexNotifyLimits.rateLimits.owner = { capacity = 1, refillPerSecond = 0 }
    SynexNotifyLimits.rateLimits.persistent = { capacity = 0, refillPerSecond = 0 }
    SynexNotifyLimits.rateLimits.toast = { capacity = 1, refillPerSecond = 0 }
    SynexNotifyLimits.notificationCosts.persistent = 1
    SynexNotifyLimits.notificationCosts.toast = 1
    SynexNotifyLimits.notificationCosts.normal = 1
    __notifyTest.addSession(9, 1)
    local registry = __notifyTest.makeRegistry()
    local _, deniedError = registry.send('consumer.atomic', 1, __notifyTest.target(9), {
      kind = 'persistent', title = 'Denied without partial debit',
    }, { operation = 'notify.send' })
    assert(deniedError.code == 'NOTIFY_RATE_LIMITED')
    local accepted = assert(registry.send('consumer.atomic', 1, __notifyTest.target(9), {
      kind = 'toast', title = 'Atomic tokens remained available',
    }, { operation = 'notify.send' }))
    assert(accepted.revision == 1 and registry.snapshot().active == 1)
    return deniedError.code .. ':' .. accepted.revision
  `);
  assert.equal(result, 'NOTIFY_RATE_LIMITED:1');
});

test('new owner epochs clean older state while stale cleanup cannot reset newer budgets', async () => {
  const result = await runNotifyLua<string>(`${notifyServerHarness}
    for _, policy in pairs(SynexNotifyLimits.rateLimits) do
      policy.capacity = 100
      policy.refillPerSecond = 0
    end
    SynexNotifyLimits.rateLimits.owner = { capacity = 2, refillPerSecond = 0 }
    __notifyTest.addSession(10, 1)
    local registry = __notifyTest.makeRegistry()
    local old = assert(registry.send('consumer.epoch', 1, __notifyTest.target(10), {
      title = 'Epoch one',
    }, { operation = 'notify.send' }))
    local current = assert(registry.send('consumer.epoch', 2, __notifyTest.target(10), {
      title = 'Epoch two first',
    }, { operation = 'notify.send' }))
    assert(registry.snapshot().active == 1)
    local stale, staleError = registry.send('consumer.epoch', 1,
      __notifyTest.target(10), { title = 'Stale epoch' },
      { operation = 'notify.send' })
    assert(stale == nil and staleError.code == 'NOTIFY_OWNER_STALE')
    assert(registry.cleanupOwner('consumer.epoch', 1).removed == 0)
    assert(registry.send('consumer.epoch', 2, __notifyTest.target(10), {
      title = 'Epoch two second',
    }, { operation = 'notify.send' }))
    local third, budgetError = registry.send('consumer.epoch', 2,
      __notifyTest.target(10), { title = 'Epoch two exhausted' },
      { operation = 'notify.send' })
    assert(third == nil and budgetError.code == 'NOTIFY_RATE_LIMITED')
    local _, oldHandleError = registry.update('consumer.epoch', 1, old, {
      message = 'Old handle cannot return',
    }, { operation = 'notify.update' })
    assert(oldHandleError.code == 'NOTIFY_NOTIFICATION_NOT_FOUND'
      or oldHandleError.code == 'NOTIFY_OWNER_STALE')
    return table.concat({ current.ownerEpoch, staleError.code,
      budgetError.code, registry.snapshot().active }, ':')
  `);
  assert.equal(result, '2:NOTIFY_OWNER_STALE:NOTIFY_RATE_LIMITED:2');
});

test('progress updates enforce revision and terminal transition invariants', async () => {
  const result = await runNotifyLua<string>(`${notifyServerHarness}
    for _, policy in pairs(SynexNotifyLimits.rateLimits) do
      policy.capacity = 128
      policy.refillPerSecond = 0
    end
    __notifyTest.addSession(5, 1)
    local registry, service = __notifyTest.makeRegistry()
    local handle = assert(registry.send('consumer.progress', 4, __notifyTest.target(5), {
      kind = 'progress', title = 'Import', progress = {
        state = 'PENDING', mode = 'determinate', value = 0, maximum = 10,
      },
    }, { operation = 'notify.send' }))
    local running = assert(registry.update('consumer.progress', 4, handle, {
      progress = { state = 'RUNNING', mode = 'determinate', value = 4, maximum = 10 },
    }, { operation = 'notify.update' }))
    assert(running.revision == 2)
    local _, oldRevisionError = registry.update('consumer.progress', 4, handle, {
      message = 'Stale write',
    }, { operation = 'notify.update' })
    assert(oldRevisionError.code == 'NOTIFY_NOTIFICATION_STALE')
    local _, backwardsError = registry.update('consumer.progress', 4, running, {
      progress = { state = 'RUNNING', mode = 'determinate', value = 3, maximum = 10 },
    }, { operation = 'notify.update' })
    assert(backwardsError.code == 'NOTIFY_NOTIFICATION_STALE')
    local completed = assert(registry.update('consumer.progress', 4, running, {
      tone = 'success',
      progress = { state = 'SUCCESS', mode = 'determinate', value = 10, maximum = 10 },
    }, { operation = 'notify.update' }))
    local _, terminalError = registry.update('consumer.progress', 4, completed, {
      progress = { state = 'RUNNING', mode = 'determinate', value = 10, maximum = 10 },
    }, { operation = 'notify.update' })
    assert(terminalError.code == 'NOTIFY_NOTIFICATION_STALE')

    local cancelHandle = assert(service.send({
      target = __notifyTest.target(5),
      payload = { kind = 'progress', title = 'Cancelable' },
    }, { caller = 'consumer.cancel', callerEpoch = 7, traceId = 'trace-cancel' }))
    local cancelled = assert(service.cancelProgress({
      handle = cancelHandle, message = 'Cancelled safely',
    }, { caller = 'consumer.cancel', callerEpoch = 7, traceId = 'trace-cancel' }))
    assert(cancelled.revision == 2)
    return table.concat({ oldRevisionError.code, backwardsError.code,
      terminalError.code, cancelled.revision }, ':')
  `);
  assert.equal(
    result,
    'NOTIFY_NOTIFICATION_STALE:NOTIFY_NOTIFICATION_STALE:'
      + 'NOTIFY_NOTIFICATION_STALE:2',
  );
});

test('invalid progress transitions do not consume update budget and completion preserves determinate data', async () => {
  const result = await runNotifyLua<string>(`${notifyServerHarness}
    for _, policy in pairs(SynexNotifyLimits.rateLimits) do
      policy.capacity = 100
      policy.refillPerSecond = 0
    end
    SynexNotifyLimits.rateLimits.update = { capacity = 1, refillPerSecond = 0 }
    __notifyTest.addSession(11, 1)
    local registry = __notifyTest.makeRegistry()
    local handle = assert(registry.send('consumer.progress-atomic', 1,
      __notifyTest.target(11), {
        kind = 'progress', title = 'Atomic progress', progress = {
          state = 'RUNNING', mode = 'determinate', value = 4, maximum = 10,
        },
      }, { operation = 'notify.send' }))
    local invalid, invalidError = registry.update('consumer.progress-atomic', 1,
      handle, { progress = {
        state = 'RUNNING', mode = 'determinate', value = 3, maximum = 10,
      } }, { operation = 'notify.update' })
    assert(invalid == nil and invalidError.code == 'NOTIFY_NOTIFICATION_STALE')
    local completed = assert(registry.completeProgress('consumer.progress-atomic', 1,
      handle, 'SUCCESS', 'success', 'Completed', { operation = 'notify.update' }))
    local progress = __notifyTest.lastCommand().payload.progress
    assert(completed.revision == 2 and progress.state == 'SUCCESS')
    assert(progress.mode == 'determinate' and progress.value == 4 and progress.maximum == 10)
    return table.concat({ invalidError.code, completed.revision,
      progress.mode, math.floor(progress.value), math.floor(progress.maximum) }, ':')
  `);
  assert.equal(result, 'NOTIFY_NOTIFICATION_STALE:2:determinate:4:10');
});

test('failed update and dismiss transports preserve the current handle revision and lifecycle', async () => {
  const result = await runNotifyLua<string>(`${notifyServerHarness}
    for _, policy in pairs(SynexNotifyLimits.rateLimits) do
      policy.capacity = 128
      policy.refillPerSecond = 0
    end
    __notifyTest.addSession(6, 1)
    local registry = __notifyTest.makeRegistry()
    local handle = assert(registry.send('consumer.atomic_transport', 3,
      __notifyTest.target(6), {
        kind = 'progress', title = 'Atomic transport', progress = {
          state = 'RUNNING', mode = 'determinate', value = 2, maximum = 10,
        },
      }, { operation = 'notify.send' }))

    __notifyTest.transportFailure = true
    local _, updateError = registry.update('consumer.atomic_transport', 3, handle, {
      progress = { state = 'SUCCESS', mode = 'determinate', value = 10, maximum = 10 },
    }, { operation = 'notify.update' })
    assert(updateError.code == 'NOTIFY_UNAVAILABLE')
    local afterUpdate = registry.records()[handle.notificationId]
    assert(afterUpdate.revision == 1 and afterUpdate.durationMs == nil)
    assert(afterUpdate.progress.state == 'RUNNING' and afterUpdate.progress.value == 2)

    local _, dismissError = registry.dismiss('consumer.atomic_transport', 3, handle,
      'dismissed', { operation = 'notify.dismiss' })
    assert(dismissError.code == 'NOTIFY_UNAVAILABLE')
    local afterDismiss = registry.records()[handle.notificationId]
    assert(afterDismiss.revision == 1 and registry.snapshot().active == 1)

    __notifyTest.transportFailure = false
    local dismissed = assert(registry.dismiss('consumer.atomic_transport', 3, handle,
      'dismissed', { operation = 'notify.dismiss' }))
    assert(dismissed.dismissed and registry.snapshot().active == 0)
    return table.concat({ updateError.code, dismissError.code,
      tostring(dismissed.dismissed) }, ':')
  `);
  assert.equal(result, 'NOTIFY_UNAVAILABLE:NOTIFY_UNAVAILABLE:true');
});
