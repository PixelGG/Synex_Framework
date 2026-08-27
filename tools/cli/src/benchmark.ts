import { Ajv2020 } from "ajv/dist/2020.js";
import { spawnSync } from "node:child_process";
import { performance } from "node:perf_hooks";
import { fileURLToPath } from "node:url";

import { CliError } from "./errors.ts";
import { canonicalJson, compareText, isRecord } from "./filesystem.ts";
import { scanLuaText } from "./security.ts";

const SUITE_VERSION = 7;
const SAMPLE_COUNT = 5;
const REGRESSION_THRESHOLD = 0.25;
const BENCHMARK_SEED = 0x5a17;
const MINIMUM_ITERATIONS = 1;
const MAXIMUM_ITERATIONS = 100_000;

export interface BenchmarkMeasurement {
  workload: string;
  execution: "node" | "synex_groups_lua" | "synex_accounts_lua" | "synex_entities_lua" | "synex_bridge_lua";
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
  thresholds: {
    minimumIterations: number;
    maximumIterations: number;
    regressionDecreasePercent: number;
  };
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

const GROUPS_LUA_WORKLOADS = {
  groups_group_lookup:
    "Actual server.persistence.organizations_read read-model lookup with a deterministic in-memory transaction adapter; excludes MariaDB I/O.",
  groups_membership_lookup:
    "Actual server.persistence.memberships_read read-model lookup with a deterministic in-memory transaction adapter; excludes MariaDB I/O.",
  groups_effective_capability_lookup:
    "Actual server.persistence.capability_access evaluateCharacter path and server.domain.capabilities composition with deterministic in-memory adapters.",
  groups_online_members_lookup:
    "Actual server.runtime_index online-member count over 2048 loaded membership fixtures.",
  groups_on_duty_members_lookup:
    "Actual server.runtime_index on-duty-member count over 2048 loaded duty fixtures.",
  groups_policy_evaluation:
    "Actual server.persistence.governance_policies evaluation of a cached bounded 16-rule policy with an in-memory transaction adapter.",
} as const;

const ACCOUNTS_LUA_WORKLOADS = {
  accounts_balance_lookup:
    "Actual synex_accounts service validation and authoritative balance-read path with a deterministic in-memory database port; excludes MariaDB I/O.",
  accounts_available_balance_lookup:
    "Actual synex_accounts service validation and available-balance read path with a deterministic in-memory database port; excludes MariaDB I/O.",
  accounts_access_check:
    "Actual synex_accounts access-check service path with authoritative principal validation and a deterministic in-memory database port.",
  accounts_transfer:
    "Actual synex_accounts transfer service validation, policy-hook, provenance, fingerprint, and multi-leg command construction; excludes MariaDB I/O.",
  accounts_multileg_post:
    "Actual synex_accounts bounded multi-leg validation, zero-sum check, policy-hook, provenance, and command construction; excludes MariaDB I/O.",
  accounts_hold_create:
    "Actual synex_accounts hold-create validation, provenance, fingerprint, and service dispatch with a deterministic in-memory database port.",
  accounts_hold_capture:
    "Actual synex_accounts hold-capture validation, policy-hook chain, provenance, fingerprint, and service dispatch with a deterministic in-memory database port.",
  accounts_reconciliation_query:
    "Actual synex_accounts reconciliation request validation, provenance, fingerprint, and service dispatch with a deterministic in-memory database port; excludes MariaDB I/O.",
} as const;

const ENTITIES_LUA_WORKLOADS = {
  entities_entity_ref_lookup:
    "Actual synex_entities registry EntityRef validation and generation-fenced lookup over 1024 in-memory entity fixtures.",
  entities_net_id_resolve:
    "Actual synex_entities registry NetID validation, reference-index resolution, and stale-generation check over 1024 in-memory entity fixtures.",
  entities_binding_lookup:
    "Actual synex_entities namespaced binding-index validation and resolution over 1024 in-memory entity fixtures.",
  entities_owner_lookup:
    "Actual synex_entities logical-owner index lookup and deterministic result ordering over 1024 in-memory entity fixtures.",
  entities_spawn_validation:
    "Actual synex_entities bounded spawn-request validation and normalization; excludes FiveM natives and entity creation.",
  entities_state_lookup:
    "Actual synex_entities extension-repository state lookup with a deterministic in-memory database port; excludes MariaDB I/O.",
  entities_bucket_lookup:
    "Actual synex_entities routing-bucket index lookup and deterministic result ordering over 1024 in-memory entity fixtures.",
  entities_nearby_query:
    "Actual synex_entities bounded spatial-index nearby query and registry resolution over 1024 in-memory entity fixtures.",
} as const;

const BRIDGE_LUA_WORKLOADS = {
  bridge_projection_copy:
    "Actual synex_bridge kernel DTO copy configured with the native compatibility projection bounds over a fixed detached player projection.",
  bridge_callback_argument_validation:
    "Actual synex_bridge kernel dense-array DTO validation configured with the native callback argument bounds.",
  bridge_account_mapping_resolve:
    "Actual synex_bridge indexed account-mapping resolution over 64 pre-registered reviewed-format mapping fixtures.",
  bridge_surface_resolve:
    "Actual synex_bridge consumer/profile/surface/adapter resolver path over a fixed compatibility policy fixture.",
  bridge_telemetry_record:
    "Actual synex_bridge bounded compatibility telemetry aggregation into one fixed owner/surface series.",
} as const;

function measureGroupsLua(iterations: number): { measurements: Record<string, BenchmarkMeasurement>; checksum: number } {
  const runnerExtension = import.meta.url.endsWith(".ts") ? "ts" : "js";
  const runner = fileURLToPath(new URL(`./groups-benchmark-runner.${runnerExtension}`, import.meta.url));
  const child = spawnSync(process.execPath, [
    "--no-warnings",
    "--experimental-strip-types",
    runner,
    String(iterations),
    String(SAMPLE_COUNT),
    String(BENCHMARK_SEED),
  ], {
    encoding: "utf8",
    windowsHide: true,
    timeout: 120_000,
    maxBuffer: 1024 * 1024,
  });
  if (child.error || child.status !== 0) {
    const reason = child.error?.message || child.stderr.trim() || "embedded Lua runner exited unsuccessfully";
    throw new CliError(`Groups Lua benchmark failed: ${reason}`, 1);
  }
  let decoded: unknown;
  try {
    decoded = JSON.parse(child.stdout);
  } catch {
    throw new CliError("Groups Lua benchmark returned invalid JSON.", 1);
  }
  if (!isRecord(decoded) || !isRecord(decoded.measurements)
    || typeof decoded.checksum !== "number" || !Number.isInteger(decoded.checksum)) {
    throw new CliError("Groups Lua benchmark returned an invalid report.", 1);
  }
  const measurements: Record<string, BenchmarkMeasurement> = {};
  for (const [name, workload] of Object.entries(GROUPS_LUA_WORKLOADS)) {
    const raw = decoded.measurements[name];
    if (!isRecord(raw) || !Array.isArray(raw.samplesMilliseconds)
      || raw.samplesMilliseconds.length !== SAMPLE_COUNT
      || typeof raw.checksum !== "number" || !Number.isInteger(raw.checksum)) {
      throw new CliError(`Groups Lua benchmark omitted or corrupted ${name}.`, 1);
    }
    const samples = raw.samplesMilliseconds;
    if (!samples.every((value): value is number =>
      typeof value === "number" && Number.isFinite(value) && value >= 0)) {
      throw new CliError(`Groups Lua benchmark returned invalid timings for ${name}.`, 1);
    }
    const medianMilliseconds = median(samples);
    measurements[name] = {
      workload,
      execution: "synex_groups_lua",
      medianMilliseconds: Number(medianMilliseconds.toFixed(3)),
      operationsPerSecond: Math.round((iterations / Math.max(medianMilliseconds, 0.001)) * 1_000),
      samplesMilliseconds: samples.map((value) => Number(value.toFixed(3))),
    };
  }
  return { measurements, checksum: decoded.checksum >>> 0 };
}

function measureAccountsLua(iterations: number): { measurements: Record<string, BenchmarkMeasurement>; checksum: number } {
  const runnerExtension = import.meta.url.endsWith(".ts") ? "ts" : "js";
  const runner = fileURLToPath(new URL(`./accounts-benchmark-runner.${runnerExtension}`, import.meta.url));
  const child = spawnSync(process.execPath, [
    "--no-warnings",
    "--experimental-strip-types",
    runner,
    String(iterations),
    String(SAMPLE_COUNT),
    String(BENCHMARK_SEED),
  ], {
    encoding: "utf8",
    windowsHide: true,
    timeout: 120_000,
    maxBuffer: 1024 * 1024,
  });
  if (child.error || child.status !== 0) {
    const reason = child.error?.message || child.stderr.trim() || "embedded Lua runner exited unsuccessfully";
    throw new CliError(`Accounts Lua benchmark failed: ${reason}`, 1);
  }
  let decoded: unknown;
  try {
    decoded = JSON.parse(child.stdout);
  } catch {
    throw new CliError("Accounts Lua benchmark returned invalid JSON.", 1);
  }
  if (!isRecord(decoded) || !isRecord(decoded.measurements)
    || typeof decoded.checksum !== "number" || !Number.isInteger(decoded.checksum)) {
    throw new CliError("Accounts Lua benchmark returned an invalid report.", 1);
  }
  const measurements: Record<string, BenchmarkMeasurement> = {};
  for (const [name, workload] of Object.entries(ACCOUNTS_LUA_WORKLOADS)) {
    const raw = decoded.measurements[name];
    if (!isRecord(raw) || !Array.isArray(raw.samplesMilliseconds)
      || raw.samplesMilliseconds.length !== SAMPLE_COUNT
      || typeof raw.checksum !== "number" || !Number.isInteger(raw.checksum)) {
      throw new CliError(`Accounts Lua benchmark omitted or corrupted ${name}.`, 1);
    }
    const samples = raw.samplesMilliseconds;
    if (!samples.every((value): value is number =>
      typeof value === "number" && Number.isFinite(value) && value >= 0)) {
      throw new CliError(`Accounts Lua benchmark returned invalid timings for ${name}.`, 1);
    }
    const medianMilliseconds = median(samples);
    measurements[name] = {
      workload,
      execution: "synex_accounts_lua",
      medianMilliseconds: Number(medianMilliseconds.toFixed(3)),
      operationsPerSecond: Math.round((iterations / Math.max(medianMilliseconds, 0.001)) * 1_000),
      samplesMilliseconds: samples.map((value) => Number(value.toFixed(3))),
    };
  }
  return { measurements, checksum: decoded.checksum >>> 0 };
}

function measureEntitiesLua(iterations: number): { measurements: Record<string, BenchmarkMeasurement>; checksum: number } {
  const runnerExtension = import.meta.url.endsWith(".ts") ? "ts" : "js";
  const runner = fileURLToPath(new URL(`./entities-benchmark-runner.${runnerExtension}`, import.meta.url));
  const child = spawnSync(process.execPath, [
    "--no-warnings",
    "--experimental-strip-types",
    runner,
    String(iterations),
    String(SAMPLE_COUNT),
    String(BENCHMARK_SEED),
  ], {
    encoding: "utf8",
    windowsHide: true,
    timeout: 120_000,
    maxBuffer: 1024 * 1024,
  });
  if (child.error || child.status !== 0) {
    const reason = child.error?.message || child.stderr.trim() || "embedded Lua runner exited unsuccessfully";
    throw new CliError(`Entities Lua benchmark failed: ${reason}`, 1);
  }
  let decoded: unknown;
  try {
    decoded = JSON.parse(child.stdout);
  } catch {
    throw new CliError("Entities Lua benchmark returned invalid JSON.", 1);
  }
  if (!isRecord(decoded) || !isRecord(decoded.measurements)
    || typeof decoded.checksum !== "number" || !Number.isInteger(decoded.checksum)) {
    throw new CliError("Entities Lua benchmark returned an invalid report.", 1);
  }
  const measurements: Record<string, BenchmarkMeasurement> = {};
  for (const [name, workload] of Object.entries(ENTITIES_LUA_WORKLOADS)) {
    const raw = decoded.measurements[name];
    if (!isRecord(raw) || !Array.isArray(raw.samplesMilliseconds)
      || raw.samplesMilliseconds.length !== SAMPLE_COUNT
      || typeof raw.checksum !== "number" || !Number.isInteger(raw.checksum)) {
      throw new CliError(`Entities Lua benchmark omitted or corrupted ${name}.`, 1);
    }
    const samples = raw.samplesMilliseconds;
    if (!samples.every((value): value is number =>
      typeof value === "number" && Number.isFinite(value) && value >= 0)) {
      throw new CliError(`Entities Lua benchmark returned invalid timings for ${name}.`, 1);
    }
    const medianMilliseconds = median(samples);
    measurements[name] = {
      workload,
      execution: "synex_entities_lua",
      medianMilliseconds: Number(medianMilliseconds.toFixed(3)),
      operationsPerSecond: Math.round((iterations / Math.max(medianMilliseconds, 0.001)) * 1_000),
      samplesMilliseconds: samples.map((value) => Number(value.toFixed(3))),
    };
  }
  return { measurements, checksum: decoded.checksum >>> 0 };
}

function measureBridgeLua(iterations: number): { measurements: Record<string, BenchmarkMeasurement>; checksum: number } {
  const runnerExtension = import.meta.url.endsWith(".ts") ? "ts" : "js";
  const runner = fileURLToPath(new URL(`./bridge-benchmark-runner.${runnerExtension}`, import.meta.url));
  const child = spawnSync(process.execPath, [
    "--no-warnings",
    "--experimental-strip-types",
    runner,
    String(iterations),
    String(SAMPLE_COUNT),
    String(BENCHMARK_SEED),
  ], {
    encoding: "utf8",
    windowsHide: true,
    timeout: 120_000,
    maxBuffer: 1024 * 1024,
  });
  if (child.error || child.status !== 0) {
    const reason = child.error?.message || child.stderr.trim() || "embedded Lua runner exited unsuccessfully";
    throw new CliError(`Bridge Lua benchmark failed: ${reason}`, 1);
  }
  let decoded: unknown;
  try {
    decoded = JSON.parse(child.stdout);
  } catch {
    throw new CliError("Bridge Lua benchmark returned invalid JSON.", 1);
  }
  if (!isRecord(decoded) || !isRecord(decoded.measurements)
    || typeof decoded.checksum !== "number" || !Number.isInteger(decoded.checksum)) {
    throw new CliError("Bridge Lua benchmark returned an invalid report.", 1);
  }
  const measurements: Record<string, BenchmarkMeasurement> = {};
  for (const [name, workload] of Object.entries(BRIDGE_LUA_WORKLOADS)) {
    const raw = decoded.measurements[name];
    if (!isRecord(raw) || !Array.isArray(raw.samplesMilliseconds)
      || raw.samplesMilliseconds.length !== SAMPLE_COUNT
      || typeof raw.checksum !== "number" || !Number.isInteger(raw.checksum)) {
      throw new CliError(`Bridge Lua benchmark omitted or corrupted ${name}.`, 1);
    }
    const samples = raw.samplesMilliseconds;
    if (!samples.every((value): value is number =>
      typeof value === "number" && Number.isFinite(value) && value >= 0)) {
      throw new CliError(`Bridge Lua benchmark returned invalid timings for ${name}.`, 1);
    }
    const medianMilliseconds = median(samples);
    measurements[name] = {
      workload,
      execution: "synex_bridge_lua",
      medianMilliseconds: Number(medianMilliseconds.toFixed(3)),
      operationsPerSecond: Math.round((iterations / Math.max(medianMilliseconds, 0.001)) * 1_000),
      samplesMilliseconds: samples.map((value) => Number(value.toFixed(3))),
    };
  }
  return { measurements, checksum: decoded.checksum >>> 0 };
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
      execution: "node",
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
      execution: raw.execution === "synex_groups_lua" || raw.execution === "synex_accounts_lua"
        || raw.execution === "synex_entities_lua" || raw.execution === "synex_bridge_lua"
        ? raw.execution
        : "node",
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
  if (!Number.isInteger(iterations)
    || iterations < MINIMUM_ITERATIONS || iterations > MAXIMUM_ITERATIONS) {
    throw new CliError("Benchmark iterations must be a whole number from 1 to 100000.", 2);
  }
  const registry = new Map(Array.from({ length: 1_024 }, (_, index) => [`resource_${index}`, index]));
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
  const groupsLua = measureGroupsLua(iterations);
  for (const [name, measurement] of Object.entries(groupsLua.measurements)) {
    measurements[name] = measurement;
  }
  checksum = (checksum + groupsLua.checksum) >>> 0;
  const accountsLua = measureAccountsLua(iterations);
  for (const [name, measurement] of Object.entries(accountsLua.measurements)) {
    measurements[name] = measurement;
  }
  checksum = (checksum + accountsLua.checksum) >>> 0;
  const entitiesLua = measureEntitiesLua(iterations);
  for (const [name, measurement] of Object.entries(entitiesLua.measurements)) {
    measurements[name] = measurement;
  }
  checksum = (checksum + entitiesLua.checksum) >>> 0;
  const bridgeLua = measureBridgeLua(iterations);
  for (const [name, measurement] of Object.entries(bridgeLua.measurements)) {
    measurements[name] = measurement;
  }
  checksum = (checksum + bridgeLua.checksum) >>> 0;
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
    thresholds: {
      minimumIterations: MINIMUM_ITERATIONS,
      maximumIterations: MAXIMUM_ITERATIONS,
      regressionDecreasePercent: REGRESSION_THRESHOLD * 100,
    },
    benchmarks: Object.fromEntries(Object.entries(measurements).sort(([left], [right]) => compareText(left, right))),
    regressions,
    baseline,
    canonicalJson: { milliseconds: canonical.medianMilliseconds, operationsPerSecond: canonical.operationsPerSecond },
    luaScan: { milliseconds: luaScan.medianMilliseconds, operationsPerSecond: luaScan.operationsPerSecond },
    checksum,
    disclaimer: "Deterministic local headless microbenchmark only. Groups, Accounts, and Entities measurements execute actual Synex Lua service, domain, validation, registry, repository, and spatial-index modules in an embedded Wasmoon VM with deterministic in-memory adapters. Bridge measurements execute its actual projection, validation, resolver, and telemetry kernel modules with deterministic in-memory fixtures. Groups, Accounts, and Bridge exclude FXServer, Cfx networking, and MariaDB I/O. Entity measurements exclude FXServer scheduling, FiveM natives, OneSync entity creation, Cfx networking, MariaDB I/O, and production concurrency. Results are not a FiveM runtime or production performance claim.",
  };
}
