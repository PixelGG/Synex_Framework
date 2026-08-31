import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory, type LuaEngine } from 'wasmoon';

import { loadSchemaRegistry } from '../../tools/cli/src/schemas.ts';
import { interactBundleFactory, runInteractLua } from './helpers.js';

const root = process.cwd();

function worldBundle(kind: 'anchor' | 'door' | 'portal'): Record<string, unknown> {
  return {
    schemaVersion: 1,
    key: 'fixture:world',
    revision: 1,
    smartObjects: [{
      key: 'fixture:world',
      binding: { type: 'worldRef', kind, key: `fixture:${kind}` },
      slots: [{
        key: 'operator',
        localTransform: { position: { x: 0, y: 0, z: 0 }, heading: 0 },
        interactionRadius: 2,
        facingTolerance: 90,
        tags: ['fixture.slot.operator'],
        capacity: 1,
        initialState: 'FREE',
        availabilityPolicy: {},
      }],
      activities: ['fixture:inspect'],
      tags: ['fixture.object.world'],
      availabilityPolicy: {},
      concurrencyPolicy: { mode: 'exclusive' },
      presentation: {},
    }],
    intents: [{
      key: 'fixture:inspect',
      smartObjectKey: 'fixture:world',
      verb: 'inspect',
      label: 'Inspect object',
      basePriority: 10,
      specificity: 2,
      trigger: 'primary',
      slotSelector: 'operator',
      visibilityConditions: [],
      executionPolicy: {
        maximumDistance: 2,
        managedOnly: false,
        leaseTtlMs: 2500,
        maximumLifetimeMs: 10000,
        lockChannels: ['actor.hands'],
        cancel: {},
        privileged: false,
      },
      actionGraphRef: 'fixture:inspect_graph',
      presentation: {},
      participants: [{
        role: 'operator',
        required: true,
        slotKey: 'operator',
        capacity: 1,
        lossPolicy: 'ABORT',
      }],
    }],
    graphs: [{
      key: 'fixture:inspect_graph',
      entry: 'verify',
      nodes: [
        { key: 'verify', type: 'verifyLease', next: 'complete' },
        { key: 'complete', type: 'complete' },
      ],
      locks: ['actor.hands'],
      timeoutMs: 10000,
      cancelPolicy: {},
      participantLossPolicy: 'ABORT',
    }],
    metadata: {},
  };
}

async function sensorEngine(): Promise<LuaEngine> {
  const engine = await new LuaFactory().createEngine();
  for (const relativePath of [
    'resources/synex_interact/shared/limits.lua',
    'resources/synex_interact/shared/validation.lua',
    'resources/synex_interact/client/cancellation.lua',
    'resources/synex_interact/client/sensor.lua',
  ]) {
    await engine.doString(await readFile(path.join(root, relativePath), 'utf8'));
  }
  return engine;
}

test('worldRef schema and compiler accept only canonical anchor, door, and portal bindings', async () => {
  const schemas = await loadSchemaRegistry(root);
  for (const kind of ['anchor', 'door', 'portal'] as const) {
    const bundle = worldBundle(kind);
    assert.equal(
      schemas.interactionBundle(bundle),
      true,
      `${kind}: ${JSON.stringify(schemas.interactionBundle.errors)}`,
    );
  }

  for (const binding of [
    { type: 'worldRef', kind: 'zone', key: 'fixture:zone' },
    { type: 'worldRef', kind: 'anchor' },
    { type: 'worldRef', kind: 'door', key: 'fixture:door', unexpected: true },
  ]) {
    const bundle = worldBundle('anchor');
    (bundle.smartObjects as Array<Record<string, unknown>>)[0]!.binding = binding;
    assert.equal(schemas.interactionBundle(bundle), false, JSON.stringify(binding));
  }

  const result = await runInteractLua<{
    accepted: string;
    invalidKind: string;
    missingKey: string;
    extraField: string;
  }>(`${interactBundleFactory}
    local accepted = {}
    for _, kind in ipairs({ 'anchor', 'door', 'portal' }) do
      local bundle = __interactBundle()
      bundle.smartObjects[1].binding = {
        type = 'worldRef', kind = kind, key = 'fixture:' .. kind,
      }
      local compiled, compileError = SynexInteractCompiler.compile(bundle, 'fixture', 1)
      assert(compiled, compileError and compileError.code)
      accepted[#accepted + 1] = compiled.discovery[1].binding.kind
    end

    local invalidKind = __interactBundle()
    invalidKind.smartObjects[1].binding = {
      type = 'worldRef', kind = 'zone', key = 'fixture:zone',
    }
    local _, invalidKindError = SynexInteractCompiler.compile(invalidKind, 'fixture', 1)

    local missingKey = __interactBundle()
    missingKey.smartObjects[1].binding = { type = 'worldRef', kind = 'anchor' }
    local _, missingKeyError = SynexInteractCompiler.compile(missingKey, 'fixture', 1)

    local extraField = __interactBundle()
    extraField.smartObjects[1].binding = {
      type = 'worldRef', kind = 'door', key = 'fixture:door', unexpected = true,
    }
    local _, extraFieldError = SynexInteractCompiler.compile(extraField, 'fixture', 1)
    return {
      accepted = table.concat(accepted, ':'),
      invalidKind = invalidKindError.code,
      missingKey = missingKeyError.code,
      extraField = extraFieldError.code,
    }
  `);

  assert.deepEqual(result, {
    accepted: 'anchor:door:portal',
    invalidKind: 'INTERACT_BUNDLE_INVALID',
    missingKey: 'INTERACT_BUNDLE_INVALID',
    extraField: 'INTERACT_BUNDLE_INVALID',
  });
});

test('world target selector fences exact reference kind and key', async () => {
  const result = await runInteractLua<{
    exact: string;
    wrongKind: boolean;
    wrongKey: boolean;
    missingKind: boolean;
    legacyAnchor: boolean;
    legacyWithoutKind: boolean;
    legacyDoor: boolean;
  }>(`
    local accepted = {}
    for _, kind in ipairs({ 'anchor', 'door', 'portal' }) do
      accepted[#accepted + 1] = tostring(SynexInteractTargetSelector.matchesTarget(
        { type = 'worldRef', kind = kind, key = 'fixture:' .. kind }, nil,
        { kind = 'world', worldRef = {
          kind = kind, key = 'fixture:' .. kind, revision = 3,
        } }))
    end
    return {
      exact = table.concat(accepted, ':'),
      wrongKind = SynexInteractTargetSelector.matchesTarget(
        { type = 'worldRef', kind = 'door', key = 'fixture:door' }, nil,
        { kind = 'world', worldRef = {
          kind = 'portal', key = 'fixture:door', revision = 3,
        } }),
      wrongKey = SynexInteractTargetSelector.matchesTarget(
        { type = 'worldRef', kind = 'portal', key = 'fixture:portal' }, nil,
        { kind = 'world', worldRef = {
          kind = 'portal', key = 'fixture:other', revision = 3,
        } }),
      missingKind = SynexInteractTargetSelector.matchesTarget(
        { type = 'worldRef', kind = 'anchor', key = 'fixture:anchor' }, nil,
        { kind = 'world', worldRef = { key = 'fixture:anchor', revision = 3 } }),
      legacyAnchor = SynexInteractTargetSelector.matchesTarget(
        { type = 'worldAnchor', key = 'fixture:anchor' }, nil,
        { kind = 'world', worldRef = {
          kind = 'anchor', key = 'fixture:anchor', revision = 3,
        } }),
      legacyWithoutKind = SynexInteractTargetSelector.matchesTarget(
        { type = 'worldAnchor', key = 'fixture:anchor' }, nil,
        { kind = 'world', worldRef = { key = 'fixture:anchor', revision = 3 } }),
      legacyDoor = SynexInteractTargetSelector.matchesTarget(
        { type = 'worldAnchor', key = 'fixture:anchor' }, nil,
        { kind = 'world', worldRef = {
          kind = 'door', key = 'fixture:anchor', revision = 3,
        } }),
    }
  `);

  assert.deepEqual(result, {
    exact: 'true:true:true',
    wrongKind: false,
    wrongKey: false,
    missingKind: false,
    legacyAnchor: true,
    legacyWithoutKind: true,
    legacyDoor: false,
  });
});

test('World authority resolves canonical positions and rechecks reference and session fences', async () => {
  const result = await runInteractLua<{
    anchor: string;
    door: string;
    portal: string;
    requested: string;
    sessionChecks: number;
    staleKind: string;
    staleKey: string;
    staleRevision: string;
    renewedSession: string;
  }>(`
    local actor = { source = 41, sourceGeneration = 7,
      sessionIdentity = 'identity-0001', characterId = 'character-0001' }
    local session = { source = 41, sourceGeneration = 7, id = 'identity-0001',
      characterId = 'character-0001', state = 'ACTIVE' }
    local requested, sessionChecks = {}, 0
    local objects = {
      anchor = { kind = 'anchor', key = 'fixture:anchor', revision = 3,
        position = { x = 3, y = 4, z = 0 } },
      door = { kind = 'door', key = 'fixture:door', revision = 4,
        leaves = {
          { position = { x = 8, y = 0, z = 0 } },
          { position = { x = 0, y = 2, z = 0 } },
          { position = { x = 'invalid', y = 0, z = 0 } },
        } },
      portal = { kind = 'portal', key = 'fixture:portal', revision = 5,
        source = { position = { x = 0, y = 3, z = 4 } } },
    }
    local authority = SynexInteractWorldAuthority.create({
      getWorld = function(reference, context)
        assert(context.traceId == 'trace-world-001')
        requested[#requested + 1] = table.concat({
          reference.kind, reference.key, reference.revision,
        }, '/')
        return objects[reference.kind]
      end,
      getWorldContext = function(source, context)
        assert(source == 41 and context.traceId == 'trace-world-001')
        return { instance = { instanceId = 'world-instance-a', revision = 7,
          template = { kind = 'instance_template', key = 'fixture:template', revision = 2 },
          state = 'ACTIVE' } }
      end,
      getSession = function(source)
        assert(source == 41)
        sessionChecks = sessionChecks + 1
        return session
      end,
      getPlayerPosition = function(source)
        assert(source == 41)
        return { x = 0, y = 0, z = 0 }
      end,
    })
    local function validate(kind, key, revision)
      return authority.validate({}, { kind = 'world', worldRef = {
        kind = kind, key = key, revision = revision,
      } }, actor, { traceId = 'trace-world-001' })
    end
    local anchor = assert(validate('anchor', 'fixture:anchor', 3))
    local door = assert(validate('door', 'fixture:door', 4))
    local portal = assert(validate('portal', 'fixture:portal', 5))
    assert(anchor.worldContext.instance.instanceId == 'world-instance-a')
    assert(anchor.worldInstance.instanceId == 'world-instance-a'
      and anchor.worldInstance.template.revision == 2)
    assert(door.position.x == 0 and door.position.y == 2 and door.position.z == 0)

    local function staleFor(field, value)
      local requestedRef = { kind = 'door', key = 'fixture:door', revision = 9 }
      local stale = SynexInteractWorldAuthority.create({
        getWorld = function()
          local object = { kind = requestedRef.kind, key = requestedRef.key,
            revision = requestedRef.revision, position = { x = 1, y = 0, z = 0 } }
          object[field] = value
          return object
        end,
        getWorldContext = function() return {} end,
        getSession = function() return session end,
        getPlayerPosition = function() return { x = 0, y = 0, z = 0 } end,
      })
      local _, operationError = stale.validate({}, {
        kind = 'world', worldRef = requestedRef,
      }, actor, { traceId = 'trace-world-001' })
      return operationError.code
    end

    local changedSession = session
    local renewed = SynexInteractWorldAuthority.create({
      getWorld = function(reference)
        return { kind = reference.kind, key = reference.key,
          revision = reference.revision, position = { x = 1, y = 0, z = 0 } }
      end,
      getWorldContext = function()
        changedSession = { source = 41, sourceGeneration = 8,
          id = 'identity-0002', characterId = 'character-0002', state = 'ACTIVE' }
        return { instance = { instanceId = 'world-instance-b', revision = 8,
          template = { kind = 'instance_template', key = 'fixture:template', revision = 2 },
          state = 'ACTIVE' } }
      end,
      getSession = function() return changedSession end,
      getPlayerPosition = function() return { x = 0, y = 0, z = 0 } end,
    })
    local _, renewedError = renewed.validate({}, { kind = 'world', worldRef = {
      kind = 'anchor', key = 'fixture:anchor', revision = 3,
    } }, actor, { traceId = 'trace-world-001' })

    return {
      anchor = table.concat({ anchor.distance, anchor.position.x,
        anchor.position.y, anchor.position.z }, '/'),
      door = table.concat({ door.distance, door.position.x,
        door.position.y, door.position.z }, '/'),
      portal = table.concat({ portal.distance, portal.position.x,
        portal.position.y, portal.position.z }, '/'),
      requested = table.concat(requested, ':'),
      sessionChecks = sessionChecks,
      staleKind = staleFor('kind', 'portal'),
      staleKey = staleFor('key', 'fixture:other'),
      staleRevision = staleFor('revision', 10),
      renewedSession = renewedError.code,
    }
  `);

  assert.deepEqual(result, {
    anchor: '5.0/3.0/4.0/0.0',
    door: '2.0/0.0/2.0/0.0',
    portal: '5.0/0.0/3.0/4.0',
    requested: 'anchor/fixture:anchor/3:door/fixture:door/4:portal/fixture:portal/5',
    sessionChecks: 6,
    staleKind: 'INTERACT_TARGET_STALE',
    staleKey: 'INTERACT_TARGET_STALE',
    staleRevision: 'INTERACT_TARGET_STALE',
    renewedSession: 'INTERACT_LEASE_STALE',
  });
});

test('World authority samples actor position after the yielding context boundary', async () => {
  const distance = await runInteractLua<number>(`
    local position = { x = 0, y = 0, z = 0 }
    local session = { source = 41, sourceGeneration = 7,
      id = 'identity-0001', characterId = 'character-0001', state = 'ACTIVE' }
    local authority = SynexInteractWorldAuthority.create({
      getWorld = function(reference)
        return { kind = reference.kind, key = reference.key,
          revision = reference.revision, position = { x = 0, y = 0, z = 0 } }
      end,
      getWorldContext = function()
        position = { x = 10, y = 0, z = 0 }
        return {}
      end,
      getSession = function() return session end,
      getPlayerPosition = function() return position end,
    })
    local canonical = assert(authority.validate({}, { kind = 'world', worldRef = {
      kind = 'anchor', key = 'fixture:anchor', revision = 1,
    } }, { source = 41, sourceGeneration = 7,
      sessionIdentity = 'identity-0001', characterId = 'character-0001' }, {}))
    return canonical.distance
  `);

  assert.equal(distance, 10);
});

test('interaction leases fence the authoritative World instance across activation and renewal', async () => {
  const result = await runInteractLua<{
    activation: string;
    renewal: string;
    publicToInstance: string;
    remainingLeases: number;
  }>(`${interactBundleFactory}
    local clock, serial = 1000, 0
    local activeInstance = {
      instanceId = 'world-instance-a', revision = 1,
      template = { kind = 'instance_template', key = 'fixture:template', revision = 1 },
      state = 'ACTIVE',
    }
    local bundle = __interactBundle()
    bundle.smartObjects[1].binding = {
      type = 'worldRef', kind = 'anchor', key = 'fixture:anchor',
    }
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
      validateTarget = function()
        return { distance = 1.0, revision = 3,
          position = { x = 1, y = 0, z = 0 },
          worldInstance = SynexInteractValidation.copy(activeInstance) }
      end,
      checkPolicy = function() return true end,
      observability = { denied = function() end, increment = function() end,
        trace = function() end, event = function() end, audit = function() end,
        observe = function() end },
    })
    authority.setGraphRuntime({
      start = function(session)
        assert(sessions.setExecution(session.id, 'execution-world-fence'))
        return { executionId = 'execution-world-fence', state = 'RUNNING' }
      end,
      cancel = function() return true end,
      cancelOwner = function() return 0 end,
    })
    authority.reconcileSlots()
    local function context(source)
      local session = { source = source, sourceGeneration = 1, state = 'ACTIVE',
        id = 'identity-' .. string.format('%08d', source),
        characterId = 'character-' .. string.format('%08d', source) }
      return { source = source, sourceGeneration = 1, session = session,
        traceId = 'trace-world-' .. tostring(source) }
    end
    local request = { intent = { key = 'fixture:inspect', revision = 1 },
      target = { kind = 'world', worldRef = {
        kind = 'anchor', key = 'fixture:anchor', revision = 3,
      } }, clientRevision = registry.currentRevision() }

    local activationContext = context(41)
    local activationLease = assert(authority.requestLease(request, activationContext))
    activeInstance = {
      instanceId = 'world-instance-b', revision = 1,
      template = { kind = 'instance_template', key = 'fixture:template', revision = 1 },
      state = 'ACTIVE',
    }
    local _, activationError = authority.activateLease({
      leaseId = activationLease.leaseId, nonce = activationLease.nonce,
    }, activationContext)

    activeInstance = {
      instanceId = 'world-instance-a', revision = 1,
      template = { kind = 'instance_template', key = 'fixture:template', revision = 1 },
      state = 'ACTIVE',
    }
    local renewalContext = context(42)
    local renewalLease = assert(authority.requestLease(request, renewalContext))
    assert(authority.activateLease({
      leaseId = renewalLease.leaseId, nonce = renewalLease.nonce,
    }, renewalContext))
    activeInstance.revision = 2
    local _, renewalError = authority.renewLease(renewalLease.leaseId, 1000, renewalContext)

    activeInstance = false
    local publicContext = context(43)
    local publicLease = assert(authority.requestLease(request, publicContext))
    activeInstance = {
      instanceId = 'world-instance-a', revision = 1,
      template = { kind = 'instance_template', key = 'fixture:template', revision = 1 },
      state = 'ACTIVE',
    }
    local _, publicError = authority.activateLease({
      leaseId = publicLease.leaseId, nonce = publicLease.nonce,
    }, publicContext)

    return { activation = activationError.code, renewal = renewalError.code,
      publicToInstance = publicError.code,
      remainingLeases = authority.snapshot().activeLeases }
  `);

  assert.deepEqual(result, {
    activation: 'INTERACT_TARGET_STALE',
    renewal: 'INTERACT_TARGET_STALE',
    publicToInstance: 'INTERACT_TARGET_STALE',
    remainingLeases: 0,
  });
});

test('client sensor discovers bounded door and portal candidates through nearbyObjects', async () => {
  const engine = await sensorEngine();
  try {
    const result = await engine.doString(`
      local calls, starts = {}, 0
      local ports = {
        playerPed = function() return 1 end,
        entityExists = function(entity) return entity == 1 end,
        entityCoords = function() return { x = 0, y = 0, z = 0 } end,
        entityVelocity = function() return { x = 0, y = 0, z = 0 } end,
        entityHeading = function() return 0 end,
        vehicleForPed = function() return 0 end,
        pedDead = function() return false end,
        pedRagdoll = function() return false end,
        pedArmed = function() return false end,
        cameraPosition = function() return { x = 0, y = 0, z = 0 } end,
        cameraRotation = function() return { x = 0, y = 0, z = 0 } end,
        startLosProbe = function()
          starts = starts + 1
          return starts
        end,
        shapeTestResult = function()
          return 1, false, { x = 0, y = 0, z = 0 }, { x = 0, y = 0, z = 1 }, 0
        end,
      }
      local function slot(index)
        return { key = ('slot-%02d'):format(index),
          localTransform = { position = { x = 0, y = 0, z = 0 } },
          interactionRadius = 2, facingTolerance = 90,
          tags = {}, initialState = 'FREE' }
      end
      local function intent(key)
        return { key = key, revision = 1, verb = 'Use', label = 'Use',
          basePriority = 0, specificity = 0, trigger = 'primary',
          visibilityConditions = {}, presentation = {} }
      end
      local objects = {}
      for index = 1, 3 do
        for _, kind in ipairs({ 'door', 'portal' }) do
          local key = ('fixture:%s.%03d'):format(kind, index)
          local slots = {}
          for slotIndex = 1, SynexInteractLimits.maximumSlotsPerObject do
            slots[slotIndex] = slot(slotIndex)
          end
          objects[#objects + 1] = {
            key = key, revision = 1,
            binding = { type = 'worldRef', kind = kind, key = key },
            tags = {}, slots = slots, intents = { intent(key .. '.use') },
            presentation = {},
          }
        end
      end
      local sensor = SynexInteractSensor.create({
        now = function() return 1000 end,
        ports = ports,
        world = {
          getContext = function() return {} end,
          nearbyObjects = function(kind, options)
            assert(options.limit == SynexInteractLimits.maximumCandidateBatch)
            assert(options.maxDistance == SynexInteractLimits.maximumDiscoveryRadius)
            calls[#calls + 1] = kind
            local definitions = {}
            if kind == 'door' or kind == 'portal' then
              for index = 1, 3 do
                local key = ('fixture:%s.%03d'):format(kind, index)
                if kind == 'door' then
                  definitions[index] = { kind = kind, key = key, revision = 1,
                    leaves = {
                      { position = { x = 0, y = 6, z = 0 } },
                      { position = { x = 0, y = 1, z = 0 } },
                    } }
                else
                  definitions[index] = { kind = kind, key = key, revision = 1,
                    source = { position = { x = 0, y = 1, z = 0 } } }
                end
              end
            end
            return definitions
          end,
        },
      })
      assert(sensor.replaceDiscovery({ schemaVersion = 1, revision = 1,
        unchanged = false, objects = objects }))
      local _, candidates, metadata = assert(sensor.sample())
      local doorCount, portalCount = 0, 0
      for _, candidate in ipairs(candidates) do
        local ref = candidate.target.worldRef
        assert(candidate.source == 'world' and candidate.target.kind == 'world')
        assert(ref.revision == 1 and (ref.kind == 'door' or ref.kind == 'portal'))
        if ref.kind == 'door' then
          assert(candidate.position.y == 1)
          doorCount = doorCount + 1
        else portalCount = portalCount + 1 end
      end
      return table.concat({
        #candidates, metadata.candidateCount, metadata.expensiveCandidateCount,
        doorCount, portalCount, table.concat(calls, ','), starts,
      }, ':')
    `) as string;

    assert.equal(result, '128:128:8:96:32:anchor,door,portal:1');
  } finally {
    engine.global.close();
  }
});
