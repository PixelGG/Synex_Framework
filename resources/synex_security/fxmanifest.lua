fx_version 'cerulean'
game 'gta5'

name 'synex_security'
author 'Synex Framework'
description 'Server-authoritative security signal, correlation, case, and enforcement foundation for Synex'
version '0.1.0'

dependencies {
    '/onesync',
    'synex_core',
}

shared_scripts {
    'shared/limits.lua',
    'shared/validation.lua',
}

client_script 'client/sentinel.lua'

server_scripts {
    'server/foundation.lua',
    'server/ring_buffer.lua',
    'server/signals.lua',
    'server/expectations.lua',
    'server/correlation.lua',
    'server/cases.lua',
    'server/enforcement.lua',
    'server/sentinel.lua',
    'server/movement.lua',
    'server/runtime_adapters.lua',
    'server/detectors.lua',
    'server/cfx_guards.lua',
    'server/hardening.lua',
    'server/core_diagnostics_cursor.lua',
    'server/database.lua',
    'server/repository.lua',
    'server/observability.lua',
    'server/diagnostics.lua',
    'server/control_provider.lua',
    'server/service.lua',
    'server/runtime.lua',
    'server/server.lua',
}

files {
    'config/default.json',
    'contracts/security.contracts.json',
    'migrations/*.sql',
    'synex.resource.json',
}

synex_manifest 'synex.resource.json'
synex_contracts 'contracts/security.contracts.json'
