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

async function bootstrapCompatibility(engine: LuaEngine, mutations = false): Promise<void> {
  await preload(engine, 'server.foundation', 'resources/synex_groups/server/foundation.lua');
  await engine.doString(mutations ? `
    gradeCalls, primaryCalls, failPrimary = 0, 0, false
    package.preload['server.persistence.memberships_lifecycle'] = function()
      return function()
        return { execute = { members_set_grade = function(tx, request, runtime, context, approvalOperation)
          gradeCalls = gradeCalls + 1
          assert(tx == expectedTx and approvalOperation == 'compatibility_set_primary_grade')
          assert(request.grade_id == 'grade_chief_0001')
          return { entity_id = request.membership_id, version = request.expected_version + 1 }, nil,
            { { action = 'grade.changed' } }
        end } }
      end
    end
    package.preload['server.persistence.memberships_access'] = function()
      return function()
        return { execute = { members_set_primary = function(tx, request)
          primaryCalls = primaryCalls + 1
          assert(tx == expectedTx and request.group_type == 'job')
          if failPrimary then return nil, { code = 'CONCURRENT_MODIFICATION' } end
          return { entity_id = 'group_primary_0001', version = 4 }, nil,
            { { action = 'membership.primary_changed' } }
        end } }
      end
    end
  ` : `
    package.preload['server.persistence.memberships_lifecycle'] = function()
      return function() return { execute = {} } end
    end
    package.preload['server.persistence.memberships_access'] = function()
      return function() return { execute = {} } end
    end
  `);
  await preload(
    engine,
    'server.persistence.compatibility',
    'resources/synex_groups/server/persistence/compatibility.lua',
  );
  await engine.doString(`
    Foundation = require 'server.foundation'
    Compatibility = require('server.persistence.compatibility')(Foundation)
  `);
}

test('compatibility contracts are narrow server-only boundaries with no internal identifiers', async () => {
  const catalog = JSON.parse(await readFile(
    path.join(root, 'resources/synex_groups/groups.contracts.json'),
    'utf8',
  )) as { contracts: Array<{
    name: string;
    capability: string;
    network: string;
    idempotent?: boolean;
    input: { additionalProperties: boolean; required: string[]; properties: Record<string, unknown> };
    output: { additionalProperties: boolean; required: string[]; properties: Record<string, unknown> };
  }> };
  const resolver = catalog.contracts.find(
    (candidate) => candidate.name === 'synex.groups.compatibility.resolve_target',
  );
  const mutation = catalog.contracts.find(
    (candidate) => candidate.name === 'synex.groups.compatibility.set_primary_grade',
  );
  assert.ok(resolver);
  assert.equal(resolver.network, 'none');
  assert.equal(resolver.capability, 'synex.groups.read');
  assert.equal(resolver.input.additionalProperties, false);
  assert.deepEqual(resolver.input.required, [
    'actor_character_id', 'group_type', 'group_key', 'grade_key',
  ]);
  assert.deepEqual(resolver.output.required, ['group_id', 'grade_id']);
  assert.equal(resolver.output.additionalProperties, false);
  assert.equal(Object.keys(resolver.output.properties).some(
    (field) => field.includes('internal') || field === 'character_id' || field.includes('metadata'),
  ), false);

  assert.ok(mutation);
  assert.equal(mutation.network, 'none');
  assert.equal(mutation.capability, 'synex.groups.compatibility.set_primary_grade');
  assert.equal(mutation.idempotent, true);
  assert.equal(mutation.input.additionalProperties, false);
  assert.ok(mutation.input.required.includes('expected_version'));
  assert.ok(mutation.input.required.includes('expected_primary_version'));

  const manifest = JSON.parse(await readFile(
    path.join(root, 'resources/synex_groups/synex.resource.json'),
    'utf8',
  )) as { contracts: { provide: string[] } };
  assert.ok(manifest.contracts.provide.includes(resolver.name));
  assert.ok(manifest.contracts.provide.includes(mutation.name));
});

test('compatibility request validation is closed, lowercase, and CAS bounded', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await preload(engine, 'server.foundation', 'resources/synex_groups/server/foundation.lua');
    await preload(engine, 'server.validation', 'resources/synex_groups/server/validation.lua');
    const result = await engine.doString(`
      local Validation = require('server.validation')(require 'server.foundation')
      local resolved, resolvedError = Validation.operation('compatibility_resolve_target', {
        actor_character_id = 'character_actor_0001', group_type = 'job',
        group_key = 'police', grade_key = 'chief'
      })
      local unknown, unknownError = Validation.operation('compatibility_resolve_target', {
        actor_character_id = 'character_actor_0001', group_type = 'job',
        group_key = 'police', grade_key = 'chief', hidden = true
      })
      local uppercase, uppercaseError = Validation.operation('compatibility_resolve_target', {
        actor_character_id = 'character_actor_0001', group_type = 'Job',
        group_key = 'police', grade_key = 'chief'
      })
      local mutation, mutationError = Validation.operation('compatibility_set_primary_grade', {
        idempotency_key = 'compatibility_request_0001',
        actor_character_id = 'character_actor_0001',
        membership_id = 'membership_police_0001', grade_id = 'grade_chief_0001',
        expected_version = 5, group_type = 'job', expected_primary_version = 0,
        reason = 'compatibility_mapping'
      })
      local badRevision, revisionError = Validation.operation('compatibility_set_primary_grade', {
        idempotency_key = 'compatibility_request_0001',
        actor_character_id = 'character_actor_0001',
        membership_id = 'membership_police_0001', grade_id = 'grade_chief_0001',
        expected_version = 5, group_type = 'job', expected_primary_version = -1,
        reason = 'compatibility_mapping'
      })
      assert(resolved and resolvedError == nil and mutation and mutationError == nil)
      assert(not unknown and unknownError.code == 'VALIDATION_FAILED')
      assert(not uppercase and uppercaseError.code == 'VALIDATION_FAILED')
      assert(not badRevision and revisionError.code == 'VALIDATION_FAILED')
      return true
    `);
    assert.equal(result, true);
  } finally {
    await engine.global.close();
  }
});

test('compatibility resolver uses three bounded indexed reads and returns only public state', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrapCompatibility(engine);
    const result = await engine.doString(`
      local queries = 0
      local tx = {}
      function tx.many(sql, parameters)
        queries = queries + 1
        assert(sql:find('LIMIT 2', 1, true))
        if queries == 1 then
          assert(sql:find('synex_group_types', 1, true) and parameters[1] == 'job')
          return { { group_type_internal_id = 12, type_key = 'job', status = 'active' } }
        end
        if queries == 2 then
          assert(sql:find('synex_group_organization_profiles', 1, true))
          assert(parameters[1] == 'chief' and parameters[2] == 12 and parameters[3] == 'police')
          return { { group_internal_id = 44, group_id = 'group_police_0001',
            legacy_group_key = 'police', legacy_group_type = 'job',
            group_status = 'active', group_key = 'police', group_lifecycle_state = 'ACTIVE',
            grade_id = 'grade_chief_0001', grade_status = 'active' } }
        end
        assert(queries == 3 and sql:find('synex_group_membership_profiles', 1, true))
        assert(parameters[1] == 12 and parameters[2] == 12 and parameters[3] == 44
          and parameters[4] == 'character_actor_0001')
        return { { membership_id = 'membership_police_0001', membership_version = 5,
          membership_storage_status = 'active', membership_status = 'ACTIVE',
          primary_state = 'selected', primary_version = 3,
          duty_session_id = 'duty_session_0001', duty_state = 'available',
          duty_status = 'open', duty_version = 2, duty_state_status = 'active',
          allowed_duty_state = 'available' } }
      end
      local value, failure = Compatibility.read.compatibility_resolve_target(tx, {
        actor_character_id = 'character_actor_0001', group_type = 'job',
        group_key = 'police', grade_key = 'chief'
      })
      assert(value and failure == nil and queries == 3)
      assert(value.group_id == 'group_police_0001' and value.grade_id == 'grade_chief_0001')
      assert(value.membership_id == 'membership_police_0001'
        and value.membership_status == 'ACTIVE' and value.membership_version == 5)
      assert(value.primary_state == 'selected' and value.primary_version == 3)
      assert(value.duty_session_id == 'duty_session_0001'
        and value.duty_state == 'available' and value.duty_version == 2)
      assert(value.character_id == nil and value.group_internal_id == nil
        and value.group_type_internal_id == nil)
      return queries .. ':' .. value.primary_state
    `);
    assert.equal(result, '3:selected');
  } finally {
    await engine.global.close();
  }
});

test('compatibility resolver distinguishes missing and inactive targets and rejects ambiguity', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrapCompatibility(engine);
    const result = await engine.doString(`
      local function resolve(typeRows, targetRows, membershipRows)
        local query = 0
        local tx = { many = function()
          query = query + 1
          if query == 1 then return typeRows end
          if query == 2 then return targetRows end
          return membershipRows
        end }
        return Compatibility.read.compatibility_resolve_target(tx, {
          actor_character_id = 'character_actor_0001', group_type = 'job',
          group_key = 'police', grade_key = 'chief'
        })
      end
      local _, missingType = resolve({}, {}, {})
      local _, inactiveType = resolve({ { group_type_internal_id = 12,
        type_key = 'job', status = 'disabled' } }, {}, {})
      local _, ambiguousType = resolve({
        { group_type_internal_id = 12, type_key = 'job', status = 'active' },
        { group_type_internal_id = 13, type_key = 'job', status = 'active' }
      }, {}, {})
      local activeType = { { group_type_internal_id = 12, type_key = 'job', status = 'active' } }
      local _, missingGroup = resolve(activeType, {}, {})
      local _, missingGrade = resolve(activeType, { { group_internal_id = 44,
        group_id = 'group_police_0001', legacy_group_key = 'police',
        legacy_group_type = 'job', group_status = 'active', group_key = 'police',
        group_lifecycle_state = 'ACTIVE' } }, {})
      assert(missingType.code == 'GROUP_TYPE_NOT_FOUND')
      assert(inactiveType.code == 'GROUP_TYPE_INACTIVE')
      assert(ambiguousType.code == 'DATABASE_RESULT_INVALID')
      assert(missingGroup.code == 'GROUP_NOT_FOUND')
      assert(missingGrade.code == 'GRADE_NOT_FOUND')
      return table.concat({ missingType.code, inactiveType.code, ambiguousType.code,
        missingGroup.code, missingGrade.code }, ':')
    `);
    assert.equal(
      result,
      'GROUP_TYPE_NOT_FOUND:GROUP_TYPE_INACTIVE:DATABASE_RESULT_INVALID:GROUP_NOT_FOUND:GRADE_NOT_FOUND',
    );
  } finally {
    await engine.global.close();
  }
});

test('atomic primary-grade mutation enforces self, both CAS revisions, and one combined effect result', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrapCompatibility(engine, true);
    const result = await engine.doString(`
      local primaryVersion = 3
      local tx = {}
      expectedTx = tx
      function tx.one(sql)
        if sql:find('synex_group_organization_profiles', 1, true) then
          return { id = 12, status = 'active', lifecycle_state = 'ACTIVE', group_status = 'active' }
        end
        assert(sql:find('synex_group_primary_memberships_by_type', 1, true))
        if primaryVersion == 0 then return nil end
        return { public_id = 'group_primary_0001', membership_id = 88,
          version = primaryVersion }
      end
      local runtime = {}
      function runtime.requireMembership(_, membershipId)
        return { id = 88, public_id = membershipId, group_id = 44,
          group_public_id = 'group_police_0001', character_id = 'character_actor_0001',
          lifecycle_state = 'ACTIVE', version = 5 }, nil
      end
      local request = {
        idempotency_key = 'compatibility_request_0001',
        actor_character_id = 'character_actor_0001',
        membership_id = 'membership_police_0001', grade_id = 'grade_chief_0001',
        expected_version = 5, group_type = 'job', expected_primary_version = 3,
        reason = 'compatibility_mapping'
      }
      local value, failure, effects = Compatibility.execute.compatibility_set_primary_grade(
        tx, request, runtime, {})
      assert(value and failure == nil and #effects == 2)
      assert(gradeCalls == 1 and primaryCalls == 1)
      assert(value.membership_version == 6 and value.primary_version == 4
        and value.grade_id == request.grade_id and value.replayed == false)

      request.expected_primary_version = 2
      local conflicted, conflictError = Compatibility.execute.compatibility_set_primary_grade(
        tx, request, runtime, {})
      assert(conflicted == nil and conflictError.code == 'CONCURRENT_MODIFICATION')
      assert(gradeCalls == 1 and primaryCalls == 1)

      request.expected_primary_version = 3
      failPrimary = true
      local partial, partialError = Compatibility.execute.compatibility_set_primary_grade(
        tx, request, runtime, {})
      assert(partial == nil and partialError.code == 'CONCURRENT_MODIFICATION')
      assert(gradeCalls == 2 and primaryCalls == 2)
      return value.membership_id .. ':' .. #effects .. ':' .. conflictError.code
    `);
    assert.equal(result, 'membership_police_0001:2:CONCURRENT_MODIFICATION');
  } finally {
    await engine.global.close();
  }
});

test('atomic compatibility approval preserves native policy and executes as the affected character', async () => {
  const lifecycle = await readFile(
    path.join(root, 'resources/synex_groups/server/persistence/memberships_lifecycle.lua'),
    'utf8',
  );
  const compatibility = await readFile(
    path.join(root, 'resources/synex_groups/server/persistence/compatibility.lua'),
    'utf8',
  );
  const approvals = await readFile(
    path.join(root, 'resources/synex_groups/server/persistence/approved_operations.lua'),
    'utf8',
  );
  const proposals = await readFile(
    path.join(root, 'resources/synex_groups/server/persistence/workflows_proposals.lua'),
    'utf8',
  );
  const persistence = await readFile(
    path.join(root, 'resources/synex_groups/server/persistence.lua'),
    'utf8',
  );
  assert.match(lifecycle, /approvalOperation = approvalOperation or 'members_set_grade'/u);
  assert.match(lifecycle, /'synex\.groups\.grades\.manage'/u);
  assert.match(compatibility, /membership\.character_id ~= request\.actor_character_id/u);
  assert.match(compatibility, /GradeHandlers\.members_set_grade[\s\S]*PrimaryHandlers\.members_set_primary/u);
  assert.match(approvals, /\['membership\.set_primary_grade'\] = 'compatibility_set_primary_grade'/u);
  assert.match(proposals, /proposal\.proposal_type == 'membership\.set_primary_grade'[\s\S]*profile`\.`character_id/u);
  assert.match(persistence, /dataPort:transaction\([\s\S]*handler, tx, request, runtime/u);
});
