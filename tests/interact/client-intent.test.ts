import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory, type LuaEngine } from 'wasmoon';

const root = process.cwd();

async function load(engine: LuaEngine, relativePath: string): Promise<void> {
  await engine.doString(await readFile(path.join(root, relativePath), 'utf8'));
}

async function intentEngine(): Promise<LuaEngine> {
  const engine = await new LuaFactory().createEngine();
  await load(engine, 'resources/synex_interact/shared/limits.lua');
  await load(engine, 'resources/synex_interact/shared/validation.lua');
  await load(engine, 'resources/synex_interact/client/intent.lua');
  return engine;
}

test('intent arbitration is deterministic and resists jitter until dwell completes', async () => {
  const engine = await intentEngine();
  try {
    const result = await engine.doString(`
      local clock = 1000
      local engine = SynexInteractIntent.create({
        now = function() return clock end,
        switchThreshold = 0.05,
        minimumDwellMs = 120,
      })
      local context = {
        actor = { dead = false, ragdoll = false, speed = 0 },
        camera = {}, worldContext = {}, inputDevice = 'keyboard',
      }
      local function candidate(id, key, priority, gaze)
        return { id = id, objectKey = 'fixture:object', objectRevision = 1,
          slotKey = 'slot', slot = { interactionRadius = 5 },
          target = { kind = 'static', bindingKey = id,
            position = { x = 0, y = 0, z = 0 } },
          position = { x = 0, y = 0, z = 0 }, distance = 1,
          gaze = gaze, exactRay = false, source = 'spatial',
          objectTags = {}, presentation = {},
          intents = {{ key = key, revision = 1, verb = 'Use', label = key,
            basePriority = priority, specificity = 0, trigger = 'primary',
            visibilityConditions = {}, presentation = {} }},
        }
      end
      local a = candidate('fixture:a', 'fixture:intent.a', 20, 0.90)
      local b = candidate('fixture:b', 'fixture:intent.b', 10, 0.90)
      local primary = assert(engine.arbitrate(context, { b, a }))
      assert(primary.key == 'fixture:intent.a')

      -- B becomes stronger, but continuity + switch threshold + dwell hold A.
      b.intents[1].basePriority = 100
      clock = clock + 20
      primary = assert(engine.arbitrate(context, { a, b }))
      assert(primary.key == 'fixture:intent.a')
      clock = clock + 100
      primary = assert(engine.arbitrate(context, { b, a }))
      assert(primary.key == 'fixture:intent.a')
      clock = clock + 25
      primary = assert(engine.arbitrate(context, { a, b }))
      assert(primary.key == 'fixture:intent.b')

      -- Equal candidates break ties by stable namespaced key, never input order.
      engine.reset('tie')
      a.intents[1].basePriority, b.intents[1].basePriority = 0, 0
      a.gaze, b.gaze = 0.8, 0.8
      clock = clock + 10
      primary = assert(engine.arbitrate(context, { b, a }))
      assert(primary.key == 'fixture:intent.a')
      return table.concat({ primary.key, #engine.snapshot().history,
        engine.snapshot().minimumDwellMs }, ':')
    `);
    assert.equal(result, 'fixture:intent.a:4:120');
  } finally {
    engine.global.close();
  }
});

test('Interaction Assist changes only observed arbitration dwell', async () => {
  const engine = await intentEngine();
  try {
    const result = await engine.doString(`
      local clock = 1000
      local engine = SynexInteractIntent.create({ now = function() return clock end,
        switchThreshold = 0.01, minimumDwellMs = 120 })
      assert(engine.setInteractionAssist(true))
      local context = { actor = { dead = false, ragdoll = false, speed = 0 },
        camera = {}, worldContext = {}, inputDevice = 'keyboard' }
      local function candidate(id, key, priority)
        return { id = id, objectKey = 'fixture:object', objectRevision = 1,
          slotKey = 'slot', slot = { interactionRadius = 5 },
          target = { kind = 'static', bindingKey = id,
            position = { x = 0, y = 0, z = 0 } },
          position = { x = 0, y = 0, z = 0 }, distance = 1,
          gaze = 1, exactRay = false, source = 'spatial', objectTags = {},
          presentation = {}, intents = {{ key = key, revision = 1,
            verb = 'Use', label = key, basePriority = priority, specificity = 0,
            trigger = 'primary', visibilityConditions = {}, presentation = {} }} }
      end
      local a = candidate('fixture:a', 'fixture:intent.a', 20)
      local b = candidate('fixture:b', 'fixture:intent.b', 10)
      assert(assert(engine.arbitrate(context, { a, b })).key == 'fixture:intent.a')
      b.intents[1].basePriority = 100
      clock = clock + 10
      assert(assert(engine.arbitrate(context, { a, b })).key == 'fixture:intent.a')
      clock = clock + 200
      assert(assert(engine.arbitrate(context, { a, b })).key == 'fixture:intent.a')
      clock = clock + 45
      local switched = assert(engine.arbitrate(context, { a, b }))
      local invalid, invalidError = engine.setInteractionAssist('yes')
      assert(invalid == nil and invalidError.code == 'INTERACT_CONTEXT_INVALID')
      local snapshot = engine.snapshot()
      return table.concat({ switched.key, tostring(snapshot.interactionAssist),
        snapshot.minimumDwellMs, snapshot.effectiveMinimumDwellMs,
        invalidError.code }, ':')
    `);
    assert.equal(result,
      'fixture:intent.b:true:120:240:INTERACT_CONTEXT_INVALID');
  } finally {
    engine.global.close();
  }
});

test('intent engine applies observed conditions and never promotes occluded or non-primary intents', async () => {
  const engine = await intentEngine();
  try {
    const result = await engine.doString(`
      local engine = SynexInteractIntent.create({ now = function() return 100 end })
      local context = {
        actor = { dead = false, ragdoll = false, speed = 0,
          movementState = 'IDLE' },
        camera = {}, worldContext = {}, inputDevice = 'keyboard',
      }
      local function make(key, trigger, occluded, conditions)
        return { id = key .. '|candidate', objectKey = 'fixture:object',
          objectRevision = 1, slotKey = 'slot',
          slot = { interactionRadius = 5 }, position = { x = 0, y = 1, z = 0 },
          target = { kind = 'static', bindingKey = key,
            position = { x = 0, y = 1, z = 0 } },
          distance = 1, gaze = 1, exactRay = false, occluded = occluded,
          source = 'spatial', objectTags = {}, presentation = {},
          intents = {{ key = key, revision = 1, verb = 'Use', label = 'Use',
            basePriority = 100, specificity = 0, trigger = trigger,
            visibilityConditions = conditions or {}, presentation = {} }},
        }
      end
      local falseCondition = {{ kind = 'declarative', path = 'actor.movementState',
        operator = 'eq', value = 'MOVING' }}
      local primary, alternatives = engine.arbitrate(context, {
        make('fixture:occluded', 'primary', true),
        make('fixture:condition', 'primary', false, falseCondition),
        make('fixture:secondary', 'secondary', false),
        make('fixture:valid', 'primary', false),
      })
      assert(primary and primary.key == 'fixture:valid')
      assert(#alternatives == 1 and alternatives[1].key == 'fixture:secondary')
      context.actor.dead = true
      primary, alternatives = engine.arbitrate(context, {
        make('fixture:valid', 'primary', false),
      })
      assert(primary == nil and #alternatives == 0)
      return 'conditioned'
    `);
    assert.equal(result, 'conditioned');
  } finally {
    engine.global.close();
  }
});

test('intent diagnostics expose bounded client-safe rejection reasons and ambiguity', async () => {
  const engine = await intentEngine();
  try {
    const result = await engine.doString(`
      local intent = SynexInteractIntent.create({ now = function() return 100 end })
      local context = { actor = { dead = false, ragdoll = false, speed = 0,
          movementState = 'IDLE' }, camera = {}, worldContext = {},
        inputDevice = 'keyboard' }
      local function candidate(id, options)
        options = options or {}
        local slot = { interactionRadius = options.radius or 5,
          initialState = options.initialState or 'FREE' }
        return { id = id, objectKey = 'fixture:object', objectRevision = 1,
          slotKey = 'operator', slot = slot, slotState = options.slotState,
          targetState = options.targetState,
          target = { kind = 'static', bindingKey = id },
          distance = options.distance or 1, gaze = 1, exactRay = false,
          occluded = options.occluded, slotAlignment = 1,
          source = 'spatial', objectTags = {}, presentation = {},
          intents = {{ key = options.key or 'fixture:' .. id, revision = 1,
            verb = 'Use', label = 'Use', basePriority = 50, specificity = 0,
            trigger = 'primary', slotSelector = options.slotSelector,
            visibilityConditions = options.conditions or {}, presentation = {} }} }
      end
      local falseCondition = {{ kind = 'declarative',
        path = 'actor.movementState', operator = 'eq', value = 'MOVING' }}
      local unknownCondition = {{ kind = 'declarative',
        path = 'actor.movementState', operator = 'gt', value = 1 }}
      local primary = assert(intent.arbitrate(context, {
        candidate('valid-a', { conditions = unknownCondition }),
        candidate('valid-b'),
        candidate('far', { distance = 7 }),
        candidate('occluded', { occluded = true }),
        candidate('target-state', { targetState = 'UNAVAILABLE' }),
        candidate('slot-busy', { slotState = 'RESERVED' }),
        candidate('slot-disabled', { initialState = 'DISABLED' }),
        candidate('condition-false', { conditions = falseCondition }),
        candidate('slot-mismatch', { slotSelector = 'assistant' }),
      }))
      assert(primary.key == 'fixture:valid-b')
      local diagnostics = intent.diagnostics()
      local decision = diagnostics.decision
      assert(decision.evaluated == 9 and decision.accepted == 2
        and decision.rejected == 7 and decision.viablePrimaryCount == 2
        and decision.ambiguous == true, table.concat({ decision.evaluated,
          decision.accepted, decision.rejected, decision.viablePrimaryCount,
          tostring(decision.ambiguous) }, ':'))
      local function count(items, code)
        for _, item in ipairs(items) do
          assert(type(item.code) == 'string' and type(item.count) == 'number')
          if item.code == code then return item.count end
        end
        return 0
      end
      for _, code in ipairs({ 'TOO_FAR', 'OCCLUDED', 'TARGET_STATE',
          'SLOT_BUSY', 'SLOT_DISABLED', 'SLOT_MISMATCH', 'CONDITION_FALSE' }) do
        assert(count(decision.rejectionReasons, code) == 1)
      end
      assert(count(decision.advisories, 'CONDITION_UNKNOWN') == 1)
      assert(count(decision.advisories, 'AMBIGUOUS') == 1)

      local forbidden = { candidateId = true, objectKey = true, slotKey = true,
        target = true, position = true, coordinates = true, entityId = true,
        sessionId = true, playerId = true }
      local function inspect(value)
        if type(value) ~= 'table' then return end
        for key, child in pairs(value) do
          assert(not forbidden[key], 'diagnostics leaked ' .. tostring(key))
          inspect(child)
        end
      end
      inspect(diagnostics)

      context.actor.dead = true
      intent.arbitrate(context, { candidate('actor-state') })
      decision = intent.diagnostics().decision
      assert(decision.accepted == 0 and decision.rejected == 1
        and count(decision.rejectionReasons, 'WRONG_ACTOR_STATE') == 1)
      return table.concat({ diagnostics.current.intentKey,
        decision.rejectionReasons[1].code }, ':')
    `);
    assert.equal(result, 'fixture:valid-b:WRONG_ACTOR_STATE');
  } finally {
    engine.global.close();
  }
});

test('sanitized context replay is deterministic, bounded, and isolated from live arbitration', async () => {
  const engine = await intentEngine();
  try {
    const result = await engine.doString(`
      local function candidate(id, key, priority)
        return { id = id, objectKey = 'fixture:object', objectRevision = 1,
          slotKey = 'operator', slot = { interactionRadius = 5,
            initialState = 'FREE' }, target = { kind = 'static', bindingKey = id },
          distance = 1, gaze = 1, exactRay = false, slotAlignment = 1,
          source = 'fixture', objectTags = {}, presentation = {},
          intents = {{ key = key, revision = 1, verb = 'Use', label = 'Use',
            basePriority = priority, specificity = 0, trigger = 'primary',
            visibilityConditions = {}, presentation = {} }} }
      end
      local function frame(at, aPriority, bPriority)
        return { at = at,
          context = { actor = { dead = false, ragdoll = false, speed = 0 },
            camera = {}, worldContext = {}, inputDevice = 'keyboard' },
          candidates = {
            candidate('candidate-a', 'fixture:intent.a', aPriority),
            candidate('candidate-b', 'fixture:intent.b', bPriority),
          } }
      end
      local frames = { frame(0, 20, 10), frame(10, 20, 100),
        frame(150, 20, 100) }
      local first = assert(SynexInteractIntent.replay(frames,
        { switchThreshold = 0.01, minimumDwellMs = 100 }))
      local second = assert(SynexInteractIntent.replay(frames,
        { switchThreshold = 0.01, minimumDwellMs = 100 }))
      assert(first[1].primary.intentKey == 'fixture:intent.a'
        and first[2].primary.intentKey == 'fixture:intent.a'
        and first[3].primary.intentKey == 'fixture:intent.b')
      for index = 1, #first do
        assert(first[index].primary.intentKey == second[index].primary.intentKey
          and first[index].primary.score == second[index].primary.score
          and first[index].decision.ambiguous == second[index].decision.ambiguous)
      end
      local forbidden = { candidateId = true, objectKey = true, slotKey = true,
        target = true, position = true, coordinates = true, entityId = true }
      local function inspect(value)
        if type(value) ~= 'table' then return end
        for key, child in pairs(value) do
          assert(not forbidden[key], 'replay leaked ' .. tostring(key))
          inspect(child)
        end
      end
      inspect(first)

      local clock = 500
      local live = SynexInteractIntent.create({ now = function() return clock end })
      local liveContext = frames[1].context
      assert(live.arbitrate(liveContext, frames[1].candidates))
      local before = live.snapshot()
      assert(SynexInteractIntent.replay(frames))
      local after = live.snapshot()
      assert(before.current.candidateId == after.current.candidateId
        and #before.history == #after.history,
        table.concat({ tostring(before.current and before.current.candidateId),
          tostring(after.current and after.current.candidateId), #before.history,
          #after.history }, ':'))

      local cyclic = {}; cyclic[1] = cyclic
      local invalid, invalidError = SynexInteractIntent.replay({{
        context = {}, candidates = cyclic,
      }})
      assert(invalid == nil and invalidError
        and invalidError.code == 'INTERACT_REPLAY_INVALID',
        table.concat({ tostring(invalid), tostring(invalidError),
          tostring(invalidError and invalidError.code) }, ':'))
      local unknownOption, optionError = SynexInteractIntent.replay(frames,
        { invokeAuthority = true })
      assert(unknownOption == nil and optionError
        and optionError.code == 'INTERACT_REPLAY_INVALID')
      local overflow = {}
      for index = 1, 65 do overflow[index] = frames[1] end
      local tooMany, overflowError = SynexInteractIntent.replay(overflow)
      assert(tooMany == nil and overflowError
        and overflowError.code == 'INTERACT_REPLAY_INVALID')
      return table.concat({ first[1].primary.intentKey,
        first[2].primary.intentKey, first[3].primary.intentKey,
        invalidError.code, optionError.code, overflowError.code }, ':')
    `);
    assert.equal(result,
      'fixture:intent.a:fixture:intent.a:fixture:intent.b:INTERACT_REPLAY_INVALID:INTERACT_REPLAY_INVALID:INTERACT_REPLAY_INVALID');
  } finally {
    engine.global.close();
  }
});

test('client condition evaluators are asynchronous, cached, fail-closed, and owner-fenced', async () => {
  const engine = await intentEngine();
  try {
    const result = await engine.doString(`
      local clock, tasks, response, calls = 100, {}, true, 0
      local intent = SynexInteractIntent.create({
        now = function() return clock end,
        spawn = function(handler) tasks[#tasks + 1] = handler end,
      })
      local handle = assert(intent.registerEvaluator('fixture_provider', 7, {
        key = 'fixture_provider:visible', timeoutMs = 8, cacheTtlMs = 25,
      }, function(request)
        calls = calls + 1
        assert(request.schemaVersion == 1 and request.authority == 'OBSERVED'
          and request.phase == 'VISIBILITY' and request.arguments.mode == 'inspect'
          and request.context.actor.dead == false)
        return response
      end))
      local context = { actor = { dead = false, ragdoll = false, speed = 0 },
        camera = {}, worldContext = {}, inputDevice = 'keyboard' }
      local candidate = { id = 'candidate-sensitive-id', objectKey = 'fixture:object',
        objectRevision = 1, slotKey = 'operator',
        slot = { interactionRadius = 5, initialState = 'FREE' },
        target = { kind = 'static', bindingKey = 'private-target' },
        position = { x = 10, y = 20, z = 30 }, distance = 1, gaze = 1,
        exactRay = false, source = 'fixture', objectTags = {}, presentation = {},
        intents = {{ key = 'fixture:inspect', revision = 1, verb = 'Inspect',
          label = 'Inspect', basePriority = 50, specificity = 0, trigger = 'primary',
          visibilityConditions = {{ kind = 'evaluator',
            evaluator = 'fixture_provider:visible', arguments = { mode = 'inspect' } }},
          presentation = {} }},
      }
      local primary = intent.arbitrate(context, { candidate })
      assert(primary == nil and #tasks == 1 and calls == 0)
      local decision = intent.diagnostics().decision
      assert(decision.rejected == 1
        and decision.rejectionReasons[1].code == 'CONDITION_UNKNOWN')
      tasks[1]()
      primary = assert(intent.arbitrate(context, { candidate }))
      assert(primary.key == 'fixture:inspect' and calls == 1 and #tasks == 1)
      assert(intent.arbitrate(context, { candidate }))
      assert(calls == 1 and #tasks == 1)

      clock = 126
      response = false
      primary = intent.arbitrate(context, { candidate })
      assert(primary == nil and #tasks == 2 and calls == 1)
      tasks[2]()
      primary = intent.arbitrate(context, { candidate })
      decision = intent.diagnostics().decision
      assert(primary == nil and calls == 2 and decision.rejected == 1
        and decision.rejectionReasons[1].code == 'CONDITION_FALSE')

      assert(handle.unregister())
      local slow = assert(intent.registerEvaluator('fixture_provider', 7, {
        key = 'fixture_provider:slow', timeoutMs = 5, cacheTtlMs = 0,
      }, function() return true end))
      candidate.intents[1].visibilityConditions[1].evaluator = 'fixture_provider:slow'
      clock = 200
      assert(intent.arbitrate(context, { candidate }) == nil and #tasks == 3)
      clock = 206
      assert(intent.arbitrate(context, { candidate }) == nil)
      local timedOut = intent.diagnostics().evaluators
      assert(timedOut.inFlight == 1 and timedOut.timeouts == 1
        and timedOut.timedOutEntries == 1)
      tasks[3]()
      assert(slow.unregister())

      assert(intent.registerEvaluator('fixture_provider', 7, {
        key = 'fixture_provider:stale', timeoutMs = 8,
      }, function() return true end))
      candidate.intents[1].visibilityConditions[1].evaluator = 'fixture_provider:stale'
      clock = 300
      assert(intent.arbitrate(context, { candidate }) == nil and #tasks == 4)
      assert(intent.cleanupOwner('fixture_provider', 7) == 1)
      tasks[4]()
      local diagnostics = intent.diagnostics()
      assert(diagnostics.evaluators.registered == 0
        and diagnostics.evaluators.cacheEntries == 0)
      assert(intent.arbitrate(context, { candidate }) == nil)

      local serialized = ''
      local function inspect(value)
        if type(value) ~= 'table' then return end
        for key, child in pairs(value) do
          serialized = serialized .. tostring(key) .. ':' .. tostring(child) .. '|'
          inspect(child)
        end
      end
      inspect(diagnostics.evaluators)
      assert(not serialized:find('candidate%-sensitive%-id')
        and not serialized:find('private%-target')
        and not serialized:find('fixture_provider:stale', 1, true))
      return table.concat({ calls, diagnostics.evaluators.registered,
        timedOut.timeouts, decision.rejectionReasons[1].code }, ':')
    `);
    assert.equal(result, '2:0:1:CONDITION_FALSE');
  } finally {
    engine.global.close();
  }
});

test('client condition evaluator registration validates ownership and boolean results', async () => {
  const engine = await intentEngine();
  try {
    const result = await engine.doString(`
      local intent = SynexInteractIntent.create({ now = function() return 10 end })
      local wrong, wrongError = intent.registerEvaluator('fixture_provider', 1,
        { key = 'another_owner:visible' }, function() return true end)
      assert(wrong == nil and wrongError.code == 'INTERACT_EVALUATOR_INVALID')
      local handle = assert(intent.registerEvaluator('fixture_provider', 1,
        { key = 'fixture_provider:visible' }, function() return 'yes' end))
      local context = { actor = { dead = false, ragdoll = false, speed = 0 },
        camera = {}, worldContext = {}, inputDevice = 'keyboard' }
      local candidate = { id = 'fixture-candidate', objectKey = 'fixture:object',
        objectRevision = 1, slotKey = 'slot', slot = { interactionRadius = 5 },
        target = { kind = 'static', bindingKey = 'fixture-target' }, distance = 1,
        gaze = 1, exactRay = false, source = 'fixture', objectTags = {},
        presentation = {}, intents = {{ key = 'fixture:inspect', revision = 1,
          verb = 'Inspect', label = 'Inspect', basePriority = 0, specificity = 0,
          trigger = 'primary', visibilityConditions = {{ kind = 'evaluator',
            evaluator = 'fixture_provider:visible' }}, presentation = {} }} }
      assert(intent.arbitrate(context, { candidate }) == nil)
      local diagnostics = intent.diagnostics()
      assert(diagnostics.evaluators.failures == 1
        and diagnostics.evaluators.invocations == 1)
      assert(handle.unregister())
      return table.concat({ wrongError.code, diagnostics.evaluators.failures,
        diagnostics.decision.rejectionReasons[1].code }, ':')
    `);
    assert.equal(result,
      'INTERACT_EVALUATOR_INVALID:1:CONDITION_UNKNOWN');
  } finally {
    engine.global.close();
  }
});
