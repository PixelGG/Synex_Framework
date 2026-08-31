import assert from 'node:assert/strict';
import test from 'node:test';
import { notifyServerHarness, runNotifyLua } from './helpers.js';

test('client presentation metrics are exact, session-fenced, idempotent, and bounded', async () => {
  const result = await runNotifyLua<string>(`${notifyServerHarness}
    local session = __notifyTest.addSession(41, 7)
    local registry, service = __notifyTest.makeRegistry()
    local observability = __notifyTest.observability
    local handler = assert(service.contractHandler({
      name = 'synex.notify.metrics.report',
    }))
    local context = {
      source = 41,
      sourceGeneration = 7,
      session = session,
    }
    local counters = {
      created = 3, displayed = 2, removed = 1,
      deduplicated = 4, grouped = 5, suppressed = 6, coalesced = 7,
      queuePromotions = 2, queueEvictions = 1, queueWaitTotalMs = 40,
      renderDispatchSamples = 2, renderDispatchTotalMs = 10,
      renderAckSamples = 2, renderAckTotalMs = 24,
      transportFailures = 1, nativeFallbacks = 0,
      presentationExpired = 1, quietDeferred = 2,
    }
    local first = assert(handler({
      clientEpoch = 1000, sequence = 1, counters = counters,
      gauges = { visible = 2, queued = 3, pendingVisibilityAcks = 1 },
    }, context))
    assert(first.accepted and not first.duplicate and first.nextReportAfterMs == 10000)
    local snapshot = observability.snapshot().clientPresentation
    assert(snapshot.available and snapshot.trust == 'presentation-telemetry-only')
    assert(snapshot.freshSessions == 1 and snapshot.staleSessions == 0)
    assert(snapshot.counters.deduplicated == 0 and snapshot.counters.grouped == 0)
    assert(snapshot.counters.suppressed == 0 and snapshot.counters.coalesced == 0)
    assert(snapshot.gauges.visible == 2 and snapshot.gauges.queued == 3)
    assert(snapshot.averages.queueWaitMs == 0
      and snapshot.averages.renderDispatchMs == 0
      and snapshot.averages.renderAckMs == 0)
    assert(__notifyTest.metrics.synex_notify_client_deduplicated_total == nil
      and __notifyTest.metrics.synex_notify_deduplicated_total == nil)

    local duplicate = assert(observability.reportClient({
      clientEpoch = 1000, sequence = 1, counters = counters,
      gauges = { visible = 2, queued = 3, pendingVisibilityAcks = 1 },
    }, context))
    assert(duplicate.duplicate and observability.snapshot()
      .clientPresentation.reportsAccepted == 1)

    __notifyTest.now = __notifyTest.now + 5000
    local nextCounters = SynexNotifyFoundation.copy(counters)
    nextCounters.deduplicated = 6
    nextCounters.grouped = 8
    nextCounters.queuePromotions = 4
    nextCounters.queueWaitTotalMs = 100
    nextCounters.renderAckSamples = 4
    nextCounters.renderAckTotalMs = 60
    assert(observability.reportClient({
      clientEpoch = 1000, sequence = 2, counters = nextCounters,
      gauges = { visible = 1, queued = 0, pendingVisibilityAcks = 0 },
    }, context))
    snapshot = observability.snapshot().clientPresentation
    assert(snapshot.counters.deduplicated == 2 and snapshot.counters.grouped == 3)
    assert(snapshot.averages.queueWaitMs == 30 and snapshot.averages.renderAckMs == 18)
    assert(__notifyTest.metrics.synex_notify_client_deduplicated_total == 2
      and __notifyTest.metrics.synex_notify_deduplicated_total == 2)

    local _, rateError = observability.reportClient({
      clientEpoch = 1000, sequence = 3, counters = nextCounters,
      gauges = { visible = 0, queued = 0, pendingVisibilityAcks = 0 },
    }, context)
    assert(rateError.code == 'NOTIFY_RATE_LIMITED')

    __notifyTest.now = __notifyTest.now + 5000
    assert(observability.reportClient({
      clientEpoch = 2000, sequence = 1, counters = counters,
      gauges = { visible = 1, queued = 1, pendingVisibilityAcks = 0 },
    }, context))
    assert(observability.snapshot().clientPresentation.counters.deduplicated == 2,
      'a new client epoch establishes a baseline instead of re-adding totals')
    __notifyTest.now = __notifyTest.now + 5000
    local _, staleEpochError = observability.reportClient({
      clientEpoch = 1000, sequence = 4, counters = nextCounters,
      gauges = { visible = 0, queued = 0, pendingVisibilityAcks = 0 },
    }, context)
    assert(staleEpochError.code == 'NOTIFY_TARGET_STALE')

    local invalid = SynexNotifyFoundation.copy(nextCounters)
    invalid.title = 'content must never enter telemetry'
    local _, invalidError = observability.reportClient({
      clientEpoch = 2000, sequence = 2, counters = invalid,
      gauges = { visible = 0, queued = 0, pendingVisibilityAcks = 0 },
    }, context)
    assert(invalidError.code == 'NOTIFY_INVALID_REQUEST')
    local _, sessionError = observability.reportClient({
      clientEpoch = 2000, sequence = 2, counters = nextCounters,
      gauges = { visible = 0, queued = 0, pendingVisibilityAcks = 0 },
    }, { source = 41, sourceGeneration = 8, session = session })
    assert(sessionError.code == 'NOTIFY_TARGET_STALE')

    local reconnected = __notifyTest.addSession(41, 8)
    local reconnectContext = {
      source = 41, sourceGeneration = 8, session = reconnected,
    }
    __notifyTest.now = __notifyTest.now + 5000
    assert(observability.reportClient({
      clientEpoch = 2000, sequence = 3, counters = nextCounters,
      gauges = { visible = 0, queued = 0, pendingVisibilityAcks = 0 },
    }, reconnectContext))
    assert(observability.snapshot().clientPresentation.counters.deduplicated == 2,
      'a new session fence establishes a baseline instead of duplicating totals')

    __notifyTest.now = __notifyTest.now + 5000
    local poisoned = SynexNotifyFoundation.copy(nextCounters)
    poisoned.deduplicated = poisoned.deduplicated
      + SynexNotifyLimits.metricsMaximumCounterDelta + 1
    local _, poisonError = observability.reportClient({
      clientEpoch = 2000, sequence = 4, counters = poisoned,
      gauges = { visible = 0, queued = 0, pendingVisibilityAcks = 0 },
    }, reconnectContext)
    assert(poisonError.code == 'NOTIFY_INVALID_REQUEST')

    for epoch = 3000, 5000, 1000 do
      __notifyTest.now = __notifyTest.now + 5000
      assert(observability.reportClient({
        clientEpoch = epoch, sequence = 1, counters = nextCounters,
        gauges = { visible = 0, queued = 0, pendingVisibilityAcks = 0 },
      }, reconnectContext))
    end
    __notifyTest.now = __notifyTest.now + 5000
    local _, epochRateError = observability.reportClient({
      clientEpoch = 6000, sequence = 1, counters = nextCounters,
      gauges = { visible = 0, queued = 0, pendingVisibilityAcks = 0 },
    }, reconnectContext)
    assert(epochRateError.code == 'NOTIFY_RATE_LIMITED')

    assert(observability.playerDropped(41))
    snapshot = observability.snapshot().clientPresentation
    assert(not snapshot.available and snapshot.reportingSessions == 0)
    return table.concat({ snapshot.counters.deduplicated,
      rateError.code, staleEpochError.code, invalidError.code, sessionError.code }, ':')
  `);
  assert.equal(
    result,
    '2:NOTIFY_RATE_LIMITED:NOTIFY_TARGET_STALE:NOTIFY_INVALID_REQUEST:NOTIFY_TARGET_STALE',
  );
});

test('client presentation availability expires without fabricating live gauges', async () => {
  const result = await runNotifyLua<string>(`${notifyServerHarness}
    local session = __notifyTest.addSession(42, 1)
    local observability = __notifyTest.makeObservability()
    local counters = {
      created = 1, displayed = 1, removed = 0,
      deduplicated = 0, grouped = 0, suppressed = 0, coalesced = 0,
      queuePromotions = 1, queueEvictions = 0, queueWaitTotalMs = 5,
      renderDispatchSamples = 1, renderDispatchTotalMs = 2,
      renderAckSamples = 1, renderAckTotalMs = 3,
      transportFailures = 0, nativeFallbacks = 0,
      presentationExpired = 0, quietDeferred = 0,
    }
    assert(observability.reportClient({
      clientEpoch = 1000, sequence = 1, counters = counters,
      gauges = { visible = 1, queued = 2, pendingVisibilityAcks = 1 },
    }, { source = 42, sourceGeneration = 1, session = session }))
    __notifyTest.now = __notifyTest.now + SynexNotifyLimits.metricsFreshnessMs + 1
    local snapshot = observability.snapshot().clientPresentation
    assert(not snapshot.available and snapshot.freshSessions == 0
      and snapshot.staleSessions == 1)
    assert(snapshot.gauges.visible == 0 and snapshot.gauges.queued == 0
      and snapshot.gauges.pendingVisibilityAcks == 0)
    assert(snapshot.counters.created == 0 and snapshot.lastReportAgeMs > snapshot.freshnessMs)
    return table.concat({ snapshot.available and 'available' or 'stale',
      snapshot.staleSessions, snapshot.counters.created }, ':')
  `);
  assert.equal(result, 'stale:1:0');
});

test('client metric session registry fails closed while fresh and prunes the deterministic stale oldest', async () => {
  const result = await runNotifyLua<string>(`${notifyServerHarness}
    SynexNotifyLimits.maximumClientMetricSessions = 2
    local observability = __notifyTest.makeObservability()
    local counters = {
      created = 0, displayed = 0, removed = 0,
      deduplicated = 0, grouped = 0, suppressed = 0, coalesced = 0,
      queuePromotions = 0, queueEvictions = 0, queueWaitTotalMs = 0,
      renderDispatchSamples = 0, renderDispatchTotalMs = 0,
      renderAckSamples = 0, renderAckTotalMs = 0,
      transportFailures = 0, nativeFallbacks = 0,
      presentationExpired = 0, quietDeferred = 0,
    }
    local function report(source)
      local session = __notifyTest.sessions[source] or __notifyTest.addSession(source, 1)
      return observability.reportClient({
        clientEpoch = 1000 + source, sequence = 1, counters = counters,
        gauges = { visible = 0, queued = 0, pendingVisibilityAcks = 0 },
      }, { source = source, sourceGeneration = 1, session = session })
    end
    assert(report(1))
    assert(report(2))
    local _, fullError = report(3)
    assert(fullError.code == 'NOTIFY_QUEUE_FULL')
    local full = observability.snapshot().clientPresentation
    assert(full.reportingSessions == 2 and full.maximumReportingSessions == 2)

    __notifyTest.now = __notifyTest.now + SynexNotifyLimits.metricsFreshnessMs + 1
    assert(report(3))
    local pruned = observability.snapshot().clientPresentation
    assert(pruned.reportingSessions == 2 and pruned.freshSessions == 1
      and pruned.staleSessions == 1)
    assert(not observability.playerDropped(1),
      'the lexicographically first equally-old session is pruned')
    assert(observability.playerDropped(2) and observability.playerDropped(3))
    return table.concat({ fullError.code, full.reportingSessions,
      pruned.freshSessions, pruned.staleSessions }, ':')
  `);
  assert.equal(result, 'NOTIFY_QUEUE_FULL:2:1:1');
});
