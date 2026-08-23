local factories = assert(SynexCoreFactories, 'factories must be loaded first')

factories.identityConnectionTerminals = function(deps)
    local platform = assert(deps.platform, 'connection terminals require platform')
    local foundation = assert(deps.foundation, 'connection terminals require foundation')
    local acceptanceRejection = assert(deps.acceptanceRejection,
        'connection terminals require acceptance validation')
    local logConnectionStage = assert(deps.logConnectionStage,
        'connection terminals require stage telemetry')
    local onFinalized = deps.onFinalized or function() end
    local metrics = foundation.metrics
    local active = {}
    local quiesced = false
    local quiesceSnapshot = {}
    local terminals = {}

    local stoppingReason = 'The Synex runtime is stopping. Please reconnect shortly.'
    local stoppingCode = 'CORE_STOPPING'

    function terminals:open(connection, deferrals)
        -- Cfx function references are callable tables or userdata, not plain Lua functions.
        local deferralRead, deferralDone = foundation.safeCall(function()
            return deferrals.done
        end)
        if type(connection) ~= 'table' or type(connection.id) ~= 'string'
            or not deferralRead or not foundation.isCallable(deferralDone) then
            return nil, foundation.error('INVALID_CONNECTION_TERMINAL',
                'A connection identity and Cfx deferral terminal are required.')
        end
        if active[connection.id] then
            return nil, foundation.error('CONNECTION_TERMINAL_EXISTS',
                'The connection already owns an open Cfx deferral terminal.')
        end
        local terminal = {
            state = 'awaiting_tick', attempted = false, acceptance = false,
            pendingFinish = quiesced and { reason = stoppingReason, code = stoppingCode } or nil
        }
        local function queueFinish(reason, code)
            if not terminal.pendingFinish or code == stoppingCode
                or (terminal.pendingFinish.code == nil and code ~= nil) then
                terminal.pendingFinish = { reason = reason, code = code }
            end
        end
        local function finalize(reason, code)
            if terminal.state ~= 'open' then return false end
            if reason == nil then
                reason, code = acceptanceRejection(connection)
                if terminal.state ~= 'open' then return false end
                if terminal.pendingFinish then
                    reason, code = terminal.pendingFinish.reason, terminal.pendingFinish.code
                    terminal.pendingFinish = nil
                end
            end
            terminal.state = 'invoking'
            terminal.attempted = true
            terminal.acceptance = reason == nil
            active[connection.id] = nil
            local safeCode = nil
            local invoked = nil
            if terminal.acceptance then
                invoked = foundation.safeCall(deferralDone)
            else
                safeCode = type(code) == 'string' and code:match('^[A-Z0-9_]+$') and code:sub(1, 48)
                    or 'CONNECTION_REJECTED'
                local safeReason = tostring(reason):gsub('[%z\1-\31\127]', ' '):sub(1, 180)
                invoked = foundation.safeCall(deferralDone,
                    ('Synex [%s]: %s'):format(safeCode, safeReason):sub(1, 256))
            end
            foundation.safeCall(onFinalized, connection, terminal.acceptance, invoked == true)
            if not invoked then
                terminal.state = 'failed'
                logConnectionStage(connection, 'deferral_terminal_failed',
                    terminal.acceptance and 'DEFERRAL_ACCEPT_FAILED' or 'DEFERRAL_REJECT_FAILED', 'error')
                return nil, foundation.error('DEFERRAL_TERMINATION_FAILED',
                    'The Cfx connection deferral could not be finalized.')
            end
            terminal.state = terminal.acceptance and 'accepted' or 'rejected'
            foundation.safeCall(metrics.increment, metrics, 'synex_connections_total', {
                result = terminal.acceptance and 'accepted' or 'rejected'
            })
            logConnectionStage(connection, terminal.acceptance and 'deferral_accepted' or 'rejected',
                safeCode, terminal.acceptance and 'info' or 'warn')
            return true
        end
        function terminal:awaitTick()
            if self.state ~= 'open' then return false end
            self.state = 'awaiting_tick'
            return true
        end
        function terminal:afterTick()
            if self.state ~= 'awaiting_tick' then return false end
            self.state = 'open'
            local pendingFinish = self.pendingFinish
            self.pendingFinish = nil
            if pendingFinish then
                return finalize(pendingFinish.reason, pendingFinish.code)
            end
            return true
        end
        function terminal:update(message)
            if self.state ~= 'open' or self.pendingFinish ~= nil or quiesced then return false end
            deferrals.update(message)
            self.state = 'awaiting_tick'
            return true
        end
        function terminal:finish(reason, code)
            if self.state == 'awaiting_tick' then
                queueFinish(reason, code)
                return true, 'pending'
            end
            if self.state ~= 'open' then return false end
            queueFinish(reason, code)
            self.state = 'awaiting_tick'
            local deferred = foundation.safeCall(platform.defer)
            if not deferred then
                self.state = 'open'
                local pendingFinish = self.pendingFinish
                self.pendingFinish = nil
                return finalize(pendingFinish.reason, pendingFinish.code)
            end
            return self:afterTick()
        end
        function terminal:cancel()
            if self.state ~= 'awaiting_tick' and self.state ~= 'open' then return false end
            queueFinish(stoppingReason, stoppingCode)
            return true, 'pending'
        end
        function terminal:flushQuiesced()
            if not self.pendingFinish
                or (self.state ~= 'awaiting_tick' and self.state ~= 'open') then return false end
            self.state = 'open'
            local pendingFinish = self.pendingFinish
            self.pendingFinish = nil
            return finalize(pendingFinish.reason, pendingFinish.code)
        end
        function terminal:flushReadyQuiesced()
            if self.state ~= 'open' or not self.pendingFinish then return false end
            local pendingFinish = self.pendingFinish
            self.pendingFinish = nil
            return finalize(pendingFinish.reason, pendingFinish.code)
        end
        terminal.arm = terminal.afterTick
        active[connection.id] = terminal
        return terminal, nil
    end

    function terminals:quiesce()
        local firstQuiesce = not quiesced
        quiesced = true
        local ordered = {}
        for connectionId, terminal in pairs(active) do
            ordered[#ordered + 1] = { id = connectionId, terminal = terminal }
        end
        table.sort(ordered, function(left, right) return left.id < right.id end)
        local report = { requested = 0, completed = 0, pending = 0, cancelled = 0, failures = 0 }
        for _, entry in ipairs(ordered) do
            if firstQuiesce then quiesceSnapshot[entry.id] = entry.terminal end
            local invoked, requested, status = foundation.safeCall(entry.terminal.cancel, entry.terminal)
            if invoked and requested then
                report.requested = report.requested + 1
                report.cancelled = report.cancelled + 1
                if status == 'pending' then report.pending = report.pending + 1 end
            else
                report.failures = report.failures + 1
            end
        end
        return report
    end

    function terminals:flushQuiesced()
        if not quiesced then
            return nil, foundation.error('CONNECTION_TERMINALS_NOT_QUIESCED',
                'Connection terminals must be quiesced before they are flushed.')
        end
        local ordered = {}
        for connectionId, terminal in pairs(quiesceSnapshot) do
            ordered[#ordered + 1] = { id = connectionId, terminal = terminal }
        end
        table.sort(ordered, function(left, right) return left.id < right.id end)
        quiesceSnapshot = {}
        local report = { completed = 0, failures = 0 }
        for _, entry in ipairs(ordered) do
            if active[entry.id] == entry.terminal then
                local invoked, completed = foundation.safeCall(
                    entry.terminal.flushQuiesced, entry.terminal)
                if invoked and completed then
                    report.completed = report.completed + 1
                else
                    report.failures = report.failures + 1
                end
            end
        end
        report.remaining = self:count()
        return report, nil
    end

    function terminals:flushReadyQuiesced()
        if not quiesced then
            return nil, foundation.error('CONNECTION_TERMINALS_NOT_QUIESCED',
                'Connection terminals must be quiesced before ready terminals are flushed.')
        end
        local ordered = {}
        for connectionId, terminal in pairs(active) do
            ordered[#ordered + 1] = { id = connectionId, terminal = terminal }
        end
        table.sort(ordered, function(left, right) return left.id < right.id end)
        local report = { completed = 0, failures = 0 }
        for _, entry in ipairs(ordered) do
            if entry.terminal.state == 'open' and entry.terminal.pendingFinish then
                local invoked, completed = foundation.safeCall(
                    entry.terminal.flushReadyQuiesced, entry.terminal)
                if invoked and completed then
                    report.completed = report.completed + 1
                else
                    report.failures = report.failures + 1
                end
            end
        end
        report.remaining = self:count()
        return report, nil
    end

    function terminals:cancelAll()
        return self:quiesce()
    end

    function terminals:isQuiesced()
        return quiesced
    end

    function terminals:count()
        local count = 0
        for _ in pairs(active) do count = count + 1 end
        return count
    end

    return terminals
end
