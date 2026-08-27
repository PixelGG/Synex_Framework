DROP PROCEDURE IF EXISTS `synex_groups_migrate_026_group_attribute_scopes`;

-- synex:statement
CREATE PROCEDURE `synex_groups_migrate_026_group_attribute_scopes`()
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLES`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_group_attribute_schemas'
            AND UPPER(`ENGINE`) = 'INNODB'
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLES`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_group_membership_profiles'
            AND UPPER(`ENGINE`) = 'INNODB'
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_group_attribute_schemas'
            AND `COLUMN_NAME` = 'group_type_scope_id'
            AND `EXTRA` LIKE '%STORED GENERATED%'
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex groups migration 026 attribute schema prerequisite verification failed';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_group_attribute_schemas'
            AND `COLUMN_NAME` = 'owner_epoch'
    ) THEN
        ALTER TABLE `synex_group_attribute_schemas`
            ADD COLUMN `owner_epoch` BIGINT UNSIGNED NOT NULL DEFAULT 1
                AFTER `owner_resource`;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_group_attribute_schemas'
            AND `COLUMN_NAME` = 'has_default'
    ) THEN
        ALTER TABLE `synex_group_attribute_schemas`
            ADD COLUMN `has_default` TINYINT UNSIGNED NOT NULL DEFAULT 0
                AFTER `validation_json`;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_group_attribute_schemas'
            AND `COLUMN_NAME` = 'default_value_string'
    ) THEN
        ALTER TABLE `synex_group_attribute_schemas`
            ADD COLUMN `default_value_string` VARCHAR(512) NULL AFTER `has_default`;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_group_attribute_schemas'
            AND `COLUMN_NAME` = 'default_value_integer'
    ) THEN
        ALTER TABLE `synex_group_attribute_schemas`
            ADD COLUMN `default_value_integer` BIGINT NULL AFTER `default_value_string`;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_group_attribute_schemas'
            AND `COLUMN_NAME` = 'default_value_decimal'
    ) THEN
        ALTER TABLE `synex_group_attribute_schemas`
            ADD COLUMN `default_value_decimal` DECIMAL(20, 6) NULL
                AFTER `default_value_integer`;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_group_attribute_schemas'
            AND `COLUMN_NAME` = 'default_value_boolean'
    ) THEN
        ALTER TABLE `synex_group_attribute_schemas`
            ADD COLUMN `default_value_boolean` TINYINT UNSIGNED NULL
                AFTER `default_value_decimal`;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_group_attribute_schemas'
            AND `COLUMN_NAME` = 'default_value_datetime'
    ) THEN
        ALTER TABLE `synex_group_attribute_schemas`
            ADD COLUMN `default_value_datetime` DATETIME(6) NULL
                AFTER `default_value_boolean`;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_group_attribute_schemas'
            AND `COLUMN_NAME` = 'default_value_json'
    ) THEN
        ALTER TABLE `synex_group_attribute_schemas`
            ADD COLUMN `default_value_json` LONGTEXT NULL AFTER `default_value_datetime`;
    END IF;

    IF EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_group_attribute_schemas'
            AND `CONSTRAINT_NAME` = 'chk_group_attribute_schemas_visibility'
    ) THEN
        ALTER TABLE `synex_group_attribute_schemas`
            DROP CONSTRAINT `chk_group_attribute_schemas_visibility`;
    END IF;
    ALTER TABLE `synex_group_attribute_schemas`
        ADD CONSTRAINT `chk_group_attribute_schemas_visibility`
            CHECK (`visibility` IN (
                'public', 'members', 'management', 'staff', 'hidden', 'server_only', 'private'
            ));

    IF EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_group_membership_profiles'
            AND `CONSTRAINT_NAME` = 'chk_group_membership_profiles_visibility'
    ) THEN
        ALTER TABLE `synex_group_membership_profiles`
            DROP CONSTRAINT `chk_group_membership_profiles_visibility`;
    END IF;
    ALTER TABLE `synex_group_membership_profiles`
        ADD CONSTRAINT `chk_group_membership_profiles_visibility`
            CHECK (`visibility` IN (
                'public', 'members', 'management', 'hidden', 'server_only', 'private'
            ));

    IF EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_group_attribute_schemas'
            AND `CONSTRAINT_NAME` = 'chk_group_attribute_schemas_owner_epoch'
    ) THEN
        ALTER TABLE `synex_group_attribute_schemas`
            DROP CONSTRAINT `chk_group_attribute_schemas_owner_epoch`;
    END IF;
    ALTER TABLE `synex_group_attribute_schemas`
        ADD CONSTRAINT `chk_group_attribute_schemas_owner_epoch`
            CHECK (`owner_epoch` > 0);

    IF EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_group_attribute_schemas'
            AND `CONSTRAINT_NAME` = 'chk_group_attribute_schemas_default'
    ) THEN
        ALTER TABLE `synex_group_attribute_schemas`
            DROP CONSTRAINT `chk_group_attribute_schemas_default`;
    END IF;
    ALTER TABLE `synex_group_attribute_schemas`
        ADD CONSTRAINT `chk_group_attribute_schemas_default`
            CHECK ((`has_default` = 0
                        AND `default_value_string` IS NULL
                        AND `default_value_integer` IS NULL
                        AND `default_value_decimal` IS NULL
                        AND `default_value_boolean` IS NULL
                        AND `default_value_datetime` IS NULL
                        AND `default_value_json` IS NULL)
                OR (`has_default` = 1 AND (
                    (`value_kind` = 'string' AND `default_value_string` IS NOT NULL
                        AND `default_value_integer` IS NULL
                        AND `default_value_decimal` IS NULL
                        AND `default_value_boolean` IS NULL
                        AND `default_value_datetime` IS NULL
                        AND `default_value_json` IS NULL)
                    OR (`value_kind` = 'integer' AND `default_value_string` IS NULL
                        AND `default_value_integer` IS NOT NULL
                        AND `default_value_decimal` IS NULL
                        AND `default_value_boolean` IS NULL
                        AND `default_value_datetime` IS NULL
                        AND `default_value_json` IS NULL)
                    OR (`value_kind` = 'decimal' AND `default_value_string` IS NULL
                        AND `default_value_integer` IS NULL
                        AND `default_value_decimal` IS NOT NULL
                        AND `default_value_boolean` IS NULL
                        AND `default_value_datetime` IS NULL
                        AND `default_value_json` IS NULL)
                    OR (`value_kind` = 'boolean' AND `default_value_string` IS NULL
                        AND `default_value_integer` IS NULL
                        AND `default_value_decimal` IS NULL
                        AND `default_value_boolean` IS NOT NULL
                        AND `default_value_boolean` IN (0, 1)
                        AND `default_value_datetime` IS NULL
                        AND `default_value_json` IS NULL)
                    OR (`value_kind` = 'datetime' AND `default_value_string` IS NULL
                        AND `default_value_integer` IS NULL
                        AND `default_value_decimal` IS NULL
                        AND `default_value_boolean` IS NULL
                        AND `default_value_datetime` IS NOT NULL
                        AND `default_value_json` IS NULL)
                    OR (`value_kind` = 'json' AND `default_value_string` IS NULL
                        AND `default_value_integer` IS NULL
                        AND `default_value_decimal` IS NULL
                        AND `default_value_boolean` IS NULL
                        AND `default_value_datetime` IS NULL
                        AND `default_value_json` IS NOT NULL
                        AND JSON_VALID(`default_value_json`)
                        AND OCTET_LENGTH(`default_value_json`) <= 32768)
                )));

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_group_attribute_schemas'
            AND `INDEX_NAME` = 'idx_group_attribute_schemas_owner_epoch'
    ) THEN
        ALTER TABLE `synex_group_attribute_schemas`
            ADD KEY `idx_group_attribute_schemas_owner_epoch`
                (`owner_resource`, `owner_epoch`, `status`, `id`);
    END IF;
END;

-- synex:statement
CALL `synex_groups_migrate_026_group_attribute_scopes`();

-- synex:statement
DROP PROCEDURE IF EXISTS `synex_groups_migrate_026_group_attribute_scopes`;

-- synex:statement
DROP PROCEDURE IF EXISTS `synex_groups_verify_026_group_attribute_scopes`;

-- synex:statement
CREATE PROCEDURE `synex_groups_verify_026_group_attribute_scopes`()
BEGIN
    IF (
        SELECT COUNT(*) FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_group_attribute_schemas'
            AND ((`COLUMN_NAME` = 'owner_epoch'
                    AND `DATA_TYPE` = 'bigint' AND `COLUMN_TYPE` LIKE '%unsigned%'
                    AND `IS_NULLABLE` = 'NO')
                OR (`COLUMN_NAME` = 'has_default'
                    AND `DATA_TYPE` = 'tinyint' AND `COLUMN_TYPE` LIKE '%unsigned%'
                    AND `IS_NULLABLE` = 'NO')
                OR (`COLUMN_NAME` = 'default_value_string'
                    AND `DATA_TYPE` = 'varchar' AND `CHARACTER_MAXIMUM_LENGTH` = 512
                    AND `IS_NULLABLE` = 'YES')
                OR (`COLUMN_NAME` = 'default_value_integer'
                    AND `DATA_TYPE` = 'bigint' AND `IS_NULLABLE` = 'YES')
                OR (`COLUMN_NAME` = 'default_value_decimal'
                    AND `DATA_TYPE` = 'decimal' AND `NUMERIC_PRECISION` = 20
                    AND `NUMERIC_SCALE` = 6 AND `IS_NULLABLE` = 'YES')
                OR (`COLUMN_NAME` = 'default_value_boolean'
                    AND `DATA_TYPE` = 'tinyint' AND `COLUMN_TYPE` LIKE '%unsigned%'
                    AND `IS_NULLABLE` = 'YES')
                OR (`COLUMN_NAME` = 'default_value_datetime'
                    AND `DATA_TYPE` = 'datetime' AND `DATETIME_PRECISION` = 6
                    AND `IS_NULLABLE` = 'YES')
                OR (`COLUMN_NAME` = 'default_value_json'
                    AND `DATA_TYPE` = 'longtext' AND `IS_NULLABLE` = 'YES'))
    ) <> 8 OR (
        SELECT COUNT(*) FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND ((`TABLE_NAME` = 'synex_group_attribute_schemas'
                    AND `CONSTRAINT_NAME` IN (
                        'chk_group_attribute_schemas_visibility',
                        'chk_group_attribute_schemas_owner_epoch',
                        'chk_group_attribute_schemas_default'
                    ))
                OR (`TABLE_NAME` = 'synex_group_membership_profiles'
                    AND `CONSTRAINT_NAME` = 'chk_group_membership_profiles_visibility'))
            AND `CONSTRAINT_TYPE` = 'CHECK'
    ) <> 4 OR (
        SELECT COUNT(*) FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_group_attribute_schemas'
            AND `INDEX_NAME` = 'idx_group_attribute_schemas_owner_epoch'
            AND ((`SEQ_IN_INDEX` = 1 AND `COLUMN_NAME` = 'owner_resource')
                OR (`SEQ_IN_INDEX` = 2 AND `COLUMN_NAME` = 'owner_epoch')
                OR (`SEQ_IN_INDEX` = 3 AND `COLUMN_NAME` = 'status')
                OR (`SEQ_IN_INDEX` = 4 AND `COLUMN_NAME` = 'id'))
    ) <> 4 OR EXISTS (
        SELECT 1 FROM `synex_group_attribute_schemas`
        WHERE `owner_epoch` < 1 OR `has_default` NOT IN (0, 1)
            OR `visibility` NOT IN (
                'public', 'members', 'management', 'staff', 'hidden', 'server_only', 'private'
            )
            OR (`has_default` = 0 AND (
                `default_value_string` IS NOT NULL
                OR `default_value_integer` IS NOT NULL
                OR `default_value_decimal` IS NOT NULL
                OR `default_value_boolean` IS NOT NULL
                OR `default_value_datetime` IS NOT NULL
                OR `default_value_json` IS NOT NULL))
            OR (`has_default` = 1 AND CASE `value_kind`
                WHEN 'string' THEN `default_value_string` IS NULL
                    OR `default_value_integer` IS NOT NULL
                    OR `default_value_decimal` IS NOT NULL
                    OR `default_value_boolean` IS NOT NULL
                    OR `default_value_datetime` IS NOT NULL
                    OR `default_value_json` IS NOT NULL
                WHEN 'integer' THEN `default_value_string` IS NOT NULL
                    OR `default_value_integer` IS NULL
                    OR `default_value_decimal` IS NOT NULL
                    OR `default_value_boolean` IS NOT NULL
                    OR `default_value_datetime` IS NOT NULL
                    OR `default_value_json` IS NOT NULL
                WHEN 'decimal' THEN `default_value_string` IS NOT NULL
                    OR `default_value_integer` IS NOT NULL
                    OR `default_value_decimal` IS NULL
                    OR `default_value_boolean` IS NOT NULL
                    OR `default_value_datetime` IS NOT NULL
                    OR `default_value_json` IS NOT NULL
                WHEN 'boolean' THEN `default_value_string` IS NOT NULL
                    OR `default_value_integer` IS NOT NULL
                    OR `default_value_decimal` IS NOT NULL
                    OR `default_value_boolean` IS NULL
                    OR `default_value_boolean` NOT IN (0, 1)
                    OR `default_value_datetime` IS NOT NULL
                    OR `default_value_json` IS NOT NULL
                WHEN 'datetime' THEN `default_value_string` IS NOT NULL
                    OR `default_value_integer` IS NOT NULL
                    OR `default_value_decimal` IS NOT NULL
                    OR `default_value_boolean` IS NOT NULL
                    OR `default_value_datetime` IS NULL
                    OR `default_value_json` IS NOT NULL
                WHEN 'json' THEN `default_value_string` IS NOT NULL
                    OR `default_value_integer` IS NOT NULL
                    OR `default_value_decimal` IS NOT NULL
                    OR `default_value_boolean` IS NOT NULL
                    OR `default_value_datetime` IS NOT NULL
                    OR `default_value_json` IS NULL
                    OR NOT JSON_VALID(`default_value_json`)
                    OR OCTET_LENGTH(`default_value_json`) > 32768
                ELSE TRUE END)
    ) OR EXISTS (
        SELECT 1 FROM `synex_group_membership_profiles`
        WHERE `visibility` NOT IN (
            'public', 'members', 'management', 'hidden', 'server_only', 'private'
        )
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex groups migration 026 attribute schema verification failed';
    END IF;
END;

-- synex:statement
CALL `synex_groups_verify_026_group_attribute_scopes`();

-- synex:statement
DROP PROCEDURE IF EXISTS `synex_groups_verify_026_group_attribute_scopes`;
