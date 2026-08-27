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
  await preload(
    engine,
    'server.persistence.organizations_shared',
    'resources/synex_groups/server/persistence/organizations_shared.lua',
  );
  await preload(
    engine,
    'server.persistence.extension_registries',
    'resources/synex_groups/server/persistence/extension_registries.lua',
  );
  await preload(
    engine,
    'server.extension_registries',
    'resources/synex_groups/server/extension_registries.lua',
  );
}

test('relation and duty extension registrations persist caller ownership and defer runtime mutation until commit', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`
      local Foundation = require 'server.foundation'
      local handlers = require('server.persistence.extension_registries')(Foundation).execute
      local sequence, writes, deferred, synchronizationChecks = 0, {}, {}, 0
      local runtime = {
        id = function(namespace)
          sequence = sequence + 1
          return namespace .. '_' .. string.format('%08d', sequence)
        end,
        reason = function(_, fallback) return fallback end,
        success = function(id, kind, status, version)
          return { entity_id = id, entity_type = kind, status = status,
            version = version, replayed = false }
        end,
        effect = function(action, kind, id, groupId, characterId, before, after, reason, version)
          return { action = action, entityType = kind, entityId = id, before = before,
            after = after, reason = reason, version = version }
        end,
        deferRegistry = function(context, registry, owner, epoch, generation, key, value)
          assert(context.caller == owner and context.callerEpoch == epoch
            and generation == 3)
          deferred[#deferred + 1] = { registry = registry, owner = owner,
            epoch = epoch, generation = generation, key = key, value = value }
          return true, nil
        end,
        requireRegistryOwnerSession = function(_, owner, epoch)
          synchronizationChecks = synchronizationChecks + 1
          assert(owner == 'vendor_groups' and epoch == 11)
          return { ownerEpoch = epoch, generation = 3 }, nil
        end
      }
      local tx = {
        one = function() return nil end,
        query = function(sql, parameters)
          writes[#writes + 1] = { sql = sql, parameters = parameters }
          return { affectedRows = 1 }
        end
      }
      local context = { caller = 'vendor_groups', callerEpoch = 11 }
      local relation, relationError, relationEffects = handlers.relation_types_register(tx, {
        type = 'supports', schema_version = 2, label = 'Supports', direction = 'directed'
      }, runtime, context)
      assert(relationError == nil and relation.entity_type == 'relation_type')
      assert(#relationEffects == 1 and relationEffects[1].action == 'relation_type.registered')
      local duty, dutyError, dutyEffects = handlers.duty_states_register(tx, {
        state = 'responding', schema_version = 3, label = 'Responding',
        counts_as_on_duty = true
      }, runtime, context)
      assert(dutyError == nil and duty.entity_type == 'duty_state')
      assert(#dutyEffects == 1 and dutyEffects[1].action == 'duty_state.registered')
      assert(#deferred == 2 and synchronizationChecks == 2)
      assert(deferred[1].registry == 'relationTypes'
        and deferred[1].key == 'relation_type:supports' and deferred[1].epoch == 11)
      assert(deferred[2].registry == 'dutyStates'
        and deferred[2].key == 'duty_state:responding' and deferred[2].epoch == 11)
      assert(writes[1].sql:find('owner_epoch', 1, true)
        and writes[1].sql:find('schema_version', 1, true))
      assert(writes[1].parameters[3] == 'vendor_groups' and writes[1].parameters[4] == 11)
      assert(writes[2].sql:find('public_id', 1, true)
        and writes[2].sql:find('owner_epoch', 1, true))
      assert(writes[2].parameters[3] == 'vendor_groups' and writes[2].parameters[4] == 11)
      return relation.entity_id .. ':' .. duty.entity_id
    `);
    assert.equal(result, 'groups_relation_type_00000001:groups_duty_state_00000002');
  } finally {
    engine.global.close();
  }
});

test('persistent registries hydrate after restart and stale owner cleanup cannot remove a newer epoch', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`
      local Foundation = require 'server.foundation'
      local Registry = require 'server.domain.registry'
      local createCoordinator = require('server.extension_registries')(Foundation)
      local registries = {
        groupTypes = Registry.create({ maximumEntries = 16, maximumPerOwner = 8 }),
        relationTypes = Registry.create({ maximumEntries = 16, maximumPerOwner = 8 }),
        attributeSchemas = Registry.create({ maximumEntries = 16, maximumPerOwner = 8 }),
        dutyStates = Registry.create({ maximumEntries = 16, maximumPerOwner = 8 })
      }
      local updates = {}
      local syncRow = { owner_resource = 'vendor_groups', owner_epoch = 4,
        begin_key = 'registry-epoch-4', generation = 1, active = 1 }
      local coordinator = createCoordinator({
        registries = registries,
        query = function(sql)
          if sql:find('generation', 1, true) and sql:find('ORDER BY', 1, true) then
            return { syncRow }
          end
          if sql:find('begin_key', 1, true)
              and sql:find('synex_group_registry_owner_syncs', 1, true) then
            return { syncRow }
          end
          if sql:find('active_registry_owners', 1, true) then
            return { { owner_resource = 'vendor_groups', owner_epoch = 4 } }
          end
          if sql:find('synex_group_attribute_schemas', 1, true) then
            return { { public_id = 'group_attr_schema_01', registry_key = 'badge',
              group_type_id = 7, group_type_key = 'company', namespace = 'vendor',
              owner_resource = 'vendor_groups', owner_epoch = 4,
              value_kind = 'integer', visibility = 'management', required_value = 1,
              has_default = 1, capability = 'synex.groups.attributes.read',
              schema_version = 2, version = 3 } }
          end
          if sql:find('synex_group_types', 1, true) then
            return { { public_id = 'groups_type_00000001', registry_key = 'company',
              owner_resource = 'vendor_groups', owner_epoch = 4, display_name = 'Company',
              schema_version = 2, create_permission = 'synex.groups.create.company',
              membership_limit = 100, active_membership_limit = 75, version = 3 } }
          end
          if sql:find('synex_group_relation_types', 1, true) then
            return { { public_id = 'groups_relation_0001', registry_key = 'supports',
              owner_resource = 'vendor_groups', owner_epoch = 4, display_name = 'Supports',
              direction = 'directed', schema_version = 1, version = 1 } }
          end
          if sql:find('synex_group_duty_states', 1, true) then
            return { { public_id = 'groups_duty_state1', registry_key = 'responding',
              owner_resource = 'vendor_groups', owner_epoch = 4, display_name = 'Responding',
              counts_as_on_duty = 1, schema_version = 1, version = 1 } }
          end
          error('unexpected hydration query')
        end,
        startTransaction = function(handler)
          return handler(function(sql, parameters)
            assert(not sql:find('DELETE', 1, true))
            if sql:find('SELECT', 1, true)
                and sql:find('synex_group_registry_owner_syncs', 1, true) then
              return { syncRow }
            end
            updates[#updates + 1] = { sql = sql, parameters = parameters }
            if sql:find('synex_group_registry_owner_syncs', 1, true) then
              syncRow.active = 0
              return { affectedRows = 1 }
            end
            return { affectedRows = 0 }
          end)
        end
      })
      local hydrated = assert(coordinator:hydrate())
      assert(hydrated.installed == 4)
      local groupType, _, typeOwner = registries.groupTypes:get('group_type:company')
      assert(groupType.createPermission == 'synex.groups.create.company')
      assert(groupType.maxMembers == 100 and groupType.maxActiveMembers == 75)
      assert(typeOwner.epoch == 4)
      local relation, _, relationOwner = registries.relationTypes:get('relation_type:supports')
      assert(relation.direction == 'directed' and relationOwner.epoch == 4)
      local duty, _, dutyOwner = registries.dutyStates:get('duty_state:responding')
      assert(duty.countsAsOnDuty == true and dutyOwner.epoch == 4)
      local attribute, _, attributeOwner = registries.attributeSchemas:get(
        'attribute_schema:type:company:vendor:badge')
      assert(attribute.required == true and attribute.hasDefault == true
        and attribute.groupType == 'company' and attributeOwner.epoch == 4)

      syncRow.owner_epoch, syncRow.begin_key = 6, 'registry-epoch-6'
      syncRow.generation, syncRow.active = 2, 1
      local begun = assert(coordinator:refresh('registries_begin', {
        idempotency_key = syncRow.begin_key
      }, { caller = 'vendor_groups', callerEpoch = 6 }, {
        owner_resource = 'vendor_groups', owner_epoch = 6, generation = 2,
        status = 'synchronized', replayed = false
      }))
      assert(begun.removed == 4)
      assert(coordinator:apply({ registry = 'relationTypes', owner = 'vendor_groups',
        epoch = 6, generation = 2, key = 'relation_type:supports', value = {
          publicId = relation.publicId, key = 'supports', direction = 'directed',
          schemaVersion = 1, version = 2
        } }))
      local staleCleanup = assert(coordinator:disableOwner('vendor_groups', 4))
      assert(staleCleanup.removed == 0)
      local current, _, currentOwner = registries.relationTypes:get('relation_type:supports')
      assert(current.version == 2 and currentOwner.epoch == 6)
      assert(#updates == 4 and syncRow.active == 1)
      for _, update in ipairs(updates) do
        assert(update.parameters[1] == 'vendor_groups' and update.parameters[2] == 4)
      end
      local currentCleanup = assert(coordinator:disableOwner('vendor_groups', 6))
      assert(currentCleanup.removed == 1 and syncRow.active == 0)
      local missing, missingError = registries.relationTypes:get('relation_type:supports')
      assert(missing == nil and missingError.code == 'REGISTRY_KEY_NOT_FOUND')
      return table.concat({ begun.removed, staleCleanup.removed,
        currentCleanup.removed, #updates }, ':')
    `);
    assert.equal(result, '4:0:1:9');
  } finally {
    engine.global.close();
  }
});

test('restart hydration disables orphan owners before installing live extension definitions', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`
      local Foundation = require 'server.foundation'
      local Registry = require 'server.domain.registry'
      local createCoordinator = require('server.extension_registries')(Foundation)
      local registries = {
        groupTypes = Registry.create({ maximumEntries = 16, maximumPerOwner = 8 }),
        relationTypes = Registry.create({ maximumEntries = 16, maximumPerOwner = 8 }),
        attributeSchemas = Registry.create({ maximumEntries = 16, maximumPerOwner = 8 }),
        dutyStates = Registry.create({ maximumEntries = 16, maximumPerOwner = 8 })
      }
      local rows = {
        { public_id = 'groups_type_orphan_01', registry_key = 'orphan',
          owner_resource = 'vendor_stale', owner_epoch = 1, display_name = 'Orphan',
          schema_version = 1, create_permission = 'synex.groups.create.orphan',
          membership_limit = 10, active_membership_limit = 5, version = 1,
          status = 'active' },
        { public_id = 'groups_type_live_0001', registry_key = 'live',
          owner_resource = 'vendor_live', owner_epoch = 2, display_name = 'Live',
          schema_version = 1, create_permission = 'synex.groups.create.live',
          membership_limit = 20, active_membership_limit = 10, version = 1,
          status = 'active' }
      }
      local cleanupWrites = 0
      local coordinator = createCoordinator({
        registries = registries,
        isOwnerRunning = function(owner) return owner == 'vendor_live' end,
        query = function(sql)
          if sql:find('generation', 1, true) and sql:find('ORDER BY', 1, true) then
            return { { owner_resource = 'vendor_live', owner_epoch = 2,
              generation = 1, active = 1 } }
          end
          if sql:find('active_registry_owners', 1, true) then
            return { { owner_resource = 'vendor_live', owner_epoch = 2 },
              { owner_resource = 'vendor_stale', owner_epoch = 1 } }
          end
          if sql:find('synex_group_attribute_schemas', 1, true)
              or sql:find('synex_group_relation_types', 1, true)
              or sql:find('synex_group_duty_states', 1, true) then return {} end
          if sql:find('synex_group_types', 1, true) then
            local active = {}
            for _, row in ipairs(rows) do
              if row.status == 'active' then active[#active + 1] = row end
            end
            return active
          end
          error('unexpected orphan hydration query')
        end,
        startTransaction = function(handler)
          return handler(function(sql, parameters)
            if sql:find('SELECT', 1, true)
                and sql:find('synex_group_registry_owner_syncs', 1, true) then
              return {}
            end
            cleanupWrites = cleanupWrites + 1
            local changed = 0
            if sql:find('UPDATE \`synex_group_types\`', 1, true) then
              for _, row in ipairs(rows) do
                if row.owner_resource == parameters[1] and row.status == 'active' then
                  row.status = 'disabled'
                  changed = changed + 1
                end
              end
            end
            return { affectedRows = changed }
          end)
        end
      })
      local hydrated, hydrationError = coordinator:hydrate()
      assert(hydrationError == nil and hydrated.installed == 1 and cleanupWrites == 4)
      local live, _, liveOwner = registries.groupTypes:get('group_type:live')
      assert(live.label == 'Live' and liveOwner.epoch == 2)
      local orphan, orphanError = registries.groupTypes:get('group_type:orphan')
      assert(orphan == nil and orphanError.code == 'REGISTRY_KEY_NOT_FOUND')
      assert(rows[1].status == 'disabled' and rows[2].status == 'active')
      return hydrated.installed .. ':' .. cleanupWrites
    `);
    assert.equal(result, '1:4');
  } finally {
    engine.global.close();
  }
});

test('new owner epochs retire partial old registrations and failed stop cleanup is retryable', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`
      local Foundation = require 'server.foundation'
      local Registry = require 'server.domain.registry'
      local createCoordinator = require('server.extension_registries')(Foundation)
      local registries = {
        groupTypes = Registry.create({ maximumEntries = 16, maximumPerOwner = 8 }),
        relationTypes = Registry.create({ maximumEntries = 16, maximumPerOwner = 8 }),
        attributeSchemas = Registry.create({ maximumEntries = 16, maximumPerOwner = 8 }),
        dutyStates = Registry.create({ maximumEntries = 16, maximumPerOwner = 8 })
      }
      assert(registries.groupTypes:replace('vendor_groups', 1,
        'group_type:alpha', { publicId = 'groups_type_alpha_01', version = 1 }))
      assert(registries.groupTypes:replace('vendor_groups', 1,
        'group_type:legacy', { publicId = 'groups_type_legacy01', version = 1 }))
      local transactions, failNext = 0, false
      local syncRows = {
        vendor_groups = { owner_epoch = 2, begin_key = 'registry-vendor-groups',
          generation = 1, active = 1 },
        vendor_retry = { owner_epoch = 3, begin_key = 'registry-vendor-retry',
          generation = 1, active = 1 }
      }
      local coordinator = createCoordinator({
        registries = registries,
        query = function(sql, parameters)
          if sql:find('begin_key', 1, true)
              and sql:find('synex_group_registry_owner_syncs', 1, true) then
            local row = syncRows[parameters[1]]
            return row and { row } or {}
          end
          if sql:find('type_key = ?', 1, true) then
            return { { public_id = 'groups_type_alpha_01', registry_key = 'alpha',
              owner_resource = 'vendor_groups', owner_epoch = 2, display_name = 'Alpha',
              schema_version = 2, create_permission = 'synex.groups.create.alpha',
              membership_limit = 20, active_membership_limit = 10, version = 2 } }
          end
          error('unexpected epoch refresh query')
        end,
        startTransaction = function(handler)
          transactions = transactions + 1
          if failNext then failNext = false return false end
          return handler(function(sql, parameters)
            assert(parameters[1] == 'vendor_groups' or parameters[1] == 'vendor_retry')
            if sql:find('SELECT', 1, true)
                and sql:find('synex_group_registry_owner_syncs', 1, true) then
              local row = syncRows[parameters[1]]
              return row and { row } or {}
            end
            if sql:find('synex_group_registry_owner_syncs', 1, true) then
              local row = syncRows[parameters[1]]
              if row then row.active = 0 end
              return { affectedRows = 1 }
            end
            return { affectedRows = sql:find('synex_group_types', 1, true) and 1 or 0 }
          end)
        end
      })
      local groupBegin = assert(coordinator:refresh('registries_begin', {
        idempotency_key = syncRows.vendor_groups.begin_key
      }, { caller = 'vendor_groups', callerEpoch = 2 }, {
        owner_resource = 'vendor_groups', owner_epoch = 2, generation = 1,
        status = 'synchronized', replayed = false
      }))
      assert(groupBegin.removed == 2)
      assert(coordinator:apply({ registry = 'groupTypes', owner = 'vendor_groups',
        epoch = 2, generation = 1, key = 'group_type:alpha', value = {
          publicId = 'groups_type_alpha_01', version = 2 } }))
      local refreshed, refreshError = coordinator:refresh('types_register',
        { type = 'alpha' }, { caller = 'vendor_groups', callerEpoch = 2 }, nil, {
          { registry = 'groupTypes', owner = 'vendor_groups', epoch = 2,
            generation = 1, key = 'group_type:alpha', value = {} }
        })
      assert(refreshError == nil and refreshed)
      local alpha, _, alphaOwner = registries.groupTypes:get('group_type:alpha')
      local legacy, legacyError = registries.groupTypes:get('group_type:legacy')
      assert(alpha.version == 2 and alphaOwner.epoch == 2)
      assert(legacy == nil and legacyError.code == 'REGISTRY_KEY_NOT_FOUND')

      assert(coordinator:refresh('registries_begin', {
        idempotency_key = syncRows.vendor_retry.begin_key
      }, { caller = 'vendor_retry', callerEpoch = 3 }, {
        owner_resource = 'vendor_retry', owner_epoch = 3, generation = 1,
        status = 'synchronized', replayed = false
      }))
      assert(coordinator:apply({ registry = 'relationTypes', owner = 'vendor_retry',
        epoch = 3, generation = 1, key = 'relation_type:retry',
        value = { publicId = 'groups_relation_retry', version = 1 } }))
      failNext = true
      local failed, failedError = coordinator:disableOwner('vendor_retry')
      assert(failed == nil and failedError.code == 'DATABASE_ERROR'
        and failedError.retryable == true)
      local fenced, fencedError = registries.relationTypes:get('relation_type:retry')
      assert(fenced == nil and fencedError.code == 'REGISTRY_KEY_NOT_FOUND')
      local retried, retryError = coordinator:disableOwner('vendor_retry')
      assert(retryError == nil and retried.removed == 1)
      local missing, missingError = registries.relationTypes:get('relation_type:retry')
      assert(missing == nil and missingError.code == 'REGISTRY_KEY_NOT_FOUND')
      return alphaOwner.epoch .. ':' .. retried.removed .. ':' .. transactions
    `);
    assert.equal(result, '2:1:2');
  } finally {
    engine.global.close();
  }
});

test('owner stop fences every runtime registry before yielding and stale cleanup cannot hide a restarted epoch', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`
      local Foundation = require 'server.foundation'
      local Registry = require 'server.domain.registry'
      local createCoordinator = require('server.extension_registries')(Foundation)
      local registries = {
        groupTypes = Registry.create({ maximumEntries = 8, maximumPerOwner = 8 }),
        relationTypes = Registry.create({ maximumEntries = 8, maximumPerOwner = 8 }),
        dutyStates = Registry.create({ maximumEntries = 8, maximumPerOwner = 8 }),
        attributeSchemas = Registry.create({ maximumEntries = 8, maximumPerOwner = 8 })
      }
      local keys = {
        groupTypes = 'group_type:vendor_test',
        relationTypes = 'relation_type:vendor_test',
        dutyStates = 'duty_state:vendor_test',
        attributeSchemas = 'attribute_schema:global:vendor:test'
      }
      local sync = { owner_epoch = 1, begin_key = 'registry-owner-epoch-1',
        generation = 1, active = 1 }
      local failCleanup, checkFenceInsideCleanup, checkedInsideCleanup = false, false, false
      local function assertHidden()
        for registryName, key in pairs(keys) do
          local value, lookupError = registries[registryName]:get(key)
          assert(value == nil and lookupError.code == 'REGISTRY_KEY_NOT_FOUND', registryName)
        end
      end
      local coordinator = createCoordinator({
        registries = registries,
        query = function(sql)
          if sql:find('synex_group_registry_owner_syncs', 1, true) then
            return { sync }
          end
          error('unexpected coordinator query')
        end,
        startTransaction = function(handler)
          if checkFenceInsideCleanup then
            assertHidden()
            checkedInsideCleanup = true
          end
          if failCleanup then
            failCleanup = false
            return false
          end
          return handler(function(sql)
            if sql:find('SELECT', 1, true)
                and sql:find('synex_group_registry_owner_syncs', 1, true) then
              return { sync }
            end
            if sql:find('synex_group_registry_owner_syncs', 1, true) then
              if tonumber(sync.owner_epoch) == 1 then sync.active = 0 end
              return { affectedRows = 1 }
            end
            return { affectedRows = 0 }
          end)
        end
      })
      assert(coordinator:refresh('registries_begin', {
        idempotency_key = sync.begin_key
      }, { caller = 'vendor_groups', callerEpoch = 1 }, {
        owner_resource = 'vendor_groups', owner_epoch = 1, generation = 1,
        status = 'synchronized', replayed = false
      }))
      for registryName, key in pairs(keys) do
        assert(coordinator:apply({ registry = registryName, owner = 'vendor_groups',
          epoch = 1, generation = 1, key = key, value = { version = 1 } }))
        assert(registries[registryName]:get(key))
      end

      failCleanup, checkFenceInsideCleanup = true, true
      local failed, failedError = coordinator:disableOwner('vendor_groups', 1)
      assert(failed == nil and failedError.code == 'DATABASE_ERROR'
        and failedError.retryable == true and checkedInsideCleanup == true)
      assertHidden()
      checkFenceInsideCleanup = false

      sync.owner_epoch, sync.begin_key = 2, 'registry-owner-epoch-2'
      sync.generation, sync.active = 2, 1
      assert(coordinator:refresh('registries_begin', {
        idempotency_key = sync.begin_key
      }, { caller = 'vendor_groups', callerEpoch = 2 }, {
        owner_resource = 'vendor_groups', owner_epoch = 2, generation = 2,
        status = 'synchronized', replayed = false
      }))
      for registryName, key in pairs(keys) do
        assert(coordinator:apply({ registry = registryName, owner = 'vendor_groups',
          epoch = 2, generation = 2, key = key, value = { version = 2 } }))
      end
      local staleCleanup = assert(coordinator:disableOwner('vendor_groups', 1))
      assert(staleCleanup.removed == 0 and sync.active == 1)
      for registryName, key in pairs(keys) do
        local value, _, metadata = registries[registryName]:get(key)
        assert(value.version == 2 and metadata.epoch == 2, registryName)
      end
      return 'fenced:' .. tostring(staleCleanup.removed)
    `);
    assert.equal(result, 'fenced:0');
  } finally {
    engine.global.close();
  }
});

test('a delayed committed registration cannot cross a newer synchronization generation', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`
      local Foundation = require 'server.foundation'
      local Registry = require 'server.domain.registry'
      local registry = Registry.create({ maximumEntries = 8, maximumPerOwner = 8 })
      local sync = { owner_epoch = 7, begin_key = 'registry-generation-1',
        generation = 1, active = 1 }
      local definitionQueries = 0
      local coordinator = require('server.extension_registries')(Foundation)({
        registries = {
          groupTypes = registry,
          relationTypes = Registry.create(), dutyStates = Registry.create(),
          attributeSchemas = Registry.create()
        },
        query = function(sql)
          if sql:find('synex_group_registry_owner_syncs', 1, true) then
            return { sync }
          end
          definitionQueries = definitionQueries + 1
          error('stale registration must not query or expose a definition')
        end,
        startTransaction = function(handler)
          return handler(function() return { affectedRows = 0 } end)
        end
      })
      local context = { caller = 'vendor_groups', callerEpoch = 7 }
      assert(coordinator:refresh('registries_begin', {
        idempotency_key = sync.begin_key
      }, context, { owner_resource = 'vendor_groups', owner_epoch = 7,
        generation = 1, status = 'synchronized', replayed = false }))
      local delayed = { registry = 'groupTypes', owner = 'vendor_groups', epoch = 7,
        generation = 1, key = 'group_type:alpha', value = { version = 1 } }

      sync.begin_key, sync.generation = 'registry-generation-2', 2
      assert(coordinator:refresh('registries_begin', {
        idempotency_key = sync.begin_key
      }, context, { owner_resource = 'vendor_groups', owner_epoch = 7,
        generation = 2, status = 'synchronized', replayed = false }))
      local missing, missingError = registry:get('group_type:alpha')
      assert(missing == nil and missingError.code == 'REGISTRY_KEY_NOT_FOUND')

      local staleApply, staleApplyError = coordinator:apply(delayed)
      assert(staleApply == nil and staleApplyError.code == 'STALE_RESOURCE')
      local staleRefresh, staleRefreshError = coordinator:refresh('types_register', {
        type = 'alpha'
      }, context, nil, { delayed })
      assert(staleRefresh == nil and staleRefreshError.code == 'STALE_RESOURCE')
      assert(definitionQueries == 0)

      local current = { registry = 'groupTypes', owner = 'vendor_groups', epoch = 7,
        generation = 2, key = 'group_type:alpha', value = { version = 2 } }
      assert(coordinator:apply(current))
      local value, _, metadata = registry:get('group_type:alpha')
      assert(value.version == 2 and metadata.epoch == 7)
      return staleApplyError.code .. ':' .. staleRefreshError.code
        .. ':' .. value.version .. ':' .. definitionQueries
    `);
    assert.equal(result, 'STALE_RESOURCE:STALE_RESOURCE:2:0');
  } finally {
    engine.global.close();
  }
});

test('registry replacement is atomic across owner epochs and rejects foreign takeover', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`
      local Registry = require 'server.domain.registry'
      local registry = Registry.create({ maximumEntries = 2, maximumPerOwner = 1 })
      assert(registry:replace('resource_a', 1, 'type.alpha', { version = 1 }))
      assert(registry:replace('resource_a', 2, 'type.alpha', { version = 2 }))
      local value, _, owner = registry:get('type.alpha')
      assert(value.version == 2 and owner.epoch == 2)
      local takeover, takeoverError = registry:replace(
        'resource_b', 1, 'type.alpha', { version = 3 })
      assert(takeover == nil and takeoverError.code == 'REGISTRY_OWNER_MISMATCH')
      assert(#assert(registry:listOwner('resource_a', 1)) == 0)
      assert(#assert(registry:listOwner('resource_a', 2)) == 1)
      return registry:latestEpoch('resource_a')
    `);
    assert.equal(result, 2);
  } finally {
    engine.global.close();
  }
});

test('extension registration fails closed before definition access without an active matching owner session', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`
      local Foundation = require 'server.foundation'
      local handler = require('server.persistence.extension_registries')(Foundation)
        .execute.relation_types_register
      local definitionReads, writes, deferred = 0, 0, 0
      local response, responseError = handler({
        one = function()
          definitionReads = definitionReads + 1
          return nil
        end,
        query = function()
          writes = writes + 1
          return { affectedRows = 1 }
        end
      }, {
        type = 'supports', schema_version = 1, label = 'Supports', direction = 'directed'
      }, {
        requireRegistryOwnerSession = function(_, owner, epoch)
          assert(owner == 'vendor_groups' and epoch == 2)
          return nil, Foundation.domainError('STALE_RESOURCE',
            'Synchronization has not begun.')
        end,
        deferRegistry = function()
          deferred = deferred + 1
          return true
        end
      }, { caller = 'vendor_groups', callerEpoch = 2 })
      assert(response == nil and responseError.code == 'STALE_RESOURCE')
      assert(definitionReads == 0 and writes == 0 and deferred == 0)
      return responseError.code
    `);
    assert.equal(result, 'STALE_RESOURCE');
  } finally {
    engine.global.close();
  }
});

test('registry begin retires the complete previous owner snapshot before selective re-registration and is replay-safe', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`
      local Foundation = require 'server.foundation'
      local Registry = require 'server.domain.registry'
      local handlers = require('server.persistence.extension_registries')(Foundation).execute
      local createCoordinator = require('server.extension_registries')(Foundation)
      local owner = 'vendor_groups'
      local rows = {
        synex_group_types = {{
          public_id = 'groups_type_alpha_01', registry_key = 'alpha', type_key = 'alpha',
          owner_resource = owner, owner_epoch = 1, display_name = 'Alpha',
          schema_version = 1, create_permission = 'synex.groups.create.alpha',
          membership_limit = 20, active_membership_limit = 10,
          status = 'active', version = 1
        }},
        synex_group_relation_types = {{
          public_id = 'groups_relation_beta1', registry_key = 'beta', type_key = 'beta',
          owner_resource = owner, owner_epoch = 1, display_name = 'Beta',
          direction = 'directed', schema_version = 1,
          status = 'active', version = 1
        }},
        synex_group_duty_states = {},
        synex_group_attribute_schemas = {}
      }
      local syncRow, beginWrites, reconciliationWrites = nil, 0, 0
      local function copy(value)
        local result = {}
        for key, item in pairs(value or {}) do result[key] = item end
        return result
      end
      local function write(sql, parameters, reconciliation)
        if sql:find('synex_group_registry_owner_syncs', 1, true) then
          beginWrites = beginWrites + 1
          if sql:find('INSERT INTO', 1, true) then
            syncRow = { owner_resource = parameters[1], owner_epoch = parameters[2],
              begin_key = parameters[3], generation = 1, active = 1 }
            return { affectedRows = 1 }
          end
          assert(syncRow and parameters[5] == syncRow.generation)
          syncRow.owner_epoch, syncRow.begin_key = parameters[1], parameters[2]
          syncRow.generation = parameters[3]
          syncRow.active = 1
          return { affectedRows = 1 }
        end
        for tableName, tableRows in pairs(rows) do
          if sql:find(tableName, 1, true) then
            if reconciliation then reconciliationWrites = reconciliationWrites + 1
            else beginWrites = beginWrites + 1 end
            local changed = 0
            for _, row in ipairs(tableRows) do
              local epochMatches = not reconciliation
                or tonumber(row.owner_epoch) ~= tonumber(parameters[2])
              if row.owner_resource == parameters[1] and row.status == 'active'
                  and epochMatches then
                row.status, row.version = 'disabled', row.version + 1
                changed = changed + 1
              end
            end
            return { affectedRows = changed }
          end
        end
        error('unexpected registry synchronization write')
      end
      local tx = {
        one = function(sql, parameters)
          assert(sql:find('synex_group_registry_owner_syncs', 1, true)
            and parameters[1] == owner)
          return syncRow and copy(syncRow) or nil
        end,
        query = function(sql, parameters) return write(sql, parameters, false) end
      }
      local registries = {
        groupTypes = Registry.create({ maximumEntries = 16, maximumPerOwner = 8 }),
        relationTypes = Registry.create({ maximumEntries = 16, maximumPerOwner = 8 }),
        attributeSchemas = Registry.create({ maximumEntries = 16, maximumPerOwner = 8 }),
        dutyStates = Registry.create({ maximumEntries = 16, maximumPerOwner = 8 })
      }
      assert(registries.groupTypes:replace(owner, 1, 'group_type:alpha', {
        publicId = 'groups_type_alpha_01', key = 'alpha', version = 1
      }))
      assert(registries.relationTypes:replace(owner, 1, 'relation_type:beta', {
        publicId = 'groups_relation_beta1', key = 'beta', version = 1
      }))
      local coordinator = createCoordinator({
        registries = registries,
        query = function(sql, parameters)
          if sql:find('begin_key', 1, true)
              and sql:find('synex_group_registry_owner_syncs', 1, true) then
            return { copy(syncRow) }
          end
          if sql:find('FROM synex_group_types', 1, true)
              and parameters[1] == 'alpha' and rows.synex_group_types[1].status == 'active' then
            return { copy(rows.synex_group_types[1]) }
          end
          error('unexpected selective registry refresh query')
        end,
        startTransaction = function(handler)
          return handler(function(sql, parameters) return write(sql, parameters, true) end)
        end
      })
      local context = { caller = owner, callerEpoch = 2 }
      local request = { idempotency_key = 'registry-boot-epoch-2' }
      local runtime = { requireRegistryOwnerEpoch = function(requestOwner, requestEpoch)
        assert(requestOwner == owner and requestEpoch == 2)
        return true, nil
      end }
      local response, responseError, effects = handlers.registries_begin(
        tx, request, runtime, context)
      assert(responseError == nil and response.generation == 1
        and response.owner_epoch == 2 and response.replayed == false and #effects == 0)
      assert(syncRow.owner_epoch == 2 and beginWrites == 5)
      assert(rows.synex_group_types[1].status == 'disabled'
        and rows.synex_group_relation_types[1].status == 'disabled')

      local synchronized, synchronizationError = coordinator:refresh(
        'registries_begin', request, context, response)
      assert(synchronizationError == nil and synchronized.removed == 2
        and synchronized.replayed == false)
      local oldAlpha, oldAlphaError = registries.groupTypes:get('group_type:alpha')
      local oldBeta, oldBetaError = registries.relationTypes:get('relation_type:beta')
      assert(oldAlpha == nil and oldAlphaError.code == 'REGISTRY_KEY_NOT_FOUND')
      assert(oldBeta == nil and oldBetaError.code == 'REGISTRY_KEY_NOT_FOUND')

      rows.synex_group_types[1].owner_epoch = 2
      rows.synex_group_types[1].schema_version = 2
      rows.synex_group_types[1].status = 'active'
      rows.synex_group_types[1].version = 3
      local refreshed, refreshError = coordinator:refresh(
        'types_register', { type = 'alpha' }, context, nil, {
          { registry = 'groupTypes', owner = owner, epoch = 2, generation = 1,
            key = 'group_type:alpha', value = {} }
        })
      assert(refreshError == nil and refreshed)
      local alpha, _, alphaOwner = registries.groupTypes:get('group_type:alpha')
      local beta, betaError = registries.relationTypes:get('relation_type:beta')
      assert(alpha.version == 3 and alphaOwner.epoch == 2)
      assert(beta == nil and betaError.code == 'REGISTRY_KEY_NOT_FOUND')
      assert(rows.synex_group_relation_types[1].status == 'disabled')

      local writesBeforeReplay = beginWrites
      local replay, replayError = handlers.registries_begin(tx, request, runtime, context)
      assert(replayError == nil and replay.replayed == true and replay.generation == 1)
      local replayed, replayRefreshError = coordinator:refresh(
        'registries_begin', request, context, replay)
      assert(replayRefreshError == nil and replayed.replayed == true and replayed.removed == 0)
      assert(beginWrites == writesBeforeReplay)
      local alphaAfterReplay, _, ownerAfterReplay = registries.groupTypes:get('group_type:alpha')
      assert(alphaAfterReplay.version == 3 and ownerAfterReplay.epoch == 2)
      return table.concat({ synchronized.removed, alphaAfterReplay.version,
        beginWrites, reconciliationWrites, replayed.removed }, ':')
    `);
    assert.equal(result, '2:3:5:0:0');
  } finally {
    engine.global.close();
  }
});

test('failed registry begin does not mutate the committed runtime snapshot', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`
      local Foundation = require 'server.foundation'
      local Registry = require 'server.domain.registry'
      local handler = require('server.persistence.extension_registries')(Foundation)
        .execute.registries_begin
      local registry = Registry.create({ maximumEntries = 8, maximumPerOwner = 8 })
      assert(registry:replace('vendor_groups', 1, 'group_type:alpha', { version = 1 }))
      assert(registry:replace('vendor_groups', 1, 'group_type:beta', { version = 1 }))
      local queryCalls = 0
      local response, responseError = handler({
        one = function() return nil end,
        query = function()
          queryCalls = queryCalls + 1
          return { affectedRows = 0 }
        end
      }, { idempotency_key = 'registry-failed-boot' }, {
        requireRegistryOwnerEpoch = function() return true, nil end
      }, {
        caller = 'vendor_groups', callerEpoch = 2
      })
      assert(response == nil and responseError.code == 'CONCURRENT_MODIFICATION'
        and responseError.retryable == true and queryCalls == 1)
      local alpha, _, alphaOwner = registry:get('group_type:alpha')
      local beta, _, betaOwner = registry:get('group_type:beta')
      assert(alpha.version == 1 and alphaOwner.epoch == 1)
      assert(beta.version == 1 and betaOwner.epoch == 1)
      return responseError.code .. ':' .. registry:stats().entries
    `);
    assert.equal(result, 'CONCURRENT_MODIFICATION:2');
  } finally {
    engine.global.close();
  }
});

test('registry begin aborts when its owner epoch stops while waiting for the synchronization lock', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`
      local Foundation = require 'server.foundation'
      local handler = require('server.persistence.extension_registries')(Foundation)
        .execute.registries_begin
      local fenceChecks, writes = 0, 0
      local response, responseError = handler({
        one = function()
          return { owner_resource = 'vendor_groups', owner_epoch = 1,
            begin_key = 'registry-old-epoch', generation = 4, active = 1 }
        end,
        query = function()
          writes = writes + 1
          return { affectedRows = 1 }
        end
      }, { idempotency_key = 'registry-new-epoch' }, {
        requireRegistryOwnerEpoch = function()
          fenceChecks = fenceChecks + 1
          if fenceChecks == 1 then return true, nil end
          return nil, Foundation.domainError('STALE_RESOURCE',
            'The extension registry owner epoch has stopped.')
        end
      }, { caller = 'vendor_groups', callerEpoch = 2 })
      assert(response == nil and responseError.code == 'STALE_RESOURCE')
      assert(fenceChecks == 2 and writes == 0)
      return responseError.code .. ':' .. fenceChecks .. ':' .. writes
    `);
    assert.equal(result, 'STALE_RESOURCE:2:0');
  } finally {
    engine.global.close();
  }
});

test('post-commit registry cleanup failure returns retryable failure and leaves its generation unapplied for convergence', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`
      local Foundation = require 'server.foundation'
      local Registry = require 'server.domain.registry'
      local createCoordinator = require('server.extension_registries')(Foundation)
      local groupTypes = Registry.create({ maximumEntries = 8, maximumPerOwner = 8 })
      local relationTypes = Registry.create({ maximumEntries = 8, maximumPerOwner = 8 })
      local dutyStates = Registry.create({ maximumEntries = 8, maximumPerOwner = 8 })
      local attributeSchemas = Registry.create({ maximumEntries = 8, maximumPerOwner = 8 })
      local cleanupCalls, failNext = 0, false
      local originalCleanup = relationTypes.cleanupOwner
      relationTypes.cleanupOwner = function(self, owner, epoch)
        cleanupCalls = cleanupCalls + 1
        if failNext then
          failNext = false
          return nil, Foundation.domainError('DATABASE_ERROR',
            'Injected post-commit cleanup failure.', true)
        end
        return originalCleanup(self, owner, epoch)
      end
      local syncRow = { owner_epoch = 1, begin_key = 'registry-initial-owner',
        generation = 6, active = 1 }
      local coordinator = createCoordinator({
        registries = { groupTypes = groupTypes, relationTypes = relationTypes,
          dutyStates = dutyStates, attributeSchemas = attributeSchemas },
        query = function(sql, parameters)
          assert(sql:find('synex_group_registry_owner_syncs', 1, true)
            and parameters[1] == 'vendor_groups')
          return { syncRow }
        end,
        startTransaction = function() error('registry begin refresh must not transact') end
      })
      assert(coordinator:refresh('registries_begin', {
        idempotency_key = syncRow.begin_key
      }, { caller = 'vendor_groups', callerEpoch = 1 }, {
        owner_resource = 'vendor_groups', owner_epoch = 1, generation = 6,
        status = 'synchronized', replayed = false
      }))
      assert(coordinator:apply({ registry = 'groupTypes', owner = 'vendor_groups',
        epoch = 1, generation = 6, key = 'group_type:alpha', value = { version = 1 } }))
      assert(coordinator:apply({ registry = 'relationTypes', owner = 'vendor_groups',
        epoch = 1, generation = 6, key = 'relation_type:beta', value = { version = 1 } }))
      cleanupCalls, failNext = 0, true
      syncRow.owner_epoch, syncRow.begin_key = 2, 'registry-cleanup-retry'
      syncRow.generation, syncRow.active = 7, 1
      local request = { idempotency_key = 'registry-cleanup-retry' }
      local context = { caller = 'vendor_groups', callerEpoch = 2 }
      local response = { owner_resource = 'vendor_groups', owner_epoch = 2,
        generation = 7, status = 'synchronized', replayed = false }
      local first, firstError = coordinator:refresh(
        'registries_begin', request, context, response)
      assert(first == nil and firstError.code == 'DATABASE_ERROR'
        and firstError.retryable == true and cleanupCalls == 1)
      local fenced, fencedError = relationTypes:get('relation_type:beta')
      assert(fenced == nil and fencedError.code == 'REGISTRY_KEY_NOT_FOUND')

      local retried, retryError = coordinator:refresh(
        'registries_begin', request, context, response)
      assert(retryError == nil and retried.generation == 7
        and retried.replayed == false and cleanupCalls == 2)
      local alpha, alphaError = groupTypes:get('group_type:alpha')
      local beta, betaError = relationTypes:get('relation_type:beta')
      assert(alpha == nil and alphaError.code == 'REGISTRY_KEY_NOT_FOUND')
      assert(beta == nil and betaError.code == 'REGISTRY_KEY_NOT_FOUND')

      local replayed, replayError = coordinator:refresh(
        'registries_begin', request, context, response)
      assert(replayError == nil and replayed.replayed == true
        and replayed.removed == 0 and cleanupCalls == 2)
      return firstError.code .. ':' .. retried.removed .. ':' .. cleanupCalls
    `);
    assert.equal(result, 'DATABASE_ERROR:1:2');
  } finally {
    engine.global.close();
  }
});
