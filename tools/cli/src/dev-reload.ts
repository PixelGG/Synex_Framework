import { spawnSync } from "node:child_process";
import { lstat } from "node:fs/promises";
import { isAbsolute } from "node:path";

import { CliError } from "./errors.ts";
import { buildResourceGraph } from "./graph.ts";
import { isRecord, readJsonFile } from "./filesystem.ts";
import { resolveResourceDirectory } from "./resources.ts";
import { isResourceManifest } from "./validation.ts";

export type ReloadAdapter = "plan" | "local" | "remote";
export type ReloadStage = "QUIESCE" | "DRAIN" | "SNAPSHOT" | "RELOAD" | "VALIDATE" | "RESTORE" | "READY" | "ABORT";

export interface ReloadAction {
  stage: ReloadStage;
  resource: string;
  schemaVersion: number | null;
}

export interface ReloadReport {
  status: "PASS" | "WARN" | "FAIL";
  adapter: ReloadAdapter;
  target: string;
  impactedResources: string[];
  stateful: boolean;
  executed: boolean;
  actions: Array<ReloadAction & { status: "PLANNED" | "PASS" | "FAIL"; detail: string }>;
  limits: string[];
}

async function buildReloadPlan(
  repositoryRoot: string,
  requestedResource: string,
  force: boolean,
): Promise<{ target: string; impacted: string[]; stateful: boolean; actions: ReloadAction[] }> {
  const directory = await resolveResourceDirectory(repositoryRoot, requestedResource);
  const value = await readJsonFile(`${directory}/synex.resource.json`);
  if (!isResourceManifest(value)) throw new CliError("Reload target has no valid Synex resource manifest.", 2);
  const graph = await buildResourceGraph(repositoryRoot);

  const dependents = new Map<string, Set<string>>();
  for (const edge of graph.edges) {
    if (!edge.resolved || !["dependency-required", "service-required"].includes(edge.kind)) continue;
    const entries = dependents.get(edge.to) ?? new Set<string>();
    entries.add(edge.from);
    dependents.set(edge.to, entries);
  }
  const impactedSet = new Set([value.name]);
  const pending = [value.name];
  while (pending.length > 0) {
    const current = pending.shift();
    if (!current) break;
    for (const dependent of dependents.get(current) ?? []) {
      if (impactedSet.has(dependent)) continue;
      impactedSet.add(dependent);
      pending.push(dependent);
    }
  }
  const impactedCycle = graph.cycles.find((cycle) => cycle.some((resource) => impactedSet.has(resource)));
  if (impactedCycle) {
    throw new CliError(`Reload is blocked by a dependency cycle in the impacted set: ${impactedCycle.join(" <-> ")}.`, 1);
  }
  const impactedUnresolved = graph.unresolvedRequired.filter((entry) => impactedSet.has(entry.resource));
  if (impactedUnresolved.length > 0) {
    const details = impactedUnresolved.map((entry) => `${entry.resource}:${entry.reference}`).join(", ");
    throw new CliError(`Reload is blocked by unresolved required dependencies in the impacted set: ${details}.`, 1);
  }
  const impactedVersionErrors = graph.dependencyVersions.filter((entry) =>
    impactedSet.has(entry.resource) && entry.severity === "error"
  );
  if (impactedVersionErrors.length > 0) {
    const details = impactedVersionErrors.map((entry) =>
      `${entry.resource}:${entry.dependency}@${entry.requiredRange} (found ${entry.actualVersion ?? "missing"})`
    ).join(", ");
    throw new CliError(`Reload is blocked by incompatible required dependencies in the impacted set: ${details}.`, 1);
  }
  const ordered = (graph.topologicalOrder ?? graph.nodes.filter((node) => !node.external).map((node) => node.name))
    .filter((resource) => impactedSet.has(resource));
  const manifests = new Map<string, { supported: boolean; schemaVersion: number }>();
  for (const resource of ordered) {
    const resourceDirectory = await resolveResourceDirectory(repositoryRoot, resource);
    const manifest = await readJsonFile(`${resourceDirectory}/synex.resource.json`);
    if (!isResourceManifest(manifest)) throw new CliError(`Reload participant ${resource} has an invalid manifest.`, 1);
    manifests.set(resource, manifest.stateSnapshot);
  }
  const unsupported = ordered.filter((resource) => !manifests.get(resource)?.supported);
  if (unsupported.length > 0 && !force) {
    throw new CliError(
      `State-aware reload requires snapshot support for every impacted resource: ${unsupported.join(", ")}. Use --force only when state loss is acceptable.`,
      1,
    );
  }

  const actions: ReloadAction[] = [];
  for (const resource of [...ordered].reverse()) actions.push({ stage: "QUIESCE", resource, schemaVersion: manifests.get(resource)?.schemaVersion ?? null });
  for (const resource of [...ordered].reverse()) actions.push({ stage: "DRAIN", resource, schemaVersion: manifests.get(resource)?.schemaVersion ?? null });
  for (const resource of [...ordered].reverse()) {
    const snapshot = manifests.get(resource);
    if (snapshot?.supported) actions.push({ stage: "SNAPSHOT", resource, schemaVersion: snapshot.schemaVersion });
  }
  for (const resource of ordered) actions.push({ stage: "RELOAD", resource, schemaVersion: manifests.get(resource)?.schemaVersion ?? null });
  for (const resource of ordered) actions.push({ stage: "VALIDATE", resource, schemaVersion: manifests.get(resource)?.schemaVersion ?? null });
  for (const resource of ordered) {
    const snapshot = manifests.get(resource);
    if (snapshot?.supported) actions.push({ stage: "RESTORE", resource, schemaVersion: snapshot.schemaVersion });
  }
  for (const resource of ordered) actions.push({ stage: "READY", resource, schemaVersion: manifests.get(resource)?.schemaVersion ?? null });
  return { target: value.name, impacted: ordered, stateful: unsupported.length === 0, actions };
}

function boundedTimeout(value: number): number {
  if (!Number.isInteger(value) || value < 1_000 || value > 30_000) {
    throw new CliError("Reload adapter timeout must be a whole number from 1000 to 30000 milliseconds.", 2);
  }
  return value;
}

async function runLocalAction(action: ReloadAction, timeoutMs: number): Promise<void> {
  const executable = process.env.SYNEX_RELOAD_EXECUTABLE;
  if (!executable || !isAbsolute(executable)) {
    throw new CliError("Local reload requires an absolute SYNEX_RELOAD_EXECUTABLE path.", 2);
  }
  const metadata = await lstat(executable).catch(() => null);
  if (!metadata?.isFile()) throw new CliError("SYNEX_RELOAD_EXECUTABLE must reference a regular file.", 2);
  let template: unknown = ["{stage}", "{resource}", "{schemaVersion}"];
  if (process.env.SYNEX_RELOAD_ARGUMENTS_JSON) {
    try {
      template = JSON.parse(process.env.SYNEX_RELOAD_ARGUMENTS_JSON) as unknown;
    } catch {
      throw new CliError("SYNEX_RELOAD_ARGUMENTS_JSON must be valid JSON.", 2);
    }
  }
  if (!Array.isArray(template) || template.length > 32 || !template.every((entry) => typeof entry === "string" && entry.length <= 256)) {
    throw new CliError("SYNEX_RELOAD_ARGUMENTS_JSON must be an array of at most 32 bounded strings.", 2);
  }
  const replacements: Record<string, string> = {
    "{stage}": action.stage,
    "{resource}": action.resource,
    "{schemaVersion}": action.schemaVersion === null ? "none" : String(action.schemaVersion),
  };
  const argumentsList = template.map((entry) => {
    let output = entry;
    for (const [placeholder, replacement] of Object.entries(replacements)) output = output.replaceAll(placeholder, replacement);
    return output;
  });
  const result = spawnSync(executable, argumentsList, {
    encoding: "utf8",
    env: process.env,
    maxBuffer: 64 * 1024,
    shell: false,
    timeout: timeoutMs,
    windowsHide: true,
  });
  if (result.error || result.status !== 0) {
    throw new CliError(`Local reload adapter rejected ${action.stage} for ${action.resource} (exit ${result.status ?? "unavailable"}).`, 1);
  }
}

async function runRemoteAction(action: ReloadAction, timeoutMs: number): Promise<void> {
  const rawEndpoint = process.env.SYNEX_RELOAD_ENDPOINT;
  const token = process.env.SYNEX_RELOAD_TOKEN;
  if (!rawEndpoint || rawEndpoint.length > 2_048 || !token || token.length < 16 || token.length > 4_096) {
    throw new CliError("Remote reload requires an endpoint of at most 2048 characters and a SYNEX_RELOAD_TOKEN from 16 to 4096 characters.", 2);
  }
  let endpoint: URL;
  try {
    endpoint = new URL(rawEndpoint);
  } catch {
    throw new CliError("SYNEX_RELOAD_ENDPOINT is not a valid URL.", 2);
  }
  if (endpoint.username || endpoint.password || endpoint.hash) {
    throw new CliError("SYNEX_RELOAD_ENDPOINT must not contain credentials or a URL fragment.", 2);
  }
  const loopback = ["127.0.0.1", "::1", "localhost"].includes(endpoint.hostname);
  if (endpoint.protocol !== "https:" && !(endpoint.protocol === "http:" && loopback)) {
    throw new CliError("Remote reload requires HTTPS; plain HTTP is accepted only for a loopback endpoint.", 2);
  }
  const response = await fetch(endpoint, {
    method: "POST",
    redirect: "error",
    signal: AbortSignal.timeout(timeoutMs),
    headers: {
      authorization: `Bearer ${token}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({ schema: 1, ...action }),
  });
  const declaredLength = Number(response.headers.get("content-length") ?? 0);
  if (Number.isFinite(declaredLength) && declaredLength > 64 * 1024) {
    await response.body?.cancel().catch(() => undefined);
    throw new CliError("Remote reload adapter response exceeds 64 KiB.", 1);
  }
  const reader = response.body?.getReader();
  const chunks: Uint8Array[] = [];
  let received = 0;
  if (reader) {
    while (true) {
      const result = await reader.read();
      if (result.done) break;
      received += result.value.byteLength;
      if (received > 64 * 1024) {
        await reader.cancel().catch(() => undefined);
        throw new CliError("Remote reload adapter response exceeds 64 KiB.", 1);
      }
      chunks.push(result.value);
    }
  }
  const responseBytes = new Uint8Array(received);
  let offset = 0;
  for (const chunk of chunks) {
    responseBytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  const responseText = new TextDecoder().decode(responseBytes);
  let body: unknown = null;
  try {
    body = JSON.parse(responseText) as unknown;
  } catch {
    body = null;
  }
  if (!response.ok || !isRecord(body) || body.ok !== true) {
    throw new CliError(`Remote reload adapter rejected ${action.stage} for ${action.resource} (HTTP ${response.status}).`, 1);
  }
}

export async function runManagedReload(
  repositoryRoot: string,
  requestedResource: string,
  adapter: ReloadAdapter = "plan",
  force = false,
  timeoutMs = 5_000,
): Promise<ReloadReport> {
  if (!(["plan", "local", "remote"] as const).includes(adapter)) throw new CliError("Reload adapter must be plan, local, or remote.", 2);
  const timeout = boundedTimeout(timeoutMs);
  const plan = await buildReloadPlan(repositoryRoot, requestedResource, force);
  const limits = [
    "The CLI coordinates an operator-owned adapter; it cannot make arbitrary FiveM resources transactionally rollback-safe.",
    "Only manifest-declared schema-compatible snapshots are restored.",
    "Durable state must be committed before QUIESCE is acknowledged.",
  ];
  if (adapter === "plan") {
    return {
      status: plan.stateful ? "PASS" : "WARN",
      adapter,
      target: plan.target,
      impactedResources: plan.impacted,
      stateful: plan.stateful,
      executed: false,
      actions: plan.actions.map((action) => ({ ...action, status: "PLANNED", detail: "No adapter command was executed." })),
      limits,
    };
  }

  const results: ReloadReport["actions"] = [];
  for (const action of plan.actions) {
    try {
      if (adapter === "local") await runLocalAction(action, timeout);
      else await runRemoteAction(action, timeout);
      results.push({ ...action, status: "PASS", detail: "Adapter acknowledged the stage." });
    } catch (error) {
      results.push({ ...action, status: "FAIL", detail: error instanceof Error ? error.message : "Reload adapter failed." });
      const abort: ReloadAction = { stage: "ABORT", resource: plan.target, schemaVersion: null };
      try {
        if (adapter === "local") await runLocalAction(abort, timeout);
        else await runRemoteAction(abort, timeout);
        results.push({ ...abort, status: "PASS", detail: "Adapter acknowledged best-effort abort." });
      } catch {
        results.push({ ...abort, status: "FAIL", detail: "Best-effort abort was not acknowledged." });
      }
      return {
        status: "FAIL",
        adapter,
        target: plan.target,
        impactedResources: plan.impacted,
        stateful: plan.stateful,
        executed: true,
        actions: results,
        limits,
      };
    }
  }
  return {
    status: plan.stateful ? "PASS" : "WARN",
    adapter,
    target: plan.target,
    impactedResources: plan.impacted,
    stateful: plan.stateful,
    executed: true,
    actions: results,
    limits,
  };
}
