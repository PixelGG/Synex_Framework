import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory, type LuaEngine } from 'wasmoon';

const root = process.cwd();

async function preload(engine: LuaEngine, name: string, relativePath: string): Promise<void> {
  const source = await readFile(path.join(root, relativePath), 'utf8');
  await engine.doString(
    `package.preload[${JSON.stringify(name)}] = assert(load(${JSON.stringify(source)}, ${JSON.stringify(`@${relativePath}`)}))`,
  );
}

async function bootstrap(engine: LuaEngine): Promise<void> {
  await preload(engine, 'server.foundation', 'resources/synex_groups/server/foundation.lua');
  await preload(engine, 'server.validation', 'resources/synex_groups/server/validation.lua');
  await preload(engine, 'server.service', 'resources/synex_groups/server/service.lua');
  await preload(engine, 'server.contracts', 'resources/synex_groups/server/contracts.lua');
}

type JsonSchema = {
  type?: string;
  minLength?: number;
  minimum?: number;
  enum?: unknown[];
  properties?: Record<string, JsonSchema>;
  anyOf?: JsonSchema[];
};

function fixtureForSchema(schema: JsonSchema, field: string): unknown {
  if (Array.isArray(schema.anyOf)) {
    const concrete = schema.anyOf.find((candidate) => candidate.type !== 'null');
    if (concrete) return fixtureForSchema(concrete, field);
  }
  if (Array.isArray(schema.enum) && schema.enum.length > 0) return schema.enum[0];
  if (schema.type === 'boolean') return false;
  if (schema.type === 'integer') return schema.minimum ?? 1;
  if (schema.type === 'array') return [];
  if (schema.type === 'object') return {};
  if (schema.type === 'string') {
    if (field === 'create_permission') return 'synex.groups.create.fixture';
    if (field === 'approval_permission') return 'synex.groups.create.approve.fixture';
    if (field.endsWith('_at') || field === 'valid_from' || field === 'valid_until') {
      return '2026-08-25T12:00:00Z';
    }
    const length = Math.max(schema.minLength ?? 1, field.endsWith('_id') || field === 'cursor' ? 8 : 1);
    return `a${'b'.repeat(Math.max(0, length - 1))}`;
  }
  return true;
}

function luaLiteral(value: unknown): string {
  if (value === null || value === undefined) return 'nil';
  if (typeof value === 'boolean' || typeof value === 'number') return String(value);
  if (typeof value === 'string') return JSON.stringify(value);
  if (Array.isArray(value)) return `{${value.map(luaLiteral).join(',')}}`;
  const entries = Object.entries(value as Record<string, unknown>);
  return `{${entries.map(([key, child]) => `[${JSON.stringify(key)}]=${luaLiteral(child)}`).join(',')}}`;
}

function recursiveKeyCount(value: unknown): number {
  if (Array.isArray(value)) {
    return value.length + value.reduce((total, child) => total + recursiveKeyCount(child), 0);
  }
  if (value === null || typeof value !== 'object') return 0;
  return Object.entries(value).reduce(
    (total, [, child]) => total + 1 + recursiveKeyCount(child),
    0,
  );
}

test('the real Groups contract catalog remains inside the fail-closed loader budgets', async () => {
  const [rawCatalog, loader] = await Promise.all([
    readFile(path.join(root, 'resources/synex_groups/groups.contracts.json'), 'utf8'),
    readFile(path.join(root, 'resources/synex_groups/server/contracts.lua'), 'utf8'),
  ]);
  const catalog = JSON.parse(rawCatalog) as unknown;
  const byteBudget = 524_288;
  const keyBudget = 16_384;
  assert.ok(Buffer.byteLength(rawCatalog, 'utf8') <= byteBudget);
  assert.ok(recursiveKeyCount(catalog) <= keyBudget);
  assert.match(loader, /local MAXIMUM_CATALOG_BYTES = 524288/u);
  assert.match(loader, /local MAXIMUM_CATALOG_KEYS = 16384/u);
  assert.match(loader, /#rawCatalog > MAXIMUM_CATALOG_BYTES/u);
  assert.match(loader, /maximumKeys = MAXIMUM_CATALOG_KEYS/u);
});

test('Groups Foundation preserves inert Cfx JSON container identities and empty-array canonical form', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`
      local Foundation = require 'server.foundation'
      local objectMetatable = { __jsontype = 'object' }
      local arrayMetatable = { __jsontype = 'array' }
      local source = setmetatable({
        object = setmetatable({}, objectMetatable),
        array = setmetatable({}, arrayMetatable)
      }, objectMetatable)
      local copied = Foundation.copyPlain(source, { preserveContainerKind = true })
      assert(copied ~= source and getmetatable(copied) == objectMetatable)
      assert(getmetatable(copied.object) == objectMetatable)
      assert(getmetatable(copied.array) == arrayMetatable)
      assert(Foundation.jsonContainerKind(copied.object) == 'object')
      assert(Foundation.jsonContainerKind(copied.array) == 'array')
      local boundaryCopy = Foundation.copyPlain(source, { preserveContainerKind = false })
      assert(getmetatable(boundaryCopy) == nil and getmetatable(boundaryCopy.array) == nil)

      local canonical = Foundation.createCanonicalEncoder(function(value)
        if type(value) == 'string' then return string.format('%q', value) end
        return tostring(value)
      end)
      assert(canonical(copied.object) == '{}')
      assert(canonical(copied.array) == '[]')

      local loadDefinitions = require('server.contracts')(Foundation)
      local definitions = assert(loadDefinitions('{}', function()
        return setmetatable({
          schema = 1,
          domain = 'synex.groups',
          contracts = setmetatable({ setmetatable({
            name = 'synex.groups.fixture', version = '1.0.0', kind = 'rpc',
            provider = 'synex_groups', network = 'none',
            input = setmetatable({}, objectMetatable),
            output = setmetatable({}, objectMetatable),
            errors = setmetatable({}, arrayMetatable)
          }, objectMetatable) }, arrayMetatable)
        }, objectMetatable)
      end))
      assert(getmetatable(definitions[1]) == nil)
      assert(getmetatable(definitions[1].input) == nil)
      assert(getmetatable(definitions[1].errors) == nil)

      local executableMarker = setmetatable({}, {
        __jsontype = 'array',
        __index = function() return 'unexpected' end
      })
      assert(not pcall(Foundation.copyPlain, executableMarker))
      return true
    `);
    assert.equal(result, true);
  } finally {
    await engine.global.close();
  }
});

test('policy simulation output passes the real Core contract validator', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    for (const relativePath of [
      'core/synex_core/shared/protocol.lua',
      'core/synex_core/server/factories.lua',
      'core/synex_core/server/foundation.lua',
      'core/synex_core/server/contracts.lua',
      'core/synex_core/shared/generated_contracts.lua',
    ]) {
      await engine.doString(await readFile(path.join(root, relativePath), 'utf8'));
    }
    const result = await engine.doString(`
      local platform = {
        nowGame = function() return 1000 end,
        random = function(_, maximum) return math.min(maximum or 1, 123456) end,
        print = function() end,
        jsonEncode = function() return '{}' end,
        jsonDecode = function() return {} end,
        jsonContainerKind = function(value)
          if type(value) ~= 'table' then return nil end
          local metadata = getmetatable(value)
          if metadata and (metadata.__jsontype == 'array' or metadata.__jsontype == 'object') then
            return metadata.__jsontype
          end
          return 'plain'
        end,
        loadResourceFile = function() return nil end,
        setTimeout = function(_, callback) callback() end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      local contracts = SynexCoreFactories.contracts({
        foundation = foundation,
        protocol = SynexProtocol,
        generated = SynexGeneratedContracts
      })
      local contract = assert(contracts.registry:resolve(
        'synex.groups.policies.simulate', '1.0.0'))
      local output = {
        decision = 'DENY', reason = 'NO_MATCHING_ALLOW',
        character_id = 'character-fixture-0001', group_id = 'group-fixture-0001',
        capability = 'synex.groups.members.manage', scope = 'group',
        delegable = false, trace_id = 'trace-fixture-0001',
        evaluation = setmetatable({}, { __jsontype = 'array' })
      }
      local valid, validError = contracts.registry:validateOutput(contract, output)
      assert(valid, validError and validError.details
        and (tostring(validError.details.path) .. ':' .. tostring(validError.details.rule))
        or 'policy output rejected')
      output.delegable = nil
      local invalid, validationError = contracts.registry:validateOutput(contract, output)
      assert(invalid == nil and validationError.code == 'INVALID_PROVIDER_RESPONSE')
      return validationError.code
    `);
    assert.equal(result, 'INVALID_PROVIDER_RESPONSE');
  } finally {
    engine.global.close();
  }
});

test('Groups service validation is closed and applies contract field semantics before dispatch', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`
      local Foundation = require 'server.foundation'
      local Validation = require('server.validation')(Foundation)
      local request = {
        idempotency_key = 'idem-1234',
        actor_character_id = 'char-1234',
        membership_id = 'member-1234',
        expected_version = 1,
        status = 'SUSPENDED',
        reason = 'reviewed'
      }
      assert(Validation.operation('members_transition', request))

      request.undeclared = true
      local _, unknownError = Validation.operation('members_transition', request)
      assert(unknownError.code == 'VALIDATION_FAILED')
      request.undeclared = nil

      request.expected_version = '1'
      local _, versionError = Validation.operation('members_transition', request)
      assert(versionError.code == 'VALIDATION_FAILED')
      request.expected_version = 1

      local objectMetatable = { __jsontype = 'object' }
      local arrayMetatable = { __jsontype = 'array' }
      local invite = {
        idempotency_key = 'invite-1234',
        actor_character_id = 'char-1234',
        group_id = 'group-1234',
        character_id = 'char-5678',
        role_ids = setmetatable({}, arrayMetatable)
      }
      assert(Validation.operation('members_invite', invite))
      invite.role_ids = setmetatable({}, objectMetatable)
      local _, arrayError = Validation.operation('members_invite', invite)
      assert(arrayError.code == 'VALIDATION_FAILED')

      local _, capabilityError = Validation.capability('synex.groups.', true)
      assert(capabilityError.code == 'VALIDATION_FAILED')
      local _, metadataError = Validation.metadata(setmetatable({}, arrayMetatable), false)
      assert(metadataError.code == 'VALIDATION_FAILED')
      return true
    `);
    assert.equal(result, true);
  } finally {
    await engine.global.close();
  }
});

test('public contracts preserve deterministic Groups domain errors instead of database fallbacks', async () => {
  const catalog = JSON.parse(await readFile(
    path.join(root, 'resources/synex_groups/groups.contracts.json'),
    'utf8',
  )) as { contracts: Array<{ name: string; errors: string[] }> };
  const deterministic = [
    'GROUP_TYPE_NOT_FOUND', 'GROUP_TYPE_INACTIVE', 'GROUP_TYPE_STATIC',
    'STATIC_DEFINITION_REQUIRED', 'GROUP_EXISTS', 'GROUP_HAS_ACTIVE_MEMBERS',
    'PARENT_GROUP_NOT_FOUND', 'HIERARCHY_DISABLED', 'HIERARCHY_DEPTH_EXCEEDED',
    'RELATIONSHIP_TYPE_NOT_FOUND', 'RELATIONSHIP_EXISTS', 'RELATIONSHIP_CYCLE',
    'GRADE_EXISTS', 'GRADE_IN_USE', 'ROLE_EXISTS', 'ROLE_IN_USE',
    'CAPABILITY_SOURCE_INACTIVE', 'READ_MODEL_TOO_LARGE',
  ];
  for (const contract of catalog.contracts) {
    for (const code of deterministic) {
      assert.ok(contract.errors.includes(code), `${contract.name} omits ${code}`);
    }
  }
  const service = await readFile(
    path.join(root, 'resources/synex_groups/server/service.lua'),
    'utf8',
  );
  for (const code of deterministic) {
    assert.match(service, new RegExp(`\\b${code}\\s*=\\s*true\\b`, 'u'));
  }
});

test('Groups operation validation stays synchronized with every declared contract input field', async () => {
  const catalog = JSON.parse(await readFile(
    path.join(root, 'resources/synex_groups/groups.contracts.json'),
    'utf8',
  )) as { contracts: Array<{
    name: string;
    input: { required?: string[]; properties?: Record<string, JsonSchema> };
  }> };
  assert.equal(catalog.contracts.length, 71);
  const assertions = catalog.contracts.map((contract) => {
    const operation = contract.name.slice('synex.groups.'.length).replaceAll('.', '_');
    const properties = contract.input.properties ?? {};
    const request = Object.fromEntries(Object.entries(properties).map(
      ([field, schema]) => [field, fixtureForSchema(schema, field)],
    ));
    const requiredRequest = Object.fromEntries((contract.input.required ?? []).map(
      (field) => [field, fixtureForSchema(properties[field] ?? {}, field)],
    ));
    const internalIdentity = contract.name === 'synex.groups.self.snapshot'
      ? { actor_character_id: 'character_self_0001' }
      : {};
    const validatedRequest = { ...request, ...internalIdentity };
    const validatedRequiredRequest = { ...requiredRequest, ...internalIdentity };
    const requiredChecks = (contract.input.required ?? []).map((field) => `do
        local previous = requiredRequest[${JSON.stringify(field)}]
        requiredRequest[${JSON.stringify(field)}] = nil
        local missing, missingFailure = Validation.operation(${JSON.stringify(operation)}, requiredRequest)
        assert(not missing and missingFailure.code == 'VALIDATION_FAILED')
        requiredRequest[${JSON.stringify(field)}] = previous
      end`).join('\n');
    return `do
      local valid, failure = Validation.operation(${JSON.stringify(operation)}, ${luaLiteral(validatedRequest)})
      assert(valid, ${JSON.stringify(contract.name)} .. ': ' .. tostring(failure and failure.message))
      local requiredRequest = ${luaLiteral(validatedRequiredRequest)}
      local minimal, minimalFailure = Validation.operation(${JSON.stringify(operation)}, requiredRequest)
      assert(minimal, ${JSON.stringify(contract.name)} .. ': ' .. tostring(minimalFailure and minimalFailure.message))
      ${requiredChecks}
    end`;
  });
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`
      local Foundation = require 'server.foundation'
      local Validation = require('server.validation')(Foundation)
      ${assertions.join('\n')}
      return true
    `);
    assert.equal(result, true);
  } finally {
    await engine.global.close();
  }
});

test('Groups service revalidates hook patches, normalizes errors, invalidates memberships, and acknowledges audit delivery', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`
      local Foundation = require 'server.foundation'
      local createService = require('server.service')(Foundation)
      local observed = {
        invalidations = {},
        errors = {},
        hookCalls = 0,
        characterCalls = 0,
        auditCalls = 0,
        acknowledgements = 0,
        runtimeEffects = 0
      }
      local hookMode = 'patch'
      local repository = {}
      function repository:preflight()
        return true
      end
      function repository:execute(operation, request, context)
        observed.operation = operation
        observed.request = request
        observed.context = context
        if operation == 'definitions_sync' then
          observed.definitionsKind = Foundation.jsonContainerKind(request.definitions)
          return {
            entity_id = 'sync-1234', entity_type = 'definition',
            status = 'synchronized', version = 1, replayed = false
          }, nil, {}
        end
        if operation == 'members_transition' then
          return {
            entity_id = request.membership_id,
            entity_type = 'membership',
            status = request.status,
            version = 2,
            replayed = false
          }, nil, {{
            groupId = 'group-1234',
            membershipId = request.membership_id,
            auditDeliveryId = 42,
            audit = {
              action = 'membership.transitioned',
              targetType = 'membership',
              targetId = request.membership_id,
              actorCharacterId = request.actor_character_id,
              reason = request.reason
            }
          }}
        end
        return nil, { code = 'CORE_UNAVAILABLE', message = 'must not cross the contract boundary' }
      end
      function repository:read()
        return nil, { code = 'CORE_UNAVAILABLE', message = 'must not cross the contract boundary' }
      end
      function repository:markAuditDelivered(deliveryId, eventId, context)
        observed.acknowledgements = observed.acknowledgements + 1
        observed.deliveryId = deliveryId
        observed.eventId = eventId
        observed.deliveryContext = context
        return true
      end

      local characters = {}
      function characters.get(characterId)
        observed.characterCalls = observed.characterCalls + 1
        return { id = characterId }
      end
      local hooks = {}
      function hooks.run(_, request)
        observed.hookCalls = observed.hookCalls + 1
        if hookMode == 'error' then
          return false, { code = 'REQUIRED_HOOK_FAILED', message = 'private hook failure' }
        end
        if hookMode == 'invalid_patch' then
          return { actor_character_id = request.actor_character_id }
        end
        local patched = Foundation.copyPlain(request)
        patched.reason = 'patched-by-policy'
        return patched
      end
      local audit = {}
      function audit.append(entry)
        observed.auditCalls = observed.auditCalls + 1
        observed.auditEntry = entry
        return { eventId = 'audit-event-1234' }
      end
      local cache = {}
      function cache:get() return nil end
      function cache:put() return true end
      function cache:invalidatePrefix(prefix)
        observed.invalidations[#observed.invalidations + 1] = prefix
        return 1
      end

      local methods = createService({
        repository = repository,
        characters = characters,
        hooks = hooks,
        audit = audit,
        runtimeEffects = { apply = function()
          observed.runtimeEffects = observed.runtimeEffects + 1
          return true
        end },
        jsonEncode = function() return '{}' end,
        cache = cache,
        errorSink = function(event) observed.errors[#observed.errors + 1] = event end
      })
      local context = {
        traceId = 'trace-1234', caller = 'synex_fixture', callerEpoch = 7,
        deadlineAt = 999999, idempotencyKey = 'idem-1234'
      }
      local request = {
        idempotency_key = 'idem-1234', actor_character_id = 'char-1234',
        membership_id = 'member-1234', expected_version = 1,
        status = 'SUSPENDED', reason = 'requested'
      }

      local value, operationError = methods.members_transition(request, context)
      assert(operationError == nil and value.status == 'SUSPENDED')
      assert(observed.request.reason == 'patched-by-policy')
      assert(observed.context.idempotencyKey == request.idempotency_key)
      assert(observed.auditCalls == 1 and observed.acknowledgements == 1)
      assert(observed.runtimeEffects == 1)
      assert(observed.deliveryId == 42 and observed.eventId == 'audit-event-1234')
      assert(observed.auditEntry.context.caller == 'synex_fixture')
      local invalidatedMembership = false
      for _, prefix in ipairs(observed.invalidations) do
        if prefix == 'membership:member-1234' then invalidatedMembership = true end
      end
      assert(invalidatedMembership)

      local arrayMetatable = { __jsontype = 'array' }
      local synchronized, synchronizationError = methods.definitions_sync({
        idempotency_key = 'sync-1234', schema_version = 1,
        definitions = setmetatable({}, arrayMetatable), dry_run = false
      }, {
        traceId = 'trace-5678', caller = 'synex_fixture', callerEpoch = 7,
        deadlineAt = 999999
      })
      assert(synchronizationError == nil and synchronized.status == 'synchronized')
      assert(observed.definitionsKind == 'array')

      local hookCalls = observed.hookCalls
      request.undeclared = true
      local _, validationError = methods.members_transition(request, context)
      assert(validationError.code == 'VALIDATION_FAILED' and observed.hookCalls == hookCalls)
      request.undeclared = nil

      hookMode = 'invalid_patch'
      local _, patchError = methods.members_transition(request, context)
      assert(patchError.code == 'HOOK_REJECTED')

      hookMode = 'error'
      local _, hookError = methods.members_transition(request, context)
      assert(hookError.code == 'HOOK_REJECTED')

      local _, repositoryError = methods.get({ group_id = 'group-1234' }, context)
      assert(repositoryError.code == 'DATABASE_ERROR')
      assert(repositoryError.message == 'The Groups operation could not be completed.')
      return true
    `);
    assert.equal(result, true);
  } finally {
    await engine.global.close();
  }
});

test('Groups service routes lifecycle and governance hooks exactly and keeps security routing immutable', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`
      local Foundation = require 'server.foundation'
      local createService = require('server.service')(Foundation)
      local observed = { hooks = {}, operations = 0 }
      local hookMode = 'pass'
      local hooks = {}
      function hooks.run(name, request, hookContext)
        observed.hooks[#observed.hooks + 1] = {
          name = name, operation = hookContext.metadata.operation
        }
        if hookMode == 'mutate_transition_route' then
          request.status = 'SUSPENDED'
          return request
        end
        if hookMode == 'mutate_membership_target' then
          request.membership_id = 'membership_forged_0001'
          return request
        end
        if hookMode == 'mutate_transition_policy' then
          request.required_capability = 'synex.groups.members.forged'
          return request
        end
        local copy = Foundation.copyPlain(request, { preserveContainerKind = true })
        if hookMode == 'patch_reason' then copy.reason = 'policy_reason' end
        if hookMode == 'mutate_proposal' and name == 'synex.groups.before_proposal_execute' then
          copy.action = 'group.archive'
        end
        if hookMode == 'mutate_approved_target'
            and name ~= 'synex.groups.before_proposal_execute' then
          copy.reason = 'forged_after_approval'
        end
        return copy
      end

      local repository = {}
      function repository:preflight()
        return true
      end
      function repository:execute(operation, request, context)
        observed.operations = observed.operations + 1
        observed.lastOperation = operation
        observed.lastRequest = request
        if operation == 'proposals_approve' then
          local envelope = {
            proposal_id = 'proposal_alpha_0001',
            group_id = 'group_alpha_0001',
            action = 'membership.transition',
            actor_character_id = request.actor_character_id,
            payload = {
              idempotency_key = 'proposal:proposal_alpha_0001',
              actor_character_id = request.actor_character_id,
              membership_id = 'membership_target_0001',
              expected_version = 7,
              status = 'BANNED',
              reason = 'approved_termination'
            },
            reason = request.reason
          }
          local hooked, hookError = context.beforeProposalExecute(envelope)
          if not hooked then return nil, hookError end
          observed.approvedEnvelope = hooked
        end
        return {
          entity_id = request.membership_id or request.application_id
            or request.delegation_id or request.proposal_id or 'fixture_entity_0001',
          entity_type = 'fixture', status = request.status or request.decision or 'ok',
          version = 2, replayed = false
        }, nil, {}
      end
      function repository:read() return nil, { code = 'DATABASE_ERROR' } end

      local methods = createService({
        repository = repository,
        characters = { get = function(characterId) return { id = characterId } end },
        hooks = hooks,
        audit = { append = function() return { eventId = 'audit_event_0001' } end },
        runtimeEffects = { apply = function() return true end },
        jsonEncode = function() return '{}' end,
        cache = {
          get = function() return nil end,
          put = function() return true end,
          invalidatePrefix = function() return 0 end
        },
        errorSink = function() end
      })
      local context = {
        traceId = 'trace_hooks_0001', caller = 'synex_fixture', callerEpoch = 3,
        deadlineAt = 999999
      }
      local function expect(operation, request, hookName)
        local before = #observed.hooks
        local value, failure = methods[operation](request, context)
        assert(value and failure == nil, operation .. ':' .. tostring(failure and failure.code))
        assert(#observed.hooks == before + 1, operation .. ':hook_count')
        assert(observed.hooks[#observed.hooks].name == 'synex.groups.' .. hookName,
          operation .. ':' .. observed.hooks[#observed.hooks].name)
        assert(observed.hooks[#observed.hooks].operation == operation)
      end
      local function base(suffix)
        return {
          idempotency_key = 'idem_' .. suffix .. '_0001',
          actor_character_id = 'character_actor_0001'
        }
      end

      local request = base('activate')
      request.membership_id = 'membership_target_0001'
      request.expected_version = 1
      request.status = 'ACTIVE'
      request.reason = 'activate'
      expect('members_transition', request, 'before_membership_activate')

      request = base('suspend')
      request.membership_id = 'membership_target_0001'
      request.expected_version = 2
      request.status = 'SUSPENDED'
      request.reason = 'suspend'
      expect('members_transition', request, 'before_membership_suspend')

      request = base('probation')
      request.membership_id = 'membership_target_0001'
      request.expected_version = 2
      request.status = 'PROBATION'
      request.reason = 'probation'
      expect('members_transition', request, 'before_membership_transition')

      for _, terminal in ipairs({ 'TERMINATED', 'BANNED', 'LEFT', 'ARCHIVED' }) do
        request = base('terminal_' .. terminal:lower())
        request.membership_id = 'membership_target_0001'
        request.expected_version = 3
        request.status = terminal
        request.reason = 'terminal'
        expect('members_transition', request, 'before_membership_terminate')
      end

      request = base('invite')
      request.group_id = 'group_alpha_0001'
      request.character_id = 'character_target_0001'
      expect('members_invite', request, 'before_membership_invite')

      request = base('grade')
      request.membership_id = 'membership_target_0001'
      request.grade_id = 'grade_target_0001'
      request.expected_version = 4
      request.reason = 'promotion'
      expect('members_set_grade', request, 'before_grade_change')

      request = base('transition_policy')
      request.group_id = 'group_alpha_0001'
      request.from_status = 'ACTIVE'
      request.to_status = 'SUSPENDED'
      request.allowed = true
      request.required_capability = 'synex.groups.members.suspend'
      request.approval_required = false
      request.reason_required = true
      request.reason = 'policy_change'
      expect('members_transition_policy_set', request, 'before_policy_change')

      request = base('role_assign')
      request.membership_id = 'membership_target_0001'
      request.role_id = 'role_target_0001'
      expect('roles_assign', request, 'before_role_assignment')

      request = base('role_remove')
      request.membership_role_id = 'membership_role_0001'
      request.expected_version = 1
      request.reason = 'removed'
      expect('roles_remove', request, 'before_role_removal')

      request = base('duty_start')
      request.membership_id = 'membership_target_0001'
      request.state = 'on_duty'
      expect('duty_start', request, 'before_duty_start')

      request = base('duty_stop')
      request.duty_session_id = 'duty_session_0001'
      request.expected_version = 1
      request.reason = 'shift_ended'
      expect('duty_stop', request, 'before_duty_end')

      request = base('relation_create')
      request.source_group_id = 'group_alpha_0001'
      request.target_group_id = 'group_bravo_0001'
      request.relation_type = 'alliance'
      expect('relationships_create', request, 'before_relationship_change')

      request = base('relation_update')
      request.relationship_id = 'relationship_0001'
      request.expected_version = 1
      request.status = 'ended'
      request.reason = 'ended'
      expect('relationships_update', request, 'before_relationship_change')

      request = base('delegation_create')
      request.group_id = 'group_alpha_0001'
      request.grantee_membership_id = 'membership_target_0001'
      request.capability = 'synex.groups.duty.start'
      request.valid_until = '2026-12-31T23:59:59Z'
      request.reason = 'temporary_duty'
      expect('delegations_create', request, 'before_delegation')

      request = base('delegation_revoke')
      request.delegation_id = 'delegation_target_0001'
      request.expected_version = 1
      request.reason = 'revoked'
      expect('delegations_revoke', request, 'before_delegation')

      request = base('application_approved')
      request.application_id = 'application_target_0001'
      request.expected_version = 1
      request.decision = 'APPROVED'
      request.reason = 'accepted'
      expect('applications_review', request, 'before_membership_activate')

      local beforeRejected = #observed.hooks
      request = base('application_rejected')
      request.application_id = 'application_target_0001'
      request.expected_version = 2
      request.decision = 'REJECTED'
      request.reason = 'declined'
      assert(methods.applications_review(request, context))
      assert(#observed.hooks == beforeRejected)

      hookMode = 'patch_reason'
      request = base('reason_patch')
      request.membership_id = 'membership_target_0001'
      request.expected_version = 5
      request.status = 'SUSPENDED'
      request.reason = 'original_reason'
      assert(methods.members_transition(request, context))
      assert(observed.lastRequest.reason == 'policy_reason')

      hookMode = 'mutate_transition_route'
      request = base('route_attack')
      request.membership_id = 'membership_target_0001'
      request.expected_version = 6
      request.status = 'ACTIVE'
      request.reason = 'activate'
      local operationsBefore = observed.operations
      local _, routingError = methods.members_transition(request, context)
      assert(routingError.code == 'HOOK_REJECTED')
      assert(observed.operations == operationsBefore)

      hookMode = 'mutate_membership_target'
      request = base('target_attack')
      request.membership_id = 'membership_target_0001'
      request.expected_version = 6
      request.status = 'SUSPENDED'
      request.reason = 'suspend'
      operationsBefore = observed.operations
      local _, targetRoutingError = methods.members_transition(request, context)
      assert(targetRoutingError.code == 'HOOK_REJECTED')
      assert(observed.operations == operationsBefore)

      hookMode = 'mutate_transition_policy'
      request = base('policy_attack')
      request.group_id = 'group_alpha_0001'
      request.from_status = 'ACTIVE'
      request.to_status = 'SUSPENDED'
      request.allowed = true
      request.required_capability = 'synex.groups.members.suspend'
      request.approval_required = false
      request.reason_required = true
      operationsBefore = observed.operations
      local _, policyRoutingError = methods.members_transition_policy_set(request, context)
      assert(policyRoutingError.code == 'HOOK_REJECTED')
      assert(observed.operations == operationsBefore)

      hookMode = 'pass'
      local proposalRequest = base('proposal_approve')
      proposalRequest.proposal_id = 'proposal_alpha_0001'
      proposalRequest.expected_version = 1
      proposalRequest.reason = 'quorum_reached'
      local hooksBefore = #observed.hooks
      assert(methods.proposals_approve(proposalRequest, context))
      assert(#observed.hooks == hooksBefore + 2)
      assert(observed.hooks[hooksBefore + 1].name
        == 'synex.groups.before_proposal_execute')
      assert(observed.hooks[hooksBefore + 1].operation == 'proposal_execute')
      assert(observed.hooks[hooksBefore + 2].name
        == 'synex.groups.before_membership_terminate')
      assert(observed.hooks[hooksBefore + 2].operation == 'members_transition')
      assert(observed.approvedEnvelope.payload.status == 'BANNED')

      hookMode = 'mutate_proposal'
      hooksBefore = #observed.hooks
      local _, proposalMutationError = methods.proposals_approve(proposalRequest, context)
      assert(proposalMutationError.code == 'HOOK_REJECTED')
      assert(#observed.hooks == hooksBefore + 1,
        'a forged action must be rejected before target-hook routing')

      hookMode = 'mutate_approved_target'
      hooksBefore = #observed.hooks
      local _, targetMutationError = methods.proposals_approve(proposalRequest, context)
      assert(targetMutationError.code == 'HOOK_REJECTED')
      assert(#observed.hooks == hooksBefore + 2)
      return #observed.hooks
    `);
    assert.equal(typeof result, 'number');
  } finally {
    await engine.global.close();
  }
});
