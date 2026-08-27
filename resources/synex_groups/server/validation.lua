return function(Foundation)
local validation = {}
local MAXIMUM_DEFINITION_ITEMS = 16
local MAXIMUM_DEFINITION_WORK = 1024
local function fields(value)
    local list, lookup = {}, {}
    for field in value:gmatch('%S+') do
        list[#list + 1] = field
        lookup[field] = true
    end
    return list, lookup
end
local operationShapes = {
    create = { 'idempotency_key actor_character_id type slug name label', 'parent_group_id description visibility dynamic metadata status' },
    get = { 'group_id', '' },
    list = { '', 'type status parent_group_id cursor limit' },
    update = { 'idempotency_key actor_character_id group_id expected_version', 'slug name label description visibility parent_group_id status reason' },
    archive = { 'idempotency_key actor_character_id group_id expected_version reason', '' },
    delete = { 'idempotency_key actor_character_id group_id expected_version reason', '' },
    types_register = { 'idempotency_key type schema_version label', 'dynamic_creation max_members max_active_members create_permission required_approvals approval_permission default_grades default_roles allowed_membership_states allowed_duty_states metadata' },
    registries_begin = { 'idempotency_key', '' },
    creation_requests_get = { 'actor_character_id creation_request_id', '' },
    creation_requests_approve = { 'idempotency_key actor_character_id creation_request_id expected_version reason', '' },
    creation_requests_reject = { 'idempotency_key actor_character_id creation_request_id expected_version reason', '' },
    relation_types_register = { 'idempotency_key type schema_version label direction', '' },
    duty_states_register = { 'idempotency_key state schema_version label counts_as_on_duty', '' },
    relationships_get = { 'actor_character_id group_id relationship_id', '' },
    relationships_list = { 'actor_character_id group_id', 'direction relation_type status cursor limit' },
    relationships_create = { 'idempotency_key actor_character_id source_group_id target_group_id relation_type', 'valid_from valid_until metadata' },
    relationships_update = { 'idempotency_key actor_character_id relationship_id expected_version status', 'valid_until reason' },
    members_get = { 'membership_id', '' },
    members_list = { 'group_id actor_character_id', 'status cursor limit' },
    members_invite = { 'idempotency_key actor_character_id group_id character_id', 'grade_id role_ids expires_at reason' },
    members_accept = { 'idempotency_key actor_character_id invitation_id', '' },
    members_decline = { 'idempotency_key actor_character_id invitation_id expected_version reason', '' },
    members_revoke_invite = { 'idempotency_key actor_character_id invitation_id expected_version reason', '' },
    members_transition = { 'idempotency_key actor_character_id membership_id expected_version status', 'reason' },
    members_transition_policy_get = {
        'actor_character_id group_id from_status to_status', ''
    },
    members_transition_policy_set = {
        'idempotency_key actor_character_id group_id from_status to_status allowed required_capability approval_required reason_required',
        'expected_version reason'
    },
    members_set_grade = { 'idempotency_key actor_character_id membership_id grade_id expected_version reason', '' },
    members_set_visibility = {
        'idempotency_key actor_character_id membership_id visibility expected_version reason', ''
    },
    members_set_primary = { 'idempotency_key actor_character_id membership_id group_type', '' },
    reporting_set = { 'idempotency_key actor_character_id membership_id reason expected_version', 'reports_to_membership_id' },
    grades_create = { 'idempotency_key actor_character_id group_id key label rank', 'capacity' },
    grades_update = { 'idempotency_key actor_character_id grade_id expected_version', 'label rank capacity status reason' },
    roles_create = { 'idempotency_key actor_character_id group_id key label', 'description assignable exclusive capacity' },
    roles_update = { 'idempotency_key actor_character_id role_id expected_version', 'label description assignable exclusive status reason' },
    roles_assign = { 'idempotency_key actor_character_id membership_id role_id', 'valid_from valid_until reason' },
    roles_remove = { 'idempotency_key actor_character_id membership_role_id expected_version reason', '' },
    capabilities_set = { 'idempotency_key actor_character_id group_id source_type source_id capability effect', 'expected_version reason scope delegable' },
    capabilities_check = { 'character_id group_id capability', 'actor_character_id scope' },
    capabilities_explain = { 'character_id group_id capability', 'actor_character_id scope' },
    duty_start = { 'idempotency_key actor_character_id membership_id state', 'assignment_id metadata' },
    duty_update = { 'idempotency_key actor_character_id duty_session_id expected_version state assignment_id metadata', '' },
    duty_stop = { 'idempotency_key actor_character_id duty_session_id expected_version reason', '' },
    duty_list = { 'actor_character_id group_id', 'membership_id status cursor limit' },
    assignments_get = { 'actor_character_id assignment_id', '' },
    assignments_list = { 'actor_character_id group_id', 'status cursor limit' },
    assignments_create = { 'idempotency_key actor_character_id group_id name type', 'parent_assignment_id starts_at ends_at metadata' },
    assignments_join = { 'idempotency_key actor_character_id assignment_id membership_id', 'role' },
    assignments_leave = { 'idempotency_key actor_character_id assignment_member_id expected_version reason', '' },
    assignments_complete = { 'idempotency_key actor_character_id assignment_id expected_version reason', '' },
    assignments_cancel = { 'idempotency_key actor_character_id assignment_id expected_version reason', '' },
    delegations_create = { 'idempotency_key actor_character_id group_id grantee_membership_id capability valid_until reason', 'scope valid_from' },
    delegations_revoke = { 'idempotency_key actor_character_id delegation_id expected_version reason', '' },
    applications_submit = { 'idempotency_key actor_character_id group_id schema_version data', '' },
    applications_review = { 'idempotency_key actor_character_id application_id expected_version decision reason', '' },
    applications_withdraw = { 'idempotency_key actor_character_id application_id expected_version reason', '' },
    proposals_create = { 'idempotency_key actor_character_id group_id action payload required_approvals expires_at', 'reason' },
    proposals_approve = { 'idempotency_key actor_character_id proposal_id expected_version reason', '' },
    proposals_reject = { 'idempotency_key actor_character_id proposal_id expected_version reason', '' },
    policies_set = { 'idempotency_key actor_character_id group_id action definition', 'expected_version reason' },
    policies_simulate = { 'actor_character_id group_id action', 'target_membership_id parameters' },
    attributes_get = { 'actor_character_id membership_id namespace key', '' },
    attributes_register_schema = { 'idempotency_key namespace key type visibility schema_version', 'validation capability group_type required default' },
    attributes_set = { 'idempotency_key actor_character_id membership_id namespace key value', 'expected_version reason' },
    definitions_sync = { 'idempotency_key schema_version definitions dry_run', 'owner_resource' },
    directory_list = { 'actor_character_id group_id', 'cursor limit' },
    history_list = { 'actor_character_id group_id', 'entity_type entity_id cursor limit' },
    self_snapshot = { 'actor_character_id', 'cursor limit' },
    compatibility_snapshot = { 'actor_character_id', 'cursor limit' },
    compatibility_resolve_target = { 'actor_character_id group_type group_key grade_key', '' }, compatibility_set_primary_grade = { 'idempotency_key actor_character_id membership_id grade_id expected_version group_type expected_primary_version reason', '' },
    doctor = { '', '' }
}
for _, definition in pairs(operationShapes) do
    local required, allowed = fields(definition[1])
    local _, optional = fields(definition[2])
    for field in pairs(optional) do allowed[field] = true end
    definition.required = required
    definition.allowed = allowed
end
local function object(value)
    if type(value) ~= 'table' or Foundation.jsonContainerKind(value) == 'array' then return false end
    for key in next, value do
        if type(key) ~= 'string' then return false end
    end
    return true
end
local function arrayLength(value)
    if type(value) ~= 'table' or Foundation.jsonContainerKind(value) == 'object' then return nil end
    local count, maximum = 0, 0
    for key in next, value do
        if type(key) ~= 'number' or math.type(key) ~= 'integer' or key < 1 then return nil end
        count = count + 1
        maximum = math.max(maximum, key)
    end
    if count ~= maximum then return nil end
    return count
end
local function token(value, field, minimum, maximum)
    if type(value) ~= 'string' or #value < minimum or #value > maximum
        or not value:match('^[A-Za-z0-9][A-Za-z0-9_.:%-]*$') then
        return nil, Foundation.domainError('VALIDATION_FAILED',
            field .. ' must be a bounded token.', false, { field = field })
    end
    return true, nil
end
function validation.shape(value, allowed, required)
    if not object(value) then
        return nil, Foundation.domainError('VALIDATION_FAILED', 'Request must be a JSON object.')
    end
    return Foundation.validateShape(value, allowed, required or {})
end
function validation.publicId(value, field, optional)
    if optional and value == nil then return true, nil end
    if not Foundation.isPublicId(value) then
        return nil, Foundation.domainError('VALIDATION_FAILED',
            (field or 'id') .. ' must be a bounded Synex public identifier.', false, { field = field or 'id' })
    end
    return true, nil
end
function validation.key(value, field, minimum, maximum)
    minimum, maximum = minimum or 2, maximum or 64
    if type(value) ~= 'string' or #value < minimum or #value > maximum
        or not value:match('^[a-z][a-z0-9_%-]*$') then
        return nil, Foundation.domainError('VALIDATION_FAILED',
            (field or 'key') .. ' must be a bounded lowercase key.', false, { field = field or 'key' })
    end
    return true, nil
end
function validation.text(value, field, minimum, maximum, optional)
    if optional and value == nil then return true, nil end
    local length = Foundation.characterLength(value)
    if length < (minimum or 1) or length > (maximum or 96)
        or value:find('[%z\1-\8\11\12\14-\31\127]') then
        return nil, Foundation.domainError('VALIDATION_FAILED',
            (field or 'text') .. ' contains invalid or out-of-range text.', false, { field = field or 'text' })
    end
    return true, nil
end
function validation.integer(value, field, minimum, maximum, optional)
    if optional and value == nil then return true, nil end
    if type(value) ~= 'number' or math.type(value) ~= 'integer'
        or value < minimum or value > maximum then
        return nil, Foundation.domainError('VALIDATION_FAILED',
            (field or 'value') .. ' must be a bounded integer.', false, { field = field or 'value' })
    end
    return true, nil
end
function validation.timestamp(value, field, optional)
    if optional and value == nil then return true, nil end
    local year, month, day, hour, minute, second, suffix
    if type(value) == 'string' and #value >= 19 and #value <= 32 then
        year, month, day, hour, minute, second, suffix = value:match(
            '^(%d%d%d%d)%-(%d%d)%-(%d%d)[T ](%d%d):(%d%d):(%d%d)(.*)$')
    end
    local validSuffix = suffix == '' or suffix == 'Z'
        or type(suffix) == 'string' and suffix:match('^%.%d+Z?$') ~= nil
        or type(suffix) == 'string' and suffix:match('^[+-]%d%d:%d%d$') ~= nil
    if not year or tonumber(month) < 1 or tonumber(month) > 12
        or tonumber(day) < 1 or tonumber(day) > 31
        or tonumber(hour) > 23 or tonumber(minute) > 59 or tonumber(second) > 60
        or not validSuffix then
        return nil, Foundation.domainError('VALIDATION_FAILED',
            (field or 'timestamp') .. ' must be a bounded ISO timestamp.', false, { field = field or 'timestamp' })
    end
    return true, nil
end
function validation.capability(value, wildcardAllowed)
    if type(value) ~= 'string' or #value < 1 or #value > 96 or value ~= value:lower()
        or value:sub(1, 1) == '.' or value:sub(-1) == '.' or value:find('..', 1, true) then
        return nil, Foundation.domainError('VALIDATION_FAILED', 'capability must be a bounded lowercase dotted name.')
    end
    local base = value
    if value:sub(-2) == '.*' then
        if not wildcardAllowed then
            return nil, Foundation.domainError('VALIDATION_FAILED', 'Wildcard capabilities cannot be evaluated directly.')
        end
        base = value:sub(1, -3)
    elseif value:find('*', 1, true) then
        return nil, Foundation.domainError('VALIDATION_FAILED', 'Only a trailing capability wildcard is supported.')
    end
    local segments = 0
    for segment in base:gmatch('[^.]+') do
        segments = segments + 1
        if not segment:match('^[a-z][a-z0-9_%-]*$') then
            return nil, Foundation.domainError('VALIDATION_FAILED', 'capability contains an invalid segment.')
        end
    end
    if segments == 0 then
        return nil, Foundation.domainError('VALIDATION_FAILED', 'capability must not be empty.')
    end
    return true, nil
end
function validation.metadata(value, optional)
    if optional and value == nil then return {}, nil end
    if not object(value) then
        return nil, Foundation.domainError('VALIDATION_FAILED', 'metadata must be an object.')
    end
    local copiedOk, copied = pcall(Foundation.copyPlain, value, {
        maximumDepth = 8,
        maximumKeys = 128,
        maximumStringBytes = 4096,
        preserveContainerKind = true
    })
    if not copiedOk then
        return nil, Foundation.domainError('VALIDATION_FAILED', 'metadata exceeds the supported JSON shape or bounds.')
    end
    return copied, nil
end
local publicIdFields = {
    actor_character_id = true, application_id = true, assignment_id = true,
    assignment_member_id = true, character_id = true, cursor = true,
    delegation_id = true, duty_session_id = true, entity_id = true,
    grade_id = true, grantee_membership_id = true, group_id = true,
    invitation_id = true, membership_id = true, membership_role_id = true,
    parent_assignment_id = true, parent_group_id = true, proposal_id = true,
    creation_request_id = true,
    reports_to_membership_id = true,
    relationship_id = true, role_id = true, source_group_id = true,
    source_id = true, target_group_id = true, target_membership_id = true
}
local keyFields = {
    grade_key = true, group_key = true, group_type = true, key = true, namespace = true, relation_type = true,
    role = true, slug = true, type = true
}
local booleanFields = {
    assignable = true, delegable = true, dry_run = true, dynamic = true,
    dynamic_creation = true, exclusive = true, counts_as_on_duty = true,
    required = true, allowed = true, approval_required = true,
    reason_required = true
}
local objectFields = {
    data = true, definition = true, metadata = true,
    parameters = true, payload = true, validation = true
}
local boundedTextFields = {
    action = { 3, 96 }, decision = { 2, 32 }, description = { 0, 1024 },
    entity_type = { 2, 32 }, label = { 1, 96 }, name = { 1, 96 },
    owner_resource = { 3, 64 }, reason = { 1, 256 }, source_type = { 2, 32 },
    state = { 2, 32 }, status = { 2, 32 }, visibility = { 2, 32 }
}
local integerFields = {
    capacity = { 1, 100000 }, expected_primary_version = { 0, 2147483647 }, expected_version = { 1, 2147483647 },
    limit = { 1, 100 }, max_members = { 1, 100000 },
    max_active_members = { 1, 100000 }, rank = { -32768, 32767 },
    required_approvals = { 1, 32 }, schema_version = { 1, 2147483647 }
}
local timestampFields = {
    ends_at = true, expires_at = true, starts_at = true,
    valid_from = true, valid_until = true
}
local membershipStates = {
    DRAFT = true, INVITED = true, APPLICANT = true, UNDER_REVIEW = true,
    APPROVED = true, PROBATION = true, ACTIVE = true, SUSPENDED = true,
    LEAVE = true, INACTIVE = true, TERMINATED = true, BANNED = true,
    LEFT = true, ARCHIVED = true
}

local function validateStringArray(value, field, maximum, itemValidator)
    local length = arrayLength(value)
    if length == nil or length > maximum then
        return nil, Foundation.domainError('VALIDATION_FAILED',
            field .. ' must be a bounded dense array.', false, { field = field })
    end
    local seen = {}
    for index = 1, length do
        local item = value[index]
        local valid, itemError = itemValidator(item, field .. '[' .. index .. ']')
        if not valid then return nil, itemError end
        if seen[item] then
            return nil, Foundation.domainError('VALIDATION_FAILED',
                field .. ' must contain unique values.', false, { field = field })
        end
        seen[item] = true
    end
    return true, nil
end
local function validateDefinitions(value)
    local length = arrayLength(value)
    if length == nil or length > MAXIMUM_DEFINITION_ITEMS then
        return nil, Foundation.domainError('VALIDATION_FAILED',
            'definitions must be a bounded dense array.', false, { field = 'definitions' })
    end
    local work = 0
    local function nested(candidate, maximum, field)
        if candidate == nil then return 0, nil end
        local count = arrayLength(candidate)
        if count == nil or count > maximum then
            return nil, Foundation.domainError('VALIDATION_FAILED',
                field .. ' must be a bounded dense array.', false, { field = field })
        end
        return count, nil
    end
    for index = 1, length do
        local definition = value[index]
        if not object(definition) then
            return nil, Foundation.domainError('VALIDATION_FAILED',
                'definitions entries must be objects.', false, { field = 'definitions' })
        end
        -- This is deliberately more conservative than the exact SQL emitted by
        -- reconciliation. It reserves work for durable definition rows, issue
        -- materialization, historical members, and the fixed inspection set.
        work = work + 256
        local grades, gradesError = nested(
            definition.grades, 64, ('definitions[%d].grades'):format(index))
        if grades == nil then return nil, gradesError end
        local roles, rolesError = nested(
            definition.roles, 64, ('definitions[%d].roles'):format(index))
        if roles == nil then return nil, rolesError end
        local groupRules, groupRulesError = nested(definition.capabilities, 64,
            ('definitions[%d].capabilities'):format(index))
        if groupRules == nil then return nil, groupRulesError end
        work = work + grades * 8 + roles * 6 + groupRules * 3
        for gradeIndex = 1, grades do
            if not object(definition.grades[gradeIndex]) then
                return nil, Foundation.domainError('VALIDATION_FAILED',
                    'Static definition grades must be objects.', false,
                    { field = ('definitions[%d].grades[%d]'):format(index, gradeIndex) })
            end
            local rules, rulesError = nested(definition.grades[gradeIndex].capabilities, 64,
                ('definitions[%d].grades[%d].capabilities'):format(index, gradeIndex))
            if rules == nil then return nil, rulesError end
            work = work + rules * 4
        end
        for roleIndex = 1, roles do
            if not object(definition.roles[roleIndex]) then
                return nil, Foundation.domainError('VALIDATION_FAILED',
                    'Static definition roles must be objects.', false,
                    { field = ('definitions[%d].roles[%d]'):format(index, roleIndex) })
            end
            local rules, rulesError = nested(definition.roles[roleIndex].capabilities, 64,
                ('definitions[%d].roles[%d].capabilities'):format(index, roleIndex))
            if rules == nil then return nil, rulesError end
            work = work + rules * 2
        end
        if work > MAXIMUM_DEFINITION_WORK then
            return nil, Foundation.domainError('VALIDATION_FAILED',
                'definitions exceed the bounded reconciliation work budget.', false, {
                    field = 'definitions', maximum_work = MAXIMUM_DEFINITION_WORK,
                    requested_work = work
                })
        end
    end
    return true, nil
end
local function validateDefaultGrades(value)
    local length = arrayLength(value)
    if length == nil or length > 32 then
        return nil, Foundation.domainError('VALIDATION_FAILED',
            'default_grades must be a bounded dense array.', false,
            { field = 'default_grades' })
    end
    local seen = {}
    for index = 1, length do
        local preset = value[index]
        local shaped, shapeError = validation.shape(preset, {
            key = true, label = true, rank = true, capacity = true
        }, { key = true, label = true, rank = true })
        if not shaped then return nil, shapeError end
        local valid, fieldError = validation.key(preset.key,
            'default_grades[' .. index .. '].key', 2, 48)
        if not valid or preset.key:find('-', 1, true) or preset.key == 'owner' then
            return nil, fieldError or Foundation.domainError('VALIDATION_FAILED',
                'Default grade keys must use lowercase letters, numbers, and underscores; owner is reserved.',
                false, { field = 'default_grades[' .. index .. '].key' })
        end
        if seen[preset.key] then
            return nil, Foundation.domainError('VALIDATION_FAILED',
                'Default grade keys must be unique.', false,
                { field = 'default_grades[' .. index .. '].key' })
        end
        seen[preset.key] = true
        valid, fieldError = validation.text(preset.label,
            'default_grades[' .. index .. '].label', 1, 96, false)
        if not valid then return nil, fieldError end
        valid, fieldError = validation.integer(preset.rank,
            'default_grades[' .. index .. '].rank', -32768, 32766, false)
        if not valid then return nil, fieldError end
        valid, fieldError = validation.integer(preset.capacity,
            'default_grades[' .. index .. '].capacity', 1, 100000, true)
        if not valid then return nil, fieldError end
    end
    return true, nil
end
local function validateDefaultRoles(value)
    local length = arrayLength(value)
    if length == nil or length > 32 then
        return nil, Foundation.domainError('VALIDATION_FAILED',
            'default_roles must be a bounded dense array.', false,
            { field = 'default_roles' })
    end
    local seen = {}
    for index = 1, length do
        local preset = value[index]
        local shaped, shapeError = validation.shape(preset, {
            key = true, label = true, description = true,
            assignable = true, exclusive = true, capacity = true
        }, { key = true, label = true })
        if not shaped then return nil, shapeError end
        local valid, fieldError = validation.key(preset.key,
            'default_roles[' .. index .. '].key', 2, 64)
        if not valid or preset.key:find('-', 1, true) then
            return nil, fieldError or Foundation.domainError('VALIDATION_FAILED',
                'Default role keys must use lowercase letters, numbers, and underscores.',
                false, { field = 'default_roles[' .. index .. '].key' })
        end
        if seen[preset.key] then
            return nil, Foundation.domainError('VALIDATION_FAILED',
                'Default role keys must be unique.', false,
                { field = 'default_roles[' .. index .. '].key' })
        end
        seen[preset.key] = true
        valid, fieldError = validation.text(preset.label,
            'default_roles[' .. index .. '].label', 1, 96, false)
        if not valid then return nil, fieldError end
        valid, fieldError = validation.text(preset.description,
            'default_roles[' .. index .. '].description', 0, 1024, true)
        if not valid then return nil, fieldError end
        for _, field in ipairs({ 'assignable', 'exclusive' }) do
            if preset[field] ~= nil and type(preset[field]) ~= 'boolean' then
                return nil, Foundation.domainError('VALIDATION_FAILED',
                    'Default role flags must be boolean.', false,
                    { field = 'default_roles[' .. index .. '].' .. field })
            end
        end
        valid, fieldError = validation.integer(preset.capacity,
            'default_roles[' .. index .. '].capacity', 1, 100000, true)
        if not valid then return nil, fieldError end
    end
    return true, nil
end
local function validateField(operation, field, value)
    if publicIdFields[field] then return validation.publicId(value, field, false) end
    if field == 'type' and operation == 'attributes_register_schema' then
        local supported = {
            string = true, integer = true, decimal = true,
            boolean = true, datetime = true, json = true
        }
        if supported[value] then return true, nil end
        return nil, Foundation.domainError('VALIDATION_FAILED',
            'type is not a supported membership attribute type.', false, { field = field })
    end
    if keyFields[field] then return validation.key(value, field, 2, 64) end
    if field == 'state' then return validation.key(value, field, 2, 32) end
    if field == 'direction' then
        if operation == 'relationships_list' then
            if value == 'any' or value == 'outgoing' or value == 'incoming' then
                return true, nil
            end
            return nil, Foundation.domainError('VALIDATION_FAILED',
                'direction must be any, outgoing, or incoming.', false, { field = field })
        end
        if value == 'directed' or value == 'symmetric' then return true, nil end
        return nil, Foundation.domainError('VALIDATION_FAILED',
            'direction must be directed or symmetric.', false, { field = field })
    end
    if field == 'create_permission' then
        local valid, capabilityError = validation.capability(value, false)
        if not valid then return nil, capabilityError end
        if #value < 22 or #value > 96
            or value:sub(1, 20) ~= 'synex.groups.create.'
            or value == 'synex.groups.create.migration_pending' then
            return nil, Foundation.domainError('VALIDATION_FAILED',
                'create_permission must use the synex.groups.create namespace.', false,
                { field = field })
        end
        return true, nil
    end
    if field == 'approval_permission' then
        local valid, capabilityError = validation.capability(value, false)
        if not valid then return nil, capabilityError end
        if #value < 30 or #value > 96
            or value:sub(1, 28) ~= 'synex.groups.create.approve.' then
            return nil, Foundation.domainError('VALIDATION_FAILED',
                'approval_permission must use the synex.groups.create.approve namespace.',
                false, { field = field })
        end
        return true, nil
    end
    if field == 'required_capability' then
        return validation.capability(value, false)
    end
    if field == 'from_status' or field == 'to_status' then
        local normalized = type(value) == 'string' and value:upper() or nil
        if normalized and membershipStates[normalized] then return true, nil end
        return nil, Foundation.domainError('VALIDATION_FAILED',
            field .. ' must be a supported membership lifecycle state.', false,
            { field = field })
    end
    if field == 'required_approvals' and operation == 'types_register' then
        return validation.integer(value, field, 0, 32, false)
    end
    if field == 'visibility' and operation == 'attributes_register_schema' then
        local supported = {
            public = true, members = true, management = true, staff = true,
            hidden = true, server_only = true, private = true
        }
        if supported[value] then return true, nil end
        return nil, Foundation.domainError('VALIDATION_FAILED',
            'visibility is not supported for membership attributes.', false,
            { field = field })
    end
    if field == 'visibility' and operation == 'members_set_visibility' then
        local supported = {
            public = true, members = true, management = true,
            hidden = true, server_only = true
        }
        if supported[value] then return true, nil end
        return nil, Foundation.domainError('VALIDATION_FAILED',
            'visibility is not supported for membership profiles.', false,
            { field = field })
    end
    if field == 'visibility' and (operation == 'create' or operation == 'update') then
        local supported = { public = true, internal = true, private = true, hidden = true }
        if supported[value] then return true, nil end
        return nil, Foundation.domainError('VALIDATION_FAILED',
            'visibility is not supported for organizations.', false, { field = field })
    end
    if field == 'status' and operation == 'create' then
        local normalized = type(value) == 'string' and value:lower() or nil
        if normalized == 'draft' or normalized == 'active' then return true, nil end
        return nil, Foundation.domainError('VALIDATION_FAILED',
            'status must be draft or active.', false, { field = field })
    end
    if field == 'status' and operation == 'update' then
        local normalized = type(value) == 'string' and value:lower() or nil
        if normalized == 'active' or normalized == 'suspended' then return true, nil end
        return nil, Foundation.domainError('VALIDATION_FAILED',
            'status must be active or suspended.', false, { field = field })
    end
    if field == 'status' and (operation == 'relationships_update'
        or operation == 'relationships_list') then
        if value == 'active' or value == 'suspended'
            or value == 'ended'
            or operation == 'relationships_list' and value == 'pending' then return true, nil end
        return nil, Foundation.domainError('VALIDATION_FAILED',
            'status is not a supported relationship state.', false, { field = field })
    end
    if field == 'status' and (operation == 'members_list'
        or operation == 'members_transition') then
        local normalized = type(value) == 'string' and value:upper() or nil
        if normalized and membershipStates[normalized] then return true, nil end
        return nil, Foundation.domainError('VALIDATION_FAILED',
            'status is not a supported membership lifecycle state.', false, { field = field })
    end
    if field == 'status' and operation == 'grades_update' then
        if value == 'active' or value == 'disabled' then return true, nil end
        return nil, Foundation.domainError('VALIDATION_FAILED',
            'status is not a supported grade state.', false, { field = field })
    end
    if field == 'status' and operation == 'roles_update' then
        if value == 'active' or value == 'disabled'
            or value == 'retired' then return true, nil end
        return nil, Foundation.domainError('VALIDATION_FAILED',
            'status is not a supported role state.', false, { field = field })
    end
    if field == 'status' and operation == 'assignments_list' then
        if value == 'active' or value == 'completed'
            or value == 'cancelled' or value == 'expired' then return true, nil end
        return nil, Foundation.domainError('VALIDATION_FAILED',
            'status is not a supported assignment state.', false, { field = field })
    end
    if field == 'status' and operation == 'duty_list' then
        if value == 'open' or value == 'closed' then return true, nil end
        return nil, Foundation.domainError('VALIDATION_FAILED',
            'status is not a supported duty-session state.', false, { field = field })
    end
    if field == 'status' and operation == 'list' then
        local normalized = type(value) == 'string' and value:lower() or nil
        if normalized == 'draft' or normalized == 'active' or normalized == 'suspended'
            or normalized == 'archived' or normalized == 'dissolving'
            or normalized == 'deleted' then return true, nil end
        return nil, Foundation.domainError('VALIDATION_FAILED',
            'status is not a supported organization lifecycle state.', false,
            { field = field })
    end
    if booleanFields[field] then
        if type(value) == 'boolean' then return true, nil end
        return nil, Foundation.domainError('VALIDATION_FAILED', field .. ' must be boolean.', false, { field = field })
    end
    if objectFields[field] then
        if field == 'metadata' then return validation.metadata(value, false) end
        if object(value) then
            local copiedOk = pcall(Foundation.copyPlain, value, {
                maximumDepth = 8,
                maximumKeys = 256,
                maximumStringBytes = 4096,
                preserveContainerKind = false
            })
            if copiedOk then return true, nil end
        end
        return nil, Foundation.domainError('VALIDATION_FAILED', field .. ' must be an object.', false, { field = field })
    end
    if field == 'label' and operation == 'duty_states_register' then
        return validation.text(value, field, 1, 64, false)
    end
    local textBounds = boundedTextFields[field]
    if textBounds then return validation.text(value, field, textBounds[1], textBounds[2], false) end
    local integerBounds = integerFields[field]
    if integerBounds then return validation.integer(value, field, integerBounds[1], integerBounds[2], false) end
    if timestampFields[field] then return validation.timestamp(value, field, false) end
    if field == 'idempotency_key' then return token(value, field, 8, 128) end
    if field == 'capability' then
        return validation.capability(value,
            operation ~= 'capabilities_check' and operation ~= 'capabilities_explain')
    end
    if field == 'effect' then
        if value == 'allow' or value == 'deny' then return true, nil end
        return nil, Foundation.domainError('VALIDATION_FAILED', 'effect must be allow or deny.', false, { field = field })
    end
    if field == 'scope' then
        if value == 'group' or value == 'subtree' then return true, nil end
        return nil, Foundation.domainError('VALIDATION_FAILED', 'scope must be group or subtree.', false, { field = field })
    end
    if field == 'allowed_duty_states' or field == 'allowed_membership_states' then
        return validateStringArray(value, field, 16, function(item, itemField)
            return validation.text(item, itemField, 2, 32, false)
        end)
    end
    if field == 'role_ids' then
        return validateStringArray(value, field, 16, function(item, itemField)
            return validation.publicId(item, itemField, false)
        end)
    end
    if field == 'definitions' then return validateDefinitions(value) end
    if field == 'default_grades' then return validateDefaultGrades(value) end
    if field == 'default_roles' then return validateDefaultRoles(value) end
    if field == 'value' or field == 'default' then return true, nil end
    return nil, Foundation.domainError('VALIDATION_FAILED',
        'The operation schema contains an unsupported field.', false, { field = field })
end
function validation.operation(operation, request)
    local definition = operationShapes[operation]
    if not definition then
        return nil, Foundation.domainError('VALIDATION_FAILED', 'The Groups operation is not supported.')
    end
    local shaped, shapeError = validation.shape(request, definition.allowed, definition.required)
    if not shaped then return nil, shapeError end
    for field, value in pairs(request) do
        local valid, fieldError = validateField(operation, field, value)
        if not valid then return nil, fieldError end
    end
    if operation == 'types_register' and request.max_members ~= nil
        and request.max_active_members ~= nil
        and request.max_active_members > request.max_members then
        return nil, Foundation.domainError('VALIDATION_FAILED',
            'max_active_members cannot exceed max_members.', false,
            { field = 'max_active_members' })
    end
    local transportPageMaximums = {
        relationships_list = 40,
        assignments_list = 40,
        duty_list = 40,
        self_snapshot = 8,
        compatibility_snapshot = 8
    }
    local transportMaximum = transportPageMaximums[operation]
    if transportMaximum ~= nil and request.limit ~= nil
        and request.limit > transportMaximum then
        return nil, Foundation.domainError('VALIDATION_FAILED',
            ('limit must be an integer between 1 and %d.'):format(transportMaximum),
            false, { field = 'limit' })
    end
    return true, nil
end
function validation.reason(value, required)
    if not required and value == nil then return true, nil end
    return validation.text(value, 'reason', 1, 256, false)
end
function validation.page(request)
    local limit = request.limit == nil and 50 or request.limit
    local valid, err = validation.integer(limit, 'limit', 1, 100, false)
    if not valid then return nil, err end
    if request.cursor ~= nil then
        valid, err = validation.publicId(request.cursor, 'cursor', false)
        if not valid then return nil, err end
    end
    return { limit = limit, cursor = request.cursor }, nil
end
return validation
end
