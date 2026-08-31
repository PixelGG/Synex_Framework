fx_version 'cerulean'
game 'gta5'

name 'synex_interact'
author 'Synex Framework'
description 'Context-aware, server-authoritative interaction and gameplay orchestration runtime for Synex'
version '0.1.0'

dependencies {
    '/onesync',
    'synex_core',
    'synex_entities',
    'synex_world',
    'synex_ui',
}

shared_scripts {
    'shared/limits.lua',
    'shared/validation.lua',
}

client_scripts {
    'client/cancellation.lua',
    'client/sensor.lua',
    'client/intent.lua',
    'client/diagnostic_trace.lua',
    'client/runtime.lua',
}

server_scripts {
    'server/foundation.lua',
    'server/target_selector.lua',
    'server/world_authority.lua',
    'server/compiler.lua',
    'server/registry.lua',
    'server/entity_projection.lua',
    'server/bundle_loader.lua',
    'server/slots.lua',
    'server/actor_locks.lua',
    'server/sessions.lua',
    'server/authority.lua',
    'server/action_graph.lua',
    'server/observability.lua',
    'server/diagnostics.lua',
    'server/compatibility.lua',
    'server/service.lua',
    'server/control_provider.lua',
    'server/runtime.lua',
    'server/server.lua',
}

files {
    'synex.resource.json',
    'contracts/interact.contracts.json',
    'interactions/terminal.interact.json',
}

synex_manifest 'synex.resource.json'
synex_contracts 'contracts/interact.contracts.json'
