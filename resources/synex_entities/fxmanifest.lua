fx_version 'cerulean'
game 'gta5'

author 'Synex Framework'
description 'Server-authoritative entity and routing-bucket foundation for Synex'
version '0.1.0'

server_only 'yes'

dependencies {
    '/onesync',
    'oxmysql',
    'synex_core',
}

server_scripts {
    'shared/validation.lua',
    'server/bootstrap_config.lua',
    'server/database.lua',
    'server/ordered_index.lua',
    'server/json_values.lua',
    'server/extension_schema.lua',
    'server/archetypes.lua',
    'server/logical_owner.lua',
    'server/checkpoint_guard.lua',
    'server/mutation_lanes.lua',
    'server/spatial_index.lua',
    'server/registry.lua',
    'server/extension_registry.lua',
    'server/foundation.lua',
    'server/repository.lua',
    'server/authority_recovery_repository.lua',
    'server/authority_inspection_repository.lua',
    'server/authority_diagnostics_repository.lua',
    'server/authority_repository.lua',
    'server/extension_repository.lua',
    'server/component_lifecycle.lua',
    'server/observability.lua',
    'server/cleanup_queue.lua',
    'server/spawn_admission.lua',
    'server/lifecycle_policy.lua',
    'server/bucket_policy.lua',
    'server/entity_runtime.lua',
    'server/entity_service.lua',
    'server/bucket_lifecycle.lua',
    'server/bucket_service.lua',
    'server/authority_lifecycle.lua',
    'server/authority_service.lua',
    'server/extensions.lua',
    'server/diagnostics_analyzer.lua',
    'server/query_service.lua',
    'server/public_errors.lua',
    'server/service.lua',
    'server/control_provider_support.lua',
    'server/control_provider_inspect.lua',
    'server/control_provider.lua',
    'server/runtime.lua',
    'server/server.lua',
}

files {
    'synex.resource.json',
    'contracts/entities.contracts.json',
    'migrations/001_entities.sql',
    'migrations/002_entity_lifecycle_authority.sql',
    'migrations/003_entity_extensions.sql',
    'migrations/004_entity_cluster_recovery.sql',
}

synex_manifest 'synex.resource.json'
synex_contracts 'contracts/entities.contracts.json'
