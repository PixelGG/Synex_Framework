DROP PROCEDURE IF EXISTS `synex_groups_migrate_032_character_reference_contract`;

-- synex:statement
CREATE PROCEDURE `synex_groups_migrate_032_character_reference_contract`()
BEGIN
    IF (
        SELECT COUNT(*) FROM `information_schema`.`TABLES`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` IN (
                'synex_group_membership_profiles',
                'synex_group_primary_memberships_by_type'
            )
            AND UPPER(`ENGINE`) = 'INNODB'
    ) <> 2 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex groups migration 032 prerequisite verification failed';
    END IF;

    IF EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_group_membership_profiles'
            AND `CONSTRAINT_NAME` = 'chk_group_membership_profiles_character'
            AND `CONSTRAINT_TYPE` = 'CHECK'
    ) THEN
        ALTER TABLE `synex_group_membership_profiles`
            DROP CONSTRAINT `chk_group_membership_profiles_character`;
    END IF;
    IF EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_group_primary_memberships_by_type'
            AND `CONSTRAINT_NAME` = 'chk_group_primary_by_type_character'
            AND `CONSTRAINT_TYPE` = 'CHECK'
    ) THEN
        ALTER TABLE `synex_group_primary_memberships_by_type`
            DROP CONSTRAINT `chk_group_primary_by_type_character`;
    END IF;

    ALTER TABLE `synex_group_membership_profiles`
        ADD CONSTRAINT `chk_group_membership_profiles_character`
            CHECK (`character_id` REGEXP '^[A-Za-z0-9][A-Za-z0-9_.:%-]{7,47}$');
    ALTER TABLE `synex_group_primary_memberships_by_type`
        ADD CONSTRAINT `chk_group_primary_by_type_character`
            CHECK (`character_id` REGEXP '^[A-Za-z0-9][A-Za-z0-9_.:%-]{7,47}$');

    IF (
        SELECT COUNT(*) FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND `CONSTRAINT_TYPE` = 'CHECK'
            AND (
                (`TABLE_NAME` = 'synex_group_membership_profiles'
                    AND `CONSTRAINT_NAME` = 'chk_group_membership_profiles_character')
                OR (`TABLE_NAME` = 'synex_group_primary_memberships_by_type'
                    AND `CONSTRAINT_NAME` = 'chk_group_primary_by_type_character')
            )
    ) <> 2 OR EXISTS (
        SELECT 1 FROM `synex_group_membership_profiles`
        WHERE `character_id` NOT REGEXP '^[A-Za-z0-9][A-Za-z0-9_.:%-]{7,47}$'
    ) OR EXISTS (
        SELECT 1 FROM `synex_group_primary_memberships_by_type`
        WHERE `character_id` NOT REGEXP '^[A-Za-z0-9][A-Za-z0-9_.:%-]{7,47}$'
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex groups migration 032 character reference verification failed';
    END IF;
END;

-- synex:statement
CALL `synex_groups_migrate_032_character_reference_contract`();

-- synex:statement
DROP PROCEDURE IF EXISTS `synex_groups_migrate_032_character_reference_contract`;
