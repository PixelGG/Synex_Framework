return function(Foundation)
local result = { read = {}, execute = {} }
local factories = {
        (require 'server.persistence.organizations_read'),
        (require 'server.persistence.organizations_creation'),
        (require 'server.persistence.organizations_lifecycle'),
        (require 'server.persistence.organizations_creation_approvals'),
        (require 'server.persistence.organizations_types'),
        (require 'server.persistence.extension_registries'),
        (require 'server.persistence.organizations_structure'),
        (require 'server.persistence.governance_capability_rules')
}
for _, factory in ipairs(factories) do
    local built = factory(Foundation)
    for name, handler in pairs(built.read or {}) do result.read[name] = handler end
    for name, handler in pairs(built.execute or {}) do result.execute[name] = handler end
    if built.evaluateStoredPolicy ~= nil then
        result.evaluateStoredPolicy = built.evaluateStoredPolicy
    end
end
return result
end
