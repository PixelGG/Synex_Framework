import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';
import { accountsRoot, bootstrapDomain, preload } from './helpers.js';

async function source(relative: string): Promise<string> {
  return readFile(path.resolve(relative), 'utf8');
}

test('Accounts observability is composed into the server-only runtime and operator service', async () => {
  const [manifest, main, operatorAdapter, persistence, resource] = await Promise.all([
    source('resources/synex_accounts/fxmanifest.lua'),
    source('resources/synex_accounts/server/main.lua'),
    source('resources/synex_accounts/server/operator_adapter.lua'),
    source('resources/synex_accounts/server/persistence.lua'),
    source('resources/synex_accounts/synex.resource.json'),
  ]);

  assert.match(manifest, /server_only 'yes'/u);
  assert.doesNotMatch(manifest, /client_scripts?|ui_page/u);
  assert.match(manifest, /server\/operator_adapter\.lua/u);
  assert.match(manifest, /server\/persistence\/observability\.lua/u);
  assert.match(main, /observability = require 'server\.persistence\.observability'/u);
  assert.match(persistence, /modules\.observability\(port, context\)/u);
  for (const method of [
    'doctor',
    'inspect_transaction',
    'inspect_account',
    'inspect_outbox',
    'outbox_retry',
  ]) {
    assert.match(operatorAdapter, new RegExp(`${method} = function`, 'u'));
  }
  assert.match(main, /capabilities\[methodName\] = capabilities\[methodName\][\s\S]*?or 'synex\.accounts\.integrity\.read'/u);
  assert.match(operatorAdapter, /requestedByResource = authority\.callerResource/u);
  assert.match(operatorAdapter, /requestedByRef = authority\.principalRef/u);
  assert.match(operatorAdapter, /action = 'accounts\.outbox_retry'/u);
  assert.match(resource, /synex\.accounts\.before_hold_capture/u);
});

test('the extracted operator adapter preserves authoritative reads and retry attribution', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrapDomain(engine);
    await preload(
      engine,
      'server.operator_adapter',
      'resources/synex_accounts/server/operator_adapter.lua',
    );
    const result = await engine.doString(`
      local retried, audited
      local methods = require('server.operator_adapter')(Foundation, Domain)({
        database = {
          doctorAccounts = function() return { status = 'healthy' }, nil end,
        },
        outboxDispatcher = {
          requestRetry = function(_, command)
            retried = command
            return {
              retryRequestId = '33333333-3333-4333-8333-333333333333',
              eventId = command.eventId,
              replayed = false,
            }, nil
          end,
        },
        coreAudit = {
          append = function(entry) audited = entry return true, nil end,
        },
        runtimeErrorSink = function() error('unexpected runtime error') end,
      })
      local context = {
        caller = 'synex_core', callerEpoch = 2, traceId = 'trace_operator_01'
      }
      local health = assert(methods.doctor({}, context))
      assert(health.status == 'healthy')
      local response = assert(methods.outbox_retry({
        idempotency_key = '11111111-1111-4111-8111-111111111111',
        event_id = '22222222-2222-4222-8222-222222222222',
        reason = 'operator-reviewed-manual-retry',
        actor_kind = 'system',
        actor_ref = 'synex_core',
      }, context))
      assert(response.accepted == true and response.replayed == false)
      assert(retried.requestedByResource == 'synex_core')
      assert(retried.requestedByRef == 'synex_core')
      assert(audited.action == 'accounts.outbox_retry')
      local rejected, rejection = methods.doctor({}, {
        caller = 'synex_core', callerEpoch = 0, traceId = 'trace_operator_02'
      })
      assert(rejected == nil and rejection.code == 'CALLER_CONTEXT_INVALID')
      return response.retry_request_id .. ':' .. response.event_id
    `);
    assert.equal(
      result,
      '33333333-3333-4333-8333-333333333333:22222222-2222-4222-8222-222222222222',
    );
  } finally {
    engine.global.close();
  }
});

test('operational metrics expose bounded financial health without a RAM balance truth', async () => {
  const [main, observability] = await Promise.all([
    source('resources/synex_accounts/server/main.lua'),
    source('resources/synex_accounts/server/persistence/observability.lua'),
  ]);
  for (const metric of [
    'synex_accounts_holds_active',
    'synex_accounts_holds_expired_pending',
    'synex_accounts_outbox_pending',
    'synex_accounts_outbox_dead',
    'synex_accounts_reconciliation_findings',
  ]) assert.ok(main.includes(metric), metric);
  assert.match(observability, /function port:getOperationalMetrics\(\)/u);
  assert.match(observability, /FROM `synex_account_holds`/u);
  assert.match(observability, /FROM `synex_account_outbox`/u);
  assert.doesNotMatch(main, /balanceCache|cachedBalance/u);
});

test('database retries are limited to classified deadlocks and lock timeouts', async () => {
  const [persistence, engine, lifecycle, lifecycleGroups] = await Promise.all([
    source('resources/synex_accounts/server/persistence.lua'),
    source('resources/synex_accounts/server/persistence/engine_shared.lua'),
    source('resources/synex_accounts/server/persistence/lifecycle.lua'),
    source('resources/synex_accounts/server/persistence/lifecycle_groups.lua'),
  ]);
  assert.match(persistence, /detail:find\('1213'/u);
  assert.match(persistence, /detail:find\('40001'/u);
  assert.match(persistence, /detail:find\('1205'/u);
  assert.match(persistence, /failureKind == 'deadlock' or failureKind == 'lock_timeout'/u);
  assert.match(persistence, /code = failureKind == 'deadlock'[\s\S]*?'DATABASE_DEADLOCK'[\s\S]*?'DATABASE_LOCK_TIMEOUT'/u);
  assert.match(engine, /failureKind == 'deadlock' or failureKind == 'lock_timeout'/u);
  assert.equal(((`${lifecycle}\n${lifecycleGroups}`).match(
    /failureKind == 'deadlock'/gu,
  ) ?? []).length, 2);
});

test('deadlock and lock-timeout retries are bounded while unclassified failures fail once', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrapDomain(engine);
    await preload(
      engine,
      'server.persistence',
      'resources/synex_accounts/server/persistence.lua',
    );
    const result = await engine.doString(`
      local capturedContext
      local function noOp() end
      local modules = {
        accounts = function(_, context) capturedContext = context end,
        ledger = noOp, holds = noOp, access = noOp, integrity = noOp,
      }
      local metrics, failures, waits = {}, {}, 0
      local portFactory = require('server.persistence')(Foundation, modules)
      local function runtime()
        return portFactory({
          jsonEncode = function() return '{}' end,
          jsonDecode = function() return {} end,
          random = function() return 1 end,
          wait = function() waits = waits + 1 end,
          metrics = {
            increment = function(name)
              metrics[name] = (metrics[name] or 0) + 1
              return true
            end,
          },
          errorSink = function(event)
            failures[#failures + 1] = event.code .. ':' .. event.traceId
          end,
        })
      end

      local attempts = 0
      MySQL = { startTransaction = function(callback)
        attempts = attempts + 1
        if attempts < 3 then error('1213 Deadlock found; SQLSTATE 40001') end
        return callback(function() return {} end)
      end }
      runtime()
      local committed = assert(capturedContext.withRetriableTransaction(
        function() return true end,
        { maximumAttempts = 3, traceId = 'trace_deadlock_01' }))
      assert(committed and attempts == 3)

      local timeoutAttempts = 0
      MySQL.startTransaction = function(callback)
        timeoutAttempts = timeoutAttempts + 1
        if timeoutAttempts == 1 then error('1205 Lock wait timeout exceeded') end
        return callback(function() return {} end)
      end
      runtime()
      assert(capturedContext.withRetriableTransaction(
        function() return true end,
        { maximumAttempts = 3, traceId = 'trace_timeout_01' }))
      assert(timeoutAttempts == 2)

      local genericAttempts = 0
      MySQL.startTransaction = function()
        genericAttempts = genericAttempts + 1
        error('connection transport failed')
      end
      runtime()
      local rejected, rejection = capturedContext.withRetriableTransaction(
        function() return true end,
        { maximumAttempts = 3, traceId = 'trace_generic_01' })
      assert(rejected == nil and rejection.code == 'WRITE_CONFLICT')
      assert(genericAttempts == 1)
      return table.concat({
        attempts, timeoutAttempts, genericAttempts, waits,
        metrics.synex_accounts_deadlocks_total or 0,
        metrics.synex_accounts_lock_timeouts_total or 0,
        metrics.synex_accounts_retries_total or 0,
        #failures,
      }, ':')
    `);
    assert.equal(result, '3:2:1:3:2:1:3:3');
  } finally {
    engine.global.close();
  }
});

test('Core CLI owns explicit reconciliation while Control exposes only Accounts provider reads', async () => {
  const [commands, control, provider, descriptorSource, web] = await Promise.all([
    source('core/synex_core/server/commands.lua'),
    source('resources/synex_control/server/server.lua'),
    source('resources/synex_accounts/server/control_provider.lua'),
    source('resources/synex_accounts/synex.resource.json'),
    source('resources/synex_control/web/app.js'),
  ]);
  const descriptor = JSON.parse(descriptorSource) as {
    controlProvider: { operations: string[]; views: Array<{ id: string }> };
  };
  for (const operation of [
    "'get_control_summary'",
    "'inspect_transaction'",
    "'inspect_account'",
    "'inspect_outbox'",
    "'integrity_reconcile'",
    "'outbox_retry'",
  ]) assert.ok(commands.includes(operation), operation);
  assert.match(provider, /candidate\.view == 'transaction'[\s\S]*?'inspect_transaction'/u);
  assert.match(provider, /candidate\.view == 'account'[\s\S]*?'inspect_account'/u);
  for (const section of [
    'accounts', 'transactions', 'holds', 'integrity', 'anomalies', 'economy', 'outbox',
  ]) {
    assert.ok(descriptor.controlProvider.views.some((view) => view.id === section), section);
  }
  assert.match(control, /ControlProviders/u);
  assert.match(web, /snapshot\.providers/u);
  assert.doesNotMatch(`${control}\n${provider}`, /set_balance|edit_balance|delete_transaction/iu);
  assert.doesNotMatch(provider, /handlers\.(?:create|delete|mutate|reconcile|retry|update|write)\s*=/iu);
  assert.deepEqual(descriptor.controlProvider.operations, [
    'summary', 'health', 'list', 'inspect', 'search', 'metrics', 'findings',
  ]);
});

test('the Accounts runtime references the actual resource root used by focused tests', async () => {
  assert.equal(accountsRoot.endsWith(path.join('resources', 'synex_accounts')), true);
});
