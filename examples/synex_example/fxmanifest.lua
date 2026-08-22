fx_version 'cerulean'
game 'gta5'

name 'synex_example'
description 'Minimal owner-aware Synex server resource example'
version '0.1.0'

dependency 'synex_core'

synex_manifest 'synex.resource.json'

server_script 'server.lua'

files {
    'contracts/example.contracts.json',
    'synex.resource.json'
}
