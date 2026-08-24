import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory, type LuaEngine } from 'wasmoon';

const root = process.cwd();

async function load(engine: LuaEngine, relativePath: string): Promise<void> {
  await engine.doString(await readFile(path.join(root, relativePath), 'utf8'));
}

async function createEngine(files: string[]): Promise<LuaEngine> {
  const engine = await new LuaFactory().createEngine();
  await load(engine, 'core/synex_core/shared/protocol.lua');
  await load(engine, 'core/synex_core/server/factories.lua');
  for (const file of files) await load(engine, `core/synex_core/server/${file}.lua`);
  await engine.doString(`
    local now = 1000
    CapturedLogs = {}
    FakePlatform = {
      nowGame = function() now = now + 1 return now end,
      random = function(_, maximum) return math.min(maximum or 1, 123456) end,
      print = function() end,
      jsonEncode = function(value)
        if type(value) == 'table' and value.message ~= nil then
          CapturedLogs[#CapturedLogs + 1] = value
        end
        return '{}'
      end,
      jsonDecode = function() return {} end,
      loadResourceFile = function() return nil end,
      setTimeout = function(_, callback) callback() end
    }
  `);
  return engine;
}

test('event and hook authority is manifest-declared, namespace-owned, and restart-fenced', async () => {
  const engine = await createEngine([
    'foundation',
    'registries',
    'lifecycle',
    'contracts',
    'security',
    'messaging',
  ]);
  try {
    const result = await engine.doString(`
      local foundation = SynexCoreFactories.foundation({ platform = FakePlatform })
      foundation.configureIds('event-authority')
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      local owners = registries.owners
      local lifecycle = SynexCoreFactories.lifecycle({
        platform = FakePlatform, foundation = foundation, owners = owners
      })
      local security = SynexCoreFactories.security({
        platform = FakePlatform, foundation = foundation, coreResource = 'synex_core',
        policy = { default = { allow = {}, deny = {} }, resources = {} }
      })
      local contracts = SynexCoreFactories.contracts({ foundation = foundation, protocol = SynexProtocol })
      local messaging = SynexCoreFactories.messaging({
        platform = FakePlatform, foundation = foundation, contracts = contracts,
        security = security, owners = owners, players = registries.players,
        lifecycle = lifecycle, dependencies = lifecycle.dependencies,
        protocol = SynexProtocol, config = {}, coreResource = 'synex_core'
      })

      local coreEpoch = owners:activate('synex_core')
      local accountsEpoch = owners:activate('synex_accounts')
      local groupsEpoch = owners:activate('synex_groups')
      local observerEpoch = owners:activate('synex_observer')
      local errorEpoch = owners:activate('synex_error_observer')
      local charactersEpoch = owners:activate('synex_characters')

      assert(security.capabilities:registerManifest('synex_core', {
        capabilities = { request = {} },
        events = { publish = {'synex.characters.created'}, subscribe = {} },
        hooks = { register = {}, run = {'synex.characters.before_create'} }
      }))
      assert(security.capabilities:registerManifest('synex_accounts', {
        capabilities = { request = {} },
        events = { publish = {'synex.accounts.*'}, subscribe = {} },
        hooks = { register = {}, run = {} }
      }))
      -- A malformed manifest cannot normally pass discovery. Registering it directly here
      -- verifies that the runtime still rejects a foreign producer namespace.
      assert(security.capabilities:registerManifest('synex_groups', {
        capabilities = { request = {} },
        events = { publish = {'synex.accounts.*'}, subscribe = {} },
        hooks = { register = {}, run = {'synex.characters.before_create'} }
      }))
      assert(security.capabilities:registerManifest('synex_observer', {
        capabilities = { request = {} },
        events = { publish = {}, subscribe = {'synex.accounts.*'} },
        hooks = { register = {'synex.characters.*'}, run = {} }
      }))
      assert(security.capabilities:registerManifest('synex_error_observer', {
        capabilities = { request = {} },
        events = { publish = {}, subscribe = {'synex.accounts.changed'} },
        hooks = { register = {'synex.characters.before_create'}, run = {} }
      }))
      assert(security.capabilities:registerManifest('synex_characters', {
        capabilities = { request = {} },
        events = { publish = {}, subscribe = {} },
        hooks = { register = {'synex.characters.before_create'}, run = {} }
      }))

      local deliveries = 0
      local eventHandler = setmetatable({ __cfx_functionReference = 'fixture-event-handler' }, {
        __metatable = 'protected-cfx-funcref',
        __call = function(_, payload, context)
          assert(payload.value == 1 and context.publisher == 'synex_accounts')
          deliveries = deliveries + 1
          return true, nil
        end
      })
      assert(messaging.events:subscribe(
        'synex_observer', observerEpoch, 'synex.accounts.changed', eventHandler))
      assert(messaging.events:subscribe(
        'synex_error_observer', errorEpoch, 'synex.accounts.changed', function()
          error('subscriber-private-payload')
        end))

      local undeclaredSubscription, undeclaredSubscriptionError = messaging.events:subscribe(
        'synex_observer', observerEpoch, 'synex.characters.created', function() end)
      assert(undeclaredSubscription == nil
        and undeclaredSubscriptionError.code == 'EVENT_SUBSCRIBE_UNDECLARED')
      local foreignPublication, foreignPublicationError = messaging.events:publish(
        'synex_groups', groupsEpoch, 'synex.accounts.changed', {})
      assert(foreignPublication == nil and foreignPublicationError.code == 'EVENT_TOPIC_FORBIDDEN')

      local first = assert(messaging.events:publish(
        'synex_accounts', accountsEpoch, 'synex.accounts.changed', { value = 1 }))
      assert(first.delivered == 1 and first.failed == 1 and deliveries == 1)

      for index = 1, 255 do
        assert(messaging.events:subscribe('synex_observer', observerEpoch,
          ('synex.accounts.fixture_%d'):format(index), function() return true end))
      end
      local subscriptionLimit, subscriptionLimitError = messaging.events:subscribe(
        'synex_observer', observerEpoch, 'synex.accounts.fixture_overflow', function() end)
      assert(subscriptionLimit == nil and subscriptionLimitError.code == 'SUBSCRIPTION_LIMIT_REACHED')

      local hookCalls = 0
      local hookHandler = setmetatable({ __cfx_functionReference = 'fixture-hook-handler' }, {
        __metatable = 'protected-cfx-funcref',
        __call = function(_, value, context)
          assert(context.caller == 'synex_core')
          hookCalls = hookCalls + 1
          if value.requestDeny then
            return { action = 'deny', code = 'FOREIGN_DENIAL', message = 'must be ignored' }
          end
          value.reviewed = true
          return { action = 'patch', value = value }
        end
      })
      local foreignRequired, foreignRequiredError = messaging.hooks:register(
        'synex_observer', observerEpoch, 'synex.characters.before_create', hookHandler,
        { priority = 10, required = true })
      assert(foreignRequired == nil and foreignRequiredError.code == 'HOOK_POLICY_FORBIDDEN')
      assert(messaging.hooks:register(
        'synex_observer', observerEpoch, 'synex.characters.before_create', hookHandler,
        { priority = 10 }))
      assert(messaging.hooks:register(
        'synex_characters', charactersEpoch, 'synex.characters.before_create', function()
          return { action = 'allow' }
        end, { priority = 5, required = true }))
      assert(messaging.hooks:register(
        'synex_error_observer', errorEpoch, 'synex.characters.before_create', function()
          error('hook-private-payload')
        end, { priority = -10 }))
      for index = 1, 255 do
        assert(messaging.hooks:register('synex_observer', observerEpoch,
          ('synex.characters.fixture_%d'):format(index), function(value)
            return { action = 'allow', value = value }
          end))
      end
      local hookLimit, hookLimitError = messaging.hooks:register(
        'synex_observer', observerEpoch, 'synex.characters.fixture_overflow', function() end)
      assert(hookLimit == nil and hookLimitError.code == 'HOOK_LIMIT_REACHED')
      local undeclaredHook, undeclaredHookError = messaging.hooks:register(
        'synex_accounts', accountsEpoch, 'synex.characters.before_create', function() end)
      assert(undeclaredHook == nil and undeclaredHookError.code == 'HOOK_REGISTER_UNDECLARED')
      local foreignRun, foreignRunError = messaging.hooks:run(
        'synex_groups', groupsEpoch, 'synex.characters.before_create', {})
      assert(foreignRun == nil and foreignRunError.code == 'HOOK_NAME_FORBIDDEN')
      local hooked = assert(messaging.hooks:run(
        'synex_core', coreEpoch, 'synex.characters.before_create', { reviewed = false }))
      assert(hooked.reviewed == true and hookCalls == 1)
      local foreignDenied = assert(messaging.hooks:run(
        'synex_core', coreEpoch, 'synex.characters.before_create', { requestDeny = true }))
      assert(foreignDenied.requestDeny == true and hookCalls == 2)

      local function containsPrivateValue(value)
        if type(value) == 'string' then return value:find('private%-payload') ~= nil end
        if type(value) ~= 'table' then return false end
        for key, child in pairs(value) do
          if containsPrivateValue(key) or containsPrivateValue(child) then return true end
        end
        return false
      end
      local subscriberLog, hookLog = false, false
      for _, record in ipairs(CapturedLogs) do
        assert(not containsPrivateValue(record))
        if record.message == 'domain event subscriber failed' then
          subscriberLog = record.fields.code == 'SUBSCRIBER_EXCEPTION'
            and record.fields.error == nil
        elseif record.message == 'hook failed' then
          hookLog = record.fields.code == 'HOOK_EXCEPTION' and record.fields.error == nil
        end
      end
      assert(subscriberLog and hookLog)

      -- Revoking a declaration takes effect at delivery time even before cleanup runs.
      assert(security.capabilities:unregisterManifest('synex_observer'))
      assert(security.capabilities:registerManifest('synex_observer', {
        capabilities = { request = {} },
        events = { publish = {}, subscribe = {} },
        hooks = { register = {}, run = {} }
      }))
      local afterRevocation = assert(messaging.events:publish(
        'synex_accounts', accountsEpoch, 'synex.accounts.changed', { value = 1 }))
      assert(afterRevocation.delivered == 0 and afterRevocation.failed == 2 and deliveries == 1)
      assert(security.capabilities:unregisterManifest('synex_characters'))
      assert(security.capabilities:registerManifest('synex_characters', {
        capabilities = { request = {} },
        events = { publish = {}, subscribe = {} },
        hooks = { register = {}, run = {} }
      }))
      local afterHookRevocation, afterHookRevocationError = messaging.hooks:run(
        'synex_core', coreEpoch, 'synex.characters.before_create', {})
      assert(afterHookRevocation == nil
        and afterHookRevocationError.code == 'REQUIRED_HOOK_FAILED' and hookCalls == 2)

      local cleanup = owners:purge('synex_observer', observerEpoch, 'fixture restart')
      assert(#cleanup.errors == 0)
      local newObserverEpoch = owners:activate('synex_observer')
      assert(newObserverEpoch ~= observerEpoch)
      local stale, staleError = messaging.events:subscribe(
        'synex_observer', observerEpoch, 'synex.accounts.changed', function() end)
      assert(stale == nil and staleError.code == 'STALE_RESOURCE')
      local current, currentError = messaging.events:subscribe(
        'synex_observer', newObserverEpoch, 'synex.accounts.changed', function() end)
      assert(current == nil and currentError.code == 'EVENT_SUBSCRIBE_UNDECLARED')

      local tooLongId, tooLongIdError = messaging.events:publishOutbox(
        'synex_accounts', accountsEpoch, 'synex.accounts.changed', {}, {
          eventId = string.rep('e', 37), aggregateId = 'aggregate-a', schemaVersion = 1
        })
      assert(tooLongId == nil and tooLongIdError.code == 'INVALID_OUTBOX_EVENT')

      return table.concat({ deliveries, hookCalls, foreignRequiredError.code, subscriptionLimitError.code,
        hookLimitError.code, afterHookRevocationError.code, staleError.code,
        currentError.code, tooLongIdError.code }, ':')
    `);
    assert.equal(
      result,
      '1:2:HOOK_POLICY_FORBIDDEN:SUBSCRIPTION_LIMIT_REACHED:HOOK_LIMIT_REACHED:REQUIRED_HOOK_FAILED:STALE_RESOURCE:'
        + 'EVENT_SUBSCRIBE_UNDECLARED:INVALID_OUTBOX_EVENT',
    );
  } finally {
    engine.global.close();
  }
});

test('hook providers preserve false-error failures across Cfx callbacks', async () => {
  const engine = await createEngine([
    'foundation',
    'registries',
    'lifecycle',
    'contracts',
    'security',
    'messaging',
  ]);
  try {
    const result = await engine.doString(`
      local foundation = SynexCoreFactories.foundation({ platform = FakePlatform })
      foundation.configureIds('hook-provider-errors')
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      local owners = registries.owners
      local coreEpoch = owners:activate('synex_core')
      local observerEpoch = owners:activate('synex_observer')
      local charactersEpoch = owners:activate('synex_characters')
      local lifecycle = SynexCoreFactories.lifecycle({
        platform = FakePlatform, foundation = foundation, owners = owners
      })
      local security = SynexCoreFactories.security({
        platform = FakePlatform, foundation = foundation, coreResource = 'synex_core'
      })
      assert(security.capabilities:registerManifest('synex_core', {
        capabilities = { request = {} },
        events = { publish = {}, subscribe = {} },
        hooks = { register = {}, run = {'synex.characters.*'} }
      }))
      assert(security.capabilities:registerManifest('synex_observer', {
        capabilities = { request = {} },
        events = { publish = {}, subscribe = {} },
        hooks = { register = {'synex.characters.*'}, run = {} }
      }))
      assert(security.capabilities:registerManifest('synex_characters', {
        capabilities = { request = {} },
        events = { publish = {}, subscribe = {} },
        hooks = { register = {'synex.characters.*'}, run = {} }
      }))
      local messaging = SynexCoreFactories.messaging({
        platform = FakePlatform, foundation = foundation,
        contracts = SynexCoreFactories.contracts({
          foundation = foundation, protocol = SynexProtocol
        }),
        security = security, owners = owners, players = registries.players,
        lifecycle = lifecycle, dependencies = lifecycle.dependencies,
        protocol = SynexProtocol, config = {}, coreResource = 'synex_core'
      })

      local optionalFailure = setmetatable({ __cfx_functionReference = 'optional-hook-failure' }, {
        __metatable = 'protected-cfx-funcref',
        __call = function()
          return false, foundation.error('OPTIONAL_HOOK_FAILURE', 'fixture optional failure')
        end
      })
      assert(messaging.hooks:register(
        'synex_observer', observerEpoch, 'synex.characters.false_error', optionalFailure,
        { priority = 20 }))
      assert(messaging.hooks:register(
        'synex_characters', charactersEpoch, 'synex.characters.false_error', function(value)
          value.continued = true
          return { action = 'patch', value = value }
        end, { priority = 10, required = true }))
      local continued = assert(messaging.hooks:run(
        'synex_core', coreEpoch, 'synex.characters.false_error', {}))
      assert(continued.continued == true)

      local requiredFailure = setmetatable({ __cfx_functionReference = 'required-hook-failure' }, {
        __metatable = 'protected-cfx-funcref',
        __call = function()
          return false, foundation.error('REQUIRED_PROVIDER_FAILURE', 'fixture required failure')
        end
      })
      assert(messaging.hooks:register(
        'synex_characters', charactersEpoch, 'synex.characters.required_failure',
        requiredFailure, { required = true }))
      local rejected, rejectedError = messaging.hooks:run(
        'synex_core', coreEpoch, 'synex.characters.required_failure', {})
      assert(rejected == nil and rejectedError.code == 'REQUIRED_HOOK_FAILED')

      assert(messaging.hooks:register(
        'synex_observer', observerEpoch, 'synex.characters.internal_failure', function()
          return nil, foundation.error('INTERNAL_PROVIDER_FAILURE', 'fixture internal failure')
        end))
      assert(messaging.hooks:register(
        'synex_characters', charactersEpoch, 'synex.characters.internal_failure', function(value)
          value.internalContinued = true
          return { action = 'patch', value = value }
        end, { required = true }))
      local internalContinued = assert(messaging.hooks:run(
        'synex_core', coreEpoch, 'synex.characters.internal_failure', {}))
      assert(internalContinued.internalContinued == true)

      local logged = {}
      for _, record in ipairs(CapturedLogs) do
        if record.message == 'hook failed' then logged[record.fields.code] = true end
      end
      assert(logged.OPTIONAL_HOOK_FAILURE and logged.REQUIRED_PROVIDER_FAILURE
        and logged.INTERNAL_PROVIDER_FAILURE)
      return table.concat({tostring(continued.continued), rejectedError.code,
        tostring(internalContinued.internalContinued)}, ':')
    `);
    assert.equal(result, 'true:REQUIRED_HOOK_FAILED:true');
  } finally {
    engine.global.close();
  }
});

test('hook transport bounds reject oversized inputs, contexts, and provider patches', async () => {
  const engine = await createEngine([
    'foundation',
    'registries',
    'lifecycle',
    'contracts',
    'security',
    'messaging',
  ]);
  try {
    const result = await engine.doString(`
      local now, handlerCalls = 1000, 0
      local function encodedSize(value, seen)
        local kind = type(value)
        if kind == 'string' then return #value + 2 end
        if kind == 'number' or kind == 'boolean' then return 8 end
        if kind == 'nil' then return 4 end
        if kind ~= 'table' then error('unsupported fixture value') end
        seen = seen or {}
        if seen[value] then error('cyclic fixture value') end
        seen[value] = true
        local size = 2
        for key, child in pairs(value) do
          size = size + encodedSize(key, seen) + encodedSize(child, seen) + 2
        end
        seen[value] = nil
        return size
      end
      local platform = {
        nowGame = function() return now end,
        random = function() return 1 end,
        print = function() end,
        jsonEncode = function(value) return string.rep('x', encodedSize(value)) end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('hook-transport-bounds')
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      local owners = registries.owners
      local coreEpoch = owners:activate('synex_core')
      local charactersEpoch = owners:activate('synex_characters')
      local lifecycle = SynexCoreFactories.lifecycle({
        platform = platform, foundation = foundation, owners = owners
      })
      local security = SynexCoreFactories.security({
        platform = platform, foundation = foundation, coreResource = 'synex_core'
      })
      assert(security.capabilities:registerManifest('synex_core', {
        capabilities = { request = {} },
        events = { publish = {}, subscribe = {} },
        hooks = { register = {}, run = {'synex.characters.before_create'} }
      }))
      assert(security.capabilities:registerManifest('synex_characters', {
        capabilities = { request = {} },
        events = { publish = {}, subscribe = {} },
        hooks = { register = {'synex.characters.before_create'}, run = {} }
      }))
      local messaging = SynexCoreFactories.messaging({
        platform = platform, foundation = foundation,
        contracts = SynexCoreFactories.contracts({
          foundation = foundation, protocol = SynexProtocol
        }),
        security = security, owners = owners, players = registries.players,
        lifecycle = lifecycle, dependencies = lifecycle.dependencies,
        protocol = SynexProtocol,
        config = { maximumPayloadBytes = 32768, timeoutMs = 5000, maximumTimeoutMs = 15000 },
        coreResource = 'synex_core'
      })
      local largeInput = {}
      for index = 1, 512 do largeInput['field_' .. index] = string.rep('x', 16384) end
      local largePatch = {}
      for index = 1, 510 do largePatch['field_' .. index] = string.rep('x', 16384) end
      assert(messaging.hooks:register(
        'synex_characters', charactersEpoch, 'synex.characters.before_create', function(value)
          handlerCalls = handlerCalls + 1
          if value.slow then
            now = now + 101
            return { action = 'allow' }
          end
          return { action = 'patch', value = largePatch }
        end, { required = true }))

      local oversizedInput, oversizedInputError = messaging.hooks:run(
        'synex_core', coreEpoch, 'synex.characters.before_create', largeInput)
      assert(oversizedInput == nil and oversizedInputError.code == 'HOOK_PAYLOAD_TOO_LARGE'
        and handlerCalls == 0)
      local oversizedMetadata = {}
      for index = 1, 510 do oversizedMetadata['field_' .. index] = string.rep('x', 16384) end
      local oversizedContext, oversizedContextError = messaging.hooks:run(
        'synex_core', coreEpoch, 'synex.characters.before_create', {}, {
          metadata = oversizedMetadata
        })
      assert(oversizedContext == nil and oversizedContextError.code == 'HOOK_CONTEXT_TOO_LARGE'
        and handlerCalls == 0)
      local forged, forgedError = messaging.hooks:run(
        'synex_core', coreEpoch, 'synex.characters.before_create', {}, {
          deadlineAt = 999999
        })
      assert(forged == nil and forgedError.code == 'INVALID_HOOK_CONTEXT'
        and handlerCalls == 0)
      local patched, patchError = messaging.hooks:run(
        'synex_core', coreEpoch, 'synex.characters.before_create', {})
      assert(patched == nil and patchError.code == 'INVALID_HOOK_RESULT'
        and handlerCalls == 1)
      local expired, expiredError = messaging.hooks:run(
        'synex_core', coreEpoch, 'synex.characters.before_create', { slow = true }, {
          timeoutMs = 100, traceId = 'trace-hook-deadline'
        })
      assert(expired == nil and expiredError.code == 'DEADLINE_EXCEEDED'
        and handlerCalls == 2)
      return table.concat({oversizedInputError.code, oversizedContextError.code,
        forgedError.code, patchError.code, expiredError.code}, ':')
    `);
    assert.equal(
      result,
      'HOOK_PAYLOAD_TOO_LARGE:HOOK_CONTEXT_TOO_LARGE:INVALID_HOOK_CONTEXT:'
        + 'INVALID_HOOK_RESULT:DEADLINE_EXCEEDED',
    );
  } finally {
    engine.global.close();
  }
});

test('generic outbox bounds event IDs and preserves nullable legacy producer attribution', async () => {
  const engine = await createEngine(['foundation', 'reliability']);
  try {
    const result = await engine.doString(`
      local foundation = SynexCoreFactories.foundation({ platform = FakePlatform })
      foundation.configureIds('outbox-owner')
      local insertedParameters = nil
      local updateCalls = 0
      local database = {
        insert = function(_, _, parameters)
          insertedParameters = parameters
          return 11, nil
        end,
        update = function()
          updateCalls = updateCalls + 1
          return 1, nil
        end,
        query = function()
          return {
            {
              id = 1, event_id = 'legacy-event', producer_resource = nil,
              aggregate_type = 'fixture', aggregate_id = 'aggregate-a',
              event_type = 'synex.accounts.changed', schema_version = 1,
              payload_json = '{}', headers_json = '{}', attempts = 1
            },
            {
              id = 2, event_id = 'owned-event', producer_resource = 'synex_accounts',
              aggregate_type = 'fixture', aggregate_id = 'aggregate-b',
              event_type = 'synex.accounts.changed', schema_version = 1,
              payload_json = '{}', headers_json = '{}', attempts = 1
            }
          }, nil
        end
      }
      local reliability = SynexCoreFactories.reliability({
        platform = FakePlatform, foundation = foundation, database = database,
        sha256 = function() return string.rep('0', 64) end,
        instanceId = 'outbox-owner', features = { durableEvents = true }
      })

      local rejected, rejectedError = reliability.outbox:enqueue('synex_accounts', {
        eventId = string.rep('e', 37), aggregateType = 'fixture', aggregateId = 'aggregate-a',
        eventType = 'synex.accounts.changed', payload = {}, headers = {}
      })
      assert(rejected == nil and rejectedError.code == 'INVALID_OUTBOX_EVENT'
        and insertedParameters == nil)
      local accepted = assert(reliability.outbox:enqueue('synex_accounts', {
        eventId = string.rep('e', 36), aggregateType = 'fixture', aggregateId = 'aggregate-a',
        eventType = 'synex.accounts.changed', payload = {}, headers = {}
      }))
      assert(accepted.id == 11 and insertedParameters[1] == string.rep('e', 36)
        and insertedParameters[2] == 'synex_accounts')

      local producers = {}
      local report = assert(reliability.outbox:dispatchBatch(function(event)
        producers[#producers + 1] = event.producerResource
        return false
      end, 2))
      assert(report.claimed == 2 and report.retried == 2 and report.published == 0)
      assert(#producers == 1 and producers[1] == 'synex_accounts')
      -- A nil array element is not retained by Lua; explicitly prove that the legacy
      -- row reached the handler without being rewritten to synex_core.
      local legacySeen = false
      reliability.outbox:dispatchBatch(function(event)
        if event.eventId == 'legacy-event' then
          legacySeen = true
          assert(event.producerResource == nil)
        end
        return false
      end, 2)
      assert(legacySeen)
      return table.concat({ rejectedError.code, insertedParameters[2], report.retried }, ':')
    `);
    assert.equal(result, 'INVALID_OUTBOX_EVENT:synex_accounts:2');
  } finally {
    engine.global.close();
  }
});

test('idempotency handler failure is indeterminate when its terminal fence is lost', async () => {
  const engine = await createEngine(['foundation', 'reliability']);
  try {
    const result = await engine.doString(`
      local foundation = SynexCoreFactories.foundation({ platform = FakePlatform })
      foundation.configureIds('idempotency-terminal-fence')
      local updates = 0
      local database = {
        update = function(_, sql)
          updates = updates + 1
          if sql:find("SET \`state\` = 'failed'", 1, true) then return 0, nil end
          error('unexpected update')
        end,
        withTransaction = function(_, handler)
          local accepted = handler(function(sql)
            if sql:find('FROM \`synex_idempotency_capacity\`', 1, true) then
              return {{ entry_count = 0, global_limit = 10, owner_limit = 10,
                namespace_limit = 10 }}
            end
            if sql:find('INSERT IGNORE INTO \`synex_idempotency_owner_capacity\`', 1, true)
              or sql:find('INSERT IGNORE INTO \`synex_idempotency_namespace_capacity\`', 1, true) then
              return { affectedRows = 1 }
            end
            if sql:find('FROM \`synex_idempotency_owner_capacity\`', 1, true) then
              return {{ entry_count = 0 }}
            end
            if sql:find('FROM \`synex_idempotency_namespace_capacity\`', 1, true) then
              return {{ owner_resource = 'synex_fixture', entry_count = 0 }}
            end
            if sql:find('FROM \`synex_idempotency_keys\`', 1, true) then return {} end
            return { affectedRows = 1 }
          end)
          return accepted == true and true or nil
        end
      }
      local reliability = SynexCoreFactories.reliability({
        platform = FakePlatform, foundation = foundation, database = database,
        sha256 = function() return string.rep('0', 64) end,
        instanceId = 'idempotency-terminal-fence', features = {}
      })
      local value, failure = reliability.idempotency:run(
        'synex_fixture', 'mutate', '11111111-1111-4111-8111-111111111111', {}, function()
          return nil, foundation.error('DOMAIN_FAILURE', 'fixture')
        end)
      assert(value == nil and failure.code == 'IDEMPOTENCY_INDETERMINATE' and updates == 1)
      return failure.code
    `);
    assert.equal(result, 'IDEMPOTENCY_INDETERMINATE');
  } finally {
    engine.global.close();
  }
});

test('public idempotency options and JSON input fail closed without database access', async () => {
  const engine = await createEngine(['foundation', 'reliability']);
  try {
    const result = await engine.doString(`
      local foundation = SynexCoreFactories.foundation({ platform = FakePlatform })
      local databaseTouches = 0
      local database = setmetatable({}, { __index = function()
        return function() databaseTouches = databaseTouches + 1 return 0, nil end
      end })
      local reliability = SynexCoreFactories.reliability({
        platform = FakePlatform, foundation = foundation, database = database,
        sha256 = function() return string.rep('0', 64) end,
        instanceId = 'idempotency-options', features = {}
      })
      local function run(options, request, owner, key)
        return reliability.idempotency:run(
          owner or 'synex_fixture', 'fixture.operation', key or 'fixture-key-0001',
          request or {}, function() return {} end, options)
      end
      for _, options in ipairs({
        { lockSeconds = '30' },
        { lockSeconds = 30.5 },
        { lockSeconds = math.huge },
        { ttlSeconds = 4 },
        { maximumRequestBytes = 65537 },
        { maximumResponseBytes = 0 },
        { unknown = true }
      }) do
        local value, failure = run(options)
        assert(value == nil and failure.code == 'INVALID_IDEMPOTENCY_OPTIONS')
      end
      local nanValue, nanFailure = run({ ttlSeconds = 0 / 0 })
      assert(nanValue == nil and nanFailure.code == 'INVALID_IDEMPOTENCY_OPTIONS')
      local metatableValue, metatableFailure = run(setmetatable({}, { __index = {} }))
      assert(metatableValue == nil and metatableFailure.code == 'INVALID_IDEMPOTENCY_OPTIONS')
      local cyclic = {}
      cyclic.self = cyclic
      local cyclicValue, cyclicFailure = run({}, cyclic)
      assert(cyclicValue == nil and cyclicFailure.code == 'INVALID_JSON_VALUE')
      local ownerValue, ownerFailure = run({}, {}, 'other_resource')
      assert(ownerValue == nil and ownerFailure.code == 'INVALID_IDEMPOTENCY_INPUT')
      local keyValue, keyFailure = run({}, {}, nil, 'invalid key')
      assert(keyValue == nil and keyFailure.code == 'INVALID_IDEMPOTENCY_INPUT')
      local operationValue, operationFailure = reliability.idempotency:run(
        'synex_fixture', 'fixture..operation', 'fixture-key-0001', {}, function() return {} end, {})
      assert(operationValue == nil and operationFailure.code == 'INVALID_IDEMPOTENCY_INPUT')
      assert(databaseTouches == 0)
      return table.concat({ nanFailure.code, metatableFailure.code,
        cyclicFailure.code, databaseTouches }, ':')
    `);
    assert.equal(
      result,
      'INVALID_IDEMPOTENCY_OPTIONS:INVALID_IDEMPOTENCY_OPTIONS:INVALID_JSON_VALUE:0',
    );
  } finally {
    engine.global.close();
  }
});

test('outbox terminal transitions fail closed when the worker loses its row claim', async () => {
  const engine = await createEngine(['foundation', 'reliability']);
  try {
    const result = await engine.doString(`
      local foundation = SynexCoreFactories.foundation({ platform = FakePlatform })
      foundation.configureIds('outbox-terminal-fence')
      local function run(publish)
        local database = {
          update = function(_, sql)
            if sql:find("SET \`state\` = 'published'", 1, true)
              or sql:find('SET \`state\` = ?', 1, true) then return 0, nil end
            return 1, nil
          end,
          query = function()
            return {{
              id = 1, event_id = 'event-terminal-fence', producer_resource = 'synex_fixture',
              aggregate_type = 'fixture', aggregate_id = 'aggregate-a',
              event_type = 'synex.fixture.changed', schema_version = 1,
              payload_json = '{}', headers_json = '{}', attempts = 1
            }}, nil
          end
        }
        local reliability = SynexCoreFactories.reliability({
          platform = FakePlatform, foundation = foundation, database = database,
          sha256 = function() return string.rep('0', 64) end,
          instanceId = publish and 'outbox-publish-fence' or 'outbox-retry-fence',
          features = { durableEvents = true }
        })
        local report, failure = reliability.outbox:dispatchBatch(function()
          return publish
        end, 1)
        assert(report == nil and failure.code == 'OUTBOX_CLAIM_LOST')
        return failure.code
      end
      return run(true) .. ':' .. run(false)
    `);
    assert.equal(result, 'OUTBOX_CLAIM_LOST:OUTBOX_CLAIM_LOST');
  } finally {
    engine.global.close();
  }
});

test('outbox recovery resets expired claims in deterministic bounded batches', async () => {
  const engine = await createEngine(['foundation', 'reliability']);
  try {
    const result = await engine.doString(`
      local foundation = SynexCoreFactories.foundation({ platform = FakePlatform })
      foundation.configureIds('outbox-recovery-bound')
      local remaining, resetCalls, claimCalls = 7, 0, 0
      local database = {
        update = function(_, sql, parameters)
          if sql:find('ORDER BY \`locked_until\` ASC, \`id\` ASC LIMIT ?', 1, true) then
            assert(parameters[1] == 3)
            resetCalls = resetCalls + 1
            local recovered = math.min(remaining, parameters[1])
            remaining = remaining - recovered
            return recovered, nil
          end
          if sql:find("SET \`state\` = 'publishing'", 1, true) then
            claimCalls = claimCalls + 1
            return 0, nil
          end
          error('unexpected update')
        end,
        query = function() return {}, nil end
      }
      local reliability = SynexCoreFactories.reliability({
        platform = FakePlatform, foundation = foundation, database = database,
        sha256 = function() return string.rep('0', 64) end,
        instanceId = 'outbox-recovery-bound', features = { durableEvents = true }
      })
      assert(reliability.outbox:dispatchBatch(function() return true end, 3))
      assert(reliability.outbox:dispatchBatch(function() return true end, 3))
      assert(reliability.outbox:dispatchBatch(function() return true end, 3))
      assert(remaining == 0 and resetCalls == 3 and claimCalls == 3)

      local invalidClaims = 0
      local invalidDatabase = {
        update = function(_, sql)
          if sql:find('ORDER BY \`locked_until\` ASC, \`id\` ASC LIMIT ?', 1, true) then
            return 4, nil
          end
          invalidClaims = invalidClaims + 1
          return 0, nil
        end,
        query = function() return {}, nil end
      }
      local invalidReliability = SynexCoreFactories.reliability({
        platform = FakePlatform, foundation = foundation, database = invalidDatabase,
        sha256 = function() return string.rep('0', 64) end,
        instanceId = 'outbox-recovery-invalid', features = { durableEvents = true }
      })
      local invalid, failure = invalidReliability.outbox:dispatchBatch(
        function() return true end, 3)
      assert(invalid == nil and failure.code == 'OUTBOX_RECOVERY_INVALID'
        and invalidClaims == 0)
      return table.concat({remaining, resetCalls, claimCalls, failure.code}, ':')
    `);
    assert.equal(result, '0:3:3:OUTBOX_RECOVERY_INVALID');
  } finally {
    engine.global.close();
  }
});

test('idempotency response failure requires its terminal fence and compacts only expired responses', async () => {
  const engine = await createEngine(['foundation', 'reliability']);
  try {
    const result = await engine.doString(`
      local foundation = SynexCoreFactories.foundation({ platform = FakePlatform })
      foundation.configureIds('idempotency-response-fence')
      local compactionSql, compactionMaximum = nil, nil
      local database = {
        update = function(_, sql, parameters)
          if sql:find("SET \`state\` = 'failed'", 1, true) then return 0, nil end
          if sql:find('SET \`response_json\` = NULL', 1, true) then
            compactionSql, compactionMaximum = sql, parameters[1]
            return 2, nil
          end
          error('unexpected update')
        end,
        withTransaction = function(_, handler)
          local accepted = handler(function(sql)
            if sql:find('FROM \`synex_idempotency_capacity\`', 1, true) then
              return {{ entry_count = 0, global_limit = 10, owner_limit = 10,
                namespace_limit = 10 }}
            end
            if sql:find('INSERT IGNORE INTO \`synex_idempotency_owner_capacity\`', 1, true)
              or sql:find('INSERT IGNORE INTO \`synex_idempotency_namespace_capacity\`', 1, true) then
              return { affectedRows = 1 }
            end
            if sql:find('FROM \`synex_idempotency_owner_capacity\`', 1, true) then
              return {{ entry_count = 0 }}
            end
            if sql:find('FROM \`synex_idempotency_namespace_capacity\`', 1, true) then
              return {{ owner_resource = 'synex_fixture', entry_count = 0 }}
            end
            if sql:find('FROM \`synex_idempotency_keys\`', 1, true) then return {} end
            return { affectedRows = 1 }
          end)
          return accepted == true and true or nil
        end
      }
      local reliability = SynexCoreFactories.reliability({
        platform = FakePlatform, foundation = foundation, database = database,
        sha256 = function() return string.rep('0', 64) end,
        instanceId = 'idempotency-response-fence', features = {}
      })
      local cyclic = {}
      cyclic.self = cyclic
      local value, failure = reliability.idempotency:run(
        'synex_fixture', 'fixture.response', '11111111-1111-4111-8111-111111111111', {},
        function() return cyclic end)
      assert(value == nil and failure.code == 'IDEMPOTENCY_INDETERMINATE')
      local compacted = assert(reliability.idempotency:compactExpired(25))
      assert(compacted.compacted == 2 and compactionMaximum == 25)
      assert(compactionSql:find("\`state\` = 'completed'", 1, true)
        and compactionSql:find('\`expires_at\` < CURRENT_TIMESTAMP(6)', 1, true)
        and compactionSql:find('idx_idempotency_response_compaction', 1, true)
        and compactionSql:find('\`response_compaction_at\` IS NULL', 1, true)
        and not compactionSql:find('\`response_json\` IS NOT NULL', 1, true))
      return table.concat({failure.code, compacted.compacted, compactionMaximum}, ':')
    `);
    assert.equal(result, 'IDEMPOTENCY_INDETERMINATE:2:25');
  } finally {
    engine.global.close();
  }
});

test('terminal outbox compaction is bounded and preserves dead-letter operator metadata', async () => {
  const engine = await createEngine(['foundation', 'reliability']);
  try {
    const result = await engine.doString(`
      local foundation = SynexCoreFactories.foundation({ platform = FakePlatform })
      foundation.configureIds('outbox-terminal-compaction')
      local terminalParameters, compactionSql, compactionParameters = nil, {}, {}
      local tick = string.char(96)
      local database = {
        update = function(_, sql, parameters)
          if sql:find('SET ' .. tick .. 'payload_json' .. tick .. ' =', 1, true) then
            compactionSql[#compactionSql + 1] = sql
            compactionParameters[#compactionParameters + 1] = parameters
            return 1, nil
          end
          if sql:find('SET ' .. tick .. 'state' .. tick .. ' = ?', 1, true) then
            terminalParameters = parameters
            return 1, nil
          end
          return 1, nil
        end,
        query = function()
          return {{
            id = 7, event_id = 'event-dead-letter', producer_resource = 'synex_fixture',
            aggregate_type = 'fixture', aggregate_id = 'aggregate-a',
            event_type = 'synex.fixture.changed', schema_version = 1,
            payload_json = '{}', headers_json = '{}', attempts = 10
          }}, nil
        end
      }
      local reliability = SynexCoreFactories.reliability({
        platform = FakePlatform, foundation = foundation, database = database,
        sha256 = function() return string.rep('0', 64) end,
        instanceId = 'outbox-terminal-compaction', features = { durableEvents = true }
      })
      local dispatched = assert(reliability.outbox:dispatchBatch(function()
        return nil, foundation.error('FIXTURE_DELIVERY_FAILED', 'safe fixture failure')
      end, 1))
      assert(dispatched.dead == 1 and terminalParameters[1] == 'dead'
        and terminalParameters[3] == 'FIXTURE_DELIVERY_FAILED')
      local compacted = assert(reliability.outbox:compactTerminal(25, {
        publishedPayloadAfterDays = 30, deadPayloadAfterDays = 365
      }))
      assert(compacted.compacted == 2 and #compactionSql == 2
        and compactionParameters[1][1] == 30 and compactionParameters[1][2] == 25
        and compactionParameters[2][1] == 365 and compactionParameters[2][2] == 24)
      local allCompactionSql = table.concat(compactionSql, '\\n')
      assert(allCompactionSql:find(tick .. 'state' .. tick .. " = 'published'", 1, true)
        and allCompactionSql:find(tick .. 'state' .. tick .. " = 'dead'", 1, true)
        and allCompactionSql:find(tick .. 'payload_compacted_at' .. tick .. ' IS NULL', 1, true)
        and allCompactionSql:find(tick .. 'payload_json' .. tick .. " = '{}'", 1, true)
        and allCompactionSql:find(tick .. 'headers_json' .. tick .. " = '{}'", 1, true)
        and not allCompactionSql:find(tick .. 'last_error_code' .. tick, 1, true)
        and not allCompactionSql:find(tick .. 'state' .. tick .. " = 'pending'", 1, true)
        and not allCompactionSql:find(tick .. 'state' .. tick .. " = 'publishing'", 1, true))
      local invalid, invalidError = reliability.outbox:compactTerminal(0, {
        publishedPayloadAfterDays = 30, deadPayloadAfterDays = 365
      })
      assert(invalid == nil and invalidError.code == 'INVALID_OUTBOX_RETENTION')
      return table.concat({dispatched.dead, terminalParameters[3], compacted.compacted,
        invalidError.code}, ':')
    `);
    assert.equal(result, '1:FIXTURE_DELIVERY_FAILED:2:INVALID_OUTBOX_RETENTION');
  } finally {
    engine.global.close();
  }
});

test('expired completed idempotency records remain terminal tombstones and never rerun handlers', async () => {
  const engine = await createEngine(['foundation', 'reliability']);
  try {
    const result = await engine.doString(`
      local foundation = SynexCoreFactories.foundation({ platform = FakePlatform })
      local effects = 0
      local database = {
        update = function(_, sql)
          error('expired completed tombstones must not be mutated during replay')
        end,
        withTransaction = function(_, handler)
          local accepted = handler(function(sql)
            if sql:find('FROM \`synex_idempotency_capacity\`', 1, true) then
              return {{ entry_count = 1, global_limit = 1, owner_limit = 1,
                namespace_limit = 1 }}
            end
            if sql:find('INSERT IGNORE INTO \`synex_idempotency_owner_capacity\`', 1, true)
              or sql:find('INSERT IGNORE INTO \`synex_idempotency_namespace_capacity\`', 1, true) then
              return { affectedRows = 0 }
            end
            if sql:find('FROM \`synex_idempotency_owner_capacity\`', 1, true) then
              return {{ entry_count = 1 }}
            end
            if sql:find('FROM \`synex_idempotency_namespace_capacity\`', 1, true) then
              return {{ owner_resource = 'synex_fixture', entry_count = 1 }}
            end
            if sql:find('FROM \`synex_idempotency_keys\`', 1, true) then
              return {{
                request_hash = string.rep('0', 64), state = 'completed', response_json = nil,
                lock_expired = 1, record_expired = 1
              }}
            end
            error('expired completed tombstones must not be mutated during replay')
          end)
          return accepted == true and true or nil
        end
      }
      local reliability = SynexCoreFactories.reliability({
        platform = FakePlatform, foundation = foundation, database = database,
        sha256 = function() return string.rep('0', 64) end,
        instanceId = 'idempotency-expired-tombstone', features = {}
      })
      local value, failure = reliability.idempotency:run(
        'synex_fixture', 'fixture.expired', '11111111-1111-4111-8111-111111111111', {},
        function() effects = effects + 1 return {} end)
      assert(value == nil and failure.code == 'IDEMPOTENCY_EXPIRED' and effects == 0)
      return failure.code .. ':' .. effects
    `);
    assert.equal(result, 'IDEMPOTENCY_EXPIRED:0');
  } finally {
    engine.global.close();
  }
});
