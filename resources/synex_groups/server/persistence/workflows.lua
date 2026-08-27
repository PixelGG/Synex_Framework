return function(Foundation)
local result = { read = {}, execute = {} }
local factories = {
        (require 'server.persistence.workflows_duty'),
        (require 'server.persistence.workflows_assignments'),
        (require 'server.persistence.workflows_applications'),
        (require 'server.persistence.workflows_proposals')
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
