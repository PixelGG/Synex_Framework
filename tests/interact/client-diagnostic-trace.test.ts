import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';

const root = process.cwd();

async function load(relativePath: string): Promise<string> {
  return readFile(path.join(root, relativePath), 'utf8');
}

test('client development trace is disabled by default, bounded, retained, and redacted', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    const [limits, validation, trace] = await Promise.all([
      load('resources/synex_interact/shared/limits.lua'),
      load('resources/synex_interact/shared/validation.lua'),
      load('resources/synex_interact/client/diagnostic_trace.lua'),
    ]);
    const result = await engine.doString(`
      assert(load(${JSON.stringify(limits)}, '@shared/limits.lua'))()
      assert(load(${JSON.stringify(validation)}, '@shared/validation.lua'))()
      assert(load(${JSON.stringify(trace)}, '@client/diagnostic_trace.lua'))()
      local clock = 1000
      local disabled = SynexInteractClientTrace.create({
        now = function() return clock end,
      })
      assert(disabled.record('input', { action = 'primary' }) == false)
      assert(disabled.snapshot().enabled == false and disabled.snapshot().count == 0)

      local recorder = SynexInteractClientTrace.create({
        now = function() return clock end, enabled = true,
      })
      assert(recorder.record('context', {
        movementState = 'IDLE', inputDevice = 'keyboard',
        position = { x = 10, y = 20, z = 30 }, playerId = 'private-player',
        actor = { name = 'private-name' }, focused = true,
      }))
      assert(recorder.record('score', { items = {{
        intentKey = 'fixture:inspect', objectKey = 'fixture:terminal',
        slotKey = 'operator', score = 0.75,
        breakdown = { base = 0.1, gaze = 0.2, distance = 0.3,
          playerId = 'private-player', position = { x = 1, y = 2, z = 3 } },
        target = { entityId = 'private-entity' },
      }}, decision = { evaluated = 4, accepted = 1, rejected = 3,
        viablePrimaryCount = 1, ambiguous = false,
        rejectionReasons = {{ code = 'TOO_FAR', count = 2 },
          { code = 'SLOT_BUSY', count = 1, candidateId = 'private-candidate' }},
        advisories = {{ code = 'CONDITION_UNKNOWN', count = 1 }} } }))
      local initial = recorder.snapshot()
      assert(initial.frames[1].data.position == nil
        and initial.frames[1].data.playerId == nil
        and initial.frames[1].data.actor == nil)
      assert(initial.frames[2].data.items[1].target == nil
        and initial.frames[2].data.items[1].breakdown.playerId == nil
        and initial.frames[2].data.items[1].breakdown.position == nil
        and initial.frames[2].data.decision.rejected == 3
        and initial.frames[2].data.decision.rejectionReasons[1].code == 'TOO_FAR'
        and initial.frames[2].data.decision.rejectionReasons[2].candidateId == nil
        and initial.frames[2].data.decision.advisories[1].code
          == 'CONDITION_UNKNOWN')
      assert(recorder.record('unknown', {}) == false)
      for index = 1, 64 do
        clock = clock + 1
        assert(recorder.record('input', {
          action = 'primary', device = 'keyboard', sequence = index,
          sessionId = 'private-session', coordinates = { x = index },
        }))
      end
      local snapshot = recorder.snapshot()
      assert(snapshot.capacity == 64 and snapshot.count == 64
        and #snapshot.frames == 64 and snapshot.frames[1].sequence == 3)
      local last = snapshot.frames[#snapshot.frames]
      assert(last.data.action == 'primary' and last.data.device == 'keyboard'
        and last.data.sequence == 64 and last.data.sessionId == nil
        and last.data.coordinates == nil)
      snapshot.frames[1].data.action = 'mutated'
      assert(recorder.snapshot().frames[1].data.action == 'primary')

      recorder.cleanup()
      assert(recorder.record('score', { items = {{
        intentKey = 'fixture:inspect', breakdown = { base = 0.1, gaze = 0.2 },
      }} }))
      local scoreFrame = recorder.snapshot().frames[1]
      assert(scoreFrame.data.items[1].intentKey == 'fixture:inspect'
        and scoreFrame.data.items[1].breakdown.base == 0.1
        and scoreFrame.data.items[1].breakdown.gaze == 0.2)
      clock = clock + SynexInteractLimits.traceRetentionMs + 1
      assert(recorder.snapshot().count == 0)
      return table.concat({ snapshot.capacity, snapshot.count,
        snapshot.frames[1].sequence, last.data.sequence }, ':')
    `);
    assert.equal(result, '64:64:3:64');
  } finally {
    engine.global.close();
  }
});

test('client runtime wires every available decision phase into diagnostics only', async () => {
  const runtime = await load('resources/synex_interact/client/runtime.lua');
  for (const phase of [
    'context', 'candidates', 'score', 'primary', 'input',
    'lease_request', 'lease_result', 'graph', 'cancel',
  ]) {
    assert.match(runtime, new RegExp(`recordTrace(?:Changed)?\\([^\\n]*'${phase}'`, 'u'));
  }
  assert.match(runtime, /trace = clientTrace\.snapshot\(\)/u);
  assert.match(runtime, /intent = intentEngine\.diagnostics\(\)/u);
  assert.match(runtime, /decision = decision/u);
  assert.doesNotMatch(runtime, /trace\s*=\s*(?:context|candidates|request|lease|command)/u);
});
