import assert from 'node:assert/strict';
import test from 'node:test';
import { runWorldLua } from './helpers.ts';

test('World JSON decoding normalizes fresh Cfx container metatables and rejects lookalikes', async () => {
  const result = await runWorldLua<string>(String.raw`
    local decoder = SynexWorldValidation.createJsonDecoder({
      decode = function(_, _, _, objectMeta, arrayMeta)
        return setmetatable({
          schema = 1,
          objects = setmetatable({
            setmetatable({ kind = 'location', tags = setmetatable({}, arrayMeta) }, objectMeta)
          }, arrayMeta),
        }, objectMeta)
      end,
    })
    local decoded = decoder('{}')
    assert(SynexWorldValidation.jsonContainerKind(decoded) == 'object'
      and SynexWorldValidation.jsonContainerKind(decoded.objects) == 'array')
    assert(SynexWorldValidation.jsonContainerKind(decoded.objects[1]) == 'object'
      and SynexWorldValidation.jsonContainerKind(decoded.objects[1].tags) == 'array'
      and #decoded.objects == 1)
    local copied = SynexWorldValidation.copy(decoded)
    assert(SynexWorldValidation.jsonContainerKind(copied.objects[1].tags) == 'array')

    local hostile = SynexWorldValidation.createJsonDecoder({
      decode = function()
        return setmetatable({}, { __jsontype = 'object' })
      end,
    })
    local ok = pcall(hostile, '{}')
    assert(ok == false)
    return decoded.objects[1].kind
  `, ['shared/limits.lua', 'shared/validation.lua']);
  assert.equal(result, 'location');
});
