return function(Foundation)
local function createCoordinator(deps)
    deps = deps or {}
    local registries = assert(type(deps.registries) == 'table' and deps.registries,
        'extension registry coordinator requires registries')
    local query = assert(type(deps.query) == 'function' and deps.query,
        'extension registry coordinator requires query')
    local startTransaction = assert(type(deps.startTransaction) == 'function' and deps.startTransaction,
        'extension registry coordinator requires transactions')
    local isOwnerRunning = deps.isOwnerRunning
    if isOwnerRunning == nil then isOwnerRunning = function() return true end end
    if type(isOwnerRunning) ~= 'function' then
        error('extension registry coordinator requires an owner-state resolver')
    end
    local coordinator = {}
    local appliedSyncGenerations = {}
    local synchronizedOwners = {}
    local managedRegistries = { 'groupTypes', 'relationTypes', 'dutyStates', 'attributeSchemas' }
    local function validOwner(owner)
        return type(owner) == 'string' and #owner >= 3 and #owner <= 64
            and owner:match('^[A-Za-z0-9][A-Za-z0-9_.%-]*$') ~= nil
    end
    local function validEpoch(epoch)
        return type(epoch) == 'number' and math.type(epoch) == 'integer' and epoch >= 1
    end
    local function affectedRows(result)
        if type(result) == 'number' then return result end
        if type(result) ~= 'table' then return nil end
        local value = tonumber(result.affectedRows or result.changedRows)
        if not value or math.type(value) ~= 'integer' or value < 0 then return nil end
        return value
    end
    local function setOwnerActive(owner, epoch, active)
        local firstError
        for _, registryName in ipairs(managedRegistries) do
            local registry = registries[registryName]
            if type(registry) ~= 'table'
                or type(registry.setOwnerActive) ~= 'function' then
                firstError = firstError or Foundation.domainError(
                    'REGISTRY_ENTRY_INVALID',
                    'An extension registry cannot enforce owner activity.')
            else
                local changed, stateError = registry:setOwnerActive(owner, epoch, active)
                if not changed then firstError = firstError or stateError end
            end
        end
        if firstError then return nil, firstError end
        return true, nil
    end
    function coordinator:apply(mutation)
        if type(mutation) ~= 'table' or type(mutation.registry) ~= 'string'
            or not validOwner(mutation.owner) or not validEpoch(mutation.epoch)
            or type(mutation.generation) ~= 'number'
            or math.type(mutation.generation) ~= 'integer'
            or mutation.generation < 1
            or type(mutation.key) ~= 'string' or type(mutation.value) ~= 'table' then
            return nil, Foundation.domainError('REGISTRY_ENTRY_INVALID',
                'The committed extension registry mutation is invalid.')
        end
        local synchronized = synchronizedOwners[mutation.owner]
        if not synchronized or not synchronized.active
            or synchronized.epoch ~= mutation.epoch
            or synchronized.generation ~= mutation.generation then
            return nil, Foundation.domainError('STALE_RESOURCE',
                'The extension registry owner synchronization is not active.')
        end
        local registry = registries[mutation.registry]
        if type(registry) ~= 'table' or type(registry.replace) ~= 'function' then
            return nil, Foundation.domainError('REGISTRY_ENTRY_INVALID',
                'The target extension registry is unavailable.')
        end
        local _, lookupError, metadata = registry:get(mutation.key)
        if metadata and metadata.owner ~= mutation.owner then
            local removed, removeError = registry:remove(
                metadata.owner, metadata.epoch, mutation.key, metadata.token)
            if not removed then return nil, removeError end
        elseif not metadata and lookupError and lookupError.code ~= 'REGISTRY_KEY_NOT_FOUND' then
            return nil, lookupError
        end
        return registry:replace(
            mutation.owner, mutation.epoch, mutation.key, mutation.value)
    end
    local refreshDefinitions = {
        types_register = {
            registry = 'groupTypes', prefix = 'group_type:', requestKey = 'type',
            sql = [[SELECT public_id, type_key AS registry_key, owner_resource, owner_epoch,
                    display_name, schema_version, create_permission,
                    membership_limit, active_membership_limit, version
                FROM synex_group_types WHERE type_key = ? AND status = 'active' LIMIT 1]],
            value = function(row)
                return { publicId = row.public_id, key = row.registry_key,
                    label = row.display_name, schemaVersion = tonumber(row.schema_version),
                    createPermission = row.create_permission,
                    maxMembers = tonumber(row.membership_limit),
                    maxActiveMembers = tonumber(row.active_membership_limit),
                    version = tonumber(row.version) }
            end
        },
        relation_types_register = {
            registry = 'relationTypes', prefix = 'relation_type:', requestKey = 'type',
            sql = [[SELECT public_id, type_key AS registry_key, owner_resource, owner_epoch,
                    display_name, direction, schema_version, version
                FROM synex_group_relation_types WHERE type_key = ? AND status = 'active' LIMIT 1]],
            value = function(row)
                return { publicId = row.public_id, key = row.registry_key,
                    label = row.display_name, direction = row.direction,
                    schemaVersion = tonumber(row.schema_version), version = tonumber(row.version) }
            end
        },
        duty_states_register = {
            registry = 'dutyStates', prefix = 'duty_state:', requestKey = 'state',
            sql = [[SELECT public_id, state_key AS registry_key, owner_resource, owner_epoch,
                    display_name, counts_as_on_duty, schema_version, version
                FROM synex_group_duty_states WHERE state_key = ? AND status = 'active' LIMIT 1]],
            value = function(row)
                return { publicId = row.public_id, key = row.registry_key,
                    label = row.display_name,
                    countsAsOnDuty = tonumber(row.counts_as_on_duty) == 1,
                    schemaVersion = tonumber(row.schema_version), version = tonumber(row.version) }
            end
        },
        attributes_register_schema = {
            registry = 'attributeSchemas', requestKey = 'key',
            query = function(request)
                if request.group_type ~= nil then
                    return [[SELECT schema.public_id,
                            schema.attribute_key AS registry_key,
                            schema.namespace, schema.owner_resource,
                            schema.owner_epoch, schema.value_kind,
                            schema.visibility, schema.required_value,
                            schema.has_default, schema.capability,
                            schema.schema_version, schema.version,
                            group_type.type_key AS group_type_key
                        FROM synex_group_attribute_schemas AS schema
                        INNER JOIN synex_group_types AS group_type
                            ON group_type.id = schema.group_type_id
                        WHERE schema.namespace = ? AND schema.attribute_key = ?
                            AND group_type.type_key = ?
                            AND group_type.status = 'active'
                            AND schema.status = 'active' LIMIT 1]], {
                        request.namespace, request.key, request.group_type
                    }
                end
                return [[SELECT schema.public_id,
                        schema.attribute_key AS registry_key,
                        schema.namespace, schema.owner_resource,
                        schema.owner_epoch, schema.value_kind,
                        schema.visibility, schema.required_value,
                        schema.has_default, schema.capability,
                        schema.schema_version, schema.version,
                        NULL AS group_type_key
                    FROM synex_group_attribute_schemas AS schema
                    WHERE schema.namespace = ? AND schema.attribute_key = ?
                        AND schema.group_type_id IS NULL
                        AND schema.status = 'active' LIMIT 1]], {
                    request.namespace, request.key
                }
            end,
            key = function(row)
                local scope = row.group_type_key ~= nil
                    and 'type:' .. tostring(row.group_type_key) or 'global'
                return 'attribute_schema:' .. scope .. ':'
                    .. tostring(row.namespace) .. ':' .. tostring(row.registry_key)
            end,
            value = function(row)
                return {
                    publicId = row.public_id,
                    namespace = row.namespace,
                    key = row.registry_key,
                    scope = row.group_type_key ~= nil
                        and 'type:' .. tostring(row.group_type_key) or 'global',
                    groupType = row.group_type_key,
                    type = row.value_kind,
                    visibility = row.visibility,
                    capability = row.capability,
                    required = tonumber(row.required_value) == 1,
                    hasDefault = tonumber(row.has_default) == 1,
                    schemaVersion = tonumber(row.schema_version),
                    ownerEpoch = tonumber(row.owner_epoch),
                    version = tonumber(row.version)
                }
            end
        }
    }
    function coordinator:refresh(operation, request, context, response, committedMutations)
        local definition = refreshDefinitions[operation]
        local owner = type(context) == 'table' and context.caller or nil
        local epoch = type(context) == 'table' and context.callerEpoch or nil
        if operation == 'registries_begin' then
            local generation = type(response) == 'table' and tonumber(response.generation) or nil
            if not validOwner(owner) or not validEpoch(epoch)
                or type(response) ~= 'table' or response.owner_resource ~= owner
                or tonumber(response.owner_epoch) ~= epoch or not generation
                or math.type(generation) ~= 'integer' or generation < 1 then
                return nil, Foundation.domainError('REGISTRY_ENTRY_INVALID',
                    'The registry synchronization response is invalid.')
            end
            local syncRows = query([[SELECT `owner_epoch`, `begin_key`, `generation`, `active`
                FROM `synex_group_registry_owner_syncs`
                WHERE `owner_resource` = ? LIMIT 1]], { owner })
            if type(syncRows) ~= 'table' then
                return nil, Foundation.domainError('DATABASE_ERROR',
                    'The registry synchronization state could not be verified.', true)
            end
            local sync = syncRows[1]
            local syncEpoch = type(sync) == 'table' and tonumber(sync.owner_epoch) or nil
            local syncGeneration = type(sync) == 'table' and tonumber(sync.generation) or nil
            local syncActive = type(sync) == 'table' and tonumber(sync.active) or nil
            if not sync or syncEpoch ~= epoch or syncGeneration ~= generation
                or sync.begin_key ~= request.idempotency_key or syncActive ~= 1 then
                return nil, Foundation.domainError('STALE_RESOURCE',
                    'The registry synchronization session is no longer current.')
            end
            local current = synchronizedOwners[owner]
            if current and current.generation > generation then
                return nil, Foundation.domainError('STALE_RESOURCE',
                    'A newer registry synchronization session is already active.')
            end
            if current and current.active and current.epoch == epoch
                and current.generation == generation
                and (appliedSyncGenerations[owner] or 0) >= generation then
                return { owner = owner, epoch = epoch, generation = generation,
                    removed = 0, replayed = true }, nil
            end
            if current then
                local deactivated, deactivationError = setOwnerActive(
                    owner, current.epoch, false)
                if not deactivated then return nil, deactivationError end
                current.active = false
            end
            local removed = 0
            local cleanupFailure
            for _, registryName in ipairs(managedRegistries) do
                local registry = registries[registryName]
                if type(registry) ~= 'table' or type(registry.cleanupOwner) ~= 'function' then
                    cleanupFailure = cleanupFailure or Foundation.domainError(
                        'REGISTRY_ENTRY_INVALID',
                        'An extension registry cannot begin owner synchronization.')
                else
                    local count, cleanupError = registry:cleanupOwner(owner)
                    if count == nil then
                        cleanupFailure = cleanupFailure or cleanupError
                    else
                        removed = removed + count
                    end
                end
            end
            if cleanupFailure then
                return nil, Foundation.domainError('DATABASE_ERROR',
                    'Registry synchronization runtime cleanup could not be completed.', true)
            end
            local activated, activationError = setOwnerActive(owner, epoch, true)
            if not activated then return nil, activationError end
            appliedSyncGenerations[owner] = generation
            synchronizedOwners[owner] = {
                epoch = epoch, generation = generation, active = true
            }
            return { owner = owner, epoch = epoch, generation = generation,
                removed = removed, replayed = false }, nil
        end
        if not definition then return true, nil end
        local key = type(request) == 'table' and request[definition.requestKey] or nil
        if not validOwner(owner) or not validEpoch(epoch) or type(key) ~= 'string' then
            return nil, Foundation.domainError('REGISTRY_ENTRY_INVALID',
                'The registry refresh context is invalid.')
        end
        local synchronized = synchronizedOwners[owner]
        if not synchronized or not synchronized.active or synchronized.epoch ~= epoch then
            return nil, Foundation.domainError('STALE_RESOURCE',
                'The extension registry owner synchronization is not active.')
        end
        if type(committedMutations) ~= 'table' or #committedMutations ~= 1
            or type(committedMutations[1]) ~= 'table' then
            return nil, Foundation.domainError('REGISTRY_ENTRY_INVALID',
                'The committed registry refresh envelope is invalid.')
        end
        local committedMutation = committedMutations[1]
        if committedMutation.registry ~= definition.registry
            or committedMutation.owner ~= owner
            or committedMutation.epoch ~= epoch
            or committedMutation.generation ~= synchronized.generation then
            return nil, Foundation.domainError('STALE_RESOURCE',
                'The committed registry mutation belongs to an inactive generation.')
        end
        local sql, parameters = definition.sql, { key }
        if type(definition.query) == 'function' then
            sql, parameters = definition.query(request)
        end
        if type(sql) ~= 'string' or type(parameters) ~= 'table' then
            return nil, Foundation.domainError('REGISTRY_ENTRY_INVALID',
                'The registry refresh query is invalid.')
        end
        local rows = query(sql, parameters)
        local row = type(rows) == 'table' and rows[1] or nil
        if not row or row.owner_resource ~= owner or tonumber(row.owner_epoch) ~= epoch then
            return nil, Foundation.domainError('STALE_RESOURCE',
                'The committed registry row no longer belongs to the calling owner epoch.')
        end
        synchronized = synchronizedOwners[owner]
        if not synchronized or not synchronized.active or synchronized.epoch ~= epoch then
            return nil, Foundation.domainError('STALE_RESOURCE',
                'The extension registry owner synchronization ended before refresh.')
        end
        local registryKey = type(definition.key) == 'function'
            and definition.key(row) or definition.prefix .. key
        if committedMutation.key ~= registryKey then
            return nil, Foundation.domainError('REGISTRY_ENTRY_INVALID',
                'The committed registry mutation key does not match its canonical row.')
        end
        return self:apply({
            registry = definition.registry, owner = owner, epoch = epoch,
            generation = committedMutation.generation,
            key = registryKey, value = definition.value(row)
        })
    end
    local hydrationQueries = {
        {
            registry = 'groupTypes', prefix = 'group_type:', limit = 1025,
            sql = [[SELECT group_type.public_id,
                    group_type.type_key AS registry_key,
                    group_type.owner_resource, group_type.owner_epoch,
                    display_name, schema_version, create_permission,
                    membership_limit, active_membership_limit, version
                FROM synex_group_types AS group_type
                INNER JOIN synex_group_registry_owner_syncs AS owner_sync
                    ON owner_sync.owner_resource = group_type.owner_resource
                    AND owner_sync.owner_epoch = group_type.owner_epoch
                    AND owner_sync.active = 1
                WHERE group_type.status = 'active'
                ORDER BY group_type.type_key ASC LIMIT 1025]],
            value = function(row)
                return {
                    publicId = row.public_id, key = row.registry_key,
                    label = row.display_name, schemaVersion = tonumber(row.schema_version),
                    createPermission = row.create_permission,
                    maxMembers = tonumber(row.membership_limit),
                    maxActiveMembers = tonumber(row.active_membership_limit),
                    version = tonumber(row.version)
                }
            end
        },
        {
            registry = 'relationTypes', prefix = 'relation_type:', limit = 1025,
            sql = [[SELECT relation_type.public_id,
                    relation_type.type_key AS registry_key,
                    relation_type.owner_resource, relation_type.owner_epoch,
                    display_name, direction, schema_version, version
                FROM synex_group_relation_types AS relation_type
                INNER JOIN synex_group_registry_owner_syncs AS owner_sync
                    ON owner_sync.owner_resource = relation_type.owner_resource
                    AND owner_sync.owner_epoch = relation_type.owner_epoch
                    AND owner_sync.active = 1
                WHERE relation_type.status = 'active'
                ORDER BY relation_type.type_key ASC LIMIT 1025]],
            value = function(row)
                return {
                    publicId = row.public_id, key = row.registry_key,
                    label = row.display_name, direction = row.direction,
                    schemaVersion = tonumber(row.schema_version), version = tonumber(row.version)
                }
            end
        },
        {
            registry = 'dutyStates', prefix = 'duty_state:', limit = 257,
            sql = [[SELECT duty_state.public_id,
                    duty_state.state_key AS registry_key,
                    duty_state.owner_resource, duty_state.owner_epoch,
                    display_name, counts_as_on_duty, schema_version, version
                FROM synex_group_duty_states AS duty_state
                INNER JOIN synex_group_registry_owner_syncs AS owner_sync
                    ON owner_sync.owner_resource = duty_state.owner_resource
                    AND owner_sync.owner_epoch = duty_state.owner_epoch
                    AND owner_sync.active = 1
                WHERE duty_state.status = 'active'
                ORDER BY duty_state.state_key ASC LIMIT 257]],
            value = function(row)
                return {
                    publicId = row.public_id, key = row.registry_key,
                    label = row.display_name,
                    countsAsOnDuty = tonumber(row.counts_as_on_duty) == 1,
                    schemaVersion = tonumber(row.schema_version), version = tonumber(row.version)
                }
            end
        },
        {
            registry = 'attributeSchemas', limit = 2049,
            sql = [[SELECT schema.public_id, schema.group_type_id,
                    schema.attribute_key AS registry_key,
                    schema.namespace, schema.owner_resource, schema.owner_epoch,
                    schema.value_kind, schema.visibility, schema.required_value,
                    schema.has_default, schema.capability,
                    schema.schema_version, schema.version,
                    group_type.type_key AS group_type_key
                FROM synex_group_attribute_schemas AS schema
                INNER JOIN synex_group_registry_owner_syncs AS owner_sync
                    ON owner_sync.owner_resource = schema.owner_resource
                    AND owner_sync.owner_epoch = schema.owner_epoch
                    AND owner_sync.active = 1
                LEFT JOIN synex_group_types AS group_type
                    ON group_type.id = schema.group_type_id
                WHERE schema.status = 'active'
                    AND (schema.group_type_id IS NULL OR group_type.status = 'active')
                ORDER BY schema.group_type_scope_id ASC,
                    schema.namespace ASC, schema.attribute_key ASC LIMIT 2049]],
            key = function(row)
                if row.group_type_key == nil and row.group_type_id ~= nil then return nil end
                local scope = row.group_type_key ~= nil
                    and 'type:' .. tostring(row.group_type_key) or 'global'
                return 'attribute_schema:' .. scope .. ':'
                    .. tostring(row.namespace) .. ':' .. tostring(row.registry_key)
            end,
            value = function(row)
                return {
                    publicId = row.public_id,
                    namespace = row.namespace,
                    key = row.registry_key,
                    scope = row.group_type_key ~= nil
                        and 'type:' .. tostring(row.group_type_key) or 'global',
                    groupType = row.group_type_key,
                    type = row.value_kind,
                    visibility = row.visibility,
                    capability = row.capability,
                    required = tonumber(row.required_value) == 1,
                    hasDefault = tonumber(row.has_default) == 1,
                    schemaVersion = tonumber(row.schema_version),
                    ownerEpoch = tonumber(row.owner_epoch),
                    version = tonumber(row.version)
                }
            end
        }
    }
    function coordinator:hydrate()
        appliedSyncGenerations = {}
        synchronizedOwners = {}
        local syncRows = query([[SELECT `owner_resource`, `owner_epoch`, `generation`, `active`
            FROM `synex_group_registry_owner_syncs`
            ORDER BY `owner_resource` ASC LIMIT 4097]], {})
        if type(syncRows) ~= 'table' or #syncRows >= 4097 then
            return nil, Foundation.domainError('REGISTRY_CAPACITY_EXCEEDED',
                'The persistent registry synchronization set exceeds its configured capacity.')
        end
        for _, row in ipairs(syncRows) do
            local owner = type(row) == 'table' and row.owner_resource or nil
            local epoch = type(row) == 'table' and tonumber(row.owner_epoch) or nil
            local generation = type(row) == 'table' and tonumber(row.generation) or nil
            local active = type(row) == 'table' and tonumber(row.active) or nil
            if not validOwner(owner) or not validEpoch(epoch) or not generation
                or math.type(generation) ~= 'integer' or generation < 1
                or active ~= 0 and active ~= 1 then
                return nil, Foundation.domainError('REGISTRY_ENTRY_INVALID',
                    'A persistent registry synchronization session is invalid.')
            end
            appliedSyncGenerations[owner] = generation
            synchronizedOwners[owner] = {
                epoch = epoch, generation = generation, active = active == 1
            }
            local stateApplied, stateError = setOwnerActive(owner, epoch, active == 1)
            if not stateApplied then return nil, stateError end
        end
        local ownerRows = query([[SELECT `owner_resource`, `owner_epoch` FROM (
                SELECT `owner_resource`, `owner_epoch`
                    FROM `synex_group_types` WHERE `status` = 'active'
                UNION
                SELECT `owner_resource`, `owner_epoch`
                    FROM `synex_group_relation_types` WHERE `status` = 'active'
                UNION
                SELECT `owner_resource`, `owner_epoch`
                    FROM `synex_group_duty_states` WHERE `status` = 'active'
                UNION
                SELECT `owner_resource`, `owner_epoch`
                    FROM `synex_group_attribute_schemas` WHERE `status` = 'active'
            ) AS `active_registry_owners`
            ORDER BY `owner_resource` ASC, `owner_epoch` ASC LIMIT 4097]], {})
        if type(ownerRows) ~= 'table' or #ownerRows >= 4097 then
            return nil, Foundation.domainError('REGISTRY_CAPACITY_EXCEEDED',
                'The persistent extension owner set exceeds its configured capacity.')
        end
        for _, row in ipairs(ownerRows) do
            local owner = type(row) == 'table' and row.owner_resource or nil
            local epoch = type(row) == 'table' and tonumber(row.owner_epoch) or nil
            if not validOwner(owner) or not validEpoch(epoch) then
                return nil, Foundation.domainError('REGISTRY_ENTRY_INVALID',
                    'A persistent extension registry owner is invalid.')
            end
            local synchronized = synchronizedOwners[owner]
            local stateOk, running = pcall(isOwnerRunning, owner)
            if not stateOk or type(running) ~= 'boolean' then
                return nil, Foundation.domainError('DATABASE_ERROR',
                    'An extension registry owner state could not be resolved.', true)
            end
            if not running or not synchronized or not synchronized.active
                or synchronized.epoch ~= epoch then
                local disabled, disableError = self:disableOwner(owner, epoch)
                if not disabled then return nil, disableError end
            end
        end
        local installed = 0
        for _, definition in ipairs(hydrationQueries) do
            local rows = query(definition.sql, {})
            if type(rows) ~= 'table' or #rows >= definition.limit then
                return nil, Foundation.domainError('REGISTRY_CAPACITY_EXCEEDED',
                    'A persistent extension registry exceeds its configured capacity.', false, {
                        registry = definition.registry
                    })
            end
            for _, row in ipairs(rows) do
                local epoch = tonumber(row.owner_epoch)
                local synchronized = synchronizedOwners[row.owner_resource]
                local mutation = {
                    registry = definition.registry,
                    owner = row.owner_resource,
                    epoch = epoch,
                    generation = synchronized and synchronized.generation or nil,
                    key = type(definition.key) == 'function'
                        and definition.key(row)
                        or definition.prefix .. tostring(row.registry_key),
                    value = definition.value(row)
                }
                local registered, registrationError = self:apply(mutation)
                if not registered then return nil, registrationError end
                installed = installed + 1
            end
        end
        return { installed = installed }, nil
    end
    function coordinator:latestEpoch(owner)
        if not validOwner(owner) then
            return nil, Foundation.domainError('REGISTRY_OWNER_INVALID',
                'The extension registry owner is invalid.')
        end
        local synchronized = synchronizedOwners[owner]
        local latest = synchronized and synchronized.active and synchronized.epoch or nil
        for _, registryName in ipairs(managedRegistries) do
            local registry = registries[registryName]
            if type(registry) == 'table' and type(registry.latestEpoch) == 'function' then
                local epoch = registry:latestEpoch(owner)
                if epoch and (latest == nil or epoch > latest) then latest = epoch end
            end
        end
        return latest, nil
    end
    function coordinator:reconcileOwnerEpoch(owner, epoch)
        if not validOwner(owner) or not validEpoch(epoch) then
            return nil, Foundation.domainError('REGISTRY_OWNER_INVALID',
                'The extension registry owner epoch is invalid.')
        end
        local total, transactionError = 0, nil
        local called, committed = pcall(startTransaction, function(transactionQuery)
            for _, tableName in ipairs({
                'synex_group_types', 'synex_group_relation_types',
                'synex_group_duty_states', 'synex_group_attribute_schemas'
            }) do
                local result = transactionQuery(([=[UPDATE `%s`
                    SET `status` = 'disabled', `version` = `version` + 1
                    WHERE `owner_resource` = ? AND `owner_epoch` <> ?
                        AND `status` = 'active']=]):format(tableName), { owner, epoch })
                local changed = affectedRows(result)
                if changed == nil then
                    transactionError = Foundation.domainError('DATABASE_ERROR',
                        'Extension registry owner cleanup returned an invalid result.', true)
                    return false
                end
                total = total + changed
            end
            return true
        end)
        if not called or committed ~= true then
            return nil, transactionError or Foundation.domainError('DATABASE_ERROR',
                'Extension registry owner cleanup could not be committed.', true)
        end
        local removed = 0
        for _, registryName in ipairs(managedRegistries) do
            local registry = registries[registryName]
            if type(registry) == 'table' and type(registry.cleanupOwnerExcept) == 'function' then
                local count, cleanupError = registry:cleanupOwnerExcept(owner, epoch)
                if count == nil then return nil, cleanupError end
                removed = removed + count
            end
        end
        return { disabled = total, removed = removed, owner = owner, epoch = epoch }, nil
    end
    function coordinator:disableOwner(owner, epoch)
        if not validOwner(owner) or epoch ~= nil and not validEpoch(epoch) then
            return nil, Foundation.domainError('REGISTRY_OWNER_INVALID',
                'The extension registry owner identity is invalid.')
        end
        -- Fence this epoch before durable cleanup yields; never hide a newer owner.
        local synchronized = synchronizedOwners[owner]
        local runtimeFenceEpoch = epoch
        if runtimeFenceEpoch == nil and synchronized then
            runtimeFenceEpoch = synchronized.epoch
        end
        if runtimeFenceEpoch ~= nil then
            if synchronized and synchronized.epoch == runtimeFenceEpoch then
                synchronized.active = false
            end
            local stateClosed, stateError = setOwnerActive(
                owner, runtimeFenceEpoch, false)
            if not stateClosed then
                return nil, Foundation.domainError('DATABASE_ERROR',
                    'Extension registry runtime fencing could not be completed.', true)
            end
        end
        local total, transactionError = 0, nil
        local cleanupEpoch = epoch
        local called, committed = pcall(startTransaction, function(transactionQuery)
            local syncRows = transactionQuery([[SELECT `owner_epoch`, `generation`, `active`
                FROM `synex_group_registry_owner_syncs`
                WHERE `owner_resource` = ? FOR UPDATE]], { owner })
            if type(syncRows) ~= 'table' then
                transactionError = Foundation.domainError('DATABASE_ERROR',
                    'Extension registry owner synchronization could not be locked.', true)
                return false
            end
            local sync = syncRows[1]
            if sync then
                local storedEpoch = tonumber(sync.owner_epoch)
                local generation = tonumber(sync.generation)
                local active = tonumber(sync.active)
                if not validEpoch(storedEpoch) or not generation
                    or math.type(generation) ~= 'integer' or generation < 1
                    or active ~= 0 and active ~= 1 then
                    transactionError = Foundation.domainError('DATABASE_ERROR',
                        'Extension registry owner synchronization is invalid.', true)
                    return false
                end
                if cleanupEpoch == nil then cleanupEpoch = storedEpoch end
                if cleanupEpoch == storedEpoch and active == 1 then
                    local tombstoned = affectedRows(transactionQuery(
                        [[UPDATE `synex_group_registry_owner_syncs`
                            SET `active` = 0, `updated_at` = CURRENT_TIMESTAMP(6)
                            WHERE `owner_resource` = ? AND `owner_epoch` = ?
                                AND `active` = 1]], { owner, storedEpoch }))
                    if tombstoned ~= 1 then
                        transactionError = Foundation.domainError('DATABASE_ERROR',
                            'Extension registry owner synchronization could not be closed.', true)
                        return false
                    end
                end
            end
            for _, tableName in ipairs({
                'synex_group_types', 'synex_group_relation_types',
                'synex_group_duty_states', 'synex_group_attribute_schemas'
            }) do
                local predicate = cleanupEpoch == nil
                    and '`owner_resource` = ?' or '`owner_resource` = ? AND `owner_epoch` = ?'
                local parameters = cleanupEpoch == nil
                    and { owner } or { owner, cleanupEpoch }
                local result = transactionQuery(([=[UPDATE `%s`
                    SET `status` = 'disabled', `version` = `version` + 1
                    WHERE %s AND `status` = 'active']=]):format(tableName, predicate), parameters)
                local changed = affectedRows(result)
                if changed == nil then
                    transactionError = Foundation.domainError('DATABASE_ERROR',
                        'Extension registry owner cleanup returned an invalid result.', true)
                    return false
                end
                total = total + changed
            end
            return true
        end)
        if not called or committed ~= true then
            return nil, transactionError or Foundation.domainError('DATABASE_ERROR',
                'Extension registry owner cleanup could not be committed.', true)
        end
        if synchronized and (cleanupEpoch == nil or synchronized.epoch == cleanupEpoch) then
            synchronized.active = false
        end
        if cleanupEpoch ~= nil and cleanupEpoch ~= runtimeFenceEpoch then
            local stateClosed, stateError = setOwnerActive(owner, cleanupEpoch, false)
            if not stateClosed then
                return nil, Foundation.domainError('DATABASE_ERROR',
                    'Extension registry runtime fencing could not be completed.', true)
            end
        end
        local removed = 0
        local cleanupFailure
        for _, registryName in ipairs(managedRegistries) do
            local registry = registries[registryName]
            if type(registry) == 'table' and type(registry.cleanupOwner) == 'function' then
                local count, cleanupError = registry:cleanupOwner(owner, cleanupEpoch)
                if count == nil then
                    cleanupFailure = cleanupFailure or cleanupError
                else
                    removed = removed + count
                end
            end
        end
        if cleanupFailure then
            return nil, Foundation.domainError('DATABASE_ERROR',
                'Extension registry runtime cleanup could not be completed.', true)
        end
        return { disabled = total, removed = removed, owner = owner,
            epoch = cleanupEpoch }, nil
    end
    return coordinator
end
return createCoordinator
end
