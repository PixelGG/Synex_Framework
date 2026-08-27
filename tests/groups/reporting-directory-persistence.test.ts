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
  await preload(engine, 'server.domain.constants', 'resources/synex_groups/server/domain/constants.lua');
  await preload(engine, 'server.domain.lifecycle', 'resources/synex_groups/server/domain/lifecycle.lua');
  await preload(
    engine,
    'server.persistence.memberships_shared',
    'resources/synex_groups/server/persistence/memberships_shared.lua',
  );
  await preload(
    engine,
    'server.persistence.memberships_reporting',
    'resources/synex_groups/server/persistence/memberships_reporting.lua',
  );
  await preload(
    engine,
    'server.persistence.memberships_read',
    'resources/synex_groups/server/persistence/memberships_read.lua',
  );
  const foundation = await readFile(
    path.join(root, 'resources', 'synex_groups', 'server', 'foundation.lua'),
    'utf8',
  );
  const validation = await readFile(
    path.join(root, 'resources', 'synex_groups', 'server', 'validation.lua'),
    'utf8',
  );
  await engine.doString(`
    Foundation = assert(load(${JSON.stringify(foundation)}, '@server/foundation.lua'))()
    Validation = assert(load(${JSON.stringify(validation)}, '@server/validation.lua'))()(Foundation)
    Reporting = require('server.persistence.memberships_reporting')(Foundation)
    MembershipReads = require('server.persistence.memberships_read')(Foundation)

    function reportingRuntime(memberships)
      local runtime = {}
      function runtime.requireMembership(_, publicId)
        local membership = memberships[publicId]
        if membership == nil then
          return nil, Foundation.domainError('MEMBERSHIP_NOT_FOUND', 'missing')
        end
        return membership
      end
      function runtime.authorize(_, groupId, actorId, capability)
        runtime.lastAuthorization = {
          groupId = groupId, actorId = actorId, capability = capability
        }
        return { public_id = 'member_actor_0001' }
      end
      function runtime.reason() return 'reporting_changed' end
      function runtime.touchGroup() return true end
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
          groupId = groupId, characterId = characterId, before = before,
          after = after, reason = reason, version = version
        }
      end
      return runtime
    end
  `);
}

test('reporting contract and persistence remain server-local, CAS guarded, and closure-backed', async () => {
  const [contractSource, resourceSource, reporting, reads, service] = await Promise.all([
    readFile(path.join(root, 'resources/synex_groups/groups.contracts.json'), 'utf8'),
    readFile(path.join(root, 'resources/synex_groups/synex.resource.json'), 'utf8'),
    readFile(path.join(root, 'resources/synex_groups/server/persistence/memberships_reporting.lua'), 'utf8'),
    readFile(path.join(root, 'resources/synex_groups/server/persistence/memberships_read.lua'), 'utf8'),
    readFile(path.join(root, 'resources/synex_groups/server/service.lua'), 'utf8'),
  ]);
  const contracts = JSON.parse(contractSource) as {
    contracts: Array<{
      name: string;
      network: string;
      capability: string;
      idempotent?: boolean;
      input: { required: string[]; properties: Record<string, unknown> };
    }>;
  };
  const resource = JSON.parse(resourceSource) as { contracts: { provide: string[] } };
  const contract = contracts.contracts.find(({ name }) => name === 'synex.groups.reporting.set');
  assert.ok(contract);
  assert.equal(contract.network, 'none');
  assert.equal(contract.capability, 'synex.groups.reporting.manage');
  assert.equal(contract.idempotent, true);
  assert.deepEqual(contract.input.required, [
    'idempotency_key',
    'actor_character_id',
    'membership_id',
    'reason',
    'expected_version',
  ]);
  assert.ok(contract.input.properties.reports_to_membership_id);
  assert.ok(resource.contracts.provide.includes('synex.groups.reporting.set'));

  for (const source of [reporting, reads, service]) {
    assert.doesNotMatch(
      source,
      /RegisterNetEvent|RegisterServerEvent|TriggerClientEvent|PerformHttpRequest/u,
    );
  }
  assert.match(reporting, /synex\.groups\.reporting\.manage/u);
  assert.match(reporting, /WHERE id = \? AND version = \?/u);
  assert.match(reporting, /REPORTING_CYCLE/u);
  assert.match(reporting, /DELETE reporting_path[\s\S]*synex_group_reporting_closure/u);
  assert.match(reporting, /INSERT INTO synex_group_reporting_closure/u);
  assert.match(reads, /reports_to_public_id/u);
  assert.doesNotMatch(reads, /directory_list\s*=\s*handlers\.read\.members_list/u);
});

test('reporting validation rejects untrusted fields and accepts nullable edge removal', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`
      local base = {
        idempotency_key = 'reporting:test:0001',
        actor_character_id = 'character_actor_0001',
        membership_id = 'membership_target_0001',
        reason = 'manager_changed',
        expected_version = 4
      }
      local validClear, clearError = Validation.operation('reporting_set', base)
      assert(validClear == true and clearError == nil)
      base.reports_to_membership_id = 'membership_manager_0001'
      local validSet, setError = Validation.operation('reporting_set', base)
      assert(validSet == true and setError == nil)
      base.reports_to_membership_id = 'bad'
      local invalidId, idError = Validation.operation('reporting_set', base)
      assert(invalidId == nil and idError.code == 'VALIDATION_FAILED')
      base.reports_to_membership_id = nil
      base.client_authorized = true
      local invalidField, fieldError = Validation.operation('reporting_set', base)
      assert(invalidField == nil and fieldError.code == 'VALIDATION_FAILED')
      return 'validated'
    `);
    assert.equal(result, 'validated');
  } finally {
    engine.global.close();
  }
});

test('reporting mutation fails stale CAS and cycles before persistent writes', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`
      local target = {
        id = 31, public_id = 'membership_target_0001', group_id = 10,
        group_public_id = 'group_alpha_0001', character_id = 'character_target_0001',
        lifecycle_state = 'ACTIVE', version = 4
      }
      local manager = {
        id = 32, public_id = 'membership_manager_0001', group_id = 10,
        group_public_id = 'group_alpha_0001', character_id = 'character_manager_0001',
        lifecycle_state = 'ACTIVE', version = 2
      }
      local runtime = reportingRuntime({
        membership_target_0001 = target,
        membership_manager_0001 = manager
      })
      local tx = { writes = 0 }
      function tx.one(sql)
        if sql:find('SELECT 1 AS creates_cycle', 1, true) then
          return { creates_cycle = 1 }
        end
        error('unexpected read')
      end
      function tx.query() tx.writes = tx.writes + 1 return {} end
      function tx.affected() tx.writes = tx.writes + 1 return 1 end

      local staleValue, staleError = Reporting.execute.reporting_set(tx, {
        actor_character_id = 'character_actor_0001',
        membership_id = 'membership_target_0001',
        expected_version = 3,
        reason = 'stale'
      }, runtime)
      assert(staleValue == nil and staleError.code == 'CONCURRENT_MODIFICATION')
      assert(tx.writes == 0)

      local cycleValue, cycleError = Reporting.execute.reporting_set(tx, {
        actor_character_id = 'character_actor_0001',
        membership_id = 'membership_target_0001',
        reports_to_membership_id = 'membership_manager_0001',
        expected_version = 4,
        reason = 'cycle'
      }, runtime)
      assert(cycleValue == nil and cycleError.code == 'REPORTING_CYCLE')
      assert(tx.writes == 0)
      assert(runtime.lastAuthorization.capability == 'synex.groups.reporting.manage')
      return staleError.code .. ':' .. cycleError.code
    `);
    assert.equal(result, 'CONCURRENT_MODIFICATION:REPORTING_CYCLE');
  } finally {
    engine.global.close();
  }
});

test('reporting mutation rebuilds closure and directory visibility is actor-scoped', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`
      local target = {
        id = 31, public_id = 'membership_target_0001', group_id = 10,
        group_public_id = 'group_alpha_0001', character_id = 'character_target_0001',
        lifecycle_state = 'ACTIVE', version = 4
      }
      local manager = {
        id = 32, public_id = 'membership_manager_0001', group_id = 10,
        group_public_id = 'group_alpha_0001', character_id = 'character_manager_0001',
        lifecycle_state = 'ACTIVE', version = 2
      }
      local runtime = reportingRuntime({
        membership_target_0001 = target,
        membership_manager_0001 = manager
      })
      local tx = { queries = {} }
      function tx.one(sql)
        if sql:find('SELECT 1 AS creates_cycle', 1, true) then return nil end
        if sql:find('synex_group_reporting_edges', 1, true) then return nil end
        error('unexpected read')
      end
      function tx.query(sql, parameters)
        tx.queries[#tx.queries + 1] = { sql = sql, parameters = parameters }
        return {}
      end
      function tx.affected(sql, parameters)
        tx.queries[#tx.queries + 1] = { sql = sql, parameters = parameters }
        return 1
      end
      local value, mutationError = Reporting.execute.reporting_set(tx, {
        actor_character_id = 'character_actor_0001',
        membership_id = 'membership_target_0001',
        reports_to_membership_id = 'membership_manager_0001',
        expected_version = 4,
        reason = 'manager_changed'
      }, runtime)
      assert(mutationError == nil and value.version == 5 and value.status == 'assigned')
      assert(#tx.queries == 4)
      assert(tx.queries[1].sql:find('WHERE id = ? AND version = ?', 1, true))
      assert(tx.queries[2].sql:find('INSERT INTO synex_group_reporting_edges', 1, true))
      assert(tx.queries[3].sql:find('DELETE reporting_path', 1, true))
      assert(tx.queries[4].sql:find('INSERT INTO synex_group_reporting_closure', 1, true))

      local function directory(active, management, actorId)
        local directoryRuntime = {}
        function directoryRuntime.requireGroup()
          return { id = 10, public_id = 'group_alpha_0001' }
        end
        function directoryRuntime.authorize(_, _, _, capability)
          if management and capability == 'synex.groups.directory.manage' then
            return { public_id = 'membership_actor_0001' }
          end
          return nil, Foundation.domainError('INSUFFICIENT_PERMISSION', 'denied')
        end
        local directoryTx = {}
        function directoryTx.one(sql)
          assert(sql:find("profile.lifecycle_state = 'ACTIVE'", 1, true))
          return active and { id = 99 } or nil
        end
        function directoryTx.many(sql, parameters)
          assert(sql:find("profile.visibility = 'public'", 1, true))
          assert(sql:find('profile.character_id = ?', 1, true))
          assert(sql:find("profile.visibility = 'members'", 1, true))
          assert(sql:find("profile.visibility = 'management'", 1, true))
          local rows = {
            { membership_id = 'membership_public_0001', group_id = 'group_alpha_0001',
              character_id = 'character_public_0001', status = 'ACTIVE',
              visibility = 'public', reports_to_public_id = 'membership_manager_0001',
              joined_at = '2026-08-25T10:00:00Z', version = 1 },
            { membership_id = 'membership_members_0001', group_id = 'group_alpha_0001',
              character_id = 'character_members_0001', status = 'ACTIVE',
              visibility = 'members', joined_at = '2026-08-25T10:00:00Z', version = 1 },
            { membership_id = 'membership_management_0001', group_id = 'group_alpha_0001',
              character_id = 'character_management_0001', status = 'ACTIVE',
              visibility = 'management', joined_at = '2026-08-25T10:00:00Z', version = 1 },
            { membership_id = 'membership_private_0001', group_id = 'group_alpha_0001',
              character_id = actorId, status = active and 'ACTIVE' or 'LEFT',
              visibility = 'private', joined_at = '2026-08-25T10:00:00Z', version = 1 }
          }
          local visible = {}
          for _, row in ipairs(rows) do
            if row.visibility == 'public' or row.character_id == parameters[4]
                or parameters[5] == 1 and row.visibility == 'members'
                or parameters[6] == 1 and row.visibility == 'management' then
              visible[#visible + 1] = row
            end
          end
          return visible
        end
        local value, directoryError = MembershipReads.read.directory_list(directoryTx, {
          actor_character_id = actorId, group_id = 'group_alpha_0001', limit = 50
        }, directoryRuntime)
        assert(directoryError == nil)
        return value
      end

      local outsider = directory(false, false, 'character_outsider_0001')
      local member = directory(true, false, 'character_member_0001')
      local management = directory(true, true, 'character_manager_0001')
      assert(#outsider.items == 2)
      assert(#member.items == 3)
      assert(#management.items == 4)
      assert(outsider.items[1].reports_to_public_id == 'membership_manager_0001')
      return tostring(#outsider.items) .. ':' .. tostring(#member.items)
        .. ':' .. tostring(#management.items)
    `);
    assert.equal(result, '2:3:4');
  } finally {
    engine.global.close();
  }
});
