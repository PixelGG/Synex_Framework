import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory, type LuaEngine } from 'wasmoon';

const root = process.cwd();

async function source(relativePath: string): Promise<string> {
  return readFile(path.join(root, relativePath), 'utf8');
}

async function preload(
  engine: LuaEngine,
  name: string,
  relativePath: string,
): Promise<void> {
  const contents = await source(relativePath);
  await engine.doString(
    `package.preload[${JSON.stringify(name)}] = assert(load(${JSON.stringify(contents)}, ${JSON.stringify(`@${relativePath}`)}))`,
  );
}

async function bootstrapFoundation(engine: LuaEngine): Promise<void> {
  const foundation = await source('resources/synex_groups/server/foundation.lua');
  await engine.doString(
    `Foundation = assert(load(${JSON.stringify(foundation)}, '@server/foundation.lua'))()`,
  );
}

test('group lifecycle storage is soft-delete-only, replay-verified, and CAS indexed', async () => {
  const migration = await source(
    'resources/synex_groups/migrations/024_group_deletion_lifecycle.sql',
  );
  const deletionPort = await source(
    'resources/synex_groups/server/persistence/deletions.lua',
  );
  const publicHandler = await source(
    'resources/synex_groups/server/persistence/organizations_deletion.lua',
  );

  assert.match(migration, /`lifecycle_state` IN \('ARCHIVED', 'DISSOLVING'\)[\s\S]*?`archived_at` IS NOT NULL AND `deleted_at` IS NULL/u);
  assert.match(migration, /`lifecycle_state` = 'DELETED'[\s\S]*?`archived_at` IS NOT NULL AND `deleted_at` IS NOT NULL/u);
  assert.match(migration, /UNIQUE KEY `uq_group_deletion_requests_active` \(`group_id`, `active_marker`\)/u);
  assert.match(migration, /UNIQUE KEY `uq_group_deletion_requests_idempotency` \(`group_id`, `idempotency_key`\)/u);
  assert.match(migration, /`state` IN \('planning', 'blocked', 'dissolving', 'deleted', 'failed'\)/u);
  assert.match(migration, /synex groups migration 024 lifecycle verification failed/u);
  assert.doesNotMatch(migration, /ON DELETE CASCADE/iu);

  assert.doesNotMatch(publicHandler, /DomainDeletions|core\.plan|core\.process/u);
  assert.match(publicHandler, /FOR UPDATE/u);
  assert.match(publicHandler, /expected_version/u);
  assert.match(publicHandler, /INSERT INTO `synex_group_deletion_requests`/u);
  assert.doesNotMatch(publicHandler, /DELETE\s+FROM|DROP\s+TABLE/iu);

  assert.match(deletionPort, /`lifecycle_state` = 'DISSOLVING'/u);
  assert.match(deletionPort, /`lifecycle_state` = 'DELETED'/u);
  assert.match(deletionPort, /AND `version` = \?/u);
  assert.match(deletionPort, /plan\.state == 'completed'/u);
  assert.doesNotMatch(deletionPort, /DELETE\s+FROM\s+`synex_groups`/iu);
});

test('public group deletion creates one archived journal and fails closed before writes', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrapFoundation(engine);
    await preload(
      engine,
      'server.persistence.organizations_shared',
      'resources/synex_groups/server/persistence/organizations_shared.lua',
    );
    await preload(
      engine,
      'server.persistence.organizations_deletion',
      'resources/synex_groups/server/persistence/organizations_deletion.lua',
    );
    const result = await engine.doString(`
      local Delete = require('server.persistence.organizations_deletion')(Foundation).execute.delete
      local group = {
        id = 7, group_public_id = 'group_12345678', status = 'archived',
        lifecycle_state = 'ARCHIVED', archived_at = '2026-08-25 12:00:00.000000',
        deleted_at = nil, version = 9, profile_version = 9
      }
      local activeRequest
      local writes = 0
      local tx = {
        one = function(sql)
          if sql:find('synex_group_deletion_requests', 1, true) then return activeRequest end
          return group
        end,
        query = function(sql, parameters)
          assert(sql:find('synex_group_deletion_requests', 1, true))
          assert(parameters[2] == 7 and parameters[3] == 'delete-once-1234')
          writes = writes + 1
          return { affectedRows = 1 }
        end
      }
      local allocated = 0
      local runtime = {
        id = function(namespace)
          assert(namespace == 'groups_deletion')
          allocated = allocated + 1
          return 'deletion_12345678'
        end,
        reason = function(_, fallback) return fallback end,
        checkCorePermission = function(characterId, permission)
          assert(characterId == 'character_12345678')
          assert(permission == 'synex.groups.delete')
          return true, nil
        end,
        effect = function(action, entityType, entityId, groupId)
          assert(action == 'group.deletion_requested')
          assert(entityType == 'deletion_request' and entityId == 'deletion_12345678')
          assert(groupId == 'group_12345678')
          return { action = action }
        end
      }
      local request = {
        idempotency_key = 'delete-once-1234', actor_character_id = 'character_12345678',
        group_id = 'group_12345678', expected_version = 9,
        reason = 'Operator requested retirement.'
      }

      local created, creationError, effects = Delete(tx, request, runtime)
      assert(creationError == nil and created.state == 'planning')
      assert(created.group_status == 'archived' and created.group_version == 9)
      assert(created.version == 1 and created.replayed == false)
      assert(writes == 1 and allocated == 1 and #effects == 1)

      request.expected_version = 8
      local stale, staleError = Delete(tx, request, runtime)
      assert(stale == nil and staleError.code == 'CONCURRENT_MODIFICATION')
      assert(writes == 1 and allocated == 1)

      request.expected_version = 9
      group.status, group.lifecycle_state = 'active', 'ACTIVE'
      local active, activeError = Delete(tx, request, runtime)
      assert(active == nil and activeError.code == 'GROUP_NOT_ARCHIVED')
      assert(writes == 1 and allocated == 1)

      group.status, group.lifecycle_state = 'archived', 'ARCHIVED'
      activeRequest = { public_id = 'deletion_existing1', state = 'dissolving', version = 3 }
      local duplicate, duplicateError = Delete(tx, request, runtime)
      assert(duplicate == nil and duplicateError.code == 'GROUP_DELETION_IN_PROGRESS')
      assert(writes == 1 and allocated == 1)
      return true
    `);
    assert.equal(result, true);
  } finally {
    engine.global.close();
  }
});

test('deletion coordinator orders plan, local dissolution, external actions, and finalization', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrapFoundation(engine);
    const coordinatorSource = await source(
      'resources/synex_groups/server/group_deletions.lua',
    );
    await engine.doString(
      `CreateGroupDeletions = assert(load(${JSON.stringify(coordinatorSource)}, '@server/group_deletions.lua'))()(Foundation)`,
    );
    const result = await engine.doString(`
      local order, planCalls, processCalls, getCalls = {}, 0, 0, 0
      local invalidated = {}
      local request = {
        deletionRequestId = 'deletion_12345678', groupId = 'group_12345678',
        planId = nil, state = 'planning', reason = 'Operator requested retirement.'
      }
      local public = {
        deletion_request_id = request.deletionRequestId, group_id = request.groupId,
        state = request.state, group_status = 'archived', group_version = 9,
        version = 1, replayed = false
      }
      local repository = {}
      function repository:getGroupDeletionPlanRequest()
        return request, nil
      end
      function repository:getGroupDeletion()
        public.state = request.state
        public.group_status = request.state == 'deleted' and 'deleted'
          or request.state == 'dissolving' and 'dissolving' or 'archived'
        return public, nil
      end
      function repository:applyGroupDeletionPlan(requestId, plan)
        order[#order + 1] = 'apply:' .. plan.state
        assert(requestId == request.deletionRequestId)
        request.planId = plan.planId
        if plan.state == 'blocked' then request.state = 'blocked'
        elseif plan.state == 'completed' then request.state = 'deleted'
        else request.state = 'dissolving' end
        return self:getGroupDeletion()
      end
      function repository:listGroupDeletions() return { request.deletionRequestId }, nil end
      function repository:preflightGroupDeletion(subjectId, requestId)
        assert(subjectId == request.groupId and requestId == request.deletionRequestId)
        return { decision = 'retain', metadata = { deletionRequestId = requestId } }, nil
      end
      local pending = {
        planId = 'deletion_plan_0001', domain = 'group', subjectId = request.groupId,
        requesterOwner = 'synex_groups', state = 'pending', reason = request.reason,
        context = { deletionRequestId = request.deletionRequestId },
        actions = {{ index = 1, decision = 'retain', state = 'completed',
          providerOwner = 'synex_groups', providerName = 'domain_state' }}
      }
      local completed = Foundation.copyPlain(pending)
      completed.state = 'completed'
      local coordinator = CreateGroupDeletions({
        repository = repository,
        core = {
          plan = function(definition)
            planCalls = planCalls + 1
            order[#order + 1] = 'plan'
            assert(definition.idempotencyKey == 'group-delete:' .. request.deletionRequestId)
            return pending, nil
          end,
          get = function(planId)
            getCalls = getCalls + 1
            order[#order + 1] = 'get'
            assert(planId == pending.planId)
            return pending, nil
          end,
          process = function(planId)
            processCalls = processCalls + 1
            order[#order + 1] = 'process'
            assert(planId == pending.planId and request.state == 'dissolving')
            return completed, nil
          end
        },
        onLifecycleChanged = function(groupId, state)
          assert(groupId == request.groupId)
          invalidated[#invalidated + 1] = state
          return true
        end,
        errorSink = function() end
      })

      local provider = coordinator:provider()
      local decision, decisionError = provider.preflight({
        domain = 'group', subjectId = request.groupId, reason = request.reason,
        context = { deletionRequestId = request.deletionRequestId }
      })
      assert(decisionError == nil and decision.decision == 'retain')
      local executed, executeError = provider.execute({})
      assert(executed == nil and executeError.code == 'DELETION_PLAN_INVALID')

      local deleted, deletionError = coordinator:advance(request.deletionRequestId)
      assert(deletionError == nil and deleted.state == 'deleted')
      assert(table.concat(order, ',') == 'plan,apply:pending,process,apply:completed')
      assert(planCalls == 1 and processCalls == 1 and getCalls == 0)
      assert(table.concat(invalidated, ',') == 'dissolving,deleted')

      local replayed, replayError = coordinator:advance(request.deletionRequestId)
      assert(replayError == nil and replayed.state == 'deleted')
      assert(planCalls == 1 and processCalls == 1 and getCalls == 0)
      assert(table.concat(invalidated, ',') == 'dissolving,deleted,deleted')
      return true
    `);
    assert.equal(result, true);
  } finally {
    engine.global.close();
  }
});

test('blocked plans stay archived and restart reconciliation resumes a bound plan', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrapFoundation(engine);
    const coordinatorSource = await source(
      'resources/synex_groups/server/group_deletions.lua',
    );
    await engine.doString(
      `CreateGroupDeletions = assert(load(${JSON.stringify(coordinatorSource)}, '@server/group_deletions.lua'))()(Foundation)`,
    );
    const result = await engine.doString(`
      local processCalls, planCalls, getCalls = 0, 0, 0
      local mode = 'blocked'
      local request = {
        deletionRequestId = 'deletion_abcdefgh', groupId = 'group_abcdefgh',
        planId = nil, state = 'planning', reason = 'Blocked deletion fixture.'
      }
      local function plan(state)
        return {
          planId = 'deletion_plan_0002', domain = 'group', subjectId = request.groupId,
          requesterOwner = 'synex_groups', state = state, reason = request.reason,
          context = { deletionRequestId = request.deletionRequestId },
          actions = {{ index = 1, decision = state == 'blocked' and 'block' or 'delete',
            state = state == 'completed' and 'completed' or 'pending',
            providerOwner = 'external_fixture', providerName = 'dependent_rows' }}
        }
      end
      local repository = {}
      function repository:getGroupDeletionPlanRequest() return request, nil end
      function repository:getGroupDeletion()
        return {
          deletion_request_id = request.deletionRequestId, group_id = request.groupId,
          state = request.state,
          group_status = request.state == 'dissolving' and 'dissolving' or 'archived',
          group_version = 4, version = 2, replayed = false
        }, nil
      end
      function repository:applyGroupDeletionPlan(_, value)
        request.planId = value.planId
        if value.state == 'blocked' then request.state = 'blocked'
        elseif value.state == 'completed' then request.state = 'deleted'
        else request.state = 'dissolving' end
        return self:getGroupDeletion()
      end
      function repository:listGroupDeletions() return { request.deletionRequestId }, nil end
      function repository:preflightGroupDeletion()
        return { decision = 'retain' }, nil
      end
      local coordinator = CreateGroupDeletions({
        repository = repository,
        core = {
          plan = function()
            planCalls = planCalls + 1
            return plan('blocked'), nil
          end,
          get = function(planId)
            getCalls = getCalls + 1
            assert(planId == request.planId)
            return plan('executing'), nil
          end,
          process = function()
            processCalls = processCalls + 1
            return plan('completed'), nil
          end
        },
        errorSink = function() end
      })

      local blocked, blockedError = coordinator:advance(request.deletionRequestId)
      assert(blockedError == nil and blocked.state == 'blocked')
      assert(blocked.group_status == 'archived')
      assert(planCalls == 1 and processCalls == 0 and getCalls == 0)

      request.planId, request.state = 'deletion_plan_0002', 'dissolving'
      local resumed, resumeError = coordinator:advance(request.deletionRequestId)
      assert(resumeError == nil and resumed.state == 'deleted')
      assert(planCalls == 1 and getCalls == 1 and processCalls == 1)
      return true
    `);
    assert.equal(result, true);
  } finally {
    engine.global.close();
  }
});
