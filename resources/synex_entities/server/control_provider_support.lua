SynexEntityControlProviderSupport = {}

local OPERATIONS = {
    'summary', 'health', 'list', 'inspect', 'search', 'metrics', 'findings'
}

local VIEWS = {
    { id = 'overview', label = 'Entities overview', operation = 'summary', presentation = 'key-value', order = 10,
        description = 'Bounded entity authority and runtime totals.' },
    { id = 'health', label = 'Entities health', operation = 'health', presentation = 'key-value', order = 20,
        description = 'Current authority, persistence, drift, and cleanup state.' },
    { id = 'runtime', label = 'Runtime', operation = 'list', presentation = 'table', order = 30,
        description = 'Cursor-based in-memory entity authority state.' },
    { id = 'persistent', label = 'Persistent', operation = 'list', presentation = 'table', order = 40,
        description = 'Cursor-based durable entity definitions.' },
    { id = 'bindings', label = 'Bindings', operation = 'list', presentation = 'table', order = 50,
        description = 'Cursor-based active binding metadata.' },
    { id = 'owners', label = 'Logical owners', operation = 'list', presentation = 'table', order = 60,
        description = 'Cursor-based logical-owner aggregates.' },
    { id = 'resources', label = 'Resource owners', operation = 'list', presentation = 'table', order = 70,
        description = 'Cursor-based resource-owner aggregates.' },
    { id = 'buckets', label = 'Buckets', operation = 'list', presentation = 'table', order = 80,
        description = 'Cursor-based managed routing buckets.' },
    { id = 'components', label = 'Components', operation = 'list', presentation = 'table', order = 90,
        description = 'Cursor-based component metadata without payloads.' },
    { id = 'state', label = 'State', operation = 'list', presentation = 'table', order = 100,
        description = 'Cursor-based state metadata without values.' },
    { id = 'recovery_log', label = 'Recovery', operation = 'list', presentation = 'timeline', order = 110,
        description = 'Cursor-based cluster recovery history.' },
    { id = 'cluster_authority', label = 'Cluster authority', operation = 'summary', presentation = 'key-value', order = 120,
        description = 'Current authority lease and server scope.' },
    { id = 'drift', label = 'Drift', operation = 'findings', presentation = 'findings', order = 130,
        description = 'Current persistence and runtime drift findings.' },
    { id = 'quotas', label = 'Quotas', operation = 'summary', presentation = 'key-value', order = 140,
        description = 'Live usage, pending reservations, and entity authority bounds.' },
    { id = 'entities', label = 'Entities', operation = 'list', presentation = 'table', order = 150,
        description = 'Cursor-based durable entity definitions.' },
    { id = 'bucket_entities', label = 'Bucket entities', operation = 'list', presentation = 'table', order = 160,
        description = 'Cursor-based entities in a routing bucket.', input = { fields = {
            { key = 'bucket', label = 'Bucket', source = 'filter', type = 'integer', format = 'integer', required = true, minimum = 0, maximum = 2147483647 },
            { key = 'generation', label = 'Generation', source = 'filter', type = 'integer', format = 'integer', required = true, minimum = 0, maximum = 2147483647 },
        } } },
    { id = 'entity', label = 'Entity inspector', operation = 'inspect', presentation = 'detail', order = 170,
        description = 'Inspect one entity authority and runtime read model.', input = { fields = {
            { key = 'id', label = 'Entity ID', source = 'id', type = 'string', format = 'identifier', required = true, minLength = 1, maxLength = 64 },
        } } },
    { id = 'binding', label = 'Binding inspector', operation = 'inspect', presentation = 'detail', order = 180,
        description = 'Inspect one entity binding by entity identifier.', input = { fields = {
            { key = 'id', label = 'Entity ID', source = 'id', type = 'string', format = 'identifier', required = true, minLength = 1, maxLength = 64 },
        } } },
    { id = 'component', label = 'Component inspector', operation = 'inspect', presentation = 'detail', order = 190,
        description = 'Inspect one component metadata record without its payload.', input = { fields = {
            { key = 'id', label = 'Entity ID', source = 'id', type = 'string', format = 'identifier', required = true, minLength = 1, maxLength = 64 },
            { key = 'namespace', label = 'Namespace', source = 'filter', type = 'string', format = 'identifier', required = true, minLength = 1, maxLength = 64 },
        } } },
    { id = 'recovery', label = 'Recovery inspector', operation = 'inspect', presentation = 'detail', order = 200,
        description = 'Inspect one entity recovery circuit and bounded history.', input = { fields = {
            { key = 'id', label = 'Entity ID', source = 'id', type = 'string', format = 'identifier', required = true, minLength = 1, maxLength = 64 },
        } } },
    { id = 'bucket', label = 'Bucket inspector', operation = 'inspect', presentation = 'detail', order = 210,
        description = 'Inspect one managed routing bucket.', input = { fields = {
            { key = 'id', label = 'Bucket', source = 'id', type = 'string', format = 'numeric-string', required = true, minLength = 1, maxLength = 10 },
            { key = 'generation', label = 'Generation', source = 'filter', type = 'integer', format = 'integer', required = true, minimum = 0, maximum = 2147483647 },
        } } },
    { id = 'search', label = 'Find entity', operation = 'search', presentation = 'table', order = 220,
        description = 'Exact lookup by entity identifier.' },
    { id = 'metrics', label = 'Metrics', operation = 'metrics', presentation = 'metrics', order = 230,
        description = 'Measured entity runtime metrics.' },
    { id = 'findings', label = 'Findings', operation = 'findings', presentation = 'findings', order = 240,
        description = 'Bounded diagnostic and recovery findings.' },
    { id = 'character_relations', label = 'Character relations', operation = 'inspect', presentation = 'detail', order = 250,
        description = 'Bounded persistent-entity links for one exact character identifier.' },
}

for _, view in ipairs(VIEWS) do
    view.accessClass = 'general'
    if view.id == 'search' then
        view.search = { kinds = {
            { id = 'entity', modes = { 'exact' }, accessClass = 'general' },
        } }
    end
end

function SynexEntityControlProviderSupport.annotateNetworkOwner(value)
    if type(value) == 'table' then
        value.networkOwnerPolicy = {
            semantics = 'transport_only', authoritative = false,
            note = 'Network ownership is transport state and never authorization.',
        }
    end
    return value
end

function SynexEntityControlProviderSupport.runtimeView(record)
    return {
        archetype = record.archetype and record.archetype.namespace or nil,
        bucket = record.bucket,
        entityId = record.entityId,
        entityType = record.entityType,
        generation = record.generation,
        model = record.model,
        netId = record.netId,
        networkOwner = record.networkOwner,
        owner = record.owner,
        persistent = record.persistent == true,
        resourceOwner = record.resourceOwner,
        status = record.status,
    }
end

function SynexEntityControlProviderSupport.recoveryTimeline(rows)
    local items = {}
    for index, row in ipairs(rows) do
        local entityId = row.entityId or row.entity_id
        local outcome = row.outcome
        items[index] = {
            id = tostring(row.recoveryId or row.recovery_id),
            timestamp = row.timestamp or row.occurredAt or row.occurred_at,
            status = outcome,
            label = 'Recovery - ' .. tostring(outcome),
            detail = 'Entity recovery lifecycle event',
            entityId = entityId,
            attempt = tonumber(row.attempt or row.attempt_number),
            failureCode = row.failureCode or row.failure_code,
        }
    end
    return items
end

function SynexEntityControlProviderSupport.recoveryInspector(value, entityId, limit)
    local persisted = value.persistence or {}
    local state = persisted.recovery or {}
    local historyItems = SynexEntityControlProviderSupport.recoveryTimeline(value.recovery or {})
    local historySaturated = #historyItems >= limit
    return {
        entity = {
            entityId = persisted.entityId or entityId,
            generation = persisted.generation,
            recoveryPolicy = persisted.recoveryPolicy,
            status = persisted.status,
        },
        attempts = tonumber(state.attempts) or 0,
        circuit = type(state.circuit) == 'string'
            and string.upper(state.circuit) or 'UNKNOWN',
        lastFailure = state.failureCode,
        nextRetry = state.nextRetryAt,
        recoveryWindowStartedAt = state.windowStartedAt,
        history = {
            items = historyItems,
            limit = limit,
            hasMore = historySaturated,
            truncated = historySaturated,
        },
    }
end

function SynexEntityControlProviderSupport.boundaryHandlers(handlers)
    local boundary = {}
    for operation, handler in pairs(handlers) do
        boundary[operation] = function(...)
            local value, operationError = handler(...)
            if value == nil and operationError ~= nil then return false, operationError end
            return value, operationError
        end
    end
    return boundary
end

SynexEntityControlProviderSupport.operations = OPERATIONS
SynexEntityControlProviderSupport.views = VIEWS
