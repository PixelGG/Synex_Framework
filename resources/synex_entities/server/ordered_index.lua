SynexEntityOrderedIndex = {}

function SynexEntityOrderedIndex.addIndex(index, key, value)
    if key == nil then return end
    local values = index[key]
    if not values then
        values = {}
        index[key] = values
    end
    values[value] = true
end

function SynexEntityOrderedIndex.removeIndex(index, key, value)
    if key == nil then return end
    local values = index[key]
    if not values then return end
    values[value] = nil
    if next(values) == nil then index[key] = nil end
end

function SynexEntityOrderedIndex.sortedRecords(entityIds, byId)
    local records = {}
    for entityId in pairs(entityIds or {}) do
        local record = byId[entityId]
        if record then records[#records + 1] = record end
    end
    table.sort(records, function(left, right)
        return left.entityId < right.entityId
    end)
    return records
end

function SynexEntityOrderedIndex.create()
    local keys, present = {}, {}
    local index = {}

    local function upperBound(value, inclusive)
        local low, high = 1, #keys + 1
        while low < high do
            local middle = math.floor((low + high) / 2)
            local candidate = keys[middle]
            if candidate < value or not inclusive and candidate == value then
                low = middle + 1
            else
                high = middle
            end
        end
        return low
    end

    function index.insert(key)
        if present[key] then return false end
        table.insert(keys, upperBound(key, true), key)
        present[key] = true
        return true
    end

    function index.remove(key)
        if not present[key] then return false end
        local position = upperBound(key, true)
        if keys[position] ~= key then return false end
        table.remove(keys, position)
        present[key] = nil
        return true
    end

    function index.page(after, limit, resolve)
        assert(type(limit) == 'number' and limit % 1 == 0
            and limit >= 1 and limit <= 1024, 'ordered index page limit is invalid')
        local first = after == nil and 1 or upperBound(after, false)
        local last = math.min(#keys, first + limit - 1)
        local items = {}
        for position = first, last do
            local key = keys[position]
            items[#items + 1] = resolve and resolve(key) or key
        end
        return items, {
            materialized = #items,
            total = #keys,
            visited = math.max(0, last - first + 1),
        }
    end

    function index.all(resolve)
        local items = {}
        for position, key in ipairs(keys) do
            items[position] = resolve and resolve(key) or key
        end
        return items
    end

    function index.count()
        return #keys
    end

    return index
end

function SynexEntityOrderedIndex.createStore()
    local ordered = SynexEntityOrderedIndex.create()
    local values = {}
    local store = setmetatable({}, {
        __index = function(_, key) return values[key] end,
        __len = function() return ordered.count() end,
        __newindex = function(_, key, value)
            local previous = values[key]
            if previous == nil and value ~= nil then
                ordered.insert(key)
            elseif previous ~= nil and value == nil then
                ordered.remove(key)
            end
            values[key] = value
        end,
        __pairs = function() return next, values, nil end,
    })
    local view = {}
    function view.page(after, limit)
        return ordered.page(after, limit, function(key) return values[key] end)
    end
    function view.count()
        return ordered.count()
    end
    return store, view
end
