import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';

const root = path.join(process.cwd(), 'resources', 'synex_entities');

test('logical owners validate active characters and fail closed for deleted or unavailable identities', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await engine.doString(await readFile(path.join(root, 'shared', 'validation.lua'), 'utf8'));
    await engine.doString(await readFile(path.join(root, 'server', 'logical_owner.lua'), 'utf8'));
    const result = await engine.doString(String.raw`
      local mode = 'active'
      local calls = 0
      local coreRef = { value = {
        Characters = {
          get = function(characterId)
            calls = calls + 1
            if mode == 'active' then
              return { id = characterId, status = 'active' }
            end
            if mode == 'deleted' then
              return nil, { code = 'CHARACTER_NOT_FOUND', message = 'missing' }
            end
            return nil, { code = 'DATABASE_ERROR', message = 'offline', retryable = true }
          end,
        },
        Services = {
          call = function(_, _, _, request)
            if request.group_id == 'group_found' then return { id = request.group_id } end
            return nil, { code = 'GROUP_NOT_FOUND', message = 'missing' }
          end,
        },
      } }
      local foundation = {
        failure = function(code, message, retryable, context)
          return nil, { code = code, message = message, retryable = retryable == true,
            traceId = context and context.traceId or nil }
        end,
        isCallable = function(value) return type(value) == 'function' end,
        protect = function(_, handler)
          local values = table.pack(pcall(handler))
          return table.unpack(values, 1, values.n)
        end,
      }
      local service = SynexEntityLogicalOwner.create({
        coreRef = coreRef, foundation = foundation, validation = SynexEntityValidation,
      })
      local context = { traceId = 'trace_logical_owner_0001' }
      local character = assert(service.validate(
        { type = 'character', id = 'character_001' }, 'synex_vehicles', context))
      assert(character.id == 'character_001' and calls == 1)

      mode = 'deleted'
      local deleted, deletedError = service.validate(
        { type = 'character', id = 'character_002' }, 'synex_vehicles', context)
      assert(deleted == nil and deletedError.code == 'INVALID_LOGICAL_OWNER')
      mode = 'offline'
      local unavailable, unavailableError = service.validate(
        { type = 'character', id = 'character_003' }, 'synex_vehicles', context)
      assert(unavailable == nil and unavailableError.code == 'UNAVAILABLE'
        and unavailableError.retryable == true)

      assert(service.validate({ type = 'group', id = 'group_found' },
        'synex_vehicles', context))
      local group, groupError = service.validate({ type = 'group', id = 'group_missing' },
        'synex_vehicles', context)
      assert(group == nil and groupError.code == 'INVALID_LOGICAL_OWNER')
      local foreign, foreignError = service.validate(
        { type = 'resource', id = 'synex_jobs' }, 'synex_vehicles', context)
      assert(foreign == nil and foreignError.code == 'FOREIGN_RESOURCE_OWNER')
      local systemOwner = assert(service.validate(
        { type = 'system', id = 'world' }, 'synex_vehicles', context))
      assert(systemOwner.id == 'world' and calls == 3)
      return deletedError.code .. ':' .. unavailableError.code .. ':' .. groupError.code
    `) as string;
    assert.equal(result, 'INVALID_LOGICAL_OWNER:UNAVAILABLE:INVALID_LOGICAL_OWNER');
  } finally {
    engine.global.close();
  }
});

test('entities requests the Core identity-read grant and uses the same owner verifier for spawn and ownerSet', async () => {
  const [descriptorSource, authority] = await Promise.all([
    readFile(path.join(root, 'synex.resource.json'), 'utf8'),
    readFile(path.join(root, 'server', 'authority_service.lua'), 'utf8'),
  ]);
  const descriptor = JSON.parse(descriptorSource) as {
    capabilities: { request: string[] };
  };
  assert.ok(descriptor.capabilities.request.includes('synex.identity.read'));
  assert.equal((authority.match(/logicalOwner\.validate\(/gu) ?? []).length, 2);
});
