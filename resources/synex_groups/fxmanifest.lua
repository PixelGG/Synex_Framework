fx_version 'cerulean'
game 'gta5'

name 'synex_groups'
author 'Synex Framework'
description 'Synex group and membership foundation service'
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
    'server/outbox.lua',
    'server/service.lua',
    'server/persistence.lua',
    'server/persistence/observability.lua',
    'server/contracts.lua',
    'synex.resource.json',
    'groups.contracts.json',
    'migrations/*.sql'
}
