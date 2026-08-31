import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { Ajv2020, type ValidateFunction } from 'ajv/dist/2020.js';

import { interactBundleFactory, runInteractLua } from './helpers.js';

type Schema = {
  type?: string;
  additionalProperties?: boolean | Schema;
  required?: string[];
  properties?: Record<string, Schema>;
  items?: Schema;
  anyOf?: Schema[];
  maxItems?: number;
  maxLength?: number;
  minimum?: number;
  maximum?: number;
};

type Contract = {
  name: string;
  input: Schema;
  output: Schema;
  errors: string[];
};

const root = process.cwd();

async function contracts(): Promise<Contract[]> {
  const source = await readFile(path.join(root,
    'resources/synex_interact/contracts/interact.contracts.json'), 'utf8');
  return (JSON.parse(source) as { contracts: Contract[] }).contracts;
}

function contractByName(values: Contract[], name: string): Contract {
  const value = values.find((entry) => entry.name === name);
  assert.ok(value, `missing contract ${name}`);
  return value;
}

function property(schema: Schema, name: string): Schema {
  const value = schema.properties?.[name];
  assert.ok(value, `missing schema property ${name}`);
  return value;
}

function compile(schema: Schema): ValidateFunction {
  return new Ajv2020({ allErrors: true, strict: true,
    validateFormats: false }).compile(schema);
}

function expectAccepted(validate: ValidateFunction, value: unknown): void {
  assert.equal(validate(value), true, JSON.stringify(validate.errors));
}

test('client metric shape and session boundary failures are fully declared', async () => {
  const collection = await contracts();
  const metrics = contractByName(collection, 'synex.interact.metrics.report');
  const counters = property(metrics.input, 'counters');
  const providerTimeouts = property(counters, 'providerTimeouts');
  assert.equal(counters.additionalProperties, false);
  assert.equal(providerTimeouts.minimum, 0);
  assert.equal(providerTimeouts.maximum, 1_000_000_000_000);

  const join = contractByName(collection, 'synex.interact.session.join');
  const leave = contractByName(collection, 'synex.interact.session.leave');
  const knownJoinCodes = [
    'INTERACT_INVALID_REQUEST',
    'INTERACT_SESSION_NOT_FOUND',
    'INTERACT_SESSION_EXPIRED',
    'INTERACT_PARTICIPANT_DENIED',
    'INTERACT_LEASE_STALE',
    'INTERACT_ACTOR_BUSY',
    'INTERACT_INTENT_NOT_FOUND',
    'INTERACT_INTENT_STALE',
    'INTERACT_BUNDLE_INVALID',
    'INTERACT_TARGET_INVALID',
    'INTERACT_TARGET_STALE',
    'INTERACT_SLOT_NOT_FOUND',
    'INTERACT_SLOT_BUSY',
    'INTERACT_SLOT_DISABLED',
    'INTERACT_SLOT_LOST',
    'INTERACT_RESERVATION_INVALID',
    'INTERACT_LEASE_DENIED',
    'INTERACT_PROVIDER_UNAVAILABLE',
    'INTERACT_PROVIDER_TIMEOUT',
    'INTERACT_EVALUATOR_UNAVAILABLE',
    'INTERACT_EVALUATOR_TIMEOUT',
    'INTERACT_EVALUATOR_INVALID',
    'INTERACT_ADAPTER_MISSING',
    'INTERACT_DOMAIN_REJECTED',
    'INTERACT_RATE_LIMITED',
    'INTERACT_UNAVAILABLE',
  ];
  const knownLeaveCodes = [
    'INTERACT_SESSION_NOT_FOUND',
    'INTERACT_PARTICIPANT_DENIED',
    'INTERACT_LEASE_STALE',
    'INTERACT_RATE_LIMITED',
    'INTERACT_UNAVAILABLE',
  ];
  assert.deepEqual([...join.errors].sort(), [...knownJoinCodes].sort());
  assert.deepEqual([...leave.errors].sort(), [...knownLeaveCodes].sort());

  const boundary = await runInteractLua<Record<string, string>>(`${interactBundleFactory}
    local clock, serial = 100, 0
    local bundle = __interactBundle()
    bundle.smartObjects[1].slots[2] = { key = 'assistant', capacity = 1,
      interactionRadius = 2.0, facingTolerance = 90, tags = {} }
    bundle.intents[1].participants[2] = { role = 'assistant', required = false,
      slotKey = 'assistant', capacity = 1, lossPolicy = 'CONTINUE' }
    local registry = SynexInteractRegistry.create({ compiler = SynexInteractCompiler,
      isOwnerCurrent = function(owner, epoch) return owner == 'fixture' and epoch == 1 end })
    assert(registry.register('fixture', 1, bundle))
    local slots = SynexInteractSlots.create({ now = function() return clock end })
    local sessions = SynexInteractSessions.create({ now = function() return clock end })
    local authority = SynexInteractAuthority.create({ registry = registry, slots = slots,
      sessions = sessions, locks = SynexInteractActorLocks.create(),
      now = function() return clock end,
      nextId = function(namespace)
        serial = serial + 1
        return namespace .. '-' .. string.format('%08d', serial)
      end,
      validateTarget = function() return { distance = 1, revision = 1 } end,
      checkPolicy = function() return true end,
      observability = { denied = function() end, increment = function() end,
        trace = function() end, event = function() end, audit = function() end,
        observe = function() end },
    })
    authority.reconcileSlots()
    local context = { source = 10, sourceGeneration = 1,
      session = { source = 10, sourceGeneration = 1, state = 'ACTIVE',
        id = 'identity-boundary-0001', characterId = 'character-boundary-0001' },
      traceId = 'trace-boundary-0001' }
    local function createSession(id, revision, expiresAt)
      return assert(sessions.create({ sessionId = id, ownerResource = 'fixture',
        ownerEpoch = 1, bundleKey = 'fixture:terminal', bundleRevision = revision,
        intentKey = 'fixture:inspect',
        target = { kind = 'static', bindingKey = 'fixture:terminal' },
        expiresAt = expiresAt, roles = {
          { role = 'operator', required = true, capacity = 1,
            lossPolicy = 'ABORT', slotKey = 'operator' },
          { role = 'assistant', required = false, capacity = 1,
            lossPolicy = 'CONTINUE', slotKey = 'assistant' },
        } }))
    end
    local _, joinStale = authority.joinSession({
      sessionId = 'session-missing-0001', role = 'operator',
      invitationId = 'invitation-boundary-0001' }, {})
    local _, joinMissing = authority.joinSession({
      sessionId = 'session-missing-0001', role = 'operator',
      invitationId = 'invitation-boundary-0002' }, context)
    createSession('session-open-0001', 1, 1000)
    local _, joinDenied = authority.joinSession({
      sessionId = 'session-open-0001', role = 'observer',
      invitationId = 'invitation-boundary-0003' }, context)
    createSession('session-stale-0001', 2, 1000)
    local _, joinDefinitionStale = authority.joinSession({
      sessionId = 'session-stale-0001', role = 'operator',
      invitationId = 'invitation-boundary-0004' }, context)
    createSession('session-expired-0001', 1, 99)
    local _, joinExpired = authority.joinSession({
      sessionId = 'session-expired-0001', role = 'assistant',
      invitationId = 'invitation-boundary-0005' }, context)
    local previousMaximum = SynexInteractLimits.maximumActiveLeases
    SynexInteractLimits.maximumActiveLeases = 0
    local _, joinBusy = authority.joinSession({
      sessionId = 'session-open-0001', role = 'operator',
      invitationId = 'invitation-boundary-0006' }, context)
    SynexInteractLimits.maximumActiveLeases = previousMaximum
    local _, leaveStale = authority.leaveSession({
      sessionId = 'session-open-0001' }, {})
    local _, leaveMissing = authority.leaveSession({
      sessionId = 'session-missing-0001' }, context)
    local _, leaveDenied = authority.leaveSession({
      sessionId = 'session-open-0001' }, context)
    return { joinStale = joinStale.code, joinMissing = joinMissing.code,
      joinDenied = joinDenied.code, joinDefinitionStale = joinDefinitionStale.code,
      joinExpired = joinExpired.code, joinBusy = joinBusy.code,
      leaveStale = leaveStale.code, leaveMissing = leaveMissing.code,
      leaveDenied = leaveDenied.code }
  `);
  for (const [outcome, code] of Object.entries(boundary)) {
    const declared = outcome.startsWith('join') ? join.errors : leave.errors;
    assert.ok(declared.includes(code), `session boundary omits ${code}`);
  }
});

test('lease target descriptors are closed, bounded, and match Lua target variants', async () => {
  const collection = await contracts();
  const lease = contractByName(collection, 'synex.interact.lease.request');
  const target = property(lease.input, 'target');
  const worldRef = property(target, 'worldRef');
  const entityRef = property(target, 'entityRef');
  const position = property(target, 'position');
  const requestIntent = property(lease.input, 'intent');
  const responseIntent = property(lease.output, 'intent');

  assert.equal(target.additionalProperties, false);
  assert.equal(worldRef.additionalProperties, false);
  assert.equal(entityRef.additionalProperties, false);
  assert.equal(position.additionalProperties, false);
  assert.equal(requestIntent.additionalProperties, false);
  assert.equal(responseIntent.additionalProperties, false);
  assert.deepEqual(position.required, ['x', 'y', 'z']);
  assert.deepEqual(
    [property(position, 'x').minimum, property(position, 'x').maximum],
    [-20000, 20000],
  );
  assert.equal(target.anyOf?.length, 5);

  const validateRequest = compile(lease.input);
  const validTargets = [
    { kind: 'world', worldRef: { kind: 'door', key: 'fixture:front_door', revision: 4 } },
    { kind: 'entity', entityRef: { entityId: 'entity_0001', generation: 2 } },
    { kind: 'ambient', netId: 42, model: 123456, bone: 'door_dside_f' },
    { kind: 'static', bindingKey: 'fixture:terminal', position: { x: 1, y: 2, z: 3 } },
    { kind: 'dynamic', bindingKey: 'fixture:runtime_target' },
  ];
  for (const candidate of validTargets) {
    expectAccepted(validateRequest, {
      intent: { key: 'fixture:inspect', revision: 4 },
      target: candidate,
      clientRevision: 4,
    });
  }

  for (const candidate of [
    { kind: 'world', worldRef: { key: 'fixture:front_door' } },
    { kind: 'entity', entityRef: { entityId: 'entity_0001', generation: 0 } },
    { kind: 'ambient', netId: 42 },
    { kind: 'static' },
    { kind: 'dynamic', bindingKey: 'x' },
    { kind: 'static', bindingKey: 'fixture:terminal', position: { x: 20001, y: 0, z: 0 } },
    { kind: 'static', bindingKey: 'fixture:terminal', position: { x: 0, y: 0, z: 0, w: 1 } },
    { kind: 'world', worldRef: { key: 'fixture:front_door', revision: 4, secret: true } },
    { kind: 'world', worldRef: { key: 'fixture:front_door', revision: 4 }, secret: true },
  ]) {
    assert.equal(validateRequest({
      intent: { key: 'fixture:inspect', revision: 4 },
      target: candidate,
      clientRevision: 4,
    }), false, `unexpectedly accepted ${JSON.stringify(candidate)}`);
  }

  const luaParity = await runInteractLua<{
    world: boolean;
    entity: boolean;
    ambient: boolean;
    staticTarget: boolean;
    dynamic: boolean;
    missingRevision: boolean;
    unknownPositionKey: boolean;
    outOfBoundsPosition: boolean;
  }>(`
    local function accepted(value)
      local normalized = SynexInteractValidation.target(value)
      return normalized ~= nil
    end
    return {
      world = accepted({ kind = 'world', worldRef = {
        kind = 'door', key = 'fixture:front_door', revision = 4,
      }}),
      entity = accepted({ kind = 'entity', entityRef = {
        entityId = 'entity_0001', generation = 2,
      }}),
      ambient = accepted({ kind = 'ambient', netId = 42, model = 123456,
        bone = 'door_dside_f' }),
      staticTarget = accepted({ kind = 'static', bindingKey = 'fixture:terminal',
        position = { x = 1, y = 2, z = 3 } }),
      dynamic = accepted({ kind = 'dynamic', bindingKey = 'fixture:runtime_target' }),
      missingRevision = accepted({ kind = 'world',
        worldRef = { key = 'fixture:front_door' } }),
      unknownPositionKey = accepted({ kind = 'static', bindingKey = 'fixture:terminal',
        position = { x = 0, y = 0, z = 0, w = 1 } }),
      outOfBoundsPosition = accepted({ kind = 'static', bindingKey = 'fixture:terminal',
        position = { x = 20001, y = 0, z = 0 } }),
    }
  `, [
    'resources/synex_interact/shared/limits.lua',
    'resources/synex_interact/shared/validation.lua',
  ]);
  assert.deepEqual(luaParity, {
    world: true,
    entity: true,
    ambient: true,
    staticTarget: true,
    dynamic: true,
    missingRevision: false,
    unknownPositionKey: false,
    outOfBoundsPosition: false,
  });

  const validateOutput = compile(lease.output);
  const response = {
    leaseId: 'lease_0001',
    nonce: 'nonce_0001',
    state: 'ISSUED',
    intent: { key: 'fixture:inspect', revision: 4 },
    expiresAt: 1000,
    sessionId: 'session_0001',
  };
  expectAccepted(validateOutput, response);
  assert.equal(validateOutput({ ...response,
    intent: { ...response.intent, displayName: 'uncontracted' } }), false);
});

test('discovery and projected intent DTOs reject unknown fields and excess bounds', async () => {
  const collection = await contracts();
  const discovery = contractByName(collection, 'synex.interact.discovery.snapshot');
  assert.deepEqual(discovery.input.required,
    ['knownRevision', 'snapshotRevision', 'page']);
  assert.deepEqual(discovery.output.required, [
    'schemaVersion', 'revision', 'unchanged', 'page', 'pageCount', 'complete',
    'objectCount', 'totalBytes', 'payload',
  ]);
  assert.equal(property(discovery.input, 'page').maximum, 24);
  assert.equal(property(discovery.output, 'pageCount').maximum, 24);
  assert.equal(property(discovery.output, 'objectCount').maximum, 2048);
  assert.equal(property(discovery.output, 'totalBytes').maximum, 262_144);
  assert.equal(property(discovery.output, 'payload').maxLength, 14_000);

  const validate = compile(discovery.output);
  const response = {
    schemaVersion: 1,
    revision: 4,
    unchanged: false,
    page: 1,
    pageCount: 1,
    complete: true,
    objectCount: 0,
    totalBytes: 2,
    payload: '[]',
  };
  expectAccepted(validate, response);
  assert.equal(validate({ ...response, objects: [] }), false);
  assert.equal(validate({ ...response, payload: 'x'.repeat(14_001) }), false);

  const entities = contractByName(collection, 'synex.interact.discovery.entities');
  const projectedEntities = property(entities.output, 'entities');
  const projectedEntity = projectedEntities.items;
  assert.ok(projectedEntity);
  assert.equal(projectedEntity.additionalProperties, false);
  assert.equal(property(projectedEntity, 'entityRef').additionalProperties, false);
  assert.equal(property(projectedEntity, 'position').additionalProperties, false);
  assert.equal(projectedEntities.maxItems, 64);
});
