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

async function bootstrapReads(engine: LuaEngine): Promise<void> {
  await preload(engine, 'server.foundation', 'resources/synex_groups/server/foundation.lua');
  await preload(
    engine,
    'server.persistence.workflow_reads',
    'resources/synex_groups/server/persistence/workflow_reads.lua',
  );
  await engine.doString(`
    Foundation = require 'server.foundation'
    WorkflowReads = require('server.persistence.workflow_reads')(Foundation)

    function readRuntime(overrides)
      overrides = overrides or {}
      local runtime = {}
      function runtime.requireGroup(_, groupId)
        if overrides.requireGroup then return overrides.requireGroup(groupId) end
        return { id = 10, public_id = groupId, status = 'active' }, nil
      end
      function runtime.authorize(_, groupId, characterId, capability, scope)
        if overrides.authorize then
          return overrides.authorize(groupId, characterId, capability, scope)
        end
        return { id = 20, public_id = 'membership_actor_0001' }, nil
      end
      function runtime.jsonDecode(value)
        if overrides.jsonDecode then return overrides.jsonDecode(value) end
        assert(value == '{"classification":"internal"}')
        return { classification = 'internal' }
      end
      return runtime
    end
  `);
}

async function bootstrapService(engine: LuaEngine): Promise<void> {
  await preload(engine, 'server.foundation', 'resources/synex_groups/server/foundation.lua');
  await preload(engine, 'server.validation', 'resources/synex_groups/server/validation.lua');
  await preload(engine, 'server.service', 'resources/synex_groups/server/service.lua');
}

test('assignment detail is authorized against its persisted group and only detail exposes bounded metadata', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrapReads(engine);
    const result = await engine.doString(`
      local authorizationCalls = 0
      local tx = {}
      function tx.one(sql, parameters)
        assert(sql:find('synex_group_assignments', 1, true))
        assert(parameters[1] == 'assignment_alpha_0001')
        return {
          assignment_id = 'assignment_alpha_0001',
          group_id = 'group_alpha_0001',
          parent_assignment_id = nil,
          name = 'Patrol Alpha', assignment_type = 'patrol', status = 'active',
          member_limit = 4, member_count = 2,
          metadata_json = '{"classification":"internal"}',
          starts_at = '2026-08-25T10:00:00.000000Z', ends_at = nil,
          version = 3, character_id = 'character_other_0001'
        }
      end
      local runtime = readRuntime({
        authorize = function(groupId, characterId, capability, scope)
          authorizationCalls = authorizationCalls + 1
          assert(groupId == 'group_alpha_0001')
          assert(characterId == 'character_actor_0001')
          assert(capability == 'synex.groups.assignments.read' and scope == 'group')
          return { id = 20 }, nil
        end
      })
      local value, failure = WorkflowReads.read.assignments_get(tx, {
        actor_character_id = 'character_actor_0001',
        assignment_id = 'assignment_alpha_0001'
      }, runtime)
      assert(failure == nil and authorizationCalls == 1)
      assert(value.assignment_id == 'assignment_alpha_0001')
      assert(value.metadata.classification == 'internal')
      assert(value.character_id == nil)

      runtime = readRuntime({
        authorize = function()
          return nil, Foundation.domainError('INSUFFICIENT_PERMISSION', 'denied')
        end
      })
      local denied, deniedError = WorkflowReads.read.assignments_get(tx, {
        actor_character_id = 'character_actor_0001',
        assignment_id = 'assignment_alpha_0001'
      }, runtime)
      assert(denied == nil and deniedError.code == 'ASSIGNMENT_NOT_FOUND')
      return value.assignment_id
    `);
    assert.equal(result, 'assignment_alpha_0001');
  } finally {
    engine.global.close();
  }
});

test('assignment reads reject array, oversized, and structurally unbounded stored metadata', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrapReads(engine);
    const result = await engine.doString(`
      local row = {
        assignment_id = 'assignment_alpha_0001', group_id = 'group_alpha_0001',
        name = 'Patrol Alpha', assignment_type = 'patrol', status = 'active',
        member_limit = 4, member_count = 2, metadata_json = '{}', version = 1
      }
      local tx = { one = function(sql)
        assert(sql:find('active_marker\` = 1', 1, true))
        return row
      end }
      local array = setmetatable({}, { __jsontype = 'array' })
      local _, arrayError = WorkflowReads.read.assignments_get(tx, {
        actor_character_id = 'character_actor_0001',
        assignment_id = 'assignment_alpha_0001'
      }, readRuntime({ jsonDecode = function() return array end }))
      assert(arrayError.code == 'DATABASE_RESULT_INVALID')

      local deep = {}
      local cursor = deep
      for index = 1, 9 do cursor.child = {} cursor = cursor.child end
      local _, depthError = WorkflowReads.read.assignments_get(tx, {
        actor_character_id = 'character_actor_0001',
        assignment_id = 'assignment_alpha_0001'
      }, readRuntime({ jsonDecode = function() return deep end }))
      assert(depthError.code == 'DATABASE_RESULT_INVALID')

      row.metadata_json = string.rep('x', 1048577)
      local decoded = false
      local _, sizeError = WorkflowReads.read.assignments_get(tx, {
        actor_character_id = 'character_actor_0001',
        assignment_id = 'assignment_alpha_0001'
      }, readRuntime({ jsonDecode = function() decoded = true return {} end }))
      assert(sizeError.code == 'READ_MODEL_TOO_LARGE' and decoded == false)
      return arrayError.code .. ':' .. depthError.code .. ':' .. sizeError.code
    `);
    assert.equal(
      result,
      'DATABASE_RESULT_INVALID:DATABASE_RESULT_INVALID:READ_MODEL_TOO_LARGE',
    );
  } finally {
    engine.global.close();
  }
});

test('assignment and duty listings authorize once, paginate deterministically, and omit private fields', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrapReads(engine);
    const result = await engine.doString(`
      local authorizationCalls, queries = 0, 0
      local runtime = readRuntime({
        authorize = function(groupId, characterId, capability, scope)
          authorizationCalls = authorizationCalls + 1
          assert(groupId == 'group_alpha_0001')
          assert(characterId == 'character_actor_0001' and scope == 'group')
          assert(capability == 'synex.groups.assignments.read'
            or capability == 'synex.groups.duty.read')
          return { id = 20 }, nil
        end
      })
      local tx = {}
      function tx.many(sql, parameters)
        queries = queries + 1
        assert(parameters[#parameters] == 3, 'limit + one look-ahead row is required')
        if sql:find('member_count', 1, true) then
          assert(parameters[1] == 10)
          assert(parameters[2] == 'active' and parameters[3] == 'active')
          assert(parameters[4] == 'assignment_before_0001'
            and parameters[5] == 'assignment_before_0001')
          return {
            { assignment_id = 'assignment_alpha_0001', group_id = 'group_alpha_0001',
              name = 'Alpha', assignment_type = 'patrol', status = 'active',
              member_limit = 4, member_count = 1, version = 1,
              metadata_json = '{"classification":"must_not_escape"}' },
            { assignment_id = 'assignment_bravo_0002', group_id = 'group_alpha_0001',
              name = 'Bravo', assignment_type = 'patrol', status = 'active',
              member_limit = 4, member_count = 2, version = 2,
              character_id = 'character_other_0001' },
            { assignment_id = 'assignment_charlie_0003', group_id = 'group_alpha_0001',
              name = 'Charlie', assignment_type = 'patrol', status = 'active',
              member_limit = 4, member_count = 3, version = 3 }
          }
        end
        assert(sql:find('synex_group_duty_sessions', 1, true))
        assert(parameters[1] == 10)
        assert(parameters[2] == 'open' and parameters[3] == 'open')
        assert(parameters[4] == 'membership_alpha_0001'
          and parameters[5] == 'membership_alpha_0001')
        assert(parameters[6] == 'duty_before_0001' and parameters[7] == 'duty_before_0001')
        return {
          { duty_session_id = 'duty_alpha_0001', membership_id = 'membership_alpha_0001',
            group_id = 'group_alpha_0001', state = 'on_duty', status = 'open',
            assignment_id = 'assignment_alpha_0001', counts_as_on_duty = 1,
            version = 1, character_id = 'character_other_0001', metadata_json = '{}' },
          { duty_session_id = 'duty_bravo_0002', membership_id = 'membership_bravo_0002',
            group_id = 'group_alpha_0001', state = 'on_duty', status = 'open',
            assignment_id = nil, counts_as_on_duty = 0, version = 2 },
          { duty_session_id = 'duty_charlie_0003', membership_id = 'membership_charlie_0003',
            group_id = 'group_alpha_0001', state = 'on_duty', status = 'open',
            assignment_id = nil, counts_as_on_duty = 1, version = 3 }
        }
      end

      local assignments, assignmentError = WorkflowReads.read.assignments_list(tx, {
        actor_character_id = 'character_actor_0001', group_id = 'group_alpha_0001',
        status = 'active', cursor = 'assignment_before_0001', limit = 2
      }, runtime)
      assert(assignmentError == nil and #assignments.items == 2)
      assert(assignments.truncated == true
        and assignments.next_cursor == 'assignment_bravo_0002')
      assert(assignments.items[1].metadata == nil
        and assignments.items[1].metadata_json == nil)
      assert(assignments.items[2].character_id == nil)

      local duty, dutyError = WorkflowReads.read.duty_list(tx, {
        actor_character_id = 'character_actor_0001', group_id = 'group_alpha_0001',
        membership_id = 'membership_alpha_0001', status = 'open',
        cursor = 'duty_before_0001', limit = 2
      }, runtime)
      assert(dutyError == nil and #duty.items == 2)
      assert(duty.truncated == true and duty.next_cursor == 'duty_bravo_0002')
      assert(duty.items[1].counts_as_on_duty == true)
      assert(duty.items[1].character_id == nil and duty.items[1].metadata_json == nil)
      assert(authorizationCalls == 2 and queries == 2)

      local deniedQueries = 0
      local deniedTx = {}
      function deniedTx.many() deniedQueries = deniedQueries + 1 return {} end
      local deniedRuntime = readRuntime({
        authorize = function()
          return nil, Foundation.domainError('INSUFFICIENT_PERMISSION', 'denied')
        end
      })
      local deniedAssignments, assignmentDeniedError =
        WorkflowReads.read.assignments_list(deniedTx, {
          actor_character_id = 'character_actor_0001', group_id = 'group_alpha_0001'
        }, deniedRuntime)
      local deniedDuty, dutyDeniedError = WorkflowReads.read.duty_list(deniedTx, {
        actor_character_id = 'character_actor_0001', group_id = 'group_alpha_0001'
      }, deniedRuntime)
      assert(deniedAssignments == nil
        and assignmentDeniedError.code == 'INSUFFICIENT_PERMISSION')
      assert(deniedDuty == nil and dutyDeniedError.code == 'INSUFFICIENT_PERMISSION')
      assert(deniedQueries == 0)
      return assignments.next_cursor .. ':' .. duty.next_cursor
    `);
    assert.equal(result, 'assignment_bravo_0002:duty_bravo_0002');
  } finally {
    engine.global.close();
  }
});

test('self snapshot uses two bounded queries for multiple memberships and exposes only the current character projection', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrapReads(engine);
    const result = await engine.doString(`
      local queries = 0
      local tx = {}
      function tx.many(sql, parameters)
        queries = queries + 1
        if queries == 1 then
          assert(sql:find('profile', 1, true) and sql:find('character_id', 1, true))
          assert(sql:find("visibility\` <> 'server_only'", 1, true))
          assert(parameters[1] == 'character_session_0001')
          assert(parameters[2] == 'membership_before_0001'
            and parameters[3] == 'membership_before_0001')
          assert(parameters[4] == 3)
          return {
            { membership_internal_id = 101, membership_id = 'membership_alpha_0001',
              group_id = 'group_alpha_0001', group_name = 'Alpha Group',
              group_type = 'faction', membership_status = 'ACTIVE',
              grade_id = 'grade_alpha_0001', grade_key = 'member',
              grade_name = 'Member', grade_rank = 10,
              duty_session_id = 'duty_alpha_0001', duty_state = 'on_duty',
              duty_assignment_id = 'assignment_alpha_0001', duty_version = 4,
              duty_counts_as_on_duty = 1, character_id = 'character_session_0001',
              metadata_json = '{"private":true}' },
            { membership_internal_id = 102, membership_id = 'membership_bravo_0002',
              group_id = 'group_bravo_0002', group_name = 'Bravo Group',
              group_type = 'business', membership_status = 'PROBATION',
              grade_id = nil, duty_session_id = nil },
            { membership_internal_id = 103, membership_id = 'membership_charlie_0003',
              group_id = 'group_charlie_0003', group_name = 'Charlie Group',
              group_type = 'club', membership_status = 'ACTIVE' }
          }
        end
        assert(queries == 2, 'roles must be fetched once, not once per membership')
        assert(sql:find('IN (?,?)', 1, true))
        assert(sql:find('ROW_NUMBER() OVER (PARTITION BY', 1, true))
        assert(sql:find('role_rank\` <= 9', 1, true) and sql:find('LIMIT 72', 1, true))
        assert(#parameters == 2 and parameters[1] == 101 and parameters[2] == 102)
        local rows = {}
        for index = 1, 9 do
          rows[#rows + 1] = {
            membership_id = 101,
            role_id = 'role_alpha_' .. string.format('%04d', index),
            role_key = 'role_' .. string.format('%04d', index),
            role_name = 'Role ' .. index,
            valid_until = nil,
            capability = 'synex.groups.private.must_not_escape'
          }
        end
        rows[#rows + 1] = {
          membership_id = 102, role_id = 'role_bravo_0001',
          role_key = 'operator', role_name = 'Operator', valid_until = nil
        }
        return rows
      end

      local snapshot, failure = WorkflowReads.read.self_snapshot(tx, {
        actor_character_id = 'character_session_0001',
        cursor = 'membership_before_0001', limit = 2
      }, readRuntime())
      assert(failure == nil and queries == 2 and #snapshot.items == 2)
      assert(snapshot.truncated == true
        and snapshot.next_cursor == 'membership_bravo_0002')
      local alpha, bravo = snapshot.items[1], snapshot.items[2]
      assert(alpha.group.group_id == 'group_alpha_0001'
        and alpha.group.name == 'Alpha Group' and alpha.group.type == 'faction')
      assert(alpha.grade.grade_id == 'grade_alpha_0001' and alpha.grade.rank == 10)
      assert(alpha.duty.duty_session_id == 'duty_alpha_0001'
        and alpha.duty.counts_as_on_duty == true)
      assert(#alpha.roles == 8 and alpha.roles_truncated == true)
      assert(#bravo.roles == 1 and bravo.roles_truncated == false)
      assert(alpha.character_id == nil and alpha.metadata == nil and alpha.metadata_json == nil)
      assert(alpha.roles[1].capability == nil)
      assert(snapshot.items[3] == nil)
      return queries .. ':' .. #alpha.roles .. ':' .. snapshot.next_cursor
    `);
    assert.equal(result, '2:8:membership_bravo_0002');
  } finally {
    engine.global.close();
  }
});

test('self snapshot service derives identity from an active source-generation-bound session and fails closed otherwise', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrapService(engine);
    const result = await engine.doString(`
      local reads, characterChecks = 0, 0
      local repository = {}
      function repository:read(operation, request, context)
        reads = reads + 1
        assert(operation == 'self_snapshot')
        assert(request.actor_character_id == 'character_session_0001')
        assert(request.limit == 2 and request.cursor == nil)
        assert(context.caller == 'synex_core' and context.callerEpoch == 8)
        return { items = {}, truncated = false }, nil, {}
      end
      function repository:execute() error('self snapshot cannot use the mutation boundary') end

      local methods = require('server.service')(
        require 'server.foundation')({
          repository = repository,
          characters = { get = function(characterId)
            characterChecks = characterChecks + 1
            assert(characterId == 'character_session_0001')
            return { id = characterId }, nil
          end },
          hooks = { run = function(_, value) return value, nil end },
          audit = { append = function() return { eventId = 'audit_event_0001' }, nil end },
          runtimeEffects = { apply = function() return true, nil end },
          jsonEncode = function() return '{}' end,
          cache = {
            get = function() return nil end,
            put = function() return true end,
            invalidatePrefix = function() return 0 end
          },
          errorSink = function() end
        })

      local function context(session)
        return {
          traceId = 'trace_self_0001', caller = 'synex_core', callerEpoch = 8,
          source = 17, sourceGeneration = 5, session = session
        }
      end
      local active = {
        state = 'ACTIVE', characterId = 'character_session_0001',
        source = 17, sourceGeneration = 5
      }
      local snapshot, failure = methods.self_snapshot({
        limit = 2,
        actor_character_id = 'character_attacker_0001'
      }, context(active))
      assert(failure == nil and snapshot and reads == 1 and characterChecks == 1)

      local invalid = {
        context(nil),
        context({ state = 'CONNECTING', characterId = 'character_session_0001',
          source = 17, sourceGeneration = 5 }),
        context({ state = 'ACTIVE', characterId = 'character_session_0001',
          source = 18, sourceGeneration = 5 }),
        context({ state = 'ACTIVE', characterId = 'character_session_0001',
          source = 17, sourceGeneration = 4 })
      }
      for _, rejectedContext in ipairs(invalid) do
        local value, sessionError = methods.self_snapshot({ limit = 2 }, rejectedContext)
        assert(value == nil and sessionError.code == 'SESSION_REQUIRED')
      end
      assert(reads == 1 and characterChecks == 1)

      local _, limitError = methods.self_snapshot({ limit = 9 }, context(active))
      assert(limitError.code == 'VALIDATION_FAILED' and reads == 1)
      return reads .. ':' .. characterChecks .. ':' .. limitError.code
    `);
    assert.equal(result, '1:1:VALIDATION_FAILED');
  } finally {
    engine.global.close();
  }
});

test('public self snapshot contract excludes caller-selected identity and caps the page size', async () => {
  const catalog = JSON.parse(
    await readFile(
      path.join(root, 'resources/synex_groups/groups.contracts.json'),
      'utf8',
    ),
  ) as {
    contracts: Array<{
      name: string;
      network: string;
      input: {
        additionalProperties: boolean;
        properties: Record<string, { maximum?: number }>;
      };
    }>;
  };
  const contract = catalog.contracts.find((candidate) => candidate.name === 'synex.groups.self.snapshot');
  assert.ok(contract);
  assert.equal(contract.network, 'client-to-server');
  assert.equal(contract.input.additionalProperties, false);
  assert.deepEqual(Object.keys(contract.input.properties).sort(), ['cursor', 'limit']);
  const limit = contract.input.properties.limit;
  assert.ok(limit);
  assert.equal(limit.maximum, 8);
});

test('server-only compatibility snapshot adds bounded primary, key, label, and revision data without per-membership queries', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrapReads(engine);
    const result = await engine.doString(`
      local queries = 0
      local tx = {}
      function tx.many(sql, parameters)
        queries = queries + 1
        if queries == 1 then
          assert(parameters[1] == 'character_session_0001' and parameters[4] == 3)
          return {
            { membership_internal_id = 101, membership_id = 'membership_alpha_0001',
              group_id = 'group_alpha_0001', group_name = 'Alpha Group',
              group_type = 'job', membership_status = 'ACTIVE',
              grade_id = 'grade_alpha_0001', grade_key = 'chief',
              grade_name = 'Chief', grade_rank = 50 },
            { membership_internal_id = 102, membership_id = 'membership_bravo_0002',
              group_id = 'group_bravo_0002', group_name = 'Bravo Group',
              group_type = 'gang', membership_status = 'ACTIVE' }
          }
        end
        if queries == 2 then
          assert(#parameters == 2 and parameters[1] == 101 and parameters[2] == 102)
          return {}
        end
        assert(queries == 3, 'compatibility enrichment must be one bounded query')
        assert(sql:find('synex_group_primary_memberships_by_type', 1, true))
        assert(sql:find('IN (?,?)', 1, true))
        assert(#parameters == 3 and parameters[1] == 'membership_alpha_0001'
          and parameters[2] == 'membership_bravo_0002'
          and parameters[3] == 'character_session_0001')
        return {
          { membership_id = 'membership_alpha_0001', membership_version = 4,
            membership_profile_version = 5, group_key = 'police',
            group_label = 'Police Department', group_version = 6,
            is_primary = 1, primary_version = 2 },
          { membership_id = 'membership_bravo_0002', membership_version = 7,
            membership_profile_version = 8, group_key = 'lostmc',
            group_label = 'Lost MC', group_version = 9,
            is_primary = 0, primary_version = nil }
        }
      end
      local snapshot, failure = WorkflowReads.read.compatibility_snapshot(tx, {
        actor_character_id = 'character_session_0001', limit = 2
      }, readRuntime())
      assert(failure == nil and queries == 3 and #snapshot.items == 2)
      local job, gang = snapshot.items[1], snapshot.items[2]
      assert(job.group.key == 'police' and job.group.label == 'Police Department')
      assert(job.is_primary == true and job.primary_version == 2)
      assert(job.membership_version == 4 and job.membership_profile_version == 5)
      assert(gang.group.key == 'lostmc' and gang.is_primary == false)
      return queries .. ':' .. job.group.key .. ':' .. gang.group.key
    `);
    assert.equal(result, '3:police:lostmc');
  } finally {
    engine.global.close();
  }

  const catalog = JSON.parse(await readFile(
    path.join(root, 'resources/synex_groups/groups.contracts.json'), 'utf8',
  )) as { contracts: Array<Record<string, unknown>> };
  const contract = catalog.contracts.find(
    (candidate) => candidate.name === 'synex.groups.compatibility.snapshot',
  ) as {
    network?: string;
    capability?: string;
    input?: { properties?: { limit?: { maximum?: number } } };
  } | undefined;
  assert.ok(contract);
  assert.equal(contract.network, 'none');
  assert.equal(contract.capability, 'synex.groups.read');
  assert.equal(contract.input?.properties?.limit?.maximum, 8);
});

test('compatibility snapshot service authorizes an explicit server-side character and remains bounded', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrapService(engine);
    const result = await engine.doString(`
      local reads, checks = 0, 0
      local methods = require('server.service')(require 'server.foundation')({
        repository = {
          read = function(_, operation, request, context)
            reads = reads + 1
            assert(operation == 'compatibility_snapshot')
            assert(request.actor_character_id == 'character_session_0001')
            assert(context.caller == 'synex_bridge_qb')
            return { items = {}, truncated = false }, nil, {}
          end,
          execute = function() error('read must not mutate') end
        },
        characters = { get = function(characterId)
          checks = checks + 1
          assert(characterId == 'character_session_0001')
          return { id = characterId }, nil
        end },
        hooks = { run = function(_, value) return value, nil end },
        audit = { append = function() return { eventId = 'audit_event_0001' }, nil end },
        runtimeEffects = { apply = function() return true, nil end },
        jsonEncode = function() return '{}' end,
        cache = {
          get = function() return nil end, put = function() return true end,
          invalidatePrefix = function() return 0 end
        },
        errorSink = function() end
      })
      local context = {
        traceId = 'trace_compat_0001', caller = 'synex_bridge_qb', callerEpoch = 4
      }
      local value, failure = methods.compatibility_snapshot({
        actor_character_id = 'character_session_0001', limit = 8
      }, context)
      assert(value and failure == nil and reads == 1 and checks == 1)
      local rejected, rejectedError = methods.compatibility_snapshot({
        actor_character_id = 'character_session_0001', limit = 9
      }, context)
      assert(rejected == nil and rejectedError.code == 'VALIDATION_FAILED')
      assert(reads == 1 and checks == 1)
      return reads .. ':' .. checks .. ':' .. rejectedError.code
    `);
    assert.equal(result, '1:1:VALIDATION_FAILED');
  } finally {
    engine.global.close();
  }
});

test('workflow read validation rejects over-limit pages before repository work', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await preload(engine, 'server.foundation', 'resources/synex_groups/server/foundation.lua');
    await preload(engine, 'server.validation', 'resources/synex_groups/server/validation.lua');
    const result = await engine.doString(`
      local Validation = require('server.validation')(require 'server.foundation')
      local actor = 'character_actor_0001'
      local group = 'group_alpha_0001'
      local assignments, assignmentsError = Validation.operation('assignments_list', {
        actor_character_id = actor, group_id = group, limit = 41
      })
      local duty, dutyError = Validation.operation('duty_list', {
        actor_character_id = actor, group_id = group, limit = 41
      })
      local snapshot, snapshotError = Validation.operation('self_snapshot', {
        actor_character_id = actor, limit = 9
      })
      assert(assignments == nil and assignmentsError.code == 'VALIDATION_FAILED')
      assert(duty == nil and dutyError.code == 'VALIDATION_FAILED')
      assert(snapshot == nil and snapshotError.code == 'VALIDATION_FAILED')

      local assignmentsValid = Validation.operation('assignments_list', {
        actor_character_id = actor, group_id = group, limit = 40
      })
      local dutyValid = Validation.operation('duty_list', {
        actor_character_id = actor, group_id = group, limit = 40
      })
      local snapshotValid = Validation.operation('self_snapshot', {
        actor_character_id = actor, limit = 8
      })
      assert(assignmentsValid and dutyValid and snapshotValid)
      return assignmentsError.code .. ':' .. dutyError.code .. ':' .. snapshotError.code
    `);
    assert.equal(result, 'VALIDATION_FAILED:VALIDATION_FAILED:VALIDATION_FAILED');
  } finally {
    engine.global.close();
  }
});

test('assignment participant counts use the generated-active marker and its exact covering index', async () => {
  const [reads, migration] = await Promise.all([
    readFile(path.join(
      root, 'resources/synex_groups/server/persistence/workflow_reads.lua',
    ), 'utf8'),
    readFile(path.join(
      root,
      'resources/synex_groups/migrations/029_assignment_member_active_counts.sql',
    ), 'utf8'),
  ]);
  assert.equal(
    [...reads.matchAll(/`participant`\.`active_marker` = 1/gu)].length,
    2,
  );
  assert.doesNotMatch(
    reads,
    /`participant`\.`status` = 'active'/u,
  );
  assert.match(
    migration,
    /ADD KEY `idx_group_assignment_members_assignment_active`\s*\(`assignment_id`, `active_marker`\)/u,
  );
  assert.match(
    migration,
    /synex groups migration 029 assignment count index verification failed/u,
  );
});
