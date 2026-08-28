SynexInteractActionGraph = {}

local Graph = SynexInteractActionGraph
local V = SynexInteractValidation
local L = SynexInteractLimits

local allowedNodeTypes = {
    call = true,
    wait = true,
    emit = true,
    branch = true,
    complete = true,
    fail = true,
}

local function validName(value, maximum)
    return type(value) == 'string' and #value >= 1 and #value <= (maximum or 128)
        and value:find('[%z\1-\31\127]') == nil
end

local function validCapability(value)
    return type(value) == 'string' and #value >= 3 and #value <= 128
        and value:match('^[a-z][a-z0-9%._%-]*$') ~= nil
end

function Graph.validate(graph)
    if graph == nil then return nil end
    if type(graph) ~= 'table' or type(graph.nodes) ~= 'table' or not validName(graph.entry, 64) then
        return V.failure('INTERACT_GRAPH_INVALID', 'Interaction action graph is invalid.')
    end
    local count = 0
    for key, node in pairs(graph.nodes) do
        count = count + 1
        if count > L.maximumGraphNodes or not validName(key, 64) or type(node) ~= 'table'
            or not allowedNodeTypes[node.type] then
            return V.failure('INTERACT_GRAPH_INVALID', 'Interaction action graph node is invalid.')
        end
        if node.type == 'call' then
            if not validName(node.service, 128) or not validName(node.method, 128)
                or not validCapability(node.capability) or not validName(node.next, 64) then
                return V.failure('INTERACT_GRAPH_INVALID',
                    'Call nodes require service, method, capability, and next.')
            end
        elseif node.type == 'emit' then
            if not validName(node.topic, 128) or not validName(node.next, 64) then
                return V.failure('INTERACT_GRAPH_INVALID', 'Emit nodes require topic and next.')
            end
        elseif node.type == 'wait' then
            if not V.isInteger(node.milliseconds, 0, 10000) or not validName(node.next, 64) then
                return V.failure('INTERACT_GRAPH_INVALID', 'Wait nodes require a bounded duration and next.')
            end
        elseif node.type == 'branch' then
            if not validName(node.field, 64) or not validName(node.whenTrue, 64)
                or not validName(node.whenFalse, 64) then
                return V.failure('INTERACT_GRAPH_INVALID',
                    'Branch nodes require field, whenTrue, and whenFalse.')
            end
        elseif node.type == 'fail' then
            if node.code ~= nil and (type(node.code) ~= 'string' or #node.code < 2 or #node.code > 64
                or not node.code:match('^INTERACT_[A-Z0-9_]+$')) then
                return V.failure('INTERACT_GRAPH_INVALID', 'Fail node error code is invalid.')
            end
            if node.message ~= nil and (type(node.message) ~= 'string' or #node.message < 1 or #node.message > 256) then
                return V.failure('INTERACT_GRAPH_INVALID', 'Fail node message is invalid.')
            end
        end
    end
    if count < 1 or not graph.nodes[graph.entry] then
        return V.failure('INTERACT_GRAPH_INVALID', 'Interaction action graph entry node is missing.')
    end
    for _, node in pairs(graph.nodes) do
        local references = {}
        if node.type == 'branch' then
            references = { node.whenTrue, node.whenFalse }
        elseif node.type == 'call' or node.type == 'wait' or node.type == 'emit' then
            references = { node.next }
        end
        for _, reference in ipairs(references) do
            if not graph.nodes[reference] then
                return V.failure('INTERACT_GRAPH_INVALID',
                    'Interaction action graph references a missing node.')
            end
        end
    end
    return V.copy(graph)
end

function Graph.create(options)
    local handlers = options.handlers or {}
    local wait = options.wait or Wait
    local api = {}

    local function nextKey(node, result)
        if node.type == 'branch' then return result and node.whenTrue or node.whenFalse end
        return node.next
    end

    function api.execute(graph, context)
        local validated, validationError = Graph.validate(graph)
        if not validated then return nil, validationError end
        local current, depth = validated.entry, 0
        while current do
            depth = depth + 1
            if depth > L.maximumGraphDepth then
                return V.failure('INTERACT_GRAPH_LIMIT', 'Interaction action graph exceeded execution depth.')
            end
            local node = validated.nodes[current]
            if not node then
                return V.failure('INTERACT_GRAPH_INVALID', 'Interaction action graph references a missing node.')
            end
            if node.type == 'complete' then
                return { state = 'COMPLETED', result = V.copy(node.result or {}) }
            elseif node.type == 'fail' then
                return V.failure(node.code or 'INTERACT_ACTION_FAILED', node.message or 'Interaction action failed.')
            elseif node.type == 'wait' then
                wait(node.milliseconds)
                current = node.next
            elseif node.type == 'call' then
                local handler = handlers.call
                if type(handler) ~= 'function' then
                    return V.failure('INTERACT_ACTION_UNAVAILABLE', 'Interaction call handler is unavailable.', true)
                end
                local result, callError = handler(node, context)
                if result == nil then return nil, callError end
                context.lastResult = V.copy(result)
                current = nextKey(node, result)
            elseif node.type == 'emit' then
                local handler = handlers.emit
                if type(handler) ~= 'function' then
                    return V.failure('INTERACT_ACTION_UNAVAILABLE', 'Interaction event handler is unavailable.', true)
                end
                local emitted, emitError = handler(node, context)
                if not emitted then return nil, emitError end
                current = node.next
            elseif node.type == 'branch' then
                local handler = handlers.branch
                if type(handler) ~= 'function' then
                    return V.failure('INTERACT_ACTION_UNAVAILABLE', 'Interaction branch handler is unavailable.', true)
                end
                local decision, branchError = handler(node, context)
                if decision == nil then return nil, branchError end
                current = nextKey(node, decision == true)
            end
        end
        return V.failure('INTERACT_GRAPH_INVALID', 'Interaction action graph ended without completion.')
    end

    return api
end
