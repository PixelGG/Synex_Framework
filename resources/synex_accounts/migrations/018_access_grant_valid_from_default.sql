DROP PROCEDURE IF EXISTS `synex_migrate_018_access_grant_valid_from_default`;

-- synex:statement
CREATE PROCEDURE `synex_migrate_018_access_grant_valid_from_default`()
BEGIN
    ALTER TABLE `synex_account_access_grants`
        MODIFY COLUMN `valid_from`
            DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6);

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_account_access_grants'
            AND `COLUMN_NAME` = 'valid_from'
            AND LOWER(`DATA_TYPE`) = 'datetime'
            AND `DATETIME_PRECISION` = 6
            AND `IS_NULLABLE` = 'NO'
            AND LOWER(REPLACE(CAST(`COLUMN_DEFAULT` AS CHAR), ' ', ''))
                = 'current_timestamp(6)'
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'synex migration 018 valid_from metadata verification failed';
    END IF;
END;

-- synex:statement
CALL `synex_migrate_018_access_grant_valid_from_default`();

-- synex:statement
DROP PROCEDURE IF EXISTS `synex_migrate_018_access_grant_valid_from_default`;

-- synex:statement
INSERT INTO `synex_account_migration_assertions`
    (`migration_id`, `violation_count`, `details_json`)
SELECT '018_access_grant_valid_from_default',
    COUNT(*),
    JSON_OBJECT(
        'validFromRequired', TRUE,
        'omittedWriteDefault', 'CURRENT_TIMESTAMP(6)'
    )
FROM `synex_account_access_grants`
WHERE `valid_from` IS NULL
ON DUPLICATE KEY UPDATE
    `violation_count` = VALUES(`violation_count`),
    `details_json` = VALUES(`details_json`),
    `verified_at` = CURRENT_TIMESTAMP(6);
