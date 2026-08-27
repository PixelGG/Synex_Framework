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
  await preload(engine, 'server.domain.constants', 'resources/synex_groups/server/domain/constants.lua');
  await preload(engine, 'server.domain.lifecycle', 'resources/synex_groups/server/domain/lifecycle.lua');
  await preload(
    engine,
    'server.persistence.memberships_shared',
    'resources/synex_groups/server/persistence/memberships_shared.lua',
  );
  await preload(
    engine,
    'server.persistence.memberships_access',
    'resources/synex_groups/server/persistence/memberships_access.lua',
  );
  await preload(engine, 'server.validation', 'resources/synex_groups/server/validation.lua');
}

test('membership visibility is a server-only capability-bound contract with one closed enum', async () => {
  const contracts = JSON.parse(await readFile(
    path.join(root, 'resources/synex_groups/groups.contracts.json'),
    'utf8',
  )) as {
    contracts: Array<{
      name: string;
      network: string;
      capability: string;
      idempotent?: boolean;
      input: {
        required: string[];
        properties: Record<string, { enum?: string[] }>;
      };
    }>;
  };
  const contract = contracts.contracts.find(
    (candidate) => candidate.name === 'synex.groups.members.set_visibility',
  );
  assert.ok(contract);
  assert.equal(contract.network, 'none');
  assert.equal(contract.capability, 'synex.groups.members.manage');
  assert.equal(contract.idempotent, true);
  assert.deepEqual(contract.input.required, [
    'idempotency_key',
    'actor_character_id',
    'membership_id',
    'visibility',
    'expected_version',
    'reason',
  ]);
  assert.deepEqual(contract.input.properties.visibility?.enum, [
    'public',
    'members',
    'management',
    'hidden',
    'server_only',
  ]);

  const manifest = JSON.parse(await readFile(
    path.join(root, 'resources/synex_groups/synex.resource.json'),
    'utf8',
  )) as { contracts: { provide: string[] } };
  assert.ok(manifest.contracts.provide.includes(contract.name));

  const source = await readFile(
    path.join(root, 'resources/synex_groups/server/persistence/memberships_access.lua'),
    'utf8',
  );
  assert.doesNotMatch(source, /RegisterNetEvent|RegisterServerEvent|TriggerClientEvent/u);
  assert.doesNotMatch(source, /MySQL\.|oxmysql/u);
});

test('membership visibility authorizes the actor and commits both CAS rows with one domain effect', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`
      local Foundation = require 'server.foundation'
      local handlers = require('server.persistence.memberships_access')(Foundation)
      local writes, insertedEvent, authorization = {}, nil, nil
      local tx = {}
      function tx.affected(sql, parameters)
        writes[#writes + 1] = { sql = sql, parameters = parameters }
        return 1
      end
      function tx.query(sql, parameters)
        insertedEvent = { sql = sql, parameters = parameters }
        return { affectedRows = 1 }
      end
      local runtime = {}
      function runtime.requireMembership(_, membershipId, lock)
        assert(membershipId == 'membership_target' and lock == true)
        return {
          id = 22, public_id = membershipId,
          group_id = 10, group_public_id = 'group_0001',
          character_id = 'character_target', lifecycle_state = 'ACTIVE',
          visibility = 'public', version = 4, profile_version = 7
        }
      end
      function runtime.authorize(_, groupId, actorId, capability, scope, policy)
        authorization = {
          groupId = groupId, actorId = actorId, capability = capability,
          scope = scope, policy = policy
        }
        return { public_id = 'membership_actor' }, nil
      end
      function runtime.reason(value) return value end
      function runtime.id(namespace)
        assert(namespace == 'group_mevent')
        return 'membership_event_0001', nil
      end
      function runtime.jsonEncode() return '{"visibility":"hidden"}' end
      function runtime.touchGroup(_, groupId)
        assert(groupId == 10)
        return true, nil
      end
      function runtime.success(entityId, entityType, status, version)
        return {
          entity_id = entityId, entity_type = entityType, status = status,
          version = version, replayed = false
        }
      end
      function runtime.effect(action, entityType, entityId, groupId, characterId,
          before, after, reason, version)
        return {
          action = action, entityType = entityType, entityId = entityId,
          groupId = groupId, characterId = characterId,
          before = before, after = after, reason = reason, version = version,
          eventType = 'synex.groups.' .. action
        }
      end

      local value, err, effects = handlers.execute.members_set_visibility(tx, {
        idempotency_key = 'visibility_command_0001',
        actor_character_id = 'character_actor',
        membership_id = 'membership_target',
        visibility = 'hidden', expected_version = 4,
        reason = 'privacy_requested'
      }, runtime)
      assert(value and err == nil and value.status == 'hidden' and value.version == 5)
      assert(authorization.groupId == 'group_0001')
      assert(authorization.actorId == 'character_actor')
      assert(authorization.capability == 'synex.groups.members.manage')
      assert(authorization.scope == 'group')
      assert(authorization.policy.target_membership.public_id == 'membership_target')
      assert(authorization.policy.parameters.visibility == 'hidden')
      assert(authorization.policy.parameters.reason == 'privacy_requested')
      assert(#writes == 2)
      assert(writes[1].sql:find('UPDATE synex_group_memberships', 1, true))
      assert(writes[1].parameters[1] == 22 and writes[1].parameters[2] == 4)
      assert(writes[2].sql:find('UPDATE synex_group_membership_profiles', 1, true))
      assert(writes[2].parameters[1] == 'hidden')
      assert(writes[2].parameters[2] == 'privacy_requested')
      assert(writes[2].parameters[3] == 22 and writes[2].parameters[4] == 7)
      assert(insertedEvent.sql:find("'visibility_changed'", 1, true))
      assert(insertedEvent.parameters[1] == 'membership_event_0001')
      assert(insertedEvent.parameters[3] == 5)
      assert(#effects == 1)
      assert(effects[1].action == 'membership.visibility_changed')
      assert(effects[1].eventType == 'synex.groups.membership.visibility_changed')
      assert(effects[1].before.visibility == 'public' and effects[1].before.version == 4)
      assert(effects[1].before.profile_version == 7)
      assert(effects[1].after.visibility == 'hidden' and effects[1].after.version == 5)
      assert(effects[1].after.profile_version == 8)
      assert(effects[1].reason == 'privacy_requested')
      return value.entity_id
    `);
    assert.equal(result, 'membership_target');
  } finally {
    await engine.global.close();
  }
});

test('membership visibility rejects stale versions, denied authority, and unsupported values without writes', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`
      local Foundation = require 'server.foundation'
      local Validation = require('server.validation')(Foundation)
      local handlers = require('server.persistence.memberships_access')(Foundation)
      local writeCount = 0
      local tx = {
        affected = function() writeCount = writeCount + 1 return 1 end,
        query = function() writeCount = writeCount + 1 return {} end
      }
      local runtime = {
        reason = function(value) return value end,
        success = function() return {} end,
        effect = function() return {} end,
        id = function() return 'membership_event_0001' end,
        jsonEncode = function() return '{}' end,
        touchGroup = function() return true end
      }
      function runtime.requireMembership()
        return {
          id = 22, public_id = 'membership_target',
          group_id = 10, group_public_id = 'group_0001',
          character_id = 'character_target', lifecycle_state = 'ACTIVE',
          visibility = 'public', version = 4, profile_version = 4
        }
      end
      function runtime.authorize() return { public_id = 'membership_actor' }, nil end
      local request = {
        idempotency_key = 'visibility_command_0001',
        actor_character_id = 'character_actor', membership_id = 'membership_target',
        visibility = 'members', expected_version = 3, reason = 'privacy_requested'
      }
      local stale, staleError = handlers.execute.members_set_visibility(tx, request, runtime)
      assert(stale == nil and staleError.code == 'CONCURRENT_MODIFICATION')
      assert(writeCount == 0)

      request.expected_version = 4
      function runtime.authorize()
        return nil, Foundation.domainError('INSUFFICIENT_PERMISSION', 'denied')
      end
      local denied, deniedError = handlers.execute.members_set_visibility(tx, request, runtime)
      assert(denied == nil and deniedError.code == 'INSUFFICIENT_PERMISSION')
      assert(writeCount == 0)

      for _, visibility in ipairs({ 'private', 'staff', 'PUBLIC', 'hidden\\nsecret' }) do
        request.visibility = visibility
        local valid, validationError = Validation.operation('members_set_visibility', request)
        assert(valid == nil and validationError.code == 'VALIDATION_FAILED')
        local rejected, rejectedError = handlers.execute.members_set_visibility(tx, request, runtime)
        assert(rejected == nil and rejectedError.code == 'VALIDATION_FAILED')
      end
      request.visibility = 'public'
      function runtime.requireMembership()
        return {
          id = 22, public_id = 'membership_target',
          group_id = 10, group_public_id = 'group_0001',
          character_id = 'character_target', lifecycle_state = 'INVITED',
          visibility = 'hidden', version = 4, profile_version = 4
        }
      end
      local hiddenFromDenied, hiddenFromDeniedError =
        handlers.execute.members_set_visibility(tx, request, runtime)
      assert(hiddenFromDenied == nil
        and hiddenFromDeniedError.code == 'INSUFFICIENT_PERMISSION')
      function runtime.authorize() return { public_id = 'membership_actor' }, nil end
      local exposed, exposedError = handlers.execute.members_set_visibility(tx, request, runtime)
      assert(exposed == nil and exposedError.code == 'INVALID_TRANSITION')
      assert(writeCount == 0)
      return true
    `);
    assert.equal(result, true);
  } finally {
    await engine.global.close();
  }
});
