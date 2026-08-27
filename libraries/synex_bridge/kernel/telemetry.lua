assert(SynexBridgeKernel and SynexBridgeKernel.Foundation,
    'synex_bridge foundation must load before telemetry')

local Foundation = SynexBridgeKernel.Foundation
local Telemetry = {}

local DEFAULTS = {
    maximumOwners = 64,
    maximumSeries = 256,
    maximumSeriesPerOwner = 64,
    maximumWarningKeys = 256,
    timerModulus = 4294967296,
}

local function defaultClock()
    if type(GetGameTimer) == 'function' then return GetGameTimer() % DEFAULTS.timerModulus end
    return math.floor(os.clock() * 1000) % DEFAULTS.timerModulus
end

local function validateEpoch(value)
    return Foundation.isSafeInteger(value, 0, Foundation.MAX_SAFE_INTEGER)
        or Foundation.isBoundedString(value, 1, 64, '^[A-Za-z0-9_.:%-]+$')
end

local function readCallable(callable, errorCode)
    local succeeded, value = pcall(callable)
    if not succeeded then return nil, Foundation.error(errorCode or 'COMPAT_INTERNAL') end
    return value, nil
end

function Telemetry.create(options)
    if options ~= nil and type(options) ~= 'table' then
        error('compatibility telemetry options are invalid')
    end
    options = options or {}
    local limits = {}
    for key, default in pairs(DEFAULTS) do
        local value = options[key]
        local maximum = key == 'timerModulus' and Foundation.MAX_SAFE_INTEGER or 4096
        if value ~= nil and not Foundation.isSafeInteger(value, 1, maximum) then
            error('compatibility telemetry limits are invalid')
        end
        limits[key] = value or default
    end
    if limits.maximumSeriesPerOwner > limits.maximumSeries
        or limits.maximumOwners > limits.maximumSeries then
        error('compatibility telemetry limits are inconsistent')
    end
    local clock = options.clock or function() return defaultClock() % limits.timerModulus end
    local clockEpoch = options.clockEpoch or function() return 'kernel' end
    local warningSink = options.warningSink
    if not Foundation.isCallable(clock) or not Foundation.isCallable(clockEpoch)
        or (warningSink ~= nil and not Foundation.isCallable(warningSink)) then
        error('compatibility telemetry callbacks are invalid')
    end

    local owners = {}
    local ownerCount, seriesCount, warningCount = 0, 0, 0
    local truncated = false

    local function getOwner(owner, create)
        local state = owners[owner]
        if state or not create then return state, nil end
        if ownerCount >= limits.maximumOwners then
            truncated = true
            return nil, Foundation.error('COMPAT_REGISTRY_LIMIT')
        end
        state = { series = {}, warnings = {}, seriesCount = 0, warningCount = 0 }
        owners[owner] = state
        ownerCount = ownerCount + 1
        return state, nil
    end

    local function validateCoordinates(owner, epoch, surface)
        return Foundation.isResourceName(owner)
            and Foundation.isSafeInteger(epoch, 1, Foundation.MAX_SAFE_INTEGER)
            and Foundation.isDefinitionName(surface)
    end

    local telemetry = {}

    function telemetry:start(owner, epoch, surface)
        if not validateCoordinates(owner, epoch, surface) then
            return nil, Foundation.error('COMPAT_INVALID_ARGUMENT')
        end
        local tick, tickError = readCallable(clock)
        local timerEpoch, epochError = readCallable(clockEpoch)
        if tickError or epochError or not Foundation.isSafeInteger(tick, 0, limits.timerModulus - 1)
            or not validateEpoch(timerEpoch) then
            return nil, tickError or epochError or Foundation.error('COMPAT_INTERNAL')
        end
        return {
            owner = owner, epoch = epoch, surface = surface,
            tick = tick, clockEpoch = timerEpoch,
        }, nil
    end

    function telemetry:record(owner, epoch, surface, outcome, latencyMs)
        if not validateCoordinates(owner, epoch, surface) or not Foundation.isOutcome(outcome)
            or not Foundation.isSafeInteger(latencyMs, 0, limits.timerModulus - 1) then
            return nil, Foundation.error('COMPAT_INVALID_ARGUMENT')
        end
        local ownerState = getOwner(owner, false)
        if not ownerState and seriesCount >= limits.maximumSeries then
            truncated = true
            return nil, Foundation.error('COMPAT_REGISTRY_LIMIT')
        end
        local ownerError
        if not ownerState then ownerState, ownerError = getOwner(owner, true) end
        if not ownerState then return nil, ownerError end
        local key = tostring(epoch) .. ':' .. surface
        local series = ownerState.series[key]
        if not series then
            if seriesCount >= limits.maximumSeries
                or ownerState.seriesCount >= limits.maximumSeriesPerOwner then
                truncated = true
                return nil, Foundation.error('COMPAT_REGISTRY_LIMIT')
            end
            series = {
                owner = owner, epoch = epoch, surface = surface, count = 0,
                latency = { totalMs = 0, maximumMs = 0 }, outcomes = {},
            }
            ownerState.series[key] = series
            ownerState.seriesCount = ownerState.seriesCount + 1
            seriesCount = seriesCount + 1
        end
        series.count = Foundation.saturatingAdd(series.count, 1)
        series.latency.totalMs = Foundation.saturatingAdd(series.latency.totalMs, latencyMs)
        series.latency.maximumMs = math.max(series.latency.maximumMs, latencyMs)
        series.outcomes[outcome] = Foundation.saturatingAdd(series.outcomes[outcome] or 0, 1)
        return true, nil
    end

    function telemetry:finish(token, outcome)
        local copied, tokenError = Foundation.copyClosedObject(token, {
            owner = true, epoch = true, surface = true, tick = true, clockEpoch = true,
        }, { 'owner', 'epoch', 'surface', 'tick', 'clockEpoch' }, {
            root = 'object', maximumEntries = 16, maximumBytes = 2048,
            maximumStringBytes = 256, maximumKeyBytes = 64,
        })
        if not copied or not Foundation.isOutcome(outcome)
            or not validateCoordinates(copied and copied.owner, copied and copied.epoch,
                copied and copied.surface)
            or not Foundation.isSafeInteger(copied and copied.tick, 0, limits.timerModulus - 1)
            or not validateEpoch(copied and copied.clockEpoch) then
            return nil, tokenError or Foundation.error('COMPAT_INVALID_ARGUMENT')
        end
        local now, tickError = readCallable(clock)
        local currentEpoch, epochError = readCallable(clockEpoch)
        if tickError or epochError or not Foundation.isSafeInteger(now, 0, limits.timerModulus - 1)
            or not validateEpoch(currentEpoch) then
            return nil, tickError or epochError or Foundation.error('COMPAT_INTERNAL')
        end
        if currentEpoch ~= copied.clockEpoch then
            return nil, Foundation.error('COMPAT_STALE_SESSION')
        end
        local elapsed = now >= copied.tick and (now - copied.tick)
            or (limits.timerModulus - copied.tick + now)
        local recorded, recordError = telemetry:record(
            copied.owner, copied.epoch, copied.surface, outcome, elapsed
        )
        if not recorded then return nil, recordError end
        return elapsed, nil
    end

    function telemetry:warnOnce(owner, epoch, key, errorCode, context)
        if not Foundation.isResourceName(owner)
            or not Foundation.isSafeInteger(epoch, 1, Foundation.MAX_SAFE_INTEGER)
            or not Foundation.isIdentifier(key) then
            return nil, Foundation.error('COMPAT_INVALID_ARGUMENT')
        end
        local compatError = Foundation.error(errorCode)
        if compatError.code == 'COMPAT_INTERNAL' and errorCode ~= 'COMPAT_INTERNAL' then
            return nil, Foundation.error('COMPAT_INVALID_ARGUMENT')
        end
        local copiedContext = nil
        if context ~= nil then
            local contextError
            copiedContext, contextError = Foundation.copyDto(context, {
                root = 'object', maximumEntries = 64, maximumBytes = 8192,
                maximumStringBytes = 1024, maximumKeyBytes = 64,
            })
            if not copiedContext then return nil, contextError end
        end
        local ownerState = getOwner(owner, false)
        if not ownerState and warningCount >= limits.maximumWarningKeys then
            truncated = true
            return nil, Foundation.error('COMPAT_REGISTRY_LIMIT')
        end
        local ownerError
        if not ownerState then ownerState, ownerError = getOwner(owner, true) end
        if not ownerState then return nil, ownerError end
        local warningKey = tostring(epoch) .. ':' .. key
        if ownerState.warnings[warningKey] then return false, nil end
        if warningCount >= limits.maximumWarningKeys then
            truncated = true
            return nil, Foundation.error('COMPAT_REGISTRY_LIMIT')
        end
        ownerState.warnings[warningKey] = true
        ownerState.warningCount = ownerState.warningCount + 1
        warningCount = warningCount + 1
        if warningSink then
            pcall(warningSink, {
                owner = owner, epoch = epoch, key = key,
                error = compatError, context = copiedContext,
            })
        end
        return true, nil
    end

    function telemetry:snapshot(owner, epoch)
        if owner ~= nil and not Foundation.isResourceName(owner) then
            return nil, Foundation.error('COMPAT_INVALID_ARGUMENT')
        end
        if epoch ~= nil and not Foundation.isSafeInteger(epoch, 1, Foundation.MAX_SAFE_INTEGER) then
            return nil, Foundation.error('COMPAT_INVALID_ARGUMENT')
        end
        local items = {}
        for resource, ownerState in pairs(owners) do
            if owner == nil or resource == owner then
                for _, series in pairs(ownerState.series) do
                    if epoch == nil or series.epoch == epoch then
                        items[#items + 1] = Foundation.copyDto(series)
                    end
                end
            end
        end
        table.sort(items, function(left, right)
            if left.owner ~= right.owner then return left.owner < right.owner end
            if left.epoch ~= right.epoch then return left.epoch < right.epoch end
            return left.surface < right.surface
        end)
        return { count = #items, series = items, truncated = truncated }, nil
    end

    function telemetry:cleanup(owner, epoch)
        if not Foundation.isResourceName(owner)
            or not Foundation.isSafeInteger(epoch, 1, Foundation.MAX_SAFE_INTEGER) then
            return nil, Foundation.error('COMPAT_INVALID_ARGUMENT')
        end
        local ownerState = owners[owner]
        if not ownerState then return 0, nil end
        local removed = 0
        local prefix = tostring(epoch) .. ':'
        for key in pairs(ownerState.series) do
            if key:sub(1, #prefix) == prefix then
                ownerState.series[key] = nil
                ownerState.seriesCount = ownerState.seriesCount - 1
                seriesCount = seriesCount - 1
                removed = removed + 1
            end
        end
        for key in pairs(ownerState.warnings) do
            if key:sub(1, #prefix) == prefix then
                ownerState.warnings[key] = nil
                ownerState.warningCount = ownerState.warningCount - 1
                warningCount = warningCount - 1
                removed = removed + 1
            end
        end
        if ownerState.seriesCount == 0 and ownerState.warningCount == 0 then
            owners[owner] = nil
            ownerCount = ownerCount - 1
        end
        return removed, nil
    end

    return telemetry
end

SynexBridgeKernel.Telemetry = Telemetry
