return function(Foundation, deps)
local arrayLength = assert(deps.arrayLength, 'group definition normalization requires arrayLength')
local closedObject = assert(deps.closedObject, 'group definition normalization requires closedObject')
local validKey = assert(deps.validKey, 'group definition normalization requires validKey')
local validText = assert(deps.validText, 'group definition normalization requires validText')
local CapabilityDefinitions = assert(deps.capabilityDefinitions,
    'group definition normalization requires capability definitions')

local GRADE_FIELDS = {
    key = true, label = true, rank = true, capacity = true, status = true,
    capabilities = true
}
local ROLE_FIELDS = {
    key = true, label = true, description = true, assignable = true,
    exclusive = true, capacity = true, status = true, capabilities = true
}
local GRADE_STATUSES = { active = true, disabled = true }
local ROLE_STATUSES = { active = true, disabled = true, retired = true }

local function normalizeGrades(value)
    local count = arrayLength(value, 64)
    if count == nil or count < 1 then
        return nil, Foundation.domainError('VALIDATION_FAILED',
            'A static group requires between one and sixty-four grades.')
    end
    local result, seen = {}, {}
    for index = 1, count do
        local entry = value[index]
        local shaped, shapeError = closedObject(entry, GRADE_FIELDS,
            'A static group grade')
        if not shaped then return nil, shapeError end
        if not validKey(entry.key, 2, 48, '^[a-z][a-z0-9_]*$')
            or seen[entry.key] or not validText(entry.label, 1, 96)
            or type(entry.rank) ~= 'number' or math.type(entry.rank) ~= 'integer'
            or entry.rank < -32768 or entry.rank > 32767
            or entry.capacity ~= nil and (type(entry.capacity) ~= 'number'
                or math.type(entry.capacity) ~= 'integer'
                or entry.capacity < 1 or entry.capacity > 100000)
            or entry.status ~= nil and not GRADE_STATUSES[entry.status] then
            return nil, Foundation.domainError('VALIDATION_FAILED',
                'A static group grade is invalid or duplicates a grade key.', false,
                { index = index })
        end
        seen[entry.key] = true
        local capabilities, capabilityError = CapabilityDefinitions.normalize(
            entry.capabilities, 'grade')
        if not capabilities then return nil, capabilityError end
        result[index] = {
            key = entry.key,
            label = entry.label,
            rank = entry.rank,
            capacity = entry.capacity,
            status = entry.status or 'active',
            capabilities = capabilities
        }
    end
    return result, nil
end

local function normalizeRoles(value)
    if value == nil then return {}, nil end
    local count = arrayLength(value, 64)
    if count == nil then
        return nil, Foundation.domainError('VALIDATION_FAILED',
            'Static group roles must be a bounded dense array.')
    end
    local result, seen = {}, {}
    for index = 1, count do
        local entry = value[index]
        local shaped, shapeError = closedObject(entry, ROLE_FIELDS,
            'A static group role')
        if not shaped then return nil, shapeError end
        if not validKey(entry.key, 2, 64, '^[a-z][a-z0-9_]*$')
            or seen[entry.key] or not validText(entry.label, 1, 96)
            or entry.description ~= nil and not validText(entry.description, 0, 512)
            or entry.assignable ~= nil and type(entry.assignable) ~= 'boolean'
            or entry.exclusive ~= nil and type(entry.exclusive) ~= 'boolean'
            or entry.capacity ~= nil and (type(entry.capacity) ~= 'number'
                or math.type(entry.capacity) ~= 'integer'
                or entry.capacity < 1 or entry.capacity > 65535)
            or entry.status ~= nil and not ROLE_STATUSES[entry.status] then
            return nil, Foundation.domainError('VALIDATION_FAILED',
                'A static group role is invalid or duplicates a role key.', false,
                { index = index })
        end
        local status = entry.status
            or (entry.assignable == false and 'disabled' or 'active')
        if entry.assignable ~= nil
            and (entry.assignable and status ~= 'active'
                or not entry.assignable and status == 'active') then
            return nil, Foundation.domainError('VALIDATION_FAILED',
                'A static group role has conflicting assignable and status values.', false,
                { index = index })
        end
        seen[entry.key] = true
        local capabilities, capabilityError = CapabilityDefinitions.normalize(
            entry.capabilities, 'role')
        if not capabilities then return nil, capabilityError end
        result[index] = {
            key = entry.key,
            label = entry.label,
            description = entry.description,
            assignable = status == 'active',
            exclusive = entry.exclusive == true,
            capacity = entry.capacity,
            status = status,
            capabilities = capabilities
        }
    end
    return result, nil
end

return {
    grades = normalizeGrades,
    roles = normalizeRoles
}
end
