SynexEntityCleanupQueue = {}

local ENTITY_TYPE_IDS = { ped = 1, vehicle = 2, object = 3 }

function SynexEntityCleanupQueue.create(options)
    assert(type(options) == 'table', 'entity cleanup queue options are required')
    local config = assert(options.config, 'entity cleanup queue config is required')
    local foundation = assert(options.foundation, 'entity cleanup queue foundation is required')
    local health = options.health
    local observability = assert(options.observability,
        'entity cleanup queue observability is required')
    local ports = assert(options.ports, 'entity cleanup queue ports are required')
    local maximumEntries = math.max(64, math.min(config.maxEntities or 4096, 20000))
    local batchSize = math.max(1, math.min(config.recoveryBatchSize or 16, 128))
    local entries = {}
    local count = 0
    local sequence = 0
    local queue = {}

    local function safeCode(value, fallback)
        if type(value) == 'string' and #value >= 2 and #value <= 64
            and value:match('^[A-Z][A-Z0-9_]*$') then return value end
        return fallback
    end

    local function safeFinding(value)
        value = type(value) == 'table' and value or {}
        local entityType = ENTITY_TYPE_IDS[value.entityType] and value.entityType or nil
        local output = {
            bucket = type(value.bucket) == 'number' and value.bucket or nil,
            code = safeCode(value.code, 'DELETE_FAILED'),
            entityId = type(value.entityId) == 'string' and value.entityId or nil,
            entityType = entityType,
            generation = type(value.generation) == 'number' and value.generation or nil,
            handle = type(value.handle) == 'number' and value.handle or nil,
            model = type(value.model) == 'number' and value.model or nil,
            netId = type(value.netId) == 'number' and value.netId or nil,
            operation = type(value.operation) == 'string'
                and value.operation:sub(1, 96) or 'entity.cleanup',
            resourceOwner = type(value.resourceOwner) == 'string'
                and value.resourceOwner:sub(1, 64) or nil,
        }
        return output
    end

    local function keyFor(finding)
        if finding.entityId and finding.generation then
            return ('entity:%s:%d'):format(finding.entityId, finding.generation)
        end
        return ('runtime:%s:%s:%s'):format(
            tostring(finding.handle or 'unknown'),
            tostring(finding.netId or 'unknown'),
            tostring(finding.model or 'unknown')
        )
    end

    local function publicEntry(entry)
        local output = {}
        for key, value in pairs(entry.finding) do output[key] = value end
        output.attempts = entry.attempts
        output.firstObservedAt = entry.firstObservedAt
        output.lastAttemptAt = entry.lastAttemptAt
        output.lastError = entry.lastError
        return output
    end

    function queue.enqueue(findingValue, handler, context)
        assert(type(handler) == 'function', 'entity cleanup handler is required')
        local finding = safeFinding(findingValue)
        local key = keyFor(finding)
        local entry = entries[key]
        if entry then
            entry.finding = finding
            entry.handler = handler
            return { queued = true, duplicate = true, key = key }
        end
        if count >= maximumEntries then
            foundation.setHealth('UNHEALTHY', 'ENTITY_CLEANUP_QUEUE_EXHAUSTED')
            observability.audit('entities.cleanup_queue_exhausted', 'resource',
                finding.resourceOwner or 'synex_entities', {
                    capacity = maximumEntries,
                    code = finding.code,
                    operation = finding.operation,
                }, context)
            observability.increment('entity_cleanup_queue_overflow_total', {}, 1)
            return foundation.failure('REGISTRY_LIMIT',
                'The bounded entity cleanup queue is full', true, context)
        end
        sequence = sequence + 1
        entry = {
            attempts = 0,
            finding = finding,
            firstObservedAt = os.date('!%Y-%m-%dT%H:%M:%SZ'),
            handler = handler,
            sequence = sequence,
        }
        entries[key] = entry
        count = count + 1
        foundation.setHealth('DEGRADED', 'ENTITY_CLEANUP_PENDING')
        observability.audit('entities.cleanup_queued', 'entity',
            finding.entityId or ('runtime:' .. tostring(finding.handle or 'unknown')),
            publicEntry(entry), context)
        observability.increment('entity_cleanup_queued_total', {
            code = finding.code,
        }, 1)
        return { queued = true, duplicate = false, key = key }
    end

    function queue.process(context)
        local ordered = {}
        for key, entry in pairs(entries) do
            ordered[#ordered + 1] = { key = key, entry = entry }
        end
        table.sort(ordered, function(left, right)
            return left.entry.sequence < right.entry.sequence
        end)
        local report = { attempted = 0, pending = count, resolved = 0 }
        for index = 1, math.min(#ordered, batchSize) do
            local item = ordered[index]
            local entry = item.entry
            entry.attempts = entry.attempts + 1
            entry.lastAttemptAt = os.date('!%Y-%m-%dT%H:%M:%SZ')
            report.attempted = report.attempted + 1
            local invoked, resolved, cleanupError = foundation.protect(
                'entity.cleanup_queue_retry', entry.handler, context)
            if invoked and resolved then
                entries[item.key] = nil
                count = count - 1
                report.resolved = report.resolved + 1
                observability.audit('entities.cleanup_resolved', 'entity',
                    entry.finding.entityId
                        or ('runtime:' .. tostring(entry.finding.handle or 'unknown')),
                    publicEntry(entry), context)
                observability.increment('entity_cleanup_resolved_total', {}, 1)
            else
                entry.lastError = safeCode(type(cleanupError) == 'table'
                    and cleanupError.code or nil, invoked and 'DELETE_FAILED'
                    or 'INTERNAL_ERROR')
                observability.increment('entity_cleanup_retry_failed_total', {
                    code = entry.lastError,
                }, 1)
            end
        end
        report.pending = count
        observability.gauge('entity_cleanup_pending', {}, count)
        if count > 0 then
            foundation.setHealth('DEGRADED', 'ENTITY_CLEANUP_PENDING')
        elseif type(health) == 'table' and health.state == 'DEGRADED'
            and health.reason == 'ENTITY_CLEANUP_PENDING' then
            foundation.setHealth('READY', 'Entity cleanup queue is empty')
        end
        return report
    end

    function queue.snapshot(limit)
        limit = math.max(1, math.min(tonumber(limit) or 25, 50))
        local ordered = {}
        for _, entry in pairs(entries) do ordered[#ordered + 1] = entry end
        table.sort(ordered, function(left, right) return left.sequence < right.sequence end)
        local findings = {}
        for index = 1, math.min(#ordered, limit) do
            findings[index] = publicEntry(ordered[index])
        end
        return {
            capacity = maximumEntries,
            count = count,
            findings = findings,
            truncated = count > #findings,
        }
    end

    return queue
end
