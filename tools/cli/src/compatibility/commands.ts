import type { CommandIo } from "../types.ts";
import { CliError } from "../errors.ts";
import { resolveWithin } from "../filesystem.ts";
import {
  buildCompatibilityMatrix,
  buildCompatibilityStatus,
  doctorCompatibility,
  explainCompatibility,
  inspectCompatibilityProfile,
  listCompatibilityAdapters,
} from "./analysis.ts";
import { loadCompatibilityCatalog } from "./catalog.ts";
import { loadCompatibilityRuntimeEvidence } from "./evidence.ts";
import {
  compatibilityExecutionOutputPath,
  executeCompatibilityProfile,
  loadCompatibilityExecutionEvidence,
} from "./execution.ts";
import {
  certifyCompatibilityProfile,
  checkCompatibilityReviewLock,
  observeCompatibility,
} from "./operations.ts";
import { scanCompatibility } from "./scanner.ts";
import type { CompatibilityStatus } from "./types.ts";

export interface CompatibilityCommandResult {
  exitCode: number;
  report: unknown;
}

export interface CompatibilityCommandOptions {
  executionEvidence?: string | null;
  runtimeEvidence?: string | null;
  output?: string | null;
  online?: boolean;
  timeoutMs?: number;
}

function requireNoArguments(command: string, arguments_: string[]): void {
  if (arguments_.length > 0) throw new CliError(`compat ${command} does not accept positional arguments.`, 2);
}

function printStatus(io: CommandIo, status: CompatibilityStatus): void {
  io.log(`Compatibility status: ${status}.`);
}

export function printCompatibilityReport(io: CommandIo, report: unknown): void {
  if (typeof report !== "object" || report === null || !("artifactKind" in report)) {
    io.log("Compatibility report is unavailable.");
    return;
  }
  const value = report as Record<string, unknown>;
  const status = typeof value.status === "string" ? value.status as CompatibilityStatus : "UNKNOWN";
  switch (value.artifactKind) {
    case "synex-compatibility-status": {
      printStatus(io, status);
      const providers = Array.isArray(value.providers) ? value.providers : [];
      for (const provider of providers) {
        if (typeof provider !== "object" || provider === null) continue;
        const entry = provider as Record<string, unknown>;
        io.log(`${String(entry.provider)}: ${String(entry.status)}.`);
      }
      break;
    }
    case "synex-compatibility-matrix": {
      printStatus(io, status);
      const rows = Array.isArray(value.rows) ? value.rows : [];
      for (const row of rows) {
        if (typeof row !== "object" || row === null) continue;
        const entry = row as Record<string, unknown>;
        io.log(`${String(entry.provider)} ${String(entry.name)} — ${String(entry.status)}.`);
      }
      break;
    }
    case "synex-compatibility-scan": {
      const files = typeof value.filesScanned === "number" ? value.filesScanned : 0;
      io.log(`Compatibility scan: ${files} source file(s); status=${status}.`);
      const counts = typeof value.signatureCounts === "object" && value.signatureCounts !== null
        ? value.signatureCounts as Record<string, unknown>
        : {};
      for (const [framework, count] of Object.entries(counts)) {
        if (typeof count === "number" && count > 0) io.log(`${framework}: ${count} signature(s).`);
      }
      io.log(String(value.disclaimer ?? ""));
      break;
    }
    case "synex-compatibility-explanation": {
      printStatus(io, status);
      const resolved = Array.isArray(value.resolved) ? value.resolved.length : 0;
      const unresolved = Array.isArray(value.unresolved) ? value.unresolved.length : 0;
      io.log(`Resolved surfaces: ${resolved}; unresolved signatures: ${unresolved}.`);
      io.log(String(value.disclaimer ?? ""));
      break;
    }
    case "synex-compatibility-profile": {
      printStatus(io, status);
      if (value.found !== true) io.log("Profile not found.");
      else {
        const profile = typeof value.profile === "object" && value.profile !== null
          ? value.profile as Record<string, unknown>
          : {};
        io.log(`Profile ${String(profile.id)}; authored=${String(profile.status)}; effective=${String(profile.effectiveStatus)}.`);
      }
      io.log(String(value.disclaimer ?? ""));
      break;
    }
    case "synex-compatibility-adapters": {
      printStatus(io, status);
      const adapters = Array.isArray(value.adapters) ? value.adapters : [];
      if (adapters.length === 0) io.log("No cataloged adapter requirement exists in this snapshot.");
      for (const adapter of adapters) {
        if (typeof adapter !== "object" || adapter === null) continue;
        const entry = adapter as Record<string, unknown>;
        io.log(`${String(entry.name)}: installed=${String(entry.installed)}; safe=${String(entry.safe)}.`);
      }
      io.log(String(value.disclaimer ?? ""));
      break;
    }
    case "synex-compatibility-doctor": {
      printStatus(io, status);
      const checks = Array.isArray(value.checks) ? value.checks : [];
      for (const check of checks) {
        if (typeof check !== "object" || check === null) continue;
        const entry = check as Record<string, unknown>;
        io.log(`${String(entry.status)} ${String(entry.id)} ${String(entry.subject)} — ${String(entry.message)}`);
      }
      const findings = Array.isArray(value.findings) ? value.findings : [];
      for (const finding of findings) {
        if (typeof finding !== "object" || finding === null) continue;
        const entry = finding as Record<string, unknown>;
        io.log(`${String(entry.severity).toUpperCase()} ${String(entry.code)} ${String(entry.subject)} — ${String(entry.message)}`);
      }
      io.log(String(value.disclaimer ?? ""));
      break;
    }
    case "synex-compatibility-observation": {
      printStatus(io, status);
      const staticReport = typeof value.static === "object" && value.static !== null
        ? value.static as Record<string, unknown>
        : {};
      const runtime = typeof value.runtime === "object" && value.runtime !== null
        ? value.runtime as Record<string, unknown>
        : null;
      io.log(`Static: ${String(staticReport.status ?? "UNKNOWN")}; files=${String(staticReport.filesScanned ?? 0)}.`);
      io.log(runtime
        ? `Observed: operator-supplied; complete=${String(runtime.complete)}; calls=${String(runtime.telemetryCalls ?? 0)}.`
        : "Observed: UNAVAILABLE; no runtime evidence supplied.");
      io.log(String(value.disclaimer ?? ""));
      break;
    }
    case "synex-compatibility-certification": {
      io.log(`Compatibility certification: ${String(value.status ?? "UNKNOWN")}.`);
      const checks = Array.isArray(value.checks) ? value.checks : [];
      for (const check of checks) {
        if (typeof check !== "object" || check === null) continue;
        const entry = check as Record<string, unknown>;
        io.log(`${String(entry.status)} ${String(entry.id)} — ${String(entry.message)}`);
      }
      io.log(String(value.disclaimer ?? ""));
      break;
    }
    case "synex-compatibility-certification-execution": {
      io.log(`Compatibility execution: ${String(value.status ?? "UNKNOWN")}; complete=${String(value.complete)}.`);
      const flows = Array.isArray(value.flows) ? value.flows : [];
      for (const flow of flows) {
        if (typeof flow !== "object" || flow === null) continue;
        const entry = flow as Record<string, unknown>;
        io.log(`${String(entry.status)} ${String(entry.testPath)} - ${String(entry.message)}`);
      }
      io.log(String(value.disclaimer ?? ""));
      break;
    }
    case "synex-compatibility-review-lock": {
      io.log(`Compatibility review lock: ${String(value.status ?? "FAIL")}; upstream=${String(value.upstreamStatus ?? "UNKNOWN")}.`);
      const findings = Array.isArray(value.findings) ? value.findings : [];
      for (const finding of findings) {
        if (typeof finding !== "object" || finding === null) continue;
        const entry = finding as Record<string, unknown>;
        io.log(`${String(entry.code)} ${String(entry.subject)} — ${String(entry.message)}`);
      }
      io.log(String(value.disclaimer ?? ""));
      break;
    }
    default:
      printStatus(io, status);
  }
}

export async function runCompatibilityCommand(
  repositoryRoot: string,
  subcommand: string,
  arguments_: string[],
  options: CompatibilityCommandOptions = {},
): Promise<CompatibilityCommandResult> {
  if (options.online && subcommand !== "drift" && subcommand !== "review-lock") {
    throw new CliError("--online is valid only with compat drift.", 2);
  }
  if (options.timeoutMs !== undefined && subcommand !== "drift" && subcommand !== "review-lock") {
    throw new CliError("--timeout is valid only with compat drift --online.", 2);
  }
  if (options.runtimeEvidence && !new Set(["doctor", "observe", "certify"]).has(subcommand)) {
    throw new CliError("--runtime-evidence is valid only with compat doctor, observe, or certify.", 2);
  }
  if (options.executionEvidence && subcommand !== "certify") {
    throw new CliError("--execution-evidence is valid only with compat certify.", 2);
  }
  if (options.output && !new Set(["certify", "execute"]).has(subcommand)) {
    throw new CliError("--output is valid only with compat certify or execute.", 2);
  }
  if (subcommand === "scan" || subcommand === "explain") {
    if (arguments_.length > 1) throw new CliError(`compat ${subcommand} accepts at most one target.`, 2);
    const target = resolveWithin(repositoryRoot, arguments_[0] ?? ".");
    const scan = await scanCompatibility(repositoryRoot, target);
    if (subcommand === "scan") return { exitCode: 0, report: scan };
    const catalog = await loadCompatibilityCatalog(repositoryRoot);
    return { exitCode: 0, report: explainCompatibility(scan, catalog) };
  }

  const catalog = await loadCompatibilityCatalog(repositoryRoot);
  if (subcommand === "observe") {
    if (arguments_.length > 1) throw new CliError("compat observe accepts at most one target.", 2);
    const target = resolveWithin(repositoryRoot, arguments_[0] ?? ".");
    const runtimeEvidence = options.runtimeEvidence
      ? await loadCompatibilityRuntimeEvidence(
        repositoryRoot,
        resolveWithin(repositoryRoot, options.runtimeEvidence),
      )
      : undefined;
    const report = await observeCompatibility(repositoryRoot, target, catalog, runtimeEvidence);
    return { exitCode: report.status === "UNSUPPORTED" ? 1 : 0, report };
  }
  if (subcommand === "status") {
    requireNoArguments(subcommand, arguments_);
    return { exitCode: 0, report: buildCompatibilityStatus(catalog) };
  }
  if (subcommand === "matrix") {
    requireNoArguments(subcommand, arguments_);
    return { exitCode: 0, report: buildCompatibilityMatrix(catalog) };
  }
  if (subcommand === "profile") {
    if (arguments_.length !== 1 || !arguments_[0]) throw new CliError("compat profile requires exactly one profile id.", 2);
    const report = inspectCompatibilityProfile(catalog, arguments_[0]);
    return { exitCode: report.found ? 0 : 1, report };
  }
  if (subcommand === "adapters") {
    requireNoArguments(subcommand, arguments_);
    return { exitCode: 0, report: await listCompatibilityAdapters(repositoryRoot, catalog) };
  }
  if (subcommand === "doctor") {
    requireNoArguments(subcommand, arguments_);
    const runtimeEvidence = options.runtimeEvidence
      ? await loadCompatibilityRuntimeEvidence(
        repositoryRoot,
        resolveWithin(repositoryRoot, options.runtimeEvidence),
      )
      : undefined;
    const report = await doctorCompatibility(repositoryRoot, catalog, runtimeEvidence);
    return { exitCode: report.status === "UNSUPPORTED" ? 1 : 0, report };
  }
  if (subcommand === "execute") {
    if (arguments_.length !== 1 || !arguments_[0]) {
      throw new CliError("compat execute requires exactly one profile id.", 2);
    }
    if (options.output) {
      const expected = compatibilityExecutionOutputPath(arguments_[0]);
      if (options.output.replaceAll("\\", "/") !== expected) {
        throw new CliError(
          `compat execute --output must equal ${expected}.`,
          2,
        );
      }
    }
    const report = await executeCompatibilityProfile(repositoryRoot, catalog, arguments_[0]);
    return { exitCode: report.status === "PASS" ? 0 : 1, report };
  }
  if (subcommand === "certify") {
    if (arguments_.length !== 1 || !arguments_[0]) {
      throw new CliError("compat certify requires exactly one profile id.", 2);
    }
    const profile = catalog.profiles.find((entry) => entry.id === arguments_[0]);
    if (options.executionEvidence) {
      const expected = compatibilityExecutionOutputPath(arguments_[0]);
      if (options.executionEvidence.replaceAll("\\", "/") !== expected) {
        throw new CliError(
          `compat certify --execution-evidence must equal ${expected}.`,
          2,
        );
      }
    }
    if (options.output) {
      const expected = profile?.certificationArtifact
        ? `libraries/synex_bridge/${profile.certificationArtifact}`
        : null;
      if (options.output.replaceAll("\\", "/") !== expected) {
        throw new CliError(
          "compat certify --output must equal the profile's declared certificationArtifact path.",
          2,
        );
      }
    }
    const runtimeEvidence = options.runtimeEvidence
      ? await loadCompatibilityRuntimeEvidence(
        repositoryRoot,
        resolveWithin(repositoryRoot, options.runtimeEvidence),
      )
      : undefined;
    const executionEvidence = options.executionEvidence
      ? await loadCompatibilityExecutionEvidence(
        repositoryRoot,
        resolveWithin(repositoryRoot, options.executionEvidence),
      )
      : undefined;
    const report = await certifyCompatibilityProfile(
      repositoryRoot, catalog, arguments_[0], runtimeEvidence, executionEvidence,
    );
    return { exitCode: report.certified ? 0 : 1, report };
  }
  if (subcommand === "drift" || subcommand === "review-lock") {
    requireNoArguments(subcommand, arguments_);
    if (options.timeoutMs !== undefined && !options.online) {
      throw new CliError("compat drift --timeout requires --online.", 2);
    }
    const report = await checkCompatibilityReviewLock(repositoryRoot, {
      online: options.online === true,
      ...(options.timeoutMs === undefined ? {} : { timeoutMs: options.timeoutMs }),
    });
    return { exitCode: report.status === "PASS" ? 0 : 1, report };
  }
  throw new CliError(
    "compat requires one of: status, matrix, scan, explain, profile, adapters, observe, doctor, execute, certify, drift.",
    2,
  );
}
