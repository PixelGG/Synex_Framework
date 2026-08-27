return function(Foundation)
local result = { read = {}, execute = {} }
local factories = {
        (require 'server.persistence.memberships_read'),
        (require 'server.persistence.memberships_invitations'),
        (require 'server.persistence.memberships_lifecycle'),
        (require 'server.persistence.memberships_access'),
        (require 'server.persistence.memberships_reporting')
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
