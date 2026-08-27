import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';
import { repositoryRoot } from './harness.js';

const luaModules = {
  synex_groups: [
    'server/cache.lua',
    'server/validation.lua',
    'server/domain/constants.lua',
    'server/domain/lifecycle.lua',
    'server/domain/graph.lua',
    'server/domain/capabilities.lua',
    'server/domain/policy.lua',
    'server/domain/registry.lua',
    'server/extension_registries.lua',
    'server/group_creation_approvals.lua',
    'server/group_deletions.lua',
    'server/scheduler.lua',
    'server/runtime_error.lua',
    'server/json_runtime.lua',
    'server/core_bootstrap.lua',
    'server/domain/application_schema.lua',
    'server/foundation.lua',
    'server/database_adapter.lua',
    'server/runtime_index.lua',
    'server/outbox.lua',
    'server/service.lua',
    'server/persistence/effects.lua',
    'server/persistence/approved_operations.lua',
    'server/persistence/definition_cache.lua',
    'server/persistence/capability_access.lua',
    'server/persistence/runtime_context.lua',
    'server/persistence.lua',
    'server/persistence/organizations_shared.lua',
    'server/persistence/organizations_read.lua',
    'server/persistence/organizations_creation.lua',
    'server/persistence/organizations_lifecycle.lua',
    'server/persistence/organizations_creation_approvals.lua',
    'server/persistence/organizations_deletion.lua',
    'server/persistence/organizations_types.lua',
    'server/persistence/extension_registries.lua',
    'server/persistence/organizations_structure.lua',
    'server/persistence/organizations.lua',
    'server/persistence/memberships_shared.lua',
    'server/persistence/memberships_read.lua',
    'server/persistence/memberships_invitations.lua',
    'server/persistence/memberships_lifecycle.lua',
    'server/persistence/membership_transition_policies.lua',
    'server/persistence/memberships_access.lua',
    'server/persistence/memberships_reporting.lua',
    'server/persistence/memberships.lua',
    'server/persistence/governance_shared.lua',
    'server/persistence/governance_capabilities.lua',
    'server/persistence/governance_capability_rules.lua',
    'server/persistence/governance_policies.lua',
    'server/persistence/governance_attribute_values.lua',
    'server/persistence/governance_attributes.lua',
    'server/persistence/governance_attribute_activation.lua',
    'server/persistence/governance_definitions_capabilities.lua',
    'server/persistence/governance_definitions_group_normalization.lua',
    'server/persistence/governance_definitions_hierarchy.lua',
    'server/persistence/governance_definitions_groups.lua',
    'server/persistence/governance_definitions.lua',
    'server/persistence/governance.lua',
    'server/persistence/workflows_shared.lua',
    'server/persistence/workflows_duty.lua',
    'server/persistence/workflows_assignments.lua',
    'server/persistence/workflow_reads.lua',
    'server/persistence/workflows_applications.lua',
    'server/persistence/workflows_proposals.lua',
    'server/persistence/workflows.lua',
    'server/persistence/diagnostics.lua',
    'server/persistence/workers.lua',
    'server/persistence/deletions.lua',
    'server/persistence/observability.lua',
    'server/control_provider.lua',
    'server/contracts.lua',
  ],
  synex_accounts: [
    'server/foundation.lua',
    'server/json_runtime.lua',
    'server/domain.lua',
    'server/core_bootstrap.lua',
    'server/operator_adapter.lua',
    'server/outbox.lua',
    'server/retention.lua',
    'server/service.lua',
    'server/service_v2/runtime.lua',
    'server/service_v2/catalog_accounts.lua',
    'server/service_v2/transactions_holds.lua',
    'server/service_v2/access_policy.lua',
    'server/service_v2/integrity.lua',
    'server/service_v2/guard.lua',
    'server/service_v2.lua',
    'server/lifecycle.lua',
    'server/persistence.lua',
    'server/persistence/engine_shared.lua',
    'server/persistence/accounts_v2.lua',
    'server/persistence/transactions.lua',
    'server/persistence/transaction_reads.lua',
    'server/persistence/holds_v2.lua',
    'server/persistence/access_v2.lua',
    'server/persistence/restrictions_v2.lua',
    'server/persistence/integrity_behavior.lua',
    'server/persistence/integrity_v2.lua',
    'server/persistence/integrity_control.lua',
    'server/persistence/observability_control.lua',
    'server/persistence/observability_inspect.lua',
    'server/persistence/observability.lua',
    'server/persistence/lifecycle_groups.lua',
    'server/persistence/lifecycle.lua',
    'server/persistence/accounts.lua',
    'server/persistence/ledger.lua',
    'server/persistence/holds.lua',
    'server/persistence/access.lua',
    'server/persistence/integrity.lua',
    'server/control_provider.lua',
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

test('Groups Cfx module loader is manifest-bound and starts before composition', async () => {
  const [loader, manifest, runtimeRegistration] = await Promise.all([
    readFile(path.join(
      repositoryRoot,
      'resources/synex_groups/server/module_loader.lua',
    ), 'utf8'),
    readFile(path.join(
      repositoryRoot,
      'resources/synex_groups/fxmanifest.lua',
    ), 'utf8'),
    readFile(path.join(
      repositoryRoot,
      'resources/synex_groups/server/runtime_registration.lua',
    ), 'utf8'),
  ]);
  assert.match(loader, /GetNumResourceMetadata\(RESOURCE_NAME, 'file'\)/u);
  assert.ok(loader.includes("path:match('^server/[a-z0-9_/]+%.lua$')"));
  assert.match(loader, /modulePaths\[name\]/u);
  assert.match(loader, /LoadResourceFile\(RESOURCE_NAME, path\)/u);
  assert.match(loader, /source, '@' \.\. RESOURCE_NAME \.\. '\/' \.\. path, 't', _ENV/u);
  assert.doesNotMatch(loader, /PerformHttpRequest|SaveResourceFile|GetConvar/u);
  assert.match(
    manifest,
    /server_scripts\s*\{\s*'server\/module_loader\.lua',\s*'server\/runtime_registration\.lua',\s*'server\/main\.lua'\s*\}/u,
  );
  const main = await readFile(path.join(
    repositoryRoot,
    'resources/synex_groups/server/main.lua',
  ), 'utf8');
  assert.doesNotMatch(main, /\bload\s*\(|\bdofile\s*\(/u);
  assert.doesNotMatch(runtimeRegistration, /\bload\s*\(|\bdofile\s*\(/u);
  assert.match(main, /local function bootstrapRuntime\(\)/u);
  assert.match(main, /CoreBootstrap\.runWhenReady\(\{/u);
  assert.match(runtimeRegistration, /CoreBootstrap\.createRegistration\(\{/u);
  const descriptor = JSON.parse(await readFile(path.join(
    repositoryRoot,
    'resources/synex_groups/synex.resource.json',
  ), 'utf8')) as { critical?: unknown };
  assert.equal(descriptor.critical, false);
});

function persistenceDependencies(resource: FoundationResource): string {
  if (resource !== 'synex_groups') {
    return `{ jsonEncode = function() return '{}' end, jsonDecode = function() return {} end,
      random = function() return 1 end, domain = module.Domain }`;
  }
  return `(function()
    local evaluator = module.Capabilities.create({
      evaluateRules = function(permission, rules)
        local matches, allows, denies = {}, 0, 0
        for index, rule in ipairs(rules) do
          local pattern = rule.permission
          local matched = pattern == permission
          if not matched and pattern:sub(-2) == '.*' then
            local prefix = pattern:sub(1, -3)
            matched = permission:sub(1, #prefix + 1) == prefix .. '.'
          end
          if matched then
            matches[#matches + 1] = {
              index = index, permission = pattern, effect = rule.effect
            }
            if rule.effect == 'deny' then denies = denies + 1 else allows = allows + 1 end
          end
        end
        return {
          matches = matches, denied = denies > 0,
          allowed = allows > 0 and denies == 0
        }, nil
      end
    })
    local database = CoreDatabaseFixture or {
      null = function() return { __synexDatabaseNull = true } end,
      read = function() return {}, nil end,
      write = function() return { affectedRows = 0 }, nil end,
      transaction = function(_, handler)
        local tx = {
          query = function() return { affectedRows = 1 } end,
          many = function() return {} end,
          one = function() return nil end,
          affected = function() return 1 end,
          insert = function() return { affectedRows = 1, insertId = 1 } end
        }
        local value, err = handler(tx)
        return value, err, { replayed = false }
      end,
      maintenance = function(_, handler)
        local tx = {
          query = function() return { affectedRows = 1 } end,
          many = function() return {} end,
          one = function() return nil end,
          affected = function() return 1 end,
          insert = function() return { affectedRows = 1, insertId = 1 } end
        }
        return handler(tx)
      end
    }
    return {
      dataPort = module.createDatabaseAdapter(database),
      jsonEncode = function() return '{}' end,
      jsonDecode = function() return {} end,
      nextId = function(namespace) return namespace .. '_test_identifier' end,
      cache = module.createCache({ maximum = 32, ttlMs = 5000 }),
      registries = {
        groupTypes = module.Registry.create(), relationTypes = module.Registry.create(),
        attributeSchemas = module.Registry.create(), dutyStates = module.Registry.create()
      },
      capabilityEvaluator = evaluator,
      policyEngine = module.Policy.create({ capabilities = evaluator }),
      applicationSchemas = module.ApplicationSchemas,
      validateOperation = module.Validation.operation,
      runtimeIndex = module.createRuntimeIndex({ maximumCharacters = 32,
        maximumMemberships = 128, maximumMembershipsPerCharacter = 16 }),
      checkCorePermission = function() return true, nil end
    }
  end)()`;
}

function serviceDependencies(
  resource: FoundationResource,
  repository: string,
  errorSink = 'function() end',
): string {
  if (resource !== 'synex_groups') {
    return `{ db = ${repository}, jsonEncode = function() return '{}' end, jsonDecode = function() return {} end, errorSink = ${errorSink} }`;
  }
  return `{
    repository = ${repository},
    characters = { get = function(characterId) return { id = characterId } end },
    hooks = { run = function(_, value) return value end },
    audit = { append = function() return { eventId = 'audit_test_identifier' } end },
    runtimeEffects = { apply = function() return true end },
    cache = module.createCache({ maximum = 32, ttlMs = 5000 }),
    jsonEncode = function() return '{}' end,
    errorSink = ${errorSink}
  }`;
}

function serviceContext(resource: FoundationResource, traceId: string): string {
  if (resource !== 'synex_groups') return `{ traceId = ${JSON.stringify(traceId)} }`;
  return `{ traceId = ${JSON.stringify(traceId)}, caller = 'synex_test', callerEpoch = 1 }`;
}

for (const [resource, expectedFactories] of [
  ['synex_groups', 13],
  ['synex_accounts', 9],
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
            ${resource === 'synex_groups'
              ? `assert(sql:find('LEFT JOIN \`synex_group_domain_history\`', 1, true))`
              : ''}
            return {{
              id = 7,
              event_id = '11111111-1111-4111-8111-111111111111',
              aggregate_id = '22222222-2222-4222-8222-222222222222',
              event_type = ${JSON.stringify(eventType)},
              schema_version = 1,
              payload_json = '{"value":7}',
              attempts = 1
              ${resource === 'synex_groups'
                ? `, correlation_id = 'trace_original_0001'`
                : ''}
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
          assert(options.schemaVersion == 1)
          assert(options.traceId == ${resource === 'synex_groups'
            ? `'trace_original_0001'`
            : `options.eventId`})
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

test('Groups outbox preserves bounded history traces and safely falls back for legacy events', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await engine.doString('SYNEX_TEST_MODE = true');
    const result = await engine.doString(`
      ${await luaBootstrap('synex_groups')}
      local rows = {
        {
          id = 1,
          event_id = '11111111-1111-4111-8111-111111111111',
          aggregate_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
          event_type = 'synex.groups.membership.visibility_changed',
          schema_version = 1, payload_json = '{"value":1}', attempts = 1,
          correlation_id = 'trace_history_0001',
          context_json = '{"traceId":"must_not_override_0001"}'
        },
        {
          id = 2,
          event_id = '22222222-2222-4222-8222-222222222222',
          aggregate_id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
          event_type = 'synex.groups.membership.visibility_changed',
          schema_version = 1, payload_json = '{"value":2}', attempts = 1,
          correlation_id = 'bad\\ntrace',
          context_json = '{"traceId":"trace_context_0002","password":"never-log"}'
        },
        {
          id = 3,
          event_id = '33333333-3333-4333-8333-333333333333',
          aggregate_id = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
          event_type = 'synex.groups.membership.visibility_changed',
          schema_version = 1, payload_json = '{"value":3}', attempts = 1,
          correlation_id = 'bad trace', context_json = nil
        }
      }
      local dispatcher = module.createOutboxDispatcher({
        update = function() return 1 end,
        query = function() return rows end,
        jsonDecode = function(value)
          if value:find('trace_context_0002', 1, true) then
            return { traceId = 'trace_context_0002', password = 'never-log' }
          end
          local number = tonumber(value:match('"value":(%d+)'))
          assert(number ~= nil)
          return { value = number }
        end
      })
      local traces, payloads = {}, {}
      local report, err = dispatcher:dispatchBatch('claim_trace_0001', function(_, payload, options)
        traces[#traces + 1] = options.traceId
        payloads[#payloads + 1] = payload.value
        assert(options.password == nil)
        return { delivered = 1, failed = 0 }, nil
      end, { maximum = 3 })
      assert(report and err == nil and report.published == 3)
      assert(traces[1] == 'trace_history_0001')
      assert(traces[2] == 'trace_context_0002')
      assert(traces[3] == '33333333-3333-4333-8333-333333333333')
      assert(payloads[1] == 1 and payloads[2] == 2 and payloads[3] == 3)
      return true
    `);
    assert.equal(result, true);
  } finally {
    engine.global.close();
  }
});

for (const [resource, expectedMethods, expectedPortCount] of [
  ['synex_groups', [
    'read', 'preflight', 'execute', 'markAuditDelivered', 'dispatchAuditBatch', 'maintain',
    'getGroupDeletion', 'getGroupDeletionPlanRequest', 'listGroupDeletions',
    'preflightGroupDeletion', 'applyGroupDeletionPlan',
    'listSubjectMemberships', 'getCharacterLifecycleSummary', 'applyCharacterDeletion',
    'getControlSummary', 'invalidateDefinitionCache', 'clearDefinitionCache',
    'definitionCacheSnapshot',
  ], 18],
  ['synex_accounts', [
    'registerCurrency', 'createAccount', 'getSnapshot', 'post', 'createHold', 'getHold',
    'captureHold', 'releaseHold', 'reverse', 'createAccessRole', 'grantAccess', 'revokeAccess',
    'getAccess', 'runReconciliation', 'getIntegrity',
    'listOwnerAccounts', 'getCharacterLifecycleSummary', 'applyCharacterDeletion',
    'getControlSummary',
    'registerCurrencyV2', 'createAccountV2', 'postTransaction', 'captureHoldV2',
    'checkAccess', 'getIntegrityV2', 'applyGroupDeletion', 'doctorAccounts',
    'inspectTransaction', 'inspectAccount', 'getOperationalMetrics',
  ], 72],
] as const) {
  test(`${resource} persistence composition preserves its complete private port`, async () => {
    const engine = await new LuaFactory().createEngine();
    try {
      await engine.doString('SYNEX_TEST_MODE = true');
      const luaMethodNames = `{ ${expectedMethods.map((name) => JSON.stringify(name)).join(', ')} }`;
      const persistenceFactory = resource === 'synex_groups'
        ? 'createDataPortPersistence'
        : 'createOxmysqlPort';
      const methodCount = await engine.doString(`
        ${await luaBootstrap(resource)}
        local port = module.${persistenceFactory}(${persistenceDependencies(resource)})
        local expected = ${luaMethodNames}
        for _, name in ipairs(expected) do assert(type(port[name]) == 'function', name) end
        local count = 0
        for _ in pairs(port) do count = count + 1 end
        return count
      `);
      assert.equal(methodCount, expectedPortCount);
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
      local allowed, denied, matched = module.Foundation.evaluateCapabilityRules({
        { capability = 'synex.accounts.*', effect = 'allow' },
        { capability = 'synex.accounts.transfer', effect = 'deny' }
      }, 'synex.accounts.transfer')
      assert(allowed == false and denied == true and #matched == 2)
      local boundaryAllowed, boundaryDenied = module.Foundation.evaluateCapabilityRules({
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
        local service = module.createService(${serviceDependencies(
          resource,
          'db',
          'function(event) captured = event end',
        )})
        local value, err = service[${JSON.stringify(method)}](${request}, ${serviceContext(resource, 'trace-safe_123')})
        assert(value == nil and err.code == 'DATABASE_ERROR' and err.retryable == true)
        assert(captured.operation == ${JSON.stringify(operation)})
        assert(captured.traceId == 'trace-safe_123')
        local count = 0
        for key, item in pairs(captured) do
          assert(key == 'operation' or key == 'traceId'
            ${resource === 'synex_groups' ? `or key == 'groupId'` : ''})
          assert(tostring(item):find('do%-not%-log') == nil)
          count = count + 1
        end
        assert(count == ${resource === 'synex_groups' ? 3 : 2})
        ${resource === 'synex_groups'
          ? `assert(captured.groupId == '11111111-1111-4111-8111-111111111111')`
          : ''}
        ${resource === 'synex_groups' ? `
        local invalidValue, invalidError = service[${JSON.stringify(method)}](${request},
          { traceId = 'bad trace\\nsecret', caller = 'synex_test', callerEpoch = 1 })
        assert(invalidValue == nil and invalidError.code == 'VALIDATION_FAILED')
        assert(captured.traceId == 'trace-safe_123')
        ` : `
        service[${JSON.stringify(method)}](${request}, { traceId = 'bad trace\\nsecret' })
        assert(captured.operation == ${JSON.stringify(operation)})
        assert(captured.traceId == 'unavailable')
        `}
        return 'redacted'
      `);
      assert.equal(result, 'redacted');
    } finally {
      engine.global.close();
    }
  });
}

test('Groups structured runtime errors copy only bounded known identifiers and reject smuggled fields', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await engine.doString('SYNEX_TEST_MODE = true');
    const result = await engine.doString(`
      ${await luaBootstrap('synex_groups')}
      local captured
      module.Foundation.reportUnexpectedError(function(event)
        captured = event
      end, 'synex_groups', 'members_set_visibility', {
        traceId = 'trace_safe_0001'
      }, {
        group_id = 'group_0001',
        membership_id = 'membership_0001',
        actor_character_id = 'character_0001',
        groupId = 'smuggled_group_0001',
        payload = { password = 'never-log' },
        metadata = { token = 'never-log' },
        password = 'never-log'
      })
      assert(captured.operation == 'members_set_visibility')
      assert(captured.traceId == 'trace_safe_0001')
      assert(captured.groupId == 'group_0001')
      assert(captured.membershipId == 'membership_0001')
      assert(captured.characterId == 'character_0001')
      assert(captured.payload == nil and captured.metadata == nil and captured.password == nil)
      local capturedCount = 0
      for key in pairs(captured) do
        assert(key == 'operation' or key == 'traceId' or key == 'groupId'
          or key == 'membershipId' or key == 'characterId')
        capturedCount = capturedCount + 1
      end
      assert(capturedCount == 5)

      local sanitized = module.sanitizeRuntimeErrorEvent({
        operation = 'runtime_index_refresh', traceId = 'trace_safe_0002',
        code = 'RUNTIME_INDEX_REFRESH_FAILED',
        groupId = 'group_0002', membershipId = 'membership_0002',
        characterId = 'character_0002', payload = { secret = 'never-log' },
        metadata = 'never-log', arbitrary = 'never-log'
      })
      assert(sanitized.level == 'error')
      assert(sanitized.event == 'groups_operation_failed')
      assert(sanitized.resource == 'synex_groups')
      assert(sanitized.operation == 'runtime_index_refresh')
      assert(sanitized.traceId == 'trace_safe_0002')
      assert(sanitized.code == 'RUNTIME_INDEX_REFRESH_FAILED')
      assert(sanitized.groupId == 'group_0002')
      assert(sanitized.membershipId == 'membership_0002')
      assert(sanitized.characterId == 'character_0002')
      assert(sanitized.payload == nil and sanitized.metadata == nil
        and sanitized.arbitrary == nil)
      local sanitizedCount = 0
      for key in pairs(sanitized) do
        assert(key == 'level' or key == 'event' or key == 'resource'
          or key == 'operation' or key == 'traceId' or key == 'code'
          or key == 'groupId' or key == 'membershipId' or key == 'characterId')
        sanitizedCount = sanitizedCount + 1
      end
      assert(sanitizedCount == 9)

      local hostile
      module.Foundation.reportUnexpectedError(function(event)
        hostile = event
      end, 'synex_groups', 'members_set_visibility', {
        traceId = 'bad\\ntrace'
      }, {
        group_id = 'group_0003\\nsecret',
        membership_id = 'membership_0003\\rsecret',
        actor_character_id = 'character_0003\\tsecret',
        payload = 'never-log'
      })
      assert(hostile.traceId == 'unavailable')
      assert(hostile.groupId == nil and hostile.membershipId == nil
        and hostile.characterId == nil and hostile.payload == nil)
      local hostileSanitized = module.sanitizeRuntimeErrorEvent({
        operation = 'bad\\noperation', traceId = 'bad\\ntrace', code = 'bad code',
        groupId = 'group_0003\\nsecret', membershipId = 'membership_0003\\rsecret',
        characterId = 'character_0003\\tsecret', payload = 'never-log'
      })
      assert(hostileSanitized.operation == 'unavailable')
      assert(hostileSanitized.traceId == 'unavailable')
      assert(hostileSanitized.code == 'UNEXPECTED_ERROR')
      assert(hostileSanitized.groupId == nil and hostileSanitized.membershipId == nil
        and hostileSanitized.characterId == nil and hostileSanitized.payload == nil)
      return true
    `);
    assert.equal(result, true);
  } finally {
    engine.global.close();
  }
});

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
    `{ { id = 1, public_id = '11111111-1111-4111-8111-111111111111',
      status = 'active', owner_kind = 'system', owner_ref = 'synex_accounts',
      booked_minor = 0, reserved_minor = 0 } }`,
    2,
  ],
] as const) {
  test(`${resource} ${method} fails closed for nil and non-table database query results`, async () => {
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
          ${resource === 'synex_groups' ? `
          CoreDatabaseFixture = {
            null = function() return { __synexDatabaseNull = true } end,
            read = function()
              queryCount = queryCount + 1
              if queryCount < ${expectedQueries} then return ${validFirstRows} end
              return invalid.produce()
            end,
            write = function() return { affectedRows = 0 } end,
            transaction = function() error('unexpected transaction') end,
            maintenance = function() error('unexpected maintenance') end
          }
          ` : `
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
          `}
          local captured
          local port = module.${resource === 'synex_groups'
            ? 'createDataPortPersistence'
            : 'createOxmysqlPort'}(${persistenceDependencies(resource)})
          local service = module.createService(${serviceDependencies(
            resource,
            'port',
            'function(event) captured = event end',
          )})
          local value, err = service[${JSON.stringify(method)}](${request}, ${serviceContext(resource, 'query-result-test')})
          assert(value == nil and err.code == 'DATABASE_ERROR' and err.retryable == true, invalid.label)
          assert(queryCount == ${expectedQueries}, invalid.label)
          if ${JSON.stringify(resource)} == 'synex_groups' then
            assert(captured == nil, invalid.label)
          else
            assert(captured.operation == ${JSON.stringify(operation)}, invalid.label)
            assert(captured.traceId == 'query-result-test', invalid.label)
          end
        end
        return 'fail-closed'
      `);
      assert.equal(result, 'fail-closed');
    } finally {
      engine.global.close();
    }
  });
}
