import assert from 'node:assert/strict';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';
import { bootstrapDomain, preload } from './helpers.js';

test('reconciliation emits bounded behavioral findings without corrective account writes', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrapDomain(engine);
    await preload(
      engine,
      'server.persistence.integrity_behavior',
      'resources/synex_accounts/server/persistence/integrity_behavior.lua',
    );
    await preload(
      engine,
      'server.persistence.integrity_v2',
      'resources/synex_accounts/server/persistence/integrity_v2.lua',
    );
    const result = await engine.doString(`
      local persistedRules, emittedEvents, accountWrites = {}, {}, 0
      local currency = {
        id = 7,
        public_id = '11111111-1111-4111-8111-111111111111',
        currency_code = 'credits',
      }
      local summary = {
        cutoff_transaction_id = 100, cutoff_entry_id = 200,
        transaction_count = 80, entry_count = 160, account_count = 12,
        total_entry_sum_minor = '0', total_debit_minor = '9000',
        total_credit_minor = '9000', minted_minor = '6000', burned_minor = '1000',
        total_booked_minor = '5000', active_held_minor = '200',
        transaction_sum_violation_count = 0, snapshot_drift_count = 0,
        negative_asset_count = 0, reserved_exceeds_booked_count = 0,
        invalid_hold_count = 0, refund_limit_violation_count = 0,
        invalid_reversal_count = 0, invalid_topology_count = 0,
        outbox_problem_count = 0, grant_problem_count = 0,
        orphan_transaction_count = 0, sequence_problem_count = 0,
        idempotency_problem_count = 0,
      }
      local Engine = {
        mutation = function(_, _, _, handler)
          return handler({}, 91)
        end,
        writeEvent = function(_, _, _, eventType, _, _, payload)
          emittedEvents[#emittedEvents + 1] = { eventType = eventType, payload = payload }
          return true, nil
        end,
      }
      local port = {}
      local context = {
        foundation = Foundation,
        domain = Domain,
        engine = Engine,
        domainError = Foundation.domainError,
        uuidV4 = function() return 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' end,
        random = function() return 1 end,
        one = function() return nil end,
        many = function() return {} end,
        jsonEncode = function() return '{}' end,
        txOne = function(_, sql)
          if sql:find('FROM \`synex_currencies\` WHERE', 1, true)
              and sql:find('FOR UPDATE', 1, true) then return currency end
          if sql:find('cutoff_transaction_id', 1, true)
              and sql:find('idempotency_problem_count', 1, true) then return summary end
          if sql:find('high_transaction_rate_count', 1, true) then
            return {
              high_transaction_rate_count = '1', large_reversal_volume_count = '1',
              high_refund_ratio_count = '1', recent_transaction_count = '80',
              baseline_transaction_count = '100', reversal_transaction_count = '3',
              refund_transaction_count = '4', total_volume_minor = '1000',
              reversal_volume_minor = '300', refund_volume_minor = '260',
            }
          end
          if sql:find('large_mint_count', 1, true) then
            return { large_mint_count = '2', maximum_minor = '10000',
              baseline_sample_count = '10', baseline_average_minor = '500' }
          end
          if sql:find('SELECT \`model_version\`', 1, true) then
            return { model_version = 2 }
          end
          if sql:find('SELECT \`id\` FROM \`synex_economy_reconciliation_runs\`',
              1, true) then return { id = 17 } end
          error('unexpected reconciliation one-row query')
        end,
        txRows = function(_, sql, values)
          if sql:find('resource_activity', 1, true) then
            return {{ source_resource = 'synex_jobs', recent_event_count = '4',
              baseline_event_count = '8', recent_supply_minor = '800',
              baseline_supply_minor = '1000' }}
          end
          if sql:find('INSERT INTO \`synex_economy_anomaly_findings\`', 1, true) then
            persistedRules[#persistedRules + 1] = values[3]
          end
          if sql:find('UPDATE \`synex_accounts\`', 1, true) then
            accountWrites = accountWrites + 1
          end
          return {}
        end,
      }
      context.integrityBehavior = require('server.persistence.integrity_behavior')(context)
      require('server.persistence.integrity_v2')(port, context)

      local value, failure = port:runReconciliationV2({
        currencyCode = 'credits',
        authority = { callerResource = 'synex_control', principalKind = 'resource',
          principalRef = 'synex_control', traceId = 'trace_integrity_01' },
      })
      assert(failure == nil and value.status == 'warn')
      assert(value.finding_count == '5' and value.warn_count == '5')
      assert(#persistedRules == 5 and accountWrites == 0)
      local expected = {
        ['economy.high_refund_ratio'] = true,
        ['economy.large_reversal_volume'] = true,
        ['economy.resource_supply_spike'] = true,
        ['economy.transaction_rate_spike'] = true,
        ['economy.unusually_large_mint'] = true,
      }
      for _, rule in ipairs(persistedRules) do
        assert(expected[rule] == true)
        expected[rule] = nil
      end
      assert(next(expected) == nil)
      for _, event in ipairs(emittedEvents) do
        if event.eventType == 'synex.accounts.integrity.finding' then
          assert(event.payload.severity == 'warn')
          assert(event.payload.action == nil and event.payload.auto_repair == nil)
        end
      end
      return value.status .. ':' .. value.finding_count .. ':' .. tostring(accountWrites)
    `);
    assert.equal(result, 'warn:5:0');
  } finally {
    engine.global.close();
  }
});
