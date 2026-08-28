import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import { Ajv2020 } from 'ajv/dist/2020.js';

import { runWorldLua } from './helpers.ts';

const files = [
  'shared/limits.lua',
  'shared/validation.lua',
  'server/geometry.lua',
  'server/service.lua',
] as const;

test('World mutation handlers use canonical rates, audit rejection, and fence yielding actors', async () => {
  const result = await runWorldLua<string>(String.raw`
    local stateCalls, doorCalls, generation, audits = 0, 0, 1, {}
    local position, reuseSource, replaceDoor = { x = 0, y = 0, z = 0 }, true, false
    local parent = { kind = 'location', key = 'synex_test:parent', revision = 1, tags = {} }
    local children = {
      { kind = 'anchor', key = 'synex_test:child_a', revision = 1,
        parent = parent.key, tags = {}, position = { x = 0, y = 0, z = 0 }, radius = 1 },
      { kind = 'anchor', key = 'synex_test:child_b', revision = 1,
        parent = parent.key, tags = {}, position = { x = 1, y = 0, z = 0 }, radius = 1 },
    }
    local door = { kind = 'door', key = 'synex_test:fenced_door', revision = 1,
      tags = {}, defaultState = 'LOCKED', persistent = false, leaves = {},
      compiledGeometry = assert(SynexWorldGeometry.compile({ type = 'sphere',
        center = { x = 0, y = 0, z = 0 }, radius = 3 })), accessPolicy = {} }
    local registry = {}
    function registry.get(key) return key == parent.key and parent or key == door.key and door or nil end
    function registry.resolve(reference, kind)
      if reference.key == door.key and kind == 'door' and reference.revision == door.revision then
        return door
      end
      return SynexWorldValidation.failure(reference.key == door.key
        and 'STALE_WORLD_REF' or 'WORLD_NOT_FOUND', 'not found or stale')
    end
    function registry.ref(value) return { kind = value.kind, key = value.key,
      revision = value.revision } end
    function registry.currentRevision() return 1 end
    function registry.children(_, _, limit)
      local result = {}
      for index = 1, math.min(#children, limit) do result[index] = children[index] end
      return result
    end
    local service = SynexWorldService.create({
      foundation = {}, registry = registry, contextResolver = {},
      mapRegistry = { objectAvailability = function() return { available = true } end },
      stateEngine = { set = function(_, request)
        stateCalls = stateCalls + 1
        return { key = request.key, scope = { type = 'global', ref = 'global' },
          version = stateCalls, persistent = false }
      end, get = function() end },
      doorEngine = { setState = function()
        doorCalls = doorCalls + 1
        return { key = door.key, state = 'LOCKED', version = 1, persistent = false }
      end, get = function() end },
      access = { check = function()
        if reuseSource then generation = 2
        elseif replaceDoor then
          door = { kind = door.kind, key = door.key, revision = door.revision + 1,
            tags = door.tags, defaultState = door.defaultState, persistent = door.persistent,
            leaves = door.leaves, compiledGeometry = door.compiledGeometry,
            accessPolicy = door.accessPolicy }
        else position = { x = 10, y = 0, z = 0 } end
        return { decision = 'ALLOW', reason = 'fixture' }
      end, checkDoorMutation = function()
        if reuseSource then generation = 2
        elseif replaceDoor then
          door = { kind = door.kind, key = door.key, revision = door.revision + 1,
            tags = door.tags, defaultState = door.defaultState, persistent = door.persistent,
            leaves = door.leaves, compiledGeometry = door.compiledGeometry,
            accessPolicy = door.accessPolicy }
        else position = { x = 10, y = 0, z = 0 } end
        return { decision = 'ALLOW', reason = 'fixture' }
      end, explain = function() end },
      portals = { transition = function() return { transitioned = true } end },
      instances = { create = function() end, join = function() end,
        leave = function() end, close = function() end },
      bundleLoader = {}, diagnostics = {},
      observability = { audit = function(action, targetType, targetId, payload)
        audits[#audits + 1] = { action = action, targetType = targetType,
          targetId = targetId, payload = payload }
      end, increment = function() end },
      getPlayer = function(source) return { state = 'ACTIVE', source = source,
        id = generation == 1 and 'session_old' or 'session_new',
        characterId = 'character_00000091', sourceGeneration = generation } end,
      getPosition = function() return position end,
      now = function() return 0 end,
    })
    local definitions = {
      { name = 'synex.world.state.set', rateLimit = { capacity = 30, refillPerSecond = 10 } },
      { name = 'synex.world.door.set_state', rateLimit = { capacity = 30, refillPerSecond = 10 } },
      { name = 'synex.world.portal.transition', rateLimit = { capacity = 12, refillPerSecond = 3 } },
      { name = 'synex.world.instance.create', rateLimit = { capacity = 8, refillPerSecond = 1 } },
      { name = 'synex.world.instance.join', rateLimit = { capacity = 20, refillPerSecond = 5 } },
      { name = 'synex.world.instance.leave', rateLimit = { capacity = 20, refillPerSecond = 5 } },
      { name = 'synex.world.instance.close', rateLimit = { capacity = 8, refillPerSecond = 2 } },
    }
    local handlers = assert(service.contractHandlers(definitions))
    local context = { caller = 'synex_test', callerEpoch = 4,
      traceId = 'trace_service_contract_0001' }
    for index = 1, 30 do
      assert(handlers['synex.world.state.set']({ key = 'synex_test:state_' .. index }, context))
    end
    local limited, rateError = handlers['synex.world.state.set'](
      { key = 'synex_test:state_31' }, context)
    assert(limited == nil and rateError.code == 'RATE_LIMITED' and stateCalls == 30)

    local changed, staleError = handlers['synex.world.door.set_state']({
      doorRef = { kind = 'door', key = door.key, revision = door.revision }, source = 91,
      state = 'LOCKED', expectedVersion = 0, reasonCode = 'door.test',
      idempotencyKey = 'door_session_fence_0001' }, context)
    assert(changed == nil and staleError.code == 'STALE_RESOURCE' and doorCalls == 0)
    generation, reuseSource, position = 1, false, { x = 0, y = 0, z = 0 }
    local moved, contextError = handlers['synex.world.door.set_state']({
      doorRef = { kind = 'door', key = door.key, revision = door.revision }, source = 91,
      state = 'LOCKED', expectedVersion = 0, reasonCode = 'door.test',
      idempotencyKey = 'door_position_fence_0001' }, context)
    assert(moved == nil and contextError.code == 'OUT_OF_CONTEXT' and doorCalls == 0)
    generation, replaceDoor, position = 1, true, { x = 0, y = 0, z = 0 }
    local replaced, replaceError = handlers['synex.world.door.set_state']({
      doorRef = { kind = 'door', key = door.key, revision = door.revision }, source = 91,
      state = 'LOCKED', expectedVersion = 0, reasonCode = 'door.test',
      idempotencyKey = 'door_definition_fence_0001' }, context)
    assert(replaced == nil and replaceError.code == 'STALE_WORLD_REF' and doorCalls == 0)
    local invalidHandlers, definitionError = service.contractHandlers({})
    assert(invalidHandlers == nil and definitionError.code == 'UNAVAILABLE')

    local exact = assert(service.getChildren({ key = parent.key, limit = 2 }, context))
    assert(#exact.items == 2 and exact.truncated == false)
    children[3] = { kind = 'anchor', key = 'synex_test:child_c', revision = 1,
      parent = parent.key, tags = {}, position = { x = 2, y = 0, z = 0 }, radius = 1 }
    local overflow = assert(service.getChildren({ key = parent.key, limit = 2 }, context))
    assert(#overflow.items == 2 and overflow.truncated == true)
    local projectedDoor = service.projectObject({ kind = 'door', key = door.key,
      revision = door.revision, tags = {}, leaves = {}, persistent = true,
      autoRelockSeconds = 17 }, true)
    assert(projectedDoor.autoRelockSeconds == 17 and projectedDoor.autoRelock == nil)
    local sawRate, sawStale, sawContext, sawDefinition = false, false, false, false
    for _, entry in ipairs(audits) do
      sawRate = sawRate or entry.payload.code == 'RATE_LIMITED'
      sawStale = sawStale or entry.payload.code == 'STALE_RESOURCE'
      sawContext = sawContext or entry.payload.code == 'OUT_OF_CONTEXT'
      sawDefinition = sawDefinition or entry.payload.code == 'STALE_WORLD_REF'
    end
    assert(sawRate and sawStale and sawContext and sawDefinition)
    return table.concat({ stateCalls, rateError.code, staleError.code,
      contextError.code, replaceError.code, doorCalls,
      tostring(exact.truncated), tostring(overflow.truncated) }, ':')
  `, files);
  assert.equal(result,
    '30:RATE_LIMITED:STALE_RESOURCE:OUT_OF_CONTEXT:STALE_WORLD_REF:0:false:true');
});

test('World context services fence source generation across position, instance and resolution reads', async () => {
  const result = await runWorldLua<string>(String.raw`
    local generation, mode = 1, 'position'
    local resolves, verifies = 0, 0
    local service = SynexWorldService.create({
      foundation = {}, registry = {}, mapRegistry = {}, stateEngine = {}, doorEngine = {},
      access = {}, portals = {}, bundleLoader = {}, diagnostics = {},
      observability = { increment = function() end, observe = function() end },
      contextResolver = {
        resolve = function()
          resolves = resolves + 1
          if mode == 'resolve' then generation = generation + 1 end
          return { schemaVersion = 1, authority = 'VERIFIED', revision = 1,
            regions = {}, zones = {} }
        end,
        verify = function()
          verifies = verifies + 1
          return { valid = true, context = {} }
        end,
      },
      instances = { getForSource = function(_, expected)
        assert(expected.id == 'session_1' and expected.sourceGeneration == 1)
        if mode == 'instance' then generation = generation + 1 end
        return nil
      end },
      getPlayer = function(source) return { state = 'ACTIVE', source = source,
        id = 'session_' .. generation, characterId = 'character_00000033',
        sourceGeneration = generation } end,
      getPosition = function()
        if mode == 'position' then generation = generation + 1 end
        return { x = 0, y = 0, z = 0 }
      end,
      now = function() return 0 end,
    })
    local caller = { caller = 'synex_test', callerEpoch = 1,
      traceId = 'trace_context_fence_0001' }

    local _, positionError = service.getContext({ source = 33 }, caller)
    assert(positionError.code == 'STALE_RESOURCE' and resolves == 0)
    generation, mode = 1, 'instance'
    local _, instanceError = service.verifyContext({ source = 33,
      expected = { schemaVersion = 1, authority = 'VERIFIED', revision = 1,
        regions = {}, zones = {} } }, caller)
    assert(instanceError.code == 'STALE_RESOURCE' and verifies == 0)
    generation, mode = 1, 'resolve'
    local _, resolveError = service.getContext({ source = 33 }, caller)
    assert(resolveError.code == 'STALE_RESOURCE' and resolves == 1)
    return table.concat({ positionError.code, instanceError.code,
      resolveError.code, resolves, verifies }, ':')
  `, files);
  assert.equal(result, 'STALE_RESOURCE:STALE_RESOURCE:STALE_RESOURCE:1:0');
});

test('World public mutation contracts are server-only, bounded, and declare runtime failures', async () => {
  const catalog = JSON.parse(await readFile(
    'resources/synex_world/contracts/world.contracts.json', 'utf8')) as {
    contracts: Array<{ name: string; network: string; input: Record<string, unknown>;
      output: Record<string, unknown>; errors: string[];
      rateLimit: { capacity: number; refillPerSecond: number } }>;
  };
  const byName = new Map(catalog.contracts.map((definition) => [definition.name, definition]));
  for (const definition of catalog.contracts) {
    assert.equal(definition.network, 'none', definition.name);
    assert.equal(definition.input.additionalProperties, false, definition.name);
    assert.ok(definition.rateLimit.capacity > 0 && definition.rateLimit.capacity <= 30,
      definition.name);
    assert.ok(definition.rateLimit.refillPerSecond > 0, definition.name);
    assert.ok(definition.errors.includes('RATE_LIMITED'), definition.name);
    assert.ok(definition.errors.includes('STALE_RESOURCE'), definition.name);
    assert.ok(definition.errors.includes('CONCURRENT_MODIFICATION'), definition.name);
    const idempotencyKey = (definition.input as { properties: Record<string, {
      minLength?: number; maxLength?: number }> }).properties.idempotencyKey;
    assert.deepEqual({ min: idempotencyKey?.minLength, max: idempotencyKey?.maxLength },
      { min: 8, max: 36 }, definition.name);
  }
  assert.ok(byName.get('synex.world.state.set')?.errors.includes('WORLD_REFERENCE_INVALID'));
  assert.ok(byName.get('synex.world.state.set')?.errors.includes('CORE_UNAVAILABLE'));
  assert.ok(byName.get('synex.world.door.set_state')?.errors.includes('DOOR_NOT_FOUND'));
  assert.ok(byName.get('synex.world.door.set_state')?.errors.includes('CORE_UNAVAILABLE'));
  assert.ok(byName.get('synex.world.portal.transition')?.errors.includes('QUERY_LIMIT_EXCEEDED'));
  const provenance = {
    actor: { type: 'resource', ref: 'synex_test' }, sourceResource: 'synex_test',
    reasonCode: 'world.contract_test', traceId: 'trace_contract_test_0001',
    timestamp: '2026-08-27T12:00:00Z',
  };
  const stateOutput = byName.get('synex.world.state.set')?.output;
  assert.ok(stateOutput);
  assert.equal(stateOutput.additionalProperties, false);
  const validateState = new Ajv2020({ strict: true, validateFormats: false })
    .compile(stateOutput);
  const stateSample = {
    key: 'synex_test:state', scope: { type: 'global', ref: 'global' }, schemaVersion: 1,
    definitionRevision: 2, valueType: 'structured', version: 4,
    previousVersion: 3, value: { enabled: true }, persistent: true,
    replayed: false, eventId: 'world_event_00000001', provenance,
  };
  assert.equal(validateState(stateSample), true, JSON.stringify(validateState.errors));
  assert.equal(validateState({ ...stateSample, unboundedMetadata: {} }), false);

  const doorOutput = byName.get('synex.world.door.set_state')?.output;
  assert.ok(doorOutput);
  assert.equal(doorOutput.additionalProperties, false);
  const validateDoor = new Ajv2020({ strict: true, validateFormats: false })
    .compile(doorOutput);
  const doorSample = {
    key: 'synex_test:door', schemaVersion: 1, definitionRevision: 2,
    state: 'LOCKED', version: 4, previousVersion: 3, persistent: true,
    replayed: false, eventId: 'world_event_00000002', provenance,
  };
  assert.equal(validateDoor(doorSample), true, JSON.stringify(validateDoor.errors));
  assert.equal(validateDoor({ ...doorSample, unboundedMetadata: {} }), false);
  for (const name of ['synex.world.instance.join', 'synex.world.instance.leave',
    'synex.world.instance.close']) {
    assert.ok(byName.get(name)?.errors.includes('CONCURRENT_MODIFICATION'), name);
    assert.ok(byName.get(name)?.errors.includes('WORLD_ACCESS_DENIED'), name);
  }
  const instanceSample = {
    instanceId: 'world_instance_00000001',
    template: { kind: 'instance_template', key: 'synex_test:template', revision: 3 },
    ownerResource: 'synex_test', ownerEpoch: 4, state: 'ACTIVE', capacity: 32,
    members: 1, createdAt: '2026-08-27T12:00:00Z', revision: 2,
    cleanupPolicy: 'manual', bucketRef: { bucket: 17, generation: 'bucket_generation_17' },
    replayed: false,
  };
  const instanceOutputs: Record<string, object> = {
    'synex.world.instance.create': instanceSample,
    'synex.world.instance.join': instanceSample,
    'synex.world.instance.leave': {
      ...instanceSample, transitioned: true, grantId: 'wxg_00000001',
    },
    'synex.world.instance.close': { ...instanceSample, transitionedMembers: 1 },
  };
  for (const [name, sample] of Object.entries(instanceOutputs)) {
    const output = byName.get(name)?.output;
    assert.ok(output, name);
    assert.equal(output?.additionalProperties, false, name);
    const validate = new Ajv2020({ strict: true, validateFormats: false }).compile(output);
    assert.equal(validate(sample), true, `${name}: ${JSON.stringify(validate.errors)}`);
    assert.equal(validate({ ...sample, unboundedMetadata: {} }), false, name);
  }
  const portalOutput = byName.get('synex.world.portal.transition')?.output;
  assert.ok(portalOutput);
  assert.equal(portalOutput?.additionalProperties, false);
  const validatePortal = new Ajv2020({ strict: true, validateFormats: false })
    .compile(portalOutput);
  assert.equal(validatePortal({ portal: { kind: 'portal', key: 'synex_test:portal', revision: 2 },
    grantId: 'world_grant_00000001', transitioned: true, replayed: false }), true,
  JSON.stringify(validatePortal.errors));
  assert.equal(validatePortal({ portal: {}, transitioned: true }), false);
});
