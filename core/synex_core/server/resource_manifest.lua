local factories = assert(SynexCoreFactories, 'factories must be loaded first')

factories.resourceManifest = function(deps)
    local foundation = assert(deps.foundation, 'resource manifest validation requires foundation')

    local function invalid(path, message)
        return nil, foundation.error('INVALID_RESOURCE_MANIFEST', message, { details = { path = path } })
    end

    local function exactObject(value, path, required, optional)
        if type(value) ~= 'table' then return invalid(path, 'Value must be an object.') end
        local allowed = {}
        for _, key in ipairs(required) do
            allowed[key] = true
            if value[key] == nil then return invalid(path .. '.' .. key, 'Required value is missing.') end
        end
        for _, key in ipairs(optional or {}) do allowed[key] = true end
        for key in pairs(value) do
            if type(key) ~= 'string' or not allowed[key] then
                return invalid(path .. '.' .. tostring(key), 'Unknown value is not allowed.')
            end
        end
        return true, nil
    end

    local function validSemver(value)
        return type(value) == 'string' and #value <= 96 and foundation.semver(value) ~= nil
    end

    local function validRange(value)
        if type(value) ~= 'string' or #value < 5 or #value > 96 then return false end
        local count = 0
        for token in value:gmatch('%S+') do
            count = count + 1
            local operator, version = token:match('^([%^~<>=]*)(%d+%.%d+%.%d+)$')
            if not version or (operator ~= '' and operator ~= '^' and operator ~= '~'
                and operator ~= '>' and operator ~= '<' and operator ~= '>=' and operator ~= '<=' and operator ~= '=')
                or not validSemver(version) then return false end
        end
        return count > 0
    end

    local function validCapability(value)
        return type(value) == 'string' and #value <= 128
            and value:match('^[a-z][a-z0-9%._%-]*$') ~= nil
            and value:match('[%._%-]$') == nil
            and value:match('[%._%-][%._%-]') == nil
    end

    local function validService(value)
        if type(value) ~= 'string' or #value > 128 then return false end
        local name, major = value:match('^(synex%.[a-z][a-z0-9%._%-]*)@([1-9]%d*)$')
        return name ~= nil and major ~= nil
            and name:match('[%._%-]$') == nil
            and name:match('[%._%-][%._%-]') == nil
    end

    local function validEventPattern(value)
        if type(value) ~= 'string' or #value < 3 or #value > 128
            or value:find('[%z\1-\31\127]') then return false end
        local base = value
        if value:sub(-2) == '.*' then base = value:sub(1, -3) end
        if base:find('*', 1, true) or base:sub(-1) == '.' or base:find('..', 1, true)
            or not base:match('^[a-z][a-z0-9_]*%.[a-z][a-z0-9_.]*$') then return false end
        for segment in base:gmatch('[^.]+') do
            if not segment:match('^[a-z][a-z0-9_]*$') then return false end
        end
        return true
    end

    local function validateArray(value, path, validator, identity, maximum)
        if type(value) ~= 'table' then return invalid(path, 'Value must be an array.') end
        local count = 0
        local largestIndex = 0
        local seen = {}
        for key, item in pairs(value) do
            count = count + 1
            if type(key) ~= 'number' or math.type(key) ~= 'integer' or key < 1 then
                return invalid(path, 'Array must be dense and one-indexed.')
            end
            largestIndex = math.max(largestIndex, key)
            if count > (maximum or 512) then return invalid(path, 'Array exceeds its supported item limit.') end
            if not validator(item) then return invalid(('%s[%s]'):format(path, tostring(key)), 'Array item is invalid.') end
            local unique = identity and identity(item) or tostring(item)
            if seen[unique] then return invalid(('%s[%s]'):format(path, tostring(key)), 'Array item is duplicated.') end
            seen[unique] = true
        end
        if count ~= largestIndex or count ~= #value then return invalid(path, 'Array must be dense and contiguous.') end
        return true, nil
    end

    local validator = {}

    function validator:validateDependencyVersion(dependency, actualVersion, duplicateVersion)
        if type(dependency) ~= 'table' or type(dependency.name) ~= 'string'
            or type(dependency.version) ~= 'string' then
            return nil, foundation.error('DEPENDENCY_DECLARATION_INVALID',
                'Dependency version validation requires a validated dependency declaration.')
        end
        local details = {
            dependency = dependency.name,
            requiredRange = dependency.version,
            actualVersion = type(actualVersion) == 'string' and actualVersion or nil
        }
        if duplicateVersion ~= nil then
            return nil, foundation.error('DEPENDENCY_VERSION_METADATA_AMBIGUOUS',
                'Dependency version metadata must be declared exactly once.', { details = details })
        end
        if type(actualVersion) ~= 'string' or actualVersion == '' then
            return nil, foundation.error('DEPENDENCY_VERSION_METADATA_MISSING',
                'Dependency version metadata is missing.', { details = details })
        end
        if not validSemver(actualVersion) then
            return nil, foundation.error('DEPENDENCY_VERSION_METADATA_INVALID',
                'Dependency version metadata is not canonical semantic versioning.', { details = details })
        end
        if not foundation.semverSatisfies(actualVersion, dependency.version) then
            return nil, foundation.error('DEPENDENCY_VERSION_INCOMPATIBLE',
                'Dependency version does not satisfy the declared range.', { details = details })
        end
        return true, nil
    end

    function validator:validate(resourceName, manifest)
        local ok, err = exactObject(manifest, '$', {
            'schema', 'name', 'version', 'synex', 'critical', 'capabilities', 'services',
            'contracts', 'events', 'hooks', 'dependencies', 'migrations', 'dataOwnership', 'stateSnapshot'
        }, { '$schema' })
        if not ok then return nil, err end
        if manifest['$schema'] ~= nil and (type(manifest['$schema']) ~= 'string' or #manifest['$schema'] > 256) then
            return invalid('$.$schema', 'Schema reference must be a bounded string.')
        end
        if manifest.schema ~= 1 or manifest.name ~= resourceName or type(resourceName) ~= 'string'
            or #resourceName > 64 or not resourceName:match('^synex_[a-z0-9_]+$') then
            return invalid('$.name', 'Manifest schema or resource name is invalid.')
        end
        if not validSemver(manifest.version) then return invalid('$.version', 'Resource version must be semantic.') end
        if not validRange(manifest.synex) then return invalid('$.synex', 'Synex API range is invalid.') end
        if not foundation.semverSatisfies(SynexProtocol.api, manifest.synex) then
            return nil, foundation.error('SYNEX_VERSION_INCOMPATIBLE',
                'Resource manifest requires an incompatible Synex API version.', { details = { path = '$.synex' } })
        end
        if type(manifest.critical) ~= 'boolean' then return invalid('$.critical', 'Critical flag must be boolean.') end

        ok, err = exactObject(manifest.capabilities, '$.capabilities', { 'request' })
        if not ok then return nil, err end
        ok, err = validateArray(manifest.capabilities.request, '$.capabilities.request', validCapability)
        if not ok then return nil, err end

        ok, err = exactObject(manifest.services, '$.services', { 'provide', 'require', 'optional' })
        if not ok then return nil, err end
        for _, key in ipairs({ 'provide', 'require', 'optional' }) do
            ok, err = validateArray(manifest.services[key], '$.services.' .. key, validService)
            if not ok then return nil, err end
        end

        ok, err = exactObject(manifest.contracts, '$.contracts', { 'provide', 'consume' })
        if not ok then return nil, err end
        for _, key in ipairs({ 'provide', 'consume' }) do
            ok, err = validateArray(manifest.contracts[key], '$.contracts.' .. key, validCapability)
            if not ok then return nil, err end
        end

        ok, err = exactObject(manifest.events, '$.events', { 'publish', 'subscribe' })
        if not ok then return nil, err end
        for _, key in ipairs({ 'publish', 'subscribe' }) do
            ok, err = validateArray(manifest.events[key], '$.events.' .. key, validEventPattern, nil, 256)
            if not ok then return nil, err end
        end
        if resourceName ~= 'synex_core' then
            local ownedPrefix = 'synex.' .. resourceName:sub(7) .. '.'
            for index, pattern in ipairs(manifest.events.publish) do
                if pattern:sub(1, #ownedPrefix) ~= ownedPrefix then
                    return invalid(('$.events.publish[%d]'):format(index),
                        'Published event topics must stay within the resource-owned namespace.')
                end
            end
        end

        ok, err = exactObject(manifest.hooks, '$.hooks', { 'register', 'run' })
        if not ok then return nil, err end
        for _, key in ipairs({ 'register', 'run' }) do
            ok, err = validateArray(manifest.hooks[key], '$.hooks.' .. key, validEventPattern, nil, 256)
            if not ok then return nil, err end
        end
        if resourceName ~= 'synex_core' then
            local ownedPrefix = 'synex.' .. resourceName:sub(7) .. '.'
            for index, pattern in ipairs(manifest.hooks.run) do
                if pattern:sub(1, #ownedPrefix) ~= ownedPrefix then
                    return invalid(('$.hooks.run[%d]'):format(index),
                        'Executed hooks must stay within the resource-owned namespace.')
                end
            end
        end

        ok, err = exactObject(manifest.dependencies, '$.dependencies', { 'required', 'optional', 'development' })
        if not ok then return nil, err end
        local dependencyNames = {}
        local function validDependency(item)
            local valid = exactObject(item, '$.dependencies[]', { 'name', 'version' })
            return valid == true and type(item.name) == 'string' and #item.name <= 64
                and item.name:match('^[A-Za-z0-9_-]+$') ~= nil and validRange(item.version)
        end
        for _, key in ipairs({ 'required', 'optional', 'development' }) do
            ok, err = validateArray(manifest.dependencies[key], '$.dependencies.' .. key, validDependency,
                function(item) return item.name end)
            if not ok then return nil, err end
            for index, item in ipairs(manifest.dependencies[key]) do
                if dependencyNames[item.name] then
                    return invalid(('$.dependencies.%s[%d]'):format(key, index),
                        'Dependency name is duplicated across dependency classes.')
                end
                dependencyNames[item.name] = true
            end
        end

        local migrationIds = {}
        local migrationPaths = {}
        local function validMigration(item)
            local valid = exactObject(item, '$.migrations[]', { 'id', 'path', 'transactional' })
            return valid == true and type(item.id) == 'string' and #item.id <= 96
                and item.id:match('^%d%d%d_[a-z0-9_]+$') ~= nil
                and type(item.path) == 'string' and #item.path <= 240
                and item.path:match('^migrations/[A-Za-z0-9%._/-]+%.sql$') ~= nil
                and not item.path:find('..', 1, true) and type(item.transactional) == 'boolean'
        end
        ok, err = validateArray(manifest.migrations, '$.migrations', validMigration,
            function(item) return item.id end)
        if not ok then return nil, err end
        for index, migration in ipairs(manifest.migrations) do
            if migrationIds[migration.id] or migrationPaths[migration.path] then
                return invalid(('$.migrations[%d]'):format(index), 'Migration ID or path is duplicated.')
            end
            migrationIds[migration.id], migrationPaths[migration.path] = true, true
        end

        ok, err = exactObject(manifest.dataOwnership, '$.dataOwnership', { 'tables', 'characterDelete' })
        if not ok then return nil, err end
        ok, err = validateArray(manifest.dataOwnership.tables, '$.dataOwnership.tables', function(value)
            return type(value) == 'string' and #value <= 64 and value:match('^synex_[a-z0-9_]+$') ~= nil
        end)
        if not ok then return nil, err end
        local deletionModes = { none = true, delete = true, anonymize = true, retain = true, block = true }
        if not deletionModes[manifest.dataOwnership.characterDelete] then
            return invalid('$.dataOwnership.characterDelete', 'Character deletion policy is invalid.')
        end

        ok, err = exactObject(manifest.stateSnapshot, '$.stateSnapshot', { 'supported', 'schemaVersion' })
        if not ok then return nil, err end
        if type(manifest.stateSnapshot.supported) ~= 'boolean' or manifest.stateSnapshot.schemaVersion ~= 1 then
            return invalid('$.stateSnapshot', 'State snapshot support must declare schemaVersion 1.')
        end
        return true, nil
    end

    return validator
end
