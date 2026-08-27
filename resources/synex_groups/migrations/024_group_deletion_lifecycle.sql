DROP PROCEDURE IF EXISTS `synex_groups_migrate_024_group_deletion_lifecycle`;

-- synex:statement
CREATE PROCEDURE `synex_groups_migrate_024_group_deletion_lifecycle`()
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLES`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_group_organization_profiles'
            AND UPPER(`ENGINE`) = 'INNODB'
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex groups migration 024 lifecycle prerequisite verification failed';
    END IF;

    IF EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_group_organization_profiles'
            AND `CONSTRAINT_NAME` = 'chk_group_profiles_lifecycle_dates'
            AND `CONSTRAINT_TYPE` = 'CHECK'
    ) THEN
        ALTER TABLE `synex_group_organization_profiles`
            DROP CONSTRAINT `chk_group_profiles_lifecycle_dates`;
    END IF;

    UPDATE `synex_group_organization_profiles`
        SET `archived_at` = COALESCE(`archived_at`, `state_changed_at`, `updated_at`),
            `deleted_at` = NULL
        WHERE `lifecycle_state` = 'DISSOLVING';

    ALTER TABLE `synex_group_organization_profiles`
        ADD CONSTRAINT `chk_group_profiles_lifecycle_dates`
            CHECK ((`lifecycle_state` IN ('DRAFT', 'ACTIVE')
                        AND `suspended_at` IS NULL
                        AND `archived_at` IS NULL AND `deleted_at` IS NULL)
                OR (`lifecycle_state` = 'SUSPENDED' AND `suspended_at` IS NOT NULL
                        AND `archived_at` IS NULL AND `deleted_at` IS NULL)
                OR (`lifecycle_state` IN ('ARCHIVED', 'DISSOLVING')
                        AND `archived_at` IS NOT NULL AND `deleted_at` IS NULL)
                OR (`lifecycle_state` = 'DELETED'
                        AND `archived_at` IS NOT NULL AND `deleted_at` IS NOT NULL));

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_group_organization_profiles'
            AND `INDEX_NAME` = 'idx_group_profiles_deleted'
    ) THEN
        ALTER TABLE `synex_group_organization_profiles`
            ADD KEY `idx_group_profiles_deleted` (`deleted_at`, `group_id`);
    END IF;
END;

-- synex:statement
CALL `synex_groups_migrate_024_group_deletion_lifecycle`();

-- synex:statement
DROP PROCEDURE IF EXISTS `synex_groups_migrate_024_group_deletion_lifecycle`;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_group_deletion_requests` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `public_id` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `group_id` BIGINT UNSIGNED NOT NULL,
    `idempotency_key` VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `plan_id` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `actor_ref` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `reason_code` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `reason_text` VARCHAR(256) NOT NULL,
    `state` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'planning',
    `plan_state` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `failure_code` VARCHAR(96) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `requested_group_version` BIGINT UNSIGNED NOT NULL,
    `group_version` BIGINT UNSIGNED NOT NULL,
    `version` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    `active_marker` TINYINT UNSIGNED
        GENERATED ALWAYS AS (
            CASE WHEN `state` IN ('planning', 'dissolving') THEN 1 ELSE NULL END
        ) STORED,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
        ON UPDATE CURRENT_TIMESTAMP(6),
    `blocked_at` DATETIME(6) NULL,
    `dissolving_at` DATETIME(6) NULL,
    `completed_at` DATETIME(6) NULL,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_group_deletion_requests_public` (`public_id`),
    UNIQUE KEY `uq_group_deletion_requests_idempotency` (`group_id`, `idempotency_key`),
    UNIQUE KEY `uq_group_deletion_requests_plan` (`plan_id`),
    UNIQUE KEY `uq_group_deletion_requests_active` (`group_id`, `active_marker`),
    KEY `idx_group_deletion_requests_reconcile`
        (`state`, `updated_at`, `id`),
    KEY `idx_group_deletion_requests_group`
        (`group_id`, `created_at`, `id`),
    CONSTRAINT `fk_group_deletion_requests_group`
        FOREIGN KEY (`group_id`) REFERENCES `synex_groups` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `chk_group_deletion_requests_public`
        CHECK (`public_id` REGEXP '^[a-z][a-z0-9_]{7,47}$'),
    CONSTRAINT `chk_group_deletion_requests_key`
        CHECK (`idempotency_key` REGEXP '^[A-Za-z0-9][A-Za-z0-9_.:%-]{7,127}$'),
    CONSTRAINT `chk_group_deletion_requests_plan`
        CHECK (`plan_id` IS NULL OR `plan_id` REGEXP '^[a-z0-9_]{1,47}$'),
    CONSTRAINT `chk_group_deletion_requests_actor`
        CHECK (`actor_ref` IS NULL
            OR `actor_ref` REGEXP '^[A-Za-z0-9][A-Za-z0-9_.:%-]{2,47}$'),
    CONSTRAINT `chk_group_deletion_requests_reason`
        CHECK (`reason_code` REGEXP '^[a-z][a-z0-9_.:-]{1,63}$'
            AND CHAR_LENGTH(`reason_text`) BETWEEN 1 AND 256),
    CONSTRAINT `chk_group_deletion_requests_state`
        CHECK (`state` IN ('planning', 'blocked', 'dissolving', 'deleted', 'failed')),
    CONSTRAINT `chk_group_deletion_requests_plan_state`
        CHECK (`plan_state` IS NULL
            OR `plan_state` IN ('pending', 'executing', 'completed', 'blocked', 'failed')),
    CONSTRAINT `chk_group_deletion_requests_failure`
        CHECK (`failure_code` IS NULL
            OR `failure_code` REGEXP '^[A-Z][A-Z0-9_]{1,95}$'),
    CONSTRAINT `chk_group_deletion_requests_versions`
        CHECK (`requested_group_version` > 0
            AND `group_version` >= `requested_group_version` AND `version` > 0),
    CONSTRAINT `chk_group_deletion_requests_terminal`
        CHECK ((`state` = 'planning' AND `plan_id` IS NULL
                    AND `plan_state` IS NULL AND `blocked_at` IS NULL
                    AND `dissolving_at` IS NULL AND `completed_at` IS NULL)
            OR (`state` = 'blocked' AND `plan_id` IS NOT NULL
                    AND `plan_state` = 'blocked' AND `blocked_at` IS NOT NULL
                    AND `dissolving_at` IS NULL AND `completed_at` IS NOT NULL)
            OR (`state` = 'dissolving' AND `plan_id` IS NOT NULL
                    AND `plan_state` IN ('pending', 'executing')
                    AND `blocked_at` IS NULL AND `dissolving_at` IS NOT NULL
                    AND `completed_at` IS NULL)
            OR (`state` = 'deleted' AND `plan_id` IS NOT NULL
                    AND `plan_state` = 'completed' AND `blocked_at` IS NULL
                    AND `dissolving_at` IS NOT NULL AND `completed_at` IS NOT NULL)
            OR (`state` = 'failed' AND `plan_id` IS NOT NULL
                    AND `plan_state` = 'failed' AND `completed_at` IS NOT NULL)),
    CONSTRAINT `chk_group_deletion_requests_active_marker`
        CHECK ((`state` IN ('planning', 'dissolving') AND `active_marker` = 1)
            OR (`state` NOT IN ('planning', 'dissolving') AND `active_marker` IS NULL))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
DROP PROCEDURE IF EXISTS `synex_groups_verify_024_group_deletion_lifecycle`;

-- synex:statement
CREATE PROCEDURE `synex_groups_verify_024_group_deletion_lifecycle`()
BEGIN
    IF (
        SELECT COUNT(*) FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND ((`TABLE_NAME` = 'synex_group_organization_profiles'
                    AND `CONSTRAINT_NAME` = 'chk_group_profiles_lifecycle_dates'
                    AND `CONSTRAINT_TYPE` = 'CHECK')
                OR (`TABLE_NAME` = 'synex_group_deletion_requests'
                    AND `CONSTRAINT_NAME` IN (
                        'uq_group_deletion_requests_public',
                        'uq_group_deletion_requests_idempotency',
                        'uq_group_deletion_requests_plan',
                        'uq_group_deletion_requests_active'
                    ) AND `CONSTRAINT_TYPE` = 'UNIQUE'))
    ) <> 5 OR (
        SELECT COUNT(*) FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_group_deletion_requests'
            AND `INDEX_NAME` = 'idx_group_deletion_requests_reconcile'
            AND ((`SEQ_IN_INDEX` = 1 AND `COLUMN_NAME` = 'state')
                OR (`SEQ_IN_INDEX` = 2 AND `COLUMN_NAME` = 'updated_at')
                OR (`SEQ_IN_INDEX` = 3 AND `COLUMN_NAME` = 'id'))
    ) <> 3 OR EXISTS (
        SELECT 1 FROM `synex_group_organization_profiles`
        WHERE (`lifecycle_state` IN ('DRAFT', 'ACTIVE')
                    AND (`suspended_at` IS NOT NULL
                        OR `archived_at` IS NOT NULL OR `deleted_at` IS NOT NULL))
            OR (`lifecycle_state` = 'SUSPENDED'
                    AND (`suspended_at` IS NULL
                        OR `archived_at` IS NOT NULL OR `deleted_at` IS NOT NULL))
            OR (`lifecycle_state` IN ('ARCHIVED', 'DISSOLVING')
                    AND (`archived_at` IS NULL OR `deleted_at` IS NOT NULL))
            OR (`lifecycle_state` = 'DELETED'
                    AND (`archived_at` IS NULL OR `deleted_at` IS NULL))
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex groups migration 024 lifecycle verification failed';
    END IF;
END;

-- synex:statement
CALL `synex_groups_verify_024_group_deletion_lifecycle`();

-- synex:statement
DROP PROCEDURE IF EXISTS `synex_groups_verify_024_group_deletion_lifecycle`;
