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

test('mutation authority preflight conceals character existence and always precedes hooks', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await preload(engine, 'server.foundation', 'resources/synex_groups/server/foundation.lua');
    await preload(engine, 'server.validation', 'resources/synex_groups/server/validation.lua');
    await preload(engine, 'server.service', 'resources/synex_groups/server/service.lua');
    const result = await engine.doString(`
      local Foundation = require 'server.foundation'
      local createService = require('server.service')(Foundation)
      local mode = 'deny'
      local preflights, characterReads, hooks, executions = 0, 0, 0, 0

      local repository = {}
      function repository:preflight(operation, request)
        preflights = preflights + 1
        assert(operation == 'members_invite')
        if mode == 'retryable' then
          return nil, Foundation.domainError('CORE_UNAVAILABLE',
            'private infrastructure detail', true, { secret = 'must_not_escape' })
        end
        if mode == 'deny' then
          return nil, Foundation.domainError('INSUFFICIENT_PERMISSION',
            'The actor character may not perform this Groups operation.')
        end
        return true, nil
      end
      function repository:execute(operation)
        executions = executions + 1
        assert(operation == 'members_invite')
        return {
          entity_id = 'groups_invitation_00000001', entity_type = 'invitation',
          status = 'pending', version = 1, replayed = false
        }, nil, {}
      end
      function repository:read() error('mutation fixture cannot read') end

      local methods = createService({
        repository = repository,
        characters = { get = function(characterId)
          characterReads = characterReads + 1
          if characterId == 'character_missing_0001' then
            return nil, Foundation.domainError('CHARACTER_NOT_FOUND', 'missing')
          end
          return { id = characterId }, nil
        end },
        hooks = { run = function(_, request)
          hooks = hooks + 1
          return Foundation.copyPlain(request, { preserveContainerKind = true }), nil
        end },
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
      local context = {
        traceId = 'trace_preflight_0001', caller = 'synex_probe', callerEpoch = 3
      }
      local function request(actor, target, suffix)
        return {
          idempotency_key = 'invite_preflight_' .. suffix,
          actor_character_id = actor,
          group_id = 'groups_group_00000001',
          character_id = target
        }
      end

      local deniedExisting, deniedExistingError = methods.members_invite(request(
        'character_actor_0001', 'character_target_0001', 'existing'), context)
      local deniedMissing, deniedMissingError = methods.members_invite(request(
        'character_missing_0001', 'character_missing_0001', 'missing'), context)
      assert(deniedExisting == nil and deniedMissing == nil)
      assert(deniedExistingError.code == deniedMissingError.code
        and deniedExistingError.message == deniedMissingError.message
        and deniedExistingError.retryable == deniedMissingError.retryable
        and deniedExistingError.details == deniedMissingError.details)
      assert(characterReads == 0 and hooks == 0 and executions == 0)

      mode = 'retryable'
      local unavailable, unavailableError = methods.members_invite(request(
        'character_actor_0001', 'character_target_0001', 'retryable'), context)
      assert(unavailable == nil and unavailableError.code == 'DATABASE_ERROR'
        and unavailableError.retryable == true and unavailableError.details == nil)
      assert(characterReads == 0 and hooks == 0 and executions == 0)

      mode = 'allow'
      local missingTarget, missingTargetError = methods.members_invite(request(
        'character_actor_0001', 'character_missing_0001', 'authorized_missing'), context)
      assert(missingTarget == nil and missingTargetError.code == 'CHARACTER_NOT_FOUND')
      assert(hooks == 0 and executions == 0 and characterReads == 2)

      local invited, inviteError = methods.members_invite(request(
        'character_actor_0001', 'character_target_0001', 'authorized'), context)
      assert(inviteError == nil and invited and invited.status == 'pending',
        'invite:' .. tostring(inviteError and inviteError.code))
      assert(hooks == 1 and executions == 1 and characterReads == 6,
        table.concat({ hooks, executions, characterReads }, ':'))
      return table.concat({ preflights, characterReads, hooks, executions }, ':')
    `);
    assert.equal(result, '5:6:1:1');
  } finally {
    await engine.global.close();
  }
});
