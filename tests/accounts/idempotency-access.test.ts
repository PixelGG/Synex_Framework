import assert from 'node:assert/strict';
import test from 'node:test';
import { LuaFactory, type LuaEngine } from 'wasmoon';
import { bootstrapDomain, preload } from './helpers.js';

async function bootstrapEngine(engine: LuaEngine): Promise<void> {
  await bootstrapDomain(engine);
  await preload(
    engine,
    'server.persistence.engine_shared',
    'resources/synex_accounts/server/persistence/engine_shared.lua',
  );
}

test('idempotency is scoped by caller, principal, operation, and key with conflict-safe replay', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrapEngine(engine);
    const result = await engine.doString(`
      local records, nextId, handlerCalls, conflictMetrics = {}, 1, 0, 0
      local function recordKey(caller, principalKind, principalRef, operation, key)
        return table.concat({ caller, principalKind, principalRef, operation, key }, '|')
      end
      local function copyRecords(source)
        local copied = {}
        for key, value in pairs(source) do
          copied[key] = {
            id = value.id, request_fingerprint = value.request_fingerprint,
            state = value.state, response_json = value.response_json
          }
        end
        return copied
      end
      local function query(sql, values)
        if sql:find('request_fingerprint', 1, true) and sql:find('response_json', 1, true) then
          local value = records[recordKey(values[1], values[2], values[3], values[4], values[5])]
          return value and { value } or {}
        end
        if sql:find('INSERT INTO', 1, true) then
          local scoped = recordKey(values[4], values[5], values[6], values[2], values[1])
          assert(records[scoped] == nil)
          records[scoped] = {
            id = nextId, request_fingerprint = values[3], state = 'pending'
          }
          nextId = nextId + 1
          return { affectedRows = 1 }
        end
        if sql:find('SELECT', 1, true) and sql:find('FROM', 1, true) then
          local value = records[recordKey(values[1], values[2], values[3], values[4], values[5])]
          return value and { { id = value.id } } or {}
        end
        if sql:find('UPDATE', 1, true) then
          for _, value in pairs(records) do
            if value.id == values[2] and value.state == 'pending' then
              value.state, value.response_json = 'completed', values[1]
              return { affectedRows = 1 }
            end
          end
          return { affectedRows = 0 }
        end
        error('unexpected query: ' .. sql)
      end
      local context = {
        foundation = Foundation,
        domain = Domain,
        domainError = Foundation.domainError,
        uuidV4 = Foundation.uuidV4,
        one = function() return nil end,
        many = function() return {} end,
        jsonEncode = function(value) return tostring(value.value) end,
        jsonDecode = function(value) return { value = tonumber(value) } end,
        random = function() return 7 end,
        recordMetric = function(method, name)
          if method == 'increment'
              and name == 'synex_accounts_idempotency_conflicts_total' then
            conflictMetrics = conflictMetrics + 1
          end
        end,
        scopedReplay = function() return nil, nil end,
        withRetriableTransaction = function(callback)
          local before, beforeId = copyRecords(records), nextId
          local committed = callback(query)
          if committed then return true, nil end
          records, nextId = before, beforeId
          return false, nil
        end
      }
      local port = {}
      require('server.persistence.engine_shared')(port, context)
      local Engine = context.engine
      local key = '11111111-1111-4111-8111-111111111111'
      local function command(caller, fingerprint, principalKind, principalRef)
        return {
          idempotencyKey = key, fingerprint = fingerprint,
          authority = {
            callerResource = caller, principalKind = principalKind or 'resource',
            principalRef = principalRef or caller,
            traceId = 'trace_12345678'
          }
        }
      end
      local function success(value)
        handlerCalls = handlerCalls + 1
        return { value = value }, nil
      end

      local first = assert(Engine:mutation('transfer', command('synex_shops', 'alpha'),
        function() return success(10) end))
      local replay = assert(Engine:mutation('transfer', command('synex_shops', 'alpha'),
        function() error('replay executed the handler') end))
      assert(first.value == 10 and replay.value == 10 and handlerCalls == 1)

      local conflict, conflictError = Engine:mutation(
        'transfer', command('synex_shops', 'different'), function() return success(99) end)
      assert(conflict == nil and conflictError.code == 'IDEMPOTENCY_CONFLICT')

      assert(Engine:mutation('transfer', command('synex_banking', 'different'),
        function() return success(20) end))
      assert(Engine:mutation('burn', command('synex_shops', 'different'),
        function() return success(30) end))
      assert(Engine:mutation('transfer',
        command('synex_shops', 'character-scope', 'character', 'character:42'),
        function() return success(35) end))

      local failed, failedError = Engine:mutation(
        'refund', command('synex_shops', 'retryable'), function()
          handlerCalls = handlerCalls + 1
          return nil, Foundation.domainError('POLICY_VIOLATION', 'fixture')
        end)
      assert(failed == nil and failedError.code == 'POLICY_VIOLATION')
      local retried = assert(Engine:mutation(
        'refund', command('synex_shops', 'retryable'), function() return success(40) end))
      assert(retried.value == 40)

      local recordCount = 0
      for _ in pairs(records) do recordCount = recordCount + 1 end
      return table.concat({ handlerCalls, recordCount, conflictMetrics,
        conflictError.code, failedError.code }, ':')
    `);
    assert.equal(result, '6:5:1:IDEMPOTENCY_CONFLICT:POLICY_VIOLATION');
  } finally {
    engine.global.close();
  }
});

test('account access grants owner authority, honors active role permissions, and denies absent grants', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrapEngine(engine);
    const result = await engine.doString(`
      local rows, queryCalls, observedSql = {}, 0, ''
      local context = {
        foundation = Foundation,
        domain = Domain,
        domainError = Foundation.domainError,
        uuidV4 = Foundation.uuidV4,
        one = function() return nil end,
        many = function() return {} end,
        jsonEncode = function() return '{}' end,
        jsonDecode = function() return {} end,
        random = function() return 3 end,
        scopedReplay = function() return nil, nil end,
        withRetriableTransaction = function() return false, nil end
      }
      local port = {}
      require('server.persistence.engine_shared')(port, context)
      local Engine = context.engine
      local account = {
        id = 8, public_id = '11111111-1111-4111-8111-111111111111',
        owner_kind = 'character', owner_ref = 'character:42', status = 'active'
      }
      local function query(sql, values)
        queryCalls = queryCalls + 1
        observedSql = sql
        assert(values[1] == 8 and values[2] == 'resource' and values[3] == 'synex_banking')
        return rows
      end

      local owner = assert(Engine:evaluateAccess(query, account, {
        principalKind = 'character', principalRef = 'character:42'
      }, 'transfer'))
      assert(owner.allowed and owner.owner and owner.reason == 'OWNER' and queryCalls == 0)

      rows = {{
        grant_id = '22222222-2222-4222-8222-222222222222', version = 4,
        role_id = '33333333-3333-4333-8333-333333333333', role_key = 'treasurer',
        permission_key = 'manage'
      }}
      local delegated = assert(Engine:evaluateAccess(query, account, {
        principalKind = 'resource', principalRef = 'synex_banking'
      }, 'settings.manage'))
      assert(delegated.allowed and delegated.grantActive and delegated.permissionGranted
        and delegated.reason == 'ROLE_PERMISSION' and delegated.grantVersion == 4)
      assert(observedSql:find("'active'", 1, true))
      assert(observedSql:find('active_marker', 1, true))
      assert(observedSql:find('valid_from', 1, true))
      assert(observedSql:find('valid_until', 1, true))

      rows = {}
      local absent = assert(Engine:evaluateAccess(query, account, {
        principalKind = 'resource', principalRef = 'synex_banking'
      }, 'transfer'))
      assert(not absent.allowed and absent.reason == 'NO_ACTIVE_GRANT')
      local denied, deniedError = Engine:requireAccess(query, account, {
        principalKind = 'resource', principalRef = 'synex_banking'
      }, 'transfer')
      assert(denied == nil and deniedError.code == 'ACCOUNT_ACCESS_DENIED')
      return table.concat({ owner.reason, delegated.reason, absent.reason, deniedError.code }, ':')
    `);
    assert.equal(
      result,
      'OWNER:ROLE_PERMISSION:NO_ACTIVE_GRANT:ACCOUNT_ACCESS_DENIED',
    );
  } finally {
    engine.global.close();
  }
});

test('multi-account row locks are deterministic and available balance excludes active reservations', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrapEngine(engine);
    const result = await engine.doString(`
      local capturedOrder
      local context = {
        foundation = Foundation,
        domain = Domain,
        domainError = Foundation.domainError,
        uuidV4 = Foundation.uuidV4,
        one = function() return nil end,
        many = function() return {} end,
        jsonEncode = function() return '{}' end,
        jsonDecode = function() return {} end,
        random = function() return 1 end,
        scopedReplay = function() return nil, nil end,
        withRetriableTransaction = function() return false, nil end
      }
      local port = {}
      require('server.persistence.engine_shared')(port, context)
      local Engine = context.engine
      local low = '11111111-1111-4111-8111-111111111111'
      local high = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee'
      local function query(sql, values)
        if sql:find('ORDER BY', 1, true) and sql:find('FOR UPDATE', 1, true) then
          capturedOrder = table.concat(values, ',')
          return {
            { id = 1, public_id = values[1], account_key = 'low', account_role = 'asset',
              allow_negative = 0, status = 'active', version = 1, currency_id = 5,
              currency_code = 'credits', minor_unit = 2, currency_status = 'active',
              owner_kind = 'system', owner_ref = 'synex_accounts', sequence_no = 3,
              booked_minor = 1000, snapshot_created_at = '2026-08-25 00:00:00' },
            { id = 2, public_id = values[2], account_key = 'high', account_role = 'asset',
              allow_negative = 0, status = 'active', version = 1, currency_id = 5,
              currency_code = 'credits', minor_unit = 2, currency_status = 'active',
              owner_kind = 'system', owner_ref = 'synex_accounts', sequence_no = 4,
              booked_minor = 2000, snapshot_created_at = '2026-08-25 00:00:00' }
          }
        end
        if sql:find('remaining_minor', 1, true) then
          return {{ reserved_minor = values[1] == 1 and 125 or 250 }}
        end
        error('unexpected query: ' .. sql)
      end
      local accounts = assert(Engine:loadAccounts(query, { high, low }))
      assert(capturedOrder == low .. ',' .. high)
      assert(accounts[low].available_minor == 875 and accounts[low].reserved_minor == 125)
      assert(accounts[high].available_minor == 1750 and accounts[high].reserved_minor == 250)

      local duplicate, duplicateError = Engine:loadAccounts(query, { low, low })
      assert(duplicate == nil and duplicateError.code == 'VALIDATION_FAILED')
      return capturedOrder .. ':' .. accounts[low].available_minor .. ':' .. duplicateError.code
    `);
    assert.equal(
      result,
      '11111111-1111-4111-8111-111111111111,eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee:875:VALIDATION_FAILED',
    );
  } finally {
    engine.global.close();
  }
});

test('closed accounts reject mutations and financial preflight reuses ledger policy rules', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrapEngine(engine);
    const result = await engine.doString(`
      local context = {
        foundation = Foundation,
        domain = Domain,
        domainError = Foundation.domainError,
        uuidV4 = Foundation.uuidV4,
        one = function() return nil end,
        many = function() return {} end,
        jsonEncode = function() return '{}' end,
        jsonDecode = function() return {} end,
        random = function() return 1 end,
        scopedReplay = function() return nil, nil end,
        withRetriableTransaction = function() return false, nil end
      }
      local port = {}
      require('server.persistence.engine_shared')(port, context)
      local Engine = context.engine
      local mutable, closedError = Engine:requireMutableAccount({ status = 'closed' })
      assert(mutable == nil and closedError.code == 'ACCOUNT_CLOSED')
      assert(Engine:requireMutableAccount({ status = 'frozen' }))

      local account = {
        id = 9, public_id = '11111111-1111-4111-8111-111111111111',
        account_role = 'asset', status = 'active', booked_minor = 100,
        reserved_minor = 20,
      }
      local mode, usageLocked = 'clear', false
      local function query(sql, values)
        if sql:find('synex_ledger_refund_anchors', 1, true) then
          if mode == 'open_refund' then return {{ original_transaction_id = 44 }} end
          return {}
        end
        if sql:find('synex_account_restrictions', 1, true) then
          if mode == 'restricted' then return {{ restriction_kind = 'outgoing_blocked' }} end
          return {}
        end
        if sql:find('FROM \`synex_account_policies\`', 1, true) then
          if mode == 'single' then return {{ single_transfer_limit_minor = 40, operation_mode = 'all' }} end
          if mode == 'daily' then return {{ daily_outgoing_limit_minor = 50, operation_mode = 'all' }} end
          if mode == 'allowlist' then return {{ operation_mode = 'allowlist' }} end
          if mode == 'maximum' then return {{ maximum_balance_minor = 110, operation_mode = 'all' }} end
          return {}
        end
        if sql:find('synex_account_policy_daily_usage', 1, true) then
          usageLocked = sql:find('FOR UPDATE', 1, true) ~= nil
          return {{ outgoing_minor = 30 }}
        end
        if sql:find('synex_account_policy_allowed_operations', 1, true) then return {} end
        error('unexpected preflight query: ' .. sql)
      end

      assert(Engine:evaluateAccountOperation(query, account, 'transfer', -50, 0, false))
      mode = 'restricted'
      local _, restricted = Engine:evaluateAccountOperation(query, account, 'transfer', -10, 0, false)
      assert(restricted.code == 'ACCOUNT_RESTRICTED')
      mode = 'clear'
      local _, insufficient = Engine:evaluateAccountOperation(query, account, 'transfer', -81, 0, false)
      assert(insufficient.code == 'INSUFFICIENT_FUNDS')
      mode = 'single'
      local _, single = Engine:evaluateAccountOperation(query, account, 'transfer', -50, 0, false)
      assert(single.code == 'TRANSFER_LIMIT_EXCEEDED')
      mode = 'daily'
      local _, daily = Engine:evaluateAccountOperation(query, account, 'transfer', -25, 0, true)
      assert(daily.code == 'DAILY_LIMIT_EXCEEDED' and usageLocked)
      mode = 'allowlist'
      local _, allowlist = Engine:evaluateAccountOperation(query, account, 'transfer', -10, 0, false)
      assert(allowlist.code == 'OPERATION_NOT_ALLOWED')
      mode = 'maximum'
      local _, maximum = Engine:evaluateAccountOperation(query, account, 'deposit', 11, 0, false)
      assert(maximum.code == 'MAXIMUM_BALANCE_VIOLATION')
      mode = 'clear'
      account.reserved_minor = 80
      assert(Engine:evaluateAccountOperation(query, account, 'hold.capture', -50, 50, false))
      account.booked_minor, account.reserved_minor = 0, 0
      assert(Engine:evaluateAccountClosure(query, account))
      account.booked_minor = 1
      local _, closeBalance = Engine:evaluateAccountClosure(query, account)
      assert(closeBalance.code == 'ACCOUNT_BALANCE_NOT_ZERO')
      account.booked_minor, account.reserved_minor = 0, 1
      local _, closeHold = Engine:evaluateAccountClosure(query, account)
      assert(closeHold.code == 'ACCOUNT_HAS_ACTIVE_HOLDS')
      account.reserved_minor, mode = 0, 'open_refund'
      local _, closeLifecycle = Engine:evaluateAccountClosure(query, account)
      assert(closeLifecycle.code == 'ACCOUNT_LIFECYCLE_BLOCKED')
      return table.concat({
        closedError.code, restricted.code, insufficient.code, single.code,
        daily.code, allowlist.code, maximum.code, closeLifecycle.code,
      }, ':')
    `);
    assert.equal(
      result,
      'ACCOUNT_CLOSED:ACCOUNT_RESTRICTED:INSUFFICIENT_FUNDS:TRANSFER_LIMIT_EXCEEDED:DAILY_LIMIT_EXCEEDED:OPERATION_NOT_ALLOWED:MAXIMUM_BALANCE_VIOLATION:ACCOUNT_LIFECYCLE_BLOCKED',
    );
  } finally {
    engine.global.close();
  }
});

test('access explain derives the intended capability from authoritative caller context', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrapDomain(engine);
    await preload(
      engine,
      'server.service_v2.access_policy',
      'resources/synex_accounts/server/service_v2/access_policy.lua',
    );
    const result = await engine.doString(`
      local capturedCapability, capturedResource, captured
      local service = {}
      local function mergeFields(...)
        local result = {}
        for index = 1, select('#', ...) do
          for key, value in pairs(select(index, ...)) do result[key] = value end
        end
        return result
      end
      local function shape(request, allowed, required)
        for key in pairs(request) do
          if not allowed[key] then
            return nil, Foundation.domainError('VALIDATION_FAILED', 'unknown field')
          end
        end
        for _, key in ipairs(required) do
          if request[key] == nil then
            return nil, Foundation.domainError('VALIDATION_FAILED', 'missing field')
          end
        end
        return request, nil
      end
      require('server.service_v2.access_policy')(service, {
        Foundation = Foundation,
        Domain = Domain,
        MAX_MINOR = Foundation.MAX_MINOR,
        domainError = Foundation.domainError,
        db = {
          checkAccess = function(_, command)
            captured = command
            return {
              accountId = command.accountId,
              principalKind = command.principalKind,
              principalRef = command.principalRef,
              permission = command.permission,
              accountState = 'active',
              resourceCapability = command.resourceCapability,
              owner = true, grantActive = false, permissionGranted = true,
              allowed = command.resourceCapability == true,
              reason = command.resourceCapability == true and 'OWNER'
                or 'RESOURCE_CAPABILITY_DENIED',
              bookedMinor = 1000, reservedMinor = 0, availableMinor = 1000,
            }, nil
          end,
        },
        shape = shape,
        readBase = function(_, context)
          return {
            callerResource = context.caller,
            principalKind = 'resource', principalRef = context.caller,
            traceId = context.traceId,
          }, nil
        end,
        mergeFields = mergeFields,
        principalFields = { actor_kind = true, actor_ref = true },
        provenanceFields = {},
        rolePattern = '^[a-z][a-z0-9_]*$', operationKeys = {},
        checkResourceCapability = function(resourceName, capability)
          capturedResource, capturedCapability = resourceName, capability
          return false, Foundation.domainError('CAPABILITY_DENIED', 'fixture')
        end,
      })
      local accountId = '11111111-1111-4111-8111-111111111111'
      local request = {
        account_id = accountId,
        principal_kind = 'character', principal_ref = 'character:42',
        permission = 'transfer', operation = 'transfer', amount_minor = 250,
        actor_kind = 'resource', actor_ref = 'synex_banking',
      }
      local response = assert(service.access_explain(request, {
        caller = 'synex_banking', callerEpoch = 3, traceId = 'trace_12345678',
      }))
      assert(capturedResource == 'synex_banking')
      assert(capturedCapability == 'synex.accounts.transfer')
      if captured.direction ~= 'outgoing' or captured.amountMinor ~= 250 then
        error('direction=' .. tostring(captured.direction)
          .. ',amount=' .. tostring(captured.amountMinor))
      end
      if captured.preflightRequired ~= true then
        error('preflight=' .. tostring(captured.preflightRequired))
      end
      if captured.resourceCapability ~= false then
        error('capability=' .. tostring(captured.resourceCapability))
      end
      assert(not response.resource_capability and not response.allowed)

      request.operation = 'mint'
      local invalid, invalidError = service.access_explain(request, {
        caller = 'synex_banking', callerEpoch = 3, traceId = 'trace_12345678',
      })
      assert(invalid == nil and invalidError.code == 'VALIDATION_FAILED')
      return table.concat({ capturedResource, capturedCapability, response.reason,
        invalidError.code }, ':')
    `);
    assert.equal(
      result,
      'synex_banking:synex.accounts.transfer:RESOURCE_CAPABILITY_DENIED:VALIDATION_FAILED',
    );
  } finally {
    engine.global.close();
  }
});
