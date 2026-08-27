import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';

const root = process.cwd();

async function preload(engine: Awaited<ReturnType<LuaFactory['createEngine']>>, name: string, file: string) {
  const source = await readFile(path.join(root, file), 'utf8');
  await engine.doString(
    `package.preload[${JSON.stringify(name)}] = assert(load(${JSON.stringify(source)}, ${JSON.stringify(`@${file}`)}))`,
  );
}

test('service dispatches creation decisions and attribute reads through their exact boundaries', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await preload(engine, 'server.foundation', 'resources/synex_groups/server/foundation.lua');
    await preload(engine, 'server.validation', 'resources/synex_groups/server/validation.lua');
    await preload(engine, 'server.service', 'resources/synex_groups/server/service.lua');
    const result = await engine.doString(`
      local Foundation = require 'server.foundation'
      local createService = require('server.service')(Foundation)
      local calls, advanced = {}, {}
      local repository = {}
      function repository:preflight()
        return true, nil
      end
      function repository:read(operation)
        calls[#calls + 1] = 'read:' .. operation
        if operation == 'attributes_get' then
          return {
            attribute_id = 'groups_attribute_00000001',
            membership_id = 'groups_membership_00000001',
            group_id = 'groups_group_00000001', namespace = 'identity', key = 'callsign',
            type = 'string', visibility = 'members', value = 'A-12', version = 1
          }, nil, {}
        end
        assert(operation == 'creation_requests_get')
        return { creation_request_id = 'groups_creation_00000001', status = 'pending' }, nil, {}
      end
      function repository:execute(operation)
        calls[#calls + 1] = 'execute:' .. operation
        assert(operation == 'creation_requests_approve')
        return {
          creation_request_id = 'groups_creation_00000001',
          decision_id = 'groups_approval_00000001', status = 'approved',
          approval_count = 2, required_approvals = 2, version = 3, replayed = false
        }, nil, {}
      end
      local methods = createService({
        repository = repository,
        characters = { get = function() return { id = 'character_00000001' }, nil end },
        hooks = { run = function(_, value) return value, nil end },
        audit = { append = function() return { eventId = 'audit_event_00000001' }, nil end },
        groupCreationApprovals = { advance = function(_, requestId, traceId)
          advanced[#advanced + 1] = requestId .. ':' .. traceId
          return { entity_id = 'groups_group_00000001' }, nil
        end },
        runtimeEffects = { apply = function() return true, nil end },
        jsonEncode = function() return '{}' end,
        cache = {
          get = function() return nil end,
          put = function() end,
          invalidatePrefix = function() end
        },
        errorSink = function() end
      })
      local context = {
        traceId = 'trace_groups_0001', caller = 'probe_resource', callerEpoch = 7
      }
      local attribute, attributeError = methods.attributes_get({
        actor_character_id = 'character_00000001',
        membership_id = 'groups_membership_00000001',
        namespace = 'identity', key = 'callsign'
      }, context)
      assert(attributeError == nil and attribute.value == 'A-12')
      local request, requestError = methods.creation_requests_get({
        actor_character_id = 'character_00000001',
        creation_request_id = 'groups_creation_00000001'
      }, context)
      assert(requestError == nil and request.status == 'pending')
      local approval, approvalError = methods.creation_requests_approve({
        idempotency_key = 'approve-request-0001',
        actor_character_id = 'character_00000001',
        creation_request_id = 'groups_creation_00000001',
        expected_version = 2, reason = 'Reviewed'
      }, context)
      assert(approvalError == nil and approval.status == 'approved')
      assert(#advanced == 1
        and advanced[1] == 'groups_creation_00000001:trace_groups_0001')
      return table.concat(calls, ',')
    `);
    assert.equal(
      result,
      'read:attributes_get,read:creation_requests_get,execute:creation_requests_approve',
    );
  } finally {
    await engine.global.close();
  }
});

test('approval execution applies committed runtime effects exactly once after persistence', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await preload(engine, 'server.foundation', 'resources/synex_groups/server/foundation.lua');
    await preload(
      engine,
      'server.group_creation_approvals',
      'resources/synex_groups/server/group_creation_approvals.lua',
    );
    const result = await engine.doString(`
      local Foundation = require 'server.foundation'
      local createCoordinator = require('server.group_creation_approvals')(Foundation)
      local applied = 0
      local execution = {
        creationRequestId = 'groups_creation_00000001', version = 3,
        request = { idempotency_key = 'creation-request-0001',
          actor_character_id = 'character_00000001', type = 'business',
          slug = 'alpha', name = 'Alpha', label = 'Alpha' },
        requestedByCharacterId = 'character_00000001',
        creatorPermission = 'synex.groups.create.business',
        approvalPermission = 'synex.groups.create.approve.business',
        requiredApprovals = 1,
        approverCharacterIds = { 'character_00000002' }
      }
      local repository = {}
      function repository:read(operation)
        assert(operation == 'creation_requests_execution_context')
        return execution, nil
      end
      function repository:execute(operation)
        assert(operation == 'creation_requests_execute')
        return { entity_id = 'groups_group_00000001' }, nil, {
          { action = 'membership.activated', entityType = 'membership',
            entityId = 'groups_membership_00000001',
            groupId = 'groups_group_00000001', characterId = 'character_00000001' }
        }
      end
      local coordinator = createCoordinator({
        repository = repository,
        permissions = { check = function() return true, nil end },
        hooks = { run = function(_, value) return Foundation.copyPlain(value), nil end },
        context = function(traceId)
          return { traceId = traceId, caller = 'synex_groups', callerEpoch = 4 }, nil
        end,
        jsonEncode = function(value)
          if type(value) == 'string' then return '"' .. value .. '"' end
          if type(value) == 'boolean' or type(value) == 'number' then
            return tostring(value)
          end
          error('unexpected scalar')
        end,
        onCommittedEffects = function(effects, traceId)
          assert(#effects == 1 and effects[1].action == 'membership.activated')
          assert(traceId == 'trace_create_0001')
          applied = applied + 1
          return true, nil
        end,
        errorSink = function() end
      })
      local created, creationError = coordinator:advance(
        execution.creationRequestId, 'trace_create_0001')
      assert(creationError == nil and created.entity_id == 'groups_group_00000001')
      return applied
    `);
    assert.equal(result, 1);
  } finally {
    await engine.global.close();
  }
});

test('composition schedules approval recovery and publishes all additive metadata server-only', async () => {
  const [main, runtimeRegistration, scheduler, catalogRaw, manifestRaw] = await Promise.all([
    readFile(path.join(root, 'resources/synex_groups/server/main.lua'), 'utf8'),
    readFile(path.join(root, 'resources/synex_groups/server/runtime_registration.lua'), 'utf8'),
    readFile(path.join(root, 'resources/synex_groups/server/scheduler.lua'), 'utf8'),
    readFile(path.join(root, 'resources/synex_groups/groups.contracts.json'), 'utf8'),
    readFile(path.join(root, 'resources/synex_groups/synex.resource.json'), 'utf8'),
  ]);
  const catalog = JSON.parse(catalogRaw) as {
    contracts: Array<{ name: string; network: string; capability: string }>;
  };
  const manifest = JSON.parse(manifestRaw) as {
    contracts: { provide: string[] };
    migrations: Array<{ id: string }>;
    dataOwnership: { tables: string[] };
  };
  assert.match(main, /organizations_creation_approvals\s*=\s*require/u);
  assert.match(main, /createGroupCreationApprovals\([\s\S]*?ownerEpoch/u);
  assert.match(runtimeRegistration, /groupCreationApprovals\s*=\s*groupCreationApprovals/u);
  assert.match(main, /onCommittedEffects\s*=\s*applyCoordinatorEffects/u);
  assert.match(scheduler, /groupCreationApprovals:reconcile\(16\)/u);
  assert.match(scheduler, /synex_groups\.creation_reconciliation/u);

  for (const name of [
    'synex.groups.creation_requests.get',
    'synex.groups.creation_requests.approve',
    'synex.groups.creation_requests.reject',
    'synex.groups.attributes.get',
    'synex.groups.members.transition_policy.get',
    'synex.groups.members.transition_policy.set',
  ]) {
    const contract = catalog.contracts.find((candidate) => candidate.name === name);
    assert.ok(contract, `${name} is missing`);
    assert.equal(contract.network, 'none');
    assert.ok(contract.capability.startsWith('synex.groups.'));
    assert.ok(manifest.contracts.provide.includes(name));
  }
  assert.deepEqual(
    manifest.migrations.slice(-6).map((migration) => migration.id),
    [
      '027_identifier_contract_consistency',
      '028_membership_transition_policies',
      '029_assignment_member_active_counts',
      '030_membership_workflow_entities',
      '031_registry_owner_sync_sessions',
      '032_character_reference_contract',
    ],
  );
  for (const table of [
    'synex_group_creation_requests',
    'synex_group_creation_approvals',
    'synex_group_slug_reservations',
    'synex_group_membership_transition_policies',
  ]) {
    assert.ok(manifest.dataOwnership.tables.includes(table));
  }
});
