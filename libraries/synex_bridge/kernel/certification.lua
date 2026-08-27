assert(SynexBridgeKernel and SynexBridgeKernel.Foundation,
    'synex_bridge foundation must load before certification')

local Foundation = SynexBridgeKernel.Foundation
local Certification = {}

local MAX_ARTIFACT_BYTES = 1048576
local PROVIDER_RESOURCES = {
    qb = 'synex_bridge_qb',
    qbx = 'synex_bridge_qbx',
    esx = 'synex_bridge_esx',
}
local SCHEMA_PATHS = {
    'libraries/synex_bridge/compatibility/schemas/certification.schema.json',
    'libraries/synex_bridge/compatibility/schemas/consumers.schema.json',
    'libraries/synex_bridge/compatibility/schemas/mappings.schema.json',
    'libraries/synex_bridge/compatibility/schemas/money-policies.schema.json',
    'libraries/synex_bridge/compatibility/schemas/profiles.schema.json',
    'libraries/synex_bridge/compatibility/schemas/review-lock.schema.json',
    'libraries/synex_bridge/compatibility/schemas/runtime-evidence.schema.json',
    'libraries/synex_bridge/compatibility/schemas/surfaces.schema.json',
}
local BASE_CHECKS = {
    'adapters.exact',
    'catalog.consumers-tracked',
    'catalog.money-policies-tracked',
    'catalog.profile-tracked',
    'catalog.review-lock',
    'catalog.schemas-tracked',
    'catalog.surface-tracked',
    'evidence.unique',
    'profile.effective-status',
    'profile.exists',
    'profile.version',
    'provider.exact',
    'provider.version-exact',
    'runtime.complete',
    'runtime.health',
    'runtime.provided',
    'runtime.provider-version',
    'script.name',
    'script.version',
    'target-framework-api.range-exact',
    'target-framework-api.range-reviewed',
    'tests.exact-set',
}

local function exactKeys(value, fields)
    if type(value) ~= 'table' then return false end
    local count = 0
    for key in pairs(value) do
        if fields[key] ~= true then return false end
        count = count + 1
    end
    local expected = 0
    for _ in pairs(fields) do expected = expected + 1 end
    return count == expected
end

local function validArray(value, minimum, maximum)
    if type(value) ~= 'table' or #value < minimum or #value > maximum then return false end
    for key in pairs(value) do
        if not Foundation.isSafeInteger(key, 1, #value) then return false end
    end
    return true
end

local function validPath(value, maximum)
    if not Foundation.isBoundedString(value, 1, maximum or 256,
        '^[A-Za-z0-9][A-Za-z0-9_./%-]*$')
        or value:find('//', 1, true) then return false end
    for segment in value:gmatch('[^/]+') do
        if segment == '.' or segment == '..' then return false end
    end
    return true
end

local function validHash(value)
    return Foundation.isBoundedString(value, 64, 64, '^[0-9a-f]+$')
end

local function sortedCopy(values, selector)
    local result = {}
    for index, value in ipairs(values) do result[index] = value end
    table.sort(result, function(left, right)
        local leftValue = selector and selector(left) or left
        local rightValue = selector and selector(right) or right
        return leftValue < rightValue
    end)
    return result
end

local function append(values, value)
    values[#values + 1] = value
end

local function contains(values, expected)
    for _, value in ipairs(values) do
        if value == expected then return true end
    end
    return false
end

local function statusAllowed(mode, status)
    if status == 'UNSUPPORTED' or status == 'UNKNOWN' then return false end
    if mode == 'strict' then
        return status == 'CERTIFIED' or status == 'COMPATIBLE'
    end
    if mode == 'compat' or mode == 'silent' then
        return status == 'CERTIFIED' or status == 'COMPATIBLE' or status == 'PARTIAL'
    end
    return false
end

local function requiredSurfaceEvidenceSatisfied(profile, surfaceDocument)
    if profile.status ~= 'CERTIFIED' or not Foundation.isMode(profile.mode)
        or not validArray(profile.requiredSurfaces, 1, 128)
        or type(profile.evidence) ~= 'table'
        or not validArray(profile.evidence.tests, 1, 32)
        or type(surfaceDocument) ~= 'table'
        or not validArray(surfaceDocument.surfaces, 1, 512) then
        return false
    end

    local profileTests = {}
    for _, testPath in ipairs(profile.evidence.tests) do
        if not validPath(testPath) or profileTests[testPath] then return false end
        profileTests[testPath] = true
    end

    local surfaces = {}
    for _, surface in ipairs(surfaceDocument.surfaces) do
        if type(surface) ~= 'table' or not Foundation.isDefinitionName(surface.name)
            or surfaces[surface.name] then return false end
        surfaces[surface.name] = surface
    end

    local requiredNames, requiredTests = {}, {}
    local requiredTestCount = 0
    for _, requirement in ipairs(profile.requiredSurfaces) do
        if type(requirement) ~= 'table'
            or not Foundation.isDefinitionName(requirement.name)
            or requiredNames[requirement.name]
            or not validArray(requirement.acceptedStatuses, 1, 5) then
            return false
        end
        requiredNames[requirement.name] = true
        local accepted = {}
        for _, status in ipairs(requirement.acceptedStatuses) do
            if not Foundation.isStatus(status) or accepted[status]
                or not statusAllowed(profile.mode, status) then return false end
            accepted[status] = true
        end

        local surface = surfaces[requirement.name]
        if not surface or not Foundation.isStatus(surface.status)
            or not statusAllowed(profile.mode, surface.status)
            or not contains(requirement.acceptedStatuses, surface.status)
            or not validArray(surface.tests, 1, 32) then return false end
        local surfaceTests = {}
        for _, testPath in ipairs(surface.tests) do
            if not validPath(testPath) or surfaceTests[testPath] then return false end
            surfaceTests[testPath] = true
            if not requiredTests[testPath] then
                requiredTests[testPath] = true
                requiredTestCount = requiredTestCount + 1
            end
        end
    end
    if requiredTestCount == 0 then return false end
    for testPath in pairs(requiredTests) do
        if not profileTests[testPath] then return false end
    end
    return true
end

local function fingerprintPayload(certificate, checkIds)
    local values = {
        'synex-compatibility-certificate-v1',
        tostring(certificate.schema), certificate.kind,
        certificate.profileId, certificate.profileVersion,
        certificate.provider, certificate.providerResource,
        certificate.providerVersion, certificate.targetFrameworkApiRange,
        certificate.script.name, certificate.script.version,
    }
    for _, test in ipairs(sortedCopy(certificate.tests,
        function(value) return value.path end)) do
        append(values, 'test')
        append(values, test.path)
        append(values, test.sha256)
        append(values, test.status)
        append(values, tostring(test.tracked))
    end
    for _, sourceUrl in ipairs(sortedCopy(certificate.sourceUrls)) do
        append(values, 'source')
        append(values, sourceUrl)
    end
    for _, name in ipairs({
        'profileCatalog', 'surfaceCatalog', 'consumerCatalog',
        'moneyPolicyCatalog', 'reviewLock',
    }) do
        local binding = certificate.bindings[name]
        append(values, 'binding')
        append(values, name)
        append(values, binding.path)
        append(values, binding.sha256)
        append(values, tostring(binding.tracked))
    end
    for _, binding in ipairs(sortedCopy(certificate.bindings.schemas,
        function(value) return value.path end)) do
        append(values, 'schema')
        append(values, binding.path)
        append(values, binding.sha256)
        append(values, tostring(binding.tracked))
    end
    for _, checkId in ipairs(sortedCopy(checkIds)) do
        append(values, 'check')
        append(values, checkId)
        append(values, 'PASS')
    end
    local encoded = {}
    for index, value in ipairs(values) do
        encoded[index] = ('%d:%s'):format(#value, value)
    end
    return table.concat(encoded)
end

function Certification.fingerprint(certificate, checkIds)
    if type(certificate) ~= 'table' or type(checkIds) ~= 'table' then return nil end
    local ok, payload = pcall(fingerprintPayload, certificate, checkIds)
    if not ok then return nil end
    return Foundation.sha256(payload)
end

local function verifyBinding(binding, expectedPath, loadFile)
    if not exactKeys(binding, { path = true, sha256 = true, tracked = true })
        or binding.path ~= expectedPath or not validHash(binding.sha256)
        or binding.tracked ~= true then return false end
    local prefix = 'libraries/synex_bridge/'
    if binding.path:sub(1, #prefix) ~= prefix then return false end
    local raw = loadFile(binding.path:sub(#prefix + 1))
    return type(raw) == 'string' and #raw > 0 and #raw <= MAX_ARTIFACT_BYTES
        and Foundation.sha256(raw) == binding.sha256
end

local function expectedChecks(tests)
    local result = {}
    for index, value in ipairs(BASE_CHECKS) do result[index] = value end
    for _, test in ipairs(tests) do result[#result + 1] = 'test:' .. test.path end
    table.sort(result)
    return result
end

local function verifyReport(report, profile, surfaceDocument, loadFile)
    if not exactKeys(report, {
        schema = true, artifactKind = true, status = true, certified = true,
        profileId = true, checks = true, certificate = true, disclaimer = true,
    }) or report.schema ~= 1
        or report.artifactKind ~= 'synex-compatibility-certification'
        or report.status ~= 'CERTIFIED' or report.certified ~= true
        or report.profileId ~= profile.id
        or not Foundation.isBoundedString(report.disclaimer, 1, 1024)
        or not validArray(report.checks, #BASE_CHECKS + 1, #BASE_CHECKS + 32) then
        return false
    end

    if not requiredSurfaceEvidenceSatisfied(profile, surfaceDocument) then return false end

    local certificate = report.certificate
    if not exactKeys(certificate, {
        schema = true, kind = true, profileId = true, profileVersion = true,
        provider = true, providerResource = true, providerVersion = true,
        targetFrameworkApiRange = true, script = true, tests = true,
        sourceUrls = true, bindings = true, fingerprint = true,
    }) or certificate.schema ~= 1
        or certificate.kind ~= 'synex-compatibility-certificate'
        or certificate.profileId ~= profile.id
        or certificate.profileVersion ~= profile.version
        or certificate.provider ~= profile.provider
        or certificate.providerResource ~= PROVIDER_RESOURCES[profile.provider]
        or certificate.providerVersion ~= profile.providerVersion
        or certificate.targetFrameworkApiRange ~= profile.targetFrameworkApiRange
        or certificate.providerVersion ~= surfaceDocument.providerVersion
        or certificate.targetFrameworkApiRange ~= surfaceDocument.targetFrameworkApiRange
        or not Foundation.isSemver(certificate.providerVersion)
        or not Foundation.isSemverRange(certificate.targetFrameworkApiRange)
        or not validHash(certificate.fingerprint)
        or not exactKeys(certificate.script, { name = true, version = true })
        or certificate.script.name ~= profile.script.name
        or certificate.script.version ~= profile.script.testedVersion
        or not Foundation.isSemver(certificate.script.version)
        or not validArray(certificate.tests, 1, 32)
        or not validArray(certificate.sourceUrls, 1, 16)
        or not exactKeys(certificate.bindings, {
            profileCatalog = true, surfaceCatalog = true,
            consumerCatalog = true, moneyPolicyCatalog = true,
            reviewLock = true, schemas = true,
        }) or not validArray(certificate.bindings.schemas, #SCHEMA_PATHS, #SCHEMA_PATHS) then
        return false
    end

    local profileTests = profile.evidence.tests
    if #certificate.tests ~= #profileTests then return false end
    local testPaths = {}
    for _, test in ipairs(certificate.tests) do
        if not exactKeys(test, {
            path = true, sha256 = true, status = true, tracked = true,
        }) or not validPath(test.path) or not validHash(test.sha256)
            or test.status ~= 'PASS' or test.tracked ~= true or testPaths[test.path] then
            return false
        end
        testPaths[test.path] = true
    end
    for _, path in ipairs(profileTests) do
        if testPaths[path] ~= true then return false end
    end

    local sourceUrls = {}
    for _, sourceUrl in ipairs(certificate.sourceUrls) do
        if not Foundation.isBoundedString(sourceUrl, 12, 512, '^https://[^%s]+$')
            or sourceUrls[sourceUrl] then return false end
        sourceUrls[sourceUrl] = true
    end
    if #certificate.sourceUrls ~= #profile.evidence.sourceUrls then return false end
    for _, sourceUrl in ipairs(profile.evidence.sourceUrls) do
        if sourceUrls[sourceUrl] ~= true then return false end
    end

    local checkIds, seenChecks = {}, {}
    for index, check in ipairs(report.checks) do
        if not exactKeys(check, { id = true, status = true, message = true })
            or not Foundation.isBoundedString(check.id, 1, 384,
                '^[A-Za-z0-9][A-Za-z0-9_.:/%-]*$')
            or check.status ~= 'PASS'
            or not Foundation.isBoundedString(check.message, 1, 1024)
            or seenChecks[check.id] then return false end
        seenChecks[check.id], checkIds[index] = true, check.id
    end
    table.sort(checkIds)
    local requiredChecks = expectedChecks(certificate.tests)
    if #checkIds ~= #requiredChecks then return false end
    for index, checkId in ipairs(requiredChecks) do
        if checkIds[index] ~= checkId then return false end
    end

    local base = 'libraries/synex_bridge/compatibility/'
    if not verifyBinding(certificate.bindings.profileCatalog,
        base .. 'profiles.json', loadFile)
        or not verifyBinding(certificate.bindings.surfaceCatalog,
            base .. 'surfaces/' .. profile.provider .. '.json', loadFile)
        or not verifyBinding(certificate.bindings.consumerCatalog,
            base .. 'consumers.json', loadFile)
        or not verifyBinding(certificate.bindings.moneyPolicyCatalog,
            base .. 'money-policies.json', loadFile)
        or not verifyBinding(certificate.bindings.reviewLock,
            base .. 'review-lock.json', loadFile) then return false end
    local seenSchemas = {}
    for _, binding in ipairs(certificate.bindings.schemas) do
        if seenSchemas[binding.path]
            or not verifyBinding(binding, binding.path, loadFile) then return false end
        seenSchemas[binding.path] = true
    end
    for _, path in ipairs(SCHEMA_PATHS) do
        if seenSchemas[path] ~= true then return false end
    end

    return Certification.fingerprint(certificate, checkIds) == certificate.fingerprint
end

function Certification.verify(options)
    if type(options) ~= 'table' or type(options.profile) ~= 'table'
        or type(options.surfaceDocument) ~= 'table'
        or type(options.loadFile) ~= 'function'
        or type(options.decode) ~= 'function' then return false end
    local profile = options.profile
    if profile.status ~= 'CERTIFIED' or not validPath(profile.certificationArtifact, 192)
        or not profile.certificationArtifact:match(
            '^compatibility/certifications/[a-z][a-z0-9_.%-]*%.json$') then
        return false
    end
    local raw = options.loadFile(profile.certificationArtifact)
    if type(raw) ~= 'string' or #raw < 2 or #raw > MAX_ARTIFACT_BYTES then return false end
    local decoded, report = pcall(options.decode, raw)
    return decoded and verifyReport(report, profile, options.surfaceDocument,
        options.loadFile) == true
end

SynexBridgeKernel.Certification = Certification
