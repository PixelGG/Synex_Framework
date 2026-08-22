local factories = assert(SynexCoreFactories, 'factories must be loaded first')

factories.identityCommon = function(deps)
    local foundation = assert(deps.foundation, 'identity common requires foundation')
    local owners = assert(deps.owners, 'identity common requires owner registry')

    local sessionTransitions = {
        DISCONNECTED = { CONNECTING = true },
        CONNECTING = { AUTHENTICATING = true, DISCONNECTING = true },
        AUTHENTICATING = { AUTHENTICATED = true, DISCONNECTING = true },
        AUTHENTICATED = { SELECTING_CHARACTER = true, DISCONNECTING = true },
        SELECTING_CHARACTER = { LOADING_CHARACTER = true, DISCONNECTING = true },
        LOADING_CHARACTER = { ACTIVE = true, SELECTING_CHARACTER = true, DISCONNECTING = true },
        ACTIVE = { UNLOADING_CHARACTER = true, DISCONNECTING = true },
        UNLOADING_CHARACTER = { SELECTING_CHARACTER = true, DISCONNECTING = true },
        DISCONNECTING = { CLOSED = true },
        CLOSED = {}
    }

    local function transition(session, target)
        if not sessionTransitions[session.state] or not sessionTransitions[session.state][target] then
            return nil, foundation.error('INVALID_SESSION_TRANSITION', ('Cannot transition a session from %s to %s.'):format(session.state, target))
        end
        session.state = target
        session.version = (session.version or 0) + 1
        session.updatedAt = foundation.utcIso()
        return session
    end

    local function invokeOwned(entry, handler, ...)
        local invocation = { cancelled = false, reason = nil }
        local token, operationError = owners:beginOperation(entry.owner, entry.epoch, function(reason)
            invocation.cancelled = true
            invocation.reason = tostring(reason or 'owner quiesced')
        end)
        if not token then return false, operationError end
        local ok, first, second = foundation.safeCall(handler, ...)
        owners:finishOperation(entry.owner, entry.epoch, token)
        if invocation.cancelled then
            return false, foundation.error('REQUEST_ABORTED', 'The owner callback was aborted while quiescing.', {
                retryable = true, details = { reason = invocation.reason }
            })
        end
        return ok, first, second
    end

    local allowedIdentifierTypes = { license = true, license2 = true, fivem = true, discord = true, steam = true, xbl = true, live = true }
    local function normalizeIdentifiers(raw)
        local result, seen = {}, {}
        for _, identifier in ipairs(raw or {}) do
            if type(identifier) == 'string' and #identifier <= 256 then
                local kind, value = identifier:match('^([a-z0-9_]+):(.+)$')
                if kind and allowedIdentifierTypes[kind] and #value >= 2 and #value <= 192 then
                    local normalized = kind .. ':' .. value:lower()
                    if not seen[normalized] then
                        seen[normalized] = true
                        result[#result + 1] = { type = kind, value = value:lower(), normalized = normalized }
                    end
                end
            end
        end
        table.sort(result, function(a, b)
            local priority = { license = 1, license2 = 2, fivem = 3, discord = 4, steam = 5, xbl = 6, live = 7 }
            local left, right = priority[a.type] or 100, priority[b.type] or 100
            if left == right then return a.normalized < b.normalized end
            return left < right
        end)
        return result
    end

    return {
        invokeOwned = invokeOwned,
        normalizeIdentifiers = normalizeIdentifiers,
        sessionTransitions = sessionTransitions,
        transition = transition
    }
end
