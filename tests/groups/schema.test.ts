import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFile, readdir } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';

const root = process.cwd();
const migrationDirectory = path.join(root, 'resources', 'synex_groups', 'migrations');
const additiveMigrationFiles = [
  '004_organization_types_graph.sql',
  '005_roles_policies_attributes.sql',
  '006_membership_workflows.sql',
  '007_audit_definitions_retention.sql',
  '008_public_id_compatibility.sql',
  '009_contract_storage_compatibility.sql',
  '010_external_resource_ownership.sql',
  '011_mutation_entity_public_ids.sql',
  '012_group_history_scope.sql',
  '013_contract_text_bounds.sql',
  '014_character_anonymization_ids.sql',
  '015_primary_membership_public_ids.sql',
  '017_static_definition_targets.sql',
  '018_default_membership_capabilities.sql',
  '019_definition_applied_snapshots.sql',
  '020_capability_delegability.sql',
  '021_persistent_extension_registries.sql',
  '022_workflow_lifecycle_expiry.sql',
  '023_dynamic_type_creation_policies.sql',
  '024_group_deletion_lifecycle.sql',
  '025_dynamic_group_creation_approvals.sql',
  '026_group_attribute_scopes.sql',
  '027_identifier_contract_consistency.sql',
  '028_membership_transition_policies.sql',
  '029_assignment_member_active_counts.sql',
  '030_membership_workflow_entities.sql',
  '031_registry_owner_sync_sessions.sql',
] as const;

const hardenedProcedureMigrations = new Set<string>([
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
  '024_group_deletion_lifecycle.sql',
  '025_dynamic_group_creation_approvals.sql',
  '026_group_attribute_scopes.sql',
  '027_identifier_contract_consistency.sql',
  '028_membership_transition_policies.sql',
  '029_assignment_member_active_counts.sql',
  '030_membership_workflow_entities.sql',
]);

const immutableMigrationDigests = new Map<string, string>([
  ['001_groups.sql', '370cf6167c0dbac0dfca1ac3e4847acfbf996e0b569446bad216d56365bd72bb'],
  ['002_grades_primary_read_models.sql', 'd137e74023ad40508256bc7d7c254383293cbf2ecbb69f23f5b2696417f08bcb'],
  ['003_character_lifecycle.sql', 'd4da16f33be25e4c909dadbdc240ecd120bc3327a356ed9651c34c2b14ad57fd'],
]);

async function readMigration(file: string): Promise<string> {
  return readFile(path.join(migrationDirectory, file), 'utf8');
}

function splitMigration(contents: string): string[] {
  return contents
    .split(/^-- synex:statement\s*$/mu)
    .map((statement) => statement.trim())
    .filter((statement) => statement.length > 0);
}

function createdTables(contents: string): string[] {
  return [...contents.matchAll(/CREATE TABLE IF NOT EXISTS `([a-z0-9_]+)`/gu)]
    .map((match) => match[1] ?? '');
}

function tableBody(contents: string, table: string): string {
  const match = contents.match(new RegExp(
    'CREATE TABLE IF NOT EXISTS `' + table + '` \\(([\\s\\S]*?)\\n\\) ENGINE=InnoDB',
    'u',
  ));
  assert.ok(match?.[1], `missing table body for ${table}`);
  return match[1];
}

function tableAlterations(contents: string, table: string): string {
  const escaped = table.replace(/[.*+?^${}()|[\]\\]/gu, '\\$&');
  return [...contents.matchAll(new RegExp('ALTER TABLE `' + escaped + '`([\\s\\S]*?);', 'gu'))]
    .map((match) => match[0] ?? '')
    .join('\n');
}

test('legacy group migrations remain byte-for-byte immutable', async () => {
  for (const [file, expectedDigest] of immutableMigrationDigests) {
    const bytes = await readFile(path.join(migrationDirectory, file));
    const actualDigest = createHash('sha256').update(bytes).digest('hex');
    assert.equal(actualDigest, expectedDigest, `${file} changed after publication`);
  }
});

test('organization engine migrations are additive, ordered, and core-runner compatible', async () => {
  const files = (await readdir(migrationDirectory))
    .filter((file) => /^(?:00[4-9]|01[0-57-9]|02[0-9]|03[01])_[a-z0-9_]+\.sql$/u.test(file))
    .sort((left, right) => left.localeCompare(right, 'en'));
  assert.deepEqual(files, additiveMigrationFiles);

  const constraintNames = new Set<string>();
  for (const file of files) {
    const contents = await readMigration(file);
    assert.equal(contents.includes('\r'), false, `${file} must use LF line endings`);
    assert.doesNotMatch(contents, /\b(?:DROP\s+(?:TABLE|COLUMN|INDEX|KEY)|TRUNCATE)\b/iu, `${file} must preserve data`);
    if (!new Set([
      '010_external_resource_ownership.sql',
      '014_character_anonymization_ids.sql',
      '022_workflow_lifecycle_expiry.sql',
      '024_group_deletion_lifecycle.sql',
      '025_dynamic_group_creation_approvals.sql',
      '026_group_attribute_scopes.sql',
      '027_identifier_contract_consistency.sql',
      '030_membership_workflow_entities.sql',
    ]).has(file)) {
      assert.doesNotMatch(contents, /\bDROP\s+(?:CHECK|CONSTRAINT)\b/iu, `${file} replaces an existing guard`);
    }
    assert.doesNotMatch(contents, /\b(?:CHAR|VARCHAR)\(36\)/iu, `${file} narrows a Core identifier`);

    const statements = splitMigration(contents);
    assert.ok(statements.length > 0, `${file} contains no statements`);
    if (hardenedProcedureMigrations.has(file)) {
      if (file === '024_group_deletion_lifecycle.sql') {
        assert.equal(statements.length, 9, file);
        assert.equal(statements[0], 'DROP PROCEDURE IF EXISTS `synex_groups_migrate_024_group_deletion_lifecycle`;');
        assert.match(statements[1] ?? '', /^CREATE PROCEDURE `synex_groups_migrate_024_group_deletion_lifecycle`\(\)/u);
        assert.equal(statements[2], 'CALL `synex_groups_migrate_024_group_deletion_lifecycle`();');
        assert.equal(statements[3], 'DROP PROCEDURE IF EXISTS `synex_groups_migrate_024_group_deletion_lifecycle`;');
        assert.match(statements[4] ?? '', /^CREATE TABLE IF NOT EXISTS `synex_group_deletion_requests`/u);
        assert.equal(statements[5], 'DROP PROCEDURE IF EXISTS `synex_groups_verify_024_group_deletion_lifecycle`;');
        assert.match(statements[6] ?? '', /^CREATE PROCEDURE `synex_groups_verify_024_group_deletion_lifecycle`\(\)/u);
        assert.equal(statements[7], 'CALL `synex_groups_verify_024_group_deletion_lifecycle`();');
        assert.equal(statements[8], 'DROP PROCEDURE IF EXISTS `synex_groups_verify_024_group_deletion_lifecycle`;');
        continue;
      }
      if (file === '025_dynamic_group_creation_approvals.sql') {
        assert.equal(statements.length, 13, file);
        assert.equal(statements[0], 'DROP PROCEDURE IF EXISTS `synex_groups_migrate_025_creation_policy`;');
        assert.match(statements[1] ?? '', /^CREATE PROCEDURE `synex_groups_migrate_025_creation_policy`\(\)/u);
        assert.equal(statements[2], 'CALL `synex_groups_migrate_025_creation_policy`();');
        assert.equal(statements[3], 'DROP PROCEDURE IF EXISTS `synex_groups_migrate_025_creation_policy`;');
        assert.match(statements[4] ?? '', /^CREATE TABLE IF NOT EXISTS `synex_group_creation_requests`/u);
        assert.match(statements[5] ?? '', /^CREATE TABLE IF NOT EXISTS `synex_group_creation_approvals`/u);
        assert.match(statements[6] ?? '', /^CREATE TABLE IF NOT EXISTS `synex_group_slug_reservations`/u);
        assert.match(statements[7] ?? '', /^INSERT IGNORE INTO `synex_group_slug_reservations`/u);
        assert.match(statements[8] ?? '', /^INSERT IGNORE INTO `synex_group_slug_reservations`/u);
        assert.equal(statements[9], 'DROP PROCEDURE IF EXISTS `synex_groups_verify_025_creation_approvals`;');
        assert.match(statements[10] ?? '', /^CREATE PROCEDURE `synex_groups_verify_025_creation_approvals`\(\)/u);
        assert.equal(statements[11], 'CALL `synex_groups_verify_025_creation_approvals`();');
        assert.equal(statements[12], 'DROP PROCEDURE IF EXISTS `synex_groups_verify_025_creation_approvals`;');
        continue;
      }
      if (file === '026_group_attribute_scopes.sql') {
        assert.equal(statements.length, 8, file);
        assert.equal(statements[0], 'DROP PROCEDURE IF EXISTS `synex_groups_migrate_026_group_attribute_scopes`;');
        assert.match(statements[1] ?? '', /^CREATE PROCEDURE `synex_groups_migrate_026_group_attribute_scopes`\(\)/u);
        assert.equal(statements[2], 'CALL `synex_groups_migrate_026_group_attribute_scopes`();');
        assert.equal(statements[3], 'DROP PROCEDURE IF EXISTS `synex_groups_migrate_026_group_attribute_scopes`;');
        assert.equal(statements[4], 'DROP PROCEDURE IF EXISTS `synex_groups_verify_026_group_attribute_scopes`;');
        assert.match(statements[5] ?? '', /^CREATE PROCEDURE `synex_groups_verify_026_group_attribute_scopes`\(\)/u);
        assert.equal(statements[6], 'CALL `synex_groups_verify_026_group_attribute_scopes`();');
        assert.equal(statements[7], 'DROP PROCEDURE IF EXISTS `synex_groups_verify_026_group_attribute_scopes`;');
        continue;
      }
      if (file === '028_membership_transition_policies.sql') {
        assert.equal(statements.length, 5, file);
        assert.match(statements[0] ?? '',
          /^CREATE TABLE IF NOT EXISTS `synex_group_membership_transition_policies`/u);
        assert.equal(statements[1],
          'DROP PROCEDURE IF EXISTS `synex_groups_verify_028_membership_transition_policies`;');
        assert.match(statements[2] ?? '',
          /^CREATE PROCEDURE `synex_groups_verify_028_membership_transition_policies`\(\)/u);
        assert.equal(statements[3],
          'CALL `synex_groups_verify_028_membership_transition_policies`();');
        assert.equal(statements[4],
          'DROP PROCEDURE IF EXISTS `synex_groups_verify_028_membership_transition_policies`;');
        continue;
      }
      const procedureOffset = file === '009_contract_storage_compatibility.sql'
        ? 4
        : file === '023_dynamic_type_creation_policies.sql' ? 2 : 0;
      const procedureName = `synex_groups_migrate_${file.slice(0, -'.sql'.length)}`;
      assert.equal(statements.length, procedureOffset + 4, file);
      assert.ok(statements.slice(0, procedureOffset).every(
        (statement) => statement.startsWith('CREATE TABLE IF NOT EXISTS'),
      ));
      assert.equal(statements[procedureOffset], `DROP PROCEDURE IF EXISTS \`${procedureName}\`;`);
      assert.match(statements[procedureOffset + 1] ?? '', new RegExp(
        '^CREATE PROCEDURE `' + procedureName + '`\\(\\)', 'u',
      ));
      assert.match(statements[procedureOffset + 1] ?? '', /`information_schema`\.`(?:TABLES|COLUMNS|STATISTICS|TABLE_CONSTRAINTS)`/u);
      assert.match(statements[procedureOffset + 1] ?? '', /SIGNAL SQLSTATE '45000'/u);
      assert.equal(statements[procedureOffset + 2], `CALL \`${procedureName}\`();`);
      assert.equal(statements[procedureOffset + 3], `DROP PROCEDURE IF EXISTS \`${procedureName}\`;`);
    } else {
    for (const statement of statements) {
      assert.match(
        statement,
        /^(?:ALTER TABLE `[a-z0-9_]+`|CREATE TABLE IF NOT EXISTS `[a-z0-9_]+`|INSERT INTO `[a-z0-9_]+`|UPDATE `[a-z0-9_]+`)/u,
        `${file} contains an unsupported statement`,
      );
      assert.doesNotMatch(statement, /^(?:DELETE|REPLACE)\b/iu, `${file} destructively mutates an existing row`);
      if (statement.startsWith('UPDATE')) {
        assert.match(statement, /\bWHERE\b/u, `${file} contains an unbounded backfill`);
      }
      if (statement.startsWith('CREATE TABLE IF NOT EXISTS')) {
        assert.match(statement, /ENGINE=InnoDB/u, `${file} contains a non-InnoDB table`);
      }
    }
    }

    for (const match of contents.matchAll(/CONSTRAINT `([^`]+)`/gu)) {
      const constraint = match[1] ?? '';
      assert.ok(constraint.length <= 64, `${constraint} exceeds the server identifier limit`);
      assert.equal(
        constraintNames.has(constraint)
          && !new Set([
            '010_external_resource_ownership.sql',
            '014_character_anonymization_ids.sql',
            '015_primary_membership_public_ids.sql',
            '022_workflow_lifecycle_expiry.sql',
            '027_identifier_contract_consistency.sql',
          ]).has(file),
        false,
        `${constraint} is not schema-unique`,
      );
      constraintNames.add(constraint);
    }
    for (const match of contents.matchAll(/FOREIGN KEY \([^)]*\)\s+REFERENCES [^\n]+ ON DELETE ([A-Z]+)/gu)) {
      assert.equal(match[1], 'RESTRICT', `${file} has cascading domain ownership`);
    }
  }
});

test('migration 030 binds every invitation and application to one durable membership', async () => {
  const sql = await readMigration('030_membership_workflow_entities.sql');
  assert.match(sql, /ALTER TABLE `synex_group_invitations`[\s\S]*?ADD COLUMN `membership_id` BIGINT UNSIGNED NULL/u);
  assert.match(sql, /ALTER TABLE `synex_group_applications`[\s\S]*?ADD COLUMN `membership_id` BIGINT UNSIGNED NULL/u);
  assert.match(sql, /INSERT INTO `synex_group_memberships`[\s\S]*?subject_kind[\s\S]*?'character'/u);
  assert.match(sql, /'UNDER_REVIEW'[\s\S]*?'APPLICANT'[\s\S]*?'INVITED'[\s\S]*?ELSE 'DRAFT'/u);
  assert.match(sql, /'hidden', NULL, NULL, NULL, 'workflow_entity_migrated'/u);
  assert.match(sql, /MODIFY COLUMN `membership_id` BIGINT UNSIGNED NOT NULL/gu);
  assert.match(sql, /fk_group_invitations_membership[\s\S]*?ON DELETE RESTRICT/u);
  assert.match(sql, /fk_group_applications_membership[\s\S]*?ON DELETE RESTRICT/u);
  assert.match(sql, /IF NOT EXISTS[\s\S]*?chk_group_membership_events_type_v2[\s\S]*?ADD CONSTRAINT `chk_group_membership_events_type_v2`/u);
  assert.match(sql, /'transitioned', 'grade_changed', 'visibility_changed'/u);
  assert.match(sql, /workflow entity verification failed/u);
});

test('definition snapshot verification compares digests without connection-collation coercion', async () => {
  const migration = await readFile(
    path.join(migrationDirectory, '019_definition_applied_snapshots.sql'),
    'utf8',
  );
  assert.match(
    migration,
    /CAST\(LOWER\(SHA2\(`applied_definition_json`, 256\)\) AS BINARY\)\s*<>\s*CAST\(`applied_digest` AS BINARY\)/u,
  );
});

test('application lifecycle expiry is indexed, terminal, and replay verified', async () => {
  const sql = await readMigration('022_workflow_lifecycle_expiry.sql');
  assert.match(sql, /ADD COLUMN `expires_at` DATETIME\(6\) NULL/u);
  assert.match(sql, /TIMESTAMPADD\(DAY, 30, `created_at`\)/u);
  assert.match(sql, /MODIFY COLUMN `expires_at` DATETIME\(6\) NOT NULL/u);
  assert.match(sql, /CHECK \(`status` IN \([\s\S]*?'expired'[\s\S]*?\)\)/u);
  assert.match(sql, /`status` = 'expired'[\s\S]*?`reviewed_at` IS NOT NULL/u);
  assert.match(sql, /idx_group_applications_expiry` \(`status`, `expires_at`, `id`\)/u);
  assert.match(sql, /`SEQ_IN_INDEX` = 2 AND `COLUMN_NAME` = 'expires_at'/u);
  assert.match(sql, /`SEQ_IN_INDEX` = 3 AND `COLUMN_NAME` = 'id'/u);
  assert.match(sql, /workflow lifecycle verification failed/u);
});

test('dynamic creation policy migration keeps both nullable member limits at the 100000 boundary', async () => {
  const sql = await readMigration('023_dynamic_type_creation_policies.sql');
  assert.match(sql, /MODIFY COLUMN `membership_limit` INT UNSIGNED NULL/u);
  assert.match(sql, /ADD COLUMN `active_membership_limit` INT UNSIGNED NULL/u);
  assert.match(sql, /`membership_limit` NOT BETWEEN 1 AND 100000/u);
  assert.match(sql, /`active_membership_limit` BETWEEN 1 AND 100000/u);
  assert.match(sql, /`active_membership_limit` <= `membership_limit`/u);
  assert.match(sql, /`COLUMN_NAME` = 'membership_limit'[\s\S]*?`DATA_TYPE` = 'int'/u);
});

test('dynamic group creation approvals align slug storage and enforce durable quorum state', async () => {
  const sql = await readMigration('025_dynamic_group_creation_approvals.sql');
  assert.match(sql, /DROP CONSTRAINT `chk_groups_key`/u);
  assert.match(sql, /ADD CONSTRAINT `chk_groups_key`\s+CHECK \(`group_key` REGEXP '\^\[a-z\]\[a-z0-9_-\]\{1,63\}\$'\)/u);
  assert.match(sql, /`required_approvals` TINYINT UNSIGNED NOT NULL DEFAULT 0/u);
  assert.match(sql, /CHECK \(`required_approvals` <= 32\)/u);
  assert.match(sql, /`approval_permission`[\s\S]*?CHARACTER SET ascii COLLATE ascii_bin NOT NULL/u);
  assert.match(sql, /UNIQUE KEY `uq_group_creation_requests_idempotency`\s*\(`requested_by_ref`, `idempotency_key`\)/u);
  assert.match(sql, /UNIQUE KEY `uq_group_creation_requests_active_slug` \(`active_slug`\)/u);
  assert.match(sql, /CASE WHEN `status` IN \('pending', 'approved'\) THEN `requested_slug` ELSE NULL END/u);
  assert.match(sql, /UNIQUE KEY `uq_group_creation_approvals_actor`\s*\(`creation_request_id`, `approver_character_ref`\)/u);
  assert.match(sql, /CREATE TABLE IF NOT EXISTS `synex_group_slug_reservations`/u);
  assert.match(sql, /PRIMARY KEY \(`slug`\)/u);
  assert.match(sql, /CHECK \(`owner_kind` IN \('group', 'creation_request'\)\)/u);
  assert.match(sql, /INSERT IGNORE INTO `synex_group_slug_reservations`[\s\S]*?FROM `synex_groups`/u);
  assert.match(sql, /INSERT IGNORE INTO `synex_group_slug_reservations`[\s\S]*?FROM `synex_group_creation_requests`/u);
  assert.match(sql, /CHECK \(`status` IN \('pending', 'approved', 'executed', 'rejected', 'expired'\)\)/u);
  assert.match(sql, /synex groups migration 025 approval schema verification failed/u);

  const slug = /^[a-z][a-z0-9_-]{1,63}$/u;
  for (const accepted of ['ab', 'a-b', 'a_b', `a${'b'.repeat(63)}`]) {
    assert.equal(slug.test(accepted), true, accepted);
  }
  for (const rejected of ['a', '-ab', '_ab', 'a.b', 'A-b', `a${'b'.repeat(64)}`]) {
    assert.equal(slug.test(rejected), false, rejected);
  }
});

test('identifier storage accepts every key admitted by the public contract boundary', async () => {
  const sql = await readMigration('027_identifier_contract_consistency.sql');
  for (const table of [
    'synex_groups',
    'synex_group_memberships',
    'synex_group_grades',
  ]) {
    assert.match(sql, new RegExp(
      'ALTER TABLE `' + table + '`[\\s\\S]*?MODIFY COLUMN `[a-z_]+' +
      '`\\s+VARCHAR\\(64\\) CHARACTER SET ascii COLLATE ascii_bin NOT NULL',
      'u',
    ), table);
  }
  for (const constraint of [
    'chk_groups_type',
    'chk_group_memberships_role_key',
    'chk_group_grades_key',
    'chk_group_types_key',
    'chk_group_relation_types_key',
    'chk_group_roles_key',
  ]) {
    assert.match(sql, new RegExp(
      'ADD CONSTRAINT `' + constraint + '`\\s+CHECK \\(.*?REGEXP ' +
      "'\\^\\[a-z\\]\\[a-z0-9_-\\]\\{1,63\\}\\$'\\)",
      'u',
    ), constraint);
  }
  assert.match(sql, /identifier contract verification failed/u);

  const key = /^[a-z][a-z0-9_-]{1,63}$/u;
  for (const accepted of ['ab', 'a-b', 'a_b', `a${'b'.repeat(63)}`]) {
    assert.equal(key.test(accepted), true, accepted);
  }
  for (const rejected of ['a', '-ab', '_ab', 'a.b', 'A-b', `a${'b'.repeat(64)}`]) {
    assert.equal(key.test(rejected), false, rejected);
  }
});

test('migration sequence creates the normalized organization ownership model', async () => {
  const expectedTables = new Map<string, string[]>([
    ['004_organization_types_graph.sql', [
      'synex_group_types',
      'synex_group_organization_profiles',
      'synex_group_hierarchy_edges',
      'synex_group_hierarchy_closure',
      'synex_group_relation_types',
      'synex_group_relationships',
    ]],
    ['005_roles_policies_attributes.sql', [
      'synex_group_roles',
      'synex_group_role_capabilities',
      'synex_group_grade_capability_scopes',
      'synex_group_grade_controls',
      'synex_group_membership_roles',
      'synex_group_policies',
      'synex_group_policy_rules',
      'synex_group_attribute_schemas',
      'synex_group_membership_attributes',
    ]],
    ['006_membership_workflows.sql', [
      'synex_group_primary_memberships_by_type',
      'synex_group_membership_profiles',
      'synex_group_reporting_edges',
      'synex_group_reporting_closure',
      'synex_group_invitations',
      'synex_group_applications',
      'synex_group_duty_states',
      'synex_group_duty_sessions',
      'synex_group_duty_events',
      'synex_group_assignments',
      'synex_group_assignment_members',
      'synex_group_delegations',
      'synex_group_proposals',
      'synex_group_approvals',
    ]],
    ['007_audit_definitions_retention.sql', [
      'synex_group_command_receipts',
      'synex_group_domain_history',
      'synex_group_audit_delivery',
      'synex_group_definition_sets',
      'synex_group_definition_migrations',
      'synex_group_definition_issues',
      'synex_group_retention_policies',
      'synex_group_retention_checkpoints',
      'synex_group_domain_history_archive',
    ]],
    ['008_public_id_compatibility.sql', []],
    ['009_contract_storage_compatibility.sql', [
      'synex_group_membership_states',
      'synex_group_type_membership_states',
      'synex_group_type_duty_states',
      'synex_group_invitation_roles',
    ]],
    ['010_external_resource_ownership.sql', []],
    ['011_mutation_entity_public_ids.sql', []],
    ['012_group_history_scope.sql', []],
    ['013_contract_text_bounds.sql', []],
    ['014_character_anonymization_ids.sql', []],
    ['015_primary_membership_public_ids.sql', []],
    ['017_static_definition_targets.sql', []],
    ['018_default_membership_capabilities.sql', [
      'synex_group_default_capabilities',
      'synex_group_membership_capabilities',
    ]],
    ['019_definition_applied_snapshots.sql', []],
    ['020_capability_delegability.sql', []],
    ['021_persistent_extension_registries.sql', []],
    ['022_workflow_lifecycle_expiry.sql', []],
    ['023_dynamic_type_creation_policies.sql', [
      'synex_group_type_default_grades',
      'synex_group_type_default_roles',
    ]],
    ['024_group_deletion_lifecycle.sql', [
      'synex_group_deletion_requests',
    ]],
    ['025_dynamic_group_creation_approvals.sql', [
      'synex_group_creation_requests',
      'synex_group_creation_approvals',
      'synex_group_slug_reservations',
    ]],
    ['026_group_attribute_scopes.sql', []],
    ['027_identifier_contract_consistency.sql', []],
    ['028_membership_transition_policies.sql', [
      'synex_group_membership_transition_policies',
    ]],
    ['029_assignment_member_active_counts.sql', []],
    ['030_membership_workflow_entities.sql', []],
  ]);

  for (const [file, tables] of expectedTables) {
    assert.deepEqual(createdTables(await readMigration(file)), tables, file);
  }

  const allSql = (await Promise.all(additiveMigrationFiles.map(readMigration))).join('\n');
  assert.doesNotMatch(allSql, /`(?:members|roles|grades|permissions|capabilities)_json`/u);
  assert.match(allSql, /CREATE TABLE IF NOT EXISTS `synex_group_hierarchy_edges`/u);
  assert.match(allSql, /CREATE TABLE IF NOT EXISTS `synex_group_reporting_edges`/u);
  assert.match(allSql, /CREATE TABLE IF NOT EXISTS `synex_group_role_capabilities`/u);
  assert.match(allSql, /CREATE TABLE IF NOT EXISTS `synex_group_policy_rules`/u);
});

test('contract persistence fields have explicit relational or scalar storage', async () => {
  const contracts = JSON.parse(await readFile(
    path.join(root, 'resources', 'synex_groups', 'groups.contracts.json'),
    'utf8',
  )) as { contracts: Array<{ name: string; input: { properties: Record<string, unknown> } }> };
  const allSql = (await Promise.all(additiveMigrationFiles.map(readMigration))).join('\n');
  const mappings: Array<[string, string, RegExp]> = [
    ['synex.groups.create', 'type', /`group_type_id` BIGINT UNSIGNED NOT NULL/u],
    ['synex.groups.create', 'parent_group_id', /CREATE TABLE IF NOT EXISTS `synex_group_hierarchy_edges`/u],
    ['synex.groups.create', 'slug', /`slug` VARCHAR\(64\) CHARACTER SET ascii/u],
    ['synex.groups.create', 'name', /ADD COLUMN `name` VARCHAR\(96\)/u],
    ['synex.groups.create', 'label', /ADD COLUMN `label` VARCHAR\(96\)/u],
    ['synex.groups.create', 'description', /ADD COLUMN `description` VARCHAR\(1024\)/u],
    ['synex.groups.create', 'visibility', /`visibility` VARCHAR\(16\)/u],
    ['synex.groups.create', 'dynamic', /ADD COLUMN `dynamic` TINYINT UNSIGNED/u],
    ['synex.groups.create', 'metadata', /chk_group_profiles_metadata_json/u],
    ['synex.groups.types.register', 'type', /`type_key` VARCHAR\(64\)/u],
    ['synex.groups.types.register', 'schema_version', /chk_group_types_schema_version/u],
    ['synex.groups.types.register', 'label', /`display_name` VARCHAR\(96\)/u],
    ['synex.groups.types.register', 'dynamic_creation', /`dynamic_creation` TINYINT UNSIGNED/u],
    ['synex.groups.types.register', 'max_members', /`membership_limit` BETWEEN 1 AND 100000/u],
    ['synex.groups.types.register', 'max_active_members', /`active_membership_limit` BETWEEN 1 AND 100000/u],
    ['synex.groups.types.register', 'create_permission', /`create_permission`[\s\S]*?VARCHAR\(96\)/u],
    ['synex.groups.types.register', 'required_approvals', /`required_approvals` TINYINT UNSIGNED/u],
    ['synex.groups.types.register', 'approval_permission', /`approval_permission`[\s\S]*?VARCHAR\(96\)/u],
    ['synex.groups.types.register', 'default_grades', /CREATE TABLE IF NOT EXISTS `synex_group_type_default_grades`/u],
    ['synex.groups.types.register', 'default_roles', /CREATE TABLE IF NOT EXISTS `synex_group_type_default_roles`/u],
    ['synex.groups.types.register', 'allowed_membership_states', /synex_group_type_membership_states/u],
    ['synex.groups.types.register', 'allowed_duty_states', /synex_group_type_duty_states/u],
    ['synex.groups.types.register', 'metadata', /chk_group_types_metadata_json/u],
    ['synex.groups.relation_types.register', 'type', /`type_key` VARCHAR\(64\)/u],
    ['synex.groups.relation_types.register', 'schema_version', /chk_group_relation_types_schema_version/u],
    ['synex.groups.relation_types.register', 'direction', /chk_group_relation_types_direction/u],
    ['synex.groups.duty_states.register', 'state', /`state_key` VARCHAR\(32\)/u],
    ['synex.groups.duty_states.register', 'schema_version', /chk_group_duty_states_schema_version/u],
    ['synex.groups.duty_states.register', 'counts_as_on_duty', /`counts_as_on_duty` TINYINT UNSIGNED/u],
    ['synex.groups.relationships.create', 'source_group_id', /`source_group_id` BIGINT UNSIGNED NOT NULL/u],
    ['synex.groups.relationships.create', 'target_group_id', /`target_group_id` BIGINT UNSIGNED NOT NULL/u],
    ['synex.groups.relationships.create', 'relation_type', /`relation_type_id` BIGINT UNSIGNED NOT NULL/u],
    ['synex.groups.relationships.create', 'valid_from', /`valid_from` DATETIME\(6\) NOT NULL/u],
    ['synex.groups.relationships.create', 'valid_until', /`valid_until` DATETIME\(6\) NULL/u],
    ['synex.groups.relationships.create', 'metadata', /chk_group_relationships_metadata_json/u],
    ['synex.groups.members.invite', 'group_id', /CREATE TABLE IF NOT EXISTS `synex_group_invitations`[\s\S]*?`group_id`/u],
    ['synex.groups.members.invite', 'character_id', /CREATE TABLE IF NOT EXISTS `synex_group_invitations`[\s\S]*?`character_id`/u],
    ['synex.groups.members.invite', 'grade_id', /CREATE TABLE IF NOT EXISTS `synex_group_invitations`[\s\S]*?`grade_id`/u],
    ['synex.groups.members.invite', 'role_ids', /CREATE TABLE IF NOT EXISTS `synex_group_invitation_roles`/u],
    ['synex.groups.members.invite', 'expires_at', /CREATE TABLE IF NOT EXISTS `synex_group_invitations`[\s\S]*?`expires_at`/u],
    ['synex.groups.members.invite', 'reason', /CREATE TABLE IF NOT EXISTS `synex_group_invitations`[\s\S]*?`reason_code`/u],
    ['synex.groups.applications.submit', 'group_id', /CREATE TABLE IF NOT EXISTS `synex_group_applications`[\s\S]*?`group_id`/u],
    ['synex.groups.applications.submit', 'schema_version', /chk_group_applications_schema_version/u],
    ['synex.groups.applications.submit', 'data', /`application_json` LONGTEXT NOT NULL/u],
    ['synex.groups.duty.start', 'membership_id', /CREATE TABLE IF NOT EXISTS `synex_group_duty_sessions`[\s\S]*?`membership_id`/u],
    ['synex.groups.duty.start', 'state', /CREATE TABLE IF NOT EXISTS `synex_group_duty_sessions`[\s\S]*?`state_key`/u],
    ['synex.groups.duty.start', 'assignment_id', /idx_group_duty_sessions_assignment/u],
    ['synex.groups.duty.start', 'metadata', /chk_group_duty_sessions_metadata_json/u],
    ['synex.groups.assignments.create', 'group_id', /CREATE TABLE IF NOT EXISTS `synex_group_assignments`[\s\S]*?`group_id`/u],
    ['synex.groups.assignments.create', 'parent_assignment_id', /fk_group_assignments_parent/u],
    ['synex.groups.assignments.create', 'name', /chk_group_assignments_name/u],
    ['synex.groups.assignments.create', 'type', /`assignment_type` VARCHAR\(64\)/u],
    ['synex.groups.assignments.create', 'starts_at', /`valid_from` DATETIME\(6\) NOT NULL/u],
    ['synex.groups.assignments.create', 'ends_at', /`valid_until` DATETIME\(6\) NULL/u],
    ['synex.groups.assignments.create', 'metadata', /chk_group_assignments_metadata_json/u],
    ['synex.groups.assignments.join', 'assignment_id', /CREATE TABLE IF NOT EXISTS `synex_group_assignment_members`[\s\S]*?`assignment_id`/u],
    ['synex.groups.assignments.join', 'membership_id', /CREATE TABLE IF NOT EXISTS `synex_group_assignment_members`[\s\S]*?`membership_id`/u],
    ['synex.groups.assignments.join', 'role', /`role_key` VARCHAR\(64\)/u],
    ['synex.groups.assignments.leave', 'assignment_member_id', /uq_group_assignment_members_public/u],
    ['synex.groups.attributes.register_schema', 'namespace', /`namespace` VARCHAR\(64\)/u],
    ['synex.groups.attributes.register_schema', 'key', /`attribute_key` VARCHAR\(64\)/u],
    ['synex.groups.attributes.register_schema', 'type', /`contract_type` VARCHAR\(64\)/u],
    ['synex.groups.attributes.register_schema', 'validation', /`validation_json` LONGTEXT NULL/u],
    ['synex.groups.attributes.register_schema', 'visibility', /CREATE TABLE IF NOT EXISTS `synex_group_attribute_schemas`[\s\S]*?`visibility`/u],
    ['synex.groups.attributes.register_schema', 'capability', /`capability` VARCHAR\(96\)/u],
    ['synex.groups.attributes.register_schema', 'schema_version', /chk_group_attribute_schemas_schema_version/u],
  ];

  assert.ok(mappings.length >= 45);
  const contractByName = new Map(contracts.contracts.map((contract) => [contract.name, contract]));
  for (const [contractName, field, storage] of mappings) {
    assert.ok(contractByName.get(contractName)?.input.properties[field], `${contractName}.${field} left the contract`);
    assert.match(allSql, storage, `${contractName}.${field} has no database mapping`);
  }
  assert.doesNotMatch(allSql, /`(?:role_ids|allowed_membership_states|allowed_duty_states)_json`/u);
});

test('external resource ownership accepts provider names and rejects injection-shaped names', async () => {
  const sql = await readMigration('010_external_resource_ownership.sql');
  const replacedConstraints = [
    'chk_group_types_owner',
    'chk_group_relation_types_owner',
    'chk_group_duty_states_owner',
    'chk_group_attribute_schemas_owner',
    'chk_group_membership_states_owner',
    'chk_group_definition_sets_owner',
    'chk_group_domain_history_source',
    'chk_group_history_archive_source',
  ];
  for (const constraint of replacedConstraints) {
    const column = constraint.includes('source') ? 'source_resource' : 'owner_resource';
    assert.ok(sql.includes(`DROP CONSTRAINT \`${constraint}\``), constraint);
    assert.match(
      sql,
      new RegExp('ADD CONSTRAINT `' + constraint + '`\\s+CHECK \\(`' + column
        + '` REGEXP \'\\^\\[A-Za-z0-9\\]\\[A-Za-z0-9_.-\\]\\{2,63\\}\\$\'\\)', 'u'),
      constraint,
    );
  }
  assert.doesNotMatch(sql, /\^synex_/u);

  const resourceName = /^[A-Za-z0-9][A-Za-z0-9_.-]{2,63}$/u;
  for (const accepted of ['synex_groups', 'acme.groups', 'ThirdParty-groups', 'vendor_resource.v2']) {
    assert.equal(resourceName.test(accepted), true, accepted);
  }
  for (const rejected of [
    'ab',
    '.hidden',
    '-switch',
    'white space',
    '../escape',
    'name/child',
    'name\\child',
    'name;DROP',
    "name'quote",
    'x'.repeat(65),
  ]) {
    assert.equal(resourceName.test(rejected), false, rejected);
  }
});

test('registry owner synchronization handshake is contract, manifest, and schema complete', async () => {
  const [sql, manifestSource, contractSource] = await Promise.all([
    readMigration('031_registry_owner_sync_sessions.sql'),
    readFile(path.join(root, 'resources', 'synex_groups', 'synex.resource.json'), 'utf8'),
    readFile(path.join(root, 'resources', 'synex_groups', 'groups.contracts.json'), 'utf8'),
  ]);
  const manifest = JSON.parse(manifestSource) as {
    migrations: Array<{ id: string; path: string; transactional: boolean }>;
    dataOwnership: { tables: string[] };
    contracts: { provide: string[] };
  };
  const catalog = JSON.parse(contractSource) as { contracts: Array<{
    name: string;
    network: string;
    capability: string;
    idempotent?: boolean;
    input: { required?: string[]; properties?: Record<string, unknown> };
    output: { required?: string[]; properties?: Record<string, unknown> };
  }> };
  const migration = manifest.migrations.find((entry) =>
    entry.id === '031_registry_owner_sync_sessions');
  assert.deepEqual(migration, {
    id: '031_registry_owner_sync_sessions',
    path: 'migrations/031_registry_owner_sync_sessions.sql',
    transactional: false,
  });
  assert.ok(manifest.dataOwnership.tables.includes('synex_group_registry_owner_syncs'));
  assert.ok(manifest.contracts.provide.includes('synex.groups.registries.begin'));

  const contract = catalog.contracts.find((entry) =>
    entry.name === 'synex.groups.registries.begin');
  assert.ok(contract);
  assert.equal(contract.network, 'none');
  assert.equal(contract.capability, 'synex.groups.registries.manage');
  assert.equal(contract.idempotent, true);
  assert.deepEqual(contract.input.required, ['idempotency_key']);
  assert.deepEqual(Object.keys(contract.input.properties ?? {}), ['idempotency_key']);
  assert.deepEqual(contract.output.required, [
    'owner_resource', 'owner_epoch', 'generation', 'status', 'replayed',
  ]);

  const table = tableBody(sql, 'synex_group_registry_owner_syncs');
  assert.match(table, /PRIMARY KEY \(`owner_resource`\)/u);
  assert.match(table, /`owner_epoch` BIGINT UNSIGNED NOT NULL/u);
  assert.match(table, /`begin_key` VARCHAR\(128\) CHARACTER SET ascii COLLATE ascii_bin NOT NULL/u);
  assert.match(table, /`generation` BIGINT UNSIGNED NOT NULL/u);
  assert.match(table, /`active` TINYINT\(1\) UNSIGNED NOT NULL DEFAULT 1/u);
  assert.match(table, /CHECK \(`active` IN \(0, 1\)\)/u);
});

test('every mutating contract resolves to an entity with a stable public identifier', async () => {
  const contractSource = JSON.parse(await readFile(
    path.join(root, 'resources', 'synex_groups', 'groups.contracts.json'),
    'utf8',
  )) as { contracts: Array<{ name: string; idempotent?: boolean }> };
  const migrationFiles = (await readdir(migrationDirectory))
    .filter((file) => /^\d{3}_[a-z0-9_]+\.sql$/u.test(file))
    .sort((left, right) => left.localeCompare(right, 'en'));
  const migrationContents = await Promise.all(migrationFiles.map(readMigration));
  const completeSql = migrationContents.join('\n');
  const mutationEntities = new Map<string, string[]>([
    ['synex.groups.create', ['synex_groups', 'synex_group_creation_requests']],
    ['synex.groups.update', ['synex_groups']],
    ['synex.groups.archive', ['synex_groups']],
    ['synex.groups.delete', ['synex_group_deletion_requests']],
    ['synex.groups.creation_requests.approve', ['synex_group_creation_approvals']],
    ['synex.groups.creation_requests.reject', ['synex_group_creation_approvals']],
    ['synex.groups.types.register', ['synex_group_types']],
    ['synex.groups.relation_types.register', ['synex_group_relation_types']],
    ['synex.groups.duty_states.register', ['synex_group_duty_states']],
    ['synex.groups.relationships.create', ['synex_group_relationships']],
    ['synex.groups.relationships.update', ['synex_group_relationships']],
    ['synex.groups.members.invite', ['synex_group_invitations']],
    ['synex.groups.members.accept', ['synex_group_invitations', 'synex_group_memberships']],
    ['synex.groups.members.decline', ['synex_group_invitations']],
    ['synex.groups.members.revoke_invite', ['synex_group_invitations']],
    ['synex.groups.members.transition', ['synex_group_memberships']],
    ['synex.groups.members.transition_policy.set', [
      'synex_group_membership_transition_policies',
    ]],
    ['synex.groups.members.set_grade', ['synex_group_memberships']],
    ['synex.groups.members.set_visibility', ['synex_group_memberships']],
    ['synex.groups.members.set_primary', ['synex_group_memberships']],
    ['synex.groups.compatibility.set_primary_grade', ['synex_group_memberships']],
    ['synex.groups.reporting.set', ['synex_group_memberships']],
    ['synex.groups.grades.create', ['synex_group_grades']],
    ['synex.groups.grades.update', ['synex_group_grades']],
    ['synex.groups.roles.create', ['synex_group_roles']],
    ['synex.groups.roles.update', ['synex_group_roles']],
    ['synex.groups.roles.assign', ['synex_group_membership_roles']],
    ['synex.groups.roles.remove', ['synex_group_membership_roles']],
    ['synex.groups.capabilities.set', ['synex_group_grades', 'synex_group_roles']],
    ['synex.groups.duty.start', ['synex_group_duty_sessions']],
    ['synex.groups.duty.update', ['synex_group_duty_sessions']],
    ['synex.groups.duty.stop', ['synex_group_duty_sessions']],
    ['synex.groups.assignments.create', ['synex_group_assignments']],
    ['synex.groups.assignments.join', ['synex_group_assignment_members']],
    ['synex.groups.assignments.leave', ['synex_group_assignment_members']],
    ['synex.groups.assignments.complete', ['synex_group_assignments']],
    ['synex.groups.assignments.cancel', ['synex_group_assignments']],
    ['synex.groups.delegations.create', ['synex_group_delegations']],
    ['synex.groups.delegations.revoke', ['synex_group_delegations']],
    ['synex.groups.applications.submit', ['synex_group_applications']],
    ['synex.groups.applications.review', ['synex_group_applications']],
    ['synex.groups.applications.withdraw', ['synex_group_applications']],
    ['synex.groups.proposals.create', ['synex_group_proposals']],
    ['synex.groups.proposals.approve', ['synex_group_proposals']],
    ['synex.groups.proposals.reject', ['synex_group_proposals']],
    ['synex.groups.policies.set', ['synex_group_policies']],
    ['synex.groups.attributes.register_schema', ['synex_group_attribute_schemas']],
    ['synex.groups.attributes.set', ['synex_group_membership_attributes']],
    ['synex.groups.definitions.sync', ['synex_group_definition_sets']],
  ]);
  const synchronizationContracts = new Set(['synex.groups.registries.begin']);
  const mutatingContracts = contractSource.contracts
    .filter((contract) => contract.idempotent === true
      && !synchronizationContracts.has(contract.name))
    .map((contract) => contract.name)
    .sort((left, right) => left.localeCompare(right, 'en'));
  assert.equal(
    contractSource.contracts.find((contract) =>
      contract.name === 'synex.groups.registries.begin')?.idempotent,
    true,
  );
  assert.equal(mutatingContracts.length, 49);
  assert.deepEqual(mutatingContracts, [...mutationEntities.keys()].sort((left, right) => left.localeCompare(right, 'en')));

  for (const [contract, tables] of mutationEntities) {
    for (const table of tables) {
      const createBody = tableBody(completeSql, table);
      const alterations = migrationContents.map((contents) => tableAlterations(contents, table)).join('\n');
      const storage = createBody + '\n' + alterations;
      assert.match(
        storage,
        /`public_id` VARCHAR\(48\) CHARACTER SET ascii COLLATE ascii_bin/u,
        `${contract} uses ${table} without a 48-character public identifier`,
      );
      assert.match(
        storage,
        /UNIQUE KEY `[^`]*public[^`]*` \(`public_id`\)/u,
        `${contract} uses ${table} without public-id uniqueness`,
      );
    }
  }
});

test('group types, relationships, and lifecycle state are deterministic and explicit', async () => {
  const sql = await readMigration('004_organization_types_graph.sql');
  const builtinTypes = [
    'job',
    'government',
    'law_enforcement',
    'medical',
    'gang',
    'business',
    'organization',
    'faction',
    'department',
    'club',
    'family',
    'crew',
    'custom',
  ];
  const builtinRelations = [
    'subdivision_of',
    'ally_of',
    'hostile_to',
    'partner_of',
    'subsidiary_of',
    'affiliated_with',
  ];

  assert.match(sql, /synex:builtin-group-type:/u);
  assert.match(sql, /synex:builtin-relation-type:/u);
  for (const type of builtinTypes) assert.match(sql, new RegExp(`'${type}'`, 'u'));
  for (const relation of builtinRelations) assert.match(sql, new RegExp(`'${relation}'`, 'u'));
  assert.ok(
    sql.indexOf('synex:builtin-group-type:') < sql.indexOf('synex:group-type:'),
    'built-ins must win type-key conflicts before legacy backfill',
  );

  const profile = tableBody(sql, 'synex_group_organization_profiles');
  assert.match(
    profile,
    /`lifecycle_state` IN\s*\('DRAFT', 'ACTIVE', 'SUSPENDED', 'ARCHIVED', 'DISSOLVING', 'DELETED'\)/u,
  );
  assert.match(profile, /`visibility` IN \('public', 'internal', 'private', 'hidden'\)/u);
  assert.match(profile, /`version` BIGINT UNSIGNED NOT NULL DEFAULT 1/u);
});

test('membership lifecycle and reporting hierarchy remain relational', async () => {
  const sql = await readMigration('006_membership_workflows.sql');
  const profile = tableBody(sql, 'synex_group_membership_profiles');
  assert.match(profile, /`character_id` VARCHAR\(48\) CHARACTER SET ascii COLLATE ascii_bin NOT NULL/u);
  assert.match(profile, /`joined_at` DATETIME\(6\) NULL/u);
  assert.match(profile, /`left_at` DATETIME\(6\) NULL/u);
  assert.match(profile, /`visibility` VARCHAR\(16\)/u);
  assert.match(profile, /`lifecycle_state` IN\s*\([\s\S]*?'PROBATION'[\s\S]*?'ACTIVE'[\s\S]*?'LEAVE'[\s\S]*?'INACTIVE'[\s\S]*?'BANNED'[\s\S]*?'LEFT'/u);
  assert.match(sql, /PRIMARY KEY \(`membership_id`\)[\s\S]*?`manager_membership_id`/u);
  assert.match(sql, /PRIMARY KEY \(`manager_membership_id`, `report_membership_id`\)/u);
  assert.match(sql, /SELECT `membership`\.`id`, `membership`\.`id`, 0/u);
});

test('membership state registry matches the domain lifecycle and backfills every active state', async () => {
  const sql = await readMigration('009_contract_storage_compatibility.sql');
  const constants = await readFile(
    path.join(root, 'resources', 'synex_groups', 'server', 'domain', 'constants.lua'),
    'utf8',
  );
  const states = [
    'DRAFT',
    'INVITED',
    'APPLICANT',
    'UNDER_REVIEW',
    'APPROVED',
    'PROBATION',
    'ACTIVE',
    'SUSPENDED',
    'LEAVE',
    'INACTIVE',
    'TERMINATED',
    'BANNED',
    'LEFT',
    'ARCHIVED',
  ];
  const membershipBlock = constants.match(/membership = \{([\s\S]*?)\n\s*\},\n\s*invite = \{/u)?.[1] ?? '';
  const domainStates = [...membershipBlock.matchAll(/\b([A-Z_]+)\s*=\s*'([A-Z_]+)'/gu)]
    .map((match) => match[2] ?? '');
  assert.deepEqual(domainStates, states);
  for (const state of states) assert.match(sql, new RegExp(`SELECT '${state}'|SELECT '${state}' AS`, 'u'), state);
  for (const terminal of ['TERMINATED', 'BANNED', 'LEFT', 'ARCHIVED']) {
    assert.match(sql, new RegExp(`SELECT '${terminal}', '[^']+', 1`, 'u'), terminal);
  }
  assert.match(sql, /CROSS JOIN `synex_group_membership_states` AS `state`/u);
  assert.match(sql, /WHERE `state`\.`status` = 'active' AND `allowed`\.`group_type_id` IS NULL/u);
  assert.match(sql, /WHEN 'UNDER_REVIEW' THEN 3/u);
  assert.match(sql, /WHEN 'ARCHIVED' THEN 13/u);
});

test('capability delegability migration covers every supported capability source', async () => {
  const sql = await readMigration('020_capability_delegability.sql');
  const sources = [
    ['synex_group_default_capabilities', 'chk_group_default_capability_delegable'],
    ['synex_group_grade_capabilities', 'chk_group_grade_capability_delegable'],
    ['synex_group_role_capabilities', 'chk_group_role_capability_delegable'],
    ['synex_group_membership_capabilities', 'chk_group_membership_capability_delegable'],
  ] as const;
  for (const [table, constraint] of sources) {
    assert.match(sql, new RegExp('ALTER TABLE `' + table + '`[\\s\\S]*?ADD COLUMN `delegable`', 'u'), table);
    assert.match(sql, new RegExp('ADD CONSTRAINT `' + constraint + '`', 'u'), constraint);
  }
  assert.match(sql, /CHECK \(`delegable` IN \(0, 1\) AND \(`effect` = 'allow' OR `delegable` = 0\)\)/u);
});

test('all new public and character identifiers preserve the 48-character Core boundary', async () => {
  const allSql = (await Promise.all(additiveMigrationFiles.map(readMigration))).join('\n');
  const publicIds = [...allSql.matchAll(/`public_id`\s+(VARCHAR\([^,\n]+)/gu)];
  const characterIds = [...allSql.matchAll(/`character_id`\s+(VARCHAR\([^,\n]+)/gu)];
  assert.ok(publicIds.length >= 10);
  assert.ok(characterIds.length >= 4);
  for (const match of [...publicIds, ...characterIds]) {
    assert.match(match[1] ?? '', /^VARCHAR\(48\) CHARACTER SET ascii COLLATE ascii_bin/u);
  }
  assert.match(allSql, /\{7,47\}/u);
});

test('legacy public, character, event, grade, operation, and outbox identifiers are widened additively', async () => {
  const sql = await readMigration('008_public_id_compatibility.sql');
  const widenedColumns = new Map<string, Array<[string, number]>>([
    ['synex_groups', [['public_id', 48], ['created_by_ref', 48]]],
    ['synex_group_memberships', [['public_id', 48], ['subject_ref', 48]]],
    ['synex_group_membership_events', [['event_id', 48], ['actor_ref', 48]]],
    ['synex_group_operations', [['idempotency_key', 128]]],
    ['synex_group_outbox', [['event_id', 48], ['aggregate_id', 48]]],
    ['synex_group_grades', [['public_id', 48]]],
    ['synex_group_membership_grades', [['assigned_by_ref', 48]]],
    ['synex_group_primary_memberships', [['subject_ref', 48], ['assigned_by_ref', 48]]],
    ['synex_group_primary_membership_events', [['event_id', 48], ['subject_ref', 48], ['actor_ref', 48]]],
  ]);

  for (const [table, columns] of widenedColumns) {
    const statement = tableAlterations(sql, table);
    assert.notEqual(statement, '', `missing widening for ${table}`);
    for (const [column, width] of columns) {
      assert.match(
        statement,
        new RegExp('MODIFY COLUMN `' + column + '` VARCHAR\\(' + width
          + '\\) CHARACTER SET ascii COLLATE ascii_bin', 'u'),
        `${table}.${column}`,
      );
    }
  }
  assert.doesNotMatch(sql, /ALTER TABLE `synex_group_character_deletions`/u);
});

test('active-workflow uniqueness and optimistic concurrency are database-enforced', async () => {
  const sql = (await Promise.all(additiveMigrationFiles.map(readMigration))).join('\n');
  const generatedMarkers = [
    'active_marker',
    'pending_marker',
    'open_marker',
  ];
  for (const marker of generatedMarkers) {
    assert.match(sql, new RegExp('`' + marker + '`[\\s\\S]{0,160}?GENERATED ALWAYS AS', 'u'));
  }
  assert.match(sql, /`exclusive_role_id` BIGINT UNSIGNED NULL/u);
  assert.match(sql, /FOREIGN KEY \(`exclusive_role_id`\) REFERENCES `synex_group_roles`/u);

  const concurrencyKeys = [
    'uq_group_relationships_active',
    'uq_group_membership_roles_active',
    'uq_group_membership_roles_exclusive',
    'uq_group_invitations_pending',
    'uq_group_applications_open',
    'uq_group_duty_sessions_open',
    'uq_group_assignment_members_active',
    'uq_group_delegations_active',
    'uq_group_definition_issues_open',
  ];
  for (const key of concurrencyKeys) assert.match(sql, new RegExp('UNIQUE KEY `' + key + '`', 'u'));

  const versionedTables = [
    'synex_group_organization_profiles',
    'synex_group_roles',
    'synex_group_membership_profiles',
    'synex_group_invitations',
    'synex_group_applications',
    'synex_group_duty_sessions',
    'synex_group_assignments',
    'synex_group_delegations',
    'synex_group_proposals',
    'synex_group_definition_sets',
    'synex_group_definition_migrations',
  ];
  for (const table of versionedTables) {
    assert.match(tableBody(sql, table), /`version` BIGINT UNSIGNED NOT NULL DEFAULT 1/u, table);
  }
});

test('legacy rows receive explicit replay-safe backfills without publishing historical audit traffic', async () => {
  const types = await readMigration('004_organization_types_graph.sql');
  const workflows = await readMigration('006_membership_workflows.sql');
  const audit = await readMigration('007_audit_definitions_retention.sql');

  assert.match(types, /FROM \(SELECT DISTINCT `group_type` FROM `synex_groups`\) AS `legacy`/u);
  assert.match(types, /LEFT JOIN `synex_group_organization_profiles` AS `profile`/u);
  assert.match(workflows, /FROM `synex_group_primary_memberships` AS `legacy`/u);
  assert.match(workflows, /FROM `synex_group_memberships` AS `membership`/u);
  assert.match(audit, /FROM `synex_group_operations` AS `legacy`/u);
  assert.match(audit, /SHA2\(`legacy`\.`request_fingerprint`, 256\)/u);
  assert.match(audit, /FROM `synex_group_membership_events` AS `legacy`/u);
  assert.match(audit, /SELECT `history`\.`id`, 'suppressed'/u);
});

test('audit delivery, definition drift, and retention have bounded work indexes', async () => {
  const sql = await readMigration('007_audit_definitions_retention.sql');
  assert.match(sql, /KEY `idx_group_command_receipts_claim` \(`status`, `locked_until`, `created_at`, `id`\)/u);
  assert.match(sql, /KEY `idx_group_audit_delivery_claim` \(`state`, `available_at`, `locked_until`, `id`\)/u);
  assert.match(sql, /KEY `idx_group_definition_migrations_claim` \(`state`, `locked_until`, `created_at`, `id`\)/u);
  assert.match(sql, /`batch_size` BETWEEN 1 AND 1000/u);
  assert.match(sql, /FOREIGN KEY \(`record_kind`\)[\s\S]*?ON DELETE RESTRICT/u);
  assert.match(sql, /UNIQUE KEY `uq_group_history_archive_source` \(`source_history_id`\)/u);
});
