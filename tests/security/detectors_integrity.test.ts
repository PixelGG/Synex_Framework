import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';

const root = process.cwd();
const files = [
  'resources/synex_security/shared/limits.lua',
  'resources/synex_security/shared/validation.lua',
  'resources/synex_security/server/detectors.lua',
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

test('Player integrity requires repeated telemetry and explicit server expectations', async () => {
  const result = await run<{
    codes: string;
    emitted: number;
    highUnboundedHealthIgnored: boolean;
    expected: number;
  }>(`
    local clock, emitted = 1000, {}
    local session = { id = 'integrity-session', source = 12, sourceGeneration = 4 }
    local detector = SynexSecurityDetectors.create({
      now = function() return clock end,
      emit = function(signal) emitted[#emitted + 1] = signal end,
      expectedPlayerState = function()
        return { visible = true, model = 10, maximumHealth = 200,
          maximumArmor = 100 }
      end,
      isWeaponAuthorized = function(_, weapon) return weapon ~= 99 end,
      matchExpectations = function(signal)
        if signal.code == 'VISIBILITY_STATE_MISMATCH' then return { { id = 'hidden' } } end
        return {}
      end,
    })
    local sample = { position = { 0, 0, 0 }, velocity = { 0, 0, 0 },
      camera = { 0, 0, 1 }, health = 300, armor = 200,
      visible = false, alpha = 0, model = 11, weapon = 99,
      movement = { inVehicle = false, ragdoll = false, falling = false,
        parachute = -1 } }
    assert(detector.observeSentinel(session, sample, { observedAt = clock }))
    clock = 2000
    assert(detector.observeSentinel(session, sample, { observedAt = clock }))

    local unconstrained = SynexSecurityDetectors.create({
      now = function() return clock end,
      emit = function(signal) emitted[#emitted + 1] = signal end,
      expectedPlayerState = function() return {} end,
    })
    local before = #emitted
    local unconstrainedSample = { position = sample.position, velocity = sample.velocity,
      camera = sample.camera, health = 300, armor = 200, visible = true,
      alpha = 255, model = 11, weapon = 99, movement = sample.movement }
    assert(unconstrained.observeSentinel({ id = 'unbounded', source = 13,
      sourceGeneration = 1 }, unconstrainedSample, { observedAt = clock }))
    clock = 3000
    assert(unconstrained.observeSentinel({ id = 'unbounded', source = 13,
      sourceGeneration = 1 }, unconstrainedSample, { observedAt = clock }))
    local codes = {}
    for _, signal in ipairs(emitted) do codes[#codes + 1] = signal.code end
    table.sort(codes)
    local snapshot = detector.snapshot()
    return { codes = table.concat(codes, ','), emitted = snapshot.emitted,
      highUnboundedHealthIgnored = #emitted == before,
      expected = snapshot.expected }
  `);

  assert.deepEqual(result, {
    codes: [
      'PLAYER_ARMOR_LIMIT_MISMATCH',
      'PLAYER_HEALTH_LIMIT_MISMATCH',
      'PLAYER_MODEL_MISMATCH',
      'WEAPON_STATE_UNAUTHORIZED',
    ].join(','),
    emitted: 4,
    highUnboundedHealthIgnored: true,
    expected: 1,
  });
});

test('Damage immunity and combat analytics remain correlated observe-only evidence', async () => {
  const result = await run<{
    immunity: boolean;
    immunityClass: string;
    combat: boolean;
    combatClass: string;
    headshotOnlyIgnored: boolean;
    unauthorizedWeapon: boolean;
    armorDamageIgnored: boolean;
    missingBaselineIgnored: boolean;
  }>(`
    local clock, emitted = 1000, {}
    local detector = SynexSecurityDetectors.create({
      now = function() return clock end,
      emit = function(signal) emitted[#emitted + 1] = signal end,
      expectedPlayerState = function() return { visible = true, invulnerable = false } end,
      isWeaponAuthorized = function(_, weapon) return weapon ~= 77 end,
      matchExpectations = function() return {} end,
    })
    local session = { id = 'damage-session', source = 15, sourceGeneration = 2 }
    local sample = { position = { 0, 0, 0 }, velocity = { 0, 0, 0 },
      camera = { 0, 0, 1 }, health = 200, armor = 0, visible = true,
      alpha = 255, model = 10, weapon = 0,
      movement = { inVehicle = false, ragdoll = false, falling = false,
        parachute = -1 } }
    assert(detector.observeSentinel(session, sample, { observedAt = clock }))
    for index = 1, 3 do
      clock = clock + 500
      assert(detector.observeDamageTaken(session, { damageClass = 'bullet',
        observedAt = clock, baselineHealth = 200 }))
    end
    clock = 3000
    assert(detector.observeSentinel(session, sample, { observedAt = clock }))
    assert(detector.observeDamage(session, { weaponType = 77, willKill = false },
      { rootEventId = 'cfx:damage:1' }))

    local armorSession = { id = 'armor-session', source = 17, sourceGeneration = 1 }
    local armorSample = { position = sample.position, velocity = sample.velocity,
      camera = sample.camera, health = 200, armor = 100, visible = true,
      alpha = 255, model = 10, weapon = 0, movement = sample.movement }
    assert(detector.observeSentinel(armorSession, armorSample, { observedAt = clock }))
    for index = 1, 3 do
      clock = clock + 100
      assert(detector.observeDamageTaken(armorSession, { damageClass = 'bullet',
        observedAt = clock }))
    end
    local beforeArmor = #emitted
    armorSample.armor = 50
    assert(detector.observeSentinel(armorSession, armorSample, { observedAt = clock + 100 }))
    local missing = assert(detector.observeDamageTaken({ id = 'missing-baseline',
      source = 18, sourceGeneration = 1 }, { damageClass = 'bullet',
      observedAt = clock + 200 }))
    local armorDamageIgnored = #emitted == beforeArmor

    local combatSession = { id = 'combat-session', source = 16, sourceGeneration = 1 }
    for index = 1, 4 do
      detector.observeCombat(combatSession, { highHeadshotRate = true })
    end
    local beforeCorrelated = #emitted
    detector.observeCombat(combatSession, { impossibleReaction = true })
    detector.observeCombat(combatSession, { trajectoryMismatch = true })
    detector.observeCombat(combatSession, {})
    detector.observeCombat(combatSession, {})

    local immunity, immunityClass, combat, combatClass, weapon = false, '', false, '', false
    for _, signal in ipairs(emitted) do
      if signal.code == 'PLAYER_DAMAGE_IMMUNITY_PATTERN' then
        immunity, immunityClass = true, signal.evidenceClass
      elseif signal.code == 'COMBAT_BEHAVIOR_CORRELATION' then
        combat, combatClass = true, signal.evidenceClass
      elseif signal.code == 'WEAPON_DAMAGE_UNAUTHORIZED' then weapon = true end
    end
    return { immunity = immunity, immunityClass = immunityClass,
      combat = combat, combatClass = combatClass,
      headshotOnlyIgnored = beforeCorrelated == 2,
      unauthorizedWeapon = weapon, armorDamageIgnored = armorDamageIgnored,
      missingBaselineIgnored = missing.tracked == false }
  `);

  assert.deepEqual(result, {
    immunity: true,
    immunityClass: 'BEHAVIORAL_HEURISTIC',
    combat: true,
    combatClass: 'BEHAVIORAL_HEURISTIC',
    headshotOnlyIgnored: true,
    unauthorizedWeapon: true,
    armorDamageIgnored: true,
    missingBaselineIgnored: true,
  });
});
