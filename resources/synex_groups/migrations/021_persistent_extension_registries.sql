DROP PROCEDURE IF EXISTS `synex_groups_migrate_021_persistent_extension_registries`;

-- synex:statement
CREATE PROCEDURE `synex_groups_migrate_021_persistent_extension_registries`()
BEGIN
    IF (
        SELECT COUNT(*) FROM `information_schema`.`TABLES`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` IN (
                'synex_group_types',
                'synex_group_relation_types',
                'synex_group_duty_states'
            )
            AND UPPER(`ENGINE`) = 'INNODB'
    ) <> 3 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex groups migration 021 prerequisite table verification failed';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_types'
            AND `COLUMN_NAME` = 'owner_epoch'
    ) THEN
        ALTER TABLE `synex_group_types`
            ADD COLUMN `owner_epoch` BIGINT UNSIGNED NOT NULL DEFAULT 1 AFTER `owner_resource`;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_relation_types'
            AND `COLUMN_NAME` = 'owner_epoch'
    ) THEN
        ALTER TABLE `synex_group_relation_types`
            ADD COLUMN `owner_epoch` BIGINT UNSIGNED NOT NULL DEFAULT 1 AFTER `owner_resource`;
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_relation_types'
            AND `COLUMN_NAME` = 'schema_version'
    ) THEN
        ALTER TABLE `synex_group_relation_types`
            ADD COLUMN `schema_version` INT UNSIGNED NOT NULL DEFAULT 1 AFTER `direction`;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_duty_states'
            AND `COLUMN_NAME` = 'public_id'
    ) THEN
        ALTER TABLE `synex_group_duty_states`
            ADD COLUMN `public_id` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NULL
            AFTER `state_key`;
    END IF;
    UPDATE `synex_group_duty_states`
        SET `public_id` = CONCAT('group_duty_state_',
            SUBSTRING(SHA2(CONCAT('synex:duty-state:', `state_key`), 256), 1, 30))
        WHERE `public_id` IS NULL;
    ALTER TABLE `synex_group_duty_states`
        MODIFY COLUMN `public_id` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_duty_states'
            AND `COLUMN_NAME` = 'owner_epoch'
    ) THEN
        ALTER TABLE `synex_group_duty_states`
            ADD COLUMN `owner_epoch` BIGINT UNSIGNED NOT NULL DEFAULT 1 AFTER `owner_resource`;
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_duty_states'
            AND `COLUMN_NAME` = 'schema_version'
    ) THEN
        ALTER TABLE `synex_group_duty_states`
            ADD COLUMN `schema_version` INT UNSIGNED NOT NULL DEFAULT 1 AFTER `counts_as_on_duty`;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_types'
            AND `INDEX_NAME` = 'idx_group_types_owner_epoch'
    ) THEN
        ALTER TABLE `synex_group_types`
            ADD KEY `idx_group_types_owner_epoch`
                (`owner_resource`, `owner_epoch`, `status`, `type_key`);
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_relation_types'
            AND `INDEX_NAME` = 'idx_group_relation_types_owner_epoch'
    ) THEN
        ALTER TABLE `synex_group_relation_types`
            ADD KEY `idx_group_relation_types_owner_epoch`
                (`owner_resource`, `owner_epoch`, `status`, `type_key`);
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_duty_states'
            AND `INDEX_NAME` = 'uq_group_duty_states_public'
    ) THEN
        ALTER TABLE `synex_group_duty_states`
            ADD UNIQUE KEY `uq_group_duty_states_public` (`public_id`);
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_duty_states'
            AND `INDEX_NAME` = 'idx_group_duty_states_owner_epoch'
    ) THEN
        ALTER TABLE `synex_group_duty_states`
            ADD KEY `idx_group_duty_states_owner_epoch`
                (`owner_resource`, `owner_epoch`, `status`, `state_key`);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_types'
            AND `CONSTRAINT_NAME` = 'chk_group_types_owner_epoch'
            AND `CONSTRAINT_TYPE` = 'CHECK'
    ) THEN
        ALTER TABLE `synex_group_types`
            ADD CONSTRAINT `chk_group_types_owner_epoch` CHECK (`owner_epoch` > 0);
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_group_relation_types'
            AND `CONSTRAINT_NAME` = 'chk_group_relation_types_owner_epoch'
            AND `CONSTRAINT_TYPE` = 'CHECK'
    ) THEN
        ALTER TABLE `synex_group_relation_types`
            ADD CONSTRAINT `chk_group_relation_types_owner_epoch` CHECK (`owner_epoch` > 0);
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_group_relation_types'
            AND `CONSTRAINT_NAME` = 'chk_group_relation_types_schema_version'
            AND `CONSTRAINT_TYPE` = 'CHECK'
    ) THEN
        ALTER TABLE `synex_group_relation_types`
            ADD CONSTRAINT `chk_group_relation_types_schema_version` CHECK (`schema_version` > 0);
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_duty_states'
            AND `CONSTRAINT_NAME` = 'chk_group_duty_states_public'
            AND `CONSTRAINT_TYPE` = 'CHECK'
    ) THEN
        ALTER TABLE `synex_group_duty_states`
            ADD CONSTRAINT `chk_group_duty_states_public`
                CHECK (`public_id` REGEXP '^[a-z][a-z0-9_]{7,47}$');
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_duty_states'
            AND `CONSTRAINT_NAME` = 'chk_group_duty_states_owner_epoch'
            AND `CONSTRAINT_TYPE` = 'CHECK'
    ) THEN
        ALTER TABLE `synex_group_duty_states`
            ADD CONSTRAINT `chk_group_duty_states_owner_epoch` CHECK (`owner_epoch` > 0);
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_duty_states'
            AND `CONSTRAINT_NAME` = 'chk_group_duty_states_schema_version'
            AND `CONSTRAINT_TYPE` = 'CHECK'
    ) THEN
        ALTER TABLE `synex_group_duty_states`
            ADD CONSTRAINT `chk_group_duty_states_schema_version` CHECK (`schema_version` > 0);
    END IF;

    IF (
        SELECT COUNT(*) FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND ((`TABLE_NAME` = 'synex_group_types' AND `COLUMN_NAME` = 'owner_epoch')
                OR (`TABLE_NAME` = 'synex_group_relation_types'
                    AND `COLUMN_NAME` IN ('owner_epoch', 'schema_version'))
                OR (`TABLE_NAME` = 'synex_group_duty_states'
                    AND `COLUMN_NAME` IN ('public_id', 'owner_epoch', 'schema_version')))
            AND `IS_NULLABLE` = 'NO'
    ) <> 6 OR (
        SELECT COUNT(*) FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `INDEX_NAME` IN (
                'idx_group_types_owner_epoch',
                'idx_group_relation_types_owner_epoch',
                'uq_group_duty_states_public',
                'idx_group_duty_states_owner_epoch'
            )
            AND `SEQ_IN_INDEX` = 1
    ) <> 4 OR (
        SELECT COUNT(*) FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND `CONSTRAINT_NAME` IN (
                'chk_group_types_owner_epoch',
                'chk_group_relation_types_owner_epoch',
                'chk_group_relation_types_schema_version',
                'chk_group_duty_states_public',
                'chk_group_duty_states_owner_epoch',
                'chk_group_duty_states_schema_version'
            )
            AND `CONSTRAINT_TYPE` = 'CHECK'
    ) <> 6 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex groups migration 021 registry verification failed';
    END IF;
END;

-- synex:statement
CALL `synex_groups_migrate_021_persistent_extension_registries`();

-- synex:statement
DROP PROCEDURE IF EXISTS `synex_groups_migrate_021_persistent_extension_registries`;
