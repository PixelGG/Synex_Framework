return function(Foundation)
local API_VERSION = Foundation.API_VERSION
local MAX_MINOR = Foundation.MAX_MINOR

local function contractDefinitions()
    local id = { type = 'string', minLength = 36, maxLength = 36 }
    local amount = { type = 'integer', minimum = 1, maximum = MAX_MINOR }
    local text128 = { type = 'string', minLength = 1, maxLength = 128 }
    local principalKind = { type = 'string', enum = { 'system', 'resource', 'user', 'character', 'group' } }
    local permission = {
        type = 'string', enum = { 'view', 'deposit', 'withdraw', 'transfer', 'history', 'manage', 'close' }
    }
    local permissions = { type = 'array', minItems = 0, maxItems = 7, uniqueItems = true, items = permission }
    local unsignedCount = { type = 'string', minLength = 1, maxLength = 20 }
    local signedTotal = { type = 'string', minLength = 1, maxLength = 38 }
    local findingSummary = {
        type = 'object', additionalProperties = false, required = { 'rule', 'severity' },
        properties = {
            rule = {
                type = 'string', enum = {
                    'ledger_imbalance', 'snapshot_sum_drift', 'negative_asset_balance',
                    'reserved_exceeds_booked', 'orphan_transaction'
                }
            },
            severity = { type = 'string', enum = { 'warn' } }
        }
    }
    local findingDetail = {
        type = 'object', additionalProperties = false,
        required = { 'finding_id', 'rule', 'severity', 'details_json', 'created_at' },
        properties = {
            finding_id = id, rule = findingSummary.properties.rule, severity = findingSummary.properties.severity,
            aggregate_type = { type = 'string', maxLength = 32 }, aggregate_id = { type = 'string', maxLength = 128 },
            details_json = { type = 'string', maxLength = 4096 }, created_at = { type = 'string' }
        }
    }
    local commonMutationProperties = {
        idempotency_key = id,
        amount_minor = amount,
        reference = text128,
        actor_ref = { type = 'string', minLength = 1, maxLength = 128 },
        metadata_json = { type = 'string', maxLength = 4096 }
    }

    local function ledgerInput(first, second)
        local properties = {}
        for key, value in pairs(commonMutationProperties) do properties[key] = value end
        properties[first] = id
        properties[second] = id
        return {
            type = 'object', additionalProperties = false,
            required = { 'idempotency_key', first, second, 'amount_minor' },
            properties = properties
        }
    end

    local ledgerOutput = {
        type = 'object', additionalProperties = false,
        required = {
            'transaction_id', 'posting_id', 'transaction_kind', 'debit_account_id',
            'credit_account_id', 'debit_minor', 'credit_minor', 'currency_code'
        },
        properties = {
            transaction_id = id, posting_id = id, transaction_kind = { type = 'string' },
            debit_account_id = id, credit_account_id = id, debit_minor = amount,
            credit_minor = amount, currency_code = { type = 'string' }
        }
    }

    local holdTransitionInput = {
        type = 'object', additionalProperties = false,
        required = { 'idempotency_key', 'hold_id' },
        properties = {
            idempotency_key = id, hold_id = id, reference = text128,
            actor_ref = { type = 'string', minLength = 1, maxLength = 128 },
            metadata_json = { type = 'string', maxLength = 4096 }
        }
    }

    return {
        {
            name = 'synex.accounts.register_currency', version = API_VERSION, network = 'none', capability = 'synex.accounts.configure',
            input = {
                type = 'object', additionalProperties = false,
                required = { 'idempotency_key', 'currency_code', 'display_name', 'minor_unit' },
                properties = {
                    idempotency_key = id, currency_code = { type = 'string', minLength = 2, maxLength = 16 },
                    display_name = { type = 'string', minLength = 1, maxLength = 64 },
                    minor_unit = { type = 'integer', minimum = 0, maximum = 6 },
                    actor_ref = { type = 'string', minLength = 1, maxLength = 128 }
                }
            },
            output = {
                type = 'object', additionalProperties = false,
                required = { 'currency_id', 'currency_code', 'display_name', 'minor_unit', 'status' },
                properties = {
                    currency_id = id, currency_code = { type = 'string' }, display_name = { type = 'string' },
                    minor_unit = { type = 'integer' }, status = { type = 'string' }
                }
            }
        },
        {
            name = 'synex.accounts.create', version = API_VERSION, network = 'none', capability = 'synex.accounts.create',
            input = {
                type = 'object', additionalProperties = false,
                required = { 'idempotency_key', 'currency_code', 'account_role', 'owner_kind', 'owner_ref' },
                properties = {
                    idempotency_key = id, currency_code = { type = 'string', minLength = 2, maxLength = 16 },
                    account_role = { type = 'string', enum = { 'asset', 'mint', 'burn' } },
                    account_key = { type = 'string', minLength = 3, maxLength = 64 },
                    owner_kind = { type = 'string', enum = { 'system', 'user', 'character', 'group' } },
                    owner_ref = { type = 'string', minLength = 1, maxLength = 64 },
                    metadata_json = { type = 'string', maxLength = 4096 },
                    actor_ref = { type = 'string', minLength = 1, maxLength = 128 }
                }
            },
            output = {
                type = 'object', additionalProperties = false,
                required = {
                    'account_id', 'currency_code', 'account_role', 'owner_kind', 'owner_ref', 'status',
                    'booked_minor', 'reserved_minor', 'available_minor', 'sequence'
                },
                properties = {
                    account_id = id, currency_code = { type = 'string' }, account_role = { type = 'string' },
                    owner_kind = { type = 'string' }, owner_ref = { type = 'string' }, status = { type = 'string' },
                    booked_minor = { type = 'integer' }, reserved_minor = { type = 'integer' },
                    available_minor = { type = 'integer' }, sequence = { type = 'integer' }
                }
            }
        },
        {
            name = 'synex.accounts.get_snapshot', version = API_VERSION, network = 'none', capability = 'synex.accounts.read',
            input = { type = 'object', additionalProperties = false, required = { 'account_id' }, properties = { account_id = id } },
            output = {
                type = 'object', additionalProperties = false,
                required = {
                    'account_id', 'currency_code', 'minor_unit', 'account_role', 'owner_kind', 'owner_ref',
                    'status', 'booked_minor', 'reserved_minor', 'available_minor', 'sequence', 'version',
                    'snapshot_created_at'
                },
                properties = {
                    account_id = id, account_key = { type = 'string' }, currency_code = { type = 'string' },
                    minor_unit = { type = 'integer' }, account_role = { type = 'string' }, owner_kind = { type = 'string' },
                    owner_ref = { type = 'string' }, status = { type = 'string' }, booked_minor = { type = 'integer' },
                    reserved_minor = { type = 'integer' }, available_minor = { type = 'integer' },
                    sequence = { type = 'integer' }, version = { type = 'integer' }, snapshot_created_at = { type = 'string' }
                }
            }
        },
        { name = 'synex.accounts.transfer', version = API_VERSION, network = 'none', capability = 'synex.accounts.transfer', input = ledgerInput('source_account_id', 'destination_account_id'), output = ledgerOutput },
        { name = 'synex.accounts.debit', version = API_VERSION, network = 'none', capability = 'synex.accounts.transfer', input = ledgerInput('account_id', 'counterparty_account_id'), output = ledgerOutput },
        { name = 'synex.accounts.credit', version = API_VERSION, network = 'none', capability = 'synex.accounts.transfer', input = ledgerInput('counterparty_account_id', 'account_id'), output = ledgerOutput },
        { name = 'synex.accounts.mint', version = API_VERSION, network = 'none', capability = 'synex.accounts.mint', input = ledgerInput('mint_account_id', 'account_id'), output = ledgerOutput },
        { name = 'synex.accounts.burn', version = API_VERSION, network = 'none', capability = 'synex.accounts.burn', input = ledgerInput('account_id', 'burn_account_id'), output = ledgerOutput },
        {
            name = 'synex.accounts.create_hold', version = API_VERSION, network = 'none', capability = 'synex.accounts.hold',
            input = {
                type = 'object', additionalProperties = false,
                required = { 'idempotency_key', 'account_id', 'capture_account_id', 'amount_minor', 'expires_in_seconds' },
                properties = {
                    idempotency_key = id, account_id = id, capture_account_id = id, amount_minor = amount,
                    expires_in_seconds = { type = 'integer', minimum = 1, maximum = 604800 },
                    reference = text128, actor_ref = { type = 'string', minLength = 1, maxLength = 128 },
                    metadata_json = { type = 'string', maxLength = 4096 }
                }
            },
            output = {
                type = 'object', additionalProperties = false,
                required = {
                    'hold_id', 'account_id', 'capture_account_id', 'amount_minor',
                    'currency_code', 'state', 'expires_in_seconds'
                },
                properties = {
                    hold_id = id, account_id = id, capture_account_id = id, amount_minor = amount,
                    currency_code = { type = 'string' }, state = { type = 'string' },
                    expires_in_seconds = { type = 'integer' }
                }
            }
        },
        {
            name = 'synex.accounts.get_hold', version = API_VERSION, network = 'none', capability = 'synex.accounts.read',
            input = { type = 'object', additionalProperties = false, required = { 'hold_id' }, properties = { hold_id = id } },
            output = {
                type = 'object', additionalProperties = false,
                required = {
                    'hold_id', 'account_id', 'capture_account_id', 'amount_minor', 'state',
                    'metadata_json', 'expires_at', 'created_at', 'event_id', 'event_occurred_at'
                },
                properties = {
                    hold_id = id, account_id = id, capture_account_id = id, amount_minor = amount,
                    state = { type = 'string' }, reference = { type = 'string' }, actor_ref = { type = 'string' },
                    metadata_json = { type = 'string' }, expires_at = { type = 'string' }, created_at = { type = 'string' },
                    event_id = id, event_occurred_at = { type = 'string' }
                }
            }
        },
        {
            name = 'synex.accounts.capture_hold', version = API_VERSION, network = 'none', capability = 'synex.accounts.hold',
            input = holdTransitionInput,
            output = {
                type = 'object', additionalProperties = false,
                required = {
                    'hold_id', 'state', 'transaction_id', 'posting_id', 'debit_account_id',
                    'credit_account_id', 'amount_minor'
                },
                properties = {
                    hold_id = id, state = { type = 'string' }, transaction_id = id, posting_id = id,
                    debit_account_id = id, credit_account_id = id, amount_minor = amount
                }
            }
        },
        {
            name = 'synex.accounts.release_hold', version = API_VERSION, network = 'none', capability = 'synex.accounts.hold',
            input = holdTransitionInput,
            output = {
                type = 'object', additionalProperties = false,
                required = { 'hold_id', 'state', 'account_id', 'amount_minor' },
                properties = { hold_id = id, state = { type = 'string' }, account_id = id, amount_minor = amount }
            }
        },
        {
            name = 'synex.accounts.reverse', version = API_VERSION, network = 'none', capability = 'synex.accounts.reverse',
            input = {
                type = 'object', additionalProperties = false,
                required = { 'idempotency_key', 'transaction_id', 'reason' },
                properties = {
                    idempotency_key = id, transaction_id = id,
                    reason = { type = 'string', minLength = 1, maxLength = 256 },
                    actor_ref = { type = 'string', minLength = 1, maxLength = 128 },
                    metadata_json = { type = 'string', maxLength = 4096 }
                }
            },
            output = {
                type = 'object', additionalProperties = false,
                required = {
                    'reversal_id', 'original_transaction_id', 'transaction_id', 'posting_id',
                    'debit_account_id', 'credit_account_id', 'amount_minor', 'currency_code'
                },
                properties = {
                    reversal_id = id, original_transaction_id = id, transaction_id = id, posting_id = id,
                    debit_account_id = id, credit_account_id = id, amount_minor = amount,
                    currency_code = { type = 'string', minLength = 2, maxLength = 16 }
                }
            }
        },
        {
            name = 'synex.accounts.create_access_role', version = API_VERSION, network = 'none',
            capability = 'synex.accounts.access.manage',
            input = {
                type = 'object', additionalProperties = false,
                required = { 'idempotency_key', 'account_id', 'role_key', 'display_name', 'permissions' },
                properties = {
                    idempotency_key = id, account_id = id,
                    role_key = { type = 'string', minLength = 2, maxLength = 48 },
                    display_name = { type = 'string', minLength = 1, maxLength = 96 },
                    permissions = { type = 'array', minItems = 1, maxItems = 7, uniqueItems = true, items = permission },
                    actor_ref = { type = 'string', minLength = 1, maxLength = 128 }
                }
            },
            output = {
                type = 'object', additionalProperties = false,
                required = { 'role_id', 'account_id', 'role_key', 'display_name', 'permissions', 'version' },
                properties = {
                    role_id = id, account_id = id, role_key = { type = 'string' },
                    display_name = { type = 'string' }, permissions = permissions,
                    version = { type = 'integer', minimum = 1 }
                }
            }
        },
        {
            name = 'synex.accounts.grant_access', version = API_VERSION, network = 'none',
            capability = 'synex.accounts.access.manage',
            input = {
                type = 'object', additionalProperties = false,
                required = { 'idempotency_key', 'account_id', 'role_id', 'principal_kind', 'principal_ref' },
                properties = {
                    idempotency_key = id, account_id = id, role_id = id, principal_kind = principalKind,
                    principal_ref = { type = 'string', minLength = 2, maxLength = 128 },
                    valid_for_seconds = { type = 'integer', minimum = 1, maximum = 31536000 },
                    actor_ref = { type = 'string', minLength = 1, maxLength = 128 }
                }
            },
            output = {
                type = 'object', additionalProperties = false,
                required = {
                    'grant_id', 'account_id', 'role_id', 'principal_kind', 'principal_ref', 'status', 'version'
                },
                properties = {
                    grant_id = id, account_id = id, role_id = id, principal_kind = principalKind,
                    principal_ref = { type = 'string' }, status = { type = 'string', enum = { 'active' } },
                    version = { type = 'integer', minimum = 1 },
                    valid_for_seconds = { type = 'integer', minimum = 1, maximum = 31536000 }
                }
            }
        },
        {
            name = 'synex.accounts.revoke_access', version = API_VERSION, network = 'none',
            capability = 'synex.accounts.access.manage',
            input = {
                type = 'object', additionalProperties = false,
                required = { 'idempotency_key', 'grant_id', 'reason', 'actor_ref' },
                properties = {
                    idempotency_key = id, grant_id = id,
                    reason = { type = 'string', minLength = 1, maxLength = 256 },
                    actor_ref = { type = 'string', minLength = 1, maxLength = 128 }
                }
            },
            output = {
                type = 'object', additionalProperties = false,
                required = {
                    'grant_id', 'account_id', 'role_id', 'principal_kind', 'principal_ref', 'status', 'version'
                },
                properties = {
                    grant_id = id, account_id = id, role_id = id, principal_kind = principalKind,
                    principal_ref = { type = 'string' }, status = { type = 'string', enum = { 'revoked' } },
                    version = { type = 'integer', minimum = 2 }
                }
            }
        },
        {
            name = 'synex.accounts.get_access', version = API_VERSION, network = 'none',
            capability = 'synex.accounts.access.read',
            input = {
                type = 'object', additionalProperties = false,
                required = { 'account_id', 'principal_kind', 'principal_ref' },
                properties = {
                    account_id = id, principal_kind = principalKind,
                    principal_ref = { type = 'string', minLength = 2, maxLength = 128 }
                }
            },
            output = {
                type = 'object', additionalProperties = false,
                required = { 'account_id', 'principal_kind', 'principal_ref', 'granted', 'permissions' },
                properties = {
                    account_id = id, principal_kind = principalKind, principal_ref = { type = 'string' },
                    granted = { type = 'boolean' }, grant_id = id,
                    grant_version = { type = 'integer', minimum = 1 }, role_id = id,
                    role_key = { type = 'string', minLength = 2, maxLength = 48 },
                    role_display_name = { type = 'string', minLength = 1, maxLength = 96 },
                    valid_until = { type = 'string' }, permissions = permissions
                }
            }
        },
        {
            name = 'synex.accounts.run_reconciliation', version = API_VERSION, network = 'none',
            capability = 'synex.accounts.integrity.run',
            input = {
                type = 'object', additionalProperties = false,
                required = { 'idempotency_key', 'currency_code' },
                properties = {
                    idempotency_key = id, currency_code = { type = 'string', minLength = 2, maxLength = 16 },
                    actor_ref = { type = 'string', minLength = 1, maxLength = 128 }
                }
            },
            output = {
                type = 'object', additionalProperties = false,
                required = {
                    'run_id', 'currency_id', 'currency_code', 'model_version', 'cutoff_posting_id',
                    'transaction_count', 'posting_count', 'total_debit_minor', 'total_credit_minor',
                    'total_booked_minor', 'status', 'finding_count', 'findings'
                },
                properties = {
                    run_id = id, currency_id = id, currency_code = { type = 'string' },
                    model_version = { type = 'integer', minimum = 2 }, cutoff_posting_id = unsignedCount,
                    transaction_count = unsignedCount, posting_count = unsignedCount,
                    total_debit_minor = signedTotal, total_credit_minor = signedTotal,
                    total_booked_minor = signedTotal, status = { type = 'string', enum = { 'healthy', 'warn' } },
                    finding_count = { type = 'integer', minimum = 0, maximum = 5 },
                    findings = { type = 'array', minItems = 0, maxItems = 5, items = findingSummary }
                }
            }
        },
        {
            name = 'synex.accounts.get_integrity', version = API_VERSION, network = 'none',
            capability = 'synex.accounts.integrity.read',
            input = {
                type = 'object', additionalProperties = false, required = { 'currency_code' },
                properties = { currency_code = { type = 'string', minLength = 2, maxLength = 16 } }
            },
            output = {
                type = 'object', additionalProperties = false,
                required = {
                    'currency_id', 'currency_code', 'model_version', 'cutoff_posting_id',
                    'transaction_count', 'posting_count', 'total_debit_minor', 'total_credit_minor',
                    'total_booked_minor', 'negative_asset_count', 'reserved_exceeds_booked_count',
                    'orphan_transaction_count', 'finding_count', 'status', 'generated_at', 'findings'
                },
                properties = {
                    currency_id = id, currency_code = { type = 'string' },
                    model_version = { type = 'integer', minimum = 1 }, cutoff_posting_id = unsignedCount,
                    transaction_count = unsignedCount, posting_count = unsignedCount,
                    total_debit_minor = signedTotal, total_credit_minor = signedTotal,
                    total_booked_minor = signedTotal,
                    negative_asset_count = unsignedCount,
                    reserved_exceeds_booked_count = unsignedCount,
                    orphan_transaction_count = unsignedCount,
                    finding_count = { type = 'integer', minimum = 0, maximum = 5 },
                    status = { type = 'string', enum = { 'healthy', 'warn' } },
                    generated_at = { type = 'string' },
                    findings = { type = 'array', minItems = 0, maxItems = 16, items = findingDetail }
                }
            }
        }
    }
end

return contractDefinitions
end
