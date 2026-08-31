import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';

import { LuaFactory } from 'wasmoon';

const engineFiles = [
  'resources/synex_security/shared/limits.lua',
  'resources/synex_security/shared/validation.lua',
  'resources/synex_security/server/foundation.lua',
  'resources/synex_security/server/ring_buffer.lua',
  'resources/synex_security/server/signals.lua',
  'resources/synex_security/server/expectations.lua',
  'resources/synex_security/server/correlation.lua',
  'resources/synex_security/server/cases.lua',
  'resources/synex_security/server/enforcement.lua',
] as const;

async function runSecurityLua<T>(source: string): Promise<T> {
  const engine = await new LuaFactory().createEngine();
  try {
    for (const relativePath of engineFiles) {
      await engine.doString(await readFile(path.join(process.cwd(), relativePath), 'utf8'));
    }
    return await engine.doString(source) as T;
  } finally {
    engine.global.close();
  }
}

test('canonical signals enforce namespace ownership, source generations, bounds and dedupe', async () => {
  const result = await runSecurityLua<{
    source: number;
    duplicate: boolean;
    accepted: number;
    duplicateCount: number;
    stale: string;
    namespace: string;
    oversized: string;
    sessionChecks: number;
  }>(`
    local clock, sessionChecks = 1000, 0
    local signals = SynexSecuritySignals.create({
      now = function() return clock end,
      isOwnerCurrent = function(owner, epoch)
        return owner == 'synex_security' and epoch == 2
      end,
      isSessionCurrent = function(sessionId, generation, subject)
        sessionChecks = sessionChecks + 1
        return sessionId == 'session-0001' and generation == 7 and subject.source == 42
      end,
    })
    local function request(generation)
      return {
        namespace = 'synex.security', category = 'transport',
        detector = 'synex.security.transport.replay', code = 'RPC_REPLAY',
        subject = { source = 42, sessionId = 'session-0001',
          sourceGeneration = generation, userId = 'user-0001' },
        severity = 'HIGH', confidence = 0.9,
        evidenceClass = 'SERVER_AUTHORITATIVE', correlationKey = 'rpc:replay',
        rootEventId = 'root-0001', summary = 'A replay fence rejected a request.',
        evidence = { method = 'accounts.transfer', attempts = 2 },
      }
    end
    local first = assert(signals.emit(request(7),
      { ownerResource = 'synex_security', ownerEpoch = 2 }))
    local _, _, duplicateMetadata = signals.emit(request(7),
      { ownerResource = 'synex_security', ownerEpoch = 2 })
    local _, stale = signals.emit(request(6),
      { ownerResource = 'synex_security', ownerEpoch = 2 })
    local foreign = request(7)
    foreign.namespace = 'synex.accounts'
    foreign.detector = 'synex.accounts.transport.replay'
    local _, namespace = signals.emit(foreign,
      { ownerResource = 'synex_security', ownerEpoch = 2 })
    local huge = request(7)
    huge.rootEventId = 'root-0002'
    huge.evidence = { raw = string.rep('x', SynexSecurityLimits.maximumEvidenceStringBytes + 1) }
    local _, oversized = signals.emit(huge,
      { ownerResource = 'synex_security', ownerEpoch = 2 })
    local snapshot = signals.snapshot()
    return { source = first.subjectSource, duplicate = duplicateMetadata.duplicate,
      accepted = snapshot.accepted, duplicateCount = snapshot.duplicates,
      stale = stale.code, namespace = namespace.code, oversized = oversized.code,
      sessionChecks = sessionChecks }
  `);

  assert.deepEqual(result, {
    source: 42,
    duplicate: true,
    accepted: 1,
    duplicateCount: 1,
    stale: 'SECURITY_SUBJECT_STALE',
    namespace: 'SECURITY_NAMESPACE_DENIED',
    oversized: 'SECURITY_VALUE_INVALID',
    sessionChecks: 4,
  });
});

test('canonical signals reject secret-shaped and raw-address evidence before retention', async () => {
  const result = await runSecurityLua<{
    password: string;
    rawIp: string;
    webhook: string;
    connection: string;
    summary: string;
    reference: string;
    subject: string;
    accepted: number;
  }>(`
    local signals = SynexSecuritySignals.create({ now = function() return 1000 end })
    local function request(root, evidence, summary)
      return { namespace = 'fixture', category = 'transport',
        detector = 'fixture.transport', code = 'RPC_PAYLOAD_INVALID',
        subject = { resourceName = 'fixture' }, severity = 'MEDIUM',
        confidence = 0.8, evidenceClass = 'SERVER_AUTHORITATIVE',
        correlationKey = 'transport-invalid', rootEventId = root,
        summary = summary or 'A bounded transport request was rejected.',
        evidence = evidence }
    end
    local context = { ownerResource = 'fixture', ownerEpoch = 1 }
    local _, password = signals.emit(request('root-password',
      { nested = { password = 'not-for-evidence' } }), context)
    local _, rawIp = signals.emit(request('root-address',
      { rawIp = '203.0.113.42' }), context)
    local _, webhook = signals.emit(request('root-webhook',
      { endpoint = 'https://discord.com/api/webhooks/1/private' }), context)
    local _, connection = signals.emit(request('root-connection',
      { endpoint = 'mysql://operator:password@database/synex' }), context)
    local _, summary = signals.emit(request('root-summary', { attempts = 1 },
      'Rejected request from 203.0.113.42.'), context)
    local referenceRequest = request('203.0.113.42', { attempts = 1 })
    local _, reference = signals.emit(referenceRequest, context)
    local subjectRequest = request('root-subject', { attempts = 1 })
    subjectRequest.subject = { userId = '203.0.113.42' }
    local _, subject = signals.emit(subjectRequest, context)
    assert(signals.emit(request('root-safe', { attempts = 1, route = 'accounts.transfer' }),
      context))
    return { password = password.code, rawIp = rawIp.code,
      webhook = webhook.code, connection = connection.code,
      summary = summary.code, reference = reference.code, subject = subject.code,
      accepted = signals.snapshot().accepted }
  `);

  assert.deepEqual(result, {
    password: 'SECURITY_SIGNAL_INVALID',
    rawIp: 'SECURITY_SIGNAL_INVALID',
    webhook: 'SECURITY_SIGNAL_INVALID',
    connection: 'SECURITY_SIGNAL_INVALID',
    summary: 'SECURITY_SIGNAL_INVALID',
    reference: 'SECURITY_SIGNAL_INVALID',
    subject: 'SECURITY_SUBJECT_INVALID',
    accepted: 1,
  });
});

test('failed signal delivery remains pending across unrelated success and retries exactly once', async () => {
  const result = await runSecurityLua<{
    firstError: string;
    pendingAfterSuccess: number;
    retryDelivered: number;
    pendingAfterRetry: number;
    callsA: number;
    callsB: number;
    deliveryFailures: number;
    retries: number;
    duplicate: boolean;
  }>(`
    local attempts = { a = 0, b = 0 }
    local signals = SynexSecuritySignals.create({
      now = function() return 1000 end,
      onAccepted = function(signal)
        local key = signal.rootEventId == 'root-a' and 'a' or 'b'
        attempts[key] = attempts[key] + 1
        if key == 'a' and attempts[key] == 1 then
          return SynexSecurityValidation.failure('SECURITY_PIPELINE_FIXTURE',
            'The fixture pipeline is temporarily unavailable.', true)
        end
        return true
      end,
    })
    local function request(root)
      return { namespace = 'fixture', category = 'transport',
        detector = 'fixture.transport', code = 'RPC_PAYLOAD_INVALID',
        subject = { resourceName = 'fixture' }, severity = 'HIGH',
        confidence = 0.9, evidenceClass = 'SERVER_AUTHORITATIVE',
        correlationKey = 'transport-invalid', rootEventId = root,
        summary = 'A bounded transport request was rejected.' }
    end
    local context = { ownerResource = 'fixture', ownerEpoch = 1 }
    local _, firstError = signals.emit(request('root-a'), context)
    assert(signals.emit(request('root-b'), context))
    local pendingAfterSuccess = signals.snapshot().pipelinePending
    local retry = assert(signals.retry(16))
    local afterRetry = signals.snapshot()
    local _, _, duplicateMetadata = signals.emit(request('root-a'), context)
    return { firstError = firstError.code,
      pendingAfterSuccess = pendingAfterSuccess,
      retryDelivered = retry.delivered,
      pendingAfterRetry = afterRetry.pipelinePending,
      callsA = attempts.a, callsB = attempts.b,
      deliveryFailures = afterRetry.pipelineDeliveryFailures,
      retries = afterRetry.pipelineRetries,
      duplicate = duplicateMetadata.duplicate }
  `);

  assert.deepEqual(result, {
    firstError: 'SECURITY_PIPELINE_FIXTURE',
    pendingAfterSuccess: 1,
    retryDelivered: 1,
    pendingAfterRetry: 0,
    callsA: 2,
    callsB: 1,
    deliveryFailures: 1,
    retries: 1,
    duplicate: true,
  });
});

test('signal and ring retention stay bounded per subject', async () => {
  const result = await runSecurityLua<{
    active: number;
    firstMissing: string;
    listed: number;
  }>(`
    SynexSecurityLimits.maximumSubjectSignals = 2
    local clock = 1000
    local signals = SynexSecuritySignals.create({ now = function() return clock end,
      capacity = 8 })
    local ids = {}
    for index = 1, 3 do
      local value = assert(signals.emit({ namespace = 'fixture',
        category = 'resource_integrity', detector = 'fixture.integrity',
        code = 'RESOURCE_POLICY_VIOLATION', subject = { resourceName = 'fixture' },
        severity = 'LOW', confidence = 0.5,
        evidenceClass = 'SERVER_AUTHORITATIVE',
        correlationKey = 'resource-policy',
        rootEventId = ('root-%04d'):format(index), summary = 'Fixture policy signal.',
      }, { ownerResource = 'fixture', ownerEpoch = 1 }))
      ids[index] = value.signalId
      clock = clock + 10
    end
    local _, firstMissing = signals.get(ids[1])
    local listed = assert(signals.list({ subjectKey = 'resource:fixture', limit = 8 }))
    return { active = signals.snapshot().active, firstMissing = firstMissing.code,
      listed = #listed }
  `);

  assert.deepEqual(result, {
    active: 2,
    firstMissing: 'SECURITY_SIGNAL_NOT_FOUND',
    listed: 2,
  });
});

test('expectations use canonical kinds, explicit selectors, TTL, revision and owner epochs', async () => {
  const result = await runSecurityLua<{
    matches: number;
    revision: number;
    staleRevision: string;
    ownerStopped: number;
    activeAfterRestart: number;
    staleOwner: string;
    invalidKind: string;
    foreignCategory: string;
    expired: number;
  }>(`
    local clock = 1000
    local registry = SynexSecurityExpectations.create({ now = function() return clock end })
    local request = {
      expectationId = 'expectation-0001', namespace = 'synex.world',
      kind = 'movement.teleport',
      subject = { source = 51, sessionId = 'session-0051', sourceGeneration = 4,
        userId = 'user-0051' },
      constraints = { categories = { 'movement' }, codes = { 'MOVEMENT_DISPLACEMENT' },
        maximumSeverity = 'HIGH' },
      reason = 'An authoritative world transition is active.', ttlMs = 1000,
    }
    local first = assert(registry.register(request,
      { ownerResource = 'synex_world', ownerEpoch = 1 }))
    local signal = { category = 'movement', detector = 'synex.security.movement',
      code = 'MOVEMENT_DISPLACEMENT', correlationKey = 'movement:noclip',
      evidenceClass = 'SERVER_DERIVED', severity = 'HIGH', subjectSource = 51,
      subjectSession = 'session-0051', sourceGeneration = 4,
      subjectUser = 'user-0051' }
    local matches = assert(registry.match(signal))
    local updated = assert(registry.update({ expectationId = first.expectationId,
      revision = first.revision }, { reason = 'Transition still active.', ttlMs = 1500 },
      { ownerResource = 'synex_world', ownerEpoch = 1 }))
    local _, staleRevision = registry.update({ expectationId = first.expectationId,
      revision = first.revision }, { ttlMs = 1500 },
      { ownerResource = 'synex_world', ownerEpoch = 1 })
    local ownerStopped = assert(registry.revokeOwner('synex_world', 1))
    assert(registry.register(request,
      { ownerResource = 'synex_world', ownerEpoch = 1 }))
    assert(registry.activateOwner('synex_world', 2))
    local _, staleOwner = registry.register(request,
      { ownerResource = 'synex_world', ownerEpoch = 1 })
    local invalid = request
    invalid.expectationId = 'expectation-0002'
    invalid.kind = 'synex.world.movement.teleport'
    local _, invalidKind = registry.register(invalid,
      { ownerResource = 'synex_world', ownerEpoch = 2 })
    local foreign = {
      expectationId = 'expectation-foreign-0001', namespace = 'synex.world',
      kind = 'movement.teleport',
      subject = { sessionId = 'session-0051', sourceGeneration = 4 },
      constraints = { categories = { 'economy' } },
      reason = 'Invalid cross-domain suppression.', ttlMs = 100,
    }
    local _, foreignCategory = registry.register(foreign,
      { ownerResource = 'synex_world', ownerEpoch = 2 })
    local short = {
      expectationId = 'expectation-0003', namespace = 'synex.world',
      kind = 'camera.spectate',
      subject = { sessionId = 'session-0051', sourceGeneration = 4 },
      constraints = { categories = { 'movement' } }, reason = 'Spectate.', ttlMs = 100,
    }
    assert(registry.register(short, { ownerResource = 'synex_world', ownerEpoch = 2 }))
    clock = 1201
    local expired = registry.prune(clock)
    return { matches = #matches, revision = updated.revision,
      staleRevision = staleRevision.code,
      ownerStopped = ownerStopped,
      activeAfterRestart = registry.snapshot().active, staleOwner = staleOwner.code,
      invalidKind = invalidKind.code, foreignCategory = foreignCategory.code,
      expired = expired }
  `);

  assert.deepEqual(result, {
    matches: 1,
    revision: 2,
    staleRevision: 'SECURITY_EXPECTATION_STALE',
    ownerStopped: 1,
    activeAfterRestart: 0,
    staleOwner: 'SECURITY_OWNER_STALE',
    invalidKind: 'SECURITY_EXPECTATION_INVALID',
    foreignCategory: 'SECURITY_EXPECTATION_INVALID',
    expired: 1,
  });
});

test('world transition expectations suppress only the authorized teleport detector', async () => {
  const result = await runSecurityLua<{
    teleport: number;
    noclip: number;
    freecam: number;
    sentinel: number;
  }>(`
    local expectations = SynexSecurityExpectations.create({ now = function() return 1000 end })
    assert(expectations.register({ expectationId = 'expectation-world-0001',
      namespace = 'synex.world', kind = 'movement.teleport',
      subject = { sessionId = 'session-world', sourceGeneration = 4 },
      constraints = { categories = { 'movement' },
        detectors = { 'synex.security.movement' },
        codes = { 'MOVEMENT_TELEPORT_ANOMALY' },
        correlationKeys = { 'movement-teleport' }, maximumSeverity = 'HIGH' },
      reason = 'portal.transition', ttlMs = 5000,
    }, { ownerResource = 'synex_world', ownerEpoch = 2 }))
    local base = { category = 'movement', detector = 'synex.security.movement',
      code = 'MOVEMENT_TELEPORT_ANOMALY', correlationKey = 'movement-teleport',
      evidenceClass = 'SERVER_DERIVED', severity = 'HIGH',
      subjectSession = 'session-world', sourceGeneration = 4 }
    local function count(overrides)
      local value = {}
      for key, item in pairs(base) do value[key] = item end
      for key, item in pairs(overrides or {}) do value[key] = item end
      return #assert(expectations.match(value))
    end
    return { teleport = count(),
      noclip = count({ code = 'MOVEMENT_NOCLIP_ANOMALY',
        correlationKey = 'movement-noclip' }),
      freecam = count({ detector = 'synex.security.player_integrity',
        code = 'PLAYER_FREECAM_ANOMALY', correlationKey = 'player-freecam' }),
      sentinel = count({ category = 'client_integrity',
        detector = 'synex.security.sentinel', code = 'SECURITY_SENTINEL_MISSING',
        correlationKey = 'sentinel-missing', severity = 'MEDIUM' }) }
  `);

  assert.deepEqual(result, { teleport: 1, noclip: 0, freecam: 0, sentinel: 0 });
});

test('correlation collapses root events, filters expectations, decays signals and caps weak evidence', async () => {
  const result = await runSecurityLua<{
    dependent: number;
    independent: number;
    stronger: boolean;
    expected: number;
    expectedHypotheses: number;
    weakConfidence: number;
    weakOnly: boolean;
    contributors: number;
    reusedHypotheses: number;
    decayedHypotheses: number;
  }>(`
    local clock = 1000
    local expectations = SynexSecurityExpectations.create({ now = function() return clock end })
    assert(expectations.register({ expectationId = 'expectation-0001',
      namespace = 'synex.world', kind = 'movement.teleport',
      subject = { sessionId = 'session-expected', sourceGeneration = 1 },
      constraints = { categories = { 'movement' } }, reason = 'Transition.', ttlMs = 10000,
    }, { ownerResource = 'synex_world', ownerEpoch = 1 }))
    local correlation = SynexSecurityCorrelation.create({ now = function() return clock end,
      expectations = expectations })
    local function signal(id, root, evidenceClass, session, generation)
      return { signalId = id, category = 'movement',
        detector = 'synex.security.movement.noclip', code = 'MOVEMENT_DISPLACEMENT',
        subjectSource = 10, subjectSession = session or 'session-main',
        sourceGeneration = generation or 3, subjectUser = 'user-main',
        severity = 'HIGH', confidence = 0.9, evidenceClass = evidenceClass,
        correlationKey = 'movement:noclip', rootEventId = root,
        observedAt = clock, summary = 'Movement anomaly.' }
    end
    assert(correlation.ingest(signal('signal-0001', 'root-shared',
      'SERVER_DERIVED')))
    assert(correlation.ingest(signal('signal-0002', 'root-shared',
      'CFX_SERVER_EVENT')))
    assert(correlation.ingest(signal('signal-0003', 'root-shared',
      'CLIENT_TELEMETRY')))
    local first = assert(correlation.assess({ source = 10, sessionId = 'session-main',
      sourceGeneration = 3, userId = 'user-main' }))
    assert(correlation.ingest(signal('signal-0004', 'root-independent',
      'SERVER_AUTHORITATIVE')))
    local second = assert(correlation.assess({ source = 10, sessionId = 'session-main',
      sourceGeneration = 3, userId = 'user-main' }))
    local contributors = assert(correlation.contributors(signal('signal-0004',
      'root-independent', 'SERVER_AUTHORITATIVE'), 32))
    assert(correlation.ingest(signal('signal-expected', 'root-expected',
      'SERVER_DERIVED', 'session-expected', 1)))
    local expectedAssessment = assert(correlation.assess({
      sessionId = 'session-expected', sourceGeneration = 1, userId = 'user-main' }))
    for index = 1, 8 do
      local weak = signal(('signal-weak-%02d'):format(index),
        ('root-weak-%02d'):format(index), 'CLIENT_TELEMETRY', 'session-weak', 2)
      weak.subjectUser = 'user-weak'
      weak.severity = 'CRITICAL'
      weak.confidence = 1
      assert(correlation.ingest(weak))
    end
    local weakAssessment = assert(correlation.assess({
      sessionId = 'session-weak', sourceGeneration = 2, userId = 'user-weak' }))
    local reused = assert(correlation.assess({ source = 10, sessionId = 'session-main',
      sourceGeneration = 4, userId = 'user-main' }))
    clock = 1000 + SynexSecurityLimits.categoryWindowsMs.movement + 1
    local decayed = assert(correlation.assess({ source = 10, sessionId = 'session-main',
      sourceGeneration = 3, userId = 'user-main' }))
    return { dependent = first.hypotheses[1].independentEvidence,
      independent = second.hypotheses[1].independentEvidence,
      stronger = second.confidence > first.confidence,
      expected = expectedAssessment.expectedSignalCount,
      expectedHypotheses = #expectedAssessment.hypotheses,
      weakConfidence = weakAssessment.confidence,
      weakOnly = weakAssessment.hypotheses[1].weakEvidenceOnly,
      contributors = #contributors,
      reusedHypotheses = #reused.hypotheses,
      decayedHypotheses = #decayed.hypotheses }
  `);

  assert.equal(result.dependent, 1);
  assert.equal(result.independent, 2);
  assert.equal(result.stronger, true);
  assert.equal(result.expected, 1);
  assert.equal(result.expectedHypotheses, 0);
  assert.ok(result.weakConfidence <= 0.64);
  assert.equal(result.weakOnly, true);
  assert.equal(result.contributors, 4);
  assert.equal(result.reusedHypotheses, 0);
  assert.equal(result.decayedHypotheses, 0);
});

test('one root event contributes independent evidence to only one hypothesis', async () => {
  const result = await runSecurityLua<{
    hypotheses: number;
    independent: number;
    nonZero: number;
  }>(`
    local correlation = SynexSecurityCorrelation.create({ now = function() return 1000 end })
    local function signal(id, category, detector, key, evidenceClass, confidence)
      return { signalId = id, category = category, detector = detector,
        code = 'POLICY_VIOLATION', subjectResource = 'synex_fixture',
        severity = 'HIGH', confidence = confidence,
        evidenceClass = evidenceClass, correlationKey = key,
        rootEventId = 'shared-root-event', observedAt = 1000,
        summary = 'One originating event produced multiple derived observations.' }
    end
    assert(correlation.ingest(signal('signal-root-a', 'transport',
      'synex.security.transport', 'transport-abuse', 'SERVER_AUTHORITATIVE', 0.9)))
    assert(correlation.ingest(signal('signal-root-b', 'interaction',
      'synex.security.interaction', 'interaction-abuse', 'DOMAIN_AUTHORITATIVE', 0.8)))
    local assessment = assert(correlation.assess('resource:synex_fixture'))
    local independent, nonZero = 0, 0
    for _, hypothesis in ipairs(assessment.hypotheses) do
      independent = independent + hypothesis.independentEvidence
      if hypothesis.independentEvidence > 0 then nonZero = nonZero + 1 end
    end
    return { hypotheses = #assessment.hypotheses, independent = independent,
      nonZero = nonZero }
  `);

  assert.deepEqual(result, { hypotheses: 2, independent: 1, nonZero: 1 });
});

test('the current signal selects its own hypothesis instead of the highest unrelated one', async () => {
  const result = await runSecurityLua<{
    selected: string;
    absent: boolean;
  }>(`
    local assessment = { hypotheses = {
      { key = 'economy:transfer-abuse', confidence = 0.99 },
      { key = 'movement:noclip', confidence = 0.81 },
    } }
    local movement = {
      category = 'movement', detector = 'synex.security.movement.noclip',
      correlationKey = 'noclip',
    }
    local selected = assert(SynexSecurityFoundation.hypothesisForSignal(
      assessment, movement))
    local absent = SynexSecurityFoundation.hypothesisForSignal(assessment, {
      category = 'combat', detector = 'synex.security.combat',
      correlationKey = 'aim-pattern',
    })
    return { selected = selected.key, absent = absent == nil }
  `);

  assert.deepEqual(result, {
    selected: 'movement:noclip',
    absent: true,
  });
});

test('cases persist bounded summaries with UTC timestamps and explicit lifecycle revisions', async () => {
  const result = await runSecurityLua<{
    sameCase: boolean;
    initialStatus: string;
    monitoringStatus: string;
    reviewStatus: string;
    closedStatus: string;
    reopenedStatus: string;
    openedAt: string;
    openedAtMs: number;
    closedAt: string;
    duplicateRevision: number;
    saves: number;
  }>(`
    local clock, saves = 1725105600000, 0
    local cases = SynexSecurityCases.create({
      now = function() return clock end,
      nowIso = function(ms)
        return ms == 1725105600000 and '2024-08-31T12:00:00Z'
          or '2024-08-31T12:00:01Z'
      end,
      saveCase = function(value)
        assert(type(value.openedAt) == 'string' and type(value.openedAtMs) == 'number')
        saves = saves + 1
        return true
      end,
    })
    local assessment = {
      subject = { source = 42, sessionId = 'session-0042', sourceGeneration = 8,
        userId = 'user-0042', characterId = 'character-0042' },
      subjectKey = 'session:session-0042:8', expectedSignalCount = 2,
      hypotheses = {{ key = 'transport:rpc:replay', category = 'transport',
        correlationKey = 'rpc:replay', detector = 'synex.security.transport.replay',
        confidence = 0.82, severity = 'HIGH', signalCount = 3,
        independentEvidence = 2,
        evidenceClasses = { 'SERVER_AUTHORITATIVE', 'SERVER_DERIVED' },
        weakEvidenceOnly = false, codes = { 'RPC_REPLAY' },
        oldestAt = clock - 200, latestAt = clock }},
    }
    local opened = assert(cases.openFromAssessment(assessment))
    local duplicate = assert(cases.openFromAssessment(assessment))
    clock = clock + 1000
    assessment.hypotheses[1].signalCount = 4
    assessment.hypotheses[1].latestAt = clock
    local monitored = assert(cases.openFromAssessment(assessment))
    local reviewed = assert(cases.transition(opened.caseId, 'REVIEW',
      { expectedRevision = monitored.revision, reason = 'Operator review required.' }))
    local closed = assert(cases.transition(opened.caseId, 'CLOSED',
      { expectedRevision = reviewed.revision, reason = 'Investigation completed.' }))
    local reopened = assert(cases.reopen(opened.caseId,
      { expectedRevision = closed.revision, reason = 'New independent evidence.' }))
    return { sameCase = opened.caseId == monitored.caseId,
      initialStatus = opened.status, monitoringStatus = monitored.status,
      reviewStatus = reviewed.status, closedStatus = closed.status,
      reopenedStatus = reopened.status, openedAt = opened.openedAt,
      openedAtMs = opened.openedAtMs, closedAt = closed.closedAt,
      duplicateRevision = duplicate.revision, saves = saves }
  `);

  assert.deepEqual(result, {
    sameCase: true,
    initialStatus: 'OPEN',
    monitoringStatus: 'MONITORING',
    reviewStatus: 'REVIEW',
    closedStatus: 'CLOSED',
    reopenedStatus: 'OPEN',
    openedAt: '2024-08-31T12:00:00Z',
    openedAtMs: 1725105600000,
    closedAt: '2024-08-31T12:00:01Z',
    duplicateRevision: 1,
    saves: 5,
  });
});

test('enforcement is policy-separated, evidence-aware, subject-fenced and idempotent', async () => {
  const result = await runSecurityLua<{
    banAction: string;
    banCalls: number;
    validateCalls: number;
    duplicate: boolean;
    weakAction: string;
    stale: string;
    unavailable: string;
    mitigationAction: string;
    oversizedUserAction: string;
  }>(`
    local clock, banCalls, validateCalls = 1000, 0, 0
    local engine = SynexSecurityEnforcement.create({
      now = function() return clock end,
      validateSubject = function(caseValue)
        validateCalls = validateCalls + 1
        return caseValue.caseId ~= 'case-stale'
      end,
      accessBan = function(request)
        assert(request.userId == 'user-0001')
        assert(request.idempotencyKey:find('security.enforce:', 1, true) == 1)
        assert(#request.id <= 36 and #request.idempotencyKey <= 36)
        assert(request.expiresAt:match('^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d$'))
        banCalls = banCalls + 1
        return true
      end,
      handlers = { MITIGATE = function() return true end },
    })
    local strong = { caseId = 'case-strong', revision = 4, subjectUser = 'user-0001',
      subjectSource = 42, severity = 'CRITICAL', confidence = 0.95,
      evidenceSummary = { independentEvidence = 2,
        evidenceClasses = { 'SERVER_AUTHORITATIVE', 'CFX_SERVER_EVENT' },
        weakEvidenceOnly = false } }
    local policy = { policyId = 'strict.transport', mode = 'ENFORCE', rules = {{
      action = 'BAN', minimumConfidence = 0.9, minimumSeverity = 'HIGH',
      minimumIndependentEvidence = 2,
      requiredEvidenceClasses = { 'SERVER_AUTHORITATIVE' },
      reason = 'Deterministic replay abuse was independently confirmed.',
      durationMs = 60000,
    }} }
    local decision = assert(engine.decide(strong, policy))
    assert(engine.apply(decision, strong))
    local _, _, duplicateMetadata = engine.apply(decision, strong)
    local weak = { caseId = 'case-weak', revision = 1, subjectUser = 'user-0002',
      subjectSource = 43, severity = 'CRITICAL', confidence = 0.99,
      evidenceSummary = { independentEvidence = 9,
        evidenceClasses = { 'CLIENT_TELEMETRY', 'BEHAVIORAL_HEURISTIC' },
        weakEvidenceOnly = true } }
    local weakDecision = assert(engine.decide(weak, { policyId = 'strict.weak',
      mode = 'ENFORCE', rules = {{ action = 'BAN', minimumConfidence = 0.5,
        minimumSeverity = 'MEDIUM', minimumIndependentEvidence = 1,
        reason = 'Weak signals must not automatically ban.' }} }))
    local staleCase = { caseId = 'case-stale', revision = 1, subjectUser = 'user-0001',
      subjectSource = 42, severity = 'CRITICAL', confidence = 0.99,
      evidenceSummary = strong.evidenceSummary }
    local staleDecision = assert(engine.decide(staleCase, policy))
    local _, stale = engine.apply(staleDecision, staleCase)
    local unavailableEngine = SynexSecurityEnforcement.create({
      now = function() return clock end, validateSubject = function() return true end })
    local unavailableDecision = assert(unavailableEngine.decide(strong, policy))
    local _, unavailable = unavailableEngine.apply(unavailableDecision, strong)
    local mitigation = assert(engine.decide(strong, { policyId = 'balanced.transport',
      mode = 'MITIGATE', rules = {
        { action = 'BAN', minimumConfidence = 0.5, minimumSeverity = 'LOW',
          minimumIndependentEvidence = 1, reason = 'Not allowed in mitigate mode.' },
        { action = 'MITIGATE', minimumConfidence = 0.5, minimumSeverity = 'LOW',
          minimumIndependentEvidence = 1, reason = 'Reject the invalid operation.' },
      } }))
    local oversizedUser = {
      caseId = 'case-oversized-user', revision = 1,
      subjectUser = string.rep('u', 37), subjectSource = 44,
      severity = 'CRITICAL', confidence = 0.99,
      evidenceSummary = strong.evidenceSummary,
    }
    local oversizedDecision = assert(engine.decide(oversizedUser, policy))
    return { banAction = decision.action, banCalls = banCalls,
      validateCalls = validateCalls, duplicate = duplicateMetadata.duplicate,
      weakAction = weakDecision.action, stale = stale.code,
      unavailable = unavailable.code, mitigationAction = mitigation.action,
      oversizedUserAction = oversizedDecision.action }
  `);

  assert.deepEqual(result, {
    banAction: 'BAN',
    banCalls: 1,
    validateCalls: 2,
    duplicate: true,
    weakAction: 'MANUAL_REVIEW',
    stale: 'SECURITY_SUBJECT_STALE',
    unavailable: 'SECURITY_ACCESS_UNAVAILABLE',
    mitigationAction: 'MITIGATE',
    oversizedUserAction: 'MANUAL_REVIEW',
  });
});
