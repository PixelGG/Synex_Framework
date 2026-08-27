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
  await preload(engine, 'server.validation', 'resources/synex_groups/server/validation.lua');
  await preload(engine, 'server.service', 'resources/synex_groups/server/service.lua');
}

test('Groups hooks cannot rewrite lifecycle, hierarchy, privacy, or nested policy authority', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrap(engine);
    const result = await engine.doString(`
      local Foundation = require 'server.foundation'
      local createService = require('server.service')(Foundation)
      local hookMode = 'clone'
      local repositoryCalls = 0
      local lastRequest

      local hooks = {}
      function hooks.run(_, request, hookContext)
        if hookMode == 'create_status' then request.status = 'active'; return request end
        if hookMode == 'create_dynamic' then request.dynamic = true; return request end
        if hookMode == 'create_visibility' then request.visibility = 'hidden'; return request end
        if hookMode == 'update_status' then request.status = 'suspended'; return request end
        if hookMode == 'update_parent' then
          request.parent_group_id = 'group_parent_bravo_0001'
          return request
        end
        if hookMode == 'update_visibility' then request.visibility = 'members'; return request end
        if hookMode == 'policy_in_place' then
          request.definition.rules[1].constraints.maximum_rank = 99
          return request
        end

        local copy = Foundation.copyPlain(request, { preserveContainerKind = true })
        if hookMode == 'policy_nested_clone' then
          copy.definition.rules[1].constraints.maximum_rank = 99
        elseif hookMode == 'decorate_create' or hookMode == 'decorate_update' then
          copy.description = 'policy-approved-description'
        elseif hookMode == 'decorate_policy' then
          copy.reason = 'policy-approved-reason'
        end
        return copy
      end

      local repository = {}
      function repository:preflight()
        return true
      end
      function repository:execute(operation, request)
        repositoryCalls = repositoryCalls + 1
        lastRequest = request
        return {
          entity_id = request.group_id or 'group_created_0001',
          entity_type = 'group',
          status = request.status or 'ok',
          version = request.expected_version or 1,
          replayed = false
        }, nil, {}
      end
      function repository:read()
        error('read operations are not used by this fixture')
      end

      local methods = createService({
        repository = repository,
        characters = { get = function(characterId) return { id = characterId } end },
        hooks = hooks,
        audit = { append = function() return { eventId = 'audit_event_0001' } end },
        runtimeEffects = { apply = function() return true end },
        jsonEncode = function() return '{}' end,
        cache = {
          get = function() return nil end,
          put = function() return true end,
          invalidatePrefix = function() return 0 end
        },
        errorSink = function() end
      })
      local context = {
        traceId = 'trace_hook_authority_0001',
        caller = 'synex_fixture',
        callerEpoch = 4,
        deadlineAt = 999999
      }

      local function createRequest(suffix)
        return {
          idempotency_key = 'idem_create_' .. suffix .. '_0001',
          actor_character_id = 'character_actor_0001',
          type = 'faction',
          slug = 'alpha_unit',
          name = 'Alpha Unit',
          label = 'Alpha',
          parent_group_id = 'group_parent_alpha_0001',
          status = 'draft',
          dynamic = false,
          visibility = 'public',
          description = 'original-description'
        }
      end

      local function updateRequest(suffix)
        return {
          idempotency_key = 'idem_update_' .. suffix .. '_0001',
          actor_character_id = 'character_actor_0001',
          group_id = 'group_alpha_0001',
          expected_version = 7,
          status = 'active',
          parent_group_id = 'group_parent_alpha_0001',
          visibility = 'public',
          description = 'original-description'
        }
      end

      local function policyRequest(suffix)
        return {
          idempotency_key = 'idem_policy_' .. suffix .. '_0001',
          actor_character_id = 'character_actor_0001',
          group_id = 'group_alpha_0001',
          expected_version = 11,
          action = 'members.manage',
          definition = {
            effect = 'allow',
            rules = {
              {
                subject = 'management',
                constraints = { maximum_rank = 4, subtree = false }
              }
            }
          },
          reason = 'original-reason'
        }
      end

      local function expectRejected(operation, request, mode)
        hookMode = mode
        local callsBefore = repositoryCalls
        local value, failure = methods[operation](request, context)
        assert(value == nil and failure and failure.code == 'HOOK_REJECTED', mode)
        assert(repositoryCalls == callsBefore, mode .. ':repository')
      end

      expectRejected('create', createRequest('status'), 'create_status')
      expectRejected('create', createRequest('dynamic'), 'create_dynamic')
      expectRejected('create', createRequest('visibility'), 'create_visibility')
      expectRejected('update', updateRequest('status'), 'update_status')
      expectRejected('update', updateRequest('parent'), 'update_parent')
      expectRejected('update', updateRequest('visibility'), 'update_visibility')
      expectRejected('policies_set', policyRequest('in_place'), 'policy_in_place')
      expectRejected('policies_set', policyRequest('nested_clone'), 'policy_nested_clone')

      hookMode = 'clone'
      assert(methods.policies_set(policyRequest('equal_clone'), context))
      assert(lastRequest.definition.rules[1].constraints.maximum_rank == 4)

      hookMode = 'decorate_create'
      assert(methods.create(createRequest('decorate'), context))
      assert(lastRequest.description == 'policy-approved-description')

      hookMode = 'decorate_update'
      assert(methods.update(updateRequest('decorate'), context))
      assert(lastRequest.description == 'policy-approved-description')

      hookMode = 'decorate_policy'
      assert(methods.policies_set(policyRequest('decorate'), context))
      assert(lastRequest.reason == 'policy-approved-reason')

      return repositoryCalls
    `);
    assert.equal(result, 4);
  } finally {
    await engine.global.close();
  }
});
