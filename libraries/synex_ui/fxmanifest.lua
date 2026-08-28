fx_version 'cerulean'
game 'gta5'

author 'Synex Framework'
description 'Synex UI library and shared NUI runtime foundation'
version '0.1.0'

dependency 'synex_core'

client_script 'client/client.lua'

ui_page 'web/dist/index.html'
nui_callback_strict_mode 'true'

files {
    'synex.resource.json',
    'client/owner_focus.lua',
    'web/dist/index.html',
    'web/dist/assets/*.js',
    'web/dist/assets/*.css',
    'web/dist/assets/*.woff2',
}

synex_manifest 'synex.resource.json'
