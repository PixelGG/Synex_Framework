return function(Foundation)
local domainError = Foundation.domainError

return function(deps)
    local jsonEncode = assert(type(deps.jsonEncode) == 'function' and deps.jsonEncode,
        'groups effect writer requires jsonEncode')
    local safeId = assert(type(deps.safeId) == 'function' and deps.safeId,
        'groups effect writer requires safeId')

    return function(tx, item, request, context)
        if type(item) ~= 'table' or type(item.action) ~= 'string'
            or type(item.entityType) ~= 'string' or not Foundation.isPublicId(item.entityId)
            or (item.groupId ~= nil and not Foundation.isPublicId(item.groupId))
            or type(item.version) ~= 'number'
            or math.type(item.version) ~= 'integer' or item.version < 1 then
            return nil, domainError('DATABASE_ERROR', 'A Groups domain effect is invalid.')
        end
        local eventId, idError = safeId('group_event')
        if not eventId then return nil, idError end
        local actor = request.actor_character_id
        local actorKind, actorRef = 'system', nil
        if Foundation.isSubjectId(actor) then
            actorKind, actorRef = 'character', actor
        elseif type(context.caller) == 'string' and #context.caller <= 48
            and context.caller:match('^[a-z][a-z0-9_]*$') then
            actorKind, actorRef = 'resource', context.caller
        end
        local beforeJson = item.before ~= nil and jsonEncode(item.before) or nil
        local afterJson = item.after ~= nil and jsonEncode(item.after) or nil
        local payload = Foundation.copyPlain(item.after or {
            entity_id = item.entityId,
            entity_type = item.entityType,
            version = item.version
        })
        payload.event_id = eventId
        if item.groupId ~= nil then payload.group_id = item.groupId end
        local contextJson = jsonEncode({
            caller = context.caller,
            traceId = context.traceId,
            operation = item.action
        })
        local historyId = tx.insert([[INSERT INTO synex_group_domain_history
            (event_id, aggregate_type, aggregate_id, aggregate_version, group_public_id, event_type,
             source_resource, actor_kind, actor_ref, reason_code, correlation_id,
             causation_id, before_json, after_json, context_json)
            VALUES (?, ?, ?, ?, ?, ?, 'synex_groups', ?, ?, ?, ?, NULL, ?, ?, ?)]], {
            eventId, item.entityType, item.entityId, item.version, item.groupId, item.eventType,
            actorKind, actorRef, item.reason,
            type(context.traceId) == 'string' and #context.traceId <= 48
                and context.traceId or nil,
            beforeJson, afterJson, contextJson
        })
        tx.query([[INSERT INTO synex_group_audit_delivery
            (history_id, state, attempts, available_at, version)
            VALUES (?, 'pending', 0, CURRENT_TIMESTAMP(6), 1)]], { historyId })
        tx.query([[INSERT INTO synex_group_outbox
            (event_id, aggregate_id, event_type, schema_version, payload_json)
            VALUES (?, ?, ?, 1, ?)]], {
            eventId, item.groupId or item.entityId, item.eventType, jsonEncode(payload)
        })
        item.historyId = historyId
        item.auditDeliveryId = historyId
        item.audit = {
            action = item.action,
            targetType = item.entityType,
            targetId = item.entityId,
            before = item.before,
            after = item.after,
            actorCharacterId = actor,
            reason = item.reason
        }
        return true, nil
    end
end
end
