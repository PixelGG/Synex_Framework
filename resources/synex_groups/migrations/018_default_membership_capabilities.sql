CREATE TABLE IF NOT EXISTS `synex_group_default_capabilities` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `group_id` BIGINT UNSIGNED NOT NULL,
    `capability_pattern` VARCHAR(96) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `effect` VARCHAR(8) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `scope_kind` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'group',
    `scope_ref` VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT '',
    `version` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_group_default_capability`
        (`group_id`, `capability_pattern`, `scope_kind`, `scope_ref`),
    KEY `idx_group_default_capability_read` (`group_id`, `id`),
    CONSTRAINT `fk_group_default_capability_group`
        FOREIGN KEY (`group_id`) REFERENCES `synex_groups` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `chk_group_default_capability_pattern`
        CHECK (`capability_pattern` REGEXP
            '^[a-z][a-z0-9_-]*(\\.[a-z][a-z0-9_-]*)*(\\.\\*)?$'),
    CONSTRAINT `chk_group_default_capability_effect` CHECK (`effect` IN ('allow', 'deny')),
    CONSTRAINT `chk_group_default_capability_scope`
        CHECK ((`scope_kind` = 'group' AND `scope_ref` = '')
            OR (`scope_kind` IN ('subtree', 'custom') AND CHAR_LENGTH(`scope_ref`) > 0)),
    CONSTRAINT `chk_group_default_capability_version` CHECK (`version` > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_group_membership_capabilities` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `membership_id` BIGINT UNSIGNED NOT NULL,
    `capability_pattern` VARCHAR(96) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `effect` VARCHAR(8) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `scope_kind` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'group',
    `scope_ref` VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT '',
    `valid_from` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `valid_until` DATETIME(6) NULL,
    `version` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_group_membership_capability`
        (`membership_id`, `capability_pattern`, `scope_kind`, `scope_ref`),
    KEY `idx_group_membership_capability_read`
        (`membership_id`, `valid_from`, `valid_until`, `id`),
    CONSTRAINT `fk_group_membership_capability_membership`
        FOREIGN KEY (`membership_id`) REFERENCES `synex_group_memberships` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `chk_group_membership_capability_pattern`
        CHECK (`capability_pattern` REGEXP
            '^[a-z][a-z0-9_-]*(\\.[a-z][a-z0-9_-]*)*(\\.\\*)?$'),
    CONSTRAINT `chk_group_membership_capability_effect` CHECK (`effect` IN ('allow', 'deny')),
    CONSTRAINT `chk_group_membership_capability_scope`
        CHECK ((`scope_kind` = 'group' AND `scope_ref` = '')
            OR (`scope_kind` IN ('subtree', 'custom') AND CHAR_LENGTH(`scope_ref`) > 0)),
    CONSTRAINT `chk_group_membership_capability_window`
        CHECK (`valid_until` IS NULL OR `valid_until` > `valid_from`),
    CONSTRAINT `chk_group_membership_capability_version` CHECK (`version` > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
