CREATE TABLE IF NOT EXISTS `synex_group_roles` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `public_id` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `group_id` BIGINT UNSIGNED NOT NULL,
    `role_key` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `display_name` VARCHAR(96) NOT NULL,
    `description` VARCHAR(512) NULL,
    `exclusivity` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'none',
    `holder_limit` SMALLINT UNSIGNED NULL,
    `status` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'active',
    `version` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_group_roles_public_id` (`public_id`),
    UNIQUE KEY `uq_group_roles_group_key` (`group_id`, `role_key`),
    KEY `idx_group_roles_group_status` (`group_id`, `status`, `role_key`, `id`),
    CONSTRAINT `fk_group_roles_group`
        FOREIGN KEY (`group_id`) REFERENCES `synex_groups` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `chk_group_roles_public_id`
        CHECK (`public_id` REGEXP '^[a-z][a-z0-9_]{7,47}$'),
    CONSTRAINT `chk_group_roles_key`
        CHECK (`role_key` REGEXP '^[a-z][a-z0-9_]{1,63}$'),
    CONSTRAINT `chk_group_roles_exclusivity`
        CHECK (`exclusivity` IN ('none', 'group')),
    CONSTRAINT `chk_group_roles_holder_limit`
        CHECK (`holder_limit` IS NULL OR `holder_limit` > 0),
    CONSTRAINT `chk_group_roles_status`
        CHECK (`status` IN ('active', 'disabled', 'retired')),
    CONSTRAINT `chk_group_roles_version` CHECK (`version` > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_group_role_capabilities` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `role_id` BIGINT UNSIGNED NOT NULL,
    `capability_pattern` VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `effect` VARCHAR(8) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `scope_kind` VARCHAR(24) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'group',
    `scope_ref` VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT '',
    `version` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_group_role_capability`
        (`role_id`, `capability_pattern`, `scope_kind`, `scope_ref`),
    KEY `idx_group_role_capability_lookup`
        (`capability_pattern`, `effect`, `scope_kind`, `role_id`),
    CONSTRAINT `fk_group_role_capabilities_role`
        FOREIGN KEY (`role_id`) REFERENCES `synex_group_roles` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `chk_group_role_capability_pattern`
        CHECK (`capability_pattern` REGEXP '^[a-z][a-z0-9_.:*?-]{0,127}$'
            AND `capability_pattern` = LOWER(`capability_pattern`)),
    CONSTRAINT `chk_group_role_capability_effect`
        CHECK (`effect` IN ('allow', 'deny')),
    CONSTRAINT `chk_group_role_capability_scope`
        CHECK (`scope_kind` IN ('global', 'group', 'relationship', 'assignment', 'custom')
            AND ((`scope_kind` IN ('global', 'group') AND `scope_ref` = '')
                OR (`scope_kind` NOT IN ('global', 'group') AND `scope_ref` <> ''))),
    CONSTRAINT `chk_group_role_capability_version` CHECK (`version` > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_group_grade_capability_scopes` (
    `grade_capability_id` BIGINT UNSIGNED NOT NULL,
    `scope_kind` VARCHAR(24) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'group',
    `scope_ref` VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT '',
    `version` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`grade_capability_id`),
    KEY `idx_group_grade_scope_lookup` (`scope_kind`, `scope_ref`, `grade_capability_id`),
    CONSTRAINT `fk_group_grade_capability_scope`
        FOREIGN KEY (`grade_capability_id`)
        REFERENCES `synex_group_grade_capabilities` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `chk_group_grade_capability_scope`
        CHECK (`scope_kind` IN ('global', 'group', 'relationship', 'assignment', 'custom')
            AND ((`scope_kind` IN ('global', 'group') AND `scope_ref` = '')
                OR (`scope_kind` NOT IN ('global', 'group') AND `scope_ref` <> ''))),
    CONSTRAINT `chk_group_grade_capability_scope_version` CHECK (`version` > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
INSERT INTO `synex_group_grade_capability_scopes`
    (`grade_capability_id`, `scope_kind`, `scope_ref`, `version`)
SELECT `capability`.`id`, 'group', '', `capability`.`version`
FROM `synex_group_grade_capabilities` AS `capability`
LEFT JOIN `synex_group_grade_capability_scopes` AS `scope`
    ON `scope`.`grade_capability_id` = `capability`.`id`
WHERE `scope`.`grade_capability_id` IS NULL;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_group_grade_controls` (
    `grade_id` BIGINT UNSIGNED NOT NULL,
    `member_limit` INT UNSIGNED NULL,
    `promotion_requires_approval` TINYINT UNSIGNED NOT NULL DEFAULT 0,
    `version` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`grade_id`),
    CONSTRAINT `fk_group_grade_controls_grade`
        FOREIGN KEY (`grade_id`) REFERENCES `synex_group_grades` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `chk_group_grade_controls_limit`
        CHECK (`member_limit` IS NULL OR `member_limit` > 0),
    CONSTRAINT `chk_group_grade_controls_approval`
        CHECK (`promotion_requires_approval` IN (0, 1)),
    CONSTRAINT `chk_group_grade_controls_version` CHECK (`version` > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
INSERT INTO `synex_group_grade_controls`
    (`grade_id`, `member_limit`, `promotion_requires_approval`, `version`)
SELECT `grade`.`id`, NULL, 0, `grade`.`version`
FROM `synex_group_grades` AS `grade`
LEFT JOIN `synex_group_grade_controls` AS `control`
    ON `control`.`grade_id` = `grade`.`id`
WHERE `control`.`grade_id` IS NULL;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_group_membership_roles` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `public_id` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `membership_id` BIGINT UNSIGNED NOT NULL,
    `role_id` BIGINT UNSIGNED NOT NULL,
    `exclusive_role_id` BIGINT UNSIGNED NULL,
    `status` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'active',
    `valid_from` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `valid_until` DATETIME(6) NULL,
    `revoked_at` DATETIME(6) NULL,
    `assigned_by_ref` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `reason_code` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `version` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    `active_marker` TINYINT UNSIGNED
        GENERATED ALWAYS AS (CASE WHEN `status` = 'active' THEN 1 ELSE NULL END) STORED,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_group_membership_roles_public` (`public_id`),
    UNIQUE KEY `uq_group_membership_roles_active`
        (`membership_id`, `role_id`, `active_marker`),
    UNIQUE KEY `uq_group_membership_roles_exclusive`
        (`exclusive_role_id`, `active_marker`),
    KEY `idx_group_membership_roles_member`
        (`membership_id`, `status`, `valid_until`, `role_id`),
    KEY `idx_group_membership_roles_role`
        (`role_id`, `status`, `valid_until`, `membership_id`),
    KEY `idx_group_membership_roles_expiry` (`status`, `valid_until`, `id`),
    CONSTRAINT `fk_group_membership_roles_membership`
        FOREIGN KEY (`membership_id`) REFERENCES `synex_group_memberships` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `fk_group_membership_roles_role`
        FOREIGN KEY (`role_id`) REFERENCES `synex_group_roles` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `fk_group_membership_roles_exclusive`
        FOREIGN KEY (`exclusive_role_id`) REFERENCES `synex_group_roles` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `chk_group_membership_roles_public`
        CHECK (`public_id` REGEXP '^[a-z][a-z0-9_]{7,47}$'),
    CONSTRAINT `chk_group_membership_roles_exclusive`
        CHECK (`exclusive_role_id` IS NULL OR `exclusive_role_id` = `role_id`),
    CONSTRAINT `chk_group_membership_roles_status`
        CHECK (`status` IN ('active', 'revoked', 'expired')),
    CONSTRAINT `chk_group_membership_roles_window`
        CHECK (`valid_until` IS NULL OR `valid_until` > `valid_from`),
    CONSTRAINT `chk_group_membership_roles_terminal`
        CHECK ((`status` = 'active' AND `revoked_at` IS NULL)
            OR (`status` <> 'active' AND `revoked_at` IS NOT NULL)),
    CONSTRAINT `chk_group_membership_roles_reason`
        CHECK (`reason_code` REGEXP '^[a-z][a-z0-9_.:-]{1,63}$'),
    CONSTRAINT `chk_group_membership_roles_version` CHECK (`version` > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_group_policies` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `public_id` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `group_id` BIGINT UNSIGNED NOT NULL,
    `policy_key` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `display_name` VARCHAR(96) NOT NULL,
    `status` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'active',
    `default_effect` VARCHAR(8) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'deny',
    `version` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_group_policies_public_id` (`public_id`),
    UNIQUE KEY `uq_group_policies_group_key` (`group_id`, `policy_key`),
    KEY `idx_group_policies_group_status` (`group_id`, `status`, `policy_key`, `id`),
    CONSTRAINT `fk_group_policies_group`
        FOREIGN KEY (`group_id`) REFERENCES `synex_groups` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `chk_group_policies_public_id`
        CHECK (`public_id` REGEXP '^[a-z][a-z0-9_]{7,47}$'),
    CONSTRAINT `chk_group_policies_key`
        CHECK (`policy_key` REGEXP '^[a-z][a-z0-9_.:-]{1,63}$'),
    CONSTRAINT `chk_group_policies_status`
        CHECK (`status` IN ('active', 'disabled', 'retired')),
    CONSTRAINT `chk_group_policies_effect`
        CHECK (`default_effect` IN ('allow', 'deny')),
    CONSTRAINT `chk_group_policies_version` CHECK (`version` > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_group_policy_rules` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `policy_id` BIGINT UNSIGNED NOT NULL,
    `rule_key` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `priority` SMALLINT NOT NULL DEFAULT 0,
    `effect` VARCHAR(8) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `action_pattern` VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `subject_kind` VARCHAR(24) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `scope_kind` VARCHAR(24) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'group',
    `scope_ref` VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT '',
    `condition_json` LONGTEXT NULL,
    `version` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_group_policy_rules_key` (`policy_id`, `rule_key`),
    KEY `idx_group_policy_rules_eval`
        (`policy_id`, `priority`, `effect`, `action_pattern`, `id`),
    CONSTRAINT `fk_group_policy_rules_policy`
        FOREIGN KEY (`policy_id`) REFERENCES `synex_group_policies` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `chk_group_policy_rules_key`
        CHECK (`rule_key` REGEXP '^[a-z][a-z0-9_.:-]{1,63}$'),
    CONSTRAINT `chk_group_policy_rules_effect` CHECK (`effect` IN ('allow', 'deny')),
    CONSTRAINT `chk_group_policy_rules_action`
        CHECK (`action_pattern` REGEXP '^[a-z][a-z0-9_.:*?-]{0,127}$'),
    CONSTRAINT `chk_group_policy_rules_subject`
        CHECK (`subject_kind` IN ('character', 'membership', 'resource', 'system')),
    CONSTRAINT `chk_group_policy_rules_scope`
        CHECK (`scope_kind` IN ('global', 'group', 'relationship', 'assignment', 'custom')
            AND ((`scope_kind` IN ('global', 'group') AND `scope_ref` = '')
                OR (`scope_kind` NOT IN ('global', 'group') AND `scope_ref` <> ''))),
    CONSTRAINT `chk_group_policy_rules_condition`
        CHECK (`condition_json` IS NULL OR JSON_VALID(`condition_json`)),
    CONSTRAINT `chk_group_policy_rules_version` CHECK (`version` > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_group_attribute_schemas` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `public_id` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `owner_resource` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `group_type_id` BIGINT UNSIGNED NULL,
    `group_type_scope_id` BIGINT UNSIGNED
        GENERATED ALWAYS AS (COALESCE(`group_type_id`, 0)) STORED,
    `attribute_key` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `display_name` VARCHAR(96) NOT NULL,
    `value_kind` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `visibility` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'private',
    `required_value` TINYINT UNSIGNED NOT NULL DEFAULT 0,
    `validation_json` LONGTEXT NULL,
    `status` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'active',
    `version` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_group_attribute_schemas_public` (`public_id`),
    UNIQUE KEY `uq_group_attribute_schemas_key`
        (`owner_resource`, `group_type_scope_id`, `attribute_key`),
    KEY `idx_group_attribute_schemas_type`
        (`group_type_id`, `status`, `attribute_key`, `id`),
    CONSTRAINT `fk_group_attribute_schemas_type`
        FOREIGN KEY (`group_type_id`) REFERENCES `synex_group_types` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `chk_group_attribute_schemas_public`
        CHECK (`public_id` REGEXP '^[a-z][a-z0-9_]{7,47}$'),
    CONSTRAINT `chk_group_attribute_schemas_owner`
        CHECK (`owner_resource` REGEXP '^synex_[a-z0-9_]+$'),
    CONSTRAINT `chk_group_attribute_schemas_key`
        CHECK (`attribute_key` REGEXP '^[a-z][a-z0-9_.:-]{1,63}$'),
    CONSTRAINT `chk_group_attribute_schemas_kind`
        CHECK (`value_kind` IN ('string', 'integer', 'decimal', 'boolean', 'datetime', 'json')),
    CONSTRAINT `chk_group_attribute_schemas_visibility`
        CHECK (`visibility` IN ('public', 'members', 'management', 'private')),
    CONSTRAINT `chk_group_attribute_schemas_required`
        CHECK (`required_value` IN (0, 1)),
    CONSTRAINT `chk_group_attribute_schemas_validation`
        CHECK (`validation_json` IS NULL OR JSON_VALID(`validation_json`)),
    CONSTRAINT `chk_group_attribute_schemas_status`
        CHECK (`status` IN ('active', 'disabled', 'retired')),
    CONSTRAINT `chk_group_attribute_schemas_version` CHECK (`version` > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_group_membership_attributes` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `membership_id` BIGINT UNSIGNED NOT NULL,
    `attribute_schema_id` BIGINT UNSIGNED NOT NULL,
    `value_kind` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `value_string` VARCHAR(512) NULL,
    `value_integer` BIGINT NULL,
    `value_decimal` DECIMAL(20, 6) NULL,
    `value_boolean` TINYINT UNSIGNED NULL,
    `value_datetime` DATETIME(6) NULL,
    `value_json` LONGTEXT NULL,
    `updated_by_ref` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `version` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_group_membership_attributes`
        (`membership_id`, `attribute_schema_id`),
    KEY `idx_group_membership_attributes_schema`
        (`attribute_schema_id`, `membership_id`),
    CONSTRAINT `fk_group_membership_attributes_member`
        FOREIGN KEY (`membership_id`) REFERENCES `synex_group_memberships` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `fk_group_membership_attributes_schema`
        FOREIGN KEY (`attribute_schema_id`)
        REFERENCES `synex_group_attribute_schemas` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `chk_group_membership_attributes_kind`
        CHECK (`value_kind` IN ('string', 'integer', 'decimal', 'boolean', 'datetime', 'json')),
    CONSTRAINT `chk_group_membership_attributes_value`
        CHECK ((`value_kind` = 'string' AND `value_string` IS NOT NULL
                    AND `value_integer` IS NULL AND `value_decimal` IS NULL
                    AND `value_boolean` IS NULL AND `value_datetime` IS NULL AND `value_json` IS NULL)
            OR (`value_kind` = 'integer' AND `value_string` IS NULL
                    AND `value_integer` IS NOT NULL AND `value_decimal` IS NULL
                    AND `value_boolean` IS NULL AND `value_datetime` IS NULL AND `value_json` IS NULL)
            OR (`value_kind` = 'decimal' AND `value_string` IS NULL
                    AND `value_integer` IS NULL AND `value_decimal` IS NOT NULL
                    AND `value_boolean` IS NULL AND `value_datetime` IS NULL AND `value_json` IS NULL)
            OR (`value_kind` = 'boolean' AND `value_string` IS NULL
                    AND `value_integer` IS NULL AND `value_decimal` IS NULL
                    AND `value_boolean` IN (0, 1) AND `value_datetime` IS NULL AND `value_json` IS NULL)
            OR (`value_kind` = 'datetime' AND `value_string` IS NULL
                    AND `value_integer` IS NULL AND `value_decimal` IS NULL
                    AND `value_boolean` IS NULL AND `value_datetime` IS NOT NULL AND `value_json` IS NULL)
            OR (`value_kind` = 'json' AND `value_string` IS NULL
                    AND `value_integer` IS NULL AND `value_decimal` IS NULL
                    AND `value_boolean` IS NULL AND `value_datetime` IS NULL
                    AND `value_json` IS NOT NULL AND JSON_VALID(`value_json`))),
    CONSTRAINT `chk_group_membership_attributes_version` CHECK (`version` > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
