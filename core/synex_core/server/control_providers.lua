local factories = assert(SynexCoreFactories, 'factories must be loaded first')

factories.controlProviders = function(deps)
    local platform = assert(deps.platform, 'control providers require platform')
    local foundation = assert(deps.foundation, 'control providers require foundation')
    local owners = assert(deps.owners, 'control providers require owner registry')
    local coreResource = assert(deps.coreResource, 'control providers require core resource')
    local manifestFor = assert(deps.manifestFor, 'control providers require manifest lookup')
    local metrics = foundation.metrics

    local allowedOperations = {
        summary = true,
        health = true,
        list = true,
        inspect = true,
        search = true,
        metrics = true,
        findings = true,
        simulate = true
    }
    local allowedPresentations = {
        metrics = true,
        ['key-value'] = true,
        ['table'] = true,
        detail = true,
        timeline = true,
        graph = true,
        findings = true
    }
    local accessClasses = {
        general = true,
        audit = true,
        security = true,
        financial = true,
        identifiers = true
    }
    local providers = {}
    local declarations = {}
    local declarationNamespaces = {}
    local providerCounts = {}
    local providerCount = 0
    local maximumProviders = 64
    local maximumProvidersPerOwner = 8
    local maximumViews = 32
    local maximumTableRows = 100
    local maximumTableColumns = 12
    local maximumRequestBytes = 4096
    local maximumResponseBytes = 32768
    local defaultTimeoutMs = 500
    local minimumTimeoutMs = 25
    local maximumTimeoutMs = 2000
    local circuitFailureThreshold = 3
    local circuitOpenMs = 5000
    local severities = {
        HEALTHY = true,
        INFO = true,
        WARNING = true,
        DEGRADED = true,
        ERROR = true,
        CRITICAL = true,
        UNAVAILABLE = true
    }
    local severityRanks = {
        HEALTHY = 1,
        INFO = 2,
        WARNING = 3,
        DEGRADED = 4,
        ERROR = 5,
        CRITICAL = 6,
        UNAVAILABLE = 7
    }
    local severityAliases = {
        ACTIVE = 'HEALTHY',
        AVAILABLE = 'HEALTHY',
        PASS = 'HEALTHY',
        READY = 'HEALTHY',
        STARTING = 'INFO',
        WARN = 'WARNING',
        PARTIAL = 'DEGRADED',
        FAIL = 'ERROR',
        FAILED = 'ERROR',
        UNHEALTHY = 'ERROR',
        STOPPING = 'UNAVAILABLE'
    }

    local function reportedSeverity(value)
        if type(value) ~= 'table' then return nil end
        local reported = rawget(value, 'status')
        if reported == nil and type(rawget(value, 'health')) == 'table' then
            reported = rawget(value.health, 'status') or rawget(value.health, 'state')
        end
        if type(reported) ~= 'string' then return nil end
        reported = reported:upper()
        if severities[reported] then return reported end
        return severityAliases[reported]
    end
    local expectedFailureCodes = {
        INVALID_ARGUMENT = 'INVALID_ARGUMENT',
        INVALID_CURSOR = 'INVALID_CURSOR',
        INVALID_LIMIT = 'INVALID_LIMIT',
        INVALID_CONTROL_PROVIDER_REQUEST = 'INVALID_ARGUMENT',
        NOT_EXPOSED = 'NOT_EXPOSED',
        NOT_FOUND = 'NOT_FOUND',
        STALE_ENTITY = 'STALE_ENTITY',
        VALIDATION_FAILED = 'INVALID_ARGUMENT',
        VIEW_UNAVAILABLE = 'VIEW_UNAVAILABLE'
    }

    local function expectedFailureCode(cause)
        local mapped = expectedFailureCodes[cause]
        if mapped then return mapped end
        if type(cause) ~= 'string' then return nil end
        if cause:match('_NOT_FOUND$') then return 'NOT_FOUND' end
        if cause:match('^STALE_') and cause ~= 'STALE_RESOURCE' then return 'STALE_ENTITY' end
        if cause == 'FORBIDDEN' or cause == 'ACCESS_DENIED'
            or cause == 'PERMISSION_DENIED' or cause == 'INSUFFICIENT_PERMISSION'
            or cause:match('_ACCESS_DENIED$') or cause:match('_FORBIDDEN$') then
            return 'NOT_EXPOSED'
        end
        return nil
    end

    local function worseSeverity(left, right)
        left = severities[left] and left or 'INFO'
        right = severities[right] and right or 'INFO'
        return severityRanks[left] >= severityRanks[right] and left or right
    end

    local function validIdentifier(value, maximum)
        return type(value) == 'string' and #value >= 2 and #value <= maximum
            and value:match('^[a-z][a-z0-9_%-]*$') ~= nil
            and value:sub(-1) ~= '_' and value:sub(-1) ~= '-'
            and not value:find('__', 1, true) and not value:find('--', 1, true)
            and not value:find('_-', 1, true) and not value:find('-_', 1, true)
    end

    local function validText(value, maximum)
        return type(value) == 'string' and #value >= 1 and #value <= maximum
            and not value:find('[%z\1-\31\127]')
    end

    local function exactObject(value, allowed)
        if type(value) ~= 'table' or getmetatable(value) ~= nil then return false end
        for key in pairs(value) do
            if type(key) ~= 'string' or not allowed[key] then return false end
        end
        return true
    end

    local function validateJson(value, limits, state, depth)
        state = state or { seen = {}, entries = 0 }
        depth = (depth or 0) + 1
        local valueType = type(value)
        if valueType == 'nil' or valueType == 'boolean' then return true end
        if valueType == 'number' then
            return value == value and value ~= math.huge and value ~= -math.huge
        end
        if valueType == 'string' then return #value <= limits.maximumStringBytes end
        if valueType ~= 'table' or depth > limits.maximumDepth
            or not foundation.jsonContainerKind(value) or state.seen[value] then return false end
        state.seen[value] = true
        local count, maximumIndex, keyType = 0, 0, nil
        for key, item in pairs(value) do
            count = count + 1
            state.entries = state.entries + 1
            if state.entries > limits.maximumEntries then
                state.seen[value] = nil
                return false
            end
            local currentType = type(key)
            if currentType == 'number' then
                if math.type(key) ~= 'integer' or key < 1 then
                    state.seen[value] = nil
                    return false
                end
                maximumIndex = math.max(maximumIndex, key)
            elseif currentType ~= 'string' or #key < 1 or #key > limits.maximumKeyBytes
                or key:find('[%z\1-\31\127]') then
                state.seen[value] = nil
                return false
            end
            if keyType ~= nil and keyType ~= currentType then
                state.seen[value] = nil
                return false
            end
            keyType = currentType
            if not validateJson(item, limits, state, depth) then
                state.seen[value] = nil
                return false
            end
        end
        state.seen[value] = nil
        return keyType ~= 'number' or (maximumIndex == count and count == #value)
    end

    local requestLimits = {
        maximumDepth = 8,
        maximumEntries = 256,
        maximumKeyBytes = 64,
        maximumStringBytes = 4096
    }
    local responseLimits = {
        maximumDepth = 12,
        maximumEntries = 2048,
        maximumKeyBytes = 128,
        maximumStringBytes = maximumResponseBytes
    }

    local function jsonObject(value)
        if type(value) ~= 'table' or foundation.jsonContainerKind(value) == 'array' then
            return false
        end
        for key in pairs(value) do
            if type(key) ~= 'string' then return false end
        end
        return true
    end

    local function boundedDenseArray(value, maximum)
        if type(value) ~= 'table' then return false end
        local count, maximumIndex = 0, 0
        for key in pairs(value) do
            if type(key) ~= 'number' or math.type(key) ~= 'integer' or key < 1 then
                return false
            end
            count = count + 1
            maximumIndex = math.max(maximumIndex, key)
            if count > maximum then return false end
        end
        return count == maximumIndex and count == #value
    end

    local function validOptionalPageMetadata(value)
        return value.cursor == nil
            and (value.nextCursor == nil or type(value.nextCursor) == 'string'
                and #value.nextCursor >= 1 and #value.nextCursor <= 256
                and not value.nextCursor:find('[%z\1-\31\127]'))
            and (value.hasMore == nil or type(value.hasMore) == 'boolean')
            and (value.truncated == nil or type(value.truncated) == 'boolean')
    end

    local function boundedObjectColumns(value, maximum)
        if not jsonObject(value) then return false end
        local count = 0
        for _ in pairs(value) do
            count = count + 1
            if count > maximum then return false end
        end
        return true
    end

    local function boundedRows(value, maximumRows, maximumColumns)
        if not boundedDenseArray(value, maximumRows) then return false end
        for _, row in ipairs(value) do
            local rowType = type(row)
            if rowType == 'table' then
                if not boundedObjectColumns(row, maximumColumns) then return false end
            elseif rowType ~= 'nil' and rowType ~= 'boolean' and rowType ~= 'number'
                and rowType ~= 'string' then return false end
        end
        return true
    end

    local function boundedObjectRows(value, maximumRows, maximumColumns, validateRow)
        if not boundedDenseArray(value, maximumRows) then return false end
        for _, row in ipairs(value) do
            if not boundedObjectColumns(row, maximumColumns)
                or validateRow ~= nil and not validateRow(row) then return false end
        end
        return true
    end

    local function boundedGenericTable(value)
        if not jsonObject(value) then return false end
        local count = 0
        for key in pairs(value) do
            if key ~= 'view' and key ~= 'hasMore' and key ~= 'nextCursor'
                and key ~= 'truncated' and key ~= 'columns' then
                count = count + 1
                if count > maximumTableRows or not validText(key, 96) then return false end
            end
        end
        return true
    end

    local function tableRows(value)
        for _, key in ipairs({
            'items', 'entries', 'rows', 'resources', 'sessions', 'deprecations'
        }) do
            if value[key] ~= nil then return value[key], false end
        end
        if jsonObject(value.snapshot) then return tableRows(value.snapshot) end
        if jsonObject(value.summary) then return value.summary, true end
        if jsonObject(value.cache) then return value.cache, true end
        return value, true
    end

    local function graphNode(row)
        return validText(row.id, 128)
    end

    local function graphEdge(row)
        return validText(row.from, 128) and validText(row.to, 128)
    end

    local function timelineRow(row)
        if row.status == 'UNAVAILABLE' then return true end
        for _, key in ipairs({
            'timestamp', 'time', 'occurredAt', 'occurred_at', 'at', 'label', 'name',
            'action', 'title', 'code', 'from', 'to'
        }) do
            if type(row[key]) == 'string' and #row[key] >= 1 then return true end
        end
        return false
    end

    local function findingRow(row)
        if not severities[row.severity] then return false end
        for _, key in ipairs({ 'title', 'code', 'capability' }) do
            if validText(row[key], 160) then return true end
        end
        return false
    end

    local function validatePresentationResponse(presentation, value)
        if presentation == nil then return true end
        if presentation == 'key-value' or presentation == 'detail' then
            return boundedObjectColumns(value, maximumTableRows) and next(value) ~= nil
        end
        if presentation == 'metrics' then
            if not boundedObjectColumns(value, maximumTableRows) or next(value) == nil then
                return false
            end
            if value.items ~= nil
                and not boundedRows(value.items, maximumTableRows, maximumTableColumns) then
                return false
            end
            return value.metrics == nil or jsonObject(value.metrics)
        end
        if presentation == 'table' then
            if value.columns ~= nil then
                if not boundedDenseArray(value.columns, maximumTableColumns) then return false end
                local observed = {}
                for _, column in ipairs(value.columns) do
                    if not jsonObject(column) or not validText(column.key, 64)
                        or not validText(column.label, 128) or observed[column.key] then return false end
                    observed[column.key] = true
                end
            end
            local rows, generic = tableRows(value)
            return generic and boundedGenericTable(rows)
                or boundedRows(rows, maximumTableRows, maximumTableColumns)
        end
        if presentation == 'graph' then
            return boundedObjectRows(value.nodes, 128, maximumTableColumns, graphNode)
                and boundedObjectRows(value.edges, 256, maximumTableColumns, graphEdge)
        end
        if presentation == 'timeline' then
            for _, key in ipairs({ 'items', 'entries', 'events', 'recentTransitions', 'deprecations' }) do
                if value[key] ~= nil then
                    return boundedObjectRows(value[key], maximumTableRows,
                        maximumTableColumns, timelineRow)
                end
            end
            return value.status == 'UNAVAILABLE'
        end
        if presentation == 'findings' then
            return boundedObjectRows(value.items, maximumTableRows,
                maximumTableColumns, findingRow)
        end
        return false
    end

    local function validateOperationResponse(operation, presentation, value)
        if not jsonObject(value) or not validOptionalPageMetadata(value) then return false end
        if operation == 'list' or operation == 'search' then
            local page = value.items ~= nil and boundedDenseArray(value.items, maximumTableRows)
            local graph = value.nodes ~= nil and value.edges ~= nil
                and boundedDenseArray(value.nodes, 128)
                and boundedDenseArray(value.edges, 256)
            if not page and not graph then return false end
            if value.hasMore == nil then return false end
        elseif operation == 'findings' then
            if not boundedDenseArray(value.items, maximumTableRows)
                or value.hasMore == nil then return false end
        end
        return validatePresentationResponse(presentation, value)
    end

    local inputFormats = {
        identifier = true,
        lookup = true,
        uuid = true,
        resource = true,
        capability = true,
        action = true,
        integer = true,
        ['numeric-string'] = true,
        boolean = true,
        text = true
    }

    local function validateViewInput(input, operation)
        if not exactObject(input, { fields = true }) or type(input.fields) ~= 'table'
            or getmetatable(input.fields) ~= nil then return false end
        local seen, count, maximumIndex, idFields = {}, 0, 0, 0
        local keys = {
            key = true, label = true, source = true, type = true, format = true,
            required = true, minLength = true, maxLength = true,
            minimum = true, maximum = true
        }
        for index, field in pairs(input.fields) do
            count = count + 1
            if count > 8 or type(index) ~= 'number' or math.type(index) ~= 'integer'
                or index < 1 or not exactObject(field, keys)
                or type(field.key) ~= 'string' or #field.key < 1 or #field.key > 48
                or not field.key:match('^[a-z][a-z0-9_]*$') or seen[field.key]
                or not validText(field.label, 64)
                or field.source ~= 'id' and field.source ~= 'filter'
                or field.type ~= 'string' and field.type ~= 'integer'
                    and field.type ~= 'boolean'
                or not inputFormats[field.format]
                or type(field.required) ~= 'boolean' then return false end
            maximumIndex = math.max(maximumIndex, index)
            if field.source == 'id' then
                idFields = idFields + 1
                if operation ~= 'inspect' or field.key ~= 'id'
                    or field.required ~= true or idFields > 1 then return false end
            end
            if field.type == 'integer' then
                if field.format ~= 'integer' or field.minLength ~= nil
                    or field.maxLength ~= nil then return false end
            elseif field.type == 'string' then
                if field.format == 'integer' or field.minimum ~= nil
                    or field.maximum ~= nil then return false end
            elseif field.format ~= 'boolean' or field.minLength ~= nil or field.maxLength ~= nil
                or field.minimum ~= nil or field.maximum ~= nil then return false end
            if field.minLength ~= nil and (type(field.minLength) ~= 'number'
                or math.type(field.minLength) ~= 'integer' or field.minLength < 1
                or field.minLength > 128) then return false end
            if field.maxLength ~= nil and (type(field.maxLength) ~= 'number'
                or math.type(field.maxLength) ~= 'integer' or field.maxLength < 1
                or field.maxLength > 128) then return false end
            if field.minLength and field.maxLength
                and field.minLength > field.maxLength then return false end
            if field.minimum ~= nil and (type(field.minimum) ~= 'number'
                or math.type(field.minimum) ~= 'integer'
                or field.minimum < -2147483648 or field.minimum > 2147483647) then
                return false
            end
            if field.maximum ~= nil and (type(field.maximum) ~= 'number'
                or math.type(field.maximum) ~= 'integer'
                or field.maximum < -2147483648 or field.maximum > 2147483647) then
                return false
            end
            if field.minimum and field.maximum and field.minimum > field.maximum then
                return false
            end
            seen[field.key] = true
        end
        return count >= 1 and count == maximumIndex and count == #input.fields
    end

    local function copyViewInput(input)
        if input == nil then return nil end
        local fields = {}
        for index, field in ipairs(input.fields) do
            fields[index] = {
                key = field.key,
                label = field.label,
                source = field.source,
                type = field.type,
                format = field.format,
                required = field.required,
                minLength = field.minLength,
                maxLength = field.maxLength,
                minimum = field.minimum,
                maximum = field.maximum
            }
        end
        return { fields = fields }
    end

    local function viewInputsEqual(left, right)
        if left == nil or right == nil then return left == right end
        if type(left.fields) ~= 'table' or type(right.fields) ~= 'table'
            or #left.fields ~= #right.fields then return false end
        for index, field in ipairs(left.fields) do
            local candidate = right.fields[index]
            if type(candidate) ~= 'table' or field.key ~= candidate.key
                or field.label ~= candidate.label or field.source ~= candidate.source
                or field.type ~= candidate.type or field.format ~= candidate.format
                or field.required ~= candidate.required
                or field.minLength ~= candidate.minLength
                or field.maxLength ~= candidate.maxLength
                or field.minimum ~= candidate.minimum
                or field.maximum ~= candidate.maximum then return false end
        end
        return true
    end

    local function validateViewSearch(search, operation)
        if operation ~= 'search' or not exactObject(search, { kinds = true })
            or not boundedDenseArray(search.kinds, 16)
            or #search.kinds < 1 then return false end
        local seenKinds = {}
        for _, kind in ipairs(search.kinds) do
            if not exactObject(kind, { id = true, modes = true, accessClass = true })
                or not validIdentifier(kind.id, 32) or seenKinds[kind.id]
                or not accessClasses[kind.accessClass]
                or not boundedDenseArray(kind.modes, 2) or #kind.modes < 1 then return false end
            local seenModes = {}
            for _, mode in ipairs(kind.modes) do
                if mode ~= 'exact' and mode ~= 'prefix' or seenModes[mode] then return false end
                seenModes[mode] = true
            end
            seenKinds[kind.id] = true
        end
        return true
    end

    local function copyViewSearch(search)
        if search == nil then return nil end
        local kinds = {}
        for index, kind in ipairs(search.kinds) do
            local modes = {}
            for modeIndex, mode in ipairs(kind.modes) do modes[modeIndex] = mode end
            kinds[index] = { id = kind.id, modes = modes, accessClass = kind.accessClass }
        end
        return { kinds = kinds }
    end

    local function viewSearchEqual(left, right)
        if left == nil or right == nil then return left == right end
        if #left.kinds ~= #right.kinds then return false end
        for index, kind in ipairs(left.kinds) do
            local candidate = right.kinds[index]
            if type(candidate) ~= 'table' or candidate.id ~= kind.id
                or candidate.accessClass ~= kind.accessClass
                or #candidate.modes ~= #kind.modes then return false end
            for modeIndex, mode in ipairs(kind.modes) do
                if candidate.modes[modeIndex] ~= mode then return false end
            end
        end
        return true
    end

    local function copyViews(views, includeDescriptions)
        local result = {}
        for index, view in ipairs(views) do
            local description
            if includeDescriptions ~= false then description = view.description end
            result[index] = {
                id = view.id,
                label = view.label,
                operation = view.operation,
                presentation = view.presentation,
                order = view.order,
                description = description,
                accessClass = view.accessClass,
                input = copyViewInput(view.input),
                search = copyViewSearch(view.search)
            }
        end
        return result
    end

    local function sortedOperations(operations)
        local result = {}
        for operation in pairs(operations) do result[#result + 1] = operation end
        table.sort(result)
        return result
    end

    local function declaredMetadata(declaration)
        local operations = {}
        for index, operation in ipairs(declaration.operations) do operations[index] = operation end
        return {
            schemaVersion = 1,
            namespace = declaration.namespace,
            label = declaration.label,
            category = declaration.category,
            version = declaration.version,
            resource = declaration.resource,
            health = 'UNAVAILABLE',
            circuit = {
                state = 'OPEN',
                consecutiveFailures = 0,
                retryAfterMs = 0,
                lastFailureCode = 'PROVIDER_UNAVAILABLE'
            },
            operations = operations,
            capabilities = operations,
            views = copyViews(declaration.views, false),
            metrics = {
                calls = 0,
                successes = 0,
                failures = 0,
                rejections = 0,
                timeouts = 0,
                busy = 0,
                lastDurationMs = 0,
                maximumDurationMs = 0,
                lastResponseBytes = 0
            }
        }
    end

    local function circuitMetadata(provider, now)
        local state = provider.circuit
        local retryAfterMs = 0
        if state == 'OPEN' then
            retryAfterMs = math.max(0, math.floor((provider.retryAt or now) - now))
        end
        return {
            state = state,
            consecutiveFailures = provider.consecutiveFailures,
            retryAfterMs = retryAfterMs,
            lastFailureCode = provider.lastFailureCode
        }
    end

    local function providerMetadata(provider, includeDescriptions)
        local now = foundation.monotonicMs()
        local operations = sortedOperations(provider.operations)
        return {
            schemaVersion = 1,
            namespace = provider.namespace,
            label = provider.label,
            category = provider.category,
            version = provider.version,
            resource = provider.owner,
            health = provider.health,
            circuit = circuitMetadata(provider, now),
            operations = operations,
            capabilities = operations,
            views = copyViews(provider.views, includeDescriptions),
            metrics = {
                calls = provider.calls,
                successes = provider.successes,
                failures = provider.failures,
                rejections = provider.rejections,
                timeouts = provider.timeouts,
                busy = provider.busy,
                lastDurationMs = provider.lastDurationMs,
                maximumDurationMs = provider.maximumDurationMs,
                lastResponseBytes = provider.lastResponseBytes
            }
        }
    end

    local function validateDefinition(owner, definition)
        local definitionKeys = {
            schemaVersion = true,
            namespace = true,
            label = true,
            category = true,
            version = true,
            operations = true,
            views = true
        }
        if not exactObject(definition, definitionKeys) or definition.schemaVersion ~= 1
            or not validIdentifier(definition.namespace, 32)
            or not validText(definition.label, 64)
            or not validIdentifier(definition.category, 32)
            or not foundation.semver(definition.version)
            or type(definition.operations) ~= 'table'
            or getmetatable(definition.operations) ~= nil
            or type(definition.views) ~= 'table'
            or getmetatable(definition.views) ~= nil then
            return nil, foundation.error('INVALID_CONTROL_PROVIDER',
                'Control provider definitions must use the bounded schemaVersion 1 shape.')
        end

        local operationCount = 0
        for operation, handler in pairs(definition.operations) do
            operationCount = operationCount + 1
            if operationCount > 8 or not allowedOperations[operation]
                or not foundation.isCallable(handler) then
                return nil, foundation.error('INVALID_CONTROL_PROVIDER_OPERATION',
                    'Control provider operations must be allowed read-only callables.')
            end
        end
        if operationCount < 1 then
            return nil, foundation.error('INVALID_CONTROL_PROVIDER_OPERATION',
                'Control providers require at least one read-only operation.')
        end

        local viewKeys = {
            id = true,
            label = true,
            operation = true,
            presentation = true,
            order = true,
            description = true,
            accessClass = true,
            input = true,
            search = true
        }
        local viewCount, maximumIndex, seenViews = 0, 0, {}
        for key, view in pairs(definition.views) do
            viewCount = viewCount + 1
            if viewCount > maximumViews or type(key) ~= 'number'
                or math.type(key) ~= 'integer' or key < 1 then
                return nil, foundation.error('INVALID_CONTROL_PROVIDER_VIEW',
                    'Control provider views must be a bounded dense array.')
            end
            maximumIndex = math.max(maximumIndex, key)
            if not exactObject(view, viewKeys) or not validIdentifier(view.id, 48)
                or seenViews[view.id] or not validText(view.label, 64)
                or not allowedOperations[view.operation]
                or not definition.operations[view.operation]
                or not allowedPresentations[view.presentation]
                or not accessClasses[view.accessClass]
                or (view.order ~= nil and (type(view.order) ~= 'number'
                    or math.type(view.order) ~= 'integer' or view.order < 0 or view.order > 1000))
                or (view.description ~= nil and not validText(view.description, 160)) then
                return nil, foundation.error('INVALID_CONTROL_PROVIDER_VIEW',
                    'Control provider view metadata is invalid or references an unsupported operation.')
            end
            if view.input ~= nil and not validateViewInput(view.input, view.operation) then
                return nil, foundation.error('INVALID_CONTROL_PROVIDER_VIEW',
                    'Control provider view input metadata is invalid.')
            end
            if view.operation == 'search' then
                if not validateViewSearch(view.search, view.operation) then
                    return nil, foundation.error('INVALID_CONTROL_PROVIDER_VIEW',
                        'Control provider search metadata is invalid.')
                end
            elseif view.search ~= nil then
                return nil, foundation.error('INVALID_CONTROL_PROVIDER_VIEW',
                    'Only search views may declare search metadata.')
            end
            seenViews[view.id] = true
        end
        if viewCount < 1 or viewCount ~= maximumIndex or viewCount ~= #definition.views then
            return nil, foundation.error('INVALID_CONTROL_PROVIDER_VIEW',
                'Control provider views must be a non-empty dense array.')
        end

        local manifest = owner ~= coreResource and manifestFor(owner) or nil
        if owner ~= coreResource then
            local declared = type(manifest) == 'table' and manifest.controlProvider or nil
            if type(declared) ~= 'table' or declared.schemaVersion ~= definition.schemaVersion
                or declared.namespace ~= definition.namespace or declared.label ~= definition.label
                or declared.category ~= definition.category or declared.version ~= definition.version then
                return nil, foundation.error('CONTROL_PROVIDER_UNDECLARED',
                    'The resource manifest does not declare this control provider definition.')
            end
            local declaredOperations = {}
            for _, operation in ipairs(declared.operations or {}) do
                declaredOperations[operation] = true
            end
            if #declared.operations ~= operationCount then
                return nil, foundation.error('CONTROL_PROVIDER_DECLARATION_MISMATCH',
                    'Runtime control provider operations differ from the resource manifest.')
            end
            for operation in pairs(definition.operations) do
                if not declaredOperations[operation] then
                    return nil, foundation.error('CONTROL_PROVIDER_DECLARATION_MISMATCH',
                        'Runtime control provider operations differ from the resource manifest.')
                end
            end
            if type(declared.views) ~= 'table' or #declared.views ~= viewCount then
                return nil, foundation.error('CONTROL_PROVIDER_DECLARATION_MISMATCH',
                    'Runtime control provider views differ from the resource manifest.')
            end
            for index, view in ipairs(definition.views) do
                local declaredView = declared.views[index]
                if type(declaredView) ~= 'table' or declaredView.id ~= view.id
                    or declaredView.label ~= view.label or declaredView.operation ~= view.operation
                    or declaredView.presentation ~= view.presentation
                    or declaredView.order ~= view.order
                    or declaredView.description ~= view.description
                    or declaredView.accessClass ~= view.accessClass
                    or not viewInputsEqual(declaredView.input, view.input)
                    or not viewSearchEqual(declaredView.search, view.search) then
                    return nil, foundation.error('CONTROL_PROVIDER_DECLARATION_MISMATCH',
                        'Runtime control provider views differ from the resource manifest.')
                end
            end
        elseif definition.namespace ~= 'core' then
            return nil, foundation.error('INVALID_CONTROL_PROVIDER',
                'The built-in Core control provider must own the core namespace.')
        end

        local operationHandlers = {}
        for operation, handler in pairs(definition.operations) do
            operationHandlers[operation] = handler
        end
        return {
            namespace = definition.namespace,
            label = definition.label,
            category = definition.category,
            version = definition.version,
            operations = operationHandlers,
            views = copyViews(definition.views)
        }, nil
    end


    local function validateDeclaration(resource, declaration)
        local declarationKeys = {
            schemaVersion = true,
            namespace = true,
            label = true,
            category = true,
            version = true,
            operations = true,
            views = true
        }
        if type(resource) ~= 'string' or #resource < 3 or #resource > 64
            or not resource:match('^[A-Za-z0-9][A-Za-z0-9_%-]*$')
            or not exactObject(declaration, declarationKeys) or declaration.schemaVersion ~= 1
            or not validIdentifier(declaration.namespace, 32)
            or not validText(declaration.label, 64)
            or not validIdentifier(declaration.category, 32)
            or not foundation.semver(declaration.version)
            or type(declaration.operations) ~= 'table'
            or getmetatable(declaration.operations) ~= nil
            or type(declaration.views) ~= 'table'
            or getmetatable(declaration.views) ~= nil then
            return nil, foundation.error('INVALID_CONTROL_PROVIDER_DECLARATION',
                'Control provider manifest metadata is invalid.')
        end
        local operations, operationSet, operationCount, operationMaximum = {}, {}, 0, 0
        for key, operation in pairs(declaration.operations) do
            operationCount = operationCount + 1
            if operationCount > 8 or type(key) ~= 'number' or math.type(key) ~= 'integer'
                or key < 1 or not allowedOperations[operation] or operationSet[operation] then
                return nil, foundation.error('INVALID_CONTROL_PROVIDER_DECLARATION',
                    'Control provider manifest operations must be a bounded unique array.')
            end
            operationMaximum = math.max(operationMaximum, key)
            operationSet[operation] = true
            operations[key] = operation
        end
        if operationCount < 1 or operationCount ~= operationMaximum
            or operationCount ~= #declaration.operations then
            return nil, foundation.error('INVALID_CONTROL_PROVIDER_DECLARATION',
                'Control provider manifest operations must be a non-empty dense array.')
        end
        table.sort(operations)

        local viewKeys = {
            id = true,
            label = true,
            operation = true,
            presentation = true,
            order = true,
            description = true,
            accessClass = true,
            input = true,
            search = true
        }
        local views, viewCount, viewMaximum, seenViews = {}, 0, 0, {}
        for key, view in pairs(declaration.views) do
            viewCount = viewCount + 1
            if viewCount > maximumViews or type(key) ~= 'number'
                or math.type(key) ~= 'integer' or key < 1 then
                return nil, foundation.error('INVALID_CONTROL_PROVIDER_DECLARATION',
                    'Control provider manifest views must be a bounded dense array.')
            end
            viewMaximum = math.max(viewMaximum, key)
            if not exactObject(view, viewKeys) or not validIdentifier(view.id, 48)
                or seenViews[view.id] or not validText(view.label, 64)
                or not operationSet[view.operation]
                or not allowedPresentations[view.presentation]
                or not accessClasses[view.accessClass]
                or (view.order ~= nil and (type(view.order) ~= 'number'
                    or math.type(view.order) ~= 'integer' or view.order < 0 or view.order > 1000))
                or (view.description ~= nil and not validText(view.description, 160)) then
                return nil, foundation.error('INVALID_CONTROL_PROVIDER_DECLARATION',
                    'Control provider manifest view metadata is invalid.')
            end
            if view.input ~= nil and not validateViewInput(view.input, view.operation) then
                return nil, foundation.error('INVALID_CONTROL_PROVIDER_DECLARATION',
                    'Control provider manifest view input metadata is invalid.')
            end
            if view.operation == 'search' then
                if not validateViewSearch(view.search, view.operation) then
                    return nil, foundation.error('INVALID_CONTROL_PROVIDER_DECLARATION',
                        'Control provider manifest search metadata is invalid.')
                end
            elseif view.search ~= nil then
                return nil, foundation.error('INVALID_CONTROL_PROVIDER_DECLARATION',
                    'Only search views may declare search metadata.')
            end
            seenViews[view.id] = true
            views[key] = {
                id = view.id,
                label = view.label,
                operation = view.operation,
                presentation = view.presentation,
                order = view.order,
                description = view.description,
                accessClass = view.accessClass,
                input = copyViewInput(view.input),
                search = copyViewSearch(view.search)
            }
        end
        if viewCount < 1 or viewCount ~= viewMaximum or viewCount ~= #declaration.views then
            return nil, foundation.error('INVALID_CONTROL_PROVIDER_DECLARATION',
                'Control provider manifest views must be a non-empty dense array.')
        end
        return {
            resource = resource,
            schemaVersion = 1,
            namespace = declaration.namespace,
            label = declaration.label,
            category = declaration.category,
            version = declaration.version,
            operations = operations,
            views = views
        }, nil
    end

    local function recordFailure(provider, operation, code, durationMs, timeout)
        provider.calls = provider.calls + 1
        provider.failures = provider.failures + 1
        provider.consecutiveFailures = provider.consecutiveFailures + 1
        provider.lastFailureCode = code
        provider.lastDurationMs = durationMs
        provider.maximumDurationMs = math.max(provider.maximumDurationMs, durationMs)
        if timeout then provider.timeouts = provider.timeouts + 1 end
        if provider.consecutiveFailures >= circuitFailureThreshold then
            provider.circuit = 'OPEN'
            provider.retryAt = foundation.monotonicMs() + circuitOpenMs
            provider.health = 'UNAVAILABLE'
        else
            provider.circuit = 'CLOSED'
            provider.health = worseSeverity(provider.reportedHealth, 'DEGRADED')
        end
        metrics:increment('synex_control_provider_invocations_total', {
            namespace = provider.namespace,
            operation = operation,
            outcome = timeout and 'timeout' or 'failure'
        })
        metrics:observe('synex_control_provider_duration_ms', {
            namespace = provider.namespace,
            operation = operation
        }, durationMs)
    end

    local function recordRejection(provider, operation, code, durationMs)
        provider.calls = provider.calls + 1
        provider.rejections = provider.rejections + 1
        provider.lastDurationMs = durationMs
        provider.maximumDurationMs = math.max(provider.maximumDurationMs, durationMs)
        metrics:increment('synex_control_provider_invocations_total', {
            namespace = provider.namespace,
            operation = operation,
            outcome = 'rejected'
        })
        metrics:observe('synex_control_provider_duration_ms', {
            namespace = provider.namespace,
            operation = operation
        }, durationMs)
        metrics:increment('synex_control_provider_rejections_total', {
            namespace = provider.namespace,
            operation = operation,
            code = code
        })
    end

    local registry = {}

    function registry:declare(resource, declaration)
        local previousNamespace = declarationNamespaces[resource]
        if declaration == nil then
            if previousNamespace and declarations[previousNamespace]
                and declarations[previousNamespace].resource == resource then
                declarations[previousNamespace] = nil
            end
            declarationNamespaces[resource] = nil
            return true, nil
        end
        local candidate, declarationError = validateDeclaration(resource, declaration)
        if not candidate then return nil, declarationError end
        local existing = declarations[candidate.namespace]
        local active = providers[candidate.namespace]
        if existing and existing.resource ~= resource
            or active and active.owner ~= resource then
            return nil, foundation.error('DUPLICATE_CONTROL_PROVIDER',
                'The control provider namespace is already owned by another resource.')
        end
        local declaredCount = 0
        for _ in pairs(declarations) do declaredCount = declaredCount + 1 end
        if not existing and declaredCount >= maximumProviders then
            return nil, foundation.error('CONTROL_PROVIDER_LIMIT',
                'The bounded control provider declaration registry is at capacity.')
        end
        if previousNamespace and previousNamespace ~= candidate.namespace
            and declarations[previousNamespace]
            and declarations[previousNamespace].resource == resource then
            declarations[previousNamespace] = nil
        end
        declarations[candidate.namespace] = candidate
        declarationNamespaces[resource] = candidate.namespace
        return declaredMetadata(candidate), nil
    end

    function registry:markUnavailable(resource)
        local namespace = declarationNamespaces[resource]
        local provider = namespace and providers[namespace] or nil
        if provider and provider.owner == resource then
            provider.deactivated = true
            provider.health = 'UNAVAILABLE'
            provider.circuit = 'OPEN'
            provider.retryAt = foundation.monotonicMs() + circuitOpenMs
            provider.lastFailureCode = 'PROVIDER_UNAVAILABLE'
        end
        return true
    end

    function registry:register(owner, epoch, definition)
        if not owners:isCurrent(owner, epoch) then
            return nil, foundation.error('STALE_RESOURCE',
                'The control provider owner restarted.', { retryable = true })
        end
        local candidate, validationError = validateDefinition(owner, definition)
        if not candidate then return nil, validationError end
        if providers[candidate.namespace] ~= nil then
            return nil, foundation.error('DUPLICATE_CONTROL_PROVIDER',
                'The control provider namespace is already registered.')
        end
        if providerCount >= maximumProviders
            or (providerCounts[owner] or 0) >= maximumProvidersPerOwner then
            return nil, foundation.error('CONTROL_PROVIDER_LIMIT',
                'The bounded control provider registry is at capacity.')
        end
        local metadataEncodedOk, encodedMetadata = pcall(platform.jsonEncode, {
            schemaVersion = 1,
            namespace = candidate.namespace,
            label = candidate.label,
            category = candidate.category,
            version = candidate.version,
            operations = sortedOperations(candidate.operations),
            views = candidate.views
        })
        if not metadataEncodedOk or type(encodedMetadata) ~= 'string'
            or #encodedMetadata > 16384 then
            return nil, foundation.error('INVALID_CONTROL_PROVIDER',
                'Control provider metadata exceeds its encoded size limit.')
        end

        local provider = {
            namespace = candidate.namespace,
            label = candidate.label,
            category = candidate.category,
            version = candidate.version,
            operations = candidate.operations,
            views = candidate.views,
            owner = owner,
            epoch = epoch,
            deactivated = false,
            health = 'INFO',
            reportedHealth = 'INFO',
            circuit = 'CLOSED',
            retryAt = nil,
            consecutiveFailures = 0,
            lastFailureCode = nil,
            inFlight = false,
            calls = 0,
            successes = 0,
            failures = 0,
            rejections = 0,
            timeouts = 0,
            busy = 0,
            lastDurationMs = 0,
            maximumDurationMs = 0,
            lastResponseBytes = 0
        }
        providers[provider.namespace] = provider
        providerCount = providerCount + 1
        providerCounts[owner] = (providerCounts[owner] or 0) + 1
        local tracked, trackingError = owners:track(owner, epoch, 'control_provider',
            provider.namespace, function()
                if providers[provider.namespace] == provider then
                    providers[provider.namespace] = nil
                    providerCount = math.max(0, providerCount - 1)
                    providerCounts[owner] = math.max(0, (providerCounts[owner] or 1) - 1)
                    if providerCounts[owner] == 0 then providerCounts[owner] = nil end
                end
            end)
        if not tracked then
            providers[provider.namespace] = nil
            providerCount = math.max(0, providerCount - 1)
            providerCounts[owner] = math.max(0, (providerCounts[owner] or 1) - 1)
            if providerCounts[owner] == 0 then providerCounts[owner] = nil end
            return nil, trackingError
        end
        metrics:increment('synex_control_provider_registrations_total', {
            namespace = provider.namespace,
            resource = owner
        })
        return providerMetadata(provider), nil
    end

    local function providerCandidates()
        local candidates = {}
        local activeNamespaces = {}
        for _, provider in pairs(providers) do
            if not provider.deactivated and owners:isCurrent(provider.owner, provider.epoch) then
                local metadata = providerMetadata(provider, false)
                -- The catalog already exposes the canonical operation list. Avoid
                -- serializing its legacy `capabilities` alias a second time.
                metadata.capabilities = nil
                candidates[#candidates + 1] = metadata
                activeNamespaces[provider.namespace] = true
            end
        end
        for namespace, declaration in pairs(declarations) do
            if not activeNamespaces[namespace] then
                local metadata = declaredMetadata(declaration)
                metadata.capabilities = nil
                candidates[#candidates + 1] = metadata
            end
        end
        table.sort(candidates, function(left, right) return left.namespace < right.namespace end)
        return candidates
    end

    function registry:describe(namespace)
        if not validIdentifier(namespace, 32) then
            return nil, foundation.error('INVALID_CONTROL_PROVIDER_REQUEST',
                'The control provider namespace is invalid.')
        end
        local provider = providers[namespace]
        if provider and not provider.deactivated and owners:isCurrent(provider.owner, provider.epoch) then
            return providerMetadata(provider), nil
        end
        local declaration = declarations[namespace]
        if declaration then return declaredMetadata(declaration), nil end
        return nil, foundation.error('CONTROL_PROVIDER_NOT_FOUND',
            'The requested control provider is unavailable.', { retryable = true })
    end

    function registry:list(request)
        request = request == nil and {} or request
        if not exactObject(request, { cursor = true, limit = true })
            or request.cursor ~= nil and not validIdentifier(request.cursor, 32)
            or request.limit ~= nil and (type(request.limit) ~= 'number'
                or math.type(request.limit) ~= 'integer' or request.limit < 1
                or request.limit > maximumProviders) then
            return nil, foundation.error('INVALID_CONTROL_PROVIDER_REQUEST',
                'The control provider catalog page is invalid.')
        end
        local candidates = providerCandidates()
        local limit = request.limit or maximumProviders
        local envelope = {
            schemaVersion = 1,
            generatedAt = foundation.utcIso(),
            providers = {},
            hasMore = false,
            nextCursor = nil,
            total = #candidates,
            truncated = false,
        }
        local first = 1
        while request.cursor ~= nil and first <= #candidates
            and candidates[first].namespace <= request.cursor do first = first + 1 end
        local lastNamespace
        for index = first, #candidates do
            if #envelope.providers >= limit then
                envelope.hasMore = true
                break
            end
            local candidate = candidates[index]
            envelope.providers[#envelope.providers + 1] = candidate
            local encodedOk, encoded = pcall(platform.jsonEncode, envelope)
            if not encodedOk or type(encoded) ~= 'string'
                or #encoded > maximumResponseBytes then
                envelope.providers[#envelope.providers] = nil
                envelope.hasMore = true
                break
            end
            lastNamespace = candidate.namespace
        end
        envelope.nextCursor = envelope.hasMore and lastNamespace or nil
        envelope.truncated = envelope.hasMore
        return envelope, nil
    end

    function registry:invoke(caller, callerEpoch, namespace, operation, request, options, traceId)
        if not owners:isCurrent(caller, callerEpoch) then
            return nil, foundation.error('STALE_RESOURCE',
                'The control provider caller restarted.', { retryable = true, traceId = traceId })
        end
        if not validIdentifier(namespace, 32) or not allowedOperations[operation] then
            return nil, foundation.error('INVALID_CONTROL_PROVIDER_REQUEST',
                'Control provider namespace or operation is invalid.', { traceId = traceId })
        end
        request = request == nil and {} or request
        options = options == nil and {} or options
        if not exactObject(options, { timeoutMs = true }) then
            return nil, foundation.error('INVALID_CONTROL_PROVIDER_OPTIONS',
                'Control provider options contain an unknown property.', { traceId = traceId })
        end
        local timeoutMs = options.timeoutMs == nil and defaultTimeoutMs or options.timeoutMs
        if type(timeoutMs) ~= 'number' or math.type(timeoutMs) ~= 'integer'
            or timeoutMs < minimumTimeoutMs or timeoutMs > maximumTimeoutMs then
            return nil, foundation.error('INVALID_CONTROL_PROVIDER_OPTIONS',
                'Control provider timeoutMs must be an integer from 25 through 2000.', {
                    traceId = traceId
                })
        end
        local requestIsObject = type(request) == 'table'
            and foundation.jsonContainerKind(request) ~= 'array'
        if requestIsObject then
            for key in pairs(request) do
                if type(key) ~= 'string' then requestIsObject = false break end
            end
        end
        if not requestIsObject or not validateJson(request, requestLimits) then
            return nil, foundation.error('INVALID_CONTROL_PROVIDER_REQUEST',
                'Control provider requests must be bounded plain JSON objects.', { traceId = traceId })
        end
        local requestEncodedOk, encodedRequest = pcall(platform.jsonEncode, request)
        if not requestEncodedOk or type(encodedRequest) ~= 'string'
            or #encodedRequest > maximumRequestBytes then
            return nil, foundation.error('CONTROL_PROVIDER_REQUEST_TOO_LARGE',
                'Control provider requests may not exceed 4096 encoded bytes.', {
                    traceId = traceId
                })
        end

        local provider = providers[namespace]
        if not provider or provider.deactivated
            or not owners:isCurrent(provider.owner, provider.epoch) then
            return nil, foundation.error('CONTROL_PROVIDER_NOT_FOUND',
                'The requested control provider is unavailable.', {
                    traceId = traceId,
                    retryable = true
                })
        end
        local handler = provider.operations[operation]
        if not foundation.isCallable(handler) then
            return nil, foundation.error('CONTROL_PROVIDER_OPERATION_UNSUPPORTED',
                'The requested control provider operation is not supported.', {
                    traceId = traceId
                })
        end
        local presentation = nil
        if request.view ~= nil then
            if type(request.view) ~= 'string' then
                return nil, foundation.error('INVALID_CONTROL_PROVIDER_REQUEST',
                    'Control provider view must be a declared bounded identifier.', {
                        traceId = traceId
                    })
            end
            for _, view in ipairs(provider.views) do
                if view.id == request.view and view.operation == operation then
                    presentation = view.presentation
                    break
                end
            end
            if presentation == nil then
                return nil, foundation.error('INVALID_CONTROL_PROVIDER_REQUEST',
                    'Control provider view is not declared for this operation.', {
                        traceId = traceId
                    })
            end
        end
        local now = foundation.monotonicMs()
        if provider.circuit == 'OPEN' then
            if now < (provider.retryAt or now) then
                return nil, foundation.error('CONTROL_PROVIDER_CIRCUIT_OPEN',
                    'The control provider circuit is open.', {
                        traceId = traceId,
                        retryable = true,
                        details = { retryAfterMs = math.max(0, math.floor(provider.retryAt - now)) }
                    })
            end
            provider.circuit = 'HALF_OPEN'
        end
        if provider.inFlight then
            provider.busy = provider.busy + 1
            metrics:increment('synex_control_provider_invocations_total', {
                namespace = provider.namespace,
                operation = operation,
                outcome = 'busy'
            })
            return nil, foundation.error('CONTROL_PROVIDER_BUSY',
                'The control provider already has an in-flight request.', {
                    traceId = traceId,
                    retryable = true
                })
        end

        local invocation = {
            cancelled = false,
            completed = false,
            returned = false,
            reason = nil
        }
        provider.inFlight = invocation
        local providerOperation, operationError = owners:beginOperation(
            provider.owner, provider.epoch, function(reason)
                invocation.cancelled = true
                invocation.reason = tostring(reason or 'provider owner quiesced')
            end)
        if not providerOperation then
            provider.inFlight = false
            return nil, operationError
        end

        local startedAt = foundation.monotonicMs()
        local deadlineAt = startedAt + timeoutMs
        local requestCopyOk, requestCopy = foundation.safeCall(foundation.copy, request)
        if not requestCopyOk then
            owners:finishOperation(provider.owner, provider.epoch, providerOperation)
            provider.inFlight = false
            return nil, foundation.error('INVALID_CONTROL_PROVIDER_REQUEST',
                'The control provider request could not be copied safely.', { traceId = traceId })
        end
        local context = foundation.readonly({
            caller = caller,
            provider = provider.owner,
            namespace = namespace,
            operation = operation,
            traceId = traceId,
            deadlineAt = deadlineAt,
            readOnly = true,
            mode = operation == 'simulate' and 'explain' or 'observe'
        })
        local parentContext = foundation.isCallable(foundation.currentContext)
            and foundation.currentContext() or nil
        local executionContext = {
            caller = caller,
            provider = provider.owner,
            contract = ('control.%s.%s'):format(namespace, operation),
            traceId = traceId,
            parentSpanId = parentContext and parentContext.spanId or nil
        }
        local function executeHandler()
            invocation.invoked, invocation.value, invocation.providerError =
                foundation.safeCall(function()
                    if foundation.isCallable(foundation.withContext) then
                        return foundation.withContext(executionContext,
                            handler, requestCopy, context)
                    end
                    return handler(requestCopy, context)
                end)
            invocation.finishedAt = foundation.monotonicMs()
            owners:finishOperation(provider.owner, provider.epoch, providerOperation)
            invocation.completed = true
            if invocation.returned and provider.inFlight == invocation then
                provider.inFlight = false
            end
        end

        local asynchronous = foundation.isCallable(platform.createThread)
            and foundation.isCallable(platform.defer)
        if asynchronous then
            local scheduled = foundation.safeCall(platform.createThread, executeHandler)
            if not scheduled then
                owners:finishOperation(provider.owner, provider.epoch, providerOperation)
                provider.inFlight = false
                recordFailure(provider, operation, 'PROVIDER_SCHEDULING_FAILED', 0, false)
                return nil, foundation.error('PROVIDER_ERROR',
                    'The control provider could not be scheduled safely.', {
                        traceId = traceId,
                        retryable = true
                    })
            end
            while not invocation.completed and foundation.monotonicMs() < deadlineAt do
                platform.defer()
            end
            if not invocation.completed then
                local timedOutAt = foundation.monotonicMs()
                local durationMs = math.max(0, timedOutAt - startedAt)
                invocation.returned = true
                recordFailure(provider, operation, 'PROVIDER_TIMEOUT', durationMs, true)
                return nil, foundation.error('PROVIDER_TIMEOUT',
                    'The control provider exceeded its execution deadline.', {
                        traceId = traceId,
                        retryable = true
                    })
            end
        else
            -- Headless runtimes without a scheduler retain the same post-call fence.
            executeHandler()
        end

        local invoked, value, providerError = invocation.invoked,
            invocation.value, invocation.providerError
        local finishedAt = invocation.finishedAt or foundation.monotonicMs()
        local durationMs = math.max(0, finishedAt - startedAt)
        invocation.returned = true
        if provider.inFlight == invocation then provider.inFlight = false end

        if invocation.cancelled or providers[namespace] ~= provider
            or not owners:isCurrent(provider.owner, provider.epoch) then
            recordFailure(provider, operation, 'STALE_RESOURCE', durationMs, false)
            return nil, foundation.error('STALE_RESOURCE',
                'The control provider restarted before completing the request.', {
                    traceId = traceId,
                    retryable = true,
                    details = { reason = invocation.reason }
                })
        end
        if durationMs > timeoutMs or finishedAt > deadlineAt then
            recordFailure(provider, operation, 'PROVIDER_TIMEOUT', durationMs, true)
            return nil, foundation.error('PROVIDER_TIMEOUT',
                'The control provider exceeded its execution deadline.', {
                    traceId = traceId,
                    retryable = true
                })
        end
        if not invoked or (providerError ~= nil and providerError ~= false) then
            local failure = invoked and providerError or value
            local cause = foundation.failureCode(failure, 'PROVIDER_EXCEPTION')
            local expected = invoked and expectedFailureCode(cause) or nil
            if expected then
                recordRejection(provider, operation, expected, durationMs)
                return nil, foundation.error(expected,
                    'The control provider rejected the bounded read request.', {
                        traceId = traceId,
                        retryable = false,
                        details = { cause = cause }
                    })
            end
            recordFailure(provider, operation, cause, durationMs, false)
            return nil, foundation.error('PROVIDER_ERROR',
                'The control provider could not complete the read operation.', {
                    traceId = traceId,
                    retryable = type(failure) == 'table' and failure.retryable == true,
                    details = { cause = cause }
                })
        end
        local healthSeverity = operation == 'health' and reportedSeverity(value) or nil
        if value == nil or not validateJson(value, responseLimits)
            or operation == 'health' and healthSeverity == nil
            or not validateOperationResponse(operation, presentation, value) then
            recordFailure(provider, operation, 'INVALID_PROVIDER_RESPONSE', durationMs, false)
            return nil, foundation.error('INVALID_PROVIDER_RESPONSE',
                'The control provider returned a non-JSON or structurally unsafe response.', {
                    traceId = traceId
                })
        end

        local valueCopied, copiedValue = foundation.safeCall(foundation.copy, value)
        if not valueCopied then
            recordFailure(provider, operation, 'INVALID_PROVIDER_RESPONSE', durationMs, false)
            return nil, foundation.error('INVALID_PROVIDER_RESPONSE',
                'The control provider response could not be copied safely.', {
                    traceId = traceId
                })
        end
        if operation == 'health' then
            copiedValue.status = healthSeverity
        end
        local envelope = {
            schemaVersion = 1,
            namespace = namespace,
            operation = operation,
            resource = provider.owner,
            generatedAt = foundation.utcIso(),
            durationMs = durationMs,
            data = copiedValue
        }
        local responseEncodedOk, encodedResponse = pcall(platform.jsonEncode, envelope)
        if not responseEncodedOk or type(encodedResponse) ~= 'string'
            or #encodedResponse > maximumResponseBytes then
            recordFailure(provider, operation, 'PROVIDER_RESPONSE_TOO_LARGE', durationMs, false)
            return nil, foundation.error('PROVIDER_RESPONSE_TOO_LARGE',
                'The control provider response may not exceed 32768 encoded bytes.', {
                    traceId = traceId
                })
        end

        provider.calls = provider.calls + 1
        provider.successes = provider.successes + 1
        provider.consecutiveFailures = 0
        provider.lastFailureCode = nil
        provider.circuit = 'CLOSED'
        provider.retryAt = nil
        provider.health = provider.reportedHealth or 'INFO'
        provider.lastDurationMs = durationMs
        provider.maximumDurationMs = math.max(provider.maximumDurationMs, durationMs)
        provider.lastResponseBytes = #encodedResponse
        if (operation == 'health' or operation == 'summary')
            and type(copiedValue) == 'table' then
            local reported = reportedSeverity(copiedValue)
            if reported then
                provider.reportedHealth = reported
                provider.health = reported
            end
        end
        metrics:increment('synex_control_provider_invocations_total', {
            namespace = provider.namespace,
            operation = operation,
            outcome = 'success'
        })
        metrics:observe('synex_control_provider_duration_ms', {
            namespace = provider.namespace,
            operation = operation
        }, durationMs)
        metrics:observe('synex_control_provider_response_bytes', {
            namespace = provider.namespace,
            operation = operation
        }, #encodedResponse)
        return envelope, nil
    end

    return registry
end
