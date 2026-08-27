import assert from 'node:assert/strict';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';
import { bootstrapControlLua, source } from './helpers.js';

test('Control client waits for NUI ready before focus and trusts only server-origin lifecycle events', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrapControlLua(engine);
    const client = await source('resources/synex_control/client/client.lua');
    const result = await engine.doString(`
      local network, nui, handlers = {}, {}, {}
      local messages, focus, emitted = {}, {}, {}
      local now = 10000
      RegisterNetEvent = function(name, handler) network[name] = handler end
      RegisterNuiCallback = function(name, handler) nui[name] = handler end
      AddEventHandler = function(name, handler) handlers[name] = handler end
      SetNuiFocusKeepInput = function(value)
        focus[#focus + 1] = 'keep:' .. tostring(value)
      end
      SetNuiFocus = function(keyboard, mouse)
        focus[#focus + 1] = ('focus:%s:%s'):format(tostring(keyboard), tostring(mouse))
      end
      SendNUIMessage = function(message) messages[#messages + 1] = message end
      GetGameTimer = function() return now end
      GetCurrentResourceName = function() return 'synex_control' end
      TriggerServerEvent = function(name, payload)
        emitted[#emitted + 1] = { name = name, payload = payload }
      end

      assert(load(${JSON.stringify(client)}, '@resources/synex_control/client/client.lua'))()
      assert(#focus == 0 and #messages == 0)

      source = 42
      network['synex_control:open']()
      assert(#focus == 0 and #messages == 0)

      source = 65535
      network['synex_control:open']()
      assert(#focus == 0 and #messages == 0)

      local readyReply
      nui.ready({ version = 1 }, function(value) readyReply = value end)
      assert(readyReply.ok == true and readyReply.data.version == 1)
      assert(messages[1].type == 'control:visibility')
      assert(messages[1].payload.open == true)
      assert(focus[1] == 'keep:false' and focus[2] == 'focus:true:true')

      local requestReply
      nui.request({ requestId = 'request-overview-01', operation = 'overview' },
        function(value) requestReply = value end)
      assert(requestReply.ok == true)
      assert(emitted[1].name == 'synex_control:request')
      assert(emitted[1].payload.requestId == 'request-overview-01')

      nui.request({ requestId = 'request-providers-01', operation = 'providers',
        cursor = 'opaque-provider-page', limit = 12 }, function(value) requestReply = value end)
      assert(requestReply.ok == true and emitted[2].name == 'synex_control:request')
      assert(emitted[2].payload.cursor == 'opaque-provider-page'
        and emitted[2].payload.limit == 12)

      nui.request({ requestId = 'request-simulate-01', operation = 'simulate',
        provider = 'groups', view = 'policy_simulation', filters = {
          actor_character_id = 'character_01', group_id = 'group_01',
          action = 'members.promote',
        } }, function(value) requestReply = value end)
      assert(requestReply.ok == true and emitted[3].name == 'synex_control:request')
      assert(emitted[3].payload.operation == 'simulate')

      source = 42
      network['synex_control:response']({
        schemaVersion = 1, requestId = 'request-overview-01', ok = true, data = {}
      })
      assert(#messages == 1)

      source = 65535
      network['synex_control:response']({ requestId = 'short', ok = true, data = {} })
      network['synex_control:response']({
        requestId = 'request-oversized-01', ok = true,
        data = { value = string.rep('x', SynexControlLimits.maximumResponseBytes) }
      })
      assert(#messages == 1)

      network['synex_control:response']({
        schemaVersion = 1, requestId = 'request-overview-01', ok = true,
        data = { providers = {} }
      })
      assert(#messages == 2 and messages[2].type == 'control:response')

      local beforeInvalidation = #messages
      source = 42
      network['synex_control:invalidate']({
        reason = 'RESOURCE_STATE_CHANGED', resource = 'synex_entities', state = 'stopped',
      })
      assert(#messages == beforeInvalidation)
      source = 65535
      network['synex_control:invalidate']({
        reason = 'RESOURCE_STATE_CHANGED', resource = 'synex_entities', state = 'stopped',
      })
      assert(#messages == beforeInvalidation + 1)
      assert(messages[#messages].type == 'control:invalidate')
      assert(messages[#messages].payload.resource == 'synex_entities')
      assert(messages[#messages].payload.state == 'stopped')

      local closeReply
      nui.close({}, function(value) closeReply = value end)
      assert(closeReply.ok == true)
      assert(emitted[4].name == 'synex_control:closed')
      assert(messages[#messages].type == 'control:visibility')
      assert(messages[#messages].payload.open == false)
      local messageCount = #messages
      network['synex_control:response']({
        requestId = 'request-overview-01', ok = true, data = {}
      })
      assert(#messages == messageCount)

      network['synex_control:open']()
      network['synex_control:access_revoked']({ code = 'ACCESS_REVOKED' })
      assert(messages[#messages - 1].type == 'control:access-revoked')
      assert(messages[#messages].type == 'control:visibility')
      assert(messages[#messages].payload.open == false)

      network['synex_control:open']()
      nui.request({ requestId = 'request-overview-02', operation = 'overview' },
        function(value) requestReply = value end)
      assert(requestReply.ok == true and #emitted == 5)

      handlers.onClientResourceStop('synex_control')
      assert(focus[#focus - 1] == 'keep:false')
      assert(focus[#focus] == 'focus:false:false')
      return table.concat({#messages, #focus, #emitted}, ':')
    `);
    assert.match(String(result), /^\d+:\d+:5$/u);
  } finally {
    engine.global.close();
  }
});

test('Control client exposes only the four read-only transport callbacks and bounded error telemetry', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrapControlLua(engine);
    const client = await source('resources/synex_control/client/client.lua');
    const result = await engine.doString(`
      local network, nui, handlers, emitted = {}, {}, {}, {}
      local now = 20000
      RegisterNetEvent = function(name, handler) network[name] = handler end
      RegisterNuiCallback = function(name, handler) nui[name] = handler end
      AddEventHandler = function(name, handler) handlers[name] = handler end
      SetNuiFocusKeepInput = function() end
      SetNuiFocus = function() end
      SendNUIMessage = function() end
      GetGameTimer = function() return now end
      GetCurrentResourceName = function() return 'synex_control' end
      TriggerServerEvent = function(name, payload)
        emitted[#emitted + 1] = { name = name, payload = payload }
      end
      assert(load(${JSON.stringify(client)}, '@resources/synex_control/client/client.lua'))()

      local names = {}
      for name in pairs(nui) do names[#names + 1] = name end
      table.sort(names)
      assert(table.concat(names, ',') == 'close,ready,reportError,request')

      local reply
      nui.reportError({ code = 'RENDER_FAILED', view = 'entities.health' },
        function(value) reply = value end)
      assert(reply.ok == true)
      assert(emitted[1].name == 'synex_control:nui_error')
      assert(emitted[1].payload.code == 'RENDER_FAILED')
      assert(emitted[1].payload.view == 'entities.health')
      assert(emitted[1].payload.message == nil and emitted[1].payload.stack == nil)

      now = 26000
      nui.reportError({ code = 'bad code', stack = 'private' },
        function(value) reply = value end)
      assert(reply.ok == false and reply.error.code == 'INVALID_REQUEST')
      assert(#emitted == 1)
      return table.concat(names, ',')
    `);
    assert.equal(result, 'close,ready,reportError,request');
  } finally {
    engine.global.close();
  }
});
