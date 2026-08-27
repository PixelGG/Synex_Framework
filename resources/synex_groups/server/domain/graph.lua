local Graph = {}

local DEFAULT_MAXIMUM_NODES = 4096
local HARD_MAXIMUM_NODES = 16384

local function domainError(code, message, details)
    return { code = code, message = message, retryable = false, details = details }
end

local function validNode(value)
    return type(value) == 'string' and #value >= 1 and #value <= 128
        and value:match('^[A-Za-z0-9_.:%-]+$') ~= nil
end

local function normalizeMaximum(options)
    if options == nil then return DEFAULT_MAXIMUM_NODES, nil end
    if type(options) ~= 'table' or getmetatable(options) ~= nil then
        return nil, domainError('GRAPH_OPTIONS_INVALID', 'Graph options must be a plain object.')
    end
    for key in pairs(options) do
        if key ~= 'maximumNodes' then
            return nil, domainError('GRAPH_OPTIONS_INVALID', 'Graph options contain an unknown property.', {
                property = tostring(key)
            })
        end
    end
    local maximum = options.maximumNodes or DEFAULT_MAXIMUM_NODES
    if type(maximum) ~= 'number' or math.type(maximum) ~= 'integer'
        or maximum < 1 or maximum > HARD_MAXIMUM_NODES then
        return nil, domainError('GRAPH_LIMIT_INVALID', 'Graph maximumNodes is outside the supported range.')
    end
    return maximum, nil
end

local function normalizeEdges(edges, maximum)
    if type(edges) ~= 'table' or getmetatable(edges) ~= nil then
        return nil, nil, domainError('GRAPH_INVALID', 'Graph edges must be a plain node-to-parent map.')
    end
    local normalized, nodes, seen = {}, {}, {}
    local function include(node)
        if not seen[node] then
            if #nodes >= maximum then
                return nil, domainError('GRAPH_TOO_LARGE', 'The graph exceeds its bounded node limit.', {
                    maximumNodes = maximum
                })
            end
            seen[node] = true
            nodes[#nodes + 1] = node
        end
        return true, nil
    end
    for node, parent in pairs(edges) do
        if not validNode(node) or not validNode(parent) then
            return nil, nil, domainError('GRAPH_NODE_INVALID', 'Graph node identifiers are invalid.')
        end
        local included, includeError = include(node)
        if not included then return nil, nil, includeError end
        included, includeError = include(parent)
        if not included then return nil, nil, includeError end
        normalized[node] = parent
    end
    table.sort(nodes)
    return normalized, nodes, nil
end

local function detect(edges, options)
    local maximum, optionsError = normalizeMaximum(options)
    if not maximum then return nil, optionsError end
    local normalized, nodes, graphError = normalizeEdges(edges, maximum)
    if not normalized then return nil, graphError end

    local completed = {}
    for _, start in ipairs(nodes) do
        if not completed[start] then
            local path, positions, current = {}, {}, start
            while current and not completed[current] do
                local position = positions[current]
                if position then
                    local cycle = {}
                    for index = position, #path do cycle[#cycle + 1] = path[index] end
                    cycle[#cycle + 1] = current
                    return { cyclic = true, cycle = cycle, nodes = #nodes }, nil
                end
                positions[current] = #path + 1
                path[#path + 1] = current
                current = normalized[current]
            end
            for _, node in ipairs(path) do completed[node] = true end
        end
    end
    return { cyclic = false, cycle = {}, nodes = #nodes }, nil
end

local function withProposedEdge(edges, node, parent, options)
    if not validNode(node) or (parent ~= nil and not validNode(parent)) then
        return nil, domainError('GRAPH_NODE_INVALID', 'The proposed graph edge is invalid.')
    end
    local maximum, optionsError = normalizeMaximum(options)
    if not maximum then return nil, optionsError end
    local normalized, _, graphError = normalizeEdges(edges, maximum)
    if not normalized then return nil, graphError end
    normalized[node] = parent
    return detect(normalized, { maximumNodes = maximum })
end

function Graph.detectGroupParents(parentByGroup, options)
    return detect(parentByGroup, options)
end

function Graph.wouldCreateGroupParentCycle(parentByGroup, groupId, parentGroupId, options)
    return withProposedEdge(parentByGroup, groupId, parentGroupId, options)
end

function Graph.detectReportsTo(reportsToByMember, options)
    return detect(reportsToByMember, options)
end

function Graph.wouldCreateReportsToCycle(reportsToByMember, membershipId, managerMembershipId, options)
    return withProposedEdge(reportsToByMember, membershipId, managerMembershipId, options)
end

return Graph
