import assert from 'node:assert/strict';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';
import { bootstrapControlLua } from './helpers.js';

test('Control protocol accepts only closed bounded overview and page requests', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrapControlLua(engine);
    const result = await engine.doString(`
      local overview = assert(SynexControlProtocol.validate({
        requestId = 'request-overview-01', operation = 'overview'
      }))
      assert(overview.limit == SynexControlLimits.defaultPageSize)

      local page = assert(SynexControlProtocol.validate({
        requestId = 'request-page-0001', operation = 'page', provider = 'entities',
        view = 'entities', cursor = 'entity_0001', limit = 50,
        filters = { status = 'active', persistent = true },
        sort = { field = 'entity_id', direction = 'asc' },
      }))
      assert(page.provider == 'entities' and page.limit == 50)
      assert(page.filters.status == 'active')

      local contract = assert(SynexControlProtocol.validate({
        requestId = 'request-contract-01', operation = 'inspect', provider = 'core',
        view = 'contract', id = 'synex.runtime.status@1.0.0',
      }))
      assert(contract.id == 'synex.runtime.status@1.0.0')
      local capability = assert(SynexControlProtocol.validate({
        requestId = 'request-capability-01', operation = 'inspect', provider = 'core',
        view = 'capability', id = 'synex.runtime.*',
      }))
      assert(capability.id == 'synex.runtime.*')
      local tracePage = assert(SynexControlProtocol.validate({
        requestId = 'request-trace-page-01', operation = 'page', provider = 'core',
        view = 'trace_detail', cursor = '42', limit = 25,
        filters = { trace_id = 'trace-runtime-01' },
      }))
      assert(tracePage.filters.trace_id == 'trace-runtime-01' and tracePage.cursor == '42')

      local simulation = assert(SynexControlProtocol.validate({
        requestId = 'request-simulate-01', operation = 'simulate', provider = 'groups',
        view = 'policy_simulation', filters = {
          actor_character_id = 'character_01', group_id = 'group_01', action = 'members.promote'
        },
      }))
      assert(simulation.provider == 'groups' and simulation.cursor == nil)
      assert(SynexControlProtocol.requestCost('simulate', 'groups', 'policy_simulation') == 3)

      local _, simulationCursorError = SynexControlProtocol.validate({
        requestId = 'request-simulate-02', operation = 'simulate', provider = 'groups',
        view = 'policy_simulation', cursor = 'forbidden', filters = {
          actor_character_id = 'character_01', group_id = 'group_01', action = 'members.promote'
        },
      })
      assert(simulationCursorError == 'INVALID_ARGUMENT')

      local _, inspectCursorError = SynexControlProtocol.validate({
        requestId = 'request-inspect-page-01', operation = 'inspect', provider = 'core',
        view = 'contract', id = 'synex.runtime.status@1.0.0', cursor = '42',
      })
      assert(inspectCursorError == 'INVALID_ARGUMENT')

      local _, extraError = SynexControlProtocol.validate({
        requestId = 'request-extra-001', operation = 'overview', action = 'delete'
      })
      local _, limitError = SynexControlProtocol.validate({
        requestId = 'request-limit-001', operation = 'page', provider = 'entities',
        view = 'entities', limit = SynexControlLimits.maximumPageSize + 1,
      })
      local _, cursorError = SynexControlProtocol.validate({
        requestId = 'request-cursor-01', operation = 'page', provider = 'entities',
        view = 'entities', cursor = string.rep('x', SynexControlLimits.maximumCursorBytes + 1),
      })
      assert(extraError == 'INVALID_ARGUMENT')
      assert(limitError == 'INVALID_LIMIT')
      assert(cursorError == 'INVALID_CURSOR')
      return overview.operation .. ':' .. page.operation
    `);
    assert.equal(result, 'overview:page');
  } finally {
    engine.global.close();
  }
});

test('Control search accepts safe provider-declared exact and prefix routes', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrapControlLua(engine);
    const result = await engine.doString(`
      local account = assert(SynexControlProtocol.validate({
        requestId = 'request-search-01', operation = 'search',
        provider = 'accounts', view = 'search',
        query = { kind = 'account', value = '11111111-1111-4111-8111-111111111111' }
      }))
      assert(account.provider == 'accounts')
      assert(account.query.mode == 'exact')

      local resource = assert(SynexControlProtocol.validate({
        requestId = 'request-search-02', operation = 'search',
        provider = 'core', view = 'audit',
        query = { kind = 'resource', value = 'synex_', mode = 'prefix' }
      }))
      assert(resource.provider == 'core')

      local routed = assert(SynexControlProtocol.validate({
        requestId = 'request-search-03', operation = 'search', provider = 'entities',
        view = 'search',
        query = { kind = 'account', value = '11111111-1111-4111-8111-111111111111' }
      }))
      local _, injection = SynexControlProtocol.validate({
        requestId = 'request-search-04', operation = 'search',
        provider = 'core', view = 'audit',
        query = { kind = 'resource', value = [[synex_core'; DROP TABLE x;--]] }
      })
      local _, shortPrefix = SynexControlProtocol.validate({
        requestId = 'request-search-05', operation = 'search',
        provider = 'groups', view = 'search',
        query = { kind = 'group', value = 'g', mode = 'prefix' }
      })
      local _, missingRoute = SynexControlProtocol.validate({
        requestId = 'request-search-06', operation = 'search',
        query = { kind = 'future_kind', value = 'future_01', mode = 'exact' }
      })
      local future = assert(SynexControlProtocol.validate({
        requestId = 'request-search-07', operation = 'search',
        provider = 'future_provider', view = 'lookup',
        query = { kind = 'future_kind', value = 'future_01', mode = 'exact' }
      }))
      assert(routed.provider == 'entities' and routed.query.kind == 'account')
      assert(injection == 'INVALID_ARGUMENT')
      assert(shortPrefix == 'INVALID_ARGUMENT')
      assert(missingRoute == 'INVALID_ARGUMENT')
      assert(future.provider == 'future_provider' and future.view == 'lookup')
      return account.provider .. ':' .. resource.provider
    `);
    assert.equal(result, 'accounts:core');
  } finally {
    engine.global.close();
  }
});

test('Control protocol rejects client-selected methods and oversized request bodies', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrapControlLua(engine);
    const result = await engine.doString(`
      local _, methodError = SynexControlProtocol.validate({
        requestId = 'request-method-01', operation = 'delete', provider = 'entities',
        view = 'entities', id = 'entity_0001'
      })
      local _, payloadError = SynexControlProtocol.validate({
        requestId = 'request-large-001', operation = 'page', provider = 'entities',
        view = 'entities', filters = { value = string.rep('x', 5000) }
      })
      assert(methodError == 'INVALID_ARGUMENT')
      assert(payloadError == 'REQUEST_TOO_LARGE')
      return methodError .. ':' .. payloadError
    `);
    assert.equal(result, 'INVALID_ARGUMENT:REQUEST_TOO_LARGE');
  } finally {
    engine.global.close();
  }
});
