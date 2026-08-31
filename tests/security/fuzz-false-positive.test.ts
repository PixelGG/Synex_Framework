import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';

import { LuaFactory } from 'wasmoon';

const root = process.cwd();

async function run<T>(files: readonly string[], source: string): Promise<T> {
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

const movementFiles = [
  'resources/synex_security/shared/limits.lua',
  'resources/synex_security/shared/validation.lua',
  'resources/synex_security/server/movement.lua',
] as const;

test('Movement false-positive profiles remain silent for exceptional legitimate states', async () => {
  const result = await run<{
    signals: string;
    expected: number;
    filtered: number;
  }>(movementFiles, `
    local clock, emitted, totals = 0, {}, { expected = 0, filtered = 0 }
    local function session(source)
      return { id = 'session-' .. source, source = source, sourceGeneration = 1 }
    end
    local function sample(x, z, movement, cameraX)
      return { position = { x, 0, z or 0 }, velocity = { 20, 0, 0 },
        camera = { cameraX or x, 0, (z or 0) + 1 },
        movement = movement or { inVehicle = false, ragdoll = false,
          falling = false, parachute = -1 } }
    end
    local function profile(expectation)
      return SynexSecurityMovement.create({
        now = function() return clock end,
        emit = function(signal) emitted[#emitted + 1] = signal end,
        matchExpectations = function(signal)
          if expectation ~= nil and expectation(signal) then
            return { { expectationId = 'legitimate-state' } }
          end
          return {}
        end,
      })
    end
    local normal = { inVehicle = false, ragdoll = false,
      falling = false, parachute = -1 }

    local knockback = profile()
    assert(knockback.observe(session(1), sample(0, 0, normal), { observedAt = 0 }))
    clock = 1000
    assert(knockback.observe(session(1), sample(200, 20, {
      inVehicle = false, ragdoll = true, falling = false, parachute = -1,
    }), { observedAt = clock }))

    local falling = profile()
    clock = 0
    assert(falling.observe(session(2), sample(0, 0, {
      inVehicle = false, ragdoll = false, falling = true, parachute = -1,
    }), { observedAt = clock }))
    for index = 1, 4 do
      clock = index * 1000
      assert(falling.observe(session(2), sample(index * 20, index * 8, {
        inVehicle = false, ragdoll = false, falling = true, parachute = -1,
      }), { observedAt = clock }))
    end

    local parachute = profile()
    clock = 0
    assert(parachute.observe(session(3), sample(0, 100, {
      inVehicle = false, ragdoll = false, falling = true, parachute = 1,
    }), { observedAt = clock }))
    for index = 1, 3 do
      clock = index * 1000
      assert(parachute.observe(session(3), sample(index * 18, 100 - index * 12, {
        inVehicle = false, ragdoll = false, falling = true, parachute = 1,
      }), { observedAt = clock }))
    end

    local vehicle = profile()
    local inVehicle = { inVehicle = true, ragdoll = false,
      falling = false, parachute = -1 }
    clock = 0
    assert(vehicle.observe(session(4), sample(0, 0, inVehicle), { observedAt = clock }))
    clock = 1000
    assert(vehicle.observe(session(4), sample(300, 0, inVehicle), { observedAt = clock }))

    local hitch = profile()
    clock = 0
    assert(hitch.observe(session(5), sample(0, 0, normal), { observedAt = clock }))
    clock = 20000
    assert(hitch.observe(session(5), sample(500, 0, normal), { observedAt = clock }))

    local transition = profile()
    clock = 0
    assert(transition.observe(session(6), sample(0, 0, normal), { observedAt = clock }))
    clock = 1000
    assert(transition.observe(session(6), sample(500, 0, normal), {
      observedAt = clock, authorizedTransition = true, instanceTransition = true }))

    local spectate = profile(function(signal)
      return signal.code == 'CAMERA_FREECAM_ANOMALY'
    end)
    clock = 0
    assert(spectate.observe(session(7), sample(0, 0, normal, 100), { observedAt = clock }))
    clock = 1000
    assert(spectate.observe(session(7), sample(1, 0, normal, 101), { observedAt = clock }))
    clock = 2000
    assert(spectate.observe(session(7), sample(2, 0, normal, 102), { observedAt = clock }))

    for _, detector in ipairs({ knockback, falling, parachute, vehicle, hitch,
      transition, spectate }) do
      local snapshot = detector.snapshot()
      totals.expected = totals.expected + snapshot.expected
      totals.filtered = totals.filtered + snapshot.filtered
    end
    local codes = {}
    for _, signal in ipairs(emitted) do codes[#codes + 1] = signal.code end
    table.sort(codes)
    return { signals = table.concat(codes, ','), expected = totals.expected,
      filtered = totals.filtered }
  `);

  assert.deepEqual(result, { signals: '', expected: 1, filtered: 2 });
});

const sentinelFiles = [
  'resources/synex_security/shared/limits.lua',
  'resources/synex_security/shared/validation.lua',
  'resources/synex_security/server/foundation.lua',
  'resources/synex_security/server/sentinel.lua',
] as const;

test('Sentinel schema fuzzing rejects hostile shapes without mutating sequence state', async () => {
  const result = await run<{
    rejected: number;
    invalidCodes: number;
    activeBeforeValid: number;
    validAccepted: boolean;
    activeAfterValid: number;
  }>(sentinelFiles, `
    local session = { id = 'session-fuzz', source = 33, sourceGeneration = 5 }
    local sentinel = SynexSecuritySentinel.create({
      now = function() return 1000 end,
      resolveSession = function() return session end,
    })
    local function sample()
      return { position = { 0, 0, 0 }, velocity = { 0, 0, 0 },
        camera = { 0, 0, 1 }, health = 200, armor = 0,
        visible = true, alpha = 255, model = 1, weapon = 0,
        movement = { inVehicle = false, ragdoll = false,
          falling = false, parachute = -1 } }
    end
    local function request()
      return { clientEpoch = 1, sequence = 1, sampledAtMs = 10,
        challengeRef = 'bootstrap', sample = sample() }
    end
    local candidates = {}
    local value = request(); value.sample.position[1] = 0 / 0; candidates[#candidates + 1] = value
    value = request(); value.sample.velocity[1] = math.huge; candidates[#candidates + 1] = value
    value = request(); value.sample.position[4] = 0; candidates[#candidates + 1] = value
    value = request(); value.sample.position[2] = nil; candidates[#candidates + 1] = value
    value = request(); value.sample.health = 1001; candidates[#candidates + 1] = value
    value = request(); value.sequence = 0; candidates[#candidates + 1] = value
    value = request(); value.challengeRef = string.rep('x', 65); candidates[#candidates + 1] = value
    value = request(); value.unexpected = true; candidates[#candidates + 1] = value
    value = request(); value.sample.movement.extra = { deeply = { nested = true } };
      candidates[#candidates + 1] = value
    local invalidCodes = 0
    for _, candidate in ipairs(candidates) do
      local accepted, operationError = sentinel.report(candidate, {
        source = 33, sourceGeneration = 5, session = session })
      assert(accepted == nil)
      if operationError.code == 'SECURITY_SENTINEL_INVALID' then
        invalidCodes = invalidCodes + 1
      end
    end
    local before = sentinel.snapshot()
    local accepted = assert(sentinel.report(request(), {
      source = 33, sourceGeneration = 5, session = session }))
    local after = sentinel.snapshot()
    return { rejected = before.rejected, invalidCodes = invalidCodes,
      activeBeforeValid = before.active, validAccepted = accepted.accepted,
      activeAfterValid = after.active }
  `);

  assert.deepEqual(result, {
    rejected: 9,
    invalidCodes: 9,
    activeBeforeValid: 0,
    validAccepted: true,
    activeAfterValid: 1,
  });
});

const signalFiles = [
  'resources/synex_security/shared/limits.lua',
  'resources/synex_security/shared/validation.lua',
  'resources/synex_security/server/foundation.lua',
  'resources/synex_security/server/ring_buffer.lua',
  'resources/synex_security/server/signals.lua',
] as const;

test('Canonical signal fuzzing fails closed for non-finite, recursive, oversized, and malformed evidence', async () => {
  const result = await run<{
    attempts: number;
    rejected: number;
    accepted: number;
    allStructured: boolean;
  }>(signalFiles, `
    local signals = SynexSecuritySignals.create({ now = function() return 1000 end })
    local function request(index)
      return { namespace = 'synex.fixture', category = 'transport',
        detector = 'synex.fixture.transport', code = 'RPC_PAYLOAD_INVALID',
        subject = { resourceName = 'synex_fixture' }, severity = 'MEDIUM',
        confidence = 0.7, evidenceClass = 'SERVER_AUTHORITATIVE',
        correlationKey = 'transport-invalid', rootEventId = ('root-%08d'):format(index),
        summary = 'Malformed request rejected.', evidence = { attempt = index } }
    end
    local attempts, allStructured = 60, true
    for index = 1, attempts do
      local value, kind = request(index), ((index - 1) % 10) + 1
      if kind == 1 then value.category = 'unknown'
      elseif kind == 2 then value.confidence = 0 / 0
      elseif kind == 3 then value.confidence = math.huge
      elseif kind == 4 then value.evidence.self = value.evidence
      elseif kind == 5 then
        local cursor = value.evidence
        for _ = 1, 8 do cursor.next = {}; cursor = cursor.next end
      elseif kind == 6 then value.evidence.raw = string.rep('x', 513)
      elseif kind == 7 then value.summary = 'bad' .. string.char(1) .. 'summary'
      elseif kind == 8 then value.subject = { source = 42 }
      elseif kind == 9 then value.unexpected = true
      else value.detector = 'Invalid.Detector' end
      local accepted, operationError = signals.emit(value,
        { ownerResource = 'synex_fixture', ownerEpoch = 1 })
      if accepted ~= nil or type(operationError) ~= 'table'
        or type(operationError.code) ~= 'string'
        or operationError.code:sub(1, 9) ~= 'SECURITY_' then
        allStructured = false
      end
    end
    local valid = assert(signals.emit(request(1000),
      { ownerResource = 'synex_fixture', ownerEpoch = 1 }))
    local snapshot = signals.snapshot()
    return { attempts = attempts, rejected = snapshot.rejected,
      accepted = snapshot.accepted, allStructured = allStructured
        and valid.signalId ~= nil }
  `);

  assert.deepEqual(result, {
    attempts: 60,
    rejected: 60,
    accepted: 1,
    allStructured: true,
  });
});

const detectorFiles = [
  'resources/synex_security/shared/limits.lua',
  'resources/synex_security/shared/validation.lua',
  'resources/synex_security/server/detectors.lua',
] as const;

test('Legitimate protection, visibility, heal, armor, model, and weapon expectations suppress findings', async () => {
  const result = await run<{
    emitted: number;
    expected: number;
    immunity: number;
  }>(detectorFiles, `
    local clock, emitted = 1000, {}
    local detector = SynexSecurityDetectors.create({
      now = function() return clock end,
      emit = function(signal) emitted[#emitted + 1] = signal end,
      expectedPlayerState = function()
        return { visible = true, model = 10, maximumHealth = 200,
          maximumArmor = 100, invulnerable = true }
      end,
      isWeaponAuthorized = function() return false end,
      matchExpectations = function(signal)
        local legitimate = {
          VISIBILITY_STATE_MISMATCH = true, PLAYER_MODEL_MISMATCH = true,
          PLAYER_HEALTH_LIMIT_MISMATCH = true, PLAYER_ARMOR_LIMIT_MISMATCH = true,
          WEAPON_STATE_UNAUTHORIZED = true,
        }
        return legitimate[signal.code] and { { expectationId = signal.code } } or {}
      end,
    })
    local session = { id = 'session-legitimate', source = 21, sourceGeneration = 1 }
    local sample = { position = { 0, 0, 0 }, velocity = { 0, 0, 0 },
      camera = { 0, 0, 1 }, health = 300, armor = 200,
      visible = false, alpha = 0, model = 11, weapon = 99,
      movement = { inVehicle = false, ragdoll = false, falling = false,
        parachute = -1 } }
    assert(detector.observeSentinel(session, sample, { observedAt = clock }))
    clock = 2000
    assert(detector.observeSentinel(session, sample, { observedAt = clock }))
    for index = 1, 3 do
      clock = clock + 500
      assert(detector.observeDamageTaken(session, { damageClass = 'bullet',
        observedAt = clock, baselineHealth = 300 }))
    end
    clock = 4000
    assert(detector.observeSentinel(session, sample, { observedAt = clock }))
    local snapshot = detector.snapshot()
    return { emitted = #emitted, expected = snapshot.expected,
      immunity = snapshot.damageImmunity }
  `);

  assert.deepEqual(result, { emitted: 0, expected: 5, immunity: 0 });
});

const lifecycleFiles = [
  'resources/synex_security/shared/limits.lua',
  'resources/synex_security/shared/validation.lua',
  'resources/synex_security/server/foundation.lua',
  'resources/synex_security/server/sentinel.lua',
  'resources/synex_security/server/movement.lua',
  'resources/synex_security/server/detectors.lua',
] as const;

test('Disconnect cleanup fences reused sources across Sentinel, movement, and detector state', async () => {
  const result = await run<{
    firstAccepted: boolean;
    secondAccepted: boolean;
    sentinelActive: number;
    movementSubjects: number;
    detectorSubjects: number;
  }>(lifecycleFiles, `
    local clock = 1000
    local current = { id = 'session-old', source = 42, sourceGeneration = 1 }
    local sentinel = SynexSecuritySentinel.create({
      now = function() return clock end,
      resolveSession = function() return current end,
    })
    local movement = SynexSecurityMovement.create({ now = function() return clock end })
    local detectors = SynexSecurityDetectors.create({
      now = function() return clock end, movement = movement,
      expectedPlayerState = function() return {} end,
    })
    local sample = { position = { 0, 0, 0 }, velocity = { 0, 0, 0 },
      camera = { 0, 0, 1 }, health = 200, armor = 0,
      visible = true, alpha = 255, model = 1, weapon = 0,
      movement = { inVehicle = false, ragdoll = false, falling = false,
        parachute = -1 } }
    local first = assert(sentinel.report({ clientEpoch = 1, sequence = 1,
      sampledAtMs = 10, challengeRef = 'bootstrap', sample = sample },
      { source = 42, sourceGeneration = 1, session = current }))
    assert(detectors.observeSentinel(current, sample, { observedAt = clock }))
    assert(sentinel.cleanupSource(42, 1) == 1)
    assert(detectors.cleanupSource(42, 1) == 1)
    current = { id = 'session-new', source = 42, sourceGeneration = 2 }
    clock = 2000
    local second = assert(sentinel.report({ clientEpoch = 1, sequence = 1,
      sampledAtMs = 20, challengeRef = 'bootstrap', sample = sample },
      { source = 42, sourceGeneration = 2, session = current }))
    assert(detectors.observeSentinel(current, sample, { observedAt = clock }))
    return { firstAccepted = first.accepted, secondAccepted = second.accepted,
      sentinelActive = sentinel.snapshot().active,
      movementSubjects = movement.snapshot().subjects,
      detectorSubjects = detectors.snapshot().subjects }
  `);

  assert.deepEqual(result, {
    firstAccepted: true,
    secondAccepted: true,
    sentinelActive: 1,
    movementSubjects: 1,
    detectorSubjects: 1,
  });
});
