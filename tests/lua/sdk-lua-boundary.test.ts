import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';

const sdkPath = path.join(process.cwd(), 'packages', 'sdk-lua', 'synex.lua');

test('Lua SDK normalizes only raw Cfx failures and preserves false success values', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await engine.doString(`
      local descriptor = {
        name = 'synex.fixture.boolean', version = '1.0.0'
      }
      SynexLuaGeneratedContracts = {
        sourceHash = 'fixture',
        latest = { ['synex.fixture.boolean'] = descriptor },
        versions = { ['synex.fixture.boolean@1.0.0'] = descriptor }
      }
      local mode = 'success'
      exports = {
        synex_core = {
          GetAPI = function()
            if mode == 'connect_failure' then
              return false, { code = 'CALLER_REQUIRED' }
            end
            return { owner = 'synex_fixture' }, nil
          end,
          Invoke = function()
            if mode == 'failure' then
              return false, { code = 'FIXTURE_FAILURE' }
            end
            return false, nil
          end
        }
      }
      FixtureSetMode = function(value) mode = value end
    `);
    await engine.doString(await readFile(sdkPath, 'utf8'));

    const result = await engine.doString(`
      local client, connectError = SynexLuaSDK.connect()
      assert(client ~= nil and connectError == nil)

      FixtureSetMode('failure')
      local failed, requestError = client:request('synex.fixture.boolean', {})
      assert(failed == nil and requestError.code == 'FIXTURE_FAILURE')

      FixtureSetMode('success')
      local booleanValue, booleanError = client:requestVersion(
        'synex.fixture.boolean', '1.0.0', {})
      assert(booleanValue == false and booleanError == nil)

      FixtureSetMode('connect_failure')
      local unavailable, unavailableError = SynexLuaSDK.connect()
      assert(unavailable == nil and unavailableError.code == 'CALLER_REQUIRED')

      return table.concat({requestError.code, tostring(booleanValue), unavailableError.code}, ':')
    `);
    assert.equal(result, 'FIXTURE_FAILURE:false:CALLER_REQUIRED');
  } finally {
    engine.global.close();
  }
});
