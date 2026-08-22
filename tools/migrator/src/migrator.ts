import { createHash } from "node:crypto";
import { lstat, mkdir, readFile, readdir, stat, writeFile } from "node:fs/promises";
import { dirname, relative, resolve, sep } from "node:path";
import {
  connectImportDatabase,
  importReviewedMigrationPlan,
  LegacyImportError,
  loadReviewedMigrationPlan,
} from "./importer.ts";

export type LegacyFramework = "qb" | "qbx" | "esx";

const PLATFORM_IDENTIFIER_PATTERN = /^(?:license|license2|fivem|discord|steam|xbl|live):[\x21-\x7e]{2,192}$/u;

export interface MigrationSource {
  schema: 1;
  framework: LegacyFramework;
  records: Record<string, unknown>[];
}

export interface MigrationMapping {
  schema: 1;
  framework: LegacyFramework;
  fields: {
    userId: string;
    characterId: string;
    firstName: string;
    lastName: string;
    money: { cash: string; bank: string };
    job?: { name: string; grade: string };
    group?: { name: string; grade: string };
    vehicles?: string;
    metadata?: string;
  };
}

export interface MigrationIssue {
  record: number;
  field: string;
  reason: string;
}

export interface MigrationPlan {
  report: {
    schema: 1;
    artifactKind: "synex-legacy-migration-plan";
    framework: LegacyFramework;
    sourceDigest: string;
    mappingDigest: string;
    reportDigest: string;
    counts: {
      users: number;
      characters: number;
      moneyEntries: number;
      groups: number;
      vehicles: number;
      metadata: number;
      unsupported: number;
      conflicts: number;
    };
    economy: {
      source: { cash: string; bank: string };
      transformed: { cash: string; bank: string };
      conserved: boolean;
    };
    unsupported: MigrationIssue[];
    unsupportedTruncated: number;
    conflicts: MigrationIssue[];
    conflictsTruncated: number;
  };
  idMap: {
    schema: 1;
    framework: LegacyFramework;
    users: Array<{ legacyId: string; synexId: string }>;
    characters: Array<{ legacyId: string; synexId: string }>;
  };
  bundle: {
    schema: 1;
    framework: LegacyFramework;
    users: Array<{ id: string; legacyId: string }>;
    characters: Array<{
      id: string;
      userId: string;
      legacyId: string;
      slot: number;
      firstName: string;
      lastName: string;
    }>;
    openingBalances: Array<{
      characterId: string;
      currency: "bank" | "cash";
      amount: number;
      reason: "legacy_migration_opening_balance";
    }>;
    groups: Array<{
      characterId: string;
      kind: "group" | "job";
      name: string;
      grade: number;
    }>;
  };
}

export interface MigratorIo {
  log(message: string): void;
  error(message: string): void;
}

export class MigrationError extends Error {
  public readonly exitCode: number;

  public constructor(message: string, exitCode = 2) {
    super(message);
    this.name = "MigrationError";
    this.exitCode = exitCode;
  }
}

const MAX_SOURCE_BYTES = 16 * 1024 * 1024;
const MAX_RECORDS = 100_000;
const MAX_ISSUES = 1_000;
const PATH_PATTERN = /^[A-Za-z_][A-Za-z0-9_-]*(?:\.[A-Za-z_][A-Za-z0-9_-]*){0,11}$/u;
const FRAMEWORKS = new Set<LegacyFramework>(["qb", "qbx", "esx"]);

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function compareText(left: string, right: string): number {
  return left < right ? -1 : left > right ? 1 : 0;
}

function stableValue(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(stableValue);
  if (!isRecord(value)) return value;
  return Object.fromEntries(
    Object.keys(value)
      .sort(compareText)
      .map((key) => [key, stableValue(value[key])]),
  );
}

export function canonicalJson(value: unknown): string {
  return `${JSON.stringify(stableValue(value), null, 2)}\n`;
}

function digest(value: string): string {
  return createHash("sha256").update(value, "utf8").digest("hex");
}

function deterministicId(kind: "character" | "user", framework: LegacyFramework, legacyId: string): string {
  const bytes = createHash("sha256")
    .update(`synex-migration:${framework}:${kind}:${legacyId}`, "utf8")
    .digest();
  bytes[6] = ((bytes[6] ?? 0) & 0x0f) | 0x50;
  bytes[8] = ((bytes[8] ?? 0) & 0x3f) | 0x80;
  const hex = bytes.subarray(0, 16).toString("hex");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

function validatePath(path: unknown, label: string): asserts path is string {
  if (typeof path !== "string" || !PATH_PATTERN.test(path)) {
    throw new MigrationError(`${label} must be a bounded dot-separated field path.`);
  }
}

function parseEmbedded(value: unknown): unknown {
  if (typeof value !== "string") return value;
  const trimmed = value.trim();
  if (trimmed.length < 2 || trimmed.length > 1_048_576) return value;
  if (!(trimmed.startsWith("{") && trimmed.endsWith("}")) && !(trimmed.startsWith("[") && trimmed.endsWith("]"))) {
    return value;
  }
  try {
    return JSON.parse(trimmed) as unknown;
  } catch {
    return value;
  }
}

function readMapped(record: Record<string, unknown>, path: string): unknown {
  let current: unknown = record;
  for (const segment of path.split(".")) {
    current = parseEmbedded(current);
    if (!isRecord(current)) return undefined;
    current = current[segment];
  }
  return parseEmbedded(current);
}

function mappedString(record: Record<string, unknown>, path: string, maximum: number): string | null {
  const value = readMapped(record, path);
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed.length > 0 && trimmed.length <= maximum ? trimmed : null;
}

function mappedInteger(record: Record<string, unknown>, path: string): number | null {
  const value = readMapped(record, path);
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0 ? value : null;
}

function countUnsupportedValue(value: unknown): number {
  if (Array.isArray(value)) return value.length;
  if (isRecord(value)) return Object.keys(value).length;
  return value === undefined || value === null || value === "" ? 0 : 1;
}

function pushBoundedIssue(target: MigrationIssue[], issue: MigrationIssue): void {
  if (target.length < MAX_ISSUES) target.push(issue);
}

function validateFramework(value: unknown, label: string): asserts value is LegacyFramework {
  if (typeof value !== "string" || !FRAMEWORKS.has(value as LegacyFramework)) {
    throw new MigrationError(`${label} must be one of qb, qbx, or esx.`);
  }
}

export function validateSource(value: unknown): MigrationSource {
  if (!isRecord(value) || value.schema !== 1) throw new MigrationError("Source schema must equal 1.");
  validateFramework(value.framework, "Source framework");
  if (!Array.isArray(value.records) || value.records.length > MAX_RECORDS) {
    throw new MigrationError(`Source records must be an array with at most ${MAX_RECORDS} entries.`);
  }
  if (!value.records.every(isRecord)) throw new MigrationError("Every source record must be an object.");
  return { schema: 1, framework: value.framework, records: value.records };
}

export function validateMapping(value: unknown): MigrationMapping {
  if (!isRecord(value) || value.schema !== 1) throw new MigrationError("Mapping schema must equal 1.");
  validateFramework(value.framework, "Mapping framework");
  if (!isRecord(value.fields) || !isRecord(value.fields.money)) {
    throw new MigrationError("Mapping fields and fields.money must be objects.");
  }

  validatePath(value.fields.userId, "fields.userId");
  validatePath(value.fields.characterId, "fields.characterId");
  validatePath(value.fields.firstName, "fields.firstName");
  validatePath(value.fields.lastName, "fields.lastName");
  validatePath(value.fields.money.cash, "fields.money.cash");
  validatePath(value.fields.money.bank, "fields.money.bank");

  const fields: MigrationMapping["fields"] = {
    userId: value.fields.userId,
    characterId: value.fields.characterId,
    firstName: value.fields.firstName,
    lastName: value.fields.lastName,
    money: { cash: value.fields.money.cash, bank: value.fields.money.bank },
  };

  if (value.fields.job !== undefined) {
    if (!isRecord(value.fields.job)) throw new MigrationError("fields.job must be an object.");
    validatePath(value.fields.job.name, "fields.job.name");
    validatePath(value.fields.job.grade, "fields.job.grade");
    fields.job = { name: value.fields.job.name, grade: value.fields.job.grade };
  }
  if (value.fields.group !== undefined) {
    if (!isRecord(value.fields.group)) throw new MigrationError("fields.group must be an object.");
    validatePath(value.fields.group.name, "fields.group.name");
    validatePath(value.fields.group.grade, "fields.group.grade");
    fields.group = { name: value.fields.group.name, grade: value.fields.group.grade };
  }
  if (value.fields.vehicles !== undefined) {
    validatePath(value.fields.vehicles, "fields.vehicles");
    fields.vehicles = value.fields.vehicles;
  }
  if (value.fields.metadata !== undefined) {
    validatePath(value.fields.metadata, "fields.metadata");
    fields.metadata = value.fields.metadata;
  }
  return { schema: 1, framework: value.framework, fields };
}

export function buildMigrationPlan(
  source: MigrationSource,
  mapping: MigrationMapping,
  sourceDigest = digest(canonicalJson(source)),
): MigrationPlan {
  if (source.framework !== mapping.framework) {
    throw new MigrationError("Source and mapping frameworks do not match.");
  }

  const usersByLegacy = new Map<string, string>();
  const charactersByLegacy = new Map<string, string>();
  const users: MigrationPlan["bundle"]["users"] = [];
  const characters: MigrationPlan["bundle"]["characters"] = [];
  const openingBalances: MigrationPlan["bundle"]["openingBalances"] = [];
  const groups: MigrationPlan["bundle"]["groups"] = [];
  const slotsByUser = new Map<string, number>();
  const unsupported: MigrationIssue[] = [];
  const conflicts: MigrationIssue[] = [];
  let unsupportedCount = 0;
  let conflictCount = 0;
  let vehicleCount = 0;
  let metadataCount = 0;
  const sourceEconomy = { cash: 0n, bank: 0n };
  const transformedEconomy = { cash: 0n, bank: 0n };

  source.records.forEach((record, index) => {
    const recordNumber = index + 1;
    const legacyUserId = mappedString(record, mapping.fields.userId, 128);
    const legacyCharacterId = mappedString(record, mapping.fields.characterId, 128);
    const firstName = mappedString(record, mapping.fields.firstName, 64);
    const lastName = mappedString(record, mapping.fields.lastName, 64);
    const cash = mappedInteger(record, mapping.fields.money.cash);
    const bank = mappedInteger(record, mapping.fields.money.bank);

    const required: Array<[string, unknown]> = [
      ["userId", legacyUserId],
      ["characterId", legacyCharacterId],
      ["firstName", firstName],
      ["lastName", lastName],
      ["money.cash", cash],
      ["money.bank", bank],
    ];
    for (const [field, value] of required) {
      if (value === null) {
        conflictCount += 1;
        pushBoundedIssue(conflicts, { record: recordNumber, field, reason: "missing_or_invalid" });
      }
    }
    const platformIdentifierValid = legacyUserId !== null && PLATFORM_IDENTIFIER_PATTERN.test(legacyUserId);
    if (legacyUserId !== null && !platformIdentifierValid) {
      conflictCount += 1;
      pushBoundedIssue(conflicts, {
        record: recordNumber,
        field: "userId",
        reason: "unsupported_platform_identifier",
      });
    }

    if (mapping.fields.vehicles) {
      const count = countUnsupportedValue(readMapped(record, mapping.fields.vehicles));
      if (count > 0) {
        vehicleCount += count;
        unsupportedCount += 1;
        pushBoundedIssue(unsupported, {
          record: recordNumber,
          field: "vehicles",
          reason: "reported_but_not_transformed",
        });
      }
    }
    if (mapping.fields.metadata) {
      const count = countUnsupportedValue(readMapped(record, mapping.fields.metadata));
      if (count > 0) {
        metadataCount += count;
        unsupportedCount += 1;
        pushBoundedIssue(unsupported, {
          record: recordNumber,
          field: "metadata",
          reason: "reported_but_not_transformed",
        });
      }
    }

    if (cash !== null) sourceEconomy.cash += BigInt(cash);
    if (bank !== null) sourceEconomy.bank += BigInt(bank);
    if (required.some(([, value]) => value === null) || !platformIdentifierValid) return;

    const safeUserId = legacyUserId as string;
    const safeCharacterId = legacyCharacterId as string;
    const existingCharacter = charactersByLegacy.get(safeCharacterId);
    if (existingCharacter) {
      conflictCount += 1;
      pushBoundedIssue(conflicts, {
        record: recordNumber,
        field: "characterId",
        reason: "duplicate_legacy_id",
      });
      return;
    }

    let synexUserId = usersByLegacy.get(safeUserId);
    if (!synexUserId) {
      synexUserId = deterministicId("user", source.framework, safeUserId);
      usersByLegacy.set(safeUserId, synexUserId);
      users.push({ id: synexUserId, legacyId: safeUserId });
    }
    const synexCharacterId = deterministicId("character", source.framework, safeCharacterId);
    const slot = (slotsByUser.get(synexUserId) ?? 0) + 1;
    if (slot > 32) {
      conflictCount += 1;
      pushBoundedIssue(conflicts, {
        record: recordNumber,
        field: "characterId",
        reason: "user_character_slot_limit_exceeded",
      });
      return;
    }
    slotsByUser.set(synexUserId, slot);
    charactersByLegacy.set(safeCharacterId, synexCharacterId);
    characters.push({
      id: synexCharacterId,
      userId: synexUserId,
      legacyId: safeCharacterId,
      slot,
      firstName: firstName as string,
      lastName: lastName as string,
    });

    for (const [currency, amount] of [["cash", cash], ["bank", bank]] as const) {
      openingBalances.push({
        characterId: synexCharacterId,
        currency,
        amount: amount as number,
        reason: "legacy_migration_opening_balance",
      });
      transformedEconomy[currency] += BigInt(amount as number);
    }

    const mappedGroups: Array<{ kind: "group" | "job"; mapping: { name: string; grade: string } }> = [];
    if (mapping.fields.job) mappedGroups.push({ kind: "job", mapping: mapping.fields.job });
    if (mapping.fields.group) mappedGroups.push({ kind: "group", mapping: mapping.fields.group });
    for (const entry of mappedGroups) {
      const name = mappedString(record, entry.mapping.name, 64);
      const grade = mappedInteger(record, entry.mapping.grade);
      if (name === null && grade === null) continue;
      if (name === null || grade === null || grade > 1000) {
        conflictCount += 1;
        pushBoundedIssue(conflicts, {
          record: recordNumber,
          field: entry.kind,
          reason: "incomplete_or_invalid_group_mapping",
        });
        continue;
      }
      groups.push({ characterId: synexCharacterId, kind: entry.kind, name, grade });
    }
  });

  users.sort((left, right) => compareText(left.legacyId, right.legacyId));
  characters.sort((left, right) => compareText(left.legacyId, right.legacyId));
  openingBalances.sort((left, right) =>
    compareText(left.characterId, right.characterId) || compareText(left.currency, right.currency),
  );
  groups.sort((left, right) =>
    compareText(left.characterId, right.characterId)
      || compareText(left.kind, right.kind)
      || compareText(left.name, right.name),
  );
  conflicts.sort((left, right) => left.record - right.record || compareText(left.field, right.field));
  unsupported.sort((left, right) => left.record - right.record || compareText(left.field, right.field));

  const conserved = sourceEconomy.cash === transformedEconomy.cash
    && sourceEconomy.bank === transformedEconomy.bank;
  const mappingDigest = digest(canonicalJson(mapping));
  const reportWithoutDigest = {
    schema: 1 as const,
    artifactKind: "synex-legacy-migration-plan" as const,
    framework: source.framework,
    sourceDigest,
    mappingDigest,
    counts: {
      users: users.length,
      characters: characters.length,
      moneyEntries: openingBalances.length,
      groups: groups.length,
      vehicles: vehicleCount,
      metadata: metadataCount,
      unsupported: unsupportedCount,
      conflicts: conflictCount,
    },
    economy: {
      source: { cash: sourceEconomy.cash.toString(), bank: sourceEconomy.bank.toString() },
      transformed: { cash: transformedEconomy.cash.toString(), bank: transformedEconomy.bank.toString() },
      conserved,
    },
    unsupported,
    unsupportedTruncated: Math.max(0, unsupportedCount - unsupported.length),
    conflicts,
    conflictsTruncated: Math.max(0, conflictCount - conflicts.length),
  };
  const reportDigest = digest(canonicalJson(reportWithoutDigest));

  return {
    report: { ...reportWithoutDigest, reportDigest },
    idMap: {
      schema: 1,
      framework: source.framework,
      users: users.map((entry) => ({ legacyId: entry.legacyId, synexId: entry.id })),
      characters: characters.map((entry) => ({ legacyId: entry.legacyId, synexId: entry.id })),
    },
    bundle: {
      schema: 1,
      framework: source.framework,
      users,
      characters,
      openingBalances,
      groups,
    },
  };
}

async function loadBoundedJson(path: string, label: string): Promise<{ raw: string; value: unknown }> {
  const metadata = await stat(path);
  if (!metadata.isFile() || metadata.size > MAX_SOURCE_BYTES) {
    throw new MigrationError(`${label} must be a file no larger than ${MAX_SOURCE_BYTES} bytes.`);
  }
  const raw = await readFile(path, "utf8");
  try {
    return { raw, value: JSON.parse(raw) as unknown };
  } catch {
    throw new MigrationError(`${label} is not valid JSON.`);
  }
}

export async function loadMigrationPlan(
  sourcePath: string,
  mappingPath: string,
  expectedFramework: LegacyFramework,
): Promise<MigrationPlan> {
  const sourceFile = await loadBoundedJson(sourcePath, "Source");
  const mappingFile = await loadBoundedJson(mappingPath, "Mapping");
  const source = validateSource(sourceFile.value);
  const mapping = validateMapping(mappingFile.value);
  if (source.framework !== expectedFramework || mapping.framework !== expectedFramework) {
    throw new MigrationError("--framework must match both source and mapping files.");
  }
  return buildMigrationPlan(source, mapping, digest(sourceFile.raw));
}

function pathIsInside(parent: string, candidate: string): boolean {
  const child = relative(parent, candidate);
  return child === "" || (!child.startsWith(`..${sep}`) && child !== "..");
}

export async function materializeMigrationPlan(
  plan: MigrationPlan,
  targetPath: string,
  confirmedTargetPath: string,
  sourcePaths: string[],
  allowUnsupported: boolean,
): Promise<string[]> {
  const target = resolve(targetPath);
  if (target !== resolve(confirmedTargetPath)) {
    throw new MigrationError("--confirm-target must resolve to exactly the same directory as --target.");
  }
  if (sourcePaths.some((path) => pathIsInside(target, resolve(path)))) {
    throw new MigrationError("The target directory must not contain the source or mapping file.");
  }
  if (plan.report.counts.conflicts > 0 || !plan.report.economy.conserved) {
    throw new MigrationError("Apply is blocked while conflicts exist or economy conservation fails.");
  }
  if (plan.report.counts.unsupported > 0 && !allowUnsupported) {
    throw new MigrationError("Apply is blocked until --allow-unsupported explicitly acknowledges reported omissions.");
  }

  try {
    await lstat(target);
    throw new MigrationError("The apply target must not already exist; no files are overwritten.");
  } catch (error) {
    if (error instanceof MigrationError) throw error;
    if (!isRecord(error) || error.code !== "ENOENT") throw error;
  }
  const parent = dirname(target);
  const parentMetadata = await lstat(parent);
  if (!parentMetadata.isDirectory() || parentMetadata.isSymbolicLink()) {
    throw new MigrationError("The apply target parent must be a real directory, not a symbolic link.");
  }

  await mkdir(target, { recursive: false });
  const artifacts = new Map<string, string>([
    ["migration-report.json", canonicalJson(plan.report)],
    ["id-map.json", canonicalJson(plan.idMap)],
    ["migration-bundle.json", canonicalJson(plan.bundle)],
  ]);
  for (const [name, contents] of artifacts) {
    await writeFile(resolve(target, name), contents, { encoding: "utf8", flag: "wx" });
  }
  return [...artifacts.keys()];
}

interface ParsedArguments {
  framework?: string;
  source?: string;
  mapping?: string;
  report?: string;
  target?: string;
  confirmTarget?: string;
  bundle?: string;
  confirmReportDigest?: string;
  databaseEnv?: string;
  apply: boolean;
  importReviewed: boolean;
  allowUnsupported: boolean;
  help: boolean;
}

function parseArguments(arguments_: string[]): ParsedArguments {
  const parsed: ParsedArguments = {
    apply: false,
    importReviewed: false,
    allowUnsupported: false,
    help: false,
  };
  const valueOptions: Record<string, keyof ParsedArguments> = {
    "--framework": "framework",
    "--source": "source",
    "--mapping": "mapping",
    "--report": "report",
    "--target": "target",
    "--confirm-target": "confirmTarget",
    "--bundle": "bundle",
    "--confirm-report-digest": "confirmReportDigest",
    "--database-env": "databaseEnv",
  };
  for (let index = 0; index < arguments_.length; index += 1) {
    const argument = arguments_[index];
    if (argument === "--apply") {
      parsed.apply = true;
    } else if (argument === "--import") {
      parsed.importReviewed = true;
    } else if (argument === "--allow-unsupported") {
      parsed.allowUnsupported = true;
    } else if (argument === "--help" || argument === "-h") {
      parsed.help = true;
    } else if (argument && valueOptions[argument]) {
      const value = arguments_[index + 1];
      if (!value || value.startsWith("--")) throw new MigrationError(`${argument} requires a value.`);
      const key = valueOptions[argument];
      if (key === "framework" || key === "source" || key === "mapping" || key === "report"
        || key === "target" || key === "confirmTarget" || key === "bundle"
        || key === "confirmReportDigest" || key === "databaseEnv") {
        parsed[key] = value;
      }
      index += 1;
    } else {
      throw new MigrationError(`Unknown migrator option: ${argument ?? ""}`);
    }
  }
  return parsed;
}

const HELP = `Synex legacy migration planner

Dry-run (default):
  node --experimental-strip-types tools/migrator/src/bin.ts \\
    --framework <qb|qbx|esx> --source <export.json> --mapping <mapping.json>

Materialize a reviewed import bundle (never writes a database):
  ... --apply --target <new-directory> --confirm-target <same-directory>

Import a reviewed bundle into an empty/non-conflicting migrated Synex database:
  ... --import --bundle <reviewed-directory> \
    --confirm-report-digest <sha256> --database-env SYNEX_MIGRATION_DATABASE_URL

Options:
  --report <new-file>       Write the machine-readable dry-run report without overwriting.
  --allow-unsupported       Explicitly acknowledge reported metadata/vehicle omissions.
  --database-env <name>     Read the target DB URL from a named environment variable (never argv).
  --help                    Show this help.
`;

export async function runMigratorCli(
  arguments_: string[],
  io: MigratorIo = { log: console.log, error: console.error },
): Promise<number> {
  try {
    const options = parseArguments(arguments_);
    if (options.help) {
      io.log(HELP);
      return 0;
    }
    if (options.apply && options.importReviewed) {
      throw new MigrationError("--apply and --import are mutually exclusive.");
    }
    if (options.importReviewed) {
      if (options.framework || options.source || options.mapping || options.report
        || options.target || options.confirmTarget) {
        throw new MigrationError(
          "--import accepts only --bundle, --confirm-report-digest, --database-env, and --allow-unsupported.",
        );
      }
      if (!options.bundle || !options.confirmReportDigest) {
        throw new MigrationError("--import requires --bundle and --confirm-report-digest.");
      }
      const environmentName = options.databaseEnv ?? "SYNEX_MIGRATION_DATABASE_URL";
      if (!/^[A-Z][A-Z0-9_]{2,63}$/u.test(environmentName)) {
        throw new MigrationError("--database-env must be a bounded uppercase environment variable name.");
      }
      const connectionUrl = process.env[environmentName];
      if (!connectionUrl) {
        throw new MigrationError(`The ${environmentName} environment variable is not set.`);
      }
      const plan = await loadReviewedMigrationPlan(options.bundle, options.confirmReportDigest);
      const database = await connectImportDatabase(connectionUrl);
      try {
        const result = await importReviewedMigrationPlan(plan, database, options.allowUnsupported);
        io.log(canonicalJson(result).trimEnd());
      } finally {
        await database.close();
      }
      return 0;
    }
    if (options.bundle || options.confirmReportDigest || options.databaseEnv) {
      throw new MigrationError("--bundle, --confirm-report-digest, and --database-env are valid only with --import.");
    }
    validateFramework(options.framework, "--framework");
    if (!options.source || !options.mapping) {
      throw new MigrationError("--source and --mapping are required.");
    }
    if (options.allowUnsupported && !options.apply) {
      throw new MigrationError("--allow-unsupported is valid only with --apply or --import.");
    }

    const sourcePath = resolve(options.source);
    const mappingPath = resolve(options.mapping);
    const plan = await loadMigrationPlan(sourcePath, mappingPath, options.framework);

    if (!options.apply) {
      if (options.target || options.confirmTarget) {
        throw new MigrationError("--target and --confirm-target are valid only with --apply.");
      }
      const dryRunArtifact = {
        schema: 1 as const,
        mode: "dry-run" as const,
        report: plan.report,
        idMap: plan.idMap,
      };
      if (options.report) {
        const reportPath = resolve(options.report);
        if (reportPath === sourcePath || reportPath === mappingPath) {
          throw new MigrationError("The report path must not overwrite source or mapping files.");
        }
        await writeFile(reportPath, canonicalJson(dryRunArtifact), { encoding: "utf8", flag: "wx" });
      }
      io.log(canonicalJson(dryRunArtifact).trimEnd());
      return plan.report.counts.conflicts === 0 && plan.report.economy.conserved ? 0 : 1;
    }

    if (options.report) throw new MigrationError("Apply writes its report inside the target; omit --report.");
    if (!options.target || !options.confirmTarget) {
      throw new MigrationError("--apply requires --target and --confirm-target.");
    }
    const written = await materializeMigrationPlan(
      plan,
      options.target,
      options.confirmTarget,
      [sourcePath, mappingPath],
      options.allowUnsupported,
    );
    io.log(`Materialized reviewed migration bundle: ${written.join(", ")}`);
    return 0;
  } catch (error) {
    io.error(error instanceof Error ? error.message : "Legacy migration failed.");
    return error instanceof MigrationError ? error.exitCode : error instanceof LegacyImportError ? 2 : 1;
  }
}

export async function assertDirectoryEmpty(path: string): Promise<boolean> {
  return (await readdir(path)).length === 0;
}
