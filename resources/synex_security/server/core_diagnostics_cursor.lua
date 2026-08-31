SynexSecurityCoreDiagnosticsCursor = {}

local Limits = assert(SynexSecurityLimits, 'security limits must be loaded first')
local Validation = assert(SynexSecurityValidation,
    'security validation must be loaded first')
local Cursor = SynexSecurityCoreDiagnosticsCursor

local CHECKPOINT_VERSION = 'v1'
local MAXIMUM_STREAM_BYTES = 36
local MAXIMUM_PAGES = 42
local PAGE_LIMIT = 50

function Cursor.create(options)
    options = options or {}
    local getCheckpoint = assert(options.getCheckpoint,
        'core diagnostic checkpoint reader is required')
    local setCheckpoint = assert(options.setCheckpoint,
        'core diagnostic checkpoint writer is required')
    local deleteCheckpoint = assert(options.deleteCheckpoint,
        'core diagnostic checkpoint delete is required')
    assert(Validation.isCallable(getCheckpoint)
        and Validation.isCallable(setCheckpoint)
        and Validation.isCallable(deleteCheckpoint),
        'core diagnostic checkpoint port is invalid')
    local onGap = Validation.isCallable(options.onGap) and options.onGap or nil
    local streamId, lastId = nil, nil
    local api = {}

    local function failure(message)
        return Validation.failure('SECURITY_CORE_SIGNAL_UNAVAILABLE', message, true)
    end

    local function validStream(value)
        return Validation.token(value, 8, MAXIMUM_STREAM_BYTES)
    end

    local function checkpointValue(stream, id)
        return ('%s|%s|%d'):format(CHECKPOINT_VERSION, stream, id)
    end

    local function parseCheckpoint(value)
        if value == nil or value == '' then return nil, 0, false end
        if type(value) ~= 'string' or #value > 80 then return nil, 0, true end
        local version, stream, idText = value:match('^([^|]+)|([^|]+)|(%d+)$')
        local id = tonumber(idText)
        if version ~= CHECKPOINT_VERSION or not validStream(stream)
            or not Validation.isInteger(id, 0, Limits.maximumSafeInteger) then
            return nil, 0, true
        end
        return stream, id, false
    end

    local function readCheckpoint()
        local ok, value = pcall(getCheckpoint)
        if not ok then return failure('Core diagnostic checkpoint could not be read.') end
        local storedStream, storedId, corrupt = parseCheckpoint(value)
        if corrupt then
            local deleted, deleteResult = pcall(deleteCheckpoint)
            if not deleted or deleteResult == false then
                return failure('Invalid Core diagnostic checkpoint could not be removed.')
            end
            if onGap ~= nil then pcall(onGap, 'CHECKPOINT_INVALID', {
                checkpoint = 'discarded',
            }) end
        end
        return { streamId = storedStream, lastId = storedId }, nil
    end

    local function persist(stream, id)
        local ok, result = pcall(setCheckpoint, checkpointValue(stream, id))
        if not ok or result == false then
            return failure('Core diagnostic checkpoint could not be persisted.')
        end
        streamId, lastId = stream, id
        return true, nil
    end

    local function validatePage(page, expectedStream, previousId)
        if type(page) ~= 'table' or page.status ~= 'AVAILABLE'
            or not validStream(page.streamId)
            or expectedStream ~= nil and page.streamId ~= expectedStream
            or type(page.items) ~= 'table'
            or Validation.arrayLength(page.items, PAGE_LIMIT) == nil
            or not Validation.isInteger(page.retained, 0, 2048)
            or not Validation.isInteger(page.dropped, 0,
                Limits.maximumSafeInteger) then
            return failure('Core returned an invalid security diagnostic page.')
        end
        if page.retained == 0 then
            if page.oldestId ~= nil or page.latestId ~= nil or #page.items ~= 0
                or page.hasMore == true then
                return failure('Core returned inconsistent empty diagnostic bounds.')
            end
        elseif not Validation.isInteger(page.oldestId, 1,
                Limits.maximumSafeInteger)
            or not Validation.isInteger(page.latestId, page.oldestId,
                Limits.maximumSafeInteger) then
            return failure('Core returned invalid security diagnostic bounds.')
        end
        local last = previousId
        for _, finding in ipairs(page.items) do
            if type(finding) ~= 'table'
                or not Validation.isInteger(finding.id, 1,
                    Limits.maximumSafeInteger)
                or page.retained > 0 and (finding.id < page.oldestId
                    or finding.id > page.latestId)
                or last ~= nil and finding.id >= last then
                return failure('Core diagnostic findings are not strictly ordered.')
            end
            last = finding.id
        end
        if page.hasMore == true then
            if #page.items == 0 or type(page.nextCursor) ~= 'string'
                or page.nextCursor ~= tostring(page.items[#page.items].id) then
                return failure('Core returned an invalid security diagnostic cursor.')
            end
        elseif page.nextCursor ~= nil then
            return failure('Core returned an unexpected terminal diagnostic cursor.')
        end
        return {
            streamId = page.streamId,
            oldestId = page.oldestId,
            latestId = page.latestId,
            lastPageId = last,
        }, nil
    end

    function api.drain(coreApi, emit)
        if type(coreApi) ~= 'table' or type(coreApi.Diagnostics) ~= 'table'
            or not Validation.isCallable(coreApi.Diagnostics.getSecurityFindings)
            or not Validation.isCallable(emit) then
            return failure('Core diagnostic API is unavailable.')
        end
        local checkpoint, checkpointError = readCheckpoint()
        if not checkpoint then return nil, checkpointError end
        local activeStream = streamId or checkpoint.streamId
        local acceptedId = lastId
        if acceptedId == nil then acceptedId = checkpoint.lastId end
        local requestCursor, pages, priorPageId = nil, 0, nil
        local findings, providerStream, oldestId, latestId = {}, nil, nil, nil
        local stop = false
        repeat
            local request = { limit = PAGE_LIMIT }
            if requestCursor ~= nil then request.cursor = requestCursor end
            local page, pageError = coreApi.Diagnostics.getSecurityFindings(request)
            if not page then return nil, pageError end
            pages = pages + 1
            local pageInfo, validationError = validatePage(
                page, providerStream, priorPageId)
            if not pageInfo then return nil, validationError end
            providerStream = pageInfo.streamId
            oldestId, latestId = pageInfo.oldestId, pageInfo.latestId
            priorPageId = pageInfo.lastPageId
            if activeStream ~= providerStream then
                activeStream, acceptedId = providerStream, 0
            elseif latestId ~= nil and acceptedId > latestId then
                if onGap ~= nil then pcall(onGap, 'CHECKPOINT_AHEAD', {
                    checkpoint = acceptedId, latest = latestId,
                }) end
                acceptedId = 0
            end
            for _, finding in ipairs(page.items) do
                if finding.id > acceptedId then
                    findings[#findings + 1] = finding
                else
                    stop = true
                end
            end
            requestCursor = page.nextCursor
            if page.hasMore ~= true or requestCursor == nil then stop = true end
        until stop or pages >= MAXIMUM_PAGES
        if not stop and pages >= MAXIMUM_PAGES then
            return failure('Core diagnostic pagination exceeded its bounded limit.')
        end
        if providerStream == nil then
            return failure('Core diagnostic stream identity is unavailable.')
        end
        if oldestId ~= nil and acceptedId < oldestId - 1 and onGap ~= nil then
            pcall(onGap, 'RETENTION_GAP', {
                checkpoint = acceptedId,
                oldest = oldestId,
                latest = latestId,
            })
        end
        table.sort(findings, function(left, right) return left.id < right.id end)
        local processed = 0
        for _, finding in ipairs(findings) do
            local emitted, emitError = emit(finding, providerStream)
            if not emitted then return nil, emitError end
            local saved, saveError = persist(providerStream, finding.id)
            if not saved then return nil, saveError end
            acceptedId, processed = finding.id, processed + 1
        end
        if lastId == nil or streamId ~= providerStream then
            local saved, saveError = persist(providerStream, acceptedId)
            if not saved then return nil, saveError end
        end
        return processed, nil
    end

    function api.resetMemory()
        streamId, lastId = nil, nil
        return true
    end

    function api.snapshot()
        return { streamId = streamId, lastId = lastId }
    end

    return api
end
