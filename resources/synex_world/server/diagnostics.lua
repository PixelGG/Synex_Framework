SynexWorldDiagnostics = {}

local Diagnostics = SynexWorldDiagnostics
local Validation = assert(SynexWorldValidation, 'world validation must be loaded first')
local Limits = assert(SynexWorldLimits, 'world limits must be loaded first')

function Diagnostics.create(options)
    local foundation = assert(options.foundation, 'world diagnostics require foundation')
    local registry = assert(options.registry, 'world diagnostics require registry')
    local mapRegistry = assert(options.mapRegistry, 'world diagnostics require maps')
    local instances = assert(options.instances, 'world diagnostics require instances')
    local slices = assert(options.slices, 'world diagnostics require slices')
    local outbox = assert(options.outbox, 'world diagnostics require outbox')
    local database = assert(options.database, 'world diagnostics require persistence')
    local getResourceState = assert(options.getResourceState,
        'world diagnostics require resource state')
    local resolveEntity = options.resolveEntity
    local resolveBucket = options.resolveBucket
    local lastReport
    local staticRevision, staticBundleKeys, staticMapPackages = -1, {}, {}
    local staticPhase, staticCursor = 'bundles', 1
    local authorityRevision, authorityCursor, instanceCursor = -1, 1, ''
    local persistencePhase = 'state'
    local persistenceStateCursor = { key = '', scopeType = '', scopeRef = '' }
    local persistenceDoorCursor = ''
    local maximumStaticChecks, maximumImpactAnalyses = 64, 2
    local maximumAuthorityScans, maximumEntityChecks = 64, 32
    local doctorRevision = -1
    local scanCycles = {}
    local diagnostics = {}

    local function resetScanCycles(revision)
        doctorRevision = revision
        scanCycles = {
            static = { actionable = false, completed = false },
            authority = { actionable = false, completed = false },
            persistence = { actionable = false, completed = false },
            outbox = { actionable = false, completed = false },
        }
    end

    local function observeScan(name, complete, actionable)
        local cycle = scanCycles[name]
        cycle.actionable = cycle.actionable or actionable == true
        if complete then
            cycle.lastActionable = cycle.actionable
            cycle.actionable = false
            cycle.completed = true
        end
    end

    local function scanDegraded(name)
        local cycle = scanCycles[name]
        return cycle.completed ~= true or cycle.lastActionable == true
            or cycle.actionable == true
    end

    local function counts()
        local value = {}
        for _, object in pairs(registry.objects()) do
            value[object.kind] = (value[object.kind] or 0) + 1
        end
        return value
    end

    local function finding(items, maximum, severity, code, summary, subject, details)
        if #items >= maximum then return false end
        items[#items + 1] = { severity = severity, code = code, title = code,
            summary = summary, subjectRef = subject, details = details }
        return true
    end

    local function persistenceFindings(items, maximum)
        local remaining = maximum - #items
        local checked = 0
        while remaining > 0 do
            if persistencePhase == 'state' then
                local cursor = persistenceStateCursor
                local stateRows, stateError = database:read([[SELECT `state_key`, `scope_type`,
                        `scope_ref`, `schema_version`, `value_type`, `version`
                    FROM `synex_world_state`
                    WHERE `state_key` > ?
                        OR (`state_key` = ? AND `scope_type` > ?)
                        OR (`state_key` = ? AND `scope_type` = ? AND `scope_ref` > ?)
                    ORDER BY `state_key`, `scope_type`, `scope_ref` LIMIT ?]], {
                    cursor.key, cursor.key, cursor.scopeType,
                    cursor.key, cursor.scopeType, cursor.scopeRef, remaining + 1,
                }, { maximumRows = remaining + 1,
                    maximumResultBytes = 512 * 1024, timeoutMs = 5000 })
                if not stateRows then
                    finding(items, maximum, 'ERROR', 'STATE_STORE_UNAVAILABLE',
                        'Persistent World state could not be inspected.', nil,
                        { cause = stateError and stateError.code })
                    return false, checked
                end
                local inspected = math.min(#stateRows, remaining)
                for index = 1, inspected do
                    local row = stateRows[index]
                    local definition = registry.objects()[row.state_key]
                    if not definition then
                        finding(items, maximum, 'WARNING', 'STALE_PERSISTENT_STATE',
                            'Persistent state has no active resource-owned definition.', row.state_key)
                    elseif definition.kind ~= 'world_state_definition'
                        or tonumber(row.schema_version) ~= definition.schemaVersion
                        or row.value_type ~= definition.stateType
                        or row.scope_type ~= definition.scope then
                        finding(items, maximum, 'ERROR', 'STATE_SCHEMA_MISMATCH',
                            'Persistent state is incompatible with its active definition.', row.state_key)
                    elseif row.scope_type == 'instance' then
                        local instance = instances.get(row.scope_ref)
                        if not instance or instance.state == 'CLOSED' then
                            finding(items, maximum, 'ERROR', 'STALE_INSTANCE_STATE',
                                'Persistent state belongs to a closed or unavailable World instance.',
                                row.state_key, { instanceId = row.scope_ref })
                        end
                    end
                end
                checked, remaining = checked + inspected, remaining - inspected
                if inspected > 0 then
                    local row = stateRows[inspected]
                    persistenceStateCursor = { key = row.state_key,
                        scopeType = row.scope_type, scopeRef = row.scope_ref }
                end
                if #stateRows > inspected then return false, checked end
                persistenceStateCursor = { key = '', scopeType = '', scopeRef = '' }
                persistencePhase = 'doors'
            else
                local doorRows, doorError = database:read([[SELECT `door_key`, `schema_version`,
                        `state`, `version` FROM `synex_world_door_states`
                    WHERE `door_key` > ? ORDER BY `door_key` LIMIT ?]], {
                    persistenceDoorCursor, remaining + 1,
                }, { maximumRows = remaining + 1,
                    maximumResultBytes = 256 * 1024, timeoutMs = 5000 })
                if not doorRows then
                    finding(items, maximum, 'ERROR', 'STATE_STORE_UNAVAILABLE',
                        'Persistent World door state could not be inspected.', nil,
                        { cause = doorError and doorError.code })
                    return false, checked
                end
                local inspected = math.min(#doorRows, remaining)
                for index = 1, inspected do
                    local row = doorRows[index]
                    local door = registry.objects()[row.door_key]
                    if not door then
                        finding(items, maximum, 'WARNING', 'STALE_PERSISTENT_DOOR_STATE',
                            'Persistent door state has no active resource-owned definition.', row.door_key)
                    elseif door.kind ~= 'door' or tonumber(row.schema_version) ~= Limits.schemaVersion
                        or row.state ~= 'LOCKED' and row.state ~= 'UNLOCKED'
                            and row.state ~= 'DISABLED' then
                        finding(items, maximum, 'ERROR', 'STATE_SCHEMA_MISMATCH',
                            'Persistent door state is incompatible with its active definition.', row.door_key)
                    end
                end
                checked, remaining = checked + inspected, remaining - inspected
                if inspected > 0 then persistenceDoorCursor = doorRows[inspected].door_key end
                if #doorRows > inspected then return false, checked end
                persistenceDoorCursor, persistencePhase = '', 'state'
                return true, checked
            end
        end
        return false, checked
    end

    local function ensureStaticIndex()
        local revision = registry.currentRevision()
        if staticRevision == revision then return end
        staticBundleKeys = {}
        for key in pairs(registry.bundles()) do
            staticBundleKeys[#staticBundleKeys + 1] = key
        end
        table.sort(staticBundleKeys)
        if type(registry.kindObjects) == 'function' then
            staticMapPackages = registry.kindObjects('map_package')
        else
            staticMapPackages = {}
            for _, object in pairs(registry.objects()) do
                if object.kind == 'map_package' then
                    staticMapPackages[#staticMapPackages + 1] = object
                end
            end
            table.sort(staticMapPackages, function(left, right) return left.key < right.key end)
        end
        staticRevision, staticPhase, staticCursor = revision, 'bundles', 1
    end

    local function staticFindings(items, maximum)
        ensureStaticIndex()
        local checked, impactAnalyses, complete = 0, 0, false
        while checked < maximumStaticChecks and #items < maximum do
            if staticPhase == 'bundles' then
                local key = staticBundleKeys[staticCursor]
                if key == nil then
                    staticPhase, staticCursor = 'maps', 1
                else
                    staticCursor, checked = staticCursor + 1, checked + 1
                    local bundle = registry.bundles()[key]
                    for _, dependency in ipairs(bundle and bundle.dependencies or {}) do
                        if getResourceState(dependency) ~= 'started' then
                            finding(items, maximum, 'ERROR', 'WORLD_DEPENDENCY_MISSING',
                                'A declared World bundle dependency is not started.', key,
                                { dependency = dependency })
                        end
                    end
                end
            else
                local object = staticMapPackages[staticCursor]
                if object == nil then
                    staticPhase, staticCursor = 'bundles', 1
                    complete = true
                    break
                end
                staticCursor, checked = staticCursor + 1, checked + 1
                local status = mapRegistry.get(object.key)
                if status and not status.available then
                    local impact, impactError
                    if impactAnalyses < maximumImpactAnalyses then
                        impactAnalyses = impactAnalyses + 1
                        impact, impactError = mapRegistry.impact(object.key, 8)
                    end
                    finding(items, maximum, object.required and 'ERROR' or 'WARNING',
                        'MAP_RESOURCE_UNAVAILABLE',
                        'A World map package is not available.', object.key,
                        { resource = object.resourceName, state = status.state,
                            impact = impact, impactDeferred = impact == nil
                                and impactError == nil,
                            impactUnavailable = impactError and impactError.code or nil })
                end
            end
        end
        local spatial = registry.spatial().diagnostics(16)
        if spatial.maximumCandidates > Limits.maximumQueryCandidates * 0.9 then
            finding(items, maximum, 'WARNING', 'SPATIAL_INDEX_DEGRADED',
                'Observed spatial candidate pressure is near the configured bound.', nil,
                { maximumCandidates = spatial.maximumCandidates })
        end
        local sliceSummary = slices.summary()
        if sliceSummary.bytes > Limits.maximumSliceBytes * math.max(1, sliceSummary.clients) * 0.9 then
            finding(items, maximum, 'WARNING', 'CLIENT_SLICE_PRESSURE',
                'Client slice memory pressure is near its configured bound.')
        end
        return complete, checked, impactAnalyses
    end

    local function authorityFindings(items, maximum)
        local revision = registry.currentRevision()
        if authorityRevision ~= revision then
            authorityRevision, authorityCursor = revision, 1
        end
        local checkedEntities, scannedAnchors = 0, 0
        local anchors
        if type(registry.kindObjects) == 'function' then
            anchors = registry.kindObjects('anchor')
        else
            anchors = {}
            for _, object in pairs(registry.objects()) do
                if object.kind == 'anchor' then anchors[#anchors + 1] = object end
            end
            table.sort(anchors, function(left, right) return left.key < right.key end)
        end
        if type(resolveEntity) == 'function' then
            while authorityCursor <= #anchors and scannedAnchors < maximumAuthorityScans
                and checkedEntities < maximumEntityChecks and #items < maximum do
                local object = anchors[authorityCursor]
                authorityCursor, scannedAnchors = authorityCursor + 1, scannedAnchors + 1
                if object.entityRef then
                    checkedEntities = checkedEntities + 1
                    local entity, entityError = resolveEntity(object.entityRef)
                    if not entity then
                        local code = entityError and entityError.code
                        local stale = code == 'STALE_ENTITY' or code == 'NOT_FOUND'
                        finding(items, maximum, stale and 'ERROR' or 'WARNING',
                            stale and 'STALE_ENTITY_REF' or 'ENTITY_AUTHORITY_UNAVAILABLE',
                            'An entity-bound World anchor could not be resolved.', object.key,
                            { cause = code })
                    end
                end
            end
        end
        local anchorsComplete = type(resolveEntity) ~= 'function'
            or authorityCursor > #anchors
        if anchorsComplete then authorityCursor = 1 end
        local records, nextCursor = instances.list(instanceCursor, 100)
        for _, instance in ipairs(records) do
            if #items >= maximum then
                return checkedEntities, false, scannedAnchors
            end
            if instance.state == 'FAILED' then
                finding(items, maximum, 'ERROR', 'INSTANCE_BUCKET_FAILURE',
                    'A World instance failed before bucket cleanup completed.', instance.instanceId)
            elseif instance.bucketRef and type(resolveBucket) == 'function'
                and instance.state ~= 'CLOSED' then
                local bucket, bucketError = resolveBucket(instance.bucketRef)
                if not bucket then
                    finding(items, maximum, 'ERROR', 'INSTANCE_BUCKET_LEAK',
                        'A live World instance has no matching entity bucket.', instance.instanceId,
                        { cause = bucketError and bucketError.code })
                end
            end
        end
        local instancesComplete = nextCursor == nil
        instanceCursor = nextCursor or ''
        return checkedEntities, anchorsComplete and instancesComplete, scannedAnchors
    end

    function diagnostics.summary()
        local objectCounts = counts()
        return {
            health = foundation.healthSnapshot(),
            revision = registry.currentRevision(),
            bundles = registry.bundleCount(), objects = registry.objectCount(),
            counts = objectCounts, maps = mapRegistry.summary(),
            instances = instances.summary(), slices = slices.summary(),
            spatial = registry.spatial().diagnostics(8),
            outbox = select(1, outbox:status()),
        }
    end

    function diagnostics.doctor(request)
        request = request or {}
        local maximum = request.limit or 100
        if not Validation.exactObject(request, { limit = true, includePersistence = true })
            or not Validation.isInteger(maximum, 1, 250)
            or request.includePersistence ~= nil
                and type(request.includePersistence) ~= 'boolean' then
            return Validation.failure('INVALID_ARGUMENT', 'World doctor bounds are invalid.')
        end
        local revision = registry.currentRevision()
        if revision ~= doctorRevision then resetScanCycles(revision) end
        local items = {}
        local before = #items
        local staticComplete, staticChecks, impactAnalyses = staticFindings(items, maximum)
        observeScan('static', staticComplete, #items > before)
        local entityChecks, authorityComplete, authorityScans = 0, false, 0
        if #items < maximum then
            before = #items
            entityChecks, authorityComplete, authorityScans = authorityFindings(items, maximum)
            observeScan('authority', authorityComplete, #items > before)
        end
        local persistenceComplete, persistenceChecks = true, 0
        if request.includePersistence ~= false and #items < maximum then
            before = #items
            persistenceComplete, persistenceChecks = persistenceFindings(items, maximum)
            observeScan('persistence', persistenceComplete, #items > before)
        end
        local outboxComplete = #items < maximum
        if outboxComplete then
            before = #items
            local outboxStatus, outboxError = outbox:status()
            if not outboxStatus then
                finding(items, maximum, 'ERROR', 'STATE_STORE_UNAVAILABLE',
                    'World outbox status is unavailable.', nil,
                    { cause = outboxError and outboxError.code })
            elseif outboxStatus.dead > 0 then
                finding(items, maximum, 'ERROR', 'OUTBOX_DELIVERY_DEAD',
                    'World outbox contains dead delivery records.', nil,
                    { records = outboxStatus.dead })
            end
            observeScan('outbox', true, #items > before)
        end
        table.sort(items, function(left, right)
            local rank = { ERROR = 1, WARNING = 2, INFO = 3 }
            return (rank[left.severity] or 4) < (rank[right.severity] or 4)
                or left.severity == right.severity and left.code < right.code
                or left.severity == right.severity and left.code == right.code
                    and tostring(left.subjectRef or '') < tostring(right.subjectRef or '')
        end)
        local degraded = scanDegraded('static') or scanDegraded('authority')
            or request.includePersistence ~= false and scanDegraded('persistence')
            or scanDegraded('outbox')
        local state = degraded and 'DEGRADED' or 'READY'
        local complete = staticComplete and authorityComplete
            and persistenceComplete and outboxComplete
        local retainedActionable = scanCycles.static.lastActionable == true
            or scanCycles.static.actionable == true
            or scanCycles.authority.lastActionable == true
            or scanCycles.authority.actionable == true
            or request.includePersistence ~= false and (
                scanCycles.persistence.lastActionable == true
                or scanCycles.persistence.actionable == true)
            or scanCycles.outbox.lastActionable == true
            or scanCycles.outbox.actionable == true
        lastReport = { status = state, items = items,
            hasMore = not complete or #items >= maximum,
            truncated = not complete or #items >= maximum,
            entityBindingsChecked = entityChecks,
            staticChecks = staticChecks,
            mapImpactsAnalyzed = impactAnalyses,
            authorityObjectsScanned = authorityScans,
            staticComplete = staticComplete,
            authorityComplete = authorityComplete,
            persistenceChecks = persistenceChecks,
            persistenceComplete = persistenceComplete,
            scanCoverage = {
                static = scanCycles.static.completed,
                authority = scanCycles.authority.completed,
                persistence = request.includePersistence == false
                    or scanCycles.persistence.completed,
                outbox = scanCycles.outbox.completed,
            },
            retainedActionable = retainedActionable,
            revision = revision, generatedAt = foundation.utc() }
        return Validation.copy(lastReport)
    end

    function diagnostics.health()
        local snapshot = foundation.healthSnapshot()
        local report = lastReport
        local status = snapshot.state
        if report and report.status == 'DEGRADED' and status == 'READY' then status = 'DEGRADED' end
        return { state = status, reasons = snapshot.reasons,
            revision = registry.currentRevision(), persistence = snapshot.persistence,
            service = snapshot.service, lastDoctor = report and {
                status = report.status, findings = #report.items,
                generatedAt = report.generatedAt,
            } or nil }
    end

    function diagnostics.lastDoctor() return Validation.copy(lastReport) end
    return diagnostics
end
