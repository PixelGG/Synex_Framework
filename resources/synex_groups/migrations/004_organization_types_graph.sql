CREATE TABLE IF NOT EXISTS `synex_group_types` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `public_id` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `type_key` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `owner_resource` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `display_name` VARCHAR(96) NOT NULL,
    `creation_mode` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'dynamic',
    `primary_policy` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'optional',
    `membership_limit` SMALLINT UNSIGNED NULL,
    `hierarchy_enabled` TINYINT UNSIGNED NOT NULL DEFAULT 1,
    `relationships_enabled` TINYINT UNSIGNED NOT NULL DEFAULT 1,
    `status` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'active',
    `schema_version` INT UNSIGNED NOT NULL DEFAULT 1,
    `dynamic_creation` TINYINT UNSIGNED NOT NULL DEFAULT 1,
    `metadata_json` LONGTEXT NOT NULL,
    `version` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_group_types_public_id` (`public_id`),
    UNIQUE KEY `uq_group_types_key` (`type_key`),
    KEY `idx_group_types_owner_status` (`owner_resource`, `status`, `type_key`),
    CONSTRAINT `chk_group_types_public_id`
        CHECK (`public_id` REGEXP '^[a-z][a-z0-9_]{7,47}$'),
    CONSTRAINT `chk_group_types_key`
        CHECK (`type_key` REGEXP '^[a-z][a-z0-9_]{1,63}$'),
    CONSTRAINT `chk_group_types_owner`
        CHECK (`owner_resource` REGEXP '^synex_[a-z0-9_]+$'),
    CONSTRAINT `chk_group_types_creation`
        CHECK (`creation_mode` IN ('static', 'dynamic', 'legacy')),
    CONSTRAINT `chk_group_types_primary`
        CHECK (`primary_policy` IN ('none', 'optional', 'required')),
    CONSTRAINT `chk_group_types_flags`
        CHECK (`hierarchy_enabled` IN (0, 1) AND `relationships_enabled` IN (0, 1)),
    CONSTRAINT `chk_group_types_status`
        CHECK (`status` IN ('active', 'disabled', 'retired')),
    CONSTRAINT `chk_group_types_version` CHECK (`version` > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
INSERT INTO `synex_group_types`
    (`public_id`, `type_key`, `owner_resource`, `display_name`, `creation_mode`,
     `primary_policy`, `status`, `schema_version`, `dynamic_creation`,
     `metadata_json`, `version`)
SELECT
    CONCAT(
        'gtype_', SUBSTRING(SHA2(CONCAT('synex:builtin-group-type:', `seed`.`type_key`), 256), 1, 11), '_',
        SUBSTRING(SHA2(CONCAT('synex:builtin-group-type:', `seed`.`type_key`), 256), 12, 8), '_',
        SUBSTRING(SHA2(CONCAT('synex:builtin-group-type:', `seed`.`type_key`), 256), 20, 8)
    ),
    `seed`.`type_key`, 'synex_groups', `seed`.`display_name`, 'dynamic', 'optional',
    'active', 1, 1, '{}', 1
FROM (
    SELECT 'job' AS `type_key`, 'Job' AS `display_name`
    UNION ALL SELECT 'government', 'Government'
    UNION ALL SELECT 'law_enforcement', 'Law enforcement'
    UNION ALL SELECT 'medical', 'Medical'
    UNION ALL SELECT 'gang', 'Gang'
    UNION ALL SELECT 'business', 'Business'
    UNION ALL SELECT 'organization', 'Organization'
    UNION ALL SELECT 'faction', 'Faction'
    UNION ALL SELECT 'department', 'Department'
    UNION ALL SELECT 'club', 'Club'
    UNION ALL SELECT 'family', 'Family'
    UNION ALL SELECT 'crew', 'Crew'
    UNION ALL SELECT 'custom', 'Custom'
) AS `seed`
LEFT JOIN `synex_group_types` AS `existing`
    ON `existing`.`type_key` = `seed`.`type_key`
WHERE `existing`.`id` IS NULL;

-- synex:statement
INSERT INTO `synex_group_types`
    (`public_id`, `type_key`, `owner_resource`, `display_name`, `creation_mode`,
     `primary_policy`, `status`, `schema_version`, `dynamic_creation`,
     `metadata_json`, `version`)
SELECT
    CONCAT(
        'gtype_', SUBSTRING(SHA2(CONCAT('synex:group-type:', `legacy`.`group_type`), 256), 1, 11), '_',
        SUBSTRING(SHA2(CONCAT('synex:group-type:', `legacy`.`group_type`), 256), 12, 8), '_',
        SUBSTRING(SHA2(CONCAT('synex:group-type:', `legacy`.`group_type`), 256), 20, 8)
    ),
    `legacy`.`group_type`, 'synex_groups', `legacy`.`group_type`, 'legacy', 'optional',
    'active', 1, 0, '{}', 1
FROM (SELECT DISTINCT `group_type` FROM `synex_groups`) AS `legacy`
LEFT JOIN `synex_group_types` AS `existing`
    ON `existing`.`type_key` = `legacy`.`group_type`
WHERE `existing`.`id` IS NULL;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_group_organization_profiles` (
    `group_id` BIGINT UNSIGNED NOT NULL,
    `group_type_id` BIGINT UNSIGNED NOT NULL,
    `slug` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `name` VARCHAR(96) NOT NULL,
    `label` VARCHAR(96) NOT NULL,
    `description` VARCHAR(1024) NULL,
    `dynamic` TINYINT UNSIGNED NOT NULL,
    `metadata_json` LONGTEXT NOT NULL,
    `visibility` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'internal',
    `creation_source` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'dynamic',
    `lifecycle_state` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'DRAFT',
    `lifecycle_reason_code` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `state_changed_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `definition_key` VARCHAR(96) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `definition_digest` CHAR(64) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `suspended_at` DATETIME(6) NULL,
    `archived_at` DATETIME(6) NULL,
    `deleted_at` DATETIME(6) NULL,
    `version` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`group_id`),
    UNIQUE KEY `uq_group_profiles_type_slug` (`group_type_id`, `slug`),
    UNIQUE KEY `uq_group_profiles_definition` (`definition_key`),
    KEY `idx_group_profiles_type_visibility` (`group_type_id`, `visibility`, `group_id`),
    KEY `idx_group_profiles_lifecycle` (`lifecycle_state`, `state_changed_at`, `group_id`),
    KEY `idx_group_profiles_archive` (`archived_at`, `group_id`),
    CONSTRAINT `fk_group_profiles_group`
        FOREIGN KEY (`group_id`) REFERENCES `synex_groups` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `fk_group_profiles_type`
        FOREIGN KEY (`group_type_id`) REFERENCES `synex_group_types` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `chk_group_profiles_slug`
        CHECK (`slug` REGEXP '^[a-z][a-z0-9_-]{1,63}$'),
    CONSTRAINT `chk_group_profiles_visibility`
        CHECK (`visibility` IN ('public', 'internal', 'private', 'hidden')),
    CONSTRAINT `chk_group_profiles_source`
        CHECK (`creation_source` IN ('static', 'dynamic', 'legacy')),
    CONSTRAINT `chk_group_profiles_lifecycle`
        CHECK (`lifecycle_state` IN
            ('DRAFT', 'ACTIVE', 'SUSPENDED', 'ARCHIVED', 'DISSOLVING', 'DELETED')),
    CONSTRAINT `chk_group_profiles_lifecycle_reason`
        CHECK (`lifecycle_reason_code` REGEXP '^[a-z][a-z0-9_.:-]{1,63}$'),
    CONSTRAINT `chk_group_profiles_lifecycle_dates`
        CHECK ((`lifecycle_state` = 'SUSPENDED' AND `suspended_at` IS NOT NULL
                    AND `archived_at` IS NULL AND `deleted_at` IS NULL)
            OR (`lifecycle_state` = 'ARCHIVED' AND `archived_at` IS NOT NULL
                    AND `deleted_at` IS NULL)
            OR (`lifecycle_state` = 'DELETED' AND `archived_at` IS NOT NULL
                    AND `deleted_at` IS NOT NULL)
            OR (`lifecycle_state` IN ('DRAFT', 'ACTIVE', 'DISSOLVING')
                    AND `archived_at` IS NULL AND `deleted_at` IS NULL)),
    CONSTRAINT `chk_group_profiles_definition`
        CHECK ((`definition_key` IS NULL AND `definition_digest` IS NULL)
            OR (`definition_key` IS NOT NULL
                AND `definition_key` REGEXP '^[a-z][a-z0-9_.:-]{1,95}$'
                AND `definition_digest` REGEXP '^[0-9a-f]{64}$')),
    CONSTRAINT `chk_group_profiles_version` CHECK (`version` > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
INSERT INTO `synex_group_organization_profiles`
    (`group_id`, `group_type_id`, `slug`, `name`, `label`, `description`,
     `dynamic`, `metadata_json`, `visibility`, `creation_source`,
     `lifecycle_state`, `lifecycle_reason_code`, `state_changed_at`,
     `suspended_at`, `archived_at`, `version`)
SELECT `group_record`.`id`, `group_type`.`id`, `group_record`.`group_key`,
    `group_record`.`display_name`, `group_record`.`display_name`, NULL,
    0, COALESCE(`group_record`.`metadata_json`, '{}'), 'internal', 'legacy',
    CASE `group_record`.`status`
        WHEN 'suspended' THEN 'SUSPENDED'
        WHEN 'archived' THEN 'ARCHIVED'
        ELSE 'ACTIVE'
    END,
    'legacy_backfill', `group_record`.`updated_at`,
    CASE WHEN `group_record`.`status` = 'suspended' THEN `group_record`.`updated_at` ELSE NULL END,
    CASE WHEN `group_record`.`status` = 'archived' THEN `group_record`.`updated_at` ELSE NULL END,
    `group_record`.`version`
FROM `synex_groups` AS `group_record`
INNER JOIN `synex_group_types` AS `group_type`
    ON `group_type`.`type_key` = `group_record`.`group_type`
LEFT JOIN `synex_group_organization_profiles` AS `profile`
    ON `profile`.`group_id` = `group_record`.`id`
WHERE `profile`.`group_id` IS NULL;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_group_hierarchy_edges` (
    `child_group_id` BIGINT UNSIGNED NOT NULL,
    `parent_group_id` BIGINT UNSIGNED NOT NULL,
    `created_by_ref` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `reason_code` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `version` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`child_group_id`),
    KEY `idx_group_hierarchy_parent` (`parent_group_id`, `child_group_id`),
    CONSTRAINT `fk_group_hierarchy_child`
        FOREIGN KEY (`child_group_id`) REFERENCES `synex_groups` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `fk_group_hierarchy_parent`
        FOREIGN KEY (`parent_group_id`) REFERENCES `synex_groups` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `chk_group_hierarchy_distinct` CHECK (`child_group_id` <> `parent_group_id`),
    CONSTRAINT `chk_group_hierarchy_reason`
        CHECK (`reason_code` REGEXP '^[a-z][a-z0-9_.:-]{1,63}$'),
    CONSTRAINT `chk_group_hierarchy_version` CHECK (`version` > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_group_hierarchy_closure` (
    `ancestor_group_id` BIGINT UNSIGNED NOT NULL,
    `descendant_group_id` BIGINT UNSIGNED NOT NULL,
    `depth` SMALLINT UNSIGNED NOT NULL,
    PRIMARY KEY (`ancestor_group_id`, `descendant_group_id`),
    KEY `idx_group_closure_descendant` (`descendant_group_id`, `depth`, `ancestor_group_id`),
    CONSTRAINT `fk_group_closure_ancestor`
        FOREIGN KEY (`ancestor_group_id`) REFERENCES `synex_groups` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `fk_group_closure_descendant`
        FOREIGN KEY (`descendant_group_id`) REFERENCES `synex_groups` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `chk_group_closure_depth`
        CHECK ((`ancestor_group_id` = `descendant_group_id` AND `depth` = 0)
            OR (`ancestor_group_id` <> `descendant_group_id` AND `depth` > 0))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
INSERT INTO `synex_group_hierarchy_closure`
    (`ancestor_group_id`, `descendant_group_id`, `depth`)
SELECT `group_record`.`id`, `group_record`.`id`, 0
FROM `synex_groups` AS `group_record`
LEFT JOIN `synex_group_hierarchy_closure` AS `closure`
    ON `closure`.`ancestor_group_id` = `group_record`.`id`
    AND `closure`.`descendant_group_id` = `group_record`.`id`
WHERE `closure`.`ancestor_group_id` IS NULL;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_group_relation_types` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `public_id` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `type_key` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `owner_resource` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `display_name` VARCHAR(96) NOT NULL,
    `direction` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `status` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'active',
    `version` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_group_relation_types_public` (`public_id`),
    UNIQUE KEY `uq_group_relation_types_key` (`type_key`),
    KEY `idx_group_relation_types_owner` (`owner_resource`, `status`, `type_key`),
    CONSTRAINT `chk_group_relation_types_public`
        CHECK (`public_id` REGEXP '^[a-z][a-z0-9_]{7,47}$'),
    CONSTRAINT `chk_group_relation_types_key`
        CHECK (`type_key` REGEXP '^[a-z][a-z0-9_]{1,63}$'),
    CONSTRAINT `chk_group_relation_types_owner`
        CHECK (`owner_resource` REGEXP '^synex_[a-z0-9_]+$'),
    CONSTRAINT `chk_group_relation_types_direction`
        CHECK (`direction` IN ('directed', 'symmetric')),
    CONSTRAINT `chk_group_relation_types_status`
        CHECK (`status` IN ('active', 'disabled', 'retired')),
    CONSTRAINT `chk_group_relation_types_version` CHECK (`version` > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
INSERT INTO `synex_group_relation_types`
    (`public_id`, `type_key`, `owner_resource`, `display_name`, `direction`, `status`, `version`)
SELECT
    CONCAT(
        'grel_', SUBSTRING(SHA2(CONCAT('synex:builtin-relation-type:', `seed`.`type_key`), 256), 1, 11), '_',
        SUBSTRING(SHA2(CONCAT('synex:builtin-relation-type:', `seed`.`type_key`), 256), 12, 8), '_',
        SUBSTRING(SHA2(CONCAT('synex:builtin-relation-type:', `seed`.`type_key`), 256), 20, 8)
    ),
    `seed`.`type_key`, 'synex_groups', `seed`.`display_name`, `seed`.`direction`, 'active', 1
FROM (
    SELECT 'subdivision_of' AS `type_key`, 'Subdivision of' AS `display_name`, 'directed' AS `direction`
    UNION ALL SELECT 'ally_of', 'Ally of', 'symmetric'
    UNION ALL SELECT 'hostile_to', 'Hostile to', 'symmetric'
    UNION ALL SELECT 'partner_of', 'Partner of', 'symmetric'
    UNION ALL SELECT 'subsidiary_of', 'Subsidiary of', 'directed'
    UNION ALL SELECT 'affiliated_with', 'Affiliated with', 'symmetric'
) AS `seed`
LEFT JOIN `synex_group_relation_types` AS `existing`
    ON `existing`.`type_key` = `seed`.`type_key`
WHERE `existing`.`id` IS NULL;

-- synex:statement
CREATE TABLE IF NOT EXISTS `synex_group_relationships` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `public_id` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `relation_type_id` BIGINT UNSIGNED NOT NULL,
    `source_group_id` BIGINT UNSIGNED NOT NULL,
    `target_group_id` BIGINT UNSIGNED NOT NULL,
    `status` VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'active',
    `valid_from` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `valid_until` DATETIME(6) NULL,
    `ended_at` DATETIME(6) NULL,
    `created_by_ref` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `reason_code` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `version` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    `active_marker` TINYINT UNSIGNED
        GENERATED ALWAYS AS (CASE WHEN `status` = 'active' THEN 1 ELSE NULL END) STORED,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_group_relationships_public` (`public_id`),
    UNIQUE KEY `uq_group_relationships_active`
        (`relation_type_id`, `source_group_id`, `target_group_id`, `active_marker`),
    KEY `idx_group_relationships_source`
        (`source_group_id`, `status`, `relation_type_id`, `target_group_id`),
    KEY `idx_group_relationships_target`
        (`target_group_id`, `status`, `relation_type_id`, `source_group_id`),
    KEY `idx_group_relationships_expiry` (`status`, `valid_until`, `id`),
    CONSTRAINT `fk_group_relationships_type`
        FOREIGN KEY (`relation_type_id`) REFERENCES `synex_group_relation_types` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `fk_group_relationships_source`
        FOREIGN KEY (`source_group_id`) REFERENCES `synex_groups` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `fk_group_relationships_target`
        FOREIGN KEY (`target_group_id`) REFERENCES `synex_groups` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `chk_group_relationships_public`
        CHECK (`public_id` REGEXP '^[a-z][a-z0-9_]{7,47}$'),
    CONSTRAINT `chk_group_relationships_distinct` CHECK (`source_group_id` <> `target_group_id`),
    CONSTRAINT `chk_group_relationships_status`
        CHECK (`status` IN ('active', 'suspended', 'ended')),
    CONSTRAINT `chk_group_relationships_window`
        CHECK (`valid_until` IS NULL OR `valid_until` > `valid_from`),
    CONSTRAINT `chk_group_relationships_terminal`
        CHECK ((`status` = 'ended' AND `ended_at` IS NOT NULL)
            OR (`status` <> 'ended' AND `ended_at` IS NULL)),
    CONSTRAINT `chk_group_relationships_reason`
        CHECK (`reason_code` REGEXP '^[a-z][a-z0-9_.:-]{1,63}$'),
    CONSTRAINT `chk_group_relationships_version` CHECK (`version` > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
