DROP PROCEDURE IF EXISTS `synex_groups_migrate_010_external_resource_ownership`;

-- synex:statement
CREATE PROCEDURE `synex_groups_migrate_010_external_resource_ownership`()
BEGIN
    IF (
        SELECT COUNT(*) FROM `information_schema`.`TABLES`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` IN (
            'synex_group_types',
            'synex_group_relation_types',
            'synex_group_duty_states',
            'synex_group_attribute_schemas',
            'synex_group_membership_states',
            'synex_group_definition_sets',
            'synex_group_domain_history',
            'synex_group_domain_history_archive'
        ) AND UPPER(`ENGINE`) = 'INNODB'
    ) <> 8 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex groups migration 010 prerequisite table verification failed';
    END IF;

    IF EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_types'
            AND `CONSTRAINT_NAME` = 'chk_group_types_owner'
    ) THEN
        ALTER TABLE `synex_group_types` DROP CONSTRAINT `chk_group_types_owner`;
    END IF;
    ALTER TABLE `synex_group_types`
        ADD CONSTRAINT `chk_group_types_owner`
            CHECK (`owner_resource` REGEXP '^[A-Za-z0-9][A-Za-z0-9_.-]{2,63}$');

    IF EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_relation_types'
            AND `CONSTRAINT_NAME` = 'chk_group_relation_types_owner'
    ) THEN
        ALTER TABLE `synex_group_relation_types` DROP CONSTRAINT `chk_group_relation_types_owner`;
    END IF;
    ALTER TABLE `synex_group_relation_types`
        ADD CONSTRAINT `chk_group_relation_types_owner`
            CHECK (`owner_resource` REGEXP '^[A-Za-z0-9][A-Za-z0-9_.-]{2,63}$');

    IF EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_duty_states'
            AND `CONSTRAINT_NAME` = 'chk_group_duty_states_owner'
    ) THEN
        ALTER TABLE `synex_group_duty_states` DROP CONSTRAINT `chk_group_duty_states_owner`;
    END IF;
    ALTER TABLE `synex_group_duty_states`
        ADD CONSTRAINT `chk_group_duty_states_owner`
            CHECK (`owner_resource` REGEXP '^[A-Za-z0-9][A-Za-z0-9_.-]{2,63}$');

    IF EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_attribute_schemas'
            AND `CONSTRAINT_NAME` = 'chk_group_attribute_schemas_owner'
    ) THEN
        ALTER TABLE `synex_group_attribute_schemas` DROP CONSTRAINT `chk_group_attribute_schemas_owner`;
    END IF;
    ALTER TABLE `synex_group_attribute_schemas`
        ADD CONSTRAINT `chk_group_attribute_schemas_owner`
            CHECK (`owner_resource` REGEXP '^[A-Za-z0-9][A-Za-z0-9_.-]{2,63}$');

    IF EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_membership_states'
            AND `CONSTRAINT_NAME` = 'chk_group_membership_states_owner'
    ) THEN
        ALTER TABLE `synex_group_membership_states` DROP CONSTRAINT `chk_group_membership_states_owner`;
    END IF;
    ALTER TABLE `synex_group_membership_states`
        ADD CONSTRAINT `chk_group_membership_states_owner`
            CHECK (`owner_resource` REGEXP '^[A-Za-z0-9][A-Za-z0-9_.-]{2,63}$');

    IF EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_definition_sets'
            AND `CONSTRAINT_NAME` = 'chk_group_definition_sets_owner'
    ) THEN
        ALTER TABLE `synex_group_definition_sets` DROP CONSTRAINT `chk_group_definition_sets_owner`;
    END IF;
    ALTER TABLE `synex_group_definition_sets`
        ADD CONSTRAINT `chk_group_definition_sets_owner`
            CHECK (`owner_resource` REGEXP '^[A-Za-z0-9][A-Za-z0-9_.-]{2,63}$');

    IF EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_domain_history'
            AND `CONSTRAINT_NAME` = 'chk_group_domain_history_source'
    ) THEN
        ALTER TABLE `synex_group_domain_history` DROP CONSTRAINT `chk_group_domain_history_source`;
    END IF;
    ALTER TABLE `synex_group_domain_history`
        ADD CONSTRAINT `chk_group_domain_history_source`
            CHECK (`source_resource` REGEXP '^[A-Za-z0-9][A-Za-z0-9_.-]{2,63}$');

    IF EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_group_domain_history_archive'
            AND `CONSTRAINT_NAME` = 'chk_group_history_archive_source'
    ) THEN
        ALTER TABLE `synex_group_domain_history_archive` DROP CONSTRAINT `chk_group_history_archive_source`;
    END IF;
    ALTER TABLE `synex_group_domain_history_archive`
        ADD CONSTRAINT `chk_group_history_archive_source`
            CHECK (`source_resource` REGEXP '^[A-Za-z0-9][A-Za-z0-9_.-]{2,63}$');

    IF (
        SELECT COUNT(*) FROM `information_schema`.`TABLE_CONSTRAINTS` AS `table_constraint`
        INNER JOIN `information_schema`.`CHECK_CONSTRAINTS` AS `check_constraint`
            ON `check_constraint`.`CONSTRAINT_SCHEMA` = `table_constraint`.`CONSTRAINT_SCHEMA`
            AND `check_constraint`.`CONSTRAINT_NAME` = `table_constraint`.`CONSTRAINT_NAME`
        WHERE `table_constraint`.`CONSTRAINT_SCHEMA` = DATABASE()
            AND `table_constraint`.`CONSTRAINT_TYPE` = 'CHECK'
            AND (
                (`table_constraint`.`TABLE_NAME` = 'synex_group_types'
                    AND `table_constraint`.`CONSTRAINT_NAME` = 'chk_group_types_owner')
                OR (`table_constraint`.`TABLE_NAME` = 'synex_group_relation_types'
                    AND `table_constraint`.`CONSTRAINT_NAME` = 'chk_group_relation_types_owner')
                OR (`table_constraint`.`TABLE_NAME` = 'synex_group_duty_states'
                    AND `table_constraint`.`CONSTRAINT_NAME` = 'chk_group_duty_states_owner')
                OR (`table_constraint`.`TABLE_NAME` = 'synex_group_attribute_schemas'
                    AND `table_constraint`.`CONSTRAINT_NAME` = 'chk_group_attribute_schemas_owner')
                OR (`table_constraint`.`TABLE_NAME` = 'synex_group_membership_states'
                    AND `table_constraint`.`CONSTRAINT_NAME` = 'chk_group_membership_states_owner')
                OR (`table_constraint`.`TABLE_NAME` = 'synex_group_definition_sets'
                    AND `table_constraint`.`CONSTRAINT_NAME` = 'chk_group_definition_sets_owner')
                OR (`table_constraint`.`TABLE_NAME` = 'synex_group_domain_history'
                    AND `table_constraint`.`CONSTRAINT_NAME` = 'chk_group_domain_history_source')
                OR (`table_constraint`.`TABLE_NAME` = 'synex_group_domain_history_archive'
                    AND `table_constraint`.`CONSTRAINT_NAME` = 'chk_group_history_archive_source')
            )
            AND `check_constraint`.`CHECK_CLAUSE` LIKE '%A-Za-z0-9_.-%'
            AND `check_constraint`.`CHECK_CLAUSE` LIKE '%2,63%'
    ) <> 8 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex groups migration 010 ownership constraint verification failed';
    END IF;
END;

-- synex:statement
CALL `synex_groups_migrate_010_external_resource_ownership`();

-- synex:statement
DROP PROCEDURE IF EXISTS `synex_groups_migrate_010_external_resource_ownership`;
