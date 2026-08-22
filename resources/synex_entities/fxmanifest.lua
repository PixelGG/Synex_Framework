fx_version 'cerulean'
game 'gta5'

author 'Synex Framework'
description 'Server-authoritative entity and routing-bucket foundation for Synex'
version '0.1.0'

server_only 'yes'

dependencies {
    '/onesync',
    'oxmysql',
    'synex_core',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'shared/validation.lua',
    'server/database.lua',
    'server/registry.lua',
    'server/foundation.lua',
    'server/repository.lua',
    'server/entity_runtime.lua',
    'server/entity_service.lua',
    'server/bucket_service.lua',
    'server/service.lua',
    'server/runtime.lua',
    'server/server.lua',
}

files {
    'synex.resource.json',
    'contracts/entities.contracts.json',
    'migrations/001_entities.sql',
}

synex_manifest 'synex.resource.json'
synex_contracts 'contracts/entities.contracts.json'
