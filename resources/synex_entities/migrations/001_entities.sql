CREATE TABLE IF NOT EXISTS `synex_entities` (
    `entity_id` VARCHAR(64) NOT NULL,
    `generation` BIGINT UNSIGNED NOT NULL,
    `persistent_key` VARCHAR(128) NOT NULL,
    `entity_type` VARCHAR(16) NOT NULL,
    `vehicle_type` VARCHAR(16) NULL,
    `model` BIGINT UNSIGNED NOT NULL,
    `position_x` DOUBLE NOT NULL,
    `position_y` DOUBLE NOT NULL,
    `position_z` DOUBLE NOT NULL,
    `heading` DOUBLE NOT NULL,
    `ped_type` SMALLINT UNSIGNED NULL,
    `door_flag` TINYINT(1) NULL,
    `owner_type` VARCHAR(32) NOT NULL,
    `owner_id` VARCHAR(64) NOT NULL,
    `resource_owner` VARCHAR(64) NOT NULL,
    `bucket_id` INT UNSIGNED NOT NULL DEFAULT 0,
    `status` VARCHAR(16) NOT NULL DEFAULT 'active',
    `version` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    `created_at` DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `updated_at` DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `deleted_at` DATETIME(3) NULL,
    PRIMARY KEY (`entity_id`),
    UNIQUE KEY `uq_synex_entities_persistent_key` (`persistent_key`),
    KEY `ix_synex_entities_resource_owner` (`resource_owner`, `status`),
    KEY `ix_synex_entities_logical_owner` (`owner_type`, `owner_id`, `status`),
    KEY `ix_synex_entities_bucket` (`bucket_id`, `status`),
    CONSTRAINT `ck_synex_entities_type`
        CHECK (`entity_type` IN ('vehicle', 'ped', 'object')),
    CONSTRAINT `ck_synex_entities_status`
        CHECK (`status` IN ('active', 'deleting', 'orphaned', 'deleted')),
    CONSTRAINT `ck_synex_entities_generation`
        CHECK (`generation` > 0 AND `generation` <= 9007199254740991),
    CONSTRAINT `ck_synex_entities_version`
        CHECK (`version` > 0 AND `version` <= 9007199254740991),
    CONSTRAINT `ck_synex_entities_model`
        CHECK (`model` <= 4294967295),
    CONSTRAINT `ck_synex_entities_bucket`
        CHECK (`bucket_id` <= 2147483647),
    CONSTRAINT `ck_synex_entities_position`
        CHECK (
            ABS(`position_x`) <= 20000 AND
            ABS(`position_y`) <= 20000 AND
            ABS(`position_z`) <= 20000 AND
            `heading` >= 0 AND `heading` < 360
        ),
    CONSTRAINT `ck_synex_entities_owner_type`
        CHECK (`owner_type` IN ('character', 'resource', 'system', 'user')),
    CONSTRAINT `ck_synex_entities_shape`
        CHECK (
            (`entity_type` = 'vehicle' AND
                `vehicle_type` IN ('automobile', 'bike', 'boat', 'heli', 'plane', 'submarine', 'trailer') AND
                `ped_type` IS NULL AND `door_flag` IS NULL) OR
            (`entity_type` = 'ped' AND
                `vehicle_type` IS NULL AND `ped_type` BETWEEN 0 AND 29 AND `door_flag` IS NULL) OR
            (`entity_type` = 'object' AND
                `vehicle_type` IS NULL AND `ped_type` IS NULL AND `door_flag` IN (0, 1))
        )
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
