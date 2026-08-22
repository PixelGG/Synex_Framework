local factories = assert(SynexCoreFactories, 'factories must be loaded first')

factories.identity = function(deps)
    local platform = assert(deps.platform, 'identity requires platform')
    local foundation = assert(deps.foundation, 'identity requires foundation')
    local database = assert(deps.database, 'identity requires database')
    local players = assert(deps.players, 'identity requires player registry')
    local owners = assert(deps.owners, 'identity requires owner registry')
    local lifecycle = assert(deps.lifecycle, 'identity requires lifecycle')
    local messaging = assert(deps.messaging, 'identity requires messaging')
    local leases = assert(deps.leases, 'identity requires cluster leases')
    local instances = assert(deps.instances, 'identity requires cluster instances')
    local rateLimiter = assert(deps.rateLimiter, 'identity requires rate limiter')
    local sha256 = assert(deps.sha256, 'identity requires SHA-256')

    local common = factories.identityCommon({
        foundation = foundation,
        owners = owners
    })
    local repositories = factories.identityRepository({
        platform = platform,
        foundation = foundation,
        database = database,
        players = players,
        config = deps.config,
        instanceId = deps.instanceId,
        normalizeIdentifiers = common.normalizeIdentifiers
    })
    local characters = factories.identityCharacters({
        platform = platform,
        foundation = foundation,
        database = database,
        players = players,
        owners = owners,
        messaging = messaging,
        coreResource = deps.coreResource,
        characterRepository = repositories.characters,
        sessionRepository = repositories.sessions,
        invokeOwned = common.invokeOwned,
        transition = common.transition,
        leases = leases,
        instances = instances,
        instanceId = deps.instanceId
    })
    local connections = factories.identityConnections({
        platform = platform,
        foundation = foundation,
        database = database,
        players = players,
        owners = owners,
        lifecycle = lifecycle,
        messaging = messaging,
        config = deps.config,
        instanceId = deps.instanceId,
        coreResource = deps.coreResource,
        leases = leases,
        instances = instances,
        characters = characters,
        userRepository = repositories.users,
        sessionRepository = repositories.sessions,
        accessRepository = repositories.access,
        rateLimiter = rateLimiter,
        sha256 = sha256,
        invokeOwned = common.invokeOwned,
        normalizeIdentifiers = common.normalizeIdentifiers,
        sessionTransitions = common.sessionTransitions,
        transition = common.transition
    })

    return {
        access = repositories.access,
        users = repositories.users,
        sessions = repositories.sessions,
        characters = characters,
        connections = connections,
        normalizeIdentifiers = common.normalizeIdentifiers,
        transitionSession = common.transition,
        sessionTransitions = common.sessionTransitions
    }
end
