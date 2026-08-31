import assert from 'node:assert/strict';
import test from 'node:test';
import { notifySharedFiles, runNotifyLua } from './helpers.js';

const clientFiles = [
  ...notifySharedFiles,
  'resources/synex_notify/client/engine.lua',
] as const;

const clientHarness = `
  local clock, rendered, removed, observed = 1000, {}, {}, {}
  for _, policy in pairs(SynexNotifyLimits.rateLimits) do
    policy.capacity = 100000
    policy.refillPerSecond = 0
  end
  SynexNotifyLimits.maximumBurst = 100000
  local function createClient(options)
    options = options or {}
    options.now = function() return clock end
    options.upsertSignal = options.upsertSignal or function(descriptor)
      rendered[#rendered + 1] = SynexNotifyValidation.copy(descriptor)
      return { signal = descriptor }
    end
    options.removeSignal = options.removeSignal or function(signalId, revision)
      removed[#removed + 1] = { signalId = signalId, revision = revision }
      return { removed = true }
    end
    options.observe = options.observe or function(name, amount)
      observed[name] = (observed[name] or 0) + (amount or 1)
    end
    return SynexNotifyEngine.create(options)
  end
  local function localValue(value)
    value.title = value.title or 'Client signal'
    return assert(SynexNotifyValidation.canonicalNotification(value, {
      authority = 'CLIENT',
    }))
  end
  local function serverValue(id, value)
    value.notificationId = id
    value.revision = value.revision or 1
    value.kind = value.kind or 'toast'
    value.tone = value.tone or 'neutral'
    value.priority = value.priority or 'normal'
    value.title = value.title or 'Server signal'
    value.createdAt = value.createdAt or clock
    value.position = value.position or 'top-right'
    value.origin = 'SERVER'
    return assert(SynexNotifyValidation.canonicalPresentation(value, {
      authority = 'SERVER',
    }))
  end
`;

test('client queue promotes by priority, owner fairness, age, and FIFO-safe sequence', async () => {
  const result = await runNotifyLua<string>(`${clientHarness}
    local notify = createClient()
    local visibleHandles = {}
    for index = 1, 4 do
      visibleHandles[index] = assert(notify.show('owner.fill', 1, localValue({
        kind = 'persistent', priority = 'low', title = ('Visible %d'):format(index),
      })))
    end
    local sameOwner = assert(notify.show('owner.fill', 1, localValue({
      kind = 'persistent', priority = 'low', title = 'Same owner queued',
    })))
    assert(notify.show('owner.other', 1, localValue({
      kind = 'persistent', priority = 'low', title = 'Other owner promoted',
    })))
    assert(notify.snapshot().visible == 4 and notify.snapshot().queued == 2)
    assert(notify.dismiss(visibleHandles[1]))
    assert(rendered[#rendered].title == 'Other owner promoted')
    assert(notify.dismiss(sameOwner))

    assert(notify.show('owner.old', 1, localValue({
      kind = 'persistent', priority = 'low', title = 'Aged low priority',
    })))
    clock = 15000
    assert(notify.show('owner.new', 1, localValue({
      kind = 'persistent', priority = 'normal', title = 'New normal priority',
    })))
    assert(notify.dismiss(visibleHandles[2]))
    assert(rendered[#rendered].title == 'Aged low priority')
    assert((observed.queue_wait_ms or 0) >= 14000)
    assert((observed.queue_promotions or 0) >= 6)
    return rendered[#rendered].title .. ':' .. notify.snapshot().visible
  `, clientFiles);
  assert.equal(result, 'Aged low priority:4');
});

test('adaptive visible capacity demotes lower priority records and restarts queued lifetime on promotion', async () => {
  const result = await runNotifyLua<string>(`${clientHarness}
    local notify = createClient()
    assert(notify.applyServer('owner.capacity', 1,
      serverValue('adaptive-low', {
        kind = 'toast', priority = 'low', title = 'Adaptive low', durationMs = 1500,
      }), 'show'))
    assert(notify.applyServer('owner.capacity', 1,
      serverValue('adaptive-normal', {
        kind = 'toast', priority = 'normal', title = 'Adaptive normal', durationMs = 1500,
      }), 'show'))
    assert(notify.applyServer('owner.capacity', 1,
      serverValue('adaptive-high', {
        kind = 'persistent', priority = 'high', title = 'Adaptive high',
      }), 'show'))
    assert(notify.applyServer('owner.capacity', 1,
      serverValue('adaptive-critical', {
        kind = 'persistent', priority = 'critical', title = 'Adaptive critical',
      }), 'show'))

    local ids = {}
    for _, descriptor in ipairs(rendered) do ids[descriptor.title] = descriptor.signalId end
    local initial = notify.snapshot()
    assert(initial.visibleCapacity == 4 and initial.visible == 4 and initial.queued == 0)

    local below, belowError = notify.setVisibleCapacity(0)
    assert(below == nil and belowError.code == 'NOTIFY_INVALID_REQUEST')
    local above, aboveError = notify.setVisibleCapacity(5)
    assert(above == nil and aboveError.code == 'NOTIFY_INVALID_REQUEST')

    local removalStart = #removed
    local constrained = assert(notify.setVisibleCapacity(2))
    assert(constrained.visibleCapacity == 2)
    local constrainedSnapshot = notify.snapshot()
    assert(constrainedSnapshot.visibleCapacity == 2)
    assert(constrainedSnapshot.visible == 2 and constrainedSnapshot.queued == 2)
    local staleAck, staleAckError = notify.confirmVisibility({
      generation = 0, visibilityGeneration = 0, visibilityRevision = 1,
      visibleCapacity = 2, visibilityCapacity = 4, signals = {},
    })
    assert(staleAck == nil and staleAckError.code == 'NOTIFY_UI_UNAVAILABLE')
    local demoted = {}
    for index = removalStart + 1, #removed do demoted[removed[index].signalId] = true end
    assert(demoted[ids['Adaptive low']] == true)
    assert(demoted[ids['Adaptive normal']] == true)
    assert(demoted[ids['Adaptive high']] ~= true)
    assert(demoted[ids['Adaptive critical']] ~= true)

    clock = 6000
    notify.tick()
    assert(notify.snapshot().visible == 2 and notify.snapshot().queued == 2)
    local restored = assert(notify.setVisibleCapacity(4))
    assert(restored.visibleCapacity == 4)
    local restoredSnapshot = notify.snapshot()
    assert(restoredSnapshot.visibleCapacity == 4)
    assert(restoredSnapshot.visible == 4 and restoredSnapshot.queued == 0)

    clock = 7499
    notify.tick()
    assert(notify.snapshot().visible == 4)
    clock = 7500
    notify.tick()
    local expired = notify.snapshot()
    assert(expired.visibleCapacity == 4 and expired.visible == 2 and expired.queued == 0)
    return table.concat({ constrainedSnapshot.visible, constrainedSnapshot.queued,
      restoredSnapshot.visible, expired.visible }, ':')
  `, clientFiles);
  assert.equal(result, '2:2:4:2');
});

test('client queue rejects equal urgency at capacity and evicts oldest lower urgency only', async () => {
  const result = await runNotifyLua<string>(`${clientHarness}
    local notify = createClient()
    for index = 1, SynexNotifyLimits.maximumQueue do
      assert(notify.show('owner.capacity', 1, localValue({
        kind = 'persistent', priority = 'low', title = ('Low %03d'):format(index),
      })))
    end
    local before = notify.snapshot()
    assert(before.records == 128 and before.visible == 4 and before.queued == 124)
    local _, equalError = notify.show('owner.capacity', 1, localValue({
      kind = 'persistent', priority = 'low', title = 'Equal urgency rejected',
    }))
    assert(equalError.code == 'NOTIFY_QUEUE_FULL')
    local admitted = assert(notify.show('owner.capacity', 1, localValue({
      kind = 'persistent', priority = 'normal', title = 'Higher urgency admitted',
    })))
    local after = notify.snapshot()
    assert(after.records == 128 and after.visible == 4 and after.queued == 124)
    assert(rendered[#rendered].title == 'Higher urgency admitted')
    local latest = notify.history('owner.capacity', 1)[1]
    assert(latest.reason == 'queue_evicted' and latest.state == 'EVICTED')
    assert((observed.queue_evictions or 0) == 1)
    return table.concat({ equalError.code, admitted.revision,
      after.records, latest.reason }, ':')
  `, clientFiles);
  assert.equal(result, 'NOTIFY_QUEUE_FULL:1:128:queue_evicted');
});

test('client dedupe policies and grouping isolate authority and presentation semantics', async () => {
  const result = await runNotifyLua<string>(`${clientHarness}
    local notify = createClient()
    local suppressA = assert(notify.show('owner.dedupe', 1, localValue({
      title = 'Suppress A', dedupeKey = 'suppress', dedupePolicy = 'suppress',
    })))
    local suppressB = assert(notify.show('owner.dedupe', 1, localValue({
      title = 'Suppress B', dedupeKey = 'suppress', dedupePolicy = 'suppress',
    })))
    assert(suppressA.notificationId == suppressB.notificationId and suppressB.revision == 1)

    local countA = assert(notify.show('owner.dedupe', 1, localValue({
      title = 'Count', dedupeKey = 'count', dedupePolicy = 'count',
    })))
    local countB = assert(notify.show('owner.dedupe', 1, localValue({
      title = 'Count', dedupeKey = 'count', dedupePolicy = 'count',
    })))
    assert(countA.notificationId == countB.notificationId and countB.revision == 2)

    local replaceA = assert(notify.show('owner.dedupe', 1, localValue({
      title = 'Replace A', dedupeKey = 'replace', dedupePolicy = 'replace',
    })))
    local replaceB = assert(notify.show('owner.dedupe', 1, localValue({
      title = 'Replace B', dedupeKey = 'replace', dedupePolicy = 'replace',
    })))
    assert(replaceA.notificationId == replaceB.notificationId and replaceB.revision == 2)

    local refreshA = assert(notify.show('owner.dedupe', 1, localValue({
      title = 'Refresh', dedupeKey = 'refresh', dedupePolicy = 'refresh',
    })))
    clock = 1500
    local refreshB = assert(notify.show('owner.dedupe', 1, localValue({
      title = 'Refresh', dedupeKey = 'refresh', dedupePolicy = 'refresh',
    })))
    assert(refreshA.notificationId == refreshB.notificationId and refreshB.revision == 2)

    local groupInfoA = assert(notify.show('owner.group', 1, localValue({
      title = 'Info A', tone = 'info', groupKey = 'safe-group',
    })))
    local groupInfoB = assert(notify.show('owner.group', 1, localValue({
      title = 'Info B', tone = 'info', groupKey = 'safe-group',
    })))
    local groupDanger = assert(notify.show('owner.group', 1, localValue({
      title = 'Danger', tone = 'danger', groupKey = 'safe-group',
    })))
    assert(groupInfoA.notificationId == groupInfoB.notificationId)
    assert(groupInfoB.revision == 2 and groupDanger.notificationId ~= groupInfoA.notificationId)

    local server = assert(notify.applyServer('owner.dedupe', 1,
      serverValue('server-dedupe-isolation', {
        dedupeKey = 'suppress', dedupePolicy = 'suppress',
      }), 'show'))
    assert(server.notificationId == 'server-dedupe-isolation')
    assert(notify.snapshot().records == 7)
    assert((observed.deduplicated or 0) == 4)
    assert((observed.suppressed or 0) == 1 and (observed.grouped or 0) == 1)
    return table.concat({ suppressB.revision, countB.revision, replaceB.revision,
      refreshB.revision, groupInfoB.revision, notify.snapshot().records }, ':')
  `, clientFiles);
  assert.equal(result, '1:2:2:2:2:7');
});

test('dedupe replacement removes a stale group index for local and server presentations', async () => {
  const result = await runNotifyLua<string>(`${clientHarness}
    local notify = createClient()
    local first = assert(notify.show('owner.local-replace', 1, localValue({
      title = 'Grouped first', dedupeKey = 'replace-key',
      dedupePolicy = 'replace', groupKey = 'old-group',
    })))
    local replaced = assert(notify.show('owner.local-replace', 1, localValue({
      title = 'Ungrouped replacement', dedupeKey = 'replace-key',
      dedupePolicy = 'replace',
    })))
    assert(first.notificationId == replaced.notificationId)
    local freshGroup = assert(notify.show('owner.local-replace', 1, localValue({
      title = 'Fresh group representative', groupKey = 'old-group',
    })))
    assert(freshGroup.notificationId ~= first.notificationId)
    assert(notify.snapshot().records == 2)

    assert(notify.applyServer('owner.server-replace', 1,
      serverValue('server-replace-one', {
        title = 'Server grouped first', dedupeKey = 'server-replace-key',
        dedupePolicy = 'replace', groupKey = 'server-old-group',
      }), 'show'))
    assert(notify.applyServer('owner.server-replace', 1,
      serverValue('server-replace-two', {
        title = 'Server ungrouped replacement', dedupeKey = 'server-replace-key',
        dedupePolicy = 'replace',
      }), 'show'))
    assert(notify.applyServer('owner.server-replace', 1,
      serverValue('server-replace-three', {
        title = 'Server fresh group representative', groupKey = 'server-old-group',
      }), 'show'))
    assert(notify.snapshot().records == 4)
    return table.concat({ tostring(first.notificationId == replaced.notificationId),
      tostring(first.notificationId ~= freshGroup.notificationId),
      notify.snapshot().records }, ':')
  `, clientFiles);
  assert.equal(result, 'true:true:4');
});

test('critical fallback activates once when CEF acceptance has no visibility acknowledgement', async () => {
  const result = await runNotifyLua<string>(`${clientHarness}
    local fallbacks = {}
    local notify = createClient({
      nativeFallback = function(descriptor)
        fallbacks[#fallbacks + 1] = descriptor.title
        return true
      end,
    })
    assert(notify.applyServer('owner.critical', 1,
      serverValue('critical-visibility-timeout', {
        title = 'Critical without browser ACK', priority = 'critical',
      }), 'show'))
    local first = rendered[#rendered]
    local firstDeadline = assert(notify.nextDeadline())
    assert(firstDeadline == clock + SynexNotifyLimits.uiVisibilityAckTimeoutMs)
    clock = firstDeadline - 1
    notify.tick()
    assert(#fallbacks == 0)
    clock = firstDeadline
    notify.tick()
    notify.tick()
    assert(#fallbacks == 1 and fallbacks[1] == 'Critical without browser ACK')

    assert(notify.applyServer('owner.critical', 1,
      serverValue('critical-visibility-timeout', {
        revision = 2, title = 'Critical update acknowledged', priority = 'critical',
      }), 'update'))
    local updated = rendered[#rendered]
    assert(notify.confirmVisibility({
      generation = 2, visibilityGeneration = 2, visibilityRevision = 2,
      signals = {{ signalId = updated.signalId, revision = updated.revision,
        visible = true }},
    }))
    clock = clock + SynexNotifyLimits.uiVisibilityAckTimeoutMs
    notify.tick()
    assert(#fallbacks == 1)
    return table.concat({ #fallbacks, observed.visibility_ack_timeouts or 0,
      observed.native_fallbacks or 0 }, ':')
  `, clientFiles);
  assert.equal(result, '1:1:1');
});

test('replace deduplication clears stale aggregate counts for local and server presentations', async () => {
  const result = await runNotifyLua<string>(`${clientHarness}
    local notify = createClient()
    assert(notify.show('owner.replace-count', 1, localValue({
      title = 'Local count', dedupeKey = 'local-count', dedupePolicy = 'count',
    })))
    assert(notify.show('owner.replace-count', 1, localValue({
      title = 'Local count', dedupeKey = 'local-count', dedupePolicy = 'count',
    })))
    assert(rendered[#rendered].count == 2)
    assert(notify.show('owner.replace-count', 1, localValue({
      title = 'Local replacement', dedupeKey = 'local-count', dedupePolicy = 'replace',
    })))
    assert(rendered[#rendered].title == 'Local replacement')
    assert(rendered[#rendered].count == nil)

    assert(notify.applyServer('owner.server-replace', 1,
      serverValue('server-count-a', {
        title = 'Server count', dedupeKey = 'server-count', dedupePolicy = 'count',
      }), 'show'))
    assert(notify.applyServer('owner.server-replace', 1,
      serverValue('server-count-b', {
        title = 'Server count', dedupeKey = 'server-count', dedupePolicy = 'count',
      }), 'show'))
    assert(rendered[#rendered].count == 2)
    assert(notify.applyServer('owner.server-replace', 1,
      serverValue('server-count-c', {
        title = 'Server replacement', dedupeKey = 'server-count', dedupePolicy = 'replace',
      }), 'show'))
    assert(rendered[#rendered].title == 'Server replacement')
    assert(rendered[#rendered].count == nil)
    return rendered[#rendered].title
  `, clientFiles);
  assert.equal(result, 'Server replacement');
});

test('client progress supports pending, running, determinate, indeterminate, and all terminal states', async () => {
  const result = await runNotifyLua<string>(`${clientHarness}
    local notify = createClient()
    local success = assert(notify.show('owner.progress', 1, localValue({
      kind = 'progress', title = 'Determinate', progress = {
        state = 'PENDING', mode = 'determinate', value = 0, maximum = 10,
      },
    })))
    success = assert(notify.update(success,
      assert(SynexNotifyValidation.notificationPatch({ progress = {
        state = 'RUNNING', mode = 'determinate', value = 5, maximum = 10,
      } }, { authority = 'CLIENT', kind = 'progress' }))))
    local _, backwardsError = notify.update(success,
      assert(SynexNotifyValidation.notificationPatch({ progress = {
        state = 'RUNNING', mode = 'determinate', value = 4, maximum = 10,
      } }, { authority = 'CLIENT', kind = 'progress' })))
    assert(backwardsError.code == 'NOTIFY_NOTIFICATION_STALE')
    success = assert(notify.complete(success, 'SUCCESS', 'Finished'))

    local failed = assert(notify.show('owner.progress', 1, localValue({
      kind = 'progress', title = 'Indeterminate failure', progress = {
        state = 'RUNNING', mode = 'indeterminate',
      },
    })))
    failed = assert(notify.complete(failed, 'FAILED', 'Failed safely'))
    local cancelled = assert(notify.show('owner.progress', 1, localValue({
      kind = 'progress', title = 'Cancellation', progress = {
        state = 'PENDING', mode = 'indeterminate',
      },
    })))
    cancelled = assert(notify.complete(cancelled, 'CANCELLED', 'Cancelled safely'))

    local _, terminalError = notify.update(success,
      assert(SynexNotifyValidation.notificationPatch({ progress = {
        state = 'RUNNING', mode = 'determinate', value = 10, maximum = 10,
      } }, { authority = 'CLIENT', kind = 'progress' })))
    assert(terminalError.code == 'NOTIFY_NOTIFICATION_STALE')
    local states = {}
    for _, descriptor in ipairs(rendered) do
      if descriptor.progress then states[descriptor.progress.state] = true end
    end
    assert(states.PENDING and states.RUNNING and states.SUCCESS
      and states.FAILED and states.CANCELLED)
    return backwardsError.code .. ':' .. terminalError.code
  `, clientFiles);
  assert.equal(result, 'NOTIFY_NOTIFICATION_STALE:NOTIFY_NOTIFICATION_STALE');
});

test('dedupe and grouping windows restart after expiry and rejected admission cannot move them', async () => {
  const result = await runNotifyLua<string>(`${clientHarness}
    local function exercise(notify, server)
      SynexNotifyLimits.rateLimits.global = { capacity = 1, refillPerSecond = 0 }
      clock = 1000
      local first
      if server then
        first = assert(notify.applyServer('owner.window', 1,
          serverValue('window-a', { dedupeKey = 'window', dedupePolicy = 'count' }), 'show'))
      else
        first = assert(notify.show('owner.window', 1,
          localValue({ dedupeKey = 'window', dedupePolicy = 'count' })))
      end
      clock = 2000
      local denied, deniedError
      if server then
        denied, deniedError = notify.applyServer('owner.window', 1,
          serverValue('window-b', { dedupeKey = 'window', dedupePolicy = 'count' }), 'show')
      else
        denied, deniedError = notify.show('owner.window', 1,
          localValue({ dedupeKey = 'window', dedupePolicy = 'count' }))
      end
      assert(denied == nil and deniedError.code == 'NOTIFY_RATE_LIMITED')
      SynexNotifyLimits.rateLimits.global = { capacity = 2, refillPerSecond = 1 }
      clock = 3001
      local nextValue
      if server then
        nextValue = assert(notify.applyServer('owner.window', 1,
          serverValue('window-c', { dedupeKey = 'window', dedupePolicy = 'count' }), 'show'))
      else
        nextValue = assert(notify.show('owner.window', 1,
          localValue({ dedupeKey = 'window', dedupePolicy = 'count' })))
      end
      assert(nextValue.notificationId ~= first.notificationId)
      clock = 4002
      local grouped
      if server then
        grouped = assert(notify.applyServer('owner.window', 1,
          serverValue('window-d', { dedupeKey = 'window', dedupePolicy = 'count' }), 'show'))
      else
        grouped = assert(notify.show('owner.window', 1,
          localValue({ dedupeKey = 'window', dedupePolicy = 'count' })))
      end
      assert(notify.snapshot().records == 2)
      return nextValue.notificationId, grouped.notificationId
    end
    local localEngine = createClient()
    local localNext, localGrouped = exercise(localEngine, false)
    local serverEngine = createClient()
    local serverNext, serverGrouped = exercise(serverEngine, true)
    assert(localNext == localGrouped and serverNext == 'window-c')
    assert(serverGrouped == 'window-d')
    return localEngine.snapshot().records .. ':' .. serverEngine.snapshot().records
  `, clientFiles);
  assert.equal(result, '2:2');
});

test('mixed dedupe/group lookup and tone reindexing keep exactly one compatible representative', async () => {
  const result = await runNotifyLua<string>(`${clientHarness}
    local notify = createClient()
    local mixedA = assert(notify.show('owner.mixed', 1, localValue({
      title = 'Mixed A', tone = 'info', dedupeKey = 'dedupe-a',
      dedupePolicy = 'count', groupKey = 'mixed-group',
    })))
    local mixedB = assert(notify.show('owner.mixed', 1, localValue({
      title = 'Mixed B', tone = 'info', dedupeKey = 'dedupe-b',
      dedupePolicy = 'count', groupKey = 'mixed-group',
    })))
    assert(mixedA.notificationId == mixedB.notificationId and mixedB.revision == 2)

    local toneBase = assert(notify.show('owner.tone', 1, localValue({
      title = 'Tone base', tone = 'success', groupKey = 'tone-group',
    })))
    toneBase = assert(notify.update(toneBase,
      assert(SynexNotifyValidation.notificationPatch({ tone = 'warning' },
        { authority = 'CLIENT' }))))
    local oldTone = assert(notify.show('owner.tone', 1, localValue({
      title = 'New success representative', tone = 'success', groupKey = 'tone-group',
    })))
    local newTone = assert(notify.show('owner.tone', 1, localValue({
      title = 'Groups with warning', tone = 'warning', groupKey = 'tone-group',
    })))
    assert(oldTone.notificationId ~= toneBase.notificationId)
    assert(newTone.notificationId == toneBase.notificationId and newTone.revision == 3)
    assert(notify.snapshot().records == 3)
    return mixedB.revision .. ':' .. newTone.revision .. ':' .. notify.snapshot().records
  `, clientFiles);
  assert.equal(result, '2:3:3');
});

test('duration starts on promotion, ordinary updates do not refresh it, and dormant server state revives', async () => {
  const result = await runNotifyLua<string>(`${clientHarness}
    local notify = createClient()
    local blockers = {}
    for index = 1, 4 do
      blockers[index] = assert(notify.show('owner.blocker', 1, localValue({
        kind = 'persistent', title = ('Blocker %d'):format(index),
      })))
    end
    assert(notify.applyServer('owner.server', 1, serverValue('queued-short', {
      title = 'Queued short', durationMs = 1500, maxLifetimeMs = 10000,
    }), 'show'))
    clock = 5000
    notify.tick()
    assert(notify.snapshot().queued == 1 and notify.snapshot().records == 5)
    assert(notify.dismiss(blockers[1]))
    assert(rendered[#rendered].title == 'Queued short')
    clock = 6500
    notify.tick()
    assert(notify.snapshot().visible == 3 and notify.snapshot().records == 4)
    assert((observed.presentation_expired or 0) == 1)
    assert(notify.applyServer('owner.server', 1, serverValue('queued-short', {
      revision = 2, title = 'Revived short', message = 'Full authoritative update',
      durationMs = 1500, maxLifetimeMs = 10000,
    }), 'update'))
    assert(rendered[#rendered].title == 'Revived short')
    clock = 7000
    assert(notify.applyServer('owner.server', 1, serverValue('queued-short', {
      revision = 3, title = 'Revived short', message = 'Does not extend duration',
      durationMs = 1500, maxLifetimeMs = 10000,
    }), 'update'))
    clock = 8000
    notify.tick()
    assert(notify.snapshot().visible == 3 and notify.snapshot().records == 4)
    return table.concat({ observed.presentation_expired or 0,
      notify.snapshot().visible, notify.snapshot().records }, ':')
  `, clientFiles);
  assert.equal(result, '2:3:4');
});

test('dormant capacity eviction retains a bounded server revision tombstone for revival', async () => {
  const result = await runNotifyLua<string>(`${clientHarness}
    SynexNotifyLimits.maximumQueue = 4
    SynexNotifyLimits.maximumVisible = 4
    local notify = createClient()
    for index = 1, 4 do
      assert(notify.applyServer('owner.capacity-server', 1,
        serverValue(('dormant-%d'):format(index), {
          title = ('Dormant %d'):format(index), durationMs = 1500,
          maxLifetimeMs = 10000,
        }), 'show'))
    end
    clock = 2500
    notify.tick()
    assert(notify.snapshot().records == 4 and notify.snapshot().visible == 0)
    assert(notify.applyServer('owner.capacity-server', 1,
      serverValue('replacement', {
        title = 'Capacity replacement', durationMs = 1500, maxLifetimeMs = 10000,
      }), 'show'))
    assert(notify.snapshot().records == 4 and notify.snapshot().serverTombstones == 1)
    assert(notify.applyServer('owner.capacity-server', 1,
      serverValue('dormant-1', {
        revision = 2, title = 'Evicted record revived', durationMs = 1500,
        maxLifetimeMs = 10000,
      }), 'update'))
    assert(rendered[#rendered].title == 'Evicted record revived')
    assert(notify.snapshot().records == 4 and notify.snapshot().serverTombstones == 1)
    return rendered[#rendered].title .. ':' .. notify.snapshot().serverTombstones
  `, clientFiles);
  assert.equal(result, 'Evicted record revived:1');
});

test('tombstone revival reuses dedupe and group representatives instead of splitting aliases', async () => {
  const result = await runNotifyLua<string>(`${clientHarness}
    SynexNotifyLimits.maximumQueue = 2
    SynexNotifyLimits.maximumVisible = 2
    local notify = createClient()
    assert(notify.applyServer('owner.alias', 1, serverValue('group-alias-a', {
      title = 'Alias A', groupKey = 'inventory.received', durationMs = 1500,
      maxLifetimeMs = 10000,
    }), 'show'))
    assert(notify.applyServer('owner.alias', 1, serverValue('group-alias-b', {
      title = 'Alias B', groupKey = 'inventory.received', durationMs = 1500,
      maxLifetimeMs = 10000,
    }), 'show'))
    assert(notify.snapshot().records == 1)
    clock = 2500
    notify.tick()
    for index = 1, 2 do
      assert(notify.applyServer('owner.fill', 1, serverValue(('fill-item-%d'):format(index), {
        title = ('Low fill %d'):format(index), priority = 'low', maxLifetimeMs = 10000,
      }), 'show'))
    end
    assert(notify.snapshot().records == 2 and notify.snapshot().serverTombstones == 2)

    assert(notify.applyServer('owner.alias', 1, serverValue('group-alias-a', {
      revision = 2, title = 'Alias A revived', groupKey = 'inventory.received',
      durationMs = 1500, maxLifetimeMs = 10000,
    }), 'update'))
    assert(notify.applyServer('owner.alias', 1, serverValue('group-alias-b', {
      revision = 2, title = 'Alias B merged', groupKey = 'inventory.received',
      durationMs = 1500, maxLifetimeMs = 10000,
    }), 'update'))
    local latest = rendered[#rendered]
    assert(notify.snapshot().records == 2 and latest.signalId == 'group-alias-a')
    assert(latest.count == 2 and latest.title == 'Alias B merged')
    return table.concat({ notify.snapshot().records, latest.signalId,
      latest.count, notify.snapshot().serverTombstones }, ':')
  `, clientFiles);
  assert.equal(result, '2:group-alias-a:2:0');
});

test('a revived and re-evicted server record keeps its newest tombstone generation', async () => {
  const result = await runNotifyLua<string>(`${clientHarness}
    SynexNotifyLimits.maximumQueue = 2
    SynexNotifyLimits.maximumVisible = 2
    SynexNotifyLimits.maximumServerNotifications = 2
    local notify = createClient()
    assert(notify.applyServer('owner.tombstone-generation', 1,
      serverValue('generation-a', {
        title = 'Generation A', durationMs = 1500, maxLifetimeMs = 10000,
      }), 'show'))
    assert(notify.applyServer('owner.tombstone-generation', 1,
      serverValue('generation-c', {
        title = 'Generation C', durationMs = 1500, maxLifetimeMs = 10000,
      }), 'show'))
    clock = 2500
    notify.tick()
    assert(notify.applyServer('owner.fill-one', 1, serverValue('generation-fill-1', {
      title = 'Fill one', priority = 'low', durationMs = 1500,
      maxLifetimeMs = 10000,
    }), 'show'))
    assert(notify.applyServer('owner.tombstone-generation', 1,
      serverValue('generation-a', {
        revision = 2, title = 'Generation A revived', priority = 'critical',
        durationMs = 1500, maxLifetimeMs = 10000,
      }), 'update'))

    clock = 4000
    notify.tick()
    assert(notify.applyServer('owner.fill-two', 1, serverValue('generation-fill-2', {
      title = 'Fill two', priority = 'low', durationMs = 1500,
      maxLifetimeMs = 10000,
    }), 'show'))
    assert(notify.snapshot().serverTombstones == 2)
    assert(notify.applyServer('owner.fill-three', 1,
      serverValue('generation-fill-3', {
        title = 'Fill three', priority = 'low', durationMs = 1500,
        maxLifetimeMs = 10000,
      }), 'show'))
    assert(notify.snapshot().serverTombstones == 2)

    local revived, reviveError = notify.applyServer(
      'owner.tombstone-generation', 1, serverValue('generation-a', {
        revision = 3, title = 'Newest tombstone survived', priority = 'critical',
        durationMs = 1500, maxLifetimeMs = 10000,
      }), 'update')
    assert(revived ~= nil and reviveError == nil)
    assert(rendered[#rendered].title == 'Newest tombstone survived')
    return rendered[#rendered].title
  `, clientFiles);
  assert.equal(result, 'Newest tombstone survived');
});

test('owner epochs are authority-scoped and stale cleanup cannot remove a newer incarnation', async () => {
  const result = await runNotifyLua<string>(`${clientHarness}
    local notify = createClient()
    assert(notify.show('owner.epoch', 2, localValue({
      kind = 'persistent', title = 'Local epoch two',
    })))
    assert(notify.applyServer('owner.epoch', 5, serverValue('server-epoch-five', {
      kind = 'persistent', title = 'Server epoch five',
    }), 'show'))
    assert(notify.snapshot().records == 2)
    assert(notify.applyServer('owner.epoch', 6, serverValue('server-epoch-six', {
      kind = 'persistent', title = 'Server epoch six',
    }), 'show'))
    assert(notify.snapshot().records == 2)
    local stale, staleError = notify.applyServer('owner.epoch', 5,
      serverValue('server-epoch-stale', { kind = 'persistent' }), 'show')
    assert(stale == nil and staleError.code == 'NOTIFY_OWNER_STALE')
    local oldCleanup = notify.ownerStop('owner.epoch', 5, 'SERVER')
    assert(oldCleanup.removed == 0 and notify.snapshot().records == 2)
    assert(notify.show('owner.epoch', 3, localValue({
      kind = 'persistent', title = 'Local epoch three',
    })))
    assert(notify.snapshot().records == 2)
    return staleError.code .. ':' .. oldCleanup.removed .. ':' .. notify.snapshot().records
  `, clientFiles);
  assert.equal(result, 'NOTIFY_OWNER_STALE:0:2');
});

test('server tombstone hard expiry arms the client deadline and removes stale recovery state', async () => {
  const result = await runNotifyLua<string>(`${clientHarness}
    SynexNotifyLimits.maximumQueue = 1
    SynexNotifyLimits.maximumVisible = 1
    local notify = createClient()
    assert(notify.applyServer('owner.timer', 1, serverValue('timer-victim', {
      title = 'Timer victim', durationMs = 1500, maxLifetimeMs = 3000,
    }), 'show'))
    clock = 2500
    notify.tick()
    assert(notify.applyServer('owner.timer-fill', 1, serverValue('timer-fill', {
      kind = 'persistent', title = 'Timer fill', maxLifetimeMs = 10000,
    }), 'show'))
    assert(notify.snapshot().serverTombstones == 1 and notify.nextDeadline() == 4000)
    clock = 4000
    notify.tick()
    assert(notify.snapshot().serverTombstones == 0)
    return notify.snapshot().serverTombstones
  `, clientFiles);
  assert.equal(result, 0);
});

test('only browser-confirmed action surfaces receive shortcuts and invocation follows the same selector', async () => {
  const result = await runNotifyLua<string>(`${clientHarness}
    local notify = createClient()
    local calls = {}
    local first = assert(notify.show('owner.actions', 1, localValue({
      title = 'First action', actions = {{ id = 'go', label = 'First' }},
    })))
    local second = assert(notify.show('owner.actions', 1, localValue({
      title = 'Second action', actions = {{ id = 'go', label = 'Second' }},
    })))
    assert(notify.onAction(first, 'go', function() calls[#calls + 1] = 'first'; return true end))
    assert(notify.onAction(second, 'go', function() calls[#calls + 1] = 'second'; return true end))
    local function latest(title)
      for index = #rendered, 1, -1 do
        if rendered[index].title == title then return rendered[index] end
      end
    end
    local firstView, secondView = assert(latest('First action')), assert(latest('Second action'))
    assert(#(firstView.actions or {}) == 0 and #(secondView.actions or {}) == 0)
    local blocked, blockedError = notify.invokeVisibleAction(1)
    assert(blocked == nil and blockedError.code == 'NOTIFY_ACTION_NOT_FOUND')
    assert(notify.confirmVisibility({
      generation = 1, visibilityGeneration = 1, visibilityRevision = 1, signals = {
        { signalId = firstView.signalId, revision = firstView.revision, visible = true },
        { signalId = secondView.signalId, revision = secondView.revision, visible = true },
      },
    }))
    firstView, secondView = assert(latest('First action')), assert(latest('Second action'))
    assert(#(firstView.actions or {}) == 1 and #(secondView.actions or {}) == 0)
    blocked, blockedError = notify.invokeVisibleAction(1)
    assert(blocked == nil and blockedError.code == 'NOTIFY_ACTION_NOT_FOUND')
    assert(notify.confirmVisibility({
      generation = 2, visibilityGeneration = 2, visibilityRevision = 2, signals = {
        { signalId = firstView.signalId, revision = firstView.revision, visible = true },
        { signalId = secondView.signalId, revision = secondView.revision, visible = true },
      },
    }))
    assert(notify.invokeVisibleAction(1))
    assert(calls[1] == 'first')
    firstView, secondView = assert(latest('First action')), assert(latest('Second action'))
    assert(#(firstView.actions or {}) == 0 and #(secondView.actions or {}) == 1)
    assert(secondView.actions[1].hint == nil)
    clock = clock + SynexNotifyLimits.actionMinimumIntervalMs
    assert(notify.confirmVisibility({
      generation = 3, visibilityGeneration = 3, visibilityRevision = 3, signals = {
        { signalId = firstView.signalId, revision = firstView.revision, visible = true },
        { signalId = secondView.signalId, revision = secondView.revision, visible = true },
      },
    }))
    assert(notify.invokeVisibleAction(1))
    assert(calls[2] == 'second')
    return table.concat(calls, ':')
  `, clientFiles);
  assert.equal(result, 'first:second');
});

test('replaced actions stay hidden until the replacement surface is acknowledged', async () => {
  const result = await runNotifyLua<string>(`${clientHarness}
    local invocations = {}
    local notify = createClient({
      invokeServerAction = function(token)
        invocations[#invocations + 1] = token
        return { accepted = true }
      end,
    })
    assert(notify.applyServer('owner.replacement', 1,
      serverValue('replace-actions', {
        title = 'Original actions',
        actions = {{ token = 'server-action-token-original-0001',
          label = 'Original', ttlMs = 30000 }},
      }), 'show'))
    local initial = rendered[#rendered]
    assert(initial.actions == nil)
    assert(notify.confirmVisibility({
      generation = 1, visibilityGeneration = 1, visibilityRevision = 1,
      signals = {{ signalId = initial.signalId, revision = initial.revision,
        visible = true }},
    }))
    local projectedOriginal = rendered[#rendered]
    assert(projectedOriginal.actions[1].label == 'Original')
    assert(notify.confirmVisibility({
      generation = 2, visibilityGeneration = 2, visibilityRevision = 2,
      signals = {{ signalId = projectedOriginal.signalId,
        revision = projectedOriginal.revision, visible = true }},
    }))

    assert(notify.applyServer('owner.replacement', 1,
      serverValue('replace-actions', {
        revision = 2,
        title = 'Replacement actions',
        actions = {{ token = 'server-action-token-replacement-0002',
          label = 'Replacement', ttlMs = 30000 }},
      }), 'update'))
    local replacementBaseline = rendered[#rendered]
    assert(replacementBaseline.title == 'Replacement actions')
    assert(replacementBaseline.actions == nil)
    local blocked, blockedError = notify.invokeVisibleAction(1)
    assert(blocked == nil and blockedError.code == 'NOTIFY_ACTION_NOT_FOUND')

    assert(notify.confirmVisibility({
      generation = 3, visibilityGeneration = 3, visibilityRevision = 3,
      signals = {{ signalId = replacementBaseline.signalId,
        revision = replacementBaseline.revision, visible = true }},
    }))
    local projectedReplacement = rendered[#rendered]
    assert(projectedReplacement.actions[1].label == 'Replacement')
    assert(projectedReplacement.revision > replacementBaseline.revision)
    blocked, blockedError = notify.invokeVisibleAction(1)
    assert(blocked == nil and blockedError.code == 'NOTIFY_ACTION_NOT_FOUND')
    assert(notify.confirmVisibility({
      generation = 4, visibilityGeneration = 4, visibilityRevision = 4,
      signals = {{ signalId = projectedReplacement.signalId,
        revision = projectedReplacement.revision, visible = true }},
    }))
    assert(notify.invokeVisibleAction(1))
    assert(invocations[1] == 'server-action-token-replacement-0002')
    return 'replacement-action-handshake-pass'
  `, clientFiles);
  assert.equal(result, 'replacement-action-handshake-pass');
});

test('quiet demotion clears stale browser acknowledgement before action reprojection', async () => {
  const result = await runNotifyLua<string>(`${clientHarness}
    local notify = createClient()
    assert(notify.show('owner.quiet-action', 1, localValue({
      kind = 'persistent', title = 'Quiet action',
      actions = {{ id = 'resume', label = 'Resume' }},
    })))
    local baseline = rendered[#rendered]
    assert(baseline.actions == nil)
    assert(notify.confirmVisibility({
      generation = 1, visibilityGeneration = 1, visibilityRevision = 1,
      signals = {{ signalId = baseline.signalId, revision = baseline.revision,
        visible = true }},
    }))
    local projected = rendered[#rendered]
    assert(projected.actions[1].label == 'Resume')
    assert(notify.confirmVisibility({
      generation = 2, visibilityGeneration = 2, visibilityRevision = 2,
      signals = {{ signalId = projected.signalId, revision = projected.revision,
        visible = true }},
    }))

    assert(notify.setPresentationContext('owner.overlay', 1, {
      contextId = 'quiet-overlay', quiet = true,
    }))
    assert(notify.snapshot().visible == 0 and notify.snapshot().queued == 1)
    assert(notify.clearPresentationContext('owner.overlay', 1, 'quiet-overlay'))
    local returned = rendered[#rendered]
    assert(returned.title == 'Quiet action' and returned.actions == nil)
    local blocked, blockedError = notify.invokeVisibleAction(1)
    assert(blocked == nil and blockedError.code == 'NOTIFY_ACTION_NOT_FOUND')
    assert(notify.confirmVisibility({
      generation = 3, visibilityGeneration = 3, visibilityRevision = 3,
      signals = {{ signalId = returned.signalId, revision = returned.revision,
        visible = true }},
    }))
    local reprojected = rendered[#rendered]
    assert(reprojected.actions[1].label == 'Resume')
    return 'quiet-reprojection-pass'
  `, clientFiles);
  assert.equal(result, 'quiet-reprojection-pass');
});
