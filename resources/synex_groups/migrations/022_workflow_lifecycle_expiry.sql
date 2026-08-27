DROP PROCEDURE IF EXISTS `synex_groups_migrate_022_workflow_lifecycle_expiry`;

-- synex:statement
CREATE PROCEDURE `synex_groups_migrate_022_workflow_lifecycle_expiry`()
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLES`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_group_applications'
            AND UPPER(`ENGINE`) = 'INNODB'
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex groups migration 022 application prerequisite verification failed';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_group_applications'
            AND `COLUMN_NAME` = 'expires_at'
    ) THEN
        ALTER TABLE `synex_group_applications`
            ADD COLUMN `expires_at` DATETIME(6) NULL AFTER `application_json`;
    END IF;

    UPDATE `synex_group_applications`
        SET `expires_at` = TIMESTAMPADD(DAY, 30, `created_at`)
        WHERE `expires_at` IS NULL;

    ALTER TABLE `synex_group_applications`
        MODIFY COLUMN `expires_at` DATETIME(6) NOT NULL;

    IF EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_group_applications'
            AND `CONSTRAINT_NAME` = 'chk_group_applications_status'
            AND `CONSTRAINT_TYPE` = 'CHECK'
    ) THEN
        ALTER TABLE `synex_group_applications`
            DROP CONSTRAINT `chk_group_applications_status`;
    END IF;

    ALTER TABLE `synex_group_applications`
        ADD CONSTRAINT `chk_group_applications_status`
            CHECK (`status` IN (
                'submitted', 'reviewing', 'approved', 'rejected', 'withdrawn', 'expired'
            ));

    IF EXISTS (
        SELECT 1 FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_group_applications'
            AND `CONSTRAINT_NAME` = 'chk_group_applications_review'
            AND `CONSTRAINT_TYPE` = 'CHECK'
    ) THEN
        ALTER TABLE `synex_group_applications`
            DROP CONSTRAINT `chk_group_applications_review`;
    END IF;

    ALTER TABLE `synex_group_applications`
        ADD CONSTRAINT `chk_group_applications_review`
            CHECK ((`status` IN ('submitted', 'reviewing')
                        AND `reviewed_at` IS NULL AND `review_reason_code` IS NULL)
                OR (`status` IN ('approved', 'rejected')
                        AND `reviewed_at` IS NOT NULL
                        AND `reviewed_by_membership_id` IS NOT NULL
                        AND `review_reason_code` REGEXP '^[a-z][a-z0-9_.:-]{1,63}$')
                OR (`status` = 'withdrawn' AND `reviewed_at` IS NOT NULL)
                OR (`status` = 'expired' AND `reviewed_at` IS NOT NULL
                        AND `review_reason_code` REGEXP '^[a-z][a-z0-9_.:-]{1,63}$'));

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_group_applications'
            AND `INDEX_NAME` = 'idx_group_applications_expiry'
    ) THEN
        ALTER TABLE `synex_group_applications`
            ADD KEY `idx_group_applications_expiry` (`status`, `expires_at`, `id`);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_group_applications'
            AND `COLUMN_NAME` = 'expires_at'
            AND `DATA_TYPE` = 'datetime' AND `DATETIME_PRECISION` = 6
            AND `IS_NULLABLE` = 'NO'
    ) OR (
        SELECT COUNT(*) FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_group_applications'
            AND `INDEX_NAME` = 'idx_group_applications_expiry'
            AND ((`SEQ_IN_INDEX` = 1 AND `COLUMN_NAME` = 'status')
                OR (`SEQ_IN_INDEX` = 2 AND `COLUMN_NAME` = 'expires_at')
                OR (`SEQ_IN_INDEX` = 3 AND `COLUMN_NAME` = 'id'))
    ) <> 3 OR (
        SELECT COUNT(*) FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_group_applications'
            AND `INDEX_NAME` = 'idx_group_applications_expiry'
    ) <> 3 OR (
        SELECT COUNT(*) FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_group_applications'
            AND `CONSTRAINT_NAME` IN (
                'chk_group_applications_status', 'chk_group_applications_review'
            ) AND `CONSTRAINT_TYPE` = 'CHECK'
    ) <> 2 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex groups migration 022 workflow lifecycle verification failed';
    END IF;
END;

-- synex:statement
CALL `synex_groups_migrate_022_workflow_lifecycle_expiry`();

-- synex:statement
DROP PROCEDURE IF EXISTS `synex_groups_migrate_022_workflow_lifecycle_expiry`;
