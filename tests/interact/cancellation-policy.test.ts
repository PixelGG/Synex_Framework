import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { Ajv2020 } from 'ajv/dist/2020.js';

import { interactBundleFactory, runInteractLua } from './helpers.js';

const root = process.cwd();
const cancellationFiles = [
  'resources/synex_interact/shared/limits.lua',
  'resources/synex_interact/shared/validation.lua',
  'resources/synex_interact/client/cancellation.lua',
] as const;

test('bundle schema and compiler enforce a closed merged cancellation policy', async () => {
  const [schemaSource, fixtureSource] = await Promise.all([
    readFile(path.join(root, 'schemas/interaction-bundle.schema.json'), 'utf8'),
    readFile(path.join(root,
      'resources/synex_interact/interactions/terminal.interact.json'), 'utf8'),
  ]);
  const validate = new Ajv2020({ allErrors: true, strict: true,
    validateFormats: false }).compile(JSON.parse(schemaSource));
  const fixture = JSON.parse(fixtureSource) as Record<string, unknown>;
  assert.equal(validate(fixture), true, JSON.stringify(validate.errors));

  const unknown = structuredClone(fixture) as {
    graphs: Array<{ cancelPolicy: Record<string, unknown> }>;
  };
  unknown.graphs[0]!.cancelPolicy.sparkle = true;
  assert.equal(validate(unknown), false);

  const compiled = await runInteractLua<{
    death: boolean;
    move: boolean;
    moveDistance: number;
    cancelDistance: number;
    policyVisible: boolean;
    unknown: string;
    hysteresis: string;
    authorityDistance: string;
  }>(`${interactBundleFactory}
    local bundle = __interactBundle()
    bundle.graphs[1].cancelPolicy = {
      cancelOnDeath = true, cancelDistance = 1.75,
      distanceHysteresis = 0.15, distanceGraceMs = 250,
    }
    bundle.intents[1].executionPolicy.cancel = {
      cancelOnMove = true, actorMoveDistance = 0.6,
    }
    local value = assert(SynexInteractCompiler.compile(bundle, 'fixture', 1))
    local policy = value.intents['fixture:inspect'].cancelPolicy
    local projected = value.discovery[1].intents[1]

    local badUnknown = __interactBundle()
    badUnknown.graphs[1].cancelPolicy = { sparkle = true }
    local _, unknownError = SynexInteractCompiler.compile(badUnknown, 'fixture', 1)
    local badHysteresis = __interactBundle()
    badHysteresis.graphs[1].cancelPolicy = {
      cancelDistance = 1.0, distanceHysteresis = 1.0,
    }
    local _, hysteresisError = SynexInteractCompiler.compile(
      badHysteresis, 'fixture', 1)
    local badDistance = __interactBundle()
    badDistance.graphs[1].cancelPolicy = { cancelDistance = 3.0 }
    local _, distanceError = SynexInteractCompiler.compile(badDistance, 'fixture', 1)
    return {
      death = policy.cancelOnDeath,
      move = policy.cancelOnMove,
      moveDistance = policy.actorMoveDistance,
      cancelDistance = policy.cancelDistance,
      policyVisible = projected.cancelPolicy ~= nil
        and projected.executionPolicy == nil,
      unknown = unknownError.code,
      hysteresis = hysteresisError.code,
      authorityDistance = distanceError.code,
    }
  `);

  assert.deepEqual(compiled, {
    death: true,
    move: true,
    moveDistance: 0.6,
    cancelDistance: 1.75,
    policyVisible: true,
    unknown: 'INTERACT_BUNDLE_INVALID',
    hysteresis: 'INTERACT_BUNDLE_INVALID',
    authorityDistance: 'INTERACT_BUNDLE_INVALID',
  });
});

test('client cancellation policy observes bounded actor, target, world, and distance changes', async () => {
  const result = await runInteractLua<{
    disabled: string;
    moved: string;
    damaged: string;
    dead: string;
    ragdoll: string;
    vehicle: string;
    targetMoved: string;
    targetGrace: string;
    world: string;
    rangeGrace: string;
    rangeReset: string;
    invalidType: boolean;
    invalidKey: boolean;
  }>(`
    local function actor(values)
      values = values or {}
      return {
        position = values.position or { x = 0, y = 0, z = 0 },
        vehicle = values.vehicle, health = values.health or 100,
        dead = values.dead == true, ragdoll = values.ragdoll == true,
      }
    end
    local function context(values)
      values = values or {}
      return { actor = actor(values.actor),
        worldInstance = values.worldInstance or { instanceId = 'world-a' } }
    end
    local function state(policy)
      return assert(SynexInteractCancellation.create(policy, {
        actor = actor(), targetPosition = { x = 0, y = 0, z = 0 },
        worldInstance = { instanceId = 'world-a' },
      }, 1000))
    end
    local function reason(value) return value or 'NONE' end
    local stableTarget = { position = { x = 0, y = 0, z = 0 }, distance = 1.0 }

    local disabled = reason(SynexInteractCancellation.evaluate(state({}),
      context({ actor = { dead = true, ragdoll = true, health = 10,
        position = { x = 10, y = 0, z = 0 }, vehicle = 22 },
        worldInstance = { instanceId = 'world-b' } }), nil, 2000))
    local moved = reason(SynexInteractCancellation.evaluate(state({
      cancelOnMove = true, actorMoveDistance = 0.5,
    }), context({ actor = { position = { x = 0.6, y = 0, z = 0 } } }),
      stableTarget, 1001))
    local damaged = reason(SynexInteractCancellation.evaluate(state({
      cancelOnDamage = true,
    }), context({ actor = { health = 99 } }), stableTarget, 1001))
    local dead = reason(SynexInteractCancellation.evaluate(state({
      cancelOnDeath = true,
    }), context({ actor = { dead = true } }), stableTarget, 1001))
    local ragdoll = reason(SynexInteractCancellation.evaluate(state({
      cancelOnRagdoll = true,
    }), context({ actor = { ragdoll = true } }), stableTarget, 1001))
    local vehicleChanged = reason(SynexInteractCancellation.evaluate(state({
      cancelOnVehicleChange = true,
    }), context({ actor = { vehicle = 22 } }), stableTarget, 1001))
    local targetMoved = reason(SynexInteractCancellation.evaluate(state({
      cancelOnTargetMove = true, targetMoveDistance = 0.5,
    }), context(), { position = { x = 0.6, y = 0, z = 0 }, distance = 1 }, 1001))
    local targetState = state({ cancelOnTargetLoss = true, targetLossGraceMs = 500 })
    assert(SynexInteractCancellation.evaluate(targetState, context(), nil, 1499) == nil)
    local targetGrace = reason(SynexInteractCancellation.evaluate(
      targetState, context(), nil, 1500))
    local worldChanged = reason(SynexInteractCancellation.evaluate(state({
      cancelOnWorldChange = true,
    }), context({ worldInstance = { instanceId = 'world-b' } }), stableTarget, 1001))

    local rangeState = state({ cancelDistance = 2.0, distanceHysteresis = 0.2,
      distanceGraceMs = 100 })
    assert(SynexInteractCancellation.evaluate(rangeState, context(),
      { position = stableTarget.position, distance = 2.3 }, 1000) == nil)
    local rangeGrace = reason(SynexInteractCancellation.evaluate(rangeState, context(),
      { position = stableTarget.position, distance = 2.0 }, 1100))
    local resetState = state({ cancelDistance = 2.0, distanceHysteresis = 0.2,
      distanceGraceMs = 100 })
    assert(SynexInteractCancellation.evaluate(resetState, context(),
      { position = stableTarget.position, distance = 2.3 }, 1000) == nil)
    assert(SynexInteractCancellation.evaluate(resetState, context(),
      { position = stableTarget.position, distance = 1.7 }, 1050) == nil)
    assert(SynexInteractCancellation.evaluate(resetState, context(),
      { position = stableTarget.position, distance = 2.3 }, 1100) == nil)
    local rangeReset = reason(SynexInteractCancellation.evaluate(resetState, context(),
      { position = stableTarget.position, distance = 2.3 }, 1200))

    return {
      disabled = disabled, moved = moved, damaged = damaged,
      dead = dead, ragdoll = ragdoll, vehicle = vehicleChanged,
      targetMoved = targetMoved, targetGrace = targetGrace,
      world = worldChanged, rangeGrace = rangeGrace, rangeReset = rangeReset,
      invalidType = SynexInteractCancellation.normalize({ cancelOnMove = 'yes' }) == nil,
      invalidKey = SynexInteractCancellation.normalize({ sparkle = true }) == nil,
    }
  `, cancellationFiles);

  assert.deepEqual(result, {
    disabled: 'NONE',
    moved: 'ACTOR_MOVED',
    damaged: 'ACTOR_DAMAGED',
    dead: 'ACTOR_DIED',
    ragdoll: 'ACTOR_RAGDOLL',
    vehicle: 'TARGET_STATE_CHANGED',
    targetMoved: 'TARGET_MOVED',
    targetGrace: 'TARGET_GONE',
    world: 'WORLD_CHANGED',
    rangeGrace: 'OUT_OF_RANGE',
    rangeReset: 'OUT_OF_RANGE',
    invalidType: true,
    invalidKey: true,
  });
});
