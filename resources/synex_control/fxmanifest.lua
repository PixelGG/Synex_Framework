fx_version 'cerulean'
game 'gta5'

author 'Synex Framework'
description 'Read-only Synex runtime, health, and metrics control surface'
version '0.1.0'

dependency 'synex_core'

shared_script 'shared/limits.lua'
client_script 'client/client.lua'
server_script 'server/server.lua'

ui_page 'web/index.html'
nui_callback_strict_mode 'true'

files {
    'synex.resource.json',
    'web/index.html',
    'web/app.js',
    'web/styles.css',
}

synex_manifest 'synex.resource.json'
