return function(Foundation)
local function identifier(runtime, namespace)
    local value, valueError = runtime.id(namespace)
    if not value then return nil, valueError end
    return value, nil
end

local function updateOne(tx, sql, parameters)
    if tx.affected(sql, parameters) ~= 1 then
        return nil, Foundation.domainError('CONCURRENT_MODIFICATION',
            'The workflow changed concurrently.', true)
    end
    return true, nil
end

local function validWindow(tx, startsAt, endsAt)
    if startsAt == nil and endsAt == nil then return true, nil end
    local row = tx.one([[SELECT CASE
        WHEN ? IS NOT NULL AND CAST(? AS DATETIME(6)) <= CURRENT_TIMESTAMP(6) THEN 0
        WHEN ? IS NOT NULL AND ? IS NOT NULL
            AND CAST(? AS DATETIME(6)) <= CAST(? AS DATETIME(6)) THEN 0
        ELSE 1 END AS valid]], {
        endsAt, endsAt, startsAt, endsAt, endsAt, startsAt
    })
    if not row or tonumber(row.valid) ~= 1 then
        return nil, Foundation.domainError('VALIDATION_FAILED',
            'The workflow time window is invalid.')
    end
    return true, nil
end

return {
    identifier = identifier,
    updateOne = updateOne,
    validWindow = validWindow,
}
end
