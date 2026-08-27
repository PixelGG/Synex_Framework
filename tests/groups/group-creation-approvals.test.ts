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

async function bootstrapFoundation(engine: LuaEngine): Promise<void> {
  const foundation = await readFile(
    path.join(root, 'resources', 'synex_groups', 'server', 'foundation.lua'),
    'utf8',
  );
  await preload(engine, 'server.domain.constants', 'resources/synex_groups/server/domain/constants.lua');
  await preload(engine, 'server.domain.lifecycle', 'resources/synex_groups/server/domain/lifecycle.lua');
  await preload(
    engine,
    'server.persistence.organizations_shared',
    'resources/synex_groups/server/persistence/organizations_shared.lua',
  );
  await engine.doString(`
    Foundation = assert(load(${JSON.stringify(foundation)}, '@server/foundation.lua'))()
    function scalarJson(value)
      if type(value) == 'nil' then return 'null' end
      if type(value) == 'boolean' or type(value) == 'number' then return tostring(value) end
      if type(value) == 'string' then return string.format('%q', value) end
      error('unexpected JSON scalar')
    end
    function approvalRuntime(overrides)
      overrides = overrides or {}
      local allocated = 0
      local runtime = { effects = {}, permissionChecks = {} }
      runtime.id = function(namespace)
        allocated = allocated + 1
        return namespace .. '_' .. string.format('%08d', allocated)
      end
      runtime.reason = function(_, fallback) return fallback end
      runtime.success = function(id, kind, status, version)
        return { entity_id = id, entity_type = kind, status = status,
          version = version, replayed = false }
      end
      runtime.effect = function(action, entityType, entityId, groupId, characterId,
          before, after, reason, version)
        local effect = { action = action, entityType = entityType, entityId = entityId,
          groupId = groupId, characterId = characterId, before = before, after = after,
          reason = reason, version = version }
        runtime.effects[#runtime.effects + 1] = effect
        return effect
      end
      runtime.jsonEncode = scalarJson
      runtime.jsonDecode = overrides.jsonDecode or function() error('unexpected decode') end
      runtime.checkCorePermission = function(characterId, permission)
        runtime.permissionChecks[#runtime.permissionChecks + 1] = {
          characterId = characterId, permission = permission
        }
        if overrides.checkCorePermission then
          return overrides.checkCorePermission(characterId, permission)
        end
        return true, nil
      end
      return runtime
    end
  `);
}

test('approval-backed create journals one pending request and replays without group materialization', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrapFoundation(engine);
    await preload(
      engine,
      'server.persistence.organizations_creation',
      'resources/synex_groups/server/persistence/organizations_creation.lua',
    );
    const result = await engine.doString(`
      local Lifecycle = require('server.persistence.organizations_creation')(Foundation)
      local request = {
        idempotency_key = 'creation-idem-0001', actor_character_id = 'character_00000001',
        type = 'business', slug = 'a-b', name = 'Alpha Business', label = 'Alpha'
      }
      local writes, persistedJson
      local replayRow
      local tx = {}
      tx.one = function(sql)
        if sql:find('FROM \`synex_group_types\`', 1, true) then
          return { id = 3, type_key = 'business', creation_mode = 'dynamic',
            dynamic_creation = 1, create_permission = 'synex.groups.create.business',
            required_approvals = 2,
            approval_permission = 'synex.groups.create.approve.business',
            schema_version = 4, membership_limit = 50, active_membership_limit = 20,
            hierarchy_enabled = 1, status = 'active', version = 7 }
        end
        if sql:find('requested_by_ref', 1, true) and sql:find('idempotency_key', 1, true) then
          return replayRow
        end
        if sql:find('synex_group_type_membership_states', 1, true) then
          return { state_key = 'ACTIVE' }
        end
        if sql:find('WHERE \`group_key\` = ?', 1, true) then return nil end
        if sql:find('active_slug', 1, true) then return nil end
        error('unexpected pending-create query: ' .. sql)
      end
      tx.many = function(sql)
        if sql:find('synex_group_type_default_', 1, true) then return {} end
        error('unexpected pending-create list: ' .. sql)
      end
      tx.query = function(sql, parameters)
        writes = (writes or 0) + 1
        if sql:find('INSERT IGNORE INTO \`synex_group_slug_reservations\`', 1, true) then
          assert(parameters[1] == request.slug)
          assert(parameters[2] == 'creation_request')
          assert(parameters[3] == 'groups_creation_00000001')
          return { affectedRows = 1 }
        end
        assert(sql:find('INSERT INTO \`synex_group_creation_requests\`', 1, true))
        persistedJson = parameters[6]
        return { affectedRows = 1 }
      end
      local runtime = approvalRuntime()
      local pending, pendingError, effects = Lifecycle.execute.create(tx, request, runtime)
      assert(pendingError == nil and pending.entity_type == 'group_creation_request')
      assert(pending.status == 'pending' and pending.version == 1 and pending.replayed == false)
      assert(writes == 2 and #effects == 1 and effects[1].action == 'group.creation_requested')
      assert(#runtime.permissionChecks == 1)
      replayRow = { public_id = pending.entity_id, request_json = persistedJson,
        status = 'pending', version = 1 }
      local replay, replayError, replayEffects = Lifecycle.execute.create(tx, request, runtime)
      assert(replayError == nil and replay.entity_id == pending.entity_id and replay.replayed == true)
      assert(writes == 2 and #replayEffects == 0)
      return table.concat({ pending.status, request.slug, tostring(writes), tostring(#effects) }, ':')
    `);
    assert.equal(result, 'pending:a-b:2:1');
  } finally {
    engine.global.close();
  }
});

test('slug reservations serialize independent creates and transfer ownership without a rename gap', async () => {
  const migration = await readFile(
    path.join(
      root,
      'resources',
      'synex_groups',
      'migrations',
      '025_dynamic_group_creation_approvals.sql',
    ),
    'utf8',
  );
  assert.match(migration, /CREATE TABLE IF NOT EXISTS `synex_group_slug_reservations`/);
  assert.match(migration, /PRIMARY KEY \(`slug`\)/);
  assert.match(
    migration,
    /INSERT IGNORE INTO `synex_group_slug_reservations`[\s\S]*FROM `synex_groups`/,
  );
  assert.match(
    migration,
    /INSERT IGNORE INTO `synex_group_slug_reservations`[\s\S]*FROM `synex_group_creation_requests`/,
  );

  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrapFoundation(engine);
    const result = await engine.doString(`
      local Shared = require('server.persistence.organizations_shared')(Foundation)
      local rows = {}
      local function transaction()
        return {
          query = function(_, parameters)
            local slug, ownerKind, ownerId = parameters[1], parameters[2], parameters[3]
            if rows[slug] then return { affectedRows = 0 } end
            rows[slug] = { owner_kind = ownerKind, owner_public_id = ownerId, version = 1 }
            return { affectedRows = 1 }
          end,
          one = function(_, parameters)
            local row = rows[parameters[1]]
            if not row then return nil end
            return { owner_kind = row.owner_kind, owner_public_id = row.owner_public_id,
              version = row.version }
          end,
          affected = function(sql, parameters)
            if sql:find('UPDATE \`synex_group_slug_reservations\`', 1, true) then
              local row = rows[parameters[3]]
              if not row or row.owner_kind ~= parameters[4]
                  or row.owner_public_id ~= parameters[5] or row.version ~= parameters[6] then
                return 0
              end
              row.owner_kind, row.owner_public_id = parameters[1], parameters[2]
              row.version = row.version + 1
              return 1
            end
            local row = rows[parameters[1]]
            if not row or row.owner_kind ~= parameters[2]
                or row.owner_public_id ~= parameters[3] then return 0 end
            rows[parameters[1]] = nil
            return 1
          end
        }
      end

      local directTx, approvalTx = transaction(), transaction()
      local first, firstError = Shared.reserveSlug(
        directTx, 'alpha', 'group', 'groups_group_00000001')
      assert(first and firstError == nil)
      local conflict, conflictError = Shared.reserveSlug(
        approvalTx, 'alpha', 'creation_request', 'groups_creation_00000001')
      assert(conflict == nil and conflictError.code == 'GROUP_EXISTS')

      local requestReservation = assert(Shared.reserveSlug(
        approvalTx, 'beta', 'creation_request', 'groups_creation_00000001'))
      local transferred, transferError = Shared.transferSlugReservation(
        approvalTx, 'beta', 'creation_request', 'groups_creation_00000001',
        'group', 'groups_group_00000002', requestReservation.version)
      assert(transferred and transferError == nil)

      -- A rename first acquires the replacement while the current reservation
      -- still exists, then releases the old row in the same transaction.
      local renamed = assert(Shared.reserveSlug(
        directTx, 'alpha-renamed', 'group', 'groups_group_00000001'))
      assert(renamed and rows.alpha and rows['alpha-renamed'])
      assert(Shared.requireSlugReservation(
        directTx, 'alpha', 'group', 'groups_group_00000001'))
      assert(Shared.releaseSlugReservation(
        directTx, 'alpha', 'group', 'groups_group_00000001'))
      assert(rows.alpha == nil and rows['alpha-renamed'] ~= nil)
      return table.concat({ conflictError.code, rows.beta.owner_kind,
        rows.beta.owner_public_id, rows['alpha-renamed'].owner_public_id }, ':')
    `);
    assert.equal(
      result,
      'GROUP_EXISTS:group:groups_group_00000002:groups_group_00000001',
    );
  } finally {
    engine.global.close();
  }
});

async function bootstrapApprovalPersistence(engine: LuaEngine): Promise<void> {
  await bootstrapFoundation(engine);
  await engine.doString(`
    package.preload['server.persistence.organizations_creation'] = function()
      return function()
        return { execute = { create = function(_, request, runtime, context)
          assert(context.approvedCreation.permissionsRevalidated == true)
          return runtime.success('groups_group_00000001', 'group',
            request.status and request.status:lower() or 'active', 1), nil, {
              runtime.effect('group.created', 'group', 'groups_group_00000001',
                'groups_group_00000001', request.actor_character_id, nil,
                { version = 1 }, 'group_created', 1),
              runtime.effect('membership.activated', 'membership', 'groups_member_00000001',
                'groups_group_00000001', request.actor_character_id, nil,
                { version = 1 }, 'group_created', 1)
            }
        end } }
      end
    end
  `);
  await preload(
    engine,
    'server.persistence.organizations_creation_approvals',
    'resources/synex_groups/server/persistence/organizations_creation_approvals.lua',
  );
}

test('creation decisions reject self, revoked authority, duplicate actors, and stale concurrent versions', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrapApprovalPersistence(engine);
    const result = await engine.doString(`
      local Approvals = require('server.persistence.organizations_creation_approvals')(Foundation)
      local row = {
        id = 41, public_id = 'groups_creation_00000001', group_type_id = 3,
        requested_by_ref = 'character_00000001', idempotency_key = 'creation-idem-0001',
        requested_slug = 'alpha', request_json = '{}', required_approvals = 2,
        approval_count = 0, creator_permission = 'synex.groups.create.business',
        approval_permission = 'synex.groups.create.approve.business',
        type_schema_version = 4, type_version = 7, status = 'pending', version = 1,
        is_expired = 0, expires_at = '2026-08-27T00:00:00.000000Z',
        created_at = '2026-08-25T00:00:00.000000Z',
        updated_at = '2026-08-25T00:00:00.000000Z', type_key = 'business',
        type_status = 'active', current_type_schema_version = 4,
        current_type_version = 7,
        current_creator_permission = 'synex.groups.create.business',
        current_required_approvals = 2,
        current_approval_permission = 'synex.groups.create.approve.business'
      }
      local decisions, duplicate, writes = {}, false, 0
      local tx = {}
      tx.one = function(sql)
        if sql:find('FROM \`synex_group_creation_requests\`', 1, true) then return row end
        if sql:find('synex_group_creation_approvals', 1, true) then
          return duplicate and { id = 99 } or nil
        end
        error('unexpected decision query: ' .. sql)
      end
      tx.many = function(sql)
        assert(sql:find('synex_group_creation_approvals', 1, true))
        return decisions
      end
      tx.query = function() writes = writes + 1 return { affectedRows = 1 } end
      tx.affected = function() writes = writes + 1 return 1 end

      local selfRuntime = approvalRuntime()
      local _, selfError = Approvals.execute.creation_requests_approve(tx, {
        idempotency_key = 'approval-idem-0001', actor_character_id = 'character_00000001',
        creation_request_id = row.public_id, expected_version = 1, reason = 'approve'
      }, selfRuntime)
      assert(selfError.code == 'CREATOR_CANNOT_DECIDE' and writes == 0)

      local deniedRuntime = approvalRuntime({ checkCorePermission = function()
        return nil, Foundation.domainError('INSUFFICIENT_PERMISSION', 'revoked')
      end })
      local _, deniedError = Approvals.execute.creation_requests_approve(tx, {
        idempotency_key = 'approval-idem-0002', actor_character_id = 'character_00000002',
        creation_request_id = row.public_id, expected_version = 1, reason = 'approve'
      }, deniedRuntime)
      assert(deniedError.code == 'INSUFFICIENT_PERMISSION' and writes == 0)

      row.approval_count, row.version = 1, 2
      decisions = { { public_id = 'groups_approval_00000001',
        approver_character_ref = 'character_00000002', decision = 'approved',
        permission_name = row.approval_permission, request_version = 1,
        created_at = '2026-08-25T00:01:00.000000Z' } }
      duplicate = true
      local _, duplicateError = Approvals.execute.creation_requests_approve(tx, {
        idempotency_key = 'approval-idem-0003', actor_character_id = 'character_00000002',
        creation_request_id = row.public_id, expected_version = 2, reason = 'approve'
      }, approvalRuntime())
      assert(duplicateError.code == 'APPROVAL_ALREADY_DECIDED' and writes == 0)

      duplicate = false
      local _, staleError = Approvals.execute.creation_requests_approve(tx, {
        idempotency_key = 'approval-idem-0004', actor_character_id = 'character_00000003',
        creation_request_id = row.public_id, expected_version = 1, reason = 'approve'
      }, approvalRuntime())
      assert(staleError.code == 'CONCURRENT_MODIFICATION' and writes == 0)

      local approved, approvedError, effects = Approvals.execute.creation_requests_approve(tx, {
        idempotency_key = 'approval-idem-0005', actor_character_id = 'character_00000003',
        creation_request_id = row.public_id, expected_version = 2, reason = 'approve'
      }, approvalRuntime())
      assert(approvedError == nil and approved.status == 'approved')
      assert(approved.approval_count == 2 and approved.version == 3)
      assert(writes == 2 and #effects == 1 and effects[1].action == 'group.creation_approved')
      return table.concat({ selfError.code, deniedError.code, duplicateError.code,
        staleError.code, approved.status }, ':')
    `);
    assert.equal(
      result,
      'CREATOR_CANNOT_DECIDE:INSUFFICIENT_PERMISSION:APPROVAL_ALREADY_DECIDED:CONCURRENT_MODIFICATION:approved',
    );
  } finally {
    engine.global.close();
  }
});

test('approved execution is quorum-checked, atomic, replay-safe, and expiry is terminal', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrapApprovalPersistence(engine);
    const result = await engine.doString(`
      local Approvals = require('server.persistence.organizations_creation_approvals')(Foundation)
      local state = 'approved'
      local row = {
        id = 41, public_id = 'groups_creation_00000001', group_type_id = 3,
        requested_by_ref = 'character_00000001', idempotency_key = 'creation-idem-0001',
        requested_slug = 'alpha', request_json = '{}', required_approvals = 2,
        approval_count = 2, creator_permission = 'synex.groups.create.business',
        approval_permission = 'synex.groups.create.approve.business',
        type_schema_version = 4, type_version = 7, status = 'approved', version = 3,
        is_expired = 0, expires_at = '2026-08-27T00:00:00.000000Z',
        created_at = '2026-08-25T00:00:00.000000Z',
        updated_at = '2026-08-25T00:00:00.000000Z', type_key = 'business',
        type_status = 'active', current_type_schema_version = 4,
        current_type_version = 7,
        current_creator_permission = 'synex.groups.create.business',
        current_required_approvals = 2,
        current_approval_permission = 'synex.groups.create.approve.business'
      }
      local decisionRows = {
        { public_id = 'groups_approval_00000001', approver_character_ref = 'character_00000002',
          decision = 'approved', permission_name = row.approval_permission,
          request_version = 1, created_at = '2026-08-25T00:01:00.000000Z' },
        { public_id = 'groups_approval_00000002', approver_character_ref = 'character_00000003',
          decision = 'approved', permission_name = row.approval_permission,
          request_version = 2, created_at = '2026-08-25T00:02:00.000000Z' }
      }
      local linked, changed, released = false, 0, 0
      local tx = {}
      tx.one = function(sql)
        if sql:find('FROM \`synex_group_creation_requests\`', 1, true) then
          row.status = state
          row.target_group_public_id = linked and 'groups_group_00000001' or nil
          return row
        end
        if sql:find('FROM \`synex_groups\`', 1, true) then return { id = 81 } end
        error('unexpected execution query: ' .. sql)
      end
      tx.many = function() return decisionRows end
      tx.affected = function(sql)
        if sql:find('DELETE FROM \`synex_group_slug_reservations\`', 1, true) then
          released = released + 1
          return 1
        end
        changed = changed + 1
        linked, state = true, 'executed'
        return 1
      end
      local runtime = approvalRuntime({ jsonDecode = function()
        return { idempotency_key = 'creation-idem-0001',
          actor_character_id = 'character_00000001', type = 'business',
          slug = 'alpha', name = 'Alpha', label = 'Alpha' }
      end })
      local created, createError, effects = Approvals.execute.creation_requests_execute(tx, {
        idempotency_key = 'creation-exec:' .. row.public_id,
        creation_request_id = row.public_id, expected_version = 3,
        permissions_revalidated = true
      }, runtime, {})
      assert(createError == nil and created.entity_id == 'groups_group_00000001')
      assert(changed == 1 and #effects == 3)
      assert(effects[1].action == 'group.created')
      assert(effects[2].action == 'membership.activated')
      assert(effects[3].action == 'group.creation_executed')

      local replay, replayError, replayEffects = Approvals.execute.creation_requests_execute(tx, {
        idempotency_key = 'creation-exec:' .. row.public_id,
        creation_request_id = row.public_id, expected_version = 3,
        permissions_revalidated = true
      }, runtime, {})
      assert(replayError == nil and replay.replayed == true and #replayEffects == 0)
      assert(changed == 1)

      state, linked, row.version, row.is_expired = 'approved', false, 3, 1
      local expired, expireError, expireEffects = Approvals.execute.creation_requests_expire(tx, {
        idempotency_key = 'creation-expire:' .. row.public_id,
        creation_request_id = row.public_id
      }, runtime)
      assert(expireError == nil and expired.status == 'expired' and #expireEffects == 1)
      assert(expireEffects[1].action == 'group.creation_expired' and changed == 2)
      assert(released == 1)
      return table.concat({ created.entity_type, effects[2].action, tostring(replay.replayed),
        expired.status, tostring(changed), tostring(released) }, ':')
    `);
    assert.equal(result, 'group:membership.activated:true:expired:2:1');
  } finally {
    engine.global.close();
  }
});

test('approval coordinator rechecks every permission and immutable hook before restart reconciliation', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrapFoundation(engine);
    await preload(
      engine,
      'server.group_creation_approvals',
      'resources/synex_groups/server/group_creation_approvals.lua',
    );
    const result = await engine.doString(`
      local createCoordinator = require('server.group_creation_approvals')(Foundation)
      local execution = {
        creationRequestId = 'groups_creation_00000001', version = 3,
        request = { idempotency_key = 'creation-idem-0001',
          actor_character_id = 'character_00000001', type = 'business',
          slug = 'alpha', name = 'Alpha', label = 'Alpha' },
        requestedByCharacterId = 'character_00000001',
        creatorPermission = 'synex.groups.create.business',
        approvalPermission = 'synex.groups.create.approve.business',
        requiredApprovals = 2,
        approverCharacterIds = { 'character_00000002', 'character_00000003' }
      }
      local deniedCharacter, hookMode, executeCalls = nil, 'identity', 0
      local repository = {}
      function repository:read(operation)
        if operation == 'creation_requests_execution_context' then return execution, nil end
        if operation == 'creation_requests_reconcile' then
          return {
            { creationRequestId = execution.creationRequestId, action = 'execute' },
            { creationRequestId = 'groups_creation_00000002', action = 'expire' }
          }, nil
        end
        error('unexpected read operation: ' .. operation)
      end
      function repository:execute(operation, request)
        executeCalls = executeCalls + 1
        if operation == 'creation_requests_execute' then
          assert(request.permissions_revalidated == true and request.expected_version == 3)
          assert(request.idempotency_key == 'creation-exec:' .. execution.creationRequestId)
          return { entity_id = 'groups_group_00000001', entity_type = 'group',
            status = 'active', version = 1, replayed = false }, nil
        end
        assert(operation == 'creation_requests_expire')
        return { entity_id = request.creation_request_id,
          entity_type = 'group_creation_request', status = 'expired',
          version = 2, replayed = false }, nil
      end
      local coordinator = createCoordinator({
        repository = repository,
        permissions = { check = function(characterId)
          if characterId == deniedCharacter then
            return nil, Foundation.domainError('INSUFFICIENT_PERMISSION', 'revoked')
          end
          return true, nil
        end },
        hooks = { run = function(_, request)
          if hookMode == 'mutate' then
            local copy = Foundation.copyPlain(request)
            copy.slug = 'changed'
            return copy, nil
          end
          return Foundation.copyPlain(request), nil
        end },
        context = function(traceId)
          return { traceId = traceId, caller = 'synex_groups', callerEpoch = 1 }, nil
        end,
        jsonEncode = scalarJson,
        errorSink = function() end
      })

      deniedCharacter = 'character_00000001'
      local _, creatorError = coordinator:advance(execution.creationRequestId, 'trace_creator')
      assert(creatorError.code == 'INSUFFICIENT_PERMISSION' and executeCalls == 0)
      deniedCharacter = 'character_00000003'
      local _, approverError = coordinator:advance(execution.creationRequestId, 'trace_approver')
      assert(approverError.code == 'INSUFFICIENT_PERMISSION' and executeCalls == 0)
      deniedCharacter, hookMode = nil, 'mutate'
      local _, hookError = coordinator:advance(execution.creationRequestId, 'trace_hook')
      assert(hookError.code == 'HOOK_REJECTED' and executeCalls == 0)

      hookMode = 'identity'
      local recovered, reconcileError = coordinator:reconcile(2)
      assert(reconcileError == nil and recovered.examined == 2)
      assert(recovered.executed == 1 and recovered.expired == 1 and recovered.failed == 0)
      assert(executeCalls == 2)
      return table.concat({ creatorError.code, approverError.code, hookError.code,
        tostring(recovered.executed), tostring(recovered.expired) }, ':')
    `);
    assert.equal(result, 'INSUFFICIENT_PERMISSION:INSUFFICIENT_PERMISSION:HOOK_REJECTED:1:1');
  } finally {
    engine.global.close();
  }
});
