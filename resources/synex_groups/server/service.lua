return function(Foundation)
local domainError = Foundation.domainError
local isUuid = Foundation.isUuid
local isSubjectId = Foundation.isSubjectId
local characterLength = Foundation.characterLength
local validateShape = Foundation.validateShape
local createCanonicalEncoder = Foundation.createCanonicalEncoder
local reportUnexpectedError = Foundation.reportUnexpectedError

local function createService(deps)
    local db = assert(deps.db, 'synex_groups service requires deps.db')
    local jsonDecode = assert(deps.jsonDecode, 'synex_groups service requires deps.jsonDecode')
    local canonicalEncode = createCanonicalEncoder(assert(deps.jsonEncode, 'synex_groups service requires deps.jsonEncode'))
    local errorSink = assert(type(deps.errorSink) == 'function' and deps.errorSink,
        'synex_groups service requires deps.errorSink')

    local function metadataJson(value)
        if value == nil then return '{}' end
        if type(value) ~= 'string' or #value > 4096 then
            return nil, domainError('VALIDATION_FAILED', 'metadata_json must be a JSON object no larger than 4096 bytes.')
        end
        local ok, decoded = pcall(jsonDecode, value)
        if not ok or type(decoded) ~= 'table' then
            return nil, domainError('VALIDATION_FAILED', 'metadata_json must contain a JSON object.')
        end
        local encodedOk, encoded = pcall(canonicalEncode, decoded)
        if not encodedOk or #encoded > 4096 then
            return nil, domainError('VALIDATION_FAILED', 'metadata_json exceeds the supported shape or size.')
        end
        return encoded, nil
    end

    local function validateIdempotencyKey(value)
        if not isUuid(value) then
            return nil, domainError('VALIDATION_FAILED', 'idempotency_key must be a lowercase UUID.')
        end
        return true, nil
    end

    local function validateActor(value)
        if value ~= nil and not isSubjectId(value) then
            return nil, domainError('VALIDATION_FAILED', 'actor_ref must be a bounded opaque identifier when supplied.')
        end
        return true, nil
    end

    local function validateCapabilityPattern(value, wildcardAllowed)
        if type(value) ~= 'string' or #value < 1 or #value > 128 or value ~= value:lower()
            or value:sub(1, 1) == '.' or value:find('..', 1, true) then
            return nil, domainError('VALIDATION_FAILED', 'capability must be a bounded lowercase dotted name.')
        end
        local base = value
        if value:sub(-2) == '.*' then
            if not wildcardAllowed then
                return nil, domainError('VALIDATION_FAILED', 'Wildcard capabilities are not accepted for evaluation.')
            end
            base = value:sub(1, -3)
        elseif value:find('*', 1, true) then
            return nil, domainError('VALIDATION_FAILED', 'Only a trailing .* wildcard is supported.')
        end
        local count = 0
        for segment in base:gmatch('[^.]+') do
            count = count + 1
            if not segment:match('^[a-z][a-z0-9_%-]*$') then
                return nil, domainError('VALIDATION_FAILED', 'capability contains an invalid segment.')
            end
        end
        if count == 0 then return nil, domainError('VALIDATION_FAILED', 'capability must not be empty.') end
        return true, nil
    end

    local function fingerprint(name, ...)
        local values = table.pack(...)
        local parts = { name }
        for index = 1, values.n do
            local value = values[index]
            local normalized = value == nil and '<nil>' or tostring(value)
            parts[#parts + 1] = tostring(#normalized) .. ':' .. normalized
        end
        return table.concat(parts, '|')
    end

    local service = {}

    function service.create(request)
        local valid, validationError = validateShape(request, {
            idempotency_key = true, group_key = true, display_name = true, group_type = true,
            created_by_ref = true, metadata_json = true
        }, { 'idempotency_key', 'group_key', 'display_name', 'group_type' })
        if not valid then return nil, validationError end
        valid, validationError = validateIdempotencyKey(request.idempotency_key)
        if not valid then return nil, validationError end
        if type(request.group_key) ~= 'string' or #request.group_key < 3 or #request.group_key > 64
            or not request.group_key:match('^[a-z][a-z0-9_]+$') then
            return nil, domainError('VALIDATION_FAILED', 'group_key must be 3-64 lowercase ASCII characters.')
        end
        if type(request.display_name) ~= 'string' or characterLength(request.display_name) < 1
            or characterLength(request.display_name) > 96 then
            return nil, domainError('VALIDATION_FAILED', 'display_name must contain 1-96 valid UTF-8 characters.')
        end
        if type(request.group_type) ~= 'string' or #request.group_type < 2 or #request.group_type > 32
            or not request.group_type:match('^[a-z][a-z0-9_]+$') then
            return nil, domainError('VALIDATION_FAILED', 'group_type must be 2-32 lowercase ASCII characters.')
        end
        if request.created_by_ref ~= nil and not isSubjectId(request.created_by_ref) then
            return nil, domainError('VALIDATION_FAILED', 'created_by_ref must be a bounded opaque identifier when supplied.')
        end
        local metadata, metadataError = metadataJson(request.metadata_json)
        if not metadata then return nil, metadataError end

        local command = {
            idempotencyKey = request.idempotency_key,
            groupKey = request.group_key,
            displayName = request.display_name,
            groupType = request.group_type,
            createdByRef = request.created_by_ref,
            metadataJson = metadata
        }
        command.fingerprint = fingerprint('create',
            command.groupKey, command.displayName, command.groupType, command.createdByRef, command.metadataJson
        )
        return db:createGroup(command)
    end

    function service.get(request)
        local valid, validationError = validateShape(request, { group_id = true }, { 'group_id' })
        if not valid then return nil, validationError end
        if not isUuid(request.group_id) then
            return nil, domainError('VALIDATION_FAILED', 'group_id must be a lowercase UUID.')
        end
        return db:getGroup(request.group_id)
    end

    local function membershipCommand(request, operation, needsRole)
        local allowed = {
            idempotency_key = true, group_id = true, subject_kind = true, subject_id = true,
            role_key = true, actor_ref = true
        }
        local required = { 'idempotency_key', 'group_id', 'subject_kind', 'subject_id' }
        if needsRole then required[#required + 1] = 'role_key' end
        local valid, validationError = validateShape(request, allowed, required)
        if not valid then return nil, validationError end
        valid, validationError = validateIdempotencyKey(request.idempotency_key)
        if not valid then return nil, validationError end
        if not isUuid(request.group_id) or not isSubjectId(request.subject_id) then
            return nil, domainError('VALIDATION_FAILED', 'group_id or subject_id is invalid.')
        end
        if request.subject_kind ~= 'user' and request.subject_kind ~= 'character' then
            return nil, domainError('VALIDATION_FAILED', 'subject_kind must be user or character.')
        end
        if needsRole and (type(request.role_key) ~= 'string' or #request.role_key < 2 or #request.role_key > 48
            or not request.role_key:match('^[a-z][a-z0-9_]+$')) then
            return nil, domainError('VALIDATION_FAILED', 'role_key must be 2-48 lowercase ASCII characters.')
        end
        valid, validationError = validateActor(request.actor_ref)
        if not valid then return nil, validationError end
        local command = {
            idempotencyKey = request.idempotency_key,
            groupId = request.group_id,
            subjectKind = request.subject_kind,
            subjectId = request.subject_id,
            roleKey = request.role_key,
            actorRef = request.actor_ref
        }
        command.fingerprint = fingerprint(operation,
            command.groupId, command.subjectKind, command.subjectId, command.roleKey, command.actorRef
        )
        return command, nil
    end

    function service.add_membership(request)
        local command, validationError = membershipCommand(request, 'add_membership', true)
        if not command then return nil, validationError end
        return db:addMembership(command)
    end

    function service.change_membership(request)
        local command, validationError = membershipCommand(request, 'change_membership', true)
        if not command then return nil, validationError end
        return db:changeMembership(command)
    end

    function service.remove_membership(request)
        local command, validationError = membershipCommand(request, 'remove_membership', false)
        if not command then return nil, validationError end
        return db:removeMembership(command)
    end

    function service.create_grade(request)
        local valid, validationError = validateShape(request, {
            idempotency_key = true, group_id = true, grade_key = true, display_name = true,
            rank_value = true, actor_ref = true
        }, { 'idempotency_key', 'group_id', 'grade_key', 'display_name', 'rank_value' })
        if not valid then return nil, validationError end
        valid, validationError = validateIdempotencyKey(request.idempotency_key)
        if not valid then return nil, validationError end
        if not isUuid(request.group_id) then return nil, domainError('VALIDATION_FAILED', 'group_id must be a lowercase UUID.') end
        if type(request.grade_key) ~= 'string' or #request.grade_key < 2 or #request.grade_key > 48
            or not request.grade_key:match('^[a-z][a-z0-9_]+$') then
            return nil, domainError('VALIDATION_FAILED', 'grade_key must be 2-48 lowercase ASCII characters.')
        end
        if type(request.display_name) ~= 'string' or characterLength(request.display_name) < 1
            or characterLength(request.display_name) > 96 then
            return nil, domainError('VALIDATION_FAILED', 'display_name must contain 1-96 valid UTF-8 characters.')
        end
        if type(request.rank_value) ~= 'number' or math.type(request.rank_value) ~= 'integer'
            or request.rank_value < -32768 or request.rank_value > 32767 then
            return nil, domainError('VALIDATION_FAILED', 'rank_value must fit a signed SMALLINT.')
        end
        valid, validationError = validateActor(request.actor_ref)
        if not valid then return nil, validationError end
        local command = {
            idempotencyKey = request.idempotency_key, groupId = request.group_id,
            gradeKey = request.grade_key, displayName = request.display_name,
            rankValue = request.rank_value, actorRef = request.actor_ref
        }
        command.fingerprint = fingerprint('create_grade', command.groupId, command.gradeKey,
            command.displayName, command.rankValue, command.actorRef)
        return db:createGrade(command)
    end

    function service.set_grade_capability(request)
        local valid, validationError = validateShape(request, {
            idempotency_key = true, grade_id = true, capability = true, effect = true, actor_ref = true
        }, { 'idempotency_key', 'grade_id', 'capability', 'effect' })
        if not valid then return nil, validationError end
        valid, validationError = validateIdempotencyKey(request.idempotency_key)
        if not valid then return nil, validationError end
        if not isUuid(request.grade_id) then return nil, domainError('VALIDATION_FAILED', 'grade_id must be a lowercase UUID.') end
        valid, validationError = validateCapabilityPattern(request.capability, true)
        if not valid then return nil, validationError end
        if request.effect ~= 'allow' and request.effect ~= 'deny' then
            return nil, domainError('VALIDATION_FAILED', 'effect must be allow or deny.')
        end
        valid, validationError = validateActor(request.actor_ref)
        if not valid then return nil, validationError end
        local command = {
            idempotencyKey = request.idempotency_key, gradeId = request.grade_id,
            capability = request.capability, effect = request.effect, actorRef = request.actor_ref
        }
        command.fingerprint = fingerprint('set_grade_capability', command.gradeId,
            command.capability, command.effect, command.actorRef)
        return db:setGradeCapability(command)
    end

    function service.set_primary_membership(request)
        local valid, validationError = validateShape(request, {
            idempotency_key = true, group_id = true, subject_kind = true, subject_id = true, actor_ref = true
        }, { 'idempotency_key', 'group_id', 'subject_kind', 'subject_id' })
        if not valid then return nil, validationError end
        valid, validationError = validateIdempotencyKey(request.idempotency_key)
        if not valid then return nil, validationError end
        if not isUuid(request.group_id) or not isSubjectId(request.subject_id) then
            return nil, domainError('VALIDATION_FAILED', 'group_id or subject_id is invalid.')
        end
        if request.subject_kind ~= 'user' and request.subject_kind ~= 'character' then
            return nil, domainError('VALIDATION_FAILED', 'subject_kind must be user or character.')
        end
        valid, validationError = validateActor(request.actor_ref)
        if not valid then return nil, validationError end
        local command = {
            idempotencyKey = request.idempotency_key, groupId = request.group_id,
            subjectKind = request.subject_kind, subjectId = request.subject_id, actorRef = request.actor_ref
        }
        command.fingerprint = fingerprint('set_primary_membership', command.groupId,
            command.subjectKind, command.subjectId, command.actorRef)
        return db:setPrimaryMembership(command)
    end

    function service.get_read_model(request)
        local valid, validationError = validateShape(request, {
            group_id = true, subject_kind = true, subject_id = true
        }, { 'group_id', 'subject_kind', 'subject_id' })
        if not valid then return nil, validationError end
        if not isUuid(request.group_id) or not isSubjectId(request.subject_id) then
            return nil, domainError('VALIDATION_FAILED', 'group_id or subject_id is invalid.')
        end
        if request.subject_kind ~= 'user' and request.subject_kind ~= 'character' then
            return nil, domainError('VALIDATION_FAILED', 'subject_kind must be user or character.')
        end
        return db:getReadModel(request.group_id, request.subject_kind, request.subject_id)
    end

    function service.list_subject_memberships(request)
        local valid, validationError = validateShape(request, {
            subject_kind = true, subject_id = true
        }, { 'subject_kind', 'subject_id' })
        if not valid then return nil, validationError end
        if request.subject_kind ~= 'user' and request.subject_kind ~= 'character' then
            return nil, domainError('VALIDATION_FAILED', 'subject_kind must be user or character.')
        end
        if not isSubjectId(request.subject_id) then
            return nil, domainError('VALIDATION_FAILED', 'subject_id is invalid.')
        end
        return db:listSubjectMemberships(request.subject_kind, request.subject_id)
    end

    function service.check_capability(request)
        local valid, validationError = validateShape(request, {
            group_id = true, subject_kind = true, subject_id = true, capability = true
        }, { 'group_id', 'subject_kind', 'subject_id', 'capability' })
        if not valid then return nil, validationError end
        if not isUuid(request.group_id) or not isSubjectId(request.subject_id) then
            return nil, domainError('VALIDATION_FAILED', 'group_id or subject_id is invalid.')
        end
        if request.subject_kind ~= 'user' and request.subject_kind ~= 'character' then
            return nil, domainError('VALIDATION_FAILED', 'subject_kind must be user or character.')
        end
        valid, validationError = validateCapabilityPattern(request.capability, false)
        if not valid then return nil, validationError end
        return db:checkCapability(request.group_id, request.subject_kind, request.subject_id, request.capability)
    end

    function service.get_control_summary(request)
        local valid, validationError = validateShape(request, {}, {})
        if not valid then return nil, validationError end
        return db:getControlSummary()
    end

    local guarded = {}
    for name, handler in pairs(service) do
        local currentHandler, operationName = handler, name
        guarded[name] = function(request, context)
            local ok, value, handlerError = pcall(currentHandler, request, context)
            if not ok then
                reportUnexpectedError(errorSink, 'synex_groups', operationName, context)
                return nil, domainError('DATABASE_ERROR', 'The group operation could not be completed.', true)
            end
            return value, handlerError
        end
    end
    return guarded
end

return createService
end
