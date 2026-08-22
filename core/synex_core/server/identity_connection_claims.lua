local factories = assert(SynexCoreFactories, 'factories must be loaded first')

factories.identityConnectionClaims = function(deps)
    local foundation = assert(deps.foundation, 'connection claims require foundation')
    local active = {}
    local claims = {}

    function claims:begin(playerSource, connectionId)
        local token = foundation.nextId('join_claim')
        active[playerSource] = { token = token, connectionId = connectionId }
        return token
    end

    function claims:isCurrent(playerSource, token, connectionId)
        local claim = active[playerSource]
        return claim ~= nil and claim.token == token and claim.connectionId == connectionId
    end

    function claims:clear(playerSource, token)
        local claim = active[playerSource]
        if claim and claim.token == token then active[playerSource] = nil return true end
        return false
    end

    function claims:invalidate(playerSource)
        active[playerSource] = nil
    end

    return claims
end
