import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory, type LuaEngine } from 'wasmoon';

const root = process.cwd();

async function load(engine: LuaEngine, relativePath: string): Promise<void> {
  await engine.doString(await readFile(path.join(root, relativePath), 'utf8'));
}

async function notifyLua(): Promise<LuaEngine> {
  const engine = await new LuaFactory().createEngine();
  await load(engine, 'resources/synex_notify/shared/limits.lua');
  await load(engine, 'resources/synex_notify/shared/validation.lua');
  await load(engine, 'resources/synex_notify/client/engine.lua');
  return engine;
}

const fixture = `
  local clock, rendered, removed, invoked, observed = 1000, {}, {}, {}, {}
  local function makeEngine()
    return SynexNotifyEngine.create({
      now = function() return clock end,
      upsertSignal = function(descriptor)
        rendered[#rendered + 1] = SynexNotifyValidation.copy(descriptor)
        return { signal = descriptor }
      end,
      removeSignal = function(signalId, revision)
        removed[#removed + 1] = { signalId = signalId, revision = revision }
        return { removed = true }
      end,
      invokeServerAction = function(token, notificationId, revision)
        invoked[#invoked + 1] = { token, notificationId, revision }
        return { accepted = true }
      end,
      observe = function(name, amount)
        observed[name] = (observed[name] or 0) + (amount or 1)
      end,
    })
  end
  local function localNotification(value)
    value.title = value.title or 'Local notification'
    return assert(SynexNotifyValidation.canonicalNotification(value, {
      authority = 'CLIENT', ownerResource = 'consumer.one', now = clock,
    }))
  end
  local function serverNotification(id, value)
    value.notificationId = id
    value.revision = value.revision or 1
    value.kind = value.kind or 'toast'
    value.tone = value.tone or 'neutral'
    value.priority = value.priority or 'normal'
    value.title = value.title or 'Server notification'
    value.createdAt = value.createdAt or clock
    value.position = value.position or 'top-right'
    value.origin = 'SERVER'
    return assert(SynexNotifyValidation.canonicalPresentation(value, {
      authority = 'SERVER', ownerResource = 'consumer.one',
    }))
  end
`;

test('presentation contexts defer quiet work, reserve logical positions, and preserve handles', async () => {
  const engine = await notifyLua();
  try {
    const result = await engine.doString(`${fixture}
      local notify = makeEngine()
      local handle = assert(notify.show('consumer.one', 1, localNotification({
        title = 'Initially visible', priority = 'normal', position = 'top-right',
      })))
      assert(notify.snapshot().visible == 1)

      local context = assert(notify.setPresentationContext('consumer.one', 1, {
        contextId = 'inventory-overlay', quiet = true,
        reservedPositions = { 'top-right' },
        preferredPosition = 'bottom-left',
        fallbackPositions = { 'bottom-right', 'top-left' },
      }))
      assert(context.ownerResource == 'consumer.one' and context.ownerEpoch == 1)
      assert(notify.snapshot().visible == 0 and notify.snapshot().queued == 1)
      assert(#removed == 1)

      local secret = 'opaque-server-action-token-1234567890'
      local longMessage = ('€'):rep(200)
      assert(notify.applyServer('consumer.one', 1, serverNotification(
        'server-critical-notification', {
          priority = 'critical', tone = 'danger', message = longMessage,
          actions = {{ token = secret, label = 'Acknowledge', ttlMs = 30000 }},
        }), 'show'))
      local projected = rendered[#rendered]
      assert(projected.priority == 'critical' and projected.position == 'bottom-left')
      assert(#projected.message <= 512 and utf8.len(projected.message) ~= nil)
      assert(projected.actions == nil)
      assert(notify.confirmVisibility({
        generation = 1, visibilityGeneration = 1, visibilityRevision = 1,
        signals = {{ signalId = projected.signalId, revision = projected.revision,
          visible = true }},
      }))
      projected = rendered[#rendered]
      assert(projected.actions[1].token ~= secret and #projected.actions[1].token <= 64)
      assert(notify.confirmVisibility({
        generation = 2, visibilityGeneration = 2, visibilityRevision = 2,
        signals = {{ signalId = projected.signalId, revision = projected.revision,
          visible = true }},
      }))
      assert(notify.invokeVisibleAction(1))
      assert(invoked[1][1] == secret)

      local cleared = assert(notify.clearPresentationContext(
        'consumer.one', 1, 'inventory-overlay'))
      assert(cleared.cleared and notify.snapshot().visible == 2)
      local patch = assert(SynexNotifyValidation.notificationPatch({
        message = 'The original handle remains valid',
      }, { authority = 'CLIENT' }))
      local updated = assert(notify.update(handle, patch))
      assert(updated.revision == 2)

      assert(notify.setPresentationContext('consumer.one', 1, {
        contextId = 'temporary-reservation', reservedPositions = { 'top-left' },
      }))
      local cleanup = notify.ownerStop('consumer.one', 1, 'LOCAL')
      assert(cleanup.removed == 1 and cleanup.contextsCleared == true)
      assert(notify.snapshot().records == 1)
      local presentation = notify.presentationSnapshot()
      assert(not presentation.quiet and presentation.contextCount == 0)
      return table.concat({ notify.snapshot().records, observed.quiet_deferred or 0,
        #projected.message, #projected.actions[1].token }, ':')
    `);
    assert.equal(result, '1:1:510:31');
  } finally {
    engine.global.close();
  }
});

test('critical native fallback remains text-only even when sound is requested', async () => {
  const engine = await notifyLua();
  try {
    const result = await engine.doString(`${fixture}
      local fallbackCalls, soundCalls = 0, 0
      local notify = SynexNotifyEngine.create({
        now = function() return clock end,
        upsertSignal = function()
          return nil, { code = 'NOTIFY_UI_UNAVAILABLE', retryable = true }
        end,
        removeSignal = function() return true end,
        nativeFallback = function()
          fallbackCalls = fallbackCalls + 1
          return true
        end,
        playSound = function()
          soundCalls = soundCalls + 1
          return true
        end,
        observe = function(name, amount)
          observed[name] = (observed[name] or 0) + (amount or 1)
        end,
      })
      notify.setSoundEnabled(true)
      assert(notify.applyServer('consumer.one', 1, serverNotification(
        'critical-fallback', {
          priority = 'critical', tone = 'danger', sound = true,
        }), 'show'))
      assert(fallbackCalls == 1 and soundCalls == 0)
      assert(observed.native_fallbacks == 1)
      assert(observed.transport_failures == 1)
      return table.concat({ fallbackCalls, soundCalls }, ':')
    `);
    assert.equal(result, '1:0');
  } finally {
    engine.global.close();
  }
});

test('critical fallback activates when the UI retains a signal before browser delivery', async () => {
  const engine = await notifyLua();
  try {
    const result = await engine.doString(`${fixture}
      local fallbackCalls, soundCalls = 0, 0
      local localObserved = {}
      local notify = SynexNotifyEngine.create({
        now = function() return clock end,
        upsertSignal = function(descriptor)
          return { signal = descriptor, delivered = false }
        end,
        removeSignal = function() return true end,
        nativeFallback = function()
          fallbackCalls = fallbackCalls + 1
          return true
        end,
        playSound = function()
          soundCalls = soundCalls + 1
          return true
        end,
        observe = function(name, amount)
          localObserved[name] = (localObserved[name] or 0) + (amount or 1)
        end,
      })
      notify.setSoundEnabled(true)
      assert(notify.applyServer('consumer.one', 1, serverNotification(
        'critical-retained-before-ready', {
          priority = 'critical', tone = 'danger', sound = true,
        }), 'show'))
      notify.tick()
      assert(fallbackCalls == 1 and soundCalls == 0)
      assert(localObserved.native_fallbacks == 1)
      assert(localObserved.transport_failures == 1)
      assert((localObserved.displayed or 0) == 0)

      assert(notify.applyServer('consumer.one', 1, serverNotification(
        'normal-retained-before-ready', {
          priority = 'normal', tone = 'warning', sound = true,
        }), 'show'))
      assert(fallbackCalls == 1 and soundCalls == 0)
      return table.concat({ fallbackCalls, soundCalls,
        localObserved.native_fallbacks, localObserved.transport_failures }, ':')
    `);
    assert.equal(result, '1:0:1:2');
  } finally {
    engine.global.close();
  }
});

test('presentation budgets are atomic and privileged and persistent classes never bypass limits', async () => {
  const engine = await notifyLua();
  try {
    const result = await engine.doString(`${fixture}
      local notify = makeEngine()
      for index = 1, 2 do
        assert(notify.applyServer('consumer.one', 1, serverNotification(
          ('critical-notification-%d'):format(index), {
            priority = 'critical', tone = 'danger',
          }), 'show'))
      end
      local deniedCritical, criticalError = notify.applyServer('consumer.one', 1,
        serverNotification('critical-notification-3', {
          priority = 'critical', tone = 'danger',
        }), 'show')
      assert(deniedCritical == nil and criticalError.code == 'NOTIFY_RATE_LIMITED')

      local persistentEngine = makeEngine()
      for index = 1, 4 do
        assert(persistentEngine.show('consumer.two', 1,
          assert(SynexNotifyValidation.canonicalNotification({
            kind = 'persistent', title = ('Persistent %d'):format(index),
          }, { authority = 'CLIENT' }))))
      end
      local deniedPersistent, persistentError = persistentEngine.show(
        'consumer.two', 1, assert(SynexNotifyValidation.canonicalNotification({
          kind = 'persistent', title = 'Persistent 5',
        }, { authority = 'CLIENT' })))
      assert(deniedPersistent == nil and persistentError.code == 'NOTIFY_RATE_LIMITED')

      SynexNotifyLimits.rateLimits.global = { capacity = 1, refillPerSecond = 0 }
      SynexNotifyLimits.rateLimits.owner = { capacity = 1, refillPerSecond = 0 }
      SynexNotifyLimits.rateLimits.persistent = { capacity = 0, refillPerSecond = 0 }
      SynexNotifyLimits.rateLimits.toast = { capacity = 1, refillPerSecond = 0 }
      SynexNotifyLimits.notificationCosts.persistent = 1
      local atomic = makeEngine()
      local denied = atomic.show('consumer.atomic', 1,
        assert(SynexNotifyValidation.canonicalNotification({
          kind = 'persistent', title = 'Denied atomically',
        }, { authority = 'CLIENT' })))
      assert(denied == nil)
      assert(atomic.show('consumer.atomic', 1,
        assert(SynexNotifyValidation.canonicalNotification({
          title = 'Global and owner tokens were not partially consumed',
        }, { authority = 'CLIENT' }))))
      return criticalError.code .. ':' .. persistentError.code
    `);
    assert.equal(result, 'NOTIFY_RATE_LIMITED:NOTIFY_RATE_LIMITED');
  } finally {
    engine.global.close();
  }
});

test('dedupe, grouping, progress coalescing, and maximum lifetime remain revision-safe', async () => {
  const engine = await notifyLua();
  try {
    const result = await engine.doString(`${fixture}
      local notify = makeEngine()
      local first = assert(notify.show('consumer.one', 1, localNotification({
        title = 'Original', dedupeKey = 'immutable-lifetime',
        dedupePolicy = 'replace', durationMs = 1500, maxLifetimeMs = 3000,
      })))
      clock = 1500
      local replaced = assert(notify.show('consumer.one', 1, localNotification({
        title = 'Replacement', dedupeKey = 'immutable-lifetime',
        dedupePolicy = 'replace', durationMs = 30000, maxLifetimeMs = 120000,
      })))
      assert(replaced.notificationId == first.notificationId and replaced.revision == 2)
      assert(notify.show('consumer.one', 1, localNotification({
        title = 'Info group', groupKey = 'compatible-group', tone = 'info',
      })))
      assert(notify.show('consumer.one', 1, localNotification({
        title = 'Danger group', groupKey = 'compatible-group', tone = 'danger',
      })))
      assert(notify.snapshot().records == 3)

      local progress = assert(notify.show('consumer.progress', 1,
        assert(SynexNotifyValidation.canonicalNotification({
          kind = 'progress', title = 'Progress', progress = {
            state = 'RUNNING', mode = 'determinate', value = 1, maximum = 10,
          },
        }, { authority = 'CLIENT' }))))
      local patchTwo = assert(SynexNotifyValidation.notificationPatch({ progress = {
        state = 'RUNNING', mode = 'determinate', value = 2, maximum = 10,
      } }, { authority = 'CLIENT', kind = 'progress' }))
      local revisionTwo = assert(notify.update(progress, patchTwo))
      local _, staleError = notify.update(progress, patchTwo)
      assert(staleError.code == 'NOTIFY_NOTIFICATION_STALE')
      local patchThree = assert(SynexNotifyValidation.notificationPatch({ progress = {
        state = 'RUNNING', mode = 'determinate', value = 3, maximum = 10,
      } }, { authority = 'CLIENT', kind = 'progress' }))
      assert(notify.update(revisionTwo, patchThree))
      assert((observed.coalesced or 0) == 1)
      assert(notify.applyServer('consumer.one', 1, serverNotification(
        'server-authority-isolation', {
          dedupeKey = 'immutable-lifetime', dedupePolicy = 'suppress',
        }), 'show'))
      assert(notify.snapshot().records == 5)
      clock = 1600
      notify.tick()

      clock = 4001
      notify.tick()
      assert(notify.history('consumer.one', 10)[1].reason == 'expired')
      return table.concat({ staleError.code, observed.coalesced or 0,
        notify.snapshot().records }, ':')
    `);
    assert.equal(result, 'NOTIFY_NOTIFICATION_STALE:1:4');
  } finally {
    engine.global.close();
  }
});

test('refresh deduplication stops extending duration at its immutable refresh-count cap', async () => {
  const engine = await notifyLua();
  try {
    const result = await engine.doString(`${fixture}
      local notify = makeEngine()
      local request = {
        title = 'Refresh bounded', dedupeKey = 'bounded-refresh',
        dedupePolicy = 'refresh', maxRefreshCount = 2,
        durationMs = 1500, maxLifetimeMs = 10000,
      }
      local first = assert(notify.show('consumer.refresh', 1,
        localNotification(SynexNotifyValidation.copy(request))))
      clock = 1500
      local second = assert(notify.show('consumer.refresh', 1,
        localNotification(SynexNotifyValidation.copy(request))))
      clock = 2000
      local third = assert(notify.show('consumer.refresh', 1,
        localNotification(SynexNotifyValidation.copy(request))))
      clock = 2500
      local capped = assert(notify.show('consumer.refresh', 1,
        localNotification(SynexNotifyValidation.copy(request))))
      assert(first.revision == 1 and second.revision == 2 and third.revision == 3)
      assert(capped.revision == 3 and (observed.suppressed or 0) == 1)
      clock = 3501
      notify.tick()
      assert(notify.snapshot().records == 0)
      assert(notify.history('consumer.refresh', 1)[1].reason == 'expired')
      return table.concat({ capped.revision, observed.suppressed or 0,
        notify.snapshot().records }, ':')
    `);
    assert.equal(result, '3:1:0');
  } finally {
    engine.global.close();
  }
});

test('UI reconciliation repairs missing signals and removes owner-scoped orphans', async () => {
  const engine = await notifyLua();
  try {
    const result = await engine.doString(`${fixture}
      local notify = makeEngine()
      local handle = assert(notify.show('consumer.one', 1, localNotification({
        title = 'Reconcile me', kind = 'persistent',
      })))
      local before = #rendered
      assert(notify.reconcile({ signals = {} }))
      assert(#rendered == before + 1)
      assert(notify.reconcile({ signals = {
        { signalId = handle.notificationId, revision = 50 },
        { signalId = 'orphan-signal', revision = 7 },
      } }))
      assert(removed[#removed].signalId == 'orphan-signal')
      local patch = assert(SynexNotifyValidation.notificationPatch({
        message = 'Handle revision is independent from UI repair revisions',
      }, { authority = 'CLIENT' }))
      local updated = assert(notify.update(handle, patch))
      assert(updated.revision == 2)
      return removed[#removed].signalId .. ':' .. updated.revision
    `);
    assert.equal(result, 'orphan-signal:2');
  } finally {
    engine.global.close();
  }
});

test('a failed coalesced render clears its due deadline instead of creating an idle retry loop', async () => {
  const engine = await notifyLua();
  try {
    const result = await engine.doString(`
      local clock, failRender = 1000, false
      local notify = SynexNotifyEngine.create({
        now = function() return clock end,
        upsertSignal = function(descriptor)
          if failRender then return nil, { code = 'UI_DOWN' } end
          return { signal = descriptor }
        end,
        removeSignal = function() return { removed = true } end,
      })
      local handle = assert(notify.show('consumer.progress', 1,
        assert(SynexNotifyValidation.canonicalNotification({
          kind = 'progress', title = 'Progress', progress = {
            state = 'RUNNING', mode = 'determinate', value = 1, maximum = 10,
          },
        }, { authority = 'CLIENT' }))))
      local patchTwo = assert(SynexNotifyValidation.notificationPatch({ progress = {
        state = 'RUNNING', mode = 'determinate', value = 2, maximum = 10,
      } }, { authority = 'CLIENT', kind = 'progress' }))
      handle = assert(notify.update(handle, patchTwo))
      failRender = true
      local patchThree = assert(SynexNotifyValidation.notificationPatch({ progress = {
        state = 'RUNNING', mode = 'determinate', value = 3, maximum = 10,
      } }, { authority = 'CLIENT', kind = 'progress' }))
      assert(notify.update(handle, patchThree))
      assert(notify.nextDeadline() == 1100)
      clock = 1100
      local nextDeadline = notify.tick()
      assert(nextDeadline > clock)
      return nextDeadline
    `);
    assert.equal(result, 121000);
  } finally {
    engine.global.close();
  }
});
