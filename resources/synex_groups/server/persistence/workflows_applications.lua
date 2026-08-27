return function(Foundation)
local Shared = require('server.persistence.workflows_shared')(Foundation)
local MembershipShared = require('server.persistence.memberships_shared')(Foundation)
local identifier = Shared.identifier
local updateOne = Shared.updateOne
local materializeWorkflowMembership = MembershipShared.materializeWorkflowMembership
local transitionWorkflowMembership = MembershipShared.transitionWorkflowMembership
local activateWorkflowMembership = MembershipShared.activateWorkflowMembership
local handlers = { read = {}, execute = {} }

local function publicState(value)
    return value == 'reviewing' and 'under_review' or value
end

function handlers.execute.applications_submit(tx, request, runtime, context)
    local preflight = Foundation.isCallable(runtime.completeAuthorizationPreflight)
        and runtime.completeAuthorizationPreflight(context)
    if preflight then return preflight end
    local group, groupError = runtime.requireGroup(tx, request.group_id, true)
    if not group then return nil, groupError end
    if group.status ~= 'active' or group.lifecycle_state ~= 'ACTIVE' then
        return nil, Foundation.domainError('GROUP_INACTIVE',
            'Applications require an active group.')
    end
    local schemaVersion = tonumber(group.type_schema_version)
    if not schemaVersion or type(group.type_metadata_json) ~= 'string' then
        return nil, Foundation.domainError('VALIDATION_FAILED',
            'The group type does not have a registered application schema.')
    end
    if request.schema_version ~= schemaVersion then
        return nil, Foundation.domainError('CONCURRENT_MODIFICATION',
            'The application schema version does not match the current group type.',
            true, { current_schema_version = schemaVersion })
    end
    local metadataOk, metadataValue = pcall(runtime.jsonDecode,
        group.type_metadata_json or '{}')
    local copiedOk, metadata = false, nil
    if metadataOk then
        copiedOk, metadata = pcall(Foundation.copyPlain, metadataValue, {
            maximumDepth = 8,
            maximumKeys = 128,
            maximumStringBytes = 4096,
            preserveContainerKind = false
        })
    end
    if not metadataOk or not copiedOk or type(metadata) ~= 'table' then
        return nil, Foundation.domainError('DATABASE_ERROR',
            'The stored group type metadata is invalid.', true)
    end
    if metadata.application_schema == nil then
        return nil, Foundation.domainError('VALIDATION_FAILED',
            'The group type does not accept applications without a registered schema.')
    end
    local applicationData, applicationError = runtime.applicationSchemas.validateData(
        metadata.application_schema, request.data)
    if not applicationData then return nil, applicationError end
    group.public_id = group.public_id or request.group_id
    local staleEffect
    local staleMembershipEffect
    local existing = tx.one([[SELECT application.id, application.public_id,
            application.membership_id, application.status, application.version,
            membership.public_id AS membership_public_id,
            membership.version AS membership_version,
            member_profile.lifecycle_state AS membership_lifecycle,
            member_profile.version AS membership_profile_version,
            CASE WHEN application.expires_at <= CURRENT_TIMESTAMP(6)
                THEN 1 ELSE 0 END AS expired
        FROM synex_group_applications AS application
        INNER JOIN synex_group_memberships AS membership
            ON membership.id = application.membership_id
            AND membership.group_id = application.group_id
            AND membership.subject_kind = 'character'
        INNER JOIN synex_group_membership_profiles AS member_profile
            ON member_profile.membership_id = membership.id
            AND member_profile.group_id = application.group_id
            AND member_profile.character_id = application.character_id
        WHERE application.group_id = ? AND application.character_id = ?
            AND application.status IN ('submitted', 'reviewing') FOR UPDATE]], {
        group.id, request.actor_character_id
    })
    if existing then
        if tonumber(existing.expired) ~= 1 then
            return nil, Foundation.domainError('IDEMPOTENCY_CONFLICT',
                'An open application already exists.')
        end
        local expectedMembershipState = existing.status == 'reviewing'
            and 'UNDER_REVIEW' or 'APPLICANT'
        if existing.membership_lifecycle ~= expectedMembershipState then
            return nil, Foundation.domainError('CONCURRENT_MODIFICATION',
                'The expired application membership lifecycle changed.', true)
        end
        local expired, expireError = updateOne(tx, [[UPDATE synex_group_applications
            SET status = 'expired', reviewed_at = CURRENT_TIMESTAMP(6),
                review_reason_code = 'application_window_expired',
                version = version + 1
            WHERE id = ? AND status IN ('submitted', 'reviewing')
                AND version = ?]], { existing.id, existing.version })
        if not expired then return nil, expireError end
        staleEffect = runtime.effect('application.expired', 'application',
            existing.public_id, request.group_id, request.actor_character_id,
            { status = publicState(existing.status), version = existing.version },
            { status = 'expired', version = tonumber(existing.version) + 1 },
            'application_window_expired', tonumber(existing.version) + 1)
        local resetMembership, resetError
        resetMembership, resetError, staleMembershipEffect = transitionWorkflowMembership(
            tx, runtime, {
                id = existing.membership_id,
                public_id = existing.membership_public_id,
                group_id = group.id,
                group_public_id = request.group_id,
                character_id = request.actor_character_id,
                lifecycle_state = existing.membership_lifecycle,
                version = tonumber(existing.membership_version),
                profile_version = tonumber(existing.membership_profile_version)
            }, 'DRAFT', 'application_window_expired', request.actor_character_id, false)
        if not resetMembership then return nil, resetError end
    end
    local membership, membershipError, membershipEffect = materializeWorkflowMembership(
        tx, runtime, group, request.actor_character_id, 'APPLICANT',
        'application_submitted', request.actor_character_id)
    if not membership then return nil, membershipError end
    local applicationId, idError = identifier(runtime, 'group_apply')
    if not applicationId then return nil, idError end
    tx.query([[INSERT INTO synex_group_applications
        (public_id, group_id, character_id, membership_id, status, application_json,
         reviewed_by_membership_id, review_reason_code, reviewed_at,
         version, schema_version, expires_at)
        VALUES (?, ?, ?, ?, 'submitted', ?, NULL, NULL, NULL, 1, ?,
            TIMESTAMPADD(DAY, 30, CURRENT_TIMESTAMP(6)))]], {
        applicationId, group.id, request.actor_character_id, membership.id,
        runtime.jsonEncode(applicationData), request.schema_version
    })
    local response = runtime.success(applicationId, 'application', 'submitted', 1)
    local effects = {}
    if staleEffect then effects[#effects + 1] = staleEffect end
    if staleMembershipEffect then effects[#effects + 1] = staleMembershipEffect end
    if membershipEffect then effects[#effects + 1] = membershipEffect end
    effects[#effects + 1] = runtime.effect('application.submitted', 'application',
        applicationId, request.group_id, request.actor_character_id, nil,
        { schema_version = request.schema_version, status = 'submitted',
            version = 1 },
        'application_submitted', 1)
    return response, nil, effects
end

function handlers.execute.applications_review(tx, request, runtime, context)
    local application = tx.one([[SELECT application.id, application.public_id,
            application.group_id, application.character_id, application.membership_id,
            application.status, application.version,
            group_record.public_id AS group_public_id,
            group_record.status AS group_status,
            organization.lifecycle_state AS group_lifecycle,
            membership.public_id AS membership_public_id,
            membership.version AS membership_version,
            member_profile.lifecycle_state AS membership_lifecycle,
            member_profile.version AS membership_profile_version,
            CASE WHEN application.expires_at > CURRENT_TIMESTAMP(6)
                THEN 1 ELSE 0 END AS inside_window
        FROM synex_group_applications AS application
        INNER JOIN synex_groups AS group_record ON group_record.id = application.group_id
        INNER JOIN synex_group_organization_profiles AS organization
            ON organization.group_id = group_record.id
        INNER JOIN synex_group_memberships AS membership
            ON membership.id = application.membership_id
            AND membership.group_id = application.group_id
            AND membership.subject_kind = 'character'
        INNER JOIN synex_group_membership_profiles AS member_profile
            ON member_profile.membership_id = membership.id
            AND member_profile.group_id = application.group_id
            AND member_profile.character_id = application.character_id
        WHERE application.public_id = ? FOR UPDATE]], { request.application_id })
    if not application then
        return nil, Foundation.domainError('MEMBERSHIP_NOT_FOUND',
            'The membership application does not exist.')
    end
    local reviewer, authorizationError = runtime.authorize(
        tx, application.group_public_id, request.actor_character_id,
        'synex.groups.applications.review', 'group')
    if not reviewer then return nil, authorizationError end
    local preflight = Foundation.isCallable(runtime.completeAuthorizationPreflight)
        and runtime.completeAuthorizationPreflight(context)
    if preflight then return preflight end
    if application.group_status ~= 'active'
        or application.group_lifecycle ~= 'ACTIVE' then
        return nil, Foundation.domainError('GROUP_INACTIVE',
            'Applications can only be reviewed for an active group.')
    end
    if tonumber(application.inside_window) ~= 1 then
        return nil, Foundation.domainError('INVALID_TRANSITION',
            'The application review window has expired.')
    end
    local publicDecision = request.decision:lower()
    local decision = publicDecision == 'under_review' and 'reviewing' or publicDecision
    if decision ~= 'reviewing' and decision ~= 'approved' and decision ~= 'rejected' then
        return nil, Foundation.domainError('INVALID_TRANSITION',
            'Application decision must be under_review, approved, or rejected.')
    end
    if (application.status ~= 'submitted' and application.status ~= 'reviewing')
        or tonumber(application.version) ~= request.expected_version then
        return nil, Foundation.domainError('CONCURRENT_MODIFICATION',
            'The application changed before review.', true)
    end
    if decision == 'reviewing' and application.status ~= 'submitted' then
        return nil, Foundation.domainError('INVALID_TRANSITION',
            'Only a submitted application can enter review.')
    end
    if decision ~= 'reviewing' and application.status ~= 'reviewing' then
        return nil, Foundation.domainError('INVALID_TRANSITION',
            'An application must enter review before a terminal decision.')
    end
    local expectedMembershipState = application.status == 'submitted'
        and 'APPLICANT' or 'UNDER_REVIEW'
    if application.membership_lifecycle ~= expectedMembershipState then
        return nil, Foundation.domainError('CONCURRENT_MODIFICATION',
            'The durable membership lifecycle no longer matches the application.', true)
    end

    local nextVersion = tonumber(application.version) + 1
    local reviewReason = runtime.reason(request.reason, 'application_reviewed')
    local changed, changeError
    if decision == 'reviewing' then
        changed, changeError = updateOne(tx, [[UPDATE synex_group_applications
            SET status = 'reviewing', reviewed_by_membership_id = ?,
                review_reason_code = NULL, reviewed_at = NULL,
                version = version + 1
            WHERE id = ? AND status = 'submitted' AND version = ?]], {
            reviewer.id, application.id, request.expected_version
        })
    else
        changed, changeError = updateOne(tx, [[UPDATE synex_group_applications
            SET status = ?, reviewed_by_membership_id = ?, review_reason_code = ?,
                reviewed_at = CURRENT_TIMESTAMP(6), version = version + 1
            WHERE id = ? AND status = 'reviewing' AND version = ?]], {
            decision, reviewer.id, reviewReason,
            application.id, request.expected_version
        })
    end
    if not changed then return nil, changeError end

    local membership = {
        id = application.membership_id,
        public_id = application.membership_public_id,
        group_id = application.group_id,
        group_public_id = application.group_public_id,
        character_id = application.character_id,
        lifecycle_state = application.membership_lifecycle,
        version = tonumber(application.membership_version),
        profile_version = tonumber(application.membership_profile_version)
    }
    local membershipEffects = {}
    local target = decision == 'reviewing' and 'UNDER_REVIEW'
        or decision == 'approved' and 'APPROVED' or 'DRAFT'
    local transitioned, transitionError, transitionEffect = transitionWorkflowMembership(
        tx, runtime, membership, target, reviewReason,
        request.actor_character_id, false)
    if not transitioned then return nil, transitionError end
    membership = transitioned
    if transitionEffect then membershipEffects[#membershipEffects + 1] = transitionEffect end

    if decision == 'approved' then
        local grade = tx.one([[SELECT grade.id, grade.public_id, grade.grade_key,
                control.member_limit
            FROM synex_group_grades AS grade
            LEFT JOIN synex_group_grade_controls AS control ON control.grade_id = grade.id
            WHERE grade.group_id = ? AND grade.status = 'active'
                AND grade.grade_key <> 'owner'
            ORDER BY grade.rank_value ASC, grade.id ASC LIMIT 1 FOR UPDATE]],
            { application.group_id })
        if not grade then
            return nil, Foundation.domainError('GRADE_NOT_FOUND',
                'The group has no default active grade.')
        end
        local activated, activationError, activationEffect = activateWorkflowMembership(
            tx, runtime, membership, grade, request.actor_character_id,
            'application_approved')
        if not activated then return nil, activationError end
        membership = activated
        if activationEffect then membershipEffects[#membershipEffects + 1] = activationEffect end
    end

    local touched, touchError = runtime.touchGroup(tx, application.group_id)
    if not touched then return nil, touchError end
    local responseStatus = publicState(decision)
    local response = runtime.success(
        application.public_id, 'application', responseStatus, nextVersion)
    local effects = membershipEffects
    effects[#effects + 1] = runtime.effect('application.' .. responseStatus, 'application',
        application.public_id, application.group_public_id,
        application.character_id,
        { status = publicState(application.status), version = application.version },
        response, request.reason, nextVersion)
    return response, nil, effects
end

function handlers.execute.applications_withdraw(tx, request, runtime, context)
    local application = tx.one([[SELECT application.id, application.public_id,
            application.group_id, application.character_id, application.membership_id,
            application.status,
            application.version, group_record.public_id AS group_public_id,
            membership.public_id AS membership_public_id,
            membership.version AS membership_version,
            member_profile.lifecycle_state AS membership_lifecycle,
            member_profile.version AS membership_profile_version,
            CASE WHEN application.expires_at > CURRENT_TIMESTAMP(6)
                THEN 1 ELSE 0 END AS inside_window
        FROM synex_group_applications AS application
        INNER JOIN synex_groups AS group_record ON group_record.id = application.group_id
        INNER JOIN synex_group_memberships AS membership
            ON membership.id = application.membership_id
            AND membership.group_id = application.group_id
            AND membership.subject_kind = 'character'
        INNER JOIN synex_group_membership_profiles AS member_profile
            ON member_profile.membership_id = membership.id
            AND member_profile.group_id = application.group_id
            AND member_profile.character_id = application.character_id
        WHERE application.public_id = ? FOR UPDATE]], { request.application_id })
    if not application then
        return nil, Foundation.domainError('MEMBERSHIP_NOT_FOUND',
            'The membership application does not exist.')
    end
    if application.character_id ~= request.actor_character_id then
        return nil, Foundation.domainError('INSUFFICIENT_PERMISSION',
            'Only the applicant may withdraw this application.')
    end
    local preflight = Foundation.isCallable(runtime.completeAuthorizationPreflight)
        and runtime.completeAuthorizationPreflight(context)
    if preflight then return preflight end
    if application.status ~= 'submitted' and application.status ~= 'reviewing' then
        return nil, Foundation.domainError('INVALID_TRANSITION',
            'Only an open application can be withdrawn.')
    end
    if tonumber(application.inside_window) ~= 1 then
        return nil, Foundation.domainError('INVALID_TRANSITION',
            'The application withdrawal window has expired.')
    end
    if tonumber(application.version) ~= request.expected_version then
        return nil, Foundation.domainError('CONCURRENT_MODIFICATION',
            'The application changed before withdrawal.', true)
    end
    local expectedMembershipState = application.status == 'reviewing'
        and 'UNDER_REVIEW' or 'APPLICANT'
    if application.membership_lifecycle ~= expectedMembershipState then
        return nil, Foundation.domainError('CONCURRENT_MODIFICATION',
            'The durable membership lifecycle no longer matches the application.', true)
    end
    local changed, changeError = updateOne(tx, [[UPDATE synex_group_applications
        SET status = 'withdrawn', review_reason_code = ?,
            reviewed_at = CURRENT_TIMESTAMP(6), version = version + 1
        WHERE id = ? AND status IN ('submitted', 'reviewing') AND version = ?]], {
        runtime.reason(request.reason, 'application_withdrawn'),
        application.id, request.expected_version
    })
    if not changed then return nil, changeError end
    local membership, membershipError, membershipEffect = transitionWorkflowMembership(
        tx, runtime, {
            id = application.membership_id,
            public_id = application.membership_public_id,
            group_id = application.group_id,
            group_public_id = application.group_public_id,
            character_id = application.character_id,
            lifecycle_state = application.membership_lifecycle,
            version = tonumber(application.membership_version),
            profile_version = tonumber(application.membership_profile_version)
        }, 'DRAFT', runtime.reason(request.reason, 'application_withdrawn'),
        request.actor_character_id, false)
    if not membership then return nil, membershipError end
    local touched, touchError = runtime.touchGroup(tx, application.group_id)
    if not touched then return nil, touchError end
    local nextVersion = tonumber(application.version) + 1
    local response = runtime.success(
        application.public_id, 'application', 'withdrawn', nextVersion)
    local effects = {
        runtime.effect('application.withdrawn', 'application',
            application.public_id, application.group_public_id,
            application.character_id,
            { status = publicState(application.status), version = application.version },
            response, request.reason, nextVersion)
    }
    if membershipEffect then effects[#effects + 1] = membershipEffect end
    return response, nil, effects
end

return handlers
end
