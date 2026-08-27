local Constants = require 'server.domain.constants'

local Policy = {}

local function domainError(code, message, details)
    return { code = code, message = message, retryable = false, details = details }
end

local function arrayLength(value, maximum)
    if type(value) ~= 'table' or getmetatable(value) ~= nil then return nil end
    local count, highest = 0, 0
    for key in pairs(value) do
        if type(key) ~= 'number' or math.type(key) ~= 'integer' or key < 1 then return nil end
        count = count + 1
        if count > maximum then return nil end
        highest = math.max(highest, key)
    end
    if highest ~= count then return nil end
    return count
end

function Policy.create(options)
    if type(options) ~= 'table' or getmetatable(options) ~= nil
        or type(options.capabilities) ~= 'table' or getmetatable(options.capabilities) ~= nil
        or type(options.capabilities.evaluate) ~= 'function' then
        error('policy requires a capability evaluator', 2)
    end
    for key in pairs(options) do
        if key ~= 'capabilities' and key ~= 'maximumGates' then
            error('policy options contain an unknown property', 2)
        end
    end
    local capabilities = options.capabilities
    local maximumGates = options.maximumGates or 16
    if type(maximumGates) ~= 'number' or math.type(maximumGates) ~= 'integer'
        or maximumGates < 0 or maximumGates > 64 then
        error('policy maximumGates is outside supported bounds', 2)
    end

    local engine = {}

    function engine:decide(input)
        if type(input) ~= 'table' or getmetatable(input) ~= nil then
            return nil, domainError('POLICY_REQUEST_INVALID', 'Policy request must be a plain object.')
        end
        local allowed = {
            capability = true, scope = true, at = true, defaults = true,
            grade = true, roles = true, membership = true, delegations = true, gates = true
        }
        for key in pairs(input) do
            if not allowed[key] then
                return nil, domainError('POLICY_REQUEST_INVALID', 'Policy request contains an unknown property.', {
                    property = tostring(key)
                })
            end
        end
        local gateCount = arrayLength(input.gates or {}, maximumGates)
        if gateCount == nil then
            return nil, domainError('POLICY_GATES_INVALID', 'Policy gates must be a bounded dense array.')
        end
        local gateTrace = {}
        local firstDenied
        for index = 1, gateCount do
            local gate = input.gates[index]
            if type(gate) ~= 'table' or getmetatable(gate) ~= nil then
                return nil, domainError('POLICY_GATE_INVALID', 'Policy gate must be a plain object.', { index = index })
            end
            for key in pairs(gate) do
                if key ~= 'name' and key ~= 'allowed' and key ~= 'reason' then
                    return nil, domainError('POLICY_GATE_INVALID', 'Policy gate contains an unknown property.', {
                        index = index, property = tostring(key)
                    })
                end
            end
            if type(gate.name) ~= 'string' or #gate.name < 1 or #gate.name > 64
                or gate.name:match('^[a-z][a-z0-9_.%-]*$') == nil
                or type(gate.allowed) ~= 'boolean'
                or (gate.reason ~= nil and (type(gate.reason) ~= 'string' or #gate.reason < 1
                    or #gate.reason > 64 or gate.reason:match('^[A-Z][A-Z0-9_]*$') == nil)) then
                return nil, domainError('POLICY_GATE_INVALID', 'Policy gate fields are invalid.', { index = index })
            end
            local trace = {
                name = gate.name,
                allowed = gate.allowed,
                reason = gate.allowed and 'GATE_ALLOWED' or (gate.reason or 'GATE_DENIED')
            }
            gateTrace[#gateTrace + 1] = trace
            if not gate.allowed and not firstDenied then firstDenied = trace end
        end
        if firstDenied then
            return {
                decision = Constants.DECISION.DENY,
                reason = firstDenied.reason,
                capability = input.capability,
                trace = { gates = gateTrace, capabilities = {} }
            }, nil
        end

        local capabilityInput = {}
        for key, value in pairs(input) do
            if key ~= 'gates' then capabilityInput[key] = value end
        end
        local evaluation, evaluationError = capabilities:evaluate(capabilityInput)
        if not evaluation then return nil, evaluationError end

        local reason = 'CAPABILITY_NOT_GRANTED'
        if evaluation.denied then
            reason = 'CAPABILITY_EXPLICITLY_DENIED'
        elseif evaluation.allowed then
            reason = 'CAPABILITY_GRANTED'
        end
        return {
            decision = evaluation.allowed and Constants.DECISION.ALLOW or Constants.DECISION.DENY,
            reason = reason,
            capability = evaluation.capability,
            evaluatedAt = evaluation.evaluatedAt,
            trace = { gates = gateTrace, capabilities = evaluation.trace },
            evaluation = evaluation
        }, nil
    end

    return engine
end

return Policy
