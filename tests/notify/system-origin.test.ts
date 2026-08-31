import assert from 'node:assert/strict';
import test from 'node:test';
import {
  createNotifyLua,
  notifyServerHarness,
  notifySharedFiles,
  runNotifyLua,
} from './helpers.js';

test('SYSTEM origin is capability-gated and cannot be selected through a normal payload', async () => {
  const result = await runNotifyLua<string>(`${notifyServerHarness}
    for _, policy in pairs(SynexNotifyLimits.rateLimits) do
      policy.capacity = 256
      policy.refillPerSecond = 0
    end
    __notifyTest.addSession(41, 1)
    __notifyTest.addSession(42, 1)
    local registry, service = __notifyTest.makeRegistry()
    local context = {
      caller = 'consumer.system', callerEpoch = 7, traceId = 'trace-system',
    }

    local spoofed, spoofError = service.send({
      target = __notifyTest.target(41),
      payload = { title = 'Spoofed', origin = 'SYSTEM' },
    }, context)
    assert(spoofed == nil and spoofError.code == 'NOTIFY_INVALID_REQUEST')

    __notifyTest.denied['synex.notify.system'] = true
    local denied, deniedError = service.sendSystem({
      target = __notifyTest.target(41), payload = { title = 'Denied system signal' },
    }, context)
    assert(denied == nil and deniedError.code == 'NOTIFY_OWNER_INVALID')
    assert(__notifyTest.deliveryCount == 0)

    __notifyTest.denied['synex.notify.system'] = nil
    local handle = assert(service.sendSystem({
      target = __notifyTest.target(41), payload = { title = 'System signal' },
    }, context))
    assert(__notifyTest.lastCommand().payload.origin == 'SYSTEM')
    assert(handle.ownerResource == context.caller)

    __notifyTest.denied['synex.notify.system'] = true
    local beforeRevocationChecks = __notifyTest.deliveryCount
    local revokedUpdate, revokedUpdateError = service.update({
      handle = handle, patch = { message = 'Must remain unchanged' },
    }, context)
    local revokedDismiss, revokedDismissError = service.dismiss({
      handle = handle, reason = 'dismissed',
    }, context)
    local revokedBroadcast, revokedBroadcastError = service.broadcastSystem({
      payload = { title = 'Must not enumerate and send' },
    }, context)
    assert(revokedUpdate == nil and revokedUpdateError.code == 'NOTIFY_OWNER_INVALID')
    assert(revokedDismiss == nil and revokedDismissError.code == 'NOTIFY_OWNER_INVALID')
    assert(revokedBroadcast == nil
      and revokedBroadcastError.code == 'NOTIFY_OWNER_INVALID')
    assert(__notifyTest.deliveryCount == beforeRevocationChecks)
    __notifyTest.denied['synex.notify.system'] = nil

    handle = assert(service.update({
      handle = handle, patch = { message = 'Authorized update' },
    }, context))
    assert(handle.revision == 2)

    local batch = assert(service.sendManySystem({
      targets = { __notifyTest.target(41), __notifyTest.target(42) },
      payload = { title = 'System batch' },
    }, context))
    assert(batch.sent == 2 and batch.failed == 0)
    assert(__notifyTest.lastCommand().payload.origin == 'SYSTEM')

    local broadcast = assert(service.broadcastSystem({
      payload = { title = 'System broadcast' },
    }, context))
    assert(broadcast.sent == 2 and broadcast.failed == 0)
    assert(__notifyTest.lastCommand().payload.origin == 'SYSTEM')

    local normal = assert(service.send({
      target = __notifyTest.target(41), payload = { title = 'Server signal' },
    }, context))
    assert(normal and __notifyTest.lastCommand().payload.origin == 'SERVER')

    local definition = service.serviceDefinition()
    assert(definition.capabilities.send_system == 'synex.notify.system')
    assert(definition.capabilities.send_many_system == 'synex.notify.system')
    assert(definition.capabilities.broadcast_system == 'synex.notify.system')
    assert(type(definition.methods.send_system) == 'function')
    assert(type(definition.methods.send_many_system) == 'function')
    assert(type(definition.methods.broadcast_system) == 'function')
    return table.concat({ spoofError.code, deniedError.code,
      revokedUpdateError.code, revokedDismissError.code,
      revokedBroadcastError.code, __notifyTest.lastCommand().payload.origin,
      broadcast.sent }, ':')
  `);
  assert.equal(
    result,
    'NOTIFY_INVALID_REQUEST:NOTIFY_OWNER_INVALID:NOTIFY_OWNER_INVALID:'
      + 'NOTIFY_OWNER_INVALID:NOTIFY_OWNER_INVALID:SERVER:2',
  );
});

test('the Core principal can own SYSTEM signals without broadening normal sends', async () => {
  const result = await runNotifyLua<string>(`${notifyServerHarness}
    for _, policy in pairs(SynexNotifyLimits.rateLimits) do
      policy.capacity = 128
      policy.refillPerSecond = 0
    end
    __notifyTest.addSession(43, 1)
    __notifyTest.systemPrincipals.synex_core = true
    for _, capability in ipairs({
      'synex.notify.send', 'synex.notify.system', 'synex.notify.priority.critical',
      'synex.notify.banner', 'synex.notify.update',
    }) do
      __notifyTest.denied[capability] = true
    end
    local _, service = __notifyTest.makeRegistry()
    local context = { caller = 'synex_core', callerEpoch = 3 }
    local systemHandle = assert(service.sendSystem({
      target = __notifyTest.target(43),
      payload = { kind = 'banner', priority = 'critical', title = 'Core system signal' },
    }, context))
    local updated = assert(service.update({
      handle = systemHandle, patch = { message = 'Core-owned update' },
    }, context))
    assert(service.dismiss({ handle = updated }, context))

    local normal, normalError = service.send({
      target = __notifyTest.target(43), payload = { title = 'Normal send' },
    }, context)
    assert(normal == nil and normalError.code == 'NOTIFY_OWNER_INVALID')
    return table.concat({ systemHandle.ownerResource, updated.revision,
      normalError.code }, ':')
  `);
  assert.equal(result, 'synex_core:2:NOTIFY_OWNER_INVALID');
});

test('client orchestration keeps SERVER and SYSTEM compaction domains isolated', async () => {
  const engine = await createNotifyLua([
    ...notifySharedFiles,
    'resources/synex_notify/client/engine.lua',
  ]);
  try {
    const result = await engine.doString(`
      local clock = 1000
      local notify = SynexNotifyEngine.create({
        now = function() return clock end,
        upsertSignal = function(value) return value end,
        removeSignal = function() return true end,
      })
      local function presentation(id, origin)
        return assert(SynexNotifyValidation.canonicalPresentation({
          notificationId = id, revision = 1, kind = 'toast', tone = 'info',
          priority = 'normal', title = origin, position = 'top-right',
          createdAt = clock, origin = origin, dedupeKey = 'same-key',
          dedupePolicy = 'suppress',
        }, { authority = origin, ownerResource = 'synex_core' }))
      end

      assert(notify.applyServer('synex_core', 1,
        presentation('server-origin-01', 'SERVER'), 'show'))
      assert(notify.applyServer('synex_core', 1,
        presentation('system-origin-01', 'SYSTEM'), 'show'))
      assert(notify.snapshot().records == 2)

      local changedOrigin = presentation('system-origin-01', 'SERVER')
      changedOrigin.revision = 2
      local changed, changedError = notify.applyServer(
        'synex_core', 1, changedOrigin, 'update')
      assert(changed == nil and changedError.code == 'NOTIFY_NOTIFICATION_STALE')

      local cleanup = notify.ownerStop('synex_core', 1, 'SERVER')
      assert(cleanup.removed == 2 and notify.snapshot().records == 0)
      local history = notify.history('synex_core', 10)
      local origins = {}
      for _, entry in ipairs(history) do origins[entry.origin] = true end
      assert(origins.SERVER and origins.SYSTEM)
      return table.concat({ cleanup.removed, changedError.code,
        origins.SERVER and 'server' or 'missing',
        origins.SYSTEM and 'system' or 'missing' }, ':')
    `) as string;
    assert.equal(
      result,
      '2:NOTIFY_NOTIFICATION_STALE:server:system',
    );
  } finally {
    engine.global.close();
  }
});
