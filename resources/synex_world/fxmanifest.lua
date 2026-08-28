fx_version 'cerulean'
game 'gta5'

name 'synex_world'
author 'Synex Framework'
description 'Server-authoritative world semantics and spatial authority foundation for Synex'
version '0.1.0'

dependencies {
    '/onesync',
    'synex_core',
    'synex_entities',
}

shared_scripts {
    'shared/limits.lua',
    'shared/validation.lua',
}

client_script 'client/runtime.lua'

server_scripts {
    'server/foundation.lua',
    'server/observability.lua',
    'server/geometry.lua',
    'server/graph.lua',
    'server/compiler.lua',
    'server/spatial_index.lua',
    'server/registry.lua',
    'server/map_registry.lua',
    'server/context.lua',
    'server/database_adapter.lua',
    'server/repository.lua',
    'server/outbox.lua',
    'server/state_engine.lua',
    'server/door_engine.lua',
    'server/instances.lua',
    'server/access.lua',
    'server/portals.lua',
    'server/presence.lua',
    'server/slices.lua',
    'server/bundle_loader.lua',
    'server/diagnostics.lua',
    'server/service.lua',
    'server/control_provider.lua',
    'server/runtime.lua',
    'server/server.lua',
}

files {
    'synex.resource.json',
    'contracts/world.contracts.json',
    'migrations/001_world.sql',
}

synex_manifest 'synex.resource.json'
synex_contracts 'contracts/world.contracts.json'
