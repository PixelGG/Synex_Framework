fx_version 'cerulean'
game 'gta5'

name 'synex_accounts'
author 'Synex Framework'
description 'Synex double-entry account and hold foundation service'
version '0.1.0'

server_only 'yes'

dependency 'synex_core'
dependency 'oxmysql'

synex_manifest 'synex.resource.json'

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/main.lua'
}

files {
    'server/foundation.lua',
    'server/json_runtime.lua',
    'server/domain.lua',
    'server/core_bootstrap.lua',
    'server/operator_adapter.lua',
    'server/control_provider.lua',
    'server/outbox.lua',
    'server/retention.lua',
    'server/service.lua',
    'server/service_v2/runtime.lua',
    'server/service_v2/catalog_accounts.lua',
    'server/service_v2/transactions_holds.lua',
    'server/service_v2/access_policy.lua',
    'server/service_v2/integrity.lua',
    'server/service_v2/guard.lua',
    'server/service_v2.lua',
    'server/lifecycle.lua',
    'server/persistence.lua',
    'server/persistence/engine_shared.lua',
    'server/persistence/accounts_v2.lua',
    'server/persistence/transactions.lua',
    'server/persistence/transaction_reads.lua',
    'server/persistence/holds_v2.lua',
    'server/persistence/access_v2.lua',
    'server/persistence/restrictions_v2.lua',
    'server/persistence/integrity_behavior.lua',
    'server/persistence/integrity_v2.lua',
    'server/persistence/integrity_control.lua',
    'server/persistence/observability_control.lua',
    'server/persistence/observability_inspect.lua',
    'server/persistence/observability.lua',
    'server/persistence/lifecycle.lua',
    'server/persistence/lifecycle_groups.lua',
    'server/persistence/accounts.lua',
    'server/persistence/ledger.lua',
    'server/persistence/holds.lua',
    'server/persistence/access.lua',
    'server/persistence/integrity.lua',
    'server/contracts.lua',
    'synex.resource.json',
    'accounts.contracts.json',
    'migrations/*.sql'
}
