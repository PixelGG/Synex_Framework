import assert from 'node:assert/strict';
import { performance } from 'node:perf_hooks';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';

import { bootstrapControlLua, source } from './helpers.js';

const root = process.cwd();

const scaleFixtures = [
  { name: 'groups', prefix: 'group', total: 10_000 },
  { name: 'accounts', prefix: 'account', total: 100_000 },
  { name: 'entities', prefix: 'entity', total: 20_000 },
  { name: 'transactions', prefix: 'transaction', total: 1_000_000 },
] as const;

function identifier(prefix: string, ordinal: number): string {
  return `${prefix}_${String(ordinal).padStart(8, '0')}`;
}

function* ordinalStream(total: number): Generator<number, void, undefined> {
  for (let ordinal = 1; ordinal <= total; ordinal += 1) yield ordinal;
}

test('Control scale fixtures stream every planned cardinality without retaining a dataset dump', () => {
  const started = performance.now();
  for (const fixture of scaleFixtures) {
    let count = 0;
    let sum = 0;
    let first = '';
    let last = '';
    for (const ordinal of ordinalStream(fixture.total)) {
      count += 1;
      sum += ordinal;
      if (ordinal === 1) first = identifier(fixture.prefix, ordinal);
      if (ordinal === fixture.total) last = identifier(fixture.prefix, ordinal);
    }
    assert.equal(count, fixture.total, fixture.name);
    assert.equal(sum, (fixture.total * (fixture.total + 1)) / 2, fixture.name);
    assert.equal(first, identifier(fixture.prefix, 1), fixture.name);
    assert.equal(last, identifier(fixture.prefix, fixture.total), fixture.name);
  }
  // Local catastrophic-regression guard only. This is not a production throughput claim.
  assert.ok(performance.now() - started < 10_000);
});

const foundationHarness = String.raw`
  local function copy(value, seen)
    if type(value) ~= 'table' then return value end
    seen = seen or {}
    assert(not seen[value], 'cyclic fixture')
    seen[value] = true
    local result = {}
    for key, item in pairs(value) do result[copy(key, seen)] = copy(item, seen) end
    seen[value] = nil
    return result
  end

  Foundation = {}
  function Foundation.domainError(code, message, retryable)
    return { code = code, message = message, retryable = retryable == true }
  end
  function Foundation.copyPlain(value) return copy(value) end
  function Foundation.validateShape(value, allowed, required)
    if type(value) ~= 'table' then
      return nil, Foundation.domainError('VALIDATION_FAILED', 'object required', false)
    end
    for key in pairs(value) do
      if type(key) ~= 'string' or not allowed[key] then
        return nil, Foundation.domainError('VALIDATION_FAILED', 'unknown field', false)
      end
    end
    for _, key in ipairs(required or {}) do
      if value[key] == nil then
        return nil, Foundation.domainError('VALIDATION_FAILED', 'missing field', false)
      end
    end
    return true
  end
  function Foundation.isCallable(value) return type(value) == 'function' end
  function Foundation.isPublicId(value)
    return type(value) == 'string' and #value >= 1 and #value <= 64
      and value:match('^[A-Za-z0-9][A-Za-z0-9_.:%-]*$') ~= nil
  end
  function Foundation.isSubjectId(value) return Foundation.isPublicId(value) end
  function Foundation.isUuid(value)
    return type(value) == 'string'
      and value:match('^[0-9a-f]+%-[0-9a-f]+%-[0-9a-f]+%-[0-9a-f]+%-[0-9a-f]+$') ~= nil
  end
`;

test('official providers keep 10k Groups, 100k Accounts, 20k Entities, and 1m Transactions keyset pages bounded', async () => {
  const [groupsSource, accountsSource, entitiesSupportSource, entitiesInspectSource,
    entitiesSource] = await Promise.all([
    source('resources/synex_groups/server/control_provider.lua'),
    source('resources/synex_accounts/server/control_provider.lua'),
    source('resources/synex_entities/server/control_provider_support.lua'),
    source('resources/synex_entities/server/control_provider_inspect.lua'),
    source('resources/synex_entities/server/control_provider.lua'),
  ]);
  const engine = await new LuaFactory().createEngine();
  try {
    const result = String(await engine.doString(`${foundationHarness}
      local maximumMaterialized = 0

      local function id(prefix, ordinal)
        return prefix .. '_' .. ('%08d'):format(ordinal)
      end

      local function afterOrdinal(prefix, cursor)
        if cursor == nil then return 0 end
        local value = cursor:match('^' .. prefix .. '_(%d+)$')
        return value and tonumber(value) or nil
      end

      local function virtualRows(prefix, total, cursor, maximum, field)
        local after = assert(afterOrdinal(prefix, cursor), 'invalid virtual cursor')
        local rows = {}
        local last = math.min(total, after + maximum)
        for ordinal = after + 1, last do
          local row = { status = 'active', version = '1' }
          row[field] = id(prefix, ordinal)
          rows[#rows + 1] = row
        end
        maximumMaterialized = math.max(maximumMaterialized, #rows)
        return rows
      end

      local groupOuter = assert(load(${JSON.stringify(groupsSource)},
        '@resources/synex_groups/server/control_provider.lua'))()
      local createGroups = groupOuter(Foundation)
      local groupOperations
      local groups = createGroups({
        database = {},
        methods = {
          list = function(request)
            local limit = request.limit or 20
            local rows = virtualRows('group', 10000, request.cursor, limit, 'group_id')
            local after = afterOrdinal('group', request.cursor)
            local last = after + #rows
            return {
              items = rows,
              next_cursor = last < 10000 and id('group', last) or nil,
              truncated = last < 10000,
            }, nil
          end,
          doctor = function() return { status = 'PASS', checks = {} }, nil end,
        },
        query = function() error('Groups SQL path is not used by this fixture') end,
        errorSink = function() end,
        getApi = function() return { ownerEpoch = 1 } end,
      })
      assert(groups:register({ ControlProviders = { register = function(definition)
        groupOperations = definition.operations
        return { namespace = definition.namespace }, nil
      end } }))

      local groupsFirst = assert(groupOperations.list({
        view = 'groups', limit = 25, filters = {}, sort = {},
      }, { traceId = 'scale_groups_first' }))
      local groupsNext = assert(groupOperations.list({
        view = 'groups', cursor = groupsFirst.nextCursor, limit = 25,
        filters = {}, sort = {},
      }, { traceId = 'scale_groups_next' }))
      local groupsLast = assert(groupOperations.list({
        view = 'groups', cursor = 'group_00009975', limit = 25,
        filters = {}, sort = {},
      }, { traceId = 'scale_groups_last' }))
      assert(#groupsFirst.items == 25 and groupsFirst.nextCursor == 'group_00000025')
      assert(groupsNext.items[1].group_id == 'group_00000026')
      assert(#groupsLast.items == 25 and groupsLast.hasMore == false
        and groupsLast.nextCursor == nil)
      local invalidGroup, invalidGroupError = groupOperations.list({
        view = 'groups', cursor = 'bad cursor', limit = 25, filters = {}, sort = {},
      }, { traceId = 'scale_groups_invalid' })
      assert(invalidGroup == false and invalidGroupError.code == 'VALIDATION_FAILED')

      local accountsOuter = assert(load(${JSON.stringify(accountsSource)},
        '@resources/synex_accounts/server/control_provider.lua'))()
      local createAccounts = accountsOuter(Foundation)
      local accountOperations
      local accounts = createAccounts({
        database = {}, operatorMethods = {}, errorSink = function() end,
        getApi = function() return { ownerEpoch = 1 } end,
        query = function(sql, parameters)
          local prefix, total, field
          if sql:find('synex_ledger_transactions', 1, true) then
            prefix, total, field = 'transaction', 1000000, 'transaction_id'
          elseif sql:find('FROM \`synex_accounts\`', 1, true) then
            prefix, total, field = 'account', 100000, 'account_id'
          else
            error('unexpected Accounts scale query')
          end
          local cursor = type(parameters[1]) == 'string' and parameters[1] or nil
          local maximum = parameters[#parameters]
          return virtualRows(prefix, total, cursor, maximum, field)
        end,
      })
      assert(accounts:register({ ControlProviders = { register = function(definition)
        accountOperations = definition.operations
        return { namespace = definition.namespace }, nil
      end } }))

      local function assertAccountPage(view, prefix, total)
        local first = assert(accountOperations.list({
          view = view, limit = 25, filters = {}, sort = {},
        }, { traceId = 'scale_' .. prefix .. '_first' }))
        local nextPage = assert(accountOperations.list({
          view = view, cursor = first.nextCursor, limit = 25,
          filters = {}, sort = {},
        }, { traceId = 'scale_' .. prefix .. '_next' }))
        local lastCursor = id(prefix, total - 25)
        local last = assert(accountOperations.list({
          view = view, cursor = lastCursor, limit = 25,
          filters = {}, sort = {},
        }, { traceId = 'scale_' .. prefix .. '_last' }))
        assert(#first.items == 25 and first.nextCursor == id(prefix, 25))
        assert(nextPage.items[1][prefix .. '_id'] == id(prefix, 26))
        assert(#last.items == 25 and last.hasMore == false and last.nextCursor == nil)
      end
      assertAccountPage('accounts', 'account', 100000)
      assertAccountPage('transactions', 'transaction', 1000000)
      local invalidAccount, invalidAccountError = accountOperations.list({
        view = 'accounts', cursor = 'bad cursor', limit = 25,
        filters = {}, sort = {},
      }, { traceId = 'scale_accounts_invalid' })
      assert(invalidAccount == false and invalidAccountError.code == 'VALIDATION_FAILED')

      assert(load(${JSON.stringify(entitiesSupportSource)},
        '@resources/synex_entities/server/control_provider_support.lua'))()
      assert(load(${JSON.stringify(entitiesInspectSource)},
        '@resources/synex_entities/server/control_provider_inspect.lua'))()
      assert(load(${JSON.stringify(entitiesSource)},
        '@resources/synex_entities/server/control_provider.lua'))()
      local entityOperations
      local entityFoundation = {
        failure = function(code, message, retryable, context)
          return nil, { code = code, message = message, retryable = retryable == true,
            traceId = type(context) == 'table' and context.traceId or nil }
        end,
        isCallable = function(value) return type(value) == 'function' end,
        reportUnexpected = function() error('unexpected entity provider failure') end,
      }
      local entities = SynexEntityControlProvider.create({
        foundation = entityFoundation,
        service = { inspectEntity = function() return nil, { code = 'NOT_FOUND' } end },
        queryOperations = {},
        authorityRepository = {
          queryDefinitions = function(request)
            local rows = virtualRows('entity', 20000, request.afterEntityId,
              request.limit, 'entityId')
            for _, row in ipairs(rows) do
              row.archetype = { namespace = 'fixture' }
              row.bucket = 0
              row.entityType = 'object'
              row.generation = 1
              row.model = 1
              row.owner = { type = 'system', id = 'fixture' }
              row.persistent = true
              row.resourceOwner = 'synex_fixture'
              row.serverScope = 'global'
            end
            return { items = rows }, nil
          end,
        },
        database = { query = function() return {} end },
        state = { buckets = {} }, registry = { page = function() return {} end },
        config = {}, bucketPolicy = { snapshot = function(value) return value end },
        spawnAdmission = { quotaSnapshot = function() return {} end },
        coreRef = { value = { ownerEpoch = 1 } },
      })
      assert(entities.register({ ControlProviders = { register = function(definition)
        entityOperations = definition.operations
        return { namespace = definition.namespace }, nil
      end } }))
      local entitiesFirst = assert(entityOperations.list({
        view = 'persistent', limit = 25, filters = {}, sort = {},
      }, { traceId = 'scale_entities_first' }))
      local entitiesNext = assert(entityOperations.list({
        view = 'persistent', cursor = entitiesFirst.nextCursor, limit = 25,
        filters = {}, sort = {},
      }, { traceId = 'scale_entities_next' }))
      local entitiesLast = assert(entityOperations.list({
        view = 'persistent', cursor = 'entity_00019975', limit = 25,
        filters = {}, sort = {},
      }, { traceId = 'scale_entities_last' }))
      assert(#entitiesFirst.items == 25 and entitiesFirst.nextCursor == 'entity_00000025')
      assert(entitiesNext.items[1].entityId == 'entity_00000026')
      assert(#entitiesLast.items == 25 and entitiesLast.hasMore == false
        and entitiesLast.nextCursor == nil)
      local invalidEntity, invalidEntityError = entityOperations.list({
        view = 'persistent', cursor = 'bad cursor', limit = 25,
        filters = {}, sort = {},
      }, { traceId = 'scale_entities_invalid' })
      assert(invalidEntity == false and invalidEntityError.code == 'VALIDATION_FAILED')

      assert(maximumMaterialized == 26,
        'largest virtual page materialized ' .. tostring(maximumMaterialized))
      return table.concat({ groupsFirst.nextCursor, groupsLast.items[#groupsLast.items].group_id,
        entitiesFirst.nextCursor, entitiesLast.items[#entitiesLast.items].entityId,
        tostring(maximumMaterialized) }, ':')
    `));
    assert.equal(result,
      'group_00000025:group_00010000:entity_00000025:entity_00020000:26');
  } finally {
    engine.global.close();
  }
});

test('Control cursor scopes reject filter and sort changes and do not survive a Control reload', async () => {
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
            namespace = 'entities', label = 'Entities', category = 'domain',
            version = '1.0.0', resource = 'synex_entities', health = 'HEALTHY',
            circuit = 'CLOSED', operations = { 'list' }, views = {{
              id = 'entities', label = 'Entities', operation = 'list',
              presentation = 'table', accessClass = 'general',
            }},
          }} } end,
          invoke = function(namespace, operation, request)
            invocations = invocations + 1
            providerCursors[#providerCursors + 1] = request.cursor or 'initial'
            return {
              namespace = namespace, operation = operation, resource = 'synex_entities',
              data = { items = {}, hasMore = true,
                nextCursor = 'entity-private-' .. tostring(invocations) },
            }
          end,
        } }
      end } }

      local function loadServer()
        assert(load(${JSON.stringify(server)}, '@resources/synex_control/server/server.lua'))()
      end
      local function request(requestId, cursor, status, direction)
        network['synex_control:request']({
          requestId = requestId, operation = 'page', provider = 'entities',
          view = 'entities', cursor = cursor, limit = 25,
          filters = { status = status or 'active' },
          sort = { field = 'entity_id', direction = direction or 'asc' },
        })
        return events[#events].payload
      end

      loadServer()
      source = 41
      local first = request('request-scope-first')
      assert(first.ok == true and first.data.nextCursor:match('^cursor%-'))
      local handle = first.data.nextCursor

      local changedFilter = request('request-scope-filter', handle, 'disabled', 'asc')
      assert(changedFilter.ok == false and changedFilter.error.code == 'INVALID_CURSOR')
      local changedSort = request('request-scope-sort', handle, 'active', 'desc')
      assert(changedSort.ok == false and changedSort.error.code == 'INVALID_CURSOR')
      assert(invocations == 1)

      local validNext = request('request-scope-next', handle, 'active', 'asc')
      assert(validNext.ok == true and providerCursors[2] == 'entity-private-1')
      local preReloadHandle = validNext.data.nextCursor

      loadServer()
      source = 41
      local stale = request('request-scope-reload', preReloadHandle, 'active', 'asc')
      assert(stale.ok == false and stale.error.code == 'INVALID_CURSOR')
      assert(invocations == 2)
      return table.concat({ changedFilter.error.code, changedSort.error.code,
        stale.error.code, tostring(invocations) }, ':')
    `);
    assert.equal(result, 'INVALID_CURSOR:INVALID_CURSOR:INVALID_CURSOR:2');
  } finally {
    engine.global.close();
  }
});

test('bounded Control projections stay inside local headless microbenchmark budgets', async () => {
  const renderers = await import(pathToFileURL(path.join(
    root, 'resources/synex_control/web/components/renderers.js',
  )).href) as {
    projectDetail: (value: unknown) => unknown[];
    projectMetrics: (value: unknown) => unknown[];
    projectTable: (value: unknown) => { items: unknown[] };
    projectTimeline: (value: unknown) => unknown[];
  };

  const fixtures = {
    overview: {
      status: 'HEALTHY', generatedAt: '2026-08-26T00:00:00Z',
      providers: Object.fromEntries(Array.from({ length: 12 }, (_, index) => [
        `provider_${index}`, { status: 'HEALTHY', views: 20, durationMs: index },
      ])),
    },
    providerSummary: {
      status: 'HEALTHY', metrics: {
        requests: 1_024, failures: 2, cacheHits: 900, cacheMisses: 124,
        duration: { maximumMs: 37, averageMs: 4 },
      },
    },
    search: { items: Array.from({ length: 100 }, (_, index) => ({
      kind: 'entity', id: identifier('entity', index + 1), status: 'active',
      resource: 'synex_entities', generation: index + 1,
    })) },
    entityInspect: {
      entityId: identifier('entity', 1), status: 'active', generation: 7,
      definition: { entityType: 'object', persistent: true, resourceOwner: 'synex_vehicles' },
      runtime: { bucket: 0, materialized: true, networkOwner: 'masked' },
      diagnostics: { status: 'HEALTHY', findings: [] },
    },
    transactionInspect: {
      transaction: {
        transactionId: '11111111-1111-4111-8111-111111111111', status: 'posted',
        currency: 'credits', reasonCode: 'synex_test.transfer', entryCount: 16,
      },
      entries: Array.from({ length: 16 }, (_, index) => ({
        accountId: `account-${index + 1}`, direction: index % 2 === 0 ? 'debit' : 'credit',
        amountMinor: String((index + 1) * 100), sequence: index + 1,
      })),
    },
    trace: { items: Array.from({ length: 100 }, (_, index) => ({
      timestamp: `2026-08-26T00:${String(index % 60).padStart(2, '0')}:00Z`,
      status: index % 17 === 0 ? 'WARNING' : 'HEALTHY',
      action: `control.operation.${index}`, traceId: `trace-${index}`,
      actor: { type: 'resource', reference: 'synex_control' },
      target: { type: 'provider', reference: `provider_${index % 12}` },
    })) },
  };

  const workloads = [
    { name: 'overview', budgetMs: 3_000, run: () => renderers.projectDetail(fixtures.overview).length },
    { name: 'provider_summary', budgetMs: 3_000, run: () => renderers.projectMetrics(fixtures.providerSummary).length },
    { name: 'search_rendering', budgetMs: 3_000, run: () => renderers.projectTable(fixtures.search).items.length },
    { name: 'entity_inspect_rendering', budgetMs: 3_000, run: () => renderers.projectDetail(fixtures.entityInspect).length },
    { name: 'transaction_inspect_rendering', budgetMs: 3_000, run: () => renderers.projectDetail(fixtures.transactionInspect).length },
    { name: 'trace_rendering', budgetMs: 3_000, run: () => renderers.projectTimeline(fixtures.trace).length },
  ];
  const iterations = 250;
  const report: Record<string, { elapsedMs: number; checksum: number }> = {};
  for (const workload of workloads) {
    for (let warmup = 0; warmup < 10; warmup += 1) workload.run();
    let checksum = 0;
    const started = performance.now();
    for (let iteration = 0; iteration < iterations; iteration += 1) {
      checksum += workload.run();
    }
    const elapsedMs = performance.now() - started;
    assert.ok(elapsedMs < workload.budgetMs,
      `${workload.name} exceeded its local ${workload.budgetMs}ms harness budget`);
    assert.ok(checksum > 0, workload.name);
    report[workload.name] = { elapsedMs, checksum };
  }
  assert.deepEqual(Object.keys(report), workloads.map((workload) => workload.name));
  const scope = 'Local Node projection harness; excludes FXServer, CEF, networking, MariaDB, and production concurrency.';
  assert.match(scope, /excludes FXServer, CEF, networking, MariaDB/u);
});
