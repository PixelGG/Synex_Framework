import assert from 'node:assert/strict';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';
import { source } from './helpers.js';

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

test('official provider registration boundaries close raw Cfx nil/error return holes', async () => {
  const [groups, accounts, entitiesSupport, compatibility] = await Promise.all([
    source('resources/synex_groups/server/control_provider.lua'),
    source('resources/synex_accounts/server/control_provider.lua'),
    source('resources/synex_entities/server/control_provider_support.lua'),
    source('libraries/synex_bridge/control_provider.lua'),
  ]);
  for (const provider of [groups, accounts, entitiesSupport, compatibility]) {
    assert.match(provider,
      /if value == nil and operationError ~= nil then return false, operationError end/u);
  }
});

test('Groups provider advances graph cursors, rejects invalid cursors, and maps policy targets', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    const providerSource = await source('resources/synex_groups/server/control_provider.lua');
    await engine.doString(`${foundationHarness}
      local outer = assert(load(${JSON.stringify(providerSource)},
        '@resources/synex_groups/server/control_provider.lua'))()
      local createProvider = outer(Foundation)
      local simulated
      local records = {
        { child_group_id = 'group_a', parent_group_id = 'group_root', edge_type = 'parent' },
        { child_group_id = 'group_b', parent_group_id = 'group_root', edge_type = 'parent' },
        { child_group_id = 'group_c', parent_group_id = 'group_root', edge_type = 'parent' },
      }
      local provider = createProvider({
        database = {},
        methods = {
          get = function(request)
            return {
              group_id = request.group_id, type = 'job', parent_group_id = 'group_root',
              slug = 'fixture', name = 'Fixture', label = 'Fixture Group', status = 'active',
              visibility = 'private', dynamic = false, version = 1,
              created_at = '2026-08-26T00:00:00Z', updated_at = '2026-08-26T00:00:00Z',
              description = 'A full real group detail projection',
            }, nil
          end,
          policies_simulate = function(request)
            simulated = request
            return { allowed = true }, nil
          end,
        },
        query = function(_, parameters)
          local after = #parameters == 4 and parameters[3] or nil
          local maximum = parameters[#parameters]
          local rows = {}
          for _, record in ipairs(records) do
            if after == nil or record.child_group_id > after then
              rows[#rows + 1] = copy(record)
              if #rows >= maximum then break end
            end
          end
          return rows
        end,
        errorSink = function() end,
        getApi = function() return { ownerEpoch = 1 } end,
      })
      local operations
      assert(provider:register({ ControlProviders = { register = function(definition)
        operations = definition.operations
        return { namespace = definition.namespace }, nil
      end } }))

      local first = assert(operations.list({
        view = 'hierarchy', limit = 2, filters = { group_id = 'group_root' }, sort = {},
      }, { traceId = 'groups_page_1' }))
      assert(#first.edges == 2 and first.hasMore == true and first.truncated == true)
      assert(first.nextCursor == 'group_b')

      local second = assert(operations.list({
        view = 'hierarchy', cursor = first.nextCursor, limit = 2,
        filters = { group_id = 'group_root' }, sort = {},
      }, { traceId = 'groups_page_2' }))
      assert(#second.edges == 1 and second.edges[1].to == 'group_c')
      assert(second.hasMore == false and second.truncated == false and second.nextCursor == nil)

      local invalid, invalidError = operations.list({
        view = 'hierarchy', cursor = 'bad cursor', limit = 2,
        filters = { group_id = 'group_root' }, sort = {},
      }, { traceId = 'groups_bad_cursor' })
      assert(invalid == false and invalidError.code == 'VALIDATION_FAILED')

      assert(operations.simulate({
        view = 'policy_simulation', limit = 1,
        filters = {
          actor_character_id = 'character_1', group_id = 'group_root',
          action = 'groups.members.manage', target_membership_id = 'membership_1',
          target_grade_id = 'grade_2',
        },
      }, { traceId = 'groups_policy' }))
      assert(simulated.group_id == 'group_root')
      assert(simulated.target_membership_id == 'membership_1')
      assert(simulated.parameters.target_grade_id == 'grade_2')
      assert(simulated.target_grade_id == nil)

      local search = assert(operations.search({
        query = { kind = 'group', value = 'group_root', mode = 'exact' },
        limit = 1, filters = {}, sort = {},
      }, { traceId = 'groups_search' }))
      local searchColumns = 0
      for _ in pairs(search.items[1]) do searchColumns = searchColumns + 1 end
      assert(searchColumns <= 12 and search.items[1].kind == 'group')
      assert(search.items[1].result.description == 'A full real group detail projection')

      local unsafe, unsafeError = operations.simulate({
        view = 'policy_simulation',
        filters = {
          actor_character_id = 'character_1', group_id = 'group_root',
          action = 'groups.members.manage', parameters = { invented = true },
        },
      }, { traceId = 'groups_policy_unsafe' })
      assert(unsafe == false and unsafeError.code == 'VALIDATION_FAILED')
    `);
  } finally {
    engine.global.close();
  }
});

test('Accounts provider advances public-id cursors, rejects invalid cursors, and renders integrity findings', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    const providerSource = await source('resources/synex_accounts/server/control_provider.lua');
    await engine.doString(`${foundationHarness}
      local outer = assert(load(${JSON.stringify(providerSource)},
        '@resources/synex_accounts/server/control_provider.lua'))()
      local createProvider = outer(Foundation)
      local records = {
        { account_id = 'account_a' }, { account_id = 'account_b' }, { account_id = 'account_c' },
      }
      local provider = createProvider({
        database = {}, operatorMethods = {
          inspect_account = function(request)
            return { account_id = request.account_id, status = 'active', balance_minor = '100' }, nil
          end,
          inspect_transaction = function(request)
            return { transaction_id = request.transaction_id, status = 'posted' }, nil
          end,
        }, errorSink = function() end,
        getApi = function() return { ownerEpoch = 1 } end,
        query = function(sql, parameters)
          if sql:find('synex_economy_integrity_read_models', 1, true) then
            return {
              { currency_code = 'usd', status = 'warn', model_version = '3',
                finding_count = '2', entry_sum_minor = '0', net_supply_minor = '100',
                total_booked_minor = '100', generated_at = '2026-08-26T00:00:00Z' },
            }
          end
          local after = type(parameters[1]) == 'string' and parameters[1] or nil
          local maximum = parameters[#parameters]
          local rows = {}
          for _, record in ipairs(records) do
            if after == nil or record.account_id > after then
              rows[#rows + 1] = copy(record)
              if #rows >= maximum then break end
            end
          end
          return rows
        end,
      })
      local operations
      assert(provider:register({ ControlProviders = { register = function(definition)
        operations = definition.operations
        return { namespace = definition.namespace }, nil
      end } }))

      local first = assert(operations.list({
        view = 'accounts', limit = 2, filters = {}, sort = {},
      }, { traceId = 'accounts_page_1' }))
      assert(#first.items == 2 and first.nextCursor == 'account_b')
      assert(first.hasMore == true and first.truncated == true)

      local second = assert(operations.list({
        view = 'accounts', cursor = first.nextCursor, limit = 2, filters = {}, sort = {},
      }, { traceId = 'accounts_page_2' }))
      assert(#second.items == 1 and second.items[1].account_id == 'account_c')
      assert(second.hasMore == false and second.truncated == false and second.nextCursor == nil)

      local invalid, invalidError = operations.list({
        view = 'accounts', cursor = 'bad cursor', limit = 2, filters = {}, sort = {},
      }, { traceId = 'accounts_bad_cursor' })
      assert(invalid == false and invalidError.code == 'VALIDATION_FAILED')

      local integrity = assert(operations.list({
        view = 'integrity', limit = 2, filters = {}, sort = {},
      }, { traceId = 'accounts_integrity' }))
      assert(#integrity.items == 1)
      assert(integrity.items[1].code == 'ACCOUNT_INTEGRITY_FINDINGS')
      assert(integrity.items[1].severity == 'WARNING')
      assert(integrity.items[1].title:find('usd', 1, true))
      assert(integrity.items[1].summary:find('2 finding', 1, true))

      local accountId = '11111111-1111-1111-1111-111111111111'
      local search = assert(operations.search({
        query = { kind = 'account', value = accountId, mode = 'exact' },
        limit = 1, filters = {}, sort = {},
      }, { traceId = 'accounts_search' }))
      local searchColumns = 0
      for _ in pairs(search.items[1]) do searchColumns = searchColumns + 1 end
      assert(searchColumns <= 12 and search.items[1].id == accountId)
      assert(search.items[1].result.balance_minor == '100')
    `);
  } finally {
    engine.global.close();
  }
});

test('Entities provider advances runtime cursors and rejects malformed cursor state', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    const [supportSource, inspectSource, providerSource] = await Promise.all([
      source('resources/synex_entities/server/control_provider_support.lua'),
      source('resources/synex_entities/server/control_provider_inspect.lua'),
      source('resources/synex_entities/server/control_provider.lua'),
    ]);
    await engine.doString(`
      assert(load(${JSON.stringify(supportSource)},
        '@resources/synex_entities/server/control_provider_support.lua'))()
      assert(load(${JSON.stringify(inspectSource)},
        '@resources/synex_entities/server/control_provider_inspect.lua'))()
      assert(load(${JSON.stringify(providerSource)},
        '@resources/synex_entities/server/control_provider.lua'))()
      local foundation = {
        failure = function(code, message, retryable, context)
          return nil, { code = code, message = message, retryable = retryable == true,
            traceId = type(context) == 'table' and context.traceId or nil }
        end,
        isCallable = function(value) return type(value) == 'function' end,
        reportUnexpected = function() error('unexpected provider failure') end,
      }
      local records = {
        {
          archetype = { namespace = 'fixture' }, binding = { namespace = 'fixture', ref = 'a' },
          bucket = 0, entityId = 'entity_a', entityType = 'object', generation = 1,
          materialized = true, model = 1, netId = 11, networkOwner = 42,
          owner = { type = 'system', id = 'fixture' }, persistent = true,
          resourceOwner = 'synex_fixture', status = 'active',
        },
        { entityId = 'entity_b', entityType = 'object', generation = 1 },
        { entityId = 'entity_c', entityType = 'object', generation = 1 },
      }
      local definition = {
        archetype = { namespace = 'fixture' }, bucket = 0, entityId = 'entity_a',
        entityType = 'object', generation = 1, model = 1,
        owner = { type = 'system', id = 'fixture' }, persistencePolicy = { mode = 'durable' },
        persistent = true, recoveryPolicy = { mode = 'restore' },
        resourceOwner = 'synex_fixture', serverScope = 'global', status = 'active', version = 1,
      }
      local inspected = {
        definition = definition, persistence = { generation = 1 },
        binding = { namespace = 'fixture', ref = 'a' },
        runtime = records[1], diagnostics = { status = 'HEALTHY' },
      }
      local provider = SynexEntityControlProvider.create({
        foundation = foundation,
        service = {
          inspectEntity = function() return inspected, nil end,
        }, queryOperations = {}, authorityRepository = {
          queryDefinitions = function()
            return { items = { definition }, hasMore = false }, nil
          end,
        },
        database = { query = function() return {} end },
        state = { buckets = {} },
        registry = { page = function(cursor, limit)
          assert(limit == 3)
          local items = {}
          for _, record in ipairs(records) do
            if cursor == nil or record.entityId > cursor then
              items[#items + 1] = record
              if #items == limit then break end
            end
          end
          return items, { materialized = #items, visited = #items }
        end },
        config = {}, bucketPolicy = { snapshot = function(value) return value end },
        spawnAdmission = { quotaSnapshot = function() return {} end },
        coreRef = { value = { ownerEpoch = 1 } },
      })
      local operations
      assert(provider.register({ ControlProviders = { register = function(definition)
        operations = definition.operations
        return { namespace = definition.namespace }, nil
      end } }))

      local first = assert(operations.list({
        view = 'runtime', limit = 2, filters = {}, sort = {},
      }, { traceId = 'entities_page_1' }))
      assert(#first.items == 2 and first.nextCursor == 'entity_b')
      assert(first.hasMore == true and first.truncated == true)
      local runtimeColumns = 0
      for _ in pairs(first.items[1]) do runtimeColumns = runtimeColumns + 1 end
      assert(runtimeColumns == 12)

      local second = assert(operations.list({
        view = 'runtime', cursor = first.nextCursor, limit = 2, filters = {}, sort = {},
      }, { traceId = 'entities_page_2' }))
      assert(#second.items == 1 and second.items[1].entityId == 'entity_c')
      assert(second.hasMore == false and second.truncated == false and second.nextCursor == nil)

      local invalid, invalidError = operations.list({
        view = 'runtime', cursor = 'bad cursor', limit = 2, filters = {}, sort = {},
      }, { traceId = 'entities_bad_cursor' })
      assert(invalid == false and invalidError.code == 'VALIDATION_FAILED')

      local persistent = assert(operations.list({
        view = 'persistent', limit = 2, filters = {}, sort = {},
      }, { traceId = 'entities_persistent' }))
      local persistentColumns = 0
      for _ in pairs(persistent.items[1]) do persistentColumns = persistentColumns + 1 end
      assert(persistentColumns == 12)

      local search = assert(operations.search({
        query = { kind = 'entity', value = 'entity_a', mode = 'exact' },
        limit = 1, filters = {}, sort = {},
      }, { traceId = 'entities_search' }))
      local searchColumns = 0
      for _ in pairs(search.items[1]) do searchColumns = searchColumns + 1 end
      assert(searchColumns <= 12 and search.items[1].entityId == 'entity_a')
      assert(search.items[1].result.definition.entityId == 'entity_a')
    `);
  } finally {
    engine.global.close();
  }
});
