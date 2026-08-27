return function(port, context)
    local Foundation = assert(type(context.Foundation) == 'table' and context.Foundation,
        'groups workers require Foundation')
    local domainError = assert(type(context.domainError) == 'function' and context.domainError,
        'groups workers require domainError')
    local jsonDecode = assert(type(context.jsonDecode) == 'function' and context.jsonDecode,
        'groups workers require jsonDecode')
    local effect = assert(type(context.effect) == 'function' and context.effect,
        'groups workers require effect')
    local nextId = assert(type(context.id) == 'function' and context.id,
        'groups workers require id')
    local writeEffect = assert(type(context.writeEffect) == 'function' and context.writeEffect,
        'groups workers require writeEffect')
    local withTransaction = assert(type(context.withTransaction) == 'function'
        and context.withTransaction, 'groups workers require withTransaction')
    local rows = assert(type(context.many) == 'function' and context.many,
        'groups workers require many')
    local update = assert(type(context.update) == 'function' and context.update,
        'groups workers require update')
    local cache = assert(type(context.cache) == 'table' and context.cache,
        'groups workers require cache')
    local maintenanceStart = 1

    function port:markAuditDelivered(historyId, externalEventId)
        if type(historyId) ~= 'number' or math.type(historyId) ~= 'integer'
            or historyId < 1 or not Foundation.isPublicId(externalEventId) then
            return nil, domainError('VALIDATION_FAILED',
                'The audit delivery acknowledgement is invalid.')
        end
        local changed = update([[UPDATE synex_group_audit_delivery
            SET state = 'delivered', external_event_id = ?,
                delivered_at = CURRENT_TIMESTAMP(6), locked_by = NULL,
                locked_until = NULL, last_error_code = NULL,
                version = version + 1
            WHERE history_id = ? AND state IN ('pending', 'delivering')]],
            { externalEventId, historyId })
        if tonumber(changed) ~= 1 then
            return nil, domainError('AUDIT_DELIVERY_CONFLICT',
                'The local audit delivery state changed before acknowledgement.', true)
        end
        return true, nil
    end

    function port:dispatchAuditBatch(claimToken, append, maximum)
        maximum = math.max(1, math.min(tonumber(maximum) or 25, 50))
        if not Foundation.isPublicId(claimToken) or type(append) ~= 'function' then
            return nil, domainError('VALIDATION_FAILED',
                'The audit dispatcher input is invalid.')
        end
        update([[UPDATE synex_group_audit_delivery
            SET state = 'pending', locked_by = NULL, locked_until = NULL,
                version = version + 1
            WHERE state = 'delivering'
                AND (locked_until IS NULL OR locked_until <= CURRENT_TIMESTAMP(6))
            ORDER BY id ASC LIMIT ?]], { maximum })
        update([[UPDATE synex_group_audit_delivery
            SET state = 'delivering', locked_by = ?,
                locked_until = TIMESTAMPADD(SECOND, 30, CURRENT_TIMESTAMP(6)),
                attempts = attempts + 1, version = version + 1
            WHERE state = 'pending' AND available_at <= CURRENT_TIMESTAMP(6)
            ORDER BY id ASC LIMIT ?]], { claimToken, maximum })
        local deliveries = rows([[SELECT delivery.history_id, delivery.attempts,
                history.event_type, history.aggregate_type, history.aggregate_id,
                history.before_json, history.after_json, history.context_json
            FROM synex_group_audit_delivery AS delivery
            INNER JOIN synex_group_domain_history AS history
                ON history.id = delivery.history_id
            WHERE delivery.state = 'delivering' AND delivery.locked_by = ?
            ORDER BY delivery.id ASC LIMIT ?]], { claimToken, maximum })
        local report = {
            claimed = #deliveries,
            delivered = 0,
            retried = 0,
            dead = 0
        }
        local function decodeOptional(value)
            if value == nil then return nil end
            local decodedOk, decoded = pcall(jsonDecode, value)
            if not decodedOk then return nil end
            local copiedOk, copied = pcall(Foundation.copyPlain, decoded)
            return copiedOk and copied or nil
        end
        for _, row in ipairs(deliveries) do
            local appended, appendError = append({
                action = row.event_type:gsub('^synex%.groups%.', ''),
                targetType = row.aggregate_type,
                targetId = row.aggregate_id,
                before = decodeOptional(row.before_json),
                after = decodeOptional(row.after_json),
                context = decodeOptional(row.context_json) or {}
            })
            local externalEventId = type(appended) == 'table' and appended.eventId or nil
            if Foundation.isPublicId(externalEventId) and appendError == nil then
                update([[UPDATE synex_group_audit_delivery
                    SET state = 'delivered', external_event_id = ?,
                        delivered_at = CURRENT_TIMESTAMP(6), locked_by = NULL,
                        locked_until = NULL, last_error_code = NULL,
                        version = version + 1
                    WHERE history_id = ? AND state = 'delivering' AND locked_by = ?]],
                    { externalEventId, row.history_id, claimToken })
                report.delivered = report.delivered + 1
            else
                local attempts = tonumber(row.attempts) or 1
                local dead = attempts >= 10
                local code = type(appendError) == 'table'
                    and tostring(appendError.code or 'AUDIT_APPEND_FAILED')
                    or 'AUDIT_APPEND_FAILED'
                if not code:match('^[A-Z][A-Z0-9_]*$') then
                    code = 'AUDIT_APPEND_FAILED'
                end
                update([[UPDATE synex_group_audit_delivery
                    SET state = ?, available_at = TIMESTAMPADD(SECOND, ?, CURRENT_TIMESTAMP(6)),
                        last_error_code = ?, locked_by = NULL, locked_until = NULL,
                        version = version + 1
                    WHERE history_id = ? AND state = 'delivering' AND locked_by = ?]], {
                    dead and 'dead' or 'pending',
                    math.min(300, 2 ^ math.min(attempts, 8)),
                    code:sub(1, 64), row.history_id, claimToken
                })
                if dead then
                    report.dead = report.dead + 1
                else
                    report.retried = report.retried + 1
                end
            end
        end
        return report, nil
    end

    function port:maintain(options)
        local maximum = math.max(1,
            math.min(tonumber(options and options.maximum) or 100, 500))
        local counters = {
            roles = 0, delegations = 0, invitations = 0,
            applications = 0, assignments = 0, proposals = 0,
            relationships = 0
        }
        local traceId, traceError = nextId('group_maintenance')
        if not traceId then return nil, traceError end
        local specs = {
            {
                counter = 'roles', action = 'role.expired', entityType = 'role_assignment',
                reason = 'role_window_expired',
                select = [[SELECT assignment.id, assignment.public_id, assignment.version,
                        assignment.status,
                        group_record.public_id AS group_public_id,
                        profile.character_id
                    FROM synex_group_membership_roles AS assignment
                    INNER JOIN synex_group_memberships AS membership
                        ON membership.id = assignment.membership_id
                    INNER JOIN synex_group_membership_profiles AS profile
                        ON profile.membership_id = membership.id
                    INNER JOIN synex_groups AS group_record
                        ON group_record.id = membership.group_id
                    WHERE assignment.status = 'active'
                        AND assignment.valid_until IS NOT NULL
                        AND assignment.valid_until <= CURRENT_TIMESTAMP(6)
                    ORDER BY assignment.id ASC LIMIT ? FOR UPDATE]],
                update = [[UPDATE synex_group_membership_roles
                    SET status = 'expired', revoked_at = CURRENT_TIMESTAMP(6),
                        reason_code = 'role_window_expired', version = version + 1
                    WHERE id = ? AND status = 'active' AND version = ?]]
            },
            {
                counter = 'delegations', action = 'delegation.expired',
                entityType = 'delegation', reason = 'delegation_window_expired',
                select = [[SELECT delegation.id, delegation.public_id, delegation.version,
                        delegation.status,
                        group_record.public_id AS group_public_id,
                        profile.character_id
                    FROM synex_group_delegations AS delegation
                    INNER JOIN synex_groups AS group_record
                        ON group_record.id = delegation.group_id
                    INNER JOIN synex_group_memberships AS membership
                        ON membership.id = delegation.grantee_membership_id
                    INNER JOIN synex_group_membership_profiles AS profile
                        ON profile.membership_id = membership.id
                    WHERE delegation.status = 'active'
                        AND delegation.valid_until <= CURRENT_TIMESTAMP(6)
                    ORDER BY delegation.id ASC LIMIT ? FOR UPDATE]],
                update = [[UPDATE synex_group_delegations
                    SET status = 'expired', revoked_at = CURRENT_TIMESTAMP(6),
                        reason_code = 'delegation_window_expired', version = version + 1
                    WHERE id = ? AND status = 'active' AND version = ?]]
            },
            {
                counter = 'invitations', action = 'membership.invitation_expired',
                entityType = 'invitation', reason = 'invitation_window_expired',
                select = [[SELECT invitation.id, invitation.public_id, invitation.version,
                        invitation.status,
                        invitation.character_id, invitation.membership_id,
                        membership.public_id AS membership_public_id,
                        membership.version AS membership_version,
                        member_profile.lifecycle_state AS membership_lifecycle,
                        member_profile.version AS membership_profile_version,
                        group_record.public_id AS group_public_id
                    FROM synex_group_invitations AS invitation
                    INNER JOIN synex_groups AS group_record
                        ON group_record.id = invitation.group_id
                    INNER JOIN synex_group_memberships AS membership
                        ON membership.id = invitation.membership_id
                        AND membership.group_id = invitation.group_id
                        AND membership.subject_kind = 'character'
                    INNER JOIN synex_group_membership_profiles AS member_profile
                        ON member_profile.membership_id = membership.id
                        AND member_profile.group_id = invitation.group_id
                        AND member_profile.character_id = invitation.character_id
                    WHERE invitation.status = 'pending'
                        AND invitation.expires_at <= CURRENT_TIMESTAMP(6)
                    ORDER BY invitation.id ASC LIMIT ? FOR UPDATE]],
                update = [[UPDATE synex_group_invitations
                    SET status = 'expired', responded_at = CURRENT_TIMESTAMP(6),
                        reason_code = 'invitation_window_expired', version = version + 1
                    WHERE id = ? AND status = 'pending' AND version = ?]]
            },
            {
                counter = 'applications', action = 'application.expired',
                entityType = 'application', reason = 'application_window_expired',
                select = [[SELECT application.id, application.public_id,
                        application.version, application.status,
                        CASE WHEN application.status = 'reviewing'
                            THEN 'under_review' ELSE application.status
                        END AS public_status,
                        application.character_id, application.membership_id,
                        membership.public_id AS membership_public_id,
                        membership.version AS membership_version,
                        member_profile.lifecycle_state AS membership_lifecycle,
                        member_profile.version AS membership_profile_version,
                        group_record.public_id AS group_public_id
                    FROM synex_group_applications AS application
                    INNER JOIN synex_groups AS group_record
                        ON group_record.id = application.group_id
                    INNER JOIN synex_group_memberships AS membership
                        ON membership.id = application.membership_id
                        AND membership.group_id = application.group_id
                        AND membership.subject_kind = 'character'
                    INNER JOIN synex_group_membership_profiles AS member_profile
                        ON member_profile.membership_id = membership.id
                        AND member_profile.group_id = application.group_id
                        AND member_profile.character_id = application.character_id
                    WHERE application.status IN ('submitted', 'reviewing')
                        AND application.expires_at <= CURRENT_TIMESTAMP(6)
                    ORDER BY application.id ASC LIMIT ? FOR UPDATE]],
                update = [[UPDATE synex_group_applications
                    SET status = 'expired', reviewed_at = CURRENT_TIMESTAMP(6),
                        review_reason_code = 'application_window_expired',
                        version = version + 1
                    WHERE id = ? AND status IN ('submitted', 'reviewing')
                        AND version = ?]]
            },
            {
                counter = 'assignments', action = 'assignment.expired',
                entityType = 'assignment', reason = 'assignment_window_expired',
                select = [[SELECT assignment.id, assignment.public_id, assignment.version,
                        assignment.status,
                        group_record.public_id AS group_public_id
                    FROM synex_group_assignments AS assignment
                    INNER JOIN synex_groups AS group_record
                        ON group_record.id = assignment.group_id
                    WHERE assignment.status = 'active'
                        AND assignment.valid_until IS NOT NULL
                        AND assignment.valid_until <= CURRENT_TIMESTAMP(6)
                    ORDER BY assignment.id ASC LIMIT ? FOR UPDATE]],
                update = [[UPDATE synex_group_assignments
                    SET status = 'expired', version = version + 1
                    WHERE id = ? AND status = 'active' AND version = ?]]
            },
            {
                counter = 'proposals', action = 'proposal.expired',
                entityType = 'proposal', reason = 'proposal_window_expired',
                select = [[SELECT proposal.id, proposal.public_id, proposal.version,
                        proposal.status,
                        group_record.public_id AS group_public_id
                    FROM synex_group_proposals AS proposal
                    INNER JOIN synex_groups AS group_record
                        ON group_record.id = proposal.group_id
                    WHERE proposal.status IN ('pending', 'approved')
                        AND proposal.expires_at <= CURRENT_TIMESTAMP(6)
                    ORDER BY proposal.id ASC LIMIT ? FOR UPDATE]],
                update = [[UPDATE synex_group_proposals
                    SET status = 'expired', reason_code = 'proposal_window_expired',
                        version = version + 1
                    WHERE id = ? AND status IN ('pending', 'approved') AND version = ?]]
            },
            {
                counter = 'relationships', action = 'relationship.expired',
                entityType = 'relationship', reason = 'relationship_window_expired',
                afterStatus = 'ended',
                select = [[SELECT relationship.id, relationship.public_id,
                        relationship.version, relationship.status,
                        relationship.source_group_id, relationship.target_group_id,
                        DATE_FORMAT(relationship.valid_until,
                            '%Y-%m-%dT%H:%i:%s.%fZ') AS valid_until,
                        source.public_id AS group_public_id,
                        target.public_id AS target_group_public_id
                    FROM synex_group_relationships AS relationship
                    INNER JOIN synex_groups AS source
                        ON source.id = relationship.source_group_id
                    INNER JOIN synex_groups AS target
                        ON target.id = relationship.target_group_id
                    WHERE relationship.status IN ('active', 'suspended')
                        AND relationship.valid_until IS NOT NULL
                        AND relationship.valid_until <= CURRENT_TIMESTAMP(6)
                    ORDER BY relationship.id ASC LIMIT ? FOR UPDATE]],
                update = [[UPDATE synex_group_relationships
                    SET status = 'ended', ended_at = valid_until,
                        reason_code = 'relationship_window_expired',
                        version = version + 1
                    WHERE id = ? AND status IN ('active', 'suspended') AND version = ?]]
            }
        }
        local startIndex = maintenanceStart
        maintenanceStart = maintenanceStart % #specs + 1
        local remaining = maximum
        local committed, maintenanceError = withTransaction(function(tx)
            for offset = 0, #specs - 1 do
                if remaining <= 0 then break end
                local spec = specs[(startIndex + offset - 1) % #specs + 1]
                local expired = tx.many(spec.select, { remaining })
                for _, row in ipairs(expired) do
                    if remaining <= 0 then break end
                    local version = tonumber(row.version)
                    if not version or math.type(version) ~= 'integer' or version < 1
                        or not Foundation.isPublicId(row.public_id)
                        or not Foundation.isPublicId(row.group_public_id) then
                        return nil, domainError('DATABASE_RESULT_INVALID',
                            'The Groups maintenance query returned an invalid entity.', true)
                    end
                    local relationshipSourceGroupId, relationshipTargetGroupId
                    if spec.counter == 'relationships' then
                        relationshipSourceGroupId = tonumber(row.source_group_id)
                        relationshipTargetGroupId = tonumber(row.target_group_id)
                        if not relationshipSourceGroupId
                            or math.type(relationshipSourceGroupId) ~= 'integer'
                            or relationshipSourceGroupId < 1 or not relationshipTargetGroupId
                            or math.type(relationshipTargetGroupId) ~= 'integer'
                            or relationshipTargetGroupId < 1
                            or relationshipSourceGroupId == relationshipTargetGroupId
                            or not Foundation.isPublicId(row.target_group_public_id) then
                            return nil, domainError('DATABASE_RESULT_INVALID',
                                'The relationship maintenance query returned an invalid edge.', true)
                        end
                    end
                    local workflowMembershipVersion, workflowProfileVersion
                    local workflowMembershipState
                    if spec.counter == 'invitations' or spec.counter == 'applications' then
                        local membershipId = tonumber(row.membership_id)
                        workflowMembershipVersion = tonumber(row.membership_version)
                        workflowProfileVersion = tonumber(row.membership_profile_version)
                        workflowMembershipState = row.membership_lifecycle
                        local expectedState = spec.counter == 'invitations' and 'INVITED'
                            or row.public_status == 'under_review'
                                and 'UNDER_REVIEW' or 'APPLICANT'
                        if not membershipId or math.type(membershipId) ~= 'integer'
                            or membershipId < 1
                            or not Foundation.isPublicId(row.membership_public_id)
                            or not workflowMembershipVersion
                            or math.type(workflowMembershipVersion) ~= 'integer'
                            or workflowMembershipVersion < 1
                            or not workflowProfileVersion
                            or math.type(workflowProfileVersion) ~= 'integer'
                            or workflowProfileVersion < 1
                            or workflowMembershipState ~= expectedState then
                            return nil, domainError('DATABASE_RESULT_INVALID',
                                'The expiring workflow membership is invalid.', true)
                        end
                    end
                    local assignmentMembersRemoved, dutySessionsClosed = 0, 0
                    if spec.counter == 'assignments' then
                        local dutyEventsWritten = tx.affected([[INSERT INTO synex_group_duty_events
                            (event_id, duty_session_id, session_version, event_type,
                             state_key, actor_ref, reason_code, assignment_id, metadata_json)
                            SELECT CONCAT('group_devent_', SUBSTRING(SHA2(CONCAT(
                                    'synex:assignment:', session.public_id, ':expired:',
                                    session.version + 1), 256), 1, 35)),
                                session.id, session.version + 1, 'ended', session.state_key,
                                NULL, 'assignment_window_expired', session.assignment_id,
                                session.metadata_json
                            FROM synex_group_duty_sessions AS session
                            WHERE session.assignment_id = ? AND session.status = 'open'
                            ORDER BY session.id ASC]], { row.id })
                        dutySessionsClosed = tx.affected([[UPDATE synex_group_duty_sessions
                            SET status = 'closed', ended_at = CURRENT_TIMESTAMP(6),
                                reason_code = 'assignment_window_expired',
                                version = version + 1
                            WHERE assignment_id = ? AND status = 'open']], { row.id })
                        if dutyEventsWritten ~= dutySessionsClosed then
                            return nil, domainError('DATABASE_ERROR',
                                'Expired assignment duty history could not be closed atomically.',
                                true)
                        end
                        assignmentMembersRemoved = tx.affected([[UPDATE synex_group_assignment_members
                            SET status = 'removed', left_at = CURRENT_TIMESTAMP(6),
                                reason_code = 'assignment_window_expired',
                                version = version + 1
                            WHERE assignment_id = ? AND status = 'active']], { row.id })
                    end
                    local changed = tx.affected(spec.update, { row.id, version })
                    if changed ~= 1 then
                        return nil, domainError('CONCURRENT_MODIFICATION',
                            'An expiring Groups entity changed during maintenance.', true)
                    end
                    if spec.counter == 'invitations' or spec.counter == 'applications' then
                        local membershipChanged = tx.affected([[UPDATE synex_group_memberships
                            SET status = 'active', version = version + 1
                            WHERE id = ? AND version = ?]], {
                            row.membership_id, workflowMembershipVersion
                        })
                        local profileChanged = tx.affected([[UPDATE synex_group_membership_profiles
                            SET lifecycle_state = 'DRAFT', visibility = 'hidden',
                                joined_at = NULL, suspended_at = NULL, left_at = NULL,
                                lifecycle_reason_code = ?, version = version + 1
                            WHERE membership_id = ? AND lifecycle_state = ?
                                AND version = ?]], {
                            spec.reason, row.membership_id, workflowMembershipState,
                            workflowProfileVersion
                        })
                        if membershipChanged ~= 1 or profileChanged ~= 1 then
                            return nil, domainError('CONCURRENT_MODIFICATION',
                                'The expiring workflow membership changed concurrently.', true)
                        end
                        local eventWritten = tx.affected([[INSERT INTO
                                synex_group_membership_events
                            (event_id, membership_id, membership_version, event_type,
                             actor_ref, snapshot_json)
                            SELECT CONCAT('group_mevent_', SUBSTRING(SHA2(CONCAT(
                                    'workflow-expired:', membership.public_id, ':',
                                    membership.version), 256), 1, 32)),
                                membership.id, membership.version, 'transitioned', NULL,
                                JSON_OBJECT(
                                    'membership_id', membership.public_id,
                                    'group_id', ?,
                                    'character_id', profile.character_id,
                                    'lifecycle_state', profile.lifecycle_state,
                                    'version', membership.version
                                )
                            FROM synex_group_memberships AS membership
                            INNER JOIN synex_group_membership_profiles AS profile
                                ON profile.membership_id = membership.id
                            WHERE membership.id = ? AND membership.version = ?]], {
                            row.group_public_id, row.membership_id,
                            workflowMembershipVersion + 1
                        })
                        if eventWritten ~= 1 then
                            return nil, domainError('DATABASE_ERROR',
                                'The workflow membership expiry history could not be written.', true)
                        end
                    end
                    if spec.counter == 'relationships' then
                        local invalidated = tx.affected([[UPDATE synex_group_read_model_versions
                            SET model_version = model_version + 1,
                                invalidated_at = CURRENT_TIMESTAMP(6)
                            WHERE group_id IN (?, ?)]], {
                            relationshipSourceGroupId, relationshipTargetGroupId
                        })
                        if invalidated ~= 2 then
                            return nil, domainError('DATABASE_RESULT_INVALID',
                                'Both relationship organization read models must be invalidated.', true)
                        end
                    end
                    local after = {
                        status = spec.afterStatus or 'expired', version = version + 1
                    }
                    if spec.counter == 'assignments' then
                        after.members_removed = assignmentMembersRemoved
                        after.duty_sessions_closed = dutySessionsClosed
                    elseif spec.counter == 'relationships' then
                        after.source_group_id = row.group_public_id
                        after.target_group_id = row.target_group_public_id
                        after.valid_until = row.valid_until
                        after.ended_at = row.valid_until
                    end
                    local before = {
                        status = row.public_status or row.status, version = version
                    }
                    if spec.counter == 'relationships' then
                        before.source_group_id = row.group_public_id
                        before.target_group_id = row.target_group_public_id
                        before.valid_until = row.valid_until
                    end
                    local item = effect(spec.action, spec.entityType, row.public_id,
                        row.group_public_id, row.character_id,
                        before, after, spec.reason, version + 1)
                    local written, writeError = writeEffect(tx, item, {}, {
                        caller = 'synex_groups', traceId = traceId
                    })
                    if not written then return nil, writeError end
                    if spec.counter == 'invitations' or spec.counter == 'applications' then
                        local membershipItem = effect('membership.draft', 'membership',
                            row.membership_public_id, row.group_public_id,
                            row.character_id,
                            { status = workflowMembershipState,
                                version = workflowMembershipVersion },
                            { status = 'DRAFT', version = workflowMembershipVersion + 1 },
                            spec.reason, workflowMembershipVersion + 1)
                        local membershipWritten, membershipWriteError = writeEffect(
                            tx, membershipItem, {}, {
                                caller = 'synex_groups', traceId = traceId
                            })
                        if not membershipWritten then return nil, membershipWriteError end
                    end
                    counters[spec.counter] = counters[spec.counter] + 1
                    remaining = remaining - 1
                end
            end
            return true, nil
        end)
        if not committed then return nil, maintenanceError end
        local changed = maximum - remaining
        if changed > 0 then
            cache:invalidate()
        end
        counters.total = changed
        return counters, nil
    end
end
