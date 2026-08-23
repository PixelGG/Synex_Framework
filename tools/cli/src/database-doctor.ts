import { createConnection, type Connection, type RowDataPacket } from "mysql2/promise";
import { join, resolve } from "node:path";

import type { OperationalCheck } from "./operations.ts";
import { compareText, readTextFile, sha256 } from "./filesystem.ts";
import {
  isAcceptedAppliedMigrationChecksum,
  isAcceptedMigrationControlChecksum,
} from "./migration-compatibility.ts";
import { loadSchemaRegistry } from "./schemas.ts";
import { loadResourceManifests } from "./validation.ts";

export interface DatabaseTableShape {
  columns: string[];
  indexes: string[];
}

export interface ExpectedDatabaseShape {
  tables: Record<string, DatabaseTableShape>;
  migrations: Record<string, string>;
}

export interface DatabaseShapeDelta {
  missingTables: string[];
  missingColumns: string[];
  missingIndexes: string[];
}

export interface MigrationRuntimeDelta {
  pending: string[];
  checksumMismatches: string[];
  unknownApplied: string[];
}

export interface MigrationControlEntry {
  identity: string;
  checksum: string;
  state: string;
}

export interface MigrationControlDelta {
  checksumMismatches: string[];
  inconsistentStates: string[];
  unknownEntries: string[];
}

function splitSqlClauses(body: string): string[] {
  const clauses: string[] = [];
  let start = 0;
  let depth = 0;
  let quote: "'" | '"' | "`" | null = null;
  for (let index = 0; index < body.length; index += 1) {
    const character = body[index];
    if (quote) {
      if (character === quote) {
        if (body[index + 1] === quote) index += 1;
        else quote = null;
      } else if (character === "\\" && quote !== "`" && index + 1 < body.length) {
        index += 1;
      }
      continue;
    }
    if (character === "'" || character === '"' || character === "`") {
      quote = character;
      continue;
    }
    if (character === "(") depth += 1;
    else if (character === ")") depth = Math.max(0, depth - 1);
    else if (character === "," && depth === 0) {
      clauses.push(body.slice(start, index).trim());
      start = index + 1;
    }
  }
  const remainder = body.slice(start).trim();
  if (remainder) clauses.push(remainder);
  return clauses;
}

function mutableTable(
  tables: Map<string, { columns: Set<string>; indexes: Set<string> }>,
  table: string,
): { columns: Set<string>; indexes: Set<string> } {
  const current = tables.get(table) ?? { columns: new Set<string>(), indexes: new Set<string>() };
  tables.set(table, current);
  return current;
}

function applyTableClauses(
  shape: { columns: Set<string>; indexes: Set<string> },
  clauses: string[],
  alter: boolean,
): void {
  for (const rawClause of clauses) {
    const clause = rawClause.replace(/^\s*--[^\r\n]*(?:\r?\n|$)/gu, "").trim();
    const column = (alter
      ? /^ADD\s+(?:COLUMN\s+)?`([^`]+)`\s+/iu
      : /^`([^`]+)`\s+/u).exec(clause)?.[1];
    if (column) {
      shape.columns.add(column);
      continue;
    }
    const dropColumn = /^DROP\s+(?:COLUMN\s+)?`([^`]+)`/iu.exec(clause)?.[1];
    if (dropColumn) {
      shape.columns.delete(dropColumn);
      continue;
    }
    if (/^(?:ADD\s+)?PRIMARY\s+KEY\b/iu.test(clause)) {
      shape.indexes.add("PRIMARY");
      continue;
    }
    const index = /^(?:ADD\s+)?(?:UNIQUE\s+)?(?:KEY|INDEX)\s+`([^`]+)`/iu.exec(clause)?.[1];
    if (index) {
      shape.indexes.add(index);
      continue;
    }
    const dropIndex = /^DROP\s+(?:KEY|INDEX)\s+`([^`]+)`/iu.exec(clause)?.[1];
    if (dropIndex) shape.indexes.delete(dropIndex);
    if (/^DROP\s+PRIMARY\s+KEY\b/iu.test(clause)) shape.indexes.delete("PRIMARY");
  }
}

export function extractDatabaseShape(sql: string): Record<string, DatabaseTableShape> {
  const tables = new Map<string, { columns: Set<string>; indexes: Set<string> }>();
  for (const match of sql.matchAll(/CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?`([^`]+)`\s*\(\s*\r?\n([\s\S]*?)^\)\s*(?:ENGINE\s*=\s*[^;]+)?;/gimu)) {
    const table = match[1];
    const body = match[2];
    if (!table || body === undefined) continue;
    applyTableClauses(mutableTable(tables, table), splitSqlClauses(body), false);
  }
  for (const match of sql.matchAll(/ALTER\s+TABLE\s+`([^`]+)`\s+([\s\S]*?);/gimu)) {
    const table = match[1];
    const body = match[2];
    if (!table || body === undefined) continue;
    applyTableClauses(mutableTable(tables, table), splitSqlClauses(body), true);
  }
  for (const match of sql.matchAll(/CREATE\s+(?:UNIQUE\s+)?INDEX\s+`([^`]+)`\s+ON\s+`([^`]+)`/gimu)) {
    const index = match[1];
    const table = match[2];
    if (table && index) mutableTable(tables, table).indexes.add(index);
  }
  return Object.fromEntries([...tables.entries()].sort(([left], [right]) => compareText(left, right)).map(([table, shape]) => [
    table,
    { columns: [...shape.columns].sort(compareText), indexes: [...shape.indexes].sort(compareText) },
  ]));
}

export async function deriveExpectedDatabaseShape(repositoryRoot: string): Promise<ExpectedDatabaseShape> {
  const schemas = await loadSchemaRegistry(repositoryRoot);
  const resources = await loadResourceManifests(repositoryRoot, resolve(repositoryRoot), schemas);
  const tables = new Map<string, { columns: Set<string>; indexes: Set<string> }>();
  const migrations: Record<string, string> = {};
  for (const resource of resources.manifests) {
    for (const table of resource.manifest.dataOwnership.tables) mutableTable(tables, table);
    for (const migration of resource.manifest.migrations) {
      const contents = (await readTextFile(join(resource.directory, migration.path))).replace(/\r\n?/gu, "\n");
      migrations[`${resource.manifest.name}:${migration.id}`] = sha256(contents);
      for (const [table, shape] of Object.entries(extractDatabaseShape(contents))) {
        const aggregate = mutableTable(tables, table);
        for (const column of shape.columns) aggregate.columns.add(column);
        for (const index of shape.indexes) aggregate.indexes.add(index);
      }
    }
  }
  return {
    tables: Object.fromEntries([...tables.entries()].sort(([left], [right]) => compareText(left, right)).map(([table, shape]) => [
      table,
      { columns: [...shape.columns].sort(compareText), indexes: [...shape.indexes].sort(compareText) },
    ])),
    migrations: Object.fromEntries(Object.entries(migrations).sort(([left], [right]) => compareText(left, right))),
  };
}

export function compareDatabaseShape(
  expected: ExpectedDatabaseShape["tables"],
  actualTables: Iterable<string>,
  actualColumns: Iterable<string>,
  actualIndexes: Iterable<string>,
): DatabaseShapeDelta {
  const tables = new Set(actualTables);
  const columns = new Set(actualColumns);
  const indexes = new Set(actualIndexes);
  const missingTables: string[] = [];
  const missingColumns: string[] = [];
  const missingIndexes: string[] = [];
  for (const [table, shape] of Object.entries(expected)) {
    if (!tables.has(table)) {
      missingTables.push(table);
      continue;
    }
    for (const column of shape.columns) {
      if (!columns.has(`${table}:${column}`)) missingColumns.push(`${table}.${column}`);
    }
    for (const index of shape.indexes) {
      if (!indexes.has(`${table}:${index}`)) missingIndexes.push(`${table}.${index}`);
    }
  }
  return {
    missingTables: missingTables.sort(compareText),
    missingColumns: missingColumns.sort(compareText),
    missingIndexes: missingIndexes.sort(compareText),
  };
}

export function compareAppliedMigrations(
  expected: Record<string, string>,
  appliedEntries: Iterable<readonly [string, string]>,
): MigrationRuntimeDelta {
  const applied = new Map(appliedEntries);
  const pending: string[] = [];
  const checksumMismatches: string[] = [];
  for (const [identity, checksum] of Object.entries(expected)) {
    const actual = applied.get(identity);
    if (actual === undefined) pending.push(identity);
    else if (!isAcceptedAppliedMigrationChecksum(identity, checksum, actual)) checksumMismatches.push(identity);
  }
  const unknownApplied = [...applied.keys()].filter((identity) => !Object.hasOwn(expected, identity));
  return {
    pending: pending.sort(compareText),
    checksumMismatches: checksumMismatches.sort(compareText),
    unknownApplied: unknownApplied.sort(compareText),
  };
}

export function compareMigrationControls(
  expected: Record<string, string>,
  appliedEntries: Iterable<readonly [string, string]>,
  fenceEntries: Iterable<MigrationControlEntry>,
  attemptEntries: Iterable<MigrationControlEntry>,
): MigrationControlDelta {
  const applied = new Map(appliedEntries);
  const checksumMismatches: string[] = [];
  const inconsistentStates: string[] = [];
  const unknownEntries: string[] = [];

  const inspect = (kind: "fence" | "attempt", entries: Iterable<MigrationControlEntry>): void => {
    for (const entry of entries) {
      const label = `${kind}:${entry.identity}`;
      const expectedChecksum = expected[entry.identity];
      if (expectedChecksum === undefined) {
        unknownEntries.push(label);
        continue;
      }
      const appliedChecksum = applied.get(entry.identity);
      if (!isAcceptedMigrationControlChecksum(
        entry.identity,
        expectedChecksum,
        entry.checksum,
        appliedChecksum,
      )) {
        checksumMismatches.push(label);
      }
      if (appliedChecksum === undefined || entry.state !== "applied") {
        inconsistentStates.push(label);
      }
    }
  };

  inspect("fence", fenceEntries);
  inspect("attempt", attemptEntries);
  return {
    checksumMismatches: checksumMismatches.sort(compareText),
    inconsistentStates: inconsistentStates.sort(compareText),
    unknownEntries: unknownEntries.sort(compareText),
  };
}

function safeErrorCode(error: unknown): string {
  if (typeof error !== "object" || error === null || !("code" in error) || typeof error.code !== "string") return "CONNECTION_FAILED";
  return /^[A-Z0-9_]{1,64}$/u.test(error.code) ? error.code : "CONNECTION_FAILED";
}

async function rows(connection: Connection, sql: string, parameters: unknown[] = []): Promise<RowDataPacket[]> {
  const [result] = await connection.query<RowDataPacket[]>({ sql, timeout: 5_000 }, parameters);
  return result;
}

export async function runDatabaseDoctor(repositoryRoot: string): Promise<OperationalCheck[]> {
  const databaseUrl = process.env.SYNEX_DOCTOR_DATABASE_URL;
  const checkNames = [
    "database-connectivity",
    "database-schema",
    "migration-runtime",
    "session-integrity",
    "ledger-reconciliation",
    "outbox-backlog",
    "entity-registry",
  ];
  if (!databaseUrl) {
    return checkNames.map((name) => ({
      name,
      status: "WARN",
      detail: "Live read-only check was not executed; set server-only SYNEX_DOCTOR_DATABASE_URL to enable it.",
    }));
  }
  if (!/^(?:mysql|mariadb):\/\//iu.test(databaseUrl)) {
    return [{ name: "database-connectivity", status: "FAIL", detail: "SYNEX_DOCTOR_DATABASE_URL must use a mysql:// or mariadb:// URL." }];
  }

  let connection: Connection | null = null;
  try {
    connection = await createConnection({ uri: databaseUrl, connectTimeout: 5_000, multipleStatements: false });
    await rows(connection, "SELECT 1 AS `ok`");
  } catch (error) {
    await connection?.end().catch(() => undefined);
    return [{ name: "database-connectivity", status: "FAIL", detail: `Read-only database connection failed (${safeErrorCode(error)}).` }];
  }

  const checks: OperationalCheck[] = [{ name: "database-connectivity", status: "PASS", detail: "Read-only SELECT 1 completed." }];
  try {
    const tableRows = await rows(connection, `SELECT TABLE_NAME AS table_name
      FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME LIKE 'synex\\_%' ESCAPE '\\\\'
      ORDER BY TABLE_NAME LIMIT 10001`);
    if (tableRows.length > 10_000) {
      checks.push({ name: "database-schema", status: "FAIL", detail: "Schema inspection exceeded the 10000-table safety limit." });
      return checks;
    }
    const tables = new Set(tableRows.map((row) => String(row.table_name)));
    const expectedShape = await deriveExpectedDatabaseShape(repositoryRoot);
    const columnRows = await rows(connection, `SELECT TABLE_NAME AS table_name, COLUMN_NAME AS column_name
      FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME LIKE 'synex\\_%' ESCAPE '\\\\'
      ORDER BY TABLE_NAME, ORDINAL_POSITION LIMIT 100001`);
    const indexRows = await rows(connection, `SELECT TABLE_NAME AS table_name, INDEX_NAME AS index_name
      FROM information_schema.STATISTICS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME LIKE 'synex\\_%' ESCAPE '\\\\'
      ORDER BY TABLE_NAME, INDEX_NAME, SEQ_IN_INDEX LIMIT 100001`);
    const schemaLimitExceeded = columnRows.length > 100_000 || indexRows.length > 100_000;
    const shapeDelta = schemaLimitExceeded
      ? { missingTables: [], missingColumns: [], missingIndexes: [] }
      : compareDatabaseShape(
          expectedShape.tables,
          tables,
          columnRows.map((row) => `${String(row.table_name)}:${String(row.column_name)}`),
          indexRows.map((row) => `${String(row.table_name)}:${String(row.index_name)}`),
        );
    const schemaDriftCount = shapeDelta.missingTables.length + shapeDelta.missingColumns.length + shapeDelta.missingIndexes.length;
    checks.push({
      name: "database-schema",
      status: schemaLimitExceeded || schemaDriftCount > 0 ? "FAIL" : "PASS",
      detail: schemaLimitExceeded
        ? "Column/index inspection exceeded the 100000-row safety limit; schema parity was not claimed."
        : `${Object.keys(expectedShape.tables).length} expected table(s); ${shapeDelta.missingTables.length} missing table(s), ${shapeDelta.missingColumns.length} missing column(s), ${shapeDelta.missingIndexes.length} missing index(es).`,
    });

    if (tables.has("synex_schema_migrations") && tables.has("synex_schema_migration_attempts")) {
      const appliedRows = await rows(connection, "SELECT `resource_name`, `migration_id`, `checksum_sha256` FROM `synex_schema_migrations` ORDER BY `resource_name`, `migration_id` LIMIT 10001");
      const attemptRows = await rows(connection, "SELECT `resource_name`, `migration_id`, `checksum_sha256`, `state` FROM `synex_schema_migration_attempts` ORDER BY `resource_name`, `migration_id` LIMIT 10001");
      const fenceRows = tables.has("synex_schema_migration_fences")
        ? await rows(connection, "SELECT `resource_name`, `migration_id`, `checksum_sha256`, `state` FROM `synex_schema_migration_fences` ORDER BY `resource_name`, `migration_id` LIMIT 10001")
        : [];
      const inspectionLimitExceeded = appliedRows.length > 10_000
        || attemptRows.length > 10_000 || fenceRows.length > 10_000;
      if (inspectionLimitExceeded) {
        checks.push({ name: "migration-runtime", status: "FAIL", detail: "Migration inspection exceeded the 10000-row safety limit." });
      } else {
        const appliedEntries = appliedRows.map((row) => [
          `${String(row.resource_name)}:${String(row.migration_id)}`,
          String(row.checksum_sha256),
        ] as const);
        const migrationDelta = compareAppliedMigrations(
          expectedShape.migrations,
          appliedEntries,
        );
        const controlDelta = compareMigrationControls(
          expectedShape.migrations,
          appliedEntries,
          fenceRows.map((row) => ({
            identity: `${String(row.resource_name)}:${String(row.migration_id)}`,
            checksum: String(row.checksum_sha256),
            state: String(row.state),
          })),
          attemptRows.map((row) => ({
            identity: `${String(row.resource_name)}:${String(row.migration_id)}`,
            checksum: String(row.checksum_sha256),
            state: String(row.state),
          })),
        );
        const migrationFenceRequired = appliedEntries.some(([identity]) =>
          identity === "synex_core:013_migration_fencing"
        );
        const missingRequiredControlTables = migrationFenceRequired
          && !tables.has("synex_schema_migration_fences") ? 1 : 0;
        const controlFailureCount = controlDelta.checksumMismatches.length
          + controlDelta.inconsistentStates.length + controlDelta.unknownEntries.length
          + missingRequiredControlTables;
        checks.push({
          name: "migration-runtime",
          status: migrationDelta.checksumMismatches.length > 0
              || migrationDelta.unknownApplied.length > 0 || controlFailureCount > 0
            ? "FAIL"
            : migrationDelta.pending.length > 0 ? "WARN" : "PASS",
          detail: `${migrationDelta.pending.length} pending, ${migrationDelta.checksumMismatches.length} applied checksum mismatch(es), ${migrationDelta.unknownApplied.length} applied migration(s) absent from local manifests, ${controlDelta.checksumMismatches.length} fence/attempt checksum mismatch(es), ${controlDelta.inconsistentStates.length} inconsistent fence/attempt state(s), ${controlDelta.unknownEntries.length} unknown fence/attempt row(s), ${missingRequiredControlTables} missing required control table(s).`,
        });
      }
    } else {
      checks.push({ name: "migration-runtime", status: "FAIL", detail: "Migration control tables are missing." });
    }

    if (tables.has("synex_sessions")) {
      const result = await rows(connection, `SELECT
        SUM(CASE WHEN (state = 'CLOSED') <> (closed_at IS NOT NULL) THEN 1 ELSE 0 END) AS invalid_closed_state,
        SUM(CASE WHEN state <> 'CLOSED' AND last_seen_at < TIMESTAMPADD(MINUTE, -2, CURRENT_TIMESTAMP(6)) THEN 1 ELSE 0 END) AS stale_open
        FROM synex_sessions`);
      const invalid = Number(result[0]?.invalid_closed_state ?? 0);
      const stale = Number(result[0]?.stale_open ?? 0);
      checks.push({
        name: "session-integrity",
        status: invalid > 0 ? "FAIL" : stale > 0 ? "WARN" : "PASS",
        detail: `${invalid} invalid closed-state row(s), ${stale} stale open session(s).`,
      });
    } else {
      checks.push({ name: "session-integrity", status: "FAIL", detail: "synex_sessions is missing." });
    }

    if (tables.has("synex_economy_reconciliation_runs")) {
      const result = await rows(connection, `SELECT status, finding_count, created_at
        FROM synex_economy_reconciliation_runs ORDER BY id DESC LIMIT 1`);
      const latest = result[0];
      checks.push({
        name: "ledger-reconciliation",
        status: !latest ? "WARN" : String(latest.status) === "healthy" ? "PASS" : "WARN",
        detail: latest
          ? `Latest reconciliation status=${String(latest.status)}, findings=${Number(latest.finding_count ?? 0)}.`
          : "No reconciliation run has been recorded.",
      });
    } else {
      checks.push({ name: "ledger-reconciliation", status: "WARN", detail: "Economy reconciliation tables are not installed." });
    }

    let pending = 0;
    let dead = 0;
    for (const table of ["synex_outbox", "synex_account_outbox", "synex_group_outbox"]) {
      if (!tables.has(table)) continue;
      const result = await rows(connection, `SELECT
        SUM(CASE WHEN state IN ('pending', 'publishing') THEN 1 ELSE 0 END) AS pending_count,
        SUM(CASE WHEN state IN ('dead', 'failed') THEN 1 ELSE 0 END) AS dead_count
        FROM \`${table}\``);
      pending += Number(result[0]?.pending_count ?? 0);
      dead += Number(result[0]?.dead_count ?? 0);
    }
    checks.push({
      name: "outbox-backlog",
      status: dead > 0 ? "FAIL" : pending > 1_000 ? "WARN" : "PASS",
      detail: `${pending} pending/publishing event(s), ${dead} dead/failed event(s).`,
    });

    if (tables.has("synex_entities")) {
      const result = await rows(connection, `SELECT
        SUM(CASE WHEN status = 'orphaned' THEN 1 ELSE 0 END) AS orphaned,
        SUM(CASE WHEN status = 'deleting' AND updated_at < TIMESTAMPADD(MINUTE, -5, CURRENT_TIMESTAMP(3)) THEN 1 ELSE 0 END) AS stuck_deleting
        FROM synex_entities`);
      const orphaned = Number(result[0]?.orphaned ?? 0);
      const stuck = Number(result[0]?.stuck_deleting ?? 0);
      checks.push({
        name: "entity-registry",
        status: stuck > 0 ? "FAIL" : orphaned > 0 ? "WARN" : "PASS",
        detail: `${orphaned} orphaned persistent entity row(s), ${stuck} stuck deletion(s).`,
      });
    } else {
      checks.push({ name: "entity-registry", status: "WARN", detail: "Persistent entity registry is not installed." });
    }
  } catch (error) {
    checks.push({ name: "database-diagnostics", status: "FAIL", detail: `A read-only diagnostic query failed (${safeErrorCode(error)}).` });
  } finally {
    await connection.end().catch(() => undefined);
  }
  return checks;
}
