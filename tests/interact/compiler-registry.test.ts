import assert from 'node:assert/strict';
import test from 'node:test';

import { interactBundleFactory, runInteractLua } from './helpers.js';

test('interaction compiler separates semantic tags, permissions, and client discovery policy', async () => {
  const result = await runInteractLua<{
    valid: boolean;
    badTag: string;
    badPermission: string;
    policyHidden: boolean;
    graphHidden: boolean;
  }>(`${interactBundleFactory}
    local bundle = __interactBundle()
    bundle.intents[1].executionPolicy.requiredCapability = 'synex.terminal.use'
    local compiled, compileError = SynexInteractCompiler.compile(bundle, 'fixture', 1)
    assert(compiled, compileError and compileError.code)

    local invalidTag = __interactBundle()
    invalidTag.smartObjects[1].tags = { 'fixture:legacy_tag' }
    local _, tagError = SynexInteractCompiler.compile(invalidTag, 'fixture', 1)

    local invalidPermission = __interactBundle()
    invalidPermission.intents[1].executionPolicy.requiredCapability = 'fixture:permission'
    local _, permissionError = SynexInteractCompiler.compile(invalidPermission, 'fixture', 1)

    return {
      valid = compiled ~= nil,
      badTag = tagError.code,
      badPermission = permissionError.code,
      policyHidden = compiled.discovery[1].intents[1].executionPolicy == nil,
      graphHidden = compiled.discovery[1].intents[1].actionGraphRef == nil,
    }
  `);

  assert.equal(result.valid, true);
  assert.equal(result.badTag, 'INTERACT_BUNDLE_INVALID');
  assert.equal(result.badPermission, 'INTERACT_BUNDLE_INVALID');
  assert.equal(result.policyHidden, true);
  assert.equal(result.graphHidden, true);
});

test('progress nodes preserve real determinate values and reject fake or ambiguous modes', async () => {
  const result = await runInteractLua<{
    mode: string;
    value: number;
    maximum: number;
    timedMode: string;
    indeterminateMode: string;
    invalidRange: string;
    missingDuration: string;
    conflictingDuration: string;
  }>(`${interactBundleFactory}
    local determinate = __interactBundle({
      key = 'fixture:inspect_graph', entry = 'progress', nodes = {
        { key = 'progress', type = 'progress', presentation = {
          label = 'Scanning', mode = 'determinate', value = 7, maximum = 20,
        }, next = 'complete' },
        { key = 'complete', type = 'complete' },
      },
    })
    local compiled = assert(SynexInteractCompiler.compile(determinate, 'fixture', 1))
    local presentation = compiled.graphs['fixture:inspect_graph'].nodes.progress.presentation

    local timed = __interactBundle({
      key = 'fixture:inspect_graph', entry = 'progress', nodes = {
        { key = 'progress', type = 'progress', durationMs = 500,
          presentation = { label = 'Waiting' }, next = 'complete' },
        { key = 'complete', type = 'complete' },
      },
    })
    local timedCompiled = assert(SynexInteractCompiler.compile(timed, 'fixture', 1))

    local indeterminate = __interactBundle({
      key = 'fixture:inspect_graph', entry = 'progress', nodes = {
        { key = 'progress', type = 'progress', next = 'complete' },
        { key = 'complete', type = 'complete' },
      },
    })
    local indeterminateCompiled = assert(
      SynexInteractCompiler.compile(indeterminate, 'fixture', 1))

    local badRange = __interactBundle()
    badRange.graphs[1].nodes = {
      { key = 'progress', type = 'progress', presentation = {
        mode = 'determinate', value = 21, maximum = 20,
      }, next = 'complete' },
      { key = 'complete', type = 'complete' },
    }
    badRange.graphs[1].entry = 'progress'
    local _, rangeError = SynexInteractCompiler.compile(badRange, 'fixture', 1)

    local missing = __interactBundle()
    missing.graphs[1].nodes = {
      { key = 'progress', type = 'progress', presentation = {
        mode = 'timed',
      }, next = 'complete' },
      { key = 'complete', type = 'complete' },
    }
    missing.graphs[1].entry = 'progress'
    local _, missingError = SynexInteractCompiler.compile(missing, 'fixture', 1)

    local conflict = __interactBundle()
    conflict.graphs[1].nodes = {
      { key = 'progress', type = 'progress', durationMs = 500,
        presentation = { mode = 'timed', durationMs = 600 }, next = 'complete' },
      { key = 'complete', type = 'complete' },
    }
    conflict.graphs[1].entry = 'progress'
    local _, conflictError = SynexInteractCompiler.compile(conflict, 'fixture', 1)

    return {
      mode = presentation.mode, value = presentation.value,
      maximum = presentation.maximum,
      timedMode = timedCompiled.graphs['fixture:inspect_graph'].nodes.progress.presentation.mode,
      indeterminateMode = indeterminateCompiled.graphs['fixture:inspect_graph']
        .nodes.progress.presentation.mode,
      invalidRange = rangeError.code, missingDuration = missingError.code,
      conflictingDuration = conflictError.code,
    }
  `);

  assert.deepEqual(result, {
    mode: 'determinate',
    value: 7,
    maximum: 20,
    timedMode: 'timed',
    indeterminateMode: 'indeterminate',
    invalidRange: 'INTERACT_BUNDLE_INVALID',
    missingDuration: 'INTERACT_BUNDLE_INVALID',
    conflictingDuration: 'INTERACT_BUNDLE_INVALID',
  });
});

test('availability and concurrency policies are closed, owner-fenced, and dependency-checked', async () => {
  const result = await runInteractLua<{
    mode: string;
    initial: string;
    occupiedDefinition: string;
    unknownPolicy: string;
    foreignEvaluator: string;
    missingEvaluator: string;
    ready: boolean;
  }>(`${interactBundleFactory}
    local bundle = __interactBundle()
    bundle.smartObjects[1].availabilityPolicy = {
      enabled = true, evaluator = 'fixture:available', arguments = { state = 'open' },
    }
    bundle.smartObjects[1].concurrencyPolicy = { mode = 'exclusive' }
    bundle.smartObjects[1].slots[1].availabilityPolicy = { enabled = true }
    local compiled = assert(SynexInteractCompiler.compile(bundle, 'fixture', 1))

    local occupied = __interactBundle()
    occupied.smartObjects[1].slots[1].initialState = 'OCCUPIED'
    local _, occupiedError = SynexInteractCompiler.compile(occupied, 'fixture', 1)

    local unknown = __interactBundle()
    unknown.smartObjects[1].concurrencyPolicy = { mode = 'exclusive', secret = true }
    local _, unknownError = SynexInteractCompiler.compile(unknown, 'fixture', 1)

    local foreign = __interactBundle()
    foreign.smartObjects[1].availabilityPolicy = { evaluator = 'intruder:available' }
    local _, foreignError = SynexInteractCompiler.compile(foreign, 'fixture', 1)

    local registry = SynexInteractRegistry.create({ compiler = SynexInteractCompiler,
      isOwnerCurrent = function(owner, epoch) return owner == 'fixture' and epoch == 1 end })
    assert(registry.register('fixture', 1, bundle))
    local resolved = assert(registry.resolveIntent('fixture:inspect', 1))
    local _, missing = registry.validateRuntimeDependencies(resolved)
    assert(registry.registerEvaluator('fixture', 1,
      { key = 'fixture:available', timeoutMs = 8 }, function() return true end))
    local ready = registry.validateRuntimeDependencies(resolved)
    return { mode = compiled.objects['fixture:terminal'].concurrencyPolicy.mode,
      initial = compiled.objects['fixture:terminal'].slots.operator.initialState,
      occupiedDefinition = occupiedError.code, unknownPolicy = unknownError.code,
      foreignEvaluator = foreignError.code, missingEvaluator = missing.code,
      ready = ready == true }
  `);

  assert.deepEqual(result, {
    mode: 'exclusive',
    initial: 'FREE',
    occupiedDefinition: 'INTERACT_BUNDLE_INVALID',
    unknownPolicy: 'INTERACT_BUNDLE_INVALID',
    foreignEvaluator: 'INTERACT_BUNDLE_INVALID',
    missingEvaluator: 'INTERACT_EVALUATOR_UNAVAILABLE',
    ready: true,
  });
});

test('client visibility evaluators are not server runtime dependencies', async () => {
  const result = await runInteractLua<{
    visibilityReady: boolean;
    graphMissing: string;
    graphReady: boolean;
  }>(`${interactBundleFactory}
    local visibility = __interactBundle()
    visibility.intents[1].visibilityConditions = {{ kind = 'evaluator',
      evaluator = 'fixture:client_visible', arguments = { mode = 'inspect' } }}
    local registry = SynexInteractRegistry.create({ compiler = SynexInteractCompiler,
      isOwnerCurrent = function(owner, epoch) return owner == 'fixture' and epoch == 1 end })
    assert(registry.register('fixture', 1, visibility))
    local resolved = assert(registry.resolveIntent('fixture:inspect', 1))
    local visibilityReady = registry.validateRuntimeDependencies(resolved)

    assert(registry.unregister('fixture', 1, 'fixture:terminal', 1))
    local graph = { key = 'fixture:inspect_graph', entry = 'choose', timeoutMs = 10000,
      nodes = {
        { key = 'choose', type = 'branch', condition = { kind = 'evaluator',
          evaluator = 'fixture:server_gate' }, thenNode = 'complete', elseNode = 'fail' },
        { key = 'complete', type = 'complete' },
        { key = 'fail', type = 'fail', code = 'INTERACT_POLICY_DENIED' },
      } }
    assert(registry.register('fixture', 1, __interactBundle(graph)))
    resolved = assert(registry.resolveIntent('fixture:inspect', 1))
    local _, graphError = registry.validateRuntimeDependencies(resolved)
    assert(registry.registerEvaluator('fixture', 1,
      { key = 'fixture:server_gate' }, function() return true end))
    local graphReady = registry.validateRuntimeDependencies(resolved)
    return { visibilityReady = visibilityReady == true,
      graphMissing = graphError.code, graphReady = graphReady == true }
  `);

  assert.deepEqual(result, {
    visibilityReady: true,
    graphMissing: 'INTERACT_EVALUATOR_UNAVAILABLE',
    graphReady: true,
  });
});

test('bounded extension calls time out yielding handlers without blocking their caller', async () => {
  const result = await runInteractLua<{
    timeout: string;
    clock: number;
    success: boolean;
  }>(`
    local clock, tasks = 0, {}
    local function spawn(handler) tasks[#tasks + 1] = coroutine.create(handler) end
    local function wait(ms)
      clock = clock + math.max(1, ms)
      for _, task in ipairs(tasks) do
        if coroutine.status(task) ~= 'dead' then assert(coroutine.resume(task)) end
      end
    end
    local _, timeoutError = SynexInteractFoundation.boundedCall(function()
      while true do coroutine.yield() end
    end, { now = function() return clock end, wait = wait, spawn = spawn,
      timeoutMs = 8, timeoutCode = 'INTERACT_EVALUATOR_TIMEOUT' })
    local success = SynexInteractFoundation.boundedCall(function(value)
      return value == 42
    end, { now = function() return clock end, wait = wait, spawn = spawn,
      timeoutMs = 8 }, 42)
    return { timeout = timeoutError.code, clock = clock, success = success == true }
  `);

  assert.equal(result.timeout, 'INTERACT_EVALUATOR_TIMEOUT');
  assert.equal(result.clock >= 8, true);
  assert.equal(result.success, true);
});

test('interaction graph compiler rejects cycles, incomplete typed calls, and unsafe cleanup paths', async () => {
  const result = await runInteractLua<{
    cycle: string;
    cycleFinding: string;
    typed: string;
    cleanup: string;
    cleanupFinding: string;
    arbitrary: string;
  }>(`${interactBundleFactory}
    local cycle = __interactBundle({ key = 'fixture:inspect_graph', entry = 'loop', nodes = {
      { key = 'loop', type = 'wait', durationMs = 1, next = 'loop' },
      { key = 'complete', type = 'complete' },
    } })
    local _, cycleError = SynexInteractCompiler.compile(cycle, 'fixture', 1)

    local typed = __interactBundle({ key = 'fixture:inspect_graph', entry = 'call', nodes = {
      { key = 'call', type = 'serviceCall', adapter = 'fixture:accounts', next = 'complete' },
      { key = 'complete', type = 'complete' },
    } })
    local _, typedError = SynexInteractCompiler.compile(typed, 'fixture', 1)

    local cleanup = __interactBundle({ key = 'fixture:inspect_graph', entry = 'verify', nodes = {
      { key = 'verify', type = 'verifyLease', cleanup = 'unsafe', next = 'complete' },
      { key = 'unsafe', type = 'progress', presentation = {}, next = 'complete' },
      { key = 'complete', type = 'complete' },
    } })
    local _, cleanupError = SynexInteractCompiler.compile(cleanup, 'fixture', 1)

    local arbitrary = __interactBundle({ key = 'fixture:inspect_graph', entry = 'event', nodes = {
      { key = 'event', type = 'triggerEvent', next = 'complete' },
      { key = 'complete', type = 'complete' },
    } })
    local _, arbitraryError = SynexInteractCompiler.compile(arbitrary, 'fixture', 1)

    return { cycle = cycleError.code,
      cycleFinding = cycleError.details.diagnosticCode,
      typed = typedError.code, cleanup = cleanupError.code,
      cleanupFinding = cleanupError.details.diagnosticCode,
      arbitrary = arbitraryError.code }
  `);

  assert.deepEqual(result, {
    cycle: 'INTERACT_BUNDLE_INVALID',
    cycleFinding: 'INTERACT_GRAPH_CYCLE',
    typed: 'INTERACT_BUNDLE_INVALID',
    cleanup: 'INTERACT_BUNDLE_INVALID',
    cleanupFinding: 'INTERACT_MISSING_CLEANUP',
    arbitrary: 'INTERACT_BUNDLE_INVALID',
  });
});

test('interaction graph compiler rejects fallthrough paths and ignores cleanup-only terminals', async () => {
  const result = await runInteractLua<{
    branch: string;
    cleanupOnly: string;
    valid: boolean;
  }>(`${interactBundleFactory}
    local branch = __interactBundle({ key = 'fixture:inspect_graph', entry = 'choose', nodes = {
      { key = 'choose', type = 'branch',
        condition = { kind = 'declarative', path = 'actor.alive', operator = 'truthy' },
        thenNode = 'complete', elseNode = 'fallthrough' },
      { key = 'fallthrough', type = 'wait', durationMs = 0 },
      { key = 'complete', type = 'complete' },
    } })
    local _, branchError = SynexInteractCompiler.compile(branch, 'fixture', 1)

    local cleanupOnly = __interactBundle({ key = 'fixture:inspect_graph', entry = 'work', nodes = {
      { key = 'work', type = 'wait', durationMs = 0, cleanup = 'cleanup' },
      { key = 'cleanup', type = 'sequence', children = { 'release', 'complete' } },
      { key = 'release', type = 'releaseLocks' },
      { key = 'complete', type = 'complete' },
    } })
    local _, cleanupError = SynexInteractCompiler.compile(cleanupOnly, 'fixture', 1)
    local valid = SynexInteractCompiler.compile(__interactBundle(), 'fixture', 1)
    return { branch = branchError.code, cleanupOnly = cleanupError.code,
      valid = valid ~= nil }
  `);

  assert.deepEqual(result, {
    branch: 'INTERACT_BUNDLE_INVALID',
    cleanupOnly: 'INTERACT_BUNDLE_INVALID',
    valid: true,
  });
});

test('compiler failures retain bounded Doctor classifications for rejected bundles', async () => {
  const result = await runInteractLua<string[]>(`${interactBundleFactory}
    local function finding(bundle)
      local _, operationError = SynexInteractCompiler.compile(bundle, 'fixture', 1)
      assert(operationError and operationError.details)
      return operationError.details.diagnosticCode
    end
    local values = {}

    local duplicate = __interactBundle()
    duplicate.smartObjects[2] = SynexInteractValidation.copy(duplicate.smartObjects[1])
    values[#values + 1] = finding(duplicate)

    local broken = __interactBundle()
    broken.intents[1].actionGraphRef = 'fixture:missing_graph'
    values[#values + 1] = finding(broken)

    local binding = __interactBundle()
    binding.smartObjects[1].binding = { type = 'unknown' }
    values[#values + 1] = finding(binding)

    local archetype = __interactBundle()
    archetype.smartObjects[1].binding = { type = 'entityArchetype' }
    values[#values + 1] = finding(archetype)

    local bone = __interactBundle()
    bone.smartObjects[1].binding = { type = 'entityBone', model = 123, bone = '' }
    values[#values + 1] = finding(bone)

    local slot = __interactBundle()
    slot.smartObjects[1].slots[1].interactionRadius = 999
    values[#values + 1] = finding(slot)

    local slotConflict = __interactBundle()
    slotConflict.smartObjects[1].slots[2] = SynexInteractValidation.copy(
      slotConflict.smartObjects[1].slots[1])
    values[#values + 1] = finding(slotConflict)

    local entry = __interactBundle()
    entry.graphs[1].entry = 'missing'
    values[#values + 1] = finding(entry)

    local retry = __interactBundle({ key = 'fixture:inspect_graph', entry = 'retry',
      nodes = {
        { key = 'retry', type = 'retry', children = { 'complete' } },
        { key = 'complete', type = 'complete' },
      } })
    values[#values + 1] = finding(retry)

    local unreachable = __interactBundle()
    unreachable.graphs[1].nodes[3] = { key = 'unused', type = 'complete' }
    values[#values + 1] = finding(unreachable)
    return values
  `);

  assert.deepEqual(result, [
    'INTERACT_DUPLICATE_KEY',
    'INTERACT_BROKEN_REFERENCE',
    'INTERACT_UNKNOWN_BINDING',
    'INTERACT_INVALID_ENTITY_ARCHETYPE',
    'INTERACT_INVALID_BONE',
    'INTERACT_INVALID_SLOT',
    'INTERACT_SLOT_CONFLICT',
    'INTERACT_GRAPH_MISSING_ENTRY',
    'INTERACT_UNBOUNDED_RETRY',
    'INTERACT_UNREACHABLE_NODE',
  ]);
});

test('registry activation is atomic and runtime extensions remain owner and epoch fenced', async () => {
  const result = await runInteractLua<{
    before: string;
    after: boolean;
    collision: string;
    unchanged: boolean;
    callbackAccepted: boolean;
  }>(`${interactBundleFactory}
    local epochs = { fixture = 7, intruder = 3 }
    local registry = SynexInteractRegistry.create({
      compiler = SynexInteractCompiler,
      isOwnerCurrent = function(owner, epoch) return epochs[owner] == epoch end,
    })
    local graph = {
      key = 'fixture:inspect_graph', entry = 'call', timeoutMs = 10000,
      nodes = {
        { key = 'call', type = 'serviceCall', adapter = 'fixture:domain',
          service = 'synex.accounts', version = '1.0.0', method = 'inspect',
          request = {}, next = 'complete' },
        { key = 'complete', type = 'complete' },
      },
    }
    local registered = assert(registry.register('fixture', 7, __interactBundle(graph)))
    local resolved = assert(registry.resolveIntent('fixture:inspect', 1))
    local _, missing = registry.validateRuntimeDependencies(resolved)
    local callable = setmetatable({}, { __call = function() return true end })
    local token = assert(registry.registerAdapter('fixture', 7,
      { key = 'fixture:domain', timeoutMs = 20 }, callable))
    local ready = registry.validateRuntimeDependencies(resolved)

    local foreign = __interactBundle()
    foreign.key = 'intruder:bundle'
    foreign.smartObjects[1].key = 'fixture:terminal'
    local _, collision = registry.register('intruder', 3, foreign)
    local snapshot = registry.snapshot()
    local discovery = registry.discovery({
      knownRevision = registry.currentRevision(), snapshotRevision = 0, page = 1,
    })
    return { before = missing.code, after = ready == true,
      collision = collision.code, unchanged = discovery.unchanged,
      callbackAccepted = token ~= nil and snapshot.bundles == 1 }
  `);

  assert.deepEqual(result, {
    before: 'INTERACT_ADAPTER_MISSING',
    after: true,
    collision: 'INTERACT_BUNDLE_CONFLICT',
    unchanged: true,
    callbackAccepted: true,
  });
});

test('discovery pages are transport-bounded, deterministic, and revision fenced', async () => {
  const result = await runInteractLua<{
    pages: Array<{
      revision: number;
      unchanged: boolean;
      page: number;
      pageCount: number;
      complete: boolean;
      objectCount: number;
      totalBytes: number;
      payload: string;
    }>;
    total: number;
    payload: string;
    unchanged: boolean;
    stale: string;
    invalid: string;
    oversized: string;
  }>(`${interactBundleFactory}
    local function fixture(index)
      local owner = ('fixture_%03d'):format(index)
      local bundle = __interactBundle()
      bundle.key = owner .. ':bundle'
      bundle.smartObjects[1].key = owner .. ':terminal'
      bundle.smartObjects[1].activities[1] = owner .. ':inspect'
      bundle.intents[1].key = owner .. ':inspect'
      bundle.intents[1].smartObjectKey = owner .. ':terminal'
      bundle.intents[1].actionGraphRef = owner .. ':inspect_graph'
      bundle.graphs[1].key = owner .. ':inspect_graph'
      return owner, bundle
    end
    local registry = SynexInteractRegistry.create({
      compiler = SynexInteractCompiler,
      isOwnerCurrent = function() return true end,
    })
    for index = 1, 129 do
      local owner, bundle = fixture(index)
      assert(registry.register(owner, 1, bundle))
    end
    local first = assert(registry.discovery({
      knownRevision = 0, snapshotRevision = 0, page = 1,
    }))
    local pages, chunks = {}, {}
    for page = 1, first.pageCount do
      local value = page == 1 and first or assert(registry.discovery({
        knownRevision = 0, snapshotRevision = first.revision, page = page,
      }))
      pages[#pages + 1] = value
      chunks[#chunks + 1] = value.payload
    end
    local unchanged = assert(registry.discovery({
      knownRevision = first.revision, snapshotRevision = 0, page = 1,
    }))
    local owner, bundle = fixture(130)
    assert(registry.register(owner, 1, bundle))
    local _, stale = registry.discovery({
      knownRevision = 0, snapshotRevision = first.revision, page = 2,
    })
    local _, invalid = registry.discovery({
      knownRevision = 0, snapshotRevision = 0, page = 0,
    })
    owner, bundle = fixture(131)
    bundle.smartObjects[1].presentation = {
      description = string.rep('x', SynexInteractLimits.maximumDiscoveryPayloadBytes),
    }
    assert(registry.register(owner, 1, bundle))
    local _, oversized = registry.discovery({
      knownRevision = 0, snapshotRevision = 0, page = 1,
    })
    return { pages = pages, total = first.objectCount,
      payload = table.concat(chunks), unchanged = unchanged.unchanged,
      stale = stale.code, invalid = invalid.code, oversized = oversized.code }
  `);

  assert.equal(result.total, 129);
  assert.ok(result.pages.length >= 2 && result.pages.length <= 24);
  for (const [index, page] of result.pages.entries()) {
    assert.equal(page.page, index + 1);
    assert.equal(page.pageCount, result.pages.length);
    assert.equal(page.unchanged, false);
    assert.equal(page.complete, index + 1 === result.pages.length);
    assert.equal(page.objectCount, 129);
    assert.equal(page.totalBytes, Buffer.byteLength(result.payload, 'utf8'));
    assert.ok(Buffer.byteLength(page.payload, 'utf8') <= 14_000);
    assert.equal(Object.keys(page).length, 9);
    assert.ok(Buffer.byteLength(JSON.stringify(page), 'utf8') < 32_768);
  }
  assert.equal((JSON.parse(result.payload) as unknown[]).length, 129);
  assert.equal(result.unchanged, true);
  assert.equal(result.stale, 'INTERACT_DISCOVERY_STALE');
  assert.equal(result.invalid, 'INTERACT_INVALID_REQUEST');
  assert.equal(result.oversized, 'INTERACT_PAYLOAD_TOO_LARGE');
});
