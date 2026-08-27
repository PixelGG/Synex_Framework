import { createHash } from "node:crypto";
import { lstat, readFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { createConnection, type Connection, type ResultSetHeader, type RowDataPacket } from "mysql2/promise";
import type { LegacyFramework, MigrationPlan } from "./migrator.ts";
import {
  MAX_MIGRATION_ARTIFACT_BYTES,
  MAX_MIGRATION_CHARACTERS,
  MAX_MIGRATION_CURRENCIES,
  MAX_MIGRATION_MEMBERSHIPS,
  MAX_MIGRATION_METADATA_VALUES,
  MAX_MIGRATION_USERS,
} from "./limits.ts";
import { pathContainsSymbolicLink } from "./path-safety.ts";
import {
  type CompatibilityMetadataCatalog,
  type CompatibilityMetadataDefinition,
  compatibilityMetadataValueIsValid,
  loadCompatibilityMetadataCatalog,
  selectCompatibilityMetadataDefinitions,
} from "./compatibility-metadata.ts";
import {
  type CompatibilityAccountCatalog,
  type CompatibilityAccountDefinition,
  loadCompatibilityAccountCatalog,
  ownerScopedCompatibilityAccountKey,
  selectCompatibilityAccountDefinitionsById,
} from "./compatibility-accounts.ts";
import {
  type CompatibilityGroupCatalog,
  type CompatibilityGroupDefinition,
  loadCompatibilityGroupCatalog,
  selectCompatibilityGroupDefinitions,
} from "./compatibility-groups.ts";

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const DIGEST_PATTERN = /^[0-9a-f]{64}$/u;
const PLATFORM_IDENTIFIER_PATTERN = /^(license|license2|fivem|discord|steam|xbl|live):([\x21-\x7e]{2,192})$/u;
const GROUP_KEY_PATTERN = /^[a-z][a-z0-9_.:-]{0,63}$/u;
const REQUIRED_TABLES = [
  "synex_users",
  "synex_identifiers",
  "synex_character_slots",
  "synex_characters",
  "synex_legacy_imports",
  "synex_legacy_id_mappings",
  "synex_compatibility_identities",
  "synex_compatibility_metadata",
  "synex_currencies",
  "synex_accounts",
  "synex_account_owners",
  "synex_account_operations",
  "synex_account_reason_codes",
  "synex_ledger_transactions",
  "synex_ledger_postings",
  "synex_ledger_entries",
  "synex_account_balance_snapshots",
  "synex_account_audit",
  "synex_account_outbox",
  "synex_account_access_roles",
  "synex_account_access_role_permissions",
  "synex_account_access_grants",
  "synex_economy_integrity_read_models",
  "synex_economy_reconciliation_runs",
  "synex_economy_anomaly_findings",
  "synex_currency_system_topology",
  "synex_groups",
  "synex_group_types",
  "synex_group_organization_profiles",
  "synex_group_grades",
  "synex_group_operations",
  "synex_group_memberships",
  "synex_group_membership_profiles",
  "synex_group_membership_grades",
  "synex_group_primary_memberships_by_type",
  "synex_group_membership_events",
  "synex_group_read_model_versions",
  "synex_group_outbox",
] as const;

export class LegacyImportError extends Error {
  public constructor(message: string) {
    super(message);
    this.name = "LegacyImportError";
  }
}

export interface ImportResult {
  schema: 1;
  artifactKind: "synex-legacy-import-result";
  framework: LegacyFramework;
  reportDigest: string;
  alreadyApplied: boolean;
  counts: {
    users: number;
    characters: number;
    identifiers: number;
    accounts: number;
    ledgerTransactions: number;
    groups: number;
    memberships: number;
    metadata: number;
  };
}

interface QueryResult {
  rows: Array<Record<string, unknown>>;
  insertId: number;
  affectedRows: number;
}

type SqlParameter = string | number | null;

export interface ImportDatabase {
  begin(): Promise<void>;
  commit(): Promise<void>;
  rollback(): Promise<void>;
  close(): Promise<void>;
  execute(sql: string, parameters?: readonly SqlParameter[]): Promise<QueryResult>;
}

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
    Object.keys(value).sort(compareText).map((key) => [key, stableValue(value[key])]),
  );
}

function canonicalJson(value: unknown): string {
  return `${JSON.stringify(stableValue(value), null, 2)}\n`;
}

function digest(value: string): string {
  return createHash("sha256").update(value, "utf8").digest("hex");
}

function deterministicId(scope: string, ...values: string[]): string {
  const bytes = createHash("sha256")
    .update(["synex-legacy-import", scope, ...values].join(":"), "utf8")
    .digest();
  bytes[6] = ((bytes[6] ?? 0) & 0x0f) | 0x50;
  bytes[8] = ((bytes[8] ?? 0) & 0x3f) | 0x80;
  const hex = bytes.subarray(0, 16).toString("hex");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

function finiteInteger(value: unknown, minimum = 0): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= minimum;
}

function boundedString(value: unknown, maximum: number): value is string {
  return typeof value === "string" && value.length > 0 && value.length <= maximum;
}

function economyTotal(value: unknown): bigint | null {
  const candidate = String(value ?? "");
  return /^(?:0|[1-9][0-9]{0,35})$/u.test(candidate) ? BigInt(candidate) : null;
}

async function readArtifact(directory: string, name: string): Promise<unknown> {
  const path = join(directory, name);
  const metadata = await lstat(path);
  if (!metadata.isFile() || metadata.isSymbolicLink() || metadata.size > MAX_MIGRATION_ARTIFACT_BYTES) {
    throw new LegacyImportError(
      `${name} must be a regular file no larger than ${MAX_MIGRATION_ARTIFACT_BYTES} bytes.`,
    );
  }
  try {
    return JSON.parse(await readFile(path, "utf8")) as unknown;
  } catch {
    throw new LegacyImportError(`${name} is not valid JSON.`);
  }
}

function validateFramework(value: unknown): value is LegacyFramework {
  return value === "qb" || value === "qbx" || value === "esx";
}

function validateReviewedPlan(
  value: unknown,
  expectedDigest: string,
  metadataCatalog: CompatibilityMetadataCatalog,
  accountCatalog: CompatibilityAccountCatalog,
  groupCatalog: CompatibilityGroupCatalog,
): MigrationPlan {
  if (!isRecord(value) || !isRecord(value.report) || !isRecord(value.idMap) || !isRecord(value.bundle)) {
    throw new LegacyImportError("The reviewed migration artifacts do not form a migration plan.");
  }
  const report = value.report;
  const idMap = value.idMap;
  const bundle = value.bundle;
  if (report.schema !== 1 || report.artifactKind !== "synex-legacy-migration-plan"
    || !validateFramework(report.framework) || report.framework !== idMap.framework
    || report.framework !== bundle.framework || idMap.schema !== 1 || bundle.schema !== 1) {
    throw new LegacyImportError("Migration artifact schemas or framework labels do not match.");
  }
  if (!DIGEST_PATTERN.test(expectedDigest) || report.reportDigest !== expectedDigest) {
    throw new LegacyImportError("The explicitly confirmed report digest does not match the reviewed report.");
  }
  const { reportDigest, ...unsignedReport } = report;
  if (digest(canonicalJson(unsignedReport)) !== reportDigest) {
    throw new LegacyImportError("The reviewed migration report digest is invalid.");
  }
  if (!isRecord(report.counts) || !isRecord(report.economy) || !isRecord(report.accounts)
    || !isRecord(report.groups)
    || !isRecord(report.identity)
    || !isRecord(report.metadata)
    || !isRecord(report.identity.identifierTypes) || !isRecord(report.identity.preservationPlan)
    || !Array.isArray(report.unsupported) || !Array.isArray(report.conflicts)
    || !finiteInteger(report.counts.users) || !finiteInteger(report.counts.characters)
    || !finiteInteger(report.counts.moneyEntries) || !finiteInteger(report.counts.groups)
    || !finiteInteger(report.counts.vehicles) || !finiteInteger(report.counts.metadata)
    || !finiteInteger(report.counts.unsupported) || !finiteInteger(report.counts.conflicts)
    || !finiteInteger(report.unsupportedTruncated) || !finiteInteger(report.conflictsTruncated)
    || report.counts.unsupported !== report.unsupported.length + report.unsupportedTruncated
    || report.counts.conflicts !== report.conflicts.length + report.conflictsTruncated
    || report.counts.conflicts !== 0 || report.economy.conserved !== true) {
    throw new LegacyImportError("Import is blocked while conflicts exist or economy conservation fails.");
  }
  if (!Array.isArray(bundle.users) || !Array.isArray(bundle.characters)
    || !Array.isArray(bundle.openingBalances) || !Array.isArray(bundle.groups)
    || !Array.isArray(bundle.metadata)
    || !Array.isArray(idMap.users) || !Array.isArray(idMap.characters)
    || bundle.users.length > MAX_MIGRATION_USERS || bundle.characters.length > MAX_MIGRATION_CHARACTERS
    || bundle.groups.length > MAX_MIGRATION_MEMBERSHIPS
    || bundle.metadata.length > MAX_MIGRATION_METADATA_VALUES) {
    throw new LegacyImportError(
      `The reviewed bundle exceeds the import limits (${MAX_MIGRATION_USERS} users, `
      + `${MAX_MIGRATION_CHARACTERS} characters, ${MAX_MIGRATION_MEMBERSHIPS} memberships, `
      + `${MAX_MIGRATION_METADATA_VALUES} metadata values).`,
    );
  }
  if (report.counts.users !== bundle.users.length || report.counts.characters !== bundle.characters.length
    || report.counts.moneyEntries !== bundle.openingBalances.length || report.counts.groups !== bundle.groups.length
    || report.counts.metadata !== bundle.metadata.length) {
    throw new LegacyImportError("Migration report counts do not match the reviewed bundle.");
  }

  const users = new Map<string, string>();
  for (const entry of bundle.users) {
    if (!isRecord(entry) || !UUID_PATTERN.test(String(entry.id)) || !boundedString(entry.legacyId, 128)
      || users.has(String(entry.id))) {
      throw new LegacyImportError("The reviewed bundle contains an invalid or duplicate user mapping.");
    }
    identifierFor(entry.legacyId);
    users.set(String(entry.id), entry.legacyId);
  }
  const identityReport = report.identity;
  const preservationPlan = identityReport.preservationPlan as Record<string, unknown>;
  const targetTables = preservationPlan.targetTables;
  const identifierTypes: Record<string, number> = {};
  const identifierDigests: string[] = [];
  for (const legacyId of users.values()) {
    const identifier = identifierFor(legacyId);
    identifierTypes[identifier.type] = (identifierTypes[identifier.type] ?? 0) + 1;
    identifierDigests.push(digest(legacyId));
  }
  const reportedIdentifierTypes = identityReport.identifierTypes as Record<string, unknown>;
  const identifierTypeKeys = Object.keys(identifierTypes).sort(compareText);
  const reportedTypeKeys = Object.keys(reportedIdentifierTypes).sort(compareText);
  if (!DIGEST_PATTERN.test(String(identityReport.evidenceDigest ?? ""))
    || digest(canonicalJson(identifierDigests.sort(compareText))) !== identityReport.evidenceDigest
    || canonicalJson(identifierTypeKeys) !== canonicalJson(reportedTypeKeys)
    || identifierTypeKeys.some((type) => reportedIdentifierTypes[type] !== identifierTypes[type])
    || preservationPlan.artifact !== "id-map.json"
    || preservationPlan.classification !== "restricted-personal-data"
    || !Array.isArray(targetTables)
    || canonicalJson(targetTables) !== canonicalJson([
      "synex_identifiers",
      "synex_legacy_id_mappings",
      "synex_compatibility_identities",
    ])
    || preservationPlan.rawValuesInReport !== false
    || preservationPlan.credentialsCaptured !== false) {
    throw new LegacyImportError("The reviewed identity evidence or preservation plan is invalid.");
  }
  const characters = new Map<string, { userId: string; legacyId: string; slot: number }>();
  const occupiedSlots = new Set<string>();
  for (const entry of bundle.characters) {
    if (!isRecord(entry) || !UUID_PATTERN.test(String(entry.id)) || !UUID_PATTERN.test(String(entry.userId))
      || !users.has(String(entry.userId)) || !boundedString(entry.legacyId, 128)
      || !finiteInteger(entry.slot, 1) || entry.slot > 32
      || !boundedString(entry.firstName, 64) || !boundedString(entry.lastName, 64)) {
      throw new LegacyImportError("The reviewed bundle contains an invalid character record.");
    }
    const slotKey = `${String(entry.userId)}:${String(entry.slot)}`;
    if (characters.has(String(entry.id)) || occupiedSlots.has(slotKey)) {
      throw new LegacyImportError("The reviewed bundle contains duplicate characters or user slots.");
    }
    occupiedSlots.add(slotKey);
    characters.set(String(entry.id), {
      userId: String(entry.userId), legacyId: entry.legacyId, slot: entry.slot,
    });
  }
  const metadataReport = report.metadata;
  if (!Array.isArray(metadataReport.mappingIds)
    || !finiteInteger(metadataReport.sourceEntries)
    || !finiteInteger(metadataReport.transformedEntries)
    || !finiteInteger(metadataReport.omittedEntries)
    || !finiteInteger(metadataReport.rejectedEntries)
    || metadataReport.transformedEntries !== bundle.metadata.length
    || metadataReport.sourceEntries
      !== metadataReport.transformedEntries + metadataReport.omittedEntries
        + metadataReport.rejectedEntries
    || metadataReport.rejectedEntries !== 0
    || metadataReport.targetTable !== "synex_compatibility_metadata"
    || metadataReport.valuesInReport !== false || metadataReport.blobCopied !== false
    || metadataReport.credentialsCaptured !== false
    || !DIGEST_PATTERN.test(String(metadataReport.evidenceDigest ?? ""))) {
    throw new LegacyImportError("The reviewed compatibility metadata report is invalid.");
  }
  let metadataDefinitions: CompatibilityMetadataDefinition[];
  if (metadataReport.mappingIds.length === 0) {
    if (metadataReport.catalogDigest !== null || bundle.metadata.length !== 0
      || metadataReport.sourceEntries !== 0) {
      throw new LegacyImportError("The reviewed compatibility metadata catalog binding is missing.");
    }
    metadataDefinitions = [];
  } else {
    if (metadataReport.catalogDigest !== metadataCatalog.digest) {
      throw new LegacyImportError("The reviewed compatibility metadata catalog digest is stale.");
    }
    try {
      metadataDefinitions = selectCompatibilityMetadataDefinitions(
        metadataCatalog,
        report.framework,
        metadataReport.mappingIds,
      );
    } catch (error) {
      throw new LegacyImportError(
        error instanceof Error ? error.message : "Compatibility metadata mappings are invalid.",
      );
    }
    if (canonicalJson(metadataReport.mappingIds)
      !== canonicalJson(metadataDefinitions.map((definition) => definition.id))) {
      throw new LegacyImportError("Compatibility metadata mapping IDs are not canonical.");
    }
  }
  const metadataDefinitionsById = new Map(
    metadataDefinitions.map((definition) => [definition.id, definition]),
  );
  const metadataKeys = new Set<string>();
  for (const entry of bundle.metadata) {
    if (!isRecord(entry) || !characters.has(String(entry.characterId))
      || typeof entry.mappingId !== "string" || typeof entry.mappingVersion !== "string"
      || typeof entry.metadataKey !== "string") {
      throw new LegacyImportError("The reviewed bundle contains an invalid compatibility metadata value.");
    }
    const definition = metadataDefinitionsById.get(entry.mappingId);
    if (!definition || entry.mappingVersion !== definition.version
      || entry.metadataKey !== definition.storageKey
      || !compatibilityMetadataValueIsValid(definition, entry.value)) {
      throw new LegacyImportError("A compatibility metadata value does not match its reviewed mapping.");
    }
    const key = `${String(entry.characterId)}:${entry.metadataKey}`;
    if (metadataKeys.has(key)) {
      throw new LegacyImportError("The reviewed bundle contains duplicate compatibility metadata values.");
    }
    metadataKeys.add(key);
  }
  if (digest(canonicalJson(bundle.metadata)) !== metadataReport.evidenceDigest) {
    throw new LegacyImportError("The reviewed compatibility metadata evidence digest is invalid.");
  }
  const accountReport = report.accounts;
  if (!Array.isArray(accountReport.mappingIds)
    || accountReport.catalogDigest !== accountCatalog.digest
    || !DIGEST_PATTERN.test(String(accountReport.evidenceDigest ?? ""))
    || accountReport.targetTable !== "synex_accounts"
    || accountReport.ownerScopedKeys !== true
    || accountReport.directBalanceWrites !== false) {
    throw new LegacyImportError("The reviewed compatibility account report is invalid or stale.");
  }
  let accountDefinitions: CompatibilityAccountDefinition[];
  try {
    accountDefinitions = selectCompatibilityAccountDefinitionsById(
      accountCatalog,
      report.framework,
      accountReport.mappingIds,
    );
  } catch (error) {
    throw new LegacyImportError(
      error instanceof Error ? error.message : "Compatibility account mappings are invalid.",
    );
  }
  if (canonicalJson(accountReport.mappingIds)
    !== canonicalJson(accountDefinitions.map((definition) => definition.id))) {
    throw new LegacyImportError("Compatibility account mapping IDs are not canonical.");
  }
  const accountDefinitionsByAlias = new Map(
    accountDefinitions.map((definition) => [definition.alias, definition]),
  );
  const reportEconomy = report.economy;
  if (!isRecord(reportEconomy) || !isRecord(reportEconomy.source)
    || !isRecord(reportEconomy.transformed)) {
    throw new LegacyImportError("The reviewed economy report is invalid.");
  }
  const sourceEconomy = reportEconomy.source;
  const transformedEconomy = reportEconomy.transformed;
  const aliases = Object.keys(sourceEconomy).sort(compareText);
  const transformedAliases = Object.keys(transformedEconomy).sort(compareText);
  const mappedAliases = accountDefinitions.map((definition) => definition.alias).sort(compareText);
  if (aliases.length === 0 || aliases.length > MAX_MIGRATION_CURRENCIES
    || canonicalJson(aliases) !== canonicalJson(mappedAliases)
    || canonicalJson(aliases) !== canonicalJson(transformedAliases)
    || aliases.some((alias) => economyTotal(sourceEconomy[alias]) === null
      || economyTotal(transformedEconomy[alias]) === null)) {
    throw new LegacyImportError("The reviewed economy report has invalid account-alias mappings.");
  }
  const openingKeys = new Set<string>();
  const economy = Object.fromEntries(
    aliases.map((alias) => [alias, 0n]),
  ) as Record<string, bigint>;
  for (const entry of bundle.openingBalances) {
    const definition = isRecord(entry) && typeof entry.alias === "string"
      ? accountDefinitionsByAlias.get(entry.alias)
      : undefined;
    if (!isRecord(entry) || !characters.has(String(entry.characterId))
      || !definition || entry.mappingId !== definition.id
      || entry.mappingVersion !== definition.version
      || entry.currency !== definition.currencyCode
      || entry.accountRole !== definition.accountRole
      || entry.minorUnit !== definition.minorUnit
      || entry.accountKey !== ownerScopedCompatibilityAccountKey(
        definition,
        String(entry.characterId),
      )
      || !finiteInteger(entry.amount) || entry.reason !== "legacy_migration_opening_balance") {
      throw new LegacyImportError("The reviewed bundle contains an invalid opening balance.");
    }
    const key = `${String(entry.characterId)}:${definition.alias}`;
    if (openingKeys.has(key)) throw new LegacyImportError("The reviewed bundle contains duplicate opening balances.");
    openingKeys.add(key);
    economy[definition.alias] = (economy[definition.alias] ?? 0n) + BigInt(entry.amount);
  }
  if (digest(canonicalJson(bundle.openingBalances)) !== accountReport.evidenceDigest
    || openingKeys.size !== characters.size * aliases.length
    || [...characters.keys()].some((characterId) =>
      aliases.some((alias) => !openingKeys.has(`${characterId}:${alias}`)))
    || aliases.some((alias) =>
      economyTotal(transformedEconomy[alias]) !== (economy[alias] ?? 0n)
      || economyTotal(sourceEconomy[alias]) !== (economy[alias] ?? 0n))) {
    throw new LegacyImportError("Opening balance totals do not match the reviewed economy report.");
  }
  const groupReport = report.groups;
  if (!Array.isArray(groupReport.mappingIds)
    || !DIGEST_PATTERN.test(String(groupReport.evidenceDigest ?? ""))
    || !Array.isArray(groupReport.targetTables)
    || canonicalJson(groupReport.targetTables) !== canonicalJson([
      "synex_group_memberships",
      "synex_group_membership_profiles",
      "synex_group_membership_grades",
      "synex_group_primary_memberships_by_type",
    ])
    || groupReport.createsGroups !== false || groupReport.createsGrades !== false) {
    throw new LegacyImportError("The reviewed compatibility group report is invalid.");
  }
  let groupDefinitions: CompatibilityGroupDefinition[];
  if (groupReport.mappingIds.length === 0) {
    if (groupReport.catalogDigest !== null || bundle.groups.length !== 0) {
      throw new LegacyImportError("The reviewed compatibility group catalog binding is missing.");
    }
    groupDefinitions = [];
  } else {
    if (groupReport.catalogDigest !== groupCatalog.digest) {
      throw new LegacyImportError("The reviewed compatibility group catalog digest is stale.");
    }
    try {
      groupDefinitions = selectCompatibilityGroupDefinitions(
        groupCatalog,
        report.framework,
        groupReport.mappingIds,
      );
    } catch (error) {
      throw new LegacyImportError(
        error instanceof Error ? error.message : "Compatibility group mappings are invalid.",
      );
    }
    if (canonicalJson(groupReport.mappingIds)
      !== canonicalJson(groupDefinitions.map((definition) => definition.id))) {
      throw new LegacyImportError("Compatibility group mapping IDs are not canonical.");
    }
  }
  const groupDefinitionsById = new Map(
    groupDefinitions.map((definition) => [definition.id, definition]),
  );
  const membershipKeys = new Set<string>();
  const primaryTypeKeys = new Set<string>();
  for (const entry of bundle.groups) {
    const definition = isRecord(entry) && typeof entry.mappingId === "string"
      ? groupDefinitionsById.get(entry.mappingId)
      : undefined;
    const gradeDefinition = definition && typeof entry.legacyGrade === "number"
      ? definition.grades.find((grade) => grade.legacyGrade === entry.legacyGrade)
      : undefined;
    if (!isRecord(entry) || !characters.has(String(entry.characterId))
      || !definition || !gradeDefinition
      || entry.mappingVersion !== definition.version
      || entry.legacyType !== definition.legacyType
      || entry.legacyName !== definition.legacyName
      || entry.nativeGroupType !== definition.nativeGroupType
      || entry.nativeGroupKey !== definition.nativeGroupKey
      || entry.gradeKey !== gradeDefinition.gradeKey
      || entry.primary !== true
      || !finiteInteger(entry.legacyGrade) || entry.legacyGrade > 65_535) {
      throw new LegacyImportError("The reviewed bundle contains an invalid group membership.");
    }
    const key = `${String(entry.characterId)}:${definition.nativeGroupType}:${definition.nativeGroupKey}`;
    if (membershipKeys.has(key)) throw new LegacyImportError("The reviewed bundle contains duplicate group memberships.");
    membershipKeys.add(key);
    const primaryKey = `${String(entry.characterId)}:${definition.nativeGroupType}`;
    if (primaryTypeKeys.has(primaryKey)) {
      throw new LegacyImportError("The reviewed bundle contains ambiguous primary group memberships.");
    }
    primaryTypeKeys.add(primaryKey);
  }
  if (digest(canonicalJson(bundle.groups)) !== groupReport.evidenceDigest) {
    throw new LegacyImportError("The reviewed compatibility group evidence digest is invalid.");
  }
  const userMap = new Map<string, string>();
  for (const entry of idMap.users) {
    if (!isRecord(entry) || !UUID_PATTERN.test(String(entry.synexId)) || !boundedString(entry.legacyId, 128)
      || userMap.has(String(entry.synexId))) {
      throw new LegacyImportError("The reviewed user ID map contains invalid or duplicate entries.");
    }
    userMap.set(String(entry.synexId), entry.legacyId);
  }
  const characterMap = new Map<string, string>();
  for (const entry of idMap.characters) {
    if (!isRecord(entry) || !UUID_PATTERN.test(String(entry.synexId)) || !boundedString(entry.legacyId, 128)
      || characterMap.has(String(entry.synexId))) {
      throw new LegacyImportError("The reviewed character ID map contains invalid or duplicate entries.");
    }
    characterMap.set(String(entry.synexId), entry.legacyId);
  }
  if (idMap.users.length !== users.size || idMap.characters.length !== characters.size
    || userMap.size !== users.size || characterMap.size !== characters.size
    || [...users].some(([id, legacyId]) => userMap.get(id) !== legacyId)
    || [...characters].some(([id, entry]) => characterMap.get(id) !== entry.legacyId)) {
    throw new LegacyImportError("ID-map artifacts do not match the reviewed bundle.");
  }
  return value as unknown as MigrationPlan;
}

export async function loadReviewedMigrationPlan(
  directoryPath: string,
  expectedDigest: string,
): Promise<MigrationPlan> {
  const directory = resolve(directoryPath);
  const metadata = await lstat(directory);
  if (!metadata.isDirectory() || metadata.isSymbolicLink()
    || await pathContainsSymbolicLink(directory)) {
    throw new LegacyImportError("The reviewed bundle path must be a real directory.");
  }
  const [report, idMap, bundle] = await Promise.all([
    readArtifact(directory, "migration-report.json"),
    readArtifact(directory, "id-map.json"),
    readArtifact(directory, "migration-bundle.json"),
  ]);
  let metadataCatalog: CompatibilityMetadataCatalog;
  let accountCatalog: CompatibilityAccountCatalog;
  let groupCatalog: CompatibilityGroupCatalog;
  try {
    [metadataCatalog, accountCatalog, groupCatalog] = await Promise.all([
      loadCompatibilityMetadataCatalog(),
      loadCompatibilityAccountCatalog(),
      loadCompatibilityGroupCatalog(),
    ]);
  } catch (error) {
    throw new LegacyImportError(
      error instanceof Error ? error.message : "Compatibility catalog loading failed.",
    );
  }
  return validateReviewedPlan(
    { report, idMap, bundle },
    expectedDigest,
    metadataCatalog,
    accountCatalog,
    groupCatalog,
  );
}

export async function connectImportDatabase(connectionUrl: string): Promise<ImportDatabase> {
  if (!connectionUrl || connectionUrl.length > 4096) {
    throw new LegacyImportError("The migration database URL is missing or invalid.");
  }
  let parsed: URL;
  try {
    parsed = new URL(connectionUrl);
  } catch {
    throw new LegacyImportError("The migration database URL is malformed.");
  }
  if (parsed.protocol !== "mysql:" || !parsed.hostname || !parsed.pathname || parsed.pathname === "/") {
    throw new LegacyImportError("The migration database URL must use mysql:// and name a target database.");
  }
  if (parsed.searchParams.has("multipleStatements")) {
    throw new LegacyImportError("The migration database URL must not override multipleStatements.");
  }
  let connection: Connection;
  try {
    connection = await createConnection({ uri: connectionUrl, multipleStatements: false });
  } catch {
    throw new LegacyImportError("The migration database connection could not be established.");
  }
  return {
    begin: () => connection.beginTransaction(),
    commit: () => connection.commit(),
    rollback: () => connection.rollback(),
    close: () => connection.end(),
    execute: async (sql, parameters = []) => {
      const [raw] = await connection.execute(sql, [...parameters]);
      if (Array.isArray(raw)) {
        return { rows: (raw as RowDataPacket[]).map((row) => ({ ...row })), insertId: 0, affectedRows: raw.length };
      }
      const header = raw as ResultSetHeader;
      return { rows: [], insertId: header.insertId, affectedRows: header.affectedRows };
    },
  };
}

function identifierFor(legacyId: string): { type: string; value: string } {
  const match = PLATFORM_IDENTIFIER_PATTERN.exec(legacyId);
  if (!match?.[1] || !match[2]) {
    throw new LegacyImportError(
      'Every imported user ID must be a supported Cfx platform identifier with its type prefix.',
    );
  }
  return { type: match[1], value: match[2].toLowerCase() };
}

async function assertSchema(database: ImportDatabase): Promise<void> {
  const placeholders = REQUIRED_TABLES.map(() => "?").join(", ");
  const result = await database.execute(
    `SELECT table_name FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name IN (${placeholders})`,
    REQUIRED_TABLES,
  );
  const present = new Set(result.rows.map((row) => String(row.table_name ?? row.TABLE_NAME ?? "")));
  const missing = REQUIRED_TABLES.filter((table) => !present.has(table));
  if (missing.length > 0) {
    throw new LegacyImportError(`Target schema is missing required migrations: ${missing.join(", ")}.`);
  }
}

async function provisionAccountOwner(
  database: ImportDatabase,
  accountId: string,
  ownerKind: "character" | "system",
  ownerRef: string,
  actorRef: string,
): Promise<void> {
  const roleId = deterministicId("account-owner-role", accountId);
  const grantId = deterministicId("account-owner-grant", accountId, ownerKind, ownerRef);
  await database.execute(
    `INSERT INTO synex_account_access_roles
      (public_id, account_id, role_key, display_name, version)
      SELECT ?, id, 'owner', 'Owner', 1 FROM synex_accounts WHERE public_id = ?`,
    [roleId, accountId],
  );
  await database.execute(
    `INSERT INTO synex_account_access_role_permissions (role_id, permission_key)
      SELECT role.id, permission.permission_key
      FROM synex_account_access_roles role
      CROSS JOIN (SELECT 'view' AS permission_key UNION ALL SELECT 'deposit'
        UNION ALL SELECT 'withdraw' UNION ALL SELECT 'transfer' UNION ALL SELECT 'history'
        UNION ALL SELECT 'manage' UNION ALL SELECT 'close') permission
      WHERE role.public_id = ?`,
    [roleId],
  );
  await database.execute(
    `INSERT INTO synex_account_access_grants
      (public_id, account_id, role_id, principal_kind, principal_ref, status,
        active_marker, valid_until, granted_by_ref, version)
      SELECT ?, account.id, role.id, ?, ?, 'active', 1, NULL, ?, 1
      FROM synex_accounts account
      INNER JOIN synex_account_access_roles role ON role.account_id = account.id AND role.public_id = ?
      WHERE account.public_id = ?`,
    [grantId, ownerKind, ownerRef, actorRef, roleId, accountId],
  );
}

interface SystemAccountState {
  publicId: string;
  booked: number;
  sequence: number;
}

function currencyDisplayName(currencyCode: string): string {
  return currencyCode
    .split("_")
    .map((part) => `${part.slice(0, 1).toUpperCase()}${part.slice(1)}`)
    .join(" ");
}

async function ensureSystemAccount(
  database: ImportDatabase,
  currencyPublicId: string,
  currencyCode: string,
  role: "mint" | "burn",
  actorRef: string,
): Promise<SystemAccountState> {
  const linked = await database.execute(
    `SELECT account.public_id, account.account_role, account.allow_negative, account.status,
      account.currency_id AS account_currency_id, topology.currency_id AS topology_currency_id,
      snapshot.booked_minor, snapshot.sequence_no
      FROM synex_currency_system_topology topology
      INNER JOIN synex_currencies currency ON currency.id = topology.currency_id
      LEFT JOIN synex_accounts account ON account.id = CASE WHEN ? = 'mint'
        THEN topology.mint_account_id ELSE topology.burn_account_id END
      LEFT JOIN synex_account_balance_snapshots snapshot ON snapshot.account_id = account.id
        AND snapshot.sequence_no = (SELECT MAX(latest.sequence_no)
          FROM synex_account_balance_snapshots latest WHERE latest.account_id = account.id)
      WHERE currency.public_id = ? LIMIT 1`,
    [role, currencyPublicId],
  );
  if (linked.rows.length === 0) {
    throw new LegacyImportError(`The ${currencyCode} currency topology is unavailable.`);
  }

  let account = linked.rows[0];
  if (!account?.public_id) {
    const publicId = deterministicId("system-account", currencyPublicId, role);
    await database.execute(
      `INSERT INTO synex_accounts
        (public_id, currency_id, account_key, account_role, allow_negative, status, metadata_json, version)
        SELECT ?, id, ?, ?, ?, 'active', ?, 1 FROM synex_currencies WHERE public_id = ?`,
      [publicId, `synex_${role}_${currencyCode}`, role, role === "mint" ? 1 : 0,
        canonicalJson({ migration: { owner: "synex_migrator", role } }).trim(), currencyPublicId],
    );
    await database.execute(
      `INSERT INTO synex_account_owners (account_id, owner_kind, owner_ref)
        SELECT id, 'system', 'legacy_migration' FROM synex_accounts WHERE public_id = ?`,
      [publicId],
    );
    await provisionAccountOwner(database, publicId, "system", "legacy_migration", actorRef);
    await database.execute(
      `INSERT INTO synex_account_balance_snapshots
        (account_id, sequence_no, source_kind, source_ref, booked_minor, reserved_minor)
        SELECT id, 0, 'opening', ?, 0, 0 FROM synex_accounts WHERE public_id = ?`,
      [deterministicId("system-opening", currencyPublicId, role), publicId],
    );
    const topologyColumn = role === "mint" ? "mint_account_id" : "burn_account_id";
    await database.execute(
      `UPDATE synex_currency_system_topology topology
        INNER JOIN synex_currencies currency ON currency.id = topology.currency_id
        INNER JOIN synex_accounts account ON account.public_id = ?
        SET topology.${topologyColumn} = account.id, topology.version = topology.version + 1,
          topology.updated_at = CURRENT_TIMESTAMP(6)
        WHERE currency.public_id = ? AND topology.${topologyColumn} IS NULL`,
      [publicId, currencyPublicId],
    );
    account = {
      public_id: publicId,
      account_role: role,
      allow_negative: role === "mint" ? 1 : 0,
      status: "active",
      account_currency_id: currencyPublicId,
      topology_currency_id: currencyPublicId,
      booked_minor: 0,
      sequence_no: 0,
    };
  }

  const publicId = String(account.public_id ?? "");
  const booked = Number(account.booked_minor);
  const sequence = Number(account.sequence_no);
  if (!UUID_PATTERN.test(publicId) || account.account_role !== role || account.status !== "active"
    || account.booked_minor === null || account.booked_minor === undefined
    || account.sequence_no === null || account.sequence_no === undefined
    || String(account.account_currency_id) !== String(account.topology_currency_id)
    || Number(account.allow_negative) !== (role === "mint" ? 1 : 0)
    || !Number.isSafeInteger(booked) || !Number.isSafeInteger(sequence) || sequence < 0
    || (role === "mint" && booked > 0) || (role === "burn" && booked < 0)) {
    throw new LegacyImportError(`The ${currencyCode} ${role} account is incompatible with legacy import.`);
  }
  return { publicId, booked, sequence };
}

async function ensureCurrencyTopology(
  database: ImportDatabase,
  currencyPublicId: string,
  currencyCode: string,
  actorRef: string,
): Promise<SystemAccountState> {
  await database.execute(
    `INSERT INTO synex_currency_system_topology (currency_id, topology_state, version)
      SELECT id, 'incomplete', 1 FROM synex_currencies currency
      WHERE currency.public_id = ? AND NOT EXISTS (
        SELECT 1 FROM synex_currency_system_topology topology WHERE topology.currency_id = currency.id)`,
    [currencyPublicId],
  );
  const mint = await ensureSystemAccount(database, currencyPublicId, currencyCode, "mint", actorRef);
  await ensureSystemAccount(database, currencyPublicId, currencyCode, "burn", actorRef);
  const updated = await database.execute(
    `UPDATE synex_currency_system_topology topology
      INNER JOIN synex_currencies currency ON currency.id = topology.currency_id
      SET topology.topology_state = 'ready', topology.version = topology.version + 1,
        topology.updated_at = CURRENT_TIMESTAMP(6)
      WHERE currency.public_id = ? AND topology.mint_account_id IS NOT NULL
        AND topology.burn_account_id IS NOT NULL`,
    [currencyPublicId],
  );
  if (updated.affectedRows !== 1) {
    throw new LegacyImportError(`The ${currencyCode} currency topology could not be made ready.`);
  }
  return mint;
}

function decimalText(row: Record<string, unknown>, key: string): string {
  const value = String(row[key] ?? "");
  if (!/^-?[0-9]{1,36}$/u.test(value)) {
    throw new LegacyImportError(`Economy reconciliation returned an invalid ${key}.`);
  }
  return value;
}

async function reconcileCurrency(
  database: ImportDatabase,
  currencyPublicId: string,
  currencyCode: string,
  importId: string,
  actorRef: string,
): Promise<void> {
  const result = await database.execute(
    `SELECT currency.id AS currency_id, model.model_version,
      (SELECT COALESCE(MAX(ledger_transaction.id), 0) FROM synex_ledger_transactions ledger_transaction
        WHERE ledger_transaction.currency_id = currency.id) AS cutoff_transaction_id,
      (SELECT COALESCE(MAX(entry.id), 0) FROM synex_ledger_entries entry
        INNER JOIN synex_ledger_transactions ledger_transaction ON ledger_transaction.id = entry.transaction_id
        WHERE ledger_transaction.currency_id = currency.id) AS cutoff_entry_id,
      (SELECT COUNT(*) FROM synex_ledger_transactions ledger_transaction
        WHERE ledger_transaction.currency_id = currency.id AND ledger_transaction.status = 'posted')
        AS transaction_count,
      (SELECT COUNT(*) FROM synex_ledger_entries entry
        INNER JOIN synex_ledger_transactions ledger_transaction ON ledger_transaction.id = entry.transaction_id
        WHERE ledger_transaction.currency_id = currency.id) AS entry_count,
      (SELECT COUNT(*) FROM synex_accounts account WHERE account.currency_id = currency.id)
        AS account_count,
      (SELECT COALESCE(SUM(entry.amount_minor), 0) FROM synex_ledger_entries entry
        INNER JOIN synex_ledger_transactions ledger_transaction ON ledger_transaction.id = entry.transaction_id
        WHERE ledger_transaction.currency_id = currency.id) AS total_entry_sum_minor,
      (SELECT COALESCE(SUM(CASE WHEN entry.amount_minor < 0 THEN -entry.amount_minor ELSE 0 END), 0)
        FROM synex_ledger_entries entry
        INNER JOIN synex_ledger_transactions ledger_transaction ON ledger_transaction.id = entry.transaction_id
        WHERE ledger_transaction.currency_id = currency.id) AS total_debit_minor,
      (SELECT COALESCE(SUM(CASE WHEN entry.amount_minor > 0 THEN entry.amount_minor ELSE 0 END), 0)
        FROM synex_ledger_entries entry
        INNER JOIN synex_ledger_transactions ledger_transaction ON ledger_transaction.id = entry.transaction_id
        WHERE ledger_transaction.currency_id = currency.id) AS total_credit_minor,
      (SELECT COALESCE(SUM(entry.amount_minor), 0) FROM synex_ledger_entries entry
        INNER JOIN synex_ledger_transactions ledger_transaction ON ledger_transaction.id = entry.transaction_id
        INNER JOIN synex_accounts account ON account.id = entry.account_id
        WHERE ledger_transaction.currency_id = currency.id AND ledger_transaction.transaction_kind = 'mint'
          AND account.account_role = 'asset' AND entry.amount_minor > 0) AS minted_minor,
      (SELECT COALESCE(SUM(-entry.amount_minor), 0) FROM synex_ledger_entries entry
        INNER JOIN synex_ledger_transactions ledger_transaction ON ledger_transaction.id = entry.transaction_id
        INNER JOIN synex_accounts account ON account.id = entry.account_id
        WHERE ledger_transaction.currency_id = currency.id AND ledger_transaction.transaction_kind = 'burn'
          AND account.account_role = 'asset' AND entry.amount_minor < 0) AS burned_minor,
      (SELECT COALESCE(SUM(snapshot.booked_minor), 0)
        FROM synex_account_balance_snapshots snapshot
        INNER JOIN synex_accounts account ON account.id = snapshot.account_id
        WHERE account.currency_id = currency.id AND account.account_role = 'asset'
          AND NOT EXISTS (SELECT 1 FROM synex_account_balance_snapshots newer
            WHERE newer.account_id = snapshot.account_id AND newer.sequence_no > snapshot.sequence_no))
        AS total_booked_minor,
      (SELECT COALESCE(SUM(hold_record.remaining_minor), 0) FROM synex_account_holds hold_record
        INNER JOIN synex_accounts account ON account.id = hold_record.account_id
        WHERE account.currency_id = currency.id
          AND hold_record.state IN ('active', 'partially_captured')
          AND hold_record.expires_at > CURRENT_TIMESTAMP(6)) AS active_held_minor,
      (SELECT COUNT(*) FROM synex_ledger_transactions ledger_transaction
        WHERE ledger_transaction.currency_id = currency.id AND ledger_transaction.status = 'posted'
          AND ((SELECT COUNT(*) FROM synex_ledger_entries entry
                WHERE entry.transaction_id = ledger_transaction.id) <> ledger_transaction.entry_count
            OR (SELECT COUNT(*) FROM synex_ledger_entries entry
                WHERE entry.transaction_id = ledger_transaction.id) < 2
            OR COALESCE((SELECT SUM(entry.amount_minor) FROM synex_ledger_entries entry
                WHERE entry.transaction_id = ledger_transaction.id), 0) <> 0))
        AS transaction_sum_violation_count,
      (SELECT COUNT(*) FROM synex_accounts account
        INNER JOIN synex_account_balance_snapshots snapshot ON snapshot.account_id = account.id
          AND snapshot.sequence_no = (SELECT MAX(latest.sequence_no)
            FROM synex_account_balance_snapshots latest WHERE latest.account_id = account.id)
        WHERE account.currency_id = currency.id
          AND snapshot.booked_minor <> COALESCE((SELECT SUM(entry.amount_minor)
            FROM synex_ledger_entries entry WHERE entry.account_id = account.id), 0))
        AS snapshot_drift_count,
      (SELECT COUNT(*) FROM synex_account_balance_snapshots snapshot
        INNER JOIN synex_accounts account ON account.id = snapshot.account_id
        WHERE account.currency_id = currency.id AND account.account_role = 'asset'
          AND snapshot.booked_minor < 0
          AND NOT EXISTS (SELECT 1 FROM synex_account_balance_snapshots newer
            WHERE newer.account_id = snapshot.account_id AND newer.sequence_no > snapshot.sequence_no))
        AS negative_asset_count,
      (SELECT COUNT(*) FROM synex_account_balance_snapshots snapshot
        INNER JOIN synex_accounts account ON account.id = snapshot.account_id
        WHERE account.currency_id = currency.id AND account.account_role = 'asset'
          AND snapshot.reserved_minor > snapshot.booked_minor
          AND NOT EXISTS (SELECT 1 FROM synex_account_balance_snapshots newer
            WHERE newer.account_id = snapshot.account_id AND newer.sequence_no > snapshot.sequence_no))
        AS reserved_exceeds_booked_count,
      (SELECT COUNT(*) FROM synex_account_holds hold_record
        INNER JOIN synex_accounts account ON account.id = hold_record.account_id
        WHERE account.currency_id = currency.id
          AND (hold_record.amount_minor <> hold_record.captured_minor
              + hold_record.released_minor + hold_record.remaining_minor
            OR (hold_record.state IN ('captured', 'released', 'expired')
              AND hold_record.remaining_minor <> 0)
            OR (account.status = 'closed'
              AND hold_record.state IN ('active', 'partially_captured')))) AS invalid_hold_count,
      (SELECT COUNT(*) FROM synex_ledger_refund_anchors anchor
        INNER JOIN synex_ledger_transactions ledger_transaction
          ON ledger_transaction.id = anchor.original_transaction_id
        LEFT JOIN (SELECT anchor_transaction_id, SUM(amount_minor) AS total,
            MAX(cumulative_refunded_minor) AS maximum_cumulative
          FROM synex_ledger_refunds GROUP BY anchor_transaction_id) refund
          ON refund.anchor_transaction_id = anchor.original_transaction_id
        WHERE ledger_transaction.currency_id = currency.id
          AND (anchor.refunded_minor > anchor.refundable_minor
            OR anchor.refunded_minor <> COALESCE(refund.total, 0)
            OR COALESCE(refund.maximum_cumulative, 0) > anchor.refundable_minor))
        AS refund_limit_violation_count,
      (SELECT COUNT(*) FROM synex_ledger_reversals reversal
        INNER JOIN synex_ledger_transactions original ON original.id = reversal.original_transaction_id
        INNER JOIN synex_ledger_transactions inverse ON inverse.id = reversal.reversal_transaction_id
        WHERE original.currency_id = currency.id
          AND (original.currency_id <> inverse.currency_id OR original.id = inverse.id
            OR inverse.transaction_kind <> 'reversal')) AS invalid_reversal_count,
      (SELECT COUNT(*) FROM synex_currency_system_topology topology
        LEFT JOIN synex_accounts mint ON mint.id = topology.mint_account_id
        LEFT JOIN synex_accounts burn ON burn.id = topology.burn_account_id
        WHERE topology.currency_id = currency.id
          AND (topology.topology_state <> 'ready' OR mint.id IS NULL OR burn.id IS NULL
            OR mint.currency_id <> currency.id OR burn.currency_id <> currency.id
            OR mint.account_role <> 'mint' OR burn.account_role <> 'burn'
            OR mint.status = 'closed' OR burn.status = 'closed' OR mint.id = burn.id
            OR COALESCE((SELECT snapshot.booked_minor FROM synex_account_balance_snapshots snapshot
                WHERE snapshot.account_id = mint.id ORDER BY snapshot.sequence_no DESC LIMIT 1), 0) > 0
            OR COALESCE((SELECT snapshot.booked_minor FROM synex_account_balance_snapshots snapshot
                WHERE snapshot.account_id = burn.id ORDER BY snapshot.sequence_no DESC LIMIT 1), 0) < 0
            OR COALESCE((SELECT SUM(snapshot.booked_minor) FROM synex_accounts topology_account
                INNER JOIN synex_account_balance_snapshots snapshot ON snapshot.account_id = topology_account.id
                  AND snapshot.sequence_no = (SELECT MAX(latest.sequence_no)
                    FROM synex_account_balance_snapshots latest
                    WHERE latest.account_id = topology_account.id)
                WHERE topology_account.currency_id = currency.id), 0) <> 0)) AS invalid_topology_count,
      (SELECT COUNT(*) FROM synex_account_outbox outbox_record
        WHERE outbox_record.state = 'dead') AS outbox_problem_count,
      (SELECT COUNT(*) FROM synex_account_access_grants grant_record
        INNER JOIN synex_accounts account ON account.id = grant_record.account_id
        WHERE account.currency_id = currency.id
          AND ((grant_record.status = 'active' AND grant_record.active_marker <> 1)
            OR (grant_record.status <> 'active' AND grant_record.active_marker IS NOT NULL)
            OR (grant_record.valid_until IS NOT NULL
              AND grant_record.valid_until <= grant_record.valid_from))) AS grant_problem_count,
      (SELECT COUNT(*) FROM synex_ledger_transactions ledger_transaction
        WHERE ledger_transaction.currency_id = currency.id
          AND NOT EXISTS (SELECT 1 FROM synex_ledger_entries entry
            WHERE entry.transaction_id = ledger_transaction.id)) AS orphan_transaction_count,
      (SELECT COUNT(*) FROM synex_ledger_transactions ledger_transaction
        WHERE ledger_transaction.currency_id = currency.id
          AND ((SELECT COALESCE(MIN(entry.sequence_no), 0) FROM synex_ledger_entries entry
                WHERE entry.transaction_id = ledger_transaction.id) <> 1
            OR (SELECT COALESCE(MAX(entry.sequence_no), 0) FROM synex_ledger_entries entry
                WHERE entry.transaction_id = ledger_transaction.id)
              <> (SELECT COUNT(*) FROM synex_ledger_entries entry
                WHERE entry.transaction_id = ledger_transaction.id))) AS sequence_problem_count,
      (SELECT COUNT(*) FROM synex_account_operations operation
        INNER JOIN synex_ledger_transactions ledger_transaction ON ledger_transaction.operation_id = operation.id
        WHERE ledger_transaction.currency_id = currency.id
          AND (operation.state <> 'completed' OR operation.response_json IS NULL))
        AS idempotency_problem_count
      FROM synex_currencies currency
      INNER JOIN synex_economy_integrity_read_models model ON model.currency_id = currency.id
      WHERE currency.public_id = ? LIMIT 1`,
    [currencyPublicId],
  );
  const stats = result.rows[0];
  if (!stats || !finiteInteger(Number(stats.model_version), 1)) {
    throw new LegacyImportError(`The ${currencyCode} integrity model is unavailable.`);
  }
  const values = {
    currencyInternalId: decimalText(stats, "currency_id"),
    cutoffTransactionId: decimalText(stats, "cutoff_transaction_id"),
    cutoffEntryId: decimalText(stats, "cutoff_entry_id"),
    transactionCount: decimalText(stats, "transaction_count"),
    entryCount: decimalText(stats, "entry_count"),
    accountCount: decimalText(stats, "account_count"),
    totalEntrySumMinor: decimalText(stats, "total_entry_sum_minor"),
    totalDebitMinor: decimalText(stats, "total_debit_minor"),
    totalCreditMinor: decimalText(stats, "total_credit_minor"),
    mintedMinor: decimalText(stats, "minted_minor"),
    burnedMinor: decimalText(stats, "burned_minor"),
    totalBookedMinor: decimalText(stats, "total_booked_minor"),
    activeHeldMinor: decimalText(stats, "active_held_minor"),
    transactionSumViolationCount: decimalText(stats, "transaction_sum_violation_count"),
    snapshotDriftCount: decimalText(stats, "snapshot_drift_count"),
    negativeAssetCount: decimalText(stats, "negative_asset_count"),
    reservedExceedsBookedCount: decimalText(stats, "reserved_exceeds_booked_count"),
    invalidHoldCount: decimalText(stats, "invalid_hold_count"),
    refundLimitViolationCount: decimalText(stats, "refund_limit_violation_count"),
    invalidReversalCount: decimalText(stats, "invalid_reversal_count"),
    invalidTopologyCount: decimalText(stats, "invalid_topology_count"),
    outboxProblemCount: decimalText(stats, "outbox_problem_count"),
    grantProblemCount: decimalText(stats, "grant_problem_count"),
    orphanTransactionCount: decimalText(stats, "orphan_transaction_count"),
    sequenceProblemCount: decimalText(stats, "sequence_problem_count"),
    idempotencyProblemCount: decimalText(stats, "idempotency_problem_count"),
  };
  const findingDefinitions = [
    ["transactionSumViolationCount", "ledger.transaction_sum", "critical"],
    ["snapshotDriftCount", "snapshot.balance_drift", "error"],
    ["negativeAssetCount", "account.negative_asset", "warn"],
    ["reservedExceedsBookedCount", "hold.reserved_exceeds_booked", "warn"],
    ["invalidHoldCount", "hold.invalid_state", "warn"],
    ["refundLimitViolationCount", "refund.limit_violation", "error"],
    ["invalidReversalCount", "reversal.invalid_relationship", "error"],
    ["invalidTopologyCount", "currency.invalid_topology", "critical"],
    ["outboxProblemCount", "outbox.delivery_problem", "warn"],
    ["grantProblemCount", "access.invalid_grant", "warn"],
    ["orphanTransactionCount", "ledger.orphan_transaction", "error"],
    ["sequenceProblemCount", "ledger.sequence_problem", "warn"],
    ["idempotencyProblemCount", "idempotency.invalid_receipt", "error"],
  ] as const;
  const findings: Array<{ rule: string; severity: "warn" | "error" | "critical"; details: Record<string, string> }> = [];
  for (const [field, rule, severity] of findingDefinitions) {
    if (BigInt(values[field]) !== 0n) findings.push({ rule, severity, details: { count: values[field] } });
  }
  const severityCounts = {
    warn: findings.filter((finding) => finding.severity === "warn").length,
    error: findings.filter((finding) => finding.severity === "error").length,
    critical: findings.filter((finding) => finding.severity === "critical").length,
  };
  const modelVersion = Number(stats.model_version) + 1;
  const status = severityCounts.critical > 0 ? "critical"
    : severityCounts.error > 0 ? "error" : severityCounts.warn > 0 ? "warn" : "healthy";
  const netSupplyMinor = (BigInt(values.mintedMinor) - BigInt(values.burnedMinor)).toString();
  const operationId = deterministicId("reconciliation-operation", importId, currencyCode);
  const runId = deterministicId("reconciliation-run", importId, currencyCode);
  const eventId = deterministicId("reconciliation-event", importId, currencyCode);
  const response = canonicalJson({
    run_id: runId, currency_id: currencyPublicId, currency_code: currencyCode,
    model_version: modelVersion, cutoff_transaction_id: values.cutoffTransactionId,
    cutoff_entry_id: values.cutoffEntryId, transaction_count: values.transactionCount,
    entry_count: values.entryCount, account_count: values.accountCount,
    total_entry_sum_minor: values.totalEntrySumMinor,
    total_debit_minor: values.totalDebitMinor, total_credit_minor: values.totalCreditMinor,
    minted_minor: values.mintedMinor, burned_minor: values.burnedMinor,
    net_supply_minor: netSupplyMinor, total_booked_minor: values.totalBookedMinor,
    active_held_minor: values.activeHeldMinor, status, finding_count: findings.length,
    findings: findings.map((finding) => ({ rule: finding.rule, severity: finding.severity })),
  }).trim();
  await database.execute(
    `INSERT INTO synex_account_operations
      (idempotency_key, caller_resource, caller_principal_kind, caller_principal_ref, trace_id,
        operation_name, request_fingerprint, state, response_json, completed_at)
      VALUES (?, 'synex_migrator', 'migration', ?, ?, 'legacy_reconciliation', ?,
        'completed', ?, CURRENT_TIMESTAMP(6))`,
    [operationId, actorRef, operationId, digest(`${importId}:${currencyCode}`), response],
  );
  const updated = await database.execute(
    `UPDATE synex_economy_integrity_read_models SET model_version = model_version + 1,
      cutoff_posting_id = ?, cutoff_transaction_id = ?, cutoff_entry_id = ?, transaction_count = ?,
      posting_count = ?, entry_count = ?, account_count = ?, total_debit_minor = ?,
      total_credit_minor = ?, total_entry_sum_minor = ?, minted_minor = ?, burned_minor = ?,
      net_supply_minor = ?, total_booked_minor = ?, active_held_minor = ?,
      negative_asset_count = ?, reserved_exceeds_booked_count = ?, orphan_transaction_count = ?,
      transaction_sum_violation_count = ?, snapshot_drift_count = ?, invalid_hold_count = ?,
      refund_limit_violation_count = ?, invalid_reversal_count = ?, invalid_topology_count = ?,
      outbox_problem_count = ?, grant_problem_count = ?, sequence_problem_count = ?,
      idempotency_problem_count = ?, info_count = 0, warn_count = ?, error_count = ?,
      critical_count = ?, finding_count = ?, status = ?, generated_at = CURRENT_TIMESTAMP(6)
      WHERE currency_id = ? AND model_version = ?`,
    [values.cutoffEntryId, values.cutoffTransactionId, values.cutoffEntryId,
      values.transactionCount, values.entryCount, values.entryCount, values.accountCount,
      values.totalDebitMinor, values.totalCreditMinor, values.totalEntrySumMinor,
      values.mintedMinor, values.burnedMinor, netSupplyMinor, values.totalBookedMinor,
      values.activeHeldMinor, values.negativeAssetCount, values.reservedExceedsBookedCount,
      values.orphanTransactionCount, values.transactionSumViolationCount, values.snapshotDriftCount,
      values.invalidHoldCount, values.refundLimitViolationCount, values.invalidReversalCount,
      values.invalidTopologyCount, values.outboxProblemCount, values.grantProblemCount,
      values.sequenceProblemCount, values.idempotencyProblemCount, severityCounts.warn,
      severityCounts.error, severityCounts.critical, findings.length, status,
      values.currencyInternalId, Number(stats.model_version)],
  );
  if (updated.affectedRows !== 1) throw new LegacyImportError(`The ${currencyCode} integrity model changed during import.`);
  await database.execute(
    `INSERT INTO synex_economy_reconciliation_runs
      (public_id, operation_id, currency_id, model_version, cutoff_posting_id,
        cutoff_transaction_id, cutoff_entry_id, transaction_count, posting_count, entry_count,
        account_count, total_debit_minor, total_credit_minor, total_entry_sum_minor,
        minted_minor, burned_minor, net_supply_minor, total_booked_minor, active_held_minor,
        transaction_sum_violation_count, snapshot_drift_count, invalid_hold_count,
        refund_limit_violation_count, invalid_reversal_count, invalid_topology_count,
        outbox_problem_count, grant_problem_count, sequence_problem_count, idempotency_problem_count,
        info_count, warn_count, error_count, critical_count, finding_count, status,
        requested_by_ref, source_resource, trace_id, actor_kind, summary_json, started_at, completed_at)
      SELECT ?, operation.id, currency.id, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
        ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?, ?, ?, ?, 'synex_migrator', ?, 'migration', ?,
        CURRENT_TIMESTAMP(6), CURRENT_TIMESTAMP(6)
      FROM synex_account_operations operation, synex_currencies currency
      WHERE operation.idempotency_key = ? AND currency.public_id = ?`,
    [runId, modelVersion, values.cutoffEntryId, values.cutoffTransactionId, values.cutoffEntryId,
      values.transactionCount, values.entryCount, values.entryCount, values.accountCount,
      values.totalDebitMinor, values.totalCreditMinor, values.totalEntrySumMinor,
      values.mintedMinor, values.burnedMinor, netSupplyMinor, values.totalBookedMinor,
      values.activeHeldMinor, values.transactionSumViolationCount, values.snapshotDriftCount,
      values.invalidHoldCount, values.refundLimitViolationCount, values.invalidReversalCount,
      values.invalidTopologyCount, values.outboxProblemCount, values.grantProblemCount,
      values.sequenceProblemCount, values.idempotencyProblemCount, severityCounts.warn,
      severityCounts.error, severityCounts.critical, findings.length, status, actorRef,
      operationId, response, operationId, currencyPublicId],
  );
  for (const finding of findings) {
    await database.execute(
      `INSERT INTO synex_economy_anomaly_findings
        (public_id, run_id, rule_key, severity, aggregate_type, aggregate_id, details_json)
        SELECT ?, id, ?, ?, 'currency', ?, ?
        FROM synex_economy_reconciliation_runs WHERE public_id = ?`,
      [deterministicId("reconciliation-finding", runId, finding.rule), finding.rule, finding.severity,
        currencyPublicId, canonicalJson(finding.details).trim(), runId],
    );
  }
  await database.execute(
    `INSERT INTO synex_account_audit
      (event_id, operation_id, event_type, aggregate_id, source_resource, trace_id,
        reference_type, reference_id, actor_kind, actor_ref, snapshot_json)
      SELECT ?, id, 'synex.accounts.reconciliation_completed', ?, 'synex_migrator', ?,
        'migration.import', ?, 'migration', ?, ?
      FROM synex_account_operations WHERE idempotency_key = ?`,
    [eventId, runId, operationId, importId, actorRef, response, operationId],
  );
  await database.execute(
    `INSERT INTO synex_account_outbox
      (event_id, aggregate_id, event_type, schema_version, trace_id, payload_json)
      VALUES (?, ?, 'synex.accounts.reconciliation_completed', 1, ?, ?)`,
    [eventId, currencyPublicId, operationId, response],
  );
}

export async function importReviewedMigrationPlan(
  plan: MigrationPlan,
  database: ImportDatabase,
  allowUnsupported: boolean,
): Promise<ImportResult> {
  if (plan.report.counts.unsupported > 0 && !allowUnsupported) {
    throw new LegacyImportError("Import requires --allow-unsupported because the reviewed report contains omissions.");
  }
  await assertSchema(database);
  const previous = await database.execute(
    "SELECT state FROM synex_legacy_imports WHERE report_digest = ? LIMIT 1",
    [plan.report.reportDigest],
  );
  if (previous.rows[0]?.state === "completed") {
    return {
      schema: 1,
      artifactKind: "synex-legacy-import-result",
      framework: plan.report.framework,
      reportDigest: plan.report.reportDigest,
      alreadyApplied: true,
      counts: {
        users: plan.bundle.users.length,
        characters: plan.bundle.characters.length,
        identifiers: plan.bundle.users.length,
        accounts: plan.bundle.openingBalances.length,
        ledgerTransactions: plan.bundle.openingBalances.filter((entry) => entry.amount > 0).length,
        groups: new Set(plan.bundle.groups.map((entry) =>
          `${entry.nativeGroupType}:${entry.nativeGroupKey}`)).size,
        memberships: plan.bundle.groups.length,
        metadata: plan.bundle.metadata.length,
      },
    };
  }
  if (previous.rows.length > 0) {
    throw new LegacyImportError("A non-completed import already exists for this report digest.");
  }

  const framework = plan.report.framework;
  const actor = `legacy_migration:${framework}`;
  const importId = deterministicId("import", framework, plan.report.reportDigest);
  const groupTargetCount = new Set(plan.bundle.groups.map((entry) =>
    `${entry.nativeGroupType}:${entry.nativeGroupKey}`)).size;

  await database.begin();
  try {
    const groupTargets = new Map<string, {
      groupInternalId: number;
      groupPublicId: string;
      groupTypeInternalId: number;
      gradeInternalId: number;
      gradePublicId: string;
    }>();
    for (const membership of plan.bundle.groups) {
      const targetKey = [
        membership.nativeGroupType,
        membership.nativeGroupKey,
        membership.gradeKey,
      ].join(":");
      if (groupTargets.has(targetKey)) continue;
      const resolvedTarget = await database.execute(
        `SELECT group_record.id AS group_internal_id,
            group_record.public_id AS group_public_id,
            group_type.id AS group_type_internal_id,
            grade.id AS grade_internal_id,
            grade.public_id AS grade_public_id
          FROM synex_group_types AS group_type
          INNER JOIN synex_group_organization_profiles AS organization
            ON organization.group_type_id = group_type.id
          INNER JOIN synex_groups AS group_record
            ON group_record.id = organization.group_id
          INNER JOIN synex_group_grades AS grade
            ON grade.group_id = group_record.id AND grade.grade_key = ?
          WHERE group_type.type_key = ? AND organization.slug = ?
            AND group_type.status = 'active'
            AND organization.lifecycle_state = 'ACTIVE'
            AND group_record.status = 'active' AND grade.status = 'active'
          ORDER BY group_record.id ASC, grade.id ASC LIMIT 2 FOR UPDATE`,
        [membership.gradeKey, membership.nativeGroupType, membership.nativeGroupKey],
      );
      const row = resolvedTarget.rows[0];
      const groupInternalId = Number(row?.group_internal_id);
      const groupTypeInternalId = Number(row?.group_type_internal_id);
      const gradeInternalId = Number(row?.grade_internal_id);
      if (resolvedTarget.rows.length !== 1
        || !finiteInteger(groupInternalId, 1)
        || !finiteInteger(groupTypeInternalId, 1)
        || !finiteInteger(gradeInternalId, 1)
        || !boundedString(row?.group_public_id, 48)
        || !boundedString(row?.grade_public_id, 48)) {
        throw new LegacyImportError(
          `Mapped Synex group target ${targetKey} is missing, inactive, or ambiguous.`,
        );
      }
      groupTargets.set(targetKey, {
        groupInternalId,
        groupPublicId: row.group_public_id,
        groupTypeInternalId,
        gradeInternalId,
        gradePublicId: row.grade_public_id,
      });
    }
    await database.execute(
      `INSERT INTO synex_legacy_imports
        (public_id, framework, report_digest, state, source_user_count, source_character_count)
        VALUES (?, ?, ?, 'running', ?, ?)`,
      [importId, framework, plan.report.reportDigest, plan.bundle.users.length, plan.bundle.characters.length],
    );

    for (const user of plan.bundle.users) {
      const identifier = identifierFor(user.legacyId);
      await database.execute(
        "INSERT INTO synex_users (id, status, locale, metadata_json, version) VALUES (?, 'active', 'en', ?, 1)",
        [user.id, canonicalJson({ migration: { framework, reportDigest: plan.report.reportDigest } }).trim()],
      );
      await database.execute(
        `INSERT INTO synex_identifiers
          (user_id, identifier_type, identifier_value, verified_at, first_seen_at, last_seen_at)
          VALUES (?, ?, ?, NULL, CURRENT_TIMESTAMP(6), CURRENT_TIMESTAMP(6))`,
        [user.id, identifier.type, identifier.value],
      );
      await database.execute(
        `INSERT INTO synex_legacy_id_mappings
          (import_id, framework, entity_kind, legacy_id_hash, synex_id)
          VALUES ((SELECT id FROM synex_legacy_imports WHERE public_id = ?), ?, 'user', ?, ?)`,
        [importId, framework, digest(user.legacyId), user.id],
      );
    }

    const slotLimits = new Map<string, number>();
    for (const character of plan.bundle.characters) {
      slotLimits.set(character.userId, Math.max(slotLimits.get(character.userId) ?? 1, character.slot));
    }
    for (const [userId, slotLimit] of slotLimits) {
      await database.execute(
        "INSERT INTO synex_character_slots (user_id, slot_limit, version) VALUES (?, ?, 1)",
        [userId, slotLimit],
      );
    }
    for (const character of plan.bundle.characters) {
      await database.execute(
        `INSERT INTO synex_characters
          (id, user_id, slot, status, first_name, last_name, metadata_json, version)
          VALUES (?, ?, ?, 'active', ?, ?, ?, 1)`,
        [character.id, character.userId, character.slot, character.firstName, character.lastName,
          canonicalJson({ migration: { framework, reportDigest: plan.report.reportDigest } }).trim()],
      );
      await database.execute(
        `INSERT INTO synex_legacy_id_mappings
          (import_id, framework, entity_kind, legacy_id_hash, synex_id)
          VALUES ((SELECT id FROM synex_legacy_imports WHERE public_id = ?), ?, 'character', ?, ?)`,
        [importId, framework, digest(character.legacyId), character.id],
      );
      await database.execute(
        `INSERT INTO synex_compatibility_identities
          (provider, identifier_type, legacy_identifier, synex_character_id, import_source)
          VALUES (?, ?, ?, ?, ?)`,
        [
          framework,
          framework === "esx" ? "identifier" : "citizenid",
          character.legacyId,
          character.id,
          `migration:${plan.report.reportDigest}`,
        ],
      );
    }

    for (const entry of plan.bundle.metadata) {
      await database.execute(
        `INSERT INTO synex_compatibility_metadata
          (provider, synex_character_id, metadata_key, value_json, version)
          VALUES (?, ?, ?, ?, 1)`,
        [framework, entry.characterId, entry.metadataKey, canonicalJson(entry.value).trim()],
      );
    }

    const currencyPublicIds = new Map<string, string>();
    const mintState = new Map<string, SystemAccountState>();
    const currencyDefinitions = new Map<string, number>();
    for (const opening of plan.bundle.openingBalances) {
      const existingMinorUnit = currencyDefinitions.get(opening.currency);
      if (existingMinorUnit !== undefined && existingMinorUnit !== opening.minorUnit) {
        throw new LegacyImportError(
          `Compatibility account mappings disagree about ${opening.currency} precision.`,
        );
      }
      currencyDefinitions.set(opening.currency, opening.minorUnit);
    }
    const currencies = [...currencyDefinitions].sort(([left], [right]) => compareText(left, right));
    for (const [currency, minorUnit] of currencies) {
      const existingCurrency = await database.execute(
        "SELECT public_id, minor_unit, status FROM synex_currencies WHERE currency_code = ? LIMIT 1",
        [currency],
      );
      let currencyId = String(existingCurrency.rows[0]?.public_id ?? "");
      if (existingCurrency.rows.length > 0) {
        if (!UUID_PATTERN.test(currencyId) || Number(existingCurrency.rows[0]?.minor_unit) !== minorUnit
          || existingCurrency.rows[0]?.status !== "active") {
          throw new LegacyImportError(`Existing ${currency} currency is incompatible with the reviewed opening balances.`);
        }
      } else {
        currencyId = deterministicId("currency", currency);
        await database.execute(
          `INSERT INTO synex_currencies (public_id, currency_code, display_name, minor_unit, status)
            VALUES (?, ?, ?, ?, 'active')`,
          [currencyId, currency, currencyDisplayName(currency), minorUnit],
        );
      }
      currencyPublicIds.set(currency, currencyId);
      await database.execute(
        `INSERT INTO synex_economy_integrity_read_models (currency_id)
          SELECT currency.id FROM synex_currencies currency
          WHERE currency.public_id = ?
            AND NOT EXISTS (SELECT 1 FROM synex_economy_integrity_read_models model WHERE model.currency_id = currency.id)`,
        [currencyId],
      );
      mintState.set(currency, await ensureCurrencyTopology(database, currencyId, currency, actor));
    }

    for (const opening of plan.bundle.openingBalances) {
      const accountIdentity = `${opening.currency}:${opening.accountKey}:${opening.accountRole}`;
      const accountId = deterministicId("asset-account", framework, opening.characterId, accountIdentity);
      const operationId = deterministicId("opening-operation", framework, opening.characterId, accountIdentity);
      const transactionId = deterministicId("opening-transaction", framework, opening.characterId, accountIdentity);
      const postingId = deterministicId("opening-posting", framework, opening.characterId, accountIdentity);
      const debitEntryId = deterministicId("opening-entry-debit", framework, opening.characterId, accountIdentity);
      const creditEntryId = deterministicId("opening-entry-credit", framework, opening.characterId, accountIdentity);
      const auditId = deterministicId("opening-audit", framework, opening.characterId, accountIdentity);
      const currencyId = currencyPublicIds.get(opening.currency);
      if (!currencyId) throw new LegacyImportError("Opening balance references an unavailable migration currency.");
      const response = canonicalJson({
        account_id: accountId,
        account_key: opening.accountKey,
        account_alias: opening.alias,
        amount_minor: opening.amount,
        currency: opening.currency,
      }).trim();
      await database.execute(
        `INSERT INTO synex_account_operations
          (idempotency_key, caller_resource, caller_principal_kind, caller_principal_ref, trace_id,
            operation_name, request_fingerprint, state, response_json, completed_at)
          VALUES (?, 'synex_migrator', 'migration', ?, ?, 'legacy_opening_balance', ?,
            'completed', ?, CURRENT_TIMESTAMP(6))`,
        [operationId, actor, operationId,
          digest(`${framework}:${opening.characterId}:${accountIdentity}:${opening.amount}`), response],
      );
      await database.execute(
        `INSERT INTO synex_accounts
          (public_id, currency_id, account_key, account_role, allow_negative, status, metadata_json, version)
          SELECT ?, id, ?, ?, 0, 'active', ?, 1 FROM synex_currencies WHERE public_id = ?`,
        [accountId, opening.accountKey, opening.accountRole, canonicalJson({
          compatibility: {
            alias: opening.alias,
            mappingId: opening.mappingId,
            mappingVersion: opening.mappingVersion,
          },
          migration: { framework, characterId: opening.characterId },
        }).trim(), currencyId],
      );
      await database.execute(
        `INSERT INTO synex_account_owners (account_id, owner_kind, owner_ref)
          SELECT id, 'character', ? FROM synex_accounts WHERE public_id = ?`,
        [opening.characterId, accountId],
      );
      await provisionAccountOwner(database, accountId, "character", opening.characterId, actor);
      await database.execute(
        `INSERT INTO synex_account_balance_snapshots
          (account_id, sequence_no, source_kind, source_ref, booked_minor, reserved_minor)
          SELECT id, 0, 'opening', ?, 0, 0 FROM synex_accounts WHERE public_id = ?`,
        [operationId, accountId],
      );
      if (opening.amount > 0) {
        const mint = mintState.get(opening.currency);
        if (!mint) throw new LegacyImportError("Opening balance references an unavailable migration currency.");
        mint.sequence += 1;
        mint.booked -= opening.amount;
        if (!Number.isSafeInteger(mint.booked) || mint.booked < -Number.MAX_SAFE_INTEGER) {
          throw new LegacyImportError(
            `The ${opening.currency} opening total exceeds the supported system-account range.`,
          );
        }
        await database.execute(
          `INSERT INTO synex_ledger_transactions
            (public_id, operation_id, currency_id, posting_model, entry_count, transaction_kind,
              reason_code, source_resource, trace_id, reference_type, reference_id, reference_text,
              actor_kind, actor_ref, metadata_json, status, posted_at)
            SELECT ?, operation.id, currency.id, 'multi_leg', 2, 'opening_balance',
              'synex_accounts.opening_balance', 'synex_migrator', ?, 'migration.import', ?,
              'legacy_migration_opening_balance', 'migration', ?, ?, 'posted', CURRENT_TIMESTAMP(6)
            FROM synex_account_operations operation, synex_currencies currency
            WHERE operation.idempotency_key = ? AND currency.public_id = ?`,
          [transactionId, operationId, importId, actor,
            canonicalJson({ framework, importId }).trim(), operationId, currencyId],
        );
        await database.execute(
          `INSERT INTO synex_ledger_entries
            (public_id, transaction_id, account_id, sequence_no, amount_minor, metadata_json)
            SELECT ?, ledger_transaction.id, account.id, 1, ?, ?
            FROM synex_ledger_transactions ledger_transaction, synex_accounts account
            WHERE ledger_transaction.public_id = ? AND account.public_id = ?
            UNION ALL
            SELECT ?, ledger_transaction.id, account.id, 2, ?, ?
            FROM synex_ledger_transactions ledger_transaction, synex_accounts account
            WHERE ledger_transaction.public_id = ? AND account.public_id = ?`,
          [debitEntryId, -opening.amount, canonicalJson({ side: "migration_system" }).trim(),
            transactionId, mint.publicId,
            creditEntryId, opening.amount, canonicalJson({ side: "character_asset" }).trim(),
            transactionId, accountId],
        );
        await database.execute(
          `INSERT INTO synex_ledger_postings
            (public_id, transaction_id, debit_account_id, credit_account_id, debit_minor, credit_minor)
            SELECT ?, transaction.id, debit.id, credit.id, ?, ?
            FROM synex_ledger_transactions transaction, synex_accounts debit, synex_accounts credit
            WHERE transaction.public_id = ? AND debit.public_id = ? AND credit.public_id = ?`,
          [postingId, opening.amount, opening.amount, transactionId, mint.publicId, accountId],
        );
        await database.execute(
          `UPDATE synex_currencies currency
            INNER JOIN synex_ledger_transactions ledger_transaction
              ON ledger_transaction.currency_id = currency.id AND ledger_transaction.public_id = ?
            SET currency.precision_locked_at = COALESCE(
                currency.precision_locked_at, ledger_transaction.occurred_at),
              currency.precision_lock_transaction_id = COALESCE(
                currency.precision_lock_transaction_id, ledger_transaction.id)
            WHERE currency.public_id = ?`,
          [transactionId, currencyId],
        );
        await database.execute(
          `INSERT INTO synex_account_balance_snapshots
            (account_id, sequence_no, source_kind, source_ref, booked_minor, reserved_minor)
            SELECT id, ?, 'ledger', ?, ?, 0 FROM synex_accounts WHERE public_id = ?`,
          [mint.sequence, transactionId, mint.booked, mint.publicId],
        );
        await database.execute(
          `INSERT INTO synex_account_balance_snapshots
            (account_id, sequence_no, source_kind, source_ref, booked_minor, reserved_minor)
            SELECT id, 1, 'ledger', ?, ?, 0 FROM synex_accounts WHERE public_id = ?`,
          [transactionId, opening.amount, accountId],
        );
      }
      const auditPayload = canonicalJson({
        accountId, characterId: opening.characterId, amountMinor: opening.amount,
        alias: opening.alias, accountKey: opening.accountKey,
        currency: opening.currency, importId, mappingId: opening.mappingId,
      }).trim();
      await database.execute(
        `INSERT INTO synex_account_audit
          (event_id, operation_id, event_type, aggregate_id, source_resource, trace_id,
            reference_type, reference_id, actor_kind, actor_ref, snapshot_json)
          SELECT ?, id, 'synex.accounts.legacy_opening_imported', ?, 'synex_migrator', ?,
            'migration.import', ?, 'migration', ?, ?
          FROM synex_account_operations WHERE idempotency_key = ?`,
        [auditId, accountId, operationId, importId, actor, auditPayload, operationId],
      );
      await database.execute(
        `INSERT INTO synex_account_outbox
          (event_id, aggregate_id, event_type, schema_version, trace_id, payload_json)
          VALUES (?, ?, 'synex.accounts.legacy_opening_imported', 1, ?, ?)`,
        [auditId, accountId, operationId, auditPayload],
      );
    }

    for (const [currencyCode, currencyPublicId] of currencyPublicIds) {
      await reconcileCurrency(database, currencyPublicId, currencyCode, importId, actor);
    }

    for (const membership of plan.bundle.groups) {
      const targetKey = [
        membership.nativeGroupType,
        membership.nativeGroupKey,
        membership.gradeKey,
      ].join(":");
      const target = groupTargets.get(targetKey);
      if (!target) throw new LegacyImportError("Group mapping disappeared during import preparation.");
      const membershipId = deterministicId(
        "group-membership",
        target.groupPublicId,
        membership.characterId,
      );
      const operationId = deterministicId("group-membership-operation", membershipId);
      const eventId = deterministicId("group-membership-event", membershipId);
      const primaryId = `gprimary_${digest(
        `${membership.characterId}:${membership.nativeGroupType}`,
      ).slice(0, 32)}`;
      const response = canonicalJson({
        membership_id: membershipId,
        group_id: target.groupPublicId,
        grade_id: target.gradePublicId,
        status: "ACTIVE",
        version: 1,
      }).trim();
      await database.execute(
        `INSERT INTO synex_group_operations
          (idempotency_key, operation_name, request_fingerprint, state, response_json, completed_at)
          VALUES (?, 'legacy_membership_import', ?, 'completed', ?, CURRENT_TIMESTAMP(6))`,
        [operationId, digest(`${membershipId}:${membership.gradeKey}:${importId}`), response],
      );
      await database.execute(
        `INSERT INTO synex_group_memberships
          (public_id, group_id, subject_kind, subject_ref, role_key, status, version)
          VALUES (?, ?, 'character', ?, ?, 'active', 1)`,
        [membershipId, target.groupInternalId, membership.characterId, membership.gradeKey],
      );
      await database.execute(
        `INSERT INTO synex_group_membership_profiles
          (membership_id, group_id, character_id, lifecycle_state, visibility,
            joined_at, suspended_at, left_at, lifecycle_reason_code, version)
          SELECT id, group_id, ?, 'ACTIVE', 'members', CURRENT_TIMESTAMP(6), NULL, NULL,
            'legacy_migration', 1
          FROM synex_group_memberships WHERE public_id = ?`,
        [membership.characterId, membershipId],
      );
      await database.execute(
        `INSERT INTO synex_group_membership_grades
          (membership_id, grade_id, assigned_by_ref, version)
          SELECT id, ?, NULL, 1 FROM synex_group_memberships WHERE public_id = ?`,
        [target.gradeInternalId, membershipId],
      );
      await database.execute(
        `INSERT INTO synex_group_primary_memberships_by_type
          (character_id, group_type_id, membership_id, public_id, assigned_by_ref,
            reason_code, version, assigned_at)
          SELECT ?, ?, id, ?, NULL, 'legacy_migration', 1, CURRENT_TIMESTAMP(6)
          FROM synex_group_memberships WHERE public_id = ?`,
        [membership.characterId, target.groupTypeInternalId, primaryId, membershipId],
      );
      const snapshot = canonicalJson({
        membershipId,
        groupId: target.groupPublicId,
        gradeId: target.gradePublicId,
        characterId: membership.characterId,
        mappingId: membership.mappingId,
        mappingVersion: membership.mappingVersion,
        legacyType: membership.legacyType,
        legacyName: membership.legacyName,
        legacyGrade: membership.legacyGrade,
        nativeGroupType: membership.nativeGroupType,
        nativeGroupKey: membership.nativeGroupKey,
        gradeKey: membership.gradeKey,
        primaryId,
        importId,
      }).trim();
      await database.execute(
        `INSERT INTO synex_group_membership_events
          (event_id, membership_id, membership_version, event_type, actor_ref, snapshot_json)
          SELECT ?, id, 1, 'added', NULL, ? FROM synex_group_memberships WHERE public_id = ?`,
        [eventId, snapshot, membershipId],
      );
      await database.execute(
        `UPDATE synex_group_read_model_versions AS model
          INNER JOIN synex_groups AS group_record ON group_record.id = model.group_id
          SET model.model_version = model.model_version + 1, model.invalidated_at = CURRENT_TIMESTAMP(6)
          WHERE group_record.public_id = ?`,
        [target.groupPublicId],
      );
      await database.execute(
        `INSERT INTO synex_group_outbox
          (event_id, aggregate_id, event_type, schema_version, payload_json)
          VALUES (?, ?, 'synex.groups.membership.activated', 1, ?)`,
        [eventId, target.groupPublicId, snapshot],
      );
    }

    await database.execute(
      `UPDATE synex_legacy_imports
        SET state = 'completed', imported_user_count = ?, imported_character_count = ?, completed_at = CURRENT_TIMESTAMP(6)
        WHERE public_id = ? AND state = 'running'`,
      [plan.bundle.users.length, plan.bundle.characters.length, importId],
    );
    await database.commit();
  } catch (error) {
    try {
      await database.rollback();
    } catch (rollbackError) {
      throw new AggregateError([error, rollbackError], "Legacy import failed and rollback also failed.");
    }
    throw error;
  }

  return {
    schema: 1,
    artifactKind: "synex-legacy-import-result",
    framework,
    reportDigest: plan.report.reportDigest,
    alreadyApplied: false,
    counts: {
      users: plan.bundle.users.length,
      characters: plan.bundle.characters.length,
      identifiers: plan.bundle.users.length,
      accounts: plan.bundle.openingBalances.length,
      ledgerTransactions: plan.bundle.openingBalances.filter((entry) => entry.amount > 0).length,
      groups: groupTargetCount,
      memberships: plan.bundle.groups.length,
      metadata: plan.bundle.metadata.length,
    },
  };
}
