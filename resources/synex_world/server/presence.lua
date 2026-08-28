SynexWorldPresence = {}

function SynexWorldPresence.create(options)
    local now = assert(options.now, 'world presence requires monotonic time')
    local emit = options.emit or function() end
    local debounceMs = options.debounceMs or 500
    local minimumDwellMs = options.minimumDwellMs or 1000
    local records = {}
    local presence = {}

    local function identity(context, field)
        local value = context and context[field]
        return type(value) == 'table' and (value.key or value.instanceId) or nil
    end

    function presence.observe(source, session, context, traceContext)
        local currentTime = now()
        local record = records[source] or { stable = {}, pending = {}, enteredAt = {} }
        records[source] = record
        for _, field in ipairs({ 'location', 'room' }) do
            local candidate, stable = identity(context, field), record.stable[field]
            if candidate ~= stable then
                local pending = record.pending[field]
                if not pending or pending.value ~= candidate then
                    record.pending[field] = { value = candidate, since = currentTime }
                elseif currentTime - pending.since >= debounceMs
                    and (stable == nil or currentTime - (record.enteredAt[field] or 0) >= minimumDwellMs) then
                    if stable then emit(('synex.world.%s.left'):format(field), {
                        source = source, characterId = session.characterId,
                        ref = stable, authority = 'VERIFIED' }, traceContext) end
                    record.stable[field] = candidate
                    record.pending[field] = nil
                    if candidate then
                        record.enteredAt[field] = currentTime
                        emit(('synex.world.%s.entered'):format(field), {
                            source = source, characterId = session.characterId,
                            ref = candidate, authority = 'VERIFIED' }, traceContext)
                    end
                end
            else
                record.pending[field] = nil
            end
        end
        return record.stable
    end

    function presence.remove(source) records[source] = nil end
    function presence.count()
        local count = 0; for _ in pairs(records) do count = count + 1 end; return count
    end
    return presence
end
