CREATE TABLE IF NOT EXISTS `synex_instance_boots` (
    `instance_id` VARCHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `boot_id` VARCHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `registered_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`instance_id`),
    UNIQUE KEY `uq_instance_boot_id` (`boot_id`),
    CONSTRAINT `fk_instance_boot_instance`
        FOREIGN KEY (`instance_id`) REFERENCES `synex_instances` (`instance_id`) ON DELETE RESTRICT,
    CONSTRAINT `chk_instance_boot_id` CHECK (CHAR_LENGTH(`boot_id`) BETWEEN 1 AND 36)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
