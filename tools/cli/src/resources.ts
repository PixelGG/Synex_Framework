import { lstat, mkdir, realpath, rm, writeFile } from "node:fs/promises";
import { basename, dirname, join, relative, resolve } from "node:path";

import type { Diagnostic } from "./types.ts";
import { CliError } from "./errors.ts";
import {
  compareText,
  containsPath,
  displayPath,
  isDirectory,
  isRecord,
  pathExists,
  prettyJson,
  readJsonFile,
  readTextFile,
  resolveWithin,
  sha256,
  toPosixPath,
  walkFiles,
} from "./filesystem.ts";
import { buildResourceGraph } from "./graph.ts";
import { flattenContracts, loadContractSources } from "./contracts.ts";
import { loadSchemaRegistry } from "./schemas.ts";
import { isResourceManifest, loadResourceManifests } from "./validation.ts";
import {
  luaCallArguments,
  luaExpressionName,
  luaStringLiteral,
  parseLuaAst,
  scanSecurity,
  walkLuaAst,
} from "./security.ts";

const RESOURCE_SCHEMA_PATH = "schemas/resource.schema.json";

export async function resolveResourceDirectory(repositoryRoot: string, requested: string): Promise<string> {
  const direct = resolveWithin(repositoryRoot, requested);
  if (await isDirectory(direct)) return direct;
  const manifests = await walkFiles(repositoryRoot, (path) => basename(path) === "synex.resource.json");
  for (const file of manifests) {
    try {
      const value = await readJsonFile(file);
      if (isResourceManifest(value) && value.name === requested) return dirname(file);
    } catch {
      continue;
    }
  }
  throw new CliError(`Resource ${requested} was not found.`, 2);
}

export async function inspectTarget(repositoryRoot: string, target: string): Promise<Record<string, unknown>> {
  const directory = await resolveResourceDirectory(repositoryRoot, target);
  const manifestPath = join(directory, "synex.resource.json");
  const fxmanifestPath = join(directory, "fxmanifest.lua");
  const manifestValue = (await pathExists(manifestPath)) ? await readJsonFile(manifestPath) : null;
  const luaFiles = await walkFiles(directory, (path) => path.endsWith(".lua"));
  let netEvents = 0;
  let exportsCount = 0;
  let nuiCallbacks = 0;
  let directDatabaseCalls = 0;
  const apiDefinitions: Array<{ kind: "net-event" | "export" | "nui-callback"; name: string; file: string; line: number }> = [];
  const referencedTables = new Set<string>();
  for (const file of luaFiles) {
    const text = await readTextFile(file);
    netEvents += (text.match(/\bRegisterNetEvent\s*\(/gu) ?? []).length;
    exportsCount += (text.match(/\bexports\s*\(/gu) ?? []).length;
    nuiCallbacks += (text.match(/\bRegisterNUICallback\s*\(/gu) ?? []).length;
    directDatabaseCalls += (text.match(/(?:\bMySQL\.|exports\s*\[\s*["']oxmysql["']\s*\])/gu) ?? []).length;
    const lines = text.replace(/\r\n?/gu, "\n").split("\n");
    for (let index = 0; index < lines.length; index += 1) {
      const line = lines[index] ?? "";
      for (const [kind, pattern] of [
        ["net-event", /\bRegisterNetEvent\s*\(\s*["']([^"']+)["']/u],
        ["export", /\bexports\s*\(\s*["']([^"']+)["']/u],
        ["nui-callback", /\bRegisterNUICallback\s*\(\s*["']([^"']+)["']/u],
      ] as const) {
        const match = pattern.exec(line);
        if (match?.[1]) apiDefinitions.push({ kind, name: match[1], file: displayPath(repositoryRoot, file), line: index + 1 });
      }
    }
    for (const match of text.matchAll(/`(synex_[a-z0-9_]+)`/gu)) {
      if (match[1]) referencedTables.add(match[1]);
    }
  }
  const security = await scanSecurity(repositoryRoot, directory);
  const graph = await buildResourceGraph(repositoryRoot);
  const resourceName = isResourceManifest(manifestValue) ? manifestValue.name : basename(directory);
  const permissions = await inspectPermissions(repositoryRoot, directory);
  const permission = permissions.resources.find((entry) => entry.resource === resourceName) ?? null;
  const ownedTables = isResourceManifest(manifestValue) ? new Set(manifestValue.dataOwnership.tables) : new Set<string>();
  const migrationDetails = [];
  if (isResourceManifest(manifestValue)) {
    for (const migration of manifestValue.migrations) {
      const file = resolveWithin(directory, migration.path);
      migrationDetails.push({
        id: migration.id,
        path: displayPath(repositoryRoot, file),
        transactional: migration.transactional,
        present: await pathExists(file),
        sha256: (await pathExists(file)) ? sha256(await readTextFile(file)) : null,
      });
    }
  }
  return {
    resource: resourceName,
    path: displayPath(repositoryRoot, directory),
    manifest: isResourceManifest(manifestValue)
      ? {
          name: manifestValue.name,
          version: manifestValue.version,
          synex: manifestValue.synex,
          critical: manifestValue.critical,
          capabilities: manifestValue.capabilities.request,
          services: manifestValue.services,
          contracts: manifestValue.contracts,
          events: manifestValue.events,
          hooks: manifestValue.hooks,
          dependencies: manifestValue.dependencies,
          migrations: manifestValue.migrations.map((migration) => migration.id),
          dataOwnership: manifestValue.dataOwnership,
          stateSnapshot: manifestValue.stateSnapshot,
        }
      : null,
    fxmanifest: await pathExists(fxmanifestPath),
    luaFiles: luaFiles.map((file) => displayPath(repositoryRoot, file)),
    apiSurface: {
      netEvents,
      exports: exportsCount,
      nuiCallbacks,
      directDatabaseCalls,
      definitions: apiDefinitions.sort((left, right) => compareText(left.file, right.file) || left.line - right.line),
    },
    dependencies: graph.edges.filter((edge) => edge.from === resourceName),
    dependencyCycles: graph.cycles.filter((cycle) => cycle.includes(resourceName)),
    capabilities: permission,
    contracts: graph.usage.contracts.filter((entry) => entry.provider === resourceName || entry.consumers.includes(resourceName)),
    services: graph.usage.services.filter((entry) => entry.provider === resourceName || entry.consumers.includes(resourceName)),
    migrations: migrationDetails,
    persistence: {
      ownedTables: [...ownedTables].sort(compareText),
      referencedTables: [...referencedTables].sort(compareText),
      foreignTableReferences: [...referencedTables].filter((table) => !ownedTables.has(table)).sort(compareText),
    },
    security: {
      filesScanned: security.filesScanned,
      filesByLanguage: security.filesByLanguage,
      typescriptAnalysis: security.typescriptAnalysis,
      findings: security.findings.length,
      critical: security.findings.filter((finding) => finding.severity === "critical").length,
      high: security.findings.filter((finding) => finding.severity === "high").length,
      deprecatedUsage: security.findings.filter((finding) => /deprecated|legacy/iu.test(finding.rule)),
      disclaimer: security.disclaimer,
    },
  };
}

interface PermissionResourceReport {
  resource: string;
  requested: string[];
  staticallyUsed: string[];
  undeclared: string[];
  unused: string[];
  granted: string[];
  denied: string[];
  notGranted: string[];
}

function wildcardCovers(pattern: string, capability: string): boolean {
  if (pattern === capability || pattern === "*") return true;
  if (!pattern.endsWith(".*")) return false;
  const prefix = pattern.slice(0, -1);
  return capability.startsWith(prefix);
}

function policyCovers(pattern: string, requested: string): boolean {
  if (!requested.endsWith(".*")) return wildcardCovers(pattern, requested);
  if (pattern === requested || pattern === "*") return true;
  return pattern.endsWith(".*") && requested.startsWith(pattern.slice(0, -1));
}

export async function inspectPermissions(
  repositoryRoot: string,
  target = repositoryRoot,
): Promise<{ resources: PermissionResourceReport[]; diagnostics: Diagnostic[] }> {
  const schemas = await loadSchemaRegistry(repositoryRoot);
  const manifests = await loadResourceManifests(repositoryRoot, resolve(target), schemas);
  const contracts = await loadContractSources(repositoryRoot, schemas);
  const byName = new Map(
    flattenContracts(contracts.sources).map((contract) => [contract.name, contract]),
  );
  const reports: PermissionResourceReport[] = [];
  const diagnostics = [...manifests.diagnostics, ...contracts.diagnostics];
  let capabilityPolicy: Record<string, unknown> = {};
  try {
    const loadedPolicy = await readJsonFile(join(repositoryRoot, "core", "synex_core", "config", "capabilities.json"));
    if (isRecord(loadedPolicy)) capabilityPolicy = loadedPolicy;
  } catch {
    diagnostics.push({
      level: "warning",
      rule: "capability-policy-unavailable",
      file: "core/synex_core/config/capabilities.json",
      message: "Capability grants and denies could not be resolved.",
    });
  }
  const defaultPolicy = isRecord(capabilityPolicy.default) ? capabilityPolicy.default : {};
  const resourcePolicies = isRecord(capabilityPolicy.resources) ? capabilityPolicy.resources : {};

  for (const loaded of manifests.manifests) {
    const used = new Set<string>();
    for (const consumed of loaded.manifest.contracts.consume) {
      const capability = byName.get(consumed)?.capability;
      if (capability) used.add(capability);
    }
    const luaFiles = await walkFiles(loaded.directory, (path) => path.endsWith(".lua"));
    for (const file of luaFiles) {
      const text = await readTextFile(file);
      const parsed = parseLuaAst(text);
      if (!parsed.ast) {
        diagnostics.push({
          level: "warning",
          rule: "permission-ast-unavailable",
          file: displayPath(repositoryRoot, file),
          message: `Lua AST analysis failed; lexical fallback was used: ${parsed.error ?? "unknown parser error"}`,
        });
      } else {
        walkLuaAst(parsed.ast, (node) => {
          if (node.type !== "CallExpression") return;
          const call = luaExpressionName(node.base);
          if (!call || !/(?:Capabilities?\.(?:require|check)|requireCapability)$/u.test(call)) return;
          const capability = luaStringLiteral(luaCallArguments(node)[0]);
          if (capability && /^[a-z][a-z0-9._-]+$/u.test(capability)) used.add(capability);
        });
      }
      for (const match of text.matchAll(/(?:Capabilities?\.(?:require|check)|requireCapability)\s*\(\s*["']([a-z][a-z0-9._-]+)["']/giu)) {
        const capability = match[1];
        if (capability) used.add(capability);
      }
    }
    const requested = new Set(loaded.manifest.capabilities.request);
    const undeclared = [...used].filter((capability) => !requested.has(capability)).sort(compareText);
    const unused = [...requested].filter((capability) => !used.has(capability)).sort(compareText);
    const rawResourcePolicy = resourcePolicies[loaded.manifest.name];
    const resourcePolicy = isRecord(rawResourcePolicy) ? rawResourcePolicy : {};
    const allowedPatterns = [
      ...(Array.isArray(defaultPolicy.allow) ? defaultPolicy.allow : []),
      ...(Array.isArray(resourcePolicy.allow) ? resourcePolicy.allow : []),
    ].filter((entry): entry is string => typeof entry === "string");
    const deniedPatterns = [
      ...(Array.isArray(defaultPolicy.deny) ? defaultPolicy.deny : []),
      ...(Array.isArray(resourcePolicy.deny) ? resourcePolicy.deny : []),
    ].filter((entry): entry is string => typeof entry === "string");
    const denied = [...requested].filter((capability) => deniedPatterns.some((pattern) => policyCovers(pattern, capability))).sort(compareText);
    const granted = [...requested].filter((capability) =>
      !denied.includes(capability) && allowedPatterns.some((pattern) => policyCovers(pattern, capability)),
    ).sort(compareText);
    const notGranted = [...requested].filter((capability) => !denied.includes(capability) && !granted.includes(capability)).sort(compareText);
    reports.push({
      resource: loaded.manifest.name,
      requested: [...requested].sort(compareText),
      staticallyUsed: [...used].sort(compareText),
      undeclared,
      unused,
      granted,
      denied,
      notGranted,
    });
    for (const capability of undeclared) {
      diagnostics.push({
        level: "error",
        rule: "capability-undeclared",
        file: displayPath(repositoryRoot, loaded.file),
        message: `Capability ${capability} is statically used but not requested.`,
      });
    }
    for (const capability of unused) {
      diagnostics.push({
        level: "warning",
        rule: "capability-unused",
        file: displayPath(repositoryRoot, loaded.file),
        message: `Capability ${capability} is declared but no static use was found. Dynamic use may require manual review.`,
      });
    }
    for (const capability of denied) {
      diagnostics.push({
        level: "error",
        rule: "capability-denied",
        file: displayPath(repositoryRoot, loaded.file),
        message: `Requested capability ${capability} is explicitly denied by the effective policy.`,
      });
    }
    for (const capability of notGranted) {
      diagnostics.push({
        level: "error",
        rule: "capability-not-granted",
        file: displayPath(repositoryRoot, loaded.file),
        message: `Requested capability ${capability} is not granted by the effective policy.`,
      });
    }
  }
  reports.sort((left, right) => compareText(left.resource, right.resource));
  return { resources: reports, diagnostics };
}

function schemaReference(resourceDirectory: string, repositoryRoot: string): string {
  const path = toPosixPath(relative(resourceDirectory, join(repositoryRoot, RESOURCE_SCHEMA_PATH)));
  return path.startsWith(".") ? path : `./${path}`;
}

export function normalizeResourceName(requestedName: string): string {
  const name = requestedName.startsWith("synex_") ? requestedName : `synex_${requestedName}`;
  if (!/^synex_[a-z0-9_]+$/u.test(name) || name.length > 64) {
    throw new CliError("Resource name must use lowercase letters, digits, or underscores and be at most 58 characters without the synex_ prefix.", 2);
  }
  return name;
}

export async function createResource(
  repositoryRoot: string,
  requestedName: string,
  parentPath = "resources",
): Promise<string[]> {
  const name = normalizeResourceName(requestedName);
  const parent = resolveWithin(repositoryRoot, parentPath);
  const directory = resolveWithin(parent, name);
  if (await pathExists(directory)) throw new CliError(`Resource ${name} already exists.`, 2);

  const existingManifestFiles = await walkFiles(repositoryRoot, (path) => basename(path) === "synex.resource.json");
  let coreVersion: string | null = null;
  for (const file of existingManifestFiles) {
    try {
      const value = await readJsonFile(file);
      if (!isResourceManifest(value)) continue;
      if (value.name === name) {
        throw new CliError(`Resource name ${name} is already declared in ${displayPath(repositoryRoot, file)}.`, 2);
      }
      if (value.name === "synex_core") coreVersion = value.version;
    } catch (error) {
      if (error instanceof CliError && error.message.startsWith("Resource name ")) throw error;
    }
  }
  const packageValue = await readJsonFile(join(repositoryRoot, "package.json"));
  const packageSynex = isRecord(packageValue) && isRecord(packageValue.synex) ? packageValue.synex : null;
  const apiVersion = packageSynex && typeof packageSynex.apiVersion === "string" ? packageSynex.apiVersion : null;
  if (!apiVersion) throw new CliError("package.json must declare synex.apiVersion before resources can be scaffolded.", 2);
  const frameworkVersion = isRecord(packageValue) && typeof packageValue.version === "string" ? packageValue.version : null;
  const dependencyVersion = coreVersion ?? frameworkVersion;
  if (name !== "synex_core" && !dependencyVersion) {
    throw new CliError("The synex_core or framework version could not be resolved for the scaffold dependency.", 2);
  }

  const dependencies = name === "synex_core" ? [] : [{ name: "synex_core", version: `>=${dependencyVersion as string}` }];
  const resourceManifest = {
    $schema: schemaReference(directory, repositoryRoot),
    schema: 1,
    name,
    version: "0.1.0",
    synex: `^${apiVersion}`,
    critical: false,
    capabilities: { request: [] },
    services: { provide: [], require: [], optional: [] },
    contracts: { provide: [], consume: [] },
    events: { publish: [], subscribe: [] },
    hooks: { register: [], run: [] },
    dependencies: { required: dependencies, optional: [], development: [] },
    migrations: [],
    dataOwnership: { tables: [], characterDelete: "none" },
    stateSnapshot: { supported: false, schemaVersion: 1 },
  };
  const dependencyLine = name === "synex_core" ? "" : "\ndependency 'synex_core'\n";
  const files = new Map<string, string>([
    [
      "fxmanifest.lua",
      `fx_version 'cerulean'\ngame 'gta5'\n\nname '${name}'\ndescription '${name} Synex resource'\nversion '0.1.0'\n${dependencyLine}\nsynex_manifest 'synex.resource.json'\n\nshared_script 'shared/config.lua'\nclient_script 'client/main.lua'\nserver_script 'server/main.lua'\n\nfiles {\n    'synex.resource.json'\n}\n`,
    ],
    ["synex.resource.json", prettyJson(resourceManifest)],
    [
      "README.md",
      `# ${name}\n\nMinimal runnable Synex resource scaffold. It intentionally declares no contracts, migrations, services, or capabilities until their implementation is added.\n\nRun the repository validation, tooling tests, and certification gates before deployment.\n`,
    ],
    [
      "shared/config.lua",
      `local config = {\n    resource = '${name}',\n    version = '0.1.0'\n}\n\nreturn config\n`,
    ],
    [
      "server/main.lua",
      "-- Server entrypoint. Keep mutations server-authoritative and validate every external input.\n",
    ],
    [
      "client/main.lua",
      "-- Client entrypoint. Add only client presentation and game-integration behavior here.\n",
    ],
    [
      "contracts/README.md",
      "# Contracts\n\nAdd schema-valid `*.contracts.json` definitions here only when the resource exposes a real API.\n",
    ],
    [
      "migrations/README.md",
      "# Migrations\n\nAdd immutable, forward-only SQL migrations here and declare each file in `synex.resource.json`.\n",
    ],
    [
      "tests/resource.test.mjs",
      `import assert from 'node:assert/strict';\nimport { readFile } from 'node:fs/promises';\nimport test from 'node:test';\n\nconst manifestUrl = new URL('../synex.resource.json', import.meta.url);\n\ntest('${name} manifest identity', async () => {\n  const manifest = JSON.parse(await readFile(manifestUrl, 'utf8'));\n  assert.equal(manifest.name, '${name}');\n  assert.equal(manifest.schema, 1);\n});\n`,
    ],
  ]);

  const parentRelative = relative(repositoryRoot, parent);
  let existingAncestor = resolve(repositoryRoot);
  for (const component of parentRelative.split(/[\\/]/u).filter(Boolean)) {
    const candidate = join(existingAncestor, component);
    const metadata = await lstat(candidate).catch(() => null);
    if (!metadata) break;
    if (metadata.isSymbolicLink() || !metadata.isDirectory()) {
      throw new CliError("Resource parent must not traverse symbolic links or non-directory path components.", 2);
    }
    existingAncestor = candidate;
  }
  const [realRepository, realAncestor] = await Promise.all([
    realpath(repositoryRoot),
    realpath(existingAncestor),
  ]);
  if (!containsPath(realRepository, realAncestor)) {
    throw new CliError("Resource parent must resolve inside the repository boundary.", 2);
  }
  await mkdir(parent, { recursive: true });
  const [realParent, parentMetadata] = await Promise.all([realpath(parent), lstat(parent)]);
  if (!parentMetadata.isDirectory() || parentMetadata.isSymbolicLink() || !containsPath(realRepository, realParent)) {
    throw new CliError("Resource parent must be a real directory inside the repository boundary.", 2);
  }
  await mkdir(directory, { recursive: false });
  const created: string[] = [];
  try {
    for (const [relativePath, contents] of files) {
      const file = resolveWithin(directory, relativePath);
      await mkdir(dirname(file), { recursive: true });
      await writeFile(file, contents, { encoding: "utf8", flag: "wx" });
      created.push(displayPath(repositoryRoot, file));
    }
  } catch (error) {
    await rm(directory, { recursive: true, force: true });
    throw error;
  }
  return created;
}
