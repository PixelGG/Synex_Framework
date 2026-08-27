return function(Foundation)
return function(event)
    event = type(event) == 'table' and event or {}
    local operation = rawget(event, 'operation')
    if type(operation) ~= 'string' or #operation < 1 or #operation > 96
        or operation:match('^[A-Za-z0-9_.:%-]+$') == nil then
        operation = 'unavailable'
    end
    local traceId = rawget(event, 'traceId')
    if type(traceId) ~= 'string' or #traceId < 8 or #traceId > 64
        or traceId:match('^[A-Za-z0-9_.:%-]+$') == nil then
        traceId = 'unavailable'
    end
    local code = rawget(event, 'code')
    if type(code) ~= 'string' or #code < 2 or #code > 64
        or code:match('^[A-Z][A-Z0-9_]*$') == nil then
        code = 'UNEXPECTED_ERROR'
    end
    local result = {
        level = 'error',
        event = 'groups_operation_failed',
        resource = 'synex_groups',
        operation = operation,
        traceId = traceId,
        code = code
    }
    local groupId = rawget(event, 'groupId')
    if Foundation.isPublicId(groupId) then result.groupId = groupId end
    local membershipId = rawget(event, 'membershipId')
    if Foundation.isPublicId(membershipId) then result.membershipId = membershipId end
    local characterId = rawget(event, 'characterId')
    if Foundation.isSubjectId(characterId) then result.characterId = characterId end
    return result
end
end
