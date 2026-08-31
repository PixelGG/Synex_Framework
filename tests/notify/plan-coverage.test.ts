import assert from 'node:assert/strict';
import test from 'node:test';
import { notifySharedFiles, runNotifyLua } from './helpers.js';

const notifyEngineFiles = [
  ...notifySharedFiles,
  'resources/synex_notify/client/engine.lua',
] as const;

test('canonical notification validation covers the complete planned boundary matrix', async () => {
  const result = await runNotifyLua<string>(`
    local maximum = assert(SynexNotifyValidation.canonicalNotification({
      kind = 'toast',
      tone = 'neutral',
      priority = 'normal',
      title = ('T'):rep(SynexNotifyLimits.maximumTitleBytes),
      message = ('B'):rep(SynexNotifyLimits.maximumMessageBytes),
      durationMs = SynexNotifyLimits.minimumDurationMs,
      iconKey = 'info',
      actions = {
        { id = 'accept', label = 'Accept' },
        { id = 'dismiss', label = 'Dismiss' },
      },
    }, { authority = 'SERVER' }))
    assert(maximum.kind == 'toast' and maximum.tone == 'neutral')
    assert(maximum.priority == 'normal')
    assert(#maximum.title == SynexNotifyLimits.maximumTitleBytes)
    assert(#maximum.message == SynexNotifyLimits.maximumMessageBytes)
    assert(maximum.durationMs == SynexNotifyLimits.minimumDurationMs)
    assert(maximum.iconKey == 'info' and #maximum.actions == 2)

    local defaulted = assert(SynexNotifyValidation.canonicalNotification({
      title = 'Defaults remain canonical',
    }, { authority = 'SERVER' }))
    assert(defaulted.priority == 'normal')

    local invalid = {
      { title = 'Invalid kind', kind = 'modal' },
      { title = 'Invalid tone', tone = 'positive' },
      { title = 'Invalid priority', priority = 'NORMAL' },
      { title = ('T'):rep(SynexNotifyLimits.maximumTitleBytes + 1) },
      { title = 'Oversized body',
        message = ('B'):rep(SynexNotifyLimits.maximumMessageBytes + 1) },
      { title = 'Duration below bound',
        durationMs = SynexNotifyLimits.minimumDurationMs - 1 },
      { title = 'Duration above bound',
        durationMs = SynexNotifyLimits.maximumDurationMs + 1 },
      { title = 'Invalid icon', iconKey = 'https://invalid.example/icon.svg' },
      { title = 'Too many actions', actions = {
        { id = 'one', label = 'One' },
        { id = 'two', label = 'Two' },
        { id = 'three', label = 'Three' },
      } },
    }
    for index, candidate in ipairs(invalid) do
      local value, operationError = SynexNotifyValidation.canonicalNotification(
        candidate, { authority = 'SERVER' })
      assert(value == nil, ('case %d unexpectedly passed'):format(index))
      assert(operationError.code == 'NOTIFY_INVALID_REQUEST',
        ('case %d returned %s'):format(index, tostring(operationError.code)))
    end
    return table.concat({ defaulted.priority, #invalid,
      #maximum.title, #maximum.message }, ':')
  `, notifySharedFiles);
  assert.equal(result, 'normal:9:120:720');
});

test('grouping keeps independent groups separate and never mixes priority classes', async () => {
  const result = await runNotifyLua<string>(`
    local clock, rendered = 1000, {}
    local notify = SynexNotifyEngine.create({
      now = function() return clock end,
      upsertSignal = function(descriptor)
        rendered[#rendered + 1] = SynexNotifyValidation.copy(descriptor)
        return { signal = descriptor }
      end,
      removeSignal = function() return { removed = true } end,
    })

    local serial = 0
    local function presentation(priority, suffix)
      serial = serial + 1
      return assert(SynexNotifyValidation.canonicalPresentation({
        notificationId = ('planned-group-%02d'):format(serial),
        revision = 1,
        kind = 'toast',
        tone = 'info',
        priority = priority,
        title = ('%s %s'):format(priority, suffix),
        groupKey = 'priority.group',
        createdAt = clock,
        position = 'top-right',
        origin = 'SERVER',
      }, { authority = 'SERVER', ownerResource = 'consumer.priority' }))
    end

    local priorities = { 'low', 'normal', 'high', 'critical' }
    for _, priority in ipairs(priorities) do
      assert(notify.applyServer('consumer.priority', 1,
        presentation(priority, 'first'), 'show'))
      assert(notify.applyServer('consumer.priority', 1,
        presentation(priority, 'second'), 'show'))
    end

    local distinctSignals, latest = {}, {}
    for _, descriptor in ipairs(rendered) do
      distinctSignals[descriptor.signalId] = true
      latest[descriptor.priority] = descriptor
    end
    local distinctCount = 0
    for _ in pairs(distinctSignals) do distinctCount = distinctCount + 1 end
    assert(distinctCount == 4)
    for _, priority in ipairs(priorities) do
      assert(latest[priority] ~= nil)
      assert(latest[priority].priority == priority)
      assert(latest[priority].count == 2)
    end

    local function localGrouped(groupKey, title)
      return assert(SynexNotifyValidation.canonicalNotification({
        title = title,
        groupKey = groupKey,
        priority = 'normal',
      }, { authority = 'CLIENT', ownerResource = 'consumer.multiple' }))
    end
    local inventoryOne = assert(notify.show('consumer.multiple', 1,
      localGrouped('inventory.received', 'Inventory one')))
    local inventoryTwo = assert(notify.show('consumer.multiple', 1,
      localGrouped('inventory.received', 'Inventory two')))
    local jobsOne = assert(notify.show('consumer.multiple', 1,
      localGrouped('jobs.update', 'Jobs one')))
    local jobsTwo = assert(notify.show('consumer.multiple', 1,
      localGrouped('jobs.update', 'Jobs two')))
    assert(inventoryOne.notificationId == inventoryTwo.notificationId)
    assert(jobsOne.notificationId == jobsTwo.notificationId)
    assert(inventoryOne.notificationId ~= jobsOne.notificationId)

    local snapshot = notify.snapshot()
    assert(snapshot.records == 6 and snapshot.visible == 4 and snapshot.queued == 2)
    return table.concat({ distinctCount, latest.low.count, latest.normal.count,
      latest.high.count, latest.critical.count, snapshot.records,
      snapshot.visible, snapshot.queued }, ':')
  `, notifyEngineFiles);
  assert.equal(result, '4:2:2:2:2:6:4:2');
});
