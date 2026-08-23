DROP PROCEDURE IF EXISTS `synex_migrate_017_runtime_scalability`;

-- synex:statement
CREATE PROCEDURE `synex_migrate_017_runtime_scalability`()
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_sessions'
            AND `INDEX_NAME` = 'idx_sessions_instance_generation'
    ) THEN
        ALTER TABLE `synex_sessions`
            ADD KEY `idx_sessions_instance_generation`
                (`server_instance_id`, `source_generation`);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_sessions'
            AND `INDEX_NAME` = 'idx_sessions_instance_open'
    ) THEN
        ALTER TABLE `synex_sessions`
            ADD KEY `idx_sessions_instance_open`
                (`server_instance_id`, `closed_at`, `id`);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE()
            AND `TABLE_NAME` = 'synex_session_control_requests'
            AND `INDEX_NAME` = 'idx_session_control_requester_pending'
    ) THEN
        ALTER TABLE `synex_session_control_requests`
            ADD KEY `idx_session_control_requester_pending`
                (`requested_by_instance_id`, `state`, `created_at`, `request_id`);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_cluster_leases'
            AND `INDEX_NAME` = 'idx_cluster_leases_owner_expiry'
    ) THEN
        ALTER TABLE `synex_cluster_leases`
            ADD KEY `idx_cluster_leases_owner_expiry`
                (`owner_id`, `expires_at`, `lease_name`);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_cluster_leases'
            AND `COLUMN_NAME` = 'lease_domain_kind'
    ) THEN
        ALTER TABLE `synex_cluster_leases`
            ADD COLUMN `lease_domain_kind` VARCHAR(20)
                CHARACTER SET ascii COLLATE ascii_bin
                GENERATED ALWAYS AS (
                    CASE
                        WHEN LEFT(`lease_name`, 5) = 'saga:' THEN 'saga'
                        WHEN LEFT(`lease_name`, 17) = 'character-delete:' THEN 'character-delete'
                        ELSE NULL
                    END
                ) STORED AFTER `lease_name`;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_cluster_leases'
            AND `INDEX_NAME` = 'idx_cluster_leases_domain_expiry'
    ) THEN
        ALTER TABLE `synex_cluster_leases`
            ADD KEY `idx_cluster_leases_domain_expiry`
                (`lease_domain_kind`, `expires_at`, `lease_name`);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_audit_log'
            AND `COLUMN_NAME` = 'archive_recorded_at'
    ) THEN
        ALTER TABLE `synex_audit_log`
            ADD COLUMN `archive_recorded_at` DATETIME(6) NULL AFTER `context_json`;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM `information_schema`.`STATISTICS`
        WHERE `TABLE_SCHEMA` = DATABASE() AND `TABLE_NAME` = 'synex_audit_log'
            AND `INDEX_NAME` = 'idx_audit_log_archive_queue'
    ) THEN
        ALTER TABLE `synex_audit_log`
            ADD KEY `idx_audit_log_archive_queue`
                (`archive_recorded_at`, `occurred_at`, `id`);
    END IF;
END;

-- synex:statement
CALL `synex_migrate_017_runtime_scalability`();

-- synex:statement
DROP PROCEDURE IF EXISTS `synex_migrate_017_runtime_scalability`;
