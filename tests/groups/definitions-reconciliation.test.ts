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
    'governance_definitions_capabilities',
    'governance_definitions_group_normalization',
    'governance_definitions_hierarchy',
    'governance_definitions_groups',
    'governance_definitions',
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
  local Groups = require('server.persistence.governance_definitions_groups')(Foundation)
  local CapabilityDefinitions = require(
    'server.persistence.governance_definitions_capabilities')(Foundation)
  local handlers = require('server.persistence.governance_definitions')(Foundation)
  local sequence = 0
  local function scalarEncode(value)
    if type(value) == 'string' then return string.format('%q', value) end
    if type(value) == 'boolean' then return value and 'true' or 'false' end
    if value == nil then return 'null' end
    return tostring(value)
  end
  local runtime = {
    jsonEncode = scalarEncode,
    validateOperation = function() return true, nil end,
    registries = {
      groupTypes = Registry.create(), relationTypes = Registry.create(),
      attributeSchemas = Registry.create(), dutyStates = Registry.create()
    }
  }
  function runtime.id(namespace)
    sequence = sequence + 1
    return namespace .. '_' .. string.format('%08d', sequence)
  end
  function runtime.effect(action, entityType, entityId, groupId, characterId,
      before, after, reason)
    return {
      action = action, eventType = 'synex.groups.' .. action,
      entityType = entityType, entityId = entityId, groupId = groupId,
      characterId = characterId, before = before, after = after,
      reason = reason, version = after and after.version or 1
    }
  end
`;

const groupDefinition = String.raw`{
  key = 'lspd', kind = 'group', type = 'law_enforcement', slug = 'lspd',
  name = 'Los Santos Police Department', label = 'LSPD', visibility = 'internal',
  metadata = {},
  grades = {{ key = 'officer', label = 'Officer', rank = 10, status = 'active' }},
  roles = {{ key = 'supervisor', label = 'Supervisor', exclusive = false }}
}`;

test('static group definitions are closed, bounded, and parent graphs are acyclic and owner-local', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`${fixture}
      local valid = assert(Groups.normalize(${groupDefinition}))
      assert(valid.kind == 'group' and valid.dynamic == nil and #valid.grades == 1
        and #valid.capabilities == 0 and #valid.grades[1].capabilities == 0)
      local secured = assert(Groups.normalize({
        key = 'secured', kind = 'group', type = 'law_enforcement', slug = 'secured',
        name = 'Secured', label = 'Secured',
        grades = {{ key = 'member', label = 'Member', rank = 1,
          capabilities = {{ capability = 'secured.records.*', effect = 'deny',
            scope = 'subtree' }} }},
        capabilities = {{ capability = 'secured.read', effect = 'allow',
          delegable = true }}
      }))
      assert(secured.capabilities[1].delegable == true
        and secured.grades[1].capabilities[1].scope == 'subtree')
      secured.capabilities[1].effect = 'deny'
      local _, delegationError = Groups.normalize(secured)
      assert(delegationError.code == 'VALIDATION_FAILED')
      local invalid, invalidError = Groups.normalize({
        key = 'lspd', kind = 'group', type = 'law_enforcement', slug = 'lspd',
        name = 'LSPD', label = 'LSPD', grades = {}, invented = true
      })
      assert(invalid == nil and invalidError.code == 'VALIDATION_FAILED')
      local first = { key = 'first', kind = 'group', group = {
        key = 'first', parent_key = 'second'
      } }
      local second = { key = 'second', kind = 'group', group = {
        key = 'second', parent_key = 'first'
      } }
      local ordered, cycleError = Groups.ordered({ first, second }, {
        first = first, second = second
      })
      assert(ordered == nil and cycleError.code == 'HIERARCHY_CYCLE')
      second.group.parent_key = 'foreign'
      local _, parentError = Groups.ordered({ first, second }, {
        first = first, second = second
      })
      assert(parentError.code == 'VALIDATION_FAILED')
      return valid.visibility
    `);
    assert.equal(result, 'internal');
  } finally {
    await engine.global.close();
  }
});

test('static capability ownership blocks removals and adoption of dynamic rules', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    const result = await bootstrap(engine).then(() => engine.doString(`${fixture}
      local rule = { capability = 'police.records.read', effect = 'allow',
        scope = 'group', delegable = false }
      local item = {
        key = 'lspd', group = { capabilities = {}, grades = {}, roles = {} },
        previousGroup = { capabilities = { rule }, grades = {}, roles = {} }
      }
      local state = {
        mode = 'update', live = { id = 101, public_id = 'groups_group_00000001' },
        issues = {}, grades = {}, roles = {}, needsWrite = false
      }
      local tx = {}
      function tx.many(sql)
        if sql:find('synex_group_default_capabilities', 1, true) then
          return {{ id = 1, capability_pattern = rule.capability, effect = 'allow',
            scope_kind = 'group', scope_ref = '', delegable = 0, version = 1,
            source_public_id = state.live.public_id }}
        end
        return {}
      end
      assert(CapabilityDefinitions.inspect(tx, item, state, true))
      assert(#state.issues == 1
        and state.issues[1].code == 'CAPABILITY_REMOVAL_REQUIRES_MIGRATION')

      item.previousGroup.capabilities = {}
      item.group.capabilities = { rule }
      state.issues = {}
      assert(CapabilityDefinitions.inspect(tx, item, state, true))
      assert(#state.issues == 1
        and state.issues[1].code == 'CAPABILITY_OWNERSHIP_CONFLICT')
      item.group.capabilities = {}
      state.issues = {}
      assert(CapabilityDefinitions.inspect(tx, item, state, true))
      assert(#state.issues == 1
        and state.issues[1].code == 'CAPABILITY_OWNERSHIP_CONFLICT')
      return state.issues[1].targetRef
    `));
    assert.equal(result, 'groups_group_00000001');
  } finally {
    await engine.global.close();
  }
});

test('group dry-run plans a real domain creation without allocating identifiers or writing', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`${fixture}
      local writes = 0
      function runtime.jsonDecode() return {} end
      local tx = {}
      function tx.one(sql)
        if sql:find('SHA2', 1, true) then return { digest = string.rep('b', 64) } end
        if sql:find('synex_group_types', 1, true) then
          return { id = 7, type_key = 'law_enforcement', status = 'active', hierarchy_enabled = 1 }
        end
        return nil
      end
      function tx.many() return {} end
      function tx.query() writes = writes + 1; return { affectedRows = 1 } end
      function tx.affected() writes = writes + 1; return 1 end
      function tx.insert() writes = writes + 1; return 1 end
      local response = assert(handlers.execute.definitions_sync(tx, {
        schema_version = 1, definitions = {${groupDefinition}}, dry_run = true
      }, runtime, { caller = 'synex_police', callerEpoch = 3 }))
      assert(writes == 0 and sequence == 0)
      assert(response.items[1].change == 'create' and response.items[1].state == 'planned')
      assert(response.items[1].issue_count == 0)
      return #response.items
    `);
    assert.equal(result, 1);
  } finally {
    await engine.global.close();
  }
});

test('unchanged registry definitions do not require a group target or rewrite persistence', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`${fixture}
      local definition = { key = 'police', kind = 'group_type', label = 'Police' }
      function runtime.jsonDecode() return definition end
      local tx = { writes = 0 }
      function tx.one(sql)
        if sql:find('SHA2', 1, true) then return { digest = string.rep('a', 64) } end
        return nil
      end
      function tx.many(sql)
        if sql:find('synex_group_definition_sets', 1, true) then
          return {{
            id = 9, public_id = 'group_definition_00000001',
            definition_key = 'police', target_group_id = nil, schema_version = 1,
            definition_json = 'stored', definition_digest = string.rep('a', 64),
            stored_definition_digest = string.rep('a', 64),
            applied_digest = string.rep('a', 64), applied_definition_json = 'stored',
            applied_snapshot_digest = string.rep('a', 64),
            state = 'applied', version = 4
          }}
        end
        return {}
      end
      function tx.query() tx.writes = tx.writes + 1 end
      function tx.affected() tx.writes = tx.writes + 1 return 1 end
      function tx.insert() tx.writes = tx.writes + 1 return 1 end
      local response = assert(handlers.execute.definitions_sync(tx, {
        schema_version = 1, definitions = { definition }, dry_run = false
      }, runtime, { caller = 'synex_police', callerEpoch = 3 }))
      assert(tx.writes == 0 and response.items[1].change == 'unchanged'
        and response.items[1].version == 4)
      return response.items[1].state
    `);
    assert.equal(result, 'applied');
  } finally {
    await engine.global.close();
  }
});

test('an applied group definition without its stable target is restored rather than accepted unchanged', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`${fixture}
      local definition = ${groupDefinition}
      function runtime.jsonDecode() return definition end
      local tx = { writes = 0 }
      function tx.one(sql)
        if sql:find('SHA2', 1, true) then return { digest = string.rep('a', 64) } end
        if sql:find('synex_group_types', 1, true) then
          return { id = 7, type_key = 'law_enforcement', status = 'active',
            hierarchy_enabled = 1 }
        end
        return nil
      end
      function tx.many(sql)
        if sql:find('synex_group_definition_sets', 1, true) then
          return {{
            id = 9, public_id = 'group_definition_00000001', definition_key = 'lspd',
            target_group_id = nil, schema_version = 1,
            definition_json = 'stored', definition_digest = string.rep('a', 64),
            stored_definition_digest = string.rep('a', 64),
            applied_digest = string.rep('a', 64), applied_definition_json = 'stored',
            applied_snapshot_digest = string.rep('a', 64), state = 'applied', version = 4
          }}
        end
        return {}
      end
      function tx.query() tx.writes = tx.writes + 1 end
      function tx.affected() tx.writes = tx.writes + 1 return 1 end
      function tx.insert() tx.writes = tx.writes + 1 return 1 end
      local response = assert(handlers.execute.definitions_sync(tx, {
        schema_version = 1, definitions = { definition }, dry_run = true
      }, runtime, { caller = 'synex_police', callerEpoch = 3 }))
      assert(tx.writes == 0 and response.items[1].change == 'restore')
      return response.items[1].state
    `);
    assert.equal(result, 'planned');
  } finally {
    await engine.global.close();
  }
});

test('applied group sync creates the canonical organization, profile, grades, roles, and definition target before reporting applied', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`${fixture}
      function runtime.jsonDecode() return {} end
      local requestedDefinition = ${groupDefinition}
      requestedDefinition.capabilities = {{
        capability = 'police.records.read', effect = 'allow', delegable = true
      }}
      requestedDefinition.grades[1].capabilities = {{
        capability = 'police.records.delete', effect = 'deny', scope = 'subtree'
      }}
      requestedDefinition.roles[1].capabilities = {{
        capability = 'police.members.manage', effect = 'allow', scope = 'subtree',
        delegable = true
      }}
      local tx = { writes = {}, nextInternal = 200 }
      function tx.one(sql)
        if sql:find('SHA2', 1, true) then return { digest = string.rep('b', 64) } end
        if sql:find('synex_group_types', 1, true) then
          return { id = 7, type_key = 'law_enforcement', status = 'active', hierarchy_enabled = 1 }
        end
        if sql:find('SELECT', 1, true) and sql:find('synex_groups', 1, true)
          and not sql:find('group_key', 1, true) then
          return { id = 101 }
        end
        if sql:find('SELECT', 1, true) and sql:find('synex_group_grades', 1, true)
          and not sql:find('grade_key', 1, true) then
          return { id = 102 }
        end
        if sql:find('SELECT', 1, true) and sql:find('synex_group_roles', 1, true)
          and not sql:find('role_key', 1, true) then
          return { id = 103 }
        end
        if sql:find('SELECT', 1, true)
          and sql:find('synex_group_grade_capabilities', 1, true) then
          return { id = 104 }
        end
        return nil
      end
      function tx.many() return {} end
      function tx.query(sql, parameters)
        tx.writes[#tx.writes + 1] = { sql = sql, parameters = parameters }
        return { affectedRows = 1 }
      end
      function tx.affected(sql, parameters)
        tx.writes[#tx.writes + 1] = { sql = sql, parameters = parameters }
        return 1
      end
      function tx.insert(sql, parameters)
        tx.writes[#tx.writes + 1] = { sql = sql, parameters = parameters }
        tx.nextInternal = tx.nextInternal + 1
        return tx.nextInternal
      end
      local response, responseError, effects = handlers.execute.definitions_sync(tx, {
        schema_version = 1, definitions = {requestedDefinition}, dry_run = false
      }, runtime, { caller = 'synex_police', callerEpoch = 3 })
      assert(response, responseError and responseError.code or 'sync failed')
      assert(response.items[1].state == 'applied' and response.items[1].group_id ~= nil,
        'definition was not applied')
      assert(#effects == 1 and effects[1].action == 'definition.group.reconciled',
        'effect missing')
      local groupInsert, profileInsert, definitionInsert
      local groupCapability, gradeCapability, gradeScope, roleCapability
      for index, write in ipairs(tx.writes) do
        if write.sql:find('INSERT INTO', 1, true)
          and write.sql:find('synex_groups', 1, true) then groupInsert = index end
        if write.sql:find('INSERT INTO', 1, true)
          and write.sql:find('synex_group_organization_profiles', 1, true) then
          profileInsert = index
          assert(write.parameters[5]:find('group_definition_', 1, true) == 1,
            'profile definition key missing')
          assert(write.parameters[6] == string.rep('b', 64), 'profile digest missing')
        end
        if write.sql:find('INSERT INTO synex_group_definition_sets', 1, true) then definitionInsert = index end
        if write.sql:find('synex_group_default_capabilities', 1, true) then
          groupCapability = true
          assert(write.parameters[4] == 'group' and write.parameters[5] == ''
            and write.parameters[6] == 1)
        end
        if write.sql:find('INSERT INTO', 1, true)
          and write.sql:find('synex_group_grade_capabilities', 1, true) then
          gradeCapability = true
          assert(write.parameters[4] == 0)
        end
        if write.sql:find('INSERT INTO', 1, true)
          and write.sql:find('synex_group_grade_capability_scopes', 1, true) then
          gradeScope = true
          assert(write.parameters[2] == 'custom' and write.parameters[3] == 'subtree')
        end
        if write.sql:find('INSERT INTO', 1, true)
          and write.sql:find('synex_group_role_capabilities', 1, true) then
          roleCapability = true
          assert(write.parameters[4] == 'custom' and write.parameters[5] == 'subtree'
            and write.parameters[6] == 1)
        end
      end
      assert(groupInsert and profileInsert and definitionInsert, 'required insert missing')
      assert(groupCapability and gradeCapability and gradeScope and roleCapability,
        'static capability rules were not reconciled')
      assert(groupInsert < profileInsert and profileInsert < definitionInsert, 'unsafe insert order')
      return response.items[1].version
    `);
    assert.equal(result, 1);
  } finally {
    await engine.global.close();
  }
});

test('unchanged static groups are verified against the live model without rewriting versions', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`${fixture}
      local storedDefinition = ${groupDefinition}
      function runtime.jsonDecode(value)
        if value == 'stored_definition' then return storedDefinition end
        return {}
      end
      local tx = { writes = 0 }
      function tx.one(sql)
        if sql:find('SHA2', 1, true) then return { digest = string.rep('a', 64) } end
        if sql:find('synex_group_types', 1, true) then
          return { id = 7, type_key = 'law_enforcement', status = 'active', hierarchy_enabled = 1 }
        end
        if sql:find('group_record', 1, true) and sql:find('organization_profiles', 1, true) then
          return {
            id = 101, public_id = 'groups_group_00000001', group_key = 'lspd',
            display_name = 'LSPD', group_type = 'law_enforcement', status = 'active',
            metadata_json = '{}', version = 4, group_type_id = 7, slug = 'lspd',
            name = 'Los Santos Police Department', label = 'LSPD', description = nil,
            visibility = 'internal', creation_source = 'static', dynamic = 0,
            lifecycle_state = 'ACTIVE', definition_key = 'group_definition_00000001',
            definition_digest = string.rep('a', 64), profile_metadata_json = '{}',
            profile_version = 4, parent_group_id = nil
          }
        end
        return nil
      end
      function tx.many(sql)
        if sql:find('capabilities', 1, true) then return {} end
        if sql:find('synex_group_definition_sets', 1, true) then
          return {{
            id = 9, public_id = 'group_definition_00000001', definition_key = 'lspd',
            target_group_id = 101, schema_version = 1,
            definition_json = 'stored_definition', definition_digest = string.rep('a', 64),
            stored_definition_digest = string.rep('a', 64),
            applied_digest = string.rep('a', 64), applied_definition_json = 'stored_definition',
            applied_snapshot_digest = string.rep('a', 64),
            state = 'applied', version = 4
          }}
        end
        if sql:find('synex_group_grades', 1, true) then
          return {{ id = 301, public_id = 'groups_grade_00000001', grade_key = 'officer',
            display_name = 'Officer', rank_value = 10, status = 'active', version = 1,
            member_limit = nil, control_version = 1, active_holders = 0 }}
        end
        if sql:find('synex_group_roles', 1, true) then
          return {{ id = 401, public_id = 'groups_role_00000001', role_key = 'supervisor',
            display_name = 'Supervisor', description = nil, exclusivity = 'none',
            holder_limit = nil, status = 'active', version = 1, active_holders = 0 }}
        end
        return {}
      end
      function tx.query() tx.writes = tx.writes + 1; return { affectedRows = 1 } end
      function tx.affected() tx.writes = tx.writes + 1; return 1 end
      function tx.insert() tx.writes = tx.writes + 1; return 1 end
      local response = assert(handlers.execute.definitions_sync(tx, {
        schema_version = 1, definitions = {storedDefinition}, dry_run = false
      }, runtime, { caller = 'synex_police', callerEpoch = 3 }))
      assert(tx.writes == 0 and response.items[1].change == 'unchanged')
      assert(response.items[1].version == 4 and response.items[1].state == 'applied')
      return response.items[1].group_id
    `);
    assert.equal(result, 'groups_group_00000001');
  } finally {
    await engine.global.close();
  }
});

test('a previously blocked definition migration is finalized when the same desired revision reconciles', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`${fixture}
      local appliedDefinition = ${groupDefinition}
      local requestedDefinition = ${groupDefinition}
      requestedDefinition.label = 'LSPD Reconciled'
      function runtime.jsonDecode(value)
        if value == 'applied_definition' then return appliedDefinition end
        if value == 'desired_definition' then return requestedDefinition end
        return {}
      end
      local tx = { writes = {} }
      function tx.one(sql)
        if sql:find('SHA2', 1, true) then return { digest = string.rep('b', 64) } end
        if sql:find('synex_group_types', 1, true) then
          return { id = 7, type_key = 'law_enforcement', status = 'active', hierarchy_enabled = 1 }
        end
        if sql:find('group_record', 1, true) and sql:find('organization_profiles', 1, true) then
          return {
            id = 101, public_id = 'groups_group_00000001', group_key = 'lspd',
            display_name = 'LSPD', group_type = 'law_enforcement', status = 'active',
            metadata_json = '{}', version = 4, group_type_id = 7, slug = 'lspd',
            name = 'Los Santos Police Department', label = 'LSPD', visibility = 'internal',
            creation_source = 'static', dynamic = 0, lifecycle_state = 'ACTIVE',
            definition_key = 'group_definition_00000001',
            definition_digest = string.rep('a', 64), profile_metadata_json = '{}',
            profile_version = 4, parent_group_id = nil
          }
        end
        return nil
      end
      function tx.many(sql)
        if sql:find('capabilities', 1, true) then return {} end
        if sql:find('synex_group_definition_sets', 1, true) then
          return {{
            id = 9, public_id = 'group_definition_00000001', definition_key = 'lspd',
            target_group_id = 101, schema_version = 2,
            definition_json = 'desired_definition', definition_digest = string.rep('b', 64),
            stored_definition_digest = string.rep('b', 64),
            applied_digest = string.rep('a', 64), applied_definition_json = 'applied_definition',
            applied_snapshot_digest = string.rep('a', 64),
            state = 'drifted', version = 5
          }}
        end
        if sql:find('synex_group_grades', 1, true) then
          return {{ id = 301, public_id = 'groups_grade_00000001', grade_key = 'officer',
            display_name = 'Officer', rank_value = 10, status = 'active', version = 1,
            control_version = 1, active_holders = 0 }}
        end
        if sql:find('synex_group_roles', 1, true) then
          return {{ id = 401, public_id = 'groups_role_00000001', role_key = 'supervisor',
            display_name = 'Supervisor', description = nil, exclusivity = 'none',
            status = 'active', version = 1, active_holders = 0 }}
        end
        return {}
      end
      function tx.query(sql, parameters)
        tx.writes[#tx.writes + 1] = { sql = sql, parameters = parameters }
        return { affectedRows = 1 }
      end
      function tx.affected(sql, parameters)
        tx.writes[#tx.writes + 1] = { sql = sql, parameters = parameters }
        return 1
      end
      function tx.insert() error('restore must not allocate a definition row') end
      local response = assert(handlers.execute.definitions_sync(tx, {
        schema_version = 2, definitions = {requestedDefinition}, dry_run = false
      }, runtime, { caller = 'synex_police', callerEpoch = 3 }))
      assert(response.items[1].change == 'restore'
        and response.items[1].state == 'applied' and response.items[1].version == 6)
      local finalized = false
      for _, write in ipairs(tx.writes) do
        if write.sql:find('UPDATE synex_group_definition_migrations', 1, true) then
          finalized = write.sql:find("state = 'applied'", 1, true) ~= nil
        end
      end
      assert(finalized, 'blocked definition migration was not finalized')
      return response.items[1].group_id
    `);
    assert.equal(result, 'groups_group_00000001');
  } finally {
    await engine.global.close();
  }
});

test('removing an applied grade records drift and a blocked migration without mutating the live group model', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`${fixture}
      local appliedDefinition = ${groupDefinition}
      appliedDefinition.grades[2] = {
        key = 'sergeant', label = 'Sergeant', rank = 20, capacity = 4, status = 'active'
      }
      local requestedDefinition = ${groupDefinition}
      function runtime.jsonDecode(value)
        if value == 'applied_definition' then return appliedDefinition end
        if value == 'desired_definition' then return requestedDefinition end
        return {}
      end
      local tx = { writes = {} }
      function tx.one(sql)
        if sql:find('SHA2', 1, true) then return { digest = string.rep('b', 64) } end
        if sql:find('synex_group_types', 1, true) then
          return { id = 7, type_key = 'law_enforcement', status = 'active', hierarchy_enabled = 1 }
        end
        if sql:find('group_record', 1, true) and sql:find('organization_profiles', 1, true) then
          return {
            id = 101, public_id = 'groups_group_00000001', group_key = 'lspd',
            display_name = 'LSPD', group_type = 'law_enforcement', status = 'active',
            metadata_json = '{}', version = 4, group_type_id = 7, slug = 'lspd',
            name = 'Los Santos Police Department', label = 'LSPD', visibility = 'internal',
            creation_source = 'static', dynamic = 0, lifecycle_state = 'ACTIVE',
            definition_key = 'group_definition_00000001',
            definition_digest = string.rep('a', 64), profile_metadata_json = '{}',
            profile_version = 4
          }
        end
        return nil
      end
      function tx.many(sql)
        if sql:find('capabilities', 1, true) then return {} end
        if sql:find('synex_group_definition_sets', 1, true) then
          return {{
            id = 9, public_id = 'group_definition_00000001', definition_key = 'lspd',
            target_group_id = 101, schema_version = 1,
            definition_json = 'desired_definition', definition_digest = string.rep('a', 64),
            stored_definition_digest = string.rep('a', 64),
            applied_digest = string.rep('a', 64), applied_definition_json = 'applied_definition',
            applied_snapshot_digest = string.rep('a', 64),
            state = 'applied', version = 4
          }}
        end
        if sql:find('synex_group_grades', 1, true) then
          return {
            { id = 301, public_id = 'groups_grade_00000001', grade_key = 'officer',
              display_name = 'Officer', rank_value = 10, status = 'active', version = 1,
              control_version = 1, active_holders = 1 },
            { id = 302, public_id = 'groups_grade_00000002', grade_key = 'sergeant',
              display_name = 'Sergeant', rank_value = 20, status = 'active', version = 1,
              member_limit = 4, control_version = 1, active_holders = 2 }
          }
        end
        if sql:find('synex_group_roles', 1, true) then return {} end
        return {}
      end
      function tx.query(sql, parameters)
        tx.writes[#tx.writes + 1] = { sql = sql, parameters = parameters }
        return { affectedRows = 1 }
      end
      function tx.affected(sql, parameters)
        tx.writes[#tx.writes + 1] = { sql = sql, parameters = parameters }
        return 1
      end
      function tx.insert(sql, parameters)
        tx.writes[#tx.writes + 1] = { sql = sql, parameters = parameters }
        return 500
      end
      local response = assert(handlers.execute.definitions_sync(tx, {
        schema_version = 2, definitions = {requestedDefinition}, dry_run = false
      }, runtime, { caller = 'synex_police', callerEpoch = 3 }))
      assert(response.items[1].state == 'drifted' and response.items[1].issue_count == 1)
      local definitionUpdated, issueWritten, migrationBlocked = false, false, false
      for _, write in ipairs(tx.writes) do
        assert(not (write.sql:find('UPDATE', 1, true) and write.sql:find('synex_groups', 1, true)))
        assert(not (write.sql:find('UPDATE', 1, true)
          and write.sql:find('synex_group_grades', 1, true)))
        if write.sql:find('UPDATE synex_group_definition_sets', 1, true) then
          definitionUpdated = true
          assert(write.sql:find('ELSE applied_definition_json', 1, true))
        end
        if write.sql:find('synex_group_definition_issues', 1, true) then issueWritten = true end
        if write.sql:find("'blocked'", 1, true)
          and write.sql:find('synex_group_definition_migrations', 1, true) then
          migrationBlocked = true
        end
      end
      assert(definitionUpdated and issueWritten and migrationBlocked)
      return response.items[1].version
    `);
    assert.equal(result, 5);
  } finally {
    await engine.global.close();
  }
});

test('reference-free grade removal retires the same grade identity idempotently and re-add reactivates it', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`${fixture}
      local previous = assert(Groups.normalize(${groupDefinition}))
      previous.grades[2] = {
        key = 'sergeant', label = 'Sergeant', rank = 20,
        capacity = 4, status = 'active', capabilities = {}
      }
      local desired = assert(Groups.normalize(${groupDefinition}))
      local groupVersion, profileVersion = 4, 4
      local retiredStatus, retiredVersion, retiredControlVersion = 'active', 1, 1
      local retiredNonterminal, retiredInvitations, retiredProposals = 0, 0, 0
      local writes = {}
      local tx = {}
      function tx.one(sql)
        if sql:find('synex_group_types', 1, true) then
          return { id = 7, type_key = 'law_enforcement', status = 'active',
            hierarchy_enabled = 1 }
        end
        if sql:find('organization_profiles', 1, true) then
          return {
            id = 101, public_id = 'groups_group_00000001', group_key = 'lspd',
            display_name = 'LSPD', group_type = 'law_enforcement', status = 'active',
            metadata_json = '{}', version = groupVersion,
            group_type_id = 7, slug = 'lspd', name = 'Los Santos Police Department',
            label = 'LSPD', visibility = 'internal', creation_source = 'static',
            dynamic = 0, lifecycle_state = 'ACTIVE',
            definition_key = 'group_definition_00000001',
            definition_digest = 'desired_digest',
            profile_metadata_json = '{}',
            profile_version = profileVersion, parent_group_id = nil
          }
        end
        return nil
      end
      function tx.many(sql)
        if sql:find('synex_group_grades', 1, true)
            and sql:find('active_holders', 1, true) then
          return {
            { id = 301, public_id = 'groups_grade_00000001', grade_key = 'officer',
              display_name = 'Officer', rank_value = 10, status = 'active',
              version = 1, control_version = 1, active_holders = 1,
              nonterminal_holders = 1, pending_invitations = 0,
              pending_grade_proposals = 0 },
            { id = 302, public_id = 'groups_grade_00000002', grade_key = 'sergeant',
              display_name = 'Sergeant', rank_value = 20, status = retiredStatus,
              version = retiredVersion, control_version = retiredControlVersion,
              member_limit = retiredStatus == 'active' and 4 or nil,
              active_holders = retiredNonterminal,
              nonterminal_holders = retiredNonterminal,
              pending_invitations = retiredInvitations,
              pending_grade_proposals = retiredProposals }
          }
        end
        if sql:find('synex_group_roles', 1, true)
            and sql:find('active_holders', 1, true) then
          return {{ id = 401, public_id = 'groups_role_00000001',
            role_key = 'supervisor', display_name = 'Supervisor', description = nil,
            exclusivity = 'none', holder_limit = nil, status = 'active',
            version = 1, active_holders = 0 }}
        end
        return {}
      end
      function tx.query(sql, parameters)
        writes[#writes + 1] = { sql = sql, parameters = parameters }
        return { affectedRows = 1 }
      end
      function tx.affected(sql, parameters)
        writes[#writes + 1] = { sql = sql, parameters = parameters }
        return 1
      end

      local item = {
        key = 'lspd', publicId = 'group_definition_00000001',
        digest = 'desired_digest', change = 'update', existing = { target_group_id = 101 },
        group = desired, previousGroup = previous
      }
      for blocker = 1, 3 do
        retiredNonterminal = blocker == 1 and 1 or 0
        retiredInvitations = blocker == 2 and 1 or 0
        retiredProposals = blocker == 3 and 1 or 0
        local blocked = Groups.inspect(tx, item, runtime, false)
        assert(#blocked.issues == 1, 'unexpected blocker issue count ' .. blocker)
        assert(blocked.issues[1].code == 'GRADE_REMOVAL_REQUIRES_MIGRATION',
          'unexpected blocker issue code ' .. blocker)
        assert(blocked.retiredGrades == nil, 'blocked grade was scheduled for retirement')
      end
      retiredNonterminal, retiredInvitations, retiredProposals = 0, 0, 0
      local state = Groups.inspect(tx, item, runtime, false)
      assert(#state.issues == 0 and #state.retiredGrades == 1,
        'reference-free grade was not scheduled exactly once')
      local reconciled, reconcileError = Groups.reconcile(tx, item, runtime, nil)
      assert(reconciled and reconcileError == nil,
        'reference-free reconciliation failed: ' .. tostring(
          reconcileError and reconcileError.code or reconcileError) .. ' / ' .. tostring(
          reconcileError and reconcileError.message or ''))
      local gradeDisabled, controlRetired = false, false
      for _, write in ipairs(writes) do
        if write.sql:find('UPDATE \`synex_group_grades\`', 1, true)
            and write.sql:find("\`status\` = 'disabled'", 1, true) then
          gradeDisabled = write.parameters[1] == 302 and write.parameters[2] == 1
        end
        if write.sql:find('UPDATE \`synex_group_grade_controls\`', 1, true)
            and write.sql:find('promotion_requires_approval', 1, true) then
          controlRetired = write.parameters[1] == 302 and write.parameters[2] == 1
        end
      end
      assert(gradeDisabled and controlRetired, 'grade/control retirement CAS was incomplete')

      retiredStatus, retiredVersion, retiredControlVersion = 'disabled', 2, 2
      groupVersion, profileVersion = 5, 5
      item.previousGroup, item.change = desired, 'unchanged'
      local repeated = Groups.inspect(tx, item, runtime, false)
      assert(#repeated.issues == 0 and repeated.needsWrite == false,
        'retirement replay was not a no-op: issues=' .. tostring(#repeated.issues)
          .. ', needs_write=' .. tostring(repeated.needsWrite)
          .. ', retired=' .. tostring(repeated.retiredGrades and #repeated.retiredGrades or 0))
      assert(repeated.retiredGrades == nil, 'retirement replay scheduled another write')

      local readded = assert(Groups.normalize(${groupDefinition}))
      readded.grades[2] = previous.grades[2]
      item.group, item.previousGroup, item.change = readded, desired, 'update'
      local reactivation = Groups.inspect(tx, item, runtime, false)
      assert(#reactivation.issues == 0 and reactivation.needsWrite == true,
        'disabled grade could not be re-added')
      local same = reactivation.grades.sergeant
      assert(same.public_id == 'groups_grade_00000002' and same.status == 'disabled',
        're-add did not preserve the grade identity')
      writes = {}
      assert(Groups.reconcile(tx, item, runtime, nil))
      local reactivatedSameIdentity = false
      for _, write in ipairs(writes) do
        if write.sql:find('UPDATE \`synex_group_grades\`', 1, true)
            and write.sql:find('\`display_name\` = ?', 1, true)
            and write.parameters[3] == 'active' and write.parameters[4] == 302
            and write.parameters[5] == 2 then
          reactivatedSameIdentity = true
        end
      end
      assert(reactivatedSameIdentity, 're-add did not reactivate the existing grade row')
      return true
    `);
    assert.equal(result, true);
  } finally {
    await engine.global.close();
  }
});
