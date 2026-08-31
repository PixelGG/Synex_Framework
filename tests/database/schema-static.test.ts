import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { loadMigrations, migrationDirectories, repositoryRoot } from './harness.js';

const runtimeFiles = {
  synex_groups: [
    'server/cache.lua',
    'server/validation.lua',
    'server/domain/constants.lua',
    'server/domain/lifecycle.lua',
    'server/domain/graph.lua',
    'server/domain/capabilities.lua',
    'server/domain/policy.lua',
    'server/domain/registry.lua',
    'server/extension_registries.lua',
    'server/domain/application_schema.lua',
    'server/foundation.lua',
    'server/outbox.lua',
    'server/service.lua',
    'server/scheduler.lua',
    'server/core_bootstrap.lua',
    'server/json_runtime.lua',
    'server/persistence/approved_operations.lua',
    'server/persistence/capability_access.lua',
    'server/persistence.lua',
    'server/persistence/organizations_shared.lua',
    'server/persistence/organizations_read.lua',
    'server/persistence/organizations_creation.lua',
    'server/persistence/organizations_lifecycle.lua',
    'server/persistence/organizations_types.lua',
    'server/persistence/extension_registries.lua',
    'server/persistence/organizations_structure.lua',
    'server/persistence/organizations.lua',
    'server/persistence/memberships_shared.lua',
    'server/persistence/memberships_read.lua',
    'server/persistence/memberships_invitations.lua',
    'server/persistence/memberships_lifecycle.lua',
    'server/persistence/memberships_access.lua',
    'server/persistence/memberships_reporting.lua',
    'server/persistence/memberships.lua',
    'server/persistence/governance_shared.lua',
    'server/persistence/governance_capabilities.lua',
    'server/persistence/governance_capability_rules.lua',
    'server/persistence/governance_policies.lua',
    'server/persistence/governance_attribute_values.lua',
    'server/persistence/governance_attributes.lua',
    'server/persistence/governance_attribute_activation.lua',
    'server/persistence/governance_definitions_capabilities.lua',
    'server/persistence/governance_definitions_hierarchy.lua',
    'server/persistence/governance_definitions_groups.lua',
    'server/persistence/governance_definitions.lua',
    'server/persistence/governance.lua',
    'server/persistence/workflows_shared.lua',
    'server/persistence/workflows_duty.lua',
    'server/persistence/workflows_assignments.lua',
    'server/persistence/workflows_applications.lua',
    'server/persistence/workflows_proposals.lua',
    'server/persistence/workflows.lua',
    'server/persistence/diagnostics.lua',
    'server/persistence/workers.lua',
    'server/persistence/observability.lua',
    'server/contracts.lua',
    'server/runtime_registration.lua',
    'server/main.lua',
  ],
  synex_accounts: [
    'server/foundation.lua',
    'server/json_runtime.lua',
    'server/domain.lua',
    'server/core_bootstrap.lua',
    'server/operator_adapter.lua',
    'server/outbox.lua',
    'server/retention.lua',
    'server/service.lua',
    'server/service_v2/runtime.lua',
    'server/service_v2/catalog_accounts.lua',
    'server/service_v2/transactions_holds.lua',
    'server/service_v2/access_policy.lua',
    'server/service_v2/integrity.lua',
    'server/service_v2/guard.lua',
    'server/service_v2.lua',
    'server/lifecycle.lua',
    'server/persistence.lua',
    'server/persistence/engine_shared.lua',
    'server/persistence/accounts.lua',
    'server/persistence/accounts_v2.lua',
    'server/persistence/ledger.lua',
    'server/persistence/transactions.lua',
    'server/persistence/transaction_reads.lua',
    'server/persistence/holds.lua',
    'server/persistence/holds_v2.lua',
    'server/persistence/access.lua',
    'server/persistence/access_v2.lua',
    'server/persistence/restrictions_v2.lua',
    'server/persistence/integrity.lua',
    'server/persistence/integrity_behavior.lua',
    'server/persistence/integrity_v2.lua',
    'server/persistence/integrity_control.lua',
    'server/persistence/observability_control.lua',
    'server/persistence/observability_inspect.lua',
    'server/persistence/observability.lua',
    'server/persistence/lifecycle_groups.lua',
    'server/persistence/lifecycle.lua',
    'server/contracts.lua',
    'server/main.lua',
  ],
} as const;

async function readResourceRuntime(resourceName: keyof typeof runtimeFiles): Promise<string> {
  return (await Promise.all(runtimeFiles[resourceName].map((relativePath) =>
    readFile(path.join(repositoryRoot, 'resources', resourceName, relativePath), 'utf8'),
  ))).join('\n');
}

interface ResourceManifest {
  migrations: Array<{ id: string; path: string; transactional: boolean }>;
  dataOwnership: { tables: string[] };
  contracts: { provide: string[] };
}

function createdTables(contents: string): string[] {
  return [...contents.matchAll(/CREATE TABLE IF NOT EXISTS `([a-z0-9_]+)`/gu)].map((match) => match[1] ?? '');
}

function transactionBindings(runtime: string): Array<{ query: string; values: string }> {
  const bindings: Array<{ query: string; values: string }> = [];
  const pattern = /query\s*=\s*(?:\[\[([\s\S]*?)\]\]|'((?:\\.|[^'])*)')\s*,\s*values\s*=\s*\{([^{}]*)\}/gu;
  for (const match of runtime.matchAll(pattern)) {
    bindings.push({ query: match[1] ?? match[2] ?? '', values: match[3] ?? '' });
  }
  const directPattern = /tx\.(?:query|one|many|affected|insert)\s*\(\s*(?:\[\[((?:(?!\]\])[\s\S])*)\]\]|'((?:\\.|[^'])*)')\s*,\s*\{([^{}]*)\}\s*\)/gu;
  for (const match of runtime.matchAll(directPattern)) {
    bindings.push({ query: match[1] ?? match[2] ?? '', values: match[3] ?? '' });
  }
  return bindings;
}

function withoutSqlStringLiterals(statement: string): string {
  return statement.replace(/'(?:''|\\.|[^'])*'/gu, "''");
}

function countTopLevelLuaValues(values: string): number {
  let depth = 0;
  let quote: "'" | '"' | undefined;
  let escaped = false;
  let entryHasContent = false;
  let count = 0;

  for (const character of values) {
    if (quote !== undefined) {
      entryHasContent = true;
      if (escaped) {
        escaped = false;
      } else if (character === '\\') {
        escaped = true;
      } else if (character === quote) {
        quote = undefined;
      }
      continue;
    }

    if (character === "'" || character === '"') {
      quote = character;
      entryHasContent = true;
    } else if (character === '(' || character === '[' || character === '{') {
      depth += 1;
      entryHasContent = true;
    } else if (character === ')' || character === ']' || character === '}') {
      assert.ok(depth > 0, 'Lua transaction values contain an unmatched closing delimiter');
      depth -= 1;
      entryHasContent = true;
    } else if (character === ',' && depth === 0) {
      assert.ok(entryHasContent, 'Lua transaction values contain an empty positional entry');
      count += 1;
      entryHasContent = false;
    } else if (!/\s/u.test(character)) {
      entryHasContent = true;
    }
  }

  assert.equal(quote, undefined, 'Lua transaction values contain an unterminated string');
  assert.equal(depth, 0, 'Lua transaction values contain an unterminated delimiter');
  return count + (entryHasContent ? 1 : 0);
}

function assertProcedureCycle(
  statements: string[],
  offset: number,
  procedureName: string,
  relativePath: string,
): void {
  assert.equal(statements[offset], `DROP PROCEDURE IF EXISTS \`${procedureName}\`;`, relativePath);
  assert.match(
    statements[offset + 1] ?? '',
    new RegExp('^CREATE PROCEDURE `' + procedureName + '`\\(\\)', 'u'),
    relativePath,
  );
  assert.equal(statements[offset + 2], `CALL \`${procedureName}\`();`, relativePath);
  assert.equal(statements[offset + 3], `DROP PROCEDURE IF EXISTS \`${procedureName}\`;`, relativePath);
  assert.match(
    statements[offset + 1] ?? '',
    /`information_schema`\.`(?:TABLES|COLUMNS|STATISTICS|TABLE_CONSTRAINTS)`/u,
    relativePath,
  );
  assert.match(statements[offset + 1] ?? '', /SIGNAL SQLSTATE '45000'/u, relativePath);
}

test('migrations are deterministic, forward ordered, and split exactly as the core runner expects', async () => {
  const migrations = await loadMigrations();
  assert.ok(migrations.length >= 10);
  for (const directory of migrationDirectories) {
    const scoped = migrations.filter((migration) => migration.directory === directory);
    const numbers = scoped.map((migration) => Number.parseInt(migration.file.slice(0, 3), 10));
    assert.deepEqual(numbers, [...numbers].sort((left, right) => left - right), directory);
    assert.equal(new Set(numbers).size, numbers.length, `${directory} has duplicate numeric prefixes`);
  }
  for (const migration of migrations) {
    assert.equal(migration.contents.includes('\r'), false, `${migration.relativePath} must use LF line endings`);
    assert.match(migration.checksum, /^[0-9a-f]{64}$/u);
    const tables = createdTables(migration.contents);
    const createStatements = migration.statements.filter((statement) => statement.startsWith('CREATE TABLE IF NOT EXISTS'));
    assert.equal(createStatements.length, tables.length, `${migration.relativePath} requires one split statement per table`);
    if (migration.directory === 'resources/synex_accounts/migrations'
      && Number.parseInt(migration.file.slice(0, 3), 10) >= 7
      && Number.parseInt(migration.file.slice(0, 3), 10) <= 17) {
      for (const statement of migration.statements) {
        const structuralSql = withoutSqlStringLiterals(statement);
        assert.match(
          statement,
          /^(?:CREATE TABLE IF NOT EXISTS|CREATE (?:UNIQUE )?INDEX IF NOT EXISTS|ALTER TABLE|UPDATE|INSERT(?: IGNORE)? INTO|DROP INDEX IF EXISTS) /u,
          migration.relativePath,
        );
        if (statement.startsWith('CREATE TABLE IF NOT EXISTS')) {
          assert.match(statement, /ENGINE=InnoDB/u, migration.relativePath);
        }
        if (statement.startsWith('DROP INDEX')) {
          assert.ok(new Set([
            'DROP INDEX IF EXISTS `uq_account_operations_key` ON `synex_account_operations`;',
            'DROP INDEX IF EXISTS `uq_account_operations_scope` ON `synex_account_operations`;',
            'DROP INDEX IF EXISTS `idx_account_operations_caller_state` ON `synex_account_operations`;',
          ]).has(statement), `${migration.relativePath} contains an unexpected destructive index change`);
        }
        assert.doesNotMatch(
          structuralSql,
          /\b(?:DROP\s+(?:TABLE|COLUMN)|TRUNCATE|RENAME\s+TABLE|DELETE\s+FROM)\b/iu,
          `${migration.relativePath} must preserve financial data`,
        );
        assert.doesNotMatch(structuralSql, /:[A-Za-z_][A-Za-z0-9_]*/u, `${migration.relativePath} uses a named placeholder`);
        assert.doesNotMatch(structuralSql, /@[A-Za-z_][A-Za-z0-9_]*/u, `${migration.relativePath} uses a named placeholder`);
      }
      continue;
    }
    if (migration.directory === 'resources/synex_accounts/migrations'
      && migration.file === '018_access_grant_valid_from_default.sql') {
      assert.equal(migration.statements.length, 5, migration.relativePath);
      assertProcedureCycle(
        migration.statements,
        0,
        'synex_migrate_018_access_grant_valid_from_default',
        migration.relativePath,
      );
      assert.match(
        migration.statements[4] ?? '',
        /^INSERT INTO `synex_account_migration_assertions`/u,
        migration.relativePath,
      );
      for (const statement of migration.statements) {
        assert.doesNotMatch(
          withoutSqlStringLiterals(statement),
          /\b(?:DROP\s+(?:TABLE|COLUMN)|TRUNCATE|RENAME\s+TABLE|DELETE\s+FROM)\b/iu,
          `${migration.relativePath} must preserve financial data`,
        );
      }
      continue;
    }
    if (migration.directory === 'resources/synex_groups/migrations'
      && migration.file === '024_group_deletion_lifecycle.sql') {
      assert.equal(migration.statements.length, 9, migration.relativePath);
      assertProcedureCycle(
        migration.statements,
        0,
        'synex_groups_migrate_024_group_deletion_lifecycle',
        migration.relativePath,
      );
      assert.match(
        migration.statements[4] ?? '',
        /^CREATE TABLE IF NOT EXISTS `synex_group_deletion_requests`/u,
        migration.relativePath,
      );
      assertProcedureCycle(
        migration.statements,
        5,
        'synex_groups_verify_024_group_deletion_lifecycle',
        migration.relativePath,
      );
      continue;
    }
    if (migration.directory === 'resources/synex_groups/migrations'
      && migration.file === '025_dynamic_group_creation_approvals.sql') {
      assert.equal(migration.statements.length, 13, migration.relativePath);
      assertProcedureCycle(
        migration.statements,
        0,
        'synex_groups_migrate_025_creation_policy',
        migration.relativePath,
      );
      for (const [offset, table] of [
        [4, 'synex_group_creation_requests'],
        [5, 'synex_group_creation_approvals'],
        [6, 'synex_group_slug_reservations'],
      ] as const) {
        assert.match(
          migration.statements[offset] ?? '',
          new RegExp('^CREATE TABLE IF NOT EXISTS `' + table + '`', 'u'),
          migration.relativePath,
        );
      }
      assert.match(migration.statements[7] ?? '', /^INSERT IGNORE INTO `synex_group_slug_reservations`/u);
      assert.match(migration.statements[8] ?? '', /^INSERT IGNORE INTO `synex_group_slug_reservations`/u);
      assertProcedureCycle(
        migration.statements,
        9,
        'synex_groups_verify_025_creation_approvals',
        migration.relativePath,
      );
      continue;
    }
    if (migration.directory === 'resources/synex_groups/migrations'
      && migration.file === '026_group_attribute_scopes.sql') {
      assert.equal(migration.statements.length, 8, migration.relativePath);
      assertProcedureCycle(
        migration.statements,
        0,
        'synex_groups_migrate_026_group_attribute_scopes',
        migration.relativePath,
      );
      assertProcedureCycle(
        migration.statements,
        4,
        'synex_groups_verify_026_group_attribute_scopes',
        migration.relativePath,
      );
      continue;
    }
    if (migration.directory === 'resources/synex_groups/migrations'
      && migration.file === '027_identifier_contract_consistency.sql') {
      assert.equal(migration.statements.length, 4, migration.relativePath);
      assertProcedureCycle(
        migration.statements,
        0,
        'synex_groups_migrate_027_identifier_contract_consistency',
        migration.relativePath,
      );
      continue;
    }
    if (migration.directory === 'resources/synex_groups/migrations'
      && migration.file === '028_membership_transition_policies.sql') {
      assert.equal(migration.statements.length, 5, migration.relativePath);
      assert.match(
        migration.statements[0] ?? '',
        /^CREATE TABLE IF NOT EXISTS `synex_group_membership_transition_policies`/u,
        migration.relativePath,
      );
      assertProcedureCycle(
        migration.statements,
        1,
        'synex_groups_verify_028_membership_transition_policies',
        migration.relativePath,
      );
      continue;
    }
    if (migration.directory === 'resources/synex_groups/migrations' && new Set([
      '008_public_id_compatibility.sql',
      '009_contract_storage_compatibility.sql',
      '010_external_resource_ownership.sql',
      '011_mutation_entity_public_ids.sql',
      '012_group_history_scope.sql',
      '013_contract_text_bounds.sql',
      '014_character_anonymization_ids.sql',
      '015_primary_membership_public_ids.sql',
      '017_static_definition_targets.sql',
      '019_definition_applied_snapshots.sql',
      '020_capability_delegability.sql',
      '021_persistent_extension_registries.sql',
      '022_workflow_lifecycle_expiry.sql',
      '023_dynamic_type_creation_policies.sql',
      '029_assignment_member_active_counts.sql',
      '030_membership_workflow_entities.sql',
      '032_character_reference_contract.sql',
    ]).has(migration.file)) {
      const procedureOffset = migration.file === '009_contract_storage_compatibility.sql'
        ? 4
        : migration.file === '023_dynamic_type_creation_policies.sql' ? 2 : 0;
      const procedureName = `synex_groups_migrate_${migration.file.slice(0, -'.sql'.length)}`;
      assert.equal(migration.statements.length, procedureOffset + 4, migration.relativePath);
      assert.ok(migration.statements.slice(0, procedureOffset).every(
        (statement) => statement.startsWith('CREATE TABLE IF NOT EXISTS'),
      ));
      assert.equal(migration.statements[procedureOffset], `DROP PROCEDURE IF EXISTS \`${procedureName}\`;`);
      assert.match(migration.statements[procedureOffset + 1] ?? '', new RegExp(
        '^CREATE PROCEDURE `' + procedureName + '`\\(\\)', 'u',
      ));
      assert.equal(migration.statements[procedureOffset + 2], `CALL \`${procedureName}\`();`);
      assert.equal(migration.statements[procedureOffset + 3], `DROP PROCEDURE IF EXISTS \`${procedureName}\`;`);
      assert.match(migration.statements[procedureOffset + 1] ?? '', /`information_schema`\.`(?:TABLES|COLUMNS|STATISTICS|TABLE_CONSTRAINTS)`/u);
      assert.match(migration.statements[procedureOffset + 1] ?? '', /SIGNAL SQLSTATE '45000'/u);
      continue;
    }
    if (migration.file === '022_idempotency_capacity.sql') {
      assert.equal(migration.statements.length, 7);
      assert.ok(migration.statements.slice(0, 3).every(
        (statement) => statement.startsWith('CREATE TABLE IF NOT EXISTS'),
      ));
      assert.match(migration.statements[3] ?? '', /^DROP PROCEDURE IF EXISTS/u);
      assert.match(migration.statements[4] ?? '', /^CREATE PROCEDURE/u);
      assert.match(migration.statements[5] ?? '', /^CALL /u);
      assert.match(migration.statements[6] ?? '', /^DROP PROCEDURE IF EXISTS/u);
      continue;
    }
    if (migration.file === '024_session_control_capacity.sql') {
      assert.equal(migration.statements.length, 6);
      assert.ok(migration.statements.slice(0, 2).every(
        (statement) => statement.startsWith('CREATE TABLE IF NOT EXISTS'),
      ));
      assert.match(migration.statements[2] ?? '', /^DROP PROCEDURE IF EXISTS/u);
      assert.match(migration.statements[3] ?? '', /^CREATE PROCEDURE/u);
      assert.match(migration.statements[4] ?? '', /^CALL /u);
      assert.match(migration.statements[5] ?? '', /^DROP PROCEDURE IF EXISTS/u);
      continue;
    }
    if (migration.file === '025_cluster_lease_capacity.sql') {
      assert.equal(migration.statements.length, 6);
      assert.ok(migration.statements.slice(0, 2).every(
        (statement) => statement.startsWith('CREATE TABLE IF NOT EXISTS'),
      ));
      assert.match(migration.statements[2] ?? '', /^DROP PROCEDURE IF EXISTS/u);
      assert.match(migration.statements[3] ?? '', /^CREATE PROCEDURE/u);
      assert.match(migration.statements[4] ?? '', /^CALL /u);
      assert.match(migration.statements[5] ?? '', /^DROP PROCEDURE IF EXISTS/u);
      continue;
    }
    if (migration.directory === 'core/synex_core/migrations'
      && migration.file === '027_domain_primitives.sql') {
      assert.equal(migration.statements.length, 15);
      assert.ok(migration.statements.slice(0, 11).every((statement) =>
        statement.startsWith('CREATE TABLE IF NOT EXISTS')
          || statement.startsWith('INSERT INTO')));
      assertProcedureCycle(
        migration.statements,
        11,
        'synex_migrate_027_domain_deletion_capacity',
        migration.relativePath,
      );
      continue;
    }
    if (migration.directory === 'resources/synex_entities/migrations'
      && migration.file === '002_entity_lifecycle_authority.sql') {
      assert.equal(migration.statements.length, 6, migration.relativePath);
      assert.match(migration.statements[0] ?? '', /^ALTER TABLE `synex_entities`/u);
      assert.match(migration.statements[1] ?? '', /^ALTER TABLE `synex_entities`/u);
      assert.match(migration.statements[2] ?? '', /^CREATE UNIQUE INDEX IF NOT EXISTS/u);
      assert.equal(
        migration.statements[3],
        'DROP INDEX IF EXISTS `uq_synex_entities_persistent_key` ON `synex_entities`;',
      );
      assert.ok(migration.statements.slice(4).every(
        (statement) => statement.startsWith('CREATE INDEX IF NOT EXISTS'),
      ));
      for (const statement of migration.statements) {
        assert.doesNotMatch(
          withoutSqlStringLiterals(statement),
          /\b(?:DROP\s+(?:TABLE|COLUMN)|TRUNCATE|RENAME\s+TABLE|DELETE\s+FROM)\b/iu,
          `${migration.relativePath} must preserve entity definitions and tombstones`,
        );
      }
      continue;
    }
    if (migration.directory === 'resources/synex_entities/migrations'
      && (migration.file === '003_entity_extensions.sql'
        || migration.file === '004_entity_cluster_recovery.sql')) {
      assert.ok(migration.statements.every((statement) =>
        statement.startsWith('CREATE TABLE IF NOT EXISTS')));
      assert.ok(migration.statements.every((statement) => /ENGINE=InnoDB/u.test(statement)));
      continue;
    }
    if (new Set([
      '014_runtime_owner_attribution.sql',
      '015_character_reconciliation_fencing.sql',
      '017_runtime_scalability.sql',
      '018_character_slot_reuse.sql',
      '019_session_control_target_authority.sql',
      '020_terminal_lease_eligibility.sql',
      '021_worker_queue_scalability.sql',
      '023_lease_authority_recovery.sql',
      '026_lease_authority_owner_index.sql',
    ]).has(migration.file)) {
      assert.equal(migration.statements.length, 4);
      assert.match(migration.statements[0] ?? '', /^DROP PROCEDURE IF EXISTS/u);
      assert.match(migration.statements[1] ?? '', /^CREATE PROCEDURE/u);
      assert.match(migration.statements[2] ?? '', /^CALL /u);
      assert.match(migration.statements[3] ?? '', /^DROP PROCEDURE IF EXISTS/u);
      continue;
    }
    for (const statement of migration.statements) {
      const structuralSql = withoutSqlStringLiterals(statement);
      assert.match(statement, /^(?:CREATE TABLE IF NOT EXISTS `[a-z0-9_]+`|INSERT INTO `[a-z0-9_]+`)/u, migration.relativePath);
      if (statement.startsWith('CREATE TABLE IF NOT EXISTS')) assert.match(statement, /ENGINE=InnoDB/u, migration.relativePath);
      assert.doesNotMatch(statement, /\b(?:DROP|TRUNCATE|RENAME)\b/iu, `${migration.relativePath} must be forward-only`);
      assert.doesNotMatch(structuralSql, /:[A-Za-z_][A-Za-z0-9_]*/u, `${migration.relativePath} uses a named placeholder`);
      assert.doesNotMatch(structuralSql, /@[A-Za-z_][A-Za-z0-9_]*/u, `${migration.relativePath} uses a named placeholder`);
    }
  }
});

test('Groups workflow expiry migration is manifest-owned and keeps open-application scans indexed', async () => {
  const migrations = await loadMigrations();
  const migration = migrations.find((entry) =>
    entry.directory === 'resources/synex_groups/migrations'
      && entry.file === '022_workflow_lifecycle_expiry.sql');
  assert.ok(migration);
  assert.match(migration.contents, /`expires_at` DATETIME\(6\) NOT NULL/u);
  assert.match(
    migration.contents,
    /idx_group_applications_expiry` \(`status`, `expires_at`, `id`\)/u,
  );
  assert.match(
    migration.contents,
    /`SEQ_IN_INDEX` = 2 AND `COLUMN_NAME` = 'expires_at'[\s\S]*?`SEQ_IN_INDEX` = 3 AND `COLUMN_NAME` = 'id'/u,
  );
  assert.match(migration.contents, /'withdrawn', 'expired'/u);
  const manifest = JSON.parse(await readFile(
    path.join(repositoryRoot, 'resources/synex_groups/synex.resource.json'),
    'utf8',
  )) as ResourceManifest;
  assert.ok(manifest.migrations.some((entry) =>
    entry.id === '022_workflow_lifecycle_expiry'
      && entry.path === 'migrations/022_workflow_lifecycle_expiry.sql'
      && entry.transactional === false));
});

test('nullable default metadata gates accept both MySQL and MariaDB SQL NULL representations', async () => {
  let checked = 0;
  for (const migration of await loadMigrations()) {
    for (const match of migration.contents.matchAll(/`COLUMN_DEFAULT`\s+IS\s+NULL/giu)) {
      const index = match.index ?? 0;
      const window = migration.contents.slice(Math.max(0, index - 300), index + 300);
      if (!/`IS_NULLABLE`\s*=\s*'YES'/u.test(window)) continue;
      checked += 1;
      assert.match(
        window,
        /\(`COLUMN_DEFAULT` IS NULL\s+OR CAST\(`COLUMN_DEFAULT` AS BINARY\) = CAST\('NULL' AS BINARY\)\)/u,
        migration.relativePath,
      );
    }
  }
  assert.ok(checked > 0);
});

test('resource manifests own every table they create and list every migration', async () => {
  for (const resourceName of ['synex_groups', 'synex_accounts'] as const) {
    const resourceDirectory = path.join(repositoryRoot, 'resources', resourceName);
    const manifest = JSON.parse(await readFile(path.join(resourceDirectory, 'synex.resource.json'), 'utf8')) as ResourceManifest;
    const contractSource = JSON.parse(await readFile(
      path.join(resourceDirectory, `${resourceName.slice('synex_'.length)}.contracts.json`),
      'utf8',
    )) as { contracts: Array<{ name: string }> };
    const migrations = (await loadMigrations()).filter((migration) =>
      migration.directory === `resources/${resourceName}/migrations`,
    );
    assert.deepEqual(
      manifest.migrations.map((migration) => migration.path),
      migrations.map((migration) => `migrations/${migration.file}`),
    );
    assert.ok(manifest.migrations.every((migration) => migration.transactional === false));
    const tables = migrations.flatMap((migration) => createdTables(migration.contents)).sort();
    assert.deepEqual([...manifest.dataOwnership.tables].sort(), tables);
    assert.equal(new Set(manifest.contracts.provide).size, manifest.contracts.provide.length);
    assert.deepEqual(manifest.contracts.provide, contractSource.contracts.map((contract) => contract.name));
  }
});

test('domain outbox dispatchers use bounded owner-aware claims and capability-gated durable publication', async () => {
  for (const [resourceName, tableName] of [
    ['synex_groups', 'synex_group_outbox'],
    ['synex_accounts', 'synex_account_outbox'],
  ] as const) {
    const directory = path.join(repositoryRoot, 'resources', resourceName);
    const outbox = await readFile(path.join(directory, 'server', 'outbox.lua'), 'utf8');
    const main = await readFile(path.join(directory, 'server', 'main.lua'), 'utf8');
    const workerRuntime = resourceName === 'synex_groups'
      ? await readFile(path.join(directory, 'server', 'scheduler.lua'), 'utf8')
      : main;
    const manifest = JSON.parse(await readFile(path.join(directory, 'synex.resource.json'), 'utf8')) as {
      capabilities: { request: string[] };
    };
    if (resourceName === 'synex_accounts') {
      assert.deepEqual(manifest.capabilities.request, [
        'synex.audit.append',
        'synex.capabilities.delegate',
        'synex.deletions.provider',
        'synex.events.durable',
        'synex.metrics.write',
        'synex.runtime.read',
        'synex.security.signal.emit',
        'synex.control.provider.register',
      ]);
    } else {
      assert.deepEqual(manifest.capabilities.request, [
        'synex.audit.append',
        'synex.events.durable',
        'synex.identity.read',
        'synex.permissions.read',
        'synex.deletions.read',
        'synex.deletions.manage',
        'synex.deletions.provider',
        'synex.database.read',
        'synex.database.write',
        'synex.database.transaction',
        'synex.database.maintenance',
        'synex.control.provider.register',
      ]);
    }
    assert.match(outbox, new RegExp('UPDATE `' + tableName + '`[\\s\\S]*?`locked_by` = \\?', 'u'));
    assert.match(outbox, /`locked_until` = TIMESTAMPADD\(SECOND, \?, CURRENT_TIMESTAMP\(6\)\)/u);
    assert.match(outbox, /`attempts` = `attempts` \+ 1/u);
    assert.match(outbox, /WHERE `state` = 'pending' AND `available_at` <= CURRENT_TIMESTAMP\(6\)[\s\S]*?ORDER BY `id` ASC LIMIT \?/u);
    assert.match(
      outbox,
      /WHERE (?:`[a-z_]+`\.)?`state` = 'publishing' AND (?:`[a-z_]+`\.)?`locked_by` = \?[\s\S]*?ORDER BY (?:`[a-z_]+`\.)?`id` ASC LIMIT \?/u,
    );
    assert.match(outbox, /`locked_until` IS NULL OR `locked_until` <= CURRENT_TIMESTAMP\(6\)/u);
    assert.match(outbox, /MAXIMUM_PAYLOAD_BYTES = 32768/u);
    assert.match(outbox, /MAXIMUM_BATCH_SIZE = 50/u);
    assert.match(outbox, /MAXIMUM_ATTEMPTS = 10/u);
    assert.match(outbox, /failed == 0/u);
    assert.match(outbox, /OUTBOX_SUBSCRIBER_FAILED/u);
    assert.match(workerRuntime, /api\.Ids\.next\('outbox_claim'\)/u);
    assert.match(workerRuntime, /api\.Events\.publishOutbox\(topic, payload/u);
    const publicationOptions = resourceName === 'synex_groups' ? 'publishOptions' : 'options';
    assert.match(workerRuntime, new RegExp(`eventId = ${publicationOptions}\\.eventId`, 'u'));
    assert.match(workerRuntime, new RegExp(`aggregateId = ${publicationOptions}\\.aggregateId`, 'u'));
    assert.match(workerRuntime, new RegExp(`schemaVersion = ${publicationOptions}\\.schemaVersion`, 'u'));
    assert.match(workerRuntime, new RegExp(`name = '${resourceName}\\.outbox_dispatcher'`, 'u'));
    assert.doesNotMatch(outbox, resourceName === 'synex_groups' ? /synex_account_/u : /synex_group_/u);
  }
});

test('the account schema encodes bounded multi-leg postings and has no directly mutable balance', async () => {
  const migrations = await loadMigrations();
  const accountSql = migrations
    .filter((migration) => migration.directory === 'resources/synex_accounts/migrations')
    .map((migration) => migration.contents)
    .join('\n');
  const accountsTable = accountSql.match(/CREATE TABLE IF NOT EXISTS `synex_accounts`([\s\S]*?)ENGINE=InnoDB/u)?.[1];
  assert.ok(accountsTable);
  assert.doesNotMatch(accountsTable, /`(?:booked_|reserved_|available_)?balance(?:_minor)?`/u);
  assert.match(accountSql, /CREATE TABLE IF NOT EXISTS `synex_ledger_entries`/u);
  assert.match(accountSql, /AND `amount_minor` <> 0\)/u);
  assert.match(accountSql, /UNIQUE KEY `uq_ledger_entries_transaction_sequence` \(`transaction_id`, `sequence_no`\)/u);
  assert.match(accountSql, /UNIQUE KEY `uq_ledger_entries_transaction_account` \(`transaction_id`, `account_id`\)/u);
  assert.match(accountSql, /`posting_model` = 'multi_leg' AND `entry_count` BETWEEN 2 AND 16/u);
  assert.match(accountSql, /COALESCE\(SUM\(`entry`\.`amount_minor`\), 1\) <> 0/u);
  assert.match(accountSql, /UNIQUE KEY `uq_account_hold_events_terminal` \(`hold_id`, `terminal_marker`\)/u);
  assert.match(accountSql, /UNIQUE KEY `uq_ledger_reversals_original` \(`original_transaction_id`\)/u);
  assert.match(accountSql, /UNIQUE KEY `uq_ledger_reversals_reversal` \(`reversal_transaction_id`\)/u);
  assert.match(accountSql, /CHECK \(`permission_key` IN \('view', 'deposit', 'withdraw', 'transfer', 'history', 'manage', 'close'\)\)/u);
  assert.match(accountSql, /UNIQUE KEY `uq_account_access_grants_active`\s*\(`account_id`, `principal_kind`, `principal_ref`, `active_marker`\)/u);
  assert.match(accountSql, /`status` = 'active' AND `active_marker` IS NOT NULL AND `active_marker` = 1/u);
  assert.match(accountSql, /CHECK \(`severity` = 'warn'\)/u);
  assert.match(accountSql, /CHECK \(`status` IN \('healthy', 'warn'\)\)/u);
  assert.match(
    accountSql,
    /UNIQUE KEY `uq_economy_reconciliation_currency_version` \(`currency_id`, `model_version`\)/u,
  );
  assert.doesNotMatch(accountSql, /\bban(?:ned|s)?\b/iu);

  const runtime = await readResourceRuntime('synex_accounts');
  assert.doesNotMatch(runtime, /UPDATE\s+`synex_accounts`[\s\S]{0,160}\bbalance/iu);
  const ledgerUpdates = [...runtime.matchAll(
    /UPDATE\s+`synex_ledger_(?:transactions|postings|entries)`\s+SET\s+([\s\S]*?)\s+WHERE/giu,
  )];
  assert.ok(ledgerUpdates.length > 0, 'character/group deletion must anonymize ledger provenance');
  for (const update of ledgerUpdates) {
    assert.match(
      (update[1] ?? '').trim(),
      /^`(?:actor_ref|reference_id)` = \?$/u,
      'immutable ledger updates may only anonymize provenance references',
    );
  }
  assert.doesNotMatch(runtime, /DELETE\s+FROM\s+`synex_(?:ledger_transactions|ledger_postings|ledger_entries|financial_transaction_archive(?:_v2)?|financial_entry_archive_v2)`/iu);
  const contracts = JSON.parse(await readFile(
    path.join(repositoryRoot, 'resources/synex_accounts/accounts.contracts.json'),
    'utf8',
  )) as { contracts: Array<{ name: string; network: string }> };
  const contractNames = new Set(contracts.contracts.map((contract) => contract.name));
  for (const operation of ['transfer', 'debit', 'credit', 'mint', 'burn']) {
    assert.ok(contractNames.has(`synex.accounts.${operation}`));
  }
  assert.ok(contractNames.has('synex.accounts.post'));
  assert.ok(contracts.contracts.every((contract) => contract.network === 'none'));
  assert.match(runtime, /api\.RPC\.registerServer/u);
  assert.doesNotMatch(runtime, /registerNetwork/u);
  assert.doesNotMatch(runtime, /exports\(['"](?:Transfer|Debit|Credit|Mint|Burn|CreateHold|CaptureHold|ReleaseHold)['"]/u);
});

test('retention archives are self-contained, append-only mirrors with bounded workers', async () => {
  const coreDirectory = path.join(repositoryRoot, 'core', 'synex_core');
  const accountsDirectory = path.join(repositoryRoot, 'resources', 'synex_accounts');
  const coreMigration = await readFile(path.join(coreDirectory, 'migrations', '010_retention_archive.sql'), 'utf8');
  const financialMigration = await readFile(
    path.join(accountsDirectory, 'migrations', '006_financial_archive.sql'),
    'utf8',
  );
  const coreRetention = await readFile(path.join(coreDirectory, 'server', 'retention.lua'), 'utf8');
  const lifecycle = await readFile(path.join(coreDirectory, 'server', 'bootstrap_lifecycle.lua'), 'utf8');
  const accountRetention = await readFile(path.join(accountsDirectory, 'server', 'retention.lua'), 'utf8');
  const accountMain = await readFile(path.join(accountsDirectory, 'server', 'main.lua'), 'utf8');

  assert.match(coreMigration, /UNIQUE KEY `uq_audit_archive_source` \(`source_audit_id`\)/u);
  assert.doesNotMatch(coreMigration, /FOREIGN KEY/iu);
  assert.match(financialMigration, /UNIQUE KEY `uq_financial_archive_source` \(`source_transaction_id`\)/u);
  assert.match(financialMigration, /CHECK \(`debit_minor` = `credit_minor`\)/u);
  assert.doesNotMatch(financialMigration, /FOREIGN KEY/iu);
  for (const runtime of [coreRetention, accountRetention]) {
    assert.match(runtime, /INSERT IGNORE INTO/u);
    assert.match(runtime, /UTC_TIMESTAMP\(6\)/u);
    assert.match(runtime, /ORDER BY [\s\S]*? LIMIT \?/u);
    assert.doesNotMatch(runtime, /\b(?:DELETE|TRUNCATE|DROP)\b/iu);
  }
  assert.match(lifecycle, /defaultConfig\.retention\.audit\.mode == 'archive'/u);
  assert.match(lifecycle, /'core\.retention\.audit_archive'/u);
  assert.match(accountMain, /api\.Runtime\.getRetentionPolicy\(\)/u);
  assert.match(accountMain, /if policy\.mode == 'archive' then/u);
  assert.match(accountMain, /name = 'synex_accounts\.financial_retention'/u);
  assert.match(accountRetention, /sourceRowsDeleted = 0/u);
});

test('group grades, deny precedence, typed primary selection, and synchronous rule evaluation stay relational', async () => {
  const migrations = await loadMigrations();
  const groupSql = migrations
    .filter((migration) => migration.directory === 'resources/synex_groups/migrations')
    .map((migration) => migration.contents)
    .join('\n');
  for (const table of [
    'synex_group_grades',
    'synex_group_grade_capabilities',
    'synex_group_membership_grades',
    'synex_group_primary_memberships',
    'synex_group_primary_memberships_by_type',
    'synex_group_read_model_versions',
  ]) assert.ok(groupSql.includes('CREATE TABLE IF NOT EXISTS `' + table + '`'), table);
  assert.match(groupSql, /CHECK \(`effect` IN \('allow', 'deny'\)\)/u);
  assert.match(groupSql, /PRIMARY KEY \(`subject_kind`, `subject_ref`\)/u);
  assert.match(groupSql, /CHECK \(`model_version` > 0\)/u);

  const runtime = await readResourceRuntime('synex_groups');
  const primaryMutation = runtime.match(/function handlers\.execute\.members_set_primary[\s\S]*?\nend/u)?.[0] ?? '';
  assert.ok(primaryMutation.length > 0);
  assert.doesNotMatch(primaryMutation, /(?:UPDATE|DELETE FROM)\s+`synex_group_memberships`/iu);
  assert.match(primaryMutation, /synex_group_primary_memberships_by_type/u);
  assert.match(runtime, /requireCurrentApi\('Permissions', 'evaluateRules'\)/u);
  assert.match(runtime, /Foundation\.isCallable\(api\.Permissions\.evaluateRules\)/u);
  assert.match(runtime, /pcall\(\s*coreEvaluateRules,\s*input\.capability,\s*candidates\)/u);
  assert.match(runtime, /result\.allowed = result\.matchedAllows > 0 and not result\.denied/u);
  assert.match(runtime, /if coreResult\.denied ~= result\.denied or coreResult\.allowed ~= result\.allowed then/u);
  assert.doesNotMatch(runtime, /synex_group_rbac_sync_state|desired_revision/u);
});

test('domain resources do not hide caller identity behind convenience exports', async () => {
  for (const resourceName of ['synex_groups', 'synex_accounts'] as const) {
    const runtime = await readResourceRuntime(resourceName);
    assert.doesNotMatch(runtime, /exports\.synex_core:Invoke/u, resourceName);
    assert.doesNotMatch(runtime, /\bexports\(['"][A-Z]/u, resourceName);
    assert.match(runtime, /capabilities\s*=\s*\{/u, `${resourceName} must capability-gate its read-only service surface`);
  }
});

test('domain methods are exposed only through guarded Core service and RPC registrations', async () => {
  const groupsRuntime = await readResourceRuntime('synex_groups');
  const accountsRuntime = await readResourceRuntime('synex_accounts');
  assert.match(groupsRuntime, /api\.Services\.provide\(options\.serviceDefinition\(binding\)\)/u);
  assert.match(groupsRuntime, /serviceDefinition\(binding, coreRegistration\)/u);
  assert.match(groupsRuntime, /serviceMethods\[name\] = registration:guard\(binding, handler\)/u);
  assert.match(groupsRuntime, /capabilities\[name\] = definition\.capability/u);
  assert.match(groupsRuntime, /api\.RPC\.registerServer/u);
  assert.match(groupsRuntime, /api\.RPC\.registerNetwork/u);
  assert.match(groupsRuntime, /'UNHEALTHY'/u);
  assert.match(groupsRuntime, /'HEALTHY'/u);
  assert.doesNotMatch(groupsRuntime, /\bexports\s*\(/u);
  assert.match(accountsRuntime, /loadContractDefinitions\(rawCatalog, decode\)/u);
  assert.match(accountsRuntime, /for _, definition in ipairs\(definitions\) do/u);
  assert.match(accountsRuntime, /serviceMethods\[methodName\] = coreRegistration:guard/u);
  assert.match(accountsRuntime, /capabilities\[methodName\] = definition\.capability/u);
  assert.match(accountsRuntime, /api\.Services\.provide\(options\.serviceDefinition\(binding\)\)/u);
  assert.match(accountsRuntime, /api\.RPC\.registerServer\(definition,/u);
  assert.doesNotMatch(accountsRuntime, /api\.RPC\.registerNetwork/u);
  assert.doesNotMatch(accountsRuntime, /\bexports\s*\(/u);
});

test('Foundation mutations remain server-only and the one Groups self projection is explicit', async () => {
  for (const resourceName of ['synex_groups', 'synex_accounts'] as const) {
    const source = JSON.parse(await readFile(
      path.join(repositoryRoot, 'resources', resourceName, `${resourceName.slice('synex_'.length)}.contracts.json`),
      'utf8',
    )) as { contracts: Array<{
      name: string;
      network: string;
      idempotent?: boolean;
      errors: string[];
      input: { required?: string[] };
    }> };
    const networkContracts = source.contracts.filter((contract) => contract.network !== 'none');
    if (resourceName === 'synex_groups') {
      assert.deepEqual(
        networkContracts.map((contract) => contract.name),
        ['synex.groups.self.snapshot'],
      );
      assert.equal(networkContracts[0]?.network, 'client-to-server');
    } else {
      assert.deepEqual(networkContracts, []);
    }
    for (const contract of source.contracts) {
      const mutation = contract.input.required?.includes('idempotency_key') === true;
      if (mutation) {
        assert.equal(contract.network, 'none', contract.name);
        assert.equal(contract.idempotent, true, contract.name);
        assert.ok(contract.errors.includes('OPERATION_IN_PROGRESS'), contract.name);
      } else {
        assert.notEqual(contract.idempotent, true, contract.name);
      }
    }
  }
});

test('new Foundation contracts use the exact privileged capability split', async () => {
  const expected = new Map<string, string>([
    ['synex.groups.types.register', 'synex.groups.types.manage'],
    ['synex.groups.members.set_grade', 'synex.groups.grades.manage'],
    ['synex.groups.members.set_primary', 'synex.groups.members.primary'],
    ['synex.groups.compatibility.set_primary_grade', 'synex.groups.compatibility.set_primary_grade'],
    ['synex.groups.grades.create', 'synex.groups.grades.manage'],
    ['synex.groups.grades.update', 'synex.groups.grades.manage'],
    ['synex.groups.roles.create', 'synex.groups.roles.manage'],
    ['synex.groups.roles.assign', 'synex.groups.roles.manage'],
    ['synex.groups.capabilities.check', 'synex.groups.read'],
    ['synex.groups.capabilities.explain', 'synex.groups.read'],
    ['synex.groups.directory.list', 'synex.groups.directory.read'],
    ['synex.groups.history.list', 'synex.groups.history.read'],
    ['synex.accounts.reverse', 'synex.accounts.reverse'],
    ['synex.accounts.create_access_role', 'synex.accounts.access.manage'],
    ['synex.accounts.grant_access', 'synex.accounts.access.manage'],
    ['synex.accounts.revoke_access', 'synex.accounts.access.manage'],
    ['synex.accounts.get_access', 'synex.accounts.access.read'],
    ['synex.accounts.run_reconciliation', 'synex.accounts.integrity.run'],
    ['synex.accounts.get_integrity', 'synex.accounts.integrity.read'],
  ]);
  const seen = new Set<string>();
  for (const resourceName of ['synex_groups', 'synex_accounts'] as const) {
    const source = JSON.parse(await readFile(
      path.join(repositoryRoot, 'resources', resourceName, `${resourceName.slice('synex_'.length)}.contracts.json`),
      'utf8',
    )) as { contracts: Array<{ name: string; capability?: string }> };
    for (const contract of source.contracts) {
      if (expected.has(contract.name)) {
        seen.add(contract.name);
        assert.equal(contract.capability, expected.get(contract.name), contract.name);
      }
    }
  }
  assert.deepEqual(seen, new Set(expected.keys()));
  const accountsRuntime = await readResourceRuntime('synex_accounts');
  assert.match(accountsRuntime, /loadContractDefinitions\(rawCatalog, decode\)/u);
  assert.match(accountsRuntime, /capabilities\[methodName\] = definition\.capability/u);
  assert.match(accountsRuntime, /api\.RPC\.registerServer\(definition,/u);
});

test('every explicit oxmysql transaction statement has one positional value per placeholder', async () => {
  for (const resourceName of ['synex_groups', 'synex_accounts'] as const) {
    const runtime = await readResourceRuntime(resourceName);
    const bindings = transactionBindings(runtime);
    assert.ok(bindings.length > 20, resourceName);
    for (const binding of bindings) {
      const placeholderCount = (withoutSqlStringLiterals(binding.query).match(/\?/gu) ?? []).length;
      const valueCount = countTopLevelLuaValues(binding.values);
      assert.equal(valueCount, placeholderCount, binding.query.replaceAll(/\s+/gu, ' ').trim());
    }
  }
});

test('idempotent Foundation mutations replay before consulting current domain state', async () => {
  const expected = new Map<keyof typeof runtimeFiles, string[]>([
    ['synex_accounts', ['reverse', 'createAccessRole', 'grantAccess', 'revokeAccess', 'runReconciliation']],
  ]);
  for (const [resourceName, methods] of expected) {
    const runtime = await readResourceRuntime(resourceName);
    for (const method of methods) {
      const block = runtime.match(new RegExp(`function port:${method}\\(command\\)([\\s\\S]*?)(?=\\n    function port:|\\n    return port)`, 'u'))?.[1] ?? '';
      assert.ok(block.length > 0, `${resourceName}.${method}`);
      const replayAt = block.indexOf('replay(');
      const queryAt = block.search(/\b(?:one|many|accountState)\(/u);
      assert.ok(replayAt >= 0 && (queryAt < 0 || replayAt < queryAt), `${resourceName}.${method}`);
    }
  }
  const groupsRuntime = await readResourceRuntime('synex_groups');
  const execute = groupsRuntime.match(
    /function port:execute\(operation, request, context\)([\s\S]*?)(?=\n    if modules)/u,
  )?.[1] ?? '';
  assert.ok(execute.length > 0, 'synex_groups.execute');
  const transactionAt = execute.indexOf('dataPort:transaction({');
  const idempotencyAt = execute.indexOf('idempotencyKey = request.idempotency_key');
  const handlerAt = execute.indexOf('handler, tx, request');
  assert.ok(
    transactionAt >= 0 && idempotencyAt > transactionAt && handlerAt > idempotencyAt,
    'synex_groups.execute delegates receipt replay to the Core transaction before its domain handler',
  );
});

test('Foundation runtime modules stay cohesive and every executable file is manifest-listed', async () => {
  for (const resourceName of ['synex_groups', 'synex_accounts'] as const) {
    const manifest = await readFile(path.join(repositoryRoot, 'resources', resourceName, 'fxmanifest.lua'), 'utf8');
    for (const relativePath of runtimeFiles[resourceName]) {
      const source = await readFile(path.join(repositoryRoot, 'resources', resourceName, relativePath), 'utf8');
      assert.ok(source.split(/\r?\n/u).length <= 700, `${resourceName}/${relativePath} exceeds 700 lines`);
      assert.ok(manifest.includes(`'${relativePath}'`), `${resourceName}/${relativePath} is not manifest-listed`);
    }
    const runtime = await readResourceRuntime(resourceName);
    assert.doesNotMatch(runtime, /\b_G\s*\[/u, `${resourceName} uses mutable global state`);
    assert.doesNotMatch(
      runtime,
      /pcall\(MySQL\.transaction\.await/u,
      `${resourceName} must let unexpected transaction failures reach the redacted service error sink`,
    );
    assert.doesNotMatch(runtime, /\b(?:load|loadstring)\s*\(/u, `${resourceName} compiles code dynamically`);
    assert.match(runtime, /local Foundation = require 'server\.foundation'/u);
    assert.match(runtime, /require\('server\.service'\)\(Foundation\)/u);
  }
  const accountsRuntime = await readResourceRuntime('synex_accounts');
  const lockHelper = accountsRuntime.match(
    /local function lockedAccountStatements[\s\S]*?local function appendStatements/u,
  )?.[0] ?? '';
  assert.match(lockHelper, /if upperId < lowerId then lowerId, upperId = upperId, lowerId end/u);
  assert.equal(
    (lockHelper.match(/WHERE `public_id` = \? FOR UPDATE/gu) ?? []).length,
    2,
    'accounts must acquire both row locks through explicitly ordered statements',
  );
});

test('core identity schema accepts the runtime initial source generation', async () => {
  const identity = await readFile(path.join(repositoryRoot, 'core/synex_core/migrations/002_identity.sql'), 'utf8');
  assert.match(identity, /`source_generation` BIGINT UNSIGNED NOT NULL/u);
  assert.doesNotMatch(identity, /CHECK\s*\(`source_generation`\s*>\s*0\)/u);
});

test('character deletion reconciliation migration adds bounded due-ordering and fencing state idempotently', async () => {
  const migration = await readFile(
    path.join(
      repositoryRoot,
      'core',
      'synex_core',
      'migrations',
      '015_character_reconciliation_fencing.sql',
    ),
    'utf8',
  );
  for (const column of [
    'attempt_count',
    'last_attempt_at',
    'next_attempt_at',
    'lease_fencing_token',
  ]) {
    assert.match(migration, new RegExp(`\\x60COLUMN_NAME\\x60\\s*=\\s*'${column}'`, 'u'));
  }
  assert.match(migration, /`next_attempt_at` DATETIME\(6\) NOT NULL DEFAULT CURRENT_TIMESTAMP\(6\)/u);
  assert.match(migration, /`lease_fencing_token` BIGINT UNSIGNED NULL/u);
  assert.match(
    migration,
    /ADD KEY `idx_character_deletion_plans_due`\s*\(`state`, `next_attempt_at`, `created_at`, `id`\)/u,
  );
  assert.equal((migration.match(/DROP PROCEDURE IF EXISTS/gu) ?? []).length, 2);
  assert.equal((migration.match(/CREATE PROCEDURE/gu) ?? []).length, 1);
  assert.equal((migration.match(/CALL `synex_migrate_015_character_reconciliation_fencing`\(\)/gu) ?? []).length, 1);
});

test('runtime scalability migration adds indexed boot, lease, and audit work queues idempotently', async () => {
  const migration = await readFile(
    path.join(repositoryRoot, 'core', 'synex_core', 'migrations', '017_runtime_scalability.sql'),
    'utf8',
  );
  assert.match(
    migration,
    /ADD KEY `idx_sessions_instance_generation`\s*\(`server_instance_id`, `source_generation`\)/u,
  );
  assert.match(
    migration,
    /ADD KEY `idx_sessions_instance_open`\s*\(`server_instance_id`, `closed_at`, `id`\)/u,
  );
  assert.match(
    migration,
    /ADD KEY `idx_session_control_requester_pending`\s*\(`requested_by_instance_id`, `state`, `created_at`, `request_id`\)/u,
  );
  assert.match(
    migration,
    /ADD KEY `idx_cluster_leases_owner_expiry`\s*\(`owner_id`, `expires_at`, `lease_name`\)/u,
  );
  assert.match(migration, /`lease_domain_kind` VARCHAR\(20\)[\s\S]*?GENERATED ALWAYS AS/u);
  assert.match(
    migration,
    /ADD KEY `idx_cluster_leases_domain_expiry`\s*\(`lease_domain_kind`, `expires_at`, `lease_name`\)/u,
  );
  assert.match(migration, /ADD COLUMN `archive_recorded_at` DATETIME\(6\) NULL/u);
  assert.match(
    migration,
    /ADD KEY `idx_audit_log_archive_queue`\s*\(`archive_recorded_at`, `occurred_at`, `id`\)/u,
  );
  assert.equal((migration.match(/DROP PROCEDURE IF EXISTS/gu) ?? []).length, 2);
  assert.equal((migration.match(/CREATE PROCEDURE/gu) ?? []).length, 1);
  assert.equal((migration.match(/CALL `synex_migrate_017_runtime_scalability`\(\)/gu) ?? []).length, 1);
});

test('character slot reuse keeps uniqueness only for active characters', async () => {
  const migration = await readFile(
    path.join(repositoryRoot, 'core', 'synex_core', 'migrations', '018_character_slot_reuse.sql'),
    'utf8',
  );
  assert.match(
    migration,
    /ADD COLUMN `active_slot_marker` TINYINT UNSIGNED\s+GENERATED ALWAYS AS\s*\(\s*CASE WHEN `deleted_at` IS NULL THEN 1 ELSE NULL END\s*\) STORED/u,
  );
  assert.match(migration, /`DATA_TYPE`\) = 'tinyint'/u);
  assert.match(migration, /LOCATE\('unsigned', LOWER\(`COLUMN_TYPE`\)\) > 0/u);
  assert.match(migration, /`IS_NULLABLE` = 'YES'/u);
  assert.match(migration, /UPPER\(`EXTRA`\) LIKE '%STORED GENERATED%'/u);
  assert.match(migration, /`GENERATION_EXPRESSION`[\s\S]*?'casewhendeleted_atisnullthen1elsenullend'/u);
  assert.match(
    migration,
    /MESSAGE_TEXT = 'synex migration 018 active slot marker definition verification failed'/u,
  );
  assert.match(
    migration,
    /ADD UNIQUE KEY `uq_characters_user_slot_active`\s*\(`user_id`, `slot`, `active_slot_marker`\)/u,
  );
  assert.match(migration, /DROP INDEX `uq_characters_user_slot`/u);
  assert.ok(
    migration.indexOf('ADD UNIQUE KEY `uq_characters_user_slot_active`')
      < migration.indexOf('DROP INDEX `uq_characters_user_slot`'),
    'the replacement unique key must exist before the legacy key is removed',
  );
  assert.ok(
    migration.indexOf('active slot marker definition verification failed')
      < migration.indexOf('ADD UNIQUE KEY `uq_characters_user_slot_active`'),
    'the generated marker definition must be verified before the replacement key is created',
  );
  assert.ok(
    migration.indexOf('active character slot uniqueness verification failed')
      < migration.indexOf('DROP INDEX `uq_characters_user_slot`'),
    'the exact replacement key must be verified before the legacy key is removed',
  );
  assert.equal((migration.match(/DROP PROCEDURE IF EXISTS/gu) ?? []).length, 2);
  assert.equal((migration.match(/CREATE PROCEDURE/gu) ?? []).length, 1);
  assert.equal((migration.match(/CALL `synex_migrate_018_character_slot_reuse`\(\)/gu) ?? []).length, 1);
});

test('session control target authority is backfilled and exposes bounded target and cursor indexes', async () => {
  const migration = await readFile(
    path.join(
      repositoryRoot,
      'core',
      'synex_core',
      'migrations',
      '019_session_control_target_authority.sql',
    ),
    'utf8',
  );
  assert.match(
    migration,
    /ADD COLUMN `target_instance_id` CHAR\(36\)[\s\S]*?CHARACTER SET ascii COLLATE ascii_bin NULL/u,
  );
  assert.match(
    migration,
    /UPDATE `synex_session_control_requests` AS `request`[\s\S]*?INNER JOIN `synex_sessions` AS `session`[\s\S]*?SET `request`.`target_instance_id` = `session`.`server_instance_id`/u,
  );
  assert.match(migration, /WHERE `target_instance_id` IS NULL[\s\S]*?SIGNAL SQLSTATE '45000'/u);
  assert.match(
    migration,
    /MODIFY COLUMN `target_instance_id` CHAR\(36\)[\s\S]*?CHARACTER SET ascii COLLATE ascii_bin NOT NULL/u,
  );
  assert.match(
    migration,
    /ADD KEY `idx_session_control_target_pending`\s*\(`target_instance_id`, `state`, `expires_at`, `created_at`, `request_id`\)/u,
  );
  assert.match(
    migration,
    /ADD KEY `idx_session_control_state_scan`\s*\(`state`, `request_id`\)/u,
  );
  assert.ok(
    migration.indexOf('could not backfill target instance authority')
      < migration.indexOf('MODIFY COLUMN `target_instance_id`'),
    'the backfill must be complete before target authority becomes mandatory',
  );
  assert.equal((migration.match(/DROP PROCEDURE IF EXISTS/gu) ?? []).length, 2);
  assert.equal((migration.match(/CREATE PROCEDURE/gu) ?? []).length, 1);
  assert.equal((migration.match(
    /CALL `synex_migrate_019_session_control_target_authority`\(\)/gu,
  ) ?? []).length, 1);
});

test('core cluster and RBAC migrations are manifest-owned and encode bounded authority', async () => {
  const coreDirectory = path.join(repositoryRoot, 'core', 'synex_core');
  const manifest = JSON.parse(await readFile(path.join(coreDirectory, 'synex.resource.json'), 'utf8')) as ResourceManifest;
  const migrations = (await loadMigrations()).filter((migration) =>
    migration.directory === 'core/synex_core/migrations'
  );
  assert.deepEqual(
    manifest.migrations.map((migration) => migration.path),
    migrations.map((migration) => `migrations/${migration.file}`),
  );
  assert.ok(manifest.migrations.every((migration) => migration.transactional === false));
  const created = migrations.flatMap((migration) => createdTables(migration.contents)).sort();
  assert.deepEqual([...manifest.dataOwnership.tables].sort(), created);

  const cluster = await readFile(path.join(coreDirectory, 'migrations', '007_cluster_runtime.sql'), 'utf8');
  assert.match(cluster, /CREATE TABLE IF NOT EXISTS `synex_instances`/u);
  assert.match(cluster, /CHECK \(`status` IN \('starting', 'ready', 'degraded', 'stopping', 'stopped', 'stale'\)\)/u);
  assert.match(cluster, /UNIQUE KEY `uq_session_control_active` \(`target_session_id`, `action`, `active_marker`\)/u);
  assert.match(cluster, /FOREIGN KEY \(`target_session_id`\) REFERENCES `synex_sessions` \(`id`\)/u);

  const bootAuthority = await readFile(
    path.join(coreDirectory, 'migrations', '011_instance_boot_authority.sql'),
    'utf8',
  );
  assert.match(bootAuthority, /CREATE TABLE IF NOT EXISTS `synex_instance_boots`/u);
  assert.match(bootAuthority, /PRIMARY KEY \(`instance_id`\)/u);
  assert.match(bootAuthority, /UNIQUE KEY `uq_instance_boot_id` \(`boot_id`\)/u);
  assert.match(bootAuthority, /FOREIGN KEY \(`instance_id`\) REFERENCES `synex_instances` \(`instance_id`\)/u);

  const controlAuthority = await readFile(
    path.join(coreDirectory, 'migrations', '012_session_control_boot_authority.sql'),
    'utf8',
  );
  assert.match(controlAuthority, /CREATE TABLE IF NOT EXISTS `synex_session_control_authority`/u);
  assert.match(controlAuthority, /PRIMARY KEY \(`request_id`\)/u);
  assert.match(
    controlAuthority,
    /FOREIGN KEY \(`request_id`\) REFERENCES `synex_session_control_requests` \(`request_id`\)/u,
  );

  const rbac = await readFile(path.join(coreDirectory, 'migrations', '008_core_rbac.sql'), 'utf8');
  for (const table of [
    'synex_rbac_roles',
    'synex_rbac_role_permissions',
    'synex_rbac_subject_roles',
    'synex_rbac_subject_versions',
  ]) assert.match(rbac, new RegExp('CREATE TABLE IF NOT EXISTS `' + table + '`', 'u'));
  assert.match(rbac, /CHECK \(`effect` IN \('allow', 'deny'\)\)/u);
  assert.match(rbac, /ON DELETE RESTRICT/u);

  const policyRevision = await readFile(
    path.join(coreDirectory, 'migrations', '016_rbac_policy_revision.sql'),
    'utf8',
  );
  assert.match(policyRevision, /CREATE TABLE IF NOT EXISTS `synex_rbac_policy_revisions`/u);
  assert.match(policyRevision, /PRIMARY KEY \(`singleton_id`\)/u);
  assert.match(policyRevision, /CHECK \(`singleton_id` = 1\)/u);
  assert.match(policyRevision, /CHECK \(`revision` > 0\)/u);
  assert.match(policyRevision, /VALUES \(1, 1\)/u);
  assert.match(
    policyRevision,
    /ON DUPLICATE KEY UPDATE `singleton_id` = VALUES\(`singleton_id`\)/u,
  );
  assert.doesNotMatch(policyRevision, /UPDATE `synex_rbac_policy_revisions` SET `revision` = 1/u);
});
