import assert from 'node:assert/strict';
import test from 'node:test';

import {
  parseBenchmarkBaseline,
  runDeterministicBenchmark,
} from '../../tools/cli/src/benchmark.ts';
import { runWorldLuaBenchmark } from '../../tools/cli/src/world-benchmark-runner.ts';

const worldMeasurements = [
  'world_query_at',
  'world_query_nearby_10m',
  'world_query_nearby_100m',
  'world_context_resolve',
  'world_anchor_resolve',
  'world_door_resolve',
  'world_access_check',
] as const;

test('World microbenchmark executes every planned Lua path at the fixed scale', async () => {
  const report = await runWorldLuaBenchmark(2, 2, 0x5a17);
  assert.deepEqual(report.fixture, {
    anchors: 50_000,
    zones: 10_000,
    doors: 5_000,
    locations: 1_000,
    total: 66_000,
  });
  assert.ok(Number.isInteger(report.checksum) && report.checksum > 0);
  assert.deepEqual(Object.keys(report.measurements).sort(), [...worldMeasurements].sort());
  for (const name of worldMeasurements) {
    const measurement = report.measurements[name];
    assert.ok(measurement, name);
    assert.equal(measurement.samplesMilliseconds.length, 2, name);
    assert.equal(measurement.samplesMilliseconds.every((value) =>
      Number.isFinite(value) && value >= 0), true, name);
    assert.ok(Number.isInteger(measurement.checksum), name);
  }
});

test('benchmark suite exposes World measurements and preserves their baseline execution type', () => {
  const report = runDeterministicBenchmark(1);
  assert.equal(report.suiteVersion, 8);
  for (const name of worldMeasurements) {
    const measurement = report.benchmarks[name];
    assert.ok(measurement, name);
    assert.equal(measurement.execution, 'synex_world_lua', name);
    assert.match(measurement.workload, /66000|66,000|compiled|Access\.check/u, name);
  }
  assert.match(report.disclaimer, /World measurements/u);
  assert.match(report.disclaimer, /50,000 Anchors/u);
  assert.match(report.disclaimer, /exclude FXServer scheduling/u);
  assert.match(report.disclaimer, /OneSync scope\/replication/u);
  assert.match(report.disclaimer, /MariaDB I\/O\/locking/u);
  assert.match(report.disclaimer, /production concurrency/u);

  const baseline = parseBenchmarkBaseline(report);
  assert.ok(baseline);
  assert.equal(baseline.suiteVersion, 8);
  assert.equal(baseline.benchmarks.world_query_at?.execution, 'synex_world_lua');
});

test('World benchmark runner rejects malformed or unbounded parameters', async () => {
  await assert.rejects(runWorldLuaBenchmark(0, 1, 1), /outside supported bounds/u);
  await assert.rejects(runWorldLuaBenchmark(5_001, 1, 1), /outside supported bounds/u);
  await assert.rejects(runWorldLuaBenchmark(1, 21, 1), /outside supported bounds/u);
  await assert.rejects(runWorldLuaBenchmark(1, 1, -1), /outside supported bounds/u);
});
