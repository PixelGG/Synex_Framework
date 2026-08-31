import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory, type LuaEngine } from 'wasmoon';

const root = process.cwd();

async function load(engine: LuaEngine, relativePath: string): Promise<void> {
  await engine.doString(await readFile(path.join(root, relativePath), 'utf8'));
}

async function sensorEngine(): Promise<LuaEngine> {
  const engine = await new LuaFactory().createEngine();
  await load(engine, 'resources/synex_interact/shared/limits.lua');
  await load(engine, 'resources/synex_interact/shared/validation.lua');
  await load(engine, 'resources/synex_interact/client/cancellation.lua');
  await load(engine, 'resources/synex_interact/client/sensor.lua');
  return engine;
}

test('client sensor unions bounded providers and advances exactly one asynchronous ray', async () => {
  const engine = await sensorEngine();
  try {
    const result = await engine.doString(`
      local clock, starts, polls = 1000, 0, 0
      local pending = {}
      local ports = {
        playerPed = function() return 11 end,
        entityExists = function(entity) return entity == 11 or entity == 44 end,
        entityCoords = function(entity)
          return entity == 11 and { x = 0, y = -2, z = 0 }
            or { x = 0, y = 2, z = 0 }
        end,
        entityVelocity = function() return { x = 0, y = 0, z = 0 } end,
        entityHeading = function() return 0 end,
        vehicleForPed = function() return 0 end,
        pedDead = function() return false end,
        pedRagdoll = function() return false end,
        pedArmed = function() return false end,
        cameraPosition = function() return { x = 0, y = -2, z = 0 } end,
        cameraRotation = function() return { x = 0, y = 0, z = 0 } end,
        startLosProbe = function(...)
          starts = starts + 1
          pending[starts] = { ... }
          return starts
        end,
        shapeTestResult = function(handle)
          polls = polls + 1
          if handle == 1 then
            return 2, true, { x = 0, y = 2, z = 0 }, { x = 0, y = -1, z = 0 }, 44
          end
          return 2, false, { x = 0, y = 0, z = 0 }, { x = 0, y = 0, z = 1 }, 0
        end,
        entityModel = function() return 123 end,
        networkId = function() return 77 end,
        boneIndex = function(_, name) return name == 'boot' and 3 or -1 end,
        bonePosition = function() return { x = 0, y = 2, z = 0 } end,
      }
      local function intent(key, revision)
        return { key = key, revision = revision, verb = 'Use', label = 'Use',
          basePriority = 0, specificity = 0, trigger = 'primary',
          visibilityConditions = {}, presentation = {} }
      end
      local function slot(key)
        return { key = key, localTransform = { position = { x = 0, y = 0, z = 0 } },
          interactionRadius = 10, facingTolerance = 90, tags = {}, initialState = 'FREE' }
      end
      local objects = {
        { key = 'fixture:static', revision = 1,
          binding = { type = 'staticTransform', position = { x = 0, y = 0, z = 0 } },
          tags = {}, slots = { slot('front') },
          intents = { intent('fixture:static.use', 1) }, presentation = {} },
        { key = 'fixture:world', revision = 1,
          binding = { type = 'worldAnchor', key = 'fixture:anchor' },
          tags = {}, slots = { slot('front') },
          intents = { intent('fixture:world.use', 1) }, presentation = {} },
        { key = 'fixture:entity', revision = 1,
          binding = { type = 'entityBone', model = 123, bone = 'boot' },
          tags = {}, slots = { slot('rear') },
          intents = { intent('fixture:entity.use', 1) }, presentation = {} },
        { key = 'fixture:dynamic', revision = 1,
          binding = { type = 'dynamic', provider = 'fixture_provider:nearby',
            bindingKey = 'dynamic-1' },
          tags = {}, slots = { slot('front') },
          intents = { intent('fixture:dynamic.use', 1) }, presentation = {} },
        { key = 'fixture:actor', revision = 1,
          binding = { type = 'dynamic', provider = 'fixture_provider:actors',
            bindingKey = 'actor-1' },
          tags = {}, slots = { slot('front') },
          intents = { intent('fixture:actor.use', 1) }, presentation = {} },
        { key = 'fixture:ephemeral', revision = 1,
          binding = { type = 'dynamic', provider = 'fixture_provider:ephemeral',
            bindingKey = 'ephemeral-1' },
          tags = {}, slots = { slot('front') },
          intents = { intent('fixture:ephemeral.use', 1) }, presentation = {} },
      }
      local sensor = SynexInteractSensor.create({
        now = function() return clock end, ports = ports,
        world = {
          getContext = function() return { instance = { instanceId = 'world-a' } } end,
          nearbyAnchors = function()
            return {{ key = 'fixture:anchor', revision = 1,
              position = { x = 0.25, y = 0, z = 0 } }}
          end,
        },
      })
      assert(sensor.setInteractionAssist(true))
      assert(sensor.snapshot().interactionAssist == true)
      local invalidAssist, invalidAssistError = sensor.setInteractionAssist('yes')
      assert(invalidAssist == nil
        and invalidAssistError.code == 'INTERACT_CONTEXT_INVALID')
      assert(sensor.replaceDiscovery({ schemaVersion = 1, revision = 5,
        unchanged = false, objects = objects }))
      local callableProvider = setmetatable({}, { __call = function()
        return {{ bindingKey = 'dynamic-1', position = { x = -0.25, y = 0, z = 0 } }}
      end })
      assert(sensor.registerProvider('fixture_provider', 1,
        { key = 'fixture_provider:nearby', kind = 'dynamic' }, callableProvider))
      assert(sensor.registerProvider('fixture_provider', 1,
        { key = 'fixture_provider:actors', kind = 'actor' }, function()
          return {{ bindingKey = 'actor-1', position = { x = 0, y = 0.25, z = 0 } }}
        end))
      assert(sensor.registerProvider('fixture_provider', 1,
        { key = 'fixture_provider:ephemeral', kind = 'ephemeral' }, function()
          return {{ bindingKey = 'ephemeral-1', position = { x = 0, y = 0.5, z = 0 } }}
        end))

      local context, first, firstMetadata = assert(sensor.sample())
      assert(context.authority == 'OBSERVED' and context.worldInstance.instanceId == 'world-a')
      assert(#first == 5 and firstMetadata.expensiveCandidateCount == 5)
      for _, candidate in ipairs(first) do assert(candidate.slotAlignment > 0.9) end
      local inspector = sensor.snapshot()
      assert(inspector.pendingRay == true and inspector.context.actor.ped == nil
        and inspector.context.actor.vehicle == nil)
      assert(inspector.context.actor.movementState == 'IDLE')
      assert(inspector.context.cameraRay.origin.y == -2)
      assert(inspector.context.cameraRay.direction.y == 1)
      assert(inspector.context.worldInstance.instanceId == 'world-a')
      assert(#inspector.topCandidates >= 1 and #inspector.topCandidates <= 8)
      inspector.context.actor.position.x = 999
      assert(sensor.snapshot().context.actor.position.x == 0)
      assert(starts == 1 and polls == 0 and inspector.pendingRay == true)

      clock = clock + 50
      local _, second = assert(sensor.sample())
      assert(#second == 6 and starts == 2 and polls == 1)
      local entityCandidate
      for _, candidate in ipairs(second) do
        if candidate.objectKey == 'fixture:entity' then entityCandidate = candidate end
      end
      assert(entityCandidate and entityCandidate.exactRay == true)
      assert(entityCandidate.target.kind == 'ambient'
        and entityCandidate.target.netId == 77 and entityCandidate.target.bone == 'boot')

      clock = clock + 50
      assert(sensor.sample())
      assert(starts == 3 and polls == 2)
      assert(sensor.snapshot().pendingRay == true)
      assert(sensor.nextInterval(true) == SynexInteractLimits.sensorFocusedIntervalMs)
      assert(sensor.nextInterval(false) == SynexInteractLimits.sensorNearIntervalMs)
      assert(sensor.replaceDiscovery({ schemaVersion = 1, revision = 6,
        unchanged = false, objects = objects }))
      assert(sensor.snapshot().pendingRay == false)
      return table.concat({ #first, #second, starts, polls,
        sensor.snapshot().providers, sensor.snapshot().revision }, ':')
    `);
    assert.equal(result, '5:6:3:2:3:6');
  } finally {
    engine.global.close();
  }
});

test('client providers are scheduled off the sensor hot path and time out fail-closed', async () => {
  const engine = await sensorEngine();
  try {
    const result = await engine.doString(`
      local clock, tasks = 0, {}
      local ports = {
        playerPed = function() return 1 end,
        entityExists = function(entity) return entity == 1 end,
        entityCoords = function() return { x = 0, y = 0, z = 0 } end,
        entityVelocity = function() return { x = 0, y = 0, z = 0 } end,
        entityHeading = function() return 0 end,
        vehicleForPed = function() return 0 end,
        pedDead = function() return false end,
        pedRagdoll = function() return false end,
        cameraPosition = function() return { x = 0, y = 0, z = 1 } end,
        cameraRotation = function() return { x = 0, y = 0, z = 0 } end,
        startLosProbe = function() return 0 end,
        shapeTestResult = function() return 0 end,
        entityModel = function() return 0 end,
        networkId = function() return 0 end,
        entityFromNetworkId = function() return 0 end,
        boneIndex = function() return -1 end,
        bonePosition = function() return nil end,
      }
      local sensor = SynexInteractSensor.create({ now = function() return clock end,
        spawn = function(handler) tasks[#tasks + 1] = handler end,
        ports = ports, world = { getContext = function() return {} end,
          nearbyAnchors = function() return {} end } })
      assert(sensor.replaceDiscovery({ schemaVersion = 1, revision = 1,
        unchanged = false, objects = {{ key = 'fixture:dynamic', revision = 1,
          binding = { type = 'dynamic', provider = 'fixture:slow', bindingKey = 'slow' },
          tags = {}, slots = {{ key = 'slot', localTransform = {
            position = { x = 0, y = 0, z = 0 } }, interactionRadius = 2,
            facingTolerance = 90, tags = {}, initialState = 'FREE' }},
          intents = {{ key = 'fixture:use', revision = 1, verb = 'use', label = 'Use',
            basePriority = 0, specificity = 0, trigger = 'primary',
            visibilityConditions = {}, presentation = {} }}, presentation = {} }} }))
      assert(sensor.registerProvider('fixture', 1,
        { key = 'fixture:slow', timeoutMs = 8 }, function()
          return {{ bindingKey = 'slow', position = { x = 0, y = 1, z = 0 } }}
        end))
      local _, firstCandidates = assert(sensor.sample())
      local first = sensor.snapshot()
      clock = 20
      local _, secondCandidates = assert(sensor.sample())
      local second = sensor.snapshot()
      return { firstCandidates = #firstCandidates, secondCandidates = #secondCandidates,
        queued = #tasks, firstRunning = first.runningProviders,
        timedOut = second.timedOutProviders }
    `) as {
      firstCandidates: number;
      secondCandidates: number;
      queued: number;
      firstRunning: number;
      timedOut: number;
    };

    assert.deepEqual(result, {
      firstCandidates: 0,
      secondCandidates: 0,
      queued: 1,
      firstRunning: 1,
      timedOut: 1,
    });
  } finally {
    engine.global.close();
  }
});

test('client providers use bounded cadence, cache, round-robin starts, and concurrency', async () => {
  const engine = await sensorEngine();
  try {
    const result = await engine.doString(`
      local clock = 0
      local ports = {
        playerPed = function() return 1 end,
        entityExists = function(entity) return entity == 1 end,
        entityCoords = function() return { x = 0, y = 0, z = 0 } end,
        entityVelocity = function() return { x = 0, y = 0, z = 0 } end,
        entityHeading = function() return 0 end,
        vehicleForPed = function() return 0 end,
        pedDead = function() return false end,
        pedRagdoll = function() return false end,
        cameraPosition = function() return { x = 0, y = 0, z = 1 } end,
        cameraRotation = function() return { x = 0, y = 0, z = 0 } end,
        startLosProbe = function() return 0 end,
        shapeTestResult = function() return 0 end,
        entityModel = function() return 0 end,
        networkId = function() return 0 end,
        entityFromNetworkId = function() return 0 end,
        boneIndex = function() return -1 end,
        bonePosition = function() return nil end,
      }
      local world = { getContext = function() return {} end,
        nearbyAnchors = function() return {} end }
      local function object(index)
        local suffix = ('%02d'):format(index)
        return { key = 'fixture:object_' .. suffix, revision = 1,
          binding = { type = 'dynamic', provider = 'fixture:provider_' .. suffix,
            bindingKey = 'binding-' .. suffix }, tags = {},
          slots = {{ key = 'slot', localTransform = { position = {
            x = 0, y = 0, z = 0 } }, interactionRadius = 2,
            facingTolerance = 90, tags = {}, initialState = 'FREE' }},
          intents = {{ key = 'fixture:intent_' .. suffix, revision = 1,
            verb = 'use', label = 'Use', basePriority = 0, specificity = 0,
            trigger = 'primary', visibilityConditions = {}, presentation = {} }},
          presentation = {} }
      end

      local cadenceCalls = 0
      local cadence = SynexInteractSensor.create({ now = function() return clock end,
        ports = ports, world = world })
      assert(cadence.replaceDiscovery({ schemaVersion = 1, revision = 1,
        unchanged = false, objects = { object(1) } }))
      assert(cadence.registerProvider('fixture', 1, {
        key = 'fixture:provider_01', intervalMs = 100, cacheTtlMs = 75,
      }, function()
        cadenceCalls = cadenceCalls + 1
        return {{ bindingKey = 'binding-01', position = { x = 0, y = 10, z = 0 } }}
      end))
      local _, fresh = assert(cadence.sample())
      clock = 50
      local _, cached = assert(cadence.sample())
      clock = 80
      local _, expired = assert(cadence.sample())
      clock = 100
      local _, refreshed = assert(cadence.sample())
      local invalidInterval, intervalError = cadence.registerProvider('fixture', 1,
        { key = 'fixture:invalid_interval', intervalMs = 32 }, function() return {} end)
      local invalidCache, cacheError = cadence.registerProvider('fixture', 1,
        { key = 'fixture:invalid_cache', cacheTtlMs = 5001 }, function() return {} end)
      assert(invalidInterval == nil and intervalError.code == 'INTERACT_PROVIDER_INVALID')
      assert(invalidCache == nil and cacheError.code == 'INTERACT_PROVIDER_INVALID')

      clock = 0
      local tasks, invoked, objects = {}, {}, {}
      local bounded = SynexInteractSensor.create({ now = function() return clock end,
        spawn = function(handler) tasks[#tasks + 1] = handler end,
        ports = ports, world = world })
      for index = 1, SynexInteractLimits.maximumProviders do
        objects[index] = object(index)
      end
      assert(bounded.replaceDiscovery({ schemaVersion = 1, revision = 1,
        unchanged = false, objects = objects }))
      for index = 1, SynexInteractLimits.maximumProviders do
        local suffix = ('%02d'):format(index)
        assert(bounded.registerProvider('fixture', 1, {
          key = 'fixture:provider_' .. suffix, intervalMs = 250,
        }, function()
          invoked[#invoked + 1] = index
          return {{ bindingKey = 'binding-' .. suffix,
            position = { x = 0, y = index / 100, z = 0 } }}
        end))
      end
      assert(bounded.sample())
      local firstQueued = #tasks
      for index = 1, firstQueued do tasks[index]() end
      assert(bounded.sample())
      local secondQueued = #tasks
      assert(bounded.sample())
      assert(bounded.sample())
      assert(bounded.sample())
      local boundedSnapshot = bounded.snapshot()
      return {
        cadenceCalls = cadenceCalls,
        cadenceCandidates = { #fresh, #cached, #expired, #refreshed },
        firstQueued = firstQueued, secondQueued = secondQueued,
        totalQueued = #tasks, running = boundedSnapshot.runningProviders,
        startBudget = boundedSnapshot.providerStartBudget,
        concurrency = boundedSnapshot.providerConcurrency,
        invoked = table.concat(invoked, ','), providers = boundedSnapshot.providers,
      }
    `) as {
      cadenceCalls: number;
      cadenceCandidates: number[];
      firstQueued: number;
      secondQueued: number;
      totalQueued: number;
      running: number;
      startBudget: number;
      concurrency: number;
      invoked: string;
      providers: number;
    };

    assert.deepEqual(result, {
      cadenceCalls: 2,
      cadenceCandidates: [1, 1, 0, 1],
      firstQueued: 4,
      secondQueued: 8,
      totalQueued: 20,
      running: 16,
      startBudget: 4,
      concurrency: 16,
      invoked: '1,2,3,4',
      providers: 64,
    });
  } finally {
    engine.global.close();
  }
});

test('client discovery admits only closed, bounded visibility condition shapes', async () => {
  const engine = await sensorEngine();
  try {
    const result = await engine.doString(`
      local function snapshot(condition)
        return { schemaVersion = 1, revision = 1, unchanged = false,
          objects = {{ key = 'fixture:object', revision = 1,
            binding = { type = 'staticTransform',
              position = { x = 0, y = 0, z = 0 } }, tags = {},
            slots = {{ key = 'slot', localTransform = {
              position = { x = 0, y = 0, z = 0 } }, interactionRadius = 2,
              facingTolerance = 90, tags = {}, initialState = 'FREE' }},
            intents = {{ key = 'fixture:use', revision = 1, verb = 'use',
              label = 'Use', basePriority = 0, specificity = 0, trigger = 'primary',
              visibilityConditions = { condition }, presentation = {} }},
            presentation = {} }} }
      end
      local function sensor()
        return SynexInteractSensor.create({ now = function() return 0 end,
          ports = {}, world = {} })
      end
      local valid = sensor()
      assert(valid.replaceDiscovery(snapshot({ kind = 'evaluator',
        evaluator = 'fixture_provider:visible', arguments = { mode = 'inspect' } })))
      local unknownField = sensor()
      local admitted, invalidError = unknownField.replaceDiscovery(snapshot({
        kind = 'evaluator', evaluator = 'fixture_provider:visible', secret = true }))
      assert(admitted == nil and invalidError.code == 'INTERACT_DISCOVERY_INVALID')
      local malformed = sensor()
      local invalid, malformedError = malformed.replaceDiscovery(snapshot({
        kind = 'evaluator', evaluator = 'not-namespaced' }))
      assert(invalid == nil and malformedError.code == 'INTERACT_DISCOVERY_INVALID')
      return table.concat({ valid.snapshot().objects, invalidError.code,
        malformedError.code }, ':')
    `);
    assert.equal(result,
      '1:INTERACT_DISCOVERY_INVALID:INTERACT_DISCOVERY_INVALID');
  } finally {
    engine.global.close();
  }
});

test('client sensor keeps expensive work bounded and rejects stale discovery', async () => {
  const engine = await sensorEngine();
  try {
    const result = await engine.doString(`
      local clock = 100
      local ports = {
        playerPed = function() return 1 end,
        entityExists = function() return true end,
        entityCoords = function() return { x = 0, y = 0, z = 0 } end,
        entityVelocity = function() return { x = 0, y = 0, z = 0 } end,
        entityHeading = function() return 0 end,
        vehicleForPed = function() return 0 end,
        pedDead = function() return false end,
        pedRagdoll = function() return false end,
        pedArmed = function() return false end,
        cameraPosition = function() return { x = 0, y = -1, z = 0 } end,
        cameraRotation = function() return { x = 0, y = 0, z = 0 } end,
        startLosProbe = function() return 1 end,
        shapeTestResult = function() return 1 end,
      }
      local objects = {}
      for index = 1, 20 do
        objects[index] = {
          key = ('fixture:object.%02d'):format(index), revision = 1,
          binding = { type = 'staticTransform',
            position = { x = 0, y = index * 0.1, z = 0 } }, tags = {},
          slots = {{ key = 'slot', localTransform = { position = { x = 0, y = 0, z = 0 } },
            interactionRadius = 10, facingTolerance = 90, tags = {}, initialState = 'FREE' }},
          intents = {{ key = ('fixture:intent.%02d'):format(index), revision = 1,
            verb = 'Use', label = 'Use', basePriority = 0, specificity = 0,
            trigger = 'primary', visibilityConditions = {}, presentation = {} }},
          presentation = {},
        }
      end
      local sensor = SynexInteractSensor.create({ now = function() return clock end,
        ports = ports, world = { getContext = function() return {} end,
          nearbyAnchors = function() return {} end } })
      assert(sensor.replaceDiscovery({ schemaVersion = 1, revision = 3,
        unchanged = false, objects = objects }))
      local _, candidates, metadata = assert(sensor.sample())
      assert(#candidates == 20)
      assert(metadata.expensiveCandidateCount == SynexInteractLimits.maximumExpensiveCandidates)
      local stale, staleError = sensor.replaceDiscovery({ schemaVersion = 1, revision = 2,
        unchanged = false, objects = {} })
      assert(stale == nil and staleError.code == 'INTERACT_DISCOVERY_STALE')
      assert(sensor.snapshot().revision == 3 and sensor.snapshot().objects == 20)
      local invalid, invalidError = sensor.replaceDiscovery({ schemaVersion = 1,
        revision = 4, unchanged = false, objects = { objects[1], {} } })
      assert(invalid == nil and invalidError.code == 'INTERACT_DISCOVERY_INVALID')
      assert(sensor.snapshot().revision == 3 and sensor.snapshot().objects == 20)
      sensor.cleanup()
      assert(sensor.snapshot().active == false and sensor.snapshot().objects == 0)
      return table.concat({ #candidates, metadata.expensiveCandidateCount,
        staleError.code, invalidError.code }, ':')
    `);
    assert.equal(result,
      '20:8:INTERACT_DISCOVERY_STALE:INTERACT_DISCOVERY_INVALID');
  } finally {
    engine.global.close();
  }
});

test('client sensor consumes managed projections without pool scans or ambient identity', async () => {
  const engine = await sensorEngine();
  try {
    const result = await engine.doString(`
      local clock = 1000
      local handles = { [21] = 121, [22] = 122, [23] = 123 }
      local models = { [121] = 100, [122] = 200, [123] = 900 }
      local ports = {
        playerPed = function() return 1 end,
        entityExists = function(entity) return entity == 1 or models[entity] ~= nil end,
        entityCoords = function(entity)
          if entity == 1 then return { x = 0, y = -2, z = 0 } end
          return { x = 0, y = entity - 120, z = 0 }
        end,
        entityVelocity = function() return { x = 0, y = 0, z = 0 } end,
        entityHeading = function() return 0 end,
        vehicleForPed = function() return 0 end,
        pedDead = function() return false end,
        pedRagdoll = function() return false end,
        pedArmed = function() return false end,
        cameraPosition = function() return { x = 0, y = -2, z = 0 } end,
        cameraRotation = function() return { x = 0, y = 0, z = 0 } end,
        startLosProbe = function() return 1 end,
        shapeTestResult = function() return 1 end,
        entityFromNetworkId = function(netId) return handles[netId] or 0 end,
        entityModel = function(entity) return models[entity] end,
        networkId = function(entity) return entity - 100 end,
        boneIndex = function(_, bone) return bone == 'boot' and 3 or -1 end,
        bonePosition = function() return { x = 0, y = 3, z = 0 } end,
      }
      local function slot()
        return { key = 'use', localTransform = { position = { x = 0, y = 0, z = 0 } },
          interactionRadius = 10, facingTolerance = 90, tags = {}, initialState = 'FREE' }
      end
      local function intent(key)
        return { key = key, revision = 1, verb = 'Use', label = 'Use',
          basePriority = 0, specificity = 0, trigger = 'primary',
          visibilityConditions = {}, presentation = {} }
      end
      local objects = {
        { key = 'fixture:exact', revision = 1,
          binding = { type = 'entityRef', entityId = 'entity_exact_001', generation = 3 },
          tags = {}, slots = { slot() }, intents = { intent('fixture:exact.use') },
          presentation = {} },
        { key = 'fixture:archetype', revision = 1,
          binding = { type = 'entityArchetype', archetype = 'synex.vehicle' },
          tags = {}, slots = { slot() }, intents = { intent('fixture:archetype.use') },
          presentation = {} },
        { key = 'fixture:bone', revision = 1,
          binding = { type = 'entityBone', model = 900, bone = 'boot' },
          tags = {}, slots = { slot() }, intents = { intent('fixture:bone.use') },
          presentation = {} },
      }
      local sensor = SynexInteractSensor.create({ now = function() return clock end,
        ports = ports, world = { getContext = function() return {} end,
          nearbyAnchors = function() return {} end } })
      assert(sensor.replaceDiscovery({ schemaVersion = 1, revision = 5,
        unchanged = false, objects = objects }))
      assert(sensor.replaceEntityProjection({ schemaVersion = 1, discoveryRevision = 5,
        projectionRevision = 10, sourceGeneration = 4, bucket = 0, truncated = false,
        entities = {
          { entityRef = { entityId = 'entity_exact_001', generation = 3 }, netId = 21,
            entityType = 'object', model = 100, archetype = 'synex.prop', bucket = 0,
            position = { x = 0, y = 1, z = 0 }, heading = 0 },
          { entityRef = { entityId = 'entity_arch_001', generation = 4 }, netId = 22,
            entityType = 'vehicle', model = 200, archetype = 'synex.vehicle', bucket = 0,
            position = { x = 0, y = 2, z = 0 }, heading = 0 },
          { entityRef = { entityId = 'entity_model_001', generation = 5 }, netId = 23,
            entityType = 'vehicle', model = 900, archetype = 'synex.other', bucket = 0,
            position = { x = 0, y = 3, z = 0 }, heading = 0 },
        } }))
      local _, candidates = assert(sensor.sample())
      assert(#candidates == 3)
      local bone
      for _, candidate in ipairs(candidates) do
        assert(candidate.source == 'managed' and candidate.target.kind == 'entity'
          and candidate.target.entityRef ~= nil and candidate.target.netId == nil)
        if candidate.objectKey == 'fixture:bone' then bone = candidate end
      end
      assert(bone and bone.target.bone == 'boot')
      local stale, staleError = sensor.replaceEntityProjection({ schemaVersion = 1,
        discoveryRevision = 5, projectionRevision = 10, sourceGeneration = 4,
        bucket = 0, truncated = false, entities = {} })
      assert(stale == nil and staleError.code == 'INTERACT_DISCOVERY_STALE')
      return table.concat({ #candidates, sensor.snapshot().projectedEntities,
        bone.target.kind, staleError.code }, ':')
    `);
    assert.equal(result, '3:3:entity:INTERACT_DISCOVERY_STALE');
  } finally {
    engine.global.close();
  }
});

test('client sensor source contains no pool scan, synchronous ray or frame loop', async () => {
  const source = await readFile(path.join(
    root,
    'resources/synex_interact/client/sensor.lua',
  ), 'utf8');
  assert.doesNotMatch(source, /GetGamePool|FindFirst(?:Object|Ped|Vehicle)/u);
  assert.doesNotMatch(source, /StartExpensiveSynchronousShapeTest|Wait\(0\)/u);
  assert.match(source, /StartShapeTestLosProbe|startLosProbe/u);
  assert.match(source, /maximumExpensiveCandidates/u);
  assert.match(source, /RAY_PENDING_TIMEOUT_MS/u);
});
