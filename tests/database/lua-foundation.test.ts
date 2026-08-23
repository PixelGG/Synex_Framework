import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';
import { repositoryRoot } from './harness.js';

const luaModules = {
  synex_groups: [
    'server/foundation.lua',
    'server/outbox.lua',
    'server/service.lua',
    'server/persistence.lua',
    'server/persistence/observability.lua',
    'server/contracts.lua',
  ],
  synex_accounts: [
    'server/foundation.lua',
    'server/outbox.lua',
    'server/retention.lua',
    'server/service.lua',
    'server/persistence.lua',
    'server/persistence/accounts.lua',
    'server/persistence/ledger.lua',
    'server/persistence/holds.lua',
    'server/persistence/access.lua',
    'server/persistence/integrity.lua',
    'server/contracts.lua',
  ],
} as const;

type FoundationResource = keyof typeof luaModules;

function moduleName(relativePath: string): string {
  return relativePath.replace(/\.lua$/u, '').replaceAll('/', '.');
}

async function luaBootstrap(resource: FoundationResource): Promise<string> {
  const directory = path.join(repositoryRoot, 'resources', resource);
  const registrations: string[] = [];
  for (const relativePath of luaModules[resource]) {
    const source = await readFile(path.join(directory, relativePath), 'utf8');
    registrations.push(
      `package.preload[${JSON.stringify(moduleName(relativePath))}] = assert(load(${JSON.stringify(source)}))`,
    );
  }
  const main = await readFile(path.join(directory, 'server/main.lua'), 'utf8');
  return `${registrations.join('\n')}\nlocal module = assert(load(${JSON.stringify(main)}))()\n`;
}

for (const [resource, expectedFactories] of [
  ['synex_groups', 5],
  ['synex_accounts', 5],
] as const) {
  test(`${resource} composition uses fixed manifest-listed modules and exposes injectable factories`, async () => {
    const engine = await new LuaFactory().createEngine();
    try {
      await engine.doString('SYNEX_TEST_MODE = true');
      const factoryCount = await engine.doString(`
        ${await luaBootstrap(resource)}
        local count = 0
        for _, value in pairs(module) do if type(value) == 'function' then count = count + 1 end end
        return count
      `);
      assert.equal(factoryCount, expectedFactories);
    } finally {
      engine.global.close();
    }
  });
}

for (const resource of ['synex_groups', 'synex_accounts'] as const) {
  test(`${resource} accepts genuine Cfx-callable API references without trusting markers`, async () => {
    const engine = await new LuaFactory().createEngine();
    await engine.global.set('cfxCallable', {});
    try {
      await engine.doString('SYNEX_TEST_MODE = true');
      const result = await engine.doString(`
        ${await luaBootstrap(resource)}
        local Foundation = require 'server.foundation'
        local tableRef = setmetatable({ __cfx_functionReference = 'table-fixture' }, {
          __metatable = 'protected-cfx-table',
          __call = function(_, value) return 'table:' .. value end
        })
        debug.setmetatable(cfxCallable, {
          __metatable = 'protected-cfx-userdata',
          __call = function(_, value) return 'userdata:' .. value end
        })
        assert(Foundation.isCallable(function() end))
        assert(Foundation.isCallable(tableRef) and tableRef('ok') == 'table:ok')
        assert(type(cfxCallable) == 'userdata')
        assert(Foundation.isCallable(cfxCallable) and cfxCallable('ok') == 'userdata:ok')
        assert(not Foundation.isCallable({ __cfx_functionReference = 'marker-only' }))
        assert(not Foundation.isCallable(setmetatable({}, {
          __metatable = 'protected-invalid-call', __call = true
        })))
        debug.setmetatable(cfxCallable, { __metatable = 'protected-noncallable-userdata' })
        assert(not Foundation.isCallable(cfxCallable))
        return type(tableRef) .. ':' .. type(cfxCallable)
      `);
      assert.equal(result, 'table:userdata');
    } finally {
      engine.global.close();
    }
  });
}

for (const [resource, eventType] of [
  ['synex_groups', 'synex.groups.created'],
  ['synex_accounts', 'synex.accounts.transferred'],
] as const) {
  test(`${resource} outbox publishes the persisted topic and payload before completing its owned claim`, async () => {
    const engine = await new LuaFactory().createEngine();
    try {
      await engine.doString('SYNEX_TEST_MODE = true');
      const result = await engine.doString(`
        ${await luaBootstrap(resource)}
        local updates = {}
        local dispatcher = module.createOutboxDispatcher({
          update = function(sql, parameters)
            updates[#updates + 1] = { sql = sql, parameters = parameters }
            return sql:find("SET \`state\` = 'pending'", 1, true) and 1 or 1
          end,
          query = function(sql, parameters)
            assert(sql:find("\`locked_by\` = ?", 1, true))
            assert(parameters[1] == 'claim_worker_0001')
            return {{
              id = 7,
              event_id = '11111111-1111-4111-8111-111111111111',
              aggregate_id = '22222222-2222-4222-8222-222222222222',
              event_type = ${JSON.stringify(eventType)},
              schema_version = 1,
              payload_json = '{"value":7}',
              attempts = 1
            }}
          end,
          jsonDecode = function(value)
            assert(value == '{"value":7}')
            return { value = 7 }
          end
        })
        local report, err = dispatcher:dispatchBatch('claim_worker_0001', function(topic, payload, options)
          assert(topic == ${JSON.stringify(eventType)})
          assert(payload.value == 7)
          assert(options.eventId == '11111111-1111-4111-8111-111111111111')
          assert(options.aggregateId == '22222222-2222-4222-8222-222222222222')
          assert(options.schemaVersion == 1 and options.traceId == options.eventId)
          return { delivered = 1, failed = 0 }, nil
        end, { maximum = 1 })
        assert(report and err == nil)
        assert(report.recovered == 1 and report.claimed == 1 and report.published == 1)
        assert(report.retried == 0 and report.dead == 0 and #report.failures == 0)
        assert(#updates == 4)
        assert(updates[1].sql:find("\`locked_until\` IS NULL", 1, true))
        assert(updates[2].sql:find("ORDER BY \`id\` ASC LIMIT ?", 1, true))
        assert(updates[2].parameters[1] == 'claim_worker_0001')
        assert(updates[3].sql:find("AND \`locked_until\` > CURRENT_TIMESTAMP(6)", 1, true))
        assert(updates[4].sql:find("SET \`state\` = 'published'", 1, true))
        assert(updates[4].parameters[2] == 'claim_worker_0001')
        return 'published'
      `);
      assert.equal(result, 'published');
    } finally {
      engine.global.close();
    }
  });

  test(`${resource} outbox retries publisher errors and dead-letters invalid persisted JSON`, async () => {
    const engine = await new LuaFactory().createEngine();
    try {
      await engine.doString('SYNEX_TEST_MODE = true');
      const result = await engine.doString(`
        ${await luaBootstrap(resource)}
        local failureTransitions = {}
        local dispatcher = module.createOutboxDispatcher({
          update = function(sql, parameters)
            if sql:find("SET \`state\` = ?,", 1, true) then
              failureTransitions[#failureTransitions + 1] = parameters
            end
            return 1
          end,
          query = function()
            return {
              {
                id = 8,
                event_id = '33333333-3333-4333-8333-333333333333',
                aggregate_id = '44444444-4444-4444-8444-444444444444',
                event_type = ${JSON.stringify(eventType)}, schema_version = 1,
                payload_json = '{"value":8}', attempts = 2
              },
              {
                id = 9,
                event_id = '55555555-5555-4555-8555-555555555555',
                aggregate_id = '66666666-6666-4666-8666-666666666666',
                event_type = ${JSON.stringify(eventType)}, schema_version = 1,
                payload_json = '{invalid', attempts = 10
              }
            }
          end,
          jsonDecode = function(value)
            if value == '{invalid' then error('decoder details must stay private') end
            return { value = 8 }
          end
        })
        local publishCalls = 0
        local report, err = dispatcher:dispatchBatch('claim_worker_0002', function()
          publishCalls = publishCalls + 1
          return { delivered = 0, failed = 1 }, nil
        end)
        assert(report and err == nil and publishCalls == 1)
        assert(report.published == 0 and report.retried == 1 and report.dead == 1)
        assert(#report.failures == 2)
        assert(report.failures[1].code == 'OUTBOX_SUBSCRIBER_FAILED' and report.failures[1].dead == false)
        assert(report.failures[2].code == 'OUTBOX_INVALID_PAYLOAD' and report.failures[2].dead == true)
        assert(#failureTransitions == 2)
        assert(failureTransitions[1][1] == 'pending' and failureTransitions[1][2] == 4)
        assert(failureTransitions[2][1] == 'dead' and failureTransitions[2][2] == 256)
        return 'bounded-retry'
      `);
      assert.equal(result, 'bounded-retry');
    } finally {
      engine.global.close();
    }
  });

  test(`${resource} outbox lock tokens keep nested workers disjoint and published rows idempotent`, async () => {
    const engine = await new LuaFactory().createEngine();
    try {
      await engine.doString('SYNEX_TEST_MODE = true');
      const result = await engine.doString(`
        ${await luaBootstrap(resource)}
        local rows = {
          { id = 1, state = 'pending', attempts = 0 },
          { id = 2, state = 'pending', attempts = 0 }
        }
        local function update(sql, parameters)
          if sql:find("SET \`state\` = 'pending'", 1, true) then return 0 end
          if sql:find("\`attempts\` = \`attempts\` + 1", 1, true) then
            local claimed = 0
            for _, row in ipairs(rows) do
              if row.state == 'pending' and claimed < parameters[3] then
                row.state, row.lockedBy, row.attempts = 'publishing', parameters[1], row.attempts + 1
                claimed = claimed + 1
              end
            end
            return claimed
          end
          if sql:find("SET \`locked_until\`", 1, true) then
            for _, row in ipairs(rows) do
              if row.id == parameters[2] and row.state == 'publishing' and row.lockedBy == parameters[3] then
                return 1
              end
            end
            return 0
          end
          if sql:find("SET \`state\` = 'published'", 1, true) then
            for _, row in ipairs(rows) do
              if row.id == parameters[1] and row.state == 'publishing' and row.lockedBy == parameters[2] then
                row.state, row.lockedBy = 'published', nil
                return 1
              end
            end
            return 0
          end
          error('unexpected update')
        end
        local function query(_, parameters)
          local selected = {}
          for _, row in ipairs(rows) do
            if row.state == 'publishing' and row.lockedBy == parameters[1] then
              selected[#selected + 1] = {
                id = row.id,
                event_id = row.id == 1 and '77777777-7777-4777-8777-777777777777'
                  or '88888888-8888-4888-8888-888888888888',
                aggregate_id = row.id == 1 and '99999999-9999-4999-8999-999999999999'
                  or 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
                event_type = ${JSON.stringify(eventType)}, schema_version = 1,
                payload_json = tostring(row.id), attempts = row.attempts
              }
            end
          end
          return selected
        end
        local dispatcher = module.createOutboxDispatcher({
          update = update, query = query,
          jsonDecode = function(value) return { id = tonumber(value) } end
        })
        local seen, nestedReport = {}, nil
        local firstReport = assert(dispatcher:dispatchBatch('claim_worker_a', function(_, payload)
          if payload.id == 1 then
            nestedReport = assert(dispatcher:dispatchBatch('claim_worker_b', function(_, nestedPayload)
              seen[#seen + 1] = nestedPayload.id
              return { delivered = 1, failed = 0 }
            end, { maximum = 1 }))
          end
          seen[#seen + 1] = payload.id
          return { delivered = 1, failed = 0 }
        end, { maximum = 1 }))
        local replayReport = assert(dispatcher:dispatchBatch('claim_worker_c', function()
          error('published rows must not be delivered again')
        end, { maximum = 1 }))
        table.sort(seen)
        assert(seen[1] == 1 and seen[2] == 2 and #seen == 2)
        assert(firstReport.published == 1 and nestedReport.published == 1)
        assert(replayReport.claimed == 0 and replayReport.published == 0)
        assert(rows[1].state == 'published' and rows[2].state == 'published')
        return 'disjoint'
      `);
      assert.equal(result, 'disjoint');
    } finally {
      engine.global.close();
    }
  });
}

for (const [resource, expectedMethods] of [
  ['synex_groups', [
    'createGroup', 'getGroup', 'addMembership', 'changeMembership', 'removeMembership',
    'createGrade', 'setGradeCapability', 'setPrimaryMembership', 'getReadModel', 'checkCapability',
    'listSubjectMemberships', 'getCharacterLifecycleSummary', 'applyCharacterDeletion',
    'getControlSummary',
  ]],
  ['synex_accounts', [
    'registerCurrency', 'createAccount', 'getSnapshot', 'post', 'createHold', 'getHold',
    'captureHold', 'releaseHold', 'reverse', 'createAccessRole', 'grantAccess', 'revokeAccess',
    'getAccess', 'runReconciliation', 'getIntegrity',
    'listOwnerAccounts', 'getCharacterLifecycleSummary', 'applyCharacterDeletion',
    'getControlSummary',
  ]],
] as const) {
  test(`${resource} persistence composition preserves its complete private port`, async () => {
    const engine = await new LuaFactory().createEngine();
    try {
      await engine.doString('SYNEX_TEST_MODE = true');
      const luaMethodNames = `{ ${expectedMethods.map((name) => JSON.stringify(name)).join(', ')} }`;
      const methodCount = await engine.doString(`
        ${await luaBootstrap(resource)}
        local port = module.createOxmysqlPort({
          jsonEncode = function() return '{}' end,
          jsonDecode = function() return {} end,
          random = function() return 1 end
        })
        local expected = ${luaMethodNames}
        for _, name in ipairs(expected) do assert(type(port[name]) == 'function', name) end
        local count = 0
        for _ in pairs(port) do count = count + 1 end
        return count
      `);
      assert.equal(methodCount, expectedMethods.length);
    } finally {
      engine.global.close();
    }
  });
}

test('group grade capability evaluation gives matching denies precedence over allows', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await engine.doString('SYNEX_TEST_MODE = true');
    const result = await engine.doString(`
      ${await luaBootstrap('synex_groups')}
      local allowed, denied, matched = module.evaluateCapabilityRules({
        { capability = 'synex.accounts.*', effect = 'allow' },
        { capability = 'synex.accounts.transfer', effect = 'deny' }
      }, 'synex.accounts.transfer')
      assert(allowed == false and denied == true and #matched == 2)
      local boundaryAllowed, boundaryDenied = module.evaluateCapabilityRules({
        { capability = 'synex.accounts.*', effect = 'allow' }
      }, 'synex.accountsx.transfer')
      assert(boundaryAllowed == false and boundaryDenied == false)
      return 'deny-wins'
    `);
    assert.equal(result, 'deny-wins');
  } finally {
    engine.global.close();
  }
});

test('account foundation rejects smuggled fields and snapshots every optional fingerprint position', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await engine.doString('SYNEX_TEST_MODE = true');
    const result = await engine.doString(`
      ${await luaBootstrap('synex_accounts')}
      local db = {
        post = function(_, command) return command, nil end
      }
      local service = module.createService({
        db = db,
        jsonEncode = function() return '{}' end,
        jsonDecode = function() return {} end,
        errorSink = function() end
      })
      local base = {
        idempotency_key = '11111111-1111-4111-8111-111111111111',
        source_account_id = '22222222-2222-4222-8222-222222222222',
        destination_account_id = '33333333-3333-4333-8333-333333333333',
        amount_minor = 25
      }
      local first = assert(service.transfer(base))
      local second = assert(service.transfer({
        idempotency_key = base.idempotency_key,
        source_account_id = base.source_account_id,
        destination_account_id = base.destination_account_id,
        amount_minor = base.amount_minor,
        actor_ref = 'resource:synex_test'
      }))
      assert(first.fingerprint ~= second.fingerprint)
      base.account_id = '44444444-4444-4444-8444-444444444444'
      local rejected, err = service.transfer(base)
      assert(rejected == nil and err.code == 'VALIDATION_FAILED')
      return first.kind
    `);
    assert.equal(result, 'transfer');
  } finally {
    engine.global.close();
  }
});

test('account access and reconciliation validators reject ambiguous or action-bearing input', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await engine.doString('SYNEX_TEST_MODE = true');
    const result = await engine.doString(`
      ${await luaBootstrap('synex_accounts')}
      local called = false
      local db = setmetatable({}, {
        __index = function()
          return function() called = true return {}, nil end
        end
      })
      local service = module.createService({
        db = db,
        jsonEncode = function() return '{}' end,
        jsonDecode = function() return {} end,
        errorSink = function() end
      })
      local role, roleError = service.create_access_role({
        idempotency_key = '11111111-1111-4111-8111-111111111111',
        account_id = '22222222-2222-4222-8222-222222222222',
        role_key = 'cashier', display_name = 'Cashier', permissions = { 'view', 'view' }
      })
      assert(role == nil and roleError.code == 'VALIDATION_FAILED')
      local grant, grantError = service.grant_access({
        idempotency_key = '33333333-3333-4333-8333-333333333333',
        account_id = '22222222-2222-4222-8222-222222222222',
        role_id = '44444444-4444-4444-8444-444444444444',
        principal_kind = 'resource', principal_ref = 'Invalid-Resource'
      })
      assert(grant == nil and grantError.code == 'VALIDATION_FAILED')
      local run, runError = service.run_reconciliation({
        idempotency_key = '55555555-5555-4555-8555-555555555555',
        currency_code = 'usd', ban_principal = true
      })
      assert(run == nil and runError.code == 'VALIDATION_FAILED')
      assert(called == false)
      return 'validated'
    `);
    assert.equal(result, 'validated');
  } finally {
    engine.global.close();
  }
});

for (const [resource, operation, method, request] of [
  ['synex_groups', 'get', 'get', "{ group_id = '11111111-1111-4111-8111-111111111111' }"],
  ['synex_accounts', 'get_snapshot', 'get_snapshot', "{ account_id = '11111111-1111-4111-8111-111111111111' }"],
] as const) {
  test(`${resource} reports unexpected failures through a redacted structured sink`, async () => {
    const engine = await new LuaFactory().createEngine();
    try {
      await engine.doString('SYNEX_TEST_MODE = true');
      const result = await engine.doString(`
        ${await luaBootstrap(resource)}
        local captured
        local db = setmetatable({}, {
          __index = function()
            return function() error('database_password=do-not-log') end
          end
        })
        local service = module.createService({
          db = db,
          jsonEncode = function() return '{}' end,
          jsonDecode = function() return {} end,
          errorSink = function(event) captured = event end
        })
        local value, err = service[${JSON.stringify(method)}](${request}, { traceId = 'trace-safe_123' })
        assert(value == nil and err.code == 'DATABASE_ERROR' and err.retryable == true)
        assert(captured.operation == ${JSON.stringify(operation)})
        assert(captured.traceId == 'trace-safe_123')
        local count = 0
        for key, item in pairs(captured) do
          assert(key == 'operation' or key == 'traceId')
          assert(tostring(item):find('do%-not%-log') == nil)
          count = count + 1
        end
        assert(count == 2)
        service[${JSON.stringify(method)}](${request}, { traceId = 'bad trace\\nsecret' })
        assert(captured.operation == ${JSON.stringify(operation)})
        assert(captured.traceId == 'unavailable')
        return 'redacted'
      `);
      assert.equal(result, 'redacted');
    } finally {
      engine.global.close();
    }
  });
}

for (const [resource, operation, method, request, validFirstRows, expectedQueries] of [
  [
    'synex_groups',
    'get',
    'get',
    "{ group_id = '11111111-1111-4111-8111-111111111111' }",
    'nil',
    1,
  ],
  [
    'synex_groups',
    'get_read_model',
    'get_read_model',
    "{ group_id = '11111111-1111-4111-8111-111111111111', subject_kind = 'user', subject_id = '22222222-2222-4222-8222-222222222222' }",
    "{ { grade_public_id = '33333333-3333-4333-8333-333333333333' } }",
    2,
  ],
  [
    'synex_accounts',
    'get_snapshot',
    'get_snapshot',
    "{ account_id = '11111111-1111-4111-8111-111111111111' }",
    'nil',
    1,
  ],
  [
    'synex_accounts',
    'get_access',
    'get_access',
    "{ account_id = '11111111-1111-4111-8111-111111111111', principal_kind = 'resource', principal_ref = 'synex_test' }",
    '{ { id = 1 } }',
    2,
  ],
] as const) {
  test(`${resource} ${method} fails closed for nil and non-table oxmysql query results`, async () => {
    const engine = await new LuaFactory().createEngine();
    try {
      await engine.doString('SYNEX_TEST_MODE = true');
      const result = await engine.doString(`
        ${await luaBootstrap(resource)}
        local invalidResults = {
          { label = 'nil', produce = function() return nil end },
          { label = 'boolean', produce = function() return false end }
        }
        for _, invalid in ipairs(invalidResults) do
          local queryCount = 0
          MySQL = {
            query = {
              await = function()
                queryCount = queryCount + 1
                if queryCount < ${expectedQueries} then return ${validFirstRows} end
                return invalid.produce()
              end
            },
            transaction = { await = function() return true end }
          }
          local captured
          local port = module.createOxmysqlPort({
            jsonEncode = function() return '{}' end,
            jsonDecode = function() return {} end,
            random = function() return 1 end
          })
          local service = module.createService({
            db = port,
            jsonEncode = function() return '{}' end,
            jsonDecode = function() return {} end,
            errorSink = function(event) captured = event end
          })
          local value, err = service[${JSON.stringify(method)}](${request}, { traceId = 'query-result-test' })
          assert(value == nil and err.code == 'DATABASE_ERROR' and err.retryable == true, invalid.label)
          assert(queryCount == ${expectedQueries}, invalid.label)
          assert(captured.operation == ${JSON.stringify(operation)}, invalid.label)
          assert(captured.traceId == 'query-result-test', invalid.label)
        end
        return 'fail-closed'
      `);
      assert.equal(result, 'fail-closed');
    } finally {
      engine.global.close();
    }
  });
}
