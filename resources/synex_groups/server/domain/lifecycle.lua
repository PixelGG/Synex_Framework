local Constants = require 'server.domain.constants'

local Lifecycle = {}

local function domainError(code, message, details)
    return { code = code, message = message, retryable = false, details = details }
end

function Lifecycle.canTransition(entity, currentState, targetState)
    if not Constants.isEntity(entity) then
        return false, domainError('LIFECYCLE_ENTITY_INVALID', 'The lifecycle entity is not supported.')
    end
    if not Constants.isState(entity, currentState) then
        return false, domainError('LIFECYCLE_STATE_INVALID', 'The current lifecycle state is invalid.', {
            entity = entity, state = currentState
        })
    end
    if not Constants.isState(entity, targetState) then
        return false, domainError('LIFECYCLE_TARGET_INVALID', 'The target lifecycle state is invalid.', {
            entity = entity, state = targetState
        })
    end
    if currentState == targetState then
        return false, domainError('LIFECYCLE_NO_CHANGE', 'A lifecycle transition must change state.', {
            entity = entity, state = currentState
        })
    end
    if not Constants.canTransition(entity, currentState, targetState) then
        return false, domainError('LIFECYCLE_TRANSITION_DENIED', 'The lifecycle transition is not allowed.', {
            entity = entity, from = currentState, to = targetState
        })
    end
    return true, nil
end

function Lifecycle.transition(entity, currentState, targetState)
    local allowed, transitionError = Lifecycle.canTransition(entity, currentState, targetState)
    if not allowed then return nil, transitionError end
    return {
        entity = entity,
        from = currentState,
        to = targetState,
        terminal = Constants.isTerminal(entity, targetState)
    }, nil
end

function Lifecycle.allowedTargets(entity, state)
    if not Constants.isEntity(entity) then
        return nil, domainError('LIFECYCLE_ENTITY_INVALID', 'The lifecycle entity is not supported.')
    end
    local targets = Constants.targets(entity, state)
    if not targets then
        return nil, domainError('LIFECYCLE_STATE_INVALID', 'The lifecycle state is invalid.', {
            entity = entity, state = state
        })
    end
    return targets, nil
end

function Lifecycle.isTerminal(entity, state)
    if not Constants.isState(entity, state) then
        return nil, domainError('LIFECYCLE_STATE_INVALID', 'The lifecycle state is invalid.', {
            entity = entity, state = state
        })
    end
    return Constants.isTerminal(entity, state), nil
end

return Lifecycle
