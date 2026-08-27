import assert from 'node:assert/strict';
import test from 'node:test';
import type { LuaEngine } from 'wasmoon';
import { LuaFactory } from 'wasmoon';
import { bootstrapControlLua, source } from './helpers.js';

function luaLiteral(value: unknown): string {
  if (value === null || value === undefined) return 'nil';
  if (typeof value === 'boolean' || typeof value === 'number') return String(value);
  if (typeof value === 'string') return JSON.stringify(value);
  if (Array.isArray(value)) return `{ ${value.map(luaLiteral).join(', ')} }`;
  if (typeof value === 'object') {
    return `{ ${Object.entries(value as Record<string, unknown>)
      .filter(([, item]) => item !== undefined)
      .map(([key, item]) => `[${JSON.stringify(key)}] = ${luaLiteral(item)}`)
      .join(', ')} }`;
  }
  throw new TypeError(`unsupported Lua fixture value: ${typeof value}`);
}

async function bootstrapRegistry(engine: LuaEngine): Promise<void> {
  await bootstrapControlLua(engine);
  const registrySource = await source('core/synex_core/server/control_providers.lua');
  await engine.doString(`
    SynexCoreFactories = {}
    assert(load(${JSON.stringify(registrySource)},
      '@core/synex_core/server/control_providers.lua'))()

    function CreateControlRegistryHarness(asynchronous)
      local now = 1000
      local current = { synex_control = 1 }
      local cleanups = {}
      local manifests = {}
      local metricEvents = {}
      local copyStats = { calls = 0, hugeStrings = 0 }
      local encodeStats = { calls = 0, hugeResponses = 0 }

      local function copy(value, seen)
        copyStats.calls = copyStats.calls + 1
        if type(value) == 'string' and #value >= 50 * 1024 * 1024 then
          copyStats.hugeStrings = copyStats.hugeStrings + 1
        end
        if type(value) ~= 'table' then return value end
        seen = seen or {}
        if seen[value] then error('cycle') end
        seen[value] = true
        local result = {}
        for key, item in pairs(value) do result[copy(key, seen)] = copy(item, seen) end
        seen[value] = nil
        return result
      end

      local metrics = {}
      function metrics:increment(name, labels)
        metricEvents[#metricEvents + 1] = { kind = 'increment', name = name, labels = labels }
      end
      function metrics:observe(name, labels, value)
        metricEvents[#metricEvents + 1] = {
          kind = 'observe', name = name, labels = labels, value = value,
        }
      end

      local foundation = {
        metrics = metrics,
        monotonicMs = function() return now end,
        utcIso = function() return '2026-08-26T00:00:00Z' end,
        semver = function(value)
          local major, minor, patch = type(value) == 'string'
            and value:match('^(%d+)%.(%d+)%.(%d+)$') or nil
          return major and { major = tonumber(major), minor = tonumber(minor), patch = tonumber(patch) }
            or nil
        end,
        isCallable = function(value) return type(value) == 'function' end,
        jsonContainerKind = function(value)
          if type(value) ~= 'table' then return nil end
          local count, maximum, array = 0, 0, true
          for key in pairs(value) do
            count = count + 1
            if type(key) ~= 'number' or math.type(key) ~= 'integer' or key < 1 then
              array = false
            else
              maximum = math.max(maximum, key)
            end
          end
          return count > 0 and array and maximum == count and 'array' or 'object'
        end,
        copy = copy,
        readonly = function(value) return value end,
        safeCall = function(handler, ...)
          local values = table.pack(pcall(handler, ...))
          local ok = values[1]
          if not ok then return false, values[2] end
          return true, table.unpack(values, 2, values.n)
        end,
        failureCode = function(value, fallback)
          return type(value) == 'table' and type(value.code) == 'string'
            and value.code or fallback
        end,
        error = function(code, message, options)
          local value = { code = code, message = message }
          for key, item in pairs(options or {}) do value[key] = item end
          return value
        end,
      }
      local owners = {}
      function owners:isCurrent(resource, epoch) return current[resource] == epoch end
      function owners:track(resource, epoch, kind, key, cleanup)
        if not self:isCurrent(resource, epoch) then
          return nil, foundation.error('STALE_RESOURCE', 'stale')
        end
        cleanups[resource .. ':' .. kind .. ':' .. key] = cleanup
        return true, nil
      end
      function owners:beginOperation(resource, epoch)
        if not self:isCurrent(resource, epoch) then
          return nil, foundation.error('STALE_RESOURCE', 'stale')
        end
        return resource .. ':' .. tostring(epoch), nil
      end
      function owners:finishOperation() return true, nil end

      local platform = { jsonEncode = function(value)
        encodeStats.calls = encodeStats.calls + 1
        local data = type(value) == 'table' and rawget(value, 'data') or nil
        local payload = type(data) == 'table' and rawget(data, 'value') or nil
        if type(payload) == 'string' and #payload >= 50 * 1024 * 1024 then
          encodeStats.hugeResponses = encodeStats.hugeResponses + 1
        end
        return json.encode(value)
      end }
      if asynchronous then
        local threads = {}
        platform.createThread = function(handler)
          threads[#threads + 1] = coroutine.create(handler)
        end
        platform.defer = function()
          now = now + 10
          local currentThreads = threads
          threads = {}
          for _, thread in ipairs(currentThreads) do
            local resumed, resumeError = coroutine.resume(thread)
            assert(resumed, resumeError)
            if coroutine.status(thread) ~= 'dead' then threads[#threads + 1] = thread end
          end
        end
      end
      local registry = SynexCoreFactories.controlProviders({
        platform = platform, foundation = foundation, owners = owners,
        coreResource = 'synex_core',
        manifestFor = function(resource) return manifests[resource] end,
      })
      return {
        registry = registry, current = current, cleanups = cleanups,
        manifests = manifests, metricEvents = metricEvents,
        copyStats = copyStats, encodeStats = encodeStats,
        advance = function(milliseconds) now = now + milliseconds end,
        setNow = function(value) now = value end,
      }
    end
  `);
}

test('Core Control registry fences declarations, duplicates, owner epochs, and cleanup', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrapRegistry(engine);
    const result = await engine.doString(`
      local harness = CreateControlRegistryHarness()
      harness.current.synex_fixture = 1
      harness.current.synex_other = 1
      local declaration = {
        schemaVersion = 1, namespace = 'fixture', label = 'Fixture', category = 'domain',
        version = '1.0.0', operations = { 'summary' }, views = {{
          id = 'overview', label = 'Overview', operation = 'summary',
          presentation = 'key-value', accessClass = 'general', order = 10,
        }},
      }
      harness.manifests.synex_fixture = { controlProvider = declaration }
      local declared, declarationError = harness.registry:declare('synex_fixture', declaration)
      assert(declared and declarationError == nil and declared.health == 'UNAVAILABLE',
        declarationError and declarationError.code or 'DECLARATION_REJECTED')

      local _, duplicateDeclaration = harness.registry:declare('synex_other', declaration)
      assert(duplicateDeclaration.code == 'DUPLICATE_CONTROL_PROVIDER')

      local definition = {
        schemaVersion = 1, namespace = 'fixture', label = 'Fixture', category = 'domain',
        version = '1.0.0', operations = {
          summary = function(_, context)
            assert(context.readOnly == true and context.mode == 'observe')
            return { status = 'HEALTHY' }, nil
          end,
        },
        views = declaration.views,
      }
      local _, staleError = harness.registry:register('synex_fixture', 2, definition)
      assert(staleError.code == 'STALE_RESOURCE')
      local metadata, registrationError = harness.registry:register('synex_fixture', 1, definition)
      assert(metadata and registrationError == nil and metadata.namespace == 'fixture')
      assert(metadata.capabilities[1] == 'summary')
      local _, duplicateRegistration = harness.registry:register('synex_fixture', 1, definition)
      assert(duplicateRegistration.code == 'DUPLICATE_CONTROL_PROVIDER')

      local response, invokeError = harness.registry:invoke(
        'synex_control', 1, 'fixture', 'summary', {}, { timeoutMs = 500 }, 'trace-fixture-01')
      assert(response and invokeError == nil and response.data.status == 'HEALTHY')

      harness.current.synex_fixture = 2
      local _, restartedError = harness.registry:invoke(
        'synex_control', 1, 'fixture', 'summary', {}, {}, 'trace-fixture-02')
      assert(restartedError.code == 'CONTROL_PROVIDER_NOT_FOUND')
      harness.cleanups['synex_fixture:control_provider:fixture']()
      local listed = assert(harness.registry:list())
      assert(#listed.providers == 1)
      assert(listed.providers[1].namespace == 'fixture')
      assert(listed.providers[1].health == 'UNAVAILABLE')
      return table.concat({
        duplicateDeclaration.code, staleError.code, duplicateRegistration.code,
        restartedError.code, listed.providers[1].health,
      }, ':')
    `);
    assert.equal(result,
      'DUPLICATE_CONTROL_PROVIDER:STALE_RESOURCE:DUPLICATE_CONTROL_PROVIDER:'
      + 'CONTROL_PROVIDER_NOT_FOUND:UNAVAILABLE');
  } finally {
    engine.global.close();
  }
});

test('Core Control registry normalizes legacy domain health without hiding raw doctor status', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrapRegistry(engine);
    const result = await engine.doString(`
      local harness = CreateControlRegistryHarness()
      harness.current.synex_fixture = 1
      local declaration = {
        schemaVersion = 1, namespace = 'fixture', label = 'Fixture', category = 'domain',
        version = '1.0.0', operations = { 'summary', 'health' }, views = {
          { id = 'overview', label = 'Overview', operation = 'summary',
            presentation = 'key-value', accessClass = 'general', order = 10 },
          { id = 'health', label = 'Health', operation = 'health',
            presentation = 'key-value', accessClass = 'general', order = 20 },
        },
      }
      harness.manifests.synex_fixture = { controlProvider = declaration }
      assert(harness.registry:declare('synex_fixture', declaration))
      local reported = 'PASS'
      assert(harness.registry:register('synex_fixture', 1, {
        schemaVersion = 1, namespace = 'fixture', label = 'Fixture', category = 'domain',
        version = '1.0.0', views = declaration.views, operations = {
          summary = function() return { status = reported }, nil end,
          health = function() return { status = reported, doctorStatus = reported }, nil end,
        },
      }))
      local function health()
        local response = assert(harness.registry:invoke('synex_control', 1, 'fixture',
          'health', { view = 'health' }, {}, 'trace-health-fixture'))
        local metadata = assert(harness.registry:describe('fixture'))
        return response.data.status, response.data.doctorStatus, metadata.health
      end
      local pass, rawPass, normalizedPass = health()
      reported = 'WARN'
      local warn, rawWarn, normalizedWarn = health()
      reported = 'FAIL'
      local fail, rawFail, normalizedFail = health()
      reported = 'PASS'
      local recovered, rawRecovered, normalizedRecovered = health()
      reported = 'MYSTERY'
      local _, invalidHealth = harness.registry:invoke('synex_control', 1, 'fixture',
        'health', { view = 'health' }, {}, 'trace-health-invalid')
      assert(invalidHealth.code == 'INVALID_PROVIDER_RESPONSE')
      return table.concat({ pass, rawPass, normalizedPass, warn, rawWarn, normalizedWarn,
        fail, rawFail, normalizedFail, recovered, rawRecovered, normalizedRecovered,
        invalidHealth.code }, ':')
    `);
    assert.equal(result,
      'HEALTHY:PASS:HEALTHY:WARNING:WARN:WARNING:ERROR:FAIL:ERROR:'
      + 'HEALTHY:PASS:HEALTHY:INVALID_PROVIDER_RESPONSE');
  } finally {
    engine.global.close();
  }
});

test('Core Control registry bounds busy, timeout, oversized, circuit, and huge logical pages', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrapRegistry(engine);
    const result = await engine.doString(`
      local harness = CreateControlRegistryHarness()
      harness.current.synex_fixture = 1
      local operations = { 'summary', 'health', 'list', 'inspect', 'search', 'metrics', 'findings' }
      local views = {{
        id = 'overview', label = 'Overview', operation = 'summary',
        presentation = 'key-value', accessClass = 'general', order = 10,
      }}
      harness.manifests.synex_fixture = { controlProvider = {
        schemaVersion = 1, namespace = 'fixture', label = 'Fixture', category = 'domain',
        version = '1.0.0', operations = operations, views = views,
      }}
      local declared, declarationError = harness.registry:declare(
        'synex_fixture', harness.manifests.synex_fixture.controlProvider)
      assert(declared, declarationError and declarationError.code or 'DECLARATION_REJECTED')

      local nestedBusy
      local definition = {
        schemaVersion = 1, namespace = 'fixture', label = 'Fixture', category = 'domain',
        version = '1.0.0', views = views, operations = {},
      }
      definition.operations.summary = function() return { status = 'HEALTHY' }, nil end
      definition.operations.list = function(request)
        if request.invalid == true then return { nested = 'invalid' }, nil end
        local _, nestedError = harness.registry:invoke(
          'synex_control', 1, 'fixture', 'summary', {}, {}, 'trace-nested')
        nestedBusy = nestedError and nestedError.code
        return { items = {}, hasMore = false, truncated = false, nested = nestedBusy }, nil
      end
      definition.operations.health = function()
        harness.advance(100)
        return { status = 'HEALTHY' }, nil
      end
      definition.operations.inspect = function()
        return { value = string.rep('x', 32700) }, nil
      end
      definition.operations.metrics = function(request)
        local total = 10000
        local start = tonumber(request.cursor) or 0
        local limit = math.min(request.limit or 25, 100)
        local items = {}
        for index = start + 1, math.min(start + limit, total) do
          items[#items + 1] = { id = ('row_%05d'):format(index) }
        end
        local nextCursor = start + #items
        return {
          items = items,
          nextCursor = nextCursor < total and tostring(nextCursor) or nil,
          hasMore = nextCursor < total,
          logicalTotal = total,
        }, nil
      end
      definition.operations.search = function(request)
        if request.failure then return nil, { code = request.failure } end
        return { items = {}, hasMore = false, truncated = false }, nil
      end
      definition.operations.findings = function()
        return nil, { code = 'FIXTURE_FAILURE', retryable = true }
      end
      assert(harness.registry:register('synex_fixture', 1, definition))

      local busyEnvelope = assert(harness.registry:invoke(
        'synex_control', 1, 'fixture', 'list', {}, {}, 'trace-busy'))
      assert(busyEnvelope.data.nested == 'CONTROL_PROVIDER_BUSY')
      local _, invalidResponse = harness.registry:invoke(
        'synex_control', 1, 'fixture', 'list', { invalid = true }, {}, 'trace-schema')
      assert(invalidResponse.code == 'INVALID_PROVIDER_RESPONSE')
      assert(harness.registry:invoke(
        'synex_control', 1, 'fixture', 'summary', {}, {}, 'trace-schema-reset'))

      local _, timeoutError = harness.registry:invoke(
        'synex_control', 1, 'fixture', 'health', {}, { timeoutMs = 25 }, 'trace-timeout')
      assert(timeoutError.code == 'PROVIDER_TIMEOUT')
      harness.setNow(2000)
      local _, oversizedError = harness.registry:invoke(
        'synex_control', 1, 'fixture', 'inspect', {}, {}, 'trace-oversized')
      assert(oversizedError.code == 'PROVIDER_RESPONSE_TOO_LARGE')

      assert(harness.registry:invoke(
        'synex_control', 1, 'fixture', 'summary', {}, {}, 'trace-reset'))
      local expected = {
        { cause = 'VALIDATION_FAILED', public = 'INVALID_ARGUMENT' },
        { cause = 'INVALID_ARGUMENT', public = 'INVALID_ARGUMENT' },
        { cause = 'INVALID_CONTROL_PROVIDER_REQUEST', public = 'INVALID_ARGUMENT' },
        { cause = 'NOT_FOUND', public = 'NOT_FOUND' },
        { cause = 'SESSION_NOT_FOUND', public = 'NOT_FOUND' },
        { cause = 'ACCOUNT_NOT_FOUND', public = 'NOT_FOUND' },
        { cause = 'STALE_ENTITY', public = 'STALE_ENTITY' },
        { cause = 'GROUP_ACCESS_DENIED', public = 'NOT_EXPOSED' },
      }
      for index, entry in ipairs(expected) do
        local _, rejected = harness.registry:invoke(
          'synex_control', 1, 'fixture', 'search', { failure = entry.cause }, {},
          'trace-rejected-' .. tostring(index))
        assert(rejected.code == entry.public)
      end
      assert(harness.registry:invoke(
        'synex_control', 1, 'fixture', 'search', {}, {}, 'trace-after-rejections'))
      local firstPage = assert(harness.registry:invoke(
        'synex_control', 1, 'fixture', 'metrics', { limit = 25 }, {}, 'trace-page-01'))
      assert(#firstPage.data.items == 25 and firstPage.data.nextCursor == '25')
      assert(firstPage.data.logicalTotal == 10000 and firstPage.data.hasMore == true)
      local secondPage = assert(harness.registry:invoke(
        'synex_control', 1, 'fixture', 'metrics', {
          limit = 25, cursor = firstPage.data.nextCursor,
        }, {}, 'trace-page-02'))
      assert(#secondPage.data.items == 25)
      assert(secondPage.data.items[1].id == 'row_00026')
      assert(secondPage.data.nextCursor == '50')

      for index = 1, 3 do
        local _, failure = harness.registry:invoke(
          'synex_control', 1, 'fixture', 'findings', {}, {}, 'trace-failure-' .. index)
        assert(failure.code == 'PROVIDER_ERROR')
      end
      local _, circuitError = harness.registry:invoke(
        'synex_control', 1, 'fixture', 'findings', {}, {}, 'trace-circuit')
      assert(circuitError.code == 'CONTROL_PROVIDER_CIRCUIT_OPEN')
      local listed = assert(harness.registry:list())
      assert(listed.providers[1].circuit.state == 'OPEN')
      assert(listed.providers[1].metrics.busy == 1)
      assert(listed.providers[1].metrics.timeouts == 1)
      assert(listed.providers[1].metrics.rejections == 8)
      return table.concat({
        nestedBusy, invalidResponse.code, timeoutError.code, oversizedError.code,
        circuitError.code, secondPage.data.nextCursor,
      }, ':')
    `);
    assert.equal(result,
      'CONTROL_PROVIDER_BUSY:INVALID_PROVIDER_RESPONSE:PROVIDER_TIMEOUT:PROVIDER_RESPONSE_TOO_LARGE:'
      + 'CONTROL_PROVIDER_CIRCUIT_OPEN:50');
  } finally {
    engine.global.close();
  }
});

test('Core Control provider boundary contains 50 MiB, cycles, secrets, and thrown handlers', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrapRegistry(engine);
    const result = await engine.doString(`
      local harness = CreateControlRegistryHarness()
      harness.current.synex_fixture = 1
      local operations = { 'summary', 'inspect', 'list', 'search', 'findings' }
      local views = {{
        id = 'overview', label = 'Overview', operation = 'summary',
        presentation = 'key-value', accessClass = 'general', order = 10,
      }}
      local declaration = {
        schemaVersion = 1, namespace = 'fixture', label = 'Fixture', category = 'domain',
        version = '1.0.0', operations = operations, views = views,
      }
      harness.manifests.synex_fixture = { controlProvider = declaration }
      assert(harness.registry:declare('synex_fixture', declaration))

      local hugeWitness = setmetatable({}, { __mode = 'v' })
      local definition = {
        schemaVersion = 1, namespace = 'fixture', label = 'Fixture', category = 'domain',
        version = '1.0.0', views = views, operations = {
          summary = function() return { status = 'HEALTHY' }, nil end,
          inspect = function()
            local response = { value = string.rep('x', 50 * 1024 * 1024) }
            hugeWitness[1] = response
            return response, nil
          end,
          list = function()
            local response = { items = {}, hasMore = false, truncated = false }
            response.cycle = response
            return response, nil
          end,
          search = function()
            return {
              items = {{
                id = 'session_private_provider_0001',
                nested = {
                  password = 'provider-password-must-not-leak',
                  endpoint = 'mysql://operator:private@database.invalid/synex',
                },
              }},
              hasMore = false,
              truncated = false,
            }, nil
          end,
          findings = function()
            error('provider-private-exception-must-not-leak')
          end,
        },
      }
      assert(harness.registry:register('synex_fixture', 1, definition))

      -- A valid provider response reaches the same final sanitizer used before NUI transport.
      local secretEnvelope = assert(harness.registry:invoke(
        'synex_control', 1, 'fixture', 'search', {}, {}, 'trace-provider-secret'))
      assert(secretEnvelope.data.items[1].nested.password
        == 'provider-password-must-not-leak')
      local sanitized, report, sanitizeError = SynexControlSanitizer.encode(secretEnvelope, {
        maximumBytes = SynexControlLimits.maximumResponseBytes,
        revealIdentifiers = false,
      })
      assert(sanitized and sanitizeError == nil)
      assert(sanitized.data.items[1].id == 'sess...0001')
      assert(sanitized.data.items[1].nested.password == '[REDACTED]')
      assert(sanitized.data.items[1].nested.endpoint == '[REDACTED]')
      assert(report.redactions == 2 and report.masked >= 1)
      local transported = json.encode(sanitized)
      assert(transported:find('provider%-password%-must%-not%-leak') == nil)
      assert(transported:find('operator:private') == nil)

      -- The 50 MiB value is rejected structurally before copy or JSON serialization.
      local hugeEncodesBefore = harness.encodeStats.hugeResponses
      local copiedHugeBefore = harness.copyStats.hugeStrings
      local _, hugeError = harness.registry:invoke(
        'synex_control', 1, 'fixture', 'inspect', {}, {}, 'trace-provider-50mib')
      assert(hugeError.code == 'INVALID_PROVIDER_RESPONSE')
      assert(harness.encodeStats.hugeResponses == hugeEncodesBefore)
      local copiedHugeAfter = harness.copyStats.hugeStrings
      assert(copiedHugeAfter == copiedHugeBefore)
      collectgarbage('collect')
      collectgarbage('collect')
      local hugeRetained = hugeWitness[1] ~= nil
      assert(hugeRetained == false, '50 MiB provider response remained reachable')
      assert(harness.registry:invoke(
        'synex_control', 1, 'fixture', 'summary', {}, {}, 'trace-after-50mib'))

      local _, exceptionError = harness.registry:invoke(
        'synex_control', 1, 'fixture', 'findings', {}, {}, 'trace-provider-exception')
      assert(exceptionError.code == 'PROVIDER_ERROR')
      assert(json.encode(exceptionError):find('provider%-private%-exception') == nil)
      assert(harness.registry:invoke(
        'synex_control', 1, 'fixture', 'summary', {}, {}, 'trace-after-exception'))

      local hugeEncodesBeforeCycle = harness.encodeStats.hugeResponses
      local _, cycleError = harness.registry:invoke(
        'synex_control', 1, 'fixture', 'list', {}, {}, 'trace-provider-cycle')
      assert(cycleError.code == 'INVALID_PROVIDER_RESPONSE')
      assert(harness.encodeStats.hugeResponses == hugeEncodesBeforeCycle)
      return table.concat({ hugeError.code, exceptionError.code, cycleError.code,
        tostring(#transported) }, ':')
    `);
    assert.match(String(result),
      /^INVALID_PROVIDER_RESPONSE:PROVIDER_ERROR:INVALID_PROVIDER_RESPONSE:\d+$/u);
  } finally {
    engine.global.close();
  }
});

test('Core Control registry returns a deadline error for a yielding provider without blocking peers', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrapRegistry(engine);
    const result = await engine.doString(`
      local harness = CreateControlRegistryHarness(true)
      harness.current.synex_hanging = 1
      harness.current.synex_peer = 1
      local function declaration(namespace, resource)
        local value = {
          schemaVersion = 1, namespace = namespace, label = namespace,
          category = 'domain', version = '1.0.0', operations = { 'health' },
          views = {{ id = 'health', label = 'Health', operation = 'health',
            presentation = 'key-value', accessClass = 'general', order = 10 }},
        }
        harness.manifests[resource] = { controlProvider = value }
        local declared, declarationError = harness.registry:declare(resource, value)
        assert(declared, declarationError and declarationError.code or 'DECLARATION_REJECTED')
        return value.views
      end
      local hangingViews = declaration('hanging', 'synex_hanging')
      local peerViews = declaration('peer', 'synex_peer')
      assert(harness.registry:register('synex_hanging', 1, {
        schemaVersion = 1, namespace = 'hanging', label = 'hanging',
        category = 'domain', version = '1.0.0', views = hangingViews,
        operations = { health = function()
          while true do coroutine.yield() end
        end },
      }))
      assert(harness.registry:register('synex_peer', 1, {
        schemaVersion = 1, namespace = 'peer', label = 'peer',
        category = 'domain', version = '1.0.0', views = peerViews,
        operations = { health = function() return { status = 'HEALTHY' }, nil end },
      }))

      local _, timeoutError = harness.registry:invoke(
        'synex_control', 1, 'hanging', 'health', {}, { timeoutMs = 25 }, 'trace-hang')
      assert(timeoutError.code == 'PROVIDER_TIMEOUT')
      local _, busyError = harness.registry:invoke(
        'synex_control', 1, 'hanging', 'health', {}, {}, 'trace-hang-busy')
      assert(busyError.code == 'CONTROL_PROVIDER_BUSY')
      local peer = assert(harness.registry:invoke(
        'synex_control', 1, 'peer', 'health', {}, {}, 'trace-peer'))
      assert(peer.data.status == 'HEALTHY')
      return table.concat({ timeoutError.code, busyError.code, peer.data.status }, ':')
    `);
    assert.equal(result, 'PROVIDER_TIMEOUT:CONTROL_PROVIDER_BUSY:HEALTHY');
  } finally {
    engine.global.close();
  }
});

test('Core Control registry enforces operation and presentation response contracts before exposure', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrapRegistry(engine);
    const result = await engine.doString(`
      local harness = CreateControlRegistryHarness()
      harness.current.synex_fixture = 1
      local views = {
        { id = 'overview', label = 'Overview', operation = 'summary',
          presentation = 'key-value', accessClass = 'general' },
        { id = 'table_rows', label = 'Table rows', operation = 'list',
          presentation = 'table', accessClass = 'general' },
        { id = 'graph', label = 'Graph', operation = 'list',
          presentation = 'graph', accessClass = 'general' },
        { id = 'timeline', label = 'Timeline', operation = 'inspect',
          presentation = 'timeline', accessClass = 'general' },
        { id = 'detail', label = 'Detail', operation = 'inspect',
          presentation = 'detail', accessClass = 'general' },
        { id = 'metrics', label = 'Metrics', operation = 'metrics',
          presentation = 'metrics', accessClass = 'general' },
        { id = 'findings', label = 'Findings', operation = 'findings',
          presentation = 'findings', accessClass = 'general' },
      }
      local declaration = {
        schemaVersion = 1, namespace = 'fixture', label = 'Fixture', category = 'domain',
        version = '1.0.0', operations = {
          'summary', 'list', 'inspect', 'metrics', 'findings',
        },
        views = views,
      }
      harness.manifests.synex_fixture = { controlProvider = declaration }
      assert(harness.registry:declare('synex_fixture', declaration))

      local function row(columns)
        local value = {}
        for index = 1, columns do value['column_' .. tostring(index)] = index end
        return value
      end
      local definition = {
        schemaVersion = 1, namespace = 'fixture', label = 'Fixture', category = 'domain',
        version = '1.0.0', views = views, operations = {},
      }
      definition.operations.summary = function(request)
        if request.invalid == 'empty' then return {}, nil end
        return { status = 'HEALTHY' }, nil
      end
      definition.operations.list = function(request)
        if request.invalid == 'raw_cursor' then
          return {
            cursor = 'provider-private-cursor', items = {}, hasMore = false,
          }, nil
        end
        if request.view == 'graph' then
          if request.invalid == 'shape' then
            return { items = {}, hasMore = false }, nil
          end
          if request.invalid == 'node' then
            return { nodes = { { label = 'missing id' } }, edges = {}, hasMore = false }, nil
          end
          if request.invalid == 'edge' then
            return { nodes = { { id = 'node_a' } }, edges = { { from = 'node_a' } },
              hasMore = false }, nil
          end
          return {
            nodes = { { id = 'node_a', label = 'Node A' } },
            edges = {}, hasMore = false,
          }, nil
        end
        local items = {}
        local rows = request.rows or 1
        for index = 1, rows do items[index] = row(request.columns or 1) end
        return { items = items, hasMore = false }, nil
      end
      definition.operations.inspect = function(request)
        if request.view == 'detail' then
          local value = {}
          for index = 1, (request.columns or 1) do value['field_' .. tostring(index)] = index end
          return value, nil
        end
        local items = {}
        for index = 1, (request.rows or 1) do
          items[index] = request.invalid == 'shape' and { arbitrary = true }
            or { timestamp = tostring(index), label = 'event', status = 'INFO' }
        end
        return { items = items, hasMore = false }, nil
      end
      definition.operations.metrics = function(request)
        if request.invalid == 'items' then return { items = { function() end } }, nil end
        if request.invalid == 'metrics' then return { metrics = { 'not', 'an', 'object' } }, nil end
        return { metrics = { calls = 1, maximumDurationMs = 2 } }, nil
      end
      definition.operations.findings = function(request)
        local items = {}
        for index = 1, (request.rows or 1) do
          items[index] = request.invalid == 'shape'
            and { summary = 'missing severity and identity' }
            or { code = 'FIXTURE', severity = 'INFO', summary = 'safe' }
        end
        return { items = items, hasMore = false }, nil
      end
      assert(harness.registry:register('synex_fixture', 1, definition))

      assert(harness.registry:invoke('synex_control', 1, 'fixture', 'list', {
        view = 'table_rows', rows = 100, columns = 12,
      }, {}, 'trace-table-boundary'))
      local _, wide = harness.registry:invoke('synex_control', 1, 'fixture', 'list', {
        view = 'table_rows', rows = 1, columns = 13,
      }, {}, 'trace-table-wide')
      assert(wide.code == 'INVALID_PROVIDER_RESPONSE')
      assert(harness.registry:invoke('synex_control', 1, 'fixture', 'summary', {
        view = 'overview',
      }, {}, 'trace-reset-wide'))
      local _, tall = harness.registry:invoke('synex_control', 1, 'fixture', 'list', {
        view = 'table_rows', rows = 101, columns = 1,
      }, {}, 'trace-table-tall')
      assert(tall.code == 'INVALID_PROVIDER_RESPONSE')
      assert(harness.registry:invoke('synex_control', 1, 'fixture', 'summary', {
        view = 'overview',
      }, {}, 'trace-reset-tall'))
      local _, rawCursor = harness.registry:invoke(
        'synex_control', 1, 'fixture', 'list', {
          view = 'table_rows', invalid = 'raw_cursor',
        }, {}, 'trace-raw-cursor')
      assert(rawCursor.code == 'INVALID_PROVIDER_RESPONSE')
      assert(harness.registry:invoke('synex_control', 1, 'fixture', 'summary', {
        view = 'overview',
      }, {}, 'trace-reset-raw-cursor'))

      local _, emptySummary = harness.registry:invoke(
        'synex_control', 1, 'fixture', 'summary', {
          view = 'overview', invalid = 'empty',
        }, {}, 'trace-summary-empty')
      assert(emptySummary.code == 'INVALID_PROVIDER_RESPONSE')
      assert(harness.registry:invoke('synex_control', 1, 'fixture', 'summary', {
        view = 'overview',
      }, {}, 'trace-reset-summary'))

      assert(harness.registry:invoke('synex_control', 1, 'fixture', 'inspect', {
        view = 'detail', columns = 100,
      }, {}, 'trace-detail-boundary'))
      local _, wideDetail = harness.registry:invoke('synex_control', 1, 'fixture', 'inspect', {
        view = 'detail', columns = 101,
      }, {}, 'trace-detail-wide')
      assert(wideDetail.code == 'INVALID_PROVIDER_RESPONSE')
      assert(harness.registry:invoke('synex_control', 1, 'fixture', 'summary', {
        view = 'overview',
      }, {}, 'trace-reset-detail'))

      assert(harness.registry:invoke('synex_control', 1, 'fixture', 'metrics', {
        view = 'metrics',
      }, {}, 'trace-metrics-valid'))
      local _, invalidMetrics = harness.registry:invoke(
        'synex_control', 1, 'fixture', 'metrics', {
          view = 'metrics', invalid = 'metrics',
        }, {}, 'trace-metrics-shape')
      assert(invalidMetrics.code == 'INVALID_PROVIDER_RESPONSE')
      assert(harness.registry:invoke('synex_control', 1, 'fixture', 'summary', {
        view = 'overview',
      }, {}, 'trace-reset-metrics'))

      assert(harness.registry:invoke('synex_control', 1, 'fixture', 'list', {
        view = 'graph',
      }, {}, 'trace-graph-valid'))
      local _, wrongGraph = harness.registry:invoke('synex_control', 1, 'fixture', 'list', {
        view = 'graph', invalid = 'shape',
      }, {}, 'trace-graph-wrong-shape')
      assert(wrongGraph.code == 'INVALID_PROVIDER_RESPONSE')
      assert(harness.registry:invoke('synex_control', 1, 'fixture', 'summary', {
        view = 'overview',
      }, {}, 'trace-reset-graph'))
      local _, invalidNode = harness.registry:invoke('synex_control', 1, 'fixture', 'list', {
        view = 'graph', invalid = 'node',
      }, {}, 'trace-graph-node')
      assert(invalidNode.code == 'INVALID_PROVIDER_RESPONSE')
      assert(harness.registry:invoke('synex_control', 1, 'fixture', 'summary', {
        view = 'overview',
      }, {}, 'trace-reset-node'))

      assert(harness.registry:invoke('synex_control', 1, 'fixture', 'inspect', {
        view = 'timeline', rows = 100,
      }, {}, 'trace-timeline-boundary'))
      local _, tallTimeline = harness.registry:invoke('synex_control', 1, 'fixture', 'inspect', {
        view = 'timeline', rows = 101,
      }, {}, 'trace-timeline-tall')
      assert(tallTimeline.code == 'INVALID_PROVIDER_RESPONSE')
      assert(harness.registry:invoke('synex_control', 1, 'fixture', 'summary', {
        view = 'overview',
      }, {}, 'trace-reset-timeline'))
      local _, malformedTimeline = harness.registry:invoke(
        'synex_control', 1, 'fixture', 'inspect', {
          view = 'timeline', rows = 1, invalid = 'shape',
        }, {}, 'trace-timeline-shape')
      assert(malformedTimeline.code == 'INVALID_PROVIDER_RESPONSE')
      assert(harness.registry:invoke('synex_control', 1, 'fixture', 'summary', {
        view = 'overview',
      }, {}, 'trace-reset-timeline-shape'))

      assert(harness.registry:invoke('synex_control', 1, 'fixture', 'findings', {
        view = 'findings', rows = 100,
      }, {}, 'trace-findings-boundary'))
      local _, tallFindings = harness.registry:invoke('synex_control', 1, 'fixture', 'findings', {
        view = 'findings', rows = 101,
      }, {}, 'trace-findings-tall')
      assert(tallFindings.code == 'INVALID_PROVIDER_RESPONSE')
      assert(harness.registry:invoke('synex_control', 1, 'fixture', 'summary', {
        view = 'overview',
      }, {}, 'trace-reset-findings'))
      local _, malformedFindings = harness.registry:invoke(
        'synex_control', 1, 'fixture', 'findings', {
          view = 'findings', rows = 1, invalid = 'shape',
        }, {}, 'trace-findings-shape')
      assert(malformedFindings.code == 'INVALID_PROVIDER_RESPONSE')
      assert(harness.registry:invoke('synex_control', 1, 'fixture', 'summary', {
        view = 'overview',
      }, {}, 'trace-reset-findings-shape'))

      local _, mismatchedView = harness.registry:invoke(
        'synex_control', 1, 'fixture', 'inspect', { view = 'table_rows' }, {},
        'trace-view-operation-mismatch')
      assert(mismatchedView.code == 'INVALID_CONTROL_PROVIDER_REQUEST')
      return table.concat({ wide.code, tall.code, rawCursor.code,
        emptySummary.code, wideDetail.code,
        invalidMetrics.code, wrongGraph.code, invalidNode.code, tallTimeline.code,
        malformedTimeline.code, tallFindings.code, malformedFindings.code,
        mismatchedView.code }, ':')
    `);
    assert.equal(result, [
      'INVALID_PROVIDER_RESPONSE', 'INVALID_PROVIDER_RESPONSE',
      'INVALID_PROVIDER_RESPONSE', 'INVALID_PROVIDER_RESPONSE',
      'INVALID_PROVIDER_RESPONSE', 'INVALID_PROVIDER_RESPONSE',
      'INVALID_PROVIDER_RESPONSE', 'INVALID_PROVIDER_RESPONSE',
      'INVALID_PROVIDER_RESPONSE', 'INVALID_PROVIDER_RESPONSE',
      'INVALID_PROVIDER_RESPONSE', 'INVALID_PROVIDER_RESPONSE',
      'INVALID_CONTROL_PROVIDER_REQUEST',
    ].join(':'));
  } finally {
    engine.global.close();
  }
});

test('Core Control registry keeps the complete official provider catalog inside its response budget', async () => {
  const descriptorPaths = [
    'resources/synex_groups/synex.resource.json',
    'resources/synex_accounts/synex.resource.json',
    'resources/synex_entities/synex.resource.json',
    'resources/synex_control/synex.resource.json',
    'libraries/synex_bridge/synex.resource.json',
  ];
  const official = await Promise.all(descriptorPaths.map(async (descriptorPath) => {
    const descriptor = JSON.parse(await source(descriptorPath)) as {
      name: string;
      controlProvider: Record<string, unknown>;
    };
    return { resource: descriptor.name, declaration: descriptor.controlProvider };
  }));
  const diagnostics = await source('core/synex_core/server/bootstrap_diagnostics.lua');
  const coreViews = [...diagnostics.matchAll(
    /\{ id = '([^']+)', label = '([^']+)', operation = '([^']+)', presentation = '([^']+)', order = (\d+)/gu,
  )].map((match) => ({
    id: match[1], label: match[2], operation: match[3], presentation: match[4],
    order: Number(match[5]), accessClass: ['capabilities', 'capability', 'security'].includes(match[1] ?? '')
      ? 'security' : match[1] === 'tracing' ? 'audit' : 'general',
  }));
  assert.equal(coreViews.length, 32);

  // Conservative metadata: every inspector receives the maximum real single-id field,
  // and the search view receives the registry maximum. Passing this fixture proves the
  // smaller runtime metadata also fits without catalog truncation.
  for (const view of coreViews as Array<Record<string, unknown>>) {
    if (view.operation === 'inspect') {
      view.input = { fields: [{
        key: 'id', label: 'Bounded diagnostic identifier', source: 'id', type: 'string',
        format: 'lookup', required: true, minLength: 1, maxLength: 128,
      }] };
    }
    if (view.operation === 'search') {
      view.search = { kinds: Array.from({ length: 16 }, (_, index) => ({
        id: `kind_${String(index + 1).padStart(2, '0')}`,
        modes: ['exact', 'prefix'], accessClass: 'general',
      })) };
    }
  }
  const expectedViews = coreViews.length + official.reduce((total, fixture) => {
    const views = (fixture.declaration as { views?: unknown[] }).views;
    return total + (Array.isArray(views) ? views.length : 0);
  }, 0);

  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrapRegistry(engine);
    const result = String(await engine.doString(`
      local harness = CreateControlRegistryHarness()
      local official = ${luaLiteral(official)}
      for _, fixture in ipairs(official) do
        harness.current[fixture.resource] = 1
        harness.manifests[fixture.resource] = { controlProvider = fixture.declaration }
        local declared, declarationError = harness.registry:declare(
          fixture.resource, fixture.declaration)
        assert(declared, declarationError and declarationError.code or 'DECLARATION_REJECTED')
      end

      harness.current.synex_core = 1
      local operations = {
        summary = function() return { status = 'HEALTHY' }, nil end,
        health = function() return { status = 'HEALTHY' }, nil end,
        list = function() return { items = {}, hasMore = false }, nil end,
        inspect = function() return { status = 'INFO' }, nil end,
        search = function() return { items = {}, hasMore = false }, nil end,
        metrics = function() return { status = 'INFO' }, nil end,
        findings = function() return { items = {}, hasMore = false }, nil end,
      }
      assert(harness.registry:register('synex_core', 1, {
        schemaVersion = 1, namespace = 'core', label = 'Synex Core',
        category = 'foundation', version = '1.0.0', operations = operations,
        views = ${luaLiteral(coreViews)},
      }))
      local firstCatalogPage = assert(harness.registry:list({ limit = 3 }))
      assert(#firstCatalogPage.providers == 3 and firstCatalogPage.hasMore == true
        and type(firstCatalogPage.nextCursor) == 'string')
      local secondCatalogPage = assert(harness.registry:list({
        cursor = firstCatalogPage.nextCursor, limit = 3,
      }))
      assert(#secondCatalogPage.providers == 3 and secondCatalogPage.hasMore == false)
      assert(secondCatalogPage.providers[1].namespace
        > firstCatalogPage.providers[#firstCatalogPage.providers].namespace)
      local _, oversizedCatalogPage = harness.registry:list({ limit = 65 })
      assert(oversizedCatalogPage.code == 'INVALID_CONTROL_PROVIDER_REQUEST')
      local catalog = assert(harness.registry:list({ limit = 12 }))
      assert(catalog.truncated == false, 'catalog truncated at ' .. tostring(#catalog.providers))
      assert(catalog.hasMore == false and catalog.nextCursor == nil)
      assert(catalog.total == 6)
      assert(#catalog.providers == 6, 'provider count ' .. tostring(#catalog.providers))
      local encoded = json.encode(catalog)
      assert(#encoded <= 32768, 'catalog bytes ' .. tostring(#encoded))
      local views, maximumDescriptionBytes = 0, 0
      for _, summary in ipairs(catalog.providers) do
        assert(summary.capabilities == nil and type(summary.operations) == 'table',
          'catalog must not duplicate the operations alias')
        local provider, describeError = harness.registry:describe(summary.namespace)
        assert(provider, describeError and describeError.code or 'DESCRIBE_FAILED')
        assert(provider.namespace == summary.namespace and #provider.views == #summary.views)
        assert(type(provider.capabilities) == 'table'
          and #provider.capabilities == #provider.operations,
          'describe must retain the compatibility alias')
        local descriptionBytes = #json.encode(provider)
        maximumDescriptionBytes = math.max(maximumDescriptionBytes, descriptionBytes)
        assert(descriptionBytes <= 32768,
          'provider description bytes ' .. tostring(descriptionBytes))
        views = views + #provider.views
      end
      assert(views == ${expectedViews}, 'view count ' .. tostring(views))
      local projected = {}
      for _, provider in ipairs(catalog.providers) do
        local projectedViews = {}
        for _, view in ipairs(provider.views) do
          projectedViews[#projectedViews + 1] = {
            id = view.id, label = view.label, operation = view.operation,
            presentation = view.presentation, order = view.order,
            accessClass = view.accessClass, input = view.input, search = view.search,
            authorized = true,
          }
        end
        projected[#projected + 1] = {
          namespace = provider.namespace, label = provider.label,
          category = provider.category, version = provider.version,
          resource = provider.resource, health = provider.health,
          circuit = provider.circuit, operations = provider.operations,
          capabilities = provider.capabilities, views = projectedViews,
          metrics = provider.metrics, authorized = true,
        }
      end
      local _, report, encodeError, nuiBytes =
        SynexControlSanitizer.encodeProviderMetadataEnvelope({
        schemaVersion = 1, requestId = 'request-provider-catalog', ok = true,
        data = { providers = projected, generatedAt = '2026-08-26T00:00:00Z',
          readOnly = true, truncated = false },
      }, { maximumBytes = SynexControlLimits.maximumResponseBytes })
      assert(encodeError == nil, encodeError or 'NUI_CATALOG_ENCODE_FAILED')
      assert(report.truncated == false, 'NUI catalog sanitizer truncated')
      assert(nuiBytes <= SynexControlLimits.maximumResponseBytes,
        'NUI catalog bytes ' .. tostring(nuiBytes))
      return table.concat({ tostring(#catalog.providers), tostring(views),
        tostring(#encoded), tostring(nuiBytes), tostring(maximumDescriptionBytes) }, ':')
    `));
    const [providerCount, viewCount, encodedBytes, nuiBytes, describeBytes]
      = result.split(':').map(Number);
    assert.equal(providerCount, 6);
    assert.equal(viewCount, expectedViews);
    assert.ok((encodedBytes ?? Number.POSITIVE_INFINITY) <= 32768);
    assert.ok((nuiBytes ?? Number.POSITIVE_INFINITY) <= 32768);
    assert.ok((describeBytes ?? Number.POSITIVE_INFINITY) <= 32768);
  } finally {
    engine.global.close();
  }
});
