fx_version 'cerulean'
game 'gta5'

name 'synex_bridge'
description 'Optional clean-room compatibility gateway for Synex'
version '0.1.0'

dependency 'synex_core'

synex_manifest 'synex.resource.json'

server_script 'server.lua'

files {
    'native_server.lua',
    'native_client.lua',
    'synex.resource.json'
}
