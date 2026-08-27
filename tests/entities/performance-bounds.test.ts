import assert from 'node:assert/strict';
import test from 'node:test';

import { runDeterministicBenchmark } from '../../tools/cli/src/benchmark.ts';
import { runEntitiesLuaBenchmark } from '../../tools/cli/src/entities-benchmark-runner.ts';

const required = [
  'entities_entity_ref_lookup',
  'entities_net_id_resolve',
  'entities_binding_lookup',
  'entities_owner_lookup',
  'entities_spawn_validation',
  'entities_state_lookup',
  'entities_bucket_lookup',
  'entities_nearby_query',
] as const;

test('Entity runner rejects parameters outside its deterministic safety bounds', async () => {
  await assert.rejects(runEntitiesLuaBenchmark(0, 5, 1), /outside supported bounds/u);
  await assert.rejects(runEntitiesLuaBenchmark(1, 21, 1), /outside supported bounds/u);
  await assert.rejects(runEntitiesLuaBenchmark(1, 5, -1), /outside supported bounds/u);
});

test('deterministic benchmark executes every required Entity hot path without runtime claims', () => {
  const report = runDeterministicBenchmark(10);
  assert.equal(report.suiteVersion, 7);
  for (const name of required) {
    const measurement = report.benchmarks[name];
    assert.ok(measurement, name);
    assert.equal(measurement.execution, 'synex_entities_lua', name);
    assert.match(measurement.workload, /Actual synex_entities/u, name);
    assert.equal(measurement.samplesMilliseconds.length, report.samples, name);
    assert.ok(measurement.operationsPerSecond > 0, name);
  }
  assert.match(report.disclaimer, /embedded Wasmoon VM/u);
  assert.match(report.disclaimer, /exclude FXServer scheduling, FiveM natives, OneSync entity creation/u);
  assert.match(report.disclaimer, /MariaDB I\/O/u);
  assert.match(report.disclaimer, /not a FiveM runtime or production performance claim/u);
});
