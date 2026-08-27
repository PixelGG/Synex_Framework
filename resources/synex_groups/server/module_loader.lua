local RESOURCE_NAME = 'synex_groups'

if GetCurrentResourceName() ~= RESOURCE_NAME then
    error('synex_groups module loader is running in the wrong resource')
end

local modulePaths = {}
local fileCount = GetNumResourceMetadata(RESOURCE_NAME, 'file')
if type(fileCount) ~= 'number' or math.type(fileCount) ~= 'integer'
    or fileCount < 1 or fileCount > 256 then
    error('synex_groups manifest file catalog is invalid')
end

for index = 0, fileCount - 1 do
    local path = GetResourceMetadata(RESOURCE_NAME, 'file', index)
    if type(path) == 'string' and #path <= 160
        and path:match('^server/[a-z0-9_/]+%.lua$') then
        local name = path:sub(1, -5):gsub('/', '.')
        if modulePaths[name] ~= nil then
            error(('synex_groups module is declared more than once: %s'):format(name))
        end
        modulePaths[name] = path
    end
end

local moduleCache = {}
local moduleLoading = {}

local function requireLocalModule(name)
    if type(name) ~= 'string' or #name < 8 or #name > 160
        or name:match('^server%.[a-z0-9_%.]+$') == nil
        or name:find('..', 1, true) then
        error('synex_groups rejected an invalid module name', 2)
    end
    local path = modulePaths[name]
    if path == nil then
        error(('synex_groups module is not manifest-listed: %s'):format(name), 2)
    end
    if moduleCache[name] ~= nil then return moduleCache[name] end
    if moduleLoading[name] then
        error(('synex_groups module dependency cycle: %s'):format(name), 2)
    end

    moduleLoading[name] = true
    local source = LoadResourceFile(RESOURCE_NAME, path)
    if type(source) ~= 'string' or #source < 1 or #source > 1048576 then
        moduleLoading[name] = nil
        error(('synex_groups module source is unavailable: %s'):format(name), 2)
    end
    local chunk, compileError = load(
        source, '@' .. RESOURCE_NAME .. '/' .. path, 't', _ENV)
    if not chunk then
        moduleLoading[name] = nil
        error(('synex_groups module failed to compile: %s'):format(
            type(compileError) == 'string' and compileError or name), 2)
    end
    local executed, result = pcall(chunk)
    moduleLoading[name] = nil
    if not executed then error(result, 2) end
    if result == nil then result = true end
    moduleCache[name] = result
    return result
end

require = requireLocalModule
