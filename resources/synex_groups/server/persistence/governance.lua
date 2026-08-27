return function(Foundation)
local result = { read = {}, execute = {} }
local factories = {
        (require 'server.persistence.governance_capabilities'),
        (require 'server.persistence.governance_capability_rules'),
        (require 'server.persistence.governance_policies'),
        (require 'server.persistence.governance_attributes'),
        (require 'server.persistence.governance_attribute_activation'),
        (require 'server.persistence.governance_definitions')
}
for _, factory in ipairs(factories) do
    local built = factory(Foundation)
    for name, handler in pairs(built.read or {}) do result.read[name] = handler end
    for name, handler in pairs(built.execute or {}) do result.execute[name] = handler end
    if built.evaluateStoredPolicy ~= nil then
        result.evaluateStoredPolicy = built.evaluateStoredPolicy
    end
    if built.enforceMembershipActivation ~= nil then
        result.enforceMembershipActivation = built.enforceMembershipActivation
    end
end
return result
end
