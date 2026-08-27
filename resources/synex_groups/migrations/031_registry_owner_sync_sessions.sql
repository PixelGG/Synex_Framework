CREATE TABLE IF NOT EXISTS `synex_group_registry_owner_syncs` (
    `owner_resource` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `owner_epoch` BIGINT UNSIGNED NOT NULL,
    `begin_key` VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `generation` BIGINT UNSIGNED NOT NULL,
    `active` TINYINT(1) UNSIGNED NOT NULL DEFAULT 1,
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
        ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`owner_resource`),
    CONSTRAINT `chk_group_registry_sync_owner`
        CHECK (`owner_resource` REGEXP '^[A-Za-z0-9][A-Za-z0-9_.-]{2,63}$'),
    CONSTRAINT `chk_group_registry_sync_epoch` CHECK (`owner_epoch` >= 1),
    CONSTRAINT `chk_group_registry_sync_key`
        CHECK (CHAR_LENGTH(`begin_key`) BETWEEN 8 AND 128),
    CONSTRAINT `chk_group_registry_sync_generation` CHECK (`generation` >= 1),
    CONSTRAINT `chk_group_registry_sync_active` CHECK (`active` IN (0, 1))
) ENGINE=InnoDB;
