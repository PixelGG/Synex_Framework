fx_version 'cerulean'
game 'gta5'

name 'synex_notify'
author 'Synex Framework'
description 'Resource-owned feedback and notification orchestration for Synex'
version '0.1.0'

dependency 'synex_core'

shared_scripts {
    'shared/limits.lua',
    'shared/validation.lua',
}

client_scripts {
    'client/engine.lua',
    'client/runtime.lua',
}

server_scripts {
    'server/foundation.lua',
    'server/observability.lua',
    'server/registry.lua',
    'server/service.lua',
    'server/control_provider.lua',
    'server/runtime.lua',
    'server/server.lua',
}

files {
    'synex.resource.json',
    'contracts/notify.contracts.json',
}

synex_manifest 'synex.resource.json'
synex_contracts 'contracts/notify.contracts.json'
