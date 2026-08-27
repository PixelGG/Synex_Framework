import assert from 'node:assert/strict';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';
import { source } from './helpers.js';

const commonFoundation = String.raw`
  local function copyPlain(value, seen)
    if type(value) ~= 'table' then return value end
    seen = seen or {}
    assert(not seen[value], 'cyclic input')
    seen[value] = true
    local result = {}
    for key, item in pairs(value) do result[copyPlain(key, seen)] = copyPlain(item, seen) end
    seen[value] = nil
    return result
  end
  local function validationError()
    return { code = 'VALIDATION_FAILED', message = 'invalid', retryable = false }
  end
  Foundation = {
    copyPlain = copyPlain,
    domainError = function(code, message, retryable)
      return { code = code, message = message, retryable = retryable == true }
    end,
    validateShape = function(value, allowed, required)
      if type(value) ~= 'table' then return nil, validationError() end
      for key in pairs(value) do if not allowed[key] then return nil, validationError() end end
      for _, key in ipairs(required or {}) do
        if value[key] == nil then return nil, validationError() end
      end
      return true, nil
    end,
    isCallable = function(value) return type(value) == 'function' end,
    isPublicId = function(value)
      return type(value) == 'string' and #value >= 1 and #value <= 64
        and value:match('^[A-Za-z0-9][A-Za-z0-9_.:%-]*$') ~= nil
    end,
    isSubjectId = function(value)
      return type(value) == 'string' and #value >= 1 and #value <= 64
        and value:match('^[A-Za-z0-9][A-Za-z0-9_.:%-]*$') ~= nil
    end,
    isUuid = function(value)
      return type(value) == 'string' and #value == 36
    end,
  }
`;

test('Groups and Accounts expose exact bounded character relation contracts without payloads', async () => {
  for (const namespace of ['groups', 'accounts'] as const) {
    const engine = await new LuaFactory().createEngine();
    try {
      const providerSource = await source(`resources/synex_${namespace}/server/control_provider.lua`);
      const result = await engine.doString(`
        ${commonFoundation}
        local factory = assert(load(${JSON.stringify(providerSource)}, '@provider'))()(Foundation)
        local queryCalls = 0
        local function query(sql, parameters)
          queryCalls = queryCalls + 1
          assert(sql:find('COUNT(*) OVER()', 1, true), 'exact-count-window')
          assert(sql:find(' = ?', 1, true), 'parameterized-character-filter')
          assert(not sql:find('character-secret', 1, true), 'identifier-must-not-be-interpolated')
          assert(not sql:find('payload_json', 1, true), 'payload-must-not-be-selected')
          assert(parameters[1] == 'character-secret' and parameters[2] == 2)
          if ${JSON.stringify(namespace)} == 'groups' then
            return {
              { membershipId = 'membership-a', groupId = 'group-a', groupType = 'job',
                groupStatus = 'active', membershipState = 'ACTIVE', relationCount = '3' },
              { membershipId = 'membership-b', groupId = 'group-b', groupType = 'faction',
                groupStatus = 'active', membershipState = 'SUSPENDED', relationCount = '3' },
            }
          end
          return {
            { accountId = '00000000-0000-0000-0000-000000000001', accountRole = 'asset',
              status = 'active', currencyCode = 'usd', relationCount = '3' },
            { accountId = '00000000-0000-0000-0000-000000000002', accountRole = 'asset',
              status = 'frozen', currencyCode = 'usd', relationCount = '3' },
          }
        end
        local provider = factory({
          database = {}, methods = {}, operatorMethods = {}, query = query,
          errorSink = function() error('unexpected error sink') end,
          getApi = function() return { ownerEpoch = 7 } end,
        })
        local definition
        assert(provider:register({ ControlProviders = {
          register = function(candidate) definition = candidate return candidate end,
        } }))
        local value = assert(definition.operations.inspect({
          view = 'character_relations', id = 'character-secret', limit = 2,
        }, { traceId = 'trace-test' }))
        assert(value.count == 3 and #value.items == 2
          and value.hasMore == true and value.truncated == true)
        assert(value.items[1].relationCount == nil and value.payloadsExposed == false)
        if ${JSON.stringify(namespace)} == 'accounts' then
          assert(value.items[1].balance == nil and value.balancesExposed == false)
        end
        local rejected, rejection = definition.operations.inspect({
          view = 'character_relations', id = 'character-secret', limit = 9,
        }, { traceId = 'trace-test' })
        assert(rejected == false and rejection.code == 'VALIDATION_FAILED'
          and queryCalls == 1)
        return table.concat({ ${JSON.stringify(namespace)}, value.count, #value.items }, ':')
      `);
      assert.equal(result, `${namespace}:3:2`);
    } finally {
      engine.global.close();
    }
  }
});

test('Entities exposes only bounded character-owned entity links and no component or state payloads', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    const supportSource = await source('resources/synex_entities/server/control_provider_support.lua');
    const inspectSource = await source('resources/synex_entities/server/control_provider_inspect.lua');
    const providerSource = await source('resources/synex_entities/server/control_provider.lua');
    const result = await engine.doString(`
      assert(load(${JSON.stringify(supportSource)}, '@support'))()
      assert(load(${JSON.stringify(inspectSource)}, '@inspect'))()
      assert(load(${JSON.stringify(providerSource)}, '@provider'))()
      local queryCalls = 0
      local foundation = {
        isCallable = function(value) return type(value) == 'function' end,
        failure = function(code, message, retryable)
          return nil, { code = code, message = message, retryable = retryable == true }
        end,
        reportUnexpected = function(_, caught) error(caught) end,
      }
      local database = { query = function(sql, parameters, limits)
        queryCalls = queryCalls + 1
        assert(sql:find('COUNT(*) OVER()', 1, true), 'exact-count-window')
        assert(sql:find('owner_id', 1, true) and sql:find(' = ?', 1, true),
          'parameterized-character-filter')
        assert(not sql:find('character-secret', 1, true), 'identifier-must-not-be-interpolated')
        assert(not sql:find('component_json', 1, true)
          and not sql:find('state_json', 1, true), 'payload-must-not-be-selected')
        assert(parameters[1] == 'character-secret' and parameters[2] == 2)
        assert(limits.maximumRows == 2 and limits.maximumResultBytes <= 16384)
        return {
          { entityId = 'entity-a', entityType = 'vehicle', status = 'active',
            persistencePolicy = 'persistent', relationCount = '3' },
          { entityId = 'entity-b', entityType = 'object', status = 'dormant',
            persistencePolicy = 'owner_lifetime', relationCount = '3' },
        }
      end }
      local provider = SynexEntityControlProvider.create({
        foundation = foundation, service = {}, queryOperations = {},
        authorityRepository = {}, database = database, state = {}, registry = {},
        config = {}, bucketPolicy = {}, spawnAdmission = {},
        coreRef = { value = { ownerEpoch = 7 } },
      })
      local definition
      assert(provider.register({ ControlProviders = {
        register = function(candidate) definition = candidate return candidate end,
      } }))
      local value = assert(definition.operations.inspect({
        view = 'character_relations', id = 'character-secret', limit = 2,
      }, { traceId = 'trace-test' }))
      assert(value.count == 3 and #value.items == 2
        and value.hasMore == true and value.truncated == true)
      assert(value.items[1].relationCount == nil
        and value.items[1].component == nil and value.items[1].stateValue == nil)
      assert(value.componentPayloadsExposed == false and value.stateValuesExposed == false)
      local rejected, rejection = definition.operations.inspect({
        view = 'character_relations', id = 'character-secret', limit = 9,
      }, { traceId = 'trace-test' })
      assert(rejected == false and rejection.code == 'VALIDATION_FAILED'
        and queryCalls == 1)
      return table.concat({ value.count, #value.items, tostring(value.networkOwnerPolicy.authoritative) }, ':')
    `);
    assert.equal(result, '3:2:false');
  } finally {
    engine.global.close();
  }
});
