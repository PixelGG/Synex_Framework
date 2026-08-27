import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';

const root = process.cwd();

test('Groups JSON runtime supplies stable inert metatables to the Cfx decoder', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    const [foundationSource, runtimeSource] = await Promise.all([
      readFile(path.join(root, 'resources/synex_groups/server/foundation.lua'), 'utf8'),
      readFile(path.join(root, 'resources/synex_groups/server/json_runtime.lua'), 'utf8'),
    ]);
    await engine.doString(`
      local Foundation = assert(load(${JSON.stringify(foundationSource)}, '@server/foundation.lua'))()
      local createJsonRuntime = assert(load(${JSON.stringify(runtimeSource)}, '@server/json_runtime.lua'))()
      local firstObjectMetatable, firstArrayMetatable
      local decodeCalls, encodeCalls = 0, 0
      local runtimeJson = {
        decode = function(value, position, nullValue, objectMetatable, arrayMetatable)
          assert(value == '{"items":[]}')
          assert(position == 1 and nullValue == nil)
          assert(type(objectMetatable) == 'table' and objectMetatable.__jsontype == 'object')
          assert(type(arrayMetatable) == 'table' and arrayMetatable.__jsontype == 'array')
          assert(next(objectMetatable, '__jsontype') == nil)
          assert(next(arrayMetatable, '__jsontype') == nil)
          assert(objectMetatable ~= arrayMetatable)
          if decodeCalls == 0 then
            firstObjectMetatable, firstArrayMetatable = objectMetatable, arrayMetatable
          else
            assert(objectMetatable == firstObjectMetatable)
            assert(arrayMetatable == firstArrayMetatable)
          end
          decodeCalls = decodeCalls + 1
          return setmetatable({
            items = setmetatable({}, arrayMetatable)
          }, objectMetatable)
        end,
        encode = function(value)
          encodeCalls = encodeCalls + 1
          assert(value.accepted == true)
          return '{"accepted":true}'
        end
      }

      assert(runtimeJson.object == nil and runtimeJson.array == nil)
      local JsonRuntime = createJsonRuntime(runtimeJson)
      local first = JsonRuntime.decode('{"items":[]}')
      local second = JsonRuntime.decode('{"items":[]}')
      assert(decodeCalls == 2)
      assert(getmetatable(first) == getmetatable(second))
      assert(getmetatable(first.items) == getmetatable(second.items))
      assert(Foundation.jsonContainerKind(first) == 'object')
      assert(Foundation.jsonContainerKind(first.items) == 'array')
      local copied = Foundation.copyPlain(first, { preserveContainerKind = true })
      assert(getmetatable(copied) == getmetatable(first))
      assert(getmetatable(copied.items) == getmetatable(first.items))
      assert(JsonRuntime.encode({ accepted = true }) == '{"accepted":true}')
      assert(encodeCalls == 1)

      local hostile = setmetatable({}, {
        __jsontype = 'object',
        __index = function() return true end
      })
      local accepted = pcall(Foundation.copyPlain, hostile)
      assert(accepted == false)
    `);
  } finally {
    engine.global.close();
  }
});
