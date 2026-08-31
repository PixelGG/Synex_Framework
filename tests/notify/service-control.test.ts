import assert from 'node:assert/strict';
import test from 'node:test';
import { notifyServerHarness, runNotifyLua } from './helpers.js';

test('service methods preserve readonly caller context and expose explicit capabilities', async () => {
  const result = await runNotifyLua<string>(`${notifyServerHarness}
    for _, policy in pairs(SynexNotifyLimits.rateLimits) do
      policy.capacity = 128
      policy.refillPerSecond = 0
    end
    __notifyTest.addSession(21, 1)
    local registry, service = __notifyTest.makeRegistry()
    local context = {
      caller = 'consumer.service', callerEpoch = 17,
      traceId = 'trace-service', immutable = 'preserved',
    }
    local handle = assert(service.send({
      target = __notifyTest.target(21), payload = { title = 'Service delivery' },
    }, context))
    assert(context.immutable == 'preserved' and context.operation == nil)
    assert(handle.ownerResource == 'consumer.service' and handle.ownerEpoch == 17)

    local updated = assert(service.update({
      handle = handle, patch = { message = 'Updated through service' },
    }, context))
    assert(updated.revision == 2 and context.operation == nil)
    local dismissed = assert(service.dismiss({
      handle = updated, reason = 'dismissed',
    }, context))
    assert(dismissed.dismissed == true)

    local _, extraError = service.send({
      target = __notifyTest.target(21), payload = { title = 'Invalid' }, extra = true,
    }, context)
    local _, missingContextError = service.send({
      target = __notifyTest.target(21), payload = { title = 'Invalid context' },
    }, nil)
    assert(extraError.code == 'NOTIFY_INVALID_REQUEST')
    assert(missingContextError.code == 'NOTIFY_OWNER_INVALID')

    local definition = service.serviceDefinition()
    assert(definition.name == 'synex.notify' and definition.version == '1.0.0')
    assert(definition.capabilities.send == 'synex.notify.send')
    assert(definition.capabilities.broadcast == 'synex.notify.broadcast')
    assert(definition.capabilities.get_control_summary == 'synex.notify.diagnostics.read')
    assert(type(definition.methods.send_many) == 'function')
    local _, unknownContractError = service.contractHandler({ name = 'synex.notify.unknown' })
    assert(unknownContractError.code == 'NOTIFY_UNAVAILABLE')

    local public = SynexNotifyFoundation.publicError({
      code = 'DATABASE_PASSWORD_LEAK', message = 'private backend detail', retryable = false,
    })
    assert(public.code == 'NOTIFY_INTERNAL_ERROR')
    assert(public.message == 'The notification operation failed.')
    return table.concat({ updated.revision, extraError.code,
      missingContextError.code, public.code }, ':')
  `);
  assert.equal(
    result,
    '2:NOTIFY_INVALID_REQUEST:NOTIFY_OWNER_INVALID:NOTIFY_INTERNAL_ERROR',
  );
});

test('audit records only broadcasts and privileged deliveries without notification content', async () => {
  const result = await runNotifyLua<string>(`${notifyServerHarness}
    for _, policy in pairs(SynexNotifyLimits.rateLimits) do
      policy.capacity = 256
      policy.refillPerSecond = 0
    end
    __notifyTest.addSession(61, 1)
    __notifyTest.addSession(62, 1)
    local _, service = __notifyTest.makeRegistry()
    local context = {
      caller = 'consumer.audit', callerEpoch = 4, traceId = 'trace-notify-audit',
    }

    assert(service.send({
      target = __notifyTest.target(61),
      payload = { title = 'Ordinary signal', message = 'Must not be audited' },
    }, context))
    assert(#__notifyTest.audits == 0)

    assert(service.send({
      target = __notifyTest.target(61),
      payload = {
        title = 'Critical framework warning', message = 'Private content',
        priority = 'critical',
      },
    }, context))
    local critical = assert(__notifyTest.audits[1])
    assert(critical.action == 'notify.privileged.send')
    assert(critical.targetType == 'resource'
      and critical.targetId == 'consumer.audit')
    assert(critical.traceId == 'trace-notify-audit')
    assert(critical.context.deliveryScope == 'single'
      and critical.context.priority == 'critical'
      and critical.context.origin == 'SERVER'
      and critical.context.sent == 1 and critical.context.failed == 0)

    assert(service.sendSystem({
      target = __notifyTest.target(61),
      payload = { title = 'Privileged system message' },
    }, context))
    assert(#__notifyTest.audits == 2
      and __notifyTest.audits[2].context.origin == 'SYSTEM')

    local batch = assert(service.sendMany({
      targets = { __notifyTest.target(61), __notifyTest.target(62) },
      payload = { title = 'Critical batch', priority = 'critical' },
    }, context))
    assert(batch.sent == 2 and #__notifyTest.audits == 3)
    assert(__notifyTest.audits[3].action == 'notify.privileged.send_many'
      and __notifyTest.audits[3].context.sent == 2)

    local broadcast = assert(service.broadcastSystem({
      payload = { title = 'System broadcast' },
    }, context))
    assert(broadcast.sent == 2 and #__notifyTest.audits == 4)
    local broadcastAudit = __notifyTest.audits[4]
    assert(broadcastAudit.action == 'notify.broadcast'
      and broadcastAudit.context.deliveryScope == 'broadcast'
      and broadcastAudit.context.targets == 2
      and broadcastAudit.context.sent == 2
      and broadcastAudit.context.failed == 0)

    for _, entry in ipairs(__notifyTest.audits) do
      assert(entry.data == nil and entry.before == nil and entry.after == nil)
      assert(entry.context.title == nil and entry.context.message == nil
        and entry.context.notificationId == nil
        and entry.context.sessionId == nil)
    end
    return table.concat({ #__notifyTest.audits,
      critical.context.priority, broadcastAudit.context.origin }, ':')
  `);
  assert.equal(result, '4:critical:SYSTEM');
});

test('control provider exposes bounded aggregate views without notification content', async () => {
  const result = await runNotifyLua<string>(`${notifyServerHarness}
    __notifyTest.addSession(31, 1)
    local registry = __notifyTest.makeRegistry()
    assert(registry.send('consumer.control', 1, __notifyTest.target(31), {
      kind = 'progress', title = 'Private title', message = 'Private message',
    }, { operation = 'notify.send' }))
    local clientCounters = {
      created = 0, displayed = 0, removed = 0,
      deduplicated = 0, grouped = 0, suppressed = 0, coalesced = 0,
      queuePromotions = 0, queueEvictions = 0, queueWaitTotalMs = 0,
      renderDispatchSamples = 0, renderDispatchTotalMs = 0,
      renderAckSamples = 0, renderAckTotalMs = 0,
      transportFailures = 0, nativeFallbacks = 0,
      presentationExpired = 0, quietDeferred = 0,
    }
    local metricContext = {
      source = 31, sourceGeneration = 1, session = __notifyTest.sessions[31],
    }
    assert(__notifyTest.observability.reportClient({
      clientEpoch = 1000, sequence = 1, counters = clientCounters,
      gauges = { visible = 0, queued = 0, pendingVisibilityAcks = 0 },
    }, metricContext))
    __notifyTest.now = __notifyTest.now + 5000
    clientCounters.displayed = 2
    clientCounters.deduplicated = 4
    clientCounters.grouped = 3
    clientCounters.suppressed = 2
    clientCounters.coalesced = 1
    clientCounters.queuePromotions = 2
    clientCounters.queueWaitTotalMs = 40
    clientCounters.renderDispatchSamples = 2
    clientCounters.renderDispatchTotalMs = 10
    clientCounters.renderAckSamples = 2
    clientCounters.renderAckTotalMs = 20
    assert(__notifyTest.observability.reportClient({
      clientEpoch = 1000, sequence = 2, counters = clientCounters,
      gauges = { visible = 1, queued = 3, pendingVisibilityAcks = 1 },
    }, metricContext))
    local provider = SynexNotifyControlProvider.create({
      registry = registry,
      now = function() return __notifyTest.now end,
      getResourceState = function(resource)
        return __notifyTest.resourceStates[resource] or 'missing'
      end,
    })

    local overview = assert(provider.operations.summary({ view = 'overview' }))
    assert(overview.state == 'ephemeral' and overview.persistence == 'none')
    assert(overview.activeDeliveries == 1 and overview.activeProgress == 1)
    assert(overview.pendingCommands == 1 and overview.maximumPendingCommands == 1024)
    assert(overview.wakeDispatched == 1 and overview.displayed == nil,
      'overview wake metric semantics')
    assert(overview.deduplicated == nil and overview.grouped == nil
      and overview.suppressed == nil, 'overview omits client-local counters')
    assert(overview.clientPresentationMetrics.aggregation == 'client-reported'
      and overview.clientPresentationMetrics.available == true
      and overview.clientPresentationMetrics.freshSessions == 1,
      'overview exposes fresh bounded client presentation telemetry')
    assert(overview.title == nil and overview.message == nil)
    local owners = assert(provider.operations.list({ view = 'owners', limit = 10 }))
    assert(#owners.items == 1 and owners.items[1].ownerResource == 'consumer.control')
    assert(owners.items[1].title == nil and owners.items[1].message == nil)
    assert(registry.send('consumer.control.second', 1, __notifyTest.target(31), {
      title = 'Second aggregate owner',
    }, { operation = 'notify.send' }))
    local limitedOwners = assert(provider.operations.list({ view = 'owners', limit = 1 }))
    assert(#limitedOwners.items == 1 and limitedOwners.hasMore
      and limitedOwners.truncated)
    local limitedBudgets = assert(provider.operations.list({ view = 'budgets', limit = 1 }))
    assert(#limitedBudgets.items == 1 and limitedBudgets.hasMore
      and limitedBudgets.truncated)
    local budgets = assert(provider.operations.list({ view = 'budgets', limit = 50 }))
    local rates = assert(provider.operations.list({ view = 'rate_limits', limit = 50 }))
    assert(#budgets.items == 9 and #rates.items > 0)
    local pendingBudget = nil
    for _, budget in ipairs(budgets.items) do
      if budget.scope == 'pending_commands' then pendingBudget = budget end
    end
    assert(pendingBudget and pendingBudget.maximum == 1024
      and pendingBudget.perSource == 128 and pendingBudget.ttlMs == 10000)
    assert(not budgets.hasMore and not rates.truncated)
    local queue = assert(provider.operations.metrics({ view = 'queue' }))
    local deduplication = assert(provider.operations.metrics({ view = 'deduplication' }))
    local grouping = assert(provider.operations.metrics({ view = 'grouping' }))
    local suppression = assert(provider.operations.metrics({ view = 'suppression' }))
    local progress = assert(provider.operations.metrics({ view = 'progress' }))
    local actions = assert(provider.operations.metrics({ view = 'actions' }))
    local performance = assert(provider.operations.metrics({ view = 'performance' }))
    assert(queue.retainedDeliveries == 2 and queue.activePresentations == 2
      and queue.dormantRetained == 0 and queue.maximumRetainedDeliveries == 512)
    assert(queue.pendingCommands == 2 and queue.maximumPendingCommands == 1024
      and queue.pendingCommandUtilization > 0)
    assert(queue.clientReported.available and queue.clientReported.visible == 1
      and queue.clientReported.queued == 3
      and queue.clientReported.averageWaitMs == 20)
    assert(deduplication.aggregation == 'client-reported'
      and deduplication.available == true and deduplication.deduplicated == 4,
      'deduplication aggregation boundary')
    assert(grouping.aggregation == 'client-reported'
      and grouping.available == true and grouping.grouped == 3,
      'grouping aggregation boundary')
    assert(suppression.aggregation == 'client-reported'
      and suppression.available == true and suppression.suppressed == 2,
      'suppression aggregation boundary')
    assert(progress.active == 1 and actions.activeTokens == 0)
    assert(performance.wakeDispatchSamples == 2
      and performance.averageWakeDispatchLatencyMs >= 0
      and performance.validationSamples == 2
      and performance.averageValidationLatencyMs >= 0,
      'wake-dispatch performance metrics')
    assert(performance.clientReported.available
      and performance.clientReported.renderAckSamples == 2
      and performance.clientReported.averageRenderAckLatencyMs == 10
      and performance.clientReported.coalesced == 1)
    assert(__notifyTest.metrics.synex_notify_wake_dispatched_total == 2,
      'wake-dispatch Core metric')
    assert(__notifyTest.metrics.synex_notify_displayed_total == 2
      and __notifyTest.metrics.synex_notify_deduplicated_total == 4
      and __notifyTest.metrics.synex_notify_grouped_total == 3
      and __notifyTest.metrics.synex_notify_suppressed_total == 2,
      'canonical presentation counters are fed only by bounded client deltas')

    local before = __notifyTest.deliveryCount
    local simulated = assert(provider.operations.simulate({
      view = 'policy', input = {
        title = 'Simulation only', kind = 'banner', priority = 'critical',
      },
    }))
    assert(simulated.valid and simulated.sends == false)
    assert(__notifyTest.deliveryCount == before)
    local _, cursorError = provider.operations.list({
      view = 'owners', cursor = 'not-supported',
    })
    assert(cursorError.code == 'NOTIFY_INVALID_REQUEST')

    __notifyTest.resourceStates.synex_ui = 'stopped'
    local health = assert(provider.operations.health({ view = 'health' }))
    assert(health.state == 'DEGRADED' and health.uiRuntime == 'stopped')
    assert(health.reasons[1] == 'UI_RUNTIME_UNAVAILABLE')

    local captured = nil
    local token = assert(provider.register({ ControlProviders = {
      register = function(definition) captured = definition; return 'provider-token' end,
    } }))
    assert(token == 'provider-token' and captured.namespace == 'notify')
    assert(#captured.views == 15 and type(captured.operations.simulate) == 'function')
    return table.concat({ overview.activeDeliveries, #budgets.items,
      simulated.sends and 'sent' or 'dry', cursorError.code, health.state }, ':')
  `);
  assert.equal(result, '1:9:dry:NOTIFY_INVALID_REQUEST:DEGRADED');
});

test('capability denials remain distinct from actual rate-limit pressure', async () => {
  const result = await runNotifyLua<string>(`${notifyServerHarness}
    __notifyTest.resourceStates['consumer.denied'] = 'started'
    __notifyTest.addSession(32, 1)
    __notifyTest.denied['synex.notify.send'] = true
    local registry = __notifyTest.makeRegistry()
    for index = 1, 20 do
      local accepted, deniedError = registry.send('consumer.denied', 1,
        __notifyTest.target(32), { title = ('Denied %d'):format(index) },
        { operation = 'notify.send' })
      assert(accepted == nil and deniedError.code == 'NOTIFY_OWNER_INVALID')
    end
    local snapshot = registry.snapshot()
    assert(snapshot.metrics.capabilityDenied == 20)
    assert(snapshot.metrics.rateLimited == 0)
    local report = assert(registry.doctor(100))
    for _, finding in ipairs(report.findings) do
      assert(finding.code ~= 'NOTIFICATION_RATE_LIMIT_PRESSURE')
    end
    return table.concat({ snapshot.metrics.capabilityDenied,
      snapshot.metrics.rateLimited, #report.findings }, ':')
  `);
  assert.equal(result, '20:0:0');
});

test('update, dismiss, and broadcast capability denials share observable accounting', async () => {
  const result = await runNotifyLua<string>(`${notifyServerHarness}
    for _, policy in pairs(SynexNotifyLimits.rateLimits) do
      policy.capacity = 100
      policy.refillPerSecond = 0
    end
    __notifyTest.addSession(35, 1)
    local registry = __notifyTest.makeRegistry()
    local handle = assert(registry.send('consumer.denial-parity', 1,
      __notifyTest.target(35), { title = 'Capability parity' },
      { operation = 'notify.send' }))
    __notifyTest.denied['synex.notify.update'] = true
    local _, updateError = registry.update('consumer.denial-parity', 1, handle, {
      message = 'Denied update',
    }, { operation = 'notify.update' })
    local _, dismissError = registry.dismiss('consumer.denial-parity', 1, handle,
      'dismissed', { operation = 'notify.dismiss' })
    __notifyTest.denied['synex.notify.broadcast'] = true
    local _, broadcastError = registry.broadcast('consumer.denial-parity', 1, {
      title = 'Denied broadcast',
    }, { operation = 'notify.broadcast' })
    assert(updateError.code == 'NOTIFY_OWNER_INVALID')
    assert(dismissError.code == 'NOTIFY_OWNER_INVALID')
    assert(broadcastError.code == 'NOTIFY_OWNER_INVALID')
    local snapshot = registry.snapshot()
    assert(snapshot.metrics.capabilityDenied == 3)
    assert(snapshot.owners[1].capabilityDenied == 3)
    return snapshot.metrics.capabilityDenied
  `);
  assert.equal(result, 3);
});

test('doctor findings are bounded and flag unavailable UI and orphan progress', async () => {
  const result = await runNotifyLua<string>(`${notifyServerHarness}
    __notifyTest.resourceStates.synex_ui = 'stopped'
    __notifyTest.resourceStates['consumer.doctor'] = 'started'
    __notifyTest.addSession(33, 1)
    local registry = __notifyTest.makeRegistry()
    assert(registry.send('consumer.doctor', 1, __notifyTest.target(33), {
      kind = 'progress', title = 'Orphan candidate',
      maxLifetimeMs = 120000,
    }, { operation = 'notify.send' }))
    __notifyTest.now = 62001
    local doctor = assert(registry.doctor(1))
    assert(doctor.status == 'DEGRADED' and #doctor.findings == 1)
    assert(doctor.findings[1].code == 'UI_RUNTIME_UNAVAILABLE')
    assert(doctor.truncated == true)
    local complete = assert(registry.doctor(50))
    assert(#complete.findings == 2)
    assert(complete.findings[2].code == 'ORPHAN_PROGRESS_NOTIFICATION')
    return doctor.findings[1].code .. ':' .. complete.findings[2].code
  `);
  assert.equal(result, 'UI_RUNTIME_UNAVAILABLE:ORPHAN_PROGRESS_NOTIFICATION');
});

test('doctor detects stale ownership, stale targets, expired actions, pressure, and payload abuse', async () => {
  const result = await runNotifyLua<string>(`${notifyServerHarness}
    __notifyTest.resourceStates['consumer.audit'] = 'started'
    __notifyTest.addSession(34, 1)
    local registry = __notifyTest.makeRegistry()
    assert(registry.send('consumer.audit', 1, __notifyTest.target(34), {
      kind = 'persistent', title = 'Audited lifecycle', actions = {
        { id = 'ack', label = 'Acknowledge', ttlMs = 1000 },
      },
    }, { operation = 'notify.send' }))
    for index = 1, 50 do
      registry.send('consumer.audit', 1, __notifyTest.target(34), {
        title = ('Pressure %d'):format(index),
      }, { operation = 'notify.send' })
    end
    for _ = 1, 20 do
      registry.send('consumer.audit', 1, __notifyTest.target(34), {
        title = nil,
      }, { operation = 'notify.send' })
    end
    __notifyTest.sessions[34] = nil
    __notifyTest.resourceStates['consumer.audit'] = 'stopped'
    __notifyTest.now = 2001
    local report = assert(registry.doctor(100))
    local found = {}
    for _, finding in ipairs(report.findings) do found[finding.code] = true end
    assert(found.OWNER_LEAK and found.STALE_NOTIFICATION_TARGET)
    assert(found.EXPIRED_ACTION_TOKEN and found.NOTIFICATION_RATE_LIMIT_PRESSURE)
    assert(found.NOTIFICATION_PAYLOAD_ABUSE)
    return report.status .. ':' .. #report.findings
  `);
  assert.match(result, /^DEGRADED:\d+$/u);
});
