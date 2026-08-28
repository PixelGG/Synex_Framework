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
  }

  GetCurrentResourceName = function() return 'synex_ui' end
  GetGameTimer = function() return __uiTest.now end
  GetActualScreenResolution = function() return 2560, 1440 end
  GetSafeZoneSize = function() return 0.95 end
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
