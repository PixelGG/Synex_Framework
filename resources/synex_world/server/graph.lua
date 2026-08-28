SynexWorldGraph = {}

local Graph = SynexWorldGraph
local Validation = assert(SynexWorldValidation, 'world validation must be loaded first')

local parentKinds = {
    region = { region = true },
    location = { region = true },
    interior = { location = true },
    room = { interior = true },
    zone = { region = true, location = true, interior = true, room = true },
    anchor = { region = true, location = true, interior = true, room = true, zone = true },
    door = { location = true, interior = true, room = true, zone = true },
    portal = { region = true, location = true, interior = true, room = true, zone = true },
    world_state_definition = { region = true, location = true, interior = true, room = true },
}

local allowedKinds = {
    region = true, location = true, interior = true, room = true, zone = true,
    anchor = true, door = true, portal = true, instance_template = true,
    map_package = true, ipl_bundle = true, world_state_definition = true,
}

function Graph.isKind(value) return allowedKinds[value] == true end

function Graph.build(objects)
    if type(objects) ~= 'table' then
        return Validation.failure('WORLD_BUNDLE_INVALID', 'World graph objects are invalid.')
    end
    local children, roots = {}, {}
    for key in pairs(objects) do children[key] = {} end
    for key, object in pairs(objects) do
        if not allowedKinds[object.kind] then
            return Validation.failure('WORLD_BUNDLE_INVALID', 'World object kind is unsupported.',
                false, { key = key })
        end
        if object.parent ~= nil then
            local parent = objects[object.parent]
            if not parent then
                return Validation.failure('WORLD_REFERENCE_INVALID', 'World parent does not exist.',
                    false, { key = key, parent = object.parent })
            end
            local validParents = parentKinds[object.kind]
            if not validParents or not validParents[parent.kind] then
                return Validation.failure('WORLD_REFERENCE_INVALID', 'World parent kind is invalid.',
                    false, { key = key, parent = object.parent })
            end
            children[object.parent][#children[object.parent] + 1] = key
        else
            roots[#roots + 1] = key
        end
    end
    local states, stack = {}, {}
    local function visit(key)
        if states[key] == 1 then
            local cycle = {}
            for index = #stack, 1, -1 do
                cycle[#cycle + 1] = stack[index]
                if stack[index] == key then break end
            end
            table.sort(cycle)
            return Validation.failure('WORLD_GRAPH_CYCLE', 'World containment graph contains a cycle.',
                false, { keys = cycle })
        end
        if states[key] == 2 then return true end
        states[key] = 1
        stack[#stack + 1] = key
        for _, child in ipairs(children[key]) do
            local valid, graphError = visit(child)
            if not valid then return nil, graphError end
        end
        stack[#stack] = nil
        states[key] = 2
        return true
    end
    table.sort(roots)
    for _, root in ipairs(roots) do
        local valid, graphError = visit(root)
        if not valid then return nil, graphError end
    end
    for key in pairs(objects) do
        if states[key] == nil then
            local valid, graphError = visit(key)
            if not valid then return nil, graphError end
        end
        table.sort(children[key])
    end
    return { children = children, roots = roots }
end

function Graph.ancestors(graph, objects, key, maximum)
    local result, seen = {}, {}
    local current = objects[key]
    maximum = maximum or 64
    while current and current.parent and #result < maximum do
        if seen[current.parent] then break end
        seen[current.parent] = true
        result[#result + 1] = current.parent
        current = objects[current.parent]
    end
    return result
end

function Graph.subtree(graph, key, maximum)
    maximum = maximum or 256
    local result, queue, cursor = {}, { key }, 1
    while cursor <= #queue and #result < maximum do
        local current = queue[cursor]
        cursor = cursor + 1
        result[#result + 1] = current
        for _, child in ipairs(graph.children[current] or {}) do queue[#queue + 1] = child end
    end
    return result, cursor <= #queue
end
