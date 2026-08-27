local IdentityStore = {}

local PROVIDERS = { qb = true, qbx = true, esx = true }
local IDENTIFIER_TYPES = {
    qb = { citizenid = true },
    qbx = { citizenid = true },
    esx = { identifier = true },
}
local MAXIMUM_METADATA_ROWS = 64
local MAXIMUM_METADATA_BYTES = 262144

local function failure(code, message, retryable, details)
    local result = {
        code = code,
        message = message,
        retryable = retryable == true,
    }
    if details ~= nil then result.details = details end
    return result
end

local function callable(value)
    if type(value) == 'function' then return true end
    if type(value) ~= 'table' and type(value) ~= 'userdata' then return false end
    local metadata = getmetatable(value)
    if type(metadata) ~= 'table' and type(debug) == 'table'
        and type(debug.getmetatable) == 'function' then
        local readable, rawMetadata = pcall(debug.getmetatable, value)
        if readable then metadata = rawMetadata end
    end
    return type(metadata) == 'table' and type(rawget(metadata, '__call')) == 'function'
end

local function token(value, minimum, maximum, pattern)
    return type(value) == 'string' and #value >= minimum and #value <= maximum
        and value:find('[%z\1-\31\127]') == nil
        and (pattern == nil or value:match(pattern) ~= nil)
end

local function validProvider(provider, identifierType)
    return PROVIDERS[provider] == true
        and type(identifierType) == 'string'
        and IDENTIFIER_TYPES[provider][identifierType] == true
end

local function validCharacterId(value)
    return token(value, 8, 48, '^[A-Za-z0-9][A-Za-z0-9_.:%-]*$')
end

local function normalize(value, operationError)
    if value == false and type(operationError) == 'table' then return nil, operationError end
    return value, operationError
end

local function hash64(value)
    local left, right = 2166136261, 2246822519
    for index = 1, #value do
        local byte = value:byte(index)
        left = ((left ~ byte) * 16777619) & 0xffffffff
        right = ((right ~ (byte + index)) * 3266489917) & 0xffffffff
    end
    return ('%08x%08x'):format(left, right)
end

local function generatedIdentifier(provider, characterId)
    local digest = hash64(('synex:compatibility:%s:%s'):format(provider, characterId))
    if provider == 'esx' then return 'synex:' .. digest end
    return 'SX' .. digest:upper()
end

function IdentityStore.create(options)
    assert(type(options) == 'table', 'bridge identity store options are required')
    assert(callable(options.getApi), 'bridge identity store requires a Core API resolver')
    local getApi = options.getApi
    local jsonDecode = options.jsonDecode
    local jsonEncode = options.jsonEncode
    assert(callable(jsonDecode) and callable(jsonEncode),
        'bridge identity store requires JSON codecs')

    local store = {}

    local function database()
        local api, apiError = getApi()
        if not api then return nil, apiError end
        if type(api.Database) ~= 'table' or not callable(api.Database.read)
            or not callable(api.Database.write)
            or not callable(api.Database.transaction) then
            return nil, failure('COMPAT_DATABASE_UNAVAILABLE',
                'Compatibility persistence is unavailable.', true)
        end
        return api.Database, nil
    end

    local function readIdentity(provider, identifierType, characterId)
        local dataPort, portError = database()
        if not dataPort then return nil, portError end
        local rows, readError = normalize(dataPort.read({
            sql = [[SELECT `legacy_identifier`, `import_source`
                FROM `synex_compatibility_identities`
                WHERE `provider` = ? AND `identifier_type` = ?
                    AND `synex_character_id` = ?
                ORDER BY `id` ASC LIMIT 2]],
            parameters = { provider, identifierType, characterId },
            maximumRows = 2,
            maximumResultBytes = 4096,
            timeoutMs = 5000,
        }))
        if not rows then return nil, readError end
        if type(rows) ~= 'table' or #rows > 1 then
            return nil, failure('COMPAT_IDENTITY_AMBIGUOUS',
                'The compatibility identity mapping is ambiguous.')
        end
        if #rows == 0 then return false, nil end
        local row = rows[1]
        if type(row) ~= 'table' or not token(row.legacy_identifier, 1, 191) then
            return nil, failure('COMPAT_IDENTITY_INVALID',
                'The compatibility identity mapping is invalid.', true)
        end
        return {
            provider = provider,
            identifierType = identifierType,
            identifier = row.legacy_identifier,
            characterId = characterId,
            importSource = type(row.import_source) == 'string' and row.import_source or nil,
        }, nil
    end

    function store:resolve(provider, identifierType, characterId)
        if not validProvider(provider, identifierType) or not validCharacterId(characterId) then
            return nil, failure('COMPAT_VALIDATION_FAILED',
                'Compatibility identity lookup is invalid.')
        end
        local current, readError = readIdentity(provider, identifierType, characterId)
        if current then return current, nil end
        if current == nil then return nil, readError end

        local dataPort, portError = database()
        if not dataPort then return nil, portError end
        local identifier = generatedIdentifier(provider, characterId)
        local written, writeError = normalize(dataPort.write({
            sql = [[INSERT IGNORE INTO `synex_compatibility_identities`
                (`provider`, `identifier_type`, `legacy_identifier`,
                 `synex_character_id`, `import_source`)
                VALUES (?, ?, ?, ?, 'runtime_generated')]],
            parameters = { provider, identifierType, identifier, characterId },
            timeoutMs = 5000,
        }))
        if not written then return nil, writeError end
        local resolved, resolveError = readIdentity(provider, identifierType, characterId)
        if resolved then return resolved, nil end
        if resolved == false then
            return nil, failure('COMPAT_IDENTITY_COLLISION',
                'A stable compatibility identity could not be allocated.')
        end
        return nil, resolveError
    end

    function store:findByLegacy(provider, identifierType, legacyIdentifier)
        if not validProvider(provider, identifierType)
            or not token(legacyIdentifier, 1, 191) then
            return nil, failure('COMPAT_VALIDATION_FAILED',
                'Compatibility reverse identity lookup is invalid.')
        end
        local dataPort, portError = database()
        if not dataPort then return nil, portError end
        local rows, readError = normalize(dataPort.read({
            sql = [[SELECT `synex_character_id`, `import_source`
                FROM `synex_compatibility_identities`
                WHERE `provider` = ? AND `identifier_type` = ?
                    AND `legacy_identifier` = ?
                ORDER BY `id` ASC LIMIT 2]],
            parameters = { provider, identifierType, legacyIdentifier },
            maximumRows = 2,
            maximumResultBytes = 4096,
            timeoutMs = 5000,
        }))
        if not rows then return nil, readError end
        if type(rows) ~= 'table' or #rows > 1 then
            return nil, failure('COMPAT_IDENTITY_AMBIGUOUS',
                'The compatibility identity mapping is ambiguous.')
        end
        if #rows == 0 then return false, nil end
        local row = rows[1]
        if type(row) ~= 'table' or not validCharacterId(row.synex_character_id) then
            return nil, failure('COMPAT_IDENTITY_INVALID',
                'The compatibility identity mapping is invalid.', true)
        end
        return {
            provider = provider,
            identifierType = identifierType,
            identifier = legacyIdentifier,
            characterId = row.synex_character_id,
            importSource = type(row.import_source) == 'string' and row.import_source or nil,
        }, nil
    end

    function store:listMetadata(provider, characterId)
        if not PROVIDERS[provider] or not validCharacterId(characterId) then
            return nil, failure('COMPAT_VALIDATION_FAILED',
                'Compatibility metadata lookup is invalid.')
        end
        local dataPort, portError = database()
        if not dataPort then return nil, portError end
        local rows, readError = normalize(dataPort.read({
            sql = [[SELECT `metadata_key`, `value_json`, `version`
                FROM `synex_compatibility_metadata`
                WHERE `provider` = ? AND `synex_character_id` = ?
                ORDER BY `metadata_key` ASC LIMIT 65]],
            parameters = { provider, characterId },
            maximumRows = MAXIMUM_METADATA_ROWS + 1,
            maximumResultBytes = MAXIMUM_METADATA_BYTES,
            timeoutMs = 5000,
        }))
        if not rows then return nil, readError end
        if type(rows) ~= 'table' or #rows > MAXIMUM_METADATA_ROWS then
            return nil, failure('COMPAT_METADATA_TRUNCATED',
                'Compatibility metadata exceeds its bounded projection.')
        end
        local values, versions = {}, {}
        for _, row in ipairs(rows) do
            local key = type(row) == 'table' and row.metadata_key or nil
            local version = type(row) == 'table' and tonumber(row.version) or nil
            if not token(key, 2, 64, '^[a-z][a-z0-9_.:%-]*$')
                or type(row.value_json) ~= 'string' or #row.value_json > 4096
                or not version or math.type(version) ~= 'integer' or version < 1 then
                return nil, failure('COMPAT_METADATA_INVALID',
                    'Compatibility metadata contains an invalid record.', true)
            end
            local decoded, value = pcall(jsonDecode, row.value_json)
            if not decoded then
                return nil, failure('COMPAT_METADATA_INVALID',
                    'Compatibility metadata contains invalid JSON.', true)
            end
            values[key] = value
            versions[key] = version
        end
        return { values = values, versions = versions }, nil
    end

    function store:setMetadata(provider, characterId, key, value, expectedVersion)
        if not PROVIDERS[provider] or not validCharacterId(characterId)
            or not token(key, 2, 64, '^[a-z][a-z0-9_.:%-]*$')
            or expectedVersion ~= nil and (type(expectedVersion) ~= 'number'
                or math.type(expectedVersion) ~= 'integer' or expectedVersion < 1) then
            return nil, failure('COMPAT_VALIDATION_FAILED',
                'Compatibility metadata mutation is invalid.')
        end
        local encoded, valueJson = pcall(jsonEncode, value)
        if not encoded or type(valueJson) ~= 'string' or #valueJson > 4096 then
            return nil, failure('COMPAT_METADATA_INVALID',
                'Compatibility metadata must be bounded JSON.')
        end
        local dataPort, portError = database()
        if not dataPort then return nil, portError end
        local response, transactionError = normalize(dataPort.transaction({
            operation = 'compatibility.metadata.set',
            request = {
                provider = provider,
                characterId = characterId,
                key = key,
                expectedVersion = expectedVersion,
            },
            timeoutMs = 5000,
            maximumRows = 2,
            maximumResultBytes = 8192,
            maximumRequestBytes = 8192,
            maximumResponseBytes = 8192,
            maximumStatements = 3,
        }, function(tx)
            local current = tx.one([[SELECT `version`
                FROM `synex_compatibility_metadata`
                WHERE `provider` = ? AND `synex_character_id` = ?
                    AND `metadata_key` = ? FOR UPDATE]],
                { provider, characterId, key })
            if current == nil then
                if expectedVersion ~= nil then
                    return nil, failure('COMPAT_WRITE_CONFLICT',
                        'Compatibility metadata changed concurrently.', true)
                end
                local inserted = tx.affected([[INSERT INTO `synex_compatibility_metadata`
                    (`provider`, `synex_character_id`, `metadata_key`, `value_json`, `version`)
                    VALUES (?, ?, ?, ?, 1)]],
                    { provider, characterId, key, valueJson })
                if inserted ~= 1 then
                    return nil, failure('COMPAT_WRITE_CONFLICT',
                        'Compatibility metadata changed concurrently.', true)
                end
                return { version = 1 }, nil
            end
            local version = tonumber(current.version)
            if not version or math.type(version) ~= 'integer' or version < 1 then
                return nil, failure('COMPAT_METADATA_INVALID',
                    'Compatibility metadata contains an invalid revision.', true)
            end
            if expectedVersion ~= nil and version ~= expectedVersion then
                return nil, failure('COMPAT_WRITE_CONFLICT',
                    'Compatibility metadata changed concurrently.', true)
            end
            local updated = tx.affected([[UPDATE `synex_compatibility_metadata`
                SET `value_json` = ?, `version` = `version` + 1
                WHERE `provider` = ? AND `synex_character_id` = ?
                    AND `metadata_key` = ? AND `version` = ?]],
                { valueJson, provider, characterId, key, version })
            if updated ~= 1 then
                return nil, failure('COMPAT_WRITE_CONFLICT',
                    'Compatibility metadata changed concurrently.', true)
            end
            return { version = version + 1 }, nil
        end))
        if not response then return nil, transactionError end
        return response, nil
    end

    function store:deleteCharacter(planId, characterId)
        if not token(planId, 8, 64, '^[A-Za-z0-9_.:%-]+$')
            or not validCharacterId(characterId) then
            return nil, failure('COMPAT_DELETE_PLAN_INVALID',
                'Compatibility deletion plan is invalid.')
        end
        local dataPort, portError = database()
        if not dataPort then return nil, portError end
        return normalize(dataPort.transaction({
            operation = 'compatibility.character.delete',
            idempotencyKey = 'compatibility-delete:' .. planId,
            request = { planId = planId, characterId = characterId },
            timeoutMs = 5000,
            maximumRows = 0,
            maximumResultBytes = 4096,
            maximumRequestBytes = 4096,
            maximumResponseBytes = 4096,
            maximumStatements = 2,
        }, function(tx)
            local metadata = tx.affected([[DELETE FROM `synex_compatibility_metadata`
                WHERE `synex_character_id` = ?]], { characterId })
            local identities = tx.affected([[DELETE FROM `synex_compatibility_identities`
                WHERE `synex_character_id` = ?]], { characterId })
            return {
                metadataDeleted = metadata,
                identitiesDeleted = identities,
            }, nil
        end))
    end

    return store
end

SynexBridgeIdentityStore = IdentityStore

return IdentityStore
