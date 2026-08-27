fx_version 'cerulean'
game 'gta5'

name 'synex_groups'
author 'Synex Framework'
description 'Synex server-authoritative organizations and membership engine'
version '0.1.0'

server_only 'yes'

dependency 'synex_core'

synex_manifest 'synex.resource.json'

server_scripts {
    'server/module_loader.lua',
    'server/runtime_registration.lua',
    'server/main.lua'
}

files {
    'server/cache.lua',
    'server/validation.lua',
    'server/domain/constants.lua',
    'server/domain/lifecycle.lua',
    'server/domain/graph.lua',
    'server/domain/capabilities.lua',
    'server/domain/policy.lua',
    'server/domain/registry.lua',
    'server/extension_registries.lua',
    'server/group_creation_approvals.lua',
    'server/group_deletions.lua',
    'server/scheduler.lua',
    'server/runtime_error.lua',
    'server/json_runtime.lua',
    'server/core_bootstrap.lua',
    'server/control_provider.lua',
    'server/domain/application_schema.lua',
    'server/foundation.lua',
    'server/database_adapter.lua',
    'server/runtime_index.lua',
    'server/outbox.lua',
    'server/service.lua',
    'server/persistence/effects.lua',
    'server/persistence/approved_operations.lua',
    'server/persistence/definition_cache.lua',
    'server/persistence/capability_access.lua',
    'server/persistence/runtime_context.lua',
    'server/persistence.lua',
    'server/persistence/organizations_shared.lua',
    'server/persistence/organizations_read.lua',
    'server/persistence/organizations_creation.lua',
    'server/persistence/organizations_lifecycle.lua',
    'server/persistence/organizations_creation_approvals.lua',
    'server/persistence/organizations_deletion.lua',
    'server/persistence/organizations_types.lua',
    'server/persistence/extension_registries.lua',
    'server/persistence/organizations_structure.lua',
    'server/persistence/organizations.lua',
    'server/persistence/memberships_shared.lua',
    'server/persistence/memberships_read.lua',
    'server/persistence/memberships_invitations.lua',
    'server/persistence/memberships_lifecycle.lua',
    'server/persistence/membership_transition_policies.lua',
    'server/persistence/memberships_access.lua',
    'server/persistence/memberships_reporting.lua',
    'server/persistence/compatibility.lua',
    'server/persistence/memberships.lua',
    'server/persistence/governance_shared.lua',
    'server/persistence/governance_capabilities.lua',
    'server/persistence/governance_capability_rules.lua',
    'server/persistence/governance_policies.lua',
    'server/persistence/governance_attribute_values.lua',
    'server/persistence/governance_attributes.lua',
    'server/persistence/governance_attribute_activation.lua',
    'server/persistence/governance_definitions_capabilities.lua',
    'server/persistence/governance_definitions_group_normalization.lua',
    'server/persistence/governance_definitions_hierarchy.lua',
    'server/persistence/governance_definitions_groups.lua',
    'server/persistence/governance_definitions.lua',
    'server/persistence/governance.lua',
    'server/persistence/workflows_shared.lua',
    'server/persistence/workflows_duty.lua',
    'server/persistence/workflows_assignments.lua',
    'server/persistence/workflow_reads.lua',
    'server/persistence/workflows_applications.lua',
    'server/persistence/workflows_proposals.lua',
    'server/persistence/workflows.lua',
    'server/persistence/diagnostics.lua',
    'server/persistence/workers.lua',
    'server/persistence/deletions.lua',
    'server/persistence/observability.lua',
    'server/contracts.lua',
    'synex.resource.json',
    'groups.contracts.json',
    'migrations/*.sql'
}
