SynexEntityLogicalOwner = {}

function SynexEntityLogicalOwner.create(options)
    assert(type(options) == 'table', 'entity logical-owner options are required')
    local coreRef = assert(options.coreRef, 'entity logical-owner Core reference is required')
    local foundation = assert(options.foundation, 'entity logical-owner foundation is required')
    local validation = assert(options.validation, 'entity logical-owner validation is required')
    local service = {}

    local function failure(code, message, retryable, context)
        return foundation.failure(code, message, retryable == true, context)
    end

    local function unavailable(message, context, operationError)
        if type(operationError) == 'table'
            and (operationError.code == 'CAPABILITY_DENIED'
                or operationError.code == 'FORBIDDEN') then
            return nil, {
                code = 'FORBIDDEN',
                message = 'Character ownership verification is not permitted',
                retryable = false,
                traceId = context and context.traceId or nil,
            }
        end
        return failure('UNAVAILABLE', message, true, context)
    end

    local function validateCharacter(characterId, context)
        local api = coreRef.value
        if not api or type(api.Characters) ~= 'table'
            or not foundation.isCallable(api.Characters.get) then
            return failure('CORE_UNAVAILABLE',
                'The Core character lookup is unavailable', true, context)
        end
        local invoked, character, operationError = foundation.protect(
            'core.characters.get',
            function() return api.Characters.get(characterId) end,
            context
        )
        if not invoked then
            return unavailable('The character owner could not be verified', context)
        end
        if not character then
            local code = type(operationError) == 'table' and operationError.code or nil
            if code == 'CHARACTER_NOT_FOUND' or code == 'CHARACTER_UNAVAILABLE'
                or code == 'NOT_FOUND' then
                return failure('INVALID_LOGICAL_OWNER',
                    'The logical owner character does not exist or is inactive', false, context)
            end
            return unavailable('The character owner could not be verified', context, operationError)
        end
        if type(character) ~= 'table' or character.id ~= characterId
            or character.status ~= nil and character.status ~= 'active'
            or character.deletedAt ~= nil or character.deleted_at ~= nil then
            return failure('INVALID_LOGICAL_OWNER',
                'The logical owner character does not exist or is inactive', false, context)
        end
        return true
    end

    local function validateGroup(groupId, context)
        local api = coreRef.value
        if not api or type(api.Services) ~= 'table'
            or not foundation.isCallable(api.Services.call) then
            return failure('CORE_UNAVAILABLE',
                'The Core service gateway is unavailable', true, context)
        end
        local invoked, group, operationError = foundation.protect(
            'core.services.synex_groups.get',
            function()
                return api.Services.call(
                    'synex.groups',
                    '^1.0.0',
                    'get',
                    { group_id = groupId },
                    { traceId = context and context.traceId or nil, timeoutMs = 5000 }
                )
            end,
            context
        )
        if not invoked then
            return failure('UNAVAILABLE',
                'The group owner could not be verified', true, context)
        end
        if not group then
            local code = type(operationError) == 'table' and operationError.code or nil
            if code == 'NOT_FOUND' or code == 'GROUP_NOT_FOUND' then
                return failure('INVALID_LOGICAL_OWNER',
                    'The logical owner group does not exist', false, context)
            end
            return nil, type(operationError) == 'table' and operationError or {
                code = 'UNAVAILABLE',
                message = 'The group owner could not be verified',
                retryable = true,
                traceId = context and context.traceId or nil,
            }
        end
        return true
    end

    function service.validate(owner, invokingResource, context)
        local normalized, ownerError = validation.validateOwner(owner)
        if not normalized then
            ownerError.traceId = context and context.traceId or nil
            return nil, ownerError
        end
        if normalized.type == 'resource' and normalized.id ~= invokingResource then
            return failure('FOREIGN_RESOURCE_OWNER',
                'A resource logical owner must match the invoking resource', false, context)
        end
        if normalized.type == 'character' then
            local valid, characterError = validateCharacter(normalized.id, context)
            if not valid then return nil, characterError end
        elseif normalized.type == 'group' then
            local valid, groupError = validateGroup(normalized.id, context)
            if not valid then return nil, groupError end
        end
        return normalized
    end

    return service
end
