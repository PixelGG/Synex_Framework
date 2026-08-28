ALTER TABLE `synex_entities`
    ADD COLUMN IF NOT EXISTS `persistence_policy`
        VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'persistent',
    ADD COLUMN IF NOT EXISTS `recovery_policy`
        VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'automatic',
    ADD COLUMN IF NOT EXISTS `server_scope`
        VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'default',
    ADD COLUMN IF NOT EXISTS `archetype_namespace`
        VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NULL,
    ADD COLUMN IF NOT EXISTS `archetype_schema_version` BIGINT UNSIGNED NULL,
    ADD COLUMN IF NOT EXISTS `archetype_descriptor_json` LONGTEXT NULL,
    ADD COLUMN IF NOT EXISTS `recovery_attempt_count` INT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS `recovery_window_started_at` DATETIME(6) NULL,
    ADD COLUMN IF NOT EXISTS `next_recovery_at` DATETIME(6) NULL,
    ADD COLUMN IF NOT EXISTS `recovery_circuit_state`
        VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'closed',
    ADD COLUMN IF NOT EXISTS `last_recovery_failure_code`
        VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NULL,
    ADD COLUMN IF NOT EXISTS `last_reason_code`
        VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NULL,
    ADD COLUMN IF NOT EXISTS `last_trace_id`
        VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NULL,
    ADD COLUMN IF NOT EXISTS `last_materialized_at` DATETIME(6) NULL,
    ADD COLUMN IF NOT EXISTS `last_checkpoint_at` DATETIME(6) NULL,
    MODIFY COLUMN `persistent_key` VARCHAR(128) NULL;

-- synex:statement
ALTER TABLE `synex_entities`
    DROP CONSTRAINT IF EXISTS `ck_synex_entities_status`,
    DROP CONSTRAINT IF EXISTS `ck_synex_entities_owner_type`,
    DROP CONSTRAINT IF EXISTS `ck_synex_entities_deleted_tombstone`,
    DROP CONSTRAINT IF EXISTS `ck_synex_entities_persistence_policy`,
    DROP CONSTRAINT IF EXISTS `ck_synex_entities_recovery_policy`,
    DROP CONSTRAINT IF EXISTS `ck_synex_entities_server_scope`,
    DROP CONSTRAINT IF EXISTS `ck_synex_entities_persistent_key_v2`,
    DROP CONSTRAINT IF EXISTS `ck_synex_entities_archetype`,
    DROP CONSTRAINT IF EXISTS `ck_synex_entities_recovery_state`,
    DROP CONSTRAINT IF EXISTS `ck_synex_entities_recovery_failure`,
    DROP CONSTRAINT IF EXISTS `ck_synex_entities_reason`,
    DROP CONSTRAINT IF EXISTS `ck_synex_entities_trace`,
    ADD CONSTRAINT `ck_synex_entities_status`
        CHECK (`status` IN (
            'defined', 'spawning', 'active', 'orphaned', 'recovering',
            'dormant', 'deleting', 'deleted', 'failed'
        )),
    ADD CONSTRAINT `ck_synex_entities_owner_type`
        CHECK (`owner_type` IN ('character', 'group', 'resource', 'system', 'user')),
    ADD CONSTRAINT `ck_synex_entities_deleted_tombstone`
        CHECK ((`status` = 'deleted' AND `deleted_at` IS NOT NULL)
            OR (`status` <> 'deleted' AND `deleted_at` IS NULL)),
    ADD CONSTRAINT `ck_synex_entities_persistence_policy`
        CHECK (`persistence_policy` IN ('temporary', 'persistent', 'session', 'owner_lifetime')),
    ADD CONSTRAINT `ck_synex_entities_recovery_policy`
        CHECK (`recovery_policy` IN ('none', 'manual', 'on_demand', 'automatic')
            AND (`recovery_policy` <> 'automatic'
                OR `persistence_policy` IN ('persistent', 'owner_lifetime'))),
    ADD CONSTRAINT `ck_synex_entities_server_scope`
        CHECK (CHAR_LENGTH(`server_scope`) BETWEEN 1 AND 64
            AND `server_scope` REGEXP '^[A-Za-z0-9][A-Za-z0-9_.:%-]*$'),
    ADD CONSTRAINT `ck_synex_entities_persistent_key_v2`
        CHECK ((`persistence_policy` IN ('temporary', 'session')
                AND `persistent_key` IS NULL)
            OR (`persistence_policy` IN ('persistent', 'owner_lifetime')
                AND `persistent_key` IS NOT NULL
                AND CHAR_LENGTH(`persistent_key`) BETWEEN 1 AND 128
                AND `persistent_key` = LOWER(`persistent_key`)
                AND `persistent_key` REGEXP '^[a-z0-9][a-z0-9_.:%-]*$')),
    ADD CONSTRAINT `ck_synex_entities_archetype`
        CHECK ((`archetype_namespace` IS NULL
                AND `archetype_schema_version` IS NULL
                AND `archetype_descriptor_json` IS NULL)
            OR (`archetype_namespace` IS NOT NULL
                AND `archetype_schema_version` IS NOT NULL
                AND `archetype_descriptor_json` IS NOT NULL
                AND CHAR_LENGTH(`archetype_namespace`) BETWEEN 3 AND 128
                AND `archetype_namespace` REGEXP '^[a-z][a-z0-9_]*[.][a-z][a-z0-9_.]*$'
                AND `archetype_schema_version` BETWEEN 1 AND 9007199254740991
                AND JSON_VALID(`archetype_descriptor_json`)
                AND OCTET_LENGTH(`archetype_descriptor_json`) BETWEEN 2 AND 32768)),
    ADD CONSTRAINT `ck_synex_entities_recovery_state`
        CHECK (`recovery_attempt_count` <= 1000
            AND (`recovery_attempt_count` = 0 OR `recovery_window_started_at` IS NOT NULL)
            AND `recovery_circuit_state` IN ('closed', 'open', 'half_open', 'paused')
            AND (`next_recovery_at` IS NULL
                OR `recovery_policy` IN ('on_demand', 'automatic'))),
    ADD CONSTRAINT `ck_synex_entities_recovery_failure`
        CHECK (`last_recovery_failure_code` IS NULL
            OR (CHAR_LENGTH(`last_recovery_failure_code`) BETWEEN 3 AND 64
                AND `last_recovery_failure_code` REGEXP '^[A-Z][A-Z0-9_]*$')),
    ADD CONSTRAINT `ck_synex_entities_reason`
        CHECK (`last_reason_code` IS NULL
            OR (CHAR_LENGTH(`last_reason_code`) BETWEEN 3 AND 128
                AND `last_reason_code` REGEXP '^[a-z][a-z0-9_]*[.][a-z0-9_.-]+$')),
    ADD CONSTRAINT `ck_synex_entities_trace`
        CHECK (`last_trace_id` IS NULL
            OR (CHAR_LENGTH(`last_trace_id`) BETWEEN 8 AND 128
                AND `last_trace_id` REGEXP '^[A-Za-z0-9][A-Za-z0-9_.:%-]*$'));

-- synex:statement
CREATE UNIQUE INDEX IF NOT EXISTS `uq_synex_entities_resource_persistent_key`
    ON `synex_entities` (`resource_owner`, `persistent_key`);

-- synex:statement
DROP INDEX IF EXISTS `uq_synex_entities_persistent_key` ON `synex_entities`;

-- synex:statement
CREATE INDEX IF NOT EXISTS `idx_synex_entities_scope_status`
    ON `synex_entities` (`server_scope`, `status`, `entity_id`);

-- synex:statement
CREATE INDEX IF NOT EXISTS `idx_synex_entities_recovery_dispatch`
    ON `synex_entities`
        (`recovery_policy`, `recovery_circuit_state`, `next_recovery_at`, `entity_id`);
