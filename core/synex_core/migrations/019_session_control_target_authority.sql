DROP PROCEDURE IF EXISTS `synex_migrate_019_session_control_target_authority`;

-- synex:statement
CREATE PROCEDURE `synex_migrate_019_session_control_target_authority`()
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_session_control_requests'
            AND `COLUMN_NAME` = 'target_instance_id'
    ) THEN
        ALTER TABLE `synex_session_control_requests`
            ADD COLUMN `target_instance_id` CHAR(36)
                CHARACTER SET ascii COLLATE ascii_bin NULL
                AFTER `target_session_id`;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_session_control_requests'
            AND `COLUMN_NAME` = 'target_instance_id'
            AND `DATA_TYPE` = 'char'
            AND `CHARACTER_MAXIMUM_LENGTH` = 36
            AND `CHARACTER_SET_NAME` = 'ascii'
            AND `COLLATION_NAME` = 'ascii_bin'
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex migration 019 target instance column verification failed';
    END IF;

    UPDATE `synex_session_control_requests` AS `request`
    INNER JOIN `synex_sessions` AS `session`
        ON `session`.`id` = `request`.`target_session_id`
    SET `request`.`target_instance_id` = `session`.`server_instance_id`
    WHERE `request`.`target_instance_id` IS NULL
        OR `request`.`target_instance_id` <> `session`.`server_instance_id`;

    IF EXISTS (
        SELECT 1 FROM `synex_session_control_requests`
        WHERE `target_instance_id` IS NULL
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex migration 019 could not backfill target instance authority';
    END IF;

    IF EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_session_control_requests'
            AND `COLUMN_NAME` = 'target_instance_id'
            AND `IS_NULLABLE` = 'YES'
    ) THEN
        ALTER TABLE `synex_session_control_requests`
            MODIFY COLUMN `target_instance_id` CHAR(36)
                CHARACTER SET ascii COLLATE ascii_bin NOT NULL;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_session_control_requests'
            AND `COLUMN_NAME` = 'target_instance_id'
            AND `DATA_TYPE` = 'char'
            AND `CHARACTER_MAXIMUM_LENGTH` = 36
            AND `CHARACTER_SET_NAME` = 'ascii'
            AND `COLLATION_NAME` = 'ascii_bin'
            AND `IS_NULLABLE` = 'NO'
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex migration 019 target instance authority is not mandatory';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_session_control_requests'
            AND `INDEX_NAME` = 'idx_session_control_target_pending'
    ) THEN
        ALTER TABLE `synex_session_control_requests`
            ADD KEY `idx_session_control_target_pending`
                (`target_instance_id`, `state`, `expires_at`, `created_at`, `request_id`);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_session_control_requests'
            AND `INDEX_NAME` = 'idx_session_control_target_pending'
            AND `NON_UNIQUE` = 1 AND `SEQ_IN_INDEX` = 1
            AND `COLUMN_NAME` = 'target_instance_id'
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_session_control_requests'
            AND `INDEX_NAME` = 'idx_session_control_target_pending'
            AND `NON_UNIQUE` = 1 AND `SEQ_IN_INDEX` = 2
            AND `COLUMN_NAME` = 'state'
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_session_control_requests'
            AND `INDEX_NAME` = 'idx_session_control_target_pending'
            AND `NON_UNIQUE` = 1 AND `SEQ_IN_INDEX` = 3
            AND `COLUMN_NAME` = 'expires_at'
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_session_control_requests'
            AND `INDEX_NAME` = 'idx_session_control_target_pending'
            AND `NON_UNIQUE` = 1 AND `SEQ_IN_INDEX` = 4
            AND `COLUMN_NAME` = 'created_at'
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_session_control_requests'
            AND `INDEX_NAME` = 'idx_session_control_target_pending'
            AND `NON_UNIQUE` = 1 AND `SEQ_IN_INDEX` = 5
            AND `COLUMN_NAME` = 'request_id'
    ) OR EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_session_control_requests'
            AND `INDEX_NAME` = 'idx_session_control_target_pending'
            AND `SEQ_IN_INDEX` > 5
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex migration 019 target request index verification failed';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_session_control_requests'
            AND `INDEX_NAME` = 'idx_session_control_state_scan'
    ) THEN
        ALTER TABLE `synex_session_control_requests`
            ADD KEY `idx_session_control_state_scan` (`state`, `request_id`);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_session_control_requests'
            AND `INDEX_NAME` = 'idx_session_control_state_scan'
            AND `NON_UNIQUE` = 1 AND `SEQ_IN_INDEX` = 1
            AND `COLUMN_NAME` = 'state'
    ) OR NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_session_control_requests'
            AND `INDEX_NAME` = 'idx_session_control_state_scan'
            AND `NON_UNIQUE` = 1 AND `SEQ_IN_INDEX` = 2
            AND `COLUMN_NAME` = 'request_id'
    ) OR EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_session_control_requests'
            AND `INDEX_NAME` = 'idx_session_control_state_scan'
            AND `SEQ_IN_INDEX` > 2
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex migration 019 control scan index verification failed';
    END IF;
END;

-- synex:statement
CALL `synex_migrate_019_session_control_target_authority`();

-- synex:statement
DROP PROCEDURE IF EXISTS `synex_migrate_019_session_control_target_authority`;
