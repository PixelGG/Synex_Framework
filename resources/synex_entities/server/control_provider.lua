SynexEntityControlProvider = {}
local support = assert(SynexEntityControlProviderSupport,
    'entity control provider support must be loaded first')
local inspectProvider = assert(SynexEntityControlProviderInspect,
    'entity control provider inspect module must be loaded first')
local OPERATIONS, VIEWS = support.operations, support.views

function SynexEntityControlProvider.create(options)
    assert(type(options) == 'table', 'entity control provider options are required')
    local foundation = assert(options.foundation, 'entity control provider foundation is required')
    local service = assert(options.service, 'entity control provider service is required')
    local queryOperations = assert(options.queryOperations, 'entity control provider query operations are required')
    local authorityRepository = assert(options.authorityRepository, 'entity control provider authority repository is required')
    local database = assert(options.database, 'entity control provider database is required')
    local state = assert(options.state, 'entity control provider state is required')
    local registry = assert(options.registry, 'entity control provider registry is required')
    local config = assert(options.config, 'entity control provider config is required')
    local bucketPolicy = assert(options.bucketPolicy, 'entity control provider bucket policy is required')
    local spawnAdmission = assert(options.spawnAdmission, 'entity control provider admission is required')
    local coreRef = assert(options.coreRef, 'entity control provider Core reference is required')

    local function failure(code, message, retryable, context)
        return foundation.failure(code, message, retryable == true, context)
    end

    local function validateRequest(request, allowed, required, context)
        if type(request) ~= 'table' then
            return failure('INVALID_ARGUMENT', 'The entity control request must be an object', false, context)
        end
        for key in pairs(request) do
            if type(key) ~= 'string' or not allowed[key] then
                return failure('INVALID_ARGUMENT',
                    'The entity control request contains an unknown field', false, context)
            end
        end
        for _, key in ipairs(required or {}) do
            if request[key] == nil then
                return failure('INVALID_ARGUMENT',
                    'The entity control request is missing a required field', false, context)
            end
        end
        return request
    end

    local function validId(value)
        return type(value) == 'string' and #value >= 1 and #value <= 64
            and value:match('^[A-Za-z0-9][A-Za-z0-9_.:%-]*$') ~= nil
    end

    local function validCursor(value, maximum)
        return value == nil or type(value) == 'string' and #value >= 1
            and #value <= (maximum or 192)
            and value:match('^[A-Za-z0-9][A-Za-z0-9_.:%-]*$') ~= nil
    end

    local function validResource(value)
        return type(value) == 'string' and #value >= 2 and #value <= 64
            and value:match('^[A-Za-z0-9][A-Za-z0-9_.:%-]*$') ~= nil
    end

    local function validLimit(value, maximum)
        return value == nil or type(value) == 'number' and value % 1 == 0
            and value >= 1 and value <= maximum
    end

    local function exactKeys(candidate, keys)
        local allowed = {}
        for _, key in ipairs(keys) do allowed[key] = true end
        for key in pairs(candidate) do if not allowed[key] then return false end end
        return true
    end

    local function emptyObject(value)
        return value == nil or type(value) == 'table' and next(value) == nil
    end

    local function nested(value, allowed, required, context)
        return validateRequest(value or {}, allowed, required or {}, context)
    end

    local function contextFor(context)
        local api = coreRef.value
        if type(api) ~= 'table' or type(api.ownerEpoch) ~= 'number'
            or api.ownerEpoch % 1 ~= 0 or api.ownerEpoch < 1 then
            return nil, { code = 'UNAVAILABLE',
                message = 'The Entities Core owner epoch is unavailable', retryable = true }
        end
        return {
            caller = 'synex_entities', callerEpoch = api.ownerEpoch,
            traceId = type(context) == 'table' and context.traceId or 'control_unavailable',
            deadlineAt = type(context) == 'table' and context.deadlineAt or nil,
        }
    end

    local function protected(operation, context, handler)
        local packed = table.pack(pcall(handler))
        if packed[1] then
            if packed[2] == nil then return nil, packed[3] end
            return support.annotateNetworkOwner(packed[2]), packed[3]
        end
        foundation.reportUnexpected('control.' .. operation, packed[2], context)
        return failure('UNAVAILABLE', 'The entity control read is unavailable', true, context)
    end

    local function listDefinitions(request, context)
        local limit = request.limit or 20
        local query = {
            afterEntityId = request.cursor,
            limit = limit + 1,
            persistent = request.persistent,
            status = request.status,
            entityTypes = request.entity_type and { request.entity_type } or nil,
        }
        local page, readError = authorityRepository.queryDefinitions(query, context)
        if not page then return nil, readError end
        local truncated = #page.items > limit
        if truncated then page.items[#page.items] = nil end
        local items = {}
        for index, definition in ipairs(page.items) do
            items[index] = {
                archetype = definition.archetype and definition.archetype.namespace or nil,
                bucket = definition.bucket,
                entityId = definition.entityId,
                entityType = definition.entityType,
                generation = definition.generation,
                model = definition.model,
                owner = definition.owner,
                persistent = definition.persistent,
                resourceOwner = definition.resourceOwner,
                serverScope = definition.serverScope,
                status = definition.status,
                version = definition.version,
            }
        end
        return {
            items = items,
            nextCursor = truncated and items[#items] and items[#items].entityId or nil,
            hasMore = truncated, truncated = truncated,
        }
    end

    local function listBuckets(request)
        local limit, cursor = request.limit or 20, request.cursor and tonumber(request.cursor) or nil
        if request.cursor ~= nil and (cursor == nil or cursor % 1 ~= 0 or cursor < 0) then
            return nil, { code = 'INVALID_ARGUMENT', message = 'The bucket cursor is invalid', retryable = false }
        end
        local buckets = state.bucketIndex.page(cursor, limit + 1)
        local items = {}
        for index = 1, math.min(#buckets, limit) do
            items[index] = bucketPolicy.snapshot(buckets[index])
        end
        local truncated = #buckets > limit
        return {
            items = items,
            nextCursor = truncated and tostring(buckets[limit].id) or nil,
            hasMore = truncated, truncated = truncated,
        }
    end

    local function queryPage(statement, parameters, limit, cursorField)
        local rows = database.query(statement, parameters, {
            maximumRows = limit + 1, maximumResultBytes = 32768, timeoutMs = 5000,
        })
        local truncated = #rows > limit
        if truncated then rows[#rows] = nil end
        return {
            items = rows,
            nextCursor = truncated and rows[#rows] and tostring(rows[#rows][cursorField]) or nil,
            hasMore = truncated, truncated = truncated,
        }
    end

    local function normalizePage(value, readError)
        if not value then return nil, readError end
        value.nextCursor = value.nextCursor or value.next_cursor
        value.next_cursor = nil
        value.hasMore = value.truncated == true or value.nextCursor ~= nil
        value.truncated = value.hasMore
        return value
    end

    local function diagnosticFindings(value, limit)
        local categories = {
            'bucketLeaks', 'bucketOwnerConflicts', 'componentSchemaMismatches',
            'duplicateBindings', 'duplicatePersistentKeys', 'generationMismatches',
            'invalidOwners', 'leaseConflicts', 'netIdMismatches', 'orphaned',
            'recovery', 'recommendations', 'resourceLeaks', 'runtimeOrphans',
            'staleBindings', 'staleMappings', 'stateSchemaMismatches',
        }
        local items, overflow = {}, false
        for _, category in ipairs(categories) do
            local findings = value[category]
            if type(findings) == 'table' and #findings > 0 then
                if #items >= limit then
                    overflow = true
                else
                    local first = findings[1]
                    local code = type(first) == 'table' and first.code
                        or string.upper(category)
                    local subject = type(first) == 'table' and (first.entityId
                        or first.resource or first.namespace or first.bucket) or nil
                    items[#items + 1] = {
                        code = code or string.upper(category),
                        severity = category == 'recommendations' and 'INFO' or 'WARNING',
                        title = category,
                        summary = ('%d sampled finding(s)'):format(#findings),
                        subjectRef = subject,
                    }
                end
            end
        end
        return {
            items = items,
            nextCursor = value.nextCursor,
            hasMore = value.nextCursor ~= nil,
            truncated = value.truncated == true or overflow,
            status = value.status,
        }
    end

    local function listRuntime(request)
        local limit = request.limit or 20
        local records, pageError = registry.page(request.cursor, limit + 1)
        if not records then return nil, pageError end
        local items = {}
        for index, record in ipairs(records) do
            items[index] = support.runtimeView(record)
        end
        local truncated = #items > limit
        if truncated then items[#items] = nil end
        return {
            items = items,
            nextCursor = truncated and items[#items] and items[#items].entityId or nil,
            hasMore = truncated, truncated = truncated,
        }
    end

    local function inspectEntity(entityId, limit, context)
        local value, readError = service.inspectEntity({
            entityId = entityId, recoveryLimit = limit,
        }, context)
        if not value then return nil, readError end
        local archetype = value.persistence and value.persistence.archetype
        if archetype then
            value.persistence.archetype = {
                namespace = archetype.namespace, schemaVersion = archetype.schemaVersion,
            }
        end
        return value
    end

    local handlers = {}
    handlers.summary = function(request, context)
        local candidate, requestError = validateRequest(request,
            { view = true, limit = true }, { 'view' }, context)
        if not candidate then return nil, requestError end
        if candidate.view ~= 'overview' and candidate.view ~= 'cluster_authority'
            and candidate.view ~= 'quotas' or not validLimit(candidate.limit, 25) then
            return failure('INVALID_ARGUMENT', 'The entity summary view is invalid', false, context)
        end
        local internalContext, contextError = contextFor(context)
        if not internalContext then return nil, contextError end
        if candidate.view == 'cluster_authority' then
            return protected('cluster_authority', internalContext, function()
                local snapshot = service.healthSnapshot()
                return { authority = snapshot.authority, state = snapshot.state,
                    persistence = snapshot.persistence, reason = snapshot.reason }
            end)
        end
        if candidate.view == 'quotas' then
            return protected('quotas', internalContext, function()
                return spawnAdmission.quotaSnapshot(candidate.limit or 25), nil
            end)
        end
        return protected('summary', internalContext,
            function()
                local summary, summaryError = service.getControlSummary({}, internalContext)
                if not summary then return nil, summaryError end
                summary.status = summary.health.status
                return summary, nil
            end)
    end
    handlers.health = function(request, context)
        local candidate, requestError = validateRequest(request,
            { view = true, limit = true }, { 'view' }, context)
        if not candidate then return nil, requestError end
        if candidate.view ~= 'health' or not validLimit(candidate.limit, 25) then
            return failure('INVALID_ARGUMENT', 'The entity health view is invalid', false, context)
        end
        return protected('health', context, service.healthSnapshot)
    end
    handlers.list = function(request, context)
        local candidate, requestError = validateRequest(request, {
            view = true, cursor = true, limit = true, filters = true, sort = true,
        }, { 'view' }, context)
        if not candidate then return nil, requestError end
        local filters, filterError = nested(candidate.filters, {
            status = true, persistent = true, entity_type = true,
            owner_type = true, owner_id = true, resource = true,
            bucket = true, generation = true, namespace = true, outcome = true,
        }, {}, context)
        if not filters then return nil, filterError end
        if not validLimit(candidate.limit, 25)
            or not validCursor(candidate.cursor, 256)
            or not emptyObject(candidate.sort)
            or filters.persistent ~= nil and type(filters.persistent) ~= 'boolean'
            or filters.entity_type ~= nil and filters.entity_type ~= 'object'
                and filters.entity_type ~= 'ped' and filters.entity_type ~= 'vehicle' then
            return failure('VALIDATION_FAILED', 'The entity list bounds are invalid', false, context)
        end
        local internalContext, contextError = contextFor(context)
        if not internalContext then return nil, contextError end
        if candidate.view == 'entities' or candidate.view == 'persistent' then
            if not exactKeys(filters, { 'status', 'persistent', 'entity_type' }) then
                return failure('VALIDATION_FAILED',
                    'The entity definition list contains irrelevant fields', false, context)
            end
            if candidate.view == 'persistent' and filters.persistent == false then
                return failure('VALIDATION_FAILED',
                    'The persistent entity view cannot request temporary entities', false, context)
            end
            return protected('list_entities', internalContext, function()
                return listDefinitions({ cursor = candidate.cursor, limit = candidate.limit,
                    status = filters.status,
                    persistent = candidate.view == 'persistent' and true or filters.persistent,
                    entity_type = filters.entity_type }, internalContext)
            end)
        end
        if candidate.view == 'runtime' then
            if not emptyObject(filters) then
                return failure('VALIDATION_FAILED',
                    'The runtime list contains irrelevant fields', false, context)
            end
            return protected('list_runtime', internalContext,
                function() return listRuntime(candidate) end)
        end
        if candidate.view == 'buckets' then
            if not emptyObject(filters) then
                return failure('VALIDATION_FAILED',
                    'The bucket list contains irrelevant fields', false, context)
            end
            return protected('list_buckets', internalContext, function()
                return listBuckets(candidate)
            end)
        end
        local limit = candidate.limit or 20
        if candidate.view == 'bindings' then
            local cursor = candidate.cursor and tonumber(candidate.cursor) or 0
            if not exactKeys(filters, { 'namespace', 'resource' })
                or cursor == nil or cursor % 1 ~= 0 or cursor < 0
                or filters.namespace ~= nil and not validCursor(filters.namespace, 128)
                or filters.resource ~= nil and not validResource(filters.resource) then
                return failure('VALIDATION_FAILED', 'The binding list is invalid', false, context)
            end
            local clauses, parameters = { '`released_at` IS NULL', '`binding_id` > ?' }, { cursor }
            if filters.namespace then
                clauses[#clauses + 1] = '`binding_namespace` = ?'
                parameters[#parameters + 1] = filters.namespace
            end
            if filters.resource then
                clauses[#clauses + 1] = '`owner_resource` = ?'
                parameters[#parameters + 1] = filters.resource
            end
            parameters[#parameters + 1] = limit + 1
            return protected('list_bindings', internalContext, function()
                return queryPage([[SELECT `binding_id` AS `bindingId`, `entity_id` AS `entityId`,
                        `binding_namespace` AS `namespace`, `binding_ref` AS `reference`,
                        `owner_resource` AS `ownerResource`, `version`, `created_at` AS `createdAt`
                    FROM `synex_entity_bindings` WHERE ]] .. table.concat(clauses, ' AND ')
                    .. ' ORDER BY `binding_id` ASC LIMIT ?', parameters, limit, 'bindingId')
            end)
        end
        if candidate.view == 'owners' then
            if not exactKeys(filters, { 'owner_type' })
                or filters.owner_type ~= nil and not validResource(filters.owner_type) then
                return failure('VALIDATION_FAILED', 'The logical-owner list is invalid', false, context)
            end
            local cursor = candidate.cursor or ''
            local parameters = { cursor }
            local constraint = ''
            if filters.owner_type then
                constraint = ' AND `owner_type` = ?'
                parameters[#parameters + 1] = filters.owner_type
            end
            parameters[#parameters + 1] = limit + 1
            return protected('list_owners', internalContext, function()
                return queryPage([[SELECT CONCAT(`owner_type`, ':', `owner_id`) AS `cursorKey`,
                        `owner_type` AS `ownerType`, `owner_id` AS `ownerId`, COUNT(*) AS `entities`,
                        SUM(`status` IN ('active','spawning','recovering')) AS `materialized`
                    FROM `synex_entities` WHERE `deleted_at` IS NULL
                        AND CONCAT(`owner_type`, ':', `owner_id`) > ?]] .. constraint
                    .. [[ GROUP BY `owner_type`, `owner_id`
                        ORDER BY `cursorKey` ASC LIMIT ?]], parameters, limit, 'cursorKey')
            end)
        end
        if candidate.view == 'resources' then
            if not emptyObject(filters) then
                return failure('VALIDATION_FAILED', 'The resource-owner list is invalid', false, context)
            end
            return protected('list_resources', internalContext, function()
                return queryPage([[SELECT `resource_owner` AS `resourceOwner`, COUNT(*) AS `entities`,
                        SUM(`status` IN ('active','spawning','recovering')) AS `materialized`
                    FROM `synex_entities` WHERE `deleted_at` IS NULL AND `resource_owner` > ?
                    GROUP BY `resource_owner` ORDER BY `resource_owner` ASC LIMIT ?]], {
                    candidate.cursor or '', limit + 1,
                }, limit, 'resourceOwner')
            end)
        end
        if candidate.view == 'components' then
            if not exactKeys(filters, { 'namespace', 'resource' })
                or filters.namespace ~= nil and not validCursor(filters.namespace, 128)
                or filters.resource ~= nil and not validResource(filters.resource) then
                return failure('VALIDATION_FAILED', 'The component list is invalid', false, context)
            end
            local cursor = candidate.cursor or ''
            local clauses, parameters = {
                "SHA2(CONCAT(`entity_id`, CHAR(31), `component_namespace`), 256) > ?",
            }, { cursor }
            if filters.namespace then
                clauses[#clauses + 1] = '`component_namespace` = ?'
                parameters[#parameters + 1] = filters.namespace
            end
            if filters.resource then
                clauses[#clauses + 1] = '`owner_resource` = ?'
                parameters[#parameters + 1] = filters.resource
            end
            parameters[#parameters + 1] = limit + 1
            return protected('list_components', internalContext, function()
                return queryPage([[SELECT SHA2(CONCAT(`entity_id`, CHAR(31), `component_namespace`), 256)
                        AS `cursorKey`, `entity_id` AS `entityId`,
                        `component_namespace` AS `namespace`, `owner_resource` AS `ownerResource`,
                        `schema_version` AS `schemaVersion`, `persistence_mode` AS `persistenceMode`,
                        `version`, `updated_at` AS `updatedAt`
                    FROM `synex_entity_components` WHERE ]] .. table.concat(clauses, ' AND ')
                    .. ' ORDER BY `cursorKey` ASC LIMIT ?', parameters, limit, 'cursorKey')
            end)
        end
        if candidate.view == 'state' then
            if not exactKeys(filters, { 'resource' })
                or filters.resource ~= nil and not validResource(filters.resource) then
                return failure('VALIDATION_FAILED', 'The state list is invalid', false, context)
            end
            local cursor = candidate.cursor or ''
            local clauses, parameters = {
                "SHA2(CONCAT(`entity_id`, CHAR(31), `state_key`), 256) > ?",
            }, { cursor }
            if filters.resource then
                clauses[#clauses + 1] = '`owner_resource` = ?'
                parameters[#parameters + 1] = filters.resource
            end
            parameters[#parameters + 1] = limit + 1
            return protected('list_state', internalContext, function()
                return queryPage([[SELECT SHA2(CONCAT(`entity_id`, CHAR(31), `state_key`), 256)
                        AS `cursorKey`, `entity_id` AS `entityId`, `state_key` AS `key`,
                        `owner_resource` AS `ownerResource`, `schema_version` AS `schemaVersion`,
                        `authority_mode` AS `authorityMode`, `replication_mode` AS `replicationMode`,
                        `version`, `updated_at` AS `updatedAt`
                    FROM `synex_entity_states` WHERE ]] .. table.concat(clauses, ' AND ')
                    .. ' ORDER BY `cursorKey` ASC LIMIT ?', parameters, limit, 'cursorKey')
            end)
        end
        if candidate.view == 'recovery_log' then
            local cursor = candidate.cursor and tonumber(candidate.cursor) or 0
            local outcomes = {
                scheduled = true, started = true, recovered = true, failed = true,
                paused = true, cancelled = true,
            }
            if not exactKeys(filters, { 'outcome' }) or cursor == nil or cursor % 1 ~= 0
                or cursor < 0 or filters.outcome ~= nil and not outcomes[filters.outcome] then
                return failure('VALIDATION_FAILED', 'The recovery list is invalid', false, context)
            end
            local parameters, constraint = { cursor }, ''
            if filters.outcome then
                constraint = ' AND `outcome` = ?'
                parameters[#parameters + 1] = filters.outcome
            end
            parameters[#parameters + 1] = limit + 1
            return protected('list_recovery', internalContext, function()
                return queryPage([[SELECT `recovery_id` AS `recoveryId`, `entity_id` AS `entityId`,
                        `entity_generation` AS `entityGeneration`, `lease_generation` AS `leaseGeneration`,
                        `attempt_number` AS `attempt`, `outcome`, `instance_id` AS `instanceId`,
                        `failure_code` AS `failureCode`, `next_retry_at` AS `nextRetryAt`,
                        `duration_ms` AS `durationMs`,
                        DATE_FORMAT(`occurred_at`, '%Y-%m-%dT%H:%i:%s.%fZ') AS `timestamp`,
                        `outcome` AS `status`, `outcome` AS `label`,
                        'Entity recovery lifecycle event' AS `detail`
                    FROM `synex_entity_recovery_history` WHERE `recovery_id` > ?]] .. constraint
                    .. ' ORDER BY `recovery_id` ASC LIMIT ?', parameters, limit, 'recoveryId')
            end)
        end
        local pageRequest = {
            cursor = candidate.cursor,
            limit = candidate.limit or 20,
        }
        if candidate.view == 'bucket_entities'
            and exactKeys(filters, { 'bucket', 'generation' })
            and type(filters.bucket) == 'number' and filters.bucket % 1 == 0
            and filters.bucket >= 0 and filters.bucket <= 2147483647
            and type(filters.generation) == 'number' and filters.generation % 1 == 0
            and filters.generation >= 0 then
            pageRequest.bucket = { bucket = filters.bucket, generation = filters.generation }
            return protected('list_bucket_entities', internalContext, function()
                return normalizePage(service.queryByBucket(pageRequest, internalContext))
            end)
        end
        return failure('VALIDATION_FAILED', 'The entity list view is invalid', false, context)
    end

    handlers.inspect = inspectProvider.create({
        validateRequest = validateRequest, nested = nested,
        validId = validId, validCursor = validCursor, validLimit = validLimit,
        emptyObject = emptyObject, exactKeys = exactKeys,
        contextFor = contextFor, protected = protected, failure = failure,
        inspectEntity = inspectEntity, queryOperations = queryOperations,
        database = database, support = support,
    })

    handlers.search = function(request, context)
        local candidate, requestError = validateRequest(request, {
            query = true, cursor = true, limit = true, filters = true, sort = true,
        }, { 'query' }, context)
        if not candidate then return nil, requestError end
        local query, queryError = nested(candidate.query,
            { kind = true, value = true, mode = true, generation = true },
            { 'kind', 'value', 'mode' }, context)
        if not query then return nil, queryError end
        if query.kind ~= 'entity' or query.mode ~= 'exact' or not validId(query.value)
            or query.generation ~= nil and (type(query.generation) ~= 'number'
                or query.generation % 1 ~= 0 or query.generation < 1)
            or candidate.cursor ~= nil or not validLimit(candidate.limit, 25)
            or not emptyObject(candidate.filters) or not emptyObject(candidate.sort) then
            return failure('VALIDATION_FAILED',
                'Entity search supports exact entity identifiers only; prefix mode is unsupported', false, context)
        end
        local internalContext, contextError = contextFor(context)
        if not internalContext then return nil, contextError end
        local value, searchError = protected('search', internalContext, function()
            return inspectEntity(query.value, 5, internalContext)
        end)
        if not value then return nil, searchError end
        local generation = value.definition and value.definition.generation
            or value.persistence and value.persistence.generation
        if query.generation ~= nil and generation ~= query.generation then
            return failure('STALE_ENTITY', 'The requested entity generation is stale', false, context)
        end
        return { items = {{ kind = 'entity', entityId = query.value,
                generation = generation, result = value }}, hasMore = false, truncated = false,
            networkOwnerPolicy = value.networkOwnerPolicy }, nil
    end

    handlers.metrics = function(request, context)
        local candidate, requestError = validateRequest(request,
            { view = true, limit = true, filters = true }, { 'view' }, context)
        if not candidate then return nil, requestError end
        if candidate.view ~= 'metrics' or not validLimit(candidate.limit, 25)
            or not emptyObject(candidate.filters) then
            return failure('INVALID_ARGUMENT', 'The entity metrics view is invalid', false, context)
        end
        local internalContext, contextError = contextFor(context)
        if not internalContext then return nil, contextError end
        return protected('metrics', internalContext, function()
            local summary, summaryError = service.getControlSummary({}, internalContext)
            if not summary then return nil, summaryError end
            return { metrics = summary.metrics, runtime = summary.runtime,
                buckets = summary.buckets, persistent = summary.persistent }
        end)
    end

    handlers.findings = function(request, context)
        local candidate, requestError = validateRequest(request, {
            view = true, cursor = true, limit = true, filters = true, sort = true,
        }, { 'view' }, context)
        if not candidate then return nil, requestError end
        local filters, filterError = nested(candidate.filters,
            { recovery_attempt_threshold = true }, {}, context)
        if not filters then return nil, filterError end
        if candidate.view ~= 'findings' and candidate.view ~= 'drift'
            or not validLimit(candidate.limit, 25)
            or candidate.cursor ~= nil and not validId(candidate.cursor)
            or not emptyObject(candidate.sort)
            or filters.recovery_attempt_threshold ~= nil
                and (type(filters.recovery_attempt_threshold) ~= 'number'
                    or filters.recovery_attempt_threshold % 1 ~= 0
                    or filters.recovery_attempt_threshold < 1
                    or filters.recovery_attempt_threshold > 1000) then
            return failure('VALIDATION_FAILED', 'The entity findings request is invalid', false, context)
        end
        local internalContext, contextError = contextFor(context)
        if not internalContext then return nil, contextError end
        return protected('findings', internalContext, function()
            local value, readError = service.getDiagnosticSnapshot({
                cursor = candidate.cursor,
                limit = math.min(candidate.limit or 25, 25),
                recoveryAttemptThreshold = filters.recovery_attempt_threshold,
            }, internalContext)
            if not value then return nil, readError end
            return diagnosticFindings(value, candidate.limit or 25)
        end)
    end
    local boundaryHandlers = support.boundaryHandlers(handlers)

    local provider = {}
    function provider.register(api)
        local register = type(api) == 'table' and type(api.ControlProviders) == 'table'
            and api.ControlProviders.register or nil
        if not foundation.isCallable(register) then
            return nil, { code = 'UNAVAILABLE',
                message = 'The Core control-provider registry is unavailable', retryable = true }
        end
        local called, metadata, registrationError = pcall(register, {
            schemaVersion = 1, namespace = 'entities', label = 'Entities',
            category = 'domain', version = '1.0.0', operations = boundaryHandlers,
            views = VIEWS,
        })
        if called and metadata then return metadata, nil end
        return nil, type(registrationError) == 'table' and registrationError
            or { code = 'UNAVAILABLE',
                message = 'The Entities control provider could not be registered', retryable = true }
    end
    provider.operations, provider.views = OPERATIONS, VIEWS
    return provider
end
