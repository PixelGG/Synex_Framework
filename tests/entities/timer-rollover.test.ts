import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';

import { LuaFactory } from 'wasmoon';

const bootstrapPath = path.join(
  process.cwd(), 'resources', 'synex_entities', 'server', 'bootstrap_config.lua',
);

test('entity runtime clock stays monotonic across signed and unsigned Cfx timer rollover', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await engine.doString(await readFile(bootstrapPath, 'utf8'));
    const result = await engine.doString(String.raw`
      local values = { 2147483646, 2147483647, -2147483648, -2147483647,
        -2, -1, 0, 1 }
      local index = 0
      local clock = SynexEntityBootstrapConfig.monotonicClock(function()
        index = index + 1
        return values[index]
      end)
      local observed = {}
      for _ = 1, #values do observed[#observed + 1] = clock() end
      assert(observed[1] == 2147483646 and observed[2] == 2147483647
        and observed[3] == 2147483648 and observed[4] == 2147483649)
      assert(observed[5] == 4294967294 and observed[6] == 4294967295
        and observed[7] == 4294967296 and observed[8] == 4294967297)
      return observed[1] .. ':' .. observed[#observed]
    `) as string;
    assert.equal(result, '2147483646:4294967297');
  } finally {
    engine.global.close();
  }
});
