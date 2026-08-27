return function(Foundation)
local function createLifecycle(deps)
    local repository = assert(type(deps.repository) == 'table' and deps.repository,
        'accounts lifecycle requires repository')
    local random = assert(deps.random, 'accounts lifecycle requires random')
    for _, method in ipairs({
        'getCharacterLifecycleSummary', 'getGroupLifecycleSummary',
        'applyCharacterDeletion', 'applyGroupDeletion'
    }) do
        assert(Foundation.isCallable(repository[method]),
            ('accounts lifecycle repository requires %s'):format(method))
    end

    local lifecycle = {}

    function lifecycle:characterParticipant()
        return {
            name = 'synex_accounts',
            priority = 80,
            required = true,
            prepare = function(context)
                local characterRef = context and context.character and context.character.id
                if not Foundation.isSubjectId(characterRef) then
                    return nil, Foundation.domainError('INVALID_CHARACTER',
                        'Character lifecycle context is invalid.')
                end
                return repository:getCharacterLifecycleSummary(characterRef)
            end,
            rollback = function()
                return true
            end,
            unload = function()
                return true
            end,
            deletePreflight = function(context)
                local characterRef = context and context.character and context.character.id
                if not Foundation.isSubjectId(characterRef) then
                    return nil, Foundation.domainError('INVALID_CHARACTER',
                        'Character deletion context is invalid.')
                end
                local summary, summaryError =
                    repository:getCharacterLifecycleSummary(characterRef)
                if not summary then return nil, summaryError end
                if summary.nonterminalHolds > 0 then
                    return {
                        action = 'block',
                        code = 'CHARACTER_ACCOUNTS_HAVE_HOLDS',
                        message = 'Release or capture all active character account holds before deletion.',
                    }
                end
                if summary.nonzeroAccounts > 0 then
                    return {
                        action = 'block',
                        code = 'CHARACTER_ACCOUNTS_HAVE_BALANCE',
                        message = 'Transfer all character account balances before deletion.',
                    }
                end
                return {
                    action = summary.accounts == 0 and summary.activeGrants == 0
                        and 'allow' or 'anonymize',
                    metadata = {
                        anonymousRef = Foundation.uuidV4(random),
                        accounts = summary.accounts,
                        grants = summary.activeGrants,
                        ledgerHistory = 'retain',
                    },
                }
            end,
            deleteCommit = function(context)
                local planId = context and context.planId
                local plan = context and context.plan
                if type(planId) ~= 'string' or #planId < 8 or #planId > 64
                    or type(plan) ~= 'table' or not Foundation.isSubjectId(plan.characterId)
                    or type(plan.actions) ~= 'table' then
                    return nil, Foundation.domainError('INVALID_DELETE_PLAN',
                        'Character account deletion plan is invalid.')
                end
                local metadata
                for _, action in ipairs(plan.actions) do
                    if action.owner == 'synex_accounts' then
                        if action.participant == nil or action.participant == 'synex_accounts' then
                            metadata = action.metadata
                            break
                        end
                    end
                end
                if type(metadata) ~= 'table'
                    or not Foundation.isUuid(metadata.anonymousRef) then
                    return nil, Foundation.domainError('INVALID_DELETE_PLAN',
                        'Character account anonymization metadata is invalid.')
                end
                return repository:applyCharacterDeletion(
                    planId, plan.characterId, metadata.anonymousRef)
            end,
        }
    end

    function lifecycle:groupProvider()
        return {
            domain = 'group',
            name = 'financial_accounts',
            schemaVersion = 1,
            preflight = function(request)
                if type(request) ~= 'table' or request.domain ~= 'group'
                    or not Foundation.isPublicId(request.subjectId) then
                    return nil, Foundation.domainError('INVALID_DELETION_REQUEST',
                        'Organization account deletion preflight is invalid.')
                end
                local summary, summaryError =
                    repository:getGroupLifecycleSummary(request.subjectId)
                if not summary then return nil, summaryError end
                if summary.nonterminalHolds > 0 then
                    return {
                        decision = 'block',
                        reason = 'Release or capture all active organization account holds before deletion.',
                        metadata = {
                            accounts = summary.accounts,
                            nonzeroAccounts = summary.nonzeroAccounts,
                            activeHolds = summary.nonterminalHolds,
                            activeGrants = summary.activeGrants,
                            bookedMinorTotal = summary.bookedMinorTotal,
                        },
                    }
                end
                if summary.nonzeroAccounts > 0 then
                    return {
                        decision = 'block',
                        reason = 'Transfer all organization account balances before deletion.',
                        metadata = {
                            accounts = summary.accounts,
                            nonzeroAccounts = summary.nonzeroAccounts,
                            activeHolds = summary.nonterminalHolds,
                            activeGrants = summary.activeGrants,
                            bookedMinorTotal = summary.bookedMinorTotal,
                            transferRequired = true,
                        },
                    }
                end
                return {
                    decision = 'anonymize',
                    reason = summary.accounts == 0 and summary.activeGrants == 0
                        and 'No account footprint exists; execution performs a fenced final check.'
                        or 'Zero-balance account ownership and access references will be anonymized.',
                    metadata = {
                        anonymousRef = Foundation.uuidV4(random),
                        accounts = summary.accounts,
                        nonzeroAccounts = summary.nonzeroAccounts,
                        activeHolds = summary.nonterminalHolds,
                        activeGrants = summary.activeGrants,
                        bookedMinorTotal = summary.bookedMinorTotal,
                        ledgerHistory = 'retain',
                    },
                }
            end,
            execute = function(request)
                local metadata = type(request) == 'table' and request.metadata or nil
                local traceId = type(request) == 'table'
                    and type(request.context) == 'table'
                    and request.context.deletionRequestId or nil
                if type(traceId) ~= 'string' or #traceId < 8 or #traceId > 64
                    or traceId:match('^[A-Za-z0-9][A-Za-z0-9_.:%-]*$') == nil then
                    traceId = nil
                end
                if type(request) ~= 'table' or request.domain ~= 'group'
                    or request.decision ~= 'anonymize'
                    or not Foundation.isPublicId(request.subjectId)
                    or type(metadata) ~= 'table'
                    or not Foundation.isUuid(metadata.anonymousRef) then
                    return nil, Foundation.domainError('INVALID_DELETION_REQUEST',
                        'Organization account deletion execution is invalid.')
                end
                return repository:applyGroupDeletion({
                    planId = request.planId,
                    actionId = request.actionId,
                    groupRef = request.subjectId,
                    anonymousRef = metadata.anonymousRef,
                    decision = request.decision,
                    reason = request.reason,
                    traceId = traceId,
                })
            end,
        }
    end

    return lifecycle
end

return createLifecycle
end
