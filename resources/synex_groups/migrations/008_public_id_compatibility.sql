DROP PROCEDURE IF EXISTS `synex_groups_migrate_008_public_id_compatibility`;

-- synex:statement
CREATE PROCEDURE `synex_groups_migrate_008_public_id_compatibility`()
BEGIN
    IF (
        SELECT COUNT(*) FROM `information_schema`.`TABLES`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` IN (
            'synex_groups',
            'synex_group_memberships',
            'synex_group_grades',
            'synex_group_membership_grades',
            'synex_group_primary_memberships',
            'synex_group_membership_events',
            'synex_group_primary_membership_events',
            'synex_group_operations',
            'synex_group_outbox'
        ) AND UPPER(`ENGINE`) = 'INNODB'
    ) <> 9 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex groups migration 008 prerequisite table verification failed';
    END IF;

    ALTER TABLE `synex_groups`
        MODIFY COLUMN `public_id` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
        MODIFY COLUMN `created_by_ref` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NULL;

    ALTER TABLE `synex_group_memberships`
        MODIFY COLUMN `public_id` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
        MODIFY COLUMN `subject_ref` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL;

    ALTER TABLE `synex_group_grades`
        MODIFY COLUMN `public_id` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL;

    ALTER TABLE `synex_group_membership_grades`
        MODIFY COLUMN `assigned_by_ref` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NULL;

    ALTER TABLE `synex_group_primary_memberships`
        MODIFY COLUMN `subject_ref` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
        MODIFY COLUMN `assigned_by_ref` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NULL;

    ALTER TABLE `synex_group_membership_events`
        MODIFY COLUMN `event_id` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
        MODIFY COLUMN `actor_ref` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NULL;

    ALTER TABLE `synex_group_primary_membership_events`
        MODIFY COLUMN `event_id` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
        MODIFY COLUMN `subject_ref` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
        MODIFY COLUMN `actor_ref` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NULL;

    ALTER TABLE `synex_group_operations`
        MODIFY COLUMN `idempotency_key` VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL;

    ALTER TABLE `synex_group_outbox`
        MODIFY COLUMN `event_id` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
        MODIFY COLUMN `aggregate_id` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL;

    IF (
        SELECT COUNT(*) FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `DATA_TYPE` = 'varchar'
            AND `CHARACTER_SET_NAME` = 'ascii'
            AND `COLLATION_NAME` = 'ascii_bin'
            AND (
                (`TABLE_NAME` = 'synex_groups' AND `COLUMN_NAME` = 'public_id'
                    AND `CHARACTER_MAXIMUM_LENGTH` = 48 AND `IS_NULLABLE` = 'NO')
                OR (`TABLE_NAME` = 'synex_groups' AND `COLUMN_NAME` = 'created_by_ref'
                    AND `CHARACTER_MAXIMUM_LENGTH` = 48 AND `IS_NULLABLE` = 'YES')
                OR (`TABLE_NAME` = 'synex_group_memberships' AND `COLUMN_NAME` IN ('public_id', 'subject_ref')
                    AND `CHARACTER_MAXIMUM_LENGTH` = 48 AND `IS_NULLABLE` = 'NO')
                OR (`TABLE_NAME` = 'synex_group_grades' AND `COLUMN_NAME` = 'public_id'
                    AND `CHARACTER_MAXIMUM_LENGTH` = 48 AND `IS_NULLABLE` = 'NO')
                OR (`TABLE_NAME` = 'synex_group_membership_grades' AND `COLUMN_NAME` = 'assigned_by_ref'
                    AND `CHARACTER_MAXIMUM_LENGTH` = 48 AND `IS_NULLABLE` = 'YES')
                OR (`TABLE_NAME` = 'synex_group_primary_memberships' AND `COLUMN_NAME` = 'subject_ref'
                    AND `CHARACTER_MAXIMUM_LENGTH` = 48 AND `IS_NULLABLE` = 'NO')
                OR (`TABLE_NAME` = 'synex_group_primary_memberships' AND `COLUMN_NAME` = 'assigned_by_ref'
                    AND `CHARACTER_MAXIMUM_LENGTH` = 48 AND `IS_NULLABLE` = 'YES')
                OR (`TABLE_NAME` = 'synex_group_membership_events' AND `COLUMN_NAME` = 'event_id'
                    AND `CHARACTER_MAXIMUM_LENGTH` = 48 AND `IS_NULLABLE` = 'NO')
                OR (`TABLE_NAME` = 'synex_group_membership_events' AND `COLUMN_NAME` = 'actor_ref'
                    AND `CHARACTER_MAXIMUM_LENGTH` = 48 AND `IS_NULLABLE` = 'YES')
                OR (`TABLE_NAME` = 'synex_group_primary_membership_events'
                    AND `COLUMN_NAME` IN ('event_id', 'subject_ref')
                    AND `CHARACTER_MAXIMUM_LENGTH` = 48 AND `IS_NULLABLE` = 'NO')
                OR (`TABLE_NAME` = 'synex_group_primary_membership_events' AND `COLUMN_NAME` = 'actor_ref'
                    AND `CHARACTER_MAXIMUM_LENGTH` = 48 AND `IS_NULLABLE` = 'YES')
                OR (`TABLE_NAME` = 'synex_group_operations' AND `COLUMN_NAME` = 'idempotency_key'
                    AND `CHARACTER_MAXIMUM_LENGTH` = 128 AND `IS_NULLABLE` = 'NO')
                OR (`TABLE_NAME` = 'synex_group_outbox' AND `COLUMN_NAME` IN ('event_id', 'aggregate_id')
                    AND `CHARACTER_MAXIMUM_LENGTH` = 48 AND `IS_NULLABLE` = 'NO')
            )
    ) <> 16 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex groups migration 008 identifier metadata verification failed';
    END IF;
END;

-- synex:statement
CALL `synex_groups_migrate_008_public_id_compatibility`();

-- synex:statement
DROP PROCEDURE IF EXISTS `synex_groups_migrate_008_public_id_compatibility`;
