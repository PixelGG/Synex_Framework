local factories = assert(SynexCoreFactories, 'factories must be loaded first')

factories.commands = function(deps)
    local platform = assert(deps.platform, 'commands require platform')
    local foundation = assert(deps.foundation, 'commands require foundation')
    local runtime = assert(deps.runtime, 'commands require runtime')
    local lifecycle = assert(deps.lifecycle, 'commands require lifecycle')
    local registries = assert(deps.registries, 'commands require registries')
    local identity = assert(deps.identity, 'commands require identity')
    local persistence = assert(deps.persistence, 'commands require persistence')
    local reliability = assert(deps.reliability, 'commands require reliability')
    local messaging = assert(deps.messaging, 'commands require messaging')
    local security = assert(deps.security, 'commands require security')
    local coreResource = assert(deps.coreResource, 'commands require core resource')
    local logger = foundation.logger
    local registry = {}
    local bound = false
    local maximumEntries = 256
    local usage = 'synex <overview|status|doctor|resources|sessions|permissions|trace|migrations|ledger|entities|prepare-restart|access|ban|unban|allow|unallow>'

    local function commandError(code, message, retryable)
        return foundation.error(code, message, { retryable = retryable == true })
    end

    local function safeError(err)
        local message = type(err) == 'table' and rawget(err, 'message') or nil
        if type(message) ~= 'string' or #message < 1 or #message > 512 then
            message = 'The command could not be completed.'
        end
        return {
            code = foundation.failureCode(err, 'UNAVAILABLE'),
            message = message,
            retryable = type(err) == 'table' and rawget(err, 'retryable') == true or false
        }
    end

    local function emit(commandSource, command, result, err)
        if command == 'overview' and err == nil then
            for _, line in ipairs(result.lines) do platform.print(line) end
            return true
        end
        local payload = {
            ok = err == nil,
            command = command,
            requestedBy = commandSource == 0 and 'console' or 'remote',
            result = result,
            error = err and safeError(err) or nil
        }
        local encodedOk, encoded = pcall(platform.jsonEncode, payload)
        if not encodedOk or type(encoded) ~= 'string' then
            platform.print('[synex_core] command output encoding failed')
            return nil
        end
        platform.print(encoded)
        return true
    end

    local function countList(values)
        local total = 0
        for _ in pairs(values or {}) do total = total + 1 end
        return total
    end

    local function resourcesSnapshot()
        local resources = registries.resources:list()
        local entries = {}
        for index = 1, math.min(#resources, maximumEntries) do
            local resource = resources[index]
            entries[index] = {
                name = resource.name,
                version = resource.manifest and resource.manifest.version or nil,
                state = resource.state,
                epoch = resource.epoch,
                health = foundation.copy(resource.health)
            }
        end
        return { entries = entries, total = #resources, truncated = #resources > maximumEntries }
    end

    local function workerSummary()
        local workers = lifecycle.scheduler:snapshot()
        local summary = { total = #workers, healthy = 0, degraded = 0, unhealthy = 0, pending = 0 }
        for _, worker in ipairs(workers) do
            local key = type(worker.health) == 'string' and worker.health:lower() or 'pending'
            if summary[key] ~= nil then summary[key] = summary[key] + 1 else summary.pending = summary.pending + 1 end
        end
        return summary
    end

    local function permissionSnapshot()
        local policies = security.capabilities:snapshot()
        local entries = {}
        for resource, entry in pairs(policies) do
            entries[#entries + 1] = {
                resource = resource,
                declared = countList(entry.requested),
                granted = #(entry.policy and entry.policy.allow or {}),
                denied = #(entry.policy and entry.policy.deny or {})
            }
        end
        table.sort(entries, function(left, right) return left.resource < right.resource end)
        local total = #entries
        while #entries > maximumEntries do entries[#entries] = nil end
        local persisted, persistedError = persistence.rbac:summary()
        return {
            runtime = security.rbac:snapshot(),
            persisted = persisted or { available = false, error = safeError(persistedError) },
            capabilities = { entries = entries, total = total, truncated = total > maximumEntries }
        }
    end

    local function serviceSummary(name, method, resource)
        local state = platform.resourceState(resource)
        if state == 'missing' then
            return { available = false, status = 'NOT_INSTALLED', resource = resource }, nil
        end
        if type(state) ~= 'string' or state == '' then
            return {
                available = false,
                status = 'DEGRADED',
                resource = resource,
                error = safeError(commandError('RESOURCE_STATE_UNAVAILABLE',
                    'The optional resource state could not be determined.', true))
            }, nil
        end
        if state ~= 'started' and state ~= 'starting' then
            return { available = false, status = 'STOPPED', resource = resource, resourceState = state }, nil
        end
        local epoch = registries.owners:epoch(coreResource)
        if not registries.owners:isCurrent(coreResource, epoch) then
            return { available = false }, commandError('CORE_NOT_READY', 'The Core service owner is not active.', true)
        end
        local result, err = messaging.services:call(coreResource, epoch, name, '^1.0.0', method, {}, {
            traceId = foundation.nextId('trace')
        })
        if err then
            return {
                available = false,
                status = state == 'starting' and 'STARTING' or 'DEGRADED',
                resource = resource,
                error = safeError(err)
            }, nil
        end
        return { available = true, status = 'HEALTHY', resource = resource, summary = result }, nil
    end

    registry.overview = {
        minimum = 1, maximum = 1,
        run = function()
            local doctor, doctorError = runtime:doctor()
            if not doctor then return nil, doctorError end
            local migrations, migrationError = persistence.migrations:snapshot(maximumEntries)
            if not migrations then return nil, migrationError end
            local lifecycleSnapshot = lifecycle.core:snapshot()
            local resources = registries.resources:summary()
            local sessions = registries.players:summary()
            local workers = workerSummary()
            local cluster = persistence.instances:snapshot()
            local checks = {}
            for _, check in ipairs(doctor.checks or {}) do checks[check.name] = check.status end
            local version = platform.resourceMetadata(coreResource, 'version', 0) or 'unknown'
            local lines = {
                ('[synex] Overview | core %s | lifecycle %s | doctor %s'):format(
                    tostring(version), tostring(lifecycleSnapshot.state), tostring(doctor.status)),
                ('[synex] Database %s | UTC %s | transaction isolation %s'):format(
                    tostring(checks.database or 'UNKNOWN'), tostring(checks['database-utc'] or 'UNKNOWN'),
                    tostring(checks['database-transaction-isolation'] or 'UNKNOWN')),
                ('[synex] Resources %d | healthy %d | degraded %d | unhealthy %d | unknown %d'):format(
                    resources.total, resources.healthy, resources.degraded, resources.unhealthy, resources.unknown),
                ('[synex] Sessions %d active | %d pending | oldest pending %dms%s | %d expired'):format(
                    sessions.activeSessions, sessions.pendingConnections,
                    sessions.oldestPendingAgeMs, sessions.pendingAgeCapped and '+' or '',
                    sessions.expiredPendingConnections),
                ('[synex] Workers %d | healthy %d | degraded %d | unhealthy %d | pending %d'):format(
                    workers.total, workers.healthy, workers.degraded, workers.unhealthy, workers.pending),
                ('[synex] Cluster %d healthy | %d stale | %d total'):format(
                    cluster.healthy, cluster.stale, cluster.total),
                ('[synex] Migrations %d/%d applied | %d applying | %d indeterminate | %d failed'):format(
                    migrations.totals.applied, migrations.totals.defined,
                    migrations.totals.applying, migrations.totals.indeterminate or 0,
                    migrations.totals.failed),
                '[synex] Details: synex status | synex doctor | synex sessions | synex migrations'
            }
            return { generatedAt = foundation.utcIso(), status = doctor.status, lines = lines }, nil
        end
    }
    registry.status = {
        minimum = 1, maximum = 1,
        run = function()
            return {
                generatedAt = foundation.utcIso(),
                lifecycle = lifecycle.core:snapshot(),
                cluster = persistence.instances:snapshot(),
                resources = registries.resources:summary(),
                sessions = registries.players:summary(),
                workers = workerSummary()
            }, nil
        end
    }
    registry.doctor = {
        minimum = 1, maximum = 1,
        run = function() return runtime:doctor() end
    }
    registry.resources = {
        minimum = 1, maximum = 1,
        run = function() return resourcesSnapshot(), nil end
    }
    registry.sessions = {
        minimum = 1, maximum = 1,
        run = function()
            return { sessions = registries.players:summary(), queue = identity.connections:snapshot() }, nil
        end
    }
    registry.permissions = {
        minimum = 1, maximum = 1,
        run = function() return permissionSnapshot(), nil end
    }
    registry.trace = {
        minimum = 3, maximum = 4,
        run = function(arguments)
            local limit = 25
            if arguments[4] ~= nil then
                limit = tonumber(arguments[4])
                if not limit or math.type(limit) ~= 'integer' or limit < 1 or limit > 64 then
                    return nil, commandError('INVALID_ARGUMENT', 'Trace limit must be an integer from 1 through 64.')
                end
            end
            return reliability.audit:search({ kind = arguments[2], value = arguments[3], limit = limit })
        end
    }
    registry.migrations = {
        minimum = 1, maximum = 1,
        run = function() return persistence.migrations:snapshot(maximumEntries) end
    }
    registry.ledger = {
        minimum = 1, maximum = 1,
        run = function() return serviceSummary('synex.accounts', 'get_control_summary', 'synex_accounts') end
    }
    registry.entities = {
        minimum = 1, maximum = 1,
        run = function() return serviceSummary('synex.entities', 'getControlSummary', 'synex_entities') end
    }
    registry['prepare-restart'] = {
        minimum = 1, maximum = 1,
        run = function()
            if type(runtime.prepareRestart) ~= 'function' then
                return nil, commandError('RESTART_PREPARATION_UNAVAILABLE',
                    'The Core restart preparation workflow is unavailable.')
            end
            return runtime:prepareRestart()
        end
    }
    local function accessContext()
        return { actor = 'console', actorType = 'system', traceId = foundation.nextId('trace') }
    end
    registry.ban = {
        minimum = 4, maximum = 4,
        run = function(arguments)
            return identity.access:ban({ id = arguments[2], userId = arguments[3], reason = arguments[4] }, accessContext())
        end
    }
    registry.unban = {
        minimum = 3, maximum = 3,
        run = function(arguments)
            return identity.access:unban({ id = arguments[2], reason = arguments[3] }, accessContext())
        end
    }
    registry.allow = {
        minimum = 4, maximum = 4,
        run = function(arguments)
            return identity.access:allow({ id = arguments[2], userId = arguments[3], reason = arguments[4] }, accessContext())
        end
    }
    registry.unallow = {
        minimum = 3, maximum = 3,
        run = function(arguments)
            return identity.access:revokeAllowlist({ id = arguments[2], reason = arguments[3] }, accessContext())
        end
    }
    registry.access = {
        minimum = 2, maximum = 3,
        run = function(arguments)
            local limit = arguments[3] == nil and 25 or tonumber(arguments[3])
            if not limit or math.type(limit) ~= 'integer' or limit < 1 or limit > 64 then
                return nil, commandError('INVALID_ARGUMENT', 'Access-list limit must be an integer from 1 through 64.')
            end
            return identity.access:list({ userId = arguments[2], limit = limit })
        end
    }

    local commands = {}
    function commands:dispatch(commandSource, arguments)
        if type(commandSource) ~= 'number' or commandSource ~= 0 then
            local err = commandError('CONSOLE_ONLY', 'Synex operator commands are console-only.')
            emit(commandSource, 'synex', nil, err)
            return nil, err
        end
        if type(arguments) ~= 'table' or getmetatable(arguments) ~= nil or #arguments > 4 then
            local err = commandError('INVALID_ARGUMENT', usage)
            emit(commandSource, 'synex', nil, err)
            return nil, err
        end
        for index = 1, #arguments do
            if type(arguments[index]) ~= 'string' or #arguments[index] < 1 or #arguments[index] > 128
                or arguments[index]:find('[%z\1-\31\127]') then
                local err = commandError('INVALID_ARGUMENT', usage)
                emit(commandSource, 'synex', nil, err)
                return nil, err
            end
        end
        local name = arguments[1]
        local definition = registry[name]
        if not definition or #arguments < definition.minimum or #arguments > definition.maximum then
            local err = commandError('INVALID_ARGUMENT', name == 'trace'
                and 'usage: synex trace <trace|character|transaction|resource> <value> [limit]' or usage)
            emit(commandSource, name or 'synex', nil, err)
            return nil, err
        end
        local invoked, result, err = foundation.safeCall(definition.run, arguments)
        if not invoked then
            logger:error('operator command failed unexpectedly', { command = name })
            result, err = nil, commandError('COMMAND_FAILED', 'The command failed unexpectedly.')
        end
        emit(commandSource, name, result, err)
        return result, err
    end

    function commands:bind()
        if bound then return true end
        bound = true
        platform.registerCommand('synex', function(commandSource, arguments)
            self:dispatch(commandSource, arguments)
        end, true)
        for _, alias in ipairs({ 'status', 'doctor' }) do
            local commandName = 'synex_' .. alias
            platform.registerCommand(commandName, function(commandSource, arguments)
                local forwarded = { alias }
                for index = 1, #arguments do forwarded[#forwarded + 1] = arguments[index] end
                self:dispatch(commandSource, forwarded)
            end, true)
        end
        return true
    end

    return commands
end
