CREATE TABLE IF NOT EXISTS `synex_rbac_policy_revisions` (
    `singleton_id` TINYINT UNSIGNED NOT NULL,
    `revision` BIGINT UNSIGNED NOT NULL DEFAULT 1,
    `updated_at` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (`singleton_id`),
    CONSTRAINT `chk_rbac_policy_revision_singleton` CHECK (`singleton_id` = 1),
    CONSTRAINT `chk_rbac_policy_revision_value` CHECK (`revision` > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- synex:statement
INSERT INTO `synex_rbac_policy_revisions` (`singleton_id`, `revision`)
VALUES (1, 1)
ON DUPLICATE KEY UPDATE `singleton_id` = VALUES(`singleton_id`);
