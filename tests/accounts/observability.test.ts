import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import luaparse from 'luaparse';
import { LuaFactory, type LuaEngine } from 'wasmoon';

const root = process.cwd();
const observabilityPath = path.join(
  root,
  'resources',
  'synex_accounts',
  'server',
  'persistence',
  'observability.lua',
);
const observabilityControlPath = path.join(
  root,
  'resources',
  'synex_accounts',
  'server',
  'persistence',
  'observability_control.lua',
);
const observabilityInspectPath = path.join(
  root,
  'resources',
  'synex_accounts',
  'server',
  'persistence',
  'observability_inspect.lua',
);
const observabilityPaths = [
  observabilityPath,
  observabilityControlPath,
  observabilityInspectPath,
];

async function bootstrap(engine: LuaEngine): Promise<void> {
  const [foundation, observability, control, inspect] = await Promise.all([
    readFile(path.join(
      root,
      'resources',
      'synex_accounts',
      'server',
      'foundation.lua',
    ), 'utf8'),
    ...observabilityPaths.map((modulePath) => readFile(modulePath, 'utf8')),
  ]);
  await engine.doString(`
    Foundation = assert(load(${JSON.stringify(foundation)}, '@server/foundation.lua'))()
    package.preload['server.persistence.observability_control'] = assert(load(
      ${JSON.stringify(control)}, '@server/persistence/observability_control.lua'))
    package.preload['server.persistence.observability_inspect'] = assert(load(
      ${JSON.stringify(inspect)}, '@server/persistence/observability_inspect.lua'))
    InstallObservability = assert(load(${JSON.stringify(observability)},
      '@server/persistence/observability.lua'))()
    function observabilityPort(one, many)
      local port = {}
      InstallObservability(port, {
        foundation = Foundation,
        domainError = Foundation.domainError,
        one = one,
        many = many
      })
      return port
    end
  `);
}

test('Accounts observability is valid Lua, read-only, bounded, and multi-leg aware', async () => {
  const sources = await Promise.all(
    observabilityPaths.map((modulePath) => readFile(modulePath, 'utf8')),
  );
  for (const moduleSource of sources) {
    assert.doesNotThrow(() => luaparse.parse(moduleSource, { luaVersion: '5.3' }));
  }
  const source = sources.join('\n');
  assert.doesNotMatch(source, /\b(?:INSERT|UPDATE|DELETE|REPLACE|ALTER|DROP|CREATE)\b/iu);
  assert.doesNotMatch(source, /`synex_groups`|`synex_group_[a-z0-9_]+`/u);
  assert.doesNotMatch(source, /synex_ledger_postings/u);
  assert.match(source, /synex_ledger_entries/u);
  assert.match(source, /LIMIT 17/u);
  assert.match(source, /LIMIT 13/u);
  assert.match(source, /LIMIT 9/u);
  assert.match(source, /ROW_NUMBER\(\) OVER \(PARTITION BY `transaction`\.`currency_id`/u);
  assert.match(source, /ATTRIBUTION_LIMIT = 4/u);
  assert.doesNotMatch(source, /LIMIT (?:[2-9]\d|1\d\d)(?!\d)/u);
  assert.match(source, /LIMIT 1001/u);
  assert.match(source, /interval = '1 DAY'/u);
  assert.match(source, /interval = '7 DAY'/u);
  assert.match(source, /interval = '30 DAY'/u);
  for (const method of [
    'getAccountsControlSummary',
    'doctorAccounts',
    'inspectTransaction',
    'inspectAccount',
    'getOperationalMetrics',
  ]) {
    assert.match(source, new RegExp(`function port:${method}\\b`, 'u'));
  }

  const inspectorStart = source.indexOf('function port:inspectTransaction');
  assert.notEqual(inspectorStart, -1);
  const inspectors = source.slice(inspectorStart);
  assert.doesNotMatch(
    inspectors,
    /`(?:payload_json|metadata_json|snapshot_json|response_json|request_fingerprint)`/u,
  );
});

test('observability registers only server-local port functions and validates public UUIDs first', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`
      local reads = 0
      local port = observabilityPort(
        function() reads = reads + 1 return nil end,
        function() reads = reads + 1 return {} end)
      assert(type(port.getAccountsControlSummary) == 'function')
      assert(type(port.getControlSummaryV3) == 'function')
      assert(type(port.doctorAccounts) == 'function')
      assert(type(port.inspectTransaction) == 'function')
      assert(type(port.inspectAccount) == 'function')
      assert(type(port.getOperationalMetrics) == 'function')
      local transaction, transactionError = port:inspectTransaction('not-a-uuid')
      local account, accountError = port:inspectAccount('not-a-uuid')
      assert(transaction == nil and transactionError.code == 'VALIDATION_FAILED')
      assert(account == nil and accountError.code == 'VALIDATION_FAILED')
      assert(reads == 0)
      return transactionError.code .. ':' .. accountError.code
    `);
    assert.equal(result, 'VALIDATION_FAILED:VALIDATION_FAILED');
  } finally {
    engine.global.close();
  }
});

test('operational metrics preserve exact decimal integers outside JavaScript safe range', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`
      local port = observabilityPort(function(sql)
        assert(sql:find('holds_active', 1, true))
        return {
          holds_active = '00000000000000000012', holds_expired = '3',
          outbox_pending = '90071992547409921234', outbox_publishing = '4',
          outbox_dead = '5', reconciliation_findings = '70000000000000000001'
        }
      end, function() error('metrics must not issue list reads') end)
      local value, failure = port:getOperationalMetrics()
      assert(failure == nil)
      assert(value.holds_active == '12')
      assert(value.outbox_pending == '90071992547409921234')
      assert(value.reconciliation_findings == '70000000000000000001')
      return value.holds_active .. ':' .. value.outbox_pending .. ':'
        .. value.reconciliation_findings
    `);
    assert.equal(result, '12:90071992547409921234:70000000000000000001');
  } finally {
    engine.global.close();
  }
});

test('Accounts doctor reports every fixed check without repair and caps issue evidence', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`
      local reads = 0
      local port = observabilityPort(function(sql)
        reads = reads + 1
        if sql:find('HAVING COUNT', 1, true) then return { count = '1001' } end
        if sql:find('synex_account_outbox', 1, true)
            and sql:find("'dead' LIMIT 1001", 1, true) then
          return { count = '0002' }
        end
        return { count = '0' }
      end, function() error('doctor must use one-row aggregate checks') end)
      local value, failure = port:doctorAccounts()
      assert(failure == nil and value.status == 'FAIL')
      assert(value.repair_performed == false and #value.checks >= 15)
      assert(reads == #value.checks)
      local ledger, dead
      for _, check in ipairs(value.checks) do
        if check.key == 'ledger_zero_sum' then ledger = check end
        if check.key == 'outbox_dead' then dead = check end
      end
      assert(ledger.status == 'FAIL' and ledger.count == '1000'
        and ledger.truncated == true)
      assert(dead.status == 'WARN' and dead.count == '2'
        and dead.truncated == false)
      return value.status .. ':' .. tostring(#value.checks) .. ':' .. ledger.count
    `);
    assert.match(String(result), /^FAIL:\d+:1000$/u);
  } finally {
    engine.global.close();
  }
});

test('control summary keeps 24h, 7d, and 30d economy aggregates separated by currency', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`
      local port = observabilityPort(function(sql)
        if sql:find('DATE_FORMAT(UTC_TIMESTAMP(6)', 1, true) then
          return { generated_at = '2026-08-26T02:00:00.000000Z' }
        end
        if sql:find('active_holds', 1, true) and sql:find('active_grants', 1, true) then
          return { currencies = '2', accounts = '90071992547409921234',
            transactions = '4', entries = '12', active_holds = '1',
            active_grants = '2', reconciliations = '3', anomalies = '0' }
        end
        if sql:find('zero_sum_violations', 1, true) then
          return { transaction_count = '4', entry_count = '12', entry_sum_minor = '0',
            credit_minor = '800', debit_minor = '800', zero_sum_violations = '0' }
        end
        if sql:find('expired_active_grants', 1, true) then
          return { roles = '3', expired_active_grants = '0', active_restrictions = '1' }
        end
        if sql:find('oldest_pending_at', 1, true) then
          return { pending = '1', publishing = '0', published = '8', dead = '0',
            attempts = '9', oldest_pending_at = '2026-08-26T01:59:00.000000Z' }
        end
        error('unexpected control summary aggregate query')
      end, function(sql)
        if sql:find('net_inflation_minor', 1, true) then
          return {
            { currency_id = '22222222-2222-4222-8222-222222222222',
              currency_code = 'credits', minor_unit = 2,
              transaction_count = '2', entry_count = '6',
              transaction_volume_minor = '350', sources_minor = '100',
              sinks_minor = '40', net_inflation_minor = '60' },
            { currency_id = '55555555-5555-4555-8555-555555555555',
              currency_code = 'tokens', minor_unit = 0,
              transaction_count = '3', entry_count = '8',
              transaction_volume_minor = '200', sources_minor = '20',
              sinks_minor = '10', net_inflation_minor = '10' }
          }
        end
        if sql:find('attribution_rank', 1, true)
            and sql:find('reason_code', 1, true) then
          return {
            { currency_id = '22222222-2222-4222-8222-222222222222',
              reason_code = 'synex_test.sale', transaction_count = '2',
              volume_minor = '350', attribution_rank = 1 },
            { currency_id = '22222222-2222-4222-8222-222222222222',
              reason_code = 'synex_test.overflow', transaction_count = '1',
              volume_minor = '1', attribution_rank = 5 },
            { currency_id = '55555555-5555-4555-8555-555555555555',
              reason_code = 'synex_test.reward', transaction_count = '3',
              volume_minor = '200', attribution_rank = 1 }
          }
        end
        if sql:find('attribution_rank', 1, true)
            and sql:find('source_resource', 1, true) then
          return {
            { currency_id = '22222222-2222-4222-8222-222222222222',
              source_resource = 'synex_shops', transaction_count = '2',
              volume_minor = '350', attribution_rank = 1 },
            { currency_id = '55555555-5555-4555-8555-555555555555',
              source_resource = 'synex_jobs', transaction_count = '3',
              volume_minor = '200', attribution_rank = 1 }
          }
        end
        if sql:find('precision_locked_at', 1, true) then
          return {{ currency_id = '22222222-2222-4222-8222-222222222222',
            currency_code = 'credits', display_name = 'Credits', minor_unit = 2,
            status = 'active', topology_state = 'ready',
            mint_account_id = '33333333-3333-4333-8333-333333333333',
            burn_account_id = '44444444-4444-4444-8444-444444444444',
            integrity_status = 'healthy', model_version = '7', finding_count = '0' }}
        end
        if sql:find("'status' AS", 1, true) then return {} end
        if sql:find('transaction_kind', 1, true)
            and sql:find('GROUP BY', 1, true) then return {} end
        if sql:find('synex_account_holds', 1, true)
            and sql:find('GROUP BY', 1, true) then return {} end
        if sql:find('principal_kind', 1, true)
            and sql:find('GROUP BY', 1, true) then return {} end
        if sql:find('synex_economy_integrity_read_models', 1, true) then return {} end
        if sql:find('synex_economy_anomaly_findings', 1, true) then return {} end
        if sql:find('synex_economy_reconciliation_runs', 1, true) then return {} end
        if sql:find('reason_code', 1, true)
            and sql:find('GROUP BY', 1, true) then return {} end
        if sql:find('source_resource', 1, true)
            and sql:find('GROUP BY', 1, true) then return {} end
        error('unexpected control summary list query')
      end)
      local value, failure = port:getAccountsControlSummary()
      assert(failure == nil and value.service == 'synex.accounts')
      assert(value.overview.accounts == '90071992547409921234')
      assert(value.ledger.entry_sum_minor == '0' and value.outbox.pending == '1')
      assert(#value.currencies.items == 1 and value.currencies.items[1].model_version == '7')
      assert(#value.economy.periods == 3)
      assert(value.economy.periods[1].period == '24h')
      assert(value.economy.periods[2].period == '7d')
      assert(value.economy.periods[3].period == '30d')
      for _, period in ipairs(value.economy.periods) do
        assert(period.transaction_volume_minor == nil)
        assert(#period.currencies.items == 2 and period.currencies.truncated == false)
        local byCode = {}
        for _, currency in ipairs(period.currencies.items) do
          byCode[currency.currency_code] = currency
        end
        assert(byCode.credits.transaction_volume_minor == '350')
        assert(byCode.credits.net_inflation_minor == '60')
        assert(byCode.tokens.transaction_volume_minor == '200')
        assert(byCode.tokens.net_inflation_minor == '10')
        assert(byCode.credits.reason_codes.items[1].reason_code == 'synex_test.sale')
        assert(byCode.credits.reason_codes.truncated == true)
        assert(byCode.tokens.reason_codes.items[1].reason_code == 'synex_test.reward')
        assert(byCode.credits.resources.items[1].source_resource == 'synex_shops')
        assert(byCode.tokens.resources.items[1].source_resource == 'synex_jobs')
      end
      assert(value.accounts and value.transactions and value.holds and value.access)
      assert(value.integrity and value.reconciliation and value.anomalies)
      return value.overview.accounts .. ':' .. table.concat({
        value.economy.periods[1].period, value.economy.periods[2].period,
        value.economy.periods[3].period }, ',')
    `);
    assert.equal(result, '90071992547409921234:24h,7d,30d');
  } finally {
    engine.global.close();
  }
});

test('transaction inspector returns bounded metadata-only multi-leg evidence', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`
      local transactionId = '11111111-1111-4111-8111-111111111111'
      local function rows(count, factory)
        local output = {}
        for index = 1, count do output[index] = factory(index) end
        return output
      end
      local port = observabilityPort(function(sql, parameters)
        assert(sql:find('synex_ledger_transactions', 1, true))
        assert(parameters[1] == transactionId)
        return {
          transaction_id = transactionId,
          currency_id = '22222222-2222-4222-8222-222222222222',
          currency_code = 'credits', minor_unit = 2, transaction_kind = 'post',
          posting_model = 'multi_leg', entry_count = '16', status = 'posted',
          reason_code = 'synex_test.payment', source_resource = 'synex_test',
          trace_id = 'trace_accounts_0001', actor_kind = 'resource',
          actor_ref = 'synex_test', operation_name = 'post',
          caller_resource = 'synex_test', caller_principal_kind = 'resource',
          caller_principal_ref = 'synex_test',
          occurred_at = '2026-08-26T01:00:00.000000Z',
          posted_at = '2026-08-26T01:00:00.000000Z'
        }
      end, function(sql)
        if sql:find('synex_ledger_entries', 1, true) then
          return rows(17, function(index) return {
            entry_id = ('entry-%02d'):format(index), sequence = tostring(index),
            account_id = ('account-%02d'):format(index), account_role = 'asset',
            owner_kind = 'group', owner_ref = 'group_alpha_0001',
            amount_minor = index == 1 and '-160' or '10',
            created_at = '2026-08-26T01:00:00.000000Z'
          } end)
        end
        if sql:find('synex_ledger_reversals', 1, true) then return {} end
        if sql:find('synex_ledger_refunds', 1, true) then
          return rows(17, function(index) return {
            refund_id = ('refund-%02d'):format(index),
            original_transaction_id = transactionId,
            refund_transaction_id = ('refund-tx-%02d'):format(index),
            sequence = tostring(index), amount_minor = '1',
            cumulative_refunded_minor = tostring(index),
            reason_code = 'synex_accounts.refund',
            created_at = '2026-08-26T01:00:00.000000Z'
          } end)
        end
        if sql:find('synex_account_outbox', 1, true) then
          return rows(17, function(index) return {
            event_id = ('event-%02d'):format(index), event_type = 'transaction.posted',
            state = 'published', attempts = '1',
            created_at = '2026-08-26T01:00:00.000000Z',
            published_at = '2026-08-26T01:00:01.000000Z'
          } end)
        end
        error('unexpected transaction inspector query')
      end)
      local value, failure = port:inspectTransaction(transactionId)
      assert(failure == nil and value.transaction.entry_count == '16')
      assert(#value.entries.items == 16 and value.entries.truncated == true)
      assert(value.entries.items[1].amount_minor == '-160')
      assert(#value.refunds.items == 16 and value.refunds.truncated == true)
      assert(#value.outbox.items == 16 and value.outbox.truncated == true)
      assert(value.transaction.metadata_json == nil and value.transaction.response_json == nil)
      return table.concat({ #value.entries.items, #value.refunds.items,
        #value.outbox.items, value.entries.items[1].amount_minor }, ':')
    `);
    assert.equal(result, '16:16:16:-160');
  } finally {
    engine.global.close();
  }
});

test('account inspector computes an exact available balance and bounds recent activity', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`
      local accountId = '33333333-3333-4333-8333-333333333333'
      local function rows(count, factory)
        local output = {}
        for index = 1, count do output[index] = factory(index) end
        return output
      end
      local port = observabilityPort(function(_, parameters)
        assert(parameters[1] == accountId)
        return {
          account_id = accountId, account_key = 'group_treasury', account_role = 'asset',
          status = 'active', owner_kind = 'group', owner_ref = 'group_alpha_0001',
          currency_id = '22222222-2222-4222-8222-222222222222',
          currency_code = 'credits', minor_unit = 2, version = '9',
          snapshot_sequence = '20', booked_minor = '90071992547409910000',
          held_minor = '40000000000000000000',
          available_minor = '50071992547409910000', active_access_count = '3',
          active_restriction_count = '1',
          created_at = '2026-08-26T01:00:00.000000Z',
          updated_at = '2026-08-26T01:01:00.000000Z',
          snapshot_created_at = '2026-08-26T01:01:00.000000Z'
        }
      end, function(sql)
        if sql:find('recent', 1, true) then error('query labels must not be required') end
        if sql:find('synex_ledger_entries', 1, true) then
          return rows(17, function(index) return {
            transaction_id = ('transaction-%02d'):format(index),
            transaction_kind = 'post', reason_code = 'synex_test.payment',
            source_resource = 'synex_test', trace_id = 'trace_accounts_0001',
            entry_sequence = '1', amount_minor = index == 1 and '-50' or '10',
            occurred_at = '2026-08-26T01:00:00.000000Z'
          } end)
        end
        if sql:find('synex_account_holds', 1, true) then
          return rows(17, function(index) return {
            hold_id = ('hold-%02d'):format(index),
            capture_account_id = 'capture-account', state = 'active',
            capture_policy = 'multiple', amount_minor = '100', captured_minor = '20',
            released_minor = '0', remaining_minor = '80',
            expires_at = '2026-08-27T01:00:00.000000Z'
          } end)
        end
        error('unexpected account inspector query')
      end)
      local value, failure = port:inspectAccount(accountId)
      assert(failure == nil)
      assert(value.account.booked_minor == '90071992547409910000')
      assert(value.account.available_minor == '50071992547409910000')
      assert(#value.recent_activity.items == 16 and value.recent_activity.truncated == true)
      assert(#value.active_holds.items == 16 and value.active_holds.truncated == true)
      assert(value.account.metadata_json == nil)
      return value.account.available_minor .. ':' .. #value.recent_activity.items
    `);
    assert.equal(result, '50071992547409910000:16');
  } finally {
    engine.global.close();
  }
});
