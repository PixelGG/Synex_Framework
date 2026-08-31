import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory, type LuaEngine } from 'wasmoon';

const root = process.cwd();

const harness = `
  __uiTest = {
    callbacks = {},
    handlers = {},
    exported = {},
    sent = {},
    focusCalls = {},
    keepInputCalls = {},
    timeouts = {},
    resourceStates = {
      owner_alpha = 'started',
      owner_beta = 'started',
    },
    invokingResource = 'owner_alpha',
    now = 1000,
    screenWidth = 2560,
    screenHeight = 1440,
    safeZone = 0.95,
  }

  GetCurrentResourceName = function() return 'synex_ui' end
  GetGameTimer = function() return __uiTest.now end
  GetActualScreenResolution = function()
    return __uiTest.screenWidth, __uiTest.screenHeight
  end
  GetSafeZoneSize = function() return __uiTest.safeZone end
  GetResourceState = function(resource)
    return __uiTest.resourceStates[resource] or 'missing'
  end
  GetInvokingResource = function() return __uiTest.invokingResource end

  SetNuiFocus = function(keyboard, pointer)
    __uiTest.focusCalls[#__uiTest.focusCalls + 1] = {
      keyboard = keyboard,
      pointer = pointer,
    }
  end
  SetNuiFocusKeepInput = function(keepInput)
    __uiTest.keepInputCalls[#__uiTest.keepInputCalls + 1] = keepInput
  end
  SendNUIMessage = function(message)
    __uiTest.sent[#__uiTest.sent + 1] = message
  end
  RegisterNuiCallback = function(route, handler)
    __uiTest.callbacks[route] = handler
  end
  AddEventHandler = function(name, handler)
    __uiTest.handlers[name] = handler
  end
  TriggerEvent = function(name, ...)
    local handler = __uiTest.handlers[name]
    if type(handler) == 'function' then handler(...) end
  end
  exports = function(name, handler)
    __uiTest.exported[name] = handler
  end
  CreateThread = function() end
  Wait = function() error('headless harness does not drive runtime threads') end
  SetTimeout = function(delay, handler)
    __uiTest.timeouts[#__uiTest.timeouts + 1] = {
      delay = delay,
      handler = handler,
    }
  end

  IsUsingKeyboard = function() return true end
  DisableControlAction = function() end
  IsDisabledControlJustPressed = function() return false end
  GetResourceKvpString = function() return nil end
  SetResourceKvp = function() end
  DeleteResourceKvp = function() end

  json = {
    encode = function() return '{}' end,
    decode = function() return {} end,
  }
  promise = {
    new = function()
      return {
        resolved = false,
        value = nil,
        resolve = function(self, value)
          assert(not self.resolved, 'promise resolved more than once')
          self.resolved = true
          self.value = value
        end,
      }
    end,
  }
  Citizen = {
    Await = function(waiter)
      if type(__uiTest.awaitHook) == 'function' then
        __uiTest.awaitHook(waiter)
      end
      return waiter.value
    end,
  }

  function __uiTest.invoke(route, request)
    local response = nil
    local replies = 0
    assert(type(__uiTest.callbacks[route]) == 'function', 'missing NUI callback: ' .. route)
    __uiTest.callbacks[route](request, function(value)
      replies = replies + 1
      response = value
    end)
    return response, replies
  end

  function __uiTest.ready(requestId, browserBootId)
    return __uiTest.invoke('runtime:ready', {
      protocolVersion = 1,
      requestId = requestId or 'ready-request',
      browserBootId = browserBootId or 'browser-boot-a',
    })
  end

  function __uiTest.lastMessage(messageType)
    for index = #__uiTest.sent, 1, -1 do
      if __uiTest.sent[index].type == messageType then
        return __uiTest.sent[index]
      end
    end
    return nil
  end

  function __uiTest.messageCount(messageType)
    local count = 0
    for _, message in ipairs(__uiTest.sent) do
      if message.type == messageType then count = count + 1 end
    end
    return count
  end

  function __uiTest.hasOnlyKeys(value, allowed)
    if type(value) ~= 'table' then return false end
    for key in pairs(value) do
      if allowed[key] ~= true then return false end
    end
    return true
  end

  function __uiTest.installFocusAgent(owner)
    local wakeup = 'synex_ui:focus-agent:wakeup:v1'
    if __uiTest.handlers[wakeup] == nil then
      __uiTest.handlers[wakeup] = function(wakeOwner)
        local previous = __uiTest.invokingResource
        __uiTest.invokingResource = wakeOwner
        local state = assert(__uiTest.exported.GetFocusAgentState('1.0.0'))
        local acknowledged, acknowledgeError = __uiTest.exported.AcknowledgeFocusAgent({
          version = '1.0.0',
          bootGeneration = state.bootGeneration,
          ownerEpoch = state.ownerEpoch,
          revision = state.revision,
          keyboard = state.keyboard,
          pointer = state.pointer,
          applied = true,
          intentGeneration = state.intent and state.intent.generation or 0,
          intentDelivered = state.intent ~= nil,
        })
        assert(acknowledged == true and acknowledgeError == nil)
        __uiTest.invokingResource = previous
      end
    end
    local previous = __uiTest.invokingResource
    __uiTest.invokingResource = owner
    local registration, registrationError = __uiTest.exported.RegisterFocusAgent('1.0.0')
    assert(registration ~= nil and registrationError == nil)
    local state = assert(__uiTest.exported.GetFocusAgentState('1.0.0'))
    local acknowledged, acknowledgeError = __uiTest.exported.AcknowledgeFocusAgent({
      version = '1.0.0',
      bootGeneration = state.bootGeneration,
      ownerEpoch = state.ownerEpoch,
      revision = state.revision,
      keyboard = state.keyboard,
      pointer = state.pointer,
      applied = true,
      intentGeneration = 0,
      intentDelivered = false,
    })
    assert(acknowledged == true and acknowledgeError == nil)
    __uiTest.invokingResource = previous
  end
`;

const cfxJsonHarness = `
  __cfxJson = {
    snapshots = {},
    serial = 0,
    suppliedDecodeCalls = 0,
    ordinaryDecodeCalls = 0,
  }

  local function inferKind(value)
    local metatable = debug.getmetatable(value)
    local kind = type(metatable) == 'table' and rawget(metatable, '__jsontype') or nil
    if kind == 'object' or kind == 'array' then return kind end
    local count, maximumIndex = 0, 0
    for key in next, value do
      if type(key) ~= 'number' or key ~= math.floor(key) or key < 1 then return 'object' end
      count = count + 1
      maximumIndex = math.max(maximumIndex, key)
    end
    return maximumIndex == count and 'array' or 'object'
  end

  local function freeze(value, active)
    if type(value) ~= 'table' then return value end
    active = active or {}
    assert(not active[value], 'fixture cannot encode a cycle')
    active[value] = true
    local kind = inferKind(value)
    local snapshot = { kind = kind }
    if kind == 'array' then
      snapshot.values = {}
      for index = 1, rawlen(value) do
        snapshot.values[index] = freeze(rawget(value, index), active)
      end
    else
      snapshot.entries = {}
      for key, child in next, value do
        snapshot.entries[#snapshot.entries + 1] = { key = key, value = freeze(child, active) }
      end
    end
    active[value] = nil
    return snapshot
  end

  local function thaw(snapshot, objectMetatable, arrayMetatable)
    if type(snapshot) ~= 'table' then return snapshot end
    local value = setmetatable({}, snapshot.kind == 'object' and objectMetatable or arrayMetatable)
    if snapshot.kind == 'array' then
      for index, child in ipairs(snapshot.values) do
        rawset(value, index, thaw(child, objectMetatable, arrayMetatable))
      end
    else
      for _, entry in ipairs(snapshot.entries) do
        rawset(value, entry.key, thaw(entry.value, objectMetatable, arrayMetatable))
      end
    end
    return value
  end

  function __cfxJson.decodeSnapshot(snapshot)
    return thaw(snapshot, { __jsontype = 'object' }, { __jsontype = 'array' })
  end

  json = {
    encode = function(value)
      local snapshot = freeze(value)
      if snapshot.kind == 'object' and #snapshot.entries == 0 then return '{}' end
      if snapshot.kind == 'array' and #snapshot.values == 0 then return '[]' end
      __cfxJson.serial = __cfxJson.serial + 1
      local token = 'cfx-json-' .. __cfxJson.serial
      __cfxJson.snapshots[token] = snapshot
      return token
    end,
    decode = function(value, position, nullValue, objectMetatable, arrayMetatable)
      assert(position == nil or position == 1)
      assert(nullValue == nil)
      local supplied = objectMetatable ~= nil or arrayMetatable ~= nil
      if supplied then
        assert(type(objectMetatable) == 'table' and rawget(objectMetatable, '__jsontype') == 'object')
        assert(type(arrayMetatable) == 'table' and rawget(arrayMetatable, '__jsontype') == 'array')
        __cfxJson.suppliedDecodeCalls = __cfxJson.suppliedDecodeCalls + 1
      else
        objectMetatable = { __jsontype = 'object' }
        arrayMetatable = { __jsontype = 'array' }
        __cfxJson.ordinaryDecodeCalls = __cfxJson.ordinaryDecodeCalls + 1
      end
      local snapshot = __cfxJson.snapshots[value]
      if value == '{}' then snapshot = { kind = 'object', entries = {} }
      elseif value == '[]' then snapshot = { kind = 'array', values = {} } end
      assert(snapshot ~= nil, 'fixture received unknown encoded JSON')
      return thaw(snapshot, objectMetatable, arrayMetatable)
    end,
  }
  assert(json.object == nil and json.array == nil)
`;

async function createRuntime(): Promise<LuaEngine> {
  const engine = await new LuaFactory().createEngine();
  const client = await readFile(
    path.join(root, 'libraries/synex_ui/client/client.lua'),
    'utf8',
  );
  await engine.doString(harness);
  await engine.doString(
    `assert(load(${JSON.stringify(client)}, '@libraries/synex_ui/client/client.lua'))()`,
  );
  return engine;
}

async function createCfxJsonRuntime(): Promise<LuaEngine> {
  const engine = await new LuaFactory().createEngine();
  const client = await readFile(
    path.join(root, 'libraries/synex_ui/client/client.lua'),
    'utf8',
  );
  await engine.doString(harness);
  await engine.doString(cfxJsonHarness);
  await engine.doString(
    `assert(load(${JSON.stringify(client)}, '@libraries/synex_ui/client/client.lua'))()`,
  );
  return engine;
}

test('synex_ui runtime completes ready once and exposes only supported API versions', async () => {
  const engine = await createRuntime();
  try {
    const result = await engine.doString(`
      local ready, readyReplies = __uiTest.ready()
      assert(readyReplies == 1)
      assert(ready.ok == true)
      assert(ready.data.requestId == 'ready-request')
      assert(ready.data.protocolVersion == 1)
      assert(ready.data.apiVersion == '1.0.0')
      assert(ready.data.limits.maximumPayloadBytes == 32768)
      assert(__uiTest.messageCount('runtime:sync') == 1)

      local sync = __uiTest.lastMessage('runtime:sync')
      assert(__uiTest.hasOnlyKeys(sync, {
        protocolVersion = true,
        messageId = true,
        type = true,
        ownerResource = true,
        ownerEpoch = true,
        revision = true,
        payload = true,
      }))
      assert(sync.ownerResource == 'synex_ui')
      assert(sync.payload.health == 'READY')

      __uiTest.invokingResource = 'owner_alpha'
      local api, apiError = __uiTest.exported.GetAPI('v1')
      assert(api ~= nil and apiError == nil)
      assert(api.version == '1.0.0')
      assert(api.protocolVersion == 1)
      assert(api.ownerResource == 'owner_alpha')
      assert(api.ownerEpoch == 1)

      local unsupported, unsupportedError = __uiTest.exported.GetAPI('2.0.0')
      assert(unsupported == nil)
      assert(unsupportedError.code == 'UI_PROTOCOL_UNSUPPORTED')

      __uiTest.invokingResource = nil
      local denied, deniedError = __uiTest.exported.GetAPI('1')
      assert(denied == nil)
      assert(deniedError.code == 'UI_FOCUS_DENIED')
      return 'ready-and-api-pass'
    `);
    assert.equal(result, 'ready-and-api-pass');
  } finally {
    engine.global.close();
  }
});

test('synex_ui runtime denies raw passive-signal APIs to foreign owners', async () => {
  const engine = await createRuntime();
  try {
    const result = await engine.doString(`
      assert(__uiTest.ready().ok == true)
      __uiTest.invokingResource = 'owner_alpha'
      local api = assert(__uiTest.exported.GetAPI('1'))

      local upserted, upsertError = api.upsertSignal({})
      assert(upserted == nil and upsertError.code == 'UI_SIGNAL_DENIED')

      local removed, removeError = api.removeSignal('foreign.signal', 1)
      assert(removed == nil and removeError.code == 'UI_SIGNAL_DENIED')

      local snapshot, snapshotError = api.getSignalSnapshot()
      assert(snapshot == nil and snapshotError.code == 'UI_SIGNAL_DENIED')
      assert(__uiTest.messageCount('signal:upsert') == 0)
      assert(__uiTest.messageCount('signal:remove') == 0)
      local diagnostics = assert(api.getDiagnostics())
      assert(diagnostics.signalGeneration == 0)
      assert(#diagnostics.signals == 0)
      return 'foreign-signal-owner-denied-pass'
    `);
    assert.equal(result, 'foreign-signal-owner-denied-pass');
  } finally {
    engine.global.close();
  }
});

test('synex_ui runtime reserves the interaction surface API for synex_interact', async () => {
  const engine = await createRuntime();
  try {
    const result = await engine.doString(`
      assert(__uiTest.ready().ok == true)
      __uiTest.invokingResource = 'owner_alpha'
      local api = assert(__uiTest.exported.GetAPI('1'))
      local upserted, upsertError = api.upsertInteraction({})
      assert(upserted == nil and upsertError.code == 'UI_INTERACTION_DENIED')
      local removed, removeError = api.removeInteraction('foreign.interaction', 1)
      assert(removed == nil and removeError.code == 'UI_INTERACTION_DENIED')
      local snapshot, snapshotError = api.getInteractionSnapshot()
      assert(snapshot == nil and snapshotError.code == 'UI_INTERACTION_DENIED')
      assert(__uiTest.messageCount('interaction:upsert') == 0)
      assert(__uiTest.messageCount('interaction:remove') == 0)
      return 'foreign-interaction-owner-denied-pass'
    `);
    assert.equal(result, 'foreign-interaction-owner-denied-pass');
  } finally {
    engine.global.close();
  }
});

test('interaction cue stays passive and pointer bloom owns an explicit shared focus lifecycle', async () => {
  const engine = await createRuntime();
  try {
    const result = await engine.doString(`
      __uiTest.resourceStates.synex_interact = 'started'
      assert(__uiTest.ready('interaction-ready', 'interaction-browser').ok == true)
      __uiTest.invokingResource = 'synex_interact'
      local api = assert(__uiTest.exported.GetAPI('1'))
      local events = {}
      assert(api.bindInteractionActions(function(event)
        events[#events + 1] = event
        return true
      end))

      local cue = assert(api.upsertInteraction({
        interactionId = 'vehicle.actions', revision = 1, mode = 'cue',
        label = 'Open trunk', targetLabel = 'Sultan RS',
        projection = { visible = true, behindCamera = false, x = 0.5, y = 0.62 },
        intents = {{ intentId = 'trunk.open', label = 'Open trunk' }},
        selectedIntentId = 'trunk.open', moreCount = 2, pointer = false,
        input = {
          primary = { keyboard = 'E', gamepad = 'A' },
          more = { keyboard = 'Left Alt', gamepad = 'D-pad Up' },
        },
        cancellable = false,
      }))
      assert(cue.focusLeaseId == nil)
      assert(__uiTest.messageCount('interaction:upsert') == 1)
      local focusBeforeBloom = #__uiTest.focusCalls

      local bloom = assert(api.upsertInteraction({
        interactionId = 'vehicle.actions', revision = 2, mode = 'bloom',
        label = 'Vehicle actions',
        intents = {
          { intentId = 'trunk.open', label = 'Open trunk' },
          { intentId = 'vehicle.inspect', label = 'Inspect' },
          { intentId = 'vehicle.repair', label = 'Repair', disabled = true },
        },
        selectedIntentId = 'trunk.open', pointer = true,
        input = {
          primary = { keyboard = 'Enter', gamepad = 'A', mouse = 'Left Click' },
          cancel = { keyboard = 'Esc', gamepad = 'B', mouse = 'Right Click' },
        },
        cancellable = true,
      }))
      assert(type(bloom.focusLeaseId) == 'string')
      assert(#__uiTest.focusCalls > focusBeforeBloom)
      local focused = __uiTest.focusCalls[#__uiTest.focusCalls]
      assert(focused.keyboard == true and focused.pointer == true)

      local rejected, rejectedReplies = __uiTest.invoke('runtime:interaction', {
        protocolVersion = 1, requestId = 'interaction-extra', browserBootId = 'interaction-browser',
        interactionId = 'vehicle.actions', ownerEpoch = api.ownerEpoch, revision = 2,
        action = 'activate', intentId = 'vehicle.inspect', device = 'mouse', callback = 'unsafe:event',
      })
      assert(rejectedReplies == 1 and rejected.ok == false and rejected.error.code == 'UI_REQUEST_INVALID')
      assert(#events == 0)

      local accepted, acceptedReplies = __uiTest.invoke('runtime:interaction', {
        protocolVersion = 1, requestId = 'interaction-select', browserBootId = 'interaction-browser',
        interactionId = 'vehicle.actions', ownerEpoch = api.ownerEpoch, revision = 2,
        action = 'activate', intentId = 'vehicle.inspect', device = 'mouse',
      })
      assert(acceptedReplies == 1 and accepted.ok == true and accepted.data.accepted == true)
      assert(#events == 1 and events[1].intentId == 'vehicle.inspect' and events[1].action == 'activate')

      local duplicate = __uiTest.invoke('runtime:interaction', {
        protocolVersion = 1, requestId = 'interaction-duplicate', browserBootId = 'interaction-browser',
        interactionId = 'vehicle.actions', ownerEpoch = api.ownerEpoch, revision = 2,
        action = 'activate', intentId = 'vehicle.inspect', device = 'mouse',
      })
      assert(duplicate.ok == false and duplicate.error.code == 'UI_REQUEST_STALE')
      assert(#events == 1)

      local focusCallsBeforeSwitch = #__uiTest.focusCalls
      local switched = assert(api.upsertInteraction({
        interactionId = 'vehicle.secondary-actions', revision = 1, mode = 'bloom',
        label = 'Other relevant actions',
        intents = {
          { intentId = 'door.open', label = 'Open door' },
          { intentId = 'vehicle.inspect', label = 'Inspect' },
        },
        selectedIntentId = 'door.open', pointer = true,
        input = {
          primary = { keyboard = 'Enter', gamepad = 'A', mouse = 'Left Click' },
          cancel = { keyboard = 'Esc', gamepad = 'B', mouse = 'Right Click' },
        },
        cancellable = true,
      }))
      assert(switched.focusLeaseId == bloom.focusLeaseId)
      assert(#__uiTest.focusCalls == focusCallsBeforeSwitch)

      local removed = assert(api.removeInteraction('vehicle.secondary-actions', 2))
      assert(removed.removed == true and __uiTest.messageCount('interaction:remove') == 1)
      local released = __uiTest.focusCalls[#__uiTest.focusCalls]
      assert(released.keyboard == false and released.pointer == false)
      local snapshot = assert(api.getInteractionSnapshot())
      assert(snapshot.interaction == nil and snapshot.focusLeaseId == nil)
      return 'interaction-focus-lifecycle-pass'
    `);
    assert.equal(result, 'interaction-focus-lifecycle-pass');
  } finally {
    engine.global.close();
  }
});

test('interaction transport rejects unbounded modes and keeps progress pointer-passive', async () => {
  const engine = await createRuntime();
  try {
    const result = await engine.doString(`
      __uiTest.resourceStates.synex_interact = 'started'
      assert(__uiTest.ready('interaction-progress-ready', 'interaction-progress-browser').ok == true)
      __uiTest.invokingResource = 'synex_interact'
      local api = assert(__uiTest.exported.GetAPI('1'))
      local invalid, invalidError = api.upsertInteraction({
        interactionId = 'invalid.bloom', revision = 1, mode = 'bloom', label = 'Too many',
        intents = {
          { intentId = 'one', label = 'One' }, { intentId = 'two', label = 'Two' },
          { intentId = 'three', label = 'Three' }, { intentId = 'four', label = 'Four' },
          { intentId = 'five', label = 'Five' }, { intentId = 'six', label = 'Six' },
          { intentId = 'seven', label = 'Seven' },
        },
        selectedIntentId = 'one', pointer = false,
        input = { primary = { keyboard = 'Enter', gamepad = 'A' },
          cancel = { keyboard = 'Esc', gamepad = 'B' } },
        cancellable = true,
      })
      assert(invalid == nil and invalidError.code == 'UI_REQUEST_INVALID')
      local extra, extraError = api.upsertInteraction({
        interactionId = 'invalid.extra', revision = 1, mode = 'progress', label = 'Working',
        intents = {}, pointer = false, input = {}, cancellable = false,
        progress = { mode = 'indeterminate' }, serverRange = 20,
      })
      assert(extra == nil and extraError.code == 'UI_REQUEST_INVALID')
      local focusBefore = #__uiTest.focusCalls
      local progress = assert(api.upsertInteraction({
        interactionId = 'vehicle.repair', revision = 1, mode = 'progress', label = 'Repairing',
        intents = {}, pointer = false,
        input = { cancel = { keyboard = 'X', gamepad = 'B' } },
        progress = { mode = 'timed', elapsedMs = 1000, durationMs = 5000 },
        cancellable = true,
      }))
      assert(progress.focusLeaseId == nil and #__uiTest.focusCalls == focusBefore)
      local message = assert(__uiTest.lastMessage('interaction:upsert'))
      assert(message.payload.progress.mode == 'timed')
      assert(#message.payload.intents == 0)
      return 'interaction-progress-passive-pass'
    `);
    assert.equal(result, 'interaction-progress-passive-pass');
  } finally {
    engine.global.close();
  }
});

test('passive Notify input reports are caller-bound, focusless, and event-synchronized', async () => {
  const engine = await createRuntime();
  try {
    const result = await engine.doString(`
      __uiTest.resourceStates.synex_notify = 'started'
      __uiTest.invokingResource = 'synex_notify'
      local notify = assert(__uiTest.exported.GetAPI('1'))
      assert(type(notify.reportInputDevice) == 'function')

      local beforeReady = assert(notify.reportInputDevice('gamepad'))
      assert(beforeReady.device == 'gamepad' and beforeReady.changed == true)
      assert(__uiTest.messageCount('runtime:sync') == 0)
      assert(#__uiTest.focusCalls == 0 and #__uiTest.keepInputCalls == 0)

      assert(__uiTest.ready('ready-passive-input', 'browser-boot-a').ok == true)
      local initial = assert(__uiTest.lastMessage('runtime:sync'))
      assert(initial.payload.inputDevice == 'gamepad')
      local syncCount = __uiTest.messageCount('runtime:sync')

      local duplicate = assert(notify.reportInputDevice('gamepad'))
      assert(duplicate.device == 'gamepad' and duplicate.changed == false)
      assert(__uiTest.messageCount('runtime:sync') == syncCount)

      local keyboard = assert(notify.reportInputDevice('keyboard'))
      assert(keyboard.device == 'keyboard' and keyboard.changed == true)
      assert(__uiTest.messageCount('runtime:sync') == syncCount + 1)
      local inputSync = assert(__uiTest.lastMessage('runtime:sync'))
      assert(__uiTest.hasOnlyKeys(inputSync.payload, { inputDevice = true }))
      assert(inputSync.payload.inputDevice == 'keyboard')

      for _, invalid in ipairs({ 'mouse', 'GAMEPAD', 'controller', 1, {} }) do
        local rejected, reportError = notify.reportInputDevice(invalid)
        assert(rejected == nil and reportError.code == 'UI_REQUEST_INVALID')
      end
      assert(__uiTest.messageCount('runtime:sync') == syncCount + 1)
      assert(#__uiTest.focusCalls == 0 and #__uiTest.keepInputCalls == 0)

      __uiTest.invokingResource = 'owner_alpha'
      local foreign = assert(__uiTest.exported.GetAPI('1'))
      assert(foreign.reportInputDevice == nil)
      local diagnostics = assert(foreign.getDiagnostics())
      assert(diagnostics.activeInputDevice == 'keyboard')

      __uiTest.handlers.onClientResourceStop('synex_notify')
      local stale, staleError = notify.reportInputDevice('gamepad')
      assert(stale == nil and staleError.code == 'UI_OWNER_STOPPED')
      return 'passive-input-report-pass'
    `);
    assert.equal(result, 'passive-input-report-pass');
  } finally {
    engine.global.close();
  }
});

test('passive signals detect the current gamepad mode without focus or control capture', async () => {
  const engine = await createRuntime();
  try {
    const result = await engine.doString(`
      local inputThread = nil
      local usingKeyboard = false
      local disabledControls = 0
      CreateThread = function(callback)
        inputThread = coroutine.create(callback)
        local resumed, waitMs = coroutine.resume(inputThread)
        assert(resumed and waitMs == 250)
      end
      Wait = function(delay) coroutine.yield(delay) end
      IsUsingKeyboard = function() return usingKeyboard end
      DisableControlAction = function() disabledControls = disabledControls + 1 end

      __uiTest.resourceStates.synex_notify = 'started'
      __uiTest.invokingResource = 'synex_notify'
      assert(__uiTest.ready('ready-passive-detection', 'browser-passive-detection').ok)
      local api = assert(__uiTest.exported.GetAPI('1'))
      local upserted = assert(api.upsertSignal({
        signalId = 'notify.passive-device', revision = 1,
        kind = 'toast', tone = 'info', priority = 'normal',
        title = 'Passive device detection', createdAt = 1000,
        position = 'top-right',
      }))
      assert(upserted.delivered == true and coroutine.status(inputThread) == 'suspended')
      local gamepadSync = assert(__uiTest.lastMessage('runtime:sync'))
      assert(__uiTest.hasOnlyKeys(gamepadSync.payload, { inputDevice = true }))
      assert(gamepadSync.payload.inputDevice == 'gamepad')
      assert(disabledControls == 0 and #__uiTest.focusCalls == 0
        and #__uiTest.keepInputCalls == 0)

      usingKeyboard = true
      local resumed, waitMs = coroutine.resume(inputThread)
      assert(resumed and waitMs == 250)
      local keyboardSync = assert(__uiTest.lastMessage('runtime:sync'))
      assert(keyboardSync.payload.inputDevice == 'keyboard')
      assert(disabledControls == 0)

      assert(api.removeSignal('notify.passive-device', 2))
      resumed = coroutine.resume(inputThread)
      assert(resumed and coroutine.status(inputThread) == 'dead')
      return table.concat({ gamepadSync.payload.inputDevice,
        keyboardSync.payload.inputDevice, disabledControls }, ':')
    `);
    assert.equal(result, 'gamepad:keyboard:0');
  } finally {
    engine.global.close();
  }
});

test('notification sound transport is private, closed, bounded, and rate-limited', async () => {
  const engine = await createRuntime();
  try {
    const result = await engine.doString(`
      assert(__uiTest.ready().ok == true)
      __uiTest.invokingResource = 'owner_alpha'
      local foreign = assert(__uiTest.exported.GetAPI('1'))
      assert(foreign.playSignalSound == nil)

      __uiTest.resourceStates.synex_notify = 'started'
      __uiTest.invokingResource = 'synex_notify'
      local notify = assert(__uiTest.exported.GetAPI('1'))
      assert(type(notify.playSignalSound) == 'function')

      local invalid = {
        {},
        { tone = 'accent', volume = 50 },
        { tone = 'info', volume = 0 },
        { tone = 'info', volume = 1.5 },
        { tone = 'info', volume = 101 },
        { tone = 'info', volume = 50, url = 'https://example.invalid' },
      }
      for _, request in ipairs(invalid) do
        local played, playError = notify.playSignalSound(request)
        assert(played == nil and playError.code == 'UI_REQUEST_INVALID')
      end
      assert(__uiTest.messageCount('signal:sound') == 0)

      local first, firstError = notify.playSignalSound({ tone = 'critical', volume = 73 })
      assert(firstError == nil and first.delivered == true)
      local sound = assert(__uiTest.lastMessage('signal:sound'))
      assert(sound.ownerResource == 'synex_notify' and sound.ownerEpoch == notify.ownerEpoch)
      assert(sound.revision == 0 and sound.payload.tone == 'critical' and sound.payload.volume == 73)
      assert(sound.payload.browserBootId == 'browser-boot-a')
      assert(__uiTest.hasOnlyKeys(sound.payload, {
        tone = true, volume = true, browserBootId = true,
      }))

      local cooled, cooldownError = notify.playSignalSound({ tone = 'info', volume = 50 })
      assert(cooled == nil and cooldownError.code == 'UI_SIGNAL_DENIED')
      assert(cooldownError.details.retryAfterMs == 50)

      for index = 2, 8 do
        __uiTest.now = __uiTest.now + 50
        assert(notify.playSignalSound({ tone = 'success', volume = index }))
      end
      __uiTest.now = __uiTest.now + 50
      local limited, limitError = notify.playSignalSound({ tone = 'warning', volume = 50 })
      assert(limited == nil and limitError.code == 'UI_SIGNAL_DENIED')
      assert(limitError.details.retryAfterMs > 0)
      assert(__uiTest.messageCount('signal:sound') == 8)

      __uiTest.now = 2000
      assert(notify.playSignalSound({ tone = 'neutral', volume = 1 }))
      assert(__uiTest.messageCount('signal:sound') == 9)
      return 'private-signal-sound-pass'
    `);
    assert.equal(result, 'private-signal-sound-pass');
  } finally {
    engine.global.close();
  }
});

test('UI diagnostics never disclose passive signal content across resource owners', async () => {
  const engine = await createRuntime();
  try {
    const result = await engine.doString(`
      assert(__uiTest.ready().ok == true)
      __uiTest.resourceStates.synex_notify = 'started'
      __uiTest.invokingResource = 'synex_notify'
      local notify = assert(__uiTest.exported.GetAPI('1'))
      assert(notify.upsertSignal({
        signalId = 'notify.private-diagnostics', revision = 1,
        kind = 'toast', tone = 'danger', priority = 'critical',
        title = 'Private notification title',
        message = 'Private notification message',
        createdAt = 1000, position = 'top-right',
      }))
      local own = assert(notify.getDiagnostics())
      assert(#own.signals == 1)
      assert(own.signals[1].title == 'Private notification title')

      __uiTest.invokingResource = 'owner_alpha'
      local foreign = assert(__uiTest.exported.GetAPI('1'))
      local diagnostics = assert(foreign.getDiagnostics())
      assert(#diagnostics.signals == 0)
      assert(#diagnostics.surfaces == 0)
      assert(#diagnostics.focus.stack == 0 and #diagnostics.focus.queue == 0)
      return 'diagnostics-owner-scope-pass'
    `);
    assert.equal(result, 'diagnostics-owner-scope-pass');
  } finally {
    engine.global.close();
  }
});

test('passive-signal upsert reports browser delivery separately from retained acceptance', async () => {
  const engine = await createRuntime();
  try {
    const result = await engine.doString(`
      __uiTest.resourceStates.synex_notify = 'started'
      __uiTest.invokingResource = 'synex_notify'
      local api = assert(__uiTest.exported.GetAPI('1'))
      local retained = assert(api.upsertSignal({
        signalId = 'notify.delivery',
        revision = 1,
        kind = 'toast',
        tone = 'danger',
        priority = 'critical',
        title = 'Retained before browser readiness',
        createdAt = 1000,
        position = 'top-right',
      }))
      assert(retained.generation == 1 and retained.delivered == false)
      assert(__uiTest.messageCount('signal:upsert') == 0)

      assert(__uiTest.ready().ok == true)
      local delivered = assert(api.upsertSignal({
        signalId = 'notify.delivery',
        revision = 2,
        kind = 'toast',
        tone = 'danger',
        priority = 'critical',
        title = 'Delivered after browser readiness',
        createdAt = 1000,
        position = 'top-right',
      }))
      assert(delivered.generation == 2 and delivered.delivered == true)
      assert(__uiTest.messageCount('signal:upsert') == 1)
      return 'signal-delivery-state-pass'
    `);
    assert.equal(result, 'signal-delivery-state-pass');
  } finally {
    engine.global.close();
  }
});

test('synex_ui runtime accepts newer visibility revisions within one generation and rejects stale reports', async () => {
  const engine = await createRuntime();
  try {
    const result = await engine.doString(`
      assert(__uiTest.ready().ok == true)
      __uiTest.resourceStates.synex_notify = 'started'
      __uiTest.invokingResource = 'synex_notify'
      local api = assert(__uiTest.exported.GetAPI('1'))
      local upserted, upsertError = api.upsertSignal({
        signalId = 'notify.visibility',
        revision = 1,
        kind = 'toast',
        tone = 'info',
        priority = 'normal',
        title = 'Visibility handshake',
        createdAt = 1000,
        position = 'top-right',
      })
      assert(upsertError == nil and upserted.generation == 1)

      local entry = {
        ownerResource = 'synex_notify',
        ownerEpoch = api.ownerEpoch,
        signalId = 'notify.visibility',
        revision = 1,
      }
      local first, firstReplies = __uiTest.invoke('runtime:signals:visible', {
        protocolVersion = 1,
        requestId = 'visibility-1',
        browserBootId = 'browser-boot-a',
        generation = 1,
        presentationRevision = 1,
        capacity = 4,
        signals = { entry },
      })
      assert(firstReplies == 1 and first.ok == true)
      assert(first.data.presentationRevision == 1 and first.data.visible == 1)

      local hidden, hiddenReplies = __uiTest.invoke('runtime:signals:visible', {
        protocolVersion = 1,
        requestId = 'visibility-2',
        browserBootId = 'browser-boot-a',
        generation = 1,
        presentationRevision = 2,
        capacity = 4,
        signals = {},
      })
      assert(hiddenReplies == 1 and hidden.ok == true)
      assert(hidden.data.presentationRevision == 2 and hidden.data.visible == 0)
      local hiddenSnapshot = assert(api.getSignalSnapshot())
      assert(hiddenSnapshot.visibilityGeneration == 1)
      assert(hiddenSnapshot.visibilityRevision == 2)
      assert(hiddenSnapshot.signals[1].visible == false)

      local shown, shownReplies = __uiTest.invoke('runtime:signals:visible', {
        protocolVersion = 1,
        requestId = 'visibility-3',
        browserBootId = 'browser-boot-a',
        generation = 1,
        presentationRevision = 3,
        capacity = 4,
        signals = { entry },
      })
      assert(shownReplies == 1 and shown.ok == true)
      assert(shown.data.presentationRevision == 3 and shown.data.visible == 1)

      local duplicate, duplicateReplies = __uiTest.invoke('runtime:signals:visible', {
        protocolVersion = 1,
        requestId = 'visibility-stale-presentation',
        browserBootId = 'browser-boot-a',
        generation = 1,
        presentationRevision = 3,
        capacity = 4,
        signals = {},
      })
      assert(duplicateReplies == 1 and duplicate.ok == false)
      assert(duplicate.error.code == 'UI_REQUEST_STALE')

      local staleEntry, staleEntryReplies = __uiTest.invoke('runtime:signals:visible', {
        protocolVersion = 1,
        requestId = 'visibility-stale-signal',
        browserBootId = 'browser-boot-a',
        generation = 1,
        presentationRevision = 4,
        capacity = 4,
        signals = {{
          ownerResource = 'synex_notify',
          ownerEpoch = api.ownerEpoch,
          signalId = 'notify.visibility',
          revision = 2,
        }},
      })
      assert(staleEntryReplies == 1 and staleEntry.ok == false)
      assert(staleEntry.error.code == 'UI_REQUEST_STALE')

      local snapshot = assert(api.getSignalSnapshot())
      assert(snapshot.visibilityGeneration == 1)
      assert(snapshot.visibilityRevision == 3)
      assert(snapshot.signals[1].visible == true)
      return 'signal-visibility-revision-pass'
    `);
    assert.equal(result, 'signal-visibility-revision-pass');
  } finally {
    engine.global.close();
  }
});

test('adaptive Notify capacity is caller-bound, fail-closed, and fences visibility reports', async () => {
  const engine = await createRuntime();
  try {
    const result = await engine.doString(`
      __uiTest.screenWidth = 1280
      __uiTest.screenHeight = 720
      __uiTest.safeZone = 1
      assert(__uiTest.ready('ready-adaptive-capacity', 'browser-boot-capacity').ok == true)
      __uiTest.resourceStates.synex_notify = 'started'
      __uiTest.invokingResource = 'synex_notify'
      local api = assert(__uiTest.exported.GetAPI('1'))
      assert(type(api.bindSignalCapacity) == 'function')

      local rejectedCalls = 0
      local rejected = assert(api.bindSignalCapacity(function()
        rejectedCalls = rejectedCalls + 1
        return false
      end))
      assert(rejected.capacity == 4)
      local rejectedTimer = table.remove(__uiTest.timeouts, #__uiTest.timeouts)
      assert(rejectedTimer.delay == 0)
      rejectedTimer.handler()
      assert(rejectedCalls == 1)
      assert(api.getDiagnostics().metrics.ui_runtime_errors == 1)
      assert(api.setPreferences({ scale = 125 }).scale == 125)
      assert(rejectedCalls == 1)
      assert(api.setPreferences({ scale = 100 }).scale == 100)

      local reports = {}
      local callable = setmetatable({}, {
        __call = function(_, update)
          assert(__uiTest.hasOnlyKeys(update, {
            ownerResource = true, ownerEpoch = true, capacity = true,
            preferences = true,
          }))
          reports[#reports + 1] = update
          return true
        end,
      })
      local binding = assert(api.bindSignalCapacity(callable))
      assert(binding.capacity == 4 and #reports == 0)
      local initialTimer = table.remove(__uiTest.timeouts, #__uiTest.timeouts)
      assert(initialTimer.delay == 0)
      initialTimer.handler()
      assert(#reports == 1)
      assert(reports[1].ownerResource == 'synex_notify')
      assert(reports[1].ownerEpoch == api.ownerEpoch and reports[1].capacity == 4)
      assert(reports[1].preferences.scale == 100
        and reports[1].preferences.density == 'comfortable')
      assert(#__uiTest.focusCalls == 0 and #__uiTest.keepInputCalls == 0)

      local timeoutCount = #__uiTest.timeouts
      local preferences = assert(api.setPreferences({ scale = 125 }))
      assert(preferences.scale == 125 and #reports == 1)
      assert(#__uiTest.timeouts == timeoutCount + 1)
      local reverted = assert(api.setPreferences({ density = 'compact' }))
      assert(reverted.density == 'compact' and #reports == 1)
      assert(#__uiTest.timeouts == timeoutCount + 1)
      local changedTimer = table.remove(__uiTest.timeouts, #__uiTest.timeouts)
      assert(changedTimer.delay == 0)
      changedTimer.handler()
      assert(#reports == 2 and reports[2].capacity == 4)
      assert(reports[2].preferences.scale == 125
        and reports[2].preferences.density == 'compact')
      local constrained = assert(api.setPreferences({ density = 'comfortable' }))
      assert(constrained.density == 'comfortable')
      local constrainedTimer = table.remove(__uiTest.timeouts, #__uiTest.timeouts)
      assert(constrainedTimer.delay == 0)
      constrainedTimer.handler()
      assert(#reports == 3 and reports[3].capacity == 3)
      assert(reports[3].preferences.density == 'comfortable')

      local upserted = assert(api.upsertSignal({
        signalId = 'notify.adaptive-capacity', revision = 1,
        kind = 'toast', tone = 'info', priority = 'normal',
        title = 'Adaptive capacity', createdAt = 1000, position = 'top-right',
      }))
      assert(upserted.generation == 1)
      local entry = {
        ownerResource = 'synex_notify', ownerEpoch = api.ownerEpoch,
        signalId = 'notify.adaptive-capacity', revision = 1,
      }
      local mismatched, mismatchedReplies = __uiTest.invoke('runtime:signals:visible', {
        protocolVersion = 1, requestId = 'visibility-capacity-mismatch',
        browserBootId = 'browser-boot-capacity', generation = 1,
        presentationRevision = 1, capacity = 4, signals = { entry },
      })
      assert(mismatchedReplies == 1 and mismatched.ok == false)
      assert(mismatched.error.code == 'UI_REQUEST_INVALID')

      local accepted, acceptedReplies = __uiTest.invoke('runtime:signals:visible', {
        protocolVersion = 1, requestId = 'visibility-capacity-match',
        browserBootId = 'browser-boot-capacity', generation = 1,
        presentationRevision = 1, capacity = 3, signals = { entry },
      })
      assert(acceptedReplies == 1 and accepted.ok == true)
      assert(accepted.data.capacity == 3 and accepted.data.visible == 1)
      local snapshot = assert(api.getSignalSnapshot())
      assert(snapshot.visibleCapacity == 3 and snapshot.visibilityCapacity == 3)
      assert(#__uiTest.focusCalls == 0 and #__uiTest.keepInputCalls == 0)

      __uiTest.invokingResource = 'owner_alpha'
      local foreign = assert(__uiTest.exported.GetAPI('1'))
      assert(foreign.bindSignalCapacity == nil)
      return table.concat({ binding.capacity, reports[3].capacity,
        snapshot.visibleCapacity, snapshot.visibilityCapacity }, ':')
    `);
    assert.equal(result, '4:3:3:3');
  } finally {
    engine.global.close();
  }
});

test('synex_ui runtime queues conflicting focus and promotes it after release', async () => {
  const engine = await createRuntime();
  try {
    const result = await engine.doString(`
      local ready = __uiTest.ready()
      assert(ready.ok == true)

      __uiTest.installFocusAgent('owner_alpha')
      __uiTest.installFocusAgent('owner_beta')

      __uiTest.invokingResource = 'owner_alpha'
      local alpha = assert(__uiTest.exported.GetAPI('1.0'))
      local alphaLease, alphaError = alpha.acquireFocus({
        mode = 'EXCLUSIVE',
        priority = 'NORMAL',
        conflict = 'DENY',
        reason = 'alpha-modal',
      })
      assert(alphaLease ~= nil and alphaError == nil)
      assert(alphaLease.state == 'active')

      __uiTest.invokingResource = 'owner_beta'
      local beta = assert(__uiTest.exported.GetAPI('^1.0.0'))
      local betaLease, betaError = beta.acquireFocus({
        mode = 'EXCLUSIVE',
        priority = 'NORMAL',
        conflict = 'QUEUE',
        reason = 'beta-modal',
      })
      assert(betaLease ~= nil and betaError == nil)
      assert(betaLease.state == 'queued')
      local queued = assert(beta.getFocusLease(betaLease.leaseId))
      assert(queued.state == 'queued')

      local released, releaseError = alpha.releaseFocus(alphaLease.leaseId)
      assert(released == true and releaseError == nil)
      local promoted = assert(beta.getFocusLease(betaLease.leaseId))
      assert(promoted.state == 'active')

      local diagnostics = assert(beta.getDiagnostics())
      assert(#diagnostics.focus.stack == 1)
      assert(#diagnostics.focus.queue == 0)
      assert(diagnostics.focus.stack[1].ownerResource == 'owner_beta')
      assert(diagnostics.focus.applied.keyboard == true)
      assert(diagnostics.focus.applied.pointer == true)
      return 'focus-queue-pass'
    `);
    assert.equal(result, 'focus-queue-pass');
  } finally {
    engine.global.close();
  }
});

test('synex_ui runtime reserves CRITICAL and SYSTEM focus priorities', async () => {
  const engine = await createRuntime();
  try {
    const result = await engine.doString(`
      assert(__uiTest.ready().ok == true)
      __uiTest.invokingResource = 'owner_alpha'
      local api = assert(__uiTest.exported.GetAPI('1'))

      local critical, criticalError = api.acquireFocus({
        mode = 'EXCLUSIVE', priority = 'CRITICAL', conflict = 'SUSPEND', reason = 'external-critical',
      })
      assert(critical == nil and criticalError.code == 'UI_FOCUS_DENIED')

      local system, systemError = api.acquireFocus({
        mode = 'EXCLUSIVE', priority = 'SYSTEM', conflict = 'SUSPEND', reason = 'external-system',
      })
      assert(system == nil and systemError.code == 'UI_FOCUS_DENIED')

      local diagnostics = assert(api.getDiagnostics())
      assert(#diagnostics.focus.stack == 0 and #diagnostics.focus.queue == 0)
      assert(diagnostics.metrics.ui_focus_denied_total == 2)
      return 'reserved-priority-pass'
    `);
    assert.equal(result, 'reserved-priority-pass');
  } finally {
    engine.global.close();
  }
});

test('synex_ui runtime preserves an active surface on a same-boot ready retry', async () => {
  const engine = await createRuntime();
  try {
    const result = await engine.doString(`
      assert(__uiTest.ready().ok == true)
      __uiTest.invokingResource = 'owner_alpha'
      local api = assert(__uiTest.exported.GetAPI('1'))

      __uiTest.awaitHook = function(waiter)
        local opened = assert(__uiTest.lastMessage('surface:open'))
        local retry, replies = __uiTest.ready('ready-retry', 'browser-boot-a')
        assert(replies == 1 and retry.ok == true)
        local sync = assert(__uiTest.lastMessage('runtime:sync'))
        assert(sync.payload.surfaces == nil)
        local diagnostics = assert(api.getDiagnostics())
        assert(diagnostics.pendingRequests == 1)
        assert(#diagnostics.focus.stack == 1)
        assert(diagnostics.focus.applied.keyboard == true)
        assert(diagnostics.focus.applied.pointer == true)

        local response, responseReplies = __uiTest.invoke('runtime:respond', {
          protocolVersion = 1,
          requestId = opened.payload.requestId,
          instanceId = opened.payload.instanceId,
          surfaceId = opened.payload.surfaceId,
          ownerEpoch = opened.ownerEpoch,
          revision = opened.revision,
          browserBootId = 'browser-boot-a',
          action = 'confirmed',
        })
        assert(responseReplies == 1 and response.ok == true)
        assert(waiter.resolved == true)
      end

      local completion, completionError = api.confirm({ title = 'Keep mounted' })
      __uiTest.awaitHook = nil
      assert(completionError == nil and completion.status == 'confirmed')
      return 'same-boot-ready-pass'
    `);
    assert.equal(result, 'same-boot-ready-pass');
  } finally {
    engine.global.close();
  }
});

test('synex_ui runtime cancels browser-owned work and releases focus on a new browser boot', async () => {
  const engine = await createRuntime();
  try {
    const result = await engine.doString(`
      assert(__uiTest.ready().ok == true)
      __uiTest.invokingResource = 'owner_alpha'
      local api = assert(__uiTest.exported.GetAPI('1'))

      __uiTest.awaitHook = function(waiter)
        local opened = assert(__uiTest.lastMessage('surface:open'))
        local restarted, replies = __uiTest.ready('ready-restarted', 'browser-boot-b')
        assert(replies == 1 and restarted.ok == true)
        assert(waiter.resolved == true)

        local diagnostics = assert(api.getDiagnostics())
        assert(diagnostics.pendingRequests == 0)
        assert(#diagnostics.surfaces == 0)
        assert(#diagnostics.focus.stack == 0 and #diagnostics.focus.queue == 0)
        assert(diagnostics.focus.applied.keyboard == false)
        assert(diagnostics.focus.applied.pointer == false)

        local sync = assert(__uiTest.lastMessage('runtime:sync'))
        assert(type(sync.payload.surfaces) == 'table' and #sync.payload.surfaces == 0)
        local stale, staleReplies = __uiTest.invoke('runtime:respond', {
          protocolVersion = 1,
          requestId = opened.payload.requestId,
          instanceId = opened.payload.instanceId,
          surfaceId = opened.payload.surfaceId,
          ownerEpoch = opened.ownerEpoch,
          revision = opened.revision,
          browserBootId = 'browser-boot-a',
          action = 'confirmed',
        })
        assert(staleReplies == 1 and stale.ok == false)
        assert(stale.error.code == 'UI_REQUEST_INVALID')
      end

      local completion, completionError = api.confirm({ title = 'Browser restart' })
      __uiTest.awaitHook = nil
      assert(completion == nil and completionError.code == 'UI_REQUEST_CANCELLED')
      return 'new-browser-boot-cleanup-pass'
    `);
    assert.equal(result, 'new-browser-boot-cleanup-pass');
  } finally {
    engine.global.close();
  }
});

test('synex_ui runtime timeout resolves the waiter and releases its exact surface lease', async () => {
  const engine = await createRuntime();
  try {
    const result = await engine.doString(`
      assert(__uiTest.ready().ok == true)
      __uiTest.invokingResource = 'owner_alpha'
      local api = assert(__uiTest.exported.GetAPI('1'))

      __uiTest.awaitHook = function(waiter)
        local opened = assert(__uiTest.lastMessage('surface:open'))
        local timeout = assert(__uiTest.timeouts[#__uiTest.timeouts])
        assert(timeout.delay == 1000)
        timeout.handler()
        assert(waiter.resolved == true)

        local diagnostics = assert(api.getDiagnostics())
        assert(diagnostics.pendingRequests == 0 and #diagnostics.surfaces == 0)
        assert(#diagnostics.focus.stack == 0 and #diagnostics.focus.queue == 0)
        assert(diagnostics.focus.applied.keyboard == false)
        assert(diagnostics.focus.applied.pointer == false)

        local late, replies = __uiTest.invoke('runtime:respond', {
          protocolVersion = 1,
          requestId = opened.payload.requestId,
          instanceId = opened.payload.instanceId,
          surfaceId = opened.payload.surfaceId,
          ownerEpoch = opened.ownerEpoch,
          revision = opened.revision,
          browserBootId = 'browser-boot-a',
          action = 'confirmed',
        })
        assert(replies == 1 and late.ok == false)
        assert(late.error.code == 'UI_REQUEST_STALE')
      end

      local completion, completionError = api.confirm({
        title = 'Bounded timeout', timeoutMs = 1000,
      })
      __uiTest.awaitHook = nil
      assert(completion == nil and completionError.code == 'UI_REQUEST_TIMEOUT')
      assert(__uiTest.messageCount('surface:close') == 1)
      return 'surface-timeout-cleanup-pass'
    `);
    assert.equal(result, 'surface-timeout-cleanup-pass');
  } finally {
    engine.global.close();
  }
});

test('synex_ui runtime render telemetry cancels the exact surface and releases focus', async () => {
  const engine = await createRuntime();
  try {
    const result = await engine.doString(`
      assert(__uiTest.ready().ok == true)
      __uiTest.invokingResource = 'owner_alpha'
      local api = assert(__uiTest.exported.GetAPI('1'))

      __uiTest.awaitHook = function(waiter)
        local opened = assert(__uiTest.lastMessage('surface:open'))
        local report, replies = __uiTest.invoke('runtime:error', {
          protocolVersion = 1,
          requestId = 'render-error-report',
          browserBootId = 'browser-boot-a',
          code = 'UI_REQUEST_INVALID',
          stage = 'render',
          surfaceRequestId = opened.payload.requestId,
          instanceId = opened.payload.instanceId,
          surfaceId = opened.payload.surfaceId,
          ownerEpoch = opened.ownerEpoch,
          revision = opened.revision,
        })
        assert(replies == 1 and report.ok == true)
        assert(waiter.resolved == true)
        local diagnostics = assert(api.getDiagnostics())
        assert(diagnostics.pendingRequests == 0)
        assert(#diagnostics.focus.stack == 0 and #diagnostics.focus.queue == 0)
        assert(diagnostics.focus.applied.keyboard == false)
        assert(diagnostics.focus.applied.pointer == false)
      end

      local completion, completionError = api.confirm({ title = 'Render failure' })
      __uiTest.awaitHook = nil
      assert(completion == nil)
      assert(completionError.code == 'UI_REQUEST_CANCELLED')
      assert(__uiTest.messageCount('surface:close') == 1)
      return 'render-error-release-pass'
    `);
    assert.equal(result, 'render-error-release-pass');
  } finally {
    engine.global.close();
  }
});

test('synex_ui runtime emits canonical surfaces and preserves false callback data', async () => {
  const engine = await createRuntime();
  try {
    const result = await engine.doString(`
      local ready = __uiTest.ready()
      assert(ready.ok == true)
      __uiTest.invokingResource = 'owner_alpha'
      local api = assert(__uiTest.exported.GetAPI())

      __uiTest.awaitHook = function(waiter)
        local opened = assert(__uiTest.lastMessage('surface:open'))
        assert(__uiTest.hasOnlyKeys(opened, {
          protocolVersion = true,
          messageId = true,
          type = true,
          ownerResource = true,
          ownerEpoch = true,
          revision = true,
          payload = true,
        }))
        assert(opened.protocolVersion == 1)
        assert(opened.ownerResource == 'owner_alpha')
        assert(opened.ownerEpoch == api.ownerEpoch)
        assert(opened.revision == 1)
        assert(opened.payload.kind == 'confirm')
        assert(opened.payload.title == 'Discard changes?')
        assert(opened.payload.description == 'The local draft will be removed.')
        assert(opened.payload.message == nil)
        assert(opened.payload.tone == 'danger')
        assert(opened.payload.danger == nil)
        assert(opened.payload.dismissible == true)
        assert(type(opened.payload.requestId) == 'string')
        assert(type(opened.payload.instanceId) == 'string')
        assert(type(opened.payload.surfaceId) == 'string')

        local response, replies = __uiTest.invoke('runtime:respond', {
          protocolVersion = 1,
          requestId = opened.payload.requestId,
          instanceId = opened.payload.instanceId,
          surfaceId = opened.payload.surfaceId,
          ownerEpoch = opened.ownerEpoch,
          revision = opened.revision,
          browserBootId = 'browser-boot-a',
          action = 'confirmed',
          data = false,
        })
        assert(replies == 1)
        assert(response.ok == true)
        assert(response.data.status == 'confirmed')
        assert(waiter.resolved == true)
      end

      local confirmation, confirmationError = api.confirm({
        title = 'Discard changes?',
        message = 'The local draft will be removed.',
        danger = true,
      })
      __uiTest.awaitHook = nil
      assert(confirmationError == nil)
      assert(confirmation.status == 'confirmed')
      assert(confirmation.data == false)
      assert(__uiTest.messageCount('surface:open') == 1)
      assert(__uiTest.messageCount('surface:close') == 1)

      local before = __uiTest.messageCount('surface:open')
      local invalid, invalidError = api.select({
        title = 'Unsafe icon metadata',
        options = {{ id = 'unsafe', label = 'Unsafe', icon = 'remote-icon' }},
      })
      assert(invalid == nil)
      assert(invalidError.code == 'UI_REQUEST_INVALID')
      assert(__uiTest.messageCount('surface:open') == before)
      local diagnostics = assert(api.getDiagnostics())
      assert(diagnostics.pendingRequests == 0)
      assert(#diagnostics.focus.stack == 0)
      assert(diagnostics.focus.applied.keyboard == false)
      assert(diagnostics.focus.applied.pointer == false)
      return 'surface-contract-pass'
    `);
    assert.equal(result, 'surface-contract-pass');
  } finally {
    engine.global.close();
  }
});

test('synex_ui runtime canonicalizes fresh constructor-less Cfx JSON containers without trusting arbitrary metatables', async () => {
  const engine = await createCfxJsonRuntime();
  try {
    const result = await engine.doString(`
      local ordinaryObjectA = json.decode('{}')
      local ordinaryObjectB = json.decode('{}')
      assert(not rawequal(debug.getmetatable(ordinaryObjectA), debug.getmetatable(ordinaryObjectB)))

      local readyRequest = __cfxJson.decodeSnapshot({
        kind = 'object', entries = {
          { key = 'protocolVersion', value = 1 },
          { key = 'requestId', value = 'ready-cfx-json' },
          { key = 'browserBootId', value = 'browser-cfx-json' },
        },
      })
      local ready, readyReplies = __uiTest.invoke('runtime:ready', readyRequest)
      assert(readyReplies == 1 and ready.ok == true)

      __uiTest.invokingResource = 'owner_alpha'
      local api = assert(__uiTest.exported.GetAPI('1'))
      __uiTest.awaitHook = function(waiter)
        local opened = assert(__uiTest.lastMessage('surface:open'))
        local responseRequest = __cfxJson.decodeSnapshot({
          kind = 'object', entries = {
            { key = 'protocolVersion', value = 1 },
            { key = 'requestId', value = opened.payload.requestId },
            { key = 'instanceId', value = opened.payload.instanceId },
            { key = 'surfaceId', value = opened.payload.surfaceId },
            { key = 'ownerEpoch', value = opened.ownerEpoch },
            { key = 'revision', value = opened.revision },
            { key = 'browserBootId', value = 'browser-cfx-json' },
            { key = 'action', value = 'confirmed' },
            { key = 'data', value = {
              kind = 'object', entries = {
                { key = 'emptyObject', value = { kind = 'object', entries = {} } },
                { key = 'emptyArray', value = { kind = 'array', values = {} } },
              },
            } },
          },
        })
        __uiTest.rawObjectMetatable = debug.getmetatable(responseRequest.data.emptyObject)
        __uiTest.rawArrayMetatable = debug.getmetatable(responseRequest.data.emptyArray)
        local response, replies = __uiTest.invoke('runtime:respond', responseRequest)
        assert(replies == 1 and response.ok == true and waiter.resolved == true)
      end

      local completion, completionError = api.confirm({ title = 'Cfx JSON identity' })
      __uiTest.awaitHook = nil
      assert(completionError == nil and completion.status == 'confirmed')
      local objectMetatable = debug.getmetatable(completion.data.emptyObject)
      local arrayMetatable = debug.getmetatable(completion.data.emptyArray)
      assert(type(objectMetatable) == 'table' and objectMetatable.__jsontype == 'object')
      assert(type(arrayMetatable) == 'table' and arrayMetatable.__jsontype == 'array')
      assert(not rawequal(objectMetatable, __uiTest.rawObjectMetatable))
      assert(not rawequal(arrayMetatable, __uiTest.rawArrayMetatable))
      assert(json.encode(completion.data.emptyObject) == '{}')
      assert(json.encode(completion.data.emptyArray) == '[]')
      assert(__cfxJson.suppliedDecodeCalls >= 2)

      local before = __uiTest.messageCount('surface:open')
      local hostile = setmetatable({}, { __jsontype = 'object' })
      local invalid, invalidError = api.select({
        title = 'Reject arbitrary metatable',
        options = {{ id = 'hostile', label = 'Hostile', metadata = hostile }},
      })
      assert(invalid == nil and invalidError.code == 'UI_REQUEST_INVALID')
      assert(__uiTest.messageCount('surface:open') == before)

      local trapCalls = 0
      local trapped = setmetatable({}, {
        __jsontype = 'object',
        __pairs = function() trapCalls = trapCalls + 1; error('must not execute') end,
      })
      local trappedValue, trappedError = api.select({
        title = 'Reject active metatable',
        options = {{ id = 'trapped', label = 'Trapped', metadata = trapped }},
      })
      assert(trappedValue == nil and trappedError.code == 'UI_REQUEST_INVALID')
      assert(trapCalls == 0 and __uiTest.messageCount('surface:open') == before)
      return 'cfx-json-canonicalization-pass'
    `);
    assert.equal(result, 'cfx-json-canonicalization-pass');
  } finally {
    engine.global.close();
  }
});

test('synex_ui runtime rejects extra callback fields and accepts bounded error telemetry', async () => {
  const engine = await createRuntime();
  try {
    const result = await engine.doString(`
      local invalidReady, invalidReadyReplies = __uiTest.invoke('runtime:ready', {
        protocolVersion = 1,
        requestId = 'ready-extra',
        browserBootId = 'browser-boot-a',
        unexpected = true,
      })
      assert(invalidReadyReplies == 1)
      assert(invalidReady.ok == false)
      assert(invalidReady.error.code == 'UI_REQUEST_INVALID')
      assert(__uiTest.messageCount('runtime:sync') == 0)

      local ready, readyReplies = __uiTest.ready('ready-valid', 'browser-boot-a')
      assert(readyReplies == 1 and ready.ok == true)

      local input, inputReplies = __uiTest.invoke('runtime:input', {
        protocolVersion = 1,
        requestId = 'input-mouse',
        browserBootId = 'browser-boot-a',
        device = 'mouse',
      })
      assert(inputReplies == 1 and input.ok == true)
      assert(input.data.device == 'mouse')

      local invalidInput, invalidInputReplies = __uiTest.invoke('runtime:input', {
        protocolVersion = 1,
        requestId = 'input-extra',
        browserBootId = 'browser-boot-a',
        device = 'keyboard',
        route = 'arbitrary',
      })
      assert(invalidInputReplies == 1)
      assert(invalidInput.ok == false)
      assert(invalidInput.error.code == 'UI_REQUEST_INVALID')

      local reported, reportReplies = __uiTest.invoke('runtime:error', {
        protocolVersion = 1,
        requestId = 'message-error',
        browserBootId = 'browser-boot-a',
        code = 'UI_REQUEST_INVALID',
        stage = 'message',
      })
      assert(reportReplies == 1 and reported.ok == true)

      local invalidReport, invalidReportReplies = __uiTest.invoke('runtime:error', {
        protocolVersion = 1,
        requestId = 'render-error-extra',
        browserBootId = 'browser-boot-a',
        code = 'UI_REQUEST_INVALID',
        stage = 'message',
        detail = 'must-not-cross-boundary',
      })
      assert(invalidReportReplies == 1)
      assert(invalidReport.ok == false)
      assert(invalidReport.error.code == 'UI_REQUEST_INVALID')

      __uiTest.invokingResource = 'owner_alpha'
      local api = assert(__uiTest.exported.GetAPI('1'))
      local diagnostics = assert(api.getDiagnostics())
      assert(diagnostics.activeInputDevice == 'mouse')
      assert(diagnostics.metrics.ui_runtime_errors >= 1)
      assert(diagnostics.health.state == 'DEGRADED')
      return 'callback-boundary-pass'
    `);
    assert.equal(result, 'callback-boundary-pass');
  } finally {
    engine.global.close();
  }
});

test('synex_ui runtime rejects unknown, deep, oversized, and markup-bearing callback payloads', async () => {
  const engine = await createRuntime();
  try {
    const result = await engine.doString(`
      assert(__uiTest.callbacks['runtime:execute'] == nil)
      assert(__uiTest.ready().ok == true)
      __uiTest.invokingResource = 'owner_alpha'
      local api = assert(__uiTest.exported.GetAPI('1'))

      __uiTest.awaitHook = function(waiter)
        local opened = assert(__uiTest.lastMessage('surface:open'))
        local function response(data, action)
          return __uiTest.invoke('runtime:respond', {
            protocolVersion = 1,
            requestId = opened.payload.requestId,
            instanceId = opened.payload.instanceId,
            surfaceId = opened.payload.surfaceId,
            ownerEpoch = opened.ownerEpoch,
            revision = opened.revision,
            browserBootId = 'browser-boot-a',
            action = action or 'confirmed',
            data = data,
          })
        end

        local deep = {}
        local cursor = deep
        for _ = 1, api.limits.maximumDepth + 2 do
          cursor.child = {}
          cursor = cursor.child
        end
        local invalidValues = {
          deep,
          { text = string.rep('x', api.limits.maximumStringBytes + 1) },
          { html = '<img src=x onerror=alert(1)>' },
          { svg = '<svg><script /></svg>' },
          { url = 'https://example.invalid/payload' },
        }
        for _, invalidValue in ipairs(invalidValues) do
          local rejectedValue, replies = response(invalidValue)
          assert(replies == 1 and rejectedValue.ok == false)
          assert(rejectedValue.error.code == 'UI_REQUEST_INVALID')
          assert(waiter.resolved == false)
        end

        local unknownAction, unknownReplies = response(nil, 'execute')
        assert(unknownReplies == 1 and unknownAction.ok == false)
        assert(unknownAction.error.code == 'UI_REQUEST_INVALID')
        assert(waiter.resolved == false)

        local accepted, acceptedReplies = response({ safe = true })
        assert(acceptedReplies == 1 and accepted.ok == true)
        assert(waiter.resolved == true)
      end

      local completion, completionError = api.confirm({ title = 'Payload boundary' })
      __uiTest.awaitHook = nil
      assert(completionError == nil and completion.status == 'confirmed')
      assert(completion.data.safe == true)
      return 'payload-abuse-matrix-pass'
    `);
    assert.equal(result, 'payload-abuse-matrix-pass');
  } finally {
    engine.global.close();
  }
});

test('synex_ui runtime fences owner epochs and resolves work when owners stop', async () => {
  const engine = await createRuntime();
  try {
    const result = await engine.doString(`
      local ready = __uiTest.ready()
      assert(ready.ok == true)
      __uiTest.invokingResource = 'owner_alpha'
      local staleFacade = assert(__uiTest.exported.GetAPI('1'))
      local originalEpoch = staleFacade.ownerEpoch

      __uiTest.awaitHook = function()
        __uiTest.handlers.onClientResourceStop('owner_alpha')
      end
      local completion, completionError = staleFacade.confirm({
        title = 'Owner-bound request',
        description = 'This request must not survive the owner epoch.',
      })
      __uiTest.awaitHook = nil
      assert(completion == nil)
      assert(completionError.code == 'UI_OWNER_STOPPED')

      local stopped, stoppedError = staleFacade.getHealth()
      assert(stopped == nil)
      assert(stoppedError.code == 'UI_OWNER_STOPPED')

      __uiTest.handlers.onClientResourceStart('owner_alpha')
      local stale, staleError = staleFacade.getHealth()
      assert(stale == nil)
      assert(staleError.code == 'UI_OWNER_STALE')

      __uiTest.invokingResource = 'owner_alpha'
      local currentFacade = assert(__uiTest.exported.GetAPI('v1'))
      assert(currentFacade.ownerEpoch > originalEpoch)
      local health, healthError = currentFacade.getHealth()
      assert(healthError == nil and health.state == 'READY')
      assert(__uiTest.messageCount('surface:close') == 1)
      return 'owner-fencing-pass'
    `);
    assert.equal(result, 'owner-fencing-pass');
  } finally {
    engine.global.close();
  }
});

test('synex_ui runtime shutdown releases focus and cancels pending surfaces', async () => {
  const engine = await createRuntime();
  try {
    const result = await engine.doString(`
      local ready = __uiTest.ready()
      assert(ready.ok == true)
      __uiTest.invokingResource = 'owner_alpha'
      local api = assert(__uiTest.exported.GetAPI('1.0.0'))

      __uiTest.awaitHook = function()
        __uiTest.handlers.onClientResourceStop('synex_ui')
      end
      local completion, completionError = api.confirm({
        title = 'Runtime shutdown request',
      })
      __uiTest.awaitHook = nil
      assert(completion == nil)
      assert(completionError.code == 'UI_REQUEST_CANCELLED')
      assert(__uiTest.messageCount('runtime:shutdown') == 1)

      local diagnostics = assert(api.getDiagnostics())
      assert(diagnostics.nuiReady == false)
      assert(diagnostics.pendingRequests == 0)
      assert(#diagnostics.focus.stack == 0)
      assert(#diagnostics.focus.queue == 0)
      assert(diagnostics.focus.applied.keyboard == false)
      assert(diagnostics.focus.applied.pointer == false)

      local lastFocus = __uiTest.focusCalls[#__uiTest.focusCalls]
      assert(lastFocus.keyboard == false and lastFocus.pointer == false)
      assert(__uiTest.keepInputCalls[#__uiTest.keepInputCalls] == false)
      local lease, leaseError = api.acquireFocus({ mode = 'EXCLUSIVE' })
      assert(lease == nil)
      assert(leaseError.code == 'UI_NOT_READY')
      return 'runtime-cleanup-pass'
    `);
    assert.equal(result, 'runtime-cleanup-pass');
  } finally {
    engine.global.close();
  }
});
