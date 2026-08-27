SynexEntityControlProviderInspect = {}

function SynexEntityControlProviderInspect.create(options)
    assert(type(options) == 'table', 'entity control inspect options are required')
    local validateRequest = assert(options.validateRequest,
        'entity control inspect request validator is required')
    local nested = assert(options.nested, 'entity control inspect nested validator is required')
    local validId = assert(options.validId, 'entity control inspect identifier validator is required')
    local validCursor = assert(options.validCursor,
        'entity control inspect cursor validator is required')
    local validLimit = assert(options.validLimit, 'entity control inspect limit validator is required')
    local emptyObject = assert(options.emptyObject,
        'entity control inspect object validator is required')
    local exactKeys = assert(options.exactKeys, 'entity control inspect key validator is required')
    local contextFor = assert(options.contextFor, 'entity control inspect context factory is required')
    local protected = assert(options.protected, 'entity control inspect boundary is required')
    local failure = assert(options.failure, 'entity control inspect failure factory is required')
    local inspectEntity = assert(options.inspectEntity,
        'entity control inspect entity reader is required')
    local queryOperations = assert(options.queryOperations,
        'entity control inspect query operations are required')
    local database = assert(options.database, 'entity control inspect database is required')
    local support = assert(options.support, 'entity control inspect support is required')

    return function(request, context)
        local candidate, requestError = validateRequest(request, {
            view = true, id = true, cursor = true, limit = true,
            filters = true, sort = true,
        }, { 'view', 'id' }, context)
        if not candidate then return nil, requestError end
        local filters, filterError = nested(candidate.filters,
            { generation = true, namespace = true }, {}, context)
        if not filters then return nil, filterError end
        if candidate.cursor ~= nil and not validId(candidate.cursor)
            or not validLimit(candidate.limit, 25) or not emptyObject(candidate.sort) then
            return failure('VALIDATION_FAILED', 'The entity inspection bounds are invalid', false, context)
        end
        local internalContext, contextError = contextFor(context)
        if not internalContext then return nil, contextError end
        if candidate.view == 'entity'
            and emptyObject(filters) and candidate.cursor == nil
            and validId(candidate.id) then
            return protected('inspect_entity', internalContext, function()
                return inspectEntity(candidate.id, math.min(candidate.limit or 10, 25), internalContext)
            end)
        end
        if candidate.view == 'character_relations' and validId(candidate.id)
            and emptyObject(filters) and candidate.cursor == nil
            and validLimit(candidate.limit, 8) then
            return protected('inspect_character_relations', internalContext, function()
                local limit = candidate.limit or 8
                local rows = database.query([[SELECT
                        `entity_id` AS `entityId`,
                        `entity_type` AS `entityType`,
                        `status`,
                        `persistence_policy` AS `persistencePolicy`,
                        CAST(COUNT(*) OVER() AS CHAR) AS `relationCount`
                    FROM `synex_entities`
                    WHERE `deleted_at` IS NULL
                        AND `owner_type` = 'character' AND `owner_id` = ?
                    ORDER BY `entity_id` ASC
                    LIMIT ?]], { candidate.id, limit }, {
                    maximumRows = limit, maximumResultBytes = 16384, timeoutMs = 5000,
                })
                local total = rows[1] and tonumber(rows[1].relationCount) or 0
                local items = {}
                for index, row in ipairs(rows) do
                    items[index] = {
                        entityId = row.entityId,
                        entityType = row.entityType,
                        status = row.status,
                        persistencePolicy = row.persistencePolicy,
                    }
                end
                local truncated = total > #items
                return {
                    view = 'character_relations',
                    characterId = candidate.id,
                    count = total,
                    items = items,
                    limit = limit,
                    hasMore = truncated,
                    truncated = truncated,
                    componentPayloadsExposed = false,
                    stateValuesExposed = false,
                }
            end)
        end
        if candidate.view == 'binding' and validId(candidate.id)
            and emptyObject(filters) and candidate.cursor == nil then
            return protected('inspect_binding', internalContext, function()
                local value, readError = inspectEntity(candidate.id, 1, internalContext)
                if not value then return nil, readError end
                if not value.binding then
                    return nil, { code = 'NOT_FOUND',
                        message = 'The entity has no active binding', retryable = false }
                end
                return { binding = value.binding, definition = value.definition }
            end)
        end
        local bucketId = tonumber(candidate.id)
        if candidate.view == 'bucket' and candidate.cursor == nil
            and exactKeys(filters, { 'generation' })
            and bucketId ~= nil and bucketId % 1 == 0 and bucketId >= 0
            and type(filters.generation) == 'number' and filters.generation % 1 == 0
            and filters.generation >= 0 then
            return protected('inspect_bucket', internalContext, function()
                return queryOperations.bucketGet({
                    bucket = { bucket = bucketId, generation = filters.generation },
                }, internalContext)
            end)
        end
        if candidate.view == 'recovery' and validId(candidate.id)
            and emptyObject(filters)
            and candidate.cursor == nil
            and validLimit(candidate.limit, 25) then
            return protected('inspect_recovery', internalContext, function()
                local limit = candidate.limit or 10
                local value, readError = inspectEntity(candidate.id, limit, internalContext)
                if not value then return nil, readError end
                return support.recoveryInspector(value, candidate.id, limit)
            end)
        end
        if candidate.view == 'component' and validId(candidate.id)
            and candidate.cursor == nil and exactKeys(filters, { 'namespace' })
            and validCursor(filters.namespace, 128) then
            return protected('inspect_component', internalContext, function()
                local rows = database.query([[SELECT `entity_id` AS `entityId`,
                        `component_namespace` AS `namespace`, `owner_resource` AS `ownerResource`,
                        `schema_version` AS `schemaVersion`, `persistence_mode` AS `persistenceMode`,
                        `version`, `created_at` AS `createdAt`, `updated_at` AS `updatedAt`
                    FROM `synex_entity_components`
                    WHERE `entity_id` = ? AND `component_namespace` = ? LIMIT 1]], {
                    candidate.id, filters.namespace,
                }, { maximumRows = 1, maximumResultBytes = 8192, timeoutMs = 5000 })
                if not rows[1] then
                    return nil, { code = 'NOT_FOUND',
                        message = 'The entity component does not exist', retryable = false }
                end
                return rows[1]
            end)
        end
        return failure('VALIDATION_FAILED', 'The entity inspection request is invalid', false, context)
    end
end
