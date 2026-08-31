SynexSecurityRepository = {}

local Limits = assert(SynexSecurityLimits, 'security limits must be loaded first')
local Validation = assert(SynexSecurityValidation, 'security validation must be loaded first')

local SUBJECT_KINDS = { user = true, session = true, character = true, resource = true }
local ENFORCEMENT_OUTCOMES = {
    DECIDED = true,
    APPLIED = true,
    FAILED = true,
    INDETERMINATE = true,
}

function SynexSecurityRepository.create(options)
    options = options or {}
    local database = assert(options.database, 'security repository requires database')
    local encode = assert(options.encode, 'security repository requires JSON encoder')
    local decode = assert(options.decode, 'security repository requires JSON decoder')
    local repository = {}

    local function jsonValue(value, maximumBytes)
        local copied, copyError = Validation.copy(value or {}, {
            maximumBytes = maximumBytes or 16384,
            maximumDepth = 6,
            maximumEntries = 128,
            maximumStringBytes = 512,
        })
        if not copied then return nil, copyError end
        local ok, encoded = pcall(encode, copied)
        if not ok or not Validation.text(encoded, 2, maximumBytes or 16384) then
            return Validation.failure('SECURITY_PERSISTENCE_INVALID',
                'Security evidence could not be encoded safely.')
        end
        return encoded
    end

    local function decodedJson(value, maximumBytes)
        if not Validation.text(value, 2, maximumBytes) then
            return Validation.failure('SECURITY_PERSISTENCE_INVALID',
                'Persisted security evidence is not a bounded JSON value.')
        end
        local ok, decoded = pcall(decode, value)
        if not ok or type(decoded) ~= 'table' then
            return Validation.failure('SECURITY_PERSISTENCE_INVALID',
                'Persisted security evidence could not be decoded.')
        end
        return Validation.copy(decoded, {
            maximumBytes = maximumBytes,
            maximumDepth = 6,
            maximumEntries = 128,
            maximumStringBytes = 512,
        })
    end

    local function timestamp(value, nullable)
        if value == nil and nullable == true then return nil end
        local normalized = tostring(value or '')
        return Validation.text(normalized, 13, 32) and normalized or nil
    end

    local function sqlTimestamp(value)
        if not Validation.text(value, 20, 32)
            or value:match('^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d') == nil then
            return nil
        end
        return value:gsub('T', ' '):gsub('Z$', ''):sub(1, 23)
    end

    local function provenanceDigest(value)
        return Validation.text(value, 16, 16)
            and value:match('^[a-f0-9]+$') ~= nil
    end

    local function normalizeCaseRow(row)
        if type(row) ~= 'table'
            or not Validation.token(row.case_id, 8, 64)
            or not SUBJECT_KINDS[row.subject_kind]
            or not Validation.token(row.subject_ref, 1, 128)
            or row.user_id ~= nil and not Validation.token(row.user_id, 3, 96)
            or row.session_id ~= nil and not Validation.token(row.session_id, 3, 96)
            or row.subject_kind == 'user' and row.user_id ~= row.subject_ref
            or row.subject_kind == 'session' and row.session_id ~= row.subject_ref
            or not Limits.categories[row.category]
            or not Limits.severities[row.severity]
            or not Limits.caseStates[row.status] then
            return Validation.failure('SECURITY_PERSISTENCE_INVALID',
                'A persisted security case row is invalid.')
        end
        local confidence = tonumber(row.confidence)
        local signalCount = tonumber(row.signal_count)
        local enforcementCount = tonumber(row.enforcement_count)
        local revision = tonumber(row.revision)
        local openedAt = timestamp(row.opened_at)
        local updatedAt = timestamp(row.updated_at)
        local closedAt = timestamp(row.closed_at, true)
        if not Validation.isFinite(confidence) or confidence < 0 or confidence > 1
            or not Validation.isInteger(signalCount, 0, Limits.maximumSafeInteger)
            or not Validation.isInteger(enforcementCount, 0, Limits.maximumSafeInteger)
            or not Validation.isInteger(revision, 1, Limits.maximumSafeInteger)
            or openedAt == nil or updatedAt == nil
            or row.status == 'CLOSED' and closedAt == nil
            or row.status ~= 'CLOSED' and row.closed_at ~= nil then
            return Validation.failure('SECURITY_PERSISTENCE_INVALID',
                'A persisted security case row contains invalid state.')
        end
        local summary, summaryError = decodedJson(row.summary_json or '', 16384)
        if not summary then return nil, summaryError end
        return {
            caseId = row.case_id, subjectKind = row.subject_kind,
            subjectRef = row.subject_ref, userId = row.user_id,
            sessionId = row.session_id, category = row.category,
            severity = row.severity, confidence = confidence,
            status = row.status, signalCount = signalCount,
            enforcementCount = enforcementCount, summary = summary,
            openedAt = openedAt, updatedAt = updatedAt, closedAt = closedAt,
            revision = revision,
        }, nil
    end

    local function validateEnforcementRecord(record)
        return type(record) == 'table'
            and Validation.token(record.enforcementId, 8, 64)
            and Validation.token(record.caseId, 8, 64)
            and Limits.enforcementActions[record.action] == true
            and Validation.token(record.policy, 3, 96)
            and Validation.token(record.idempotencyKey, 8, 64)
            and ENFORCEMENT_OUTCOMES[record.outcome] == true
            and (record.traceId == nil or Validation.token(record.traceId, 3, 96))
            and type(record.summary) == 'table'
            and provenanceDigest(record.summary.provenanceDigest)
            and (record.outcome ~= 'DECIDED' or Validation.token(
                record.persistenceAttemptId, 8, 64))
    end

    local function normalizeEnforcementRow(row, expected)
        if type(row) ~= 'table'
            or not Validation.token(row.enforcement_id, 8, 64)
            or not Validation.token(row.case_id, 8, 64)
            or not Limits.enforcementActions[row.action]
            or not Validation.token(row.policy, 3, 96)
            or not Validation.token(row.idempotency_key, 8, 64)
            or not ENFORCEMENT_OUTCOMES[row.outcome]
            or row.trace_id ~= nil and not Validation.token(row.trace_id, 3, 96) then
            return Validation.failure('SECURITY_PERSISTENCE_INVALID',
                'A persisted security enforcement row is invalid.')
        end
        local summary, summaryError = decodedJson(row.summary_json or '', 8192)
        if not summary then return nil, summaryError end
        if not provenanceDigest(summary.provenanceDigest) then
            return Validation.failure('SECURITY_PERSISTENCE_INVALID',
                'Persisted security enforcement provenance is invalid.')
        end
        local createdAt = timestamp(row.created_at)
        if createdAt == nil then
            return Validation.failure('SECURITY_PERSISTENCE_INVALID',
                'Persisted security enforcement time is invalid.')
        end
        if expected ~= nil and (row.case_id ~= expected.caseId
            or row.action ~= expected.action
            or row.policy ~= expected.policy
            or row.idempotency_key ~= expected.idempotencyKey
            or summary.reason ~= expected.summary.reason) then
            return Validation.failure('SECURITY_ENFORCEMENT_CONFLICT',
                'The enforcement idempotency key belongs to another decision.', false)
        end
        return {
            enforcementId = row.enforcement_id,
            caseId = row.case_id,
            action = row.action,
            policyId = row.policy,
            idempotencyKey = row.idempotency_key,
            outcome = row.outcome,
            traceId = row.trace_id,
            summary = summary,
            createdAt = createdAt,
        }, nil
    end

    local CASE_UPSERT = [[
        INSERT INTO synex_security_cases
            (case_id, subject_kind, subject_ref, user_id, session_id, category,
             severity, confidence, status, signal_count, enforcement_count,
             summary_json, opened_at, updated_at, closed_at, revision)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON DUPLICATE KEY UPDATE
            user_id = VALUES(user_id), session_id = VALUES(session_id),
            category = VALUES(category), severity = VALUES(severity),
            confidence = VALUES(confidence), status = VALUES(status),
            signal_count = VALUES(signal_count),
            enforcement_count = VALUES(enforcement_count),
            summary_json = VALUES(summary_json), updated_at = VALUES(updated_at),
            closed_at = VALUES(closed_at), revision = VALUES(revision)
    ]]

    local SIGNAL_INSERT = [[
        INSERT IGNORE INTO synex_security_case_signals
            (case_id, signal_id, category, detector, code, evidence_class,
             severity, confidence, observed_at, trace_id, root_event_id, summary_json)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ]]

    local ENFORCEMENT_INSERT_APPLIED = [[
        INSERT IGNORE INTO synex_security_enforcements
            (enforcement_id, case_id, action, policy, idempotency_key,
             outcome, trace_id, summary_json, created_at)
        VALUES (?, ?, ?, ?, ?, 'APPLIED', ?, ?, UTC_TIMESTAMP(3))
    ]]

    local ENFORCEMENT_SELECT = [[
        SELECT enforcement_id, case_id, action, policy, idempotency_key,
               outcome, trace_id, summary_json, created_at
          FROM synex_security_enforcements
         WHERE idempotency_key = ?
         LIMIT 1
    ]]

    local ENFORCEMENT_MARK_APPLIED = [[
        UPDATE synex_security_enforcements
           SET outcome = 'APPLIED', trace_id = ?, summary_json = ?
         WHERE enforcement_id = ? AND idempotency_key = ?
           AND outcome = 'DECIDED'
    ]]

    local function caseParameters(record)
        if type(record) ~= 'table' or not Validation.token(record.caseId, 8, 64)
            or not SUBJECT_KINDS[record.subjectKind]
            or not Validation.token(record.subjectRef, 1, 128)
            or record.userId ~= nil and not Validation.token(record.userId, 3, 96)
            or record.sessionId ~= nil and not Validation.token(record.sessionId, 3, 96)
            or record.subjectKind == 'user' and record.userId ~= record.subjectRef
            or record.subjectKind == 'session' and record.sessionId ~= record.subjectRef
            or not Limits.categories[record.category]
            or not Limits.severities[record.severity]
            or not Validation.isFinite(record.confidence)
            or record.confidence < 0 or record.confidence > 1
            or not Limits.caseStates[record.status]
            or not Validation.isInteger(record.signalCount or 0, 0,
                Limits.maximumSafeInteger)
            or not Validation.isInteger(record.enforcementCount or 0, 0,
                Limits.maximumSafeInteger)
            or not Validation.isInteger(record.revision or 1, 1,
                Limits.maximumSafeInteger)
            or timestamp(record.openedAt) == nil or timestamp(record.updatedAt) == nil
            or record.closedAt ~= nil and timestamp(record.closedAt) == nil
            or record.status == 'CLOSED' and record.closedAt == nil
            or record.status ~= 'CLOSED' and record.closedAt ~= nil then
            return Validation.failure('SECURITY_PERSISTENCE_INVALID',
                'Security case persistence input is invalid.')
        end
        local summary, summaryError = jsonValue(record.summary or {}, 16384)
        if not summary then return nil, summaryError end
        return {
            record.caseId, record.subjectKind, record.subjectRef,
            record.userId, record.sessionId, record.category, record.severity,
            record.confidence, record.status, record.signalCount or 0,
            record.enforcementCount or 0, summary, record.openedAt,
            record.updatedAt, record.closedAt, record.revision or 1,
        }, nil
    end

    local function signalParameters(caseId, signal)
        if not Validation.token(caseId, 8, 64) or type(signal) ~= 'table'
            or not Validation.token(signal.signalId, 8, 64)
            or not Limits.categories[signal.category]
            or not Validation.semanticKey(signal.detector, 64)
            or not Validation.errorCode(signal.code)
            or not Limits.evidenceClasses[signal.evidenceClass]
            or not Limits.severities[signal.severity]
            or not Validation.isFinite(signal.confidence)
            or signal.confidence < 0 or signal.confidence > 1
            or sqlTimestamp(signal.observedAtUtc) == nil
            or signal.traceId ~= nil and not Validation.token(signal.traceId, 3, 96)
            or signal.rootEventId ~= nil
                and not Validation.token(signal.rootEventId, 3, 96) then
            return Validation.failure('SECURITY_PERSISTENCE_INVALID',
                'Security case signal persistence input is invalid.')
        end
        local summary, summaryError = jsonValue({
            summary = signal.summary,
            evidence = signal.evidence,
            correlationKey = signal.correlationKey,
            requestId = signal.requestId,
        }, 8192)
        if not summary then return nil, summaryError end
        return {
            caseId, signal.signalId, signal.category, signal.detector,
            signal.code, signal.evidenceClass, signal.severity,
            signal.confidence, sqlTimestamp(signal.observedAtUtc), signal.traceId,
            signal.rootEventId, summary,
        }, nil
    end

    local function verifySignalOwner(transaction, caseId, signalId)
        local row, rowError = transaction:one([[
            SELECT case_id
              FROM synex_security_case_signals
             WHERE signal_id = ?
             LIMIT 1
        ]], { signalId })
        if row == nil then
            return nil, rowError or { code = 'SECURITY_PERSISTENCE_INVALID' }
        end
        if row.case_id ~= caseId then
            return Validation.failure('SECURITY_CASE_SIGNAL_CONFLICT',
                'The security signal already belongs to another case.')
        end
        return true, nil
    end

    local function completeEnforcement(transaction, record, summary)
        local inserted, insertError = transaction:affected(
            ENFORCEMENT_INSERT_APPLIED, {
                record.enforcementId, record.caseId, record.action, record.policy,
                record.idempotencyKey, record.traceId, summary,
            })
        if inserted == nil then return nil, insertError end
        local row, rowError = transaction:one(
            ENFORCEMENT_SELECT, { record.idempotencyKey })
        if row == nil then
            return nil, rowError or { code = 'SECURITY_PERSISTENCE_INVALID' }
        end
        local existing, existingError = normalizeEnforcementRow(row, record)
        if not existing then return nil, existingError end
        if existing.outcome == 'DECIDED' then
            local updated, updateError = transaction:affected(
                ENFORCEMENT_MARK_APPLIED, {
                    record.traceId, summary, record.enforcementId,
                    record.idempotencyKey,
                })
            if updated ~= 1 then
                return nil, updateError or {
                    code = 'SECURITY_ENFORCEMENT_PERSISTENCE_FAILED',
                }
            end
        elseif existing.outcome ~= 'APPLIED' then
            return Validation.failure('SECURITY_ENFORCEMENT_CONFLICT',
                'The enforcement decision is in an incompatible terminal state.')
        end
        return {
            enforcementId = record.enforcementId,
            outcome = 'APPLIED',
            duplicate = inserted == 0 and existing.outcome == 'APPLIED',
        }, nil
    end

    function repository.saveCase(record)
        local parameters, parameterError = caseParameters(record)
        if not parameters then return nil, parameterError end
        return database.write(CASE_UPSERT, parameters)
    end

    function repository.appendSignal(caseId, signal)
        local parameters, parameterError = signalParameters(caseId, signal)
        if not parameters then return nil, parameterError end
        return database.transaction({
            operation = 'security.case.signal.append',
            idempotencyKey = signal.signalId,
            request = { caseId = caseId, signalId = signal.signalId },
        }, function(transaction)
            local inserted, insertError = transaction:affected(
                SIGNAL_INSERT, parameters)
            if inserted == nil then return nil, insertError end
            if inserted == 0 then
                local owned, ownerError = verifySignalOwner(
                    transaction, caseId, signal.signalId)
                if not owned then return nil, ownerError end
            end
            return { affectedRows = inserted, duplicate = inserted == 0 }, nil
        end)
    end

    function repository.saveCaseWithSignals(record, signals)
        local caseValues, caseError = caseParameters(record)
        if not caseValues then return nil, caseError end
        local count = Validation.arrayLength(signals, Limits.maximumCaseSignals)
        if count == nil or count < 1 then
            return Validation.failure('SECURITY_PERSISTENCE_INVALID',
                'Security case evidence must be a bounded signal batch.')
        end
        local batches = {}
        for index = 1, count do
            local values, signalError = signalParameters(record.caseId, signals[index])
            if not values then return nil, signalError end
            batches[index] = values
        end
        return database.transaction({
            operation = 'security.case.evidence.commit',
            idempotencyKey = record.caseId .. ':' .. tostring(record.revision),
            request = { caseId = record.caseId, revision = record.revision,
                signalCount = count },
        }, function(transaction)
            local saved, saveError = transaction:affected(CASE_UPSERT, caseValues)
            if saved == nil then return nil, saveError end
            for _, values in ipairs(batches) do
                local inserted, insertError = transaction:affected(
                    SIGNAL_INSERT, values)
                if inserted == nil then return nil, insertError end
                if inserted == 0 then
                    local owned, ownerError = verifySignalOwner(
                        transaction, record.caseId, values[2])
                    if not owned then return nil, ownerError end
                end
            end
            return { affectedRows = saved, signalCount = count }, nil
        end)
    end

    function repository.appendEnforcement(record)
        if not validateEnforcementRecord(record) or record.outcome ~= 'APPLIED' then
            return Validation.failure('SECURITY_PERSISTENCE_INVALID',
                'Security enforcement persistence input is invalid.')
        end
        local summary, summaryError = jsonValue(record.summary or {}, 8192)
        if not summary then return nil, summaryError end
        return database.transaction({
            operation = 'security.enforcement.complete',
            idempotencyKey = record.enforcementId,
            request = {
                enforcementId = record.enforcementId,
                caseId = record.caseId,
                provenanceDigest = record.summary.provenanceDigest,
            },
        }, function(transaction)
            return completeEnforcement(transaction, record, summary)
        end)
    end

    function repository.saveCaseWithEnforcement(caseRecord, enforcementRecord)
        local caseValues, caseError = caseParameters(caseRecord)
        if not caseValues then return nil, caseError end
        if not validateEnforcementRecord(enforcementRecord)
            or enforcementRecord.outcome ~= 'APPLIED'
            or enforcementRecord.caseId ~= caseRecord.caseId then
            return Validation.failure('SECURITY_PERSISTENCE_INVALID',
                'Atomic security enforcement projection input is invalid.')
        end
        local summary, summaryError = jsonValue(
            enforcementRecord.summary or {}, 8192)
        if not summary then return nil, summaryError end
        return database.transaction({
            operation = 'security.enforcement.project',
            idempotencyKey = enforcementRecord.enforcementId,
            request = {
                enforcementId = enforcementRecord.enforcementId,
                caseId = enforcementRecord.caseId,
                caseRevision = caseRecord.revision,
                provenanceDigest = enforcementRecord.summary.provenanceDigest,
            },
        }, function(transaction)
            local completed, completeError = completeEnforcement(
                transaction, enforcementRecord, summary)
            if not completed then return nil, completeError end
            local saved, saveError = transaction:affected(CASE_UPSERT, caseValues)
            if saved == nil then return nil, saveError end
            return {
                enforcementId = enforcementRecord.enforcementId,
                outcome = 'APPLIED',
                duplicate = completed.duplicate,
                affectedRows = saved,
            }, nil
        end)
    end

    function repository.reserveEnforcement(record)
        if not validateEnforcementRecord(record) or record.outcome ~= 'DECIDED' then
            return Validation.failure('SECURITY_PERSISTENCE_INVALID',
                'Security enforcement decision input is invalid.')
        end
        local summary, summaryError = jsonValue(record.summary, 8192)
        if not summary then return nil, summaryError end
        return database.transaction({
            operation = 'security.enforcement.reserve',
            idempotencyKey = record.persistenceAttemptId,
            request = {
                enforcementId = record.enforcementId,
                caseId = record.caseId,
                provenanceDigest = record.summary.provenanceDigest,
            },
        }, function(transaction)
            local inserted, insertError = transaction:affected([[
                INSERT IGNORE INTO synex_security_enforcements
                    (enforcement_id, case_id, action, policy, idempotency_key,
                     outcome, trace_id, summary_json, created_at)
                VALUES (?, ?, ?, ?, ?, 'DECIDED', ?, ?, UTC_TIMESTAMP(3))
            ]], {
                record.enforcementId, record.caseId, record.action, record.policy,
                record.idempotencyKey, record.traceId, summary,
            })
            if inserted == nil then return nil, insertError end
            local row, rowError = transaction:one([[
                SELECT enforcement_id, case_id, action, policy, idempotency_key,
                       outcome, trace_id, summary_json, created_at
                  FROM synex_security_enforcements
                 WHERE idempotency_key = ?
                 LIMIT 1 FOR UPDATE
            ]], { record.idempotencyKey })
            if row == nil then
                return nil, rowError or { code = 'SECURITY_PERSISTENCE_INVALID' }
            end
            local existing, existingError = normalizeEnforcementRow(row, record)
            if not existing then return nil, existingError end
            if inserted == 0 and existing.outcome == 'DECIDED' then
                local quarantined, quarantineError = transaction:affected([[
                    UPDATE synex_security_enforcements
                       SET outcome = 'INDETERMINATE'
                     WHERE enforcement_id = ? AND idempotency_key = ?
                       AND outcome = 'DECIDED'
                ]], { existing.enforcementId, existing.idempotencyKey })
                if quarantined == nil then return nil, quarantineError end
                if quarantined ~= 1 then
                    return Validation.failure('SECURITY_PERSISTENCE_CONFLICT',
                        'A duplicate security decision changed during reconciliation.',
                        true)
                end
                existing.outcome = 'INDETERMINATE'
            end
            return { enforcementId = existing.enforcementId,
                outcome = existing.outcome, summary = existing.summary,
                duplicate = inserted == 0 }, nil
        end)
    end

    function repository.reconcilePendingEnforcements(limit)
        local maximum = limit == nil and Limits.maximumEnforcementHistory or limit
        if not Validation.isInteger(maximum, 1,
            Limits.maximumEnforcementHistory) then
            return Validation.failure('SECURITY_PERSISTENCE_INVALID',
                'Security enforcement reconciliation limit is invalid.')
        end
        local rows, readError = database.read([[
            SELECT
                SUM(CASE WHEN outcome = 'DECIDED' THEN 1 ELSE 0 END)
                    AS decided_count,
                SUM(CASE WHEN outcome = 'INDETERMINATE' THEN 1 ELSE 0 END)
                    AS indeterminate_count
              FROM synex_security_enforcements
             WHERE outcome IN ('DECIDED', 'INDETERMINATE')
        ]], {}, { maximumRows = 1, maximumResultBytes = 4096 })
        if not rows then return nil, readError end
        if Validation.arrayLength(rows, 1) ~= 1 or type(rows[1]) ~= 'table' then
            return Validation.failure('SECURITY_PERSISTENCE_INVALID',
                'Security enforcement reconciliation returned an invalid result.')
        end
        local decided = tonumber(rows[1].decided_count) or 0
        local indeterminate = tonumber(rows[1].indeterminate_count) or 0
        if not Validation.isInteger(decided, 0, Limits.maximumSafeInteger)
            or not Validation.isInteger(indeterminate, 0,
                Limits.maximumSafeInteger) then
            return Validation.failure('SECURITY_PERSISTENCE_INVALID',
                'Security enforcement reconciliation counts are invalid.')
        end
        if decided > maximum then
            return Validation.failure('SECURITY_PERSISTENCE_BACKLOG',
                'Pending security decisions exceed the bounded recovery capacity.',
                true)
        end
        if decided == 0 then
            return { quarantined = 0, indeterminate = indeterminate }, nil
        end
        local result, reconcileError = database.maintenance(
            'security.enforcement.reconcile', function(transaction)
                local affected, affectedError = transaction:affected([[
                    UPDATE synex_security_enforcements
                       SET outcome = 'INDETERMINATE'
                     WHERE outcome = 'DECIDED'
                     ORDER BY created_at ASC, enforcement_id ASC
                     LIMIT ?
                ]], { maximum })
                if affected == nil then return nil, affectedError end
                if not Validation.isInteger(affected, 0, maximum) then
                    return Validation.failure('SECURITY_PERSISTENCE_INVALID',
                        'Security enforcement reconciliation affected an invalid row count.')
                end
                return { quarantined = affected }, nil
            end)
        if not result then return nil, reconcileError end
        if result.quarantined ~= decided then
            return Validation.failure('SECURITY_PERSISTENCE_CONFLICT',
                'Pending security decisions changed during recovery.', true)
        end
        return {
            quarantined = result.quarantined,
            indeterminate = indeterminate + result.quarantined,
        }, nil
    end

    function repository.loadOpenCases(limit)
        local maximum = limit == nil and 500 or limit
        if not Validation.isInteger(maximum, 1, Limits.maximumCases) then
            return Validation.failure('SECURITY_PERSISTENCE_INVALID',
                'Security case load limit is invalid.')
        end

        local rows, readError = database.read([[
            SELECT case_id, subject_kind, subject_ref, user_id, session_id,
                   category, severity, confidence, status, signal_count,
                   enforcement_count, summary_json, opened_at, updated_at,
                   closed_at, revision
              FROM synex_security_cases
             WHERE status <> 'CLOSED'
             ORDER BY updated_at DESC, case_id ASC
             LIMIT ?
        ]], { maximum + 1 }, {
            maximumRows = maximum + 1,
            maximumResultBytes = 4194304,
        })
        if not rows then return nil, readError end
        local rowCount = Validation.arrayLength(rows, maximum + 1)
        if rowCount == nil then
            return Validation.failure('SECURITY_PERSISTENCE_INVALID',
                'Security case rows exceed their bounded result contract.')
        end
        if rowCount > maximum then
            return Validation.failure('SECURITY_PERSISTENCE_BACKLOG',
                'Open security cases exceed the bounded restore capacity.', true)
        end
        local result = {}
        for _, row in ipairs(rows) do
            local normalized, normalizeError = normalizeCaseRow(row)
            if not normalized then return nil, normalizeError end
            result[#result + 1] = normalized
        end
        return result, nil
    end

    function repository.loadClosedCases(limit)
        local maximum = limit == nil and Limits.maximumClosedCaseArchive or limit
        if not Validation.isInteger(maximum, 1,
            Limits.maximumClosedCaseArchive) then
            return Validation.failure('SECURITY_PERSISTENCE_INVALID',
                'Closed security case load limit is invalid.')
        end
        local rows, readError = database.read([[
            SELECT case_id, subject_kind, subject_ref, user_id, session_id,
                   category, severity, confidence, status, signal_count,
                   enforcement_count, summary_json, opened_at, updated_at,
                   closed_at, revision
              FROM synex_security_cases
             WHERE status = 'CLOSED'
             ORDER BY updated_at DESC, case_id ASC
             LIMIT ?
        ]], { maximum }, {
            maximumRows = maximum,
            maximumResultBytes = 1048576,
        })
        if not rows then return nil, readError end
        if Validation.arrayLength(rows, maximum) == nil then
            return Validation.failure('SECURITY_PERSISTENCE_INVALID',
                'Closed security case rows exceed their bounded result contract.')
        end
        local result = {}
        for _, row in ipairs(rows) do
            local normalized, normalizeError = normalizeCaseRow(row)
            if not normalized then return nil, normalizeError end
            if normalized.status ~= 'CLOSED' then
                return Validation.failure('SECURITY_PERSISTENCE_INVALID',
                    'Closed security case restore returned an active case.')
            end
            result[#result + 1] = normalized
        end
        return result, nil
    end

    function repository.getCase(caseId)
        if not Validation.token(caseId, 8, 64) then
            return Validation.failure('SECURITY_CASE_NOT_FOUND',
                'The security case does not exist.')
        end
        local rows, readError = database.read([[
            SELECT case_id, subject_kind, subject_ref, user_id, session_id,
                   category, severity, confidence, status, signal_count,
                   enforcement_count, summary_json, opened_at, updated_at,
                   closed_at, revision
              FROM synex_security_cases WHERE case_id = ? LIMIT 1
        ]], { caseId }, { maximumRows = 1, maximumResultBytes = 65536 })
        if not rows then return nil, readError end
        local rowCount = Validation.arrayLength(rows, 1)
        if rowCount == nil then
            return Validation.failure('SECURITY_PERSISTENCE_INVALID',
                'Security case lookup exceeded its bounded result contract.')
        end
        if rowCount == 0 then
            return Validation.failure('SECURITY_CASE_NOT_FOUND',
                'The security case does not exist.')
        end
        local normalized, normalizeError = normalizeCaseRow(rows[1])
        if not normalized then return nil, normalizeError end
        if normalized.caseId ~= caseId then
            return Validation.failure('SECURITY_PERSISTENCE_INVALID',
                'Security case lookup returned another case identity.')
        end
        return normalized, nil
    end

    function repository.loadCaseSignals(caseId, limit)
        if not Validation.token(caseId, 8, 64) then
            return Validation.failure('SECURITY_CASE_NOT_FOUND',
                'The security case does not exist.')
        end
        local maximum = limit == nil and 64 or limit
        if not Validation.isInteger(maximum, 1, 128) then
            return Validation.failure('SECURITY_PERSISTENCE_INVALID',
                'Security case signal load limit is invalid.')
        end
        local rows, readError = database.read([[
            SELECT signal_id, category, detector, code, evidence_class, severity,
                   confidence, observed_at, trace_id, root_event_id, summary_json
              FROM synex_security_case_signals
             WHERE case_id = ?
             ORDER BY observed_at ASC, id ASC
             LIMIT ?
        ]], { caseId, maximum }, {
            maximumRows = maximum,
            maximumResultBytes = 262144,
        })
        if not rows then return nil, readError end
        if Validation.arrayLength(rows, maximum) == nil then
            return Validation.failure('SECURITY_PERSISTENCE_INVALID',
                'Security case signal rows exceed their bounded result contract.')
        end
        local values = {}
        for _, row in ipairs(rows) do
            if type(row) ~= 'table' then
                return Validation.failure('SECURITY_PERSISTENCE_INVALID',
                    'A persisted security case signal row is invalid.')
            end
            local confidence = tonumber(row.confidence)
            local observedAt = timestamp(row.observed_at)
            if not Validation.token(row.signal_id, 8, 64)
                or not Limits.categories[row.category]
                or not Validation.semanticKey(row.detector, 64)
                or not Validation.errorCode(row.code)
                or not Limits.evidenceClasses[row.evidence_class]
                or not Limits.severities[row.severity]
                or not Validation.isFinite(confidence)
                or confidence < 0 or confidence > 1
                or observedAt == nil
                or row.trace_id ~= nil and not Validation.token(row.trace_id, 3, 96)
                or row.root_event_id ~= nil
                    and not Validation.token(row.root_event_id, 3, 96) then
                return Validation.failure('SECURITY_PERSISTENCE_INVALID',
                    'A persisted security case signal row is invalid.')
            end
            local summary, summaryError = decodedJson(row.summary_json or '{}', 8192)
            if not summary then return nil, summaryError end
            values[#values + 1] = {
                signalId = row.signal_id,
                category = row.category,
                detector = row.detector,
                code = row.code,
                evidenceClass = row.evidence_class,
                severity = row.severity,
                confidence = confidence,
                observedAt = observedAt,
                traceId = row.trace_id,
                rootEventId = row.root_event_id,
                summary = summary.summary,
                evidence = summary.evidence,
                correlationKey = summary.correlationKey,
                requestId = summary.requestId,
            }
        end
        return values, nil
    end

    function repository.loadCaseEnforcements(caseId, limit)
        if not Validation.token(caseId, 8, 64) then
            return Validation.failure('SECURITY_CASE_NOT_FOUND',
                'The security case does not exist.')
        end
        local maximum = limit == nil and 32 or limit
        if not Validation.isInteger(maximum, 1, 64) then
            return Validation.failure('SECURITY_PERSISTENCE_INVALID',
                'Security enforcement load limit is invalid.')
        end
        local rows, readError = database.read([[
            SELECT enforcement_id, case_id, action, policy, idempotency_key,
                   outcome, trace_id, summary_json, created_at
              FROM synex_security_enforcements
             WHERE case_id = ?
             ORDER BY created_at ASC, enforcement_id ASC
             LIMIT ?
        ]], { caseId, maximum }, {
            maximumRows = maximum,
            maximumResultBytes = 131072,
        })
        if not rows then return nil, readError end
        if Validation.arrayLength(rows, maximum) == nil then
            return Validation.failure('SECURITY_PERSISTENCE_INVALID',
                'Security enforcement rows exceed their bounded result contract.')
        end
        local values = {}
        for _, row in ipairs(rows) do
            local normalized, normalizeError = normalizeEnforcementRow(row)
            if not normalized then return nil, normalizeError end
            if normalized.caseId ~= caseId then
                return Validation.failure('SECURITY_PERSISTENCE_INVALID',
                    'Security enforcement history returned another case identity.')
            end
            values[#values + 1] = {
                enforcementId = normalized.enforcementId,
                caseId = caseId,
                action = normalized.action,
                policyId = normalized.policyId,
                outcome = normalized.outcome,
                traceId = normalized.traceId,
                summary = normalized.summary,
                createdAt = normalized.createdAt,
            }
        end
        return values, nil
    end

    function repository.purge(retentionDays, closedRetentionDays)
        if not Validation.isInteger(retentionDays, 7, 3650)
            or not Validation.isInteger(closedRetentionDays, 1, retentionDays) then
            return Validation.failure('SECURITY_PERSISTENCE_INVALID',
                'Security retention policy is invalid.')
        end
        return database.maintenance('security.retention', function(transaction)
            local affected = transaction:affected([[
                DELETE FROM synex_security_cases
                 WHERE (status = 'CLOSED' AND updated_at < DATE_SUB(UTC_TIMESTAMP(3), INTERVAL ? DAY))
                    OR updated_at < DATE_SUB(UTC_TIMESTAMP(3), INTERVAL ? DAY)
                 LIMIT 500
            ]], { closedRetentionDays, retentionDays })
            return { removed = affected or 0 }
        end)
    end

    return repository
end
