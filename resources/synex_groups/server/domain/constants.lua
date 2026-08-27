local Constants = {}

Constants.ENTITY = {
    GROUP = 'group',
    MEMBERSHIP = 'membership',
    INVITE = 'invite',
    APPLICATION = 'application',
    DUTY = 'duty',
    ASSIGNMENT = 'assignment',
    PROPOSAL = 'proposal'
}

Constants.DECISION = { ALLOW = 'ALLOW', DENY = 'DENY' }
Constants.EFFECT = { ALLOW = 'allow', DENY = 'deny' }

Constants.STATE = {
    group = {
        DRAFT = 'draft', ACTIVE = 'active', SUSPENDED = 'suspended',
        ARCHIVED = 'archived', DISSOLVING = 'dissolving', DELETED = 'deleted'
    },
    membership = {
        DRAFT = 'DRAFT', INVITED = 'INVITED', APPLICANT = 'APPLICANT',
        UNDER_REVIEW = 'UNDER_REVIEW', APPROVED = 'APPROVED', PROBATION = 'PROBATION',
        ACTIVE = 'ACTIVE', SUSPENDED = 'SUSPENDED', LEAVE = 'LEAVE',
        INACTIVE = 'INACTIVE', TERMINATED = 'TERMINATED', BANNED = 'BANNED',
        LEFT = 'LEFT', ARCHIVED = 'ARCHIVED'
    },
    invite = {
        PENDING = 'pending', ACCEPTED = 'accepted', DECLINED = 'declined',
        REVOKED = 'revoked', EXPIRED = 'expired'
    },
    application = {
        SUBMITTED = 'submitted', REVIEWING = 'reviewing', APPROVED = 'approved',
        REJECTED = 'rejected', WITHDRAWN = 'withdrawn', EXPIRED = 'expired'
    },
    duty = {
        OPEN = 'open', CLOSED = 'closed'
    },
    assignment = {
        ACTIVE = 'active', COMPLETED = 'completed', CANCELLED = 'cancelled', EXPIRED = 'expired'
    },
    proposal = {
        PENDING = 'pending', APPROVED = 'approved', REJECTED = 'rejected',
        EXECUTED = 'executed', CANCELLED = 'cancelled', EXPIRED = 'expired'
    }
}

local transitions = {
    group = {
        draft = { active = true, archived = true },
        active = { suspended = true, archived = true },
        suspended = { active = true, archived = true },
        archived = { dissolving = true },
        dissolving = { deleted = true },
        deleted = {}
    },
    membership = {
        DRAFT = { INVITED = true, APPLICANT = true },
        INVITED = { DRAFT = true, PROBATION = true, ACTIVE = true },
        APPLICANT = { DRAFT = true, UNDER_REVIEW = true },
        UNDER_REVIEW = { DRAFT = true, APPROVED = true },
        APPROVED = { PROBATION = true, ACTIVE = true },
        PROBATION = { ACTIVE = true, SUSPENDED = true, LEAVE = true,
            INACTIVE = true, TERMINATED = true, BANNED = true,
            LEFT = true, ARCHIVED = true },
        ACTIVE = { SUSPENDED = true, LEAVE = true, INACTIVE = true,
            TERMINATED = true, BANNED = true, LEFT = true, ARCHIVED = true },
        SUSPENDED = { PROBATION = true, ACTIVE = true, LEAVE = true,
            INACTIVE = true, TERMINATED = true, BANNED = true,
            LEFT = true, ARCHIVED = true },
        LEAVE = { PROBATION = true, ACTIVE = true, SUSPENDED = true,
            INACTIVE = true, TERMINATED = true, BANNED = true,
            LEFT = true, ARCHIVED = true },
        INACTIVE = { PROBATION = true, ACTIVE = true, SUSPENDED = true,
            TERMINATED = true, BANNED = true, LEFT = true, ARCHIVED = true },
        TERMINATED = {}, BANNED = {}, LEFT = {}, ARCHIVED = {}
    },
    invite = {
        pending = { accepted = true, declined = true, revoked = true, expired = true },
        accepted = {}, declined = {}, revoked = {}, expired = {}
    },
    application = {
        submitted = { reviewing = true, withdrawn = true, expired = true },
        reviewing = {
            approved = true, rejected = true, withdrawn = true, expired = true
        },
        approved = {}, rejected = {}, withdrawn = {}, expired = {}
    },
    duty = {
        open = { closed = true }, closed = {}
    },
    assignment = {
        active = { completed = true, cancelled = true, expired = true },
        completed = {}, cancelled = {}, expired = {}
    },
    proposal = {
        pending = { approved = true, rejected = true, cancelled = true, expired = true },
        approved = { executed = true, cancelled = true, expired = true },
        rejected = {}, cancelled = {}, expired = {}, executed = {}
    }
}

local function sortedKeys(values)
    local result = {}
    for key in pairs(values) do result[#result + 1] = key end
    table.sort(result)
    return result
end

function Constants.entities()
    return sortedKeys(transitions)
end

function Constants.states(entity)
    local entityTransitions = transitions[entity]
    if not entityTransitions then return nil end
    return sortedKeys(entityTransitions)
end

function Constants.targets(entity, state)
    local entityTransitions = transitions[entity]
    local stateTransitions = entityTransitions and entityTransitions[state]
    if not stateTransitions then return nil end
    return sortedKeys(stateTransitions)
end

function Constants.isEntity(entity)
    return type(entity) == 'string' and transitions[entity] ~= nil
end

function Constants.isState(entity, state)
    return type(state) == 'string' and transitions[entity] ~= nil and transitions[entity][state] ~= nil
end

function Constants.isTerminal(entity, state)
    local stateTransitions = transitions[entity] and transitions[entity][state]
    return stateTransitions ~= nil and next(stateTransitions) == nil
end

function Constants.canTransition(entity, currentState, targetState)
    local stateTransitions = transitions[entity] and transitions[entity][currentState]
    return stateTransitions ~= nil and stateTransitions[targetState] == true
end

return Constants
