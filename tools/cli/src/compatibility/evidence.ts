import { lstat, readFile } from "node:fs/promises";
import { isAbsolute, join, relative, resolve, sep } from "node:path";
import { Ajv2020, type AnySchema } from "ajv/dist/2020.js";

import { CliError } from "../errors.ts";
import { isRecord } from "../filesystem.ts";
import type {
  CompatibilityDoctorFinding,
  CompatibilityProvider,
} from "./types.ts";

const EVIDENCE_SCHEMA = join(
  "libraries", "synex_bridge", "compatibility", "schemas", "runtime-evidence.schema.json",
);
const MAX_EVIDENCE_BYTES = 1024 * 1024;
export const RUNTIME_RATE_MINIMUM_CALLS = 20;
export const RUNTIME_UNSUPPORTED_WARNING_BASIS_POINTS = 500;
export const RUNTIME_DEPRECATED_WARNING_BASIS_POINTS = 2500;

export interface RuntimeTelemetryEntry {
  consumer: string;
  operation: string;
  calls: number;
  outcomes: {
    success: number;
    denied: number;
    unsupported: number;
    error: number;
    timeout: number;
    rateLimited: number;
    deprecated: number;
  };
  latency: { samples: number; totalMs: number; maximumMs: number };
}

export interface RuntimeProviderEvidence {
  provider: CompatibilityProvider;
  resource: string;
  version: string;
  state: "started" | "starting" | "stopped" | "missing" | "unknown";
  health: {
    status: "READY" | "DEGRADED" | "FAILED" | "UNAVAILABLE";
    reasons: string[];
    callbackPending?: number;
    callbackCapacity?: number;
    callbackRegistrations?: number;
    callbackRegistrationCapacity?: number;
  };
  capabilities: Array<{ name: string; required: boolean; granted: boolean }>;
  conflicts: Array<{ code: string; active: boolean }>;
  telemetry: { truncated: boolean; entries: RuntimeTelemetryEntry[] };
}

export interface RuntimeCertificationEvidence {
  profileId: string;
  profileVersion: string;
  provider: CompatibilityProvider;
  providerVersion: string;
  targetFrameworkApiRange: string;
  script: { name: string; version: string };
  tests: Array<{ path: string; sha256: string; status: "PASS" | "FAIL" | "SKIP" }>;
}

export interface RuntimeCompatibilityEvidence {
  schema: 1;
  kind: "synex-compatibility-runtime-evidence";
  source: "operator";
  complete: boolean;
  expectedProviders: CompatibilityProvider[];
  providers: RuntimeProviderEvidence[];
  consumers: Array<{ consumer: string; provider: CompatibilityProvider; active: boolean }>;
  mappings: { ambiguous: number; missing: number; forbidden: number };
  certifications: RuntimeCertificationEvidence[];
}

export interface RuntimeEvidenceSummary {
  provided: true;
  source: "operator";
  complete: boolean;
  expectedProviders: CompatibilityProvider[];
  providers: Array<{
    provider: CompatibilityProvider;
    resource: string;
    version: string;
    state: RuntimeProviderEvidence["state"];
    health: RuntimeProviderEvidence["health"]["status"];
    requiredCapabilities: number;
    deniedRequiredCapabilities: number;
    activeConflicts: number;
    telemetryEntries: number;
    telemetryCalls: number;
    telemetryTruncated: boolean;
    callbackPending: number | null;
    callbackCapacity: number | null;
    callbackRegistrations: number | null;
    callbackRegistrationCapacity: number | null;
  }>;
  activeConsumerBindings: number;
  mappingIssues: number;
  telemetryEntries: number;
  telemetryCalls: number;
  telemetryTruncated: boolean;
}

async function pathContainsSymlink(repositoryRoot: string, path: string): Promise<boolean> {
  const rel = relative(resolve(repositoryRoot), resolve(path));
  if (rel === "" || rel === ".." || rel.startsWith(`..${sep}`) || isAbsolute(rel)) return true;
  let current = resolve(repositoryRoot);
  for (const segment of rel.split(sep).filter(Boolean)) {
    current = join(current, segment);
    try {
      if ((await lstat(current)).isSymbolicLink()) return true;
    } catch {
      return false;
    }
  }
  return false;
}

async function readBoundedJson(repositoryRoot: string, path: string, label: string): Promise<unknown> {
  if (await pathContainsSymlink(repositoryRoot, path)) {
    throw new CliError(`${label} must be a non-symlink file inside the repository root.`, 2);
  }
  let metadata;
  try {
    metadata = await lstat(path);
  } catch {
    throw new CliError(`${label} is unavailable.`, 2);
  }
  if (!metadata.isFile() || metadata.isSymbolicLink() || metadata.size > MAX_EVIDENCE_BYTES) {
    throw new CliError(`${label} must be a regular file no larger than ${MAX_EVIDENCE_BYTES} bytes.`, 2);
  }
  try {
    return JSON.parse(await readFile(path, "utf8")) as unknown;
  } catch {
    throw new CliError(`${label} is not valid JSON.`, 2);
  }
}

export async function loadCompatibilityRuntimeEvidence(
  repositoryRoot: string,
  evidencePath: string,
): Promise<RuntimeCompatibilityEvidence> {
  const [schema, evidence] = await Promise.all([
    readBoundedJson(repositoryRoot, resolve(repositoryRoot, EVIDENCE_SCHEMA), "Runtime-evidence schema"),
    readBoundedJson(repositoryRoot, evidencePath, "Runtime evidence"),
  ]);
  if (!isRecord(schema)) throw new CliError("Runtime-evidence schema is invalid.", 2);
  let validator;
  try {
    validator = new Ajv2020({ allErrors: true, strict: true, validateFormats: false })
      .compile(schema as AnySchema);
  } catch {
    throw new CliError("Runtime-evidence schema could not be compiled.", 2);
  }
  if (!validator(evidence)) {
    throw new CliError(
      `Runtime evidence does not satisfy its closed schema (${validator.errors?.length ?? 0} error(s)).`,
      2,
    );
  }
  return evidence as RuntimeCompatibilityEvidence;
}

function compareText(left: string, right: string): number {
  return left < right ? -1 : left > right ? 1 : 0;
}

function rateBasisPoints(count: number, calls: number): number {
  return calls > 0 ? Math.floor((count * 10_000) / calls) : 0;
}

function formatBasisPoints(value: number): string {
  return `${(value / 100).toFixed(2)}%`;
}

export function inspectRuntimeEvidence(evidence: RuntimeCompatibilityEvidence): {
  findings: CompatibilityDoctorFinding[];
  summary: RuntimeEvidenceSummary;
} {
  const findings: CompatibilityDoctorFinding[] = [];
  if (!evidence.complete) findings.push({
    severity: "warning",
    code: "RUNTIME_EVIDENCE_INCOMPLETE",
    subject: "runtime",
    message: "The operator marked the supplied runtime snapshot as incomplete.",
  });

  const activeProvidersByConsumer = new Map<string, Set<CompatibilityProvider>>();
  const activeConsumersByProvider = new Map<CompatibilityProvider, Set<string>>();
  const consumerBindings = new Set<string>();
  for (const consumer of evidence.consumers) {
    const binding = `${consumer.provider}:${consumer.consumer}:${String(consumer.active)}`;
    if (consumerBindings.has(binding)) findings.push({
      severity: "error", code: "RUNTIME_CONSUMER_BINDING_DUPLICATE", subject: consumer.consumer,
      message: `Consumer binding ${consumer.provider}:${String(consumer.active)} is duplicated.`,
    });
    consumerBindings.add(binding);
    if (!consumer.active) continue;
    const activeProviders = activeProvidersByConsumer.get(consumer.consumer) ?? new Set();
    activeProviders.add(consumer.provider);
    activeProvidersByConsumer.set(consumer.consumer, activeProviders);
    const providerConsumers = activeConsumersByProvider.get(consumer.provider) ?? new Set();
    providerConsumers.add(consumer.consumer);
    activeConsumersByProvider.set(consumer.provider, providerConsumers);
  }

  const expected = new Set(evidence.expectedProviders);
  const providers = new Map<CompatibilityProvider, RuntimeProviderEvidence>();
  for (const provider of evidence.providers) {
    if (providers.has(provider.provider)) findings.push({
      severity: "error", code: "RUNTIME_PROVIDER_DUPLICATE", subject: provider.provider,
      message: "Runtime evidence contains more than one record for this provider.",
    });
    else providers.set(provider.provider, provider);
    if (!expected.has(provider.provider)) findings.push({
      severity: "error", code: "RUNTIME_PROVIDER_UNEXPECTED", subject: provider.provider,
      message: "Runtime evidence contains a provider outside expectedProviders.",
    });
  }
  for (const provider of expected) {
    if (!providers.has(provider)) findings.push({
      severity: "error", code: "RUNTIME_PROVIDER_MISSING", subject: provider,
      message: "Runtime evidence is missing an expected provider record.",
    });
  }

  for (const provider of evidence.providers) {
    if (provider.resource !== `synex_bridge_${provider.provider}`) findings.push({
      severity: "error", code: "RUNTIME_PROVIDER_RESOURCE_MISMATCH", subject: provider.provider,
      message: `Provider evidence names ${provider.resource}; expected synex_bridge_${provider.provider}.`,
    });
    if (provider.state !== "started") findings.push({
      severity: "warning", code: "RUNTIME_PROVIDER_NOT_STARTED", subject: provider.provider,
      message: `Provider resource state is ${provider.state}.`,
    });
    if (provider.health.status === "FAILED") findings.push({
      severity: "error", code: "RUNTIME_PROVIDER_FAILED", subject: provider.provider,
      message: "Provider runtime health is FAILED.",
    });
    if (provider.health.status === "DEGRADED" || provider.health.status === "UNAVAILABLE") findings.push({
      severity: "warning", code: `RUNTIME_PROVIDER_${provider.health.status}`, subject: provider.provider,
      message: `Provider runtime health is ${provider.health.status}.`,
    });
    if (provider.state === "started" && provider.health.status === "UNAVAILABLE") findings.push({
      severity: "error", code: "RUNTIME_PROVIDER_STATE_CONTRADICTION", subject: provider.provider,
      message: "A started provider cannot have an unavailable health snapshot.",
    });

    const capabilityNames = new Set<string>();
    for (const capability of provider.capabilities) {
      if (capabilityNames.has(capability.name)) findings.push({
        severity: "error", code: "RUNTIME_CAPABILITY_DUPLICATE", subject: provider.provider,
        message: `Capability ${capability.name} is duplicated in runtime evidence.`,
      });
      capabilityNames.add(capability.name);
      if (capability.required && !capability.granted) findings.push({
        severity: "error", code: "RUNTIME_CAPABILITY_DENIED", subject: provider.provider,
        message: `Required capability ${capability.name} was not granted.`,
      });
    }

    for (const conflict of provider.conflicts) {
      if (conflict.active) findings.push({
        severity: "error",
        code: conflict.code === "COMPAT_FRAMEWORK_CONFLICT"
          ? "RUNTIME_FRAMEWORK_RESOURCE_CONFLICT"
          : "RUNTIME_PROVIDER_CONFLICT",
        subject: provider.provider,
        message: conflict.code === "COMPAT_FRAMEWORK_CONFLICT"
          ? "A native framework resource conflicts with the active historical Synex facade."
          : `Runtime conflict ${conflict.code} is active.`,
      });
    }
    const callbackValues = [
      provider.health.callbackPending,
      provider.health.callbackCapacity,
      provider.health.callbackRegistrations,
      provider.health.callbackRegistrationCapacity,
    ];
    const callbackFields = callbackValues.filter((value) => value !== undefined).length;
    if (callbackFields > 0 && callbackFields < callbackValues.length) findings.push({
      severity: "error", code: "RUNTIME_CALLBACK_TELEMETRY_INCOMPLETE", subject: provider.provider,
      message: "Callback telemetry must include pending and registration counts with both capacities.",
    });
    if (callbackFields === callbackValues.length) {
      const pending = provider.health.callbackPending ?? 0;
      const capacity = provider.health.callbackCapacity ?? 0;
      const registrations = provider.health.callbackRegistrations ?? 0;
      const registrationCapacity = provider.health.callbackRegistrationCapacity ?? 0;
      if (capacity < 1 || registrationCapacity < 1
        || pending > capacity || registrations > registrationCapacity) findings.push({
        severity: "error", code: "RUNTIME_CALLBACK_TELEMETRY_INVALID", subject: provider.provider,
        message: "Callback telemetry exceeds its declared capacity or reports a zero capacity.",
      });
      const activeConsumers = activeConsumersByProvider.get(provider.provider)?.size ?? 0;
      const inactiveProvider = provider.state === "stopped"
        || provider.state === "missing" || provider.state === "unknown";
      if ((inactiveProvider || activeConsumers === 0) && pending > 0) findings.push({
        severity: "error", code: "RUNTIME_STALE_CALLBACK_PENDING", subject: provider.provider,
        message: `${pending} callback response(s) remain pending without an active provider/consumer binding.`,
      });
      if ((inactiveProvider || activeConsumers === 0) && registrations > 0) findings.push({
        severity: "error", code: "RUNTIME_STALE_CALLBACK_REGISTRATION", subject: provider.provider,
        message: `${registrations} callback registration(s) remain without an active provider/consumer binding.`,
      });
    }
    if (provider.telemetry.truncated) findings.push({
      severity: "warning", code: "RUNTIME_TELEMETRY_TRUNCATED", subject: provider.provider,
      message: "The bounded runtime telemetry snapshot is truncated.",
    });
    const telemetryKeys = new Set<string>();
    for (const entry of provider.telemetry.entries) {
      const telemetryKey = `${entry.consumer}:${entry.operation}`;
      if (telemetryKeys.has(telemetryKey)) findings.push({
        severity: "error", code: "RUNTIME_TELEMETRY_ENTRY_DUPLICATE", subject: provider.provider,
        message: `Telemetry ${telemetryKey} is duplicated.`,
      });
      telemetryKeys.add(telemetryKey);
      if (!activeConsumersByProvider.get(provider.provider)?.has(entry.consumer)) findings.push({
        severity: "error", code: "RUNTIME_STALE_CONSUMER_TELEMETRY", subject: entry.consumer,
        message: `Provider ${provider.provider} retains usage telemetry without an active consumer binding.`,
      });
      const terminal = entry.outcomes.success + entry.outcomes.denied + entry.outcomes.unsupported
        + entry.outcomes.error + entry.outcomes.timeout + entry.outcomes.rateLimited;
      if (terminal !== entry.calls) findings.push({
        severity: "error", code: "RUNTIME_TELEMETRY_COUNTER_INVALID", subject: provider.provider,
        message: `Telemetry ${entry.consumer}:${entry.operation} has ${entry.calls} call(s) but ${terminal} terminal outcome(s).`,
      });
      if (entry.outcomes.deprecated > entry.calls || entry.latency.samples > entry.calls) findings.push({
        severity: "error", code: "RUNTIME_TELEMETRY_BOUND_INVALID", subject: provider.provider,
        message: `Telemetry ${entry.consumer}:${entry.operation} exceeds its call bound.`,
      });
      if (entry.calls >= RUNTIME_RATE_MINIMUM_CALLS && terminal === entry.calls
        && entry.outcomes.deprecated <= entry.calls) {
        const unsupportedRate = rateBasisPoints(entry.outcomes.unsupported, entry.calls);
        const deprecatedRate = rateBasisPoints(entry.outcomes.deprecated, entry.calls);
        if (unsupportedRate >= RUNTIME_UNSUPPORTED_WARNING_BASIS_POINTS) findings.push({
          severity: "warning", code: "RUNTIME_UNSUPPORTED_RATE_HIGH", subject: entry.consumer,
          message: `${provider.provider}:${entry.operation} has an unsupported outcome rate of ${formatBasisPoints(unsupportedRate)} (${entry.outcomes.unsupported}/${entry.calls}); the warning threshold is ${formatBasisPoints(RUNTIME_UNSUPPORTED_WARNING_BASIS_POINTS)}.`,
        });
        if (deprecatedRate >= RUNTIME_DEPRECATED_WARNING_BASIS_POINTS) findings.push({
          severity: "warning", code: "RUNTIME_DEPRECATED_RATE_HIGH", subject: entry.consumer,
          message: `${provider.provider}:${entry.operation} has a deprecated-call rate of ${formatBasisPoints(deprecatedRate)} (${entry.outcomes.deprecated}/${entry.calls}); the warning threshold is ${formatBasisPoints(RUNTIME_DEPRECATED_WARNING_BASIS_POINTS)}.`,
        });
      }
    }
  }

  for (const [consumer, activeProviders] of activeProvidersByConsumer) {
    if (activeProviders.size > 1) findings.push({
      severity: "error", code: "RUNTIME_CONSUMER_PROVIDER_CONFLICT", subject: consumer,
      message: `Consumer has multiple active providers: ${[...activeProviders].sort(compareText).join(", ")}.`,
    });
  }

  if (evidence.mappings.ambiguous > 0) findings.push({
    severity: "error", code: "RUNTIME_MAPPING_AMBIGUOUS", subject: "mappings",
    message: `${evidence.mappings.ambiguous} ambiguous runtime mapping result(s) were reported.`,
  });
  if (evidence.mappings.forbidden > 0) findings.push({
    severity: "error", code: "RUNTIME_MAPPING_FORBIDDEN", subject: "mappings",
    message: `${evidence.mappings.forbidden} forbidden runtime mapping attempt(s) were reported.`,
  });
  if (evidence.mappings.missing > 0) findings.push({
    severity: "warning", code: "RUNTIME_MAPPING_MISSING", subject: "mappings",
    message: `${evidence.mappings.missing} missing runtime mapping result(s) were reported.`,
  });

  const summaryProviders = evidence.providers.map((provider) => ({
    provider: provider.provider,
    resource: provider.resource,
    version: provider.version,
    state: provider.state,
    health: provider.health.status,
    requiredCapabilities: provider.capabilities.filter((entry) => entry.required).length,
    deniedRequiredCapabilities: provider.capabilities.filter((entry) => entry.required && !entry.granted).length,
    activeConflicts: provider.conflicts.filter((entry) => entry.active).length,
    telemetryEntries: provider.telemetry.entries.length,
    telemetryCalls: provider.telemetry.entries.reduce((sum, entry) => sum + entry.calls, 0),
    telemetryTruncated: provider.telemetry.truncated,
    callbackPending: provider.health.callbackPending ?? null,
    callbackCapacity: provider.health.callbackCapacity ?? null,
    callbackRegistrations: provider.health.callbackRegistrations ?? null,
    callbackRegistrationCapacity: provider.health.callbackRegistrationCapacity ?? null,
  })).sort((left, right) => compareText(left.provider, right.provider));
  findings.sort((left, right) => compareText(left.subject, right.subject)
    || compareText(left.code, right.code));
  return {
    findings,
    summary: {
      provided: true,
      source: "operator",
      complete: evidence.complete,
      expectedProviders: [...evidence.expectedProviders].sort(compareText),
      providers: summaryProviders,
      activeConsumerBindings: evidence.consumers.filter((entry) => entry.active).length,
      mappingIssues: evidence.mappings.ambiguous + evidence.mappings.missing + evidence.mappings.forbidden,
      telemetryEntries: summaryProviders.reduce((sum, entry) => sum + entry.telemetryEntries, 0),
      telemetryCalls: summaryProviders.reduce((sum, entry) => sum + entry.telemetryCalls, 0),
      telemetryTruncated: summaryProviders.some((entry) => entry.telemetryTruncated),
    },
  };
}
