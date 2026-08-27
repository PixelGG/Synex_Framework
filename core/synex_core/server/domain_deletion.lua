local factories = assert(SynexCoreFactories, 'factories must be loaded first')

factories.domainDeletion = function(deps)
    local platform = assert(deps.platform, 'domain deletion requires platform')
    local foundation = assert(deps.foundation, 'domain deletion requires foundation')
    local database = assert(deps.database, 'domain deletion requires database')
    local owners = assert(deps.owners, 'domain deletion requires owners')
    local leases = assert(deps.leases, 'domain deletion requires leases')
    local instances = assert(deps.instances, 'domain deletion requires instances')
    local sha256 = assert(deps.sha256, 'domain deletion requires hashing')
    local instanceId = assert(deps.instanceId, 'domain deletion requires instance ID')
    local logger = foundation.logger
    local metrics = foundation.metrics
    local providers = {}
    local maximumProvidersPerDomain = 64
    local maximumRetainedPlans = 10000
    local maximumPlansPerOwner = 1000
    local terminalRetentionDays = 30
    local maximumExactInteger = 9007199254740991
    local decisions = { allow = true, block = true, delete = true, anonymize = true, retain = true }
    local terminalPlanStates = { completed = true, blocked = true, failed = true }

    local function exactObject(value, allowed)
        if type(value) ~= 'table' or getmetatable(value) ~= nil then return false end
        for key in pairs(value) do
            if type(key) ~= 'string' or not allowed[key] then return false end
        end
        return true
    end

    local function validDomain(value)
        return type(value) == 'string' and #value >= 2 and #value <= 32
            and value:match('^[a-z][a-z0-9_]*$') ~= nil
    end

    local function validOwner(value)
        return type(value) == 'string' and #value <= 64
            and value:match('^synex_[a-z0-9_]+$') ~= nil
    end

    local function validProviderName(value)
        return type(value) == 'string' and #value >= 2 and #value <= 64
            and value:match('^[a-z][a-z0-9_.%-]*$') ~= nil
            and not value:match('[._%-]$') and not value:match('[._%-][._%-]')
    end

    local function validSubject(value)
        return type(value) == 'string' and #value >= 1 and #value <= 128
            and value:match('^[A-Za-z0-9][A-Za-z0-9_.:%-]*$') ~= nil
    end

    local function affectedRows(value)
        local parsed = type(value) == 'table' and tonumber(value.affectedRows) or tonumber(value)
        if not parsed or math.type(parsed) ~= 'integer' or parsed < 0
            or parsed > maximumExactInteger then return nil end
        return parsed
    end

    local function lockPlanCapacity(query, owner)
        local globalRows = query([[SELECT `entry_count`, `global_limit`, `owner_limit`
            FROM `synex_domain_deletion_plan_capacity`
            WHERE `singleton_id` = 1 FOR UPDATE]]) or {}
        local global = globalRows[1]
        local globalCount = global and tonumber(global.entry_count) or nil
        local globalLimit = global and tonumber(global.global_limit) or nil
        local ownerLimit = global and tonumber(global.owner_limit) or nil
        if #globalRows ~= 1 or not globalCount or math.type(globalCount) ~= 'integer'
            or not globalLimit or math.type(globalLimit) ~= 'integer'
            or not ownerLimit or math.type(ownerLimit) ~= 'integer'
            or globalCount < 0 or globalLimit < 1 or globalLimit > maximumRetainedPlans
            or ownerLimit < 1 or ownerLimit > maximumPlansPerOwner
            or ownerLimit > globalLimit or globalCount > globalLimit then
            return nil, foundation.error('DELETION_PLAN_CAPACITY_INVALID',
                'Deletion plan capacity is invalid.')
        end
        local ownerCreated = affectedRows(query(
            [[INSERT IGNORE INTO `synex_domain_deletion_plan_owner_capacity`
            (`requester_owner`, `entry_count`) VALUES (?, 0)]], { owner }))
        if ownerCreated ~= 0 and ownerCreated ~= 1 then
            return nil, foundation.error('DELETION_PLAN_CAPACITY_INVALID',
                'Deletion plan owner capacity could not be initialized safely.')
        end
        local ownerRows = query([[SELECT `entry_count`
            FROM `synex_domain_deletion_plan_owner_capacity`
            WHERE `requester_owner` = ? FOR UPDATE]], { owner }) or {}
        local ownerCount = ownerRows[1] and tonumber(ownerRows[1].entry_count) or nil
        if #ownerRows ~= 1 or not ownerCount or math.type(ownerCount) ~= 'integer'
            or ownerCount < 0 or ownerCount > ownerLimit or ownerCount > globalCount then
            return nil, foundation.error('DELETION_PLAN_CAPACITY_INVALID',
                'Deletion plan owner capacity is invalid.')
        end
        return {
            globalCount = globalCount,
            globalLimit = globalLimit,
            ownerCount = ownerCount,
            ownerLimit = ownerLimit
        }, nil
    end

    local function canonical(value, maximumBytes)
        local active, keys = {}, 0
        local function encode(candidate, depth)
            local candidateType = type(candidate)
            if candidateType == 'nil' then return 'null' end
            if candidateType == 'boolean' or candidateType == 'string' then
                local ok, encoded = pcall(platform.jsonEncode, candidate)
                if not ok or type(encoded) ~= 'string' then error('JSON encoding failed', 0) end
                return encoded
            end
            if candidateType == 'number' then
                if candidate ~= candidate or candidate == math.huge or candidate == -math.huge then
                    error('JSON number is not finite', 0)
                end
                return tostring(candidate)
            end
            local kind = candidateType == 'table' and foundation.jsonContainerKind(candidate) or nil
            if candidateType ~= 'table' or not kind or depth > 10 or active[candidate] then
                error('JSON value is not a bounded acyclic container', 0)
            end
            active[candidate] = true
            local count, maximumIndex, keyType = 0, 0, nil
            for key in next, candidate do
                keys = keys + 1
                count = count + 1
                if keys > 512 then active[candidate] = nil error('JSON key limit exceeded', 0) end
                local currentType = type(key)
                if currentType == 'number' and math.type(key) == 'integer' and key >= 1 then
                    maximumIndex = math.max(maximumIndex, key)
                elseif currentType ~= 'string' or #key < 1 or #key > 128 then
                    active[candidate] = nil error('JSON key is invalid', 0)
                end
                if keyType and keyType ~= currentType then
                    active[candidate] = nil error('JSON container mixes key types', 0)
                end
                keyType = currentType
            end
            local encoded
            if keyType == 'number' or (count == 0 and kind == 'array') then
                if kind == 'object' or maximumIndex ~= count then
                    active[candidate] = nil error('JSON array is invalid', 0)
                end
                local items = {}
                for index = 1, count do items[index] = encode(candidate[index], depth + 1) end
                encoded = '[' .. table.concat(items, ',') .. ']'
            else
                if kind == 'array' then active[candidate] = nil error('JSON object is invalid', 0) end
                local ordered = {}
                for key in next, candidate do ordered[#ordered + 1] = key end
                table.sort(ordered)
                local properties = {}
                for index, key in ipairs(ordered) do
                    local ok, encodedKey = pcall(platform.jsonEncode, key)
                    if not ok or type(encodedKey) ~= 'string' then
                        active[candidate] = nil error('JSON key encoding failed', 0)
                    end
                    properties[index] = encodedKey .. ':' .. encode(candidate[key], depth + 1)
                end
                encoded = '{' .. table.concat(properties, ',') .. '}'
            end
            active[candidate] = nil
            return encoded
        end
        local ok, encoded = pcall(encode, value, 1)
        if not ok or type(encoded) ~= 'string' then
            return nil, foundation.error('INVALID_DELETION_PAYLOAD',
                'Deletion data must be bounded plain JSON.')
        end
        if #encoded > maximumBytes then
            return nil, foundation.error('DELETION_PAYLOAD_TOO_LARGE',
                'Deletion data exceeds its supported byte limit.')
        end
        return encoded, nil
    end

    local function decode(value, maximumBytes)
        if type(value) ~= 'string' or #value > maximumBytes then
            return nil, foundation.error('DELETION_PLAN_CORRUPT',
                'Persisted deletion data is outside its supported bounds.')
        end
        local ok, decoded = pcall(platform.jsonDecode, value)
        if not ok then
            return nil, foundation.error('DELETION_PLAN_CORRUPT',
                'Persisted deletion data is invalid JSON.')
        end
        local verified, verifyError = canonical(decoded, maximumBytes)
        if not verified then return nil, verifyError end
        return foundation.copy(decoded), nil
    end

    local function providerKey(domain, owner, name)
        return domain .. ':' .. owner .. ':' .. name
    end

    local function currentProvider(domain, owner, name, schemaVersion)
        local provider = providers[providerKey(domain, owner, name)]
        if not provider or not owners:isCurrent(owner, provider.epoch)
            or schemaVersion ~= nil and provider.schemaVersion ~= schemaVersion then return nil end
        return provider
    end

    local service = {}

    function service:registerProvider(owner, epoch, definition)
        if not validOwner(owner) or not owners:isCurrent(owner, epoch)
            or not exactObject(definition, {
                domain = true, name = true, schemaVersion = true,
                preflight = true, execute = true
            }) or not validDomain(definition.domain) or not validProviderName(definition.name)
            or type(definition.schemaVersion) ~= 'number'
            or math.type(definition.schemaVersion) ~= 'integer'
            or definition.schemaVersion < 1 or definition.schemaVersion > 65535
            or not foundation.isCallable(definition.preflight)
            or not foundation.isCallable(definition.execute) then
            return nil, foundation.error('INVALID_DELETION_PROVIDER',
                'Deletion provider definition is invalid.')
        end
        local key = providerKey(definition.domain, owner, definition.name)
        if providers[key] then
            return nil, foundation.error('DUPLICATE_DELETION_PROVIDER',
                'The deletion provider is already bound for this owner epoch.')
        end
        local domainError
        local committed, transactionError = database:withTransaction(function(query)
            local domainInserted = affectedRows(query(
                [[INSERT IGNORE INTO `synex_domain_deletion_domains`
                (`domain_name`, `provider_count`) VALUES (?, 0)]], { definition.domain }))
            if domainInserted ~= 0 and domainInserted ~= 1 then
                domainError = foundation.error('DELETION_PROVIDER_PERSISTENCE_FAILED',
                    'The deletion domain catalog could not be initialized safely.')
                return false
            end
            local domains = query([[SELECT `provider_count`
                FROM `synex_domain_deletion_domains`
                WHERE `domain_name` = ? FOR UPDATE]], { definition.domain }) or {}
            local providerCount = domains[1] and tonumber(domains[1].provider_count) or nil
            if #domains ~= 1 or not providerCount or math.type(providerCount) ~= 'integer'
                or providerCount < 0 or providerCount > maximumProvidersPerDomain then
                domainError = foundation.error('DELETION_PROVIDER_PERSISTENCE_FAILED',
                    'The deletion domain provider counter is invalid.')
                return false
            end
            local rows = query([[SELECT `provider_owner`, `provider_name`, `schema_version`
                FROM `synex_domain_deletion_providers`
                WHERE `domain_name` = ? AND `provider_owner` = ? AND `provider_name` = ?
                LIMIT 1 FOR UPDATE]], { definition.domain, owner, definition.name }) or {}
            if #rows > 1 then
                domainError = foundation.error('DELETION_PROVIDER_PERSISTENCE_FAILED',
                    'The deletion provider identity is not unique.')
                return false
            end
            local existing = rows[1] ~= nil
            local persistedSchema = existing and tonumber(rows[1].schema_version) or nil
            if existing and (not persistedSchema or math.type(persistedSchema) ~= 'integer'
                or persistedSchema < 1 or persistedSchema > 65535) then
                domainError = foundation.error('DELETION_PROVIDER_PERSISTENCE_FAILED',
                    'The persisted deletion provider schema is invalid.')
                return false
            end
            if providerCount >= maximumProvidersPerDomain and not existing then
                domainError = foundation.error('DELETION_PROVIDER_LIMIT',
                    'The deletion domain reached its provider limit.')
                return false
            end
            if persistedSchema and persistedSchema ~= definition.schemaVersion then
                local incompatibleActions = query([[SELECT `action`.`plan_id`,
                        `action`.`provider_schema_version`
                    FROM `synex_domain_deletion_actions` AS `action`
                    INNER JOIN `synex_domain_deletion_plans` AS `plan`
                        ON `plan`.`plan_id` = `action`.`plan_id`
                    WHERE `plan`.`domain_name` = ? AND `action`.`provider_owner` = ?
                        AND `action`.`provider_name` = ? AND `action`.`state` = 'pending'
                        AND `plan`.`state` IN ('pending', 'executing')
                        AND `action`.`provider_schema_version` <> ?
                    ORDER BY `action`.`plan_id`, `action`.`action_index`
                    LIMIT 1]], {
                    definition.domain, owner, definition.name, definition.schemaVersion
                }) or {}
                if #incompatibleActions > 1 then
                    domainError = foundation.error('DELETION_PROVIDER_PERSISTENCE_FAILED',
                        'The deletion provider compatibility lookup returned an invalid result.')
                    return false
                end
                local incompatible = incompatibleActions[1]
                if incompatible then
                    local requiredVersion = tonumber(incompatible.provider_schema_version)
                    if type(incompatible.plan_id) ~= 'string' or not requiredVersion
                        or math.type(requiredVersion) ~= 'integer'
                        or requiredVersion < 1 or requiredVersion > 65535 then
                        domainError = foundation.error('DELETION_PROVIDER_PERSISTENCE_FAILED',
                            'A pending deletion provider binding is invalid.')
                        return false
                    end
                    domainError = foundation.error('DELETION_PROVIDER_SCHEMA_IN_USE',
                        'A pending deletion plan still requires another provider schema version.', {
                            details = {
                                domain = definition.domain,
                                owner = owner,
                                provider = definition.name,
                                planId = incompatible.plan_id,
                                requiredSchemaVersion = requiredVersion,
                                requestedSchemaVersion = definition.schemaVersion
                            }
                        })
                    return false
                end
            end
            local affected = affectedRows(query([[INSERT INTO `synex_domain_deletion_providers`
                (`domain_name`, `provider_owner`, `provider_name`, `schema_version`)
                VALUES (?, ?, ?, ?)
                ON DUPLICATE KEY UPDATE `schema_version` = VALUES(`schema_version`),
                    `last_bound_at` = CURRENT_TIMESTAMP(6)]], {
                definition.domain, owner, definition.name, definition.schemaVersion
            }))
            if affected == nil or affected > 2 then
                domainError = foundation.error('DELETION_PROVIDER_PERSISTENCE_FAILED',
                    'The deletion provider catalog could not be updated safely.')
                return false
            end
            if not existing then
                local counted = affectedRows(query([[UPDATE `synex_domain_deletion_domains`
                    SET `provider_count` = `provider_count` + 1
                    WHERE `domain_name` = ? AND `provider_count` = ?
                        AND `provider_count` < 64]], { definition.domain, providerCount }))
                if counted ~= 1 then
                    domainError = foundation.error('DELETION_PROVIDER_PERSISTENCE_FAILED',
                        'The deletion domain provider counter changed unexpectedly.')
                    return false
                end
            end
            return true
        end)
        if not committed then return nil, domainError or transactionError end
        local record = {
            owner = owner,
            epoch = epoch,
            domain = definition.domain,
            name = definition.name,
            schemaVersion = definition.schemaVersion,
            preflight = definition.preflight,
            execute = definition.execute
        }
        providers[key] = record
        local tracked, trackError = owners:track(owner, epoch, 'domain-deletion-provider', key,
            function()
                if providers[key] == record then providers[key] = nil end
            end)
        if not tracked then
            providers[key] = nil
            return nil, trackError
        end
        return {
            token = key,
            domain = definition.domain,
            name = definition.name,
            schemaVersion = definition.schemaVersion,
            ownerEpoch = epoch
        }, nil
    end

    local function invoke(provider, handler, request, phase)
        if not provider or not owners:isCurrent(provider.owner, provider.epoch) then
            return nil, foundation.error('DELETION_PROVIDER_UNAVAILABLE',
                'A required deletion provider is not bound to a current owner epoch.', {
                    retryable = true
                })
        end
        local invocation = { cancelled = false, reason = nil }
        local operationToken = owners:beginOperation(
            provider.owner, provider.epoch, function(reason)
                invocation.cancelled = true
                invocation.reason = tostring(reason or 'provider owner quiesced')
            end)
        if not operationToken then
            return nil, foundation.error('DELETION_PROVIDER_UNAVAILABLE',
                'A required deletion provider is not available for invocation.', {
                    retryable = true
                })
        end
        local invoked, value, providerError = foundation.safeCall(function()
            return foundation.withContext({
                caller = provider.owner,
                provider = provider.owner,
                contract = 'DomainDeletions.' .. phase
            }, handler, foundation.readonly(request))
        end)
        local operationFinished = owners:finishOperation(
            provider.owner, provider.epoch, operationToken)
        if invocation.cancelled or not operationFinished
            or not owners:isCurrent(provider.owner, provider.epoch) then
            return nil, foundation.error('DELETION_PROVIDER_UNAVAILABLE',
                'A deletion provider restarted during invocation.', {
                    retryable = true,
                    details = { reason = invocation.reason }
                })
        end
        if not invoked then
            logger:error('domain deletion provider raised an exception', {
                owner = provider.owner,
                domain = provider.domain,
                provider = provider.name,
                phase = phase,
                code = foundation.failureCode(value, 'DELETION_PROVIDER_EXCEPTION')
            })
            return nil, foundation.error('DELETION_PROVIDER_FAILED',
                'A deletion provider failed.', { retryable = true })
        end
        if providerError then
            return nil, type(providerError) == 'table' and providerError
                or foundation.error('DELETION_PROVIDER_FAILED',
                    'A deletion provider rejected the operation.', { retryable = true })
        end
        return value, nil
    end

    local function validateDecision(value)
        if not exactObject(value, { decision = true, reason = true, metadata = true })
            or not decisions[value.decision]
            or value.reason ~= nil and (type(value.reason) ~= 'string'
                or #value.reason < 1 or #value.reason > 512) then
            return nil, foundation.error('INVALID_DELETION_DECISION',
                'A deletion provider returned an invalid decision.')
        end
        local metadata = value.metadata or {}
        local metadataJson, metadataError = canonical(metadata, 4096)
        if not metadataJson then return nil, metadataError end
        return {
            decision = value.decision,
            reason = value.reason,
            metadata = foundation.copy(metadata),
            metadataJson = metadataJson
        }, nil
    end

    local function loadPlan(planId, requesterOwner)
        if type(planId) ~= 'string' or #planId < 1 or #planId > 48
            or not planId:match('^[a-z0-9_]+$') then
            return nil, foundation.error('INVALID_DELETION_PLAN',
                'Deletion plan identity is invalid.')
        end
        if requesterOwner ~= nil and not validOwner(requesterOwner) then
            return nil, foundation.error('DELETION_PLAN_NOT_FOUND',
                'The deletion plan does not exist.')
        end
        local planSql = [[SELECT `plan_id`, `domain_name`, `subject_id`,
                `requester_owner`, `state`, `version`, `attempt_count`, `failure_code`,
                `request_context_json`, `reason`, `created_at`, `updated_at`, `completed_at`,
                `purge_after`
            FROM `synex_domain_deletion_plans` WHERE `plan_id` = ?]]
        local planParameters = { planId }
        if requesterOwner ~= nil then
            planSql = planSql .. ' AND `requester_owner` = ?'
            planParameters[2] = requesterOwner
        end
        planSql = planSql .. ' LIMIT 1'
        local plans, planError = database:query(planSql, planParameters)
        if not plans then return nil, planError end
        if #plans ~= 1 then
            return nil, foundation.error('DELETION_PLAN_NOT_FOUND',
                'The deletion plan does not exist.')
        end
        local row = plans[1]
        local version = tonumber(row.version)
        local attempts = tonumber(row.attempt_count)
        if not version or math.type(version) ~= 'integer' or version < 1
            or version > maximumExactInteger or not attempts
            or math.type(attempts) ~= 'integer' or attempts < 0 then
            return nil, foundation.error('DELETION_PLAN_CORRUPT',
                'Persisted deletion plan counters are invalid.')
        end
        local context, contextError = decode(row.request_context_json, 16384)
        if not context then return nil, contextError end
        local actions, actionError = database:query([[SELECT `action_index`, `provider_owner`,
                `provider_name`, `provider_schema_version`, `decision`, `decision_reason`,
                `metadata_json`,
                `state`, `version`, `attempt_count`, `failure_code`, `last_attempt_at`,
                `completed_at`
            FROM `synex_domain_deletion_actions` WHERE `plan_id` = ?
            ORDER BY `action_index` LIMIT 256]], { planId })
        if not actions then return nil, actionError end
        local resultActions = {}
        for index, action in ipairs(actions) do
            local metadata, metadataError = decode(action.metadata_json, 4096)
            if not metadata then return nil, metadataError end
            local actionIndex = tonumber(action.action_index)
            local actionVersion = tonumber(action.version)
            local schemaVersion = tonumber(action.provider_schema_version)
            if actionIndex ~= index or not actionVersion
                or math.type(actionVersion) ~= 'integer' or actionVersion < 1
                or not schemaVersion or math.type(schemaVersion) ~= 'integer'
                or schemaVersion < 1 or schemaVersion > 65535 then
                return nil, foundation.error('DELETION_PLAN_CORRUPT',
                    'Persisted deletion actions are invalid.')
            end
            resultActions[index] = {
                index = actionIndex,
                providerOwner = action.provider_owner,
                providerName = action.provider_name,
                providerSchemaVersion = schemaVersion,
                decision = action.decision,
                decisionReason = action.decision_reason,
                metadata = metadata,
                state = action.state,
                version = actionVersion,
                attemptCount = tonumber(action.attempt_count) or 0,
                failureCode = action.failure_code,
                lastAttemptAt = action.last_attempt_at,
                completedAt = action.completed_at
            }
        end
        return {
            planId = row.plan_id,
            domain = row.domain_name,
            subjectId = row.subject_id,
            requesterOwner = row.requester_owner,
            state = row.state,
            version = version,
            attemptCount = attempts,
            failureCode = row.failure_code,
            context = context,
            reason = row.reason,
            actions = resultActions,
            createdAt = row.created_at,
            updatedAt = row.updated_at,
            completedAt = row.completed_at,
            purgeAfter = row.purge_after
        }, nil
    end

    local function requesterCurrent(owner, epoch)
        if not validOwner(owner) or not owners:isCurrent(owner, epoch) then
            return nil, foundation.error('STALE_RESOURCE',
                'The deletion plan owner epoch is no longer current.', { retryable = true })
        end
        return true, nil
    end

    function service:get(owner, epoch, planId)
        local current, currentError = requesterCurrent(owner, epoch)
        if not current then return nil, currentError end
        local plan, planError = loadPlan(planId, owner)
        if not plan then return nil, planError end
        current, currentError = requesterCurrent(owner, epoch)
        if not current then return nil, currentError end
        return plan, nil
    end

    function service:plan(owner, epoch, request)
        if not owners:isCurrent(owner, epoch) then
            return nil, foundation.error('STALE_RESOURCE',
                'The deletion plan owner epoch is no longer current.', { retryable = true })
        end
        if not exactObject(request, {
                domain = true, subjectId = true, idempotencyKey = true,
                context = true, reason = true
            }) or not validDomain(request.domain) or not validSubject(request.subjectId)
            or type(request.idempotencyKey) ~= 'string'
            or #request.idempotencyKey < 8 or #request.idempotencyKey > 128
            or not request.idempotencyKey:match('^[A-Za-z0-9_.:%-]+$')
            or type(request.reason) ~= 'string' or #request.reason < 1
            or #request.reason > 512 then
            return nil, foundation.error('INVALID_DELETION_REQUEST',
                'Deletion planning request is invalid.')
        end
        local singularOwner = 'synex_' .. request.domain
        local pluralOwner = singularOwner .. 's'
        if owner ~= singularOwner and owner ~= pluralOwner then
            return nil, foundation.error('DELETION_DOMAIN_FORBIDDEN',
                'Only the owning domain resource may create deletion plans.')
        end
        local context = request.context or {}
        local contextJson, contextError = canonical(context, 16384)
        if not contextJson then return nil, contextError end
        local requestEnvelope = {
            domain = request.domain,
            subjectId = request.subjectId,
            reason = request.reason,
            context = context
        }
        local requestJson, requestJsonError = canonical(requestEnvelope, 32768)
        if not requestJson then return nil, requestJsonError end
        local requestHash = sha256(requestJson)

        local replayPlanId, replayDomainError
        local replayCommitted, replayTransactionError = database:withTransaction(function(query)
            replayPlanId, replayDomainError = nil, nil
            local replayRows = query([[SELECT `plan_id`, `request_hash`
                FROM `synex_domain_deletion_plans`
                WHERE `requester_owner` = ? AND `domain_name` = ?
                    AND `idempotency_key` = ? LIMIT 1 FOR UPDATE]],
                { owner, request.domain, request.idempotencyKey }) or {}
            if #replayRows > 1 then
                replayDomainError = foundation.error('DELETION_PLAN_CORRUPT',
                    'Deletion request identity is not unique.')
                return false
            end
            if not replayRows[1] then return true end
            local capacity
            capacity, replayDomainError = lockPlanCapacity(query, owner)
            if not capacity then return false end
            if capacity.globalCount < 1 or capacity.ownerCount < 1 then
                replayDomainError = foundation.error('DELETION_PLAN_CAPACITY_INVALID',
                    'The deletion plan is absent from its capacity counters.')
                return false
            end
            if replayRows[1].request_hash ~= requestHash then
                replayDomainError = foundation.error('IDEMPOTENCY_CONFLICT',
                    'The deletion idempotency key was used with a different request.')
                return false
            end
            replayPlanId = replayRows[1].plan_id
            return true
        end)
        if not replayCommitted then
            return nil, replayDomainError or replayTransactionError
        end
        if replayPlanId then return loadPlan(replayPlanId, owner) end

        local catalog, catalogError = database:query([[SELECT `provider_owner`, `provider_name`,
                `schema_version` FROM `synex_domain_deletion_providers`
            WHERE `domain_name` = ? ORDER BY `provider_owner`, `provider_name` LIMIT 65]],
            { request.domain })
        if not catalog then return nil, catalogError end
        if #catalog < 1 then
            return nil, foundation.error('DELETION_PROVIDER_REQUIRED',
                'The deletion domain has no durable provider registrations.')
        end
        if #catalog > maximumProvidersPerDomain then
            return nil, foundation.error('DELETION_PROVIDER_LIMIT',
                'The deletion provider catalog exceeds its supported bound.')
        end
        local actions, providerBindings, blocked, pending = {}, {}, false, false
        for index, providerRow in ipairs(catalog) do
            local schemaVersion = tonumber(providerRow.schema_version)
            local provider = schemaVersion and currentProvider(request.domain,
                providerRow.provider_owner, providerRow.provider_name, schemaVersion) or nil
            if not provider then
                return nil, foundation.error('DELETION_PROVIDER_UNAVAILABLE',
                    'A durable deletion provider has not rebound after restart.', {
                        retryable = true,
                        details = {
                            owner = providerRow.provider_owner,
                            provider = providerRow.provider_name
                        }
                    })
            end
            local value, preflightError = invoke(provider, provider.preflight, {
                domain = request.domain,
                subjectId = request.subjectId,
                reason = request.reason,
                context = foundation.copy(context)
            }, 'preflight')
            if not value then return nil, preflightError end
            local decision, decisionError = validateDecision(value)
            if not decision then return nil, decisionError end
            decision.index = index
            decision.providerOwner = provider.owner
            decision.providerName = provider.name
            decision.providerSchemaVersion = provider.schemaVersion
            providerBindings[index] = provider
            blocked = blocked or decision.decision == 'block'
            pending = pending or decision.decision == 'delete'
                or decision.decision == 'anonymize'
            actions[index] = decision
        end
        if not owners:isCurrent(owner, epoch) then
            return nil, foundation.error('STALE_RESOURCE',
                'The deletion plan owner restarted during preflight.', { retryable = true })
        end
        for _, provider in ipairs(providerBindings) do
            if not owners:isCurrent(provider.owner, provider.epoch) then
                return nil, foundation.error('DELETION_PROVIDER_UNAVAILABLE',
                    'A deletion provider restarted after preflight.', { retryable = true })
            end
        end
        local planId = foundation.nextId('dplan')
        local state = blocked and 'blocked' or (pending and 'pending' or 'completed')
        local storedPlanId, domainError
        local committed, transactionError = database:withTransaction(function(query)
            storedPlanId, domainError = nil, nil
            local claimed = affectedRows(query([[INSERT IGNORE INTO
                `synex_domain_deletion_plans`
                (`plan_id`, `domain_name`, `subject_id`, `requester_owner`, `idempotency_key`,
                    `request_hash`, `request_context_json`, `reason`, `state`, `completed_at`,
                    `purge_after`)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?,
                    CASE WHEN ? IN ('blocked', 'completed')
                        THEN CURRENT_TIMESTAMP(6) ELSE NULL END,
                    CASE WHEN ? IN ('blocked', 'completed')
                        THEN TIMESTAMPADD(DAY, ?, CURRENT_TIMESTAMP(6)) ELSE NULL END)]], {
                planId, request.domain, request.subjectId, owner, request.idempotencyKey,
                requestHash, contextJson, request.reason, state, state, state,
                terminalRetentionDays
            }))
            if claimed ~= 0 and claimed ~= 1 then
                domainError = foundation.error('DELETION_PLAN_PERSISTENCE_FAILED',
                    'The deletion plan could not be claimed safely.')
                return false
            end
            local existing = query([[SELECT `plan_id`, `request_hash`
                FROM `synex_domain_deletion_plans`
                WHERE `requester_owner` = ? AND `domain_name` = ?
                    AND `idempotency_key` = ? LIMIT 1 FOR UPDATE]],
                { owner, request.domain, request.idempotencyKey }) or {}
            if #existing > 1 then
                domainError = foundation.error('DELETION_PLAN_CORRUPT',
                    'Deletion request identity is not unique.')
                return false
            end
            if not existing[1] then
                domainError = foundation.error('DELETION_PLAN_PERSISTENCE_FAILED',
                    'The deletion plan claim is not visible to its transaction.')
                return false
            end
            if claimed == 0 then
                local capacity
                capacity, domainError = lockPlanCapacity(query, owner)
                if not capacity then return false end
                if capacity.globalCount < 1 or capacity.ownerCount < 1 then
                    domainError = foundation.error('DELETION_PLAN_CAPACITY_INVALID',
                        'The deletion plan is absent from its capacity counters.')
                    return false
                end
                if existing[1].request_hash ~= requestHash then
                    domainError = foundation.error('IDEMPOTENCY_CONFLICT',
                        'The deletion idempotency key was used with a different request.')
                    return false
                end
                storedPlanId = existing[1].plan_id
                return true
            end
            if existing[1].plan_id ~= planId or existing[1].request_hash ~= requestHash then
                domainError = foundation.error('DELETION_PLAN_PERSISTENCE_FAILED',
                    'The deletion plan claim has an invalid identity.')
                return false
            end
            for _, provider in ipairs(providerBindings) do
                local catalogRows = query([[SELECT `schema_version`
                    FROM `synex_domain_deletion_providers`
                    WHERE `domain_name` = ? AND `provider_owner` = ?
                        AND `provider_name` = ? LIMIT 1 FOR UPDATE]], {
                    provider.domain, provider.owner, provider.name
                }) or {}
                local catalogVersion = catalogRows[1]
                    and tonumber(catalogRows[1].schema_version) or nil
                if #catalogRows ~= 1 or not catalogVersion
                    or math.type(catalogVersion) ~= 'integer'
                    or catalogVersion < 1 or catalogVersion > 65535 then
                    domainError = foundation.error('DELETION_PROVIDER_PERSISTENCE_FAILED',
                        'A deletion provider catalog binding is invalid.')
                    return false
                end
                if catalogVersion ~= provider.schemaVersion then
                    domainError = foundation.error('DELETION_PROVIDER_SCHEMA_CHANGED',
                        'A deletion provider schema changed during preflight.', {
                            retryable = true,
                            details = {
                                domain = provider.domain,
                                owner = provider.owner,
                                provider = provider.name,
                                expectedSchemaVersion = provider.schemaVersion,
                                actualSchemaVersion = catalogVersion
                            }
                        })
                    return false
                end
                if not owners:isCurrent(provider.owner, provider.epoch) then
                    domainError = foundation.error('DELETION_PROVIDER_UNAVAILABLE',
                        'A deletion provider restarted before its decision could be persisted.', {
                            retryable = true
                        })
                    return false
                end
            end
            local capacity
            capacity, domainError = lockPlanCapacity(query, owner)
            if not capacity then return false end
            if capacity.globalCount >= capacity.globalLimit
                or capacity.ownerCount >= capacity.ownerLimit then
                domainError = foundation.error('DELETION_PLAN_CAPACITY_EXCEEDED',
                    'Deletion plan capacity is exhausted.', {
                        details = {
                            scope = capacity.globalCount >= capacity.globalLimit
                                and 'global' or 'owner'
                        }
                    })
                return false
            end
            local globalUpdated = affectedRows(query([[UPDATE
                `synex_domain_deletion_plan_capacity`
                SET `entry_count` = `entry_count` + 1
                WHERE `singleton_id` = 1 AND `entry_count` = ?
                    AND `entry_count` < `global_limit`]], { capacity.globalCount }))
            local ownerUpdated = affectedRows(query([[UPDATE
                `synex_domain_deletion_plan_owner_capacity`
                SET `entry_count` = `entry_count` + 1
                WHERE `requester_owner` = ? AND `entry_count` = ?
                    AND `entry_count` < ?]],
                { owner, capacity.ownerCount, capacity.ownerLimit }))
            if globalUpdated ~= 1 or ownerUpdated ~= 1 then
                domainError = foundation.error('DELETION_PLAN_CAPACITY_INVALID',
                    'Deletion plan capacity changed unexpectedly.')
                return false
            end
            for _, action in ipairs(actions) do
                local actionState = action.decision == 'delete'
                    or action.decision == 'anonymize' and 'pending' or 'completed'
                if action.decision == 'delete' or action.decision == 'anonymize' then
                    actionState = 'pending'
                else actionState = 'completed' end
                local actionInserted = affectedRows(query([[INSERT INTO `synex_domain_deletion_actions`
                    (`plan_id`, `action_index`, `provider_owner`, `provider_name`,
                        `provider_schema_version`, `decision`, `decision_reason`, `metadata_json`,
                        `state`, `completed_at`)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?,
                        CASE WHEN ? = 'completed' THEN CURRENT_TIMESTAMP(6) ELSE NULL END)]], {
                    planId, action.index, action.providerOwner, action.providerName,
                    action.providerSchemaVersion, action.decision, action.reason,
                    action.metadataJson, actionState, actionState
                }))
                if actionInserted ~= 1 then
                    domainError = foundation.error('DELETION_PLAN_PERSISTENCE_FAILED',
                        'A deletion action could not be persisted safely.')
                    return false
                end
            end
            if not owners:isCurrent(owner, epoch) then
                domainError = foundation.error('STALE_RESOURCE',
                    'The deletion plan owner restarted before commit.', { retryable = true })
                return false
            end
            for _, provider in ipairs(providerBindings) do
                if not owners:isCurrent(provider.owner, provider.epoch) then
                    domainError = foundation.error('DELETION_PROVIDER_UNAVAILABLE',
                        'A deletion provider restarted before its decision commit.', {
                            retryable = true
                        })
                    return false
                end
            end
            storedPlanId = planId
            return true
        end)
        if not committed then return nil, domainError or transactionError end
        metrics:increment('synex_domain_deletion_plans_total', {
            domain = request.domain,
            state = blocked and 'blocked' or (pending and 'pending' or 'completed')
        })
        return loadPlan(storedPlanId)
    end

    local function leaseOwner(planId)
        local owner = instanceId .. ':domain-delete:' .. planId
        if #owner > 96 then return nil end
        return owner
    end

    local function deferPlan(plan, fence, errorValue)
        local code = foundation.failureCode(errorValue, 'DELETION_PROVIDER_FAILED')
            :upper():gsub('[^A-Z0-9_]', '_'):sub(1, 96)
        local affected, updateError = database:update([[UPDATE `synex_domain_deletion_plans`
            SET `state` = 'pending', `failure_code` = ?, `lease_fencing_token` = NULL,
                `next_attempt_at` = TIMESTAMPADD(SECOND, 5, CURRENT_TIMESTAMP(6)),
                `version` = `version` + 1
            WHERE `plan_id` = ? AND `version` = ? AND `state` = 'executing'
                AND `lease_fencing_token` = ?]],
            { code, plan.planId, plan.version, fence })
        if updateError then return nil, updateError end
        if affectedRows(affected) ~= 1 then
            return nil, foundation.error('DELETION_PLAN_CONFLICT',
                'The deletion plan changed while its retry was scheduled.', { retryable = true })
        end
        return true, nil
    end

    local function executePlan(plan, requester)
        if plan.state ~= 'pending' and plan.state ~= 'executing' then
            return nil, foundation.error('DELETION_PLAN_TERMINAL',
                'The deletion plan is not eligible for execution.')
        end
        local activeBootId, bootError = instances:bootId()
        if not activeBootId then return nil, bootError end
        local owner = leaseOwner(plan.planId)
        if not owner then
            return nil, foundation.error('INVALID_DELETION_PLAN',
                'Deletion plan lease identity exceeds its supported bound.')
        end
        if requester then
            local current, currentError = requesterCurrent(requester.owner, requester.epoch)
            if not current then return nil, currentError end
        end
        local boundProviders = {}
        for _, action in ipairs(plan.actions) do
            if action.state == 'pending' then
                local provider = currentProvider(plan.domain, action.providerOwner,
                    action.providerName, action.providerSchemaVersion)
                if not provider then
                    return nil, foundation.error('DELETION_PROVIDER_UNAVAILABLE',
                        'A durable deletion provider is waiting to rebind.', { retryable = true })
                end
                boundProviders[action.index] = provider
            end
        end
        local function bindingsCurrent()
            if requester and not owners:isCurrent(requester.owner, requester.epoch) then
                return nil, foundation.error('STALE_RESOURCE',
                    'The deletion plan owner restarted during execution.', { retryable = true })
            end
            for _, provider in pairs(boundProviders) do
                if not owners:isCurrent(provider.owner, provider.epoch) then
                    return nil, foundation.error('DELETION_PROVIDER_UNAVAILABLE',
                        'A deletion provider restarted during execution.', { retryable = true })
                end
            end
            return true, nil
        end
        local lease, leaseError = leases:acquire('domain-delete:' .. plan.planId,
            owner, 30, instanceId, activeBootId)
        if not lease then return nil, leaseError end
        local function release()
            local released, releaseError = leases:release(lease)
            if not released then
                logger:error('domain deletion lease release failed', {
                    planId = plan.planId,
                    code = foundation.failureCode(releaseError, 'DELETION_LEASE_RELEASE_FAILED')
                })
            end
        end
        local bindingsAvailable, bindingError = bindingsCurrent()
        if not bindingsAvailable then release() return nil, bindingError end
        local started, startError = database:update([[UPDATE `synex_domain_deletion_plans`
            SET `state` = 'executing', `lease_fencing_token` = ?,
                `attempt_count` = `attempt_count` + 1,
                `failure_code` = NULL, `version` = `version` + 1
            WHERE `plan_id` = ? AND `version` = ?
                AND `state` IN ('pending', 'executing')
                AND `next_attempt_at` <= CURRENT_TIMESTAMP(6)]],
            { lease.fencingToken, plan.planId, plan.version })
        if startError or affectedRows(started) ~= 1 then
            release()
            return nil, startError or foundation.error('DELETION_PLAN_CONFLICT',
                'The deletion plan is no longer eligible for this worker.', { retryable = true })
        end
        plan.version = plan.version + 1
        plan.state = 'executing'
        local refreshed, refreshError = loadPlan(plan.planId)
        if not refreshed then
            deferPlan(plan, lease.fencingToken, refreshError)
            release()
            return nil, refreshError
        end
        plan = refreshed
        bindingsAvailable, bindingError = bindingsCurrent()
        if not bindingsAvailable then
            deferPlan(plan, lease.fencingToken, bindingError)
            release()
            return nil, bindingError
        end
        for _, action in ipairs(plan.actions) do
            if action.state == 'pending' then
                local renewed, renewError = leases:renew(lease)
                if not renewed then
                    deferPlan(plan, lease.fencingToken, renewError)
                    release()
                    return nil, renewError
                end
                local provider = boundProviders[action.index]
                if not provider then
                    local unavailable = foundation.error('DELETION_PROVIDER_UNAVAILABLE',
                        'A durable deletion provider is waiting to rebind.', { retryable = true })
                    deferPlan(plan, lease.fencingToken, unavailable)
                    release()
                    return nil, unavailable
                end
                local value, providerError = invoke(provider, provider.execute, {
                    planId = plan.planId,
                    actionId = plan.planId .. ':' .. tostring(action.index),
                    domain = plan.domain,
                    subjectId = plan.subjectId,
                    decision = action.decision,
                    reason = plan.reason,
                    context = foundation.copy(plan.context),
                    metadata = foundation.copy(action.metadata)
                }, 'execute')
                if providerError then
                    database:update([[UPDATE `synex_domain_deletion_actions`
                        SET `attempt_count` = `attempt_count` + 1,
                            `last_attempt_at` = CURRENT_TIMESTAMP(6), `failure_code` = ?
                        WHERE `plan_id` = ? AND `action_index` = ? AND `version` = ?
                            AND `state` = 'pending']], {
                        foundation.failureCode(providerError, 'DELETION_PROVIDER_FAILED')
                            :upper():gsub('[^A-Z0-9_]', '_'):sub(1, 96),
                        plan.planId, action.index, action.version
                    })
                    deferPlan(plan, lease.fencingToken, providerError)
                    release()
                    return nil, providerError
                end
                local completed = value == true or type(value) == 'table'
                    and rawget(value, 'completed') == true
                if not completed then
                    local invalid = foundation.error('INVALID_DELETION_PROVIDER_RESULT',
                        'A deletion provider did not confirm idempotent completion.')
                    deferPlan(plan, lease.fencingToken, invalid)
                    release()
                    return nil, invalid
                end
                renewed, renewError = leases:renew(lease)
                if not renewed then
                    deferPlan(plan, lease.fencingToken, renewError)
                    release()
                    return nil, renewError
                end
                if not owners:isCurrent(provider.owner, provider.epoch) then
                    local staleProvider = foundation.error('DELETION_PROVIDER_UNAVAILABLE',
                        'A deletion provider restarted before its result commit.', {
                            retryable = true
                        })
                    deferPlan(plan, lease.fencingToken, staleProvider)
                    release()
                    return nil, staleProvider
                end
                bindingsAvailable, bindingError = bindingsCurrent()
                if not bindingsAvailable then
                    deferPlan(plan, lease.fencingToken, bindingError)
                    release()
                    return nil, bindingError
                end
                local actionUpdated, actionError = database:update(
                    [[UPDATE `synex_domain_deletion_actions`
                    SET `state` = 'completed', `attempt_count` = `attempt_count` + 1,
                        `failure_code` = NULL, `last_attempt_at` = CURRENT_TIMESTAMP(6),
                        `completed_at` = CURRENT_TIMESTAMP(6), `version` = `version` + 1
                    WHERE `plan_id` = ? AND `action_index` = ? AND `version` = ?
                        AND `state` = 'pending'
                        AND EXISTS (SELECT 1 FROM `synex_domain_deletion_plans`
                            WHERE `plan_id` = ? AND `version` = ? AND `state` = 'executing'
                                AND `lease_fencing_token` = ?)]],
                    { plan.planId, action.index, action.version,
                        plan.planId, plan.version, lease.fencingToken })
                if actionError or affectedRows(actionUpdated) ~= 1 then
                    local conflict = actionError or foundation.error('DELETION_ACTION_CONFLICT',
                        'The deletion action changed during execution.', { retryable = true })
                    deferPlan(plan, lease.fencingToken, conflict)
                    release()
                    return nil, conflict
                end
                boundProviders[action.index] = nil
            end
        end
        local renewed, renewError = leases:renew(lease)
        if not renewed then
            deferPlan(plan, lease.fencingToken, renewError)
            release()
            return nil, renewError
        end
        bindingsAvailable, bindingError = bindingsCurrent()
        if not bindingsAvailable then
            deferPlan(plan, lease.fencingToken, bindingError)
            release()
            return nil, bindingError
        end
        local completed, completionError = database:update([[UPDATE `synex_domain_deletion_plans`
            SET `state` = 'completed', `failure_code` = NULL,
                `lease_fencing_token` = NULL, `completed_at` = CURRENT_TIMESTAMP(6),
                `purge_after` = TIMESTAMPADD(DAY, ?, CURRENT_TIMESTAMP(6)),
                `version` = `version` + 1
            WHERE `plan_id` = ? AND `version` = ? AND `state` = 'executing'
                AND `lease_fencing_token` = ?
                AND NOT EXISTS (SELECT 1 FROM `synex_domain_deletion_actions`
                    WHERE `plan_id` = ? AND `state` <> 'completed')]],
            { terminalRetentionDays, plan.planId, plan.version,
                lease.fencingToken, plan.planId })
        release()
        if completionError or affectedRows(completed) ~= 1 then
            return nil, completionError or foundation.error('DELETION_PLAN_CONFLICT',
                'The deletion plan could not reach a fenced terminal state.', { retryable = true })
        end
        metrics:increment('synex_domain_deletion_plans_total', {
            domain = plan.domain, state = 'completed'
        })
        return loadPlan(plan.planId)
    end

    function service:process(owner, epoch, planId)
        local current, currentError = requesterCurrent(owner, epoch)
        if not current then return nil, currentError end
        local plan, planError = loadPlan(planId, owner)
        if not plan then return nil, planError end
        current, currentError = requesterCurrent(owner, epoch)
        if not current then return nil, currentError end
        return executePlan(plan, { owner = owner, epoch = epoch })
    end

    function service:reconcile(limit)
        if type(limit) ~= 'number' or math.type(limit) ~= 'integer'
            or limit < 1 or limit > 32 then
            return nil, foundation.error('INVALID_ARGUMENT',
                'Deletion reconciliation limit must be 1 through 32.')
        end
        local compaction = { removed = 0, owners = 0 }
        local compactionDomainError
        local compacted, compactionTransactionError = database:withTransaction(function(query)
            compactionDomainError = nil
            local terminalRows = query([[SELECT `plan_id`, `requester_owner`, `state`
                FROM `synex_domain_deletion_plans`
                FORCE INDEX (`idx_domain_deletion_retention`)
                WHERE `purge_after` <= CURRENT_TIMESTAMP(6)
                ORDER BY `purge_after`, `plan_id` LIMIT ? FOR UPDATE]], { limit }) or {}
            if #terminalRows > limit then
                compactionDomainError = foundation.error('DATABASE_RESULT_INVALID',
                    'Deletion retention returned an oversized batch.')
                return false
            end
            if #terminalRows == 0 then return true end
            local globalRows = query([[SELECT `entry_count`, `global_limit`, `owner_limit`
                FROM `synex_domain_deletion_plan_capacity`
                WHERE `singleton_id` = 1 FOR UPDATE]]) or {}
            local global = globalRows[1]
            local globalCount = global and tonumber(global.entry_count) or nil
            local globalLimit = global and tonumber(global.global_limit) or nil
            local ownerLimit = global and tonumber(global.owner_limit) or nil
            if #globalRows ~= 1 or not globalCount
                or math.type(globalCount) ~= 'integer' or globalCount < #terminalRows
                or not globalLimit or math.type(globalLimit) ~= 'integer'
                or globalLimit < 1 or globalLimit > maximumRetainedPlans
                or not ownerLimit or math.type(ownerLimit) ~= 'integer'
                or ownerLimit < 1 or ownerLimit > maximumPlansPerOwner
                or ownerLimit > globalLimit or globalCount > globalLimit then
                compactionDomainError = foundation.error('DELETION_PLAN_CAPACITY_INVALID',
                    'Deletion plan capacity is invalid during retention.')
                return false
            end
            local ownerCounts, ownerNames = {}, {}
            for _, row in ipairs(terminalRows) do
                if type(row.plan_id) ~= 'string' or #row.plan_id < 1 or #row.plan_id > 48
                    or not row.plan_id:match('^[a-z0-9_]+$')
                    or not validOwner(row.requester_owner)
                    or not terminalPlanStates[row.state] then
                    compactionDomainError = foundation.error('DELETION_PLAN_CAPACITY_INVALID',
                        'Deletion retention returned an invalid terminal plan.')
                    return false
                end
                if not ownerCounts[row.requester_owner] then
                    ownerNames[#ownerNames + 1] = row.requester_owner
                    ownerCounts[row.requester_owner] = 0
                end
                ownerCounts[row.requester_owner] = ownerCounts[row.requester_owner] + 1
            end
            table.sort(ownerNames)
            local ownerCurrent = {}
            for _, ownerName in ipairs(ownerNames) do
                local ownerRows = query([[SELECT `entry_count`
                    FROM `synex_domain_deletion_plan_owner_capacity`
                    WHERE `requester_owner` = ? FOR UPDATE]], { ownerName }) or {}
                local current = ownerRows[1] and tonumber(ownerRows[1].entry_count) or nil
                if #ownerRows ~= 1 or not current or math.type(current) ~= 'integer'
                    or current < ownerCounts[ownerName] or current > ownerLimit
                    or current > globalCount then
                    compactionDomainError = foundation.error('DELETION_PLAN_CAPACITY_INVALID',
                        'Deletion plan owner capacity is invalid during retention.')
                    return false
                end
                ownerCurrent[ownerName] = current
            end
            for _, row in ipairs(terminalRows) do
                local removed = affectedRows(query([[DELETE FROM `synex_domain_deletion_plans`
                    WHERE `plan_id` = ? AND `requester_owner` = ?
                        AND `state` IN ('completed', 'blocked', 'failed')
                        AND `purge_after` <= CURRENT_TIMESTAMP(6)]], {
                    row.plan_id, row.requester_owner
                }))
                if removed ~= 1 then
                    compactionDomainError = foundation.error('DELETION_PLAN_CAPACITY_INVALID',
                        'A deletion plan changed during terminal retention.')
                    return false
                end
            end
            for _, ownerName in ipairs(ownerNames) do
                local count = ownerCounts[ownerName]
                local current = ownerCurrent[ownerName]
                local released
                if current == count then
                    released = affectedRows(query(
                        [[DELETE FROM `synex_domain_deletion_plan_owner_capacity`
                        WHERE `requester_owner` = ? AND `entry_count` = ?]],
                        { ownerName, current }))
                else
                    released = affectedRows(query(
                        [[UPDATE `synex_domain_deletion_plan_owner_capacity`
                        SET `entry_count` = `entry_count` - ?
                        WHERE `requester_owner` = ? AND `entry_count` = ?]],
                        { count, ownerName, current }))
                end
                if released ~= 1 then
                    compactionDomainError = foundation.error('DELETION_PLAN_CAPACITY_INVALID',
                        'Deletion plan owner capacity changed during retention.')
                    return false
                end
            end
            local globalReleased = affectedRows(query(
                [[UPDATE `synex_domain_deletion_plan_capacity`
                SET `entry_count` = `entry_count` - ?
                WHERE `singleton_id` = 1 AND `entry_count` = ?]],
                { #terminalRows, globalCount }))
            if globalReleased ~= 1 then
                compactionDomainError = foundation.error('DELETION_PLAN_CAPACITY_INVALID',
                    'Deletion plan capacity changed during retention.')
                return false
            end
            compaction = { removed = #terminalRows, owners = #ownerNames }
            return true
        end)
        if not compacted then
            return nil, compactionDomainError or compactionTransactionError
        end
        local rows, queryError = database:query([[SELECT `plan_id`
            FROM `synex_domain_deletion_plans`
            WHERE `state` IN ('pending', 'executing')
                AND `next_attempt_at` <= CURRENT_TIMESTAMP(6)
            ORDER BY `next_attempt_at`, `created_at`, `plan_id` LIMIT ?]], { limit })
        if not rows then return nil, queryError end
        if #rows > limit then
            return nil, foundation.error('DATABASE_RESULT_INVALID',
                'Deletion reconciliation returned an oversized batch.')
        end
        local report = {
            examined = #rows,
            completed = 0,
            deferred = 0,
            compacted = compaction.removed,
            compactedOwners = compaction.owners
        }
        for _, row in ipairs(rows) do
            local plan, planError = loadPlan(row.plan_id)
            local completed, executionError
            if plan then completed, executionError = executePlan(plan)
            else executionError = planError end
            if completed then report.completed = report.completed + 1
            else
                report.deferred = report.deferred + 1
                metrics:increment('synex_domain_deletion_reconciliation_total', {
                    result = foundation.failureCode(executionError, 'DEFERRED')
                })
            end
        end
        return report, nil
    end

    function service:snapshot()
        local active = {}
        for _, provider in pairs(providers) do
            if owners:isCurrent(provider.owner, provider.epoch) then
                active[#active + 1] = {
                    domain = provider.domain,
                    owner = provider.owner,
                    name = provider.name,
                    schemaVersion = provider.schemaVersion,
                    ownerEpoch = provider.epoch
                }
            end
        end
        table.sort(active, function(left, right)
            if left.domain ~= right.domain then return left.domain < right.domain end
            if left.owner ~= right.owner then return left.owner < right.owner end
            return left.name < right.name
        end)
        return { providers = active }, nil
    end

    return service
end
