DROP PROCEDURE IF EXISTS `synex_groups_migrate_029_assignment_member_active_counts`;

-- synex:statement
CREATE PROCEDURE `synex_groups_migrate_029_assignment_member_active_counts`()
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_group_assignment_members'
            AND `INDEX_NAME` = 'idx_group_assignment_members_assignment_active'
    ) THEN
        ALTER TABLE `synex_group_assignment_members`
            ADD KEY `idx_group_assignment_members_assignment_active`
                (`assignment_id`, `active_marker`);
    END IF;

    IF (
        SELECT COUNT(*) FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_group_assignment_members'
            AND `INDEX_NAME` = 'idx_group_assignment_members_assignment_active'
    ) <> 2 OR (
        SELECT COUNT(*) FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_group_assignment_members'
            AND `INDEX_NAME` = 'idx_group_assignment_members_assignment_active'
            AND `NON_UNIQUE` = 1 AND `SUB_PART` IS NULL
            AND ((`SEQ_IN_INDEX` = 1 AND `COLUMN_NAME` = 'assignment_id')
                OR (`SEQ_IN_INDEX` = 2 AND `COLUMN_NAME` = 'active_marker'))
    ) <> 2 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex groups migration 029 assignment count index verification failed';
    END IF;
END;

-- synex:statement
CALL `synex_groups_migrate_029_assignment_member_active_counts`();

-- synex:statement
DROP PROCEDURE IF EXISTS `synex_groups_migrate_029_assignment_member_active_counts`;
