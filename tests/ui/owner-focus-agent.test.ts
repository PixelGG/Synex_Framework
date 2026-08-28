import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory, type LuaEngine } from 'wasmoon';

const root = process.cwd();

const bridgeHarness = `
  __bridge = {
    currentResource = 'synex_ui',
    invokingResource = nil,
    exported = {}, callbacks = {}, handlers = {}, sent = {},
    focusCalls = {}, keepInputCalls = {}, ownerMessages = {}, threads = {}, timeouts = {},
    resourceStates = { owner_alpha = 'started', owner_beta = 'started', synex_ui = 'started' },
    now = 1000, pressedControl = nil, failOwnerFocus = false, failOwnerMessage = false,
  }

  GetCurrentResourceName = function() return __bridge.currentResource end
  GetInvokingResource = function() return __bridge.invokingResource end
  GetGameTimer = function() return __bridge.now end
  GetActualScreenResolution = function() return 1920, 1080 end
  GetSafeZoneSize = function() return 1.0 end
  GetResourceState = function(resource) return __bridge.resourceStates[resource] or 'missing' end
  GetRandomIntInRange = function(minimum, maximum)
    __bridge.randomSerial = (__bridge.randomSerial or 100) + 7919
    return minimum + (__bridge.randomSerial % (maximum - minimum))
  end

  SetNuiFocusKeepInput = function(value)
    __bridge.keepInputCalls[#__bridge.keepInputCalls + 1] = {
      resource = __bridge.currentResource, value = value,
    }
  end
  SetNuiFocus = function(keyboard, pointer)
    __bridge.focusCalls[#__bridge.focusCalls + 1] = {
      resource = __bridge.currentResource, keyboard = keyboard, pointer = pointer,
    }
    if __bridge.failOwnerFocus and __bridge.currentResource ~= 'synex_ui'
      and (keyboard or pointer) then error('simulated owner native failure') end
  end
  SendNUIMessage = function(message)
    if __bridge.failOwnerMessage and __bridge.currentResource ~= 'synex_ui' then
      error('simulated owner message failure')
    end
    if __bridge.currentResource == 'synex_ui' then
      __bridge.sent[#__bridge.sent + 1] = message
    else
      __bridge.ownerMessages[#__bridge.ownerMessages + 1] = {
        resource = __bridge.currentResource, message = message,
      }
    end
  end
  RegisterNuiCallback = function(route, handler) __bridge.callbacks[route] = handler end
  AddEventHandler = function(name, handler)
    __bridge.handlers[name] = __bridge.handlers[name] or {}
    __bridge.handlers[name][#__bridge.handlers[name] + 1] = {
      resource = __bridge.currentResource, handler = handler,
    }
  end
  function __bridge.emit(name, ...)
    local entries = __bridge.handlers[name] or {}
    local count = #entries
    for index = 1, count do
      local entry = entries[index]
      local previous = __bridge.currentResource
      __bridge.currentResource = entry.resource
      entry.handler(...)
      __bridge.currentResource = previous
    end
  end
  TriggerEvent = function(name, ...) return __bridge.emit(name, ...) end

  function __bridge.useRegistrar()
    exports = function(name, handler) __bridge.exported[name] = handler end
  end
  function __bridge.callExport(caller, name, ...)
    local handler = assert(__bridge.exported[name], 'missing export: ' .. name)
    local previousResource, previousInvoking = __bridge.currentResource, __bridge.invokingResource
    __bridge.currentResource = 'synex_ui'
    __bridge.invokingResource = caller
    local values = table.pack(handler(...))
    __bridge.currentResource = previousResource
    __bridge.invokingResource = previousInvoking
    return table.unpack(values, 1, values.n)
  end
  function __bridge.useConsumerExports()
    exports = { synex_ui = setmetatable({}, {
      __index = function(_, name)
        return function(_, ...)
          local caller = __bridge.currentResource
          return __bridge.callExport(caller, name, ...)
        end
      end,
    }) }
  end

  CreateThread = function(handler)
    __bridge.threads[#__bridge.threads + 1] = coroutine.create(handler)
  end
  Wait = function(delay) return coroutine.yield(delay) end
  function __bridge.tickThread(index)
    local thread = __bridge.threads[index]
    if thread == nil or coroutine.status(thread) == 'dead' then return false end
    local resumed, errorValue = coroutine.resume(thread)
    assert(resumed, errorValue)
    return coroutine.status(thread) ~= 'dead'
  end
  SetTimeout = function(delay, handler)
    __bridge.timeouts[#__bridge.timeouts + 1] = { delay = delay, handler = handler }
  end
  IsUsingKeyboard = function() return false end
  DisableControlAction = function() end
  IsDisabledControlJustPressed = function(_, control)
    if __bridge.pressedControl == control then
      __bridge.pressedControl = nil
      return true
    end
    return false
  end
  GetResourceKvpString = function() return nil end
  SetResourceKvp = function() end
  DeleteResourceKvp = function() end

  json = { encode = function() return '{}' end, decode = function() return {} end }
  promise = {
    new = function()
      return { resolved = false, value = nil, resolve = function(self, value)
        assert(not self.resolved); self.resolved = true; self.value = value
      end }
    end,
  }
  Citizen = {
    Await = function(waiter)
      if type(__bridge.awaitHook) == 'function' then __bridge.awaitHook(waiter) end
      return waiter.value
    end,
  }

  function __bridge.invoke(route, request)
    local response, replies = nil, 0
    assert(type(__bridge.callbacks[route]) == 'function', 'missing callback: ' .. route)
    local previous = __bridge.currentResource
    __bridge.currentResource = 'synex_ui'
    __bridge.callbacks[route](request, function(value) replies = replies + 1; response = value end)
    __bridge.currentResource = previous
    assert(replies == 1)
    return response
  end
  function __bridge.ready(boot)
    return __bridge.invoke('runtime:ready', {
      protocolVersion = 1, requestId = 'ready-' .. boot, browserBootId = boot,
    })
  end
  function __bridge.lastMessage(messageType)
    for index = #__bridge.sent, 1, -1 do
      if __bridge.sent[index].type == messageType then return __bridge.sent[index] end
    end
    return nil
  end
`;

async function sources(): Promise<{ central: string; helper: string }> {
  const [central, helper] = await Promise.all([
    readFile(path.join(root, 'libraries/synex_ui/client/client.lua'), 'utf8'),
    readFile(path.join(root, 'libraries/synex_ui/client/owner_focus.lua'), 'utf8'),
  ]);
  return { central, helper };
}

async function createBridge(): Promise<{ engine: LuaEngine; central: string; helper: string }> {
  const engine = await new LuaFactory().createEngine();
  const source = await sources();
  await engine.doString(bridgeHarness);
  await engine.doString(`__bridge.useRegistrar(); assert(load(${JSON.stringify(source.central)}, '@synex_ui/client.lua'))()`);
  return { engine, ...source };
}

async function loadOwnerHelper(engine: LuaEngine, helper: string, owner = 'owner_alpha'): Promise<void> {
  await engine.doString(`
    __bridge.currentResource = ${JSON.stringify(owner)}
    __bridge.useConsumerExports()
    assert(load(${JSON.stringify(helper)}, '@${owner}/owner_focus.lua'))()
    __bridge.currentResource = 'synex_ui'
  `);
}

test('direct interactive focus fails closed without a compatible owner agent', async () => {
  const { engine } = await createBridge();
  try {
    const result = await engine.doString(`
      assert(__bridge.ready('boot-a').ok)
      local api = assert(__bridge.callExport('owner_beta', 'GetAPI', '1'))
      local lease, leaseError = api.acquireFocus({ mode = 'EXCLUSIVE' })
      assert(lease == nil and leaseError.code == 'UI_FOCUS_DENIED')
      local diagnostics = assert(api.getDiagnostics())
      assert(#diagnostics.focus.stack == 0)
      return 'absent-agent-pass'
    `);
    assert.equal(result, 'absent-agent-pass');
  } finally {
    engine.global.close();
  }
});

test('owner helper applies direct focus and gamepad intents in the owner resource context', async () => {
  const { engine, helper } = await createBridge();
  try {
    await loadOwnerHelper(engine, helper);
    const result = await engine.doString(`
      assert(__bridge.ready('boot-owner').ok)
      local api = assert(__bridge.callExport('owner_alpha', 'GetAPI', '1'))
      local lease = assert(api.acquireFocus({ mode = 'EXCLUSIVE', reason = 'owner-panel' }))
      local applied = __bridge.focusCalls[#__bridge.focusCalls]
      assert(applied.resource == 'owner_alpha' and applied.keyboard and applied.pointer)
      for _, call in ipairs(__bridge.focusCalls) do
        assert(not (call.resource == 'synex_ui' and (call.keyboard or call.pointer)))
      end

      local state = assert(__bridge.callExport('owner_alpha', 'GetFocusAgentState', '1'))
      local focusCallCount = #__bridge.focusCalls
      TriggerEvent(state.wakeupEvent, 'owner_alpha', state.ownerEpoch,
        state.bootGeneration, math.max(1, state.revision - 1), 0)
      assert(#__bridge.focusCalls == focusCallCount)
      local stale, staleError = __bridge.callExport('owner_alpha', 'AcknowledgeFocusAgent', {
        version = '1.0.0', bootGeneration = state.bootGeneration,
        ownerEpoch = state.ownerEpoch, revision = math.max(1, state.revision - 1),
        keyboard = true, pointer = true, applied = true,
        intentGeneration = 0, intentDelivered = false,
      })
      assert(stale == nil and staleError.code == 'UI_REQUEST_STALE')

      __bridge.pressedControl = 201
      assert(__bridge.tickThread(1))
      local ownerMessage = __bridge.ownerMessages[#__bridge.ownerMessages]
      assert(ownerMessage.resource == 'owner_alpha')
      assert(ownerMessage.message.messageId == ('focus-intent-%d'):format(
        ownerMessage.message.payload.generation))
      assert(ownerMessage.message.type == 'input:intent')
      assert(ownerMessage.message.payload.intent == 'CONFIRM')
      assert(ownerMessage.message.payload.device == 'gamepad')
      assert(ownerMessage.message.payload.generation >= 1)

      assert(api.releaseFocus(lease.leaseId))
      local released = __bridge.focusCalls[#__bridge.focusCalls]
      assert(released.resource == 'owner_alpha' and not released.keyboard and not released.pointer)
      return 'owner-context-pass'
    `);
    assert.equal(result, 'owner-context-pass');
  } finally {
    engine.global.close();
  }
});

test('failed owner native application rolls back the lease and recovers the agent to unfocused', async () => {
  const { engine, helper } = await createBridge();
  try {
    await loadOwnerHelper(engine, helper);
    const result = await engine.doString(`
      assert(__bridge.ready('boot-failure').ok)
      local api = assert(__bridge.callExport('owner_alpha', 'GetAPI', '1'))
      __bridge.failOwnerFocus = true
      local lease, leaseError = api.acquireFocus({ mode = 'EXCLUSIVE' })
      assert(lease == nil and leaseError.code == 'UI_FOCUS_DENIED')
      __bridge.failOwnerFocus = false
      local diagnostics = assert(api.getDiagnostics())
      assert(#diagnostics.focus.stack == 0 and diagnostics.focus.applied.target == 'none')
      local state = assert(__bridge.callExport('owner_alpha', 'GetFocusAgentState', '1'))
      assert(state.keyboard == false and state.pointer == false)
      assert(state.pending == false and state.acknowledgedRevision == state.revision)
      return 'native-failure-pass'
    `);
    assert.equal(result, 'native-failure-pass');
  } finally {
    engine.global.close();
  }
});

test('shared surfaces hand focus back to the owner agent and block new direct leases while open', async () => {
  const { engine, helper } = await createBridge();
  try {
    await loadOwnerHelper(engine, helper);
    const result = await engine.doString(`
      assert(__bridge.ready('boot-handoff').ok)
      local api = assert(__bridge.callExport('owner_alpha', 'GetAPI', '1'))
      local direct = assert(api.acquireFocus({ mode = 'EXCLUSIVE', reason = 'domain-panel' }))
      __bridge.awaitHook = function(waiter)
        local ownerReleased, sharedApplied = false, false
        for _, call in ipairs(__bridge.focusCalls) do
          if call.resource == 'owner_alpha' and not call.keyboard and not call.pointer then ownerReleased = true end
          if call.resource == 'synex_ui' and call.keyboard and call.pointer then sharedApplied = true end
        end
        assert(ownerReleased and sharedApplied)
        local denied, deniedError = api.acquireFocus({ mode = 'EXCLUSIVE', reason = 'illegal-overlap' })
        assert(denied == nil and deniedError.code == 'UI_FOCUS_BUSY')
        local opened = assert(__bridge.lastMessage('surface:open'))
        local response = __bridge.invoke('runtime:respond', {
          protocolVersion = 1, requestId = opened.payload.requestId,
          instanceId = opened.payload.instanceId, surfaceId = opened.payload.surfaceId,
          ownerEpoch = opened.ownerEpoch, revision = opened.revision,
          browserBootId = 'boot-handoff', action = 'confirmed', data = true,
        })
        assert(response.ok)
      end
      local completion, completionError = api.confirm({ title = 'Continue?' })
      assert(completion ~= nil, completionError and completionError.code or 'missing completion')
      assert(completion.status == 'confirmed')
      local restored = __bridge.focusCalls[#__bridge.focusCalls]
      assert(restored.resource == 'owner_alpha' and restored.keyboard and restored.pointer)
      assert(api.releaseFocus(direct.leaseId))
      return 'handoff-pass'
    `);
    assert.equal(result, 'handoff-pass');
  } finally {
    engine.global.close();
  }
});

test('owner and synex_ui stop paths clear owner focus and a restarted runtime gets a new generation', async () => {
  const { engine, central, helper } = await createBridge();
  try {
    await loadOwnerHelper(engine, helper);
    const result = await engine.doString(`
      assert(__bridge.ready('boot-before-restart').ok)
      local api = assert(__bridge.callExport('owner_alpha', 'GetAPI', '1'))
      assert(api.acquireFocus({ mode = 'EXCLUSIVE' }))
      local before = assert(__bridge.callExport('owner_alpha', 'GetFocusAgentState', '1')).bootGeneration

      __bridge.emit('onClientResourceStop', 'synex_ui')
      local stopped = __bridge.focusCalls[#__bridge.focusCalls]
      assert(stopped.resource == 'owner_alpha' and not stopped.keyboard and not stopped.pointer)

      __bridge.currentResource = 'synex_ui'
      __bridge.useRegistrar()
      assert(load(${JSON.stringify(central)}, '@synex_ui/restarted-client.lua'))()
      __bridge.useConsumerExports()
      __bridge.emit('onClientResourceStart', 'synex_ui')
      assert(__bridge.ready('boot-after-restart').ok)
      local after = assert(__bridge.callExport('owner_alpha', 'GetFocusAgentState', '1')).bootGeneration
      assert(after ~= before)
      local restartedApi = assert(__bridge.callExport('owner_alpha', 'GetAPI', '1'))
      assert(restartedApi.acquireFocus({ mode = 'EXCLUSIVE' }))
      local reapplied = __bridge.focusCalls[#__bridge.focusCalls]
      assert(reapplied.resource == 'owner_alpha' and reapplied.keyboard and reapplied.pointer)

      __bridge.emit('onClientResourceStop', 'owner_alpha')
      local ownerStopped = __bridge.focusCalls[#__bridge.focusCalls]
      assert(ownerStopped.resource == 'owner_alpha' and not ownerStopped.keyboard and not ownerStopped.pointer)
      local stale, staleError = restartedApi.acquireFocus({ mode = 'EXCLUSIVE' })
      assert(stale == nil and (staleError.code == 'UI_OWNER_STOPPED' or staleError.code == 'UI_OWNER_STALE'))
      return 'restart-owner-stop-pass'
    `);
    assert.equal(result, 'restart-owner-stop-pass');
  } finally {
    engine.global.close();
  }
});
