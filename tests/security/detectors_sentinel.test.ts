import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';

const root = process.cwd();
const files = [
  'resources/synex_security/shared/limits.lua',
  'resources/synex_security/shared/validation.lua',
  'resources/synex_security/server/foundation.lua',
  'resources/synex_security/server/sentinel.lua',
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

test('Sentinel validates session generation, sequence, challenge, and freshness', async () => {
  const result = await run<{
    first: boolean;
    duplicate: boolean;
    second: boolean;
    replay: string;
    stale: string;
    malicious: string;
    accepted: number;
    replays: number;
  }>(`
    local clock = 1000
    local session = { id = 'session-one', source = 41, sourceGeneration = 7,
      userId = 'user-one' }
    local sentinel = SynexSecuritySentinel.create({
      now = function() return clock end,
      resolveSession = function(source) if source == 41 then return session end end,
      reportIntervalMs = 3000,
    })
    local function sample(x)
      return { position = { x, 0, 30 }, velocity = { 0, 0, 0 },
        camera = { x, 0, 31 }, health = 200, armor = 0,
        visible = true, alpha = 255, model = 10, weapon = 20,
        movement = { inVehicle = false, ragdoll = false, falling = false,
          parachute = -1 } }
    end
    local context = { source = 41, sourceGeneration = 7, session = session }
    local first = assert(sentinel.report({ clientEpoch = 99, sequence = 1,
      sampledAtMs = 200, challengeRef = 'bootstrap', sample = sample(0) }, context))
    local duplicate = assert(sentinel.report({ clientEpoch = 99, sequence = 1,
      sampledAtMs = 200, challengeRef = 'bootstrap', sample = sample(0) }, context))
    clock = 4000
    local second = assert(sentinel.report({ clientEpoch = 99, sequence = 2,
      sampledAtMs = 3200, challengeRef = first.nextChallengeRef,
      sample = sample(1) }, context))
    local _, replayError = sentinel.report({ clientEpoch = 99, sequence = 2,
      sampledAtMs = 3200, challengeRef = 'wrong-ref', sample = sample(1) }, context)
    local _, staleError = sentinel.report({ clientEpoch = 99, sequence = 3,
      sampledAtMs = 6200, challengeRef = second.nextChallengeRef, sample = sample(2) },
      { source = 41, sourceGeneration = 8,
        session = { id = 'other-session', source = 41, sourceGeneration = 8 } })
    local bad = sample(2)
    bad.position[1] = 0 / 0
    local _, maliciousError = sentinel.report({ clientEpoch = 99, sequence = 3,
      sampledAtMs = 6200, challengeRef = second.nextChallengeRef, sample = bad }, context)
    local snapshot = sentinel.snapshot()
    return { first = first.accepted, duplicate = duplicate.duplicate,
      second = second.accepted, replay = replayError.code,
      stale = staleError.code, malicious = maliciousError.code,
      accepted = snapshot.accepted, replays = snapshot.replays }
  `);

  assert.deepEqual(result, {
    first: true,
    duplicate: true,
    second: true,
    replay: 'SECURITY_SENTINEL_REPLAY',
    stale: 'SECURITY_SENTINEL_STALE',
    malicious: 'SECURITY_SENTINEL_INVALID',
    accepted: 2,
    replays: 1,
  });
});

test('Sentinel liveness is bounded, advisory, and reset by a fresh epoch', async () => {
  const result = await run<{
    missing: number;
    missingCode: string;
    evidenceClass: string;
    advisory: boolean;
    subjectSource: number;
    epochsChanged: number;
    activeAfterCleanup: number;
  }>(`
    local clock, emitted = 0, {}
    local session = { id = 'session-two', source = 9, sourceGeneration = 2 }
    local sentinel = SynexSecuritySentinel.create({
      now = function() return clock end,
      resolveSession = function() return session end,
      reportIntervalMs = 1000, missingAfterMs = 2500,
      maximumClientGapMs = 10000,
      emit = function(signal) emitted[#emitted + 1] = signal end,
    })
    local sample = { position = { 0, 0, 0 }, velocity = { 0, 0, 0 },
      camera = { 0, 0, 1 }, health = 200, armor = 0, visible = true,
      alpha = 255, model = 1, weapon = 0,
      movement = { inVehicle = false, ragdoll = false, falling = false,
        parachute = -1 } }
    local context = { source = 9, sourceGeneration = 2, session = session }
    assert(sentinel.report({ clientEpoch = 1, sequence = 1, sampledAtMs = 1,
      challengeRef = 'bootstrap', sample = sample }, context))
    clock = 2500
    sentinel.sweep()
    sentinel.sweep()
    clock = 3000
    assert(sentinel.report({ clientEpoch = 2, sequence = 1, sampledAtMs = 2,
      challengeRef = 'bootstrap', sample = sample }, context))
    sentinel.cleanupSource(9, 2)
    local snapshot = sentinel.snapshot()
    return { missing = #emitted, missingCode = emitted[1].code,
      evidenceClass = emitted[1].evidenceClass,
      advisory = emitted[1].evidence.advisoryOnly,
      subjectSource = emitted[1].subject.source,
      epochsChanged = snapshot.epochsChanged,
      activeAfterCleanup = snapshot.active }
  `);

  assert.deepEqual(result, {
    missing: 1,
    missingCode: 'SECURITY_SENTINEL_MISSING',
    evidenceClass: 'SERVER_DERIVED',
    advisory: true,
    subjectSource: 9,
    epochsChanged: 1,
    activeAfterCleanup: 0,
  });
});

test('Sentinel tracks an active session before its first client report', async () => {
  const result = await run<{
    missing: number;
    awaiting: boolean;
    code: string;
  }>(`
    local clock, emitted = 0, {}
    local session = { id = 'session-before-report', source = 18,
      sourceGeneration = 4, userId = 'user-before-report' }
    local sentinel = SynexSecuritySentinel.create({
      now = function() return clock end,
      reportIntervalMs = 1000,
      missingAfterMs = 2500,
      emit = function(signal) emitted[#emitted + 1] = signal end,
    })
    assert(sentinel.track(session))
    local tracked = assert(sentinel.inspect(18, 4))
    clock = 2500
    sentinel.sweep()
    sentinel.sweep()
    return { missing = #emitted, awaiting = tracked.awaitingFirstReport,
      code = emitted[1].code }
  `);

  assert.deepEqual(result, {
    missing: 1,
    awaiting: true,
    code: 'SECURITY_SENTINEL_MISSING',
  });
});
