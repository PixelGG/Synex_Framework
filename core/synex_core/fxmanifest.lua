fx_version 'cerulean'
game 'gta5'

name 'synex_core'
description 'Synex framework kernel'
version '0.1.0'

dependency 'oxmysql'

synex_manifest 'synex.resource.json'

shared_scripts {
    'shared/protocol.lua',
    'shared/generated_contracts.lua'
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/factories.lua',
    'server/platform.lua',
    'server/foundation.lua',
    'server/configuration.lua',
    'server/runtime_configuration.lua',
    'server/runtime_gate.lua',
    'server/resource_manifest.lua',
    'server/persistence.lua',
    'server/runtime_persistence.lua',
    'server/registries.lua',
    'server/lifecycle.lua',
    'server/contracts.lua',
    'server/security.lua',
    'server/messaging.lua',
    'server/identity_common.lua',
    'server/identity_repository.lua',
    'server/identity_characters.lua',
    'server/identity_connection_replacement.lua',
    'server/identity_connection_claims.lua',
    'server/identity_connection_authority.lua',
    'server/identity_connection_terminals.lua',
    'server/identity_connection_join.lua',
    'server/identity_connection_maintenance.lua',
    'server/identity_connections.lua',
    'server/identity.lua',
    'server/state.lua',
    'server/reliability.lua',
    'server/retention.lua',
    'server/saga_runtime.lua',
    'server/commands.lua',
    'server/bootstrap_discovery.lua',
    'server/bootstrap_api.lua',
    'server/bootstrap_diagnostics.lua',
    'server/bootstrap_restart.lua',
    'server/bootstrap_lifecycle.lua',
    'server/bootstrap.lua',
    'server/main.lua'
}

client_script 'client/client.lua'

files {
    'config/default.json',
    'config/capabilities.json',
    'contracts/*.json',
    'synex.resource.json',
    'migrations/*.sql'
}
