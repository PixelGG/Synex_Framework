SynexWorldGeometry = {}

local Geometry = SynexWorldGeometry
local Validation = assert(SynexWorldValidation, 'world validation must be loaded first')
local Limits = assert(SynexWorldLimits, 'world limits must be loaded first')

local function invalid(message, details)
    return Validation.failure('WORLD_GEOMETRY_INVALID', message, false, details)
end

local function bounds(minX, minY, minZ, maxX, maxY, maxZ)
    return { minX = minX, minY = minY, minZ = minZ,
        maxX = maxX, maxY = maxY, maxZ = maxZ }
end

local function mergeBounds(left, right)
    return bounds(math.min(left.minX, right.minX), math.min(left.minY, right.minY),
        math.min(left.minZ, right.minZ), math.max(left.maxX, right.maxX),
        math.max(left.maxY, right.maxY), math.max(left.maxZ, right.maxZ))
end

local function validateExtent(value)
    return Validation.isFinite(value) and value >= Limits.minimumGeometryExtent
        and value <= Limits.maximumGeometryExtent
end

local function orientation(a, b, c)
    return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
end

local function onSegment(a, b, c)
    return b.x >= math.min(a.x, c.x) and b.x <= math.max(a.x, c.x)
        and b.y >= math.min(a.y, c.y) and b.y <= math.max(a.y, c.y)
end

local function segmentsIntersect(a, b, c, d)
    local o1, o2 = orientation(a, b, c), orientation(a, b, d)
    local o3, o4 = orientation(c, d, a), orientation(c, d, b)
    if ((o1 > 0 and o2 < 0) or (o1 < 0 and o2 > 0))
        and ((o3 > 0 and o4 < 0) or (o3 < 0 and o4 > 0)) then return true end
    local epsilon = 1e-9
    if math.abs(o1) <= epsilon and onSegment(a, c, b) then return true end
    if math.abs(o2) <= epsilon and onSegment(a, d, b) then return true end
    if math.abs(o3) <= epsilon and onSegment(c, a, d) then return true end
    if math.abs(o4) <= epsilon and onSegment(c, b, d) then return true end
    return false
end

local function polygonSelfIntersects(vertices)
    local count = #vertices
    for first = 1, count do
        local firstNext = first % count + 1
        for second = first + 1, count do
            local secondNext = second % count + 1
            if first ~= second and firstNext ~= second and secondNext ~= first
                and not (first == 1 and secondNext == 1)
                and segmentsIntersect(vertices[first], vertices[firstNext],
                    vertices[second], vertices[secondNext]) then
                return true
            end
        end
    end
    return false
end

local function compilePolygon(candidate)
    if not Validation.isDenseArray(candidate.vertices, Limits.maximumPolygonVertices)
        or #candidate.vertices < 3 then
        return invalid('Polygon vertices must be a bounded array with at least three points.')
    end
    if not Validation.isFinite(candidate.minZ) or not Validation.isFinite(candidate.maxZ)
        or candidate.minZ < Limits.coordinateMinimum or candidate.maxZ > Limits.coordinateMaximum
        or candidate.maxZ - candidate.minZ < Limits.minimumGeometryExtent then
        return invalid('Polygon vertical bounds are invalid.')
    end
    local vertices, area, minX, minY, maxX, maxY = {}, 0,
        math.huge, math.huge, -math.huge, -math.huge
    for index, vertex in ipairs(candidate.vertices) do
        if not Validation.exactObject(vertex, { x = true, y = true })
            or not Validation.isFinite(vertex.x) or not Validation.isFinite(vertex.y)
            or vertex.x < Limits.coordinateMinimum or vertex.x > Limits.coordinateMaximum
            or vertex.y < Limits.coordinateMinimum or vertex.y > Limits.coordinateMaximum then
            return invalid('Polygon contains an invalid vertex.', { vertex = index })
        end
        local normalized = { x = vertex.x + 0.0, y = vertex.y + 0.0 }
        local previous = vertices[index - 1]
        if previous and previous.x == normalized.x and previous.y == normalized.y then
            return invalid('Polygon contains adjacent duplicate vertices.', { vertex = index })
        end
        vertices[index] = normalized
        minX, minY = math.min(minX, normalized.x), math.min(minY, normalized.y)
        maxX, maxY = math.max(maxX, normalized.x), math.max(maxY, normalized.y)
    end
    if vertices[1].x == vertices[#vertices].x and vertices[1].y == vertices[#vertices].y then
        return invalid('Polygon must not repeat its first vertex at the end.')
    end
    for index, vertex in ipairs(vertices) do
        local following = vertices[index % #vertices + 1]
        area = area + vertex.x * following.y - following.x * vertex.y
    end
    if math.abs(area) < Limits.minimumGeometryExtent then
        return invalid('Polygon area is degenerate.')
    end
    if polygonSelfIntersects(vertices) then
        return invalid('Polygon edges intersect.')
    end
    return {
        kind = 'polygon', vertices = vertices,
        minZ = candidate.minZ + 0.0, maxZ = candidate.maxZ + 0.0,
        bounds = bounds(minX, minY, candidate.minZ, maxX, maxY, candidate.maxZ),
    }
end

function Geometry.compile(candidate, depth)
    depth = depth or 0
    if depth > Limits.maximumGeometryDepth or not Validation.isPlainTable(candidate)
        or type(candidate.type) ~= 'string' then
        return invalid('Geometry is invalid or exceeds maximum nesting depth.')
    end
    if candidate.type == 'point' then
        if not Validation.exactObject(candidate, { type = true, position = true }) then
            return invalid('Point geometry contains unsupported fields.')
        end
        local position, positionError = Validation.vector3(candidate.position)
        if not position then return nil, positionError end
        return { kind = 'point', position = position,
            bounds = bounds(position.x, position.y, position.z,
                position.x, position.y, position.z) }
    end
    if candidate.type == 'sphere' then
        if not Validation.exactObject(candidate, { type = true, center = true, radius = true })
            or not validateExtent(candidate.radius) then
            return invalid('Sphere geometry is invalid.')
        end
        local center, centerError = Validation.vector3(candidate.center)
        if not center then return nil, centerError end
        local radius = candidate.radius + 0.0
        return { kind = 'sphere', center = center, radius = radius,
            bounds = bounds(center.x - radius, center.y - radius, center.z - radius,
                center.x + radius, center.y + radius, center.z + radius) }
    end
    if candidate.type == 'aabb' then
        if not Validation.exactObject(candidate, { type = true, min = true, max = true }) then
            return invalid('Axis-aligned box geometry is invalid.')
        end
        local minimum, minimumError = Validation.vector3(candidate.min)
        if not minimum then return nil, minimumError end
        local maximum, maximumError = Validation.vector3(candidate.max)
        if not maximum then return nil, maximumError end
        if maximum.x - minimum.x < Limits.minimumGeometryExtent
            or maximum.y - minimum.y < Limits.minimumGeometryExtent
            or maximum.z - minimum.z < Limits.minimumGeometryExtent then
            return invalid('Axis-aligned box extents are invalid.')
        end
        return { kind = 'aabb', min = minimum, max = maximum,
            bounds = bounds(minimum.x, minimum.y, minimum.z,
                maximum.x, maximum.y, maximum.z) }
    end
    if candidate.type == 'box' then
        if not Validation.exactObject(candidate,
                { type = true, center = true, size = true, heading = true })
            or not Validation.isPlainTable(candidate.size)
            or not Validation.exactObject(candidate.size, { x = true, y = true, z = true })
            or not validateExtent(candidate.size.x) or not validateExtent(candidate.size.y)
            or not validateExtent(candidate.size.z) or not Validation.isFinite(candidate.heading)
            or math.abs(candidate.heading) > 360000 then
            return invalid('Rotated box geometry is invalid.')
        end
        local center, centerError = Validation.vector3(candidate.center)
        if not center then return nil, centerError end
        local heading = candidate.heading % 360
        local radians, halfX, halfY, halfZ = math.rad(heading),
            candidate.size.x / 2, candidate.size.y / 2, candidate.size.z / 2
        local extentX = math.abs(math.cos(radians)) * halfX + math.abs(math.sin(radians)) * halfY
        local extentY = math.abs(math.sin(radians)) * halfX + math.abs(math.cos(radians)) * halfY
        return { kind = 'box', center = center,
            half = { x = halfX, y = halfY, z = halfZ }, heading = heading,
            sin = math.sin(radians), cos = math.cos(radians),
            bounds = bounds(center.x - extentX, center.y - extentY, center.z - halfZ,
                center.x + extentX, center.y + extentY, center.z + halfZ) }
    end
    if candidate.type == 'polygon' then
        if not Validation.exactObject(candidate,
                { type = true, vertices = true, minZ = true, maxZ = true }) then
            return invalid('Polygon geometry contains unsupported fields.')
        end
        return compilePolygon(candidate)
    end
    if candidate.type == 'composite' then
        if not Validation.exactObject(candidate,
                { type = true, operation = true, geometries = true })
            or candidate.operation ~= 'union'
            or not Validation.isDenseArray(candidate.geometries, Limits.maximumCompositeParts)
            or #candidate.geometries < 1 then
            return invalid('Composite geometry must be a bounded union.')
        end
        local parts, combined = {}, nil
        for index, part in ipairs(candidate.geometries) do
            local compiled, compileError = Geometry.compile(part, depth + 1)
            if not compiled then
                if type(compileError) == 'table' then
                    compileError.details = compileError.details or {}
                    compileError.details.part = index
                end
                return nil, compileError
            end
            parts[index] = compiled
            combined = combined and mergeBounds(combined, compiled.bounds) or compiled.bounds
        end
        return { kind = 'composite', operation = 'union', parts = parts, bounds = combined }
    end
    return invalid('Geometry type is unsupported.')
end

local function pointSegmentDistanceSquared(point, first, second)
    local dx, dy = second.x - first.x, second.y - first.y
    if dx == 0 and dy == 0 then
        local px, py = point.x - first.x, point.y - first.y
        return px * px + py * py
    end
    local t = ((point.x - first.x) * dx + (point.y - first.y) * dy) / (dx * dx + dy * dy)
    t = math.max(0, math.min(1, t))
    local px, py = point.x - (first.x + t * dx), point.y - (first.y + t * dy)
    return px * px + py * py
end

local function polygonContains(compiled, point, margin)
    if point.z < compiled.minZ - margin or point.z > compiled.maxZ + margin then return false end
    local inside, vertices = false, compiled.vertices
    local previous = #vertices
    for index = 1, #vertices do
        local a, b = vertices[index], vertices[previous]
        if ((a.y > point.y) ~= (b.y > point.y))
            and point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x then
            inside = not inside
        end
        if margin > 0 and pointSegmentDistanceSquared(point, a, b) <= margin * margin then
            return true
        end
        previous = index
    end
    return inside
end

function Geometry.contains(compiled, point, margin)
    margin = Validation.isFinite(margin) and math.max(0, margin) or 0
    if not compiled or not Validation.isFinite(point.x) or not Validation.isFinite(point.y)
        or not Validation.isFinite(point.z) then return false end
    if compiled.kind == 'point' then
        return math.abs(point.x - compiled.position.x) <= margin
            and math.abs(point.y - compiled.position.y) <= margin
            and math.abs(point.z - compiled.position.z) <= margin
    elseif compiled.kind == 'sphere' then
        local dx, dy, dz = point.x - compiled.center.x,
            point.y - compiled.center.y, point.z - compiled.center.z
        local radius = compiled.radius + margin
        return dx * dx + dy * dy + dz * dz <= radius * radius
    elseif compiled.kind == 'aabb' then
        return point.x >= compiled.min.x - margin and point.x <= compiled.max.x + margin
            and point.y >= compiled.min.y - margin and point.y <= compiled.max.y + margin
            and point.z >= compiled.min.z - margin and point.z <= compiled.max.z + margin
    elseif compiled.kind == 'box' then
        local dx, dy = point.x - compiled.center.x, point.y - compiled.center.y
        local localX = dx * compiled.cos + dy * compiled.sin
        local localY = -dx * compiled.sin + dy * compiled.cos
        return math.abs(localX) <= compiled.half.x + margin
            and math.abs(localY) <= compiled.half.y + margin
            and math.abs(point.z - compiled.center.z) <= compiled.half.z + margin
    elseif compiled.kind == 'polygon' then
        return polygonContains(compiled, point, margin)
    elseif compiled.kind == 'composite' then
        for _, part in ipairs(compiled.parts) do
            if Geometry.contains(part, point, margin) then return true end
        end
    end
    return false
end

function Geometry.distanceSquaredToBounds(compiled, point)
    local candidate = compiled.bounds
    local dx = point.x < candidate.minX and candidate.minX - point.x
        or point.x > candidate.maxX and point.x - candidate.maxX or 0
    local dy = point.y < candidate.minY and candidate.minY - point.y
        or point.y > candidate.maxY and point.y - candidate.maxY or 0
    local dz = point.z < candidate.minZ and candidate.minZ - point.z
        or point.z > candidate.maxZ and point.z - candidate.maxZ or 0
    return dx * dx + dy * dy + dz * dz
end

function Geometry.centroid(compiled)
    local candidate = compiled.bounds
    return { x = (candidate.minX + candidate.maxX) / 2,
        y = (candidate.minY + candidate.maxY) / 2,
        z = (candidate.minZ + candidate.maxZ) / 2 }
end
