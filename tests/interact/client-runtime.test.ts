import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';

const root = process.cwd();

async function source(relativePath: string): Promise<string> {
  return readFile(path.join(root, relativePath), 'utf8');
}

test('client runtime registers zero-mode inputs, graph transport and bounded workers', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    const [limits, validation, foundation, observability, cancellation, sensor,
      intent, trace, runtime] = await Promise.all([
      source('resources/synex_interact/shared/limits.lua'),
      source('resources/synex_interact/shared/validation.lua'),
      source('resources/synex_interact/server/foundation.lua'),
      source('resources/synex_interact/server/observability.lua'),
      source('resources/synex_interact/client/cancellation.lua'),
      source('resources/synex_interact/client/sensor.lua'),
      source('resources/synex_interact/client/intent.lua'),
      source('resources/synex_interact/client/diagnostic_trace.lua'),
      source('resources/synex_interact/client/runtime.lua'),
    ]);
    const instrumentedRuntime = runtime.replace(
      '\nRegisterNetEvent(GRAPH_EVENT, function(command)',
      '\n__fixture.applyGraphPresentation = applyGraphPresentation\n\nRegisterNetEvent(GRAPH_EVENT, function(command)',
    ).replace(
      '\nlocal function bindUi()',
      '\n__fixture.handleInput = handleInput\n__fixture.setBloomOpen = function(value) bloomOpen = value end\n__fixture.getBloomOpen = function() return bloomOpen end\n\nlocal function bindUi()',
    );
    assert.notEqual(instrumentedRuntime, runtime);
    const result = await engine.doString(`
      __fixture = { events = {}, handlers = {}, commands = {}, mappings = {},
        exports = {}, threads = {}, timers = {}, discoveryCalls = 0,
        discoveryFailed = true }
      __fixture.uiApi = {
        ownerResource = 'synex_interact', ownerEpoch = 1,
        upsertInteraction = function(request)
          __fixture.lastInteraction = SynexInteractValidation.copy(request)
          return true
        end,
        removeInteraction = function() return true end,
        getInteractionSnapshot = function() return {} end,
        bindInteractionActions = function(handler)
          __fixture.interactionHandler = handler
          return true
        end,
        getPreferences = function()
          return { schemaVersion = 1, quality = 'BALANCED', scale = 100,
            density = 'comfortable', reducedMotion = true,
            reducedTransparency = false, highContrast = true,
            interactionAssist = true }
        end,
      }
      __fixture.discoveryObjects = function()
        local objects = {}
        for index = 1, 2 do
          objects[index] = {
            key = ('fixture:object.%02d'):format(index), revision = 2,
            binding = { type = 'staticTransform',
              position = { x = index, y = 0, z = 0 } }, tags = {},
            slots = {{ key = 'operator',
              localTransform = { position = { x = 0, y = 0, z = 0 } },
              interactionRadius = 2, facingTolerance = 90,
              tags = {}, initialState = 'FREE' }},
            intents = {{ key = ('fixture:intent.%02d'):format(index),
              revision = 2, verb = 'Use', label = 'Use',
              basePriority = 0, specificity = 0, trigger = 'primary',
              visibilityConditions = {}, cancelPolicy = {
                cancelOnMove = false, cancelOnDamage = false,
                cancelOnDeath = false, cancelOnRagdoll = false,
                cancelOnVehicleChange = false, cancelOnTargetMove = false,
                cancelOnTargetLoss = false, cancelOnWorldChange = false },
              presentation = {} }}, presentation = {},
          }
        end
        return objects
      end
      json = { decode = function(value)
        assert(value == 'snapshot:complete')
        return __fixture.discoveryObjects()
      end }
      exports = setmetatable({}, {
        __call = function(_, name, handler) __fixture.exports[name] = handler end,
        __index = function(_, resource)
          if resource == 'synex_ui' then
            return { GetAPI = function() return __fixture.uiApi end }
          end
          if resource == 'synex_core' then
            return { Call = function(_, name, version, payload)
              assert(version == '1.0.0')
              if name == 'synex.interact.metrics.report' then
                __fixture.metricPayload = SynexInteractValidation.copy(payload)
                return { accepted = true, duplicate = false,
                  nextReportAfterMs = SynexInteractLimits.metricsReportIntervalMs }
              end
              if name == 'synex.interact.discovery.snapshot' then
                __fixture.discoveryCalls = __fixture.discoveryCalls + 1
                assert(payload.knownRevision == 0 and payload.page >= 1
                  and payload.page <= 2)
                local index = payload.page
                if index == 2 and __fixture.discoveryFailed then
                  return nil, { code = 'INTERACT_DISCOVERY_STALE' }
                end
                assert(payload.snapshotRevision == (index == 1 and 0 or 2))
                return { schemaVersion = 1, revision = 2, unchanged = false,
                  page = index, pageCount = 2, complete = index == 2,
                  objectCount = 2, totalBytes = 17,
                  payload = index == 1 and 'snapshot:' or 'complete',
                }
              end
              return nil, { code = 'INTERACT_UNAVAILABLE' }
            end }
          end
          return {}
        end,
      })
      GetCurrentResourceName = function() return 'synex_interact' end
      GetGameTimer = function() return 1000 end
      PlayerPedId = function() return 1 end
      DoesEntityExist = function() return true end
      GetHashKey = function() return 7 end
      GetControlInstructionalButton = function(_, control)
        assert(control == -2147483641)
        return 't_R'
      end
      GetConvarInt = function(name, fallback)
        return name == 'synex_interact_trace' and 1 or fallback
      end
      RegisterNetEvent = function(name, handler) __fixture.events[name] = handler end
      AddEventHandler = function(name, handler) __fixture.handlers[name] = handler end
      RegisterCommand = function(name, handler) __fixture.commands[name] = handler end
      RegisterKeyMapping = function(command, label, device, key)
        __fixture.mappings[#__fixture.mappings + 1] = {
          command = command, label = label, device = device, key = key,
        }
      end
      CreateThread = function(handler) __fixture.threads[#__fixture.threads + 1] = handler end
      SetTimeout = function(delay, handler)
        __fixture.timers[#__fixture.timers + 1] = { delay = delay, handler = handler }
      end
      GetResourceState = function() return 'started' end
      GetInvokingResource = function() return 'fixture_provider' end
      assert(load(${JSON.stringify(limits)}, '@shared/limits.lua'))()
      assert(load(${JSON.stringify(validation)}, '@shared/validation.lua'))()
      assert(load(${JSON.stringify(foundation)}, '@server/foundation.lua'))()
      assert(load(${JSON.stringify(observability)}, '@server/observability.lua'))()
      assert(load(${JSON.stringify(cancellation)}, '@client/cancellation.lua'))()
      assert(load(${JSON.stringify(sensor)}, '@client/sensor.lua'))()
      assert(load(${JSON.stringify(intent)}, '@client/intent.lua'))()
      assert(load(${JSON.stringify(trace)}, '@client/diagnostic_trace.lua'))()
      assert(load(${JSON.stringify(instrumentedRuntime)}, '@client/runtime.lua'))()
      assert(__fixture.exports.GetAPI)
      assert(__fixture.events['synex_interact:client:graph'])
      assert(__fixture.handlers.onClientResourceStart and __fixture.handlers.onClientResourceStop)
      assert(#__fixture.threads == 3 and #__fixture.timers == 2)
      __fixture.timers[1].handler()
      local api = assert(__fixture.exports.GetAPI('^1.0.0'))
      assert(api.registerConditionEvaluator({ key = 'fixture_provider:visible' },
        function() return true end))
      __fixture.commands['synex-interact-cancel']()
      local diagnostics = assert(api.getDiagnostics())
      assert(diagnostics.sensor.interactionAssist == true
        and diagnostics.intent.interactionAssist == true
        and diagnostics.intent.effectiveMinimumDwellMs
          == SynexInteractLimits.intentAssistMinimumDwellMs
        and diagnostics.intent.decision.evaluated == 0
        and diagnostics.intent.decision.rejected == 0
        and diagnostics.intent.evaluators.registered == 1
        and diagnostics.ui.preferences.interactionAssist == true
        and diagnostics.ui.preferences.reducedMotion == true
        and diagnostics.ui.preferences.highContrast == true
        and diagnostics.trace.enabled == true
        and diagnostics.trace.capacity == 64
        and diagnostics.trace.count == 1
        and diagnostics.trace.frames[1].phase == 'input')
      local mapped = {}
      for _, value in ipairs(__fixture.mappings) do mapped[value.command] = value end
      for _, action in ipairs({ 'primary', 'more', 'cancel' }) do
        assert(__fixture.commands['synex-interact-' .. action])
        assert(__fixture.commands['synex-interact-' .. action .. '-pad'])
        assert(mapped['synex-interact-' .. action].device == 'KEYBOARD')
        assert(mapped['synex-interact-' .. action .. '-pad'].device == 'PAD_DIGITALBUTTON')
      end
      for _, action in ipairs({ 'primary', 'cancel' }) do
        assert(__fixture.commands['synex-interact-' .. action .. '-mouse'])
        assert(mapped['synex-interact-' .. action .. '-mouse'].device == 'MOUSE_BUTTON')
      end
      assert(mapped['synex-interact-primary-mouse'].key == 'MOUSE_LEFT'
        and mapped['synex-interact-cancel-mouse'].key == 'MOUSE_RIGHT')
      __fixture.setBloomOpen(true)
      __fixture.commands['synex-interact-primary-mouse']()
      __fixture.commands['synex-interact-cancel-mouse']()
      assert(__fixture.getBloomOpen() == true)
      __fixture.handleInput('cancel', 'mouse', nil, true)
      assert(__fixture.getBloomOpen() == false)

      assert(__fixture.applyGraphPresentation({
        sessionId = 'session-graph-0001', executionId = 'execution-graph-0001',
        nodeKey = 'progress', sequence = 1, type = 'progress',
        presentation = { label = 'Scanning', mode = 'determinate',
          value = 7, maximum = 20, cancellable = false },
        target = { kind = 'static', bindingKey = 'fixture:terminal' },
        serverDurationMs = 0,
      }, {}))
      assert(__fixture.lastInteraction.mode == 'progress'
        and __fixture.lastInteraction.progress.mode == 'determinate'
        and __fixture.lastInteraction.progress.value == 7
        and __fixture.lastInteraction.progress.maximum == 20
        and __fixture.lastInteraction.cancellable == false)
      assert(__fixture.applyGraphPresentation({
        sessionId = 'session-graph-0001', executionId = 'execution-graph-0001',
        nodeKey = 'progress', sequence = 2, type = 'progress',
        presentation = { label = 'Waiting', mode = 'timed' },
        target = { kind = 'static', bindingKey = 'fixture:terminal' },
        serverDurationMs = 750,
      }, {}))
      assert(__fixture.lastInteraction.progress.mode == 'timed'
        and __fixture.lastInteraction.progress.elapsedMs == 0
        and __fixture.lastInteraction.progress.durationMs == 750
        and __fixture.lastInteraction.input.cancel.keyboard == 'R')
      __fixture.handlers.onClientResourceStop('fixture_provider')
      local stale, staleError = api.getDiagnostics()
      assert(stale == nil and staleError.code == 'INTERACT_OWNER_STALE')
      __fixture.handlers.onClientResourceStart('fixture_provider')
      local restarted = assert(__fixture.exports.GetAPI('^1.0.0'))
      local restartedDiagnostics = assert(restarted.getDiagnostics())
      assert(restarted.ownerEpoch > api.ownerEpoch
        and restartedDiagnostics.intent.evaluators.registered == 0)

      CreateThread = function(handler) handler() end
      __fixture.handlers.onClientResourceStart('synex_core')
      local partial = assert(restarted.getDiagnostics())
      assert(partial.sensor.revision == 0 and partial.sensor.objects == 0)
      __fixture.discoveryFailed = false
      __fixture.handlers.onClientResourceStart('synex_core')
      local complete = assert(restarted.getDiagnostics())
      assert(complete.sensor.revision == 2 and complete.sensor.objects == 2
        and __fixture.discoveryCalls == 4)

      __fixture.timers[2].handler()
      local metricPayload = assert(__fixture.metricPayload)
      local counterCount, gaugeCount = 0, 0
      for _ in pairs(metricPayload.counters) do counterCount = counterCount + 1 end
      for _ in pairs(metricPayload.gauges) do gaugeCount = gaugeCount + 1 end
      assert(counterCount == 9 and gaugeCount == 6
        and metricPayload.counters.providerTimeouts == 0)
      local received = {}
      local telemetry = SynexInteractObservability.create({
        coreRef = { value = { Metrics = {
          increment = function(name, _, amount)
            received[name] = (received[name] or 0) + amount
            return true
          end,
          gauge = function() return true end,
        } } },
        foundation = SynexInteractFoundation,
        now = function() return 10000 end,
      })
      local accepted = assert(telemetry.reportClient(metricPayload, {
        source = 10, sourceGeneration = 2,
        session = { id = 'session-metrics-0001', state = 'ACTIVE',
          source = 10, sourceGeneration = 2 },
      }))
      assert(accepted.accepted == true and accepted.duplicate == false
        and telemetry.snapshot().clientMetricSources == 1
        and received.synex_interact_client_reports_total == 1)
      return table.concat({ #__fixture.mappings, #__fixture.threads,
        #__fixture.timers }, ':')
    `);
    assert.equal(result, '8:3:3');
  } finally {
    engine.global.close();
  }
});

test('client runtime contains no pool scan, arbitrary event action or unbounded frame wait', async () => {
  const runtime = await source('resources/synex_interact/client/runtime.lua');
  assert.doesNotMatch(runtime, /GetGamePool|FindFirst(?:Object|Ped|Vehicle)/u);
  assert.doesNotMatch(runtime, /TriggerServerEvent\s*\(|Wait\(0\)/u);
  assert.doesNotMatch(runtime, /TriggerEvent\([^'"]|TriggerServerEvent\([^'"]/u);
  assert.match(runtime, /RegisterKeyMapping/u);
  assert.match(runtime, /synex_interact:client:graph/u);
  assert.match(runtime, /upsertInteraction/u);
  assert.match(runtime, /bindInteractionActions/u);
  assert.match(runtime, /getPreferences/u);
  assert.match(runtime, /UI_PREFERENCE_INTERVAL_MS = 1000/u);
  assert.match(runtime, /device == 'mouse'/u);
  assert.match(runtime, /graphCommandCurrent/u);
  assert.match(runtime, /cleanupOwnedPresentation/u);
  assert.match(runtime, /GetScreenCoordFromWorldCoord/u);
  assert.match(runtime, /projection = projection/u);
});
