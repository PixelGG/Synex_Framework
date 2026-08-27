import assert from 'node:assert/strict';
import test from 'node:test';
import { LuaFactory, type LuaEngine } from 'wasmoon';
import { source } from './helpers.js';

async function loadCore(engine: LuaEngine): Promise<void> {
  for (const relativePath of [
    'core/synex_core/server/factories.lua',
    'core/synex_core/server/foundation.lua',
    'core/synex_core/server/persistence.lua',
  ]) {
    await engine.doString(await source(relativePath));
  }
}

test('Core trace history records real bounded parent-child outcomes and starts empty after restart', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await loadCore(engine);
    const result = await engine.doString(`
      local clock = 1000
      local platform = {
        nowGame = function() return clock end,
        random = function() return 17 end,
        print = function() end,
        jsonEncode = function() return '{}' end,
        jsonDecode = function() return {} end,
        loadResourceFile = function() return nil end
      }
      local foundation = SynexCoreFactories.foundation({
        platform = platform,
        maximumTraceSpans = 32
      })

      local nestedError = foundation.error('FIXTURE_DENIED',
        'password=must-never-enter-trace-history')
      foundation.withContext({
        traceId = 'trace-parent', caller = 'synex_fixture', contract = 'fixture.parent'
      }, function()
        clock = clock + 3
        local value, operationError = foundation.withContext({
          traceId = 'trace-parent', caller = 'synex_fixture', contract = 'fixture.child'
        }, function()
          clock = clock + 7
          return nil, nestedError
        end)
        assert(value == nil and operationError == nestedError)
        clock = clock + 2
        return true, nil
      end)

      local detail = assert(foundation.tracing:detail('trace-parent', 10))
      assert(detail.status == 'AVAILABLE' and detail.retainedSpans == 2)
      assert(detail.payloadsExposed == false and detail.hasMore == false)
      local parent, child
      for _, span in ipairs(detail.items) do
        if span.operation == 'fixture.parent' then parent = span end
        if span.operation == 'fixture.child' then child = span end
        local columns = 0
        for _ in pairs(span) do columns = columns + 1 end
        assert(columns <= 12)
        assert(span.resource == 'synex_fixture')
        assert(span.password == nil and span.arguments == nil and span.payload == nil)
      end
      assert(parent and child and parent.status == 'SUCCESS' and child.status == 'ERROR')
      assert(child.errorCode == 'FIXTURE_DENIED' and child.parentSpanId == parent.spanId)
      assert(parent.childSpanIds[1] == child.spanId)
      assert(parent.durationMs >= child.durationMs and child.durationMs == 7)
      foundation.withContext({
        traceId = 'password-secret-token', caller = 'synex_fixture',
        contract = 'fixture.sanitized'
      }, function() return true, nil end)
      local sanitizedTrace = assert(foundation.tracing:list({ limit = 5 }))
      for _, span in ipairs(sanitizedTrace.items) do
        assert(span.traceId ~= 'password-secret-token')
      end

      for index = 1, 40 do
        foundation.withContext({
          traceId = 'trace-' .. tostring(index), caller = 'synex_fixture',
          contract = 'fixture.operation_' .. tostring(index)
        }, function() clock = clock + 1 return true, nil end)
      end
      local first = assert(foundation.tracing:list({ limit = 5 }))
      assert(#first.items == 5 and first.hasMore and first.truncated)
      assert(first.retained == 32 and first.maximumRetained == 32)
      assert(type(first.nextCursor) == 'string' and first.payloadsExposed == false)
      local second = assert(foundation.tracing:list({
        limit = 5, cursor = first.nextCursor
      }))
      assert(#second.items == 5
        and tonumber(second.items[1].cursor) < tonumber(first.items[5].cursor))
      local invalid, invalidError = foundation.tracing:list({ cursor = '0' })
      assert(invalid == nil and invalidError.code == 'INVALID_CURSOR')

      local pagedDetailFoundation = SynexCoreFactories.foundation({
        platform = platform,
        maximumTraceSpans = 64
      })
      for index = 1, 60 do
        pagedDetailFoundation.withContext({
          traceId = 'trace-large', caller = 'synex_fixture',
          contract = 'fixture.large_' .. tostring(index)
        }, function() clock = clock + 1 return true, nil end)
      end
      local detailFirst = assert(pagedDetailFoundation.tracing:detail(
        'trace-large', { limit = 50 }))
      assert(#detailFirst.items == 50 and detailFirst.hasMore
        and type(detailFirst.nextCursor) == 'string')
      local detailSecond = assert(pagedDetailFoundation.tracing:detail(
        'trace-large', { limit = 50, cursor = detailFirst.nextCursor }))
      assert(#detailSecond.items == 10 and not detailSecond.hasMore
        and detailSecond.nextCursor == nil)

      local restarted = SynexCoreFactories.foundation({
        platform = platform,
        maximumTraceSpans = 32
      })
      local empty = assert(restarted.tracing:list({ limit = 5 }))
      assert(#empty.items == 0 and empty.retained == 0 and not empty.hasMore)
      return table.concat({
        child.errorCode, tostring(first.retained), tostring(#second.items),
        tostring(#empty.items)
      }, ':')
    `);
    assert.equal(result, 'FIXTURE_DENIED:32:5:0');
  } finally {
    engine.global.close();
  }
});

test('Core database retains only bounded sanitized slow-query aggregates and resets on restart', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await loadCore(engine);
    const result = await engine.doString(`
      local clock = 2000
      local platform = {
        nowGame = function() return clock end,
        random = function() return 23 end,
        print = function() end,
        jsonEncode = function() return '{}' end,
        jsonDecode = function() return {} end,
        wait = function() end,
        loadResourceFile = function() return nil end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      local adapter = {
        query = function()
          clock = clock + 300
          return {}
        end,
        scalar = function() clock = clock + 300 return 1 end,
        insert = function() clock = clock + 300 return 1 end,
        update = function() clock = clock + 300 return 1 end,
        transaction = function() clock = clock + 300 return true end,
        startTransaction = function() clock = clock + 300 return true end
      }
      local persistence = SynexCoreFactories.persistence({
        platform = platform,
        foundation = foundation,
        db = adapter,
        config = { queryWarnMs = 250 },
        instanceId = 'instance-observability',
        manifestSnapshot = function() return {} end
      })

      local rawSql = 'SELECT * FROM private_users WHERE password = ?'
      foundation.withContext({
        traceId = 'trace-database', caller = 'synex_accounts',
        contract = 'accounts.inspect'
      }, function()
        assert(persistence.database:query(rawSql, { 'private-password' }))
        assert(persistence.database:query(rawSql, { 'second-private-password' }))
      end)
      local aggregate = assert(persistence.database:slowQueries({ limit = 5 }))
      assert(#aggregate.items == 1 and aggregate.items[1].occurrences == 2)
      local observed = aggregate.items[1]
      assert(observed.resource == 'synex_accounts'
        and observed.operation == 'accounts.inspect' and observed.kind == 'query')
      assert(observed.traceId == 'trace-database' and observed.durationMs == 300)
      assert(#observed.statementHash == 64 and observed.statementHash ~= rawSql)
      assert(observed.sql == nil and observed.parameters == nil
        and observed.password == nil and observed.status == 'SUCCESS')
      assert(aggregate.rawSqlExposed == false and aggregate.parametersExposed == false)

      for index = 1, 140 do
        foundation.withContext({
          traceId = 'trace-query-' .. tostring(index), caller = 'synex_fixture',
          contract = 'fixture.query_' .. tostring(index)
        }, function()
          assert(persistence.database:query(
            'SELECT ' .. tostring(index) .. ' AS bounded_fixture', { 'secret-' .. index }))
        end)
      end
      local first = assert(persistence.database:slowQueries({ limit = 50 }))
      assert(#first.items == 50 and first.retained == 128
        and first.maximumRetained == 128 and first.hasMore)
      local second = assert(persistence.database:slowQueries({
        limit = 50, cursor = first.nextCursor
      }))
      local third = assert(persistence.database:slowQueries({
        limit = 50, cursor = second.nextCursor
      }))
      assert(#second.items == 50 and second.hasMore)
      assert(#third.items == 28 and not third.hasMore and third.nextCursor == nil)
      for _, page in ipairs({ first, second, third }) do
        for _, entry in ipairs(page.items) do
          local columns = 0
          for _ in pairs(entry) do columns = columns + 1 end
          assert(columns <= 12 and entry.statementHash:match('^[0-9a-f]+$'))
          assert(entry.sql == nil and entry.parameters == nil
            and entry.password == nil and not tostring(entry.operation):find('secret', 1, true))
        end
      end
      local invalid, invalidError = persistence.database:slowQueries({ cursor = '0' })
      assert(invalid == nil and invalidError.code == 'INVALID_CURSOR')

      local restarted = SynexCoreFactories.persistence({
        platform = platform,
        foundation = foundation,
        db = adapter,
        config = { queryWarnMs = 250 },
        instanceId = 'instance-observability-restarted',
        manifestSnapshot = function() return {} end
      })
      local empty = assert(restarted.database:slowQueries({ limit = 5 }))
      assert(#empty.items == 0 and empty.retained == 0 and not empty.hasMore)
      return table.concat({
        tostring(observed.occurrences), tostring(first.retained),
        tostring(#third.items), tostring(#empty.items)
      }, ':')
    `);
    assert.equal(result, '2:128:28:0');
  } finally {
    engine.global.close();
  }
});

test('Core Control descriptors route tracing and slow-query history through bounded read models', async () => {
  const diagnostics = (await Promise.all([
    source('core/synex_core/server/bootstrap_diagnostics_control_shared.lua'),
    source('core/synex_core/server/bootstrap_diagnostics_control_queries.lua'),
    source('core/synex_core/server/bootstrap_diagnostics.lua'),
  ])).join('\n');
  assert.match(diagnostics, /tracing = true/u);
  assert.match(
    diagnostics,
    /id = 'tracing'.+operation = 'list'.+presentation = 'timeline'/u,
  );
  assert.match(diagnostics, /id = 'trace_detail'.+operation = 'list'.+presentation = 'timeline'/u);
  assert.match(diagnostics, /foundation\.tracing:list\(\{/u);
  assert.match(diagnostics, /foundation\.tracing:detail\(/u);
  assert.match(diagnostics, /persistence\.database:slowQueries\(\{/u);
  assert.doesNotMatch(diagnostics, /SLOW_QUERY_HISTORY_UNAVAILABLE'\s*\}\s*,\s*nil/u);
});
