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
  await preload(engine, 'server.domain.registry', 'resources/synex_groups/server/domain/registry.lua');
  for (const name of [
    'governance_shared',
    'governance_capabilities',
    'governance_capability_rules',
    'governance_policies',
    'governance_attribute_values',
    'governance_attributes',
    'governance_attribute_activation',
    'governance_definitions_capabilities',
    'governance_definitions_group_normalization',
    'governance_definitions_hierarchy',
    'governance_definitions_groups',
    'governance_definitions',
    'governance',
  ]) {
    await preload(
      engine,
      `server.persistence.${name}`,
      `resources/synex_groups/server/persistence/${name}.lua`,
    );
  }
}

const fixture = String.raw`
  local Foundation = require 'server.foundation'
  local Registry = require 'server.domain.registry'
  local handlers = require('server.persistence.governance')(Foundation)

  local sequence = 0
  local function scalarEncode(value)
    if type(value) == 'string' then return string.format('%q', value) end
    if type(value) == 'boolean' then return value and 'true' or 'false' end
    if value == nil then return 'null' end
    return tostring(value)
  end
  local runtime = {
    jsonEncode = scalarEncode,
    jsonDecode = function() return {} end,
    validateOperation = function() return true, nil end,
    registries = {
      groupTypes = Registry.create(),
      relationTypes = Registry.create(),
      attributeSchemas = Registry.create(),
      dutyStates = Registry.create()
    }
  }
  function runtime.id(namespace)
    sequence = sequence + 1
    return namespace .. '_' .. string.format('%08d', sequence)
  end
  function runtime.reason(_, fallback) return fallback end
  function runtime.success(entityId, entityType, status, version)
    return {
      entity_id = entityId, entity_type = entityType, status = status,
      version = version, replayed = false
    }
  end
  function runtime.effect(action, entityType, entityId, groupId, characterId,
      before, after, operationReason, version)
    return {
      action = action, entityType = entityType, entityId = entityId,
      groupId = groupId, characterId = characterId, before = before, after = after,
      reason = operationReason or action, version = version,
      eventType = 'synex.groups.' .. action
    }
  end
  function runtime.deferRegistry(_, registry, owner, epoch, generation, key, value)
    assert(generation == 1)
    return runtime.registries[registry]:replace(owner, epoch, key, value)
  end
  function runtime.requireRegistryOwnerSession(_, owner, epoch)
    assert(type(owner) == 'string' and type(epoch) == 'number' and epoch >= 1)
    return { ownerEpoch = epoch, generation = 1 }, nil
  end
  function runtime.requireGroup(_, groupId)
    return {
      id = 10, public_id = groupId, status = 'active', lifecycle_state = 'ACTIVE',
      version = 3
    }
  end
  function runtime.requireMembership(_, membershipId)
    return {
      id = membershipId == 'membership_target' and 22 or 21,
      public_id = membershipId,
      group_id = 10,
      group_public_id = 'group_0001',
      character_id = membershipId == 'membership_target' and 'character_target' or 'character_actor',
      lifecycle_state = 'ACTIVE',
      version = 1
    }
  end
  function runtime.touchGroup() return true end
  function runtime.authorize(_, _, characterId, capability)
    if capability == 'forbidden.capability' then
      return nil, Foundation.domainError('INSUFFICIENT_PERMISSION', 'denied')
    end
    return {
      id = 21, public_id = 'membership_actor', character_id = characterId,
      lifecycle_state = 'ACTIVE'
    }
  end
  function runtime.evaluateCharacter(_, _, characterId, capability)
    return {
      allowed = true, denied = false, reason = 'CAPABILITY_GRANTED',
      membership = { id = 21, character_id = characterId },
      trace = {{
        layer = 'grade', sourceId = 'grade_owner', ruleId = 'owner',
        capability = capability, effect = 'allow', matched = true, reason = 'MATCHED'
      }}
    }
  end
`;

test('governance persistence is pure server-side Lua and compiles without runtime globals', async () => {
  const source = await readFile(
    path.join(root, 'resources/synex_groups/server/persistence/governance.lua'),
    'utf8',
  );
  assert.doesNotMatch(source, /RegisterNetEvent|RegisterServerEvent|TriggerClientEvent/u);
  assert.doesNotMatch(source, /PerformHttpRequest|loadstring|dofile/u);
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    assert.equal(
      await engine.doString(`
        local Foundation = require 'server.foundation'
        local factory = require 'server.persistence.governance'
        local built = factory(Foundation)
        assert(type(built.read) == 'table' and type(built.execute) == 'table')
        assert(type(built.evaluateStoredPolicy) == 'function')
        return type(factory)
      `),
      'function',
    );
  } finally {
    await engine.global.close();
  }
});

test('capability management persists group defaults and direct membership grants with CAS', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`${fixture}
      local writes = {}
      local tx = {}
      function tx.one(sql)
        if sql:find('FROM synex_group_memberships AS membership', 1, true) then
          return { id = 22, public_id = 'membership_target', status = 'ACTIVE' }
        end
        if sql:find('synex_group_default_capabilities', 1, true)
            and sql:find('SELECT', 1, true) then return nil end
        if sql:find('synex_group_membership_capabilities', 1, true)
            and sql:find('SELECT', 1, true) then
          return { id = 81, effect = 'allow', scope_kind = 'group',
            scope_ref = '', delegable = 1, version = 2 }
        end
        error('unexpected capability rule query: ' .. sql)
      end
      function tx.affected(sql, parameters)
        writes[#writes + 1] = { sql = sql, parameters = parameters }
        return 1
      end
      function tx.query() error('capability changes must not enqueue a second authority copy') end

      local created = assert(handlers.execute.capabilities_set(tx, {
        actor_character_id = 'character_actor', group_id = 'group_0001',
        source_type = 'group', source_id = 'group_0001',
        capability = 'police.directory.read', effect = 'allow',
        scope = 'subtree', delegable = true
      }, runtime))
      assert(created.version == 1 and created.status == 'allow')
      assert(writes[1].sql:find('synex_group_default_capabilities', 1, true))
      assert(writes[1].parameters[4] == 'custom'
        and writes[1].parameters[5] == 'subtree'
        and writes[1].parameters[6] == 1)

      local changed = assert(handlers.execute.capabilities_set(tx, {
        actor_character_id = 'character_actor', group_id = 'group_0001',
        source_type = 'membership', source_id = 'membership_target',
        capability = 'police.directory.read', effect = 'deny', expected_version = 2
      }, runtime))
      assert(changed.version == 3 and changed.status == 'deny')
      assert(writes[2].sql:find('synex_group_membership_capabilities', 1, true))
      assert(writes[2].parameters[2] == 0)

      local _, invalidDelegableDeny = handlers.execute.capabilities_set(tx, {
        actor_character_id = 'character_actor', group_id = 'group_0001',
        source_type = 'group', source_id = 'group_0001',
        capability = 'police.directory.write', effect = 'deny', delegable = true
      }, runtime)
      assert(invalidDelegableDeny.code == 'VALIDATION_FAILED')

      local _, staleError = handlers.execute.capabilities_set(tx, {
        actor_character_id = 'character_actor', group_id = 'group_0001',
        source_type = 'membership', source_id = 'membership_target',
        capability = 'police.directory.read', effect = 'allow', expected_version = 1
      }, runtime)
      assert(staleError.code == 'CONCURRENT_MODIFICATION')
      return created.status .. ':' .. changed.status .. ':' .. staleError.code
    `);
    assert.equal(result, 'allow:deny:CONCURRENT_MODIFICATION');
  } finally {
    await engine.global.close();
  }
});

test('capability check and explain return bounded deny-wins traces for active memberships', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`${fixture}
      function runtime.evaluateCharacter(_, _, characterId, capability)
        local trace = {}
        for index = 1, 140 do
          trace[index] = {
            layer = 'role', sourceId = 'role_' .. index, ruleId = 'rule_' .. index,
            capability = capability, effect = index == 140 and 'deny' or 'allow',
            matched = true, reason = 'MATCHED'
          }
        end
        return {
          allowed = false, denied = true, reason = 'EXPLICIT_DENY',
          membership = { id = 21, character_id = characterId }, trace = trace
        }
      end
      local request = {
        character_id = 'character_target', actor_character_id = 'character_target',
        group_id = 'group_0001', capability = 'police.evidence.delete', scope = 'group'
      }
      local checked = assert(handlers.read.capabilities_check({}, request, runtime, {
        traceId = 'trace_governance_0001'
      }))
      local explained = assert(handlers.read.capabilities_explain({}, request, runtime, {
        traceId = 'trace_governance_0002'
      }))
      assert(checked.decision == 'DENY' and checked.reason == 'EXPLICIT_DENY')
      assert(checked.character_id == request.character_id and checked.group_id == request.group_id)
      assert(checked.scope == 'group' and checked.delegable == false
        and #checked.evaluation == 128)
      assert(explained.decision == checked.decision and #explained.evaluation == 128)
      return checked.trace_id .. ':' .. explained.trace_id
    `);
    assert.equal(result, 'trace_governance_0001:trace_governance_0002');
  } finally {
    await engine.global.close();
  }
});

test('delegations require owned authority, same-group active targets, bounded windows, and subtree scope encoding', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`${fixture}
      local observed = { queries = {}, authorizations = {} }
      local forceNonDelegable = false
      function runtime.authorize(_, _, characterId, capability)
        observed.authorizations[#observed.authorizations + 1] = capability
        if capability == 'forbidden.capability' then
          return nil, Foundation.domainError('INSUFFICIENT_PERMISSION', 'denied')
        end
        local membership = { id = 21, public_id = 'membership_actor', character_id = characterId }
        if capability == 'synex.groups.delegations.manage' then return membership end
        return membership, nil, { delegable = not forceNonDelegable }
      end
      local tx = {}
      function tx.one(sql)
        if sql:find('CASE', 1, true) then return { valid = 1 } end
        return nil
      end
      function tx.query(sql, parameters)
        observed.queries[#observed.queries + 1] = { sql = sql, parameters = parameters }
        return { affectedRows = 1 }
      end
      local request = {
        actor_character_id = 'character_actor', group_id = 'group_0001',
        grantee_membership_id = 'membership_target', capability = 'police.members.manage',
        scope = 'subtree', valid_from = '2026-08-25T12:00:00Z',
        valid_until = '2026-08-26T12:00:00Z', reason = 'temporary coverage'
      }
      local created, createError, effects = handlers.execute.delegations_create(tx, request, runtime)
      assert(createError == nil and created.status == 'active' and #effects == 1)
      assert(observed.authorizations[1] == 'synex.groups.delegations.manage')
      assert(observed.authorizations[2] == request.capability)
      local insert = observed.queries[1]
      assert(insert.sql:find('synex_group_delegations', 1, true))
      assert(insert.parameters[6] == 'custom' and insert.parameters[7] == 'subtree')

      forceNonDelegable = true
      request.capability = 'police.members.read'
      local blocked, blockedError = handlers.execute.delegations_create(tx, request, runtime)
      assert(blocked == nil and blockedError.code == 'INSUFFICIENT_PERMISSION'
        and blockedError.details.reason == 'CAPABILITY_NOT_DELEGABLE')
      forceNonDelegable = false

      request.capability = 'forbidden.capability'
      local denied, deniedError = handlers.execute.delegations_create(tx, request, runtime)
      assert(denied == nil and deniedError.code == 'INSUFFICIENT_PERMISSION')
      return created.entity_type .. ':' .. effects[1].action
    `);
    assert.equal(result, 'delegation:delegation.created');
  } finally {
    await engine.global.close();
  }
});

test('policy definitions are closed, updates require expected versions, and simulation applies explicit deny over allow', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`${fixture}
      local writes = 0
      local tx = {}
      function tx.one(sql)
        if sql:find('synex_group_policies', 1, true) then return nil end
        return nil
      end
      function tx.insert() writes = writes + 1 return 44 end
      function tx.query() writes = writes + 1 return { affectedRows = 1 } end
      function tx.affected() writes = writes + 1 return 1 end
      local base = {
        actor_character_id = 'character_actor', group_id = 'group_0001',
        action = 'police.members.promote'
      }
      local invalid = {
        display_name = 'Promotion', default_effect = 'deny', rules = {}, executable = true
      }
      local _, invalidError = handlers.execute.policies_set(tx, {
        actor_character_id = base.actor_character_id, group_id = base.group_id,
        action = base.action, definition = invalid
      }, runtime)
      assert(invalidError.code == 'VALIDATION_FAILED' and writes == 0)

      local _, unsupportedSubjectError = handlers.execute.policies_set(tx, {
        actor_character_id = base.actor_character_id, group_id = base.group_id,
        action = base.action, definition = {
          display_name = 'Resource policy', default_effect = 'deny', rules = {{
            key = 'resource_allow', priority = 1, effect = 'allow',
            action = base.action, subject_kind = 'resource'
          }}
        }
      }, runtime)
      assert(unsupportedSubjectError.code == 'VALIDATION_FAILED' and writes == 0)

      local definition = {
        display_name = 'Promotion', default_effect = 'deny', rules = {
          { key = 'allow_active', priority = 10, effect = 'allow',
            action = base.action, condition = { target_active = true } },
          { key = 'deny_locked', priority = 20, effect = 'deny',
            action = base.action, condition = {
              parameter = 'locked', operator = 'equals', value = true
            } }
        }
      }
      local created = assert(handlers.execute.policies_set(tx, {
        actor_character_id = base.actor_character_id, group_id = base.group_id,
        action = base.action, definition = definition
      }, runtime))
      assert(created.entity_type == 'policy' and created.version == 1 and writes == 3)

      function tx.one(sql)
        if sql:find('SELECT version FROM synex_group_policies', 1, true) then
          return { version = 1 }
        end
        if sql:find('FROM synex_group_policies', 1, true) then
          return { id = 44, public_id = created.entity_id, default_effect = 'deny', version = 1 }
        end
        return nil
      end
      function tx.many()
        return {
          { rule_key = 'deny_locked', priority = 20, effect = 'deny',
            action_pattern = base.action, subject_kind = 'character',
            scope_kind = 'group', scope_ref = '', condition_json = 'deny' },
          { rule_key = 'allow_active', priority = 10, effect = 'allow',
            action_pattern = base.action, subject_kind = 'character',
            scope_kind = 'group', scope_ref = '', condition_json = nil }
        }
      end
      function runtime.jsonDecode(value)
        if value == 'deny' then
          return { parameter = 'locked', operator = 'equals', value = true }
        end
        return {}
      end
      local simulated = assert(handlers.read.policies_simulate(tx, {
        actor_character_id = base.actor_character_id, group_id = base.group_id,
        action = base.action, parameters = { locked = true }
      }, runtime, { traceId = 'trace_policy_0001' }))
      assert(simulated.decision == 'DENY' and simulated.reason == 'POLICY_EXPLICIT_DENY')
      assert(#simulated.evaluation == 3)
      return created.status .. ':' .. simulated.reason
    `);
    assert.equal(result, 'active:POLICY_EXPLICIT_DENY');
  } finally {
    await engine.global.close();
  }
});

test('attribute schemas bind ownership to caller and typed writes enforce schema plus optimistic concurrency', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`${fixture}
      local tx = { writes = 0 }
      function tx.one(sql)
        if sql:find('synex_group_attribute_schemas', 1, true) then
          if sql:find('namespace =', 1, true) and sql:find('status =', 1, true) then
            return {
              id = 50, public_id = 'schema_0001', owner_resource = 'synex_police',
              value_kind = 'integer', visibility = 'management', required_value = 1,
              validation_json = 'integer_rules', capability = nil, schema_version = 1
            }
          end
          return nil
        end
        if sql:find('synex_group_membership_attributes', 1, true) then
          return {
            public_id = 'attribute_0001', value_kind = 'integer',
            value_integer = 41, version = 2
          }
        end
        return nil
      end
      function tx.query(_, parameters) tx.writes = tx.writes + 1; tx.last = parameters; return { affectedRows = 1 } end
      function tx.affected(_, parameters) tx.writes = tx.writes + 1; tx.last = parameters; return 1 end
      function runtime.jsonDecode(value)
        if value == 'integer_rules' then return { required = true, minimum = 1, maximum = 9999 } end
        return {}
      end

      local _, ownerError = handlers.execute.attributes_register_schema(tx, {
        namespace = 'synex_police', key = 'badge', type = 'integer',
        visibility = 'management', schema_version = 1
      }, runtime, { caller = 'synex_police', callerEpoch = 0 })
      assert(ownerError.code == 'VALIDATION_FAILED' and tx.writes == 0)

      local registered = assert(handlers.execute.attributes_register_schema(tx, {
        namespace = 'synex_police', key = 'badge', type = 'integer',
        default = 1,
        validation = { required = true, minimum = 1, maximum = 9999 },
        visibility = 'management', schema_version = 1
      }, runtime, { caller = 'synex_police', callerEpoch = 7 }))
      assert(registered.entity_type == 'attribute_schema')
      assert(tx.writes == 1 and tx.last[2] == 'synex_police')
      local schemaRegistration, _, schemaOwner =
        runtime.registries.attributeSchemas:get(
          'attribute_schema:global:synex_police:badge')
      assert(schemaRegistration.type == 'integer')
      assert(schemaOwner.owner == 'synex_police' and schemaOwner.epoch == 7)
      tx.writes, tx.last = 0, nil

      local _, versionError = handlers.execute.attributes_set(tx, {
        actor_character_id = 'character_actor', membership_id = 'membership_target',
        namespace = 'synex_police', key = 'badge', value = 42
      }, runtime)
      assert(versionError.code == 'CONCURRENT_MODIFICATION' and tx.writes == 0)

      local updated, updateError, effects = handlers.execute.attributes_set(tx, {
        actor_character_id = 'character_actor', membership_id = 'membership_target',
        namespace = 'synex_police', key = 'badge', value = 42,
        expected_version = 2, reason = 'badge corrected'
      }, runtime)
      assert(updateError == nil and updated.version == 3 and updated.entity_id == 'attribute_0001')
      assert(tx.last[3] == 42 and #effects == 1)

      local _, invalidValue = handlers.execute.attributes_set(tx, {
        actor_character_id = 'character_actor', membership_id = 'membership_target',
        namespace = 'synex_police', key = 'badge', value = 10000,
        expected_version = 2
      }, runtime)
      assert(invalidValue.code == 'VALIDATION_FAILED')
      return updated.entity_type .. ':' .. effects[1].action
    `);
    assert.equal(result, 'attribute:attribute.changed');
  } finally {
    await engine.global.close();
  }
});

test('definition sync is a catalog operation and cannot masquerade as an operational type registration', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`${fixture}
      local tx = { writes = 0 }
      function tx.one(sql)
        if sql:find('SHA2', 1, true) then return { digest = string.rep('a', 64) } end
        return nil
      end
      function tx.many() return {} end
      function tx.query() tx.writes = tx.writes + 1; return { affectedRows = 1 } end
      function tx.affected() tx.writes = tx.writes + 1; return 1 end
      function tx.insert() tx.writes = tx.writes + 1; return 99 end

      local request = {
        schema_version = 1,
        definitions = {{ key = 'police', kind = 'group_type', label = 'Police' }},
        dry_run = true
      }
      local dry, dryError = handlers.execute.definitions_sync(tx, request, runtime, {
        caller = 'synex_police', callerEpoch = 7
      })
      assert(dry, dryError and dryError.code or 'dry sync failed')
      assert(tx.writes == 0 and #dry.items == 1 and dry.items[1].change == 'create')
      local _, absent = runtime.registries.groupTypes:get('group_type:police')
      assert(absent.code == 'REGISTRY_KEY_NOT_FOUND')

      request.owner_resource = 'synex_ambulance'
      local _, impersonationError = handlers.execute.definitions_sync(tx, request, runtime, {
        caller = 'synex_police', callerEpoch = 7
      })
      assert(impersonationError.code == 'INSUFFICIENT_PERMISSION' and tx.writes == 0)

      request.owner_resource = 'synex_police'
      request.dry_run = false
      local applied, appliedError = handlers.execute.definitions_sync(tx, request, runtime, {
        caller = 'synex_police', callerEpoch = 7
      })
      assert(applied, appliedError and appliedError.code or 'applied sync failed')
      assert(tx.writes == 1 and applied.items[1].state == 'applied')
      local _, stillAbsent = runtime.registries.groupTypes:get('group_type:police')
      assert(stillAbsent.code == 'REGISTRY_KEY_NOT_FOUND')
      return dry.items[1].state .. ':' .. applied.items[1].state
    `);
    assert.equal(result, 'planned:applied');
  } finally {
    await engine.global.close();
  }
});
