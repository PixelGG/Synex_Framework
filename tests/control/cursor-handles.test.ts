import assert from 'node:assert/strict';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';
import { bootstrapControlLua, source } from './helpers.js';

test('Control replaces provider cursors with player-scoped expiring opaque handles', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrapControlLua(engine);
    const server = await source('resources/synex_control/server/server.lua');
    const result = await engine.doString(`
      local network, handlers, events, providerCursors = {}, {}, {}, {}
      local now, invocations = 1000, 0
      RegisterCommand = function() end
      RegisterNetEvent = function(name, handler) network[name] = handler end
      AddEventHandler = function(name, handler) handlers[name] = handler end
      GetResourceState = function() return 'started' end
      GetPlayerName = function() return 'operator' end
      IsPlayerAceAllowed = function(_, ace) return ace == 'synex.control.view' end
      GetGameTimer = function() return now end
      TriggerClientEvent = function(name, target, payload)
        events[#events + 1] = { name = name, target = target, payload = payload }
      end
      exports = { synex_core = { GetAPI = function()
        return { ControlProviders = {
          register = function() return { namespace = 'control' } end,
          list = function() return { providers = {{
            namespace = 'entities', label = 'Entities', category = 'domain', version = '1.0.0',
            resource = 'synex_entities', health = 'HEALTHY', circuit = 'CLOSED',
            operations = { 'list' }, views = {
              { id = 'entities', label = 'Entities', operation = 'list', presentation = 'table', accessClass = 'general' },
              { id = 'other', label = 'Other', operation = 'list', presentation = 'table', accessClass = 'general' },
            },
          }} } end,
          invoke = function(namespace, operation, request)
            invocations = invocations + 1
            providerCursors[#providerCursors + 1] = request.cursor or 'initial'
            return {
              namespace = namespace, operation = operation, resource = 'synex_entities',
              data = { items = {}, hasMore = true, nextCursor = 'entity-private-' .. tostring(invocations) },
            }
          end,
        } }
      end } }
      assert(load(${JSON.stringify(server)}, '@resources/synex_control/server/server.lua'))()

      local function page(requestId, cursor, view, limit)
        network['synex_control:request']({
          requestId = requestId, operation = 'page', provider = 'entities',
          view = view or 'entities', cursor = cursor, limit = limit or 25,
        })
      end

      source = 41
      page('request-cursor-001')
      local first = events[#events].payload.data.nextCursor
      assert(type(first) == 'string' and first:match('^cursor%-') ~= nil)
      assert(json.encode(events[#events].payload):find('entity%-private', 1, false) == nil)

      page('request-cursor-002', first)
      assert(providerCursors[2] == 'entity-private-1')
      local second = events[#events].payload.data.nextCursor

      page('request-cursor-003', first, 'entities', 24)
      assert(events[#events].payload.ok == false and invocations == 2)

      source = 42
      page('request-cursor-004', first)
      assert(events[#events].target == 42, tostring(events[#events].target))
      assert(events[#events].payload.ok == false, providerCursors[#providerCursors])
      assert(invocations == 2)

      source = 41
      now = now + 121000
      page('request-cursor-005', second)
      assert(events[#events].payload.ok == false and invocations == 2)
      return table.concat(providerCursors, ':')
    `);
    assert.equal(result, 'initial:entity-private-1');
  } finally {
    engine.global.close();
  }
});

test('Control clears opaque cursor state on player drop and resource stop', async () => {
  const server = await source('resources/synex_control/server/server.lua');
  assert.match(server, /AddEventHandler\('playerDropped',[\s\S]*?clearCursorHandles\(playerSource\)/u);
  assert.match(server, /AddEventHandler\('onResourceStop',[\s\S]*?cursorHandles = \{\}/u);
});

test('Control keeps cached catalog cursors raw and seals independent handles per player', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrapControlLua(engine);
    const server = await source('resources/synex_control/server/server.lua');
    const result = await engine.doString(`
      local network, events, listCursors = {}, {}, {}
      RegisterCommand = function() end
      RegisterNetEvent = function(name, handler) network[name] = handler end
      AddEventHandler = function() end
      GetResourceState = function() return 'started' end
      GetPlayerName = function(player) return player == '41' and 'one' or 'two' end
      IsPlayerAceAllowed = function(_, ace) return ace == 'synex.control.view' end
      GetGameTimer = function() return 1000 end
      TriggerClientEvent = function(name, target, payload)
        events[#events + 1] = { name = name, target = target, payload = payload }
      end
      local function provider(namespace)
        return {
          namespace = namespace, label = namespace, category = 'domain', version = '1.0.0',
          resource = 'synex_' .. namespace, health = 'HEALTHY', circuit = 'CLOSED',
          operations = { 'summary' }, views = {{
            id = 'overview', label = 'Overview', operation = 'summary',
            presentation = 'key-value', accessClass = 'general',
          }},
        }
      end
      exports = { synex_core = { GetAPI = function()
        return { ControlProviders = {
          register = function() return { namespace = 'control' } end,
          list = function(options)
            local cursor = options and options.cursor or nil
            listCursors[#listCursors + 1] = cursor or 'initial'
            if cursor == nil then
              return { providers = { provider('alpha') }, hasMore = true,
                nextCursor = 'github_pat_ABCDEFGHIJKLMNOPQRSTUVWXYZ123456', total = 2 }
            end
            assert(cursor == 'github_pat_ABCDEFGHIJKLMNOPQRSTUVWXYZ123456',
              'nested, redacted, or foreign cursor reached Core')
            return { providers = { provider('beta') }, hasMore = false, total = 2 }
          end,
          invoke = function() return nil, { code = 'VIEW_UNAVAILABLE' } end,
        } }
      end } }
      assert(load(${JSON.stringify(server)}, '@resources/synex_control/server/server.lua'))()

      local function catalog(player, requestId, cursor)
        source = player
        network['synex_control:request']({
          requestId = requestId, operation = 'providers', limit = 1, cursor = cursor,
        })
        local response = events[#events].payload
        assert(response.ok == true)
        return response.data.nextCursor
      end

      local first = catalog(41, 'catalog-one-first')
      local second = catalog(42, 'catalog-two-first')
      assert(first ~= second)
      assert(#listCursors == 1 and listCursors[1] == 'initial')

      assert(catalog(41, 'catalog-one-next', first) == nil)
      assert(catalog(42, 'catalog-two-next', second) == nil)
      assert(#listCursors == 2
        and listCursors[2] == 'github_pat_ABCDEFGHIJKLMNOPQRSTUVWXYZ123456')
      return table.concat(listCursors, ':')
    `);
    assert.equal(result, 'initial:github_pat_ABCDEFGHIJKLMNOPQRSTUVWXYZ123456');
  } finally {
    engine.global.close();
  }
});
