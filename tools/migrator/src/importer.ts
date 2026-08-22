import { createHash } from "node:crypto";
import { lstat, readFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { createConnection, type Connection, type ResultSetHeader, type RowDataPacket } from "mysql2/promise";
import type { LegacyFramework, MigrationPlan } from "./migrator.ts";

const MAX_ARTIFACT_BYTES = 16 * 1024 * 1024;
const MAX_IMPORT_USERS = 10_000;
const MAX_IMPORT_CHARACTERS = 10_000;
const MAX_IMPORT_MEMBERSHIPS = 20_000;
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const DIGEST_PATTERN = /^[0-9a-f]{64}$/u;
const PLATFORM_IDENTIFIER_PATTERN = /^(license|license2|fivem|discord|steam|xbl|live):([\x21-\x7e]{2,192})$/u;
const REQUIRED_TABLES = [
  "synex_users",
  "synex_identifiers",
  "synex_character_slots",
  "synex_characters",
  "synex_legacy_imports",
  "synex_legacy_id_mappings",
  "synex_currencies",
  "synex_accounts",
  "synex_account_owners",
  "synex_account_operations",
  "synex_ledger_transactions",
  "synex_ledger_postings",
  "synex_account_balance_snapshots",
  "synex_account_audit",
  "synex_account_outbox",
  "synex_account_access_roles",
  "synex_account_access_role_permissions",
  "synex_account_access_grants",
  "synex_economy_integrity_read_models",
  "synex_economy_reconciliation_runs",
  "synex_economy_anomaly_findings",
  "synex_groups",
  "synex_group_grades",
  "synex_group_memberships",
  "synex_group_membership_grades",
  "synex_group_membership_events",
  "synex_group_read_model_versions",
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

async function readArtifact(directory: string, name: string): Promise<unknown> {
  const path = join(directory, name);
  const metadata = await lstat(path);
  if (!metadata.isFile() || metadata.isSymbolicLink() || metadata.size > MAX_ARTIFACT_BYTES) {
    throw new LegacyImportError(`${name} must be a regular file no larger than ${MAX_ARTIFACT_BYTES} bytes.`);
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

function validateReviewedPlan(value: unknown, expectedDigest: string): MigrationPlan {
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
  if (!isRecord(report.counts) || !isRecord(report.economy)
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
    || !Array.isArray(idMap.users) || !Array.isArray(idMap.characters)
    || bundle.users.length > MAX_IMPORT_USERS || bundle.characters.length > MAX_IMPORT_CHARACTERS
    || bundle.groups.length > MAX_IMPORT_MEMBERSHIPS) {
    throw new LegacyImportError(
      `The reviewed bundle exceeds the import limits (${MAX_IMPORT_USERS} users, `
      + `${MAX_IMPORT_CHARACTERS} characters, ${MAX_IMPORT_MEMBERSHIPS} memberships).`,
    );
  }
  if (report.counts.users !== bundle.users.length || report.counts.characters !== bundle.characters.length
    || report.counts.moneyEntries !== bundle.openingBalances.length || report.counts.groups !== bundle.groups.length) {
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
  const openingKeys = new Set<string>();
  const economy = { cash: 0n, bank: 0n };
  for (const entry of bundle.openingBalances) {
    if (!isRecord(entry) || !characters.has(String(entry.characterId))
      || (entry.currency !== "cash" && entry.currency !== "bank")
      || !finiteInteger(entry.amount) || entry.reason !== "legacy_migration_opening_balance") {
      throw new LegacyImportError("The reviewed bundle contains an invalid opening balance.");
    }
    const key = `${String(entry.characterId)}:${entry.currency}`;
    if (openingKeys.has(key)) throw new LegacyImportError("The reviewed bundle contains duplicate opening balances.");
    openingKeys.add(key);
    economy[entry.currency] += BigInt(entry.amount);
  }
  if (!isRecord(report.economy.source) || !isRecord(report.economy.transformed)
    || String(report.economy.transformed.cash) !== economy.cash.toString()
    || String(report.economy.transformed.bank) !== economy.bank.toString()
    || String(report.economy.source.cash) !== economy.cash.toString()
    || String(report.economy.source.bank) !== economy.bank.toString()) {
    throw new LegacyImportError("Opening balance totals do not match the reviewed economy report.");
  }
  const membershipKeys = new Set<string>();
  for (const entry of bundle.groups) {
    if (!isRecord(entry) || !characters.has(String(entry.characterId))
      || (entry.kind !== "group" && entry.kind !== "job") || !boundedString(entry.name, 64)
      || !finiteInteger(entry.grade) || entry.grade > 1000) {
      throw new LegacyImportError("The reviewed bundle contains an invalid group membership.");
    }
    const key = `${String(entry.characterId)}:${entry.kind}:${entry.name}`;
    if (membershipKeys.has(key)) throw new LegacyImportError("The reviewed bundle contains duplicate group memberships.");
    membershipKeys.add(key);
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
  if (!metadata.isDirectory() || metadata.isSymbolicLink()) {
    throw new LegacyImportError("The reviewed bundle path must be a real directory.");
  }
  const [report, idMap, bundle] = await Promise.all([
    readArtifact(directory, "migration-report.json"),
    readArtifact(directory, "id-map.json"),
    readArtifact(directory, "migration-bundle.json"),
  ]);
  return validateReviewedPlan({ report, idMap, bundle }, expectedDigest);
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

function groupKey(framework: LegacyFramework, kind: string, name: string): string {
  const slug = name.toLowerCase().replace(/[^a-z0-9_]+/gu, "_").replace(/^_+|_+$/gu, "");
  const base = `legacy_${framework}_${kind}_${slug || "group"}`;
  if (base.length <= 54) return base;
  return `${base.slice(0, 45)}_${digest(base).slice(0, 8)}`;
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
      (SELECT COALESCE(MAX(posting.id), 0) FROM synex_ledger_postings posting
        INNER JOIN synex_ledger_transactions ledger_transaction ON ledger_transaction.id = posting.transaction_id
        WHERE ledger_transaction.currency_id = currency.id) AS cutoff_posting_id,
      (SELECT COUNT(*) FROM synex_ledger_transactions ledger_transaction
        WHERE ledger_transaction.currency_id = currency.id) AS transaction_count,
      (SELECT COUNT(*) FROM synex_ledger_postings posting
        INNER JOIN synex_ledger_transactions ledger_transaction ON ledger_transaction.id = posting.transaction_id
        WHERE ledger_transaction.currency_id = currency.id) AS posting_count,
      (SELECT COALESCE(SUM(posting.debit_minor), 0) FROM synex_ledger_postings posting
        INNER JOIN synex_ledger_transactions ledger_transaction ON ledger_transaction.id = posting.transaction_id
        WHERE ledger_transaction.currency_id = currency.id) AS total_debit_minor,
      (SELECT COALESCE(SUM(posting.credit_minor), 0) FROM synex_ledger_postings posting
        INNER JOIN synex_ledger_transactions ledger_transaction ON ledger_transaction.id = posting.transaction_id
        WHERE ledger_transaction.currency_id = currency.id) AS total_credit_minor,
      (SELECT COALESCE(SUM(snapshot.booked_minor), 0)
        FROM synex_account_balance_snapshots snapshot
        INNER JOIN synex_accounts account ON account.id = snapshot.account_id
        WHERE account.currency_id = currency.id
          AND NOT EXISTS (SELECT 1 FROM synex_account_balance_snapshots newer
            WHERE newer.account_id = snapshot.account_id AND newer.sequence_no > snapshot.sequence_no))
        AS total_booked_minor,
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
      (SELECT COUNT(*) FROM synex_ledger_transactions ledger_transaction
        WHERE ledger_transaction.currency_id = currency.id
          AND NOT EXISTS (SELECT 1 FROM synex_ledger_postings posting
            WHERE posting.transaction_id = ledger_transaction.id)) AS orphan_transaction_count
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
    cutoffPostingId: decimalText(stats, "cutoff_posting_id"),
    transactionCount: decimalText(stats, "transaction_count"),
    postingCount: decimalText(stats, "posting_count"),
    totalDebitMinor: decimalText(stats, "total_debit_minor"),
    totalCreditMinor: decimalText(stats, "total_credit_minor"),
    totalBookedMinor: decimalText(stats, "total_booked_minor"),
    negativeAssetCount: decimalText(stats, "negative_asset_count"),
    reservedExceedsBookedCount: decimalText(stats, "reserved_exceeds_booked_count"),
    orphanTransactionCount: decimalText(stats, "orphan_transaction_count"),
  };
  const findings: Array<{ rule: string; details: Record<string, string> }> = [];
  if (BigInt(values.totalDebitMinor) !== BigInt(values.totalCreditMinor)) {
    findings.push({ rule: "ledger_imbalance", details: { debit: values.totalDebitMinor, credit: values.totalCreditMinor } });
  }
  if (BigInt(values.totalBookedMinor) !== 0n) {
    findings.push({ rule: "snapshot_sum_drift", details: { total_booked_minor: values.totalBookedMinor } });
  }
  if (BigInt(values.negativeAssetCount) !== 0n) {
    findings.push({ rule: "negative_asset_balance", details: { count: values.negativeAssetCount } });
  }
  if (BigInt(values.reservedExceedsBookedCount) !== 0n) {
    findings.push({ rule: "reserved_exceeds_booked", details: { count: values.reservedExceedsBookedCount } });
  }
  if (BigInt(values.orphanTransactionCount) !== 0n) {
    findings.push({ rule: "orphan_transaction", details: { count: values.orphanTransactionCount } });
  }
  const modelVersion = Number(stats.model_version) + 1;
  const status = findings.length > 0 ? "warn" : "healthy";
  const operationId = deterministicId("reconciliation-operation", importId, currencyCode);
  const runId = deterministicId("reconciliation-run", importId, currencyCode);
  const eventId = deterministicId("reconciliation-event", importId, currencyCode);
  const response = canonicalJson({
    run_id: runId, currency_id: currencyPublicId, currency_code: currencyCode,
    model_version: modelVersion, cutoff_posting_id: values.cutoffPostingId,
    transaction_count: values.transactionCount, posting_count: values.postingCount,
    total_debit_minor: values.totalDebitMinor, total_credit_minor: values.totalCreditMinor,
    total_booked_minor: values.totalBookedMinor, status, finding_count: findings.length,
    findings: findings.map((finding) => ({ rule: finding.rule, severity: "warn" })),
  }).trim();
  await database.execute(
    `INSERT INTO synex_account_operations
      (idempotency_key, operation_name, request_fingerprint, state, response_json, completed_at)
      VALUES (?, 'legacy_reconciliation', ?, 'completed', ?, CURRENT_TIMESTAMP(6))`,
    [operationId, digest(`${importId}:${currencyCode}`), response],
  );
  const updated = await database.execute(
    `UPDATE synex_economy_integrity_read_models SET model_version = model_version + 1,
      cutoff_posting_id = ?, transaction_count = ?, posting_count = ?, total_debit_minor = ?,
      total_credit_minor = ?, total_booked_minor = ?, negative_asset_count = ?,
      reserved_exceeds_booked_count = ?, orphan_transaction_count = ?, finding_count = ?,
      status = ?, generated_at = CURRENT_TIMESTAMP(6)
      WHERE currency_id = ? AND model_version = ?`,
    [values.cutoffPostingId, values.transactionCount, values.postingCount, values.totalDebitMinor,
      values.totalCreditMinor, values.totalBookedMinor, values.negativeAssetCount,
      values.reservedExceedsBookedCount, values.orphanTransactionCount, findings.length,
      status, values.currencyInternalId, Number(stats.model_version)],
  );
  if (updated.affectedRows !== 1) throw new LegacyImportError(`The ${currencyCode} integrity model changed during import.`);
  await database.execute(
    `INSERT INTO synex_economy_reconciliation_runs
      (public_id, operation_id, currency_id, model_version, cutoff_posting_id, transaction_count,
        posting_count, total_debit_minor, total_credit_minor, total_booked_minor, finding_count,
        status, requested_by_ref)
      SELECT ?, operation.id, currency.id, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
      FROM synex_account_operations operation, synex_currencies currency
      WHERE operation.idempotency_key = ? AND currency.public_id = ?`,
    [runId, modelVersion, values.cutoffPostingId, values.transactionCount, values.postingCount,
      values.totalDebitMinor, values.totalCreditMinor, values.totalBookedMinor, findings.length,
      status, actorRef, operationId, currencyPublicId],
  );
  for (const finding of findings) {
    await database.execute(
      `INSERT INTO synex_economy_anomaly_findings
        (public_id, run_id, rule_key, severity, aggregate_type, aggregate_id, details_json)
        SELECT ?, id, ?, 'warn', 'currency', ?, ?
        FROM synex_economy_reconciliation_runs WHERE public_id = ?`,
      [deterministicId("reconciliation-finding", runId, finding.rule), finding.rule,
        currencyPublicId, canonicalJson(finding.details).trim(), runId],
    );
  }
  await database.execute(
    `INSERT INTO synex_account_audit
      (event_id, operation_id, event_type, aggregate_id, actor_ref, snapshot_json)
      SELECT ?, id, 'synex.accounts.reconciliation_completed', ?, ?, ?
      FROM synex_account_operations WHERE idempotency_key = ?`,
    [eventId, runId, actorRef, response, operationId],
  );
  await database.execute(
    `INSERT INTO synex_account_outbox
      (event_id, aggregate_id, event_type, schema_version, payload_json)
      VALUES (?, ?, 'synex.accounts.reconciliation_completed', 1, ?)`,
    [eventId, currencyPublicId, response],
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
        groups: new Set(plan.bundle.groups.map((entry) => `${entry.kind}:${entry.name}`)).size,
        memberships: plan.bundle.groups.length,
      },
    };
  }
  if (previous.rows.length > 0) {
    throw new LegacyImportError("A non-completed import already exists for this report digest.");
  }

  const framework = plan.report.framework;
  const actor = `legacy_migration:${framework}`;
  const importId = deterministicId("import", framework, plan.report.reportDigest);
  const groups = new Map<string, { publicId: string; key: string; name: string; kind: "group" | "job" }>();
  for (const membership of plan.bundle.groups) {
    const key = `${membership.kind}:${membership.name}`;
    if (!groups.has(key)) {
      groups.set(key, {
        publicId: deterministicId("group", framework, membership.kind, membership.name),
        key: groupKey(framework, membership.kind, membership.name),
        name: membership.name,
        kind: membership.kind,
      });
    }
  }
  const grades = new Map<string, { publicId: string; groupId: string; key: string; rank: number }>();
  for (const membership of plan.bundle.groups) {
    const group = groups.get(`${membership.kind}:${membership.name}`);
    if (!group) throw new LegacyImportError("Group mapping disappeared during import preparation.");
    const key = `grade_${membership.grade}`;
    const identity = `${group.publicId}:${key}`;
    if (!grades.has(identity)) {
      grades.set(identity, {
        publicId: deterministicId("group-grade", group.publicId, key),
        groupId: group.publicId,
        key,
        rank: membership.grade,
      });
    }
  }

  await database.begin();
  try {
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
    }

    const currencyPublicIds = new Map<string, string>();
    const mintState = new Map<string, { publicId: string; booked: number; sequence: number }>();
    for (const currency of ["cash", "bank"] as const) {
      const existingCurrency = await database.execute(
        "SELECT public_id, minor_unit, status FROM synex_currencies WHERE currency_code = ? LIMIT 1",
        [currency],
      );
      let currencyId = String(existingCurrency.rows[0]?.public_id ?? "");
      if (existingCurrency.rows.length > 0) {
        if (!UUID_PATTERN.test(currencyId) || Number(existingCurrency.rows[0]?.minor_unit) !== 0
          || existingCurrency.rows[0]?.status !== "active") {
          throw new LegacyImportError(`Existing ${currency} currency is incompatible with the reviewed opening balances.`);
        }
      } else {
        currencyId = deterministicId("currency", currency);
        await database.execute(
          `INSERT INTO synex_currencies (public_id, currency_code, display_name, minor_unit, status)
            VALUES (?, ?, ?, 0, 'active')`,
          [currencyId, currency, currency === "cash" ? "Cash" : "Bank"],
        );
      }
      currencyPublicIds.set(currency, currencyId);
      const mintPublicId = deterministicId("mint-account", plan.report.reportDigest, currency);
      await database.execute(
        `INSERT INTO synex_economy_integrity_read_models (currency_id)
          SELECT currency.id FROM synex_currencies currency
          WHERE currency.public_id = ?
            AND NOT EXISTS (SELECT 1 FROM synex_economy_integrity_read_models model WHERE model.currency_id = currency.id)`,
        [currencyId],
      );
      await database.execute(
        `INSERT INTO synex_accounts
          (public_id, currency_id, account_key, account_role, allow_negative, status, metadata_json, version)
          SELECT ?, id, ?, 'mint', 1, 'active', ?, 1 FROM synex_currencies WHERE public_id = ?`,
        [mintPublicId, `legacy_${plan.report.reportDigest.slice(0, 8)}_mint_${currency}`,
          canonicalJson({ migration: { framework: "system" } }).trim(), currencyId],
      );
      await database.execute(
        `INSERT INTO synex_account_owners (account_id, owner_kind, owner_ref)
          SELECT id, 'system', 'legacy_migration' FROM synex_accounts WHERE public_id = ?`,
        [mintPublicId],
      );
      await provisionAccountOwner(database, mintPublicId, "system", "legacy_migration", actor);
      await database.execute(
        `INSERT INTO synex_account_balance_snapshots
          (account_id, sequence_no, source_kind, source_ref, booked_minor, reserved_minor)
          SELECT id, 0, 'opening', ?, 0, 0 FROM synex_accounts WHERE public_id = ?`,
        [deterministicId("mint-opening", currency), mintPublicId],
      );
      mintState.set(currency, { publicId: mintPublicId, booked: 0, sequence: 0 });
    }

    for (const opening of plan.bundle.openingBalances) {
      const accountId = deterministicId("asset-account", framework, opening.characterId, opening.currency);
      const operationId = deterministicId("opening-operation", framework, opening.characterId, opening.currency);
      const transactionId = deterministicId("opening-transaction", framework, opening.characterId, opening.currency);
      const postingId = deterministicId("opening-posting", framework, opening.characterId, opening.currency);
      const auditId = deterministicId("opening-audit", framework, opening.characterId, opening.currency);
      const currencyId = currencyPublicIds.get(opening.currency);
      if (!currencyId) throw new LegacyImportError("Opening balance references an unavailable migration currency.");
      const response = canonicalJson({ account_id: accountId, amount_minor: opening.amount, currency: opening.currency }).trim();
      await database.execute(
        `INSERT INTO synex_account_operations
          (idempotency_key, operation_name, request_fingerprint, state, response_json, completed_at)
          VALUES (?, 'legacy_opening_balance', ?, 'completed', ?, CURRENT_TIMESTAMP(6))`,
        [operationId, `${framework}:${opening.characterId}:${opening.currency}:${opening.amount}`, response],
      );
      await database.execute(
        `INSERT INTO synex_accounts
          (public_id, currency_id, account_key, account_role, allow_negative, status, metadata_json, version)
          SELECT ?, id, NULL, 'asset', 0, 'active', ?, 1 FROM synex_currencies WHERE public_id = ?`,
        [accountId, canonicalJson({ migration: { framework, characterId: opening.characterId } }).trim(), currencyId],
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
        await database.execute(
          `INSERT INTO synex_ledger_transactions
            (public_id, operation_id, currency_id, transaction_kind, reference_text, actor_ref, metadata_json)
            SELECT ?, operation.id, currency.id, 'mint', 'legacy_migration_opening_balance', ?, ?
            FROM synex_account_operations operation, synex_currencies currency
            WHERE operation.idempotency_key = ? AND currency.public_id = ?`,
          [transactionId, actor, canonicalJson({ framework, importId }).trim(), operationId, currencyId],
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
        currency: opening.currency, importId,
      }).trim();
      await database.execute(
        `INSERT INTO synex_account_audit
          (event_id, operation_id, event_type, aggregate_id, actor_ref, snapshot_json)
          SELECT ?, id, 'synex.accounts.legacy_opening_imported', ?, ?, ?
          FROM synex_account_operations WHERE idempotency_key = ?`,
        [auditId, accountId, actor, auditPayload, operationId],
      );
      await database.execute(
        `INSERT INTO synex_account_outbox
          (event_id, aggregate_id, event_type, schema_version, payload_json)
          VALUES (?, ?, 'synex.accounts.legacy_opening_imported', 1, ?)`,
        [auditId, accountId, auditPayload],
      );
    }

    for (const [currencyCode, currencyPublicId] of currencyPublicIds) {
      await reconcileCurrency(database, currencyPublicId, currencyCode, importId, actor);
    }

    for (const group of groups.values()) {
      const operationId = deterministicId("group-create-operation", group.publicId);
      const eventId = deterministicId("group-create-event", group.publicId);
      const response = canonicalJson({ group_id: group.publicId, group_key: group.key, status: "active", version: 1 }).trim();
      const payload = canonicalJson({
        group_id: group.publicId, group_key: group.key, group_type: group.kind,
        status: "active", version: 1, import_id: importId,
      }).trim();
      await database.execute(
        `INSERT INTO synex_group_operations
          (idempotency_key, operation_name, request_fingerprint, state, response_json, completed_at)
          VALUES (?, 'legacy_group_import', ?, 'completed', ?, CURRENT_TIMESTAMP(6))`,
        [operationId, digest(payload), response],
      );
      await database.execute(
        `INSERT INTO synex_groups
          (public_id, group_key, display_name, group_type, status, metadata_json, version)
          VALUES (?, ?, ?, ?, 'active', ?, 1)`,
        [group.publicId, group.key, group.name, group.kind,
          canonicalJson({ migration: { framework, importId } }).trim()],
      );
      await database.execute(
        `INSERT INTO synex_group_read_model_versions (group_id, model_version)
          SELECT id, 1 FROM synex_groups WHERE public_id = ?`,
        [group.publicId],
      );
      await database.execute(
        `INSERT INTO synex_group_outbox
          (event_id, aggregate_id, event_type, schema_version, payload_json)
          VALUES (?, ?, 'synex.groups.legacy_group_imported', 1, ?)`,
        [eventId, group.publicId, payload],
      );
    }
    for (const grade of grades.values()) {
      await database.execute(
        `INSERT INTO synex_group_grades
          (public_id, group_id, grade_key, display_name, rank_value, status, version)
          SELECT ?, id, ?, ?, ?, 'active', 1 FROM synex_groups WHERE public_id = ?`,
        [grade.publicId, grade.key, `Grade ${grade.rank}`, grade.rank, grade.groupId],
      );
    }
    for (const membership of plan.bundle.groups) {
      const group = groups.get(`${membership.kind}:${membership.name}`);
      if (!group) throw new LegacyImportError("Group mapping disappeared during import preparation.");
      const gradeKey = `grade_${membership.grade}`;
      const membershipId = deterministicId("group-membership", group.publicId, membership.characterId);
      const operationId = deterministicId("group-membership-operation", membershipId);
      const eventId = deterministicId("group-membership-event", membershipId);
      const response = canonicalJson({
        membership_id: membershipId, group_id: group.publicId, status: "active", version: 1,
      }).trim();
      await database.execute(
        `INSERT INTO synex_group_operations
          (idempotency_key, operation_name, request_fingerprint, state, response_json, completed_at)
          VALUES (?, 'legacy_membership_import', ?, 'completed', ?, CURRENT_TIMESTAMP(6))`,
        [operationId, digest(`${membershipId}:${gradeKey}:${importId}`), response],
      );
      await database.execute(
        `INSERT INTO synex_group_memberships
          (public_id, group_id, subject_kind, subject_ref, role_key, status, version)
          SELECT ?, id, 'character', ?, ?, 'active', 1 FROM synex_groups WHERE public_id = ?`,
        [membershipId, membership.characterId, gradeKey, group.publicId],
      );
      await database.execute(
        `INSERT INTO synex_group_membership_grades (membership_id, grade_id, version)
          SELECT membership.id, grade.id, 1
          FROM synex_group_memberships membership, synex_group_grades grade
          WHERE membership.public_id = ? AND grade.group_id = membership.group_id AND grade.grade_key = ?`,
        [membershipId, gradeKey],
      );
      const snapshot = canonicalJson({
        membershipId, groupId: group.publicId, characterId: membership.characterId,
        grade: membership.grade, importId,
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
        [group.publicId],
      );
      await database.execute(
        `INSERT INTO synex_group_outbox
          (event_id, aggregate_id, event_type, schema_version, payload_json)
          VALUES (?, ?, 'synex.groups.legacy_membership_imported', 1, ?)`,
        [eventId, group.publicId, snapshot],
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
      groups: groups.size,
      memberships: plan.bundle.groups.length,
    },
  };
}
