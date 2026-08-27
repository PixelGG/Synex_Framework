import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory, type LuaEngine } from 'wasmoon';

const root = process.cwd();
const organizationModules = [
  'governance_shared',
  'governance_capability_rules',
  'organizations_shared',
  'organizations_read',
  'organizations_creation',
  'organizations_lifecycle',
  'organizations_creation_approvals',
  'organizations_types',
  'extension_registries',
  'organizations_structure',
  'organizations',
] as const;

async function readOrganizationSource(): Promise<string> {
  return (await Promise.all(organizationModules.map((name) => readFile(path.join(
    root,
    'resources',
    'synex_groups',
    'server',
    'persistence',
    `${name}.lua`,
  ), 'utf8')))).join('\n');
}

async function bootstrap(engine: LuaEngine): Promise<void> {
  const foundation = await readFile(
    path.join(root, 'resources', 'synex_groups', 'server', 'foundation.lua'),
    'utf8',
  );
  for (const name of ['constants', 'lifecycle']) {
    const relativePath = `resources/synex_groups/server/domain/${name}.lua`;
    const source = await readFile(path.join(root, relativePath), 'utf8');
    await engine.doString(
      `package.preload[${JSON.stringify(`server.domain.${name}`)}] = assert(load(${JSON.stringify(source)}, ${JSON.stringify(`@${relativePath}`)}))`,
    );
  }
  const validationPath = 'resources/synex_groups/server/validation.lua';
  const validation = await readFile(path.join(root, validationPath), 'utf8');
  await engine.doString(
    `package.preload['server.validation'] = assert(load(${JSON.stringify(validation)}, '@${validationPath}'))`,
  );
  for (const name of organizationModules) {
    const relativePath = `resources/synex_groups/server/persistence/${name}.lua`;
    const source = await readFile(path.join(root, relativePath), 'utf8');
    await engine.doString(
      `package.preload[${JSON.stringify(`server.persistence.${name}`)}] = assert(load(${JSON.stringify(source)}, ${JSON.stringify(`@${relativePath}`)}))`,
    );
  }
  await engine.doString(`
    Foundation = assert(load(${JSON.stringify(foundation)}, '@server/foundation.lua'))()
    Validation = require('server.validation')(Foundation)
    Organizations = require('server.persistence.organizations')(Foundation)

    function testJsonEncode(value)
      local kind = type(value)
      if kind == 'nil' then return 'null' end
      if kind == 'boolean' or kind == 'number' then return tostring(value) end
      if kind == 'string' then
        assert(value:match('^[A-Za-z0-9_.:%-]+$'))
        return '"' .. value .. '"'
      end
      error('testJsonEncode only receives canonical scalar fragments')
    end

    function testRuntime(overrides)
      overrides = overrides or {}
      local allocated = 0
      local runtime
      runtime = {
        caller = overrides.caller or 'synex_groups',
        allocated = {},
        authorizations = {},
        corePermissionChecks = {},
        registryMutations = {},
        activationEnforcements = {},
        id = function(namespace)
          allocated = allocated + 1
          runtime.allocated[#runtime.allocated + 1] = namespace
          return namespace .. '_' .. string.format('%08d', allocated)
        end,
        authorize = function(tx, groupId, actorId, capability, scope, policyContext)
          runtime.authorizations[#runtime.authorizations + 1] = {
            groupId = groupId, actorId = actorId, capability = capability,
            scope = scope, policyContext = policyContext
          }
          if overrides.authorize then
            return overrides.authorize(groupId, actorId, capability, scope, policyContext)
          end
          return true
        end,
        checkCorePermission = function(characterId, permission)
          runtime.corePermissionChecks[#runtime.corePermissionChecks + 1] = {
            characterId = characterId, permission = permission
          }
          if overrides.checkCorePermission then
            return overrides.checkCorePermission(characterId, permission)
          end
          return true, nil
        end,
        requireGroup = function(_, groupId)
          return {
            id = 10, public_id = groupId, status = 'active',
            lifecycle_state = 'ACTIVE', version = 2
          }, nil
        end,
        touchGroup = function() return true, nil end,
        enforceMembershipActivation = function(tx, membership, passedRuntime)
          assert(type(tx) == 'table' and passedRuntime == runtime)
          runtime.activationEnforcements[#runtime.activationEnforcements + 1] = membership
          if overrides.enforceMembershipActivation then
            return overrides.enforceMembershipActivation(membership)
          end
          return true, nil
        end,
        resolveApprovedOperation = function(context, operation, request, groupId)
          if overrides.resolveApprovedOperation then
            return overrides.resolveApprovedOperation(context, operation, request, groupId)
          end
          return nil, nil
        end,
        success = function(entityId, entityType, status, version)
          return {
            entity_id = entityId, entity_type = entityType, status = status,
            version = version, replayed = false
          }
        end,
        effect = function(action, entityType, entityId, groupId, characterId,
            before, after, reason)
          return {
            action = action, entityType = entityType, entityId = entityId,
            groupId = groupId, characterId = characterId,
            before = before, after = after, reason = reason
          }
        end,
        reason = function(_, fallback) return fallback end,
        deferRegistry = function(context, registry, owner, epoch, generation, key, value)
          assert(context.caller == owner and context.callerEpoch == epoch
            and generation == 1)
          runtime.registryMutations[#runtime.registryMutations + 1] = {
            registry = registry, owner = owner, epoch = epoch,
            generation = generation, key = key, value = value
          }
          return true, nil
        end,
        requireRegistryOwnerSession = function(_, owner, epoch)
          assert(type(owner) == 'string' and type(epoch) == 'number' and epoch >= 1)
          return { ownerEpoch = epoch, generation = 1 }, nil
        end,
        jsonEncode = testJsonEncode,
        jsonDecode = function(encoded)
          if encoded == '{}' then return {} end
          if encoded == '{"tier":"gold"}' then return { tier = 'gold' } end
          error('unexpected test JSON: ' .. tostring(encoded))
        end
      }
      return runtime
    end
  `);
}

test('organization persistence is a pure parameterized handler catalog with bounded Core namespaces', async () => {
  const source = await readOrganizationSource();
  assert.doesNotMatch(
    source,
    /\bMySQL\b|oxmysql|RegisterNetEvent|RegisterServerEvent|TriggerClientEvent|PerformHttpRequest/u,
  );
  assert.doesNotMatch(source, /:format\s*\(\s*request\./u);
  assert.match(source, /FOR UPDATE/u);
  assert.match(source, /AND `version` = \?/u);
  const namespaces = [...source.matchAll(/checkedId\(runtime, '([^']+)'\)/gu)]
    .map((match) => match[1]);
  assert.ok(namespaces.length >= 6);
  for (const namespace of namespaces) {
    assert.ok(namespace && namespace.length <= 32, namespace);
    assert.match(namespace, /^[a-z][a-z0-9_]*$/u);
  }

  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`
      local expectedRead = { get = true, list = true }
      local expectedExecute = {
        create = true, update = true, archive = true,
        creation_requests_approve = true, creation_requests_reject = true,
        types_register = true,
        relation_types_register = true, duty_states_register = true,
        relationships_create = true, relationships_update = true,
        grades_create = true, grades_update = true,
        roles_create = true, roles_update = true, capabilities_set = true
      }
      for name in pairs(expectedRead) do assert(type(Organizations.read[name]) == 'function') end
      for name in pairs(expectedExecute) do assert(type(Organizations.execute[name]) == 'function') end
      return 'catalog-ok'
    `);
    assert.equal(result, 'catalog-ok');
  } finally {
    engine.global.close();
  }
});

test('get and cursor list expose contract-shaped metadata and bind every filter', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`
      local listParameters
      local rows = {
        {
          group_public_id = 'group_00000001', type_key = 'business',
          parent_public_id = 'group_parent001', slug = 'alpha', name = 'Alpha LLC',
          label = 'Alpha', description = 'Private description', status = 'active',
          lifecycle_state = 'ACTIVE',
          visibility = 'internal', dynamic = 1, version = 4,
          created_at = '2026-08-25T01:02:03.000000Z',
          updated_at = '2026-08-25T02:03:04.000000Z'
        },
        {
          group_public_id = 'group_00000002', type_key = 'business',
          parent_public_id = 'group_parent001', slug = 'beta', name = 'Beta LLC',
          label = 'Beta', status = 'active', lifecycle_state = 'ACTIVE',
          visibility = 'internal', dynamic = 1,
          version = 1, created_at = '2026-08-25T01:02:03.000000Z',
          updated_at = '2026-08-25T02:03:04.000000Z'
        }
      }
      local tx = {
        one = function(sql, parameters)
          assert(sql:find('DATE_FORMAT', 1, true))
          assert(parameters[1] == 'group_00000001')
          return rows[1]
        end,
        many = function(sql, parameters)
          assert(sql:find('type_key', 1, true))
          assert(sql:find('lifecycle_state', 1, true))
          assert(sql:find('parent', 1, true))
          assert(sql:find('public_id', 1, true))
          listParameters = parameters
          return rows
        end
      }
      local runtime = testRuntime()
      local detail = assert(Organizations.read.get(tx, { group_id = 'group_00000001' }, runtime))
      assert(detail.group_id == 'group_00000001' and detail.type == 'business')
      assert(detail.name == 'Alpha LLC' and detail.label == 'Alpha')
      assert(detail.description == 'Private description' and detail.dynamic == true)
      assert(detail.version == 4 and #detail.created_at >= 19)
      local listed = assert(Organizations.read.list(tx, {
        type = 'business', status = 'active', parent_group_id = 'group_parent001',
        cursor = 'group_00000000', limit = 1
      }, runtime))
      assert(#listed.items == 1 and listed.items[1].description == nil)
      assert(listed.truncated == true and listed.next_cursor == 'group_00000001')
      assert(listParameters[1] == 'business' and listParameters[2] == 'ACTIVE')
      assert(listParameters[3] == 'group_parent001')
      assert(listParameters[4] == 'group_00000000' and listParameters[5] == 2)
      return table.concat({ detail.group_id, listed.next_cursor, tostring(listed.truncated) }, ':')
    `);
    assert.equal(result, 'group_00000001:group_00000001:true');
  } finally {
    engine.global.close();
  }
});

test('create atomically bootstraps hierarchy, owner grade, wildcard authority, and founder membership', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`
      local writes = {}
      local tx = {}
      tx.one = function(sql, parameters)
        if sql:find('FROM \`synex_group_types\`', 1, true) then
          return {
            id = 3, type_key = 'business', creation_mode = 'dynamic',
            dynamic_creation = 1, create_permission = 'synex.groups.create.business',
            membership_limit = 25, active_membership_limit = 10,
            hierarchy_enabled = 1, status = 'active', version = 1
          }
        end
        if sql:find('synex_group_type_membership_states', 1, true) then
          return { state_key = 'ACTIVE' }
        end
        if sql:find('WHERE \`group_key\` = ?', 1, true) then return nil end
        if sql:find('active_slug', 1, true) then return nil end
        if sql:find('FROM \`synex_groups\` WHERE \`public_id\`', 1, true) then return { id = 10 } end
        if sql:find('FROM \`synex_group_grades\`', 1, true) then return { id = 20 } end
        if sql:find('FROM \`synex_group_grade_capabilities\`', 1, true) then return { id = 30 } end
        if sql:find('FROM \`synex_group_memberships\`', 1, true) then return { id = 40 } end
        error('unexpected one query: ' .. sql)
      end
      tx.many = function() return {} end
      tx.query = function(sql, parameters)
        writes[#writes + 1] = { sql = sql, parameters = parameters }
        return { affectedRows = 1 }
      end
      local runtime = testRuntime()
      local value, failure, effects = Organizations.execute.create(tx, {
        actor_character_id = 'character_00000001', type = 'business', slug = 'alpha',
        name = 'Alpha LLC', label = 'Alpha', description = 'Founding organization',
        visibility = 'private', dynamic = true, metadata = { tier = 'gold' }
      }, runtime)
      assert(failure == nil and value.entity_type == 'group' and value.status == 'active')
      assert(value.version == 1 and value.replayed == false and #effects == 2)
      -- The public service applies the Core resource-capability gate before this
      -- handler; no group-scoped authority exists until founder bootstrap commits.
      assert(#runtime.authorizations == 0)
      assert(#runtime.activationEnforcements == 1)
      assert(runtime.activationEnforcements[1].id == 40)
      assert(runtime.activationEnforcements[1].group_id == 10)
      assert(runtime.activationEnforcements[1].character_id == 'character_00000001')
      local found = { profile = false, owner = false, capability = false,
        member = false, memberProfile = false, memberGrade = false,
        memberEvent = false, readModel = false }
      for _, write in ipairs(writes) do
        if write.sql:find('synex_group_organization_profiles', 1, true) then
          found.profile = write.sql:find('\`name\`', 1, true) ~= nil
            and write.sql:find('\`metadata_json\`', 1, true) ~= nil
        end
        if write.sql:find('INSERT INTO \`synex_group_grades\`', 1, true) then
          found.owner = write.sql:find('32767', 1, true) ~= nil
            and write.sql:find("'owner'", 1, true) ~= nil
        end
        if write.sql:find('INSERT INTO \`synex_group_grade_capabilities\`', 1, true) then
          found.capability = write.sql:find('synex.groups.*', 1, true) ~= nil
        end
        if write.sql:find('INSERT INTO \`synex_group_memberships\`', 1, true) then
          found.member = write.parameters[3] == 'character_00000001'
        end
        if write.sql:find('INSERT INTO \`synex_group_membership_profiles\`', 1, true) then
          found.memberProfile = write.sql:find("'ACTIVE'", 1, true) ~= nil
        end
        if write.sql:find('INSERT INTO \`synex_group_membership_grades\`', 1, true) then
          found.memberGrade = true
        end
        if write.sql:find('INSERT INTO \`synex_group_membership_events\`', 1, true) then
          found.memberEvent = true
        end
        if write.sql:find('INSERT INTO \`synex_group_read_model_versions\`', 1, true) then
          found.readModel = true
        end
      end
      for name, present in pairs(found) do assert(present == true, name) end
      local namespaces = table.concat(runtime.allocated, ',')
      assert(namespaces == 'groups_group,groups_grade,groups_member,groups_event')
      assert(effects[1].action == 'group.created' and effects[1].groupId == value.entity_id)
      assert(effects[1].after.founder_membership_id ~= nil)
      assert(effects[2].action == 'membership.activated')
      assert(effects[2].entityId == effects[1].after.founder_membership_id)
      assert(effects[2].groupId == value.entity_id)
      return table.concat({ value.entity_type, value.status, #writes, namespaces }, ':')
    `);
    assert.match(result, /^group:active:\d+:groups_group,groups_grade,groups_member,groups_event$/u);
  } finally {
    engine.global.close();
  }
});

test('create obeys the registered dynamic-creation and ACTIVE-membership policies', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`
      local writes = 0
      local typeDefinition = {
        id = 3, type_key = 'business', creation_mode = 'legacy', dynamic_creation = 0,
        create_permission = 'synex.groups.create.business', membership_limit = 5,
        active_membership_limit = 3, hierarchy_enabled = 1, status = 'active', version = 1
      }
      local tx = {
        one = function(sql)
          if sql:find('FROM \`synex_group_types\`', 1, true) then return typeDefinition end
          if sql:find('synex_group_type_membership_states', 1, true) then return nil end
          error('unexpected policy query: ' .. sql)
        end,
        many = function() return {} end,
        query = function() writes = writes + 1 return { affectedRows = 1 } end
      }
      local request = {
        actor_character_id = 'character_00000001', type = 'business',
        slug = 'alpha', name = 'Alpha', label = 'Alpha', dynamic = true
      }
      local _, creationError = Organizations.execute.create(tx, request, testRuntime())
      assert(creationError.code == 'GROUP_TYPE_STATIC' and writes == 0)

      typeDefinition.creation_mode = 'dynamic'
      typeDefinition.dynamic_creation = 1
      local _, stateError = Organizations.execute.create(tx, request, testRuntime())
      assert(stateError.code == 'INVALID_TRANSITION' and writes == 0)
      return creationError.code .. ':' .. stateError.code
    `);
    assert.equal(result, 'GROUP_TYPE_STATIC:INVALID_TRANSITION');
  } finally {
    engine.global.close();
  }
});

test('dynamic type policy validation is closed and creation materializes presets without weakening owner recovery', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`
      local validPolicy = {
        idempotency_key = 'type-policy-0001', type = 'company', schema_version = 1,
        label = 'Company', max_members = 100, max_active_members = 50,
        create_permission = 'synex.groups.create.company',
        default_grades = { { key = 'member', label = 'Member', rank = 0 } },
        default_roles = { { key = 'recruiter', label = 'Recruiter', exclusive = true } }
      }
      assert(Validation.operation('types_register', validPolicy))
      local invalidLimit = Foundation.copyPlain(validPolicy)
      invalidLimit.max_active_members = 101
      local _, limitError = Validation.operation('types_register', invalidLimit)
      assert(limitError.code == 'VALIDATION_FAILED')
      local invalidPermission = Foundation.copyPlain(validPolicy)
      invalidPermission.create_permission = 'synex.groups.create.migration_pending'
      local _, permissionError = Validation.operation('types_register', invalidPermission)
      assert(permissionError.code == 'VALIDATION_FAILED')
      local invalidOwner = Foundation.copyPlain(validPolicy)
      invalidOwner.default_grades = { { key = 'owner', label = 'Owner', rank = 1 } }
      local _, ownerError = Validation.operation('types_register', invalidOwner)
      assert(ownerError.code == 'VALIDATION_FAILED')
      local duplicateRole = Foundation.copyPlain(validPolicy)
      duplicateRole.default_roles = {
        { key = 'member', label = 'Member' }, { key = 'member', label = 'Duplicate' }
      }
      local _, duplicateError = Validation.operation('types_register', duplicateRole)
      assert(duplicateError.code == 'VALIDATION_FAILED')

      local writes = {}
      local tx = {}
      tx.one = function(sql, parameters)
        if sql:find('FROM \`synex_group_types\`', 1, true) then
          return { id = 3, type_key = 'company', creation_mode = 'dynamic',
            dynamic_creation = 1, create_permission = 'synex.groups.create.company',
            membership_limit = 100, active_membership_limit = 50,
            hierarchy_enabled = 1, status = 'active', version = 1 }
        end
        if sql:find('synex_group_type_membership_states', 1, true) then
          return { state_key = 'ACTIVE' }
        end
        if sql:find('WHERE \`group_key\` = ?', 1, true) then return nil end
        if sql:find('active_slug', 1, true) then return nil end
        if sql:find('FROM \`synex_groups\` WHERE \`public_id\`', 1, true) then
          return { id = 10 }
        end
        if sql:find('FROM \`synex_group_grades\`', 1, true) then
          if parameters[1] == 'groups_grade_00000004' then return { id = 20 } end
          if parameters[1] == 'groups_grade_00000001' then return { id = 21 } end
        end
        if sql:find('FROM \`synex_group_grade_capabilities\`', 1, true) then
          return { id = 30 }
        end
        if sql:find('FROM \`synex_group_memberships\`', 1, true) then return { id = 40 } end
        error('unexpected preset create query: ' .. sql)
      end
      tx.many = function(sql)
        if sql:find('synex_group_type_default_grades', 1, true) then
          return { { grade_key = 'member', display_name = 'Member', rank_value = 0,
            member_limit = 80, sort_order = 0 } }
        end
        if sql:find('synex_group_type_default_roles', 1, true) then
          return { { role_key = 'recruiter', display_name = 'Recruiter',
            description = 'Recruitment', assignable = 1, exclusive = 1,
            holder_limit = 5, sort_order = 0 } }
        end
        error('unexpected preset list query: ' .. sql)
      end
      tx.query = function(sql, parameters)
        writes[#writes + 1] = { sql = sql, parameters = parameters }
        return { affectedRows = 1 }
      end
      local runtime = testRuntime({
        checkCorePermission = function(characterId, permission)
          assert(characterId == 'character_00000001')
          assert(permission == 'synex.groups.create.company')
          return true, nil
        end
      })
      local created, createError, effects = Organizations.execute.create(tx, {
        actor_character_id = 'character_00000001', type = 'company',
        slug = 'acme', name = 'ACME', label = 'ACME'
      }, runtime)
      assert(createError == nil and created.status == 'active' and #effects == 2)
      assert(#runtime.corePermissionChecks == 1)
      assert(effects[1].after.default_grade_count == 1)
      assert(effects[1].after.default_role_count == 1)
      local ownerGrade, presetGrade, ownerCapability, presetRole, founderGrade
      for _, write in ipairs(writes) do
        if write.sql:find('INSERT INTO \`synex_group_grades\`', 1, true) then
          if write.sql:find("'owner'", 1, true) then ownerGrade = write
          elseif write.parameters[3] == 'member' then presetGrade = write end
        elseif write.sql:find('synex_group_grade_capabilities', 1, true) then
          ownerCapability = write
        elseif write.sql:find('INSERT INTO \`synex_group_roles\`', 1, true) then
          presetRole = write
        elseif write.sql:find('INSERT INTO \`synex_group_membership_grades\`', 1, true) then
          founderGrade = write
        end
      end
      assert(ownerGrade and ownerGrade.sql:find('32767', 1, true))
      assert(ownerCapability and ownerCapability.sql:find('synex.groups.*', 1, true))
      assert(presetGrade and presetGrade.parameters[5] == 0)
      assert(presetRole and presetRole.parameters[6] == 'group'
        and presetRole.parameters[7] == 5 and presetRole.parameters[8] == 'active')
      assert(founderGrade and founderGrade.parameters[2] == 20)
      assert(table.concat(runtime.allocated, ',') ==
        'groups_grade,groups_role,groups_group,groups_grade,groups_member,groups_event')
      return table.concat({ limitError.code, permissionError.code, ownerError.code,
        duplicateError.code, created.status, effects[1].after.default_grade_count,
        effects[1].after.default_role_count }, ':')
    `);
    assert.equal(
      result,
      'VALIDATION_FAILED:VALIDATION_FAILED:VALIDATION_FAILED:VALIDATION_FAILED:active:1:1',
    );
  } finally {
    engine.global.close();
  }
});

test('create checks parent depth before writes and update fails closed on versions, authorization, cycles, and CAS', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`
      local writeCount = 0
      local createTx = {
        one = function(sql)
          if sql:find('FROM \`synex_group_types\`', 1, true) then
            return { id = 3, type_key = 'business', creation_mode = 'dynamic', dynamic_creation = 1,
              create_permission = 'synex.groups.create.business', membership_limit = 5,
              active_membership_limit = 3,
              hierarchy_enabled = 1, status = 'active', version = 1 }
          end
          if sql:find('synex_group_type_membership_states', 1, true) then
            return { state_key = 'ACTIVE' }
          end
          if sql:find('WHERE \`group_key\` = ?', 1, true) then return nil end
          if sql:find('active_slug', 1, true) then return nil end
          if sql:find('profile\`.\`lifecycle_state', 1, true) then
            return { id = 9, public_id = 'group_parent001', status = 'active', lifecycle_state = 'ACTIVE' }
          end
          error('unexpected create query: ' .. sql)
        end,
        many = function(sql)
          if sql:find('synex_group_hierarchy_closure', 1, true) then
            return { { ancestor_group_id = 1, depth = 64 } }
          end
          if sql:find('synex_group_type_default_', 1, true) then return {} end
          error('unexpected create list query: ' .. sql)
        end,
        query = function() writeCount = writeCount + 1 return { affectedRows = 1 } end
      }
      local _, depthError = Organizations.execute.create(createTx, {
        actor_character_id = 'character_00000001', type = 'business',
        parent_group_id = 'group_parent001', slug = 'child', name = 'Child', label = 'Child'
      }, testRuntime())
      assert(depthError.code == 'HIERARCHY_DEPTH_EXCEEDED' and writeCount == 0)

      local function groupRow()
        return {
          id = 10, group_public_id = 'group_00000001', group_key = 'alpha',
          display_name = 'Alpha', status = 'active', metadata_json = '{}', version = 4,
          group_type_id = 3, slug = 'alpha', name = 'Alpha LLC', label = 'Alpha',
          description = nil, dynamic = 1, profile_metadata_json = '{}', visibility = 'internal',
          creation_source = 'dynamic', lifecycle_state = 'ACTIVE', profile_version = 4,
          type_key = 'business', hierarchy_enabled = 1, relationships_enabled = 1
        }
      end
      local noWrite = { query = function() error('must not write') end, many = function() return {} end }
      noWrite.one = function(sql)
        if sql:find('type_record', 1, true) then return groupRow() end
        return nil
      end
      local runtime = testRuntime()
      local _, versionError = Organizations.execute.update(noWrite, {
        actor_character_id = 'character_00000001', group_id = 'group_00000001',
        expected_version = 3, label = 'Changed'
      }, runtime)
      assert(versionError.code == 'CONCURRENT_MODIFICATION' and #runtime.authorizations == 1)

      local deniedRuntime = testRuntime({
        authorize = function() return nil, Foundation.domainError('INSUFFICIENT_PERMISSION', 'denied') end
      })
      local _, denied = Organizations.execute.update(noWrite, {
        actor_character_id = 'character_00000001', group_id = 'group_00000001',
        expected_version = 4, label = 'Changed'
      }, deniedRuntime)
      assert(denied.code == 'INSUFFICIENT_PERMISSION')

      local cycleTx = { many = function() return {} end, query = function() error('must not write') end }
      cycleTx.one = function(sql)
        if sql:find('type_record', 1, true) then return groupRow() end
        if sql:find('synex_group_hierarchy_edges', 1, true) then return nil end
        if sql:find('profile\`.\`lifecycle_state', 1, true) then
          return { id = 20, status = 'active', lifecycle_state = 'ACTIVE' }
        end
        if sql:find('creates_cycle', 1, true) then return { creates_cycle = 1 } end
        error('unexpected cycle query: ' .. sql)
      end
      local _, cycle = Organizations.execute.update(cycleTx, {
        actor_character_id = 'character_00000001', group_id = 'group_00000001',
        expected_version = 4, parent_group_id = 'group_descendant1'
      }, testRuntime())
      assert(cycle.code == 'HIERARCHY_CYCLE')

      local casWrites = 0
      local casTx = { many = function() return {} end }
      casTx.one = function(sql)
        if sql:find('type_record', 1, true) then return groupRow() end
        if sql:find('synex_group_hierarchy_edges', 1, true) then return nil end
        return nil
      end
      casTx.query = function(sql)
        casWrites = casWrites + 1
        if sql:find('UPDATE \`synex_groups\`', 1, true) then return { affectedRows = 0 } end
        return { affectedRows = 1 }
      end
      local _, cas = Organizations.execute.update(casTx, {
        actor_character_id = 'character_00000001', group_id = 'group_00000001',
        expected_version = 4, label = 'Changed'
      }, testRuntime())
      assert(cas.code == 'CONCURRENT_MODIFICATION' and cas.retryable == true and casWrites == 2)
      return table.concat({ depthError.code, versionError.code, denied.code, cycle.code, cas.code }, ':')
    `);
    assert.equal(
      result,
      'HIERARCHY_DEPTH_EXCEEDED:CONCURRENT_MODIFICATION:INSUFFICIENT_PERMISSION:HIERARCHY_CYCLE:CONCURRENT_MODIFICATION',
    );
  } finally {
    engine.global.close();
  }
});

test('group suspension closes duty atomically while resume requires Core break-glass authority', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`
      local updateRequest = {
        idempotency_key = 'group-status-0001',
        actor_character_id = 'character_00000001', group_id = 'group_00000001',
        expected_version = 4, status = 'SUSPENDED'
      }
      assert(Validation.operation('update', updateRequest))
      updateRequest.status = 'ARCHIVED'
      local _, statusValidation = Validation.operation('update', updateRequest)
      assert(statusValidation.code == 'VALIDATION_FAILED')

      local function groupRow(status, lifecycle, version)
        return {
          id = 10, group_public_id = 'group_00000001', group_key = 'alpha',
          display_name = 'Alpha', status = status, metadata_json = '{}', version = version,
          group_type_id = 3, slug = 'alpha', name = 'Alpha LLC', label = 'Alpha',
          description = nil, dynamic = 1, profile_metadata_json = '{}', visibility = 'internal',
          creation_source = 'dynamic', lifecycle_state = lifecycle, profile_version = version,
          type_key = 'business', hierarchy_enabled = 1, relationships_enabled = 1
        }
      end

      local suspendWrites = {}
      local suspendTx = { many = function() return {} end }
      suspendTx.one = function(sql)
        if sql:find('type_record', 1, true) then return groupRow('active', 'ACTIVE', 4) end
        if sql:find('synex_group_hierarchy_edges', 1, true) then return nil end
        error('unexpected suspend query: ' .. sql)
      end
      suspendTx.query = function(sql, parameters)
        suspendWrites[#suspendWrites + 1] = { sql = sql, parameters = parameters }
        if sql:find('INSERT INTO', 1, true)
            and sql:find('synex_group_duty_events', 1, true) then
          return { affectedRows = 2 }
        end
        if sql:find('UPDATE', 1, true)
            and sql:find('synex_group_duty_sessions', 1, true) then
          return { affectedRows = 2 }
        end
        return { affectedRows = 1 }
      end
      local suspendRuntime = testRuntime({
        checkCorePermission = function() error('suspension must use group authority') end
      })
      local suspended, suspendError, suspendEffects = Organizations.execute.update(suspendTx, {
        actor_character_id = 'character_00000001', group_id = 'group_00000001',
        expected_version = 4, status = 'SUSPENDED', reason = 'operator_suspend'
      }, suspendRuntime)
      assert(suspendError == nil and suspended.status == 'suspended' and suspended.version == 5)
      assert(#suspendRuntime.authorizations == 1 and #suspendRuntime.corePermissionChecks == 0)
      assert(#suspendEffects == 1 and suspendEffects[1].action == 'group.suspended')
      assert(suspendEffects[1].after.closed_duty_sessions == 2)
      assert(suspendWrites[1].sql:find('synex_group_duty_events', 1, true))
      assert(suspendWrites[2].sql:find('synex_group_duty_sessions', 1, true))
      assert(suspendWrites[3].parameters[1] == 'suspended')
      assert(suspendWrites[4].parameters[1] == 'SUSPENDED')

      local resumeWrites = {}
      local resumeTx = { many = function() return {} end }
      resumeTx.one = function(sql)
        if sql:find('type_record', 1, true) then return groupRow('suspended', 'SUSPENDED', 5) end
        if sql:find('synex_group_hierarchy_edges', 1, true) then return nil end
        error('unexpected resume query: ' .. sql)
      end
      resumeTx.query = function(sql, parameters)
        resumeWrites[#resumeWrites + 1] = { sql = sql, parameters = parameters }
        return { affectedRows = 1 }
      end
      local resumeRuntime = testRuntime({
        authorize = function() error('suspended group authority must remain unavailable') end,
        checkCorePermission = function(characterId, permission)
          assert(characterId == 'character_00000001' and permission == 'synex.groups.update')
          return true, nil
        end
      })
      local resumed, resumeError, resumeEffects = Organizations.execute.update(resumeTx, {
        actor_character_id = 'character_00000001', group_id = 'group_00000001',
        expected_version = 5, status = 'ACTIVE', reason = 'operator_resume'
      }, resumeRuntime)
      assert(resumeError == nil and resumed.status == 'active' and resumed.version == 6)
      assert(#resumeRuntime.authorizations == 0 and #resumeRuntime.corePermissionChecks == 1)
      assert(#resumeEffects == 1 and resumeEffects[1].action == 'group.resumed')
      assert(resumeWrites[1].parameters[1] == 'active')
      assert(resumeWrites[2].parameters[1] == 'ACTIVE')

      local deniedWrites = 0
      local deniedTx = { many = function() return {} end,
        query = function() deniedWrites = deniedWrites + 1 return { affectedRows = 1 } end }
      deniedTx.one = resumeTx.one
      local deniedRuntime = testRuntime({
        authorize = function() error('suspended group authority must remain unavailable') end,
        checkCorePermission = function()
          return nil, Foundation.domainError('INSUFFICIENT_PERMISSION', 'Core denied resume')
        end
      })
      local _, denied = Organizations.execute.update(deniedTx, {
        actor_character_id = 'character_00000001', group_id = 'group_00000001',
        expected_version = 5, status = 'active'
      }, deniedRuntime)
      assert(denied.code == 'INSUFFICIENT_PERMISSION' and deniedWrites == 0)
      assert(#deniedRuntime.authorizations == 0 and #deniedRuntime.corePermissionChecks == 1)
      local controlledTx = { many = function() return {} end,
        query = function() error('invalid lifecycle requests must not write') end }
      controlledTx.one = function(sql)
        if sql:find('type_record', 1, true) then return groupRow('active', 'ACTIVE', 4) end
        error('unexpected controlled-lifecycle query: ' .. sql)
      end
      local _, archivedThroughUpdate = Organizations.execute.update(controlledTx, {
        actor_character_id = 'character_00000001', group_id = 'group_00000001',
        expected_version = 4, status = 'ARCHIVED'
      }, testRuntime())
      assert(archivedThroughUpdate.code == 'INVALID_TRANSITION')
      local _, unsupported = Organizations.execute.update(controlledTx, {
        actor_character_id = 'character_00000001', group_id = 'group_00000001',
        expected_version = 4, status = 'DISSOLVING'
      }, testRuntime())
      assert(unsupported.code == 'INVALID_TRANSITION')
      local _, suspendedEdit = Organizations.execute.update({
        many = function() return {} end, one = resumeTx.one,
        query = function() error('suspended edits must not write') end
      }, {
        actor_character_id = 'character_00000001', group_id = 'group_00000001',
        expected_version = 5, label = 'Bypass'
      }, testRuntime())
      assert(suspendedEdit.code == 'GROUP_INACTIVE')
      return table.concat({ suspended.status, suspendEffects[1].action,
        resumed.status, resumeEffects[1].action, denied.code,
        archivedThroughUpdate.code, unsupported.code, suspendedEdit.code }, ':')
    `);
    assert.equal(
      result,
      'suspended:group.suspended:active:group.resumed:INSUFFICIENT_PERMISSION:INVALID_TRANSITION:INVALID_TRANSITION:GROUP_INACTIVE',
    );
  } finally {
    engine.global.close();
  }
});

test('type registration persists owner, schema metadata, and allowed membership and duty states', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`
      local writes = {}
      local tx = {
        one = function(sql, parameters)
          if sql:find('synex_group_membership_states', 1, true) then
            return { state_key = parameters[1] }
          end
          if sql:find('synex_group_duty_states', 1, true) then
            return { state_key = parameters[1] }
          end
          if sql:find('FROM \`synex_group_types\` WHERE \`type_key\`', 1, true) then return nil end
          if sql:find('SELECT \`id\` FROM \`synex_group_types\`', 1, true) then return { id = 77 } end
          error('unexpected type query: ' .. sql)
        end,
        many = function() return {} end,
        query = function(sql, parameters)
          writes[#writes + 1] = { sql = sql, parameters = parameters }
          return { affectedRows = 1 }
        end
      }
      local runtime = testRuntime()
      local value, failure, effects = Organizations.execute.types_register(tx, {
        type = 'company', schema_version = 3, label = 'Company',
        dynamic_creation = true, max_members = 100000, max_active_members = 90000,
        create_permission = 'synex.groups.create.company',
        required_approvals = 2,
        approval_permission = 'synex.groups.create.approve.company',
        default_grades = {
          { key = 'member', label = 'Member', rank = 0 },
          { key = 'manager', label = 'Manager', rank = 100, capacity = 8 }
        },
        default_roles = {
          { key = 'recruiter', label = 'Recruiter', description = 'Recruitment',
            assignable = true, exclusive = false, capacity = 4 }
        },
        allowed_membership_states = { 'DRAFT', 'ACTIVE' },
        allowed_duty_states = { 'on_duty' }, metadata = { tier = 'gold' }
      }, runtime, { caller = 'synex_businesses', callerEpoch = 7 })
      assert(failure == nil and value.entity_type == 'group_type' and value.version == 1)
      assert(#effects == 1 and #runtime.authorizations == 0)
      assert(effects[1].action == 'type.registered' and effects[1].groupId == nil)
      local typeInsert, membershipCount, dutyCount, defaultGradeCount, defaultRoleCount
      membershipCount, dutyCount, defaultGradeCount, defaultRoleCount = 0, 0, 0, 0
      for _, write in ipairs(writes) do
        if write.sql:find('INSERT INTO \`synex_group_types\`', 1, true) then typeInsert = write end
        if write.sql:find('INSERT INTO \`synex_group_type_membership_states\`', 1, true) then
          membershipCount = membershipCount + 1
        end
        if write.sql:find('INSERT INTO \`synex_group_type_duty_states\`', 1, true) then
          dutyCount = dutyCount + 1
        end
        if write.sql:find('INSERT INTO \`synex_group_type_default_grades\`', 1, true) then
          defaultGradeCount = defaultGradeCount + 1
        end
        if write.sql:find('INSERT INTO \`synex_group_type_default_roles\`', 1, true) then
          defaultRoleCount = defaultRoleCount + 1
        end
      end
      assert(typeInsert and typeInsert.sql:find('\`schema_version\`', 1, true))
      assert(typeInsert.sql:find('\`metadata_json\`', 1, true))
      assert(typeInsert.sql:find('\`active_membership_limit\`', 1, true))
      assert(typeInsert.sql:find('\`create_permission\`', 1, true))
      assert(typeInsert.parameters[3] == 'synex_businesses' and typeInsert.parameters[4] == 7)
      assert(typeInsert.parameters[8] == 'synex.groups.create.company')
      assert(typeInsert.parameters[9] == 2)
      assert(typeInsert.parameters[10] == 'synex.groups.create.approve.company')
      assert(typeInsert.parameters[11] == 100000 and typeInsert.parameters[12] == 90000)
      assert(typeInsert.parameters[14] == '{"tier":"gold"}')
      assert(runtime.registryMutations[1].key == 'group_type:company')
      assert(runtime.registryMutations[1].value.maxMembers == 100000)
      assert(runtime.registryMutations[1].value.maxActiveMembers == 90000)
      assert(runtime.registryMutations[1].value.createPermission == 'synex.groups.create.company')
      assert(runtime.registryMutations[1].value.requiredApprovals == 2)
      assert(runtime.registryMutations[1].value.approvalPermission ==
        'synex.groups.create.approve.company')
      assert(membershipCount == 2 and dutyCount == 1)
      assert(defaultGradeCount == 2 and defaultRoleCount == 1)
      return table.concat({ value.entity_type, value.version, membershipCount, dutyCount,
        defaultGradeCount, defaultRoleCount }, ':')
    `);
    assert.equal(result, 'group_type:1:2:1:2:1');
  } finally {
    engine.global.close();
  }
});

test('type registration and archive use optimistic concurrency and active-child safeguards', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`
      local tx = {}
      tx.one = function(sql, parameters)
        if sql:find('synex_group_membership_states', 1, true) then return { state_key = parameters[1] } end
        if sql:find('synex_group_duty_states', 1, true) then return { state_key = parameters[1] } end
        if sql:find('FROM \`synex_group_types\` WHERE \`type_key\`', 1, true) then
          return {
            id = 7, public_id = 'groups_type_00000001', owner_resource = 'synex_groups',
            owner_epoch = 3,
            display_name = 'Company', creation_mode = 'dynamic', dynamic_creation = 1,
            membership_limit = 50, schema_version = 2, metadata_json = '{}',
            status = 'active', version = 5
          }
        end
        error('unexpected type one: ' .. sql)
      end
      tx.many = function(sql)
        if sql:find('membership_states', 1, true) then return { { state_key = 'ACTIVE' } } end
        if sql:find('duty_states', 1, true) then return { { state_key = 'on_duty' } } end
        return {}
      end
      tx.query = function(sql)
        if sql:find('UPDATE \`synex_group_types\`', 1, true) then return { affectedRows = 0 } end
        return { affectedRows = 1 }
      end
      local _, typeError = Organizations.execute.types_register(tx, {
        type = 'company', schema_version = 3, label = 'Company', dynamic_creation = true,
        max_members = 50, allowed_membership_states = { 'ACTIVE' },
        allowed_duty_states = { 'on_duty' }
      }, testRuntime(), { caller = 'synex_groups', callerEpoch = 3 })
      assert(typeError.code == 'CONCURRENT_MODIFICATION' and typeError.retryable == true)

      local archiveWrites = 0
      local archiveTx = { many = function() return {} end,
        query = function() archiveWrites = archiveWrites + 1 return { affectedRows = 1 } end }
      archiveTx.one = function(sql)
        if sql:find('type_record', 1, true) then
          return {
            id = 10, group_public_id = 'group_00000001', status = 'active', version = 2,
            profile_version = 2, group_type_id = 1, type_key = 'business',
            hierarchy_enabled = 1, relationships_enabled = 1,
            slug = 'parent', name = 'Parent', label = 'Parent', dynamic = 1,
            visibility = 'internal', lifecycle_state = 'ACTIVE', metadata_json = '{}'
          }
        end
        if sql:find('child\`.\`public_id', 1, true) then return { public_id = 'group_child0001' } end
        error('unexpected archive one: ' .. sql)
      end
      local _, archiveError = Organizations.execute.archive(archiveTx, {
        actor_character_id = 'character_00000001', group_id = 'group_00000001',
        expected_version = 2, reason = 'still_has_child'
      }, testRuntime())
      assert(archiveError.code == 'GROUP_HAS_ACTIVE_CHILDREN' and archiveWrites == 0)
      return typeError.code .. ':' .. archiveError.code
    `);
    assert.equal(result, 'CONCURRENT_MODIFICATION:GROUP_HAS_ACTIVE_CHILDREN');
  } finally {
    engine.global.close();
  }
});

test('proposal-driven archive excludes only its executing proposal from workflow blockers', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`
      local function groupRow()
        return {
          id = 10, group_public_id = 'group_00000001', status = 'active', version = 2,
          profile_version = 2, group_type_id = 1, type_key = 'business',
          hierarchy_enabled = 1, relationships_enabled = 1,
          slug = 'parent', name = 'Parent', label = 'Parent', dynamic = 1,
          visibility = 'internal', lifecycle_state = 'ACTIVE', metadata_json = '{}'
        }
      end

      local writes, proposalQuerySeen = 0, false
      local approvedTx = { many = function() return {} end }
      approvedTx.one = function(sql, parameters)
        if sql:find('type_record', 1, true) then return groupRow() end
        if sql:find("SELECT 'proposal' AS blocker", 1, true) then
          proposalQuerySeen = true
          assert(sql:find('public_id <> ?', 1, true))
          assert(parameters[1] == 10 and parameters[2] == 'proposal_approved_0001')
        end
        return nil
      end
      approvedTx.query = function()
        writes = writes + 1
        return { affectedRows = 1 }
      end
      local approvedRuntime = testRuntime({
        resolveApprovedOperation = function(_, operation, request, groupId)
          assert(operation == 'archive' and request.group_id == groupId)
          return { proposalId = 'proposal_approved_0001' }, nil
        end
      })
      local archived, archiveError = Organizations.execute.archive(approvedTx, {
        actor_character_id = 'character_00000001', group_id = 'group_00000001',
        expected_version = 2, reason = 'approved_archive'
      }, approvedRuntime, { internal = true })
      assert(archiveError == nil and archived.status == 'archived')
      assert(proposalQuerySeen and writes == 3)

      local blockedWrites = 0
      local blockedTx = { many = function() return {} end }
      blockedTx.one = function(sql, parameters)
        if sql:find('type_record', 1, true) then return groupRow() end
        if sql:find("SELECT 'proposal' AS blocker", 1, true) then
          assert(parameters[2] == 'proposal_approved_0001')
          return { blocker = 'proposal', public_id = 'proposal_other_0002' }
        end
        return nil
      end
      blockedTx.query = function()
        blockedWrites = blockedWrites + 1
        return { affectedRows = 1 }
      end
      local _, blocked = Organizations.execute.archive(blockedTx, {
        actor_character_id = 'character_00000001', group_id = 'group_00000001',
        expected_version = 2, reason = 'approved_archive'
      }, approvedRuntime, { internal = true })
      assert(blocked.code == 'GROUP_HAS_ACTIVE_WORKFLOWS' and blockedWrites == 0)
      assert(blocked.details.entity_id == 'proposal_other_0002')
      return archived.status .. ':' .. blocked.code
    `);
    assert.equal(result, 'archived:GROUP_HAS_ACTIVE_WORKFLOWS');
  } finally {
    engine.global.close();
  }
});

test('archive ignores workflow pre-states and banned history but blocks joined members and open workflows', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`
      local function groupRow()
        return {
          id = 10, group_public_id = 'group_00000001', status = 'active', version = 2,
          profile_version = 2, group_type_id = 1, type_key = 'business',
          hierarchy_enabled = 1, relationships_enabled = 1,
          slug = 'archive-candidate', name = 'Archive candidate',
          label = 'Archive candidate', dynamic = 1, visibility = 'internal',
          lifecycle_state = 'ACTIVE', metadata_json = '{}'
        }
      end
      local function run(mode)
        local writes, membershipQuerySeen = 0, false
        local tx = { many = function() return {} end }
        tx.one = function(sql)
          if sql:find('type_record', 1, true) then return groupRow() end
          if sql:find('FROM synex_group_memberships AS membership', 1, true) then
            membershipQuerySeen = true
            assert(sql:find("'PROBATION', 'ACTIVE', 'SUSPENDED', 'LEAVE', 'INACTIVE'", 1, true))
            assert(not sql:find("'DRAFT'", 1, true) and not sql:find("'BANNED'", 1, true))
            if mode == 'active' then
              return { public_id = 'membership_active_0001' }
            end
            return nil
          end
          if sql:find("SELECT 'invitation' AS blocker", 1, true)
              and mode == 'invitation' then
            return { blocker = 'invitation', public_id = 'invitation_open_0001' }
          end
          return nil
        end
        tx.query = function()
          writes = writes + 1
          return { affectedRows = 1 }
        end
        local value, failure = Organizations.execute.archive(tx, {
          actor_character_id = 'character_00000001', group_id = 'group_00000001',
          expected_version = 2, reason = 'archive_regression'
        }, testRuntime())
        assert(membershipQuerySeen)
        return value, failure, writes
      end

      local draft, draftError, draftWrites = run('draft')
      assert(draftError == nil and draft.status == 'archived' and draftWrites == 3)
      local banned, bannedError, bannedWrites = run('banned')
      assert(bannedError == nil and banned.status == 'archived' and bannedWrites == 3)
      local active, activeError, activeWrites = run('active')
      assert(active == nil and activeError.code == 'GROUP_HAS_ACTIVE_MEMBERS'
        and activeWrites == 0)
      local invitation, invitationError, invitationWrites = run('invitation')
      assert(invitation == nil and invitationError.code == 'GROUP_HAS_ACTIVE_WORKFLOWS'
        and invitationError.details.entity_type == 'invitation' and invitationWrites == 0)
      return table.concat({ draft.status, banned.status, activeError.code,
        invitationError.code }, ':')
    `);
    assert.equal(
      result,
      'archived:archived:GROUP_HAS_ACTIVE_MEMBERS:GROUP_HAS_ACTIVE_WORKFLOWS',
    );
  } finally {
    engine.global.close();
  }
});

test('symmetric relationship ownership stays with the authorized source and rejects reverse duplicates', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`
      local writes = {}
      local tx = {}
      tx.many = function()
        return {
          { id = 1, public_id = 'group_alpha0001', status = 'active',
            lifecycle_state = 'ACTIVE', relationships_enabled = 1 },
          { id = 2, public_id = 'group_zulu00001', status = 'active',
            lifecycle_state = 'ACTIVE', relationships_enabled = 1 }
        }
      end
      tx.one = function(sql, parameters)
        if sql:find('synex_group_relation_types', 1, true) then
          return { id = 8, type_key = 'ally_of', direction = 'symmetric', status = 'active' }
        end
        if sql:find('synex_group_relationships', 1, true) then
          assert(sql:find('OR', 1, true) and #parameters == 5)
          assert(parameters[2] == 2 and parameters[3] == 1
            and parameters[4] == 1 and parameters[5] == 2)
          return nil
        end
        error('unexpected relationship query: ' .. sql)
      end
      tx.query = function(sql, parameters)
        writes[#writes + 1] = { sql = sql, parameters = parameters }
        return { affectedRows = 1 }
      end
      local runtime = testRuntime()
      local value, failure, effects = Organizations.execute.relationships_create(tx, {
        actor_character_id = 'character_00000001', source_group_id = 'group_zulu00001',
        target_group_id = 'group_alpha0001', relation_type = 'ally_of', metadata = { tier = 'gold' }
      }, runtime)
      assert(failure == nil and value.entity_type == 'relationship' and value.version == 1)
      assert(runtime.authorizations[1].groupId == 'group_zulu00001')
      assert(runtime.authorizations[1].scope == 'group')
      assert(runtime.authorizations[1].policyContext.kind == 'relationship'
        and runtime.authorizations[1].policyContext.target_group_id == 'group_alpha0001')
      assert(effects[1].after.source_group_id == 'group_zulu00001')
      assert(effects[1].after.target_group_id == 'group_alpha0001')
      local relationshipInsert
      for _, write in ipairs(writes) do
        if write.sql:find('INSERT INTO \`synex_group_relationships\`', 1, true) then
          relationshipInsert = write
        end
      end
      assert(relationshipInsert and relationshipInsert.sql:find('\`metadata_json\`', 1, true))
      assert(relationshipInsert.parameters[9] == '{"tier":"gold"}')
      assert(relationshipInsert.parameters[3] == 2 and relationshipInsert.parameters[4] == 1)

      local updateRuntime = testRuntime()
      local updateTx = {}
      updateTx.one = function(sql)
        if sql:find('AS \`relationship\`', 1, true) then
          return {
            id = 71, public_id = value.entity_id,
            source_group_id = 2, target_group_id = 1,
            source_public_id = 'group_zulu00001',
            target_public_id = 'group_alpha0001',
            type_key = 'ally_of', status = 'active',
            valid_from = '2026-08-25 10:00:00.000000', version = 1
          }
        end
        error('unexpected relationship update query: ' .. sql)
      end
      updateTx.query = function() return { affectedRows = 1 } end
      local changed, changeError = Organizations.execute.relationships_update(updateTx, {
        actor_character_id = 'character_00000001', relationship_id = value.entity_id,
        expected_version = 1, status = 'suspended', reason = 'mutual_review'
      }, updateRuntime)
      assert(changeError == nil and changed.status == 'suspended')
      assert(updateRuntime.authorizations[1].groupId == 'group_zulu00001')

      local cycleWrites = 0
      local cycleTx = {
        many = tx.many,
        query = function() cycleWrites = cycleWrites + 1 return { affectedRows = 1 } end
      }
      cycleTx.one = function(sql)
        if sql:find('synex_group_relation_types', 1, true) then
          return { id = 9, type_key = 'subsidiary_of', direction = 'directed', status = 'active' }
        end
        if sql:find('WITH RECURSIVE', 1, true) then return { group_id = 2, depth = 2 } end
        if sql:find('synex_group_relationships', 1, true) then return nil end
        error('unexpected cycle query: ' .. sql)
      end
      local _, cycleError = Organizations.execute.relationships_create(cycleTx, {
        actor_character_id = 'character_00000001', source_group_id = 'group_zulu00001',
        target_group_id = 'group_alpha0001', relation_type = 'subsidiary_of'
      }, testRuntime())
      assert(cycleError.code == 'RELATIONSHIP_CYCLE' and cycleWrites == 0)

      local oversizedRuntime = testRuntime()
      oversizedRuntime.jsonEncode = function() return string.rep('x', 16385) end
      local writesBeforeOversized = #writes
      local oversized, oversizedError = Organizations.execute.relationships_create(tx, {
        actor_character_id = 'character_00000001', source_group_id = 'group_zulu00001',
        target_group_id = 'group_alpha0001', relation_type = 'ally_of',
        metadata = { payload = 'bounded_at_persistence' }
      }, oversizedRuntime)
      assert(oversized == nil and oversizedError.code == 'VALIDATION_FAILED'
        and #writes == writesBeforeOversized)
      return value.entity_type .. ':' .. effects[1].after.source_group_id .. ':'
        .. changed.status .. ':' .. cycleError.code .. ':' .. oversizedError.code
    `);
    assert.equal(
      result,
      'relationship:group_zulu00001:suspended:RELATIONSHIP_CYCLE:VALIDATION_FAILED',
    );
  } finally {
    engine.global.close();
  }
});

test('grade and role handlers enforce authorization, capacity, exclusivity, and output shapes', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`
      local function groupRow()
        return {
          id = 10, group_public_id = 'group_00000001', status = 'active', version = 2,
          profile_version = 2, group_type_id = 1, type_key = 'business',
          hierarchy_enabled = 1, relationships_enabled = 1, slug = 'alpha',
          name = 'Alpha', label = 'Alpha', dynamic = 1, visibility = 'internal',
          lifecycle_state = 'ACTIVE', metadata_json = '{}'
        }
      end
      local writes = {}
      local createTx = { many = function() return {} end }
      createTx.one = function(sql)
        if sql:find('type_record', 1, true) then return groupRow() end
        if sql:find('grade_key', 1, true) then return nil end
        if sql:find('WHERE \`public_id\` = ?', 1, true) then return { id = 31 } end
        error('unexpected grade create query: ' .. sql)
      end
      createTx.query = function(sql, parameters)
        writes[#writes + 1] = { sql = sql, parameters = parameters }
        return { affectedRows = 1 }
      end
      local runtime = testRuntime({
        authorize = function()
          -- Production returns the authorized, locked membership rather than a boolean.
          return { id = 91, public_id = 'groups_member_00000001' }
        end
      })
      local grade = assert(Organizations.execute.grades_create(createTx, {
        actor_character_id = 'character_00000001', group_id = 'group_00000001',
        key = 'manager', label = 'Manager', rank = 100, capacity = 2
      }, runtime))
      assert(grade.entity_type == 'grade' and grade.status == 'active' and grade.version == 1)
      assert(runtime.authorizations[1].capability == 'synex.groups.grades.manage')

      local gradeWrites = 0
      local gradeTx = { many = function() return {} end,
        query = function() gradeWrites = gradeWrites + 1 return { affectedRows = 1 } end }
      gradeTx.one = function(sql)
        if sql:find('FROM \`synex_group_grades\` AS \`grade\`', 1, true) then
          return {
            id = 31, public_id = 'groups_grade_00000001', group_id = 10,
            display_name = 'Manager', rank_value = 100, status = 'active', version = 3,
            member_limit = 3, control_version = 3, group_public_id = 'group_00000001',
            group_status = 'active'
          }
        end
        if sql:find('active_holders', 1, true) then return { active_holders = 2 } end
        error('unexpected grade update query: ' .. sql)
      end
      local _, gradeError = Organizations.execute.grades_update(gradeTx, {
        actor_character_id = 'character_00000001', grade_id = 'groups_grade_00000001',
        expected_version = 3, capacity = 1
      }, testRuntime())
      assert(gradeError.code == 'GRADE_CAPACITY_REACHED' and gradeWrites == 0)

      local roleTx = { many = function() return {} end,
        query = function() error('must not write') end }
      roleTx.one = function(sql)
        if sql:find('FROM \`synex_group_roles\` AS \`role\`', 1, true) then
          return {
            id = 41, public_id = 'groups_role_00000001', group_id = 10,
            display_name = 'Supervisor', description = nil, exclusivity = 'none',
            holder_limit = nil, status = 'active', version = 4,
            group_public_id = 'group_00000001', group_status = 'active'
          }
        end
        if sql:find('active_holders', 1, true) then return { active_holders = 2 } end
        error('unexpected role query: ' .. sql)
      end
      local _, roleError = Organizations.execute.roles_update(roleTx, {
        actor_character_id = 'character_00000001', role_id = 'groups_role_00000001',
        expected_version = 4, exclusive = true
      }, testRuntime())
      assert(roleError.code == 'ROLE_EXCLUSIVE_CONFLICT')
      return table.concat({ grade.entity_type, gradeError.code, roleError.code }, ':')
    `);
    assert.equal(result, 'grade:GRADE_CAPACITY_REACHED:ROLE_EXCLUSIVE_CONFLICT');
  } finally {
    engine.global.close();
  }
});

test('capability set persists deny-wins-ready scoped rules and requires CAS for replacements', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`
      local function groupRow()
        return {
          id = 10, group_public_id = 'group_00000001', status = 'active', version = 2,
          profile_version = 2, group_type_id = 1, type_key = 'business',
          hierarchy_enabled = 1, relationships_enabled = 1, slug = 'alpha',
          name = 'Alpha', label = 'Alpha', dynamic = 1, visibility = 'internal',
          lifecycle_state = 'ACTIVE', metadata_json = '{}'
        }
      end
      local writes = {}
      local tx = { many = function() return {} end }
      tx.one = function(sql)
        if sql:find('FROM synex_group_grades', 1, true) then
          return { id = 31, public_id = 'groups_grade_00000001', group_id = 10,
            status = 'active', version = 2 }
        end
        if sql:find('FROM synex_group_grade_capabilities AS capability', 1, true) then return nil end
        if sql:find('SELECT id FROM synex_group_grade_capabilities', 1, true) then
          return { id = 51 }
        end
        error('unexpected capability query: ' .. sql)
      end
      tx.query = function(sql, parameters)
        writes[#writes + 1] = { sql = sql, parameters = parameters }
        return { affectedRows = 1 }
      end
      tx.affected = function(sql, parameters)
        local result = tx.query(sql, parameters)
        return result.affectedRows
      end
      local runtime = testRuntime()
      local value, failure, effects = Organizations.execute.capabilities_set(tx, {
        actor_character_id = 'character_00000001', group_id = 'group_00000001',
        source_type = 'grade', source_id = 'groups_grade_00000001',
        capability = 'synex.groups.members.*', effect = 'deny'
      }, runtime)
      assert(failure == nil and value.entity_id == 'groups_grade_00000001')
      assert(value.entity_type == 'capability' and value.status == 'deny' and value.version == 1)
      assert(runtime.authorizations[1].capability == 'synex.groups.capabilities.manage')
      local scopeInserted = false
      for _, write in ipairs(writes) do
        if write.sql:find('INSERT INTO synex_group_grade_capability_scopes', 1, true) then
          scopeInserted = write.parameters[2] == 'group' and write.parameters[3] == ''
        end
      end
      assert(scopeInserted and effects[1].after.effect == 'deny')

      local existingTx = { many = function() return {} end, query = function() error('must not write') end }
      existingTx.one = function(sql)
        if sql:find('FROM synex_group_grades', 1, true) then
          return { id = 31, public_id = 'groups_grade_00000001', group_id = 10,
            status = 'active', version = 2 }
        end
        if sql:find('FROM synex_group_grade_capabilities AS capability', 1, true) then
          return { id = 51, effect = 'allow', version = 3,
            scope_kind = 'group', scope_ref = '', scope_version = 3 }
        end
        error('unexpected existing capability query: ' .. sql)
      end
      local _, expectedError = Organizations.execute.capabilities_set(existingTx, {
        actor_character_id = 'character_00000001', group_id = 'group_00000001',
        source_type = 'grade', source_id = 'groups_grade_00000001',
        capability = 'synex.groups.members.*', effect = 'deny'
      }, testRuntime())
      assert(expectedError.code == 'CONCURRENT_MODIFICATION')
      return table.concat({ value.entity_type, value.status, expectedError.code }, ':')
    `);
    assert.equal(result, 'capability:deny:CONCURRENT_MODIFICATION');
  } finally {
    engine.global.close();
  }
});
