ALTER TABLE `synex_economy_integrity_read_models`
    ADD COLUMN IF NOT EXISTS `cutoff_transaction_id`
        BIGINT UNSIGNED NOT NULL DEFAULT 0 AFTER `cutoff_posting_id`,
    ADD COLUMN IF NOT EXISTS `cutoff_entry_id`
        BIGINT UNSIGNED NOT NULL DEFAULT 0 AFTER `cutoff_transaction_id`,
    ADD COLUMN IF NOT EXISTS `entry_count`
        BIGINT UNSIGNED NOT NULL DEFAULT 0 AFTER `posting_count`,
    ADD COLUMN IF NOT EXISTS `account_count`
        BIGINT UNSIGNED NOT NULL DEFAULT 0 AFTER `entry_count`,
    ADD COLUMN IF NOT EXISTS `total_entry_sum_minor`
        DECIMAL(36, 0) NOT NULL DEFAULT 0 AFTER `total_credit_minor`,
    ADD COLUMN IF NOT EXISTS `minted_minor`
        DECIMAL(36, 0) UNSIGNED NOT NULL DEFAULT 0 AFTER `total_entry_sum_minor`,
    ADD COLUMN IF NOT EXISTS `burned_minor`
        DECIMAL(36, 0) UNSIGNED NOT NULL DEFAULT 0 AFTER `minted_minor`,
    ADD COLUMN IF NOT EXISTS `net_supply_minor`
        DECIMAL(36, 0) NOT NULL DEFAULT 0 AFTER `burned_minor`,
    ADD COLUMN IF NOT EXISTS `active_held_minor`
        DECIMAL(36, 0) UNSIGNED NOT NULL DEFAULT 0 AFTER `total_booked_minor`,
    ADD COLUMN IF NOT EXISTS `transaction_sum_violation_count`
        BIGINT UNSIGNED NOT NULL DEFAULT 0 AFTER `orphan_transaction_count`,
    ADD COLUMN IF NOT EXISTS `snapshot_drift_count`
        BIGINT UNSIGNED NOT NULL DEFAULT 0 AFTER `transaction_sum_violation_count`,
    ADD COLUMN IF NOT EXISTS `invalid_hold_count`
        BIGINT UNSIGNED NOT NULL DEFAULT 0 AFTER `snapshot_drift_count`,
    ADD COLUMN IF NOT EXISTS `refund_limit_violation_count`
        BIGINT UNSIGNED NOT NULL DEFAULT 0 AFTER `invalid_hold_count`,
    ADD COLUMN IF NOT EXISTS `invalid_reversal_count`
        BIGINT UNSIGNED NOT NULL DEFAULT 0 AFTER `refund_limit_violation_count`,
    ADD COLUMN IF NOT EXISTS `invalid_topology_count`
        BIGINT UNSIGNED NOT NULL DEFAULT 0 AFTER `invalid_reversal_count`,
    ADD COLUMN IF NOT EXISTS `outbox_problem_count`
        BIGINT UNSIGNED NOT NULL DEFAULT 0 AFTER `invalid_topology_count`,
    ADD COLUMN IF NOT EXISTS `grant_problem_count`
        BIGINT UNSIGNED NOT NULL DEFAULT 0 AFTER `outbox_problem_count`,
    ADD COLUMN IF NOT EXISTS `sequence_problem_count`
        BIGINT UNSIGNED NOT NULL DEFAULT 0 AFTER `grant_problem_count`,
    ADD COLUMN IF NOT EXISTS `idempotency_problem_count`
        BIGINT UNSIGNED NOT NULL DEFAULT 0 AFTER `sequence_problem_count`,
    ADD COLUMN IF NOT EXISTS `info_count`
        BIGINT UNSIGNED NOT NULL DEFAULT 0 AFTER `idempotency_problem_count`,
    ADD COLUMN IF NOT EXISTS `warn_count`
        BIGINT UNSIGNED NOT NULL DEFAULT 0 AFTER `info_count`,
    ADD COLUMN IF NOT EXISTS `error_count`
        BIGINT UNSIGNED NOT NULL DEFAULT 0 AFTER `warn_count`,
    ADD COLUMN IF NOT EXISTS `critical_count`
        BIGINT UNSIGNED NOT NULL DEFAULT 0 AFTER `error_count`;

-- synex:statement
ALTER TABLE `synex_economy_integrity_read_models`
    MODIFY COLUMN `finding_count` BIGINT UNSIGNED NOT NULL DEFAULT 0;

-- synex:statement
ALTER TABLE `synex_economy_integrity_read_models`
    DROP CONSTRAINT IF EXISTS `chk_economy_integrity_status`;

-- synex:statement
ALTER TABLE `synex_economy_integrity_read_models`
    ADD CONSTRAINT `chk_economy_integrity_status`
        CHECK (`status` IN ('healthy', 'warn', 'error', 'critical'));

-- synex:statement
CREATE INDEX IF NOT EXISTS `idx_economy_integrity_generated`
    ON `synex_economy_integrity_read_models`
        (`generated_at`, `currency_id`);

-- synex:statement
ALTER TABLE `synex_economy_reconciliation_runs`
    ADD COLUMN IF NOT EXISTS `cutoff_transaction_id`
        BIGINT UNSIGNED NOT NULL DEFAULT 0 AFTER `cutoff_posting_id`,
    ADD COLUMN IF NOT EXISTS `cutoff_entry_id`
        BIGINT UNSIGNED NOT NULL DEFAULT 0 AFTER `cutoff_transaction_id`,
    ADD COLUMN IF NOT EXISTS `entry_count`
        BIGINT UNSIGNED NOT NULL DEFAULT 0 AFTER `posting_count`,
    ADD COLUMN IF NOT EXISTS `account_count`
        BIGINT UNSIGNED NOT NULL DEFAULT 0 AFTER `entry_count`,
    ADD COLUMN IF NOT EXISTS `total_entry_sum_minor`
        DECIMAL(36, 0) NOT NULL DEFAULT 0 AFTER `total_credit_minor`,
    ADD COLUMN IF NOT EXISTS `minted_minor`
        DECIMAL(36, 0) UNSIGNED NOT NULL DEFAULT 0 AFTER `total_entry_sum_minor`,
    ADD COLUMN IF NOT EXISTS `burned_minor`
        DECIMAL(36, 0) UNSIGNED NOT NULL DEFAULT 0 AFTER `minted_minor`,
    ADD COLUMN IF NOT EXISTS `net_supply_minor`
        DECIMAL(36, 0) NOT NULL DEFAULT 0 AFTER `burned_minor`,
    ADD COLUMN IF NOT EXISTS `active_held_minor`
        DECIMAL(36, 0) UNSIGNED NOT NULL DEFAULT 0 AFTER `total_booked_minor`,
    ADD COLUMN IF NOT EXISTS `transaction_sum_violation_count`
        BIGINT UNSIGNED NOT NULL DEFAULT 0 AFTER `active_held_minor`,
    ADD COLUMN IF NOT EXISTS `snapshot_drift_count`
        BIGINT UNSIGNED NOT NULL DEFAULT 0 AFTER `transaction_sum_violation_count`,
    ADD COLUMN IF NOT EXISTS `invalid_hold_count`
        BIGINT UNSIGNED NOT NULL DEFAULT 0 AFTER `snapshot_drift_count`,
    ADD COLUMN IF NOT EXISTS `refund_limit_violation_count`
        BIGINT UNSIGNED NOT NULL DEFAULT 0 AFTER `invalid_hold_count`,
    ADD COLUMN IF NOT EXISTS `invalid_reversal_count`
        BIGINT UNSIGNED NOT NULL DEFAULT 0 AFTER `refund_limit_violation_count`,
    ADD COLUMN IF NOT EXISTS `invalid_topology_count`
        BIGINT UNSIGNED NOT NULL DEFAULT 0 AFTER `invalid_reversal_count`,
    ADD COLUMN IF NOT EXISTS `outbox_problem_count`
        BIGINT UNSIGNED NOT NULL DEFAULT 0 AFTER `invalid_topology_count`,
    ADD COLUMN IF NOT EXISTS `grant_problem_count`
        BIGINT UNSIGNED NOT NULL DEFAULT 0 AFTER `outbox_problem_count`,
    ADD COLUMN IF NOT EXISTS `sequence_problem_count`
        BIGINT UNSIGNED NOT NULL DEFAULT 0 AFTER `grant_problem_count`,
    ADD COLUMN IF NOT EXISTS `idempotency_problem_count`
        BIGINT UNSIGNED NOT NULL DEFAULT 0 AFTER `sequence_problem_count`,
    ADD COLUMN IF NOT EXISTS `info_count`
        BIGINT UNSIGNED NOT NULL DEFAULT 0 AFTER `idempotency_problem_count`,
    ADD COLUMN IF NOT EXISTS `warn_count`
        BIGINT UNSIGNED NOT NULL DEFAULT 0 AFTER `info_count`,
    ADD COLUMN IF NOT EXISTS `error_count`
        BIGINT UNSIGNED NOT NULL DEFAULT 0 AFTER `warn_count`,
    ADD COLUMN IF NOT EXISTS `critical_count`
        BIGINT UNSIGNED NOT NULL DEFAULT 0 AFTER `error_count`,
    ADD COLUMN IF NOT EXISTS `source_resource`
        VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'legacy'
        AFTER `requested_by_ref`,
    ADD COLUMN IF NOT EXISTS `trace_id`
        VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NULL AFTER `source_resource`,
    ADD COLUMN IF NOT EXISTS `actor_kind`
        VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NULL AFTER `trace_id`,
    ADD COLUMN IF NOT EXISTS `summary_json`
        LONGTEXT NULL AFTER `actor_kind`,
    ADD COLUMN IF NOT EXISTS `started_at`
        DATETIME(6) NULL AFTER `summary_json`,
    ADD COLUMN IF NOT EXISTS `completed_at`
        DATETIME(6) NULL AFTER `created_at`;

-- synex:statement
UPDATE `synex_economy_reconciliation_runs`
SET `source_resource` = COALESCE(`source_resource`, 'legacy'),
    `actor_kind` = CASE
        WHEN `requested_by_ref` IS NULL THEN NULL ELSE 'migration' END,
    `summary_json` = COALESCE(`summary_json`, JSON_OBJECT('source', 'legacy')),
    `started_at` = COALESCE(`started_at`, `created_at`),
    `completed_at` = COALESCE(`completed_at`, `created_at`);

-- synex:statement
ALTER TABLE `synex_economy_reconciliation_runs`
    MODIFY COLUMN `finding_count` BIGINT UNSIGNED NOT NULL;

-- synex:statement
ALTER TABLE `synex_economy_reconciliation_runs`
    DROP CONSTRAINT IF EXISTS `chk_economy_reconciliation_runs_status`,
    DROP CONSTRAINT IF EXISTS `chk_economy_reconciliation_runs_source`,
    DROP CONSTRAINT IF EXISTS `chk_economy_reconciliation_runs_trace`,
    DROP CONSTRAINT IF EXISTS `chk_economy_reconciliation_runs_actor`,
    DROP CONSTRAINT IF EXISTS `chk_economy_reconciliation_runs_summary`,
    DROP CONSTRAINT IF EXISTS `chk_economy_reconciliation_runs_terminal`;

-- synex:statement
ALTER TABLE `synex_economy_reconciliation_runs`
    ADD CONSTRAINT `chk_economy_reconciliation_runs_status`
        CHECK (`status` IN
            ('running', 'healthy', 'warn', 'error', 'critical', 'failed')),
    ADD CONSTRAINT `chk_economy_reconciliation_runs_source`
        CHECK (`source_resource` REGEXP '^[a-z][a-z0-9_]{1,63}$'),
    ADD CONSTRAINT `chk_economy_reconciliation_runs_trace`
        CHECK (`trace_id` IS NULL OR (CHAR_LENGTH(`trace_id`) BETWEEN 8 AND 64
            AND `trace_id` REGEXP '^[A-Za-z0-9][A-Za-z0-9_.:-]*$')),
    ADD CONSTRAINT `chk_economy_reconciliation_runs_actor`
        CHECK (`actor_kind` IS NULL OR (`actor_kind` IN
            ('system', 'resource', 'user', 'character', 'group', 'operator', 'migration')
            AND `requested_by_ref` IS NOT NULL)),
    ADD CONSTRAINT `chk_economy_reconciliation_runs_summary`
        CHECK (`summary_json` IS NULL OR JSON_VALID(`summary_json`)),
    ADD CONSTRAINT `chk_economy_reconciliation_runs_terminal`
        CHECK (`completed_at` IS NULL OR `completed_at` >= `started_at`);

-- synex:statement
CREATE INDEX IF NOT EXISTS `idx_economy_reconciliation_runs_status`
    ON `synex_economy_reconciliation_runs`
        (`status`, `created_at`, `id`);

-- synex:statement
CREATE INDEX IF NOT EXISTS `idx_economy_reconciliation_runs_trace`
    ON `synex_economy_reconciliation_runs` (`trace_id`, `id`);

-- synex:statement
ALTER TABLE `synex_economy_anomaly_findings`
    MODIFY COLUMN `rule_key`
        VARCHAR(96) CHARACTER SET ascii COLLATE ascii_bin NOT NULL;

-- synex:statement
ALTER TABLE `synex_economy_anomaly_findings`
    DROP CONSTRAINT IF EXISTS `chk_economy_anomaly_findings_rule`,
    DROP CONSTRAINT IF EXISTS `chk_economy_anomaly_findings_severity`;

-- synex:statement
ALTER TABLE `synex_economy_anomaly_findings`
    ADD CONSTRAINT `chk_economy_anomaly_findings_rule`
        CHECK (`rule_key` REGEXP '^[a-z][a-z0-9_.:-]{2,95}$'),
    ADD CONSTRAINT `chk_economy_anomaly_findings_severity`
        CHECK (`severity` IN ('info', 'warn', 'error', 'critical'));

-- synex:statement
CREATE INDEX IF NOT EXISTS `idx_economy_anomaly_findings_severity`
    ON `synex_economy_anomaly_findings`
        (`severity`, `created_at`, `id`);

-- synex:statement
CREATE INDEX IF NOT EXISTS `idx_economy_anomaly_findings_rule_time`
    ON `synex_economy_anomaly_findings`
        (`rule_key`, `created_at`, `id`);

-- synex:statement
ALTER TABLE `synex_account_outbox`
    ADD COLUMN IF NOT EXISTS `trace_id`
        VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NULL AFTER `schema_version`,
    ADD COLUMN IF NOT EXISTS `last_attempt_at`
        DATETIME(6) NULL AFTER `attempts`,
    ADD COLUMN IF NOT EXISTS `last_error_code`
        VARCHAR(96) CHARACTER SET ascii COLLATE ascii_bin NULL AFTER `last_attempt_at`,
    ADD COLUMN IF NOT EXISTS `last_error_at`
        DATETIME(6) NULL AFTER `last_error_code`,
    ADD COLUMN IF NOT EXISTS `dead_at`
        DATETIME(6) NULL AFTER `published_at`,
    ADD COLUMN IF NOT EXISTS `manual_retry_count`
        SMALLINT UNSIGNED NOT NULL DEFAULT 0 AFTER `dead_at`,
    ADD COLUMN IF NOT EXISTS `updated_at`
        DATETIME(6) NULL AFTER `created_at`;

-- synex:statement
UPDATE `synex_account_outbox`
SET `last_attempt_at` = CASE WHEN `attempts` > 0
        THEN COALESCE(`last_attempt_at`, `locked_until`, `available_at`, `created_at`)
        ELSE `last_attempt_at` END,
    `last_error_code` = CASE WHEN `state` = 'dead'
        THEN COALESCE(`last_error_code`, 'LEGACY_DEAD_LETTER')
        ELSE `last_error_code` END,
    `last_error_at` = CASE WHEN `state` = 'dead'
        THEN COALESCE(`last_error_at`, `last_attempt_at`, `locked_until`, `created_at`)
        ELSE `last_error_at` END,
    `dead_at` = CASE WHEN `state` = 'dead'
        THEN COALESCE(`dead_at`, `last_error_at`, `last_attempt_at`, `created_at`)
        ELSE NULL END,
    `updated_at` = COALESCE(`updated_at`, `published_at`, `dead_at`, `created_at`);

-- synex:statement
ALTER TABLE `synex_account_outbox`
    MODIFY COLUMN `updated_at`
        DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
        ON UPDATE CURRENT_TIMESTAMP(6);

-- synex:statement
ALTER TABLE `synex_account_outbox`
    DROP CONSTRAINT IF EXISTS `chk_account_outbox_trace`,
    DROP CONSTRAINT IF EXISTS `chk_account_outbox_error_pair`,
    DROP CONSTRAINT IF EXISTS `chk_account_outbox_dead_state`,
    DROP CONSTRAINT IF EXISTS `chk_account_outbox_attempt_time`;

-- synex:statement
ALTER TABLE `synex_account_outbox`
    ADD CONSTRAINT `chk_account_outbox_trace`
        CHECK (`trace_id` IS NULL OR (CHAR_LENGTH(`trace_id`) BETWEEN 8 AND 64
            AND `trace_id` REGEXP '^[A-Za-z0-9][A-Za-z0-9_.:-]*$')),
    ADD CONSTRAINT `chk_account_outbox_error_pair`
        CHECK ((`last_error_code` IS NULL) = (`last_error_at` IS NULL)),
    ADD CONSTRAINT `chk_account_outbox_dead_state`
        CHECK ((`state` = 'published' AND `published_at` IS NOT NULL
                AND `dead_at` IS NULL)
            OR (`state` = 'dead' AND `published_at` IS NULL
                AND `dead_at` IS NOT NULL AND `last_error_code` IS NOT NULL)
            OR (`state` IN ('pending', 'publishing')
                AND `published_at` IS NULL AND `dead_at` IS NULL)),
    ADD CONSTRAINT `chk_account_outbox_attempt_time`
        CHECK ((`attempts` = 0 AND `last_attempt_at` IS NULL)
            OR (`attempts` > 0 AND `last_attempt_at` IS NOT NULL));

-- synex:statement
CREATE INDEX IF NOT EXISTS `idx_account_outbox_health`
    ON `synex_account_outbox` (`state`, `attempts`, `available_at`, `id`);

-- synex:statement
CREATE INDEX IF NOT EXISTS `idx_account_outbox_errors`
    ON `synex_account_outbox` (`last_error_at`, `state`, `id`);

-- synex:statement
CREATE INDEX IF NOT EXISTS `idx_account_outbox_trace`
    ON `synex_account_outbox` (`trace_id`, `id`);

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_account_outbox_attempts` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `event_id` CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `outbox_id` BIGINT UNSIGNED NOT NULL,
    `attempt_no` INT UNSIGNED NOT NULL,
    `worker_id` VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `outcome` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `error_code` VARCHAR(96) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `duration_ms` INT UNSIGNED NOT NULL,
    `occurred_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_account_outbox_attempts_sequence` (`outbox_id`, `attempt_no`),
    KEY `idx_account_outbox_attempts_event` (`event_id`, `id`),
    KEY `idx_account_outbox_attempts_outcome` (`outcome`, `occurred_at`, `id`),
    CONSTRAINT `fk_account_outbox_attempts_outbox`
        FOREIGN KEY (`outbox_id`) REFERENCES `synex_account_outbox` (`id`)
        ON DELETE RESTRICT,
    CONSTRAINT `chk_account_outbox_attempts_sequence`
        CHECK (`attempt_no` > 0),
    CONSTRAINT `chk_account_outbox_attempts_worker`
        CHECK (CHAR_LENGTH(`worker_id`) BETWEEN 1 AND 128),
    CONSTRAINT `chk_account_outbox_attempts_outcome`
        CHECK ((`outcome` = 'published' AND `error_code` IS NULL)
            OR (`outcome` IN ('retry', 'dead') AND `error_code` IS NOT NULL)),
    CONSTRAINT `chk_account_outbox_attempts_duration`
        CHECK (`duration_ms` <= 3600000)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_account_outbox_retry_requests` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `public_id` CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `outbox_id` BIGINT UNSIGNED NOT NULL,
    `idempotency_key` VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `requested_by_resource`
        VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `requested_by_ref`
        VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `reason` VARCHAR(256) NOT NULL,
    `state` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'pending',
    `failure_code` VARCHAR(96) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `completed_at` DATETIME(6) NULL,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_account_outbox_retry_requests_public` (`public_id`),
    UNIQUE KEY `uq_account_outbox_retry_requests_scope`
        (`requested_by_resource`, `idempotency_key`),
    KEY `idx_account_outbox_retry_requests_outbox` (`outbox_id`, `created_at`, `id`),
    KEY `idx_account_outbox_retry_requests_state` (`state`, `created_at`, `id`),
    CONSTRAINT `fk_account_outbox_retry_requests_outbox`
        FOREIGN KEY (`outbox_id`) REFERENCES `synex_account_outbox` (`id`)
        ON DELETE RESTRICT,
    CONSTRAINT `chk_account_outbox_retry_requests_key`
        CHECK (CHAR_LENGTH(`idempotency_key`) BETWEEN 8 AND 128
            AND `idempotency_key` REGEXP '^[A-Za-z0-9][A-Za-z0-9_.:-]*$'),
    CONSTRAINT `chk_account_outbox_retry_requests_resource`
        CHECK (`requested_by_resource` REGEXP '^[a-z][a-z0-9_]{1,63}$'),
    CONSTRAINT `chk_account_outbox_retry_requests_reason`
        CHECK (CHAR_LENGTH(`reason`) BETWEEN 1 AND 256),
    CONSTRAINT `chk_account_outbox_retry_requests_state`
        CHECK ((`state` = 'pending' AND `completed_at` IS NULL
                AND `failure_code` IS NULL)
            OR (`state` = 'applied' AND `completed_at` IS NOT NULL
                AND `failure_code` IS NULL)
            OR (`state` = 'rejected' AND `completed_at` IS NOT NULL
                AND `failure_code` IS NOT NULL)),
    CONSTRAINT `chk_account_outbox_retry_requests_failure`
        CHECK (`failure_code` IS NULL
            OR `failure_code` REGEXP '^[A-Z][A-Z0-9_]{2,95}$')
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE INDEX IF NOT EXISTS `idx_ledger_entries_account_transaction`
    ON `synex_ledger_entries` (`account_id`, `transaction_id`, `sequence_no`);

-- synex:statement
CREATE INDEX IF NOT EXISTS `idx_account_balance_snapshots_account_time`
    ON `synex_account_balance_snapshots` (`account_id`, `created_at`, `sequence_no`);

-- synex:statement
CREATE INDEX IF NOT EXISTS `idx_ledger_refund_anchors_state`
    ON `synex_ledger_refund_anchors` (`state`, `updated_at`, `original_transaction_id`);

-- synex:statement
INSERT INTO `synex_account_migration_assertions`
    (`migration_id`, `violation_count`, `details_json`)
SELECT '014_integrity_outbox_control',
    (SELECT COUNT(*) FROM `synex_account_outbox`
        WHERE (`last_error_code` IS NULL) <> (`last_error_at` IS NULL))
    + (SELECT COUNT(*)
        FROM `synex_ledger_refund_anchors` AS `anchor`
        LEFT JOIN (
            SELECT `anchor_transaction_id`, SUM(`amount_minor`) AS `refunded_minor`,
                MAX(`cumulative_refunded_minor`) AS `maximum_cumulative`
            FROM `synex_ledger_refunds`
            GROUP BY `anchor_transaction_id`
        ) AS `refund`
            ON `refund`.`anchor_transaction_id` = `anchor`.`original_transaction_id`
        WHERE `anchor`.`refunded_minor` <> COALESCE(`refund`.`refunded_minor`, 0)
            OR `anchor`.`refunded_minor` > `anchor`.`refundable_minor`
            OR COALESCE(`refund`.`maximum_cumulative`, 0) > `anchor`.`refundable_minor`),
    JSON_OBJECT(
        'integrityModel', 'multi_leg_additive',
        'outboxAttempts', 'append_only',
        'manualRetry', 'scoped_idempotency'
    )
ON DUPLICATE KEY UPDATE
    `violation_count` = VALUES(`violation_count`),
    `details_json` = VALUES(`details_json`),
    `verified_at` = CURRENT_TIMESTAMP(6);
