import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory, type LuaEngine } from 'wasmoon';

const root = process.cwd();

async function createEngine(): Promise<LuaEngine> {
  const [foundationSource, sharedSource, valuesSource, attributesSource, activationSource]
    = await Promise.all([
    readFile(path.join(root, 'resources/synex_groups/server/foundation.lua'), 'utf8'),
    readFile(path.join(
      root,
      'resources/synex_groups/server/persistence/governance_shared.lua',
    ), 'utf8'),
    readFile(path.join(
      root,
      'resources/synex_groups/server/persistence/governance_attribute_values.lua',
    ), 'utf8'),
    readFile(path.join(
      root,
      'resources/synex_groups/server/persistence/governance_attributes.lua',
    ), 'utf8'),
    readFile(path.join(
      root,
      'resources/synex_groups/server/persistence/governance_attribute_activation.lua',
    ), 'utf8'),
  ]);
  const engine = await new LuaFactory().createEngine();
  await engine.doString(`
    package.preload['server.foundation'] = assert(load(
      ${JSON.stringify(foundationSource)}, '@server/foundation.lua'))
    package.preload['server.persistence.governance_shared'] = assert(load(
      ${JSON.stringify(sharedSource)}, '@server/persistence/governance_shared.lua'))
    package.preload['server.persistence.governance_attribute_values'] = assert(load(
      ${JSON.stringify(valuesSource)}, '@server/persistence/governance_attribute_values.lua'))
    package.preload['server.persistence.governance_attributes'] = assert(load(
      ${JSON.stringify(attributesSource)}, '@server/persistence/governance_attributes.lua'))
    package.preload['server.persistence.governance_attribute_activation'] = assert(load(
      ${JSON.stringify(activationSource)}, '@server/persistence/governance_attribute_activation.lua'))
  `);
  return engine;
}

const runtimeFixture = String.raw`
  local Foundation = require 'server.foundation'
  local Attributes = require('server.persistence.governance_attributes')(Foundation)
  local Activation = require('server.persistence.governance_attribute_activation')(Foundation)
  Attributes.enforceMembershipActivation = Activation.enforceMembershipActivation

  local function encode(value)
    local kind = type(value)
    if kind == 'nil' then return 'null' end
    if kind == 'boolean' then return value and 'true' or 'false' end
    if kind == 'number' then return tostring(value) end
    if kind == 'string' then return string.format('%q', value) end
    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = key end
    table.sort(keys)
    local items = {}
    for _, key in ipairs(keys) do
      items[#items + 1] = string.format('%q', key) .. ':' .. encode(value[key])
    end
    return '{' .. table.concat(items, ',') .. '}'
  end

  local sequence = 0
  local runtime = { jsonEncode = encode, deferred = {}, effects = {} }
  function runtime.jsonDecode(value)
    if value == '{}' then return {} end
    if value == '{"required":true}' then return { required = true } end
    if value == '{"minimum":1,"required":true}' then
      return { minimum = 1, required = true }
    end
    error('unexpected JSON fixture: ' .. tostring(value))
  end
  function runtime.id(namespace)
    sequence = sequence + 1
    return namespace .. '_' .. string.format('%08d', sequence)
  end
  function runtime.success(entityId, entityType, status, version)
    return { entity_id = entityId, entity_type = entityType,
      status = status, version = version, replayed = false }
  end
  function runtime.effect(action, entityType, entityId, groupId, characterId,
      before, after, reason, version)
    local effect = { action = action, entityType = entityType, entityId = entityId,
      groupId = groupId, characterId = characterId, before = before, after = after,
      reason = reason, version = version }
    runtime.effects[#runtime.effects + 1] = effect
    return effect
  end
  function runtime.deferRegistry(context, registry, owner, epoch, generation, key, value)
    assert(context.caller == owner and context.callerEpoch == epoch and generation == 1)
    assert(type(context.registryMutations) == 'table')
    local item = { registry = registry, owner = owner, epoch = epoch, generation = generation,
      key = key, value = value }
    context.registryMutations[#context.registryMutations + 1] = item
    runtime.deferred[#runtime.deferred + 1] = item
    return true
  end
  function runtime.requireRegistryOwnerSession(_, owner, epoch)
    assert(type(owner) == 'string' and type(epoch) == 'number' and epoch >= 1)
    return { ownerEpoch = epoch, generation = 1 }, nil
  end
`;

test('migration 026 persists scoped schema ownership and type-safe defaults', async () => {
  const migration = await readFile(path.join(
    root,
    'resources/synex_groups/migrations/026_group_attribute_scopes.sql',
  ), 'utf8');
  assert.match(migration, /ADD COLUMN `owner_epoch` BIGINT UNSIGNED NOT NULL DEFAULT 1/u);
  assert.match(migration, /ADD COLUMN `has_default` TINYINT UNSIGNED NOT NULL DEFAULT 0/u);
  for (const column of [
    'default_value_string',
    'default_value_integer',
    'default_value_decimal',
    'default_value_boolean',
    'default_value_datetime',
    'default_value_json',
  ]) {
    assert.match(migration, new RegExp('ADD COLUMN `' + column + '`', 'u'));
  }
  assert.match(migration, /`visibility` IN \([\s\S]*?'staff'[\s\S]*?'hidden'[\s\S]*?'server_only'/u);
  assert.match(
    migration,
    /chk_group_membership_profiles_visibility[\s\S]*?'hidden'[\s\S]*?'server_only'/u,
  );
  assert.match(migration, /chk_group_attribute_schemas_default/u);
  assert.match(
    migration,
    /`default_value_boolean` IS NOT NULL\s+AND `default_value_boolean` IN \(0, 1\)/u,
  );
  assert.match(migration, /idx_group_attribute_schemas_owner_epoch/u);
  assert.match(migration, /synex_groups_verify_026_group_attribute_scopes/u);
});

test('schema registration scopes keys, persists owner epochs, and requires valid defaults', async () => {
  const engine = await createEngine();
  try {
    const result = await engine.doString(`${runtimeFixture}
      local tx = { inserted = nil, existing = nil, updated = nil }
      function tx.one(sql)
        if sql:find('FROM synex_group_types', 1, true) then
          return { id = 7, public_id = 'group_type_police_0001',
            type_key = 'police', status = 'active' }
        end
        if sql:find('FROM synex_group_attribute_schemas', 1, true) then
          return tx.existing
        end
        error('unexpected registration query: ' .. sql)
      end
      function tx.query(sql, parameters)
        tx.inserted = { sql = sql, parameters = parameters }
        return { affectedRows = 1 }
      end
      function tx.affected(sql, parameters)
        tx.updated = { sql = sql, parameters = parameters }
        return 1
      end

      local context = { caller = 'synex_police', callerEpoch = 7,
        registryMutations = {} }
      local missing, missingError = Attributes.execute.attributes_register_schema(tx, {
        namespace = 'synex_police', key = 'badge', type = 'integer',
        validation = { required = true, minimum = 1 },
        visibility = 'management', schema_version = 1
      }, runtime, context)
      assert(missing == nil and missingError.code == 'VALIDATION_FAILED')
      assert(tx.inserted == nil)

      local invalid, invalidError = Attributes.execute.attributes_register_schema(tx, {
        namespace = 'synex_police', key = 'badge', type = 'integer', default = 0,
        validation = { required = true, minimum = 1 },
        visibility = 'management', schema_version = 1, group_type = 'police'
      }, runtime, context)
      assert(invalid == nil and invalidError.code == 'VALIDATION_FAILED')
      assert(tx.inserted == nil)

      local lossy, lossyError = Attributes.execute.attributes_register_schema(tx, {
        namespace = 'synex_police', key = 'rating', type = 'decimal',
        default = 1.2345678, visibility = 'management', schema_version = 1,
        group_type = 'police'
      }, runtime, context)
      assert(lossy == nil and lossyError.code == 'VALIDATION_FAILED')
      assert(tx.inserted == nil)

      local registered, registrationError, effects =
        Attributes.execute.attributes_register_schema(tx, {
          namespace = 'synex_police', key = 'badge', type = 'integer', default = 7,
          validation = { required = true, minimum = 1 },
          visibility = 'management', schema_version = 1, group_type = 'police'
        }, runtime, context)
      assert(registered, registrationError and registrationError.code)
      assert(#effects == 1 and effects[1].action == 'attribute_schema.registered')
      assert(tx.inserted.parameters[2] == 'synex_police')
      assert(tx.inserted.parameters[3] == 7 and tx.inserted.parameters[4] == 7)
      assert(tx.inserted.parameters[9] == 1 and tx.inserted.parameters[11] == 1)
      assert(tx.inserted.parameters[13] == 7)
      assert(runtime.deferred[1].registry == 'attributeSchemas')
      assert(runtime.deferred[1].key
        == 'attribute_schema:type:police:synex_police:badge')
      assert(runtime.deferred[1].value.scope == 'type:police')

      local rulesJson = tx.inserted.parameters[10]
      tx.existing = {
        id = 51, public_id = registered.entity_id, owner_resource = 'synex_police',
        owner_epoch = 7, group_type_id = 7, namespace = 'synex_police',
        attribute_key = 'badge', value_kind = 'integer', contract_type = 'integer',
        visibility = 'management', required_value = 1, validation_json = rulesJson,
        capability = nil, schema_version = 1, status = 'active', version = 1,
        has_default = 1, default_value_integer = 7
      }
      local rebound = assert(Attributes.execute.attributes_register_schema(tx, {
        namespace = 'synex_police', key = 'badge', type = 'integer', default = 7,
        validation = { required = true, minimum = 1 },
        visibility = 'management', schema_version = 1, group_type = 'police'
      }, runtime, { caller = 'synex_police', callerEpoch = 8,
        registryMutations = {} }))
      assert(rebound.version == 2 and tx.updated.parameters[8] == 8)

      -- Core owner epochs are process-local and restart at one after a full
      -- FXServer restart. A currently-authorized owner must therefore be able
      -- to rebind a persisted schema even when its new epoch is numerically
      -- lower than the epoch stored by the previous process.
      tx.existing.owner_epoch = 8
      tx.existing.version = 2
      local restarted = assert(Attributes.execute.attributes_register_schema(tx, {
        namespace = 'synex_police', key = 'badge', type = 'integer', default = 7,
        validation = { required = true, minimum = 1 },
        visibility = 'management', schema_version = 1, group_type = 'police'
      }, runtime, { caller = 'synex_police', callerEpoch = 7,
        registryMutations = {} }))
      assert(restarted.version == 3 and tx.updated.parameters[8] == 7)

      tx.existing = nil
      tx.inserted = nil
      local global = assert(Attributes.execute.attributes_register_schema(tx, {
        namespace = 'synex_shared', key = 'employee', type = 'string',
        default = 'unassigned', visibility = 'hidden', schema_version = 1
      }, runtime, { caller = 'synex_shared', callerEpoch = 2,
        registryMutations = {} }))
      assert(global.entity_type == 'attribute_schema')
      assert(tx.inserted.parameters[4] == nil)
      assert(runtime.deferred[#runtime.deferred].key
        == 'attribute_schema:global:synex_shared:employee')
      return registered.status .. ':' .. rebound.version .. ':'
        .. restarted.version .. ':' .. global.status
    `);
    assert.equal(result, 'active:2:3:active');
  } finally {
    await engine.global.close();
  }
});

test('activation helper atomically validates existing values and materializes scoped defaults', async () => {
  const engine = await createEngine();
  try {
    const result = await engine.doString(`${runtimeFixture}
      local schemas = {
        {
          id = 10, public_id = 'group_attr_schema_0001', owner_resource = 'synex_police',
          owner_epoch = 4, group_type_id = 7, namespace = 'synex_police',
          attribute_key = 'badge', value_kind = 'integer', required_value = 1,
          validation_json = '{"minimum":1,"required":true}', schema_version = 1,
          version = 1, has_default = 1, default_value_integer = 42
        },
        {
          id = 11, public_id = 'group_attr_schema_0002', owner_resource = 'synex_shared',
          owner_epoch = 2, group_type_id = nil, namespace = 'synex_shared',
          attribute_key = 'verified', value_kind = 'boolean', required_value = 0,
          validation_json = '{}', schema_version = 1, version = 1,
          has_default = 1, default_value_boolean = 0
        }
      }
      local existingRows, inserts = {}, {}
      local tx = {}
      function tx.one(sql)
        if sql:find('FROM synex_group_organization_profiles', 1, true) then
          return { group_type_id = 7 }
        end
        error('unexpected activation one query: ' .. sql)
      end
      function tx.many(sql)
        assert(sql:find('scoped_schema.group_type_id', 1, true))
        if sql:find('synex_group_membership_attributes AS attribute', 1, true) then
          return existingRows
        end
        return schemas
      end
      function tx.query(sql, parameters)
        assert(sql:find('INSERT INTO synex_group_membership_attributes', 1, true))
        inserts[#inserts + 1] = parameters
        return { affectedRows = 1 }
      end
      local membership = { id = 91, group_id = 33,
        character_id = 'character_00000001' }
      local enforced = assert(Attributes.enforceMembershipActivation(
        tx, membership, runtime))
      assert(enforced.schemas == 2 and enforced.materialized == 2
        and enforced.validated == 0)
      assert(#inserts == 2)
      assert(inserts[1][3] == 10 and inserts[1][6] == 42)
      assert(inserts[2][3] == 11 and inserts[2][8] == 0)

      schemas = {{
        id = 12, public_id = 'group_attr_schema_0003', owner_resource = 'legacy_owner',
        owner_epoch = 1, group_type_id = 7, namespace = 'legacy',
        attribute_key = 'required', value_kind = 'string', required_value = 1,
        validation_json = '{}', schema_version = 1, version = 1, has_default = 0
      }}
      inserts = {}
      local blocked, blockedError = Attributes.enforceMembershipActivation(
        tx, membership, runtime)
      assert(blocked == nil and blockedError.code == 'VALIDATION_FAILED'
        and #inserts == 0)

      schemas = {
        { id = 20, owner_resource = 'owner_one', owner_epoch = 1,
          group_type_id = 7, namespace = 'duplicate', attribute_key = 'key',
          value_kind = 'string', required_value = 0, validation_json = '{}',
          schema_version = 1, version = 1, has_default = 0 },
        { id = 21, owner_resource = 'owner_two', owner_epoch = 1,
          group_type_id = nil, namespace = 'duplicate', attribute_key = 'key',
          value_kind = 'string', required_value = 0, validation_json = '{}',
          schema_version = 1, version = 1, has_default = 0 }
      }
      local ambiguous, ambiguousError = Attributes.enforceMembershipActivation(
        tx, membership, runtime)
      assert(ambiguous == nil and ambiguousError.code == 'DATABASE_RESULT_INVALID')
      return enforced.materialized .. ':' .. blockedError.code .. ':' .. ambiguousError.code
    `);
    assert.equal(result, '2:VALIDATION_FAILED:DATABASE_RESULT_INVALID');
  } finally {
    await engine.global.close();
  }
});

test('attribute visibility and scoped lookup fail closed for hidden, staff, and server-only values', async () => {
  const [source, directorySource] = await Promise.all([
    readFile(path.join(
      root,
      'resources/synex_groups/server/persistence/governance_attributes.lua',
    ), 'utf8'),
    readFile(path.join(
      root,
      'resources/synex_groups/server/persistence/memberships_read.lua',
    ), 'utf8'),
  ]);
  assert.match(source, /schema\.group_type_id = organization\.group_type_id/u);
  assert.match(source, /schema\.group_type_id IS NULL AND NOT EXISTS/u);
  assert.doesNotMatch(source, /group_type_scope_id = 0 AND schema\.status/u);
  assert.match(
    directorySource,
    /profile\.character_id = \? AND profile\.visibility <> 'server_only'/u,
  );
  assert.doesNotMatch(
    directorySource,
    /OR profile\.character_id = \?\s+OR/u,
  );

  const engine = await createEngine();
  try {
    const result = await engine.doString(`${runtimeFixture}
      local visibility, ownerEpoch = 'hidden', 5
      local tx = {}
      function tx.one(sql)
        if sql:find('schema.namespace', 1, true) then
          return {
            attribute_public_id = 'group_attribute_00000001', value_kind = 'string',
            value_string = 'ADAM-12', version = 1,
            namespace = 'synex_police', attribute_key = 'callsign',
            visibility = visibility, capability = nil,
            owner_resource = 'synex_police', owner_epoch = ownerEpoch,
            membership_public_id = 'group_member_00000001',
            character_id = 'character_subject_0001', lifecycle_state = 'ACTIVE',
            group_internal_id = 20, group_public_id = 'groups_group_00000001'
          }
        end
        error('unexpected visibility query: ' .. sql)
      end
      runtime.authorize = function() error('hidden/server-only cannot use manager fallback') end
      runtime.checkCorePermission = function(_, permission)
        assert(permission == 'synex.groups.attributes.staff.read')
        return true
      end
      local request = { actor_character_id = 'character_other_0002',
        membership_id = 'group_member_00000001', namespace = 'synex_police',
        key = 'callsign' }
      local denied, hiddenError = Attributes.read.attributes_get(tx, request, runtime, {
        caller = 'foreign_resource', callerEpoch = 5 })
      assert(denied == nil and hiddenError.code == 'ATTRIBUTE_NOT_FOUND')
      request.actor_character_id = 'character_subject_0001'
      assert(Attributes.read.attributes_get(tx, request, runtime, {
        caller = 'foreign_resource', callerEpoch = 5 }))

      visibility = 'server_only'
      local serverDenied, serverError = Attributes.read.attributes_get(tx, request, runtime, {
        caller = 'synex_police', callerEpoch = 4 })
      assert(serverDenied == nil and serverError.code == 'ATTRIBUTE_NOT_FOUND')
      assert(Attributes.read.attributes_get(tx, request, runtime, {
        caller = 'synex_police', callerEpoch = 5 }))

      visibility = 'staff'
      assert(Attributes.read.attributes_get(tx, request, runtime, {
        caller = 'foreign_resource', callerEpoch = 1 }))
      runtime.checkCorePermission = nil
      local unavailable, unavailableError = Attributes.read.attributes_get(
        tx, request, runtime, {})
      assert(unavailable == nil and unavailableError.code == 'DATABASE_ERROR')
      return hiddenError.code .. ':' .. serverError.code .. ':' .. unavailableError.code
    `);
    assert.equal(
      result,
      'ATTRIBUTE_NOT_FOUND:ATTRIBUTE_NOT_FOUND:DATABASE_ERROR',
    );
  } finally {
    await engine.global.close();
  }
});
