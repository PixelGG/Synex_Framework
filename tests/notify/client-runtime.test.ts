import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory, type LuaEngine } from 'wasmoon';

const root = process.cwd();

async function load(engine: LuaEngine, relativePath: string): Promise<void> {
  await engine.doString(await readFile(path.join(root, relativePath), 'utf8'));
}

async function clientRuntimeLua(): Promise<LuaEngine> {
  const engine = await new LuaFactory().createEngine();
  await load(engine, 'resources/synex_notify/shared/limits.lua');
  await load(engine, 'resources/synex_notify/shared/validation.lua');
  await load(engine, 'resources/synex_notify/client/engine.lua');
  await engine.doString(`
    __clientTest = {
      clock = 1000, invokingResource = 'consumer.fixture', uiFailures = 2,
      timers = {}, events = {}, handlers = {}, commands = {}, mappings = {},
      exported = {}, upserts = {}, removals = {}, coreCalls = {}, metricCalls = {},
      metricFailures = 0,
      uiGetCalls = 0,
      visibilityCalls = 0, visibilityLag = 0, uiGeneration = 0, signalState = {},
      visibleCapacity = 4, capacityCallback = nil,
      uiPreferences = { schemaVersion = 1, quality = 'BALANCED', scale = 115,
        density = 'comfortable', reducedMotion = true,
        reducedTransparency = false, highContrast = true },
      nativeFallbackPosts = 0, pulledCommands = {}, soundRequests = {},
      inputDeviceReports = {},
      resourceStates = { ['consumer.fixture'] = 'started',
        ['legacy.consumer'] = 'started', ['synex_bridge_qb'] = 'started' },
    }
    exports = setmetatable({}, {
      __call = function(_, name, handler) __clientTest.exported[name] = handler end,
    })
    exports.synex_ui = {
      GetAPI = function(_, version)
        assert(version == '^1.0.0')
        __clientTest.uiGetCalls = __clientTest.uiGetCalls + 1
        if __clientTest.uiFailures > 0 then
          __clientTest.uiFailures = __clientTest.uiFailures - 1
          return nil, { code = 'UI_NOT_READY' }
        end
        local api = {
          ownerResource = 'synex_notify', ownerEpoch = 1,
          upsertSignal = function(descriptor)
            __clientTest.upserts[#__clientTest.upserts + 1] = descriptor
            __clientTest.uiGeneration = __clientTest.uiGeneration + 1
            __clientTest.signalState[descriptor.signalId] = descriptor
            return { generation = __clientTest.uiGeneration, signal = descriptor }
          end,
          removeSignal = function(signalId, revision)
            __clientTest.removals[#__clientTest.removals + 1] = {
              signalId = signalId, revision = revision,
            }
            __clientTest.uiGeneration = __clientTest.uiGeneration + 1
            __clientTest.signalState[signalId] = nil
            return { generation = __clientTest.uiGeneration, signalId = signalId,
              revision = revision, removed = true }
          end,
          bindSignalCapacity = function(callback)
            __clientTest.capacityCallback = callback
            local accepted = callback({
              ownerResource = 'synex_notify', ownerEpoch = 1,
              capacity = __clientTest.visibleCapacity,
              preferences = __clientTest.uiPreferences,
            })
            if accepted ~= true then
              return nil, { code = 'UI_REQUEST_INVALID' }
            end
            return { capacity = __clientTest.visibleCapacity }
          end,
          getSignalSnapshot = function()
            __clientTest.visibilityCalls = __clientTest.visibilityCalls + 1
            local signals = {}
            if __clientTest.visibilityLag > 0 then
              __clientTest.visibilityLag = __clientTest.visibilityLag - 1
            else
              for _, signal in pairs(__clientTest.signalState) do
                signals[#signals + 1] = {
                  signalId = signal.signalId, revision = signal.revision, visible = true,
                }
              end
            end
            return {
              generation = __clientTest.uiGeneration,
              visibilityGeneration = __clientTest.uiGeneration,
              visibilityRevision = __clientTest.visibilityCalls,
              visibleCapacity = __clientTest.visibleCapacity,
              visibilityCapacity = __clientTest.visibleCapacity,
              signals = signals,
            }
          end,
          getPreferences = function()
            return SynexNotifyValidation.copy(__clientTest.uiPreferences)
          end,
          playSignalSound = function(request)
            __clientTest.soundRequests[#__clientTest.soundRequests + 1] = request
            return { delivered = true }
          end,
          reportInputDevice = function(device)
            __clientTest.inputDeviceReports[#__clientTest.inputDeviceReports + 1] = device
            return { device = device }
          end,
        }
        if __clientTest.omitReportInput then api.reportInputDevice = nil end
        return api
      end,
    }
    exports.synex_core = {
      Call = function(_, name, version, payload)
        if name == 'synex.notify.metrics.report' then
          __clientTest.metricCalls[#__clientTest.metricCalls + 1] = {
            name = name, version = version, payload = payload, at = __clientTest.clock,
          }
          if __clientTest.metricFailures > 0 then
            __clientTest.metricFailures = __clientTest.metricFailures - 1
            return false, { code = 'NOTIFY_TARGET_STALE', retryable = true }
          end
          return { accepted = true, duplicate = false, nextReportAfterMs = 10000 }
        end
        __clientTest.coreCalls[#__clientTest.coreCalls + 1] = {
          name = name, version = version, payload = payload,
        }
        if name == 'synex.notify.command.pull' then
          local command = __clientTest.pulledCommands[payload.commandId]
          if command == nil then return false, { code = 'NOTIFY_COMMAND_NOT_FOUND' } end
          __clientTest.pulledCommands[payload.commandId] = nil
          return SynexNotifyValidation.copy(command)
        end
        return { accepted = true }
      end,
    }
    function GetCurrentResourceName() return 'synex_notify' end
    function GetInvokingResource() return __clientTest.invokingResource end
    function GetResourceState(resource)
      return __clientTest.resourceStates[resource] or 'missing'
    end
    function GetGameTimer() return __clientTest.clock end
    function SetTimeout(delay, callback)
      __clientTest.timers[#__clientTest.timers + 1] = {
        delay = delay, at = __clientTest.clock + delay, callback = callback,
      }
    end
    function RegisterNetEvent(name, handler) __clientTest.events[name] = handler end
    function AddEventHandler(name, handler) __clientTest.handlers[name] = handler end
    function RegisterCommand(name, handler) __clientTest.commands[name] = handler end
    function RegisterKeyMapping(command, label, device, key)
      __clientTest.mappings[#__clientTest.mappings + 1] = {
        command, label, device, key,
      }
    end
    function PlayerId() return 0 end
    function GetPlayerServerId() return 42 end
    function IsUsingKeyboard() return true end
    function BeginTextCommandThefeedPost() end
    function AddTextComponentSubstringPlayerName() end
    function EndTextCommandThefeedPostTicker()
      __clientTest.nativeFallbackPosts = __clientTest.nativeFallbackPosts + 1
    end
    function PlaySoundFrontend() end
    function __clientTest.runTimer()
      local selected = 1
      for index = 2, #__clientTest.timers do
        if __clientTest.timers[index].at < __clientTest.timers[selected].at then
          selected = index
        end
      end
      local timer = table.remove(__clientTest.timers, selected)
      assert(timer)
      __clientTest.clock = math.max(__clientTest.clock, timer.at)
      timer.callback()
    end
    function __clientTest.runUntilProjectedAction()
      for _ = 1, 24 do
        for index = #__clientTest.upserts, 1, -1 do
          local candidate = __clientTest.upserts[index]
          local current = __clientTest.signalState[candidate.signalId]
          if current == candidate and candidate.actions and candidate.actions[1] then
            return candidate
          end
        end
        if #__clientTest.timers == 0 then break end
        __clientTest.runTimer()
      end
      return nil
    end
    function __clientTest.runUntilVisibilityCalls(target)
      for _ = 1, 24 do
        if __clientTest.visibilityCalls >= target then return true end
        if #__clientTest.timers == 0 then return false end
        __clientTest.runTimer()
      end
      return false
    end
    function __clientTest.runUntilCoreCalls(target)
      for _ = 1, 24 do
        if #__clientTest.coreCalls >= target then return true end
        if #__clientTest.timers == 0 then return false end
        __clientTest.runTimer()
      end
      return false
    end
    function __clientTest.runUntilUiCalls(target)
      for _ = 1, 24 do
        if __clientTest.uiGetCalls >= target then return true end
        if #__clientTest.timers == 0 then return false end
        __clientTest.runTimer()
      end
      return false
    end
    function __clientTest.runUntilMetricCalls(target)
      for _ = 1, 64 do
        if #__clientTest.metricCalls >= target then return true end
        if #__clientTest.timers == 0 then return false end
        __clientTest.runTimer()
      end
      return false
    end
    function __clientTest.stageCommand(command)
      __clientTest.pulledCommands[command.commandId] = command
      return { schemaVersion = 1, commandId = command.commandId }
    end
  `);
  await load(engine, 'resources/synex_notify/client/runtime.lua');
  return engine;
}

test('mapped Notify action commands report their actual keyboard or gamepad path without polling', async () => {
  const engine = await clientRuntimeLua();
  try {
    const result = await engine.doString(`
      assert(__clientTest.runUntilUiCalls(3))
      assert(__clientTest.uiGetCalls == 3)

      __clientTest.commands['synex-notify-action-1']()
      __clientTest.commands['synex-notify-action-2-pad']()
      __clientTest.commands['synex-notify-action-2']()
      assert(#__clientTest.inputDeviceReports == 3)
      assert(__clientTest.inputDeviceReports[1] == 'keyboard')
      assert(__clientTest.inputDeviceReports[2] == 'gamepad')
      assert(__clientTest.inputDeviceReports[3] == 'keyboard')

      local beforePreference = #__clientTest.inputDeviceReports
      __clientTest.commands['synex-notify-sound'](nil, { 'toggle' })
      assert(#__clientTest.inputDeviceReports == beforePreference)

      local mappings = {}
      for _, mapping in ipairs(__clientTest.mappings) do
        mappings[mapping[1]] = { device = mapping[3], key = mapping[4] }
      end
      assert(mappings['synex-notify-action-1'].device == 'keyboard'
        and mappings['synex-notify-action-1'].key == 'F9')
      assert(mappings['synex-notify-action-1-pad'].device == 'pad_digitalbutton'
        and mappings['synex-notify-action-1-pad'].key == 'LLEFT_INDEX')
      assert(mappings['synex-notify-action-2'].device == 'keyboard'
        and mappings['synex-notify-action-2'].key == 'F10')
      assert(mappings['synex-notify-action-2-pad'].device == 'pad_digitalbutton'
        and mappings['synex-notify-action-2-pad'].key == 'LRIGHT_INDEX')
      return table.concat(__clientTest.inputDeviceReports, ':')
    `);
    assert.equal(result, 'keyboard:gamepad:keyboard');
  } finally {
    engine.global.close();
  }
});

test('client runtime rejects an incomplete private UI facade before binding', async () => {
  const engine = await clientRuntimeLua();
  try {
    const result = await engine.doString(`
      __clientTest.uiFailures = 0
      __clientTest.omitReportInput = true
      __clientTest.runTimer()
      local api = assert(__clientTest.exported.GetAPI('^1.0.0'))
      local rejected = assert(api.getDiagnostics())
      assert(rejected.ui.bound == false)
      assert(rejected.metrics.ui_rebind_attempts == 1)
      assert(rejected.metrics.ui_rebind_failures == 1)

      __clientTest.omitReportInput = false
      assert(__clientTest.runUntilUiCalls(2))
      local rebound = assert(api.getDiagnostics())
      assert(rebound.ui.bound == true, table.concat({
        'calls=' .. tostring(__clientTest.uiGetCalls),
        'attempts=' .. tostring(rebound.metrics.ui_rebind_attempts),
        'failures=' .. tostring(rebound.metrics.ui_rebind_failures),
        'successes=' .. tostring(rebound.metrics.ui_rebind_successes),
      }, ','))
      assert(rebound.metrics.ui_rebind_successes == 1)
      return table.concat({ __clientTest.uiGetCalls,
        rejected.metrics.ui_rebind_failures,
        rebound.metrics.ui_rebind_successes }, ':')
    `);
    assert.equal(result, '2:1:1');
  } finally {
    engine.global.close();
  }
});

test('client runtime applies only current caller-bound UI capacity reports end to end', async () => {
  const engine = await clientRuntimeLua();
  try {
    const result = await engine.doString(`
      assert(__clientTest.runUntilUiCalls(3))
      assert(type(__clientTest.capacityCallback) == 'function')

      local api = assert(__clientTest.exported.GetAPI('^1.0.0'))
      for _, policy in pairs(SynexNotifyLimits.rateLimits) do
        policy.capacity = 128
        policy.refillPerSecond = 0
      end
      for index = 1, 4 do
        local shown, showError = api.show({
          kind = 'persistent', priority = 'normal',
          title = ('Capacity %d'):format(index),
        })
        assert(shown, ('capacity fixture %d failed: %s'):format(index,
          showError and showError.code or 'UNKNOWN'))
      end
      local initial = assert(api.getDiagnostics())
      assert(initial.visibleCapacity == 4 and initial.visible == 4 and initial.queued == 0)

      local rejected = __clientTest.capacityCallback({
        ownerResource = 'other.resource', ownerEpoch = 1, capacity = 2,
        preferences = __clientTest.uiPreferences,
      })
      assert(rejected == false)
      assert(api.getDiagnostics().visibleCapacity == 4)

      __clientTest.visibleCapacity = 2
      assert(__clientTest.capacityCallback({
        ownerResource = 'synex_notify', ownerEpoch = 1, capacity = 2,
        preferences = __clientTest.uiPreferences,
      }) == true)
      local constrained = assert(api.getDiagnostics())
      assert(constrained.visibleCapacity == 2)
      assert(constrained.visible == 2 and constrained.queued == 2)

      __clientTest.uiPreferences.scale = 85
      __clientTest.uiPreferences.reducedMotion = false
      assert(__clientTest.capacityCallback({
        ownerResource = 'synex_notify', ownerEpoch = 1, capacity = 2,
        preferences = __clientTest.uiPreferences,
      }) == true)
      local synchronized = assert(api.getPresentationSnapshot())
      assert(synchronized.preferences.scale == 85
        and synchronized.preferences.reducedMotion == false)

      __clientTest.visibleCapacity = 4
      assert(__clientTest.capacityCallback({
        ownerResource = 'synex_notify', ownerEpoch = 1, capacity = 4,
        preferences = __clientTest.uiPreferences,
      }) == true)
      local restored = assert(api.getDiagnostics())
      assert(restored.visibleCapacity == 4)
      assert(restored.visible == 4 and restored.queued == 0)
      return table.concat({ initial.visibleCapacity, constrained.visible,
        constrained.queued, restored.visible, restored.queued }, ':')
    `);
    assert.equal(result, '4:2:2:4:0');
  } finally {
    engine.global.close();
  }
});

test('client runtime retries UI binding, fences server origin, and routes only internal action tokens', async () => {
  const engine = await clientRuntimeLua();
  try {
    const result = await engine.doString(`
      assert(__clientTest.runUntilUiCalls(3))
      assert(__clientTest.uiGetCalls == 3)

      local api = assert(__clientTest.exported.GetAPI('^1.0.0'))
      assert(api.ownerResource == 'consumer.fixture' and api.notify == api.show)
      __clientTest.commands['synex-notify-sound'](nil, { 'on' })
      __clientTest.commands['synex-notify-sound'](nil, { 'volume', '37' })
      local handle = assert(api.show({
        title = 'Local runtime signal', tone = 'success', sound = true,
      }))
      assert(handle.ownerEpoch == api.ownerEpoch and #__clientTest.upserts == 1)
      assert(#__clientTest.soundRequests == 1
        and __clientTest.soundRequests[1].tone == 'success'
        and __clientTest.soundRequests[1].volume == 37)
      assert(api.setPresentationContext({
        contextId = 'generic-surface', quiet = true,
        reservedPositions = { 'top-right' }, preferredPosition = 'bottom-left',
      }))
      assert(#__clientTest.removals == 1)
      assert(api.getPresentationSnapshot().quiet == true)
      assert(api.clearPresentationContext('generic-surface').cleared == true)

      local command = {
        schemaVersion = 1, command = 'show', commandId = 'notify-command-00000001',
        ownerResource = 'server.owner', ownerEpoch = 1,
        notificationId = 'server-runtime-notification', revision = 1,
        target = { source = 42, sessionId = 'session-0001', sourceGeneration = 1 },
        payload = {
          notificationId = 'server-runtime-notification', revision = 1,
          kind = 'toast', tone = 'info', priority = 'normal', title = 'Server',
          createdAt = 1000, position = 'top-right', origin = 'SERVER',
          actions = {{ token = 'opaque-server-action-token', label = 'Accept',
            style = 'default', ttlMs = 30000 }},
        },
      }
      local wake = __clientTest.stageCommand(command)
      local beforeSpoof = #__clientTest.upserts
      source = 0
      __clientTest.events['synex_notify:client:command:v1'](wake)
      assert(#__clientTest.upserts == beforeSpoof)

      source = 65535
      local forged = SynexNotifyValidation.copy(command)
      forged.commandId = 'notify-command-high-generation'
      forged.target.sourceGeneration = 9007199254740991
      __clientTest.events['synex_notify:client:command:v1'](forged)
      assert(#__clientTest.coreCalls == 0 and #__clientTest.upserts == beforeSpoof)

      __clientTest.events['synex_notify:client:command:v1']({
        schemaVersion = 1, commandId = 'notify-command-fake-wake-id',
      })
      assert(__clientTest.runUntilCoreCalls(1))
      assert(#__clientTest.coreCalls == 1 and #__clientTest.upserts == beforeSpoof)

      __clientTest.events['synex_notify:client:command:v1'](wake)
      local projected = assert(__clientTest.runUntilProjectedAction())
      assert(projected.actions[1].token ~= 'opaque-server-action-token')
      __clientTest.commands['synex-notify-action-1']()
      assert(#__clientTest.coreCalls == 3)
      local pull = __clientTest.coreCalls[2]
      assert(pull.name == 'synex.notify.command.pull' and pull.version == '1.0.0')
      assert(pull.payload.commandId == command.commandId)
      local actionCall = __clientTest.coreCalls[3]
      assert(actionCall.name == 'synex.notify.action.invoke'
        and actionCall.version == '1.0.0')
      assert(actionCall.payload.token == 'opaque-server-action-token')

      local diagnostics = assert(api.getDiagnostics())
      assert(diagnostics.ui.bound and diagnostics.metrics.ui_rebind_attempts == 3)
      assert(diagnostics.metrics.ui_rebind_failures == 2)
      assert(diagnostics.metrics.ui_rebind_successes == 1)
      assert(diagnostics.metrics.server_command_rejected == 3)
      assert(diagnostics.presentation.preferences.scale == 115)
      assert(diagnostics.presentation.preferences.reducedMotion == true)

      __clientTest.handlers.onClientResourceStop('consumer.fixture')
      local stale, staleError = api.show({ title = 'Stale facade' })
      assert(stale == nil and staleError.code == 'NOTIFY_OWNER_STALE')
      return table.concat({ __clientTest.uiGetCalls, #__clientTest.coreCalls,
        diagnostics.metrics.server_command_rejected }, ':')
    `);
    assert.equal(result, '3:3:3');
  } finally {
    engine.global.close();
  }
});

test('client action facade accepts Cfx callable proxies and purges them on owner stop', async () => {
  const engine = await clientRuntimeLua();
  try {
    const result = await engine.doString(`
      assert(__clientTest.runUntilUiCalls(3))
      local api = assert(__clientTest.exported.GetAPI('^1.0.0'))
      local calls = {}
      local callable = setmetatable({}, {
        __call = function(_, payload)
          calls[#calls + 1] = payload.actionId
          return { accepted = true }
        end,
        __metatable = 'cfx-funcref',
      })
      local handle = assert(api.show({
        title = 'Callable action',
        actions = {{ id = 'open', label = 'Open' }},
      }))
      assert(handle:onAction('open', callable))
      local invalid, invalidError = handle:onAction('open', {})
      assert(invalid == nil and invalidError.code == 'NOTIFY_INVALID_REQUEST')
      local malformed, malformedError = handle:onAction('open',
        setmetatable({}, { __call = true }))
      assert(malformed == nil and malformedError.code == 'NOTIFY_INVALID_REQUEST')

      local projected = assert(__clientTest.runUntilProjectedAction())
      assert(projected.title == 'Callable action' and projected.actions[1].label == 'Open')
      __clientTest.commands['synex-notify-action-1']()
      assert(#calls == 1 and calls[1] == 'open')

      local staleCalls = 0
      local staleCallable = setmetatable({}, {
        __call = function()
          staleCalls = staleCalls + 1
          return true
        end,
      })
      local staleHandle = assert(api.show({
        title = 'Owner cleanup action',
        actions = {{ id = 'stale', label = 'Stale' }},
      }))
      assert(staleHandle:onAction('stale', staleCallable))
      local staleProjection = assert(__clientTest.runUntilProjectedAction())
      assert(staleProjection.title == 'Owner cleanup action')
      __clientTest.handlers.onClientResourceStop('consumer.fixture')
      local stale, staleError = staleHandle:onAction('stale', staleCallable)
      assert(stale == nil and staleError.code == 'NOTIFY_OWNER_STALE')
      __clientTest.commands['synex-notify-action-1']()
      assert(staleCalls == 0)
      return table.concat({ calls[1], invalidError.code, malformedError.code,
        staleError.code, staleCalls }, ':')
    `);
    assert.equal(result,
      'open:NOTIFY_INVALID_REQUEST:NOTIFY_INVALID_REQUEST:NOTIFY_OWNER_STALE:0');
  } finally {
    engine.global.close();
  }
});

test('compatibility access remains provider-bound, consumer-owned, and unprivileged', async () => {
  const engine = await clientRuntimeLua();
  try {
    const result = await engine.doString(`
      assert(__clientTest.runUntilUiCalls(3))

      __clientTest.invokingResource = 'attacker.resource'
      local denied, deniedError = __clientTest.exported.GetCompatibilityAPI(
        'legacy.consumer', 'qb')
      assert(denied == nil and deniedError.code == 'NOTIFY_OWNER_INVALID')

      __clientTest.invokingResource = 'synex_bridge_qb'
      local crossed, crossedError = __clientTest.exported.GetCompatibilityAPI(
        'legacy.consumer', 'esx')
      assert(crossed == nil and crossedError.code == 'NOTIFY_OWNER_INVALID')

      local api = assert(__clientTest.exported.GetCompatibilityAPI(
        'legacy.consumer', 'qb'))
      assert(api.ownerResource == 'legacy.consumer' and api.provider == 'qb')
      local handle = assert(api.Notify({
        kind = 'toast', tone = 'success', priority = 'normal',
        title = 'Legacy notification', message = 'Consumer-bound',
      }))
      assert(handle.ownerResource == 'legacy.consumer')
      local projected = __clientTest.upserts[#__clientTest.upserts]
      assert(projected.ownerResource == nil and projected.origin == nil
        and projected.priority == 'normal'
        and projected.title == 'Legacy notification')

      local privileged, privilegedError = api.show({
        kind = 'banner', tone = 'danger', priority = 'critical',
        origin = 'SYSTEM', title = 'Spoofed system message',
      })
      assert(privileged == nil and (privilegedError.code == 'NOTIFY_INVALID_REQUEST'
        or privilegedError.code == 'NOTIFY_PRIORITY_DENIED'))

      __clientTest.handlers.onClientResourceStop('legacy.consumer')
      local stale, staleError = api.notify({ title = 'Stale compatibility facade' })
      assert(stale == nil and staleError.code == 'NOTIFY_OWNER_STALE')
      return table.concat({ deniedError.code, crossedError.code,
        handle.ownerResource, privilegedError.code, staleError.code }, ':')
    `);
    assert.match(result,
      /^NOTIFY_OWNER_INVALID:NOTIFY_OWNER_INVALID:legacy\.consumer:(?:NOTIFY_INVALID_REQUEST|NOTIFY_PRIORITY_DENIED):NOTIFY_OWNER_STALE$/u);
  } finally {
    engine.global.close();
  }
});

test('client runtime reports only bounded aggregate presentation telemetry', async () => {
  const engine = await clientRuntimeLua();
  try {
    const result = await engine.doString(`
      __clientTest.metricFailures = 1
      assert(__clientTest.runUntilMetricCalls(1))
      local baseline = __clientTest.metricCalls[1]
      assert(__clientTest.clock == 1000 and baseline.payload.sequence == 1)
      assert(baseline.payload.counters.created == 0)

      assert(__clientTest.runUntilUiCalls(3))
      local api = assert(__clientTest.exported.GetAPI('^1.0.0'))
      assert(api.show({ title = 'Aggregate-only fixture' }))
      assert(__clientTest.runUntilMetricCalls(2))
      local acceptedBaseline = __clientTest.metricCalls[2]
      assert(acceptedBaseline.at - baseline.at
        == SynexNotifyLimits.metricsBaselineRetryDelayMs)
      assert(acceptedBaseline.payload.sequence == 2
        and acceptedBaseline.payload.counters.created == 0,
        'the retry must preserve the frozen pre-activity baseline')
      assert(__clientTest.runUntilMetricCalls(3))
      local report = __clientTest.metricCalls[3]
      assert(report and report.version == '1.0.0')
      local payload = report.payload
      assert(SynexNotifyValidation.exactObject(payload, {
        clientEpoch = true, sequence = true, counters = true, gauges = true,
      }))
      assert(payload.clientEpoch >= 1 and payload.sequence == 3)
      assert(payload.counters.created == 1)
      assert(payload.gauges.visible >= 0 and payload.gauges.visible <= 4)
      assert(payload.gauges.queued >= 0 and payload.gauges.queued <= 128)
      assert(payload.notificationId == nil and payload.ownerResource == nil
        and payload.sessionId == nil and payload.traceId == nil
        and payload.title == nil and payload.message == nil)
      for key, value in pairs(payload.counters) do
        assert(type(key) == 'string' and type(value) == 'number'
          and value >= 0 and value <= SynexNotifyLimits.metricsMaximumCounter)
      end
      __clientTest.handlers.onClientResourceStop('synex_notify')
      local callsAtStop = #__clientTest.metricCalls
      for _ = 1, 64 do
        if #__clientTest.timers == 0 then break end
        __clientTest.runTimer()
      end
      assert(#__clientTest.metricCalls == callsAtStop,
        'stopped telemetry generation must not reschedule or report')
      return table.concat({ report.name, payload.sequence,
        payload.counters.created, payload.gauges.queued }, ':')
    `);
    assert.match(result, /^synex\.notify\.metrics\.report:3:1:[0-9]+$/u);
  } finally {
    engine.global.close();
  }
});

test('critical signals without actions keep polling until the browser visibility ACK arrives', async () => {
  const engine = await clientRuntimeLua();
  try {
    const result = await engine.doString(`
      assert(__clientTest.runUntilUiCalls(3))
      local api = assert(__clientTest.exported.GetAPI('^1.0.0'))
      source = 65535
      local command = {
        schemaVersion = 1, command = 'show',
        commandId = 'notify-command-00000002',
        ownerResource = 'server.owner', ownerEpoch = 1,
        notificationId = 'server-critical-ack', revision = 1,
        target = { source = 42, sessionId = 'session-0001', sourceGeneration = 1 },
        payload = {
          notificationId = 'server-critical-ack', revision = 1,
          kind = 'persistent', priority = 'critical', tone = 'danger',
          title = 'Delayed browser acknowledgement', createdAt = 1000,
          position = 'top-right', origin = 'SERVER',
        },
      }
      __clientTest.events['synex_notify:client:command:v1'](
        __clientTest.stageCommand(command))
      assert(__clientTest.runUntilCoreCalls(1))
      __clientTest.visibilityLag = 1
      assert(api.getDiagnostics().pendingVisibilityAcks == 1)

      local before = __clientTest.visibilityCalls
      assert(__clientTest.runUntilVisibilityCalls(before + 1))
      assert(__clientTest.visibilityCalls == before + 1)
      assert(api.getDiagnostics().pendingVisibilityAcks == 1)
      assert(__clientTest.runUntilVisibilityCalls(before + 2))
      assert(__clientTest.visibilityCalls == before + 2)
      assert(api.getDiagnostics().pendingVisibilityAcks == 0)

      local verificationDeadline = __clientTest.clock
        + SynexNotifyLimits.uiVisibilityAckTimeoutMs + 1
      for _ = 1, 24 do
        if __clientTest.clock >= verificationDeadline then break end
        assert(#__clientTest.timers > 0)
        __clientTest.runTimer()
      end
      assert(__clientTest.clock >= verificationDeadline)
      assert(__clientTest.nativeFallbackPosts == 0)
      return table.concat({ __clientTest.visibilityCalls - before,
        __clientTest.nativeFallbackPosts }, ':')
    `);
    assert.equal(result, '2:0');
  } finally {
    engine.global.close();
  }
});

test('wake pulls stay FIFO so owner cleanup cannot be overtaken by older presentation work', async () => {
  const engine = await clientRuntimeLua();
  try {
    const result = await engine.doString(`
      assert(__clientTest.runUntilUiCalls(3))
      local api = assert(__clientTest.exported.GetAPI('^1.0.0'))
      local target = { source = 42, sessionId = 'session-0001', sourceGeneration = 1 }
      local show = {
        schemaVersion = 1, command = 'show', commandId = 'notify-command-fifo-show',
        ownerResource = 'server.owner', ownerEpoch = 1,
        notificationId = 'server-fifo-notification', revision = 1, target = target,
        payload = {
          notificationId = 'server-fifo-notification', revision = 1,
          kind = 'toast', tone = 'info', priority = 'normal', title = 'Before stop',
          createdAt = 1000, position = 'top-right', origin = 'SERVER',
        },
      }
      local ownerStop = {
        schemaVersion = 1, command = 'owner_stop',
        commandId = 'notify-command-fifo-owner-stop',
        ownerResource = 'server.owner', ownerEpoch = 1,
        notificationId = 'owner-stop', revision = 1, target = target,
      }
      source = 65535
      __clientTest.events['synex_notify:client:command:v1'](
        __clientTest.stageCommand(show))
      __clientTest.events['synex_notify:client:command:v1'](
        __clientTest.stageCommand(ownerStop))
      assert(__clientTest.runUntilCoreCalls(2))
      assert(__clientTest.coreCalls[1].payload.commandId == show.commandId)
      assert(__clientTest.coreCalls[2].payload.commandId == ownerStop.commandId)
      local diagnostics = api.getDiagnostics()
      assert(diagnostics.records == 0 and diagnostics.pendingVisibilityAcks == 0)
      assert(#__clientTest.upserts >= 1 and #__clientTest.removals >= 1)
      return table.concat({ #__clientTest.coreCalls, diagnostics.records,
        #__clientTest.removals }, ':')
    `);
    assert.match(String(result), /^2:0:[1-9][0-9]*$/u);
  } finally {
    engine.global.close();
  }
});
