DROP PROCEDURE IF EXISTS `synex_groups_migrate_025_creation_policy`;

-- synex:statement
CREATE PROCEDURE `synex_groups_migrate_025_creation_policy`()
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLES`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_types'
            AND UPPER(`ENGINE`) = 'INNODB'
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex groups migration 025 type prerequisite verification failed';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLES`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_groups'
            AND UPPER(`ENGINE`) = 'INNODB'
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex groups migration 025 group prerequisite verification failed';
    END IF;

    -- The public slug contract permits two-character and hyphenated slugs. Keep
    -- the legacy group_key guard aligned so validation never falls through to a
    -- vendor-specific SQL constraint error.
    IF EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_groups'
            AND `CONSTRAINT_NAME` = 'chk_groups_key'
            AND `CONSTRAINT_TYPE` = 'CHECK'
    ) THEN
        ALTER TABLE `synex_groups`
            DROP CONSTRAINT `chk_groups_key`;
    END IF;

    ALTER TABLE `synex_groups`
        ADD CONSTRAINT `chk_groups_key`
            CHECK (`group_key` REGEXP '^[a-z][a-z0-9_-]{1,63}$');

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_types'
            AND `COLUMN_NAME` = 'required_approvals'
    ) THEN
        ALTER TABLE `synex_group_types`
            ADD COLUMN `required_approvals` TINYINT UNSIGNED NOT NULL DEFAULT 0
            AFTER `create_permission`;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_types'
            AND `COLUMN_NAME` = 'approval_permission'
    ) THEN
        ALTER TABLE `synex_group_types`
            ADD COLUMN `approval_permission`
                VARCHAR(96) CHARACTER SET ascii COLLATE ascii_bin NULL
                DEFAULT 'synex.groups.create.approve.migration_pending'
            AFTER `required_approvals`;
    END IF;

    UPDATE `synex_group_types`
        SET `approval_permission` = CONCAT(
            'synex.groups.create.approve.', `type_key`)
        WHERE `approval_permission` IS NULL;

    ALTER TABLE `synex_group_types`
        MODIFY COLUMN `required_approvals`
            TINYINT UNSIGNED NOT NULL DEFAULT 0,
        MODIFY COLUMN `approval_permission`
            VARCHAR(96) CHARACTER SET ascii COLLATE ascii_bin NOT NULL
            DEFAULT 'synex.groups.create.approve.migration_pending';

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_types'
            AND `CONSTRAINT_NAME` = 'chk_group_types_creation_approval_count'
            AND `CONSTRAINT_TYPE` = 'CHECK'
    ) THEN
        ALTER TABLE `synex_group_types`
            ADD CONSTRAINT `chk_group_types_creation_approval_count`
                CHECK (`required_approvals` <= 32);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_types'
            AND `CONSTRAINT_NAME` = 'chk_group_types_creation_approval_permission'
            AND `CONSTRAINT_TYPE` = 'CHECK'
    ) THEN
        ALTER TABLE `synex_group_types`
            ADD CONSTRAINT `chk_group_types_creation_approval_permission`
                CHECK (`approval_permission` REGEXP
                    '^synex\\.groups\\.create\\.approve\\.[a-z][a-z0-9_.-]+$');
    END IF;

    IF (
        SELECT COUNT(*) FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_types'
            AND ((`COLUMN_NAME` = 'required_approvals'
                    AND `DATA_TYPE` = 'tinyint' AND `COLUMN_TYPE` LIKE '%unsigned%'
                    AND `IS_NULLABLE` = 'NO')
                OR (`COLUMN_NAME` = 'approval_permission'
                    AND `DATA_TYPE` = 'varchar' AND `CHARACTER_MAXIMUM_LENGTH` = 96
                    AND `CHARACTER_SET_NAME` = 'ascii' AND `COLLATION_NAME` = 'ascii_bin'
                    AND `IS_NULLABLE` = 'NO'))
    ) <> 2 OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_groups'
            AND `CONSTRAINT_NAME` = 'chk_groups_key'
            AND `CONSTRAINT_TYPE` = 'CHECK'
    ) OR EXISTS (
        SELECT 1 FROM `synex_groups`
        WHERE `group_key` NOT REGEXP '^[a-z][a-z0-9_-]{1,63}$'
    ) OR EXISTS (
        SELECT 1 FROM `synex_group_types`
        WHERE `required_approvals` > 32
            OR `approval_permission` NOT REGEXP
                '^synex\\.groups\\.create\\.approve\\.[a-z][a-z0-9_.-]+$'
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex groups migration 025 creation policy verification failed';
    END IF;
END;

-- synex:statement
CALL `synex_groups_migrate_025_creation_policy`();

-- synex:statement
DROP PROCEDURE IF EXISTS `synex_groups_migrate_025_creation_policy`;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_group_creation_requests` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `public_id` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `group_type_id` BIGINT UNSIGNED NOT NULL,
    `requested_by_ref` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `idempotency_key` VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `requested_slug` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `request_json` LONGTEXT NOT NULL,
    `required_approvals` TINYINT UNSIGNED NOT NULL,
    `approval_count` TINYINT UNSIGNED NOT NULL DEFAULT 0,
    `creator_permission` VARCHAR(96) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `approval_permission` VARCHAR(96) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `type_schema_version` INT UNSIGNED NOT NULL,
    `type_version` BIGINT UNSIGNED NOT NULL,
    `status` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'pending',
    `target_group_id` BIGINT UNSIGNED NULL,
    `active_slug` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin
        GENERATED ALWAYS AS (
            CASE WHEN `status` IN ('pending', 'approved') THEN `requested_slug` ELSE NULL END
        ) STORED,
    `expires_at` DATETIME(6) NOT NULL,
    `approved_at` DATETIME(6) NULL,
    `completed_at` DATETIME(6) NULL,
    `failure_code` VARCHAR(96) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `execution_attempts` SMALLINT UNSIGNED NOT NULL DEFAULT 0,
    `last_attempt_at` DATETIME(6) NULL,
    `version` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
        ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_group_creation_requests_public` (`public_id`),
    UNIQUE KEY `uq_group_creation_requests_idempotency`
        (`requested_by_ref`, `idempotency_key`),
    UNIQUE KEY `uq_group_creation_requests_active_slug` (`active_slug`),
    KEY `idx_group_creation_requests_reconcile`
        (`status`, `expires_at`, `id`),
    KEY `idx_group_creation_requests_requester`
        (`requested_by_ref`, `status`, `created_at`, `id`),
    KEY `idx_group_creation_requests_target` (`target_group_id`),
    CONSTRAINT `fk_group_creation_requests_type`
        FOREIGN KEY (`group_type_id`) REFERENCES `synex_group_types` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `fk_group_creation_requests_target`
        FOREIGN KEY (`target_group_id`) REFERENCES `synex_groups` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `chk_group_creation_requests_public`
        CHECK (`public_id` REGEXP '^[a-z][a-z0-9_]{7,47}$'),
    CONSTRAINT `chk_group_creation_requests_requester`
        CHECK (`requested_by_ref` REGEXP
            '^[A-Za-z0-9][A-Za-z0-9_.:%-]{7,47}$'),
    CONSTRAINT `chk_group_creation_requests_idempotency`
        CHECK (`idempotency_key` REGEXP
            '^[A-Za-z0-9][A-Za-z0-9_.:%-]{7,127}$'),
    CONSTRAINT `chk_group_creation_requests_slug`
        CHECK (`requested_slug` REGEXP '^[a-z][a-z0-9_-]{1,63}$'),
    CONSTRAINT `chk_group_creation_requests_json`
        CHECK (JSON_VALID(`request_json`)
            AND OCTET_LENGTH(`request_json`) BETWEEN 2 AND 32768),
    CONSTRAINT `chk_group_creation_requests_approval_count`
        CHECK (`required_approvals` BETWEEN 1 AND 32
            AND `approval_count` <= `required_approvals`),
    CONSTRAINT `chk_group_creation_requests_permissions`
        CHECK (`creator_permission` REGEXP
                '^synex\\.groups\\.create\\.[a-z][a-z0-9_.-]+$'
            AND `approval_permission` REGEXP
                '^synex\\.groups\\.create\\.approve\\.[a-z][a-z0-9_.-]+$'),
    CONSTRAINT `chk_group_creation_requests_versions`
        CHECK (`type_schema_version` > 0 AND `type_version` > 0 AND `version` > 0),
    CONSTRAINT `chk_group_creation_requests_status`
        CHECK (`status` IN ('pending', 'approved', 'executed', 'rejected', 'expired')),
    CONSTRAINT `chk_group_creation_requests_failure`
        CHECK (`failure_code` IS NULL
            OR `failure_code` REGEXP '^[A-Z][A-Z0-9_]{1,95}$'),
    CONSTRAINT `chk_group_creation_requests_terminal`
        CHECK ((`status` = 'pending' AND `target_group_id` IS NULL
                    AND `approved_at` IS NULL AND `completed_at` IS NULL
                    AND `failure_code` IS NULL
                    AND `approval_count` < `required_approvals`)
            OR (`status` = 'approved' AND `target_group_id` IS NULL
                    AND `approved_at` IS NOT NULL AND `completed_at` IS NULL
                    AND `approval_count` = `required_approvals`)
            OR (`status` = 'executed' AND `target_group_id` IS NOT NULL
                    AND `approved_at` IS NOT NULL AND `completed_at` IS NOT NULL
                    AND `failure_code` IS NULL
                    AND `approval_count` = `required_approvals`)
            OR (`status` IN ('rejected', 'expired') AND `target_group_id` IS NULL
                    AND `completed_at` IS NOT NULL)),
    CONSTRAINT `chk_group_creation_requests_expiry`
        CHECK (`expires_at` > `created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_group_creation_approvals` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `public_id` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `creation_request_id` BIGINT UNSIGNED NOT NULL,
    `approver_character_ref` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `decision` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `permission_name` VARCHAR(96) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `request_version` BIGINT UNSIGNED NOT NULL,
    `reason_code` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `version` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_group_creation_approvals_public` (`public_id`),
    UNIQUE KEY `uq_group_creation_approvals_actor`
        (`creation_request_id`, `approver_character_ref`),
    KEY `idx_group_creation_approvals_decision`
        (`creation_request_id`, `decision`, `id`),
    KEY `idx_group_creation_approvals_character`
        (`approver_character_ref`, `created_at`, `id`),
    CONSTRAINT `fk_group_creation_approvals_request`
        FOREIGN KEY (`creation_request_id`)
        REFERENCES `synex_group_creation_requests` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `chk_group_creation_approvals_public`
        CHECK (`public_id` REGEXP '^[a-z][a-z0-9_]{7,47}$'),
    CONSTRAINT `chk_group_creation_approvals_actor`
        CHECK (`approver_character_ref` REGEXP
            '^[A-Za-z0-9][A-Za-z0-9_.:%-]{7,47}$'),
    CONSTRAINT `chk_group_creation_approvals_decision`
        CHECK (`decision` IN ('approved', 'rejected')),
    CONSTRAINT `chk_group_creation_approvals_permission`
        CHECK (`permission_name` REGEXP
            '^synex\\.groups\\.create\\.approve\\.[a-z][a-z0-9_.-]+$'),
    CONSTRAINT `chk_group_creation_approvals_versions`
        CHECK (`request_version` > 0 AND `version` > 0),
    CONSTRAINT `chk_group_creation_approvals_reason`
        CHECK (`reason_code` REGEXP '^[a-z][a-z0-9_.:%-]{1,63}$')
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_group_slug_reservations` (
    `slug` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `owner_kind` VARCHAR(24) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `owner_public_id` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `version` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
        ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`slug`),
    KEY `idx_group_slug_reservations_owner` (`owner_kind`, `owner_public_id`),
    CONSTRAINT `chk_group_slug_reservations_slug`
        CHECK (`slug` REGEXP '^[a-z][a-z0-9_-]{1,63}$'),
    CONSTRAINT `chk_group_slug_reservations_owner_kind`
        CHECK (`owner_kind` IN ('group', 'creation_request')),
    CONSTRAINT `chk_group_slug_reservations_owner_public`
        CHECK (`owner_public_id` REGEXP
            '^[A-Za-z0-9][A-Za-z0-9_.:%-]{7,47}$'),
    CONSTRAINT `chk_group_slug_reservations_version`
        CHECK (`version` > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
INSERT IGNORE INTO `synex_group_slug_reservations`
    (`slug`, `owner_kind`, `owner_public_id`, `version`)
SELECT `group_key`, 'group', `public_id`, 1
FROM `synex_groups`;

-- synex:statement
INSERT IGNORE INTO `synex_group_slug_reservations`
    (`slug`, `owner_kind`, `owner_public_id`, `version`)
SELECT `requested_slug`, 'creation_request', `public_id`, 1
FROM `synex_group_creation_requests`
WHERE `status` IN ('pending', 'approved');

-- synex:statement
DROP PROCEDURE IF EXISTS `synex_groups_verify_025_creation_approvals`;

-- synex:statement
CREATE PROCEDURE `synex_groups_verify_025_creation_approvals`()
BEGIN
    IF (
        SELECT COUNT(*) FROM `information_schema`.`TABLES`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` IN (
                'synex_group_creation_requests',
                'synex_group_creation_approvals',
                'synex_group_slug_reservations'
            ) AND UPPER(`ENGINE`) = 'INNODB'
    ) <> 3 OR (
        SELECT COUNT(*) FROM `information_schema`.`REFERENTIAL_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND `CONSTRAINT_NAME` IN (
                'fk_group_creation_requests_type',
                'fk_group_creation_requests_target',
                'fk_group_creation_approvals_request'
            )
    ) <> 3 OR (
        SELECT COUNT(*) FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND ((`TABLE_NAME` = 'synex_group_creation_requests'
                    AND `INDEX_NAME` IN (
                        'uq_group_creation_requests_public',
                        'uq_group_creation_requests_idempotency',
                        'uq_group_creation_requests_active_slug',
                        'idx_group_creation_requests_reconcile',
                        'idx_group_creation_requests_requester',
                        'idx_group_creation_requests_target'
                    ))
                OR (`TABLE_NAME` = 'synex_group_creation_approvals'
                    AND `INDEX_NAME` IN (
                        'uq_group_creation_approvals_public',
                        'uq_group_creation_approvals_actor',
                        'idx_group_creation_approvals_decision',
                        'idx_group_creation_approvals_character'
                    ))
                OR (`TABLE_NAME` = 'synex_group_slug_reservations'
                    AND `INDEX_NAME` IN (
                        'PRIMARY',
                        'idx_group_slug_reservations_owner'
                    )))
    ) <> 24 OR EXISTS (
        SELECT 1 FROM `synex_group_creation_requests`
        WHERE (`status` = 'pending' AND (`approval_count` >= `required_approvals`
                    OR `approved_at` IS NOT NULL OR `completed_at` IS NOT NULL))
            OR (`status` = 'approved' AND (`approval_count` <> `required_approvals`
                    OR `approved_at` IS NULL OR `completed_at` IS NOT NULL))
            OR (`status` = 'executed' AND (`target_group_id` IS NULL
                    OR `completed_at` IS NULL))
    ) OR EXISTS (
        SELECT 1 FROM `synex_groups` AS `group_record`
        LEFT JOIN `synex_group_slug_reservations` AS `reservation`
            ON `reservation`.`slug` = `group_record`.`group_key`
            AND `reservation`.`owner_kind` = 'group'
            AND `reservation`.`owner_public_id` = `group_record`.`public_id`
        WHERE `reservation`.`slug` IS NULL
    ) OR EXISTS (
        SELECT 1 FROM `synex_group_creation_requests` AS `request`
        LEFT JOIN `synex_group_slug_reservations` AS `reservation`
            ON `reservation`.`slug` = `request`.`requested_slug`
            AND `reservation`.`owner_kind` = 'creation_request'
            AND `reservation`.`owner_public_id` = `request`.`public_id`
        WHERE `request`.`status` IN ('pending', 'approved')
            AND `reservation`.`slug` IS NULL
    ) OR EXISTS (
        SELECT 1 FROM `synex_group_slug_reservations` AS `reservation`
        LEFT JOIN `synex_groups` AS `group_record`
            ON `reservation`.`owner_kind` = 'group'
            AND `group_record`.`public_id` = `reservation`.`owner_public_id`
            AND `group_record`.`group_key` = `reservation`.`slug`
        LEFT JOIN `synex_group_creation_requests` AS `request`
            ON `reservation`.`owner_kind` = 'creation_request'
            AND `request`.`public_id` = `reservation`.`owner_public_id`
            AND `request`.`requested_slug` = `reservation`.`slug`
            AND `request`.`status` IN ('pending', 'approved')
        WHERE (`reservation`.`owner_kind` = 'group' AND `group_record`.`id` IS NULL)
            OR (`reservation`.`owner_kind` = 'creation_request' AND `request`.`id` IS NULL)
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex groups migration 025 approval schema verification failed';
    END IF;
END;

-- synex:statement
CALL `synex_groups_verify_025_creation_approvals`();

-- synex:statement
DROP PROCEDURE IF EXISTS `synex_groups_verify_025_creation_approvals`;
