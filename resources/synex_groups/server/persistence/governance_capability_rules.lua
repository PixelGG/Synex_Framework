return function(Foundation)
local Shared = require('server.persistence.governance_shared')(Foundation)
local rejected = Shared.rejected
local activeGroup = Shared.activeGroup
local reason = Shared.reason
local handlers = { read = {}, execute = {} }

local function requestedScope(request)
    local scope = request.scope or 'group'
    if scope == 'group' then return 'group', '', nil end
    if scope == 'subtree' then return 'custom', 'subtree', nil end
    return nil, nil, Foundation.domainError('INVALID_SCOPE',
        'Capability rule scope must be group or subtree.')
end

local function resolveSource(tx, request, group)
    if request.source_type == 'group' then
        if request.source_id ~= request.group_id then
            return nil, Foundation.domainError('INVALID_SCOPE',
                'A group-default capability source must be the requested group.')
        end
        return {
            id = group.id,
            public_id = request.group_id,
            kind = 'group',
            status = 'active'
        }, nil
    end
    if request.source_type == 'grade' then
        local source = tx.one([[SELECT id, public_id, status
            FROM synex_group_grades
            WHERE public_id = ? AND group_id = ? FOR UPDATE]],
            { request.source_id, group.id })
        if not source then
            return nil, Foundation.domainError('GRADE_NOT_FOUND',
                'The capability grade does not exist in this organization.')
        end
        source.kind = 'grade'
        return source, nil
    end
    if request.source_type == 'role' then
        local source = tx.one([[SELECT id, public_id, status
            FROM synex_group_roles
            WHERE public_id = ? AND group_id = ? FOR UPDATE]],
            { request.source_id, group.id })
        if not source then
            return nil, Foundation.domainError('ROLE_NOT_FOUND',
                'The capability role does not exist in this organization.')
        end
        source.kind = 'role'
        return source, nil
    end
    if request.source_type == 'membership' then
        local source = tx.one([[SELECT membership.id, membership.public_id,
                profile.lifecycle_state AS status
            FROM synex_group_memberships AS membership
            INNER JOIN synex_group_membership_profiles AS profile
                ON profile.membership_id = membership.id
            WHERE membership.public_id = ? AND membership.group_id = ? FOR UPDATE]],
            { request.source_id, group.id })
        if not source then
            return nil, Foundation.domainError('MEMBERSHIP_NOT_FOUND',
                'The capability membership does not exist in this organization.')
        end
        source.kind = 'membership'
        return source, nil
    end
    return nil, Foundation.domainError('CAPABILITY_SOURCE_INVALID',
        'Capability sources must be a group, grade, role, or membership.')
end

local function sourceActive(source)
    if source.kind == 'membership' then return source.status == 'ACTIVE' end
    return source.status == 'active'
end

local function loadExisting(tx, source, capability, scopeKind, scopeRef)
    if source.kind == 'group' then
        return tx.one([[SELECT id, effect, scope_kind, scope_ref, delegable, version
            FROM synex_group_default_capabilities
            WHERE group_id = ? AND capability_pattern = ?
                AND scope_kind = ? AND scope_ref = ? FOR UPDATE]],
            { source.id, capability, scopeKind, scopeRef })
    end
    if source.kind == 'membership' then
        return tx.one([[SELECT id, effect, scope_kind, scope_ref, delegable, version
            FROM synex_group_membership_capabilities
            WHERE membership_id = ? AND capability_pattern = ?
                AND scope_kind = ? AND scope_ref = ? FOR UPDATE]],
            { source.id, capability, scopeKind, scopeRef })
    end
    if source.kind == 'role' then
        return tx.one([[SELECT id, effect, scope_kind, scope_ref, delegable, version
            FROM synex_group_role_capabilities
            WHERE role_id = ? AND capability_pattern = ?
                AND scope_kind = ? AND scope_ref = ? FOR UPDATE]],
            { source.id, capability, scopeKind, scopeRef })
    end
    return tx.one([[SELECT capability.id, capability.effect, capability.delegable,
            capability.version,
            scope.scope_kind, scope.scope_ref, scope.version AS scope_version
        FROM synex_group_grade_capabilities AS capability
        LEFT JOIN synex_group_grade_capability_scopes AS scope
            ON scope.grade_capability_id = capability.id
        WHERE capability.grade_id = ? AND capability.capability_pattern = ?
        FOR UPDATE]], { source.id, capability })
end

local function insertRule(tx, source, capability, effect, scopeKind, scopeRef, delegable)
    if source.kind == 'group' then
        return tx.affected([[INSERT INTO synex_group_default_capabilities
            (group_id, capability_pattern, effect, scope_kind, scope_ref, delegable, version)
            VALUES (?, ?, ?, ?, ?, ?, 1)]],
            { source.id, capability, effect, scopeKind, scopeRef, delegable }) == 1
    end
    if source.kind == 'membership' then
        return tx.affected([[INSERT INTO synex_group_membership_capabilities
            (membership_id, capability_pattern, effect, scope_kind, scope_ref, delegable, version)
            VALUES (?, ?, ?, ?, ?, ?, 1)]],
            { source.id, capability, effect, scopeKind, scopeRef, delegable }) == 1
    end
    if source.kind == 'role' then
        return tx.affected([[INSERT INTO synex_group_role_capabilities
            (role_id, capability_pattern, effect, scope_kind, scope_ref, delegable, version)
            VALUES (?, ?, ?, ?, ?, ?, 1)]],
            { source.id, capability, effect, scopeKind, scopeRef, delegable }) == 1
    end
    if tx.affected([[INSERT INTO synex_group_grade_capabilities
            (grade_id, capability_pattern, effect, delegable, version)
            VALUES (?, ?, ?, ?, 1)]],
            { source.id, capability, effect, delegable }) ~= 1 then
        return false
    end
    local inserted = tx.one([[SELECT id FROM synex_group_grade_capabilities
        WHERE grade_id = ? AND capability_pattern = ? FOR UPDATE]],
        { source.id, capability })
    return inserted ~= nil and tx.affected([[INSERT INTO synex_group_grade_capability_scopes
        (grade_capability_id, scope_kind, scope_ref, version)
        VALUES (?, ?, ?, 1)]], { inserted and inserted.id, scopeKind, scopeRef }) == 1
end

local function updateRule(tx, source, existing, effect, scopeKind, scopeRef, delegable)
    local changed
    if source.kind == 'group' then
        changed = tx.affected([[UPDATE synex_group_default_capabilities
            SET effect = ?, delegable = ?, version = version + 1
            WHERE id = ? AND version = ?]],
            { effect, delegable, existing.id, existing.version })
    elseif source.kind == 'membership' then
        changed = tx.affected([[UPDATE synex_group_membership_capabilities
            SET effect = ?, delegable = ?, version = version + 1
            WHERE id = ? AND version = ?]],
            { effect, delegable, existing.id, existing.version })
    elseif source.kind == 'role' then
        changed = tx.affected([[UPDATE synex_group_role_capabilities
            SET effect = ?, delegable = ?, version = version + 1
            WHERE id = ? AND version = ?]],
            { effect, delegable, existing.id, existing.version })
    else
        changed = tx.affected([[UPDATE synex_group_grade_capabilities
            SET effect = ?, delegable = ?, version = version + 1
            WHERE id = ? AND version = ?]],
            { effect, delegable, existing.id, existing.version })
        if changed == 1 then
            changed = tx.affected([[UPDATE synex_group_grade_capability_scopes
                SET scope_kind = ?, scope_ref = ?, version = version + 1
                WHERE grade_capability_id = ? AND version = ?]],
                { scopeKind, scopeRef, existing.id, existing.version })
        end
    end
    return changed == 1
end

function handlers.execute.capabilities_set(tx, request, runtime, context)
    local scopeKind, scopeRef, scopeError = requestedScope(request)
    if not scopeKind then return nil, scopeError end
    local delegable = request.delegable == true and 1 or 0
    if request.effect == 'deny' and delegable == 1 then
        return rejected('VALIDATION_FAILED', 'A deny capability rule cannot be delegable.')
    end
    local _, authorizationError = runtime.authorize(
        tx, request.group_id, request.actor_character_id,
        'synex.groups.capabilities.manage', 'group', {
            parameters = {
                source_type = request.source_type,
                source_id = request.source_id,
                capability = request.capability,
                effect = request.effect,
                scope = request.scope or 'group',
                delegable = delegable == 1
            }
    })
    if authorizationError then return nil, authorizationError end
    local preflight = Foundation.isCallable(runtime.completeAuthorizationPreflight)
        and runtime.completeAuthorizationPreflight(context)
    if preflight then return preflight end
    local group, groupError = activeGroup(tx, runtime, request.group_id, true)
    if not group then return nil, groupError end
    local source, sourceError = resolveSource(tx, request, group)
    if not source then return nil, sourceError end
    if not sourceActive(source) then
        return rejected('CAPABILITY_SOURCE_INACTIVE',
            'The capability source must be active.')
    end
    local existing = loadExisting(tx, source, request.capability, scopeKind, scopeRef)
    local nextVersion = 1
    if existing then
        local currentVersion = tonumber(existing.version)
        if request.expected_version == nil
            or currentVersion ~= tonumber(request.expected_version)
            or source.kind == 'grade'
                and tonumber(existing.scope_version) ~= currentVersion then
            return rejected('CONCURRENT_MODIFICATION',
                'The capability rule version has changed.', true, {
                    expected = request.expected_version,
                    actual = currentVersion
                })
        end
        if not updateRule(tx, source, existing, request.effect,
                scopeKind, scopeRef, delegable) then
            return rejected('CONCURRENT_MODIFICATION',
                'The capability rule changed during the update.', true)
        end
        nextVersion = currentVersion + 1
    else
        if request.expected_version ~= nil then
            return rejected('CONCURRENT_MODIFICATION',
                'The capability rule does not yet exist.', true)
        end
        if not insertRule(tx, source, request.capability, request.effect,
                scopeKind, scopeRef, delegable) then
            return rejected('CONCURRENT_MODIFICATION',
                'The capability rule could not be created.', true)
        end
    end
    local touched, touchError = runtime.touchGroup(tx, group.id)
    if not touched then return nil, touchError end
    local reasonCode = reason(runtime, request.reason, 'capability_changed')
    local response = runtime.success(
        request.source_id, 'capability', request.effect, nextVersion)
    return response, nil, {
        runtime.effect('capability.changed', 'capability', request.source_id,
            request.group_id, request.actor_character_id,
            existing and {
                effect = existing.effect,
                scope = existing.scope_kind == 'custom' and existing.scope_ref or existing.scope_kind,
                delegable = tonumber(existing.delegable) == 1,
                version = existing.version
            } or nil,
            {
                source_type = request.source_type,
                source_id = request.source_id,
                capability = request.capability,
                effect = request.effect,
                scope = request.scope or 'group',
                delegable = delegable == 1,
                version = nextVersion
            }, reasonCode, nextVersion)
    }
end

return handlers
end
