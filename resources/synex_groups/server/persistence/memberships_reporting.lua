return function(Foundation)
local Shared = require('server.persistence.memberships_shared')(Foundation)
local ensureAffected = Shared.ensureAffected
local handlers = { read = {}, execute = {} }

local function requireActiveMembership(runtime, tx, publicId)
    local membership, membershipError = runtime.requireMembership(tx, publicId, true)
    if not membership then return nil, membershipError end
    if membership.lifecycle_state ~= 'ACTIVE' then
        return nil, Foundation.domainError('MEMBERSHIP_NOT_ACTIVE',
            'Reporting relationships require active memberships.')
    end
    return membership, nil
end

local function reportingCycle(tx, membershipId, managerMembershipId)
    if membershipId == managerMembershipId then return true end
    return tx.one([[SELECT 1 AS creates_cycle
        FROM synex_group_reporting_closure
        WHERE manager_membership_id = ? AND report_membership_id = ?
        LIMIT 1 FOR UPDATE]], { membershipId, managerMembershipId }) ~= nil
end

local function detachReportingSubtree(tx, membershipId)
    tx.query([[DELETE reporting_path
        FROM synex_group_reporting_closure AS reporting_path
        INNER JOIN synex_group_reporting_closure AS previous_ancestor
            ON previous_ancestor.report_membership_id = ?
            AND previous_ancestor.manager_membership_id <> ?
        INNER JOIN synex_group_reporting_closure AS reporting_subtree
            ON reporting_subtree.manager_membership_id = ?
            AND reporting_subtree.report_membership_id = reporting_path.report_membership_id
        WHERE reporting_path.manager_membership_id =
            previous_ancestor.manager_membership_id]], {
        membershipId, membershipId, membershipId
    })
end

local function attachReportingSubtree(tx, membershipId, managerMembershipId)
    tx.query([[INSERT INTO synex_group_reporting_closure
            (manager_membership_id, report_membership_id, depth)
        SELECT manager_path.manager_membership_id,
            reporting_subtree.report_membership_id,
            manager_path.depth + reporting_subtree.depth + 1
        FROM synex_group_reporting_closure AS manager_path
        CROSS JOIN synex_group_reporting_closure AS reporting_subtree
        WHERE manager_path.report_membership_id = ?
            AND reporting_subtree.manager_membership_id = ?]], {
        managerMembershipId, membershipId
    })
end

function handlers.execute.reporting_set(tx, request, runtime, context)
    local membership, membershipError = runtime.requireMembership(
        tx, request.membership_id, true)
    if not membership then return nil, membershipError end

    local _, authorizationError = runtime.authorize(
        tx, membership.group_public_id, request.actor_character_id,
        'synex.groups.reporting.manage', 'group', {
            target_membership = membership
        })
    if authorizationError then return nil, authorizationError end
    local preflight = Foundation.isCallable(runtime.completeAuthorizationPreflight)
        and runtime.completeAuthorizationPreflight(context)
    if preflight then return preflight end
    if membership.lifecycle_state ~= 'ACTIVE' then
        return nil, Foundation.domainError('MEMBERSHIP_NOT_ACTIVE',
            'Reporting relationships require active memberships.')
    end
    if tonumber(membership.version) ~= request.expected_version then
        return nil, Foundation.domainError('CONCURRENT_MODIFICATION',
            'The membership reporting relationship changed.', true)
    end

    local manager
    if request.reports_to_membership_id ~= nil then
        local managerError
        manager, managerError = requireActiveMembership(
            runtime, tx, request.reports_to_membership_id)
        if not manager then return nil, managerError end
        if manager.group_id ~= membership.group_id then
            return nil, Foundation.domainError('VALIDATION_FAILED',
                'Reporting memberships must belong to the same group.')
        end
        if reportingCycle(tx, membership.id, manager.id) then
            return nil, Foundation.domainError('REPORTING_CYCLE',
                'The reporting relationship would create a cycle.')
        end
    end

    local current = tx.one([[SELECT reporting_edge.manager_membership_id,
            reporting_edge.version,
            reporting_manager.public_id AS manager_public_id
        FROM synex_group_reporting_edges AS reporting_edge
        INNER JOIN synex_group_memberships AS reporting_manager
            ON reporting_manager.id = reporting_edge.manager_membership_id
        WHERE reporting_edge.membership_id = ? FOR UPDATE]], { membership.id })

    local changed, changeError = ensureAffected(tx,
        [[UPDATE synex_group_memberships SET version = version + 1
        WHERE id = ? AND version = ?]], {
        membership.id, request.expected_version
    }, 'The membership reporting relationship changed concurrently.')
    if not changed then return nil, changeError end

    local reasonCode = runtime.reason(request.reason, 'reporting_changed')
    if current and manager then
        local edgeChanged, edgeError = ensureAffected(tx,
            [[UPDATE synex_group_reporting_edges
            SET manager_membership_id = ?, group_id = ?, created_by_ref = ?,
                reason_code = ?, version = version + 1,
                updated_at = CURRENT_TIMESTAMP(6)
            WHERE membership_id = ? AND version = ?]], {
            manager.id, membership.group_id, request.actor_character_id,
            reasonCode, membership.id, current.version
        }, 'The reporting edge changed concurrently.')
        if not edgeChanged then return nil, edgeError end
    elseif manager then
        tx.query([[INSERT INTO synex_group_reporting_edges
            (membership_id, manager_membership_id, group_id, created_by_ref,
             reason_code, version)
            VALUES (?, ?, ?, ?, ?, 1)]], {
            membership.id, manager.id, membership.group_id,
            request.actor_character_id, reasonCode
        })
    elseif current then
        local edgeChanged, edgeError = ensureAffected(tx,
            [[DELETE FROM synex_group_reporting_edges
            WHERE membership_id = ? AND version = ?]], {
            membership.id, current.version
        }, 'The reporting edge changed concurrently.')
        if not edgeChanged then return nil, edgeError end
    end

    detachReportingSubtree(tx, membership.id)
    if manager then attachReportingSubtree(tx, membership.id, manager.id) end

    local touched, touchError = runtime.touchGroup(tx, membership.group_id)
    if not touched then return nil, touchError end
    local nextVersion = tonumber(membership.version) + 1
    local nextManagerId = manager and manager.public_id or nil
    local response = runtime.success(
        membership.public_id, 'membership_reporting',
        manager and 'assigned' or 'unassigned', nextVersion)
    return response, nil, {
        runtime.effect('membership.reporting_changed', 'membership',
            membership.public_id, membership.group_public_id,
            membership.character_id,
            { reports_to_public_id = current and current.manager_public_id or nil,
                version = membership.version },
            { reports_to_public_id = nextManagerId, version = nextVersion },
            request.reason, nextVersion)
    }
end

return handlers
end
