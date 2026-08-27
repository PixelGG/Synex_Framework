CREATE TABLE IF NOT EXISTS `synex_group_command_receipts` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `public_id` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `operation_name` VARCHAR(96) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `idempotency_key` VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `request_digest` CHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `status` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'pending',
    `owner_ref` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `locked_until` DATETIME(6) NULL,
    `response_json` LONGTEXT NULL,
    `error_code` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `completed_at` DATETIME(6) NULL,
    `expires_at` DATETIME(6) NULL,
    `version` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_group_command_receipts_public` (`public_id`),
    UNIQUE KEY `uq_group_command_receipts_key` (`operation_name`, `idempotency_key`),
    KEY `idx_group_command_receipts_claim` (`status`, `locked_until`, `created_at`, `id`),
    KEY `idx_group_command_receipts_expiry` (`expires_at`, `id`),
    CONSTRAINT `chk_group_command_receipts_public`
        CHECK (`public_id` REGEXP '^[a-z][a-z0-9_]{7,47}$'),
    CONSTRAINT `chk_group_command_receipts_operation`
        CHECK (`operation_name` REGEXP '^[a-z][a-z0-9_.:-]{1,95}$'),
    CONSTRAINT `chk_group_command_receipts_key`
        CHECK (OCTET_LENGTH(`idempotency_key`) BETWEEN 8 AND 128),
    CONSTRAINT `chk_group_command_receipts_digest`
        CHECK (`request_digest` REGEXP '^[0-9a-f]{64}$'),
    CONSTRAINT `chk_group_command_receipts_status`
        CHECK (`status` IN ('pending', 'completed', 'failed')),
    CONSTRAINT `chk_group_command_receipts_response`
        CHECK (`response_json` IS NULL OR JSON_VALID(`response_json`)),
    CONSTRAINT `chk_group_command_receipts_terminal`
        CHECK ((`status` = 'pending' AND `response_json` IS NULL
                AND `error_code` IS NULL AND `completed_at` IS NULL)
            OR (`status` = 'completed' AND `response_json` IS NOT NULL
                AND `error_code` IS NULL AND `completed_at` IS NOT NULL)
            OR (`status` = 'failed' AND `response_json` IS NULL
                AND `error_code` IS NOT NULL AND `completed_at` IS NOT NULL)),
    CONSTRAINT `chk_group_command_receipts_lock`
        CHECK ((`owner_ref` IS NULL AND `locked_until` IS NULL)
            OR (`owner_ref` IS NOT NULL AND `locked_until` IS NOT NULL)),
    CONSTRAINT `chk_group_command_receipts_expiry_window`
        CHECK (`expires_at` IS NULL OR `expires_at` > `created_at`),
    CONSTRAINT `chk_group_command_receipts_version` CHECK (`version` > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
INSERT INTO `synex_group_command_receipts`
    (`public_id`, `operation_name`, `idempotency_key`, `request_digest`, `status`,
     `owner_ref`, `locked_until`, `response_json`, `error_code`, `completed_at`,
     `expires_at`, `version`, `created_at`, `updated_at`)
SELECT CONCAT('gcmd_', SUBSTRING(SHA2(CONCAT('legacy-operation:', `legacy`.`id`), 256), 1, 32)),
    `legacy`.`operation_name`, `legacy`.`idempotency_key`,
    SHA2(`legacy`.`request_fingerprint`, 256), `legacy`.`state`, NULL, NULL,
    CASE
        WHEN `legacy`.`state` = 'completed' THEN COALESCE(`legacy`.`response_json`, 'null')
        ELSE NULL
    END,
    NULL, `legacy`.`completed_at`, NULL, 1, `legacy`.`created_at`,
    COALESCE(`legacy`.`completed_at`, `legacy`.`created_at`)
FROM `synex_group_operations` AS `legacy`
LEFT JOIN `synex_group_command_receipts` AS `receipt`
    ON `receipt`.`operation_name` = `legacy`.`operation_name`
    AND `receipt`.`idempotency_key` = `legacy`.`idempotency_key`
WHERE `receipt`.`id` IS NULL;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_group_domain_history` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `event_id` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `aggregate_type` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `aggregate_id` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `aggregate_version` BIGINT UNSIGNED NOT NULL,
    `event_type` VARCHAR(96) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `source_resource` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `actor_kind` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `actor_ref` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `reason_code` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `correlation_id` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `causation_id` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `before_json` LONGTEXT NULL,
    `after_json` LONGTEXT NULL,
    `context_json` LONGTEXT NULL,
    `occurred_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_group_domain_history_event` (`event_id`),
    UNIQUE KEY `uq_group_domain_history_version`
        (`aggregate_type`, `aggregate_id`, `aggregate_version`),
    KEY `idx_group_domain_history_aggregate`
        (`aggregate_type`, `aggregate_id`, `aggregate_version`, `id`),
    KEY `idx_group_domain_history_time` (`occurred_at`, `id`),
    KEY `idx_group_domain_history_actor` (`actor_kind`, `actor_ref`, `occurred_at`, `id`),
    KEY `idx_group_domain_history_correlation` (`correlation_id`, `id`),
    CONSTRAINT `chk_group_domain_history_event`
        CHECK (`event_id` REGEXP '^[a-z0-9][a-z0-9_:-]{7,47}$'),
    CONSTRAINT `chk_group_domain_history_aggregate_type`
        CHECK (`aggregate_type` REGEXP '^[a-z][a-z0-9_.:-]{1,47}$'),
    CONSTRAINT `chk_group_domain_history_aggregate_id`
        CHECK (`aggregate_id` REGEXP '^[a-z0-9][a-z0-9_:-]{7,47}$'),
    CONSTRAINT `chk_group_domain_history_version` CHECK (`aggregate_version` > 0),
    CONSTRAINT `chk_group_domain_history_type`
        CHECK (`event_type` REGEXP '^[a-z][a-z0-9_.:-]{1,95}$'),
    CONSTRAINT `chk_group_domain_history_source`
        CHECK (`source_resource` REGEXP '^[a-z][a-z0-9_]{1,63}$'),
    CONSTRAINT `chk_group_domain_history_actor`
        CHECK ((`actor_kind` = 'system' AND `actor_ref` IS NULL)
            OR (`actor_kind` IN ('resource', 'user', 'character') AND `actor_ref` IS NOT NULL)),
    CONSTRAINT `chk_group_domain_history_reason`
        CHECK (`reason_code` REGEXP '^[a-z][a-z0-9_.:-]{1,63}$'),
    CONSTRAINT `chk_group_domain_history_before`
        CHECK (`before_json` IS NULL OR JSON_VALID(`before_json`)),
    CONSTRAINT `chk_group_domain_history_after`
        CHECK (`after_json` IS NULL OR JSON_VALID(`after_json`)),
    CONSTRAINT `chk_group_domain_history_context`
        CHECK (`context_json` IS NULL OR JSON_VALID(`context_json`))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
INSERT INTO `synex_group_domain_history`
    (`event_id`, `aggregate_type`, `aggregate_id`, `aggregate_version`, `event_type`,
     `source_resource`, `actor_kind`, `actor_ref`, `reason_code`, `correlation_id`,
     `causation_id`, `before_json`, `after_json`, `context_json`, `occurred_at`)
SELECT `legacy`.`event_id`, 'membership', `membership`.`public_id`,
    `legacy`.`membership_version`, CONCAT('membership.', `legacy`.`event_type`),
    'synex_groups',
    CASE WHEN `legacy`.`actor_ref` IS NULL THEN 'system' ELSE 'character' END,
    `legacy`.`actor_ref`, 'legacy_backfill', NULL, NULL, NULL,
    `legacy`.`snapshot_json`, '{"source":"synex_group_membership_events"}',
    `legacy`.`occurred_at`
FROM `synex_group_membership_events` AS `legacy`
INNER JOIN `synex_group_memberships` AS `membership`
    ON `membership`.`id` = `legacy`.`membership_id`
LEFT JOIN `synex_group_domain_history` AS `history`
    ON `history`.`event_id` = `legacy`.`event_id`
WHERE `history`.`id` IS NULL;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_group_audit_delivery` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `history_id` BIGINT UNSIGNED NOT NULL,
    `state` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'pending',
    `attempts` SMALLINT UNSIGNED NOT NULL DEFAULT 0,
    `available_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `locked_by` VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `locked_until` DATETIME(6) NULL,
    `external_event_id` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `last_error_code` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `delivered_at` DATETIME(6) NULL,
    `version` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_group_audit_delivery_history` (`history_id`),
    UNIQUE KEY `uq_group_audit_delivery_external` (`external_event_id`),
    KEY `idx_group_audit_delivery_claim` (`state`, `available_at`, `locked_until`, `id`),
    CONSTRAINT `fk_group_audit_delivery_history`
        FOREIGN KEY (`history_id`) REFERENCES `synex_group_domain_history` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `chk_group_audit_delivery_state`
        CHECK (`state` IN ('pending', 'delivering', 'delivered', 'dead', 'suppressed')),
    CONSTRAINT `chk_group_audit_delivery_attempts` CHECK (`attempts` <= 1000),
    CONSTRAINT `chk_group_audit_delivery_lock`
        CHECK ((`state` = 'delivering' AND `locked_by` IS NOT NULL AND `locked_until` IS NOT NULL)
            OR (`state` <> 'delivering' AND `locked_by` IS NULL AND `locked_until` IS NULL)),
    CONSTRAINT `chk_group_audit_delivery_terminal`
        CHECK ((`state` = 'delivered' AND `external_event_id` IS NOT NULL
                AND `delivered_at` IS NOT NULL)
            OR (`state` <> 'delivered' AND `delivered_at` IS NULL)),
    CONSTRAINT `chk_group_audit_delivery_error`
        CHECK ((`state` = 'dead' AND `last_error_code` IS NOT NULL)
            OR (`state` <> 'dead')),
    CONSTRAINT `chk_group_audit_delivery_version` CHECK (`version` > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
INSERT INTO `synex_group_audit_delivery`
    (`history_id`, `state`, `attempts`, `available_at`, `locked_by`, `locked_until`,
     `external_event_id`, `last_error_code`, `delivered_at`, `version`, `created_at`, `updated_at`)
SELECT `history`.`id`, 'suppressed', 0, `history`.`occurred_at`, NULL, NULL,
    NULL, NULL, NULL, 1, `history`.`occurred_at`, `history`.`occurred_at`
FROM `synex_group_domain_history` AS `history`
LEFT JOIN `synex_group_audit_delivery` AS `delivery`
    ON `delivery`.`history_id` = `history`.`id`
WHERE `delivery`.`id` IS NULL;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_group_definition_sets` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `public_id` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `owner_resource` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `definition_key` VARCHAR(96) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `schema_version` INT UNSIGNED NOT NULL,
    `definition_json` LONGTEXT NOT NULL,
    `definition_digest` CHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `applied_digest` CHAR(64) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `state` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'registered',
    `drift_detected_at` DATETIME(6) NULL,
    `last_applied_at` DATETIME(6) NULL,
    `version` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_group_definition_sets_public` (`public_id`),
    UNIQUE KEY `uq_group_definition_sets_owner` (`owner_resource`, `definition_key`),
    KEY `idx_group_definition_sets_state` (`state`, `updated_at`, `id`),
    CONSTRAINT `chk_group_definition_sets_public`
        CHECK (`public_id` REGEXP '^[a-z][a-z0-9_]{7,47}$'),
    CONSTRAINT `chk_group_definition_sets_owner`
        CHECK (`owner_resource` REGEXP '^[a-z][a-z0-9_]{1,63}$'),
    CONSTRAINT `chk_group_definition_sets_key`
        CHECK (`definition_key` REGEXP '^[a-z][a-z0-9_.:-]{1,95}$'),
    CONSTRAINT `chk_group_definition_sets_schema_version` CHECK (`schema_version` > 0),
    CONSTRAINT `chk_group_definition_sets_json` CHECK (JSON_VALID(`definition_json`)),
    CONSTRAINT `chk_group_definition_sets_digest`
        CHECK (`definition_digest` REGEXP '^[0-9a-f]{64}$'
            AND (`applied_digest` IS NULL OR `applied_digest` REGEXP '^[0-9a-f]{64}$')),
    CONSTRAINT `chk_group_definition_sets_state`
        CHECK (`state` IN ('registered', 'applied', 'drifted', 'blocked', 'retired')),
    CONSTRAINT `chk_group_definition_sets_applied`
        CHECK ((`state` = 'applied' AND `applied_digest` = `definition_digest`
                AND `last_applied_at` IS NOT NULL AND `drift_detected_at` IS NULL)
            OR (`state` = 'drifted' AND `applied_digest` IS NOT NULL
                AND `applied_digest` <> `definition_digest` AND `drift_detected_at` IS NOT NULL)
            OR (`state` IN ('registered', 'blocked', 'retired'))),
    CONSTRAINT `chk_group_definition_sets_version` CHECK (`version` > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_group_definition_migrations` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `public_id` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `definition_set_id` BIGINT UNSIGNED NOT NULL,
    `from_schema_version` INT UNSIGNED NOT NULL,
    `to_schema_version` INT UNSIGNED NOT NULL,
    `from_digest` CHAR(64) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `to_digest` CHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `plan_json` LONGTEXT NOT NULL,
    `state` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'pending',
    `owner_ref` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `locked_until` DATETIME(6) NULL,
    `error_code` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `applied_at` DATETIME(6) NULL,
    `version` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_group_definition_migrations_public` (`public_id`),
    UNIQUE KEY `uq_group_definition_migrations_target`
        (`definition_set_id`, `to_schema_version`, `to_digest`),
    KEY `idx_group_definition_migrations_claim` (`state`, `locked_until`, `created_at`, `id`),
    CONSTRAINT `fk_group_definition_migrations_set`
        FOREIGN KEY (`definition_set_id`) REFERENCES `synex_group_definition_sets` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `chk_group_definition_migrations_public`
        CHECK (`public_id` REGEXP '^[a-z][a-z0-9_]{7,47}$'),
    CONSTRAINT `chk_group_definition_migrations_versions`
        CHECK (`to_schema_version` > `from_schema_version`),
    CONSTRAINT `chk_group_definition_migrations_digests`
        CHECK ((`from_digest` IS NULL OR `from_digest` REGEXP '^[0-9a-f]{64}$')
            AND `to_digest` REGEXP '^[0-9a-f]{64}$'),
    CONSTRAINT `chk_group_definition_migrations_plan` CHECK (JSON_VALID(`plan_json`)),
    CONSTRAINT `chk_group_definition_migrations_state`
        CHECK (`state` IN ('pending', 'applying', 'applied', 'failed', 'blocked')),
    CONSTRAINT `chk_group_definition_migrations_lock`
        CHECK ((`state` = 'applying' AND `owner_ref` IS NOT NULL AND `locked_until` IS NOT NULL)
            OR (`state` <> 'applying' AND `owner_ref` IS NULL AND `locked_until` IS NULL)),
    CONSTRAINT `chk_group_definition_migrations_terminal`
        CHECK ((`state` = 'applied' AND `applied_at` IS NOT NULL AND `error_code` IS NULL)
            OR (`state` IN ('failed', 'blocked') AND `applied_at` IS NULL
                AND `error_code` IS NOT NULL)
            OR (`state` IN ('pending', 'applying') AND `applied_at` IS NULL
                AND `error_code` IS NULL)),
    CONSTRAINT `chk_group_definition_migrations_version` CHECK (`version` > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_group_definition_issues` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `public_id` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `definition_set_id` BIGINT UNSIGNED NOT NULL,
    `issue_code` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `target_kind` VARCHAR(24) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `target_ref` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT '',
    `details_json` LONGTEXT NOT NULL,
    `state` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'open',
    `open_marker` TINYINT UNSIGNED GENERATED ALWAYS AS
        (CASE WHEN `state` = 'open' THEN 1 ELSE NULL END) STORED,
    `resolved_by_ref` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `resolution_reason_code` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `resolved_at` DATETIME(6) NULL,
    `version` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_group_definition_issues_public` (`public_id`),
    UNIQUE KEY `uq_group_definition_issues_open`
        (`definition_set_id`, `issue_code`, `target_kind`, `target_ref`, `open_marker`),
    KEY `idx_group_definition_issues_state` (`state`, `created_at`, `id`),
    CONSTRAINT `fk_group_definition_issues_set`
        FOREIGN KEY (`definition_set_id`) REFERENCES `synex_group_definition_sets` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `chk_group_definition_issues_public`
        CHECK (`public_id` REGEXP '^[a-z][a-z0-9_]{7,47}$'),
    CONSTRAINT `chk_group_definition_issues_code`
        CHECK (`issue_code` REGEXP '^[A-Z][A-Z0-9_]{2,63}$'),
    CONSTRAINT `chk_group_definition_issues_target`
        CHECK ((`target_kind` = 'definition' AND `target_ref` = '')
            OR (`target_kind` IN ('group', 'membership', 'grade', 'role', 'policy')
                AND `target_ref` REGEXP '^[a-z0-9][a-z0-9_:-]{7,47}$')),
    CONSTRAINT `chk_group_definition_issues_details` CHECK (JSON_VALID(`details_json`)),
    CONSTRAINT `chk_group_definition_issues_state`
        CHECK (`state` IN ('open', 'resolved', 'waived')),
    CONSTRAINT `chk_group_definition_issues_terminal`
        CHECK ((`state` = 'open' AND `resolved_by_ref` IS NULL
                AND `resolution_reason_code` IS NULL AND `resolved_at` IS NULL)
            OR (`state` IN ('resolved', 'waived') AND `resolved_by_ref` IS NOT NULL
                AND `resolution_reason_code` IS NOT NULL AND `resolved_at` IS NOT NULL)),
    CONSTRAINT `chk_group_definition_issues_version` CHECK (`version` > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_group_retention_policies` (
    `record_kind` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `disposition` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'retain',
    `retention_days` INT UNSIGNED NULL,
    `batch_size` SMALLINT UNSIGNED NOT NULL DEFAULT 250,
    `legal_hold` TINYINT UNSIGNED NOT NULL DEFAULT 0,
    `status` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'active',
    `version` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`record_kind`),
    KEY `idx_group_retention_policies_status` (`status`, `record_kind`),
    CONSTRAINT `chk_group_retention_policies_kind`
        CHECK (`record_kind` REGEXP '^[a-z][a-z0-9_.:-]{1,47}$'),
    CONSTRAINT `chk_group_retention_policies_disposition`
        CHECK (`disposition` IN ('retain', 'archive', 'anonymize', 'purge')),
    CONSTRAINT `chk_group_retention_policies_days`
        CHECK ((`disposition` = 'retain' AND `retention_days` IS NULL)
            OR (`disposition` <> 'retain' AND `retention_days` > 0)),
    CONSTRAINT `chk_group_retention_policies_batch`
        CHECK (`batch_size` BETWEEN 1 AND 1000),
    CONSTRAINT `chk_group_retention_policies_hold` CHECK (`legal_hold` IN (0, 1)),
    CONSTRAINT `chk_group_retention_policies_status`
        CHECK (`status` IN ('active', 'suspended')),
    CONSTRAINT `chk_group_retention_policies_version` CHECK (`version` > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_group_retention_checkpoints` (
    `record_kind` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `cursor_time` DATETIME(6) NULL,
    `cursor_id` BIGINT UNSIGNED NOT NULL DEFAULT 0,
    `owner_ref` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `locked_until` DATETIME(6) NULL,
    `last_completed_at` DATETIME(6) NULL,
    `version` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`record_kind`),
    KEY `idx_group_retention_checkpoints_lock` (`locked_until`, `record_kind`),
    CONSTRAINT `fk_group_retention_checkpoints_policy`
        FOREIGN KEY (`record_kind`) REFERENCES `synex_group_retention_policies` (`record_kind`) ON DELETE RESTRICT,
    CONSTRAINT `chk_group_retention_checkpoints_cursor`
        CHECK ((`cursor_time` IS NULL AND `cursor_id` = 0)
            OR (`cursor_time` IS NOT NULL AND `cursor_id` > 0)),
    CONSTRAINT `chk_group_retention_checkpoints_lock`
        CHECK ((`owner_ref` IS NULL AND `locked_until` IS NULL)
            OR (`owner_ref` IS NOT NULL AND `locked_until` IS NOT NULL)),
    CONSTRAINT `chk_group_retention_checkpoints_version` CHECK (`version` > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_group_domain_history_archive` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `source_history_id` BIGINT UNSIGNED NOT NULL,
    `event_id` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `aggregate_type` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `aggregate_id` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `aggregate_version` BIGINT UNSIGNED NOT NULL,
    `event_type` VARCHAR(96) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `source_resource` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `actor_kind` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `actor_ref` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `reason_code` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `correlation_id` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `causation_id` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `before_json` LONGTEXT NULL,
    `after_json` LONGTEXT NULL,
    `context_json` LONGTEXT NULL,
    `occurred_at` DATETIME(6) NOT NULL,
    `archive_batch_ref` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `archived_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_group_history_archive_source` (`source_history_id`),
    UNIQUE KEY `uq_group_history_archive_event` (`event_id`),
    KEY `idx_group_history_archive_aggregate`
        (`aggregate_type`, `aggregate_id`, `aggregate_version`, `id`),
    KEY `idx_group_history_archive_time` (`occurred_at`, `id`),
    KEY `idx_group_history_archive_batch` (`archive_batch_ref`, `id`),
    CONSTRAINT `chk_group_history_archive_event`
        CHECK (`event_id` REGEXP '^[a-z0-9][a-z0-9_:-]{7,47}$'),
    CONSTRAINT `chk_group_history_archive_aggregate`
        CHECK (`aggregate_type` REGEXP '^[a-z][a-z0-9_.:-]{1,47}$'
            AND `aggregate_id` REGEXP '^[a-z0-9][a-z0-9_:-]{7,47}$'
            AND `aggregate_version` > 0),
    CONSTRAINT `chk_group_history_archive_type`
        CHECK (`event_type` REGEXP '^[a-z][a-z0-9_.:-]{1,95}$'),
    CONSTRAINT `chk_group_history_archive_source`
        CHECK (`source_resource` REGEXP '^[a-z][a-z0-9_]{1,63}$'),
    CONSTRAINT `chk_group_history_archive_actor`
        CHECK ((`actor_kind` = 'system' AND `actor_ref` IS NULL)
            OR (`actor_kind` IN ('resource', 'user', 'character') AND `actor_ref` IS NOT NULL)),
    CONSTRAINT `chk_group_history_archive_reason`
        CHECK (`reason_code` REGEXP '^[a-z][a-z0-9_.:-]{1,63}$'),
    CONSTRAINT `chk_group_history_archive_before`
        CHECK (`before_json` IS NULL OR JSON_VALID(`before_json`)),
    CONSTRAINT `chk_group_history_archive_after`
        CHECK (`after_json` IS NULL OR JSON_VALID(`after_json`)),
    CONSTRAINT `chk_group_history_archive_context`
        CHECK (`context_json` IS NULL OR JSON_VALID(`context_json`)),
    CONSTRAINT `chk_group_history_archive_batch`
        CHECK (`archive_batch_ref` REGEXP '^[a-z0-9][a-z0-9_:-]{7,47}$')
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
