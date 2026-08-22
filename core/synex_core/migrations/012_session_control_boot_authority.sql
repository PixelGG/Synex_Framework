CREATE TABLE IF NOT EXISTS `synex_session_control_authority` (
    `request_id` CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `requester_boot_id` VARCHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `recorded_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`request_id`),
    CONSTRAINT `fk_session_control_authority_request`
        FOREIGN KEY (`request_id`) REFERENCES `synex_session_control_requests` (`request_id`) ON DELETE RESTRICT,
    CONSTRAINT `chk_session_control_authority_boot`
        CHECK (CHAR_LENGTH(`requester_boot_id`) BETWEEN 1 AND 36)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
