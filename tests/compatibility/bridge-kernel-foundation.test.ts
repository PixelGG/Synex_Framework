import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';

const foundationPath = path.join(
  process.cwd(), 'libraries', 'synex_bridge', 'kernel', 'foundation.lua',
);

test('bridge kernel exposes a closed error and status vocabulary', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await engine.doString(await readFile(foundationPath, 'utf8'));
    const result = await engine.doString(String.raw`
      local foundation = SynexBridgeKernel.Foundation
      assert(foundation.isStatus('CERTIFIED') and foundation.isStatus('COMPATIBLE'))
      assert(foundation.isStatus('PARTIAL') and foundation.isStatus('UNSUPPORTED'))
      assert(foundation.isStatus('UNKNOWN') and not foundation.isStatus('READY'))
      assert(foundation.isMode('strict') and foundation.isMode('compat')
        and foundation.isMode('silent') and not foundation.isMode('permissive'))
      local catalog = foundation.errorCatalog()
      assert(catalog.COMPAT_PROVIDER_DISABLED and catalog.COMPAT_API_UNSUPPORTED)
      assert(catalog.COMPAT_MAPPING_MISSING and catalog.COMPAT_MAPPING_AMBIGUOUS)
      assert(catalog.COMPAT_ADAPTER_MISSING and catalog.COMPAT_CONSUMER_DENIED)
      assert(catalog.COMPAT_CATALOG_UNAVAILABLE)
      assert(catalog.COMPAT_STALE_SESSION and catalog.COMPAT_CALLBACK_TIMEOUT)
      assert(catalog.COMPAT_CALLBACK_LIMIT and catalog.COMPAT_PROJECTION_UNAVAILABLE)
      assert(catalog.COMPAT_FRAMEWORK_CONFLICT and catalog.COMPAT_IDENTITY_CONFLICT)
      assert(catalog.COMPAT_PROFILE_INCOMPLETE)
      catalog.COMPAT_API_UNSUPPORTED.message = 'mutated'
      assert(foundation.error('COMPAT_API_UNSUPPORTED').message
        == 'The requested compatibility API is unsupported.')
      local unknown = foundation.error('PRIVATE_EXCEPTION')
      assert(unknown.code == 'COMPAT_INTERNAL' and unknown.retryable == true)
      assert(unknown.private == nil and unknown.details == nil)
      return 'ok'
    `);
    assert.equal(result, 'ok');
  } finally {
    engine.global.close();
  }
});

test('bridge DTO validation accepts Cfx JSON containers and returns detached canonical copies', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await engine.doString(await readFile(foundationPath, 'utf8'));
    const result = await engine.doString(String.raw`
      local foundation = SynexBridgeKernel.Foundation
      local object = setmetatable({
        name = 'fixture',
        nested = setmetatable({ enabled = true }, { __jsontype = 'object' }),
        values = setmetatable({ 2, 4, 8 }, { __jsontype = 'array' }),
        empty = setmetatable({}, { __jsontype = 'array' }),
      }, { __jsontype = 'object' })
      local copied, copyError = foundation.copyDto(object, { root = 'object' })
      assert(copied and copyError == nil and copied ~= object)
      assert(copied.nested ~= object.nested and copied.values ~= object.values)
      assert(copied.values[2] == 4 and getmetatable(copied.values).__jsontype == 'array')
      assert(getmetatable(copied.empty).__jsontype == 'array')
      local emptyArguments, emptyArgumentsError = foundation.copyDto({}, { root = 'array' })
      assert(emptyArguments and emptyArgumentsError == nil
        and getmetatable(emptyArguments).__jsontype == 'array'
        and #emptyArguments == 0)
      object.nested.enabled = false
      object.values[2] = 99
      assert(copied.nested.enabled == true and copied.values[2] == 4)

      local protected = setmetatable({ value = 'safe' }, {
        __jsontype = 'object', __metatable = 'cfx-json-object'
      })
      local protectedCopy, protectedError = foundation.copyDto(protected, { root = 'object' })
      assert(protectedCopy and protectedError == nil and protectedCopy.value == 'safe')
      return 'ok'
    `);
    assert.equal(result, 'ok');
  } finally {
    engine.global.close();
  }
});

test('bridge DTO validation rejects cycles, sparse arrays, metatables, non-finite values, and overflow', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await engine.doString(await readFile(foundationPath, 'utf8'));
    const result = await engine.doString(String.raw`
      local foundation = SynexBridgeKernel.Foundation
      local cyclic = {}
      cyclic.self = cyclic
      local _, cyclicError = foundation.copyDto(cyclic)
      assert(cyclicError.code == 'COMPAT_DTO_CYCLE')

      local _, sparseError = foundation.copyDto({ [1] = 'a', [3] = 'c' })
      assert(sparseError.code == 'COMPAT_DTO_INVALID')
      local _, mixedError = foundation.copyDto({ [1] = 'a', key = 'value' })
      assert(mixedError.code == 'COMPAT_DTO_INVALID')
      local _, numberError = foundation.copyDto({ value = math.huge })
      assert(numberError.code == 'COMPAT_DTO_INVALID')
      local _, functionError = foundation.copyDto({ value = function() end })
      assert(functionError.code == 'COMPAT_DTO_INVALID')
      local _, metadataError = foundation.copyDto(setmetatable({}, { custom = true }))
      assert(metadataError.code == 'COMPAT_DTO_INVALID')
      local _, forgedJsonError = foundation.copyDto(setmetatable({ value = true }, {
        __jsontype = 'object', __pairs = function() error('must not execute') end,
      }))
      assert(forgedJsonError.code == 'COMPAT_DTO_INVALID')
      local _, entryError = foundation.copyDto({ a = 1, b = 2 }, {
        root = 'object', maximumEntries = 2, maximumObjectProperties = 2,
      })
      assert(entryError.code == 'COMPAT_DTO_LIMIT')
      local _, stringError = foundation.copyDto({ value = string.rep('a', 17) }, {
        root = 'object', maximumStringBytes = 16,
      })
      assert(stringError.code == 'COMPAT_DTO_LIMIT')
      local _, rootError = foundation.copyDto({ 1, 2 }, { root = 'object' })
      assert(rootError.code == 'COMPAT_DTO_INVALID')
      local _, closedRootError = foundation.copyClosedObject({ 1 }, {}, {}, {})
      assert(closedRootError.code == 'COMPAT_DTO_INVALID')
      return table.concat({cyclicError.code, sparseError.code, entryError.code}, ':')
    `);
    assert.equal(result, 'COMPAT_DTO_CYCLE:COMPAT_DTO_INVALID:COMPAT_DTO_LIMIT');
  } finally {
    engine.global.close();
  }
});
