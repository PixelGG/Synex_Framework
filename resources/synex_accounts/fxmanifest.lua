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
    'server/outbox.lua',
    'server/retention.lua',
    'server/service.lua',
    'server/persistence.lua',
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
