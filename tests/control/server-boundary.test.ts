import assert from 'node:assert/strict';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';
import { bootstrapControlLua, source } from './helpers.js';

test('Control opens only for an ACE-authorized player and replies only to that source', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrapControlLua(engine);
    const server = await source('resources/synex_control/server/server.lua');
    const result = await engine.doString(`
      local commands, network, events = {}, {}, {}
      local grants = {
        ['synex.control.view'] = true,
        ['synex.control.audit'] = false,
        ['synex.control.security'] = false,
        ['synex.control.financial'] = false,
        ['synex.control.identifiers'] = false,
      }
      local now = 1000
      local calls = { list = 0, summary = 0, listOperation = 0 }
      RegisterCommand = function(name, handler) commands[name] = handler end
      RegisterNetEvent = function(name, handler) network[name] = handler end
      AddEventHandler = function() end
      GetResourceState = function() return 'started' end
      GetPlayerName = function(player) return player == '41' and 'operator' or nil end
      IsPlayerAceAllowed = function(_, ace) return grants[ace] == true end
      GetGameTimer = function() return now end
      TriggerClientEvent = function(name, target, payload)
        events[#events + 1] = { name = name, target = target, payload = payload }
      end
      exports = { synex_core = { GetAPI = function()
        return { ControlProviders = {
          register = function(definition)
            assert(definition.namespace == 'control')
            return { namespace = 'control' }
          end,
          list = function()
            calls.list = calls.list + 1
            return { schemaVersion = 1, providers = {
              {
                namespace = 'core', label = 'Synex Core', category = 'platform',
                version = '1.0.0', resource = 'synex_core', health = 'HEALTHY',
                circuit = 'CLOSED', operations = { 'summary', 'list', 'inspect', 'search' },
                views = {
                  { id = 'overview', label = 'Overview', operation = 'summary', presentation = 'key-value', accessClass = 'general' },
                  { id = 'resources', label = 'Resources', operation = 'list', presentation = 'table', accessClass = 'general' },
                  { id = 'security', label = 'Security', operation = 'list', presentation = 'findings', accessClass = 'security' },
                },
              },
              {
                namespace = 'accounts', label = 'Accounts', category = 'foundation',
                version = '1.0.0', resource = 'synex_accounts', health = 'HEALTHY',
                circuit = 'CLOSED', operations = { 'summary', 'list', 'inspect', 'search' },
                views = {
                  { id = 'overview', label = 'Overview', operation = 'summary', presentation = 'key-value', accessClass = 'financial' },
                  { id = 'public_status', label = 'Public status', operation = 'summary', presentation = 'key-value', accessClass = 'general' },
                  { id = 'currencies', label = 'Currencies', operation = 'list', presentation = 'table', accessClass = 'general' },
                  { id = 'accounts', label = 'Accounts', operation = 'list', presentation = 'table', accessClass = 'financial' },
                },
              },
            }, truncated = false }
          end,
          invoke = function(namespace, operation, request, options)
            assert(options.timeoutMs >= 25 and options.timeoutMs <= 2000)
            if operation == 'summary' then calls.summary = calls.summary + 1 end
            if operation == 'list' then calls.listOperation = calls.listOperation + 1 end
            return {
              schemaVersion = 1, namespace = namespace, operation = operation,
              resource = namespace == 'core' and 'synex_core' or 'synex_accounts',
              generatedAt = '2026-08-26T00:00:00Z', durationMs = 1,
              data = operation == 'summary'
                and { status = 'HEALTHY', counts = { resources = 4 } }
                or { items = {}, hasMore = false },
            }
          end,
        } }
      end } }

      assert(load(${JSON.stringify(server)}, '@resources/synex_control/server/server.lua'))()

      commands['synex-control'](41)
      assert(#events == 1)
      assert(events[1].name == 'synex_control:open' and events[1].target == 41)

      source = 41
      network['synex_control:request']({
        requestId = 'request-overview-01', operation = 'overview'
      })
      assert(#events == 2)
      assert(events[2].name == 'synex_control:response' and events[2].target == 41)
      assert(events[2].payload.ok == true)
      assert(events[2].payload.requestId == 'request-overview-01')
      assert(calls.list >= 1)
      assert(calls.summary == 1)
      assert(calls.listOperation == 0)
      assert(events[2].payload.data.summaries.accounts.restricted == true)

      grants['synex.control.view'] = false
      commands['synex-control'](41)
      assert(#events == 2)
      return calls.summary
    `);
    assert.equal(result, 1);
  } finally {
    engine.global.close();
  }
});

test('Control rechecks granular ACEs and closes on base permission revocation', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrapControlLua(engine);
    const server = await source('resources/synex_control/server/server.lua');
    const result = await engine.doString(`
      local network, events = {}, {}
      local grants = {
        ['synex.control.view'] = true,
        ['synex.control.financial'] = false,
        ['synex.control.audit'] = false,
        ['synex.control.security'] = false,
        ['synex.control.identifiers'] = false,
      }
      RegisterCommand = function() end
      RegisterNetEvent = function(name, handler) network[name] = handler end
      AddEventHandler = function() end
      GetResourceState = function() return 'started' end
      GetPlayerName = function() return 'operator' end
      IsPlayerAceAllowed = function(_, ace) return grants[ace] == true end
      GetGameTimer = function() return 1000 end
      TriggerClientEvent = function(name, target, payload)
        events[#events + 1] = { name = name, target = target, payload = payload }
      end
      exports = { synex_core = { GetAPI = function()
        return { ControlProviders = {
          register = function() return { namespace = 'control' } end,
          list = function() return { providers = {
            { namespace = 'accounts', label = 'Accounts', category = 'foundation',
              version = '1.0.0', resource = 'synex_accounts', health = 'HEALTHY',
              circuit = 'CLOSED', operations = { 'list' }, views = {
                { id = 'accounts', label = 'Accounts', operation = 'list', presentation = 'table', accessClass = 'financial' }
              } }
          } } end,
          invoke = function() error('financial provider must not be invoked without ACE') end,
        } }
      end } }
      assert(load(${JSON.stringify(server)}, '@resources/synex_control/server/server.lua'))()
      source = 42

      network['synex_control:request']({
        requestId = 'request-financial-1', operation = 'section',
        provider = 'accounts', view = 'accounts', limit = 25,
      })
      assert(events[1].name == 'synex_control:response')
      assert(events[1].payload.ok == false)
      assert(events[1].payload.error.code == 'ACCESS_REVOKED')

      grants['synex.control.view'] = false
      network['synex_control:request']({
        requestId = 'request-revoked-001', operation = 'overview'
      })
      assert(events[2].payload.error.code == 'ACCESS_REVOKED')
      assert(events[3].name == 'synex_control:access_revoked')
      assert(events[3].target == 42)
      return #events
    `);
    assert.equal(result, 3);
  } finally {
    engine.global.close();
  }
});

test('Control rechecks every effective ACE after provider execution and closes revoked viewers', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrapControlLua(engine);
    const server = await source('resources/synex_control/server/server.lua');
    const result = await engine.doString(`
      local network, events, handlers, invocations = {}, {}, {}, 0
      local grants = {
        ['synex.control.view'] = true,
        ['synex.control.audit'] = false,
        ['synex.control.security'] = false,
        ['synex.control.financial'] = true,
        ['synex.control.identifiers'] = true,
      }
      RegisterCommand = function() end
      RegisterNetEvent = function(name, handler) network[name] = handler end
      AddEventHandler = function(name, handler) handlers[name] = handler end
      GetResourceState = function() return 'started' end
      GetPlayerName = function() return 'operator' end
      IsPlayerAceAllowed = function(_, ace) return grants[ace] == true end
      GetGameTimer = function() return 1000 end
      TriggerClientEvent = function(name, target, payload)
        events[#events + 1] = { name = name, target = target, payload = payload }
      end
      exports = { synex_core = { GetAPI = function()
        return { ControlProviders = {
          register = function() return { namespace = 'control' } end,
          list = function() return { providers = {{
            namespace = 'fixture', label = 'Fixture', category = 'domain',
            version = '1.0.0', resource = 'synex_fixture', health = 'HEALTHY',
            circuit = 'CLOSED', operations = { 'inspect', 'list' }, views = {
              { id = 'entity', label = 'Entity', operation = 'inspect',
                presentation = 'detail', accessClass = 'general' },
              { id = 'accounts', label = 'Accounts', operation = 'list',
                presentation = 'table', accessClass = 'financial' },
            },
          }} } end,
          invoke = function(namespace, operation, request)
            invocations = invocations + 1
            if operation == 'inspect' then grants['synex.control.identifiers'] = false end
            if operation == 'list' then grants['synex.control.financial'] = false end
            return {
              schemaVersion = 1, namespace = namespace, operation = operation,
              resource = 'synex_fixture', generatedAt = '2026-08-26T00:00:00Z',
              durationMs = 1, data = operation == 'list'
                and { items = {{ accountId = 'account-private' }}, hasMore = false }
                or { entityId = request.id },
            }
          end,
        } }
      end } }
      assert(load(${JSON.stringify(server)}, '@resources/synex_control/server/server.lua'))()
      source = 42

      network['synex_control:request']({
        requestId = 'request-identifier-race', operation = 'inspect',
        provider = 'fixture', view = 'entity', id = 'entity-private',
      })
      assert(events[1].name == 'synex_control:response'
        and events[1].payload.ok == false
        and events[1].payload.error.code == 'ACCESS_REVOKED'
        and events[1].payload.data == nil)
      assert(events[2].name == 'synex_control:access_revoked')

      grants['synex.control.identifiers'] = true
      grants['synex.control.financial'] = true
      network['synex_control:request']({
        requestId = 'request-financial-race', operation = 'section',
        provider = 'fixture', view = 'accounts', limit = 25,
      })
      assert(events[3].name == 'synex_control:response'
        and events[3].payload.ok == false
        and events[3].payload.error.code == 'ACCESS_REVOKED'
        and events[3].payload.data == nil)
      assert(events[4].name == 'synex_control:access_revoked')

      -- Revoked clients close locally on ACCESS_REVOKED. The server must also
      -- remove them from its viewer set so they receive no invalidation hints.
      local beforeInvalidation = #events
      handlers.onResourceStart('synex_fixture')
      assert(#events == beforeInvalidation)
      return table.concat({ invocations, events[1].payload.error.code,
        events[3].payload.error.code }, ':')
    `);
    assert.equal(result, '2:ACCESS_REVOKED:ACCESS_REVOKED');
  } finally {
    engine.global.close();
  }
});

test('Control rejects forged routes before provider invocation and masks provider identifiers', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrapControlLua(engine);
    const server = await source('resources/synex_control/server/server.lua');
    const result = await engine.doString(`
      local network, events, invocations = {}, {}, 0
      RegisterCommand = function() end
      RegisterNetEvent = function(name, handler) network[name] = handler end
      AddEventHandler = function() end
      GetResourceState = function() return 'started' end
      GetPlayerName = function() return 'operator' end
      IsPlayerAceAllowed = function(_, ace) return ace == 'synex.control.view' end
      GetGameTimer = function() return 1000 end
      TriggerClientEvent = function(name, target, payload)
        events[#events + 1] = { name = name, target = target, payload = payload }
      end
      exports = { synex_core = { GetAPI = function()
        return { ControlProviders = {
          register = function() return { namespace = 'control' } end,
          list = function() return { providers = {
            { namespace = 'entities', label = 'Entities', category = 'foundation',
              version = '1.0.0', resource = 'synex_entities', health = 'HEALTHY',
              circuit = 'CLOSED', operations = { 'inspect' }, views = {
                { id = 'entities', label = 'Entities', operation = 'inspect', presentation = 'detail', accessClass = 'general' }
              } }
          } } end,
          invoke = function(namespace, operation, request)
            invocations = invocations + 1
            return { namespace = namespace, operation = operation, resource = 'synex_entities',
              schemaVersion = 1, generatedAt = '2026-08-26T00:00:00Z', durationMs = 1,
              data = { entityId = request.id, api_key = 'must-never-leak' } }
          end,
        } }
      end } }
      assert(load(${JSON.stringify(server)}, '@resources/synex_control/server/server.lua'))()
      source = 7
      network['synex_control:request']({
        requestId = 'request-forged-001', operation = 'delete', provider = 'entities',
        view = 'entities', id = 'entity_private_0001'
      })
      assert(invocations == 0)
      assert(events[1].payload.error.code == 'INVALID_ARGUMENT')

      network['synex_control:request']({
        requestId = 'request-inspect-01', operation = 'inspect', provider = 'entities',
        view = 'entities', id = 'entity_private_0001'
      })
      assert(invocations == 1)
      assert(events[2].payload.data.entityId == 'enti...0001')
      assert(events[2].payload.data.api_key == '[REDACTED]')
      local encoded = json.encode(events[2].payload)
      assert(encoded:find('must%-never%-leak') == nil)
      return events[2].payload.data.entityId
    `);
    assert.equal(result, 'enti...0001');
  } finally {
    engine.global.close();
  }
});

test('Control trusts navigation IDs only for its own provider catalog envelope', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrapControlLua(engine);
    const server = await source('resources/synex_control/server/server.lua');
    const result = await engine.doString(`
      local network, events = {}, {}
      RegisterCommand = function() end
      RegisterNetEvent = function(name, handler) network[name] = handler end
      AddEventHandler = function() end
      GetResourceState = function() return 'started' end
      GetPlayerName = function() return 'operator' end
      IsPlayerAceAllowed = function(_, ace) return ace == 'synex.control.view' end
      GetGameTimer = function() return 1000 end
      TriggerClientEvent = function(name, target, payload)
        events[#events + 1] = { name = name, target = target, payload = payload }
      end
      exports = { synex_core = { GetAPI = function()
        return { ControlProviders = {
          register = function() return { namespace = 'fixture' } end,
          list = function() return { providers = {{
            namespace = 'fixture', label = 'Fixture', category = 'domain',
            version = '1.0.0', resource = 'synex_fixture', health = 'HEALTHY',
            circuit = 'CLOSED', operations = { 'list' }, views = {{
              id = 'records', label = 'Records', operation = 'list',
              presentation = 'table', accessClass = 'general',
              search = { kinds = {{
                id = 'record_key', modes = { 'exact' }, accessClass = 'general',
              }} },
            }},
          }} } end,
          invoke = function(namespace, operation)
            assert(namespace == 'fixture' and operation == 'list')
            return {
              namespace = namespace, operation = operation, resource = 'synex_fixture',
              data = {
                providers = {{ views = {{
                  id = 'provider_secret_view',
                  search = { kinds = {{ id = 'secret_kind_identifier' }} },
                }} }},
                id = 'provider_secret_root', hasMore = false,
              },
            }
          end,
        } }
      end } }
      assert(load(${JSON.stringify(server)}, '@resources/synex_control/server/server.lua'))()
      source = 42

      network['synex_control:request']({
        requestId = 'request-catalog-trust', operation = 'providers', limit = 25,
      })
      local catalog = events[1].payload
      assert(catalog.ok == true)
      assert(catalog.data.providers[1].views[1].id == 'records')
      assert(catalog.data.providers[1].views[1].search.kinds[1].id == 'record_key')

      network['synex_control:request']({
        requestId = 'request-page-untrusted', operation = 'page',
        provider = 'fixture', view = 'records', limit = 25,
      })
      local page = events[2].payload
      assert(page.ok == true)
      assert(page.data.id == 'prov...root')
      assert(page.data.providers[1].views[1].id == 'prov...view')
      assert(page.data.providers[1].views[1].search.kinds[1].id == 'secr...fier')
      return table.concat({ catalog.data.providers[1].views[1].id,
        page.data.providers[1].views[1].id }, ':')
    `);
    assert.equal(result, 'records:prov...view');
  } finally {
    engine.global.close();
  }
});

test('Control routes only declared read-only simulations through the provider contract', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrapControlLua(engine);
    const server = await source('resources/synex_control/server/server.lua');
    const result = await engine.doString(`
      local network, events, invocations = {}, {}, 0
      RegisterCommand = function() end
      RegisterNetEvent = function(name, handler) network[name] = handler end
      AddEventHandler = function() end
      GetResourceState = function() return 'started' end
      GetPlayerName = function() return 'operator' end
      IsPlayerAceAllowed = function(_, ace) return ace == 'synex.control.view' end
      GetGameTimer = function() return 1000 end
      TriggerClientEvent = function(name, target, payload)
        events[#events + 1] = { name = name, target = target, payload = payload }
      end
      exports = { synex_core = { GetAPI = function()
        return { ControlProviders = {
          register = function() return { namespace = 'control' } end,
          list = function() return { providers = {{
            namespace = 'groups', label = 'Groups', category = 'domain',
            version = '1.0.0', resource = 'synex_groups', health = 'HEALTHY',
            circuit = 'CLOSED', operations = { 'simulate' }, views = {{
              id = 'policy_simulation', label = 'Policy simulation', operation = 'simulate',
              presentation = 'detail', accessClass = 'general',
            }},
          }} } end,
          invoke = function(namespace, operation, request)
            invocations = invocations + 1
            assert(namespace == 'groups' and operation == 'simulate')
            assert(request.view == 'policy_simulation')
            assert(request.filters.group_id == 'group_01')
            assert(request.filters.action == 'members.promote')
            return { namespace = namespace, operation = operation, resource = 'synex_groups',
              data = { decision = 'ALLOWED', readOnly = true, persisted = false } }
          end,
        } }
      end } }
      assert(load(${JSON.stringify(server)}, '@resources/synex_control/server/server.lua'))()
      source = 42
      network['synex_control:request']({
        requestId = 'request-simulate-01', operation = 'simulate', provider = 'groups',
        view = 'policy_simulation', filters = {
          actor_character_id = 'character_01', group_id = 'group_01',
          action = 'members.promote',
        },
      })
      assert(#events == 1 and events[1].name == 'synex_control:response')
      assert(events[1].payload.ok == true)
      assert(events[1].payload.data.decision == 'ALLOWED')
      assert(events[1].payload.data.persisted == false)
      return invocations
    `);
    assert.equal(result, 1);
  } finally {
    engine.global.close();
  }
});

test('Control bounds request rate, never fans out, tracks close, and revokes an open viewer', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrapControlLua(engine);
    const server = await source('resources/synex_control/server/server.lua');
    const result = await engine.doString(`
      local commands, network, handlers, events = {}, {}, {}, {}
      local viewGranted = true
      local thread
      local waitBudget = 0
      RegisterCommand = function(name, handler) commands[name] = handler end
      RegisterNetEvent = function(name, handler) network[name] = handler end
      AddEventHandler = function(name, handler) handlers[name] = handler end
      CreateThread = function(handler) thread = handler end
      Wait = function()
        if waitBudget <= 0 then error('STOP_THREAD') end
        waitBudget = waitBudget - 1
      end
      GetResourceState = function() return 'started' end
      GetPlayerName = function(player) return player == '42' and 'operator' or nil end
      IsPlayerAceAllowed = function(_, ace)
        if ace == 'synex.control.view' then return viewGranted end
        return false
      end
      GetGameTimer = function() return 1000 end
      TriggerClientEvent = function(name, target, payload)
        assert(target == 42, 'Control must never broadcast diagnostics')
        events[#events + 1] = { name = name, target = target, payload = payload }
      end
      exports = { synex_core = { GetAPI = function()
        return { ControlProviders = {
          register = function() return { namespace = 'control' }, nil end,
          list = function() return { schemaVersion = 1, providers = {
            { namespace = 'core', label = 'Core', category = 'platform',
              version = '1.0.0', resource = 'synex_core', health = 'HEALTHY',
              operations = { 'summary' }, views = {{
                id = 'overview', label = 'Overview', operation = 'summary',
                presentation = 'key-value', accessClass = 'general',
              }} }
          }, truncated = false }, nil end,
          invoke = function(namespace, operation)
            assert(namespace == 'core' and operation == 'summary')
            return { data = { status = 'HEALTHY' } }, nil
          end,
        } }
      end } }
      assert(load(${JSON.stringify(server)}, '@resources/synex_control/server/server.lua'))()
      source = 42

      commands['synex-control'](42)
      assert(events[1].name == 'synex_control:open')
      network['synex_control:closed']()
      local beforeClosedScan = #events
      viewGranted = false
      waitBudget = 1
      pcall(thread)
      assert(#events == beforeClosedScan)

      viewGranted = true
      commands['synex-control'](42)
      viewGranted = false
      waitBudget = 1
      pcall(thread)
      assert(events[#events].name == 'synex_control:access_revoked')
      assert(events[#events].payload.code == 'ACCESS_REVOKED')

      viewGranted = true
      local firstRequestEvent = #events + 1
      for index = 1, SynexControlLimits.serverBurst + 2 do
        network['synex_control:request']({
          requestId = ('request-rate-%02d'):format(index), operation = 'overview',
        })
      end
      local rateLimited = 0
      for index = firstRequestEvent, #events do
        local payload = events[index].payload
        if events[index].name == 'synex_control:response' and payload.ok == false
          and payload.error.code == 'RATE_LIMITED' then rateLimited = rateLimited + 1 end
      end
      assert(rateLimited == 2)

      local beforeInvalidTelemetry = #events
      network['synex_control:nui_error']({
        code = 'RENDER_FAILED', view = 'core.overview', stack = 'private-browser-stack',
      })
      assert(#events == beforeInvalidTelemetry)

      handlers.playerDropped()
      return rateLimited
    `);
    assert.equal(result, 2);
  } finally {
    engine.global.close();
  }
});

test('Control invalidates only open viewers and refreshes provider health across restarts', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrapControlLua(engine);
    const server = await source('resources/synex_control/server/server.lua');
    const result = await engine.doString(`
      local commands, network, handlers, events = {}, {}, {}, {}
      local entityHealth = 'HEALTHY'
      RegisterCommand = function(name, handler) commands[name] = handler end
      RegisterNetEvent = function(name, handler) network[name] = handler end
      AddEventHandler = function(name, handler) handlers[name] = handler end
      GetResourceState = function() return 'started' end
      GetPlayerName = function(player) return player == '42' and 'operator' or nil end
      IsPlayerAceAllowed = function(_, ace) return ace == 'synex.control.view' end
      GetGameTimer = function() return 1000 end
      TriggerClientEvent = function(name, target, payload)
        assert(target == 42)
        events[#events + 1] = { name = name, target = target, payload = payload }
      end
      exports = { synex_core = { GetAPI = function()
        return { ControlProviders = {
          register = function() return { namespace = 'control' }, nil end,
          list = function() return { schemaVersion = 1, providers = {{
            namespace = 'entities', label = 'Entities', category = 'domain',
            version = '1.0.0', resource = 'synex_entities', health = entityHealth,
            circuit = { state = entityHealth == 'UNAVAILABLE' and 'OPEN' or 'CLOSED' },
            operations = { 'summary' }, views = {{
              id = 'overview', label = 'Overview', operation = 'summary',
              presentation = 'key-value', accessClass = 'general',
            }},
          }}, truncated = false }, nil end,
          invoke = function() return { data = { status = entityHealth } }, nil end,
        } }
      end } }
      assert(load(${JSON.stringify(server)}, '@resources/synex_control/server/server.lua'))()
      source = 42
      commands['synex-control'](42)
      network['synex_control:request']({
        requestId = 'request-catalog-before', operation = 'providers',
      })
      assert(events[2].payload.ok == true)
      assert(events[2].payload.data.providers[1].health == 'HEALTHY')

      entityHealth = 'UNAVAILABLE'
      handlers.onResourceStop('synex_entities')
      assert(events[3].name == 'synex_control:invalidate')
      assert(events[3].payload.resource == 'synex_entities')
      assert(events[3].payload.state == 'stopped')
      network['synex_control:request']({
        requestId = 'request-catalog-stopped', operation = 'providers',
      })
      assert(events[4].payload.data.providers[1].health == 'UNAVAILABLE')

      entityHealth = 'HEALTHY'
      handlers.onResourceStart('synex_entities')
      assert(events[5].name == 'synex_control:invalidate')
      assert(events[5].payload.state == 'started')
      network['synex_control:request']({
        requestId = 'request-catalog-started', operation = 'providers',
      })
      assert(events[6].payload.data.providers[1].health == 'HEALTHY')

      network['synex_control:closed']()
      local closedCount = #events
      handlers.onResourceStop('synex_entities')
      assert(#events == closedCount)
      return table.concat({ events[3].payload.state, events[5].payload.state,
        events[6].payload.data.providers[1].health }, ':')
    `);
    assert.equal(result, 'stopped:started:HEALTHY');
  } finally {
    engine.global.close();
  }
});
