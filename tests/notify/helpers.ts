import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { LuaFactory, type LuaEngine } from 'wasmoon';

const root = process.cwd();

export const notifySharedFiles = [
  'resources/synex_notify/shared/limits.lua',
  'resources/synex_notify/shared/validation.lua',
] as const;

export const notifyServerFiles = [
  ...notifySharedFiles,
  'resources/synex_notify/server/foundation.lua',
  'resources/synex_notify/server/observability.lua',
  'resources/synex_notify/server/registry.lua',
  'resources/synex_notify/server/service.lua',
  'resources/synex_notify/server/control_provider.lua',
] as const;

export async function createNotifyLua(
  files: readonly string[] = notifyServerFiles,
): Promise<LuaEngine> {
  const engine = await new LuaFactory().createEngine();
  for (const relativePath of files) {
    await engine.doString(await readFile(path.join(root, relativePath), 'utf8'));
  }
  return engine;
}

export async function runNotifyLua<T>(
  source: string,
  files: readonly string[] = notifyServerFiles,
): Promise<T> {
  const engine = await createNotifyLua(files);
  try {
    return await engine.doString(source) as T;
  } finally {
    engine.global.close();
  }
}

export const notifyServerHarness = `
  __notifyTest = {
    now = 1000,
    serial = 0,
    deliveries = {},
    deliveryCount = 0,
    denied = {},
    systemPrincipals = {},
    privilegeChecks = {},
    sessions = {},
    players = {},
    audits = {},
    events = {},
    metrics = {},
    resourceStates = { synex_ui = 'started' },
    transportFailure = false,
  }

  function __notifyTest.addSession(source, generation)
    generation = generation or 1
    local session = {
      source = source,
      id = ('session-%04d-%04d'):format(source, generation),
      sourceGeneration = generation,
      state = 'ACTIVE',
    }
    __notifyTest.sessions[source] = session
    __notifyTest.players[#__notifyTest.players + 1] = tostring(source)
    return session
  end

  function __notifyTest.makeObservability()
    local coreRef = { value = {
      Metrics = {
        increment = function(name, _, amount)
          __notifyTest.metrics[name] = (__notifyTest.metrics[name] or 0) + (amount or 1)
          return true
        end,
        gauge = function() return true end,
        observe = function() return true end,
      },
      Audit = { append = function(entry)
        __notifyTest.audits[#__notifyTest.audits + 1] = entry
        return true
      end },
      Events = { publish = function(topic, payload)
        __notifyTest.events[#__notifyTest.events + 1] = { topic = topic, payload = payload }
        return true
      end },
    } }
    return SynexNotifyObservability.create({
      foundation = SynexNotifyFoundation,
      coreRef = coreRef,
      now = function() return __notifyTest.now end,
    })
  end

  function __notifyTest.makeRegistry()
    local observability = __notifyTest.makeObservability()
    local registry = SynexNotifyRegistry.create({
      foundation = SynexNotifyFoundation,
      now = function() return __notifyTest.now end,
      utc = function() return '2026-08-28T18:00:00Z' end,
      nextId = function(namespace)
        if type(__notifyTest.nextId) == 'function' then
          return __notifyTest.nextId(namespace)
        end
        __notifyTest.serial = __notifyTest.serial + 1
        return ('%s-%08d'):format(namespace, __notifyTest.serial)
      end,
      getSession = function(source)
        return __notifyTest.sessions[source]
      end,
      triggerClient = function(source, eventName, envelope)
        if __notifyTest.transportFailure then error('transport unavailable') end
        __notifyTest.deliveryCount = __notifyTest.deliveryCount + 1
        __notifyTest.deliveries[#__notifyTest.deliveries + 1] = {
          source = source,
          eventName = eventName,
          envelope = SynexNotifyFoundation.copy(envelope),
        }
        return true
      end,
      checkPrivilege = function(owner, capability, operation)
        __notifyTest.privilegeChecks[#__notifyTest.privilegeChecks + 1] = {
          owner = owner, capability = capability, operation = operation,
        }
        if __notifyTest.denied[capability] then
          return nil, { code = 'CAPABILITY_DENIED', retryable = false }
        end
        return true
      end,
      isSystemPrincipal = function(owner)
        return __notifyTest.systemPrincipals[owner] == true
      end,
      getPlayers = function() return __notifyTest.players end,
      getResourceState = function(resource)
        return __notifyTest.resourceStates[resource] or 'missing'
      end,
      observability = observability,
    })
    __notifyTest.registry = registry
    __notifyTest.observability = observability
    return registry, SynexNotifyService.create({
      registry = registry,
      foundation = SynexNotifyFoundation,
      observability = observability,
    })
  end

  function __notifyTest.target(source)
    local session = assert(__notifyTest.sessions[source])
    return {
      source = session.source,
      sessionId = session.id,
      sourceGeneration = session.sourceGeneration,
    }
  end

  function __notifyTest.lastDelivery()
    return __notifyTest.deliveries[#__notifyTest.deliveries]
  end

  function __notifyTest.command(delivery)
    delivery = delivery or __notifyTest.lastDelivery()
    assert(delivery and delivery.envelope)
    if delivery.command ~= nil then return delivery.command end
    local session = assert(__notifyTest.sessions[delivery.source])
    local command, commandError = __notifyTest.registry.pullCommand({
      commandId = delivery.envelope.commandId,
    }, {
      source = session.source,
      sourceGeneration = session.sourceGeneration,
      session = session,
    })
    assert(command, commandError and commandError.code or 'command pull failed')
    delivery.command = command
    return command
  end

  function __notifyTest.lastCommand()
    return __notifyTest.command(__notifyTest.lastDelivery())
  end
`;
