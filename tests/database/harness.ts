import { createHash } from 'node:crypto';
import { readFile, readdir } from 'node:fs/promises';
import path from 'node:path';
import mysql, { type Connection, type RowDataPacket } from 'mysql2/promise';

export const repositoryRoot = process.cwd();

export const migrationDirectories = [
  'core/synex_core/migrations',
  'resources/synex_groups/migrations',
  'resources/synex_accounts/migrations',
  'resources/synex_entities/migrations',
  'libraries/synex_bridge/migrations',
  'resources/synex_world/migrations',
] as const;

export interface MigrationSource {
  directory: string;
  file: string;
  relativePath: string;
  contents: string;
  checksum: string;
  statements: string[];
}

export function splitMigration(contents: string): string[] {
  return contents
    .replaceAll('\r\n', '\n')
    .split(/^-- synex:statement\s*$/mu)
    .map((statement) => statement.trim())
    .filter((statement) => statement.length > 0);
}

export function migrationChecksum(contents: string): string {
  return createHash('sha256').update(contents.replaceAll('\r\n', '\n'), 'utf8').digest('hex');
}

export async function loadMigrations(): Promise<MigrationSource[]> {
  const migrations: MigrationSource[] = [];
  for (const directory of migrationDirectories) {
    const absoluteDirectory = path.join(repositoryRoot, directory);
    const files = (await readdir(absoluteDirectory))
      .filter((file) => /^\d{3}_[a-z0-9_]+\.sql$/u.test(file))
      .sort((left, right) => left.localeCompare(right));
    for (const file of files) {
      const relativePath = path.posix.join(directory.replaceAll('\\', '/'), file);
      const contents = await readFile(path.join(absoluteDirectory, file), 'utf8');
      migrations.push({
        directory,
        file,
        relativePath,
        contents,
        checksum: migrationChecksum(contents),
        statements: splitMigration(contents),
      });
    }
  }
  return migrations;
}

export interface LiveDatabase {
  connection: Connection;
  databaseName: string;
}

export function liveDatabaseGate(): { enabled: false; reason: string } | { enabled: true; url: string; databaseName: string } {
  const url = process.env.SYNEX_TEST_DATABASE_URL;
  if (!url) return { enabled: false, reason: 'SYNEX_TEST_DATABASE_URL is not set' };
  if (process.env.SYNEX_TEST_DATABASE_LIVE !== '1') {
    return { enabled: false, reason: 'SYNEX_TEST_DATABASE_LIVE=1 is required' };
  }
  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    return { enabled: false, reason: 'SYNEX_TEST_DATABASE_URL is not a valid URL' };
  }
  if (parsed.protocol !== 'mysql:') {
    return { enabled: false, reason: 'SYNEX_TEST_DATABASE_URL must use mysql://' };
  }
  const databaseName = decodeURIComponent(parsed.pathname.replace(/^\//u, ''));
  if (!/^synex_test_[a-z0-9_]+$/u.test(databaseName)) {
    return { enabled: false, reason: 'database name must match synex_test_[a-z0-9_]+' };
  }
  return { enabled: true, url, databaseName };
}

export async function openLiveDatabase(): Promise<LiveDatabase> {
  const gate = liveDatabaseGate();
  if (!gate.enabled) throw new Error(`Live database gate is closed: ${gate.reason}`);
  const connection = await mysql.createConnection(gate.url);
  return { connection, databaseName: gate.databaseName };
}

export async function applyMigrations(connection: Connection, migrations: MigrationSource[]): Promise<void> {
  const [lockRows] = await connection.query<RowDataPacket[]>(
    "SELECT GET_LOCK(CONCAT('synex:test:migrations:', DATABASE()), 60) AS acquired",
  );
  if (Number(lockRows[0]?.acquired) !== 1) {
    throw new Error('Timed out while serializing live-test migration application.');
  }
  try {
    for (const migration of migrations) {
      for (const statement of migration.statements) {
        await connection.query(statement);
      }
    }
  } finally {
    await connection.query(
      "SELECT RELEASE_LOCK(CONCAT('synex:test:migrations:', DATABASE()))",
    );
  }
}
