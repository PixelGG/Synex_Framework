import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';

import { LuaFactory } from 'wasmoon';

const root = process.cwd();
const runtimeFiles = [
  'resources/synex_security/shared/limits.lua',
  'resources/synex_security/shared/validation.lua',
  'resources/synex_security/server/foundation.lua',
  'resources/synex_security/server/ring_buffer.lua',
  'resources/synex_security/server/cases.lua',
  'resources/synex_security/server/enforcement.lua',
  'resources/synex_security/server/repository.lua',
] as const;

async function run<T>(source: string): Promise<T> {
  const engine = await new LuaFactory().createEngine();
  try {
    for (const file of runtimeFiles) {
      await engine.doString(await readFile(path.join(root, file), 'utf8'));
    }
    return await engine.doString(source) as T;
  } finally {
    engine.global.close();
  }
}

test('Case restore rebases prior-process timers and closed cases do not consume active capacity', async () => {
  const result = await run<{
    restoredUpdatedAt: number;
    restoredFirstAt: number;
    active: number;
    archived: number;
    firstEvicted: string;
    newestClosed: string;
  }>(`
    local clock = 10
    local function record(id, updatedAt, status)
      return { caseId = id, subjectUser = 'user-0001',
        subjectKey = 'session:session-0001:1', hypothesisKey = id,
        category = 'transport', severity = 'HIGH', confidence = 0.8,
        openedAtMs = updatedAt - 100, openedAt = '2026-08-31T12:00:00Z',
        updatedAtMs = updatedAt, updatedAt = '2026-08-31T12:00:01Z',
        status = status, revision = 1,
        signalSummary = { count = 1, firstAt = updatedAt - 50, lastAt = updatedAt },
        evidenceSummary = { independentEvidence = 1,
          evidenceClasses = { 'SERVER_AUTHORITATIVE' }, weakEvidenceOnly = false },
        enforcementSummary = { count = 0 } }
    end
    local restored = SynexSecurityCases.create({ now = function() return clock end,
      capacity = 1, closedArchiveCapacity = 1 })
    assert(restored.restore({ record('security:case:restored', 4000000000, 'OPEN') }))
    local value = assert(restored.get('security:case:restored'))

    local function assessment(id)
      return { subject = { userId = id }, subjectKey = 'user:' .. id,
        expectedSignalCount = 0, hypotheses = {{ key = 'transport:' .. id,
          category = 'transport', correlationKey = id, confidence = 0.9,
          severity = 'HIGH', signalCount = 1, independentEvidence = 1,
          evidenceClasses = { 'SERVER_AUTHORITATIVE' }, weakEvidenceOnly = false,
          codes = { 'RPC_REPLAY_ATTEMPT' }, oldestAt = clock, latestAt = clock }} }
    end
    local closedCases = SynexSecurityCases.create({ now = function() return clock end,
      capacity = 1, closedArchiveCapacity = 1 })
    local first = assert(closedCases.openFromAssessment(assessment('user-0001')))
    assert(closedCases.transition(first.caseId, 'CLOSED', {
      expectedRevision = first.revision, reason = 'Archived.' }))
    local second = assert(closedCases.openFromAssessment(assessment('user-0002')))
    assert(closedCases.transition(second.caseId, 'CLOSED', {
      expectedRevision = second.revision, reason = 'Archived.' }))
    local third = assert(closedCases.openFromAssessment(assessment('user-0003')))
    local snapshot = closedCases.snapshot()
    local _, firstError = closedCases.get(first.caseId)
    local newest = assert(closedCases.get(second.caseId))
    return { restoredUpdatedAt = value.updatedAtMs,
      restoredFirstAt = value.signalSummary.firstAt,
      active = snapshot.active, archived = snapshot.archived,
      firstEvicted = firstError.code, newestClosed = newest.status }
  `);

  assert.deepEqual(result, {
    restoredUpdatedAt: 10,
    restoredFirstAt: 9,
    active: 1,
    archived: 1,
    firstEvicted: 'SECURITY_CASE_NOT_FOUND',
    newestClosed: 'CLOSED',
  });
});

test('Irreversible enforcement persists stable provenance before action and uses UTC expiry', async () => {
  const result = await run<{
    sequence: string;
    expiry: string;
    missingPersistence: string;
    mutationRejected: string;
    commitFailure: string;
    kickCalls: number;
    finalizeCalls: number;
    retryFinalized: boolean;
    retryState: string;
    accessKeyLength: number;
  }>(`
    local sequence, expiry, accessKeyLength, kickCalls, finalizeCalls = {}, '', 0, 0, 0
    local caseValue = { caseId = 'security:case:durable', revision = 2,
      subjectUser = 'user-durable', subjectSource = 42, sourceGeneration = 7,
      severity = 'CRITICAL', confidence = 0.99,
      evidenceSummary = { independentEvidence = 2,
        evidenceClasses = { 'SERVER_AUTHORITATIVE', 'CFX_SERVER_EVENT' },
        weakEvidenceOnly = false } }
    local policy = { policyId = 'security.strict', mode = 'ENFORCE', rules = {{
      action = 'BAN', minimumConfidence = 0.9, minimumSeverity = 'HIGH',
      minimumIndependentEvidence = 2, reason = 'Deterministic abuse.',
      durationMs = 60000,
    }} }
    local engine = SynexSecurityEnforcement.create({
      now = function() return 1000 end,
      utcNow = function() return 1893456000000 end,
      validateSubject = function() return true end,
      persistDecision = function(record)
        sequence[#sequence + 1] = record.outcome
        assert(record.summary.provenanceDigest:match('^[a-f0-9]+$'))
        return { enforcementId = record.enforcementId, outcome = 'DECIDED',
          summary = record.summary }
      end,
      accessBan = function(request)
        sequence[#sequence + 1] = 'BAN'
        expiry = request.expiresAt
        accessKeyLength = #request.idempotencyKey
        assert(accessKeyLength >= 8 and accessKeyLength <= 36)
        return true
      end,
      onApplied = function(record)
        sequence[#sequence + 1] = record.persistenceState
        return true
      end,
    })
    local decision = assert(engine.decide(caseValue, policy))
    assert(engine.apply(decision, caseValue))

    local missing = SynexSecurityEnforcement.create({
      now = function() return 1000 end, utcNow = function() return 1893456000000 end,
      validateSubject = function() return true end, accessBan = function() return true end,
      onApplied = function() return true end,
    })
    local missingDecision = assert(missing.decide(caseValue, policy))
    local _, missingError = missing.apply(missingDecision, caseValue)

    local mutated = assert(engine.decide(caseValue, policy))
    mutated.reason = 'Changed after decision.'
    local _, mutationError = engine.apply(mutated, caseValue)

    local failing = SynexSecurityEnforcement.create({
      now = function() return 1000 end, utcNow = function() return 1893456000000 end,
      validateSubject = function() return true end,
      persistDecision = function(record)
        return { enforcementId = record.enforcementId, outcome = 'DECIDED',
          summary = record.summary }
      end,
      handlers = { KICK = function() kickCalls = kickCalls + 1; return true end },
      onApplied = function()
        finalizeCalls = finalizeCalls + 1
        if finalizeCalls == 1 then
          return nil, { code = 'DATABASE_UNAVAILABLE' }
        end
        return true
      end,
    })
    local kickPolicy = { policyId = 'security.kick', mode = 'ENFORCE', rules = {{
      action = 'KICK', minimumConfidence = 0.9, minimumSeverity = 'HIGH',
      minimumIndependentEvidence = 2, reason = 'Deterministic abuse.',
    }} }
    local kickDecision = assert(failing.decide(caseValue, kickPolicy))
    local _, commitError = failing.apply(kickDecision, caseValue)
    local retry, _, retryMetadata = failing.apply(kickDecision, caseValue)
    assert(failing.apply(kickDecision, caseValue))
    return { sequence = table.concat(sequence, ','), expiry = expiry,
      missingPersistence = missingError.code, mutationRejected = mutationError.code,
      commitFailure = commitError.code, kickCalls = kickCalls,
      finalizeCalls = finalizeCalls, retryFinalized = retryMetadata.finalized,
      retryState = retry.persistenceState, accessKeyLength = accessKeyLength }
  `);

  assert.deepEqual(result, {
    sequence: 'DECIDED,BAN,APPLIED',
    expiry: '2030-01-01 00:01:00',
    missingPersistence: 'SECURITY_ENFORCEMENT_PERSISTENCE_UNAVAILABLE',
    mutationRejected: 'SECURITY_ENFORCEMENT_INVALID',
    commitFailure: 'SECURITY_ENFORCEMENT_PERSISTENCE_FAILED',
    kickCalls: 1,
    finalizeCalls: 2,
    retryFinalized: true,
    retryState: 'APPLIED',
    accessKeyLength: 33,
  });
});

test('Indeterminate and duplicate durable decisions require review without replay', async () => {
  const result = await run<{
    code: string;
    duplicateCode: string;
    handlerCalls: number;
  }>(`
    local handlerCalls = 0
    local caseValue = { caseId = 'security:case:recovery', revision = 1,
      subjectUser = 'user-recovery', subjectSource = 42, sourceGeneration = 1,
      severity = 'CRITICAL', confidence = 0.99,
      evidenceSummary = { independentEvidence = 2,
        evidenceClasses = { 'SERVER_AUTHORITATIVE', 'CFX_SERVER_EVENT' },
        weakEvidenceOnly = false } }
    local engine = SynexSecurityEnforcement.create({
      now = function() return 1000 end,
      utcNow = function() return 1893456000000 end,
      validateSubject = function() return true end,
      persistDecision = function(record)
        return { enforcementId = record.enforcementId,
          outcome = 'INDETERMINATE', summary = record.summary }
      end,
      handlers = { KICK = function()
        handlerCalls = handlerCalls + 1
        return true
      end },
      onApplied = function() return true end,
    })
    local policy = { policyId = 'security.recovery', mode = 'ENFORCE', rules = {{
      action = 'KICK', minimumConfidence = 0.9, minimumSeverity = 'HIGH',
      minimumIndependentEvidence = 2, reason = 'Deterministic abuse.',
    }} }
    local decision = assert(engine.decide(caseValue, policy))
    local _, operationError = engine.apply(decision, caseValue)
    local duplicateEngine = SynexSecurityEnforcement.create({
      now = function() return 1000 end,
      utcNow = function() return 1893456000000 end,
      validateSubject = function() return true end,
      persistDecision = function(record)
        return { enforcementId = record.enforcementId, outcome = 'DECIDED',
          summary = record.summary, duplicate = true }
      end,
      handlers = { KICK = function()
        handlerCalls = handlerCalls + 1
        return true
      end },
      onApplied = function() return true end,
    })
    local duplicateDecision = assert(duplicateEngine.decide(caseValue, policy))
    local _, duplicateError = duplicateEngine.apply(duplicateDecision, caseValue)
    return { code = operationError.code, duplicateCode = duplicateError.code,
      handlerCalls = handlerCalls }
  `);

  assert.deepEqual(result, {
    code: 'SECURITY_ENFORCEMENT_REVIEW_REQUIRED',
    duplicateCode: 'SECURITY_ENFORCEMENT_REVIEW_REQUIRED',
    handlerCalls: 0,
  });
});

test('Ban policies match Core Access reason and remaining-expiry bounds', async () => {
  const result = await run<{
    controlReason: string;
    shortDuration: string;
    staleExpiry: string;
    accessCalls: number;
  }>(`
    local accessCalls, utcCalls = 0, 0
    local caseValue = { caseId = 'security:case:expiry', revision = 1,
      subjectUser = 'user-expiry', subjectSource = 42, sourceGeneration = 1,
      severity = 'CRITICAL', confidence = 0.99,
      evidenceSummary = { independentEvidence = 2,
        evidenceClasses = { 'SERVER_AUTHORITATIVE', 'CFX_SERVER_EVENT' },
        weakEvidenceOnly = false } }
    local function policy(reason, durationMs)
      return { policyId = 'security.expiry', mode = 'ENFORCE', rules = {{
        action = 'BAN', minimumConfidence = 0.9, minimumSeverity = 'HIGH',
        minimumIndependentEvidence = 2, reason = reason,
        durationMs = durationMs,
      }} }
    end
    local engine = SynexSecurityEnforcement.create({
      now = function() return 1000 end,
      utcNow = function()
        utcCalls = utcCalls + 1
        if utcCalls == 1 then return 1893456000000 end
        return 1893456060000
      end,
      validateSubject = function() return true end,
      persistDecision = function(record)
        return { enforcementId = record.enforcementId, outcome = 'DECIDED',
          summary = record.summary, duplicate = false }
      end,
      accessBan = function()
        accessCalls = accessCalls + 1
        return true
      end,
      onApplied = function() return true end,
    })
    local _, controlReason = engine.decide(caseValue, policy('bad\\nreason', 60000))
    local _, shortDuration = engine.decide(caseValue, policy('Too short.', 1000))
    local decision = assert(engine.decide(caseValue, policy('Bounded.', 60000)))
    local _, staleExpiry = engine.apply(decision, caseValue)
    return { controlReason = controlReason.code,
      shortDuration = shortDuration.code, staleExpiry = staleExpiry.code,
      accessCalls = accessCalls }
  `);

  assert.deepEqual(result, {
    controlReason: 'SECURITY_POLICY_INVALID',
    shortDuration: 'SECURITY_POLICY_INVALID',
    staleExpiry: 'SECURITY_EXPIRY_INVALID',
    accessCalls: 0,
  });
});

test('Repository quarantines bounded restart leftovers as indeterminate', async () => {
  const result = await run<{
    quarantined: number;
    indeterminate: number;
    retained: number;
    updates: number;
    backlog: string;
    invalidLimit: string;
  }>(`
    local decided, indeterminate, updates = 3, 2, 0
    local database = {
      read = function()
        return {{ decided_count = tostring(decided),
          indeterminate_count = tostring(indeterminate) }}
      end,
      maintenance = function(_, handler)
        local transaction = {}
        function transaction:affected(sql, parameters)
          assert(sql:find("SET outcome = 'INDETERMINATE'", 1, true))
          assert(parameters[1] == 64)
          updates = updates + 1
          local affected = decided
          decided, indeterminate = 0, indeterminate + affected
          return affected
        end
        return handler(transaction)
      end,
    }
    local repository = SynexSecurityRepository.create({ database = database,
      encode = function() return '{}' end, decode = function() return {} end })
    local recovered = assert(repository.reconcilePendingEnforcements(64))
    local retained = assert(repository.reconcilePendingEnforcements(64))
    decided = 65
    local _, backlog = repository.reconcilePendingEnforcements(64)
    local _, invalidLimit = repository.reconcilePendingEnforcements(0)
    return { quarantined = recovered.quarantined,
      indeterminate = recovered.indeterminate,
      retained = retained.indeterminate, updates = updates,
      backlog = backlog.code, invalidLimit = invalidLimit.code }
  `);

  assert.deepEqual(result, {
    quarantined: 3,
    indeterminate: 5,
    retained: 5,
    updates: 1,
    backlog: 'SECURITY_PERSISTENCE_BACKLOG',
    invalidLimit: 'SECURITY_PERSISTENCE_INVALID',
  });
});

test('Repository atomically quarantines a duplicate nonterminal decision', async () => {
  const result = await run<{
    first: string;
    duplicate: string;
    retained: string;
    quarantineWrites: number;
  }>(`
    local row, quarantineWrites
    quarantineWrites = 0
    local database = { transaction = function(_, handler)
      local transaction = {}
      function transaction:affected(sql, parameters)
        if sql:find('INSERT IGNORE', 1, true) then
          if row ~= nil then return 0 end
          row = { enforcement_id = parameters[1], case_id = parameters[2],
            action = parameters[3], policy = parameters[4],
            idempotency_key = parameters[5], outcome = 'DECIDED',
            trace_id = parameters[6], summary_json = parameters[7],
            created_at = '2026-08-31 12:00:00' }
          return 1
        end
        assert(sql:find("SET outcome = 'INDETERMINATE'", 1, true))
        assert(row.outcome == 'DECIDED')
        row.outcome = 'INDETERMINATE'
        quarantineWrites = quarantineWrites + 1
        return 1
      end
      function transaction:one() return row end
      return handler(transaction)
    end }
    local repository = SynexSecurityRepository.create({ database = database,
      encode = function() return 'encoded' end,
      decode = function() return { provenanceDigest = '0123456789abcdef',
        reason = 'Duplicate decision.' } end })
    local record = { enforcementId = 'security:enforcement:duplicate',
      persistenceAttemptId = 'security:persistence:first',
      caseId = 'security:case:duplicate', action = 'KICK',
      policy = 'security.duplicate', idempotencyKey = 'security:duplicate:key',
      outcome = 'DECIDED', summary = {
        provenanceDigest = '0123456789abcdef', reason = 'Duplicate decision.' } }
    local first = assert(repository.reserveEnforcement(record))
    record.persistenceAttemptId = 'security:persistence:second'
    local duplicate = assert(repository.reserveEnforcement(record))
    record.persistenceAttemptId = 'security:persistence:third'
    local retained = assert(repository.reserveEnforcement(record))
    return { first = first.outcome, duplicate = duplicate.outcome,
      retained = retained.outcome, quarantineWrites = quarantineWrites }
  `);

  assert.deepEqual(result, {
    first: 'DECIDED',
    duplicate: 'INDETERMINATE',
    retained: 'INDETERMINATE',
    quarantineWrites: 1,
  });
});

test('Repository reads and enforcement decisions are bounded, schema-aligned, and idempotent', async () => {
  const result = await run<{
    restored: number;
    largestRead: number;
    largestResult: number;
    restoreBacklog: string;
    invalidLimit: string;
    oversizedIdentity: string;
    reserved: string;
    duplicate: boolean;
    duplicateOutcome: string;
    revisedDuplicate: boolean;
    completed: string;
    conflict: string;
  }>(`
    local function caseRow(index)
      return { case_id = string.format('security:case:%04d', index),
        subject_kind = 'user', subject_ref = string.rep('u', 96),
        user_id = string.rep('u', 96), session_id = string.rep('s', 96),
        category = 'transport', severity = 'HIGH', confidence = '0.80000',
        status = 'OPEN', signal_count = 1, enforcement_count = 0,
        summary_json = '{}', opened_at = '2026-08-31 12:00:00',
        updated_at = '2026-08-31 12:00:01',
        restore_updated_at = '2026-08-31 12:00:01', closed_at = nil, revision = 1 }
    end
    local rows = {}
    for index = 1, 4096 do rows[index] = caseRow(index) end
    local largestRead = 0
    local largestResult = 0
    local persisted
    local database = {
      read = function(sql, parameters, options)
        largestRead = math.max(largestRead, options.maximumRows)
        largestResult = math.max(largestResult, options.maximumResultBytes)
        local requested = parameters[#parameters]
        local result = {}
        for index = 1, math.min(#rows, requested) do
          result[#result + 1] = rows[index]
        end
        return result
      end,
      write = function() return { affectedRows = 1 } end,
      transaction = function(_, handler)
        local transaction = {}
        function transaction:affected(sql, parameters)
          if sql:find('INSERT IGNORE', 1, true) then
            if persisted ~= nil then return 0 end
            persisted = { enforcement_id = parameters[1], case_id = parameters[2],
              action = parameters[3], policy = parameters[4],
              idempotency_key = parameters[5], outcome = sql:find("'DECIDED'", 1, true)
                and 'DECIDED' or 'APPLIED', trace_id = parameters[6],
              summary_json = parameters[7], created_at = '2026-08-31 12:00:02' }
            return 1
          end
          persisted.outcome, persisted.trace_id = 'APPLIED', parameters[1]
          persisted.summary_json = parameters[2]
          return 1
        end
        function transaction:one() return persisted end
        return handler(transaction)
      end,
      maintenance = function() return { removed = 0 } end,
    }
    local repository = SynexSecurityRepository.create({ database = database,
      encode = function(value) return 'digest:' .. tostring(value.provenanceDigest or '-') end,
      decode = function(value)
        local digest = value:match('^digest:(.+)$')
        return digest and { provenanceDigest = digest } or {}
      end,
    })
    local restored = assert(repository.loadOpenCases(4096))
    rows[4097] = caseRow(4097)
    local _, restoreBacklog = repository.loadOpenCases(4096)
    local _, invalidLimit = repository.loadOpenCases(4097)
    rows = { caseRow(1) }
    rows[1].user_id = string.rep('u', 97)
    local _, oversizedIdentity = repository.loadOpenCases(1)
    local record = { enforcementId = 'security:enforcement:0001',
      persistenceAttemptId = 'security:persistence:0001',
      caseId = 'security:case:repository', action = 'BAN', policy = 'security.strict',
      idempotencyKey = 'security.enforcement:0123456789abcdef', outcome = 'DECIDED',
      summary = { provenanceDigest = '0123456789abcdef' } }
    local reserved = assert(repository.reserveEnforcement(record))
    record.outcome = 'APPLIED'
    local completed = assert(repository.appendEnforcement(record))
    record.outcome = 'DECIDED'
    local duplicate = assert(repository.reserveEnforcement(record))
    local revisedRecord = { enforcementId = 'security:enforcement:0003',
      persistenceAttemptId = 'security:persistence:0003',
      caseId = record.caseId, action = record.action, policy = record.policy,
      idempotencyKey = record.idempotencyKey, outcome = 'DECIDED',
      summary = { provenanceDigest = 'fedcba9876543210' } }
    local revisedDuplicate = assert(repository.reserveEnforcement(revisedRecord))
    local conflictRecord = { enforcementId = 'security:enforcement:0002',
      persistenceAttemptId = 'security:persistence:0002',
      caseId = 'security:case:conflict', action = 'BAN', policy = 'security.strict',
      idempotencyKey = record.idempotencyKey, outcome = 'DECIDED',
      summary = { provenanceDigest = record.summary.provenanceDigest } }
    local _, conflict = repository.reserveEnforcement(conflictRecord)
    return { restored = #restored, largestRead = largestRead,
      largestResult = largestResult,
      restoreBacklog = restoreBacklog.code,
      invalidLimit = invalidLimit.code,
      oversizedIdentity = oversizedIdentity.code, reserved = reserved.outcome,
      duplicate = duplicate.duplicate, duplicateOutcome = duplicate.outcome,
      completed = completed.outcome,
      revisedDuplicate = revisedDuplicate.duplicate,
      conflict = conflict.code }
  `);

  assert.deepEqual(result, {
    restored: 4096,
    largestRead: 4097,
    largestResult: 4194304,
    restoreBacklog: 'SECURITY_PERSISTENCE_BACKLOG',
    invalidLimit: 'SECURITY_PERSISTENCE_INVALID',
    oversizedIdentity: 'SECURITY_PERSISTENCE_INVALID',
    reserved: 'DECIDED',
    duplicate: true,
    duplicateOutcome: 'APPLIED',
    revisedDuplicate: true,
    completed: 'APPLIED',
    conflict: 'SECURITY_ENFORCEMENT_CONFLICT',
  });

  const migration = await readFile(path.join(root,
    'resources/synex_security/migrations/001_security.sql'), 'utf8');
  assert.match(migration, /`user_id` VARCHAR\(96\)/u);
  assert.match(migration, /`session_id` VARCHAR\(96\)/u);
  assert.match(migration, /`policy` VARCHAR\(96\)/u);
  assert.match(migration, /`trace_id` VARCHAR\(96\)/u);
  assert.match(migration,
    /KEY `idx_security_enforcements_recovery`[\s\S]*?`outcome`, `created_at`, `enforcement_id`/u);
});

test('case-signal persistence uses UTC observation time instead of monotonic uptime', async () => {
  const result = await run<{ observedAt: string }>(`
    local parameters
    local repository = SynexSecurityRepository.create({
      database = { transaction = function(_, handler)
        local transaction = {}
        function transaction:affected(_, values)
          parameters = values
          return 1
        end
        return handler(transaction)
      end },
      encode = function() return '{}' end,
      decode = function() return {} end,
    })
    assert(repository.appendSignal('security:case:utc0001', {
      signalId = 'security:signal:utc0001', category = 'transport',
      detector = 'synex.security.transport', code = 'RPC_REPLAY_ATTEMPT',
      evidenceClass = 'SERVER_AUTHORITATIVE', severity = 'HIGH',
      confidence = 0.9, observedAt = 3600000,
      observedAtUtc = '2026-08-31T12:34:56Z',
      summary = 'A server-authoritative replay was rejected.',
    }))
    return { observedAt = parameters[9] }
  `);

  assert.deepEqual(result, { observedAt: '2026-08-31 12:34:56' });
});

test('case evidence and applied enforcement projections commit atomically', async () => {
  const result = await run<{
    signalSequence: string;
    signalConflict: string;
    enforcementSequence: string;
    enforcementOutcome: string;
  }>(`
    local signalOwner, phase, sequence = nil, 'signals', {}
    local enforcementRow = {
      enforcement_id = 'security:enforcement:atomic1',
      case_id = 'security:case:atomic0001', action = 'KICK',
      policy = 'security.atomic', idempotency_key = 'security:atomic:key0001',
      outcome = 'DECIDED', trace_id = nil, summary_json = 'encoded',
      created_at = '2026-08-31 12:00:02',
    }
    local database = {
      transaction = function(_, handler)
        local transaction = {}
        function transaction:affected(sql, parameters)
          if sql:find('synex_security_case_signals', 1, true) then
            sequence[#sequence + 1] = 'signal'
            if signalOwner == nil then signalOwner = parameters[1]; return 1 end
            return 0
          end
          if sql:find('INSERT IGNORE INTO synex_security_enforcements', 1, true) then
            sequence[#sequence + 1] = 'enforcement_insert'
            return 0
          end
          if sql:find('UPDATE synex_security_enforcements', 1, true) then
            sequence[#sequence + 1] = 'enforcement_update'
            enforcementRow.outcome = 'APPLIED'
            enforcementRow.summary_json = parameters[2]
            return 1
          end
          if sql:find('synex_security_cases', 1, true) then
            sequence[#sequence + 1] = 'case'
            return 1
          end
          error('unexpected statement')
        end
        function transaction:one(sql)
          if sql:find('synex_security_case_signals', 1, true) then
            sequence[#sequence + 1] = 'signal_owner'
            return { case_id = signalOwner }
          end
          sequence[#sequence + 1] = 'enforcement_select'
          return enforcementRow
        end
        return handler(transaction)
      end,
    }
    local repository = SynexSecurityRepository.create({ database = database,
      encode = function() return 'encoded' end,
      decode = function() return { provenanceDigest = '0123456789abcdef',
        reason = 'Atomic enforcement.' } end,
    })
    local function caseRecord(caseId, revision, enforcementCount)
      return { caseId = caseId, subjectKind = 'user', subjectRef = 'user-atomic',
        userId = 'user-atomic', sessionId = 'session-atomic',
        category = 'transport', severity = 'HIGH', confidence = 0.9,
        status = 'OPEN', signalCount = 1,
        enforcementCount = enforcementCount or 0, summary = { caseId = caseId },
        openedAt = '2026-08-31 12:00:00',
        updatedAt = '2026-08-31 12:00:01', revision = revision }
    end
    local signal = { signalId = 'security:signal:atomic001',
      category = 'transport', detector = 'synex.security.transport',
      code = 'RPC_REPLAY_ATTEMPT', evidenceClass = 'SERVER_AUTHORITATIVE',
      severity = 'HIGH', confidence = 0.9,
      observedAtUtc = '2026-08-31T12:00:00Z', summary = 'Replay rejected.' }
    assert(repository.saveCaseWithSignals(
      caseRecord('security:case:atomic0001', 1), { signal }))
    local signalSequence = table.concat(sequence, ',')
    sequence = {}
    local _, signalConflict = repository.saveCaseWithSignals(
      caseRecord('security:case:atomic0002', 1), { signal })
    sequence = {}
    local enforcement = assert(repository.saveCaseWithEnforcement(
      caseRecord('security:case:atomic0001', 2, 1), {
        enforcementId = 'security:enforcement:atomic1',
        caseId = 'security:case:atomic0001', action = 'KICK',
        policy = 'security.atomic', idempotencyKey = 'security:atomic:key0001',
        outcome = 'APPLIED', summary = {
          provenanceDigest = '0123456789abcdef', reason = 'Atomic enforcement.' },
      }))
    return { signalSequence = signalSequence,
      signalConflict = signalConflict.code,
      enforcementSequence = table.concat(sequence, ','),
      enforcementOutcome = enforcement.outcome }
  `);

  assert.deepEqual(result, {
    signalSequence: 'case,signal',
    signalConflict: 'SECURITY_CASE_SIGNAL_CONFLICT',
    enforcementSequence:
      'enforcement_insert,enforcement_select,enforcement_update,case',
    enforcementOutcome: 'APPLIED',
  });
});
