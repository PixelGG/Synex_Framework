SynexInteractCompatibility = {}

local Limits = assert(SynexInteractLimits, 'interact limits must be loaded first')
local Validation = assert(SynexInteractValidation, 'interact validation must be loaded first')

local SYSTEMS = { ox_target = true, ['qb-target'] = true, qtarget = true }

local function failure(code, message)
    return Validation.failure(code, message, false)
end

local function stringArray(value, maximum, validator)
    if value == nil then return {} end
    local normalized = Validation.array(value, maximum, validator)
    if not normalized then return nil end
    local seen = {}
    for _, item in ipairs(normalized) do
        local key = tostring(item)
        if seen[key] then return nil end
        seen[key] = true
    end
    return Validation.copy(normalized)
end

local function normalizeSelector(value)
    if not Validation.exactObject(value, { 'kind' }, {
        'models', 'bones', 'distance', 'worldAnchor',
    }) or value.kind ~= 'model' and value.kind ~= 'entity'
        and value.kind ~= 'world' then
        return failure('COMPAT_INVALID_ARGUMENT',
            'The legacy target selector is invalid.')
    end
    local models = stringArray(value.models, 32, function(model)
        return Validation.isInteger(model, 0, 4294967295)
    end)
    local bones = stringArray(value.bones, 16, function(bone)
        return Validation.text(bone, 1, 64)
    end)
    if not models or not bones
        or value.distance ~= nil and (not Validation.isFinite(value.distance)
            or value.distance < 0.25 or value.distance > Limits.maximumAuthorityDistance)
        or value.kind == 'world' and not Validation.identifier(value.worldAnchor) then
        return failure('COMPAT_INVALID_ARGUMENT',
            'The legacy target selector bounds are invalid.')
    end
    return { kind = value.kind, models = models, bones = bones,
        distance = value.distance, worldAnchor = value.worldAnchor }, nil
end

local function hintMap(value, maximum)
    if value == nil then return {} end
    if not Validation.isPlainTable(value) then return nil end
    local count, result = 0, {}
    for key, requirement in pairs(value) do
        count = count + 1
        if count > maximum or not Validation.semanticKey(key, 64)
            or type(requirement) ~= 'boolean' and not Validation.isInteger(requirement, 0, 1000) then
            return nil
        end
        result[key] = requirement
    end
    return result
end

local function normalizeOption(consumer, value)
    if not Validation.exactObject(value, { 'name', 'label' }, {
        'icon', 'distance', 'bones', 'groups', 'items', 'actionAdapter', 'actionRequest',
    }) or not Validation.semanticKey(value.name, 64)
        or not Validation.text(value.label, 1, 96)
        or value.icon ~= nil and not Validation.token(value.icon, 1, 64)
        or value.distance ~= nil and (not Validation.isFinite(value.distance)
            or value.distance < 0.25 or value.distance > Limits.maximumAuthorityDistance) then
        return failure('COMPAT_INVALID_ARGUMENT',
            'A legacy interaction option is invalid.')
    end
    local bones = stringArray(value.bones, 16,
        function(bone) return Validation.text(bone, 1, 64) end)
    local groups, items = hintMap(value.groups, 32), hintMap(value.items, 32)
    if not bones or not groups or not items then
        return failure('COMPAT_INVALID_ARGUMENT',
            'Legacy visibility hints exceed their bounds.')
    end
    if value.actionAdapter ~= nil then
        if not Validation.identifier(value.actionAdapter)
            or value.actionAdapter:sub(1, #consumer + 1) ~= consumer .. ':' then
            return failure('COMPAT_CONSUMER_DENIED',
                'Compatibility actions must use a consumer-owned typed adapter.')
        end
    elseif value.actionRequest ~= nil then
        return failure('COMPAT_INVALID_ARGUMENT',
            'A compatibility action request requires a typed adapter.')
    end
    return {
        name = value.name, label = value.label, icon = value.icon,
        discovery = { distance = value.distance, bones = bones },
        visibilityHints = { groups = groups, items = items,
            authority = 'observed-only' },
        action = value.actionAdapter and { adapter = value.actionAdapter,
            request = Validation.copy(value.actionRequest or {}) } or nil,
    }, nil
end

function SynexInteractCompatibility.create()
    local compatibility = {}
    function compatibility.normalize(context, payload)
        local consumer = type(context) == 'table' and context.consumer or nil
        if not Validation.resourceName(consumer)
            or not Validation.exactObject(payload, { 'system', 'selector', 'options' })
            or not SYSTEMS[payload.system] then
            return failure('COMPAT_INVALID_ARGUMENT',
                'The interaction compatibility request is invalid.')
        end
        local selector, selectorError = normalizeSelector(payload.selector)
        if not selector then return nil, selectorError end
        local rawOptions = Validation.array(payload.options, Limits.maximumVisibleIntents)
        if not rawOptions or #rawOptions == 0 then
            return failure('COMPAT_INVALID_ARGUMENT',
                'Compatibility registrations require one bounded option set.')
        end
        local options = {}
        for index, raw in ipairs(rawOptions) do
            local normalized, optionError = normalizeOption(consumer, raw)
            if not normalized then return nil, optionError end
            options[index] = normalized
        end
        return {
            schemaVersion = 1, sourceSystem = payload.system,
            status = 'PARTIAL', selector = selector, options = options,
            authority = 'server-revalidation-required',
            unsupported = { 'arbitrary_event', 'onSelect', 'canInteract_authority' },
        }, nil
    end
    function compatibility.definition()
        return { name = 'synex.interact', version = '1.0.0', provider = 'all',
            domain = 'interaction', status = 'PARTIAL', operations = { 'normalize' } }
    end
    function compatibility.implementation()
        return { normalize = compatibility.normalize }
    end
    return compatibility
end
