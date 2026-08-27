fx_version 'cerulean'
game 'gta5'

name 'synex_bridge_qb'
description 'Consumer-bound QBCore compatibility bridge backed by native Synex services'
version '0.1.0'

dependency 'synex_core'
dependency 'synex_bridge'
dependency 'synex_accounts'
dependency 'synex_groups'

synex_manifest 'synex.resource.json'

server_scripts {
    '@synex_bridge/kernel/foundation.lua',
    '@synex_bridge/native_server.lua',
    'server.lua'
}

client_scripts {
    '@synex_bridge/native_client.lua',
    'client.lua'
}

files {
    'synex.resource.json'
}
