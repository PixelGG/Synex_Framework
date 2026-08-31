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

test('Cfx guards install once and cancel only deterministic or live-gated violations', async () => {
  const result = await run<{
    registrations: number;
    codes: string;
    canceled: number;
    damageObserved: number;
    normalExplosionIgnored: boolean;
    projectileCancellationDisabled: boolean;
    allHooksInstalled: boolean;
  }>(`
    local clock, callbacks, emitted = 0, {}, {}
    local registrations, canceled, damageObserved = 0, 0, 0
    local guards = SynexSecurityCfxGuards.create({
      now = function() return clock end,
      ports = {
        addEventHandler = function(name, handler)
          registrations = registrations + 1
          callbacks[name] = handler
          return registrations
        end,
        removeEventHandler = function() end,
        cancelEvent = function() canceled = canceled + 1 end,
        getEntityOwner = function(entity)
          if entity >= 100 then return 0 end
          return entity >= 30 and 8 or 7
        end,
        getEntityModel = function(entity) return entity == 10 and 999 or 100 end,
        getEntityType = function() return 3 end,
        getEntityBucket = function() return 0 end,
      },
      resolveSession = function(source)
        return { id = 'session-' .. source, source = source, sourceGeneration = 1 }
      end,
      emit = function(signal) emitted[#emitted + 1] = signal end,
      deniedModels = { [999] = true },
      deniedExplosions = { [42] = true },
      deniedProjectiles = { [123] = true },
      entityBurstLimit = 2,
      entityBurstMitigation = true,
      ptFxBurstLimit = 2,
      ptFxBurstMitigation = true,
      supportsCancellation = { ptFxEvent = true, startProjectileEvent = false },
      liveVerified = { ptFxEvent = true, startProjectileEvent = false },
      authorizeEntity = function(request)
        return { allowed = true, deterministic = false,
          policy = request.creator == 0 and 'managed'
            or request.creator == 8 and 'strict' or 'legacy_allowed' }
      end,
      detectors = {
        mode = function() return 'MITIGATE' end,
        observeDamage = function() damageObserved = damageObserved + 1 end,
      },
      matchExpectations = function() return {} end,
    })
    assert(guards.install())
    assert(guards.install())
    callbacks.entityCreating(10)
    callbacks.entityCreating(20)
    callbacks.entityCreating(30)
    callbacks.entityCreating(31)
    callbacks.entityCreating(32)
    for entity = 100, 124 do callbacks.entityCreating(entity) end
    callbacks.explosionEvent(7, { explosionType = 1, posX = 0, posY = 0, posZ = 0 })
    local beforeDeniedExplosion = #emitted
    callbacks.explosionEvent(7, { explosionType = 42, posX = 1, posY = 2, posZ = 3 })
    callbacks.startProjectileEvent(7, { projectileHash = 123 })
    callbacks.ptFxEvent(7, { effectHash = 1 })
    callbacks.ptFxEvent(7, { effectHash = 1 })
    callbacks.ptFxEvent(7, { effectHash = 1 })
    callbacks.weaponDamageEvent(7, { weaponType = 50, damageType = 1,
      hitGlobalId = 22, willKill = false })
    local snapshot, codes = guards.snapshot(), {}
    for _, signal in ipairs(emitted) do codes[#codes + 1] = signal.code end
    table.sort(codes)
    local installed = true
    for _, hook in ipairs(snapshot.hooks) do
      if not hook.installed then installed = false end
    end
    return { registrations = registrations, codes = table.concat(codes, ','),
      canceled = canceled, damageObserved = damageObserved,
      normalExplosionIgnored = beforeDeniedExplosion == 2,
      projectileCancellationDisabled = canceled == 4,
      allHooksInstalled = installed }
  `);

  assert.deepEqual(result, {
    registrations: 5,
    codes: [
      'ENTITY_MODEL_DENIED',
      'ENTITY_SPAWN_BURST',
      'EXPLOSION_TYPE_DENIED',
      'PROJECTILE_TYPE_DENIED',
      'PTFX_EVENT_BURST',
    ].sort().join(','),
    canceled: 4,
    damageObserved: 1,
    normalExplosionIgnored: true,
    projectileCancellationDisabled: true,
    allHooksInstalled: true,
  });
});

test('Expectations suppress both entity signals and mitigation', async () => {
  const result = await run<{
    emitted: number;
    canceled: number;
    expected: number;
  }>(`
    local callback, emitted, canceled = nil, 0, 0
    local guards = SynexSecurityCfxGuards.create({
      now = function() return 1000 end,
      ports = {
        addEventHandler = function(name, handler)
          if name == 'entityCreating' then callback = handler end
          return name
        end,
        cancelEvent = function() canceled = canceled + 1 end,
        getEntityOwner = function() return 5 end,
        getEntityModel = function() return 444 end,
        getEntityType = function() return 2 end,
        getEntityBucket = function() return 9 end,
      },
      resolveSession = function()
        return { id = 'expected-session', source = 5, sourceGeneration = 1 }
      end,
      deniedModels = { [444] = true },
      emit = function() emitted = emitted + 1 end,
      matchExpectations = function(signal)
        if signal.code == 'ENTITY_MODEL_DENIED' then return { { id = 'spawn-grant' } } end
        return {}
      end,
    })
    assert(guards.install())
    callback(100)
    local snapshot = guards.snapshot()
    return { emitted = emitted, canceled = canceled, expected = snapshot.expected }
  `);

  assert.deepEqual(result, { emitted: 0, canceled: 0, expected: 1 });
});

test('Heuristic event bursts stay observe-only unless mitigation is explicitly enabled', async () => {
  const result = await run<{ code: string; canceled: number }>(`
    local callbacks, signals, canceled = {}, {}, 0
    local guards = SynexSecurityCfxGuards.create({
      now = function() return 1000 end,
      ports = {
        addEventHandler = function(name, handler) callbacks[name] = handler; return name end,
        cancelEvent = function() canceled = canceled + 1 end,
      },
      resolveSession = function(source)
        return { id = 'burst-' .. source, source = source, sourceGeneration = 1 }
      end,
      emit = function(signal) signals[#signals + 1] = signal end,
      explosionBurstLimit = 2,
      matchExpectations = function() return {} end,
    })
    assert(guards.install())
    for index = 1, 3 do
      callbacks.explosionEvent(6, { explosionType = 1, posX = index,
        posY = 0, posZ = 0 })
    end
    return { code = signals[1].code, canceled = canceled }
  `);

  assert.deepEqual(result, { code: 'EXPLOSION_EVENT_BURST', canceled: 0 });
});
