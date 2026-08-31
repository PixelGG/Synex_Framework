CREATE TABLE IF NOT EXISTS `synex_security_cases` (
    `case_id` VARCHAR(64) NOT NULL,
    `subject_kind` VARCHAR(16) NOT NULL,
    `subject_ref` VARCHAR(128) NOT NULL,
    `user_id` VARCHAR(96) NULL,
    `session_id` VARCHAR(96) NULL,
    `category` VARCHAR(32) NOT NULL,
    `severity` VARCHAR(16) NOT NULL,
    `confidence` DECIMAL(6,5) NOT NULL,
    `status` VARCHAR(16) NOT NULL,
    `signal_count` INT UNSIGNED NOT NULL DEFAULT 0,
    `enforcement_count` INT UNSIGNED NOT NULL DEFAULT 0,
    `summary_json` LONGTEXT NOT NULL,
    `opened_at` DATETIME(3) NOT NULL,
    `updated_at` DATETIME(3) NOT NULL,
    `closed_at` DATETIME(3) NULL,
    `revision` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    PRIMARY KEY (`case_id`),
    KEY `idx_security_cases_subject` (`subject_kind`, `subject_ref`, `updated_at`),
    KEY `idx_security_cases_status` (`status`, `updated_at`),
    KEY `idx_security_cases_category` (`category`, `updated_at`),
    CONSTRAINT `chk_security_cases_summary_json`
        CHECK (JSON_VALID(`summary_json`))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_security_case_signals` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `case_id` VARCHAR(64) NOT NULL,
    `signal_id` VARCHAR(64) NOT NULL,
    `category` VARCHAR(32) NOT NULL,
    `detector` VARCHAR(128) NOT NULL,
    `code` VARCHAR(96) NOT NULL,
    `evidence_class` VARCHAR(32) NOT NULL,
    `severity` VARCHAR(16) NOT NULL,
    `confidence` DECIMAL(6,5) NOT NULL,
    `observed_at` DATETIME(3) NOT NULL,
    `trace_id` VARCHAR(96) NULL,
    `root_event_id` VARCHAR(96) NULL,
    `summary_json` LONGTEXT NOT NULL,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_security_case_signal` (`signal_id`),
    KEY `idx_security_case_signals_case` (`case_id`, `observed_at`),
    KEY `idx_security_case_signals_code` (`code`, `observed_at`),
    CONSTRAINT `fk_security_case_signals_case`
        FOREIGN KEY (`case_id`) REFERENCES `synex_security_cases` (`case_id`)
        ON DELETE CASCADE,
    CONSTRAINT `chk_security_case_signals_summary_json`
        CHECK (JSON_VALID(`summary_json`))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_security_enforcements` (
    `enforcement_id` VARCHAR(64) NOT NULL,
    `case_id` VARCHAR(64) NOT NULL,
    `action` VARCHAR(24) NOT NULL,
    `policy` VARCHAR(96) NOT NULL,
    `idempotency_key` VARCHAR(256) NOT NULL,
    `outcome` VARCHAR(24) NOT NULL,
    `trace_id` VARCHAR(96) NULL,
    `summary_json` LONGTEXT NOT NULL,
    `created_at` DATETIME(3) NOT NULL,
    PRIMARY KEY (`enforcement_id`),
    UNIQUE KEY `uq_security_enforcement_idempotency` (`idempotency_key`),
    KEY `idx_security_enforcements_case` (`case_id`, `created_at`),
    KEY `idx_security_enforcements_recovery`
        (`outcome`, `created_at`, `enforcement_id`),
    CONSTRAINT `fk_security_enforcements_case`
        FOREIGN KEY (`case_id`) REFERENCES `synex_security_cases` (`case_id`)
        ON DELETE CASCADE,
    CONSTRAINT `chk_security_enforcements_summary_json`
        CHECK (JSON_VALID(`summary_json`))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
