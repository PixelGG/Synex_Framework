import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';

import { LuaFactory } from 'wasmoon';

const root = process.cwd();

async function run<T>(files: readonly string[], source: string): Promise<T> {
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

const serviceFiles = [
  'resources/synex_security/shared/limits.lua',
  'resources/synex_security/shared/validation.lua',
  'resources/synex_security/server/foundation.lua',
  'resources/synex_security/server/ring_buffer.lua',
  'resources/synex_security/server/signals.lua',
  'resources/synex_security/server/cases.lua',
  'resources/synex_security/server/service.lua',
] as const;

test('Security service derives caller ownership, rejects ambiguous JSON forms, and keeps reads bounded', async () => {
  const result = await run<{
    accepted: boolean;
    caseId: string;
    denied: string;
    ambiguous: string;
    forgedEvidence: string;
    staleOwner: string;
    detailCaseId: string;
    detailStatus: string;
    methodCount: number;
    enforceExposed: boolean;
    lifecycleCapability: string;
    activations: number;
  }>(serviceFiles, `
    local clock, activations = 1000, 0
    local signals = SynexSecuritySignals.create({
      now = function() return clock end,
      isOwnerCurrent = function(owner, epoch)
        return owner == 'synex_fixture' and epoch == 3
      end,
      isSessionCurrent = function(sessionId, generation, subject)
        return sessionId == 'session-0042' and generation == 7 and subject.source == 42
      end,
    })
    local service = SynexSecurityService.create({
      signals = signals,
      expectations = {
        register = function() return nil, { code = 'SECURITY_UNAVAILABLE' } end,
        revoke = function() return true end,
        list = function() return {} end,
      },
      correlation = { assess = function()
        return { subjectKey = 'resource:synex_fixture', severity = 'INFO',
          confidence = 0, activeExpectations = 0, hypotheses = {} }
      end },
      cases = { get = function() return nil, { code = 'SECURITY_CASE_NOT_FOUND' } end },
      getCase = function(caseId)
        return { caseId = caseId, status = 'REVIEW', category = 'transport',
          severity = 'HIGH', confidence = 0.81,
          signalSummary = { count = 2 }, enforcementSummary = { count = 0 },
          openedAt = '2026-08-31T12:00:00Z',
          updatedAt = '2026-08-31T12:00:01Z' }
      end,
      sentinel = { report = function() return { accepted = true } end },
      diagnostics = {
        health = function() return { state = 'READY', detectors = 9,
          openCases = 0, activeExpectations = 0, sentinelSources = 0,
          persistenceBacklog = 0 } end,
        summary = function() return {} end,
        list = function() return { items = {}, total = 0, truncated = false } end,
        doctor = function() return { items = {}, total = 0, truncated = false } end,
      },
      detectors = {},
      decode = function() return {} end,
      encode = function() return '{"bounded":true}' end,
      caseForSignal = function() return 'security:case:00000001' end,
      activateOwner = function(owner, epoch)
        activations = activations + 1
        if owner == 'synex_fixture' and epoch == 3 then return true end
        return nil, { code = 'SECURITY_OWNER_STALE', retryable = true }
      end,
    })
    local function request()
      return {
        namespace = 'synex.fixture', category = 'transport',
        detector = 'synex.fixture.transport', code = 'RPC_REPLAY_ATTEMPT',
        subject = { source = 42, sessionId = 'session-0042',
          sourceGeneration = 7 }, severity = 'HIGH', confidence = 0.9,
        evidenceClass = 'DOMAIN_AUTHORITATIVE',
        correlationKey = 'transport-replay', summary = 'Replay was rejected.',
        evidence = { attempts = 2 }, rootEventId = 'root-00000001',
      }
    end
    local accepted = assert(service.reportSignal(request(), {
      caller = 'synex_fixture', callerEpoch = 3, traceId = 'trace-00000001' }))
    local foreign = request()
    foreign.rootEventId = 'root-00000002'
    foreign.namespace = 'synex.accounts'
    local _, denied = service.reportSignal(foreign,
      { caller = 'synex_fixture', callerEpoch = 3 })
    local ambiguousRequest = request()
    ambiguousRequest.rootEventId = 'root-00000003'
    ambiguousRequest.evidenceJson = '{}'
    local _, ambiguous = service.reportSignal(ambiguousRequest,
      { caller = 'synex_fixture', callerEpoch = 3 })
    local forgedRequest = request()
    forgedRequest.rootEventId = 'root-00000004'
    forgedRequest.evidenceClass = 'SERVER_AUTHORITATIVE'
    local _, forgedEvidence = service.reportSignal(forgedRequest,
      { caller = 'synex_fixture', callerEpoch = 3 })
    local _, staleOwner = service.reportSignal(request(),
      { caller = 'synex_fixture', callerEpoch = 2 })
    local detail = assert(service.getCase({ caseId = 'security:case:00000001' }))
    local definition = service.serviceDefinition()
    local methodCount = 0
    for _ in pairs(definition.methods) do methodCount = methodCount + 1 end
    return { accepted = accepted.accepted, caseId = accepted.caseId,
      denied = denied.code, ambiguous = ambiguous.code,
      forgedEvidence = forgedEvidence.code,
      staleOwner = staleOwner.code, detailCaseId = detail.caseId,
      detailStatus = detail.status, methodCount = methodCount,
      enforceExposed = definition.methods.enforce ~= nil,
      lifecycleCapability = definition.capabilities.transitionCase,
      activations = activations }
  `);

  assert.deepEqual(result, {
    accepted: true,
    caseId: 'security:case:00000001',
    denied: 'SECURITY_NAMESPACE_DENIED',
    ambiguous: 'SECURITY_VALUE_INVALID',
    forgedEvidence: 'SECURITY_SIGNAL_INVALID',
    staleOwner: 'SECURITY_OWNER_STALE',
    detailCaseId: 'security:case:00000001',
    detailStatus: 'REVIEW',
    methodCount: 12,
    enforceExposed: false,
    lifecycleCapability: 'synex.security.enforce',
    activations: 5,
  });
});

test('privileged service lifecycle port closes and reopens cases with revisions and audit callbacks', async () => {
  const result = await run<{
    closed: string;
    reopened: string;
    revision: number;
    lifecycleEvents: number;
  }>(serviceFiles, `
    local lifecycleEvents = 0
    local cases = SynexSecurityCases.create({ now = function() return 1000 end,
      nowIso = function() return '2026-08-31T12:00:00Z' end })
    local opened = assert(cases.openFromAssessment({
      subject = { userId = 'user-lifecycle' }, subjectKey = 'user:user-lifecycle',
      expectedSignalCount = 0, hypotheses = {{ key = 'transport:abuse',
        category = 'transport', detector = 'synex.security.transport',
        correlationKey = 'transport-abuse', confidence = 0.9, severity = 'HIGH',
        signalCount = 2, independentEvidence = 2,
        evidenceClasses = { 'SERVER_AUTHORITATIVE', 'DOMAIN_AUTHORITATIVE' },
        weakEvidenceOnly = false, codes = { 'RPC_REPLAY_ATTEMPT' },
        oldestAt = 900, latestAt = 1000 }} }))
    local service = SynexSecurityService.create({
      signals = {}, expectations = {}, correlation = {}, cases = cases,
      sentinel = {}, detectors = {},
      diagnostics = { health = function() return {} end,
        summary = function() return {} end },
      decode = function() return {} end, encode = function() return '{}' end,
      now = function() return 1000 end,
      onCaseLifecycle = function()
        lifecycleEvents = lifecycleEvents + 1
        return true
      end,
    })
    local context = { caller = 'synex_admin_fixture', callerEpoch = 1 }
    local closed = assert(service.transitionCase({ caseId = opened.caseId,
      targetStatus = 'CLOSED', expectedRevision = opened.revision,
      reason = 'Operator investigation completed.' }, context))
    local reopened = assert(service.reopenCase({ caseId = opened.caseId,
      expectedRevision = closed.revision,
      reason = 'New authoritative evidence arrived.' }, context))
    return { closed = closed.status, reopened = reopened.status,
      revision = reopened.revision, lifecycleEvents = lifecycleEvents }
  `);

  assert.deepEqual(result, {
    closed: 'CLOSED',
    reopened: 'OPEN',
    revision: 3,
    lifecycleEvents: 4,
  });
});

test('Security case reads deterministically truncate mature case collections before encoding', async () => {
  const result = await run<{
    timeline: number;
    enforcements: number;
    expectations: number;
    timelineTruncated: boolean;
    enforcementsTruncated: boolean;
    expectationsTruncated: boolean;
  }>(serviceFiles, `
    local captured
    local function items(prefix, count)
      local values = {}
      for index = 1, count do
        values[index] = { id = prefix .. tostring(index),
          summary = 'Bounded case evidence.' }
      end
      return values
    end
    local service = SynexSecurityService.create({
      signals = {}, expectations = {}, correlation = {}, cases = {}, sentinel = {},
      detectors = {}, decode = function() return {} end,
      encode = function(value)
        captured = value
        return '{"bounded":true}'
      end,
      getCase = function(caseId)
        return { caseId = caseId, status = 'REVIEW', category = 'transport',
          severity = 'HIGH', confidence = 0.8, revision = 2,
          signalSummary = { count = 32 }, enforcementSummary = { count = 32 },
          openedAt = '2026-08-31T12:00:00Z',
          updatedAt = '2026-08-31T12:00:01Z',
          timeline = items('signal-', 32), enforcements = items('enforcement-', 32),
          expectations = items('expectation-', 32), expectationCount = 32 }
      end,
      diagnostics = { health = function() return {} end,
        summary = function() return {} end },
    })
    assert(service.getCase({ caseId = 'security:case:bounded' }))
    return { timeline = #captured.timeline,
      enforcements = #captured.enforcements,
      expectations = #captured.expectations,
      timelineTruncated = captured.timelineTruncated,
      enforcementsTruncated = captured.enforcementsTruncated,
      expectationsTruncated = captured.expectationsTruncated }
  `);

  assert.deepEqual(result, {
    timeline: 4,
    enforcements: 4,
    expectations: 4,
    timelineTruncated: true,
    enforcementsTruncated: true,
    expectationsTruncated: true,
  });
});

test('Contract handlers preserve declared errors and redact undeclared internal outcomes', async () => {
  const result = await run<{
    declared: string;
    redacted: string;
    unavailableMethod: string;
  }>(serviceFiles, `
    local signals = SynexSecuritySignals.create({ now = function() return 1000 end })
    local service = SynexSecurityService.create({
      signals = signals, expectations = {}, correlation = {}, cases = {},
      sentinel = {}, detectors = {},
      diagnostics = { health = function() return {} end, summary = function() return {} end },
      decode = function() return {} end, encode = function() return '{}' end,
      activateOwner = function() return true end,
    })
    local request = {
      namespace = 'synex.accounts', category = 'transport',
      detector = 'synex.accounts.transport', code = 'RPC_REPLAY_ATTEMPT',
      subject = { resourceName = 'synex_fixture' }, severity = 'HIGH',
      confidence = 0.9, evidenceClass = 'DOMAIN_AUTHORITATIVE',
      correlationKey = 'transport-replay', summary = 'Replay was rejected.',
    }
    local declaredHandler = assert(service.contractHandler({
      name = 'synex.security.signal.report',
      errors = { 'SECURITY_NAMESPACE_DENIED', 'SECURITY_UNAVAILABLE' },
    }))
    local _, declared = declaredHandler(request,
      { caller = 'synex_fixture', callerEpoch = 1 })
    local redactingHandler = assert(service.contractHandler({
      name = 'synex.security.signal.report', errors = { 'SECURITY_UNAVAILABLE' },
    }))
    local _, redacted = redactingHandler(request,
      { caller = 'synex_fixture', callerEpoch = 1 })
    local _, unavailableMethod = service.contractHandler({
      name = 'synex.security.enforce', errors = {} })
    return { declared = declared.code, redacted = redacted.code,
      unavailableMethod = unavailableMethod.code }
  `);

  assert.deepEqual(result, {
    declared: 'SECURITY_NAMESPACE_DENIED',
    redacted: 'SECURITY_UNAVAILABLE',
    unavailableMethod: 'SECURITY_UNAVAILABLE',
  });
});

test('Service calls are rate-limited per owner incarnation and operation', async () => {
  const result = await run<{
    accepted: number;
    limited: string;
    otherOperation: boolean;
    nextEpoch: boolean;
  }>(serviceFiles, `
    local clock = 1000
    local service = SynexSecurityService.create({
      now = function() return clock end,
      signals = {}, expectations = {}, correlation = {}, cases = {}, sentinel = {},
      detectors = {}, decode = function() return {} end,
      encode = function() return '{}' end,
      diagnostics = {
        health = function() return { state = 'READY', detectors = 0, openCases = 0,
          activeExpectations = 0, sentinelSources = 0, persistenceBacklog = 0,
          reasons = {} } end,
        summary = function() return { state = 'READY' } end,
      },
    })
    local context = { caller = 'synex_fixture', callerEpoch = 1 }
    local accepted = 0
    for _ = 1, 10 do
      if service.getHealth({}, context) then accepted = accepted + 1 end
    end
    local _, limited = service.getHealth({}, context)
    local otherOperation = service.getControlSummary({}, context) ~= nil
    local nextEpoch = service.getHealth({},
      { caller = 'synex_fixture', callerEpoch = 2 }) ~= nil
    return { accepted = accepted, limited = limited.code,
      otherOperation = otherOperation, nextEpoch = nextEpoch }
  `);

  assert.deepEqual(result, {
    accepted: 10,
    limited: 'SECURITY_RATE_LIMITED',
    otherOperation: true,
    nextEpoch: true,
  });
});

const runtimeFiles = [
  'resources/synex_security/shared/limits.lua',
  'resources/synex_security/shared/validation.lua',
  'resources/synex_security/server/foundation.lua',
  'resources/synex_security/server/runtime.lua',
] as const;

test('Runtime retries a partial bind without duplicate registrations and fences old generations', async () => {
  const result = await run<{
    initialReady: boolean;
    serviceProvides: number;
    contracts: number;
    providers: number;
    subscriptions: number;
    workers: number;
    initializations: number;
    waits: number;
    revokedEpochs: string;
    unavailableCalls: number;
    oldWorkerFenced: boolean;
    reboundReady: boolean;
    stoppedReady: boolean;
  }>(runtimeFiles, `
    local counts = { service = 0, contracts = 0, providers = 0,
      subscriptions = 0, workers = 0, initialized = 0, waits = 0,
      unavailable = 0, ticks = 0 }
    local states = { synex_security = 'started', synex_fixture = 'started' }
    local revoked, workerCallbacks = {}, {}
    local function callable(handler)
      return setmetatable({}, { __call = function(_, ...) return handler(...) end })
    end
    local function ok() return true end
    local api = {
      ownerEpoch = 11,
      Services = {
        provide = callable(function() counts.service = counts.service + 1; return counts.service end),
        setHealth = callable(ok),
      },
      RPC = {
        registerServer = callable(function() counts.contracts = counts.contracts + 1; return counts.contracts end),
        registerNetwork = callable(function() counts.contracts = counts.contracts + 1; return counts.contracts end),
      },
      Scheduler = { every = callable(function(_, handler)
        counts.workers = counts.workers + 1
        workerCallbacks[#workerCallbacks + 1] = handler
        return counts.workers
      end) },
      ControlProviders = { register = callable(ok) },
      Ids = { next = callable(function() return 'security:test:0001' end) },
      Players = { getBySource = callable(function() return nil end) },
      Capabilities = { checkResource = callable(ok) },
      Metrics = { increment = callable(ok), gauge = callable(ok), observe = callable(ok) },
      Audit = { append = callable(ok) },
      Events = {
        publish = callable(ok),
        subscribe = callable(function()
          counts.subscriptions = counts.subscriptions + 1
          return counts.subscriptions
        end),
      },
      Database = { null = callable(ok), read = callable(ok), write = callable(ok),
        transaction = callable(ok), maintenance = callable(ok) },
      Access = { ban = callable(ok) },
      Diagnostics = { getSecurityFindings = callable(function() return {} end) },
    }
    local definitions = {}
    local names = {
      'synex.security.signal.report', 'synex.security.expectation.register',
      'synex.security.expectation.revoke', 'synex.security.expectation.list',
      'synex.security.assessment.get', 'synex.security.case.get',
      'synex.security.health.get', 'synex.security.sentinel.report',
    }
    for index, name in ipairs(names) do
      definitions[index] = { name = name, version = '1.0.0',
        network = name == 'synex.security.sentinel.report'
          and 'client-to-server' or 'none', errors = {} }
    end
    local application = SynexSecurityApplication.create({
      resourceName = 'synex_security', coreRef = {},
      service = {
        serviceDefinition = function() return { name = 'synex.security' } end,
        contractHandler = function() return function() return true end end,
      },
      controlProvider = { register = function()
        counts.providers = counts.providers + 1
        return counts.providers
      end },
      expectations = {
        revokeOwner = function(owner, epoch)
          revoked[#revoked + 1] = owner .. ':' .. epoch
          return 1
        end,
        activateOwner = function() return true end,
      },
      ownerEpochs = {}, topics = { 'topic.one', 'topic.two' },
      acquireCore = function() return api end,
      loadResourceFile = function() return 'contract-bundle' end,
      decode = function() return { schema = 1, domain = 'synex.security',
        contracts = definitions } end,
      getResourceState = function(name) return states[name] or 'missing' end,
      createThread = function(handler) handler() end,
      wait = function() counts.waits = counts.waits + 1 end,
      onCoreReady = function()
        counts.initialized = counts.initialized + 1
        if counts.initialized == 1 then
          return nil, { code = 'SECURITY_PERSISTENCE_UNAVAILABLE', retryable = true }
        end
        return true
      end,
      onCoreUnavailable = function()
        counts.unavailable = counts.unavailable + 1
        return true
      end,
      onTick = function() counts.ticks = counts.ticks + 1; return true end,
    })
    assert(application.start())
    local initialReady = application.ready()
    assert(application.activateOwner('synex_fixture', 1))
    assert(application.activateOwner('synex_fixture', 2))
    application.resourceStopped('synex_fixture')
    application.resourceStopped('synex_core')
    local unavailableCalls = counts.unavailable
    application.resourceStarted('synex_core')
    workerCallbacks[1]()
    workerCallbacks[2]()
    local oldWorkerFenced = counts.ticks == 1
    local reboundReady = application.ready()
    application.resourceStopped('synex_security')
    table.sort(revoked)
    return { initialReady = initialReady, serviceProvides = counts.service,
      contracts = counts.contracts, providers = counts.providers,
      subscriptions = counts.subscriptions, workers = counts.workers,
      initializations = counts.initialized, waits = counts.waits,
      revokedEpochs = table.concat(revoked, ','),
      unavailableCalls = unavailableCalls, oldWorkerFenced = oldWorkerFenced,
      reboundReady = reboundReady, stoppedReady = application.ready() }
  `);

  assert.deepEqual(result, {
    initialReady: true,
    serviceProvides: 2,
    contracts: 16,
    providers: 2,
    subscriptions: 4,
    workers: 2,
    initializations: 3,
    waits: 1,
    revokedEpochs: 'synex_fixture:1,synex_fixture:2',
    unavailableCalls: 1,
    oldWorkerFenced: true,
    reboundReady: true,
    stoppedReady: false,
  });
});
