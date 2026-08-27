import assert from 'node:assert/strict';
import { readFile, readdir } from 'node:fs/promises';
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
  await preload(engine, 'server.database_adapter', 'resources/synex_groups/server/database_adapter.lua');
  await preload(engine, 'server.persistence.effects', 'resources/synex_groups/server/persistence/effects.lua');
  await preload(engine, 'server.persistence.approved_operations',
    'resources/synex_groups/server/persistence/approved_operations.lua');
  await preload(engine, 'server.persistence', 'resources/synex_groups/server/persistence.lua');
}

async function luaFiles(directory: string): Promise<string[]> {
  const entries = await readdir(directory, { withFileTypes: true });
  const nested = await Promise.all(entries.map(async (entry) => {
    const target = path.join(directory, entry.name);
    if (entry.isDirectory()) return luaFiles(target);
    return entry.isFile() && entry.name.endsWith('.lua') ? [target] : [];
  }));
  return nested.flat();
}

test('synex_groups runtime has no direct database-driver dependency or legacy receipt access', async () => {
  const serverDirectory = path.join(root, 'resources/synex_groups/server');
  for (const file of await luaFiles(serverDirectory)) {
    const source = await readFile(file, 'utf8');
    assert.doesNotMatch(source, /\bMySQL\b|oxmysql/iu, path.relative(root, file));
    assert.doesNotMatch(source, /synex_group_command_receipts/iu, path.relative(root, file));
  }
  const manifest = await readFile(path.join(root, 'resources/synex_groups/fxmanifest.lua'), 'utf8');
  assert.doesNotMatch(manifest, /oxmysql|@oxmysql/iu);
  const resourceManifest = JSON.parse(await readFile(
    path.join(root, 'resources/synex_groups/synex.resource.json'), 'utf8',
  )) as { dependencies: { required: Array<{ name: string }> }; capabilities: { request: string[] } };
  assert.deepEqual(resourceManifest.dependencies.required.map((entry) => entry.name), ['synex_core']);
  for (const capability of [
    'synex.database.read', 'synex.database.write',
    'synex.database.transaction', 'synex.database.maintenance',
  ]) assert.ok(resourceManifest.capabilities.request.includes(capability), capability);
});

test('definitions.sync enforces a combined reconciliation budget below the Core transaction limit', async () => {
  const catalog = JSON.parse(await readFile(
    path.join(root, 'resources/synex_groups/groups.contracts.json'), 'utf8',
  )) as { contracts: Array<{ name: string; input: { properties: { definitions: { maxItems: number } } } }> };
  const contract = catalog.contracts.find((item) => item.name === 'synex.groups.definitions.sync');
  assert.equal(contract?.input.properties.definitions.maxItems, 16);

  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`
      local Foundation = require 'server.foundation'
      local Validation = require('server.validation')(Foundation)
      local function request(definitions)
        return {
          idempotency_key = 'definition-budget-0001', schema_version = 1,
          definitions = definitions, dry_run = false
        }
      end
      local accepted, acceptedError = Validation.operation('definitions_sync',
        request({ {}, {}, {}, {} }))
      assert(accepted == true and acceptedError == nil)
      local rejected, rejectedError = Validation.operation('definitions_sync',
        request({ {}, {}, {}, {}, {} }))
      assert(rejected == nil and rejectedError.code == 'VALIDATION_FAILED')
      assert(rejectedError.details.maximum_work == 1024)
      assert(rejectedError.details.requested_work > rejectedError.details.maximum_work)
      return rejectedError.details.requested_work
    `);
    assert.equal(result, 1280);
  } finally {
    engine.global.close();
  }
});

test('Groups database adapter preserves sparse and trailing SQL NULL positions', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`
      local Foundation = require 'server.foundation'
      local observed
      local nullCalls = 0
      local database = {
        null = function()
          nullCalls = nullCalls + 1
          return { __synex_database_null = true }
        end,
        read = function(request) observed = request return {}, nil end,
        write = function() return { affectedRows = 1 }, nil end,
        transaction = function() return {}, nil, { replayed = false } end,
        maintenance = function() return true, nil end
      }
      local adapter = require('server.database_adapter')(Foundation)(database)
      assert(adapter:read([[SELECT '?' AS literal, "?" AS quoted
        FROM synex_groups WHERE public_id = ?
          AND description = ? /* ? */ AND metadata_json = ? -- ?
      ]], { [1] = 'group_fixture' }))
      assert(#observed.parameters == 3)
      assert(observed.parameters[1] == 'group_fixture')
      assert(observed.parameters[2].__synex_database_null == true)
      assert(observed.parameters[3].__synex_database_null == true)
      assert(nullCalls == 2)
      local rejected, rejectedError = adapter:read(
        'SELECT * FROM synex_groups WHERE public_id = ?',
        { [1] = 'group_fixture', [2] = 'smuggled' })
      assert(rejected == nil and rejectedError.code == 'INVALID_DATABASE_PARAMETERS')
      return observed.maximumRows
    `);
    assert.equal(result, 8192);
  } finally {
    engine.global.close();
  }
});

test('Groups transaction adapter propagates Core errors instead of returning false absence', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`
      local Foundation = require 'server.foundation'
      local coreError = Foundation.domainError('DATABASE_DEADLINE_EXCEEDED',
        'deadline exceeded', true)
      local database = {
        null = function() return { __synex_database_null = true } end,
        read = function() return {}, nil end,
        write = function() return { affectedRows = 1 }, nil end,
        transaction = function(_, handler)
          local transaction = {
            query = function() return nil, coreError end,
            many = function() return nil, coreError end,
            one = function() return nil, coreError end,
            affected = function() return nil, coreError end,
            insert = function() return nil, coreError end
          }
          local invoked, value, handlerError = pcall(handler, transaction)
          if not invoked then return nil, value end
          return value, handlerError
        end,
        maintenance = function() return true, nil end
      }
      local adapter = require('server.database_adapter')(Foundation)(database)
      local ok, raised = pcall(function()
        return adapter:transaction({
          operation = 'groups.fixture', idempotencyKey = 'fixture-key-0001', request = {}
        }, function(tx)
          local missing = tx.one(
            'SELECT id FROM synex_groups WHERE public_id = ?',
            { 'group_fixture' })
          if not missing then return 'incorrect-not-found', nil end
          return 'unreachable', nil
        end)
      end)
      assert(ok == true)
      assert(raised == nil)
      -- The Core boundary catches the structured exception and returns it; it
      -- must never allow the domain handler to classify this as NOT_FOUND.
      local _, propagated = adapter:transaction({
        operation = 'groups.fixture', idempotencyKey = 'fixture-key-0002', request = {}
      }, function(tx)
        tx.one('SELECT id FROM synex_groups WHERE public_id = ?',
          { 'group_fixture' })
      end)
      assert(propagated.code == 'DATABASE_DEADLINE_EXCEEDED')
      return propagated.code
    `);
    assert.equal(result, 'DATABASE_DEADLINE_EXCEEDED');
  } finally {
    engine.global.close();
  }
});

test('Groups persistence stores a complete Core receipt envelope and suppresses replay side effects', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`
      local Foundation = require 'server.foundation'
      local createAdapter = require('server.database_adapter')(Foundation)
      local createPersistence = require('server.persistence')(Foundation, {
        effects = require 'server.persistence.effects',
        approved_operations = require 'server.persistence.approved_operations',
        capability_access = function()
          return function()
            local definitionCache = { snapshot = function() return {} end }
            return { authorize = function() return true end,
              evaluateCharacter = function() return true end,
              definitionCache = definitionCache,
              invalidateDefinitions = function() return 0 end,
              clearDefinitions = function() return 0 end,
              definitionCacheSnapshot = function() return {} end }
          end
        end,
        organizations_creation = function()
          return { execute = { create = function(_, _, _, context)
            context.registryMutations[1] = {
              registry = 'groupTypes', owner = 'synex_fixture', epoch = 7,
              generation = 3, key = 'group_type:fixture', value = { key = 'fixture' }
            }
            return {
              entity_id = 'group_fixture_0001', entity_type = 'group',
              status = 'active', version = 1, replayed = false
            }, nil, {{
              action = 'created', eventType = 'synex.groups.created',
              entityType = 'group', entityId = 'group_fixture_0001',
              groupId = 'group_fixture_0001', reason = 'created', version = 1
            }}
          end } }
        end
      })
      local storedEnvelope
      local handlerCalls, registryCalls, refreshCalls = 0, 0, 0
      local coreDatabase = {
        null = function() return { __synex_database_null = true } end,
        read = function() return {}, nil end,
        write = function() return { affectedRows = 1 }, nil end,
        maintenance = function(_, handler) return handler({}) end,
        transaction = function(_, handler)
          if storedEnvelope then
            return Foundation.copyPlain(storedEnvelope), nil, { replayed = true }
          end
          handlerCalls = handlerCalls + 1
          local tx = {
            query = function() return { affectedRows = 1 }, nil end,
            many = function() return {}, nil end,
            one = function() return nil, nil end,
            affected = function() return 1, nil end,
            insert = function() return 41, nil end
          }
          local value, handlerError = handler(tx)
          assert(value and handlerError == nil)
          storedEnvelope = Foundation.copyPlain(value)
          return Foundation.copyPlain(value), nil, { replayed = false }
        end
      }
      local evaluator = { evaluate = function() return true end }
      local registry = {
        get = function() return nil, { code = 'REGISTRY_KEY_NOT_FOUND' } end,
        replace = function() return true end, stats = function()
          return { entries = 0, maximumEntries = 10, maximumPerOwner = 10 }
        end,
        listOwner = function() return {} end
      }
      local port = createPersistence({
        dataPort = createAdapter(coreDatabase),
        jsonEncode = function(value)
          if type(value) == 'string' then return string.format('%q', value) end
          if type(value) == 'boolean' or type(value) == 'number' then return tostring(value) end
          return '{}'
        end,
        jsonDecode = function() return {} end,
        nextId = function(namespace) return namespace .. '_fixture_0001' end,
        capabilityEvaluator = evaluator,
        policyEngine = { decide = function() return true end },
        cache = {}, registries = { groupTypes = registry },
        applicationSchemas = { validateSchema = function() return true end,
          validateData = function() return true end },
        validateOperation = function() return true end,
        runtimeIndex = { snapshot = function()
          return { characters = 0, memberships = 0, dutySessions = 0 }
        end },
        checkCorePermission = function() return true end,
        applyRegistryMutation = function() registryCalls = registryCalls + 1 return true end,
        refreshRegistry = function(_, _, _, _, mutations)
          assert(type(mutations) == 'table' and #mutations == 1
            and mutations[1].generation == 3)
          refreshCalls = refreshCalls + 1
          return true
        end
      })
      local request = { idempotency_key = 'fixture-key-0001' }
      local context = { caller = 'synex_fixture', callerEpoch = 7, traceId = 'trace_fixture' }
      local first, firstError, effects = port:execute('create', request, context)
      assert(first and firstError == nil and first.replayed == false)
      assert(#effects == 1 and handlerCalls == 1 and registryCalls == 0 and refreshCalls == 1)
      assert(type(storedEnvelope.response) == 'table')
      assert(type(storedEnvelope.effects) == 'table' and #storedEnvelope.effects == 1)
      assert(type(storedEnvelope.registryMutations) == 'table'
        and #storedEnvelope.registryMutations == 1)
      local replay, replayError, replayEffects = port:execute('create', request, context)
      assert(replay and replayError == nil and replay.replayed == true)
      assert(#replayEffects == 0 and handlerCalls == 1 and registryCalls == 0)
      assert(refreshCalls == 2)
      return 'replay-safe'
    `);
    assert.equal(result, 'replay-safe');
  } finally {
    engine.global.close();
  }
});

test('approved operations require a durable quorum-bound private execution grant', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`
      local Foundation = require 'server.foundation'
      local createAdapter = require('server.database_adapter')(Foundation)
      local targetCalls = 0
      local createPersistence = require('server.persistence')(Foundation, {
        effects = require 'server.persistence.effects',
        approved_operations = require 'server.persistence.approved_operations',
        capability_access = function()
          return function()
            local definitionCache = { snapshot = function() return {} end }
            return { authorize = function() return true end,
              evaluateCharacter = function() return true end,
              definitionCache = definitionCache,
              invalidateDefinitions = function() return 0 end,
              clearDefinitions = function() return 0 end,
              definitionCacheSnapshot = function() return {} end }
          end
        end,
        memberships_lifecycle = function()
          return { execute = { members_transition = function(_, request, runtime, context)
            local approved, approvalError = runtime.verifyApprovedOperation(
              context, 'members_transition', request, 'group_fixture_0001')
            if not approved then return nil, approvalError end
            targetCalls = targetCalls + 1
            local response = runtime.success(
              request.membership_id, 'membership', request.status, 2)
            return response, nil, { runtime.effect(
              'membership.suspended', 'membership', request.membership_id,
              'group_fixture_0001', 'character_target_0001', nil,
              response, request.reason, 2) }
          end } }
        end,
        workflows_proposals = function()
          return { execute = { proposals_approve = function(tx, _, runtime, context)
            return runtime.invokeApproved(tx, 'membership.transition', {
              membership_id = 'membership_target_0001',
              expected_version = 1, status = 'SUSPENDED'
            }, 'character_actor_0001', 'proposal_fixture_0001',
              'group_fixture_0001', 7, 'approved_transition', context)
          end } }
        end
      })
      local insertSequence = 100
      local coreDatabase = {
        null = function() return { __synex_database_null = true } end,
        read = function() return {}, nil end,
        write = function() return { affectedRows = 1 }, nil end,
        maintenance = function(_, handler) return handler({}) end,
        transaction = function(_, handler)
          local tx = {}
          function tx.one(_, sql)
            if sql:find('synex_group_proposals', 1, true) then
              return {
                id = 41, public_id = 'proposal_fixture_0001', group_id = 10,
                status = 'pending', proposal_type = 'membership.transition',
                payload_json = 'durable-payload', required_approvals = 2,
                version = 7, group_public_id = 'group_fixture_0001',
                approved_count = 2
              }, nil
            end
            return nil, nil
          end
          function tx.many() return {}, nil end
          function tx.query() return { affectedRows = 1 }, nil end
          function tx.affected() return 1, nil end
          function tx.insert()
            insertSequence = insertSequence + 1
            return insertSequence, nil
          end
          local value, handlerError = handler(tx)
          return value, handlerError, { replayed = false }
        end
      }
      local function encode(value)
        if type(value) == 'string' then return string.format('%q', value) end
        if type(value) == 'boolean' or type(value) == 'number' then return tostring(value) end
        return '{}'
      end
      local registry = {
        get = function() return nil, { code = 'REGISTRY_KEY_NOT_FOUND' } end,
        replace = function() return true end,
        stats = function() return { entries = 0, maximumEntries = 1, maximumPerOwner = 1 } end,
        listOwner = function() return {} end
      }
      local port = createPersistence({
        dataPort = createAdapter(coreDatabase), jsonEncode = encode,
        jsonDecode = function(value)
          assert(value == 'durable-payload')
          return { membership_id = 'membership_target_0001',
            expected_version = 1, status = 'SUSPENDED' }
        end,
        nextId = function(namespace) return namespace .. '_fixture_0001' end,
        capabilityEvaluator = { evaluate = function() return true end },
        policyEngine = { decide = function() return true end },
        cache = {}, registries = { groupTypes = registry },
        applicationSchemas = { validateSchema = function() return true end,
          validateData = function() return true end },
        validateOperation = function() return true end,
        runtimeIndex = { snapshot = function()
          return { characters = 0, memberships = 0, dutySessions = 0 }
        end },
        checkCorePermission = function() return true end
      })

      local forged, forgedError = port:execute('members_transition', {
        idempotency_key = 'proposal:proposal_fixture_0001',
        actor_character_id = 'character_actor_0001',
        membership_id = 'membership_target_0001', expected_version = 1,
        status = 'SUSPENDED', reason = 'approved_transition'
      }, {
        caller = 'synex_fixture', callerEpoch = 7, traceId = 'trace_forged_0001',
        approvedProposalId = 'proposal_fixture_0001'
      })
      assert(forged == nil and forgedError.code == 'APPROVAL_REQUIRED')
      assert(targetCalls == 0)

      local approved, approvedError, effects = port:execute('proposals_approve', {
        idempotency_key = 'proposal-decision-0001'
      }, {
        caller = 'synex_fixture', callerEpoch = 7, traceId = 'trace_approved_0001',
        beforeProposalExecute = function(envelope)
          return Foundation.copyPlain(envelope), nil
        end
      })
      return forgedError.code .. ':' .. tostring(approvedError and approvedError.code)
        .. ':' .. tostring(approved and approved.status) .. ':'
        .. tostring(targetCalls) .. ':' .. tostring(type(effects) == 'table' and #effects or -1)
    `);
    assert.equal(result, 'APPROVAL_REQUIRED:nil:SUSPENDED:1:1');
  } finally {
    engine.global.close();
  }
});
