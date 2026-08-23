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

    local function affectedRows(value)
        if type(value) == 'table' then return tonumber(value.affectedRows) end
        return tonumber(value)
    end

    function audit:archiveBatch()
        if auditPolicy.mode ~= 'archive' then
            return {
                scope = 'audit', mode = 'retain_forever', skipped = true,
                archived = 0, sourceRowsDeleted = 0
            }, nil
        end

        local archived, selected = 0, 0
        local archiveFailure = nil
        local committed, archiveError = database:withTransaction(function(query)
            archived, selected, archiveFailure = 0, 0, nil
            local rows = query([[SELECT CAST(`id` AS CHAR) AS `source_audit_id`
                FROM `synex_audit_log`
                WHERE `archive_recorded_at` IS NULL
                    AND `occurred_at` < TIMESTAMPADD(DAY, -?, UTC_TIMESTAMP(6))
                ORDER BY `occurred_at` ASC, `id` ASC LIMIT ? FOR UPDATE]], {
                auditPolicy.archiveAfterDays, config.batchSize
            })
            if type(rows) ~= 'table' or #rows > config.batchSize then
                archiveFailure = foundation.error('RETENTION_BATCH_INVALID',
                    'The audit archive candidate batch is invalid.', { retryable = true })
                return false
            end
            selected = #rows
            if selected == 0 then return true end

            local ids, placeholders, seen = {}, {}, {}
            for index, row in ipairs(rows) do
                local id = type(row) == 'table' and tostring(row.source_audit_id or '') or ''
                if #id < 1 or #id > 20 or not id:match('^[1-9][0-9]*$') or seen[id] then
                    archiveFailure = foundation.error('RETENTION_BATCH_INVALID',
                        'The audit archive candidate identity is invalid.', { retryable = true })
                    return false
                end
                seen[id] = true
                ids[index], placeholders[index] = id, '?'
            end
            local idList = table.concat(placeholders, ', ')
            local inserted = query([[INSERT IGNORE INTO `synex_audit_archive`
                (`source_audit_id`, `event_id`, `occurred_at`, `actor_type`, `actor_id`, `action`,
                    `target_type`, `target_id`, `trace_id`, `before_json`, `after_json`,
                    `context_json`, `archived_at`)
                SELECT `source`.`id`, `source`.`event_id`, `source`.`occurred_at`, `source`.`actor_type`,
                    `source`.`actor_id`, `source`.`action`, `source`.`target_type`, `source`.`target_id`,
                    `source`.`trace_id`, `source`.`before_json`, `source`.`after_json`,
                    `source`.`context_json`, UTC_TIMESTAMP(6)
                FROM `synex_audit_log` AS `source`
                WHERE `source`.`archive_recorded_at` IS NULL
                    AND `source`.`id` IN (]] .. idList .. [[)]], ids)
            local insertedCount = affectedRows(inserted)
            if not insertedCount or math.type(insertedCount) ~= 'integer'
                or insertedCount < 0 or insertedCount > selected then
                archiveFailure = foundation.error('RETENTION_BATCH_INVALID',
                    'The audit archive insert result is invalid.', { retryable = true })
                return false
            end

            local marked = query([[UPDATE `synex_audit_log` AS `source`
                INNER JOIN `synex_audit_archive` AS `archive`
                    ON `archive`.`source_audit_id` = `source`.`id`
                        AND `archive`.`event_id` = `source`.`event_id`
                        AND `archive`.`occurred_at` = `source`.`occurred_at`
                SET `source`.`archive_recorded_at` = `archive`.`archived_at`
                WHERE `source`.`archive_recorded_at` IS NULL
                    AND `source`.`id` IN (]] .. idList .. [[)]], ids)
            archived = affectedRows(marked)
            if not archived or math.type(archived) ~= 'integer' or archived ~= selected then
                archiveFailure = foundation.error('RETENTION_ARCHIVE_INCOMPLETE',
                    'The audit archive checkpoint did not cover the locked batch.', { retryable = true })
                return false
            end
            return true
        end)
        if not committed then
            metrics:increment('synex_retention_runs_total', { scope = 'audit', result = 'failed' })
            return nil, archiveFailure or archiveError
        end

        local report = {
            scope = 'audit', mode = 'archive', skipped = false,
            archiveAfterDays = auditPolicy.archiveAfterDays,
            batchSize = config.batchSize,
            archived = archived,
            sourceRowsDeleted = 0,
            batchExhausted = selected >= config.batchSize
        }
        metrics:increment('synex_retention_runs_total', { scope = 'audit', result = 'completed' })
        metrics:increment('synex_retention_archived_rows_total', { scope = 'audit' }, archived)
        if archived > 0 then logger:info('audit archive batch completed', report) end
        return report, nil
    end

    return { audit = audit }
end
