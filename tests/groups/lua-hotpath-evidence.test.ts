import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { performance } from 'node:perf_hooks';
import test from 'node:test';

import { LuaFactory, type LuaEngine } from 'wasmoon';

const root = process.cwd();

async function preload(engine: LuaEngine, name: string, relativePath: string): Promise<void> {
  const source = await readFile(path.join(root, relativePath), 'utf8');
  await engine.doString(
    `package.preload[${JSON.stringify(name)}] = assert(load(${JSON.stringify(source)}, ${JSON.stringify(`@${relativePath}`)}))`,
  );
}

test('actual Lua runtime-index hot keys remain non-enumerating under a realistic headless load', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await preload(engine, 'server.foundation', 'resources/synex_groups/server/foundation.lua');
    await preload(engine, 'server.runtime_index',
      'resources/synex_groups/server/runtime_index.lua');
    await engine.doString(`
      local Foundation = require 'server.foundation'
      local RuntimeIndex = require('server.runtime_index')(Foundation)
      local contexts = {}
      for number = 1, 2048 do
        local suffix = string.format('%04d', number)
        local group = string.format('group_live_%02d', ((number - 1) % 64) + 1)
        contexts[number] = {
          characterId = 'character_live_' .. suffix,
          memberships = {{
            membershipId = 'membership_live_' .. suffix,
            groupId = group,
            characterId = 'character_live_' .. suffix,
            lifecycleState = 'ACTIVE',
            dutySession = {
              sessionId = 'duty_live_' .. suffix,
              state = 'available',
              countsAsOnDuty = number % 4 == 0,
              version = 1
            }
          }}
        }
      end
      LiveRuntimeIndex = RuntimeIndex({
        maximumCharacters = 4096,
        maximumMemberships = 8192,
        maximumMembershipsPerCharacter = 4
      })
      assert(LiveRuntimeIndex:rebuild(contexts))
      local snapshot = LiveRuntimeIndex:snapshot()
      assert(snapshot.characters == 2048 and snapshot.memberships == 2048)
      assert(snapshot.dutySessions == 2048 and snapshot.onlineGroups == 64)
      assert(snapshot.onDutyGroups == 16)
    `);

    const started = performance.now();
    const evidence = await engine.doString(`
      local originalPairs, enumerations = pairs, 0
      pairs = function(value)
        enumerations = enumerations + 1
        return originalPairs(value)
      end
      local checksum = 0
      for operation = 1, 25000 do
        local number = ((operation - 1) % 2048) + 1
        local suffix = string.format('%04d', number)
        local groupNumber = ((number - 1) % 64) + 1
        local group = string.format('group_live_%02d', groupNumber)
        if LiveRuntimeIndex:isCharacterOnline('character_live_' .. suffix) then
          checksum = checksum + 1
        end
        checksum = checksum + LiveRuntimeIndex:countOnlineMembers(group)
        checksum = checksum + LiveRuntimeIndex:countActiveDutyMembers(group)
        local duty = LiveRuntimeIndex:getActiveDutySession('membership_live_' .. suffix)
        checksum = checksum + (duty and duty.version or 0)
      end
      pairs = originalPairs
      local snapshot = LiveRuntimeIndex:snapshot()
      return {
        checksum = checksum,
        enumerations = enumerations,
        hits = snapshot.hits,
        misses = snapshot.misses
      }
    `) as { checksum: number; enumerations: number; hits: number; misses: number };
    const elapsedMilliseconds = performance.now() - started;

    assert.equal(evidence.enumerations, 0);
    assert.equal(evidence.hits, 81_250);
    assert.equal(evidence.misses, 18_750);
    assert.ok(evidence.checksum > 0);
    // This generous ceiling catches accidental full-index scans or runaway
    // work in the actual Lua path. It is headless evidence, not a FiveM or
    // production latency guarantee.
    assert.ok(elapsedMilliseconds < 5_000, `Lua hot-path exercise took ${elapsedMilliseconds}ms`);
  } finally {
    engine.global.close();
  }
});
