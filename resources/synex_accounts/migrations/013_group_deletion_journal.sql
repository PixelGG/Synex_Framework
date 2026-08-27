CREATE TABLE IF NOT EXISTS `synex_account_group_deletions` (
    `plan_id` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `action_id` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `group_ref` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `anonymous_ref` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `request_fingerprint` CHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `decision` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `state` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'pending',
    `account_count` INT UNSIGNED NOT NULL DEFAULT 0,
    `nonzero_account_count` INT UNSIGNED NOT NULL DEFAULT 0,
    `grant_count` INT UNSIGNED NOT NULL DEFAULT 0,
    `nonterminal_hold_count` INT UNSIGNED NOT NULL DEFAULT 0,
    `booked_minor_total` DECIMAL(36, 0) NOT NULL DEFAULT 0,
    `reason_text` VARCHAR(512) NOT NULL,
    `source_resource` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `trace_id` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `response_json` LONGTEXT NULL,
    `failure_code` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `version` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
        ON UPDATE CURRENT_TIMESTAMP(6),
    `completed_at` DATETIME(6) NULL,
    PRIMARY KEY (`plan_id`),
    UNIQUE KEY `uq_account_group_deletions_action` (`action_id`),
    KEY `idx_account_group_deletions_group`
        (`group_ref`, `created_at`, `plan_id`),
    KEY `idx_account_group_deletions_state`
        (`state`, `updated_at`, `plan_id`),
    CONSTRAINT `chk_account_group_deletions_plan`
        CHECK (`plan_id` REGEXP '^[a-z0-9_]{1,47}$'),
    CONSTRAINT `chk_account_group_deletions_action`
        CHECK (CHAR_LENGTH(`action_id`) BETWEEN 8 AND 64
            AND `action_id` REGEXP '^[A-Za-z0-9][A-Za-z0-9_.:%-]*$'),
    CONSTRAINT `chk_account_group_deletions_group`
        CHECK (CHAR_LENGTH(`group_ref`) BETWEEN 8 AND 48
            AND `group_ref` REGEXP '^[A-Za-z0-9][A-Za-z0-9_.:%-]*$'),
    CONSTRAINT `chk_account_group_deletions_anonymous`
        CHECK ((`decision` = 'anonymize' AND `anonymous_ref` IS NOT NULL
                AND CHAR_LENGTH(`anonymous_ref`) BETWEEN 8 AND 48
                AND `anonymous_ref` REGEXP '^[A-Za-z0-9][A-Za-z0-9_.:%-]*$')
            OR (`decision` <> 'anonymize' AND `anonymous_ref` IS NULL)),
    CONSTRAINT `chk_account_group_deletions_fingerprint`
        CHECK (`request_fingerprint` REGEXP '^[0-9a-f]{64}$'),
    CONSTRAINT `chk_account_group_deletions_decision`
        CHECK (`decision` IN ('block', 'anonymize', 'retain')),
    CONSTRAINT `chk_account_group_deletions_state`
        CHECK ((`decision` = 'anonymize' AND `state` IN ('pending', 'completed', 'failed'))
            OR (`decision` = 'block' AND `state` = 'blocked')
            OR (`decision` = 'retain' AND `state` = 'completed')),
    CONSTRAINT `chk_account_group_deletions_terminal`
        CHECK ((`state` = 'pending' AND `completed_at` IS NULL
                AND `response_json` IS NULL AND `failure_code` IS NULL)
            OR (`state` = 'completed' AND `completed_at` IS NOT NULL
                AND `response_json` IS NOT NULL AND `failure_code` IS NULL)
            OR (`state` = 'blocked' AND `completed_at` IS NOT NULL
                AND `failure_code` IS NOT NULL)
            OR (`state` = 'failed' AND `completed_at` IS NOT NULL
                AND `failure_code` IS NOT NULL)),
    CONSTRAINT `chk_account_group_deletions_completion_safety`
        CHECK (`state` <> 'completed' OR `decision` = 'retain'
            OR (`nonzero_account_count` = 0
                AND `nonterminal_hold_count` = 0 AND `booked_minor_total` = 0)),
    CONSTRAINT `chk_account_group_deletions_reason`
        CHECK (CHAR_LENGTH(`reason_text`) BETWEEN 1 AND 512),
    CONSTRAINT `chk_account_group_deletions_source`
        CHECK (`source_resource` REGEXP '^[a-z][a-z0-9_]{1,63}$'),
    CONSTRAINT `chk_account_group_deletions_trace`
        CHECK (`trace_id` IS NULL OR (CHAR_LENGTH(`trace_id`) BETWEEN 8 AND 64
            AND `trace_id` REGEXP '^[A-Za-z0-9][A-Za-z0-9_.:-]*$')),
    CONSTRAINT `chk_account_group_deletions_response`
        CHECK (`response_json` IS NULL OR JSON_VALID(`response_json`)),
    CONSTRAINT `chk_account_group_deletions_failure`
        CHECK (`failure_code` IS NULL
            OR `failure_code` REGEXP '^[A-Z][A-Z0-9_]{2,63}$'),
    CONSTRAINT `chk_account_group_deletions_version`
        CHECK (`version` > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
INSERT INTO `synex_account_migration_assertions`
    (`migration_id`, `violation_count`, `details_json`)
SELECT '013_group_deletion_journal',
    COUNT(*),
    JSON_OBJECT(
        'idempotencyIdentity', 'action_id',
        'crossResourceForeignKeys', FALSE,
        'ledgerHistoryRetained', TRUE
    )
FROM `synex_account_group_deletions`
WHERE (`state` = 'completed' AND `decision` = 'anonymize'
        AND (`nonzero_account_count` <> 0
            OR `nonterminal_hold_count` <> 0 OR `booked_minor_total` <> 0))
    OR (`state` = 'pending' AND `decision` <> 'anonymize')
ON DUPLICATE KEY UPDATE
    `violation_count` = VALUES(`violation_count`),
    `details_json` = VALUES(`details_json`),
    `verified_at` = CURRENT_TIMESTAMP(6);
