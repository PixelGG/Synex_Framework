return function(Foundation)
local Shared = require('server.persistence.organizations_shared')(Foundation)
local rejected = Shared.rejected
local affectedRows = Shared.affectedRows
local checkedId = Shared.checkedId
local checkedReason = Shared.checkedReason
local mutationResult = Shared.mutationResult
local execute = {}

local function ownerContext(context)
    local owner = type(context) == 'table' and context.caller or nil
    local epoch = type(context) == 'table' and context.callerEpoch or nil
    if type(owner) ~= 'string' or #owner < 3 or #owner > 64
        or owner:match('^[A-Za-z0-9][A-Za-z0-9_.%-]*$') == nil
        or type(epoch) ~= 'number' or math.type(epoch) ~= 'integer' or epoch < 1 then
        return nil, nil, Foundation.domainError('VALIDATION_FAILED',
            'The extension registry owner context is invalid.')
    end
    return owner, epoch, nil
end

local function defer(runtime, context, registry, owner, epoch, generation, key, value)
    if type(runtime.deferRegistry) ~= 'function' then
        return nil, Foundation.domainError('DATABASE_ERROR',
            'The extension registry commit coordinator is unavailable.', true)
    end
    return runtime.deferRegistry(
        context, registry, owner, epoch, generation, key, value)
end

local function requireSynchronization(tx, runtime, owner, epoch)
    if not Foundation.isCallable(runtime.requireRegistryOwnerSession) then
        return nil, Foundation.domainError('DATABASE_ERROR',
            'The extension registry synchronization boundary is unavailable.', true)
    end
    return runtime.requireRegistryOwnerSession(tx, owner, epoch)
end

function execute.registries_begin(tx, request, runtime, context)
    local owner, epoch, ownerError = ownerContext(context)
    if not owner then return nil, ownerError, nil end
    local preflight = Foundation.isCallable(runtime.completeAuthorizationPreflight)
        and runtime.completeAuthorizationPreflight(context)
    if preflight then return preflight end
    if not Foundation.isCallable(runtime.requireRegistryOwnerEpoch) then
        return rejected('DATABASE_ERROR',
            'The registry owner epoch fence is unavailable.', true)
    end
    local current, currentError = runtime.requireRegistryOwnerEpoch(owner, epoch)
    if not current then return nil, currentError, nil end
    local existing = tx.one([[SELECT `owner_resource`, `owner_epoch`, `begin_key`,
            `generation`, `active` FROM `synex_group_registry_owner_syncs`
        WHERE `owner_resource` = ? FOR UPDATE]], { owner })
    current, currentError = runtime.requireRegistryOwnerEpoch(owner, epoch)
    if not current then return nil, currentError, nil end
    local generation
    if existing and existing.begin_key == request.idempotency_key then
        local active = tonumber(existing.active)
        if active ~= 0 and active ~= 1 then
            return rejected('DATABASE_RESULT_INVALID',
                'The stored registry synchronization state is invalid.', true)
        end
        if tonumber(existing.owner_epoch) ~= epoch then
            return rejected('IDEMPOTENCY_CONFLICT',
                'The registry synchronization key belongs to another owner epoch.')
        end
        if active ~= 1 then
            return rejected('STALE_RESOURCE',
                'The registry synchronization session is no longer active.')
        end
        generation = tonumber(existing.generation)
        if not generation or math.type(generation) ~= 'integer' or generation < 1 then
            return rejected('DATABASE_RESULT_INVALID',
                'The stored registry synchronization generation is invalid.', true)
        end
        return {
            owner_resource = owner,
            owner_epoch = epoch,
            generation = generation,
            status = 'synchronized',
            replayed = true
        }, nil, {}
    end

    if existing then
        local currentGeneration = tonumber(existing.generation)
        local currentActive = tonumber(existing.active)
        if not currentGeneration or math.type(currentGeneration) ~= 'integer'
            or currentGeneration < 1 or currentActive ~= 0 and currentActive ~= 1 then
            return rejected('DATABASE_RESULT_INVALID',
                'The stored registry synchronization generation is invalid.', true)
        end
        generation = currentGeneration + 1
    else
        generation = 1
    end
    if not generation or math.type(generation) ~= 'integer' or generation < 1 then
        return rejected('DATABASE_RESULT_INVALID',
            'The registry synchronization generation cannot be advanced.', true)
    end
    local changed
    if existing then
        changed = affectedRows(tx.query([[UPDATE `synex_group_registry_owner_syncs`
            SET `owner_epoch` = ?, `begin_key` = ?, `generation` = ?,
                `active` = 1, `updated_at` = CURRENT_TIMESTAMP(6)
            WHERE `owner_resource` = ? AND `generation` = ?]], {
            epoch, request.idempotency_key, generation, owner,
            tonumber(existing.generation)
        }))
    else
        changed = affectedRows(tx.query([[INSERT INTO `synex_group_registry_owner_syncs`
            (`owner_resource`, `owner_epoch`, `begin_key`, `generation`, `active`)
            VALUES (?, ?, ?, 1, 1)]], { owner, epoch, request.idempotency_key }))
    end
    if changed ~= 1 then
        return rejected('CONCURRENT_MODIFICATION',
            'The registry synchronization session changed concurrently.', true)
    end

    for _, tableName in ipairs({
        'synex_group_types', 'synex_group_relation_types',
        'synex_group_duty_states', 'synex_group_attribute_schemas'
    }) do
        local disabled = affectedRows(tx.query(([=[UPDATE `%s`
            SET `status` = 'disabled', `version` = `version` + 1
            WHERE `owner_resource` = ? AND `status` = 'active']=]):format(tableName),
            { owner }))
        if disabled == nil then
            return rejected('DATABASE_RESULT_INVALID',
                'The registry synchronization cleanup returned an invalid result.', true)
        end
    end
    return {
        owner_resource = owner,
        owner_epoch = epoch,
        generation = generation,
        status = 'synchronized',
        replayed = false
    }, nil, {}
end

function execute.relation_types_register(tx, request, runtime, context)
    local owner, epoch, ownerError = ownerContext(context)
    if not owner then return nil, ownerError, nil end
    local preflight = Foundation.isCallable(runtime.completeAuthorizationPreflight)
        and runtime.completeAuthorizationPreflight(context)
    if preflight then return preflight end
    if request.direction ~= 'directed' and request.direction ~= 'symmetric' then
        return rejected('VALIDATION_FAILED',
            'A relation type direction must be directed or symmetric.')
    end
    local synchronized, synchronizationError = requireSynchronization(
        tx, runtime, owner, epoch)
    if not synchronized then return nil, synchronizationError, nil end
    local existing = tx.one([[SELECT id, public_id, owner_resource, owner_epoch,
            type_key, display_name, direction, schema_version, status, version
        FROM synex_group_relation_types WHERE type_key = ? FOR UPDATE]], { request.type })
    local publicId, version, changed, previous
    if existing then
        if existing.owner_resource ~= owner then
            return rejected('TYPE_OWNER_CONFLICT',
                'The relation type is owned by another resource.')
        end
        if existing.status == 'retired' then
            return rejected('INVALID_TRANSITION', 'A retired relation type cannot be registered again.')
        end
        local currentSchemaVersion = tonumber(existing.schema_version)
        local currentVersion = tonumber(existing.version)
        local currentEpoch = tonumber(existing.owner_epoch)
        if not currentSchemaVersion or not currentVersion or not currentEpoch then
            return rejected('DATABASE_RESULT_INVALID',
                'The stored relation type ownership or version is invalid.')
        end
        local sameDefinition = existing.display_name == request.label
            and existing.direction == request.direction
        if request.schema_version < currentSchemaVersion
            or request.schema_version == currentSchemaVersion and not sameDefinition then
            return rejected('CONCURRENT_MODIFICATION',
                'Relation type changes must advance schema_version.', true, {
                    expected_minimum = currentSchemaVersion + 1,
                    actual = request.schema_version
                })
        end
        publicId, version = existing.public_id, currentVersion
        changed = request.schema_version > currentSchemaVersion
            or currentEpoch ~= epoch or existing.status ~= 'active'
        previous = { schema_version = currentSchemaVersion, owner_epoch = currentEpoch,
            status = existing.status, version = currentVersion }
        if changed then
            if affectedRows(tx.query([[UPDATE synex_group_relation_types
                    SET display_name = ?, direction = ?, schema_version = ?,
                        owner_epoch = ?, status = 'active', version = version + 1
                    WHERE id = ? AND version = ?]], {
                request.label, request.direction, request.schema_version,
                epoch, existing.id, currentVersion
            })) ~= 1 then
                return rejected('CONCURRENT_MODIFICATION',
                    'The relation type changed during registration.', true)
            end
            version = currentVersion + 1
        end
    else
        local id, idError = checkedId(runtime, 'groups_relation_type')
        if not id then return nil, idError, nil end
        if affectedRows(tx.query([[INSERT INTO synex_group_relation_types
                (public_id, type_key, owner_resource, owner_epoch, display_name,
                 direction, schema_version, status, version)
                VALUES (?, ?, ?, ?, ?, ?, ?, 'active', 1)]], {
            id, request.type, owner, epoch, request.label,
            request.direction, request.schema_version
        })) ~= 1 then
            return rejected('CONCURRENT_MODIFICATION',
                'The relation type could not be registered.', true)
        end
        publicId, version, changed = id, 1, true
    end

    local deferred, deferError = defer(runtime, context, 'relationTypes', owner, epoch,
        synchronized.generation, 'relation_type:' .. request.type, {
            publicId = publicId, key = request.type, label = request.label,
            direction = request.direction, schemaVersion = request.schema_version,
            version = version
        })
    if not deferred then return nil, deferError, nil end
    local effect
    if changed then
        local reason, reasonError = checkedReason(runtime, nil, 'relation_type_registered')
        if not reason then return nil, reasonError, nil end
        effect = runtime.effect('relation_type.registered', 'relation_type', publicId,
            nil, nil, previous, {
                type = request.type, schema_version = request.schema_version,
                owner_epoch = epoch, direction = request.direction, version = version
            }, reason, version)
    end
    return mutationResult(runtime, publicId, 'relation_type',
        changed and 'active' or 'unchanged', version, effect)
end

function execute.duty_states_register(tx, request, runtime, context)
    local owner, epoch, ownerError = ownerContext(context)
    if not owner then return nil, ownerError, nil end
    local preflight = Foundation.isCallable(runtime.completeAuthorizationPreflight)
        and runtime.completeAuthorizationPreflight(context)
    if preflight then return preflight end
    local synchronized, synchronizationError = requireSynchronization(
        tx, runtime, owner, epoch)
    if not synchronized then return nil, synchronizationError, nil end
    local existing = tx.one([[SELECT public_id, owner_resource, owner_epoch, state_key,
            display_name, counts_as_on_duty, schema_version, status, version
        FROM synex_group_duty_states WHERE state_key = ? FOR UPDATE]], { request.state })
    local publicId, version, changed, previous
    if existing then
        if existing.owner_resource ~= owner then
            return rejected('TYPE_OWNER_CONFLICT',
                'The duty state is owned by another resource.')
        end
        if existing.status == 'retired' then
            return rejected('INVALID_TRANSITION', 'A retired duty state cannot be registered again.')
        end
        local currentSchemaVersion = tonumber(existing.schema_version)
        local currentVersion = tonumber(existing.version)
        local currentEpoch = tonumber(existing.owner_epoch)
        if not currentSchemaVersion or not currentVersion or not currentEpoch then
            return rejected('DATABASE_RESULT_INVALID',
                'The stored duty state ownership or version is invalid.')
        end
        local sameDefinition = existing.display_name == request.label
            and tonumber(existing.counts_as_on_duty)
                == (request.counts_as_on_duty == true and 1 or 0)
        if request.schema_version < currentSchemaVersion
            or request.schema_version == currentSchemaVersion and not sameDefinition then
            return rejected('CONCURRENT_MODIFICATION',
                'Duty state changes must advance schema_version.', true, {
                    expected_minimum = currentSchemaVersion + 1,
                    actual = request.schema_version
                })
        end
        publicId, version = existing.public_id, currentVersion
        changed = request.schema_version > currentSchemaVersion
            or currentEpoch ~= epoch or existing.status ~= 'active'
        previous = { schema_version = currentSchemaVersion, owner_epoch = currentEpoch,
            status = existing.status, version = currentVersion }
        if changed then
            if affectedRows(tx.query([[UPDATE synex_group_duty_states
                    SET display_name = ?, counts_as_on_duty = ?, schema_version = ?,
                        owner_epoch = ?, status = 'active', version = version + 1
                    WHERE state_key = ? AND version = ?]], {
                request.label, request.counts_as_on_duty == true and 1 or 0,
                request.schema_version, epoch, request.state, currentVersion
            })) ~= 1 then
                return rejected('CONCURRENT_MODIFICATION',
                    'The duty state changed during registration.', true)
            end
            version = currentVersion + 1
        end
    else
        local id, idError = checkedId(runtime, 'groups_duty_state')
        if not id then return nil, idError, nil end
        if affectedRows(tx.query([[INSERT INTO synex_group_duty_states
                (public_id, state_key, owner_resource, owner_epoch, display_name,
                 counts_as_on_duty, schema_version, status, version)
                VALUES (?, ?, ?, ?, ?, ?, ?, 'active', 1)]], {
            id, request.state, owner, epoch, request.label,
            request.counts_as_on_duty == true and 1 or 0, request.schema_version
        })) ~= 1 then
            return rejected('CONCURRENT_MODIFICATION',
                'The duty state could not be registered.', true)
        end
        publicId, version, changed = id, 1, true
    end

    local deferred, deferError = defer(runtime, context, 'dutyStates', owner, epoch,
        synchronized.generation, 'duty_state:' .. request.state, {
            publicId = publicId, key = request.state, label = request.label,
            countsAsOnDuty = request.counts_as_on_duty == true,
            schemaVersion = request.schema_version, version = version
        })
    if not deferred then return nil, deferError, nil end
    local effect
    if changed then
        local reason, reasonError = checkedReason(runtime, nil, 'duty_state_registered')
        if not reason then return nil, reasonError, nil end
        effect = runtime.effect('duty_state.registered', 'duty_state', publicId,
            nil, nil, previous, {
                state = request.state, schema_version = request.schema_version,
                owner_epoch = epoch, counts_as_on_duty = request.counts_as_on_duty,
                version = version
            }, reason, version)
    end
    return mutationResult(runtime, publicId, 'duty_state',
        changed and 'active' or 'unchanged', version, effect)
end

return { execute = execute }
end
