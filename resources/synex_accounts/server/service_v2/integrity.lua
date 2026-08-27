return function(service, runtime)
    local Foundation = runtime.Foundation
    local Domain = runtime.Domain
    local domainError = runtime.domainError
    local db = runtime.db
    local shape = runtime.shape
    local currency = runtime.currency
    local utf8 = runtime.utf8
    local mutationBase = runtime.mutationBase
    local readBase = runtime.readBase
    local mergeFields = runtime.mergeFields
    local principalFields = runtime.principalFields
    local provenanceFields = runtime.provenanceFields

    function service.reason_register(request, context)
        local candidate, validationError = shape(request, mergeFields(provenanceFields, {
            idempotency_key = true, reason_code = true, display_name = true, description = true,
        }), { 'idempotency_key', 'reason_code', 'display_name' })
        if not candidate then return nil, validationError end
        if not Domain.validReasonCode(candidate.reason_code) then
            return nil, domainError('VALIDATION_FAILED', 'reason_code must be a namespaced reason.')
        end
        local _, displayError = utf8(candidate.display_name, 1, 64, 'display_name')
        if displayError then return nil, displayError end
        if candidate.description ~= nil then
            local _, descriptionError = utf8(candidate.description, 1, 256, 'description')
            if descriptionError then return nil, descriptionError end
        end
        local command, commandError = mutationBase('reason_register', candidate, context)
        if not command then return nil, commandError end
        command.displayName, command.description = candidate.display_name, candidate.description
        return db:registerReason(command)
    end
    function service.reason_get(request, context)
        local candidate, validationError = shape(request, mergeFields(principalFields,
            { reason_code = true }), { 'reason_code' })
        if not candidate then return nil, validationError end
        local accountAuthority, authorityError = readBase(candidate, context)
        if not accountAuthority then return nil, authorityError end
        return db:getReason(candidate.reason_code)
    end
    function service.reason_list(request, context)
        local candidate, validationError = shape(request, mergeFields(principalFields,
            { owner_resource = true, cursor = true, limit = true }), {})
        if not candidate then return nil, validationError end
        local accountAuthority, authorityError = readBase(candidate, context)
        if not accountAuthority then return nil, authorityError end
        local owner = candidate.owner_resource or accountAuthority.callerResource
        if owner ~= accountAuthority.callerResource then
            return nil, domainError('PRINCIPAL_SPOOFED',
                'A resource may list only its own reason namespace.')
        end
        return db:listReasons(owner, candidate.cursor, candidate.limit)
    end

    function service.integrity_get(request, context)
        local candidate, validationError = shape(request, mergeFields(principalFields,
            { currency_code = true }), { 'currency_code' })
        if not candidate then return nil, validationError end
        local _, currencyError = currency(candidate.currency_code)
        if currencyError then return nil, currencyError end
        local accountAuthority, authorityError = readBase(candidate, context)
        if not accountAuthority then return nil, authorityError end
        return db:getIntegrityV2(candidate.currency_code)
    end

    function service.get_integrity(request, context)
        local candidate, validationError = shape(request, { currency_code = true },
            { 'currency_code' })
        if not candidate then return nil, validationError end
        local _, currencyError = currency(candidate.currency_code)
        if currencyError then return nil, currencyError end
        local accountAuthority, authorityError = readBase(candidate, context)
        if not accountAuthority then return nil, authorityError end
        local report, reportError
        if Foundation.isCallable(db.getIntegrityInternal) then
            report, reportError = db:getIntegrityInternal(candidate.currency_code)
        else
            report, reportError = db:getIntegrityV2(candidate.currency_code)
        end
        if not report then return nil, reportError end
        local findings = {}
        local legacyRules = {
            ['ledger.transaction_sum'] = 'ledger_imbalance',
            ['snapshot.balance_drift'] = 'snapshot_sum_drift',
            ['account.negative_asset'] = 'negative_asset_balance',
            ['hold.reserved_exceeds_booked'] = 'reserved_exceeds_booked',
            ['ledger.orphan_transaction'] = 'orphan_transaction',
        }
        for _, finding in ipairs(report.findings or {}) do
            local legacyRule = legacyRules[finding.rule]
            if legacyRule then
                findings[#findings + 1] = {
                    finding_id = finding.finding_id,
                    rule = legacyRule, severity = 'warn',
                    aggregate_type = finding.aggregate_type,
                    aggregate_id = finding.aggregate_id,
                    details_json = finding.details_json or '{}',
                    created_at = finding.created_at or report.generated_at,
                }
            end
        end
        return {
            currency_id = report.currency_id, currency_code = report.currency_code,
            model_version = report.model_version,
            cutoff_posting_id = report.cutoff_entry_id,
            transaction_count = report.transaction_count,
            posting_count = report.entry_count,
            total_debit_minor = report.total_debit_minor or '0',
            total_credit_minor = report.total_credit_minor or '0',
            total_booked_minor = report.total_booked_minor,
            negative_asset_count = report.negative_asset_count,
            reserved_exceeds_booked_count = report.reserved_exceeds_booked_count,
            orphan_transaction_count = report.orphan_transaction_count,
            finding_count = #findings,
            status = #findings > 0 and 'warn' or 'healthy',
            generated_at = report.generated_at,
            findings = findings,
        }, nil
    end

    function service.integrity_reconcile(request, context)
        local candidate, validationError = shape(request, mergeFields(provenanceFields, {
            idempotency_key = true, currency_code = true, actor_ref = true,
        }), { 'idempotency_key', 'currency_code' })
        if not candidate then return nil, validationError end
        local _, currencyError = currency(candidate.currency_code)
        if currencyError then return nil, currencyError end
        local command, commandError = mutationBase('integrity_reconcile', candidate, context)
        if not command then return nil, commandError end
        command.currencyCode = candidate.currency_code
        if Foundation.isCallable(db.runReconciliationV2) then
            return db:runReconciliationV2(command)
        end
        return db:runReconciliation(command)
    end
    function service.run_reconciliation(request, context)
        local candidate, validationError = shape(request, {
            idempotency_key = true, currency_code = true, actor_ref = true,
        }, { 'idempotency_key', 'currency_code' })
        if not candidate then return nil, validationError end
        local _, currencyError = currency(candidate.currency_code)
        if currencyError then return nil, currencyError end
        local command, commandError = mutationBase(
            'run_reconciliation', candidate, context)
        if not command then return nil, commandError end
        command.currencyCode, command.actorRef = candidate.currency_code, candidate.actor_ref
        local report, reportError = db:runReconciliationV2(command)
        if not report then return nil, reportError end
        local legacy, legacyError = service.get_integrity({
            currency_code = candidate.currency_code,
        }, context)
        if not legacy then return nil, legacyError end
        local findings = {}
        for index, finding in ipairs(legacy.findings or {}) do
            if index > 5 then break end
            findings[index] = { rule = finding.rule, severity = 'warn' }
        end
        return {
            run_id = report.run_id,
            currency_id = legacy.currency_id,
            currency_code = legacy.currency_code,
            model_version = legacy.model_version,
            cutoff_posting_id = legacy.cutoff_posting_id,
            transaction_count = legacy.transaction_count,
            posting_count = legacy.posting_count,
            total_debit_minor = legacy.total_debit_minor,
            total_credit_minor = legacy.total_credit_minor,
            total_booked_minor = legacy.total_booked_minor,
            status = #findings > 0 and 'warn' or 'healthy',
            finding_count = #findings,
            findings = findings,
        }, nil
    end

    function service.get_control_summary(request, context)
        local candidate, validationError = shape(request, principalFields, {})
        if not candidate then return nil, validationError end
        local accountAuthority, authorityError = readBase(candidate, context)
        if not accountAuthority then return nil, authorityError end
        if Foundation.isCallable(db.getAccountsControlSummary) then
            return db:getAccountsControlSummary()
        end
        return db:getControlSummaryV2()
    end
end
