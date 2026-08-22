import { Ajv2020 } from "ajv/dist/2020.js";
import { performance } from "node:perf_hooks";

import { CliError } from "./errors.ts";
import { canonicalJson, compareText, isRecord } from "./filesystem.ts";
import { scanLuaText } from "./security.ts";

const SUITE_VERSION = 2;
const SAMPLE_COUNT = 5;
const REGRESSION_THRESHOLD = 0.25;
const BENCHMARK_SEED = 0x5a17;

export interface BenchmarkMeasurement {
  workload: string;
  medianMilliseconds: number;
  operationsPerSecond: number;
  samplesMilliseconds: number[];
}

export interface BenchmarkReport {
  schema: 1;
  suiteVersion: number;
  status: "PASS" | "WARN";
  runtime: { node: string; platform: string; architecture: string };
  iterations: number;
  samples: number;
  seed: number;
  benchmarks: Record<string, BenchmarkMeasurement>;
  regressions: Array<{ benchmark: string; baselineOps: number; currentOps: number; decreasePercent: number }>;
  baseline: { compared: boolean; reason: string };
  canonicalJson: { milliseconds: number; operationsPerSecond: number };
  luaScan: { milliseconds: number; operationsPerSecond: number };
  checksum: number;
  disclaimer: string;
}

function median(values: number[]): number {
  const sorted = [...values].sort((left, right) => left - right);
  return sorted[Math.floor(sorted.length / 2)] ?? 0;
}

function measure(
  iterations: number,
  workload: string,
  operation: (index: number) => number,
): { measurement: BenchmarkMeasurement; checksum: number } {
  let checksum = 0;
  const warmup = Math.min(iterations, 1_000);
  for (let index = 0; index < warmup; index += 1) checksum = (checksum + operation(index)) >>> 0;
  const samples: number[] = [];
  for (let sample = 0; sample < SAMPLE_COUNT; sample += 1) {
    const started = performance.now();
    for (let index = 0; index < iterations; index += 1) checksum = (checksum + operation(index)) >>> 0;
    samples.push(performance.now() - started);
  }
  const medianMilliseconds = median(samples);
  return {
    measurement: {
      workload,
      medianMilliseconds: Number(medianMilliseconds.toFixed(3)),
      operationsPerSecond: Math.round((iterations / Math.max(medianMilliseconds, 0.001)) * 1_000),
      samplesMilliseconds: samples.map((value) => Number(value.toFixed(3))),
    },
    checksum,
  };
}

function parseBaseline(value: unknown): { suiteVersion: number; iterations: number; runtime: BenchmarkReport["runtime"]; benchmarks: Record<string, BenchmarkMeasurement> } | null {
  if (!isRecord(value) || typeof value.suiteVersion !== "number" || typeof value.iterations !== "number"
    || !isRecord(value.runtime) || !isRecord(value.benchmarks)) return null;
  if (typeof value.runtime.node !== "string" || typeof value.runtime.platform !== "string" || typeof value.runtime.architecture !== "string") return null;
  const benchmarks: Record<string, BenchmarkMeasurement> = {};
  for (const [name, raw] of Object.entries(value.benchmarks)) {
    if (!isRecord(raw) || typeof raw.workload !== "string" || typeof raw.operationsPerSecond !== "number" || typeof raw.medianMilliseconds !== "number"
      || !Array.isArray(raw.samplesMilliseconds)) return null;
    benchmarks[name] = {
      workload: raw.workload,
      operationsPerSecond: raw.operationsPerSecond,
      medianMilliseconds: raw.medianMilliseconds,
      samplesMilliseconds: raw.samplesMilliseconds.filter((entry): entry is number => typeof entry === "number"),
    };
  }
  return {
    suiteVersion: value.suiteVersion,
    iterations: value.iterations,
    runtime: { node: value.runtime.node, platform: value.runtime.platform, architecture: value.runtime.architecture },
    benchmarks,
  };
}

export function runDeterministicBenchmark(iterations = 5_000, rawBaseline?: unknown): BenchmarkReport {
  if (!Number.isInteger(iterations) || iterations < 1 || iterations > 100_000) {
    throw new CliError("Benchmark iterations must be a whole number from 1 to 100000.", 2);
  }
  const registry = new Map(Array.from({ length: 1_024 }, (_, index) => [`resource_${index}`, index]));
  const memberships = new Map(Array.from({ length: 2_048 }, (_, index) => [`character_${index}`, index % 32]));
  const gradeCapabilities = new Map(Array.from({ length: 32 }, (_, index) => [index, new Set([`synex.groups.grade_${index}.read`])]));
  const states = new Map<string, { value: number; revision: number }>();
  const cache = new Map(Array.from({ length: 512 }, (_, index) => [`cache_${index}`, index]));
  const ledgerSlots: Array<{ debit: number; credit: number; sequence: number } | undefined> = Array.from({ length: 1_024 });
  const schemaValidator = new Ajv2020({ allErrors: true, strict: true, validateFormats: false }).compile({
    type: "object",
    additionalProperties: false,
    required: ["request_id", "amount"],
    properties: {
      request_id: { type: "string", minLength: 8, maxLength: 64 },
      amount: { type: "integer", minimum: 1, maximum: 1_000_000 },
    },
  });
  const request = { request_id: "request_00000001", amount: 10 };
  const rpcHandler = (payload: typeof request): number => payload.amount + payload.request_id.length;
  const capabilityMatches = (pattern: string, capability: string): boolean =>
    pattern === capability || pattern === "*" || (pattern.endsWith(".*") && capability.startsWith(pattern.slice(0, -1)));
  const permissionAllows = (capability: string): boolean => {
    const deny = ["synex.groups.delete", "synex.admin.*"];
    const allow = ["synex.groups.*", "synex.identity.read"];
    return !deny.some((pattern) => capabilityMatches(pattern, capability))
      && allow.some((pattern) => capabilityMatches(pattern, capability));
  };
  const measurements: Record<string, BenchmarkMeasurement> = {};
  let checksum = 0;
  const add = (name: string, workload: string, operation: (index: number) => number): void => {
    const measured = measure(iterations, workload, operation);
    measurements[name] = measured.measurement;
    checksum = (checksum + measured.checksum) >>> 0;
  };

  add("registry_lookup", "Map#get across 1024 pre-registered resource fixtures.", (index) =>
    registry.get(`resource_${(index + BENCHMARK_SEED) & 1_023}`) ?? 0,
  );
  add("permission_lookup", "Deny-first exact and wildcard capability evaluation over fixed policy fixtures.", (index) => {
    const capability = index % 32 === 0 ? "synex.groups.delete" : `synex.groups.action_${index & 255}`;
    return permissionAllows(capability) ? 1 : 0;
  });
  add("rpc_dispatch", "AJV request validation followed by dispatch to a fixed in-process handler.", (index) => {
    const payload = { ...request, amount: (index % 1_000) + 1 };
    return schemaValidator(payload) ? rpcHandler(payload) : 0;
  });
  add("contract_validation", "AJV validation of one fixed valid bounded RPC payload.", () => schemaValidator(request) ? 1 : 0);
  add("state_update", "Revisioned Map read-modify-write across 256 owned-state fixtures.", (index) => {
    const key = `state_${(index + BENCHMARK_SEED) & 255}`;
    const previous = states.get(key);
    const revision = (previous?.revision ?? 0) + 1;
    states.set(key, { value: index, revision });
    return revision;
  });
  add("ledger_operation", "Balanced debit/credit construction, invariant check, and bounded ring storage.", (index) => {
    const amount = (index % 10_000) + 1;
    const debit = -amount;
    const credit = amount;
    if (debit + credit !== 0) throw new Error("benchmark ledger invariant failed");
    ledgerSlots[(index + BENCHMARK_SEED) & 1_023] = { debit, credit, sequence: index };
    return credit + (ledgerSlots[(index + BENCHMARK_SEED) & 1_023]?.sequence ?? 0);
  });
  add("group_membership_query", "Membership-to-grade lookup plus grade capability membership check.", (index) => {
    const grade = memberships.get(`character_${(index + BENCHMARK_SEED) & 2_047}`) ?? 0;
    return gradeCapabilities.get(grade)?.has(`synex.groups.grade_${grade}.read`) ? grade + 1 : 0;
  });
  add("cache_lookup", "Bounded 512-entry Map cache with a deterministic mixed hit/miss workload.", (index) => {
    const key = index % 5 === 0 ? `miss_${(index + BENCHMARK_SEED) & 1_023}` : `cache_${(index + BENCHMARK_SEED) & 511}`;
    const cached = cache.get(key);
    if (cached !== undefined) return cached;
    cache.set(key, index & 511);
    if (cache.size > 512) cache.delete(cache.keys().next().value as string);
    return index & 511;
  });

  const sampleObject = {
    schema: 1,
    domain: "benchmark",
    contracts: [{ name: "synex.benchmark.sample", version: "1.0.0", input: { type: "object" } }],
  };
  const sampleLua = "RegisterNetEvent('synex:benchmark', function(value) local src = source if type(value) ~= 'string' then return end end)";
  add("canonical_json", "Canonical serialization of a fixed nested contract descriptor.", () => canonicalJson(sampleObject).length);
  add("lua_static_scan", "Lua AST/static-security scan of one fixed network-event fixture.", () => scanLuaText(sampleLua).length + 1);

  const runtime = { node: process.versions.node, platform: process.platform, architecture: process.arch };
  const regressions: BenchmarkReport["regressions"] = [];
  let baseline = { compared: false, reason: "No baseline supplied; use --output to capture one and --baseline to compare it." };
  if (rawBaseline !== undefined) {
    const parsed = parseBaseline(rawBaseline);
    if (!parsed) {
      throw new CliError("Benchmark baseline is not a valid Synex benchmark report.", 2);
    }
    const comparable = parsed.suiteVersion === SUITE_VERSION
      && parsed.iterations === iterations
      && parsed.runtime.node === runtime.node
      && parsed.runtime.platform === runtime.platform
      && parsed.runtime.architecture === runtime.architecture;
    if (!comparable) {
      baseline = { compared: false, reason: "Baseline suite, iteration count, Node version, platform, and architecture must match exactly." };
    } else {
      baseline = { compared: true, reason: `Compared with a ${(REGRESSION_THRESHOLD * 100).toFixed(0)}% warning threshold.` };
      for (const name of Object.keys(measurements).sort(compareText)) {
        const current = measurements[name];
        const previous = parsed.benchmarks[name];
        if (!current || !previous || previous.operationsPerSecond <= 0) continue;
        const decrease = (previous.operationsPerSecond - current.operationsPerSecond) / previous.operationsPerSecond;
        if (decrease > REGRESSION_THRESHOLD) {
          regressions.push({
            benchmark: name,
            baselineOps: previous.operationsPerSecond,
            currentOps: current.operationsPerSecond,
            decreasePercent: Number((decrease * 100).toFixed(2)),
          });
        }
      }
    }
  }
  const canonical = measurements.canonical_json as BenchmarkMeasurement;
  const luaScan = measurements.lua_static_scan as BenchmarkMeasurement;
  return {
    schema: 1,
    suiteVersion: SUITE_VERSION,
    status: regressions.length > 0 || (rawBaseline !== undefined && !baseline.compared) ? "WARN" : "PASS",
    runtime,
    iterations,
    samples: SAMPLE_COUNT,
    seed: BENCHMARK_SEED,
    benchmarks: Object.fromEntries(Object.entries(measurements).sort(([left], [right]) => compareText(left, right))),
    regressions,
    baseline,
    canonicalJson: { milliseconds: canonical.medianMilliseconds, operationsPerSecond: canonical.operationsPerSecond },
    luaScan: { milliseconds: luaScan.medianMilliseconds, operationsPerSecond: luaScan.operationsPerSecond },
    checksum,
    disclaimer: "Deterministic local headless microbenchmark only; results are not a FiveM runtime or production performance claim.",
  };
}
