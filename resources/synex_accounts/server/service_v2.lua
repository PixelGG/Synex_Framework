return function(Foundation, Domain)
local createRuntime = require('server.service_v2.runtime')(Foundation, Domain)
local attachCatalogAccounts = require 'server.service_v2.catalog_accounts'
local attachTransactionsHolds = require 'server.service_v2.transactions_holds'
local attachAccessPolicy = require 'server.service_v2.access_policy'
local attachIntegrity = require 'server.service_v2.integrity'
local guardService = require 'server.service_v2.guard'

local function createService(deps)
    local service, runtime = createRuntime(deps)
    attachCatalogAccounts(service, runtime)
    attachTransactionsHolds(service, runtime)
    attachAccessPolicy(service, runtime)
    attachIntegrity(service, runtime)
    return guardService(service, runtime)
end

return createService
end
