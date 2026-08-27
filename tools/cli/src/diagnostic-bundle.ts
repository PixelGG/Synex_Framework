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
  return [
      "authorization", "bearer", "cfxkey", "connectionuri", "cookie", "databaseuri",
      "databaseurl", "dburl", "dsn", "license", "licensekey", "mysqluri", "mysqlurl",
      "passphrase", "serverkey", "sessioncookie", "webhookurl",
    ].includes(normalized)
    || [
      "password", "passphrase", "secret", "credential", "webhook", "privatekey",
      "apikey", "accesstoken", "refreshtoken", "connectionstring",
    ].some((fragment) => normalized.includes(fragment))
    || normalized.endsWith("token");
}

const IDENTIFIER_KEYS = new Set([
  "accountid", "aggregateid", "actorid", "actorref", "applicationid", "assignmentid",
  "bindingid", "bindingref", "characterid", "callerprincipalref", "citizenid", "entryid",
  "entityid", "eventid", "findingid", "gradeid", "grantid", "groupid", "holdid", "id",
  "idempotencykey", "identifier", "identifiers", "instanceid", "license2", "membershipid", "outboxid",
  "originaltransactionid", "ownerid", "ownerref", "playersource", "principalref", "proposalid",
  "publicid", "reference", "referenceid", "relationshipid", "refundtransactionid", "roleid",
  "runid", "serverinstanceid", "sessionid", "subjectid", "subjectref", "targetid",
  "transactionid", "userid", "workflowid",
]);
const IDENTIFIER_FRAGMENTS = [
  "account", "aggregate", "actor", "application", "assignment", "binding", "bucket",
  "character", "citizen", "component", "definition", "delegation", "entry", "entity", "event",
  "finding", "grade", "grant", "group", "hold", "invitation", "membership", "outbox", "owner",
  "policy", "principal", "proposal", "recovery", "reference", "refund", "relationship", "role",
  "run", "session", "subject", "target", "transaction", "user", "workflow",
];
const MAXIMUM_DEPTH = 10;
const MAXIMUM_ENTRIES = 2_048;
const MAXIMUM_KEY_BYTES = 96;
const MAXIMUM_STRING_BYTES = 512;
const NO_TRUSTED_NAVIGATION_PATHS = new Set<string>();
const REPOSITORY_PROVIDER_CATALOG_NAVIGATION_PATHS = new Set([
  "providercatalog.providers[].views[].id",
  "providercatalog.providers[].views[].search.kinds[].id",
]);

function normalizedKey(key: string): string {
  return key.replace(/[^a-z0-9]/giu, "").toLowerCase();
}

function isIdentifierKey(
  key: string,
  path: string,
  trustedNavigationPaths: ReadonlySet<string>,
): boolean {
  const normalized = normalizedKey(key);
  if (normalized === "id" && trustedNavigationPaths.has(path)) return false;
  if ((normalized === "from" || normalized === "to") && /edges\[\]\.[a-z0-9]+$/u.test(path)) return true;
  if (IDENTIFIER_KEYS.has(normalized) || /identifiers?$/u.test(normalized)) return true;
  if (!/(?:id|ref)$/u.test(normalized)) return false;
  return IDENTIFIER_FRAGMENTS.some((fragment) => normalized.includes(fragment));
}

function masked(value: unknown): string {
  if (typeof value !== "string") return "[MASKED]";
  if (value.length <= 8) return "****";
  return `${value.slice(0, 4)}...${value.slice(-4)}`;
}

function bounded(value: string, maximum: number): string {
  const candidate = value.toWellFormed();
  if (Buffer.byteLength(candidate, "utf8") <= maximum) return candidate;
  if (maximum <= 3) return ".".repeat(maximum);
  let output = "";
  let bytes = 0;
  for (const character of candidate) {
    const size = Buffer.byteLength(character, "utf8");
    if (bytes + size > maximum - 3) break;
    output += character;
    bytes += size;
  }
  return `${output}...`;
}

export interface RedactionResult {
  value: unknown;
  maskedIdentifiers: number;
  redactedFields: number;
  redactedValues: number;
  replacements: number;
  truncated: boolean;
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

function redactDiagnosticValueWithContext(
  input: unknown,
  options: { revealIdentifiers?: boolean },
  trustedNavigationPaths: ReadonlySet<string>,
): RedactionResult {
  let maskedIdentifiers = 0;
  let redactedFields = 0;
  let redactedValues = 0;
  let remaining = MAXIMUM_ENTRIES;
  let replacements = 0;
  let truncated = false;
  const seen = new WeakSet<object>();
  const visit = (value: unknown, depth: number, path: string): unknown => {
    if (typeof value === "string") {
      const redacted = redactString(value);
      redactedValues += redacted.changes;
      if (Buffer.byteLength(redacted.value.toWellFormed(), "utf8") > MAXIMUM_STRING_BYTES) truncated = true;
      return bounded(redacted.value, MAXIMUM_STRING_BYTES);
    }
    if (typeof value === "number") {
      if (Number.isFinite(value)) return value;
      replacements += 1;
      return "[NON_FINITE]";
    }
    if (value === null || typeof value === "boolean") return value;
    if ((typeof value !== "object" && typeof value !== "function") || value === undefined) {
      replacements += 1;
      return `[${String(typeof value).toUpperCase()}]`;
    }
    if (depth >= MAXIMUM_DEPTH) {
      truncated = true;
      return "[DEPTH_LIMIT]";
    }
    if (seen.has(value)) {
      replacements += 1;
      return "[CYCLE]";
    }
    if (!Array.isArray(value) && !isRecord(value)) {
      replacements += 1;
      return `[${String(typeof value).toUpperCase()}]`;
    }
    seen.add(value);
    if (Array.isArray(value)) {
      const output: unknown[] = [];
      for (const nested of value) {
        if (remaining <= 0) {
          output.push("[ENTRY_LIMIT]");
          truncated = true;
          break;
        }
        remaining -= 1;
        output.push(visit(nested, depth + 1, `${path}[]`));
      }
      seen.delete(value);
      return output;
    }
    const output: Record<string, unknown> = {};
    const keys = Reflect.ownKeys(value);
    const stringKeys = keys.filter((key): key is string => typeof key === "string").sort(compareText);
    replacements += keys.length - stringKeys.length;
    for (const key of stringKeys) {
      if (remaining <= 0) {
        output.__truncated = true;
        truncated = true;
        break;
      }
      remaining -= 1;
      const descriptor = Object.getOwnPropertyDescriptor(value, key);
      const nested = descriptor && "value" in descriptor ? descriptor.value : "[ACCESSOR]";
      if (!descriptor || !("value" in descriptor)) replacements += 1;
      const safeKey = bounded(key, MAXIMUM_KEY_BYTES);
      if (safeKey !== key) truncated = true;
      const childPath = path ? `${path}.${normalizedKey(key)}` : normalizedKey(key);
      if (isSecretKey(key)) {
        output[safeKey] = "[REDACTED]";
        redactedFields += 1;
      } else if (!options.revealIdentifiers
        && isIdentifierKey(key, childPath, trustedNavigationPaths)) {
        output[safeKey] = masked(nested);
        maskedIdentifiers += 1;
      } else {
        output[safeKey] = visit(nested, depth + 1, childPath);
      }
    }
    seen.delete(value);
    return output;
  };
  return {
    value: visit(input, 0, ""),
    maskedIdentifiers,
    redactedFields,
    redactedValues,
    replacements,
    truncated,
  };
}

export function redactDiagnosticValue(
  input: unknown,
  options: { revealIdentifiers?: boolean } = {},
): RedactionResult {
  return redactDiagnosticValueWithContext(input, options, NO_TRUSTED_NAVIGATION_PATHS);
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
  runtimeEvidence?: unknown,
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
  const providerCatalog = resources.manifests.flatMap((entry) => {
    const provider = entry.manifest.controlProvider;
    if (!provider) return [];
    return [{
      namespace: provider.namespace,
      resource: entry.manifest.name,
      views: provider.views.map((view) => {
        const projection: {
          id: string;
          search?: { kinds: Array<{ id: string }> };
        } = { id: view.id };
        if (view.search) {
          projection.search = {
            kinds: view.search.kinds.map((kind) => ({ id: kind.id })),
          };
        }
        return projection;
      }),
    }];
  });
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
  const rawBody = {
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
    health: { status: doctor.status, checks: doctor.checks },
    dependencyGraph: {
      nodes: graph.nodes,
      edges: graph.edges,
      cycles: graph.cycles,
      unresolvedRequired: graph.unresolvedRequired,
      dependencyVersions: graph.dependencyVersions,
    },
    providerCatalog: {
      source: "repository-manifests",
      providers: providerCatalog,
    },
    migrations: migrations.sort((left, right) =>
      compareText(left.resource, right.resource) || compareText(left.id, right.id),
    ),
    diagnostics: runtimeEvidence ?? {
      status: "UNAVAILABLE",
      reason: "RUNTIME_CONTROL_EVIDENCE_NOT_SUPPLIED",
    },
    configuration,
    warnings: doctor.checks.filter((check) => check.status === "WARN").map((check) => check.name).sort(compareText),
    errors: doctor.checks.filter((check) => check.status === "FAIL").map((check) => check.name).sort(compareText),
  };
  const sanitized = redactDiagnosticValueWithContext(
    rawBody,
    {},
    REPOSITORY_PROVIDER_CATALOG_NAVIGATION_PATHS,
  );
  const body = isRecord(sanitized.value) ? sanitized.value : {
    artifactKind: "synex-diagnostic-bundle",
    diagnostics: { status: "UNAVAILABLE", reason: "BUNDLE_SANITIZATION_FAILED" },
  };
  body.redaction = {
    fields: sanitized.redactedFields,
    values: sanitized.redactedValues,
    identifiers: sanitized.maskedIdentifiers,
    replacements: sanitized.replacements,
    truncated: sanitized.truncated,
    environmentIncluded: false,
  };
  return { ...body, sha256: sha256(canonicalJson(body)) };
}
