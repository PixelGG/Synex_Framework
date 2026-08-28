fx_version 'cerulean'
game 'gta5'

name 'synex_interact'
author 'Synex Framework'
description 'Context-aware interaction authority, intent arbitration, leases and action graphs for Synex'
version '0.1.0'

dependencies {
    '/onesync',
    'synex_core',
    'synex_world',
    'synex_entities',
    'synex_ui',
}

shared_scripts {
    'shared/limits.lua',
    'shared/validation.lua',
}

client_scripts {
    'client/context_sensor.lua',
    'client/runtime.lua',
}

server_scripts {
    'server/registry.lua',
    'server/lease_engine.lua',
    'server/action_graph.lua',
    'server/service.lua',
    'server/server.lua',
}

files {
    'synex.resource.json',
    'contracts/interact.contracts.json',
}

synex_manifest 'synex.resource.json'
synex_contracts 'contracts/interact.contracts.json'
