import assert from 'node:assert/strict';
import test from 'node:test';
import { createNotifyLua, notifyServerFiles } from './helpers.js';

test('server application binds Core once per generation and fences resource-owned facades', async () => {
  const engine = await createNotifyLua([
    ...notifyServerFiles,
    'resources/synex_notify/server/runtime.lua',
  ]);
  try {
    const result = await engine.doString(`
      __appTest = {
        invokingResource = 'owner_alpha',
        states = {
          synex_core = 'started', synex_ui = 'started', synex_bridge = 'started',
          owner_alpha = 'started', compat_consumer = 'started',
        },
        services = {}, health = {}, serverContracts = {}, networkContracts = {},
        workers = {}, providers = {}, bridges = {}, cleanup = {}, records = {},
        serial = 0, facadeCalls = 0, waits = {}, pendingClears = 0,
      }
      GetInvokingResource = function() return __appTest.invokingResource end

      local function freshObject(value)
        return setmetatable(value, { __jsontype = 'object' })
      end
      local function contractBundle()
        return freshObject({
          schema = 1,
          domain = 'synex.notify',
          contracts = setmetatable({
            freshObject({ name = 'synex.notify.send', version = '1.0.0', network = 'none' }),
            freshObject({ name = 'synex.notify.update', version = '1.0.0', network = 'none' }),
            freshObject({ name = 'synex.notify.dismiss', version = '1.0.0', network = 'none' }),
            freshObject({ name = 'synex.notify.command.pull', version = '1.0.0',
              network = 'client-to-server' }),
            freshObject({ name = 'synex.notify.action.invoke', version = '1.0.0',
              network = 'client-to-server' }),
            freshObject({ name = 'synex.notify.metrics.report', version = '1.0.0',
              network = 'client-to-server' }),
          }, { __jsontype = 'array' }),
        })
      end

      local coreApi = {
        ownerEpoch = 99,
        Services = {
          provide = function(definition)
            __appTest.services[#__appTest.services + 1] = definition
            return 'service-token-' .. #__appTest.services
          end,
          setHealth = function(name, version, state)
            __appTest.health[#__appTest.health + 1] = {
              name = name, version = version, state = state,
            }
            return true
          end,
        },
        RPC = {
          registerServer = function(definition, handler)
            __appTest.serverContracts[#__appTest.serverContracts + 1] = {
              definition = definition, handler = handler,
            }
            return 'server-rpc-' .. #__appTest.serverContracts
          end,
          registerNetwork = function(definition, handler)
            __appTest.networkContracts[#__appTest.networkContracts + 1] = {
              definition = definition, handler = handler,
            }
            return 'network-rpc-' .. #__appTest.networkContracts
          end,
        },
        Scheduler = {
          every = function(interval, handler, options)
            __appTest.workers[#__appTest.workers + 1] = {
              interval = interval, handler = handler, options = options,
            }
            return 'worker-token-' .. #__appTest.workers
          end,
        },
        ControlProviders = {
          register = function(definition)
            __appTest.providers[#__appTest.providers + 1] = definition
            return 'core-provider-' .. #__appTest.providers
          end,
        },
        Ids = { next = function() return 'runtime-generated-id' end },
        Players = { getBySource = function() return nil end },
        Capabilities = {
          checkResource = function() return true end,
        },
        Metrics = {
          increment = function() return true end,
          gauge = function() return true end,
          observe = function() return true end,
        },
        Audit = { append = function() return true end },
        Events = { publish = function() return true end },
      }

      local registry = {}
      function registry.send(owner, epoch, _, payload, context)
        __appTest.serial = __appTest.serial + 1
        __appTest.facadeCalls = __appTest.facadeCalls + 1
        __appTest.lastFacadeContext = context
        local descriptor = {
          notificationId = ('notify-app-%08d'):format(__appTest.serial),
          ownerResource = owner, ownerEpoch = epoch, revision = 1,
        }
        __appTest.records[descriptor.notificationId] = {
          kind = payload.kind or 'toast',
          progress = payload.progress,
        }
        return descriptor
      end
      function registry.update(owner, epoch, handle, patch)
        assert(handle.ownerResource == owner and handle.ownerEpoch == epoch)
        local record = __appTest.records[handle.notificationId]
        if patch.progress then record.progress = patch.progress end
        return {
          notificationId = handle.notificationId, ownerResource = owner,
          ownerEpoch = epoch, revision = handle.revision + 1,
        }
      end
      function registry.dismiss(owner, epoch, handle)
        assert(handle.ownerResource == owner and handle.ownerEpoch == epoch)
        __appTest.records[handle.notificationId] = nil
        return { notificationId = handle.notificationId, dismissed = true }
      end
      function registry.sendMany(owner, epoch, targets, payload)
        local result = { sent = 0, failed = 0, handles = {}, errors = {} }
        for _ in ipairs(targets) do
          result.sent = result.sent + 1
          result.handles[#result.handles + 1] = assert(registry.send(owner, epoch, {}, payload))
        end
        return result
      end
      function registry.broadcast(owner, epoch, payload)
        return registry.sendMany(owner, epoch, { {}, {} }, payload)
      end
      function registry.onAction() return true end
      function registry.pullCommand() return { commandId = 'notify-command-pull-fixture' } end
      function registry.invokeAction() return { accepted = true } end
      function registry.cleanupOwner(owner, maximumEpoch)
        __appTest.cleanup[#__appTest.cleanup + 1] = {
          owner = owner, maximumEpoch = maximumEpoch,
        }
        return { removed = 0 }
      end
      function registry.playerDropped() return 0 end
      function registry.clearPendingCommands()
        __appTest.pendingClears = __appTest.pendingClears + 1
        return 0
      end
      function registry.expire() return { actions = 0, notifications = 0 } end
      function registry.snapshot()
        return { active = 0, progressActive = 0, actionTokens = 0,
          ownerCount = 0, maximumRecords = 512, owners = {}, metrics = {}, history = {} }
      end
      function registry.doctor() return { status = 'READY', findings = {} } end
      function registry.records() return __appTest.records end

      local application
      local observability = {
        gauge = function() end,
        refreshClientGauges = function() end,
        playerDropped = function() end,
        reportClient = function() return { accepted = true } end,
      }
      local service = SynexNotifyService.create({
        registry = registry,
        foundation = SynexNotifyFoundation,
        observability = observability,
        resolveOwnerEpoch = function(owner, callerEpoch)
          assert(callerEpoch == 501 or callerEpoch == 777)
          return application.resolveOwnerEpoch(owner, callerEpoch)
        end,
      })
      local controlProvider = {
        register = function(api)
          return api.ControlProviders.register({ namespace = 'notify' })
        end,
      }
      local coreRef = {}
      application = SynexNotifyApplication.create({
        resourceName = 'synex_notify', coreResource = 'synex_core',
        bridgeResource = 'synex_bridge', uiResource = 'synex_ui',
        coreRange = '^1.0.0', coreRef = coreRef, registry = registry,
        service = service, controlProvider = controlProvider,
        observability = observability,
        acquireCore = function(range)
          assert(range == '^1.0.0')
          return coreApi
        end,
        loadResourceFile = function(resource, relative)
          assert(resource == 'synex_notify' and relative == 'contracts/notify.contracts.json')
          return '{}'
        end,
        decode = function() return contractBundle() end,
        wait = function(milliseconds)
          __appTest.waits[#__appTest.waits + 1] = milliseconds
        end,
        createThread = function(handler) handler() end,
        getResourceState = function(resource)
          return __appTest.states[resource] or 'missing'
        end,
        registerBridgeAdapter = function(definition, implementation)
          __appTest.bridges[#__appTest.bridges + 1] = {
            definition = definition, implementation = implementation,
          }
          return 'bridge-token-' .. #__appTest.bridges
        end,
      })

      assert(application.start())
      assert(#__appTest.services == 1)
      assert(#__appTest.serverContracts == 3 and #__appTest.networkContracts == 3)
      assert(#__appTest.workers == 1 and __appTest.workers[1].interval == 1000)
      assert(#__appTest.providers == 1 and #__appTest.bridges == 1)
      assert(__appTest.health[1].state == 'UNHEALTHY')
      assert(__appTest.health[#__appTest.health].state == 'HEALTHY')
      assert(__appTest.bridges[1].definition.status == 'PARTIAL')
      assert(#__appTest.bridges[1].definition.operations == 1
        and __appTest.bridges[1].definition.operations[1] == 'send')

      local facade = assert(application.getAPI('v1'))
      assert(facade.ownerResource == 'owner_alpha' and facade.version == '1.0.0')
      assert(type(facade.sendSystem) == 'function'
        and type(facade.sendManySystem) == 'function'
        and type(facade.broadcastSystem) == 'function')
      local firstEpoch = facade.ownerEpoch
      local handle = assert(facade.notify({}, { title = 'Facade send' }))
      local updated = assert(handle:update({ message = 'Facade update' }))
      assert(updated == handle and handle.revision == 2)
      local dismissed = assert(handle:dismiss('dismissed'))
      assert(dismissed.dismissed == true)
      local systemHandle = assert(facade.sendSystem({}, { title = 'System facade send' }))
      assert(systemHandle.ownerResource == 'owner_alpha')
      assert(__appTest.lastFacadeContext.operation == 'notify.send_system'
        and __appTest.lastFacadeContext.origin == 'SYSTEM')
      local diagnostics = assert(facade.getDiagnostics())
      assert(diagnostics.maximumRecords == 512)

      local compatibility = __appTest.bridges[1].implementation
      local compatible = assert(compatibility.send({
        consumer = 'compat_consumer', traceId = 'trace-compat',
      }, {
        target = {}, notification = { title = 'Compatibility send' },
      }))
      assert(compatible.ownerResource == 'compat_consumer')

      assert(application.resourceStopped('owner_alpha'))
      assert(__appTest.cleanup[#__appTest.cleanup].owner == 'owner_alpha')
      assert(__appTest.cleanup[#__appTest.cleanup].maximumEpoch == firstEpoch)
      local staleValue, staleError = facade.send({}, { title = 'Stale owner' })
      assert(staleValue == false and staleError.code == 'NOTIFY_OWNER_STOPPED')
      application.resourceStarted('owner_alpha')
      local currentFacade = assert(application.getAPI('1.0.0'))
      assert(currentFacade.ownerEpoch > firstEpoch)

      local serviceHandle = assert(service.send({
        target = {}, payload = { title = 'Service path shares owner authority' },
      }, { caller = 'owner_alpha', callerEpoch = 501, traceId = 'trace-service' }))
      assert(serviceHandle.ownerEpoch == currentFacade.ownerEpoch)
      local directUpdate = assert(currentFacade.update(serviceHandle, {
        message = 'Updated through the direct facade',
      }))
      local serviceUpdate = assert(service.update({
        handle = {
          notificationId = directUpdate.notificationId,
          ownerResource = directUpdate.ownerResource,
          ownerEpoch = directUpdate.ownerEpoch,
          revision = directUpdate.revision,
        },
        patch = { message = 'Updated through Core service' },
      }, { caller = 'owner_alpha', callerEpoch = 777, traceId = 'trace-service' }))
      assert(serviceUpdate.ownerEpoch == currentFacade.ownerEpoch
        and serviceUpdate.revision == directUpdate.revision + 1)

      application.resourceStopped('synex_ui')
      assert(__appTest.health[#__appTest.health].state == 'DEGRADED')
      application.resourceStopped('synex_bridge')
      application.resourceStarted('synex_bridge')
      assert(#__appTest.bridges == 2)

      application.resourceStopped('synex_core')
      assert(__appTest.pendingClears == 1)
      local unavailable, unavailableError = currentFacade.getDiagnostics()
      assert(unavailable == false and unavailableError.code == 'NOTIFY_UNAVAILABLE')
      application.resourceStarted('synex_core')
      assert(#__appTest.services == 2)
      assert(#__appTest.serverContracts == 6 and #__appTest.networkContracts == 6)
      assert(#__appTest.workers == 2 and #__appTest.providers == 2)
      assert(#__appTest.bridges == 3)
      return table.concat({ #__appTest.services, #__appTest.serverContracts,
        #__appTest.networkContracts, #__appTest.bridges, currentFacade.ownerEpoch }, ':')
    `);
    assert.match(String(result), /^2:6:6:3:[2-9][0-9]*$/u);
  } finally {
    engine.global.close();
  }
});

test('server application rejects unsupported API ranges and caller-less access', async () => {
  const engine = await createNotifyLua([
    ...notifyServerFiles,
    'resources/synex_notify/server/runtime.lua',
  ]);
  try {
    const result = await engine.doString(`
      GetInvokingResource = function() return nil end
      local registry = {
        cleanupOwner = function() return { removed = 0 } end,
        playerDropped = function() return 0 end,
      }
      local application = SynexNotifyApplication.create({
        resourceName = 'synex_notify', coreResource = 'synex_core',
        coreRef = {}, registry = registry,
        service = {}, controlProvider = {}, observability = {},
        acquireCore = function() return nil end,
        decode = function() return {} end,
        registerBridgeAdapter = function() return nil end,
        wait = function() end, createThread = function() end,
        getResourceState = function() return 'started' end,
      })
      local _, rangeError = application.getAPI('2.0.0')
      local _, ownerError = application.getAPI('1')
      assert(rangeError.code == 'NOTIFY_PROTOCOL_UNSUPPORTED')
      assert(ownerError.code == 'NOTIFY_OWNER_INVALID')
      return rangeError.code .. ':' .. ownerError.code
    `);
    assert.equal(result, 'NOTIFY_PROTOCOL_UNSUPPORTED:NOTIFY_OWNER_INVALID');
  } finally {
    engine.global.close();
  }
});
