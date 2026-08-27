import assert from "node:assert/strict";
import test from "node:test";

import { runBridgeLuaBenchmark } from "../../tools/cli/src/bridge-benchmark-runner.ts";

const workloads = [
  "bridge_projection_copy",
  "bridge_callback_argument_validation",
  "bridge_account_mapping_resolve",
  "bridge_surface_resolve",
  "bridge_telemetry_record",
] as const;

test("bridge microbenchmark executes real bounded kernel paths with deterministic fixtures", async () => {
  const report = await runBridgeLuaBenchmark(5, 2, 0x5a17);
  assert.equal(report.checksum, 1_876_980);
  assert.deepEqual(Object.keys(report.measurements).sort(), [...workloads].sort());
  const expectedChecksums: Record<(typeof workloads)[number], number> = {
    bridge_projection_copy: 1_875_165,
    bridge_callback_argument_validation: 1_170,
    bridge_account_mapping_resolve: 195,
    bridge_surface_resolve: 435,
    bridge_telemetry_record: 15,
  };
  for (const name of workloads) {
    const measurement = report.measurements[name];
    assert.ok(measurement);
    assert.equal(measurement.checksum, expectedChecksums[name]);
    assert.equal(measurement.samplesMilliseconds.length, 2);
    assert.equal(measurement.samplesMilliseconds.every((value) =>
      Number.isFinite(value) && value >= 0), true);
  }
});

test("bridge microbenchmark rejects unbounded and malformed runner parameters", async () => {
  await assert.rejects(runBridgeLuaBenchmark(0, 5, 1), /outside supported bounds/u);
  await assert.rejects(runBridgeLuaBenchmark(100_001, 5, 1), /outside supported bounds/u);
  await assert.rejects(runBridgeLuaBenchmark(1, 0, 1), /outside supported bounds/u);
  await assert.rejects(runBridgeLuaBenchmark(1, 21, 1), /outside supported bounds/u);
  await assert.rejects(runBridgeLuaBenchmark(1, 5, -1), /outside supported bounds/u);
});
