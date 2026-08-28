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

    local controlProviderOperations = {
        summary = true,
        health = true,
        list = true,
        inspect = true,
        search = true,
        metrics = true,
        findings = true,
        simulate = true
    }
    local controlProviderPresentations = {
        metrics = true,
        ['key-value'] = true,
        ['table'] = true,
        detail = true,
        timeline = true,
        graph = true,
        findings = true
    }
    local controlProviderInputFormats = {
        identifier = true,
        lookup = true,
        uuid = true,
        resource = true,
        capability = true,
        action = true,
        integer = true,
        ['numeric-string'] = true,
        boolean = true,
        text = true
    }
    local controlProviderAccessClasses = {
        general = true,
        audit = true,
        security = true,
        financial = true,
        identifiers = true
    }
    local function validControlIdentifier(value, maximum)
        return type(value) == 'string' and #value >= 2 and #value <= maximum
            and value:match('^[a-z][a-z0-9_%-]*$') ~= nil
            and value:sub(-1) ~= '_' and value:sub(-1) ~= '-'
            and not value:find('__', 1, true) and not value:find('--', 1, true)
            and not value:find('_-', 1, true) and not value:find('-_', 1, true)
    end
    local function validControlText(value, maximum)
        return type(value) == 'string' and #value >= 1 and #value <= maximum
            and not value:find('[%z\1-\31\127]')
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

    local function validControlInput(input, operation)
        local valid = exactObject(input, '$.controlProvider.views[].input', { 'fields' })
        if valid ~= true then return false end
        local seen, idFields = {}, 0
        local fieldsValid = validateArray(input.fields,
            '$.controlProvider.views[].input.fields', function(field)
                local fieldValid = exactObject(field,
                    '$.controlProvider.views[].input.fields[]', {
                        'key', 'label', 'source', 'type', 'format', 'required'
                    }, { 'minLength', 'maxLength', 'minimum', 'maximum' })
                if fieldValid ~= true or type(field.key) ~= 'string' or #field.key < 1
                    or #field.key > 48 or not field.key:match('^[a-z][a-z0-9_]*$')
                    or seen[field.key] or not validControlText(field.label, 64)
                    or field.source ~= 'id' and field.source ~= 'filter'
                    or field.type ~= 'string' and field.type ~= 'integer'
                        and field.type ~= 'boolean'
                    or not controlProviderInputFormats[field.format]
                    or type(field.required) ~= 'boolean' then return false end
                if field.source == 'id' then
                    idFields = idFields + 1
                    if operation ~= 'inspect' or field.key ~= 'id'
                        or field.required ~= true or idFields > 1 then return false end
                end
                if field.type == 'integer' then
                    if field.format ~= 'integer' or field.minLength ~= nil
                        or field.maxLength ~= nil then return false end
                elseif field.type == 'string' then
                    if field.format == 'integer' or field.format == 'boolean' or field.minimum ~= nil
                        or field.maximum ~= nil then return false end
                elseif field.format ~= 'boolean' or field.minLength ~= nil or field.maxLength ~= nil
                    or field.minimum ~= nil or field.maximum ~= nil then return false end
                if field.minLength ~= nil and (type(field.minLength) ~= 'number'
                    or math.type(field.minLength) ~= 'integer' or field.minLength < 1
                    or field.minLength > 128) then return false end
                if field.maxLength ~= nil and (type(field.maxLength) ~= 'number'
                    or math.type(field.maxLength) ~= 'integer' or field.maxLength < 1
                    or field.maxLength > 128) then return false end
                if field.minLength ~= nil and field.maxLength ~= nil
                    and field.minLength > field.maxLength then return false end
                if field.minimum ~= nil and (type(field.minimum) ~= 'number'
                    or math.type(field.minimum) ~= 'integer'
                    or field.minimum < -2147483648 or field.minimum > 2147483647) then
                    return false
                end
                if field.maximum ~= nil and (type(field.maximum) ~= 'number'
                    or math.type(field.maximum) ~= 'integer'
                    or field.maximum < -2147483648 or field.maximum > 2147483647) then
                    return false
                end
                if field.minimum ~= nil and field.maximum ~= nil
                    and field.minimum > field.maximum then return false end
                seen[field.key] = true
                return true
            end, function(field) return field.key end, 8)
        return fieldsValid == true and #input.fields >= 1
    end

    local function validControlSearch(search)
        local valid = exactObject(search, '$.controlProvider.views[].search', { 'kinds' })
        if valid ~= true then return false end
        local kindsValid = validateArray(search.kinds,
            '$.controlProvider.views[].search.kinds', function(kind)
                local kindValid = exactObject(kind,
                    '$.controlProvider.views[].search.kinds[]', {
                        'id', 'modes', 'accessClass'
                    })
                if kindValid ~= true or not validControlIdentifier(kind.id, 32)
                    or not controlProviderAccessClasses[kind.accessClass] then return false end
                local modesValid = validateArray(kind.modes,
                    '$.controlProvider.views[].search.kinds[].modes', function(mode)
                        return mode == 'exact' or mode == 'prefix'
                    end, nil, 2)
                return modesValid == true and #kind.modes >= 1
            end, function(kind) return kind.id end, 16)
        return kindsValid == true and #search.kinds >= 1
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
        }, { '$schema', 'controlProvider', 'worldBundles' })
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

        if manifest.controlProvider ~= nil then
            local provider = manifest.controlProvider
            ok, err = exactObject(provider, '$.controlProvider', {
                'schemaVersion', 'namespace', 'label', 'category', 'version',
                'operations', 'views'
            })
            if not ok then return nil, err end
            if provider.schemaVersion ~= 1
                or not validControlIdentifier(provider.namespace, 32)
                or not validControlText(provider.label, 64)
                or not validControlIdentifier(provider.category, 32)
                or not validSemver(provider.version) then
                return invalid('$.controlProvider',
                    'Control provider identity must use the bounded schemaVersion 1 shape.')
            end
            local operationSet = {}
            ok, err = validateArray(provider.operations, '$.controlProvider.operations',
                function(operation) return controlProviderOperations[operation] == true end,
                nil, 8)
            if not ok then return nil, err end
            if #provider.operations < 1 then
                return invalid('$.controlProvider.operations',
                    'Control providers require at least one read-only operation.')
            end
            for _, operation in ipairs(provider.operations) do operationSet[operation] = true end
            local viewIds = {}
            local function validControlView(view)
                local valid = exactObject(view, '$.controlProvider.views[]', {
                    'id', 'label', 'operation', 'presentation', 'accessClass'
                }, { 'order', 'description', 'input', 'search' })
                if valid ~= true or not validControlIdentifier(view.id, 48)
                    or viewIds[view.id] or not validControlText(view.label, 64)
                    or not operationSet[view.operation]
                    or not controlProviderPresentations[view.presentation]
                    or not controlProviderAccessClasses[view.accessClass]
                    or (view.order ~= nil and (type(view.order) ~= 'number'
                        or math.type(view.order) ~= 'integer'
                        or view.order < 0 or view.order > 1000))
                    or (view.description ~= nil
                        and not validControlText(view.description, 160))
                    or (view.input ~= nil
                        and not validControlInput(view.input, view.operation))
                    or (view.operation == 'search'
                        and not validControlSearch(view.search))
                    or (view.operation ~= 'search' and view.search ~= nil) then return false end
                viewIds[view.id] = true
                return true
            end
            ok, err = validateArray(provider.views, '$.controlProvider.views',
                validControlView, function(view) return view.id end, 32)
            if not ok then return nil, err end
            if #provider.views < 1 then
                return invalid('$.controlProvider.views',
                    'Control providers require at least one declared view.')
            end
        end

        if manifest.worldBundles ~= nil then
            ok, err = validateArray(manifest.worldBundles, '$.worldBundles', function(path)
                if type(path) ~= 'string' or #path < 18 or #path > 240
                    or path:match('^world/[A-Za-z0-9%._/-]+%.world%.json$') == nil
                    or path:find('//', 1, true) ~= nil then return false end
                for segment in path:gmatch('[^/]+') do
                    if segment == '.' or segment == '..' then return false end
                end
                return true
            end, nil, 64)
            if not ok then return nil, err end
        end

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
