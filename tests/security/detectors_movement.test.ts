import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';

const root = process.cwd();
const files = [
  'resources/synex_security/shared/limits.lua',
  'resources/synex_security/shared/validation.lua',
  'resources/synex_security/server/movement.lua',
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

test('Movement filters expected transitions and stale or high-latency intervals', async () => {
  const result = await run<{
    codes: string;
    expected: number;
    filtered: number;
    historyBounded: boolean;
  }>(`
    local clock, emitted = 0, {}
    local expectedTeleport = true
    local movement = SynexSecurityMovement.create({
      now = function() return clock end,
      historyCapacity = 4,
      emit = function(signal) emitted[#emitted + 1] = signal end,
      matchExpectations = function(signal)
        if expectedTeleport and signal.code == 'MOVEMENT_TELEPORT_ANOMALY' then
          return { { expectationId = 'world-transition' } }
        end
        return {}
      end,
    })
    local session = { id = 'move-session', source = 4, sourceGeneration = 3 }
    local function sample(x, z)
      return { position = { x, 0, z or 0 }, velocity = { 0, 0, 0 },
        camera = { x, 0, (z or 0) + 1 },
        movement = { inVehicle = false, ragdoll = false, falling = false,
          parachute = -1 } }
    end
    assert(movement.observe(session, sample(0), { observedAt = clock, bucket = 0 }))
    clock = 1000
    assert(movement.observe(session, sample(300), { observedAt = clock, bucket = 0 }))
    expectedTeleport = false
    clock = 2000
    assert(movement.observe(session, sample(600), { observedAt = clock,
      authorizedTransition = true, bucket = 0 }))
    clock = 22000
    assert(movement.observe(session, sample(900), { observedAt = clock, bucket = 0 }))
    for index = 1, 8 do
      clock = clock + 1000
      assert(movement.observe(session, sample(900 + index), {
        observedAt = clock, bucket = 1 }))
    end
    local snapshot, inspection = movement.snapshot(), movement.inspect(4, 3)
    local codes = {}
    for _, signal in ipairs(emitted) do codes[#codes + 1] = signal.code end
    return { codes = table.concat(codes, ','), expected = snapshot.expected,
      filtered = snapshot.filtered, historyBounded = inspection.samples == 4 }
  `);

  assert.deepEqual(result, {
    codes: '',
    expected: 1,
    filtered: 3,
    historyBounded: true,
  });
});

test('Movement emits observe-only teleport, noclip, freecam, and repeated jump patterns', async () => {
  const result = await run<{
    codes: string;
    teleportClass: string;
    noclipClass: string;
    jumpAdvisory: boolean;
    teleportSource: number;
    anomalies: number;
  }>(`
    local clock, emitted = 0, {}
    local function engine()
      return SynexSecurityMovement.create({
        now = function() return clock end,
        emit = function(signal) emitted[#emitted + 1] = signal end,
        matchExpectations = function() return {} end,
      })
    end
    local function session(source)
      return { id = 'session-' .. source, source = source, sourceGeneration = 1 }
    end
    local function sample(x, z, cameraX, velocity)
      return { position = { x, 0, z }, velocity = { velocity or 0, 0, 0 },
        camera = { cameraX or x, 0, z + 1 },
        movement = { inVehicle = false, ragdoll = false, falling = false,
          parachute = -1 } }
    end

    local teleport = engine()
    assert(teleport.observe(session(1), sample(0, 0), { observedAt = clock,
      serverPosition = { 0, 0, 0 } }))
    clock = 1000
    assert(teleport.observe(session(1), sample(300, 0), { observedAt = clock,
      serverPosition = { 300, 0, 0 } }))

    local noclip = engine()
    clock = 0
    assert(noclip.observe(session(2), sample(0, 0, nil, 15), { observedAt = clock }))
    for index = 1, 3 do
      clock = index * 1000
      assert(noclip.observe(session(2), sample(index * 20, 0, nil, 15),
        { observedAt = clock }))
    end

    local freecam = engine()
    clock = 0
    assert(freecam.observe(session(3), sample(0, 0, 0), { observedAt = clock }))
    clock = 1000
    assert(freecam.observe(session(3), sample(1, 0, 100), { observedAt = clock }))
    clock = 2000
    assert(freecam.observe(session(3), sample(2, 0, 102), { observedAt = clock }))

    local jumping = engine()
    clock = 0
    assert(jumping.observe(session(4), sample(0, 0), { observedAt = clock }))
    clock = 1000
    assert(jumping.observe(session(4), sample(1, 12), { observedAt = clock }))
    clock = 2000
    assert(jumping.observe(session(4), sample(2, 24), { observedAt = clock }))

    local codes, teleportClass, noclipClass, jumpAdvisory, teleportSource =
      {}, '', '', false, 0
    for _, signal in ipairs(emitted) do
      codes[#codes + 1] = signal.code
      if signal.code == 'MOVEMENT_TELEPORT_ANOMALY' then
        teleportClass = signal.evidenceClass
        teleportSource = signal.subject.source
      elseif signal.code == 'MOVEMENT_NOCLIP_PATTERN' then
        noclipClass = signal.evidenceClass
      elseif signal.code == 'MOVEMENT_SUPER_JUMP_PATTERN' then
        jumpAdvisory = signal.evidence.advisoryOnly
      end
    end
    table.sort(codes)
    return { codes = table.concat(codes, ','), teleportClass = teleportClass,
      noclipClass = noclipClass, jumpAdvisory = jumpAdvisory,
      teleportSource = teleportSource,
      anomalies = #emitted }
  `);

  assert.deepEqual(result, {
    codes: [
      'CAMERA_FREECAM_ANOMALY',
      'MOVEMENT_NOCLIP_PATTERN',
      'MOVEMENT_SUPER_JUMP_PATTERN',
      'MOVEMENT_TELEPORT_ANOMALY',
    ].join(','),
    teleportClass: 'SERVER_DERIVED',
    noclipClass: 'BEHAVIORAL_HEURISTIC',
    jumpAdvisory: true,
    teleportSource: 1,
    anomalies: 4,
  });
});
