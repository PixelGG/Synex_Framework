import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';

import { LuaFactory } from 'wasmoon';

const root = process.cwd();
const files = [
  'resources/synex_security/shared/limits.lua',
  'resources/synex_security/shared/validation.lua',
  'resources/synex_security/server/cfx_guards.lua',
] as const;

async function run<T>(source: string): Promise<T> {
  const engine = await new LuaFactory().createEngine();
  try {
    for (const file of files) {
      await engine.doString(await readFile(path.join(root, file), 'utf8'));
    }
    return await engine.doString(source) as T;
  } finally {
    engine.global.close();
  }
}

test('Cfx hook installation rolls back partial state and can be retried cleanly', async () => {
  const result = await run<{
    firstError: string;
    removedAfterFailure: number;
    installedAfterFailure: boolean;
    installedAfterRetry: boolean;
    registrations: number;
    removedAfterStop: number;
    hooksAfterStop: number;
  }>(`
    local registrations, removed, fail = 0, {}, true
    local guards = SynexSecurityCfxGuards.create({
      now = function() return 1000 end,
      ports = {
        addEventHandler = function(name)
          registrations = registrations + 1
          if fail and registrations == 3 then error('injected hook failure') end
          return 'hook:' .. name .. ':' .. registrations
        end,
        removeEventHandler = function(token) removed[#removed + 1] = token end,
      },
    })
    local _, firstError = guards.install()
    local afterFailure = guards.snapshot()
    local removedAfterFailure = #removed
    fail = false
    assert(guards.install())
    local afterRetry = guards.snapshot()
    guards.uninstall()
    guards.uninstall()
    local afterStop, hooksAfterStop = guards.snapshot(), 0
    for _, hook in ipairs(afterStop.hooks) do
      if hook.installed then hooksAfterStop = hooksAfterStop + 1 end
    end
    return { firstError = firstError.code, removedAfterFailure = removedAfterFailure,
      installedAfterFailure = afterFailure.installed,
      installedAfterRetry = afterRetry.installed,
      registrations = registrations, removedAfterStop = #removed,
      hooksAfterStop = hooksAfterStop }
  `);

  assert.deepEqual(result, {
    firstError: 'SECURITY_CFX_HOOK_FAILED',
    removedAfterFailure: 2,
    installedAfterFailure: false,
    installedAfterRetry: true,
    registrations: 8,
    removedAfterStop: 7,
    hooksAfterStop: 0,
  });
});

test('Source cleanup prevents a reconnect from inheriting event-rate history', async () => {
  const result = await run<{
    burstSignals: number;
    canceled: number;
    sourceGeneration: number;
    observed: number;
  }>(`
    local callbacks, emitted, canceled, generation = {}, {}, 0, 1
    local guards = SynexSecurityCfxGuards.create({
      now = function() return 1000 end,
      explosionBurstLimit = 2,
      ports = {
        addEventHandler = function(name, handler) callbacks[name] = handler; return name end,
        cancelEvent = function() canceled = canceled + 1 end,
      },
      resolveSession = function(source)
        return { id = 'session-' .. generation, source = source,
          sourceGeneration = generation }
      end,
      emit = function(signal) emitted[#emitted + 1] = signal end,
    })
    assert(guards.install())
    callbacks.explosionEvent(42, { explosionType = 1, posX = 0, posY = 0, posZ = 0 })
    callbacks.explosionEvent(42, { explosionType = 1, posX = 0, posY = 0, posZ = 0 })
    guards.cleanupSource(42)
    generation = 2
    callbacks.explosionEvent(42, { explosionType = 1, posX = 0, posY = 0, posZ = 0 })
    callbacks.explosionEvent(42, { explosionType = 1, posX = 0, posY = 0, posZ = 0 })
    callbacks.explosionEvent(42, { explosionType = 1, posX = 0, posY = 0, posZ = 0 })
    local burstSignals, sourceGeneration = 0, 0
    for _, signal in ipairs(emitted) do
      if signal.code == 'EXPLOSION_EVENT_BURST' then
        burstSignals = burstSignals + 1
        sourceGeneration = signal.subject.sourceGeneration
      end
    end
    return { burstSignals = burstSignals, canceled = canceled,
      sourceGeneration = sourceGeneration, observed = guards.snapshot().explosion }
  `);

  assert.deepEqual(result, {
    burstSignals: 1,
    canceled: 0,
    sourceGeneration: 2,
    observed: 5,
  });
});

test('Malformed server events fail closed while observe mode never mitigates deterministic findings', async () => {
  const result = await run<{
    malformedCode: string;
    malformedCanceled: number;
    observeCode: string;
    observeCanceled: number;
    malformedCount: number;
  }>(`
    local callbacks, emitted, canceled = {}, {}, 0
    local guards = SynexSecurityCfxGuards.create({
      now = function() return 1000 end,
      ports = {
        addEventHandler = function(name, handler) callbacks[name] = handler; return name end,
        cancelEvent = function() canceled = canceled + 1 end,
      },
      emit = function(signal) emitted[#emitted + 1] = signal end,
      modeFor = function() return 'MITIGATE' end,
    })
    assert(guards.install())
    callbacks.weaponDamageEvent('forged', {})
    local malformedCanceled = canceled

    local observeCallback, observeSignals, observeCanceled = nil, {}, 0
    local observe = SynexSecurityCfxGuards.create({
      now = function() return 1000 end,
      ports = {
        addEventHandler = function(name, handler)
          if name == 'entityCreating' then observeCallback = handler end
          return name
        end,
        cancelEvent = function() observeCanceled = observeCanceled + 1 end,
        getEntityOwner = function() return 7 end,
        getEntityModel = function() return 999 end,
        getEntityType = function() return 3 end,
        getEntityBucket = function() return 0 end,
      },
      deniedModels = { [999] = true },
      modeFor = function() return 'OBSERVE' end,
      resolveSession = function(source)
        return { id = 'session-' .. source, source = source, sourceGeneration = 1 }
      end,
      emit = function(signal) observeSignals[#observeSignals + 1] = signal end,
    })
    assert(observe.install())
    observeCallback(100)
    return { malformedCode = emitted[1].code,
      malformedCanceled = malformedCanceled,
      observeCode = observeSignals[1].code, observeCanceled = observeCanceled,
      malformedCount = guards.snapshot().malformed }
  `);

  assert.deepEqual(result, {
    malformedCode: 'CFX_GAME_EVENT_INVALID',
    malformedCanceled: 1,
    observeCode: 'ENTITY_MODEL_DENIED',
    observeCanceled: 0,
    malformedCount: 1,
  });
});

test('Normal gameplay event volume remains silent below configured bounds', async () => {
  const result = await run<{
    signals: number;
    canceled: number;
    observed: number;
    bursts: number;
  }>(`
    local callbacks, signals, canceled = {}, 0, 0
    local guards = SynexSecurityCfxGuards.create({
      now = function() return 1000 end,
      ports = {
        addEventHandler = function(name, handler) callbacks[name] = handler; return name end,
        cancelEvent = function() canceled = canceled + 1 end,
        getEntityOwner = function() return 7 end,
        getEntityModel = function() return 100 end,
        getEntityType = function() return 2 end,
        getEntityBucket = function() return 0 end,
      },
      authorizeEntity = function() return { allowed = true,
        deterministic = false, policy = 'legacy_allowed' } end,
      emit = function() signals = signals + 1 end,
      entityBurstLimit = 10, explosionBurstLimit = 10,
      projectileBurstLimit = 10, ptFxBurstLimit = 10, damageBurstLimit = 10,
    })
    assert(guards.install())
    for index = 1, 3 do
      callbacks.entityCreating(index)
      callbacks.explosionEvent(7, { explosionType = 1, posX = index, posY = 0, posZ = 0 })
      callbacks.startProjectileEvent(7, { projectileHash = 100 })
      callbacks.ptFxEvent(7, { effectHash = 100 })
      callbacks.weaponDamageEvent(7, { weaponType = 100, damageType = 1,
        hitGlobalId = index, willKill = false })
    end
    local snapshot = guards.snapshot()
    return { signals = signals, canceled = canceled, observed = snapshot.observed,
      bursts = snapshot.bursts }
  `);

  assert.deepEqual(result, { signals: 0, canceled: 0, observed: 15, bursts: 0 });
});

test('Disabled detector families keep hooks inert without signals or mitigation', async () => {
  const result = await run<{
    signals: number;
    canceled: number;
    observed: number;
    hooks: number;
  }>(`
    local callbacks, signals, canceled = {}, 0, 0
    local guards = SynexSecurityCfxGuards.create({
      now = function() return 1000 end,
      ports = {
        addEventHandler = function(name, handler) callbacks[name] = handler; return name end,
        cancelEvent = function() canceled = canceled + 1 end,
        getEntityOwner = function() return 7 end,
        getEntityModel = function() return 999 end,
        getEntityType = function() return 3 end,
        getEntityBucket = function() return 0 end,
      },
      modeFor = function() return 'DISABLED' end,
      deniedModels = { [999] = true }, deniedExplosions = { [42] = true },
      deniedProjectiles = { [123] = true }, deniedPtFx = { [456] = true },
      supportsCancellation = { startProjectileEvent = true, ptFxEvent = true },
      liveVerified = { startProjectileEvent = true, ptFxEvent = true },
      emit = function() signals = signals + 1 end,
    })
    assert(guards.install())
    callbacks.entityCreating(1)
    callbacks.weaponDamageEvent(7, { weaponType = 1, damageType = 1,
      hitGlobalId = 1, willKill = false })
    callbacks.explosionEvent(7, { explosionType = 42, posX = 0, posY = 0, posZ = 0 })
    callbacks.startProjectileEvent(7, { projectileHash = 123 })
    callbacks.ptFxEvent(7, { effectHash = 456 })
    local snapshot, hooks = guards.snapshot(), 0
    for _, hook in ipairs(snapshot.hooks) do if hook.installed then hooks = hooks + 1 end end
    return { signals = signals, canceled = canceled, observed = snapshot.observed,
      hooks = hooks }
  `);

  assert.deepEqual(result, { signals: 0, canceled: 0, observed: 0, hooks: 5 });
});
