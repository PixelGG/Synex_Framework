SynexEntitySecurityReporting = {}

function SynexEntitySecurityReporting.create(options)
    assert(type(options) == 'table', 'entity security reporting options are required')
    local resourceName = assert(options.resourceName,
        'entity security reporting resourceName is required')
    local coreRef = assert(options.coreRef, 'entity security reporting coreRef is required')
    local foundation = assert(options.foundation,
        'entity security reporting foundation is required')
    local policies = {
        FOREIGN_BUCKET = { severity = 'HIGH', confidence = 0.96,
            key = 'foreign-bucket' },
        FOREIGN_RESOURCE_OWNER = { severity = 'HIGH', confidence = 0.96,
            key = 'foreign-owner' },
        FOREIGN_NAMESPACE = { severity = 'HIGH', confidence = 0.96,
            key = 'foreign-namespace' },
        STALE_ENTITY = { severity = 'MEDIUM', confidence = 0.93,
            key = 'stale-entity' },
        STALE_BUCKET = { severity = 'MEDIUM', confidence = 0.93,
            key = 'stale-bucket' },
        BUCKET_MISMATCH = { severity = 'MEDIUM', confidence = 0.90,
            key = 'bucket-mismatch' },
        AUTHORITY_LEASE_CONFLICT = { severity = 'MEDIUM', confidence = 0.90,
            key = 'authority-conflict' },
        ENTITY_QUOTA_EXCEEDED = { severity = 'LOW', confidence = 0.68,
            key = 'entity-quota' },
        INTERACTION_CONTEXT_INVALID = { severity = 'MEDIUM', confidence = 0.88,
            key = 'interaction-context' },
    }
    local reporting = {}

    function reporting.reportDenial(contractName, operationError, context)
        local code = type(operationError) == 'table' and operationError.code or nil
        local policy = policies[code]
        local api = coreRef.value
        local call = type(api) == 'table' and type(api.Services) == 'table'
            and api.Services.call or nil
        if not policy or not foundation.isCallable(call) then return false end
        local session = type(context) == 'table' and context.session or nil
        local subject
        if type(session) == 'table' and type(session.id) == 'string'
            and type(session.sourceGeneration) == 'number'
            and type(context.source) == 'number' then
            subject = {
                sessionId = session.id,
                source = context.source,
                sourceGeneration = session.sourceGeneration,
                userId = session.userId,
                characterId = session.characterId,
            }
        else
            local caller = type(context) == 'table'
                and (context.caller or context.callerResource) or nil
            subject = { resourceName = type(caller) == 'string'
                and caller or resourceName }
        end
        local ok = pcall(call, 'synex.security', '^1.0.0', 'reportSignal', {
            namespace = 'synex.entities',
            category = 'entity',
            detector = 'synex.entities.domain',
            code = code,
            subject = subject,
            severity = policy.severity,
            confidence = policy.confidence,
            evidenceClass = 'DOMAIN_AUTHORITATIVE',
            correlationKey = 'entity:' .. policy.key,
            traceId = type(context) == 'table' and context.traceId or nil,
            summary = 'Entity authority rejected a security-relevant operation.',
            evidence = { contract = tostring(contractName):sub(1, 96) },
        }, {
            traceId = type(context) == 'table' and context.traceId or nil,
            timeoutMs = 1000,
        })
        return ok
    end

    return reporting
end
