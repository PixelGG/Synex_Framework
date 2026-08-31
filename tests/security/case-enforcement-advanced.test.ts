import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';

import { LuaFactory } from 'wasmoon';

const root = process.cwd();
const files = [
  'resources/synex_security/shared/limits.lua',
  'resources/synex_security/shared/validation.lua',
  'resources/synex_security/server/foundation.lua',
  'resources/synex_security/server/ring_buffer.lua',
  'resources/synex_security/server/cases.lua',
  'resources/synex_security/server/enforcement.lua',
] as const;

async function run<T>(source: string): Promise<T> {
  const engine = await new LuaFactory().createEngine();
  try {
    for (const file of files) {
      await engine.doString(await readFile(path.join(root, file), 'utf8'));
    }
    return await engine.doString(source) as T;
  } finally {
    engine.global.close();
  }
}

test('Case state changes are persistence-atomic and closed-case reopening is conflict-aware', async () => {
  const result = await run<{
    persistenceError: string;
    unchangedStatus: string;
    unchangedRevision: number;
    invalidTransition: string;
    reviewStatus: string;
    reviewCount: number;
    duplicateAttachment: boolean;
    closedAttachment: string;
    closedHypothesis: string;
    reopenedStatus: string;
    activeCases: number;
    saveAttempts: number;
  }>(`
    local clock, failReview, saveAttempts = 1000, true, 0
    local cases = SynexSecurityCases.create({
      now = function() return clock end,
      nowIso = function(ms) return ('2026-08-31T12:00:%02dZ'):format(ms / 1000) end,
      saveCase = function(value)
        saveAttempts = saveAttempts + 1
        if failReview and value.status == 'REVIEW' then
          return nil, { code = 'DATABASE_UNAVAILABLE' }
        end
        return true
      end,
    })
    local assessment = {
      subject = { source = 42, sessionId = 'session-0042',
        sourceGeneration = 1, userId = 'user-0042' },
      subjectKey = 'session:session-0042:1', expectedSignalCount = 0,
      hypotheses = {{ key = 'transport:replay', category = 'transport',
        correlationKey = 'replay', detector = 'synex.security.transport',
        confidence = 0.88, severity = 'HIGH', signalCount = 2,
        independentEvidence = 2,
        evidenceClasses = { 'SERVER_AUTHORITATIVE', 'SERVER_DERIVED' },
        weakEvidenceOnly = false, codes = { 'RPC_REPLAY_ATTEMPT' },
        oldestAt = 900, latestAt = 1000 }},
    }
    local first = assert(cases.openFromAssessment(assessment))
    local _, persistenceError = cases.transition(first.caseId, 'REVIEW', {
      expectedRevision = first.revision, reason = 'Independent review.' })
    local unchanged = assert(cases.get(first.caseId))
    failReview = false
    local reviewed = assert(cases.transition(first.caseId, 'REVIEW', {
      expectedRevision = unchanged.revision, reason = 'Independent review.' }))
    local _, invalidTransition = cases.transition(first.caseId, 'OPEN', {
      expectedRevision = reviewed.revision, reason = 'Implicit reopen is forbidden.' })
    clock = 2000
    local manual = assert(cases.attachEnforcement(first.caseId, {
      enforcementId = 'security:enforcement:0001', action = 'MANUAL_REVIEW',
      appliedAt = clock }))
    local duplicate, _, duplicateMetadata = cases.attachEnforcement(first.caseId, {
      enforcementId = 'security:enforcement:0001', action = 'MANUAL_REVIEW',
      appliedAt = clock })
    assert(duplicate.revision == manual.revision
      and duplicate.enforcementSummary.count == 1)
    local closed = assert(cases.transition(first.caseId, 'CLOSED', {
      expectedRevision = manual.revision, reason = 'Review completed.' }))
    local _, closedAttachment = cases.attachEnforcement(first.caseId, {
      enforcementId = 'security:enforcement:0002', action = 'OBSERVE',
      appliedAt = clock })
    clock = 3000
    local _, closedHypothesis = cases.openFromAssessment(assessment)
    local reopened = assert(cases.reopen(first.caseId, {
      expectedRevision = closed.revision, reason = 'New evidence.' }))
    local snapshot = cases.snapshot()
    return { persistenceError = persistenceError.code,
      unchangedStatus = unchanged.status, unchangedRevision = unchanged.revision,
      invalidTransition = invalidTransition.code, reviewStatus = manual.status,
      reviewCount = manual.enforcementSummary.count,
      duplicateAttachment = duplicateMetadata.duplicate,
      closedAttachment = closedAttachment.code,
      closedHypothesis = closedHypothesis.code,
      reopenedStatus = reopened.status,
      activeCases = (snapshot.states.OPEN or 0) + (snapshot.states.MONITORING or 0)
        + (snapshot.states.REVIEW or 0) + (snapshot.states.ENFORCED or 0),
      saveAttempts = saveAttempts }
  `);

  assert.deepEqual(result, {
    persistenceError: 'SECURITY_CASE_PERSISTENCE_FAILED',
    unchangedStatus: 'OPEN',
    unchangedRevision: 1,
    invalidTransition: 'SECURITY_CASE_TRANSITION_DENIED',
    reviewStatus: 'REVIEW',
    reviewCount: 1,
    duplicateAttachment: true,
    closedAttachment: 'SECURITY_CASE_CLOSED',
    closedHypothesis: 'SECURITY_CASE_REOPEN_REQUIRED',
    reopenedStatus: 'OPEN',
    activeCases: 1,
    saveAttempts: 6,
  });
});

test('Case restore rejects duplicate active hypotheses and listing uses a stable bounded offset', async () => {
  const result = await run<{
    conflict: string;
    newest: string;
    second: string;
    total: number;
    invalidOffset: string;
  }>(`
    local function record(id, updatedAt, status)
      return { caseId = id, subjectUser = 'user-0001',
        subjectKey = 'session:session-0001:1', hypothesisKey = 'transport:replay',
        category = 'transport', severity = 'HIGH', confidence = 0.8,
        openedAtMs = 1000, openedAt = '2026-08-31T12:00:00Z',
        updatedAtMs = updatedAt, updatedAt = '2026-08-31T12:00:01Z',
        status = status, revision = 1, signalSummary = { count = 1 },
        evidenceSummary = { independentEvidence = 1,
          evidenceClasses = { 'SERVER_AUTHORITATIVE' }, weakEvidenceOnly = false },
        enforcementSummary = { count = 0 } }
    end
    local conflicted = SynexSecurityCases.create({ now = function() return 5000 end })
    local _, conflict = conflicted.restore({
      record('security:case:00000001', 2000, 'OPEN'),
      record('security:case:00000002', 3000, 'REVIEW'),
    })
    local cases = SynexSecurityCases.create({ now = function() return 5000 end })
    assert(cases.restore({
      record('security:case:00000001', 2000, 'CLOSED'),
      record('security:case:00000002', 3000, 'OPEN'),
      (function()
        local value = record('security:case:00000003', 4000, 'CLOSED')
        value.hypothesisKey = 'movement:teleport'
        return value
      end)(),
    }))
    local first = assert(cases.list({ limit = 1, offset = 0 }))
    local second = assert(cases.list({ limit = 1, offset = 1 }))
    local all = assert(cases.list({ limit = 10 }))
    local _, invalidOffset = cases.list({ limit = 1, offset = -1 })
    return { conflict = conflict.code, newest = first[1].caseId,
      second = second[1].caseId, total = #all,
      invalidOffset = invalidOffset.code }
  `);

  assert.deepEqual(result, {
    conflict: 'SECURITY_CASE_RESTORE_INVALID',
    newest: 'security:case:00000003',
    second: 'security:case:00000002',
    total: 3,
    invalidOffset: 'SECURITY_CASE_INVALID',
  });
});

test('concurrent case creation is serialized per subject hypothesis', async () => {
  const result = await run<{
    follower: string;
    total: number;
    leaderCase: string;
  }>(`
    local firstSave = true
    local cases = SynexSecurityCases.create({
      now = function() return 1000 end,
      saveCase = function()
        if firstSave then
          firstSave = false
          coroutine.yield('persisting')
        end
        return true
      end,
    })
    local assessment = { subject = { userId = 'user-concurrent' },
      subjectKey = 'user:user-concurrent', expectedSignalCount = 0,
      hypotheses = {{ key = 'transport:replay', category = 'transport',
        detector = 'synex.security.transport', correlationKey = 'replay',
        confidence = 0.9, severity = 'HIGH', signalCount = 2,
        independentEvidence = 2,
        evidenceClasses = { 'SERVER_AUTHORITATIVE', 'DOMAIN_AUTHORITATIVE' },
        weakEvidenceOnly = false, codes = { 'RPC_REPLAY_ATTEMPT' },
        oldestAt = 900, latestAt = 1000 }} }
    local leaderValue
    local leader = coroutine.create(function()
      leaderValue = assert(cases.openFromAssessment(assessment))
    end)
    local started, marker = coroutine.resume(leader)
    assert(started and marker == 'persisting')
    local _, follower = cases.openFromAssessment(assessment)
    assert(coroutine.resume(leader))
    return { follower = follower.code, total = cases.snapshot().total,
      leaderCase = leaderValue.caseId }
  `);

  assert.equal(result.follower, 'SECURITY_CASE_IN_PROGRESS');
  assert.equal(result.total, 1);
  assert.match(result.leaderCase, /^security:case:/u);
});

test('Enforcement modes cap actions, fence subjects, expire idempotency, and never bypass Core Access', async () => {
  const result = await run<{
    observeAction: string;
    mitigateAction: string;
    kickAction: string;
    kickCalls: number;
    validatorCalls: number;
    duplicate: boolean;
    duplicateAcrossRevision: boolean;
    reappliedAfterExpiry: boolean;
    weakAction: string;
    banCalls: number;
    banUser: string;
    duplicateBanAcrossReconnect: boolean;
    missingHandler: string;
  }>(`
    local clock, kickCalls, validatorCalls, banCalls, banUser = 1000, 0, 0, 0, ''
    local engine = SynexSecurityEnforcement.create({
      now = function() return clock end,
      idempotencyRetentionMs = 1000,
      validateSubject = function(caseValue)
        validatorCalls = validatorCalls + 1
        return caseValue.sourceGeneration == 9
      end,
      handlers = { KICK = function() kickCalls = kickCalls + 1; return true end,
        MITIGATE = function() return true end },
      accessBan = function(request)
        banCalls, banUser = banCalls + 1, request.userId
        return true
      end,
    })
    local strong = { caseId = 'security:case:strong', revision = 2,
      subjectUser = 'user-strong', subjectSource = 42, sourceGeneration = 9,
      severity = 'CRITICAL', confidence = 0.96,
      evidenceSummary = { independentEvidence = 3,
        evidenceClasses = { 'SERVER_AUTHORITATIVE', 'CFX_SERVER_EVENT' },
        weakEvidenceOnly = false } }
    local rules = {
      { action = 'BAN', minimumConfidence = 0.9, minimumSeverity = 'HIGH',
        minimumIndependentEvidence = 2,
        requiredEvidenceClasses = { 'SERVER_AUTHORITATIVE' },
        reason = 'Deterministic abuse.' },
      { action = 'KICK', minimumConfidence = 0.8, minimumSeverity = 'HIGH',
        minimumIndependentEvidence = 2,
        reason = 'Immediate containment.' },
      { action = 'MITIGATE', minimumConfidence = 0.5, minimumSeverity = 'MEDIUM',
        minimumIndependentEvidence = 1,
        reason = 'Reject invalid action.' },
    }
    local observe = assert(engine.decide(strong,
      { policyId = 'observe', mode = 'OBSERVE', rules = rules }))
    local mitigate = assert(engine.decide(strong,
      { policyId = 'mitigate', mode = 'MITIGATE', rules = rules }))
    local kickPolicy = { policyId = 'kick', mode = 'ENFORCE', rules = {
      rules[2], rules[3] } }
    local kick = assert(engine.decide(strong, kickPolicy))
    assert(engine.apply(kick, strong))
    local _, _, duplicateMetadata = engine.apply(kick, strong)
    local revised = {}
    for key, value in pairs(strong) do revised[key] = value end
    revised.revision = strong.revision + 1
    local revisedKick = assert(engine.decide(revised, kickPolicy))
    local _, _, revisedMetadata = engine.apply(revisedKick, revised)
    clock = 2001
    assert(engine.apply(kick, strong))
    local weak = { caseId = 'security:case:weak', revision = 1,
      subjectSource = 43, sourceGeneration = 9, severity = 'CRITICAL', confidence = 1,
      evidenceSummary = { independentEvidence = 8,
        evidenceClasses = { 'CLIENT_TELEMETRY', 'BEHAVIORAL_HEURISTIC' },
        weakEvidenceOnly = true } }
    local weakDecision = assert(engine.decide(weak,
      { policyId = 'weak', mode = 'ENFORCE', rules = { rules[2] } }))
    local banDecision = assert(engine.decide(strong,
      { policyId = 'ban', mode = 'ENFORCE', rules = { rules[1] } }))
    assert(engine.apply(banDecision, strong))
    local reconnected = {}
    for key, value in pairs(strong) do reconnected[key] = value end
    reconnected.revision = strong.revision + 2
    reconnected.subjectSession = 'session-reconnected'
    reconnected.subjectSource = 77
    reconnected.sourceGeneration = 12
    local repeatedBan = assert(engine.decide(reconnected,
      { policyId = 'ban', mode = 'ENFORCE', rules = { rules[1] } }))
    local _, _, repeatedBanMetadata = engine.apply(repeatedBan, reconnected)
    local unavailable = SynexSecurityEnforcement.create({
      now = function() return clock end,
      validateSubject = function() return true end,
    })
    local missingDecision = assert(unavailable.decide(strong,
      { policyId = 'restrict', mode = 'ENFORCE', rules = {{
        action = 'RESTRICT', minimumConfidence = 0.5, minimumSeverity = 'LOW',
        minimumIndependentEvidence = 1, reason = 'Temporary restriction.'
      }} }))
    local _, missingHandler = unavailable.apply(missingDecision, strong)
    return { observeAction = observe.action, mitigateAction = mitigate.action,
      kickAction = kick.action, kickCalls = kickCalls,
      validatorCalls = validatorCalls, duplicate = duplicateMetadata.duplicate,
      duplicateAcrossRevision = revisedMetadata.duplicate,
      reappliedAfterExpiry = kickCalls == 2, weakAction = weakDecision.action,
      banCalls = banCalls, banUser = banUser,
      duplicateBanAcrossReconnect = repeatedBanMetadata.duplicate,
      missingHandler = missingHandler.code }
  `);

  assert.deepEqual(result, {
    observeAction: 'OBSERVE',
    mitigateAction: 'MITIGATE',
    kickAction: 'KICK',
    kickCalls: 2,
    validatorCalls: 3,
    duplicate: true,
    duplicateAcrossRevision: true,
    reappliedAfterExpiry: true,
    weakAction: 'MANUAL_REVIEW',
    banCalls: 1,
    banUser: 'user-strong',
    duplicateBanAcrossReconnect: true,
    missingHandler: 'SECURITY_ACTION_UNAVAILABLE',
  });
});

test('concurrent duplicate enforcement has one action leader and a retryable follower', async () => {
  const result = await run<{
    follower: string;
    actionCalls: number;
    leaderApplied: boolean;
  }>(`
    local actionCalls = 0
    local engine = SynexSecurityEnforcement.create({
      now = function() return 1000 end,
      utcNow = function() return 1893456000000 end,
      validateSubject = function() return true end,
      persistDecision = function(record)
        coroutine.yield('reserved')
        return { enforcementId = record.enforcementId, outcome = 'DECIDED',
          summary = record.summary }
      end,
      handlers = { KICK = function() actionCalls = actionCalls + 1; return true end },
      onApplied = function() return true end,
    })
    local caseValue = { caseId = 'security:case:concurrent', revision = 1,
      subjectSource = 42, sourceGeneration = 9, severity = 'CRITICAL',
      confidence = 0.99, evidenceSummary = { independentEvidence = 2,
        evidenceClasses = { 'SERVER_AUTHORITATIVE', 'CFX_SERVER_EVENT' },
        weakEvidenceOnly = false } }
    local policy = { policyId = 'security.concurrent', mode = 'ENFORCE', rules = {{
      action = 'KICK', minimumConfidence = 0.9, minimumSeverity = 'HIGH',
      minimumIndependentEvidence = 2, reason = 'Concurrent deterministic abuse.' }} }
    local decision = assert(engine.decide(caseValue, policy))
    local leaderValue
    local leader = coroutine.create(function()
      leaderValue = assert(engine.apply(decision, caseValue))
    end)
    local started, marker = coroutine.resume(leader)
    assert(started and marker == 'reserved')
    local _, follower = engine.apply(decision, caseValue)
    assert(coroutine.resume(leader))
    return { follower = follower.code, actionCalls = actionCalls,
      leaderApplied = leaderValue.persistenceState == 'APPLIED' }
  `);

  assert.deepEqual(result, {
    follower: 'SECURITY_ENFORCEMENT_IN_PROGRESS',
    actionCalls: 1,
    leaderApplied: true,
  });
});
