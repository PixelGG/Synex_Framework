local factories = assert(SynexCoreFactories, 'factories must be loaded first')

factories.security = function(deps)
    local foundation = assert(deps.foundation, 'security requires foundation')
    local logger = foundation.logger
    local metrics = foundation.metrics
    local platform = assert(deps.platform, 'security requires platform')

    local manifests = {}
    local policy = deps.policy or { default = { allow = {}, deny = {} }, resources = {} }
    local rolePermissions = {}
    local subjectRoles = {}
    local rbacStore = deps.rbacStore
    local subjectCache = {}
    local subjectCacheSize = 0
    local rbacHydrated = rbacStore == nil
    local rbacCacheTtlMs = math.max(1000, math.min(tonumber(deps.rbacCacheTtlMs) or 5000, 60000))
    local rbacCacheMaximum = math.max(64, math.min(tonumber(deps.rbacCacheMaximum) or 2048, 10000))
    local buckets = {}
    local auditSink = nil
    local denialAudit = {}
    local denialAuditSize = 0

    local capabilityClass = {
        ['synex.runtime.read'] = 'normal',
        ['synex.metrics.read'] = 'sensitive',
        ['synex.identity.read'] = 'sensitive',
        ['synex.audit.summary'] = 'sensitive',
        ['synex.audit.raw'] = 'privileged',
        ['synex.events.durable'] = 'sensitive',
        ['synex.access.read'] = 'sensitive',
        ['synex.access.manage'] = 'privileged',
        ['synex.capabilities.delegate'] = 'privileged',
        ['synex.permissions.manage'] = 'privileged',
        ['synex.sagas.register'] = 'privileged',
        ['synex.accounts.mint'] = 'privileged',
        ['synex.accounts.burn'] = 'privileged',
        ['synex.characters.delete'] = 'destructive',
        ['synex.entities.delete_persistent'] = 'destructive'
    }

    local function matchesAny(patterns, capability)
        for _, pattern in ipairs(patterns or {}) do
            if foundation.wildcardMatch(pattern, capability) then return true end
        end
        return false
    end

    local function auditCapabilityDenial(resource, capability, context, reason)
        if type(auditSink) ~= 'function' then return end
        local key = tostring(resource) .. ':' .. tostring(capability)
        local now = foundation.monotonicMs()
        local previous = denialAudit[key]
        if previous and now - previous < 5000 then return end
        if not previous then
            denialAuditSize = denialAuditSize + 1
            if denialAuditSize > 2048 then
                local oldestKey, oldestAt = nil, nil
                for candidate, at in pairs(denialAudit) do
                    if oldestAt == nil or at < oldestAt then oldestKey, oldestAt = candidate, at end
                end
                if oldestKey then denialAudit[oldestKey] = nil; denialAuditSize = denialAuditSize - 1 end
            end
        end
        denialAudit[key] = now
        local ok, sinkResult, sinkError = foundation.safeCall(auditSink, {
            actorType = 'resource',
            actorId = tostring(resource):sub(1, 128),
            action = 'capability.denied',
            targetType = 'capability',
            targetId = tostring(capability):sub(1, 128),
            traceId = context.traceId,
            context = {
                operation = tostring(context.operation or 'unknown'):sub(1, 128),
                reason = reason
            }
        })
        if not ok or sinkError then
            logger:error('capability denial audit failed', {
                resource = resource, capability = capability,
                error = tostring(ok and sinkError or sinkResult), traceId = context.traceId
            })
        end
    end

    local capabilityPolicy = {}
    function capabilityPolicy:registerManifest(resource, manifest)
        local requested = {}
        for _, capability in ipairs((manifest.capabilities and manifest.capabilities.request) or {}) do requested[capability] = true end
        manifests[resource] = { requested = requested, manifest = foundation.copy(manifest) }
    end
    function capabilityPolicy:class(capability)
        return capabilityClass[capability]
            or (capability:find('delete', 1, true) and 'destructive')
            or (capability:find('admin', 1, true) and 'privileged')
            or 'normal'
    end
    function capabilityPolicy:check(resource, capability, context)
        context = context or {}
        if resource == deps.coreResource then return true, nil end
        local manifest = manifests[resource]
        if not manifest then
            metrics:increment('synex_capability_denials_total', { resource = tostring(resource), reason = 'unregistered' })
            logger:warn('capability denied', {
                resource = resource, capability = capability, operation = context.operation,
                traceId = context.traceId, reason = 'unregistered'
            })
            auditCapabilityDenial(resource, capability, context, 'unregistered')
            return nil, foundation.error('RESOURCE_NOT_REGISTERED', 'The calling resource has no validated Synex manifest.', { traceId = context.traceId })
        end
        if not manifest.requested[capability] and not matchesAny((manifest.manifest.capabilities or {}).request, capability) then
            metrics:increment('synex_capability_denials_total', { resource = resource, reason = 'undeclared' })
            logger:warn('capability denied', { resource = resource, capability = capability, operation = context.operation, traceId = context.traceId, reason = 'undeclared' })
            auditCapabilityDenial(resource, capability, context, 'undeclared')
            return nil, foundation.error('CAPABILITY_UNDECLARED', 'The resource did not declare this capability.', { traceId = context.traceId })
        end
        local resourcePolicy = (policy.resources or {})[resource] or {}
        local denied = matchesAny((policy.default or {}).deny, capability) or matchesAny(resourcePolicy.deny, capability)
        local allowed = matchesAny(resourcePolicy.allow, capability) or matchesAny((policy.default or {}).allow, capability)
        if denied or not allowed then
            metrics:increment('synex_capability_denials_total', { resource = resource, reason = denied and 'denied' or 'not_granted' })
            logger:warn('capability denied', { resource = resource, capability = capability, operation = context.operation, traceId = context.traceId, reason = denied and 'denied' or 'not_granted' })
            auditCapabilityDenial(resource, capability, context, denied and 'denied' or 'not_granted')
            return nil, foundation.error('CAPABILITY_DENIED', 'The resource is not granted this capability.', { traceId = context.traceId })
        end
        return true, nil
    end
    function capabilityPolicy:snapshot()
        local result = {}
        for resource, manifest in pairs(manifests) do
            result[resource] = { requested = foundation.copy(manifest.requested), policy = foundation.copy((policy.resources or {})[resource] or {}) }
        end
        return result
    end
    function capabilityPolicy:preflight(resource)
        local registered = manifests[resource]
        if not registered then
            return { { resource = resource, capability = nil, reason = 'unregistered' } }
        end
        local findings = {}
        local resourcePolicy = (policy.resources or {})[resource] or {}
        for capability in pairs(registered.requested) do
            local denied = matchesAny((policy.default or {}).deny, capability)
                or matchesAny(resourcePolicy.deny, capability)
            local allowed = matchesAny(resourcePolicy.allow, capability)
                or matchesAny((policy.default or {}).allow, capability)
            if denied or not allowed then
                findings[#findings + 1] = {
                    resource = resource, capability = capability,
                    reason = denied and 'denied' or 'not_granted'
                }
            end
        end
        table.sort(findings, function(left, right) return left.capability < right.capability end)
        return findings
    end
    function capabilityPolicy:providesContract(resource, name)
        local registered = manifests[resource]
        if not registered then return false end
        for _, provided in ipairs((registered.manifest.contracts or {}).provide or {}) do
            if provided == name then return true end
        end
        return false
    end
    function capabilityPolicy:providesService(resource, name, major)
        local registered = manifests[resource]
        if not registered then return false end
        local expected = name .. '@' .. tostring(major)
        for _, provided in ipairs((registered.manifest.services or {}).provide or {}) do
            if provided == expected then return true end
        end
        return false
    end
    function capabilityPolicy:setAuditSink(sink)
        if sink ~= nil and type(sink) ~= 'function' then
            return nil, foundation.error('INVALID_ARGUMENT', 'Capability audit sink must be a function.')
        end
        auditSink = sink
        return true, nil
    end

    local function validPermission(value)
        if type(value) ~= 'string' or #value < 1 or #value > 128
            or not value:match('^[a-z][a-z0-9%._%-%*]*$') then return false end
        local wildcard = value:find('*', 1, true)
        local base = value
        if wildcard then
            if value:sub(-2) ~= '.*' or wildcard ~= #value then return false end
            base = value:sub(1, -3)
        end
        return base:match('^[a-z][a-z0-9%._%-]*$') ~= nil
            and not base:match('[%._%-]$') and not base:match('[%._%-][%._%-]')
    end

    local function validRole(value)
        return type(value) == 'string' and #value >= 1 and #value <= 64
            and value:match('^[a-z][a-z0-9%._%-]*$') ~= nil
            and not value:match('[%._%-]$') and not value:match('[%._%-][%._%-]')
    end

    local function validSubject(value)
        return type(value) == 'string' and #value >= 3 and #value <= 128
            and value:match('^[a-z][a-z0-9_%-]*:[A-Za-z0-9_.:%-]+$') ~= nil
    end

    local function normalizeRolePermissions(permissions)
        if type(permissions) ~= 'table' or #permissions > 512 then
            return nil, foundation.error('INVALID_PERMISSION_SET', 'Role permissions must be a bounded array.')
        end
        local normalized, seen = {}, {}
        for index, candidate in ipairs(permissions) do
            local permission = type(candidate) == 'table' and candidate.permission or candidate
            local effect = type(candidate) == 'table' and candidate.effect or 'allow'
            if not validPermission(permission) or (effect ~= 'allow' and effect ~= 'deny') then
                return nil, foundation.error('INVALID_PERMISSION', ('Role permission %d is invalid.'):format(index))
            end
            local key = effect .. ':' .. permission
            if seen[key] then return nil, foundation.error('DUPLICATE_PERMISSION', 'Role permission entries must be unique.') end
            seen[key] = true
            normalized[#normalized + 1] = { permission = permission, effect = effect }
        end
        return normalized, nil
    end

    local function invalidateSubject(subject)
        if subjectCache[subject] then
            subjectCache[subject] = nil
            subjectCacheSize = math.max(0, subjectCacheSize - 1)
        end
    end

    local function putSubjectCache(subject, roles, version)
        if not subjectCache[subject] then
            subjectCacheSize = subjectCacheSize + 1
            if subjectCacheSize > rbacCacheMaximum then
                local oldestSubject, oldestAt = nil, nil
                for candidate, entry in pairs(subjectCache) do
                    if oldestAt == nil or entry.touchedAt < oldestAt then oldestSubject, oldestAt = candidate, entry.touchedAt end
                end
                if oldestSubject then subjectCache[oldestSubject] = nil; subjectCacheSize = subjectCacheSize - 1 end
            end
        end
        local now = foundation.monotonicMs()
        subjectCache[subject] = {
            roles = foundation.copy(roles), version = tonumber(version) or 0,
            expiresAt = now + rbacCacheTtlMs, touchedAt = now
        }
    end

    local rbac = {}
    local function validateMutationContext(context)
        if type(context) ~= 'table' or getmetatable(context) ~= nil then
            return nil, foundation.error('INVALID_AUDIT_CONTEXT', 'RBAC mutations require an audit context.')
        end
        local allowed = { actor = true, actorType = true, reason = true, traceId = true, expiresAt = true }
        for key in pairs(context) do
            if type(key) ~= 'string' or not allowed[key] then
                return nil, foundation.error('INVALID_AUDIT_CONTEXT', 'RBAC audit context contains an unknown property.')
            end
        end
        if type(context.actor) ~= 'string' or #context.actor < 1 or #context.actor > 128
            or context.actor:find('[%z\1-\31\127]')
            or type(context.reason) ~= 'string' or #context.reason < 1 or #context.reason > 256
            or context.reason:find('[%z\1-\31\127]')
            or type(context.traceId) ~= 'string' or #context.traceId < 8 or #context.traceId > 64
            or not context.traceId:match('^[A-Za-z0-9_.:%-]+$') then
            return nil, foundation.error('INVALID_AUDIT_CONTEXT', 'RBAC actor, reason, or trace ID is invalid.')
        end
        if context.actorType ~= nil and context.actorType ~= 'resource' and context.actorType ~= 'system' then
            return nil, foundation.error('INVALID_AUDIT_CONTEXT', 'RBAC actor type is invalid.')
        end
        return foundation.copy(context), nil
    end

    function rbac:hydrate()
        if not rbacStore then rbacHydrated = true return true, nil end
        local rows, err = rbacStore:loadRoles()
        if not rows then return nil, err end
        if #rows > 16384 then return nil, foundation.error('RBAC_TOO_LARGE', 'Persistent RBAC role data exceeds the safe bootstrap limit.') end
        local loaded = {}
        for _, row in ipairs(rows) do
            if not validRole(row.role_name) then return nil, foundation.error('RBAC_DATA_INVALID', 'Persistent RBAC contains an invalid role.') end
            loaded[row.role_name] = loaded[row.role_name] or { allow = {}, deny = {}, version = tonumber(row.version) or 1 }
            if row.permission_key ~= nil then
                if not validPermission(row.permission_key) or (row.effect ~= 'allow' and row.effect ~= 'deny') then
                    return nil, foundation.error('RBAC_DATA_INVALID', 'Persistent RBAC contains an invalid permission.')
                end
                loaded[row.role_name][row.effect][row.permission_key] = true
            end
        end
        rolePermissions = loaded
        rbacHydrated = true
        subjectCache = {}
        subjectCacheSize = 0
        return true, nil
    end

    function rbac:defineRole(name, permissions, context)
        if not validRole(name) then return nil, foundation.error('INVALID_ROLE', 'Role name is invalid.') end
        local normalized, normalizeError = normalizeRolePermissions(permissions or {})
        if not normalized then return nil, normalizeError end
        local mutationContext, contextError = validateMutationContext(context)
        if not mutationContext then return nil, contextError end
        if rbacStore then
            local persisted, persistenceError = rbacStore:defineRole(name, normalized, mutationContext)
            if not persisted then return nil, persistenceError end
        end
        local currentVersion = rolePermissions[name] and tonumber(rolePermissions[name].version) or 0
        local stored = { allow = {}, deny = {}, version = currentVersion + 1 }
        for _, permission in ipairs(normalized) do stored[permission.effect][permission.permission] = true end
        rolePermissions[name] = stored
        subjectCache = {}
        subjectCacheSize = 0
        metrics:increment('synex_rbac_mutations_total', { action = 'define_role' })
        return true, nil
    end

    function rbac:assign(subject, role, context)
        if not validSubject(subject) then return nil, foundation.error('INVALID_SUBJECT', 'RBAC subject is invalid.') end
        if not validRole(role) or not rolePermissions[role] then return nil, foundation.error('ROLE_NOT_FOUND', 'The role does not exist.') end
        local mutationContext, contextError = validateMutationContext(context)
        if not mutationContext then return nil, contextError end
        local expiresAt = mutationContext.expiresAt
        if expiresAt ~= nil and (type(expiresAt) ~= 'string' or #expiresAt < 19 or #expiresAt > 32
            or not expiresAt:match('^%d%d%d%d%-%d%d%-%d%d[T ]%d%d:%d%d:%d%d')) then
            return nil, foundation.error('INVALID_EXPIRY', 'RBAC assignment expiry must be an ISO-like timestamp.')
        end
        if rbacStore then
            local persisted, persistenceError = rbacStore:assign(subject, role, mutationContext)
            if not persisted then return nil, persistenceError end
        end
        subjectRoles[subject] = subjectRoles[subject] or {}
        subjectRoles[subject][role] = true
        invalidateSubject(subject)
        metrics:increment('synex_rbac_mutations_total', { action = 'assign' })
        return true, nil
    end

    function rbac:revoke(subject, role, context)
        if not validSubject(subject) then return nil, foundation.error('INVALID_SUBJECT', 'RBAC subject is invalid.') end
        if not validRole(role) then return nil, foundation.error('INVALID_ROLE', 'Role name is invalid.') end
        local mutationContext, contextError = validateMutationContext(context)
        if not mutationContext then return nil, contextError end
        if rbacStore then
            local persisted, persistenceError = rbacStore:revoke(subject, role, mutationContext)
            if not persisted then return nil, persistenceError end
        end
        if subjectRoles[subject] then subjectRoles[subject][role] = nil end
        invalidateSubject(subject)
        metrics:increment('synex_rbac_mutations_total', { action = 'revoke' })
        return true, nil
    end

    function rbac:check(subject, permission, explicitDenies)
        if not validSubject(subject) or not validPermission(permission) then return false, nil end
        if matchesAny(explicitDenies, permission) then return false, nil end
        if not rbacHydrated then
            local hydrated, hydrationError = self:hydrate()
            if not hydrated then return false, hydrationError end
        end
        local roles = subjectRoles[subject] or {}
        if rbacStore then
            local now = foundation.monotonicMs()
            local cached = subjectCache[subject]
            if cached and cached.expiresAt > now then
                cached.touchedAt = now
                roles = cached.roles
                metrics:increment('synex_rbac_cache_total', { result = 'hit' })
            else
                local loaded, loadError = rbacStore:loadSubject(subject)
                if not loaded then
                    metrics:increment('synex_rbac_cache_total', { result = 'error' })
                    return false, loadError
                end
                roles = {}
                for _, role in ipairs(loaded.roles or {}) do if rolePermissions[role] then roles[role] = true end end
                putSubjectCache(subject, roles, loaded.version)
                metrics:increment('synex_rbac_cache_total', { result = 'miss' })
            end
        end
        local allowed = false
        for role in pairs(roles) do
            local permissions = rolePermissions[role]
            if permissions then
                for denied in pairs(permissions.deny or {}) do
                    if foundation.wildcardMatch(denied, permission) then return false, nil end
                end
                for granted in pairs(permissions.allow or {}) do
                    if foundation.wildcardMatch(granted, permission) then allowed = true end
                end
            end
        end
        return allowed, nil
    end

    function rbac:invalidate(subject)
        if subject ~= nil and not validSubject(subject) then return nil, foundation.error('INVALID_SUBJECT', 'RBAC subject is invalid.') end
        if subject then invalidateSubject(subject)
        else
            subjectCache = {}
            subjectCacheSize = 0
        end
        return true, nil
    end

    function rbac:snapshot()
        local roleCount = 0
        for _ in pairs(rolePermissions) do roleCount = roleCount + 1 end
        return {
            persistent = rbacStore ~= nil,
            hydrated = rbacHydrated,
            roles = roleCount,
            cachedSubjects = subjectCacheSize,
            cacheMaximum = rbacCacheMaximum,
            cacheTtlMs = rbacCacheTtlMs
        }
    end

    local limiter = {}
    function limiter:consume(key, capacity, refillPerSecond, cost)
        local now = foundation.monotonicMs()
        capacity = math.max(1, math.min(capacity or 1, 10000))
        refillPerSecond = math.max(0.01, math.min(refillPerSecond or 1, 10000))
        cost = math.max(0.01, cost or 1)
        local bucket = buckets[key]
        if not bucket then bucket = { tokens = capacity, at = now }; buckets[key] = bucket end
        local elapsed = math.max(0, now - bucket.at)
        bucket.tokens = math.min(capacity, bucket.tokens + elapsed * refillPerSecond / 1000)
        bucket.at = now
        if bucket.tokens < cost then
            metrics:increment('synex_rate_limit_rejections_total', { scope = tostring(key):match('^[^:]+') or 'unknown' })
            local retryAfterMs = math.ceil((cost - bucket.tokens) / refillPerSecond * 1000)
            return nil, foundation.error('RATE_LIMITED', 'The operation rate limit was exceeded.', {
                retryable = true, details = { retryAfterMs = retryAfterMs }
            })
        end
        bucket.tokens = bucket.tokens - cost
        return true, nil
    end
    function limiter:purge(prefix)
        for key in pairs(buckets) do if key:sub(1, #prefix) == prefix then buckets[key] = nil end end
    end

    local function validateNetworkEnvelope(envelope)
        if type(envelope) ~= 'table' then return nil, foundation.error('INVALID_ENVELOPE', 'RPC envelope must be an object.') end
        local allowed = { wire = true, requestId = true, procedure = true, version = true, payload = true, traceId = true, deadlineMs = true, idempotencyKey = true }
        for key in pairs(envelope) do if not allowed[key] then return nil, foundation.error('INVALID_ENVELOPE', 'RPC envelope contains an unknown field.') end end
        if envelope.wire ~= 1 then return nil, foundation.error('WIRE_VERSION_UNSUPPORTED', 'RPC wire version is unsupported.') end
        if type(envelope.requestId) ~= 'string' or #envelope.requestId < 8 or #envelope.requestId > 96
            or not envelope.requestId:match('^[A-Za-z0-9_.:%-]+$') then
            return nil, foundation.error('INVALID_REQUEST_ID', 'RPC request ID is invalid.')
        end
        if type(envelope.procedure) ~= 'string' or #envelope.procedure < 3 or #envelope.procedure > 128
            or not envelope.procedure:match('^[a-z][a-z0-9_]*%.[a-z][a-z0-9_.]*$') then
            return nil, foundation.error('INVALID_PROCEDURE', 'RPC procedure is invalid.')
        end
        if type(envelope.version) ~= 'string' or not foundation.semver(envelope.version) then return nil, foundation.error('INVALID_VERSION', 'RPC version is invalid.') end
        if envelope.traceId ~= nil and (type(envelope.traceId) ~= 'string' or #envelope.traceId < 8 or #envelope.traceId > 64
            or not envelope.traceId:match('^[A-Za-z0-9_.:%-]+$')) then
            return nil, foundation.error('INVALID_TRACE_ID', 'RPC trace ID is invalid.')
        end
        if envelope.deadlineMs ~= nil and (type(envelope.deadlineMs) ~= 'number' or envelope.deadlineMs < 50 or envelope.deadlineMs > 15000) then return nil, foundation.error('INVALID_DEADLINE', 'RPC deadline is invalid.') end
        if envelope.idempotencyKey ~= nil and (type(envelope.idempotencyKey) ~= 'string'
            or #envelope.idempotencyKey < 8 or #envelope.idempotencyKey > 128
            or not envelope.idempotencyKey:match('^[A-Za-z0-9_.:%-]+$')) then
            return nil, foundation.error('INVALID_IDEMPOTENCY_KEY', 'RPC idempotency key is invalid.')
        end
        return true, nil
    end

    return {
        capabilities = capabilityPolicy,
        rbac = rbac,
        rateLimiter = limiter,
        validateNetworkEnvelope = validateNetworkEnvelope
    }
end
