import { Ajv2020 } from "ajv/dist/2020.js";
import { spawnSync } from "node:child_process";
import { basename, join, relative, resolve } from "node:path";
import type { JsonSchema } from "../../../packages/contracts/src/types.js";

import type { ContractFuzzReport, SecurityReport } from "./types.ts";
import { CliError } from "./errors.ts";
import {
  canonicalJson,
  compareText,
  displayPath,
  isDirectory,
  isRecord,
  pathExists,
  readJsonFile,
  readTextFile,
  sha256,
  walkFiles,
} from "./filesystem.ts";
import type { BenchmarkReport } from "./benchmark.ts";
import { runDeterministicBenchmark } from "./benchmark.ts";
import { runDatabaseDoctor } from "./database-doctor.ts";
import { buildResourceGraph } from "./graph.ts";
import { inspectPermissions } from "./resources.ts";
import { runHeadlessRuntimeFuzz } from "./runtime-fuzz.ts";
import { flattenContracts, generateContracts, loadContractSources } from "./contracts.ts";
import { compareContracts } from "./compatibility.ts";
import { formatDiagnostic } from "./diagnostics.ts";
import { loadSchemaRegistry } from "./schemas.ts";
import { scanSecurity } from "./security.ts";
import { compareVersion, parseVersion, satisfiesVersionRange } from "./semver.ts";
import type { ValidationReport } from "./validation.ts";
import { loadResourceManifests, validateRepository } from "./validation.ts";
import { npmScriptInvocation } from "./package-runner.ts";

export type CheckStatus = "PASS" | "WARN" | "FAIL";

export interface OperationalCheck {
  name: string;
  status: CheckStatus;
  detail: string;
}

function overallStatus(checks: OperationalCheck[]): CheckStatus {
  if (checks.some((check) => check.status === "FAIL")) return "FAIL";
  if (checks.some((check) => check.status === "WARN")) return "WARN";
  return "PASS";
}

function isBlockingSecurityFinding(finding: SecurityReport["findings"][number]): boolean {
  return (finding.severity === "critical" && finding.confidence !== "low")
    || (finding.severity === "high" && finding.confidence === "high");
}

async function readPackageMetadata(repositoryRoot: string): Promise<{ version: string; apiVersion: string; nodeEngine: string | null }> {
  const value = await readJsonFile(join(repositoryRoot, "package.json"));
  if (!isRecord(value) || typeof value.version !== "string") {
    throw new CliError("package.json does not declare a valid framework version.");
  }
  const engines = isRecord(value.engines) ? value.engines : null;
  const synex = isRecord(value.synex) ? value.synex : null;
  if (!synex || typeof synex.apiVersion !== "string" || !parseVersion(synex.apiVersion)) {
    throw new CliError("package.json does not declare a valid synex.apiVersion.");
  }
  return {
    version: value.version,
    apiVersion: synex.apiVersion,
    nodeEngine: engines && typeof engines.node === "string" ? engines.node : null,
  };
}

function minimumEngineVersion(range: string | null): string | null {
  if (!range) return null;
  return /(?:>=|\^|~)?\s*([0-9]+\.[0-9]+\.[0-9]+)/u.exec(range)?.[1] ?? null;
}

export async function runDoctor(
  repositoryRoot: string,
  target = repositoryRoot,
): Promise<{ status: CheckStatus; checks: OperationalCheck[] }> {
  const checks: OperationalCheck[] = [];
  const metadata = await readPackageMetadata(repositoryRoot);
  const requiredNode = minimumEngineVersion(metadata.nodeEngine);
  const currentNode = parseVersion(process.versions.node);
  const minimumNode = requiredNode ? parseVersion(requiredNode) : null;
  checks.push({
    name: "node-runtime",
    status: currentNode && minimumNode && compareVersion(currentNode, minimumNode) >= 0 ? "PASS" : "FAIL",
    detail: requiredNode
      ? `Node ${process.versions.node}; required ${metadata.nodeEngine ?? requiredNode}.`
      : "Node engine requirement is missing.",
  });
  checks.push({
    name: "package-lock",
    status: (await pathExists(join(repositoryRoot, "package-lock.json"))) ? "PASS" : "WARN",
    detail: (await pathExists(join(repositoryRoot, "package-lock.json")))
      ? "package-lock.json is present."
      : "package-lock.json is not present; reproducible npm installation cannot be verified.",
  });

  try {
    await loadSchemaRegistry(repositoryRoot);
    checks.push({
      name: "schemas",
      status: "PASS",
      detail: "Contract, resource, state, runtime configuration, and capability-policy schemas compile with Ajv 2020-12.",
    });
  } catch (error) {
    checks.push({ name: "schemas", status: "FAIL", detail: error instanceof Error ? error.message : "Schema compilation failed." });
  }

  try {
    const generation = await generateContracts(repositoryRoot, true);
    checks.push({
      name: "generated-contracts",
      status: generation.stale.length === 0 ? "PASS" : "FAIL",
      detail: generation.stale.length === 0
        ? `${generation.contractCount} contract(s); generated outputs are current.`
        : `Stale generated outputs: ${generation.stale.join(", ")}.`,
    });
  } catch (error) {
    checks.push({ name: "generated-contracts", status: "FAIL", detail: error instanceof Error ? error.message : "Contract check failed." });
  }

  try {
    const validation = await validateRepository(repositoryRoot, target);
    const errors = validation.diagnostics.filter((diagnostic) => diagnostic.level === "error");
    const warnings = validation.diagnostics.filter((diagnostic) => diagnostic.level === "warning");
    checks.push({
      name: "repository-validation",
      status: errors.length > 0 ? "FAIL" : warnings.length > 0 ? "WARN" : "PASS",
      detail: `${validation.filesChecked} file(s), ${errors.length} error(s), ${warnings.length} warning(s).`,
    });
  } catch (error) {
    checks.push({ name: "repository-validation", status: "FAIL", detail: error instanceof Error ? error.message : "Validation failed." });
  }

  const security = await scanSecurity(repositoryRoot, target);
  const blockingSecurity = security.findings.filter(isBlockingSecurityFinding);
  checks.push({
    name: "security-static",
    status: blockingSecurity.length > 0 ? "FAIL" : security.findings.length > 0 ? "WARN" : "PASS",
    detail: `${security.filesScanned} Lua/TypeScript file(s), ${security.typescriptAnalysis.astFiles}/${security.filesByLanguage.typescript} TypeScript compiler-AST file(s), ${security.findings.length} review finding(s). ${security.disclaimer}`,
  });

  try {
    const graph = await buildResourceGraph(repositoryRoot);
    const dependencyVersionErrors = graph.dependencyVersions.filter((finding) => finding.severity === "error");
    const dependencyVersionWarnings = graph.dependencyVersions.filter((finding) => finding.severity === "warning");
    checks.push({
      name: "resource-dependencies",
      status: graph.cycles.length > 0 || graph.unresolvedRequired.length > 0
        || dependencyVersionErrors.length > 0
        ? "FAIL"
        : dependencyVersionWarnings.length > 0 ? "WARN" : "PASS",
      detail: `${graph.nodes.filter((node) => !node.external).length} resource(s), ${graph.edges.length} edge(s), ${graph.cycles.length} cycle(s), ${graph.unresolvedRequired.length} unresolved required declaration(s), ${dependencyVersionErrors.length} incompatible required version(s), ${dependencyVersionWarnings.length} optional/runtime version warning(s).`,
    });
    const unusedContracts = graph.usage.contracts.filter((entry) => entry.unused).length;
    const unusedServices = graph.usage.services.filter((entry) => entry.unused).length;
    checks.push({
      name: "unused-apis",
      status: unusedContracts > 0 || unusedServices > 0 ? "WARN" : "PASS",
      detail: `${unusedContracts} provided contract(s) and ${unusedServices} provided service(s) have no declared consumer in this checkout. ${graph.usage.disclaimer}`,
    });
  } catch (error) {
    checks.push({ name: "resource-dependencies", status: "FAIL", detail: error instanceof Error ? error.message : "Resource graph failed." });
  }

  try {
    const permissions = await inspectPermissions(repositoryRoot, target);
    const errors = permissions.diagnostics.filter((diagnostic) => diagnostic.level === "error");
    const warnings = permissions.diagnostics.filter((diagnostic) => diagnostic.level === "warning");
    const denied = permissions.resources.reduce((total, resource) => total + resource.denied.length + resource.notGranted.length, 0);
    checks.push({
      name: "capabilities",
      status: errors.length > 0 || denied > 0 ? "FAIL" : warnings.length > 0 ? "WARN" : "PASS",
      detail: `${permissions.resources.length} resource policy declaration(s), ${errors.length} error(s), ${warnings.length} warning(s), ${denied} requested but denied/ungranted capability declaration(s).`,
    });
  } catch (error) {
    checks.push({ name: "capabilities", status: "FAIL", detail: error instanceof Error ? error.message : "Capability analysis failed." });
  }

  const schemas = await loadSchemaRegistry(repositoryRoot);
  const resources = await loadResourceManifests(repositoryRoot, resolve(target), schemas);
  const migrationIdentities = new Set<string>();
  const duplicateMigrations: string[] = [];
  let migrationFiles = 0;
  for (const resource of resources.manifests) {
    for (const migration of resource.manifest.migrations) {
      const identity = `${resource.manifest.name}:${migration.id}`;
      if (migrationIdentities.has(identity)) duplicateMigrations.push(identity);
      migrationIdentities.add(identity);
      if (await pathExists(join(resource.directory, migration.path))) migrationFiles += 1;
    }
  }
  checks.push({
    name: "migration-files",
    status: duplicateMigrations.length > 0 || migrationFiles !== migrationIdentities.size ? "FAIL" : "PASS",
    detail: `${migrationFiles}/${migrationIdentities.size} declared forward migration file(s) present; ${duplicateMigrations.length} duplicate identity declaration(s).`,
  });

  const stateDefinitions = await walkFiles(resolve(target), (path) => path.endsWith(".state.json"));
  checks.push({
    name: "state-registrations",
    status: "WARN",
    detail: `${stateDefinitions.length} schema-backed state definition file(s); runtime registrations require an FXServer snapshot for health verification.`,
  });
  const deprecated = security.findings.filter((finding) => /deprecated|legacy/iu.test(finding.rule));
  checks.push({
    name: "deprecated-apis",
    status: deprecated.length > 0 ? "WARN" : "PASS",
    detail: `${deprecated.length} statically detectable deprecated API use(s). Runtime usage counters require an FXServer snapshot.`,
  });
  checks.push({
    name: "provider-health",
    status: "WARN",
    detail: "Provider declarations were checked statically; live provider health requires the restricted FXServer doctor command or a runtime snapshot.",
  });
  checks.push(...await runDatabaseDoctor(repositoryRoot));

  return { status: overallStatus(checks), checks };
}

async function nuiClosedStateCheck(
  repositoryRoot: string,
  resourceDirectory: string,
): Promise<OperationalCheck | null> {
  const fxmanifest = join(resourceDirectory, "fxmanifest.lua");
  if (!(await pathExists(fxmanifest))) return null;
  const manifestText = await readTextFile(fxmanifest);
  if (!/\bui_page\s+["']/u.test(manifestText)) return null;

  const cssFiles = await walkFiles(resourceDirectory, (path) => path.endsWith(".css"));
  const luaFiles = await walkFiles(resourceDirectory, (path) => path.endsWith(".lua"));
  const css = (await Promise.all(cssFiles.map((file) => readTextFile(file)))).join("\n");
  const lua = (await Promise.all(luaFiles.map((file) => readTextFile(file)))).join("\n");
  const closedBlocks = [...css.matchAll(/([^{}]+)\{([^{}]*)\}/gu)].filter((match) =>
    /background(?:-color)?\s*:\s*transparent(?:\s*!important)?/iu.test(match[2] ?? "")
      && /pointer-events\s*:\s*none/iu.test(match[2] ?? ""),
  );
  const transparent = ["html", "body", "#root"].every((selector) =>
    closedBlocks.some((match) => (match[1] ?? "").split(",").some((candidate) => candidate.trim() === selector)),
  );
  const focusCleanup = /SetNuiFocus\s*\(\s*false\s*,\s*false\s*\)/u.test(lua)
    && /on(?:Client)?ResourceStop/u.test(lua);
  return {
    name: `nui-closed-state:${displayPath(repositoryRoot, resourceDirectory)}`,
    status: transparent && focusCleanup ? "PASS" : "WARN",
    detail: transparent && focusCleanup
      ? "Transparent closed surface and resource-stop focus cleanup were found statically."
      : "NUI closed-state guarantees could not be established statically; test transparency and focus cleanup in runtime.",
  };
}

export async function certify(
  repositoryRoot: string,
  target = repositoryRoot,
): Promise<{
  schema: 1;
  artifactKind: "synex-certification";
  generatedAt: string;
  status: CheckStatus;
  framework: { version: string; apiVersion: string };
  target: { path: string; resources: Array<{ name: string; version: string }> };
  revision: { commit: string | null; dirty: boolean | null };
  checks: OperationalCheck[];
  checkHash: string;
  hashes: Record<string, string>;
  validation: ValidationReport;
  security: SecurityReport;
}> {
  const validation = await validateRepository(repositoryRoot, target);
  const security = await scanSecurity(repositoryRoot, target);
  const checks: OperationalCheck[] = [];
  const validationErrors = validation.diagnostics.filter((diagnostic) => diagnostic.level === "error");
  const validationWarnings = validation.diagnostics.filter((diagnostic) => diagnostic.level === "warning");
  checks.push({
    name: "schema-and-manifest-validation",
    status: validationErrors.length > 0 ? "FAIL" : validationWarnings.length > 0 ? "WARN" : "PASS",
    detail: `${validationErrors.length} error(s), ${validationWarnings.length} warning(s).`,
  });

  const blockingSecurity = security.findings.filter(isBlockingSecurityFinding);
  checks.push({
    name: "static-security",
    status: blockingSecurity.length > 0 ? "FAIL" : security.findings.length > 0 ? "WARN" : "PASS",
    detail: `${security.findings.length} finding(s), ${blockingSecurity.length} blocker(s), ${security.typescriptAnalysis.astFiles}/${security.filesByLanguage.typescript} TypeScript compiler-AST file(s). ${security.disclaimer}`,
  });

  const schemas = await loadSchemaRegistry(repositoryRoot);
  const resources = await loadResourceManifests(repositoryRoot, resolve(target), schemas);
  const graph = await buildResourceGraph(repositoryRoot);
  const targetNames = new Set(resources.manifests.map((resource) => resource.manifest.name));
  const cycles = graph.cycles.filter((cycle) => cycle.some((resource) => targetNames.has(resource)));
  const unresolved = graph.unresolvedRequired.filter((entry) => targetNames.has(entry.resource));
  const dependencyVersionErrors = graph.dependencyVersions.filter((entry) =>
    targetNames.has(entry.resource) && entry.severity === "error"
  );
  const dependencyVersionWarnings = graph.dependencyVersions.filter((entry) =>
    targetNames.has(entry.resource) && entry.severity === "warning"
  );
  checks.push({
    name: "dependency-graph",
    status: cycles.length > 0 || unresolved.length > 0 || dependencyVersionErrors.length > 0
      ? "FAIL"
      : dependencyVersionWarnings.length > 0 ? "WARN" : "PASS",
    detail: `${cycles.length} cycle(s), ${unresolved.length} unresolved required declaration(s), ${dependencyVersionErrors.length} incompatible required version(s), ${dependencyVersionWarnings.length} optional/runtime version warning(s).`,
  });

  const permissions = await inspectPermissions(repositoryRoot, target);
  const permissionErrors = permissions.diagnostics.filter((diagnostic) => diagnostic.level === "error");
  const permissionWarnings = permissions.diagnostics.filter((diagnostic) => diagnostic.level === "warning");
  const deniedCapabilities = permissions.resources.reduce(
    (total, resource) => total + resource.denied.length + resource.notGranted.length,
    0,
  );
  checks.push({
    name: "capability-policy",
    status: permissionErrors.length > 0 || deniedCapabilities > 0
      ? "FAIL"
      : permissionWarnings.length > 0 ? "WARN" : "PASS",
    detail: `${permissionErrors.length} error(s), ${permissionWarnings.length} warning(s), ${deniedCapabilities} requested but denied/ungranted capability declaration(s).`,
  });

  const generated = await generateContracts(repositoryRoot, true);
  checks.push({
    name: "generated-contracts",
    status: generated.stale.length > 0 ? "FAIL" : "PASS",
    detail: generated.stale.length > 0 ? `Stale artifact(s): ${generated.stale.join(", ")}.` : `${generated.contractCount} generated contract descriptor(s) are current.`,
  });
  const migrationIdentities = new Set<string>();
  const duplicateMigrations: string[] = [];
  const missingMigrations: string[] = [];
  const outOfOrderMigrations: string[] = [];
  let declaredMigrations = 0;
  for (const resource of resources.manifests) {
    let previousId: string | null = null;
    for (const migration of resource.manifest.migrations) {
      declaredMigrations += 1;
      const identity = `${resource.manifest.name}:${migration.id}`;
      if (migrationIdentities.has(identity)) duplicateMigrations.push(identity);
      migrationIdentities.add(identity);
      if (previousId !== null && compareText(previousId, migration.id) >= 0) outOfOrderMigrations.push(identity);
      previousId = migration.id;
      if (!(await pathExists(join(resource.directory, migration.path)))) missingMigrations.push(identity);
    }
  }
  checks.push({
    name: "migration-artifacts",
    status: duplicateMigrations.length > 0 || missingMigrations.length > 0 || outOfOrderMigrations.length > 0 ? "FAIL" : "PASS",
    detail: `${declaredMigrations} declared migration(s), ${missingMigrations.length} missing, ${duplicateMigrations.length} duplicate identity declaration(s), ${outOfOrderMigrations.length} out of order. Live application is covered only when database tests are configured.`,
  });
  const centralTestFiles = await walkFiles(join(repositoryRoot, "tests"), (path) =>
    /(?:^|[._-])test\.(?:mjs|js|ts|lua)$/u.test(basename(path)),
  );
  const centralTests = await Promise.all(centralTestFiles.map(async (file) => ({
    file,
    text: await readTextFile(file),
  })));
  if (resources.manifests.length === 0) {
    checks.push({ name: "resources", status: "WARN", detail: "No Synex resource manifests were found in the certification target." });
  }
  for (const resource of resources.manifests) {
    const localTestFiles = await walkFiles(resource.directory, (path) => /(?:^|[._-])test\.(?:mjs|js|ts|lua)$/u.test(basename(path)));
    const centralMatches = centralTests
      .filter(({ text }) => text.includes(resource.manifest.name))
      .map(({ file }) => file);
    const testFiles = new Set([...localTestFiles, ...centralMatches]);
    checks.push({
      name: `tests:${resource.manifest.name}`,
      status: testFiles.size > 0 ? "PASS" : "WARN",
      detail: testFiles.size > 0
        ? `${testFiles.size} resource-local or repository test file(s) reference this resource.`
        : "No resource-local or repository test file references this resource.",
    });
    const nui = await nuiClosedStateCheck(repositoryRoot, resource.directory);
    if (nui) checks.push(nui);

    if (resource.manifest.name !== "synex_core") {
      const luaFiles = await walkFiles(resource.directory, (path) => path.endsWith(".lua"));
      let directDatabaseCalls = 0;
      const referencedTables = new Set<string>();
      for (const file of luaFiles) {
        const text = await readTextFile(file);
        directDatabaseCalls += (text.match(/(?:\bMySQL\.|exports\s*\[\s*["']oxmysql["']\s*\])/gu) ?? []).length;
        for (const match of text.matchAll(/`(synex_[a-z0-9_]+)`/gu)) {
          if (match[1]) referencedTables.add(match[1]);
        }
      }
      const ownedTables = new Set(resource.manifest.dataOwnership.tables);
      const unownedTables = [...referencedTables].filter((table) => !ownedTables.has(table)).sort(compareText);
      checks.push({
        name: `persistence-boundary:${resource.manifest.name}`,
        status: unownedTables.length > 0 ? "FAIL" : "PASS",
        detail: unownedTables.length > 0
          ? `Runtime SQL references unowned table(s): ${unownedTables.join(", ")}.`
          : `${directDatabaseCalls} direct database call(s) remain within the manifest-owned table set.`,
      });
    }

    const deprecatedFiles: string[] = [];
    const performanceFindings: string[] = [];
    for (const file of await walkFiles(resource.directory, (path) => path.endsWith(".lua"))) {
      const text = await readTextFile(file);
      if (/\b(?:RegisterServerEvent|lua54\s+["']yes["'])/u.test(text)) deprecatedFiles.push(displayPath(repositoryRoot, file));
      if (/while\s+true\s+do[\s\S]{0,512}?Wait\s*\(\s*0\s*\)/u.test(text)) performanceFindings.push(displayPath(repositoryRoot, file));
    }
    checks.push({
      name: `deprecated-apis:${resource.manifest.name}`,
      status: deprecatedFiles.length > 0 ? "WARN" : "PASS",
      detail: deprecatedFiles.length > 0 ? `Deprecated use in: ${deprecatedFiles.join(", ")}.` : "No statically detectable deprecated API use.",
    });
    checks.push({
      name: `performance-basics:${resource.manifest.name}`,
      status: performanceFindings.length > 0 ? "WARN" : "PASS",
      detail: performanceFindings.length > 0
        ? `Unconditional zero-wait loop candidate(s): ${performanceFindings.join(", ")}.`
        : "No unconditional zero-wait loop was detected statically.",
    });
  }

  const runGate = (script: "check" | "test"): { status: number | null; stdout: string; stderr: string; errorCode: string | null } => {
    let invocation: ReturnType<typeof npmScriptInvocation>;
    try {
      invocation = npmScriptInvocation(script);
    } catch {
      return { status: null, stdout: "", stderr: "", errorCode: "NPM_LAUNCHER_UNAVAILABLE" };
    }
    const result = spawnSync(invocation.executable, invocation.arguments, {
      cwd: repositoryRoot,
      encoding: "utf8",
      env: process.env,
      maxBuffer: 16 * 1024 * 1024,
      timeout: 10 * 60 * 1_000,
      windowsHide: true,
    });
    const errorCode = result.error && "code" in result.error && typeof result.error.code === "string"
      ? result.error.code.replace(/[^A-Z0-9_]/giu, "").slice(0, 64) || "SPAWN_FAILED"
      : null;
    return { status: result.status, stdout: result.stdout ?? "", stderr: result.stderr ?? "", errorCode };
  };
  const checkGate = runGate("check");
  checks.push({
    name: "repository-check-command",
    status: checkGate.status === 0 ? "PASS" : "FAIL",
    detail: checkGate.status === 0
      ? `npm run check completed; output sha256=${sha256(`${checkGate.stdout}\n${checkGate.stderr}`)}.`
      : `npm run check failed (exit ${checkGate.status ?? "unavailable"}, launch=${checkGate.errorCode ?? "none"}); output sha256=${sha256(`${checkGate.stdout}\n${checkGate.stderr}`)}.`,
  });
  let testGate: ReturnType<typeof runGate> | null = null;
  if (checkGate.status === 0) testGate = runGate("test");
  const skipped = testGate ? Number(/# skipped\s+(\d+)/u.exec(testGate.stdout)?.[1] ?? 0) : 0;
  checks.push({
    name: "repository-test-command",
    status: !testGate || testGate.status !== 0 ? "FAIL" : skipped > 0 ? "WARN" : "PASS",
    detail: !testGate
      ? "npm test was not started because npm run check failed."
      : `npm test exit=${testGate.status ?? "unavailable"}, skipped=${skipped}, output sha256=${sha256(`${testGate.stdout}\n${testGate.stderr}`)}.`,
  });

  const hashes: Record<string, string> = {};
  for (const resource of resources.manifests) {
    hashes[displayPath(repositoryRoot, resource.file)] = sha256(await readTextFile(resource.file));
    for (const migration of resource.manifest.migrations) {
      const file = join(resource.directory, migration.path);
      if (await pathExists(file)) hashes[displayPath(repositoryRoot, file)] = sha256((await readTextFile(file)).replace(/\r\n?/gu, "\n"));
    }
    for (const file of await walkFiles(resource.directory, (path) => path.endsWith(".contract.json") || path.endsWith(".contracts.json"))) {
      hashes[displayPath(repositoryRoot, file)] = sha256(await readTextFile(file));
    }
  }
  const commitResult = spawnSync("git", ["rev-parse", "--verify", "HEAD"], {
    cwd: repositoryRoot, encoding: "utf8", timeout: 5_000, windowsHide: true,
  });
  const dirtyResult = spawnSync("git", ["status", "--porcelain=v1", "--untracked-files=normal"], {
    cwd: repositoryRoot, encoding: "utf8", timeout: 5_000, windowsHide: true,
  });
  const metadata = await readPackageMetadata(repositoryRoot);
  const status = overallStatus(checks);
  return {
    schema: 1,
    artifactKind: "synex-certification",
    generatedAt: new Date().toISOString(),
    status,
    framework: { version: metadata.version, apiVersion: metadata.apiVersion },
    target: {
      path: displayPath(repositoryRoot, resolve(target)),
      resources: resources.manifests.map((resource) => ({ name: resource.manifest.name, version: resource.manifest.version })),
    },
    revision: {
      commit: commitResult.status === 0 ? commitResult.stdout.trim() || null : null,
      dirty: dirtyResult.status === 0 ? dirtyResult.stdout.trim().length > 0 : null,
    },
    checks,
    checkHash: sha256(canonicalJson(checks)),
    hashes: Object.fromEntries(Object.entries(hashes).sort(([left], [right]) => compareText(left, right))),
    validation,
    security,
  };
}

export async function upgradeCheck(
  repositoryRoot: string,
  target = repositoryRoot,
  against?: string,
): Promise<{
  status: CheckStatus;
  blockers: string[];
  warnings: string[];
  baseline: string | null;
  deltas: {
    contracts: ReturnType<typeof compareContracts>;
    resources: string[];
    capabilities: string[];
    migrations: string[];
    dataOwnership: string[];
  };
}> {
  const blockers: string[] = [];
  const warnings: string[] = [];
  const deltas = { contracts: [], resources: [], capabilities: [], migrations: [], dataOwnership: [] } as {
    contracts: ReturnType<typeof compareContracts>;
    resources: string[];
    capabilities: string[];
    migrations: string[];
    dataOwnership: string[];
  };
  const metadata = await readPackageMetadata(repositoryRoot);
  const schemas = await loadSchemaRegistry(repositoryRoot);
  const resources = await loadResourceManifests(repositoryRoot, resolve(target), schemas);
  for (const diagnostic of resources.diagnostics) {
    (diagnostic.level === "error" ? blockers : warnings).push(formatDiagnostic(diagnostic));
  }
  for (const resource of resources.manifests) {
    if (!satisfiesVersionRange(metadata.apiVersion, resource.manifest.synex)) {
      blockers.push(`${resource.manifest.name} requires Synex API ${resource.manifest.synex}, current API version is ${metadata.apiVersion}.`);
    }
  }

  const validation = await validateRepository(repositoryRoot, target);
  for (const diagnostic of validation.diagnostics) {
    (diagnostic.level === "error" ? blockers : warnings).push(formatDiagnostic(diagnostic));
  }
  const generation = await generateContracts(repositoryRoot, true);
  if (generation.stale.length > 0) blockers.push(`Generated contract outputs are stale: ${generation.stale.join(", ")}.`);

  const luaFiles = await walkFiles(resolve(target), (path) => path.endsWith(".lua"), { skipTopLevelTests: true });
  for (const file of luaFiles) {
    const text = await readTextFile(file);
    if (/\blua54\s+["']yes["']/u.test(text)) warnings.push(`${displayPath(repositoryRoot, file)} uses deprecated lua54 metadata.`);
    if (/\bRegisterServerEvent\s*\(/u.test(text)) warnings.push(`${displayPath(repositoryRoot, file)} uses deprecated RegisterServerEvent.`);
    if (/esx:getSharedObject/u.test(text)) warnings.push(`${displayPath(repositoryRoot, file)} uses the legacy ESX shared-object event.`);
  }

  if (against) {
    const baselineRoot = resolve(against);
    if (!(await pathExists(join(baselineRoot, "package.json")))) {
      blockers.push("Upgrade baseline does not contain package.json.");
    } else {
      const baselineMetadata = await readPackageMetadata(baselineRoot);
      const previousVersion = parseVersion(baselineMetadata.version);
      const currentVersion = parseVersion(metadata.version);
      if (!previousVersion || !currentVersion) {
        blockers.push("Framework versions cannot be compared as semantic versions.");
      } else if (compareVersion(currentVersion, previousVersion) < 0) {
        blockers.push(`Framework version moves backwards from ${baselineMetadata.version} to ${metadata.version}.`);
      } else if (currentVersion.major > previousVersion.major) {
        warnings.push(`Framework major version changes from ${baselineMetadata.version} to ${metadata.version}; review every compatibility delta.`);
      }
      const previousApi = parseVersion(baselineMetadata.apiVersion);
      const currentApi = parseVersion(metadata.apiVersion);
      if (previousApi && currentApi && compareVersion(currentApi, previousApi) < 0) {
        blockers.push(`Synex API version moves backwards from ${baselineMetadata.apiVersion} to ${metadata.apiVersion}.`);
      }

      const targetedUpgrade = resolve(target) !== resolve(repositoryRoot);
      const baselineContractRoot = targetedUpgrade
        ? join(baselineRoot, relative(repositoryRoot, resolve(target)))
        : baselineRoot;
      if (!(await isDirectory(baselineContractRoot))) {
        blockers.push("The upgrade baseline does not contain the matching contract/resource target path.");
      } else {
        const previousContracts = await loadContractSources(repositoryRoot, schemas, baselineContractRoot);
        const currentContracts = await loadContractSources(
          repositoryRoot,
          schemas,
          targetedUpgrade ? resolve(target) : undefined,
        );
        const contractErrors = [...previousContracts.diagnostics, ...currentContracts.diagnostics]
          .filter((diagnostic) => diagnostic.level === "error");
        if (contractErrors.length > 0) {
          blockers.push(...contractErrors.map(formatDiagnostic));
        } else {
          deltas.contracts = compareContracts(previousContracts.sources, currentContracts.sources);
          for (const change of deltas.contracts) {
            const message = `${change.contract}: ${change.message}`;
            (change.level === "breaking" ? blockers : warnings).push(message);
          }
        }
      }

      const previousResources = await loadResourceManifests(repositoryRoot, baselineRoot, schemas);
      for (const diagnostic of previousResources.diagnostics) {
        (diagnostic.level === "error" ? blockers : warnings).push(`Baseline: ${formatDiagnostic(diagnostic)}`);
      }
      const currentByName = new Map(resources.manifests.map((resource) => [resource.manifest.name, resource]));
      const previousManifests = resolve(target) === resolve(repositoryRoot)
        ? previousResources.manifests
        : previousResources.manifests.filter((resource) => currentByName.has(resource.manifest.name));
      const previousByName = new Map(previousManifests.map((resource) => [resource.manifest.name, resource]));
      for (const [name, previous] of previousByName) {
        const current = currentByName.get(name);
        if (!current) {
          const delta = `Resource ${name} was removed.`;
          deltas.resources.push(delta);
          blockers.push(delta);
          continue;
        }
        const previousResourceVersion = parseVersion(previous.manifest.version);
        const currentResourceVersion = parseVersion(current.manifest.version);
        if (previousResourceVersion && currentResourceVersion && compareVersion(currentResourceVersion, previousResourceVersion) < 0) {
          const delta = `${name} version moves backwards from ${previous.manifest.version} to ${current.manifest.version}.`;
          deltas.resources.push(delta);
          blockers.push(delta);
        }

        const previousCapabilities = new Set(previous.manifest.capabilities.request);
        const currentCapabilities = new Set(current.manifest.capabilities.request);
        for (const capability of [...currentCapabilities].filter((entry) => !previousCapabilities.has(entry)).sort(compareText)) {
          const delta = `${name} requests new capability ${capability}.`;
          deltas.capabilities.push(delta);
          warnings.push(delta);
        }
        for (const capability of [...previousCapabilities].filter((entry) => !currentCapabilities.has(entry)).sort(compareText)) {
          deltas.capabilities.push(`${name} no longer requests capability ${capability}.`);
        }

        const previousMigrations = new Map<string, string>();
        const currentMigrations = new Map<string, string>();
        for (const migration of previous.manifest.migrations) {
          const file = join(previous.directory, migration.path);
          if (await pathExists(file)) previousMigrations.set(migration.id, sha256((await readTextFile(file)).replace(/\r\n?/gu, "\n")));
        }
        for (const migration of current.manifest.migrations) {
          const file = join(current.directory, migration.path);
          if (await pathExists(file)) currentMigrations.set(migration.id, sha256((await readTextFile(file)).replace(/\r\n?/gu, "\n")));
        }
        for (const [id, checksum] of previousMigrations) {
          const currentChecksum = currentMigrations.get(id);
          if (!currentChecksum) {
            const delta = `${name} migration ${id} was removed.`;
            deltas.migrations.push(delta);
            blockers.push(delta);
          } else if (currentChecksum !== checksum) {
            const delta = `${name} migration ${id} changed checksum.`;
            deltas.migrations.push(delta);
            blockers.push(delta);
          }
        }
        for (const id of [...currentMigrations.keys()].filter((entry) => !previousMigrations.has(entry)).sort(compareText)) {
          const delta = `${name} adds migration ${id}.`;
          deltas.migrations.push(delta);
          warnings.push(delta);
        }

        const previousTables = new Set(previous.manifest.dataOwnership.tables);
        const currentTables = new Set(current.manifest.dataOwnership.tables);
        for (const table of [...previousTables].filter((entry) => !currentTables.has(entry)).sort(compareText)) {
          const delta = `${name} removes owned table declaration ${table}.`;
          deltas.dataOwnership.push(delta);
          blockers.push(delta);
        }
        for (const table of [...currentTables].filter((entry) => !previousTables.has(entry)).sort(compareText)) {
          const delta = `${name} adds owned table declaration ${table}.`;
          deltas.dataOwnership.push(delta);
          warnings.push(delta);
        }
      }
      for (const name of [...currentByName.keys()].filter((entry) => !previousByName.has(entry)).sort(compareText)) {
        const delta = `Resource ${name} was added.`;
        deltas.resources.push(delta);
        warnings.push(delta);
      }

      for (const path of ["core/synex_core/config/capabilities.json", "core/synex_core/config/default.json"]) {
        const previousFile = join(baselineRoot, path);
        const currentFile = join(repositoryRoot, path);
        if (await pathExists(previousFile) && await pathExists(currentFile)) {
          const previousHash = sha256(canonicalJson(await readJsonFile(previousFile)));
          const currentHash = sha256(canonicalJson(await readJsonFile(currentFile)));
          if (previousHash !== currentHash) warnings.push(`${path} changed; review policy and runtime configuration deltas.`);
        }
      }
    }
  } else {
    warnings.push("No --against baseline was supplied; contract, migration, capability, and DB ownership deltas were not compared.");
  }

  const uniqueBlockers = [...new Set(blockers)].sort(compareText);
  const uniqueWarnings = [...new Set(warnings)].sort(compareText);
  return {
    status: uniqueBlockers.length > 0 ? "FAIL" : uniqueWarnings.length > 0 ? "WARN" : "PASS",
    blockers: uniqueBlockers,
    warnings: uniqueWarnings,
    baseline: against ? displayPath(repositoryRoot, resolve(against)) : null,
    deltas,
  };
}

export function runBenchmark(iterations = 5_000, baseline?: unknown): BenchmarkReport {
  return runDeterministicBenchmark(iterations, baseline);
}

function schemaPrimaryType(schema: JsonSchema): string | null {
  if (typeof schema.type === "string") return schema.type;
  if (Array.isArray(schema.type)) {
    return schema.type.find((entry): entry is string => typeof entry === "string" && entry !== "null") ?? null;
  }
  if (isRecord(schema.properties)) return "object";
  return null;
}

function sampleString(schema: JsonSchema): string {
  if (Array.isArray(schema.enum) && typeof schema.enum[0] === "string") return schema.enum[0];
  if (typeof schema.const === "string") return schema.const;
  const pattern = typeof schema.pattern === "string" ? schema.pattern : "";
  if (pattern.includes("[0-9a-f-]{36}")) return "11111111-1111-4111-8111-111111111111";
  const repeated = /\{([0-9]+)(?:,([0-9]+))?\}/u.exec(pattern);
  const requested = repeated ? Number(repeated[1]) + (pattern.includes("^[a-z]") ? 1 : 0) : 0;
  const minimum = typeof schema.minLength === "number" ? schema.minLength : 1;
  return "a".repeat(Math.max(1, minimum, requested));
}

function sampleForSchema(schema: JsonSchema, depth = 0): unknown {
  if (depth > 16) return undefined;
  if (Object.hasOwn(schema, "const")) return schema.const;
  if (Array.isArray(schema.enum) && schema.enum.length > 0) return structuredClone(schema.enum[0]);
  for (const union of [schema.oneOf, schema.anyOf]) {
    if (Array.isArray(union)) {
      const branch = union.find((candidate): candidate is JsonSchema => isRecord(candidate));
      if (branch) return sampleForSchema(branch, depth + 1);
    }
  }
  const type = schemaPrimaryType(schema);
  if (type === "string") return sampleString(schema);
  if (type === "integer" || type === "number") {
    const minimum = typeof schema.minimum === "number" ? schema.minimum : 0;
    return type === "integer" ? Math.ceil(minimum) : minimum;
  }
  if (type === "boolean") return false;
  if (type === "null") return null;
  if (type === "array") {
    const minimum = typeof schema.minItems === "number" ? Math.min(schema.minItems, 64) : 0;
    const itemSchema = isRecord(schema.items) ? schema.items : {};
    return Array.from({ length: minimum }, () => sampleForSchema(itemSchema, depth + 1));
  }
  if (type === "object") {
    const properties = isRecord(schema.properties) ? schema.properties : {};
    const required = Array.isArray(schema.required)
      ? schema.required.filter((entry): entry is string => typeof entry === "string")
      : [];
    const output: Record<string, unknown> = {};
    for (const name of required) {
      const property = properties[name];
      if (!isRecord(property)) return undefined;
      output[name] = sampleForSchema(property, depth + 1);
    }
    return output;
  }
  return {};
}

function wrongType(type: string | null): unknown {
  if (type === "string") return 42;
  if (type === "integer" || type === "number") return "not-a-number";
  if (type === "boolean") return 1;
  if (type === "array") return {};
  if (type === "object") return [];
  if (type === "null") return false;
  return null;
}

export async function fuzzContractInputs(
  repositoryRoot: string,
  target = repositoryRoot,
): Promise<ContractFuzzReport> {
  const schemas = await loadSchemaRegistry(repositoryRoot);
  const resolvedTarget = resolve(target);
  const sources = await loadContractSources(
    repositoryRoot,
    schemas,
    resolvedTarget === resolve(repositoryRoot) ? undefined : resolvedTarget,
  );
  const errors = sources.diagnostics.filter((diagnostic) => diagnostic.level === "error");
  if (errors.length > 0) throw new CliError(`Contract fuzzing could not load contracts:\n${errors.map(formatDiagnostic).join("\n")}`);

  const unexpectedAccepted: ContractFuzzReport["unexpectedAccepted"] = [];
  const skipped: ContractFuzzReport["skipped"] = [];
  let cases = 0;
  let rejected = 0;
  const contracts = flattenContracts(sources.sources);

  for (const contract of contracts) {
    const validator = new Ajv2020({ allErrors: true, strict: true, validateFormats: false }).compile(contract.input);
    const baseline = sampleForSchema(contract.input);
    if (!validator(baseline)) {
      skipped.push({ contract: contract.name, version: contract.version, reason: "no deterministic valid baseline for this schema" });
      continue;
    }
    const mutations: Array<{ name: string; value: unknown }> = [];
    const type = schemaPrimaryType(contract.input);
    mutations.push({ name: "wrong-root-type", value: wrongType(type) });

    if (type === "object" && isRecord(baseline)) {
      const properties = isRecord(contract.input.properties) ? contract.input.properties : {};
      const required = Array.isArray(contract.input.required)
        ? contract.input.required.filter((entry): entry is string => typeof entry === "string")
        : [];
      if (contract.input.additionalProperties === false) {
        mutations.push({ name: "unknown-property", value: { ...structuredClone(baseline), __unexpected: true } });
      }
      for (const name of required) {
        const candidate = structuredClone(baseline);
        delete candidate[name];
        mutations.push({ name: `missing-required:${name}`, value: candidate });
      }
      for (const [name, rawProperty] of Object.entries(properties)) {
        if (!isRecord(rawProperty)) continue;
        const invalidType = structuredClone(baseline);
        invalidType[name] = wrongType(schemaPrimaryType(rawProperty));
        mutations.push({ name: `wrong-type:${name}`, value: invalidType });
        if (typeof rawProperty.maxLength === "number" && rawProperty.maxLength >= 0 && rawProperty.maxLength <= 65_536) {
          const oversized = structuredClone(baseline);
          oversized[name] = "x".repeat(rawProperty.maxLength + 1);
          mutations.push({ name: `oversized-string:${name}`, value: oversized });
        }
        if (typeof rawProperty.minimum === "number") {
          const belowMinimum = structuredClone(baseline);
          belowMinimum[name] = rawProperty.minimum - 1;
          mutations.push({ name: `below-minimum:${name}`, value: belowMinimum });
        }
        if (typeof rawProperty.maximum === "number") {
          const aboveMaximum = structuredClone(baseline);
          aboveMaximum[name] = rawProperty.maximum + 1;
          mutations.push({ name: `above-maximum:${name}`, value: aboveMaximum });
        }
        if (typeof rawProperty.pattern === "string") {
          const malformed = structuredClone(baseline);
          malformed[name] = "!";
          mutations.push({ name: `pattern-mismatch:${name}`, value: malformed });
        }
        if (Array.isArray(rawProperty.enum)) {
          const invalidEnum = structuredClone(baseline);
          invalidEnum[name] = "__invalid_enum_value__";
          mutations.push({ name: `invalid-enum:${name}`, value: invalidEnum });
        }
      }
    }

    for (const mutation of mutations) {
      cases += 1;
      if (!validator(mutation.value)) rejected += 1;
      else unexpectedAccepted.push({ contract: contract.name, version: contract.version, case: mutation.name });
    }
  }

  const runtimeScenarios = await runHeadlessRuntimeFuzz(repositoryRoot);
  const status = unexpectedAccepted.length > 0 || runtimeScenarios.failed > 0
    ? "FAIL"
    : skipped.length > 0 || !runtimeScenarios.executed
      ? "WARN"
      : "PASS";
  return {
    status,
    contracts: contracts.length,
    cases,
    rejected,
    unexpectedAccepted,
    skipped,
    runtimeScenarios,
    disclaimer: "Schema mutations and headless Core Lua scenarios do not prove Cfx transport, OneSync, live-database, load, or production security.",
  };
}
