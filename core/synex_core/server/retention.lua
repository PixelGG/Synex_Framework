local factories = assert(SynexCoreFactories, 'factories must be loaded first')

factories.retention = function(deps)
    local foundation = assert(deps.foundation, 'retention requires foundation')
    local database = assert(deps.database, 'retention requires database')
    local config = assert(deps.config, 'retention requires configuration')
    local metrics = foundation.metrics
    local logger = foundation.logger

    local auditPolicy = config.audit
    if type(auditPolicy) ~= 'table'
        or (auditPolicy.mode ~= 'retain_forever' and auditPolicy.mode ~= 'archive')
        or type(auditPolicy.archiveAfterDays) ~= 'number'
        or math.type(auditPolicy.archiveAfterDays) ~= 'integer'
        or auditPolicy.archiveAfterDays < 1 or auditPolicy.archiveAfterDays > 36500
        or type(config.batchSize) ~= 'number' or math.type(config.batchSize) ~= 'integer'
        or config.batchSize < 1 or config.batchSize > 1000 then
        error('retention received invalid validated configuration')
    end

    local audit = {}

    function audit:archiveBatch()
        if auditPolicy.mode ~= 'archive' then
            return {
                scope = 'audit', mode = 'retain_forever', skipped = true,
                archived = 0, sourceRowsDeleted = 0
            }, nil
        end

        local archived, archiveError = database:update([[INSERT IGNORE INTO `synex_audit_archive`
            (`source_audit_id`, `event_id`, `occurred_at`, `actor_type`, `actor_id`, `action`,
                `target_type`, `target_id`, `trace_id`, `before_json`, `after_json`, `context_json`, `archived_at`)
            SELECT `source`.`id`, `source`.`event_id`, `source`.`occurred_at`, `source`.`actor_type`,
                `source`.`actor_id`, `source`.`action`, `source`.`target_type`, `source`.`target_id`,
                `source`.`trace_id`, `source`.`before_json`, `source`.`after_json`, `source`.`context_json`,
                UTC_TIMESTAMP(6)
            FROM `synex_audit_log` AS `source`
            WHERE `source`.`occurred_at` < TIMESTAMPADD(DAY, -?, UTC_TIMESTAMP(6))
                AND NOT EXISTS (SELECT 1 FROM `synex_audit_archive` AS `archive`
                    WHERE `archive`.`source_audit_id` = `source`.`id`)
            ORDER BY `source`.`id` ASC LIMIT ?]], {
            auditPolicy.archiveAfterDays, config.batchSize
        })
        if archived == nil then
            metrics:increment('synex_retention_runs_total', { scope = 'audit', result = 'failed' })
            return nil, archiveError
        end

        local report = {
            scope = 'audit', mode = 'archive', skipped = false,
            archiveAfterDays = auditPolicy.archiveAfterDays,
            batchSize = config.batchSize,
            archived = archived,
            sourceRowsDeleted = 0,
            batchExhausted = archived >= config.batchSize
        }
        metrics:increment('synex_retention_runs_total', { scope = 'audit', result = 'completed' })
        metrics:increment('synex_retention_archived_rows_total', { scope = 'audit' }, archived)
        if archived > 0 then logger:info('audit archive batch completed', report) end
        return report, nil
    end

    return { audit = audit }
end
