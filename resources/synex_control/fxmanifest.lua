fx_version 'cerulean'
game 'gta5'

author 'Synex Framework'
description 'Read-only Synex operations and diagnostics control plane'
version '0.1.0'

dependency 'synex_core'

shared_script 'shared/limits.lua'
client_script 'client/client.lua'
server_scripts {
    'server/sanitizer.lua',
    'server/request_protocol.lua',
    'server/server.lua',
}

ui_page 'web/index.html'
nui_callback_strict_mode 'true'

files {
    'synex.resource.json',
    'web/index.html',
    'web/app.js',
    'web/styles.css',
    'web/core/protocol.js',
    'web/transport/nui.js',
    'web/store/control-store.js',
    'web/components/renderers.js',
}

synex_manifest 'synex.resource.json'
