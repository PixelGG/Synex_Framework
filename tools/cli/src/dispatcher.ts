import { spawnSync } from "node:child_process";
import { join, resolve } from "node:path";

import type { CommandIo, Diagnostic, SecurityReport } from "./types.ts";
import { CliError } from "./errors.ts";
import {
  optionBoolean,
  optionString,
  parseArguments,
  resolveRepositoryRoot,
} from "./arguments.ts";
import {
  canonicalize,
  pathExists,
  prettyJson,
  readJsonFile,
  resolveWithin,
  writeFileAtomic,
} from "./filesystem.ts";
import { formatDiagnostic } from "./diagnostics.ts";
import { generateContracts, loadContractSources } from "./contracts.ts";
import { buildResourceGraph, renderResourceGraph } from "./graph.ts";
import { createDiagnosticBundle } from "./diagnostic-bundle.ts";
import { runManagedReload, type ReloadAdapter } from "./dev-reload.ts";
import { loadSchemaRegistry } from "./schemas.ts";
import type { ContractCompatibilityChange } from "./compatibility.ts";
import { compareContracts, scanCompatibility } from "./compatibility.ts";
import {
  createResource,
  inspectPermissions,
  inspectTarget,
  normalizeResourceName,
  resolveResourceDirectory,
} from "./resources.ts";
import { scanSecurity } from "./security.ts";
import type { OperationalCheck } from "./operations.ts";
import {
  certify,
  fuzzContractInputs,
  runBenchmark,
  runDoctor,
  upgradeCheck,
} from "./operations.ts";
import { validateRepository } from "./validation.ts";
import { runMigratorCli } from "../../migrator/src/migrator.ts";
import { npmScriptInvocation } from "./package-runner.ts";
import { prepareCoreLiveTestBundle } from "./live-test-bundle.ts";

function printJson(io: CommandIo, value: unknown): void {
  io.log(JSON.stringify(canonicalize(value), null, 2));
}

function printDiagnostics(io: CommandIo, diagnostics: Diagnostic[]): void {
  if (diagnostics.length === 0) {
    io.log("No validation diagnostics.");
    return;
  }
  for (const diagnostic of diagnostics) io.log(formatDiagnostic(diagnostic));
}

function printSecurity(io: CommandIo, report: SecurityReport): void {
  io.log(`Security scan: ${report.filesScanned} file(s) (${report.filesByLanguage.lua} Lua, ${report.filesByLanguage.typescript} TypeScript/JavaScript), ${report.findings.length} finding(s).`);
  io.log(`TypeScript compiler AST: ${report.typescriptAnalysis.astFiles}/${report.filesByLanguage.typescript} file(s); syntax fallback=${report.typescriptAnalysis.syntaxFallbackFiles}.`);
  for (const finding of report.findings) {
    io.log(
      `${finding.severity.toUpperCase()} confidence=${finding.confidence} ${finding.rule} ${finding.file}:${finding.line} — ${finding.explanation}`,
    );
  }
  if (report.skippedFiles > 0) io.log(`Skipped files: ${report.skippedFiles}.`);
  io.log(report.disclaimer);
}

function printChecks(io: CommandIo, checks: OperationalCheck[]): void {
  for (const check of checks) io.log(`${check.status} ${check.name} — ${check.detail}`);
}

function helpText(): string {
  return [
    "Synex developer CLI",
    "",
    "Usage:",
    "  synex dev",
    "  synex dev reload <resource> [--adapter <plan|local|remote>] [--timeout <ms>] [--force] [--json]",
    "  synex build",
    "  synex test",
    "  synex contract generate [--check] [--json]",
    "  synex contract check [--against <directory>] [--json]",
    "  synex validate [path] [--json]",
    "  synex inspect [resource] <path-or-name> [--json]",
    "  synex inspect graph [--json]",
    "  synex create resource <synex_name> [--path <parent>] [--json]",
    "  synex doctor [path] [--bundle] [--output <file>] [--json]",
    "  synex permissions [path] [--json]",
    "  synex security scan [path] [--json]",
    "  synex security fuzz [path] [--json]",
    "  synex certify <repository|resource|path> [--output <file>] [--json]",
    "  synex compat scan [path] [--json]",
    "  synex benchmark [--iterations <count>] [--baseline <file>] [--output <file>] [--json]",
    "  synex upgrade-check [path] [--against <repository>] [--json]",
    "  synex live-test prepare --probe <external-directory> [--output <.temp/live-test/directory>] [--json]",
    "  synex migrate <qb|qbx|esx> --dry-run --source <file> --mapping <file>",
    "",
    "Global option: --root <repository>",
  ].join("\n");
}

function runPackageScript(repositoryRoot: string, script: "build" | "test"): number {
  const invocation = npmScriptInvocation(script);
  const result = spawnSync(invocation.executable, invocation.arguments, {
    cwd: repositoryRoot,
    env: process.env,
    stdio: "inherit",
    windowsHide: true,
  });
  if (result.error) throw new CliError(`Unable to launch npm run ${script}: ${result.error.message}`);
  return result.status ?? 1;
}

async function runDevelopmentWatch(repositoryRoot: string): Promise<number> {
  const generation = await generateContracts(repositoryRoot, false);
  if (generation.stale.length > 0) return 1;
  const validation = await validateRepository(repositoryRoot);
  if (validation.diagnostics.some((diagnostic) => diagnostic.level === "error")) return 1;
  const compiler = join(repositoryRoot, "node_modules", "typescript", "bin", "tsc");
  if (!(await pathExists(compiler))) {
    throw new CliError("TypeScript is not installed; run npm ci before synex dev.", 2);
  }
  const result = spawnSync(
    process.execPath,
    [compiler, "--build", "--watch", "--preserveWatchOutput", "false"],
    { cwd: repositoryRoot, env: process.env, stdio: "inherit", windowsHide: true },
  );
  if (result.error) throw new CliError(`Unable to start the development watcher: ${result.error.message}`);
  return result.status ?? 1;
}

async function checkContractCompatibility(
  repositoryRoot: string,
  againstPath: string,
): Promise<ContractCompatibilityChange[]> {
  const schemas = await loadSchemaRegistry(repositoryRoot);
  const current = await loadContractSources(repositoryRoot, schemas);
  const previous = await loadContractSources(repositoryRoot, schemas, resolve(againstPath));
  const diagnostics = [...current.diagnostics, ...previous.diagnostics].filter((diagnostic) => diagnostic.level === "error");
  if (diagnostics.length > 0) throw new CliError(`Contract comparison failed:\n${diagnostics.map(formatDiagnostic).join("\n")}`);
  return compareContracts(previous.sources, current.sources);
}

function hasBlockingSecurity(report: SecurityReport): boolean {
  return report.findings.some(
    (finding) =>
      (finding.severity === "critical" && finding.confidence !== "low") ||
      (finding.severity === "high" && finding.confidence === "high"),
  );
}

export async function runCli(
  argumentsList: string[],
  io: CommandIo = console,
): Promise<number> {
  try {
    if (argumentsList[0] === "migrate") {
      const migratedArguments = argumentsList.slice(1);
      const framework = migratedArguments[0];
      if (framework === "qb" || framework === "qbx" || framework === "esx") {
        migratedArguments.splice(0, 1, "--framework", framework);
      }
      const dryRun = migratedArguments.indexOf("--dry-run");
      if (dryRun >= 0) migratedArguments.splice(dryRun, 1);
      return runMigratorCli(migratedArguments, io);
    }
    const parsed = parseArguments(argumentsList);
    if (optionBoolean(parsed, "help") || parsed.positionals.length === 0) {
      io.log(helpText());
      return 0;
    }
    const repositoryRoot = await resolveRepositoryRoot(parsed);
    const json = optionBoolean(parsed, "json");
    const [command, subcommand] = parsed.positionals;

    if (command === "build") {
      if (subcommand) throw new CliError("build does not accept positional arguments.", 2);
      return runPackageScript(repositoryRoot, "build");
    }

    if (command === "test") {
      if (subcommand) throw new CliError("test does not accept positional arguments.", 2);
      return runPackageScript(repositoryRoot, "test");
    }

    if (command === "dev") {
      if (subcommand === "reload") {
        const requestedResource = parsed.positionals[2];
        if (!requestedResource) throw new CliError("dev reload requires a resource path or name.", 2);
        if (parsed.positionals[3]) throw new CliError("dev reload accepts exactly one resource.", 2);
        const adapter = (optionString(parsed, "adapter") ?? "plan") as ReloadAdapter;
        const timeoutValue = optionString(parsed, "timeout");
        const timeout = timeoutValue ? Number(timeoutValue) : 5_000;
        const report = await runManagedReload(repositoryRoot, requestedResource, adapter, optionBoolean(parsed, "force"), timeout);
        if (json) printJson(io, report);
        else {
          io.log(`Managed reload: ${report.status}; adapter=${report.adapter}; executed=${report.executed}.`);
          for (const action of report.actions) io.log(`${action.status} ${action.stage} ${action.resource} — ${action.detail}`);
          for (const limit of report.limits) io.log(`LIMIT ${limit}`);
        }
        return report.status === "FAIL" ? 1 : 0;
      }
      if (subcommand) throw new CliError("dev accepts only the reload subcommand.", 2);
      return runDevelopmentWatch(repositoryRoot);
    }

    if (command === "contract" && subcommand === "generate") {
      const checkOnly = optionBoolean(parsed, "check");
      const result = await generateContracts(repositoryRoot, checkOnly);
      if (json) printJson(io, result);
      else {
        io.log(`Contracts: ${result.contractCount}; source hash ${result.sourceHash}.`);
        io.log(
          result.changed.length > 0
            ? `${checkOnly ? "Stale" : "Changed"}: ${result.changed.join(", ")}.`
            : "Generated outputs are current.",
        );
      }
      return result.stale.length > 0 ? 1 : 0;
    }

    if (command === "contract" && subcommand === "check") {
      const generation = await generateContracts(repositoryRoot, true);
      const against = optionString(parsed, "against");
      const compatibility = against ? await checkContractCompatibility(repositoryRoot, against) : [];
      if (json) printJson(io, { generation, compatibility });
      else {
        io.log(generation.stale.length === 0 ? "Generated contract outputs are current." : `Stale outputs: ${generation.stale.join(", ")}.`);
        for (const change of compatibility) io.log(`${change.level.toUpperCase()} ${change.contract} — ${change.message}`);
      }
      return generation.stale.length > 0 || compatibility.some((change) => change.level === "breaking") ? 1 : 0;
    }

    if (command === "validate") {
      const target = resolveWithin(repositoryRoot, parsed.positionals[1] ?? ".");
      const report = await validateRepository(repositoryRoot, target);
      if (json) printJson(io, report);
      else {
        io.log(`Validated ${report.filesChecked} file(s) across ${report.resources} resource(s).`);
        printDiagnostics(io, report.diagnostics);
      }
      return report.diagnostics.some((diagnostic) => diagnostic.level === "error") ? 1 : 0;
    }

    if (command === "inspect") {
      if (subcommand === "graph") {
        if (parsed.positionals[2]) throw new CliError("inspect graph does not accept a target.", 2);
        const report = await buildResourceGraph(repositoryRoot);
        if (json) printJson(io, report);
        else {
          io.log(renderResourceGraph(report));
          const unusedContracts = report.usage.contracts.filter((entry) => entry.unused);
          const unusedServices = report.usage.services.filter((entry) => entry.unused);
          io.log(`Unused declarations: ${unusedContracts.length} contract(s), ${unusedServices.length} service(s).`);
          io.log(report.usage.disclaimer);
        }
        return report.cycles.length > 0 || report.unresolvedRequired.length > 0
          || report.dependencyVersions.some((finding) => finding.severity === "error")
          ? 1
          : 0;
      }
      const targetArgument = subcommand === "resource" ? parsed.positionals[2] : subcommand;
      const report = await inspectTarget(repositoryRoot, targetArgument ?? ".");
      if (json) printJson(io, report);
      else printJson(io, report);
      return 0;
    }

    if (command === "create" && subcommand === "resource") {
      const requestedName = parsed.positionals[2];
      if (!requestedName) throw new CliError("create resource requires a resource name.", 2);
      const name = normalizeResourceName(requestedName);
      const created = await createResource(repositoryRoot, requestedName, optionString(parsed, "path") ?? "resources");
      if (json) printJson(io, { resource: name, created });
      else io.log(`Created ${name}: ${created.join(", ")}.`);
      return 0;
    }

    if (command === "doctor") {
      const target = resolveWithin(repositoryRoot, subcommand ?? ".");
      const report = await runDoctor(repositoryRoot, target);
      let bundlePath: string | null = null;
      if (optionBoolean(parsed, "bundle")) {
        const requestedOutput = optionString(parsed, "output");
        const defaultName = `doctor-${new Date().toISOString().replace(/[:.]/gu, "-")}.json`;
        const output = resolveWithin(repositoryRoot, requestedOutput ?? join(".synex", "diagnostics", defaultName));
        await writeFileAtomic(output, prettyJson(await createDiagnosticBundle(repositoryRoot, target, report)));
        bundlePath = output.slice(repositoryRoot.length + 1).replaceAll("\\", "/");
      } else if (optionString(parsed, "output")) {
        throw new CliError("doctor --output requires --bundle.", 2);
      }
      if (json) printJson(io, bundlePath ? { ...report, bundle: bundlePath } : report);
      else {
        printChecks(io, report.checks);
        io.log(`Doctor: ${report.status}.`);
        if (bundlePath) io.log(`Redacted diagnostics bundle: ${bundlePath}.`);
      }
      return report.status === "FAIL" ? 1 : 0;
    }

    if (command === "permissions") {
      const target = resolveWithin(repositoryRoot, subcommand ?? ".");
      const report = await inspectPermissions(repositoryRoot, target);
      if (json) printJson(io, report);
      else {
        for (const resource of report.resources) {
          io.log(`${resource.resource}: requested=${resource.requested.length}, granted=${resource.granted.length}, denied=${resource.denied.length}, ungranted=${resource.notGranted.length}, used=${resource.staticallyUsed.length}, undeclared=${resource.undeclared.length}, unused=${resource.unused.length}.`);
        }
        printDiagnostics(io, report.diagnostics);
      }
      return report.diagnostics.some((diagnostic) => diagnostic.level === "error") ? 1 : 0;
    }

    if (command === "security" && subcommand === "scan") {
      const target = resolveWithin(repositoryRoot, parsed.positionals[2] ?? ".");
      const report = await scanSecurity(repositoryRoot, target);
      if (json) printJson(io, report);
      else printSecurity(io, report);
      return hasBlockingSecurity(report) ? 1 : 0;
    }

    if (command === "security" && subcommand === "fuzz") {
      const target = resolveWithin(repositoryRoot, parsed.positionals[2] ?? ".");
      const report = await fuzzContractInputs(repositoryRoot, target);
      if (json) printJson(io, report);
      else {
        io.log(`Contract fuzz: ${report.rejected}/${report.cases} malformed case(s) rejected across ${report.contracts} contract(s).`);
        for (const finding of report.unexpectedAccepted) {
          io.log(`FAIL ${finding.contract}@${finding.version} accepted ${finding.case}.`);
        }
        for (const skipped of report.skipped) {
          io.log(`WARN ${skipped.contract}@${skipped.version} — ${skipped.reason}.`);
        }
        for (const scenario of report.runtimeScenarios.scenarios) {
          io.log(`${scenario.status} runtime:${scenario.name} — ${scenario.detail}`);
        }
        io.log(report.runtimeScenarios.reason);
        io.log(report.disclaimer);
      }
      return report.status === "FAIL" ? 1 : 0;
    }

    if (command === "certify") {
      const modeOrPath = subcommand ?? "repository";
      let target = repositoryRoot;
      if (modeOrPath === "resource") {
        const requested = parsed.positionals[2];
        if (!requested) throw new CliError("certify resource requires a path or resource name.", 2);
        target = await resolveResourceDirectory(repositoryRoot, requested);
      } else if (modeOrPath !== "repository") {
        target = resolveWithin(repositoryRoot, modeOrPath);
      }
      const report = await certify(repositoryRoot, target);
      const output = optionString(parsed, "output");
      if (output) await writeFileAtomic(resolveWithin(repositoryRoot, output), prettyJson(report));
      if (json) printJson(io, report);
      else {
        printChecks(io, report.checks);
        io.log(`Certification: ${report.status}.`);
      }
      return report.status === "FAIL" ? 1 : 0;
    }

    if (command === "compat" && subcommand === "scan") {
      const target = resolveWithin(repositoryRoot, parsed.positionals[2] ?? ".");
      const report = await scanCompatibility(repositoryRoot, target);
      if (json) printJson(io, report);
      else {
        io.log(`Compatibility scan: ${report.filesScanned} Lua file(s).`);
        for (const [framework, count] of Object.entries(report.signatureCounts)) io.log(`${framework}: ${count} signature(s).`);
        io.log(report.disclaimer);
      }
      return 0;
    }

    if (command === "benchmark") {
      const iterationsValue = optionString(parsed, "iterations");
      const iterations = iterationsValue ? Number(iterationsValue) : 5_000;
      const baselinePath = optionString(parsed, "baseline");
      const baseline = baselinePath ? await readJsonFile(resolveWithin(repositoryRoot, baselinePath)) : undefined;
      const report = runBenchmark(iterations, baseline);
      const output = optionString(parsed, "output");
      if (output) await writeFileAtomic(resolveWithin(repositoryRoot, output), prettyJson(report));
      if (json) printJson(io, report);
      else {
        for (const [name, measurement] of Object.entries(report.benchmarks)) {
          io.log(`${name}: ${measurement.operationsPerSecond} ops/s (${measurement.medianMilliseconds} ms median). ${measurement.workload}`);
        }
        for (const regression of report.regressions) io.log(`WARN ${regression.benchmark}: ${regression.decreasePercent}% below baseline.`);
        io.log(report.baseline.reason);
        io.log(report.disclaimer);
      }
      return 0;
    }

    if (command === "upgrade-check") {
      const target = resolveWithin(repositoryRoot, subcommand ?? ".");
      const against = optionString(parsed, "against");
      const report = await upgradeCheck(repositoryRoot, target, against ? resolve(against) : undefined);
      if (json) printJson(io, report);
      else {
        for (const blocker of report.blockers) io.log(`BLOCKER ${blocker}`);
        for (const warning of report.warnings) io.log(`WARN ${warning}`);
        io.log(`Upgrade check: ${report.status}.`);
      }
      return report.status === "FAIL" ? 1 : 0;
    }

    if (command === "live-test" && subcommand === "prepare") {
      if (parsed.positionals[2]) throw new CliError("live-test prepare does not accept positional targets.", 2);
      const probe = optionString(parsed, "probe");
      if (!probe) throw new CliError("live-test prepare requires --probe <external-directory>.", 2);
      const report = await prepareCoreLiveTestBundle(repositoryRoot, probe, optionString(parsed, "output") ?? undefined);
      if (json) printJson(io, report);
      else {
        io.log(`Prepared disposable Core live-test bundle at ${report.bundle}.`);
        io.log(`Revision ${report.revision}; probe run ${report.runId}; ${report.grants.length} exact test capability grant(s).`);
        io.log("Not bundled: oxmysql >= 2.14.1, mysql_connection_string, Cfx license, and isolated endpoints.");
        io.log(`Use ${report.configuration}; never deploy this bundle or its derived capability policy.`);
      }
      return 0;
    }

    if (command === "live-test") {
      throw new CliError("live-test accepts only the prepare subcommand.", 2);
    }

    throw new CliError(`Unknown command.\n\n${helpText()}`, 2);
  } catch (error) {
    const message = error instanceof Error ? error.message : "Synex CLI failed.";
    io.error(message);
    return error instanceof CliError ? error.exitCode : 1;
  }
}
