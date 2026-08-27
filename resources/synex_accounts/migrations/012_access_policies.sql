INSERT IGNORE INTO `synex_account_reason_codes`
    (`reason_code`, `owner_resource`, `display_name`, `description`, `status`)
VALUES
    ('synex_accounts.access', 'synex_accounts', 'Account access change',
        'A grant, role, or permission change for an account.', 'active'),
    ('synex_accounts.restriction', 'synex_accounts', 'Account restriction',
        'A server-authoritative incoming or outgoing account restriction.', 'active'),
    ('synex_accounts.policy', 'synex_accounts', 'Account policy',
        'A server-authoritative account balance or operation policy.', 'active');

-- synex:statement
ALTER TABLE `synex_account_access_role_permissions`
    MODIFY COLUMN `permission_key`
        VARCHAR(32) CHARACTER SET ascii COLLATE ascii_bin NOT NULL;

-- synex:statement
ALTER TABLE `synex_account_access_role_permissions`
    DROP CONSTRAINT IF EXISTS `chk_account_access_permissions_key`;

-- synex:statement
ALTER TABLE `synex_account_access_role_permissions`
    ADD CONSTRAINT `chk_account_access_permissions_key`
        CHECK (`permission_key` IN (
            'view', 'deposit', 'withdraw', 'transfer', 'history', 'manage', 'close',
            'balance.read', 'history.read',
            'hold.create', 'hold.capture', 'hold.release',
            'access.read', 'access.manage', 'settings.manage'
        ));

-- synex:statement
ALTER TABLE `synex_account_access_grants`
    ADD COLUMN IF NOT EXISTS `valid_from`
        DATETIME(6) NULL AFTER `active_marker`;

-- synex:statement
UPDATE `synex_account_access_grants`
SET `valid_from` = `created_at`
WHERE `valid_from` IS NULL;

-- synex:statement
ALTER TABLE `synex_account_access_grants`
    MODIFY COLUMN `valid_from` DATETIME(6) NOT NULL;

-- synex:statement
CREATE INDEX IF NOT EXISTS `idx_account_access_grants_window`
    ON `synex_account_access_grants`
        (`status`, `valid_from`, `valid_until`, `id`);

-- synex:statement
CREATE INDEX IF NOT EXISTS `idx_account_access_grants_principal_window`
    ON `synex_account_access_grants`
        (`principal_kind`, `principal_ref`, `status`, `valid_from`, `valid_until`, `id`);

-- synex:statement
ALTER TABLE `synex_account_access_grants`
    DROP CONSTRAINT IF EXISTS `chk_account_access_grants_validity`;

-- synex:statement
ALTER TABLE `synex_account_access_grants`
    ADD CONSTRAINT `chk_account_access_grants_validity`
        CHECK (`valid_until` IS NULL OR `valid_until` > `valid_from`);

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_account_restrictions` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `public_id` CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `operation_id` BIGINT UNSIGNED NOT NULL,
    `account_id` BIGINT UNSIGNED NOT NULL,
    `restriction_kind` VARCHAR(24) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `status` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'active',
    `active_marker` TINYINT UNSIGNED NULL DEFAULT 1,
    `reason_code` VARCHAR(96) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `reason_text` VARCHAR(256) NULL,
    `source_resource` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `trace_id` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `actor_kind` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `actor_ref` VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `valid_from` DATETIME(6) NOT NULL,
    `valid_until` DATETIME(6) NULL,
    `version` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
        ON UPDATE CURRENT_TIMESTAMP(6),
    `terminal_at` DATETIME(6) NULL,
    `termination_reason` VARCHAR(256) NULL,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_account_restrictions_public_id` (`public_id`),
    UNIQUE KEY `uq_account_restrictions_operation` (`operation_id`),
    UNIQUE KEY `uq_account_restrictions_active`
        (`account_id`, `restriction_kind`, `active_marker`),
    KEY `idx_account_restrictions_account_window`
        (`account_id`, `status`, `valid_from`, `valid_until`, `id`),
    KEY `idx_account_restrictions_kind_window`
        (`restriction_kind`, `status`, `valid_until`, `id`),
    CONSTRAINT `fk_account_restrictions_operation`
        FOREIGN KEY (`operation_id`) REFERENCES `synex_account_operations` (`id`)
        ON DELETE RESTRICT,
    CONSTRAINT `fk_account_restrictions_account`
        FOREIGN KEY (`account_id`) REFERENCES `synex_accounts` (`id`)
        ON DELETE RESTRICT,
    CONSTRAINT `fk_account_restrictions_reason`
        FOREIGN KEY (`reason_code`) REFERENCES `synex_account_reason_codes` (`reason_code`)
        ON DELETE RESTRICT,
    CONSTRAINT `chk_account_restrictions_kind`
        CHECK (`restriction_kind` IN
            ('outgoing_blocked', 'incoming_blocked', 'all_blocked')),
    CONSTRAINT `chk_account_restrictions_state`
        CHECK ((`status` = 'active' AND `active_marker` = 1
                AND `terminal_at` IS NULL AND `termination_reason` IS NULL)
            OR (`status` IN ('revoked', 'expired') AND `active_marker` IS NULL
                AND `terminal_at` IS NOT NULL)),
    CONSTRAINT `chk_account_restrictions_window`
        CHECK ((`valid_until` IS NULL OR `valid_until` > `valid_from`)
            AND (`status` <> 'expired' OR `valid_until` IS NOT NULL)),
    CONSTRAINT `chk_account_restrictions_source`
        CHECK (`source_resource` REGEXP '^[a-z][a-z0-9_]{1,63}$'),
    CONSTRAINT `chk_account_restrictions_trace`
        CHECK (`trace_id` IS NULL OR (CHAR_LENGTH(`trace_id`) BETWEEN 8 AND 64
            AND `trace_id` REGEXP '^[A-Za-z0-9][A-Za-z0-9_.:-]*$')),
    CONSTRAINT `chk_account_restrictions_actor`
        CHECK (`actor_kind` IS NULL OR (`actor_kind` IN
            ('system', 'resource', 'user', 'character', 'group', 'operator', 'migration')
            AND `actor_ref` IS NOT NULL)),
    CONSTRAINT `chk_account_restrictions_version`
        CHECK (`version` > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_account_policies` (
    `account_id` BIGINT UNSIGNED NOT NULL,
    `operation_id` BIGINT UNSIGNED NOT NULL,
    `minimum_balance_minor` BIGINT NULL,
    `maximum_balance_minor` BIGINT NULL,
    `single_transfer_limit_minor` BIGINT UNSIGNED NULL,
    `daily_outgoing_limit_minor` BIGINT UNSIGNED NULL,
    `operation_mode` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin
        NOT NULL DEFAULT 'all',
    `reason_code` VARCHAR(96) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `source_resource` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `trace_id` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `actor_kind` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `actor_ref` VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `version` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
        ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`account_id`),
    UNIQUE KEY `uq_account_policies_operation` (`operation_id`),
    CONSTRAINT `fk_account_policies_account`
        FOREIGN KEY (`account_id`) REFERENCES `synex_accounts` (`id`)
        ON DELETE RESTRICT,
    CONSTRAINT `fk_account_policies_operation`
        FOREIGN KEY (`operation_id`) REFERENCES `synex_account_operations` (`id`)
        ON DELETE RESTRICT,
    CONSTRAINT `fk_account_policies_reason`
        FOREIGN KEY (`reason_code`) REFERENCES `synex_account_reason_codes` (`reason_code`)
        ON DELETE RESTRICT,
    CONSTRAINT `chk_account_policies_balances`
        CHECK ((`minimum_balance_minor` IS NULL OR `minimum_balance_minor`
                    BETWEEN -9007199254740991 AND 9007199254740991)
            AND (`maximum_balance_minor` IS NULL OR `maximum_balance_minor`
                    BETWEEN -9007199254740991 AND 9007199254740991)
            AND (`minimum_balance_minor` IS NULL OR `maximum_balance_minor` IS NULL
                OR `minimum_balance_minor` <= `maximum_balance_minor`)),
    CONSTRAINT `chk_account_policies_limits`
        CHECK ((`single_transfer_limit_minor` IS NULL
                    OR `single_transfer_limit_minor` BETWEEN 1 AND 9007199254740991)
            AND (`daily_outgoing_limit_minor` IS NULL
                    OR `daily_outgoing_limit_minor` BETWEEN 1 AND 9007199254740991)),
    CONSTRAINT `chk_account_policies_mode`
        CHECK (`operation_mode` IN ('all', 'allowlist')),
    CONSTRAINT `chk_account_policies_source`
        CHECK (`source_resource` REGEXP '^[a-z][a-z0-9_]{1,63}$'),
    CONSTRAINT `chk_account_policies_trace`
        CHECK (`trace_id` IS NULL OR (CHAR_LENGTH(`trace_id`) BETWEEN 8 AND 64
            AND `trace_id` REGEXP '^[A-Za-z0-9][A-Za-z0-9_.:-]*$')),
    CONSTRAINT `chk_account_policies_actor`
        CHECK (`actor_kind` IS NULL OR (`actor_kind` IN
            ('system', 'resource', 'user', 'character', 'group', 'operator', 'migration')
            AND `actor_ref` IS NOT NULL)),
    CONSTRAINT `chk_account_policies_version`
        CHECK (`version` > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_account_policy_allowed_operations` (
    `account_id` BIGINT UNSIGNED NOT NULL,
    `operation_key` VARCHAR(32) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`account_id`, `operation_key`),
    KEY `idx_account_policy_allowed_operation` (`operation_key`, `account_id`),
    CONSTRAINT `fk_account_policy_allowed_account`
        FOREIGN KEY (`account_id`) REFERENCES `synex_account_policies` (`account_id`)
        ON DELETE RESTRICT,
    CONSTRAINT `chk_account_policy_allowed_operation`
        CHECK (`operation_key` IN (
            'post', 'deposit', 'withdraw', 'transfer', 'mint', 'burn',
            'reversal', 'refund', 'hold.create', 'hold.capture', 'hold.release'
        ))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_account_policy_daily_usage` (
    `account_id` BIGINT UNSIGNED NOT NULL,
    `usage_date` DATE NOT NULL,
    `outgoing_minor` BIGINT UNSIGNED NOT NULL DEFAULT 0,
    `operation_count` BIGINT UNSIGNED NOT NULL DEFAULT 0,
    `version` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
        ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`account_id`, `usage_date`),
    KEY `idx_account_policy_daily_usage_date` (`usage_date`, `account_id`),
    CONSTRAINT `fk_account_policy_daily_usage_account`
        FOREIGN KEY (`account_id`) REFERENCES `synex_accounts` (`id`)
        ON DELETE RESTRICT,
    CONSTRAINT `chk_account_policy_daily_usage_amount`
        CHECK (`outgoing_minor` <= 9007199254740991),
    CONSTRAINT `chk_account_policy_daily_usage_version`
        CHECK (`version` > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
INSERT IGNORE INTO `synex_account_access_role_permissions`
    (`role_id`, `permission_key`)
SELECT `role`.`id`, `permission`.`permission_key`
FROM `synex_account_access_roles` AS `role`
CROSS JOIN (
    SELECT 'balance.read' AS `permission_key`
    UNION ALL SELECT 'history.read'
    UNION ALL SELECT 'deposit'
    UNION ALL SELECT 'withdraw'
    UNION ALL SELECT 'transfer'
    UNION ALL SELECT 'hold.create'
    UNION ALL SELECT 'hold.capture'
    UNION ALL SELECT 'hold.release'
    UNION ALL SELECT 'access.read'
    UNION ALL SELECT 'access.manage'
    UNION ALL SELECT 'settings.manage'
    UNION ALL SELECT 'close'
) AS `permission`
WHERE `role`.`role_key` = 'owner';

-- synex:statement
INSERT INTO `synex_account_migration_assertions`
    (`migration_id`, `violation_count`, `details_json`)
SELECT '012_access_policies',
    (SELECT COUNT(*) FROM `synex_account_access_grants`
        WHERE `valid_from` IS NULL
            OR (`valid_until` IS NOT NULL AND `valid_until` <= `valid_from`))
    + (SELECT COUNT(*)
        FROM `synex_account_access_roles` AS `role`
        CROSS JOIN (
            SELECT 'balance.read' AS `permission_key`
            UNION ALL SELECT 'history.read'
            UNION ALL SELECT 'deposit'
            UNION ALL SELECT 'withdraw'
            UNION ALL SELECT 'transfer'
            UNION ALL SELECT 'hold.create'
            UNION ALL SELECT 'hold.capture'
            UNION ALL SELECT 'hold.release'
            UNION ALL SELECT 'access.read'
            UNION ALL SELECT 'access.manage'
            UNION ALL SELECT 'settings.manage'
            UNION ALL SELECT 'close'
        ) AS `required`
        WHERE `role`.`role_key` = 'owner'
            AND NOT EXISTS (
                SELECT 1 FROM `synex_account_access_role_permissions` AS `permission`
                WHERE `permission`.`role_id` = `role`.`id`
                    AND `permission`.`permission_key` = `required`.`permission_key`)),
    JSON_OBJECT(
        'legacyPermissionsRetained', TRUE,
        'canonicalPermissionCount', 12,
        'restrictionKinds', JSON_ARRAY(
            'outgoing_blocked', 'incoming_blocked', 'all_blocked')
    )
ON DUPLICATE KEY UPDATE
    `violation_count` = VALUES(`violation_count`),
    `details_json` = VALUES(`details_json`),
    `verified_at` = CURRENT_TIMESTAMP(6);
