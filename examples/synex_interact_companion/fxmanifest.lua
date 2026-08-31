fx_version 'cerulean'
game 'gta5'

name 'synex_interact_companion'
author 'Synex Framework'
description 'Minimal declarative Synex World Anchor and Interact bundle example'
version '0.1.0'

dependencies {
    '/onesync',
    'synex_core',
    'synex_entities',
    'synex_world',
    'synex_ui',
    'synex_interact',
}

files {
    'synex.resource.json',
    'world/terminal.world.json',
    'interactions/terminal.interact.json',
}

synex_manifest 'synex.resource.json'
