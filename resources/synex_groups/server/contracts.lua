return function(Foundation)
local API_VERSION = Foundation.API_VERSION

local function contractDefinitions()
    local id = { type = 'string', minLength = 36, maxLength = 36 }
    local shortText = { type = 'string', minLength = 1, maxLength = 96 }
    local mutationResponse = {
        type = 'object', additionalProperties = false,
        required = { 'membership_id', 'group_id', 'status', 'version' },
        properties = {
            membership_id = id, group_id = id, role_key = { type = 'string', minLength = 2, maxLength = 48 },
            status = { type = 'string' }, version = { type = 'integer', minimum = 1 }
        }
    }
    local membershipInput = {
        type = 'object', additionalProperties = false,
        required = { 'idempotency_key', 'group_id', 'subject_kind', 'subject_id', 'role_key' },
        properties = {
            idempotency_key = id, group_id = id, subject_kind = { type = 'string', enum = { 'user', 'character' } },
            subject_id = id, role_key = { type = 'string', minLength = 2, maxLength = 48 }, actor_ref = id
        }
    }
    local subjectProperties = {
        group_id = id, subject_kind = { type = 'string', enum = { 'user', 'character' } }, subject_id = id
    }
    local capabilityRule = {
        type = 'object', additionalProperties = false, required = { 'capability', 'effect' },
        properties = {
            capability = { type = 'string', minLength = 1, maxLength = 128 },
            effect = { type = 'string', enum = { 'allow', 'deny' } },
            version = { type = 'integer', minimum = 1 }
        }
    }
    return {
        {
            name = 'synex.groups.create', version = API_VERSION, network = 'none', capability = 'synex.groups.manage',
            input = {
                type = 'object', additionalProperties = false,
                required = { 'idempotency_key', 'group_key', 'display_name', 'group_type' },
                properties = {
                    idempotency_key = id, group_key = { type = 'string', minLength = 3, maxLength = 64 },
                    display_name = shortText, group_type = { type = 'string', minLength = 2, maxLength = 32 },
                    created_by_ref = id, metadata_json = { type = 'string', maxLength = 4096 }
                }
            },
            output = {
                type = 'object', additionalProperties = false,
                required = { 'group_id', 'group_key', 'status', 'version' },
                properties = {
                    group_id = id, group_key = { type = 'string' }, status = { type = 'string' },
                    version = { type = 'integer', minimum = 1 }
                }
            }
        },
        {
            name = 'synex.groups.get', version = API_VERSION, network = 'none', capability = 'synex.groups.read',
            input = { type = 'object', additionalProperties = false, required = { 'group_id' }, properties = { group_id = id } },
            output = {
                type = 'object', additionalProperties = false,
                required = { 'group_id', 'group_key', 'display_name', 'group_type', 'status', 'metadata_json', 'version', 'read_model_version', 'created_at', 'updated_at' },
                properties = {
                    group_id = id, group_key = { type = 'string' }, display_name = shortText, group_type = { type = 'string' },
                    status = { type = 'string' }, created_by_ref = { type = { 'string', 'nil' } }, metadata_json = { type = 'string' },
                    version = { type = 'integer' }, read_model_version = { type = 'integer', minimum = 1 },
                    created_at = { type = 'string' }, updated_at = { type = 'string' }
                }
            }
        },
        { name = 'synex.groups.add_membership', version = API_VERSION, network = 'none', capability = 'synex.groups.manage', input = membershipInput, output = mutationResponse },
        { name = 'synex.groups.change_membership', version = API_VERSION, network = 'none', capability = 'synex.groups.manage', input = membershipInput, output = mutationResponse },
        {
            name = 'synex.groups.remove_membership', version = API_VERSION, network = 'none', capability = 'synex.groups.manage',
            input = {
                type = 'object', additionalProperties = false,
                required = { 'idempotency_key', 'group_id', 'subject_kind', 'subject_id' },
                properties = {
                    idempotency_key = id, group_id = id, subject_kind = { type = 'string', enum = { 'user', 'character' } },
                    subject_id = id, actor_ref = id
                }
            },
            output = mutationResponse
        },
        {
            name = 'synex.groups.create_grade', version = API_VERSION, network = 'none', capability = 'synex.groups.grades.manage',
            input = {
                type = 'object', additionalProperties = false,
                required = { 'idempotency_key', 'group_id', 'grade_key', 'display_name', 'rank_value' },
                properties = {
                    idempotency_key = id, group_id = id, grade_key = { type = 'string', minLength = 2, maxLength = 48 },
                    display_name = shortText, rank_value = { type = 'integer', minimum = -32768, maximum = 32767 }, actor_ref = id
                }
            },
            output = {
                type = 'object', additionalProperties = false,
                required = { 'grade_id', 'group_id', 'grade_key', 'display_name', 'rank_value', 'status', 'version' },
                properties = {
                    grade_id = id, group_id = id, grade_key = { type = 'string' }, display_name = shortText,
                    rank_value = { type = 'integer' }, status = { type = 'string' }, version = { type = 'integer' }
                }
            }
        },
        {
            name = 'synex.groups.set_grade_capability', version = API_VERSION, network = 'none', capability = 'synex.groups.grades.manage',
            input = {
                type = 'object', additionalProperties = false,
                required = { 'idempotency_key', 'grade_id', 'capability', 'effect' },
                properties = {
                    idempotency_key = id, grade_id = id, capability = { type = 'string', minLength = 1, maxLength = 128 },
                    effect = { type = 'string', enum = { 'allow', 'deny' } }, actor_ref = id
                }
            },
            output = {
                type = 'object', additionalProperties = false,
                required = { 'grade_id', 'group_id', 'capability', 'effect' },
                properties = { grade_id = id, group_id = id, capability = { type = 'string' }, effect = { type = 'string' } }
            }
        },
        {
            name = 'synex.groups.set_primary_membership', version = API_VERSION, network = 'none', capability = 'synex.groups.memberships.primary',
            input = {
                type = 'object', additionalProperties = false,
                required = { 'idempotency_key', 'group_id', 'subject_kind', 'subject_id' },
                properties = {
                    idempotency_key = id, group_id = id,
                    subject_kind = { type = 'string', enum = { 'user', 'character' } }, subject_id = id, actor_ref = id
                }
            },
            output = {
                type = 'object', additionalProperties = false,
                required = { 'membership_id', 'group_id', 'subject_kind', 'subject_id', 'primary_version' },
                properties = {
                    membership_id = id, group_id = id, subject_kind = { type = 'string' }, subject_id = id,
                    primary_version = { type = 'integer', minimum = 1 }
                }
            }
        },
        {
            name = 'synex.groups.get_read_model', version = API_VERSION, network = 'none', capability = 'synex.groups.read',
            input = {
                type = 'object', additionalProperties = false,
                required = { 'group_id', 'subject_kind', 'subject_id' }, properties = subjectProperties
            },
            output = {
                type = 'object', additionalProperties = false,
                required = {
                    'group_id', 'group_key', 'read_model_version', 'invalidated_at', 'membership_id',
                    'membership_status', 'membership_version', 'grade_id', 'grade_key', 'grade_display_name',
                    'rank_value', 'grade_version', 'is_primary', 'capabilities'
                },
                properties = {
                    group_id = id, group_key = { type = 'string' }, read_model_version = { type = 'integer' },
                    invalidated_at = { type = 'string' }, membership_id = id, membership_status = { type = 'string' },
                    membership_version = { type = 'integer' }, grade_id = id, grade_key = { type = 'string' },
                    grade_display_name = shortText, rank_value = { type = 'integer' }, grade_version = { type = 'integer' },
                    is_primary = { type = 'boolean' }, primary_version = { type = 'integer' },
                    capabilities = { type = 'array', maxItems = 128, items = capabilityRule }
                }
            }
        },
        {
            name = 'synex.groups.check_capability', version = API_VERSION, network = 'none', capability = 'synex.groups.read',
            input = {
                type = 'object', additionalProperties = false,
                required = { 'group_id', 'subject_kind', 'subject_id', 'capability' },
                properties = {
                    group_id = id, subject_kind = { type = 'string', enum = { 'user', 'character' } }, subject_id = id,
                    capability = { type = 'string', minLength = 1, maxLength = 128 }
                }
            },
            output = {
                type = 'object', additionalProperties = false,
                required = {
                    'group_id', 'membership_id', 'grade_id', 'capability', 'allowed', 'denied',
                    'read_model_version', 'matched_rules'
                },
                properties = {
                    group_id = id, membership_id = id, grade_id = id, capability = { type = 'string' },
                    allowed = { type = 'boolean' }, denied = { type = 'boolean' },
                    read_model_version = { type = 'integer' },
                    matched_rules = { type = 'array', maxItems = 128, items = capabilityRule }
                }
            }
        }
    }
end

return contractDefinitions
end
