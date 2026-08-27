CREATE TABLE IF NOT EXISTS `synex_group_membership_transition_policies` (
    `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `public_id` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `group_id` BIGINT UNSIGNED NOT NULL,
    `from_state` VARCHAR(32) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `to_state` VARCHAR(32) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `allowed` TINYINT UNSIGNED NOT NULL DEFAULT 1,
    `required_capability`
        VARCHAR(96) CHARACTER SET ascii COLLATE ascii_bin NOT NULL
        DEFAULT 'synex.groups.members.manage',
    `approval_required` TINYINT UNSIGNED NOT NULL DEFAULT 0,
    `reason_required` TINYINT UNSIGNED NOT NULL DEFAULT 1,
    `updated_by_ref` VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `version` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    `created_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
        ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_group_membership_transition_policy_public` (`public_id`),
    UNIQUE KEY `uq_group_membership_transition_policy_route`
        (`group_id`, `from_state`, `to_state`),
    CONSTRAINT `fk_group_membership_transition_policy_group`
        FOREIGN KEY (`group_id`) REFERENCES `synex_groups` (`id`) ON DELETE RESTRICT,
    CONSTRAINT `fk_group_membership_transition_policy_from_state`
        FOREIGN KEY (`from_state`)
        REFERENCES `synex_group_membership_states` (`state_key`) ON DELETE RESTRICT,
    CONSTRAINT `fk_group_membership_transition_policy_to_state`
        FOREIGN KEY (`to_state`)
        REFERENCES `synex_group_membership_states` (`state_key`) ON DELETE RESTRICT,
    CONSTRAINT `chk_group_membership_transition_policy_public`
        CHECK (`public_id` REGEXP '^[a-z][a-z0-9_]{7,47}$'),
    CONSTRAINT `chk_group_membership_transition_policy_route`
        CHECK (`from_state` REGEXP '^[A-Z][A-Z0-9_]{1,31}$'
            AND `to_state` REGEXP '^[A-Z][A-Z0-9_]{1,31}$'
            AND `from_state` <> `to_state`),
    CONSTRAINT `chk_group_membership_transition_policy_flags`
        CHECK (`allowed` IN (0, 1)
            AND `approval_required` IN (0, 1)
            AND `reason_required` IN (0, 1)),
    CONSTRAINT `chk_group_membership_transition_policy_capability`
        CHECK (`required_capability` REGEXP
            '^[a-z][a-z0-9_-]*(\\.[a-z][a-z0-9_-]*)*$'),
    CONSTRAINT `chk_group_membership_transition_policy_actor`
        CHECK (`updated_by_ref` REGEXP
            '^[A-Za-z0-9][A-Za-z0-9_.:%-]{7,47}$'),
    CONSTRAINT `chk_group_membership_transition_policy_version`
        CHECK (`version` > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
DROP PROCEDURE IF EXISTS `synex_groups_verify_028_membership_transition_policies`;

-- synex:statement
CREATE PROCEDURE `synex_groups_verify_028_membership_transition_policies`()
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`TABLES`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_group_membership_transition_policies'
            AND UPPER(`ENGINE`) = 'INNODB'
    ) OR (
        SELECT COUNT(*) FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_group_membership_transition_policies'
            AND ((`COLUMN_NAME` = 'id' AND `DATA_TYPE` = 'bigint'
                    AND `COLUMN_TYPE` LIKE '%unsigned%'
                    AND `IS_NULLABLE` = 'NO' AND `EXTRA` LIKE '%auto_increment%')
                OR (`COLUMN_NAME` = 'public_id' AND `DATA_TYPE` = 'varchar'
                    AND `CHARACTER_MAXIMUM_LENGTH` = 48
                    AND `CHARACTER_SET_NAME` = 'ascii'
                    AND `COLLATION_NAME` = 'ascii_bin' AND `IS_NULLABLE` = 'NO')
                OR (`COLUMN_NAME` = 'group_id' AND `DATA_TYPE` = 'bigint'
                    AND `COLUMN_TYPE` LIKE '%unsigned%' AND `IS_NULLABLE` = 'NO')
                OR (`COLUMN_NAME` IN ('from_state', 'to_state')
                    AND `DATA_TYPE` = 'varchar' AND `CHARACTER_MAXIMUM_LENGTH` = 32
                    AND `CHARACTER_SET_NAME` = 'ascii'
                    AND `COLLATION_NAME` = 'ascii_bin' AND `IS_NULLABLE` = 'NO')
                OR (`COLUMN_NAME` IN ('allowed', 'approval_required', 'reason_required')
                    AND `DATA_TYPE` = 'tinyint' AND `COLUMN_TYPE` LIKE '%unsigned%'
                    AND `IS_NULLABLE` = 'NO')
                OR (`COLUMN_NAME` = 'required_capability' AND `DATA_TYPE` = 'varchar'
                    AND `CHARACTER_MAXIMUM_LENGTH` = 96
                    AND `CHARACTER_SET_NAME` = 'ascii'
                    AND `COLLATION_NAME` = 'ascii_bin' AND `IS_NULLABLE` = 'NO')
                OR (`COLUMN_NAME` = 'updated_by_ref' AND `DATA_TYPE` = 'varchar'
                    AND `CHARACTER_MAXIMUM_LENGTH` = 48
                    AND `CHARACTER_SET_NAME` = 'ascii'
                    AND `COLLATION_NAME` = 'ascii_bin' AND `IS_NULLABLE` = 'NO')
                OR (`COLUMN_NAME` = 'version' AND `DATA_TYPE` = 'bigint'
                    AND `COLUMN_TYPE` LIKE '%unsigned%' AND `IS_NULLABLE` = 'NO')
                OR (`COLUMN_NAME` IN ('created_at', 'updated_at')
                    AND `DATA_TYPE` = 'datetime' AND `DATETIME_PRECISION` = 6
                    AND `IS_NULLABLE` = 'NO'))
    ) <> 13 OR (
        SELECT COUNT(*) FROM `information_schema`.`TABLE_CONSTRAINTS`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_group_membership_transition_policies'
            AND ((`CONSTRAINT_NAME` IN (
                    'uq_group_membership_transition_policy_public',
                    'uq_group_membership_transition_policy_route'
                ) AND `CONSTRAINT_TYPE` = 'UNIQUE')
                OR (`CONSTRAINT_NAME` IN (
                    'fk_group_membership_transition_policy_group',
                    'fk_group_membership_transition_policy_from_state',
                    'fk_group_membership_transition_policy_to_state'
                ) AND `CONSTRAINT_TYPE` = 'FOREIGN KEY')
                OR (`CONSTRAINT_NAME` IN (
                    'chk_group_membership_transition_policy_public',
                    'chk_group_membership_transition_policy_route',
                    'chk_group_membership_transition_policy_flags',
                    'chk_group_membership_transition_policy_capability',
                    'chk_group_membership_transition_policy_actor',
                    'chk_group_membership_transition_policy_version'
                ) AND `CONSTRAINT_TYPE` = 'CHECK'))
    ) <> 11 OR (
        SELECT COUNT(*) FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_group_membership_transition_policies'
            AND `INDEX_NAME` = 'uq_group_membership_transition_policy_public'
    ) <> 1 OR (
        SELECT COUNT(*) FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_group_membership_transition_policies'
            AND `INDEX_NAME` = 'uq_group_membership_transition_policy_public'
            AND `NON_UNIQUE` = 0 AND `SUB_PART` IS NULL
            AND `SEQ_IN_INDEX` = 1 AND `COLUMN_NAME` = 'public_id'
    ) <> 1 OR (
        SELECT COUNT(*) FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_group_membership_transition_policies'
            AND `INDEX_NAME` = 'uq_group_membership_transition_policy_route'
    ) <> 3 OR (
        SELECT COUNT(*) FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_group_membership_transition_policies'
            AND `INDEX_NAME` = 'uq_group_membership_transition_policy_route'
            AND `NON_UNIQUE` = 0 AND `SUB_PART` IS NULL
            AND ((`SEQ_IN_INDEX` = 1 AND `COLUMN_NAME` = 'group_id')
                OR (`SEQ_IN_INDEX` = 2 AND `COLUMN_NAME` = 'from_state')
                OR (`SEQ_IN_INDEX` = 3 AND `COLUMN_NAME` = 'to_state'))
    ) <> 3 OR (
        SELECT COUNT(*) FROM `information_schema`.`KEY_COLUMN_USAGE`
        WHERE `CONSTRAINT_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_group_membership_transition_policies'
            AND ((`CONSTRAINT_NAME` = 'fk_group_membership_transition_policy_group'
                    AND `COLUMN_NAME` = 'group_id'
                    AND `REFERENCED_TABLE_NAME` = 'synex_groups'
                    AND `REFERENCED_COLUMN_NAME` = 'id')
                OR (`CONSTRAINT_NAME` = 'fk_group_membership_transition_policy_from_state'
                    AND `COLUMN_NAME` = 'from_state'
                    AND `REFERENCED_TABLE_NAME` = 'synex_group_membership_states'
                    AND `REFERENCED_COLUMN_NAME` = 'state_key')
                OR (`CONSTRAINT_NAME` = 'fk_group_membership_transition_policy_to_state'
                    AND `COLUMN_NAME` = 'to_state'
                    AND `REFERENCED_TABLE_NAME` = 'synex_group_membership_states'
                    AND `REFERENCED_COLUMN_NAME` = 'state_key'))
    ) <> 3 OR EXISTS (
        SELECT 1 FROM `synex_group_membership_transition_policies`
        WHERE `public_id` NOT REGEXP '^[a-z][a-z0-9_]{7,47}$'
            OR `from_state` NOT REGEXP '^[A-Z][A-Z0-9_]{1,31}$'
            OR `to_state` NOT REGEXP '^[A-Z][A-Z0-9_]{1,31}$'
            OR `from_state` = `to_state`
            OR `allowed` NOT IN (0, 1)
            OR `approval_required` NOT IN (0, 1)
            OR `reason_required` NOT IN (0, 1)
            OR `required_capability` NOT REGEXP
                '^[a-z][a-z0-9_-]*(\\.[a-z][a-z0-9_-]*)*$'
            OR `updated_by_ref` NOT REGEXP
                '^[A-Za-z0-9][A-Za-z0-9_.:%-]{7,47}$'
            OR `version` < 1
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex groups migration 028 transition policy verification failed';
    END IF;
END;

-- synex:statement
CALL `synex_groups_verify_028_membership_transition_policies`();

-- synex:statement
DROP PROCEDURE IF EXISTS `synex_groups_verify_028_membership_transition_policies`;
