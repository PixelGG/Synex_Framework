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

test('maximum public list and self-snapshot pages cross the service and cache boundaries', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await preload(engine, 'server.foundation', 'resources/synex_groups/server/foundation.lua');
    await preload(engine, 'server.validation', 'resources/synex_groups/server/validation.lua');
    await preload(engine, 'server.service', 'resources/synex_groups/server/service.lua');
    await preload(engine, 'server.cache', 'resources/synex_groups/server/cache.lua');
    const result = await engine.doString(`
      local Foundation = require 'server.foundation'
      local createService = require('server.service')(Foundation)
      local cache = require('server.cache')(Foundation)({ maximum = 16, ttlMs = 5000,
        now = function() return 1000 end })
      local responses = {}
      local relationships, assignments, duty = {}, {}, {}
      for index = 1, 40 do
        local suffix = string.format('%04d', index)
        relationships[index] = {
          relationship_id = 'relationship_' .. suffix,
          source_group_id = 'group_source_' .. suffix,
          target_group_id = 'group_target_' .. suffix,
          relation_type = 'partner_of', direction = 'symmetric', status = 'active',
          valid_from = '2026-08-25T10:00:00.000000Z', version = 1,
          created_at = '2026-08-25T10:00:00.000000Z',
          updated_at = '2026-08-25T10:00:00.000000Z'
        }
        assignments[index] = {
          assignment_id = 'assignment_' .. suffix, group_id = 'group_alpha_0001',
          name = 'Assignment ' .. index, type = 'unit', status = 'active',
          member_limit = 100, member_count = 100,
          starts_at = '2026-08-25T10:00:00.000000Z', version = 1
        }
        duty[index] = {
          duty_session_id = 'duty_session_' .. suffix,
          membership_id = 'membership_' .. suffix, group_id = 'group_alpha_0001',
          state = 'on_duty', status = 'open', counts_as_on_duty = true,
          started_at = '2026-08-25T10:00:00.000000Z', version = 1
        }
      end
      responses.relationships_list = { items = relationships, truncated = false }
      responses.assignments_list = { items = assignments, truncated = false }
      responses.duty_list = { items = duty, truncated = false }
      local memberships = {}
      for memberIndex = 1, 8 do
        local roles = {}
        for roleIndex = 1, 8 do
          roles[roleIndex] = {
            role_id = ('role_%02d_%02d'):format(memberIndex, roleIndex),
            key = ('role_%02d'):format(roleIndex), name = 'Role ' .. roleIndex,
            valid_until = '2026-08-26T10:00:00.000000Z'
          }
        end
        memberships[memberIndex] = {
          membership_id = ('membership_self_%02d'):format(memberIndex),
          group = { group_id = ('group_self_%02d'):format(memberIndex),
            type = 'organization', name = 'Group ' .. memberIndex },
          status = 'ACTIVE',
          grade = { grade_id = ('grade_self_%02d'):format(memberIndex),
            key = 'member', name = 'Member', rank = 10 },
          roles = roles, roles_truncated = false,
          duty = { duty_session_id = ('duty_self_%02d'):format(memberIndex),
            state = 'on_duty', counts_as_on_duty = true,
            assignment_id = ('assignment_self_%02d'):format(memberIndex), version = 1 }
        }
      end
      responses.self_snapshot = { items = memberships, truncated = false }
      local reads = {}
      local repository = {}
      function repository:read(operation)
        reads[operation] = (reads[operation] or 0) + 1
        return responses[operation], nil, {}
      end
      function repository:execute() error('read fixtures must not execute mutations') end
      local methods = createService({
        repository = repository,
        characters = { get = function(characterId) return { id = characterId } end },
        hooks = { run = function() error('read fixtures must not run hooks') end },
        audit = { append = function() return { eventId = 'audit_event_0001' } end },
        runtimeEffects = { apply = function() return true end }, cache = cache,
        jsonEncode = function() return '{}' end,
        errorSink = function() end
      })
      local context = { traceId = 'trace_response_bounds_0001',
        caller = 'synex_fixture', callerEpoch = 1 }
      local actor, group = 'character_actor_0001', 'group_alpha_0001'
      assert(methods.relationships_list({ actor_character_id = actor,
        group_id = group, limit = 40 }, context))
      assert(methods.assignments_list({ actor_character_id = actor,
        group_id = group, limit = 40 }, context))
      assert(methods.duty_list({ actor_character_id = actor,
        group_id = group, limit = 40 }, context))
      local session = { state = 'ACTIVE', characterId = 'character_self_0001',
        source = 17, sourceGeneration = 3 }
      local selfContext = { traceId = 'trace_response_bounds_0002',
        caller = 'synex_core', callerEpoch = 1, source = 17,
        sourceGeneration = 3, session = session }
      local snapshot = assert(methods.self_snapshot({ limit = 8 }, selfContext))
      assert(#snapshot.items == 8 and #snapshot.items[8].roles == 8)
      local cached = assert(methods.self_snapshot({ limit = 8 }, selfContext))
      assert(#cached.items == 8 and reads.self_snapshot == 1)
      return table.concat({ #relationships, #assignments, #duty,
        #cached.items, cache:snapshot().hits }, ':')
    `);
    assert.equal(result, '40:40:40:8:1');
  } finally {
    engine.global.close();
  }
});

test('open-object read models fail closed below the Core response transport ceiling', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await preload(engine, 'server.foundation', 'resources/synex_groups/server/foundation.lua');
    await preload(engine, 'server.validation', 'resources/synex_groups/server/validation.lua');
    await preload(engine, 'server.service', 'resources/synex_groups/server/service.lua');
    const result = await engine.doString(`
      local Foundation = require 'server.foundation'
      local createService = require('server.service')(Foundation)
      local cachePuts = 0
      local methods = createService({
        repository = {
          read = function()
            return {
              relationship_id = 'relationship_large_0001',
              source_group_id = 'group_source_0001', target_group_id = 'group_target_0001',
              relation_type = 'partner_of', direction = 'symmetric', status = 'active',
              valid_from = '2026-08-25T10:00:00.000000Z', version = 1,
              created_at = '2026-08-25T10:00:00.000000Z',
              updated_at = '2026-08-25T10:00:00.000000Z',
              metadata = { left = string.rep('x', 16000), right = string.rep('y', 16000) }
            }, nil, {}
          end,
          execute = function() error('large response fixture must stay read-only') end
        },
        characters = { get = function(characterId) return { id = characterId } end },
        hooks = { run = function() error('read fixture must not run hooks') end },
        audit = { append = function() return { eventId = 'audit_event_0001' } end },
        runtimeEffects = { apply = function() return true end },
        cache = { get = function() return nil end, put = function() cachePuts = cachePuts + 1 end,
          invalidatePrefix = function() return 0 end },
        jsonEncode = function(value)
          if value.metadata and value.metadata.left then return string.rep('z', 30001) end
          return '{}'
        end,
        errorSink = function() end
      })
      local value, failure = methods.relationships_get({
        actor_character_id = 'character_actor_0001', group_id = 'group_alpha_0001',
        relationship_id = 'relationship_large_0001'
      }, { traceId = 'trace_response_large_0001', caller = 'synex_fixture', callerEpoch = 1 })
      assert(value == nil and failure.code == 'READ_MODEL_TOO_LARGE' and cachePuts == 0)
      return failure.code
    `);
    assert.equal(result, 'READ_MODEL_TOO_LARGE');
  } finally {
    engine.global.close();
  }
});

test('every schema-maximal Groups response remains below the Core 32 KiB transport bound', async () => {
  const catalog = JSON.parse(await readFile(path.join(
    root,
    'resources/synex_groups/groups.contracts.json',
  ), 'utf8')) as {
    contracts: Array<{ name: string; output: Record<string, unknown> }>;
  };

  function maximalValue(schema: Record<string, any>, depth = 0): unknown {
    assert.ok(depth <= 20, 'contract output schema recursion must remain bounded');
    if (Array.isArray(schema.anyOf)) {
      return schema.anyOf
        .map((candidate: Record<string, any>) => maximalValue(candidate, depth + 1))
        .sort((left: unknown, right: unknown) => (
          Buffer.byteLength(JSON.stringify(right)) - Buffer.byteLength(JSON.stringify(left))
        ))[0];
    }
    if (schema.type === 'object') {
      return Object.fromEntries(Object.entries(schema.properties ?? {}).map(
        ([key, value]) => [key, maximalValue(value as Record<string, any>, depth + 1)],
      ));
    }
    if (schema.type === 'array') {
      return Array.from(
        { length: schema.maxItems ?? 0 },
        () => maximalValue(schema.items, depth + 1),
      );
    }
    if (schema.type === 'string') return 'x'.repeat(schema.maxLength ?? 64);
    if (schema.type === 'integer' || schema.type === 'number') {
      return schema.maximum ?? 999_999_999_999;
    }
    if (schema.type === 'boolean') return true;
    return null;
  }

  for (const contract of catalog.contracts) {
    const encoded = JSON.stringify(maximalValue(contract.output));
    assert.ok(
      Buffer.byteLength(encoded) <= 32_768,
      `${contract.name} schema maximum exceeds the Core response transport bound`,
    );
  }
});
