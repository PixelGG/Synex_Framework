import { spawnSync } from "node:child_process";
import { join, resolve } from "node:path";

import type { CheckStatus, OperationalCheck } from "./operations.ts";
import { buildResourceGraph } from "./graph.ts";
import {
  canonicalJson,
  compareText,
  displayPath,
  isRecord,
  pathExists,
  readJsonFile,
  readTextFile,
  sha256,
} from "./filesystem.ts";
import { loadSchemaRegistry } from "./schemas.ts";
import { loadResourceManifests } from "./validation.ts";

const SECRET_VALUE_PATTERNS: Array<[RegExp, string]> = [
  [/https:\/\/(?:canary\.|ptb\.)?discord(?:app)?\.com\/api(?:\/v\d+)?\/webhooks\/[^\s"']+/giu, "[REDACTED_WEBHOOK]"],
  [/(?:mysql|mariadb):\/\/[^\s"']+/giu, "[REDACTED_DATABASE_URL]"],
  [/\b(?:github_pat_[A-Za-z0-9_]+|gh[pousr]_[A-Za-z0-9_]{20,}|cfxk_[A-Za-z0-9_-]{20,})\b/gu, "[REDACTED_TOKEN]"],
  [/\bAKIA[A-Z0-9]{16}\b/gu, "[REDACTED_ACCESS_KEY]"],
  [/(bearer\s+)[A-Za-z0-9._~+/=-]{8,}/giu, "$1[REDACTED]"],
  [/([?&](?:access[_-]?token|api[_-]?key|secret|signature|token)=)[^&#\s"']+/giu, "$1[REDACTED]"],
  [/\b[a-z][a-z0-9+.-]*:\/\/[^/\s:@]+:[^@\s/]+@[^\s"']+/giu, "[REDACTED_CREDENTIAL_URL]"],
  [/-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----/gu, "[REDACTED_PRIVATE_KEY]"],
];

function isSecretKey(key: string): boolean {
  const normalized = key.replace(/[^a-z0-9]/giu, "").toLowerCase();
  return /(?:authorization|credentials?|databaseurl|connectionstring|password|privatekey|secret|token|webhook|apikey|accesskey)$/u.test(normalized);
}

export interface RedactionResult {
  value: unknown;
  redactedFields: number;
  redactedValues: number;
}

function redactString(value: string): { value: string; changes: number } {
  let output = value;
  let changes = 0;
  for (const [pattern, replacement] of SECRET_VALUE_PATTERNS) {
    output = output.replace(pattern, () => {
      changes += 1;
      return replacement;
    });
  }
  return { value: output, changes };
}

export function redactDiagnosticValue(input: unknown): RedactionResult {
  let redactedFields = 0;
  let redactedValues = 0;
  const visit = (value: unknown): unknown => {
    if (typeof value === "string") {
      const redacted = redactString(value);
      redactedValues += redacted.changes;
      return redacted.value;
    }
    if (Array.isArray(value)) return value.map(visit);
    if (!isRecord(value)) return value;
    const output: Record<string, unknown> = {};
    for (const [key, nested] of Object.entries(value)) {
      if (isSecretKey(key)) {
        output[key] = "[REDACTED]";
        redactedFields += 1;
      } else {
        output[key] = visit(nested);
      }
    }
    return output;
  };
  return { value: visit(input), redactedFields, redactedValues };
}

function gitMetadata(repositoryRoot: string): { commit: string | null; dirty: boolean | null } {
  const commit = spawnSync("git", ["rev-parse", "--verify", "HEAD"], {
    cwd: repositoryRoot,
    encoding: "utf8",
    windowsHide: true,
    timeout: 5_000,
  });
  const status = spawnSync("git", ["status", "--porcelain=v1", "--untracked-files=normal"], {
    cwd: repositoryRoot,
    encoding: "utf8",
    windowsHide: true,
    timeout: 5_000,
  });
  return {
    commit: commit.status === 0 ? commit.stdout.trim() || null : null,
    dirty: status.status === 0 ? status.stdout.trim().length > 0 : null,
  };
}

export async function createDiagnosticBundle(
  repositoryRoot: string,
  target: string,
  doctor: { status: CheckStatus; checks: OperationalCheck[] },
): Promise<Record<string, unknown>> {
  const packageValue = await readJsonFile(join(repositoryRoot, "package.json"));
  const packageMetadata = isRecord(packageValue) ? {
    name: typeof packageValue.name === "string" ? packageValue.name : null,
    version: typeof packageValue.version === "string" ? packageValue.version : null,
    engines: isRecord(packageValue.engines) ? packageValue.engines : null,
    synex: isRecord(packageValue.synex) ? packageValue.synex : null,
  } : null;
  const graph = await buildResourceGraph(repositoryRoot);
  const schemas = await loadSchemaRegistry(repositoryRoot);
  const resources = await loadResourceManifests(repositoryRoot, resolve(repositoryRoot), schemas);
  const migrations = [];
  for (const resource of resources.manifests) {
    for (const migration of resource.manifest.migrations) {
      const file = join(resource.directory, migration.path);
      migrations.push({
        resource: resource.manifest.name,
        id: migration.id,
        path: displayPath(repositoryRoot, file),
        transactional: migration.transactional,
        present: await pathExists(file),
        sha256: (await pathExists(file)) ? sha256((await readTextFile(file)).replace(/\r\n?/gu, "\n")) : null,
      });
    }
  }

  const configuration: Record<string, unknown> = {};
  for (const [name, path] of [
    ["runtime", join(repositoryRoot, "core", "synex_core", "config", "default.json")],
    ["capabilityPolicy", join(repositoryRoot, "core", "synex_core", "config", "capabilities.json")],
  ] as const) {
    configuration[name] = (await pathExists(path)) ? await readJsonFile(path) : null;
  }
  const redactedConfiguration = redactDiagnosticValue(configuration);
  const checks = redactDiagnosticValue(doctor.checks);
  const body = {
    schema: 1,
    artifactKind: "synex-diagnostic-bundle",
    generatedAt: new Date().toISOString(),
    target: displayPath(repositoryRoot, resolve(target)),
    framework: packageMetadata,
    runtime: {
      node: process.versions.node,
      platform: process.platform,
      architecture: process.arch,
    },
    revision: gitMetadata(repositoryRoot),
    health: { status: doctor.status, checks: checks.value },
    dependencyGraph: {
      nodes: graph.nodes,
      edges: graph.edges,
      cycles: graph.cycles,
      unresolvedRequired: graph.unresolvedRequired,
      dependencyVersions: graph.dependencyVersions,
    },
    migrations: migrations.sort((left, right) =>
      compareText(left.resource, right.resource) || compareText(left.id, right.id),
    ),
    configuration: redactedConfiguration.value,
    warnings: doctor.checks.filter((check) => check.status === "WARN").map((check) => check.name).sort(compareText),
    errors: doctor.checks.filter((check) => check.status === "FAIL").map((check) => check.name).sort(compareText),
    redaction: {
      fields: redactedConfiguration.redactedFields + checks.redactedFields,
      values: redactedConfiguration.redactedValues + checks.redactedValues,
      environmentIncluded: false,
    },
  };
  return { ...body, sha256: sha256(canonicalJson(body)) };
}
