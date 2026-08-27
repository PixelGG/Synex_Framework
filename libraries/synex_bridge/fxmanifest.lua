fx_version 'cerulean'
game 'gta5'

name 'synex_bridge'
description 'Optional clean-room compatibility gateway for Synex'
version '0.1.0'

dependency 'synex_core'

synex_manifest 'synex.resource.json'

server_scripts {
    'kernel/foundation.lua',
    'kernel/certification.lua',
    'kernel/catalogs.lua',
    'kernel/mappings.lua',
    'kernel/telemetry.lua',
    'kernel/resolver.lua',
    'kernel/runtime.lua',
    'control_provider.lua',
    'identity_store.lua',
    'server.lua'
}

files {
    'kernel/foundation.lua',
    'native_server.lua',
    'native_client.lua',
    'synex.resource.json',
    'compatibility/*.json',
    'compatibility/surfaces/*.json',
    'compatibility/schemas/*.schema.json',
    'migrations/*.sql'
}
