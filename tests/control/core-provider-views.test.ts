import assert from 'node:assert/strict';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';
import { source } from './helpers.js';

test('Core Control inspectors expose bounded projections from real registries', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    const diagnosticsPaths = [
      'core/synex_core/server/bootstrap_diagnostics_shared.lua',
      'core/synex_core/server/bootstrap_diagnostics_runtime.lua',
      'core/synex_core/server/bootstrap_diagnostics_control_shared.lua',
      'core/synex_core/server/bootstrap_diagnostics_control_queries.lua',
      'core/synex_core/server/bootstrap_diagnostics_control_inspect.lua',
      'core/synex_core/server/bootstrap_diagnostics_control_security.lua',
      'core/synex_core/server/bootstrap_diagnostics.lua',
    ];
    const diagnostics = await Promise.all(diagnosticsPaths.map((entry) => source(entry)));
    const diagnosticsBootstrap = diagnostics.map((contents, index) => `
      assert(load(${JSON.stringify(contents)}, '@${diagnosticsPaths[index]}'))()
    `).join('\n');
    await engine.doString(`
      SynexProtocol = { api = '1.0.0', wire = 1 }
      SynexCoreFactories = {}
      ${diagnosticsBootstrap}

      local function copy(value, seen)
        if type(value) ~= 'table' then return value end
        seen = seen or {}
        if seen[value] then error('cycle') end
        seen[value] = true
        local result = {}
        for key, item in pairs(value) do result[copy(key, seen)] = copy(item, seen) end
        seen[value] = nil
        return result
      end

      local foundation = {
        copy = copy,
        utcIso = function() return '2026-08-26T00:00:00Z' end,
        monotonicMs = function() return 1000 end,
        isCallable = function(value) return type(value) == 'function' end,
        safeCall = function(handler, ...)
          local values = table.pack(pcall(handler, ...))
          if not values[1] then return false, values[2] end
          return true, table.unpack(values, 2, values.n)
        end,
        error = function(code, message, options)
          local value = { code = code, message = message }
          for key, item in pairs(options or {}) do value[key] = item end
          return value
        end,
        tracing = {
          list = function(_, request)
            if request.traceId == 'trace-retained' then
              return {
                status = 'AVAILABLE', matched = 1,
                items = {{
                  cursor = '12', traceId = request.traceId, spanId = 'span-retained',
                  childSpanIds = {}, resource = 'synex_accounts',
                  operation = 'accounts.inspect', durationMs = 8,
                  status = 'SUCCESS', timestamp = '2026-08-26T00:00:00Z'
                }},
                nextCursor = nil, hasMore = false, truncated = false,
                retained = 2, maximumRetained = 512, payloadsExposed = false
              }, nil
            end
            if request.traceId ~= nil then
              return {
                status = 'AVAILABLE', matched = 0, items = {}, nextCursor = nil,
                hasMore = false, truncated = false, retained = 2,
                maximumRetained = 512, payloadsExposed = false
              }, nil
            end
            assert(request.limit == 1 and request.cursor == '11')
            return {
              status = 'AVAILABLE',
              items = {{
                cursor = '10', traceId = 'trace-a', spanId = 'span-a',
                childSpanIds = {}, resource = 'synex_core', operation = 'fixture.trace',
                durationMs = 3, status = 'SUCCESS', timestamp = '2026-08-26T00:00:00Z'
              }},
              nextCursor = '10', hasMore = true, truncated = true,
              retained = 2, maximumRetained = 512, payloadsExposed = false
            }, nil
          end,
          detail = function(_, traceId, request)
            assert(traceId == 'trace-a' and request.limit == 5
              and request.cursor == '7')
            return {
              status = 'AVAILABLE', traceId = traceId,
              items = {{
                cursor = '10', traceId = traceId, spanId = 'span-a',
                childSpanIds = {}, resource = 'synex_core', operation = 'fixture.trace',
                durationMs = 3, status = 'SUCCESS', timestamp = '2026-08-26T00:00:00Z'
              }},
              nextCursor = nil, hasMore = false, truncated = false, retainedSpans = 1,
              payloadsExposed = false
            }, nil
          end
        },
        metrics = { snapshot = function() return {
          values = {
            ['synex_db_deadlocks_total:4:kind=string:5:batch'] = 3,
            ['synex_db_deadlock_retries_total:4:kind=string:5:batch'] = 2
          },
          histograms = {}
        } end }
      }
      local transitions = {}
      for index = 1, 40 do
        transitions[index] = {
          from = index == 1 and 'BOOTING' or 'READY', to = 'READY',
          reason = 'transition-' .. tostring(index), revision = index,
          at = '2026-08-26T00:00:00Z'
        }
      end
      local resourceRows = {
        {
          name = 'synex_core', state = 'STARTED', epoch = 7,
          health = { status = 'HEALTHY', reasons = {} },
          manifest = {
            version = '0.1.0', critical = true,
            services = { provide = { 'synex.runtime@1' }, require = {}, optional = {} },
            contracts = { provide = { 'synex.runtime.status' }, consume = {} },
            stateSnapshot = { supported = true, schemaVersion = 1 },
            private = 'must-not-leak'
          }
        },
        {
          name = 'synex_consumer', state = 'STARTED', epoch = 2,
          health = { status = 'HEALTHY', reasons = {} },
          manifest = {
            version = '1.0.0', critical = false,
            services = { provide = {}, require = { 'synex.runtime@1' }, optional = {} },
            contracts = { provide = {}, consume = { 'synex.runtime.status' } }
          }
        }
      }
      for index = 1, 70 do
        resourceRows[#resourceRows + 1] = {
          name = ('synex_consumer_%02d'):format(index), state = 'STARTED', epoch = 1,
          health = { status = 'HEALTHY', reasons = {} },
          manifest = {
            version = '1.0.0', critical = false,
            services = { provide = {}, require = {}, optional = {} },
            contracts = { provide = {}, consume = { 'synex.runtime.status' } }
          }
        }
      end
      local resources = {}
      function resources:list() return copy(resourceRows) end
      function resources:get(name)
        for _, row in ipairs(resourceRows) do if row.name == name then return copy(row) end end
      end
      function resources:summary()
        return { total = #resourceRows, healthy = #resourceRows, degraded = 0,
          unhealthy = 0, unknown = 0, states = { STARTED = #resourceRows } }
      end

      local session = {
        id = 'session-a', userId = 'user-private', characterId = 'character-a',
        source = 42, sourceGeneration = 3, state = 'ACTIVE', version = 4,
        serverInstanceId = 'instance-a', persistencePending = false,
        replacementClosePending = false, authorityDeadlineAt = 2500,
        identifiers = { license = 'license:secret' }, token = 'secret-token'
      }
      local players = {}
      function players:summary() return { activeSessions = 1, pendingConnections = 0, states = { ACTIVE = 1 } } end
      function players:getSession(id) return id == session.id and copy(session) or nil end
      function players:getByCharacter(id) return id == session.characterId and copy(session) or nil end
      function players:sessionsByUser(id)
        return id == session.userId and { copy(session) } or {}
      end
      function players:listSessions(request)
        assert(request.limit == 1 and request.cursor == nil)
        return { items = { copy(session) }, limit = 1, nextCursor = 'session-a',
          hasMore = true, truncated = true, total = 2 }, nil
      end
      function players:staleSessions(request)
        assert(request.limit == 50 and request.scanLimit == 512)
        return { status = 'AVAILABLE', items = {{
            sessionId = 'session-private-stale', state = 'ACTIVE',
            reasons = { 'AUTHORITY_EXPIRED' }
          }}, matched = 1, scanned = 1,
          complete = true, truncated = false, rawIdentifiersExposed = false }, nil
      end

      local contractErrors, contractProperties, contractRequired = {}, {}, {}
      for index = 1, 70 do
        contractErrors[index] = ('ERROR_%02d'):format(index)
        local name = ('field_%02d'):format(index)
        contractProperties[name] = { type = 'string', pattern = 'private-pattern' }
        contractRequired[index] = name
      end
      local contracts = {{
        name = 'synex.runtime.status', version = '1.0.0', provider = 'synex_core',
        kind = 'rpc', domain = 'synex.runtime', network = 'none', stability = 'stable',
        capability = 'synex.runtime.read', errors = contractErrors,
        input = { type = 'object', additionalProperties = false,
          properties = contractProperties, required = contractRequired },
        output = { type = 'object', additionalProperties = false,
          properties = { status = { type = 'string' } }, required = { 'status' } }
      }}
      local capabilitySnapshot = {
        synex_core = {
          requested = { ['synex.runtime.read'] = true },
          policy = { allow = { 'synex.runtime.read' }, deny = {} }
        },
        synex_consumer = {
          requested = { ['synex.runtime.read'] = true },
          policy = { allow = {}, deny = { 'synex.runtime.read' } }
        }
      }
      local diagnosticMode = 'available'
      local diagnosticRows = {
        { id = 5, cursor = '5', timestampMs = 5000,
          timestamp = '2026-08-26T00:00:05Z', category = 'capability_denial',
          severity = 'WARNING', code = 'CAPABILITY_DENIED', resource = 'synex_fixture',
          scope = 'synex.runtime.read', operation = 'capability.check',
          summary = 'Capability authorization rejected.',
          traceId = 'trace-private', payload = { private = true } },
        { id = 4, cursor = '4', timestampMs = 4000,
          timestamp = '2026-08-26T00:00:04Z', category = 'event_authorization',
          severity = 'WARNING', code = 'EVENT_TOPIC_FORBIDDEN', resource = 'synex_fixture',
          scope = 'synex.core.changed', operation = 'event.publish',
          summary = 'Foreign event namespace call rejected.' },
        { id = 3, cursor = '3', timestampMs = 3000,
          timestamp = '2026-08-26T00:00:03Z', category = 'hook_authorization',
          severity = 'WARNING', code = 'HOOK_RUN_UNDECLARED', resource = 'synex_fixture',
          scope = 'synex.fixture.before', operation = 'hook.run',
          summary = 'Undeclared hook call rejected.' },
        { id = 2, cursor = '2', timestampMs = 2000,
          timestamp = '2026-08-26T00:00:02Z', category = 'rate_limit_rejection',
          severity = 'WARNING', code = 'RATE_LIMITED', scope = 'rpc',
          operation = 'rate_limit.consume', summary = 'Rate-limit token budget rejection.' },
        { id = 1, cursor = '1', timestampMs = 1000,
          timestamp = '2026-08-26T00:00:01Z', category = 'contract_validation',
          severity = 'WARNING', code = 'VALIDATION_FAILED', resource = 'synex_fixture',
          scope = 'synex.fixture.call', operation = 'rpc.request.contract',
          summary = 'RPC request contract validation rejected.' }
      }
      local function diagnosticPage(cursor, limit)
        if diagnosticMode == 'throw' then error('private diagnostics failure') end
        local numericCursor = cursor and tonumber(cursor) or nil
        if numericCursor and numericCursor > 6 then
          return nil, { code = 'INVALID_CURSOR', message = 'invalid' }
        end
        local items = {}
        local hasMore = false
        for _, row in ipairs(diagnosticRows) do
          if numericCursor == nil or row.id < numericCursor then
            if #items < limit then items[#items + 1] = copy(row)
            else hasMore = true break end
          end
        end
        return {
          status = 'AVAILABLE', items = items,
          nextCursor = hasMore and items[#items].cursor or nil,
          hasMore = hasMore, truncated = hasMore,
          retained = #diagnosticRows, maximumRetained = 512,
          dropped = 0, retentionTruncated = false, payloadsExposed = false
        }, nil
      end
      local securityState = {
        rbac = { snapshot = function() return {} end },
        capabilities = {
          snapshot = function() return copy(capabilitySnapshot) end,
          preflight = function(_, resource)
            if resource == 'synex_consumer' then return {{
              resource = resource, capability = 'synex.runtime.read', reason = 'denied'
            }} end
            return {}
          end,
          class = function(_, capability)
            return capability == 'synex.runtime.read' and 'normal' or 'unknown'
          end
        },
        diagnostics = {
          snapshot = function(_, limit) return diagnosticPage(nil, limit) end,
          page = function(_, request) return diagnosticPage(request.cursor, request.limit) end
        }
      }
      local provider
      local auditRequests = {}
      local runtime = {}
      SynexCoreFactories.bootstrapDiagnostics({
        runtime = runtime,
        reloadSnapshots = {},
        defaultConfig = {
          instanceId = 'instance-a', environment = 'test', features = {},
          database = { minimumOxmysqlVersion = '2.14.1' }
        },
        lifecycle = {
          core = {
            snapshot = function() return {
              state = 'READY', revision = 40, operational = true,
              playerAdmission = true, reasons = {
                fixture = { status = 'DEGRADED', reason = 'bounded-fixture' }
              }, recentTransitions = transitions
            } end,
            healthStatus = function() return 'DEGRADED' end
          },
          dependencies = {
            snapshot = function() return {
              providers = { ['synex.runtime'] = { synex_core = '1.0.0' } },
              consumers = { synex_consumer = {
                ['synex.runtime'] = { range = '^1.0.0', optional = false }
              } }
            } end,
            validate = function() return {} end
          },
          scheduler = { snapshot = function() return {} end, count = function() return 0 end }
        },
        registries = {
          owners = { epoch = function(_, name) return name == 'synex_core' and 7 or 0 end },
          resources = resources,
          players = players
        },
        messaging = {
          gateway = { snapshot = function() return {{
            key = 'synex.runtime.status@1', name = 'synex.runtime.status', version = '1.0.0',
            owner = 'synex_core', network = false, stability = 'stable',
            capability = 'synex.runtime.read', calls = 4, successes = 4, failures = 0,
            timeouts = 0, averageDurationMs = 2, percentile95DurationMs = 3,
            lastDurationMs = 2, maximumDurationMs = 3, sampleSize = 4,
          }} end },
          services = { snapshot = function() return {
            ['synex.runtime@1'] = {
              synex_core = {
                version = '1.0.0', stability = 'stable',
                health = 'HEALTHY', circuit = 'CLOSED'
              }
            }
          } end },
          network = { snapshot = function() return {} end },
          events = { snapshot = function() return {} end },
          hooks = { snapshot = function() return {{
            name = 'synex.fixture.before', handlers = 2, required = 1, slow = false,
            calls = 6, successes = 6, failures = 0, timeouts = 0, denials = 1,
            handlerDetails = {
              { owner = 'synex_core', priority = 100, required = true, timeoutMs = 500,
                calls = 4, successes = 4, failures = 0, timeouts = 0, denials = 1,
                averageDurationMs = 2, percentile95DurationMs = 3,
                lastDurationMs = 2, maximumDurationMs = 3, sampleSize = 4, slow = false },
              { owner = 'synex_fixture', priority = 50, required = false, timeoutMs = 500,
                calls = 2, successes = 2, failures = 0, timeouts = 0, denials = 0,
                averageDurationMs = 400, percentile95DurationMs = 450,
                lastDurationMs = 400, maximumDurationMs = 450, sampleSize = 2, slow = true },
            },
          }} end },
          deprecations = { snapshot = function() return {} end }
        },
        stateService = { snapshot = function() return {} end },
        foundation = foundation,
        persistence = {
          instances = { snapshot = function() return {
            status = 'ready', total = 2, healthy = 1, stale = 1,
            pendingControlRequests = 0, refreshedAt = '2026-08-26T00:00:00Z'
          } end },
          migrations = { snapshot = function() return { resources = {}, totals = {} }, nil end },
          database = { slowQueries = function(_, request)
            assert(request.limit == 5 and request.cursor == '9')
            return {
              status = 'AVAILABLE',
              items = {{
                cursor = '8', resource = 'synex_accounts', operation = 'accounts.inspect',
                kind = 'query', statementHash = string.rep('a', 64), durationMs = 300,
                maximumDurationMs = 350, traceId = 'trace-database', occurrences = 2,
                status = 'SUCCESS', firstObservedAt = '2026-08-26T00:00:00Z',
                observedAt = '2026-08-26T00:00:01Z'
              }},
              nextCursor = nil, hasMore = false, truncated = false, retained = 1,
              maximumRetained = 128, thresholdMs = 250,
              rawSqlExposed = false, parametersExposed = false
            }, nil
          end }, rbac = {}
        },
        platform = {},
        contractSystem = { registry = { list = function() return copy(contracts) end } },
        security = securityState,
        identity = {
          connections = { snapshot = function() return { queued = 0, maximumQueued = 128 } end },
          characters = {
            cacheSnapshot = function() return { entries = 1, maximum = 128 } end,
            get = function(_, id)
              if id ~= 'character-a' then
                return nil, foundation.error('CHARACTER_NOT_FOUND', 'missing')
              end
              return {
                id = id, userId = 'user-private', slot = 1, status = 'active', version = 2,
                firstName = 'Private', lastName = 'Person', dateOfBirth = '2000-01-01',
                metadata = { secret = true }
              }, nil
            end
          }
        },
        sagaRuntime = { snapshot = function() return { handlers = {}, persisted = {} } end },
        reliability = {
          audit = { search = function(_, request)
            auditRequests[#auditRequests + 1] = copy(request)
            return {
              entries = {{ eventId = 'event-a', action = 'fixture', traceId = 'trace-a' }},
              nextCursor = '17', hasMore = true, truncated = true
            }, nil
          end },
          outbox = { snapshot = function(_, request)
            assert(request.limit == 10)
            return { status = 'AVAILABLE', total = 3, backlog = 1,
              states = { pending = { total = 1 }, publishing = { total = 0 },
                published = { total = 2 }, dead = { total = 0 } },
              items = {}, hasMore = false, truncated = false,
              payloadsExposed = false, headersExposed = false }, nil
          end }
        },
        controlProviders = {
          register = function(_, owner, epoch, definition)
            assert(owner == 'synex_core' and epoch == 7)
            provider = definition
            return { namespace = definition.namespace }, nil
          end,
          list = function() return { providers = {}, truncated = false }, nil end,
          invoke = function(_, caller, epoch, namespace, operation, request, options)
            assert(caller == 'synex_core' and epoch == 7 and operation == 'inspect')
            assert(request.view == 'character_relations' and request.id == 'character-a'
              and request.limit == 8 and options.timeoutMs == 125)
            if namespace == 'accounts' then
              return nil, { code = 'PROVIDER_TIMEOUT', retryable = true }
            end
            local item = namespace == 'groups'
              and { groupId = 'group-private', membershipState = 'ACTIVE' }
              or { entityId = 'entity-private', status = 'active' }
            return { data = { count = namespace == 'groups' and 2 or 1,
              items = { item }, hasMore = namespace == 'groups',
              truncated = namespace == 'groups' } }, nil
          end
        },
        coreResource = 'synex_core'
      })

      assert(provider and #provider.views == 32 and #provider.views <= 32, 'view-count')
      local expectedViews = {
        resource = true, contract = true, capability = true, session = true,
        character = true, instances = true, health_timeline = true,
        dependency_impact = true, rpc_detail = true, hook_detail = true,
        service_detail = true, incident_window = true, trace_detail = true,
        slow_queries = true
      }
      for _, view in ipairs(provider.views) do expectedViews[view.id] = nil end
      assert(next(expectedViews) == nil, 'required-views')
      local requiredInputs = {
        resource = 'resource', dependency_impact = 'resource', contract = 'lookup',
        capability = 'capability', session = 'identifier', character = 'identifier',
        rpc_detail = 'lookup', hook_detail = 'lookup', service_detail = 'lookup'
      }
      for _, view in ipairs(provider.views) do
        local expectedFormat = requiredInputs[view.id]
        if expectedFormat then
          local expectedFields = view.id == 'capability' and 2 or 1
          assert(view.input and #view.input.fields == expectedFields, view.id .. '-input')
          local field = view.input.fields[1]
          assert(field.key == 'id' and field.source == 'id' and field.required == true
            and field.type == 'string' and field.format == expectedFormat,
            view.id .. '-input-contract')
          if view.id == 'capability' then
            local resourceField = view.input.fields[2]
            assert(resourceField.key == 'resource' and resourceField.source == 'filter'
              and resourceField.required == false and resourceField.format == 'resource',
              'capability-resource-input')
          end
          requiredInputs[view.id] = nil
        end
      end
      assert(next(requiredInputs) == nil, 'required-inputs')
      local traceDescriptor
      for _, view in ipairs(provider.views) do
        if view.id == 'trace_detail' then traceDescriptor = view break end
      end
      assert(traceDescriptor and traceDescriptor.operation == 'list'
        and traceDescriptor.presentation == 'timeline')
      local traceField = traceDescriptor.input.fields[1]
      assert(traceField.key == 'trace_id' and traceField.source == 'filter'
        and traceField.required == true and traceField.format == 'identifier')

      local inspect = provider.operations.inspect
      local runtimeView = assert(inspect({ view = 'runtime' }))
      assert(runtimeView.frameworkVersion == '0.1.0'
        and runtimeView.apiVersion == '1.0.0' and runtimeView.wireVersion == 1,
        'runtime-version-separation')
      assert(runtimeView.outbox.status == 'AVAILABLE'
        and runtimeView.outbox.payloadsExposed == false, 'runtime-outbox')
      local resource = assert(inspect({ view = 'resource', id = 'synex_core', limit = 25 }))
      assert(resource.resource.name == 'synex_core' and resource.resource.manifest.private == nil,
        'resource-projection')
      assert(resource.resource.manifest.services.provide[1] == 'synex.runtime@1',
        'resource-services')
      assert(resource.impact.nodes == nil and resource.impact.edges == nil, 'resource-impact-graph')
      assert(resource.impact.counts.provisions == 1, 'resource-impact-count')

      local impact = assert(inspect({ view = 'dependency_impact', id = 'synex_core' }))
      assert(impact.counts.provisions == 1 and impact.counts.affectedConsumers == 1,
        'impact-counts')
      assert(#impact.nodes == 3 and #impact.edges == 2, 'impact-graph')
      assert(impact.cycleDetection.status == 'AVAILABLE'
        and #impact.cycleDetection.cycles == 0, 'impact-cycle')

      local contract = assert(inspect({ view = 'contract', id = 'synex.runtime.status@1.0.0' }))
      assert(#contract.contracts == 1 and #contract.contracts[1].errors == 32)
      assert(contract.contracts[1].errorsTruncated == true)
      assert(#contract.contracts[1].input.properties == 32)
      assert(contract.contracts[1].input.propertiesTruncated == true)
      assert(#contract.contracts[1].consumers == 32)
      assert(contract.contracts[1].consumersTruncated == true)
      assert(contract.contracts[1].input.properties.field_01 == nil)

      local capability = assert(inspect({ view = 'capability', id = 'synex.runtime.read' }))
      assert(capability.class == 'normal' and #capability.items == 2)
      assert(capability.items[1].status == 'DENIED')
      assert(capability.items[2].status == 'GRANTED')
      assert(capability.items[1].declared == true
        and capability.items[1].explicitDeny == true
        and capability.items[1].effectiveResult == 'DENIED')
      local capabilityForCore = assert(inspect({ view = 'capability',
        id = 'synex.runtime.read', filters = { resource = 'synex_core' } }))
      assert(#capabilityForCore.items == 1
        and capabilityForCore.items[1].resource == 'synex_core'
        and capabilityForCore.items[1].granted == true)

      local sessionView = assert(inspect({ view = 'session', id = 'session-a' }))
      assert(sessionView.session.state == 'ACTIVE' and sessionView.session.identifiers == nil)
      assert(sessionView.session.token == nil and sessionView.rawIdentifiersExposed == false)
      local sessions = assert(provider.operations.list({ view = 'sessions', limit = 1 }))
      assert(#sessions.items == 1 and sessions.items[1].id == 'session-a'
        and sessions.nextCursor == 'session-a' and sessions.hasMore == true
        and sessions.pagination.kind == 'keyset' and sessions.identifiersExposed == false)

      local character = assert(inspect({ view = 'character', id = 'character-a' }))
      assert(character.character.id == 'character-a' and character.character.firstName == nil)
      assert(character.character.metadata == nil and character.personalProfileExposed == false)
      assert(character.relatedDomains.groups.status == 'AVAILABLE'
        and character.relatedDomains.groups.count == 2
        and character.relatedDomains.groups.hasMore == true)
      assert(character.relatedDomains.entities.status == 'AVAILABLE'
        and character.relatedDomains.entities.count == 1)
      assert(character.relatedDomains.accounts.status == 'UNAVAILABLE'
        and character.relatedDomains.accounts.reason == 'PROVIDER_TIMEOUT'
        and character.relatedDomains.accounts.retryable == true)
      assert(character.relatedDomains.groups.items == nil
        and character.relatedDomains.accounts.items == nil
        and character.relatedDomains.entities.items == nil
        and character.relatedDomains.groups.groupId == nil
        and character.relatedDomains.entities.entityId == nil,
        'character-relations-must-not-bypass-domain-access-classes')
      for _, view in ipairs(provider.views) do
        if view.id == 'character' then assert(view.accessClass == 'general') end
      end

      local instances = assert(inspect({ view = 'instances' }))
      assert(instances.current.id == 'instance-a' and instances.cluster.stale == 1)
      assert(instances.remoteInstanceDetails.status == 'UNAVAILABLE')

      local timeline = assert(inspect({ view = 'health_timeline' }))
      assert(#timeline.items == 32 and timeline.truncated == true and timeline.hasMore == false)
      assert(timeline.items[1].revision == 9 and timeline.items[32].revision == 40)
      assert(timeline.items[1].timestamp and timeline.items[1].label == 'READY to READY')

      local rpc = assert(inspect({ view = 'rpc_detail', id = 'synex.runtime.status' }))
      assert(rpc.status == 'AVAILABLE' and #rpc.items == 1)
      assert(rpc.items[1].owner == 'synex_core' and rpc.items[1].calls == 4)
      local hook = assert(inspect({ view = 'hook_detail', id = 'synex.fixture.before' }))
      assert(hook.hook.handlers == 2 and #hook.handlerDetails == 2)
      assert(hook.handlerDetails[1].owner == 'synex_core'
        and hook.handlerDetails[1].percentile95DurationMs == 3
        and hook.handlerDetails[1].denials == 1
        and hook.hook.calls == 6 and hook.hook.denials == 1)
      local service = assert(inspect({ view = 'service_detail', id = 'synex.runtime@1' }))
      assert(#service.items == 1 and service.items[1].resource == 'synex_core')
      local incident = assert(inspect({ view = 'incident_window' }))
      assert(#incident.items == 16
        and incident.items[1].revision == 25
        and incident.persistedIncidentHistory.status == 'UNAVAILABLE')
      local security = assert(provider.operations.findings({ view = 'security', limit = 25 }))
      assert(security.coverage.staleSessions.status == 'AVAILABLE'
        and security.coverage.staleSessions.complete == true)
      assert(security.coverage.capabilityPolicy.status == 'AVAILABLE'
        and security.coverage.capabilityDenials.status == 'AVAILABLE'
        and security.coverage.contractValidation.status == 'AVAILABLE'
        and security.coverage.rpcRateLimits.status == 'AVAILABLE'
        and security.coverage.eventAuthorization.status == 'AVAILABLE'
        and security.coverage.hookAuthorization.status == 'AVAILABLE'
        and security.coverage.foreignCalls.status == 'AVAILABLE')
      assert(security.coverage.fuzzing.status == 'NOT_RUNTIME'
        and security.coverage.fuzzing.reason == 'REPOSITORY_TEST_GATE'
        and security.coverage.staticAnalyzer.status == 'NOT_RUNTIME'
        and security.coverage.staticAnalyzer.reason == 'REPOSITORY_TEST_GATE')
      assert(security.runtimeHistory.status == 'AVAILABLE'
        and security.runtimeHistory.reason == nil
        and security.runtimeHistory.retained == 5
        and security.payloadsExposed == false
        and security.identifiersExposed == false
        and security.crossDomainDataExposed == false)
      local slowHookFinding, staleFinding, preflightFinding = false, false, false
      for _, finding in ipairs(security.items) do
        if finding.code == 'SLOW_HOOK_HANDLER' and finding.resource == 'synex_fixture'
            and finding.hook == 'synex.fixture.before' then slowHookFinding = true end
        if finding.code == 'STALE_SESSION_AUTHORITY' then
          staleFinding = finding.occurrences == 1 and finding.state == 'ACTIVE'
            and finding.sessionId == nil and finding.source == nil
        end
        if finding.code == 'CAPABILITY_PREFLIGHT_DENIAL'
            and finding.capability == 'synex.runtime.read' then preflightFinding = true end
        assert(finding.id == nil and finding.cursor == nil and finding.traceId == nil
          and finding.requestId == nil and finding.payload == nil
          and finding.sessionId == nil and finding.userId == nil
          and finding.identifiers == nil and finding.details == nil)
      end
      assert(slowHookFinding, 'slow-hook-finding')
      assert(staleFinding, 'stale-session-finding')
      assert(preflightFinding, 'capability-preflight-finding')

      local firstSecurityPage = assert(provider.operations.findings({
        view = 'security', limit = 3
      }))
      assert(#firstSecurityPage.items == 3
        and firstSecurityPage.items[1].origin == 'current'
        and firstSecurityPage.items[2].origin == 'current'
        and firstSecurityPage.items[3].origin == 'runtime'
        and firstSecurityPage.nextCursor == '5'
        and firstSecurityPage.hasMore == true
        and firstSecurityPage.currentFindings.included == 2,
        'security-first-page-reserves-runtime-slot')
      local nextSecurityPage = assert(provider.operations.findings({
        view = 'security', limit = 2, cursor = firstSecurityPage.nextCursor
      }))
      assert(#nextSecurityPage.items == 2
        and nextSecurityPage.items[1].origin == 'runtime'
        and nextSecurityPage.items[2].origin == 'runtime'
        and nextSecurityPage.nextCursor == '3'
        and nextSecurityPage.hasMore == true
        and nextSecurityPage.currentFindings.included == 0,
        'security-next-page-runtime-only')
      local lastSecurityPage = assert(provider.operations.findings({
        view = 'security', limit = 2, cursor = nextSecurityPage.nextCursor
      }))
      assert(#lastSecurityPage.items == 2
        and lastSecurityPage.items[1].origin == 'runtime'
        and lastSecurityPage.items[2].origin == 'runtime'
        and lastSecurityPage.nextCursor == nil
        and lastSecurityPage.hasMore == false,
        'security-last-page')
      local seenRuntimeCodes = {}
      for _, page in ipairs({ firstSecurityPage, nextSecurityPage, lastSecurityPage }) do
        for _, finding in ipairs(page.items) do
          if finding.origin == 'runtime' then
            assert(not seenRuntimeCodes[finding.code], 'duplicate-runtime-security-cursor')
            seenRuntimeCodes[finding.code] = true
            assert(finding.id == nil and finding.cursor == nil
              and finding.traceId == nil and finding.payload == nil)
          end
        end
      end
      assert(seenRuntimeCodes.CAPABILITY_DENIED
        and seenRuntimeCodes.EVENT_TOPIC_FORBIDDEN
        and seenRuntimeCodes.HOOK_RUN_UNDECLARED
        and seenRuntimeCodes.RATE_LIMITED
        and seenRuntimeCodes.VALIDATION_FAILED)

      local invalidSecurityPage, invalidSecurityError = provider.operations.findings({
        view = 'security', limit = 2, cursor = '01'
      })
      assert(invalidSecurityPage == nil
        and invalidSecurityError.code == 'INVALID_CONTROL_PROVIDER_REQUEST')
      local futureSecurityPage, futureSecurityError = provider.operations.findings({
        view = 'security', limit = 2, cursor = '999'
      })
      assert(futureSecurityPage == nil
        and futureSecurityError.code == 'INVALID_CONTROL_PROVIDER_REQUEST')

      diagnosticMode = 'throw'
      local failedRuntimeSecurity = assert(provider.operations.findings({
        view = 'security', limit = 25
      }))
      assert(failedRuntimeSecurity.runtimeHistory.status == 'UNAVAILABLE'
        and failedRuntimeSecurity.runtimeHistory.reason
          == 'SECURITY_DIAGNOSTICS_API_EXCEPTION'
        and #failedRuntimeSecurity.items >= 3,
        'security-runtime-failure-isolated')
      diagnosticMode = 'available'
      securityState.diagnostics = nil
      local missingRuntimeSecurity = assert(provider.operations.findings({
        view = 'security', limit = 25
      }))
      assert(missingRuntimeSecurity.runtimeHistory.status == 'UNAVAILABLE'
        and missingRuntimeSecurity.runtimeHistory.reason
          == 'SECURITY_DIAGNOSTICS_API_UNAVAILABLE'
        and missingRuntimeSecurity.coverage.contractValidation.status == 'UNAVAILABLE'
        and #missingRuntimeSecurity.items >= 3,
        'security-runtime-missing-isolated')

      local tracePage = assert(provider.operations.list({
        view = 'tracing', limit = 1, cursor = '11'
      }))
      assert(tracePage.spanStore == true and tracePage.items[1].traceId == 'trace-a'
        and tracePage.items[1].operation == 'fixture.trace'
        and tracePage.nextCursor == '10' and tracePage.hasMore == true)
      local traceDetail = assert(provider.operations.list({
        view = 'trace_detail', filters = { trace_id = 'trace-a' },
        limit = 5, cursor = '7'
      }))
      assert(traceDetail.spanStore == true and #traceDetail.items == 1
        and traceDetail.items[1].resource == 'synex_core')
      local database = assert(inspect({
        view = 'database', limit = 5, cursor = '9'
      }))
      assert(database.slowQueryHistory.status == 'AVAILABLE'
        and database.slowQueryHistory.items[1].occurrences == 2
        and database.slowQueryHistory.rawSqlExposed == false)
      assert(database.deadlocks.status == 'AVAILABLE'
        and database.deadlocks.total == 3 and database.deadlocks.series == 1
        and database.deadlocks.saturated == false)
      assert(database.retries.status == 'AVAILABLE'
        and database.retries.total == 2 and database.retries.series == 1
        and database.retries.saturated == false)
      assert(database.timeouts.status == 'UNAVAILABLE'
        and database.timeouts.reason
          == 'DATABASE_QUERY_TIMEOUT_TELEMETRY_UNAVAILABLE')
      assert(database.pool.status == 'UNAVAILABLE'
        and database.pool.reason == 'DATABASE_POOL_SNAPSHOT_UNAVAILABLE')
      local slowQueries = assert(provider.operations.list({
        view = 'slow_queries', limit = 5, cursor = '9'
      }))
      assert(slowQueries.view == 'slow_queries' and #slowQueries.items == 1
        and slowQueries.items[1].resource == 'synex_accounts'
        and slowQueries.items[1].durationMs == 300)
      local performance = assert(provider.operations.metrics({
        view = 'performance', limit = 5, cursor = '9'
      }))
      assert(performance.slowQueryHistory.items[1].statementHash == string.rep('a', 64)
        and performance.slowQueryHistory.parametersExposed == false)

      local sessionSearch = assert(provider.operations.search({
        query = { kind = 'session', value = 'session-a', mode = 'exact' }, limit = 5
      }))
      assert(#sessionSearch.items == 1 and sessionSearch.items[1].sessionId == 'session-a')
      assert(sessionSearch.items[1].userId == nil and sessionSearch.items[1].characterId == nil)
      local userSearch = assert(provider.operations.search({
        query = { kind = 'user', value = 'user-private', mode = 'exact' }, limit = 5
      }))
      assert(userSearch.status == 'AVAILABLE' and #userSearch.items == 1
        and userSearch.items[1].sessionId == 'session-a')
      assert(userSearch.value == 'exact-match' and userSearch.items[1].userId == nil
        and userSearch.userIdentifierExposed == false)
      local characterSearch = assert(provider.operations.search({
        query = { kind = 'character', value = 'character-a', mode = 'exact' }, limit = 5
      }))
      assert(#characterSearch.items == 1
        and characterSearch.items[1].characterId == 'character-a')
      assert(characterSearch.items[1].userId == nil
        and characterSearch.items[1].firstName == nil)

      local auditSearch = assert(provider.operations.search({
        query = { kind = 'trace', value = 'trace-a', mode = 'exact' },
        cursor = '41', limit = 5
      }))
      local auditRequest = auditRequests[#auditRequests]
      assert(#auditRequests == 2 and auditRequest.cursor == '41'
        and auditRequest.limit == 5 and auditRequest.value == 'trace-a',
        'audit-request-cursor')
      assert(auditSearch.status == 'AVAILABLE' and auditSearch.value == 'exact-match'
        and auditSearch.nextCursor == '17' and auditSearch.hasMore == true
        and auditSearch.truncated == true and auditSearch.pagination.kind == 'keyset'
        and auditSearch.payloadsExposed == false, 'audit-search-projection')
      local retainedTrace = assert(provider.operations.search({
        query = { kind = 'trace', value = 'trace-retained', mode = 'exact' },
        limit = 5
      }))
      assert(retainedTrace.status == 'AVAILABLE' and #retainedTrace.items == 1
        and retainedTrace.items[1].operation == 'accounts.inspect'
        and retainedTrace.items[1].traceId == nil
        and retainedTrace.value == 'exact-match'
        and retainedTrace.traceValueExposed == false
        and retainedTrace.auditCorrelation.reason == 'RETAINED_SPAN_MATCH')

      local missing, missingError = inspect({ view = 'resource' })
      assert(missing == nil and missingError.code == 'INVALID_CONTROL_PROVIDER_REQUEST')
      local absent, absentError = inspect({ view = 'session', id = 'session-missing' })
      assert(absent == nil and absentError.code == 'SESSION_NOT_FOUND')
      return table.concat({
        #provider.views, #contract.contracts[1].errors, #contract.contracts[1].consumers,
        #timeline.items, impact.cycleDetection.status
      }, ':')
    `).then((result) => assert.equal(result, '32:32:32:32:AVAILABLE'));
  } finally {
    engine.global.close();
  }
});
