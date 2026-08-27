import assert from 'node:assert/strict';
import test from 'node:test';

import { runDeterministicBenchmark } from '../../tools/cli/src/benchmark.ts';

test('deterministic benchmark executes every required Accounts hot path without production claims', () => {
  const report = runDeterministicBenchmark(10);
  const required = [
    'accounts_balance_lookup',
    'accounts_available_balance_lookup',
    'accounts_access_check',
    'accounts_transfer',
    'accounts_multileg_post',
    'accounts_hold_create',
    'accounts_hold_capture',
    'accounts_reconciliation_query',
  ];
  for (const name of required) {
    const measurement = report.benchmarks[name];
    assert.ok(measurement, name);
    assert.equal(measurement.execution, 'synex_accounts_lua', name);
    assert.match(measurement.workload, /Actual synex_accounts/u, name);
    assert.equal(measurement.samplesMilliseconds.length, report.samples, name);
    assert.ok(measurement.operationsPerSecond > 0, name);
  }
  assert.match(report.disclaimer, /deterministic in-memory adapters/u);
  assert.match(report.disclaimer, /exclude FXServer, Cfx networking, and MariaDB I\/O/u);
  assert.match(report.disclaimer, /not a FiveM runtime or production performance claim/u);
});
