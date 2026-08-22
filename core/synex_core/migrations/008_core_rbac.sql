CREATE TABLE IF NOT EXISTS `synex_rbac_roles` (
    `role_name` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `description` VARCHAR(256) NULL,
    `version` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`role_name`),
    CONSTRAINT `chk_rbac_roles_name`
        CHECK (`role_name` REGEXP '^[a-z][a-z0-9_.-]{0,63}$'),
    CONSTRAINT `chk_rbac_roles_version` CHECK (`version` > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_rbac_role_permissions` (
    `role_name` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `permission_key` VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `effect` VARCHAR(8) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`role_name`, `permission_key`, `effect`),
    KEY `idx_rbac_permissions_key` (`permission_key`, `effect`),
    CONSTRAINT `fk_rbac_permissions_role`
        FOREIGN KEY (`role_name`) REFERENCES `synex_rbac_roles` (`role_name`) ON DELETE CASCADE,
    CONSTRAINT `chk_rbac_permissions_key`
        CHECK (`permission_key` REGEXP '^[a-z][a-z0-9._*-]{0,127}$'),
    CONSTRAINT `chk_rbac_permissions_effect` CHECK (`effect` IN ('allow', 'deny'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_rbac_subject_roles` (
    `subject_ref` VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `role_name` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `assigned_by_ref` VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `assigned_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `expires_at` DATETIME(6) NULL,
    PRIMARY KEY (`subject_ref`, `role_name`),
    KEY `idx_rbac_subject_roles_expiry` (`expires_at`, `subject_ref`),
    KEY `idx_rbac_subject_roles_role` (`role_name`, `expires_at`),
    CONSTRAINT `fk_rbac_subject_roles_role`
        FOREIGN KEY (`role_name`) REFERENCES `synex_rbac_roles` (`role_name`) ON DELETE RESTRICT,
    CONSTRAINT `chk_rbac_subject_ref`
        CHECK (`subject_ref` REGEXP '^[a-z][a-z0-9_-]*:[A-Za-z0-9_.:-]+$'),
    CONSTRAINT `chk_rbac_subject_roles_expiry`
        CHECK (`expires_at` IS NULL OR `expires_at` > `assigned_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_rbac_subject_versions` (
    `subject_ref` VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `version` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`subject_ref`),
    CONSTRAINT `chk_rbac_subject_versions_ref`
        CHECK (`subject_ref` REGEXP '^[a-z][a-z0-9_-]*:[A-Za-z0-9_.:-]+$'),
    CONSTRAINT `chk_rbac_subject_versions_value` CHECK (`version` > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
