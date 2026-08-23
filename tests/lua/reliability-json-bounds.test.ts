import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';

const root = process.cwd();

test('reliability payload limits reject oversized aggregates before JSON encoding', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    for (const relativePath of [
      'core/synex_core/server/factories.lua',
      'core/synex_core/server/foundation.lua',
      'core/synex_core/server/reliability.lua',
    ]) {
      await engine.doString(await readFile(path.join(root, relativePath), 'utf8'));
    }
    const result = await engine.doString(`
      local encodeCalls, databaseCalls = 0, 0
      local platform = {
        nowGame = function() return 1000 end, random = function() return 5 end,
        print = function() end,
        jsonEncode = function()
          encodeCalls = encodeCalls + 1
          return '{}'
        end,
        jsonDecode = function() return {} end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('reliability-json-bound')
      local database = {
        update = function() databaseCalls = databaseCalls + 1 return 1, nil end,
        insert = function() databaseCalls = databaseCalls + 1 return 1, nil end,
        query = function() databaseCalls = databaseCalls + 1 return {}, nil end
      }
      local reliability = SynexCoreFactories.reliability({
        foundation = foundation, database = database, platform = platform,
        instanceId = 'instance-a', sha256 = function() return string.rep('a', 64) end,
        features = { durableEvents = true, sagas = true }
      })
      local oversized = {}
      for index = 1, 10 do oversized['field_' .. index] = string.rep('x', 8192) end

      local value, payloadError = reliability.idempotency:run(
        'synex_fixture', 'fixture.write', 'request-12345678', oversized,
        function() error('oversized idempotency input reached its handler') end)
      assert(value == nil and payloadError.code == 'PAYLOAD_TOO_LARGE')
      assert(encodeCalls == 0 and databaseCalls == 0)

      value, payloadError = reliability.outbox:enqueue('synex_fixture', {
        aggregateType = 'fixture.aggregate', aggregateId = 'aggregate-a',
        eventType = 'fixture.aggregate.changed', payload = oversized
      })
      assert(value == nil and payloadError.code == 'PAYLOAD_TOO_LARGE')
      assert(encodeCalls == 0 and databaseCalls == 0)

      value, payloadError = reliability.sagas:start(
        'synex_fixture', 'fixture.workflow', 'correlation-a', oversized)
      assert(value == nil and payloadError.code == 'PAYLOAD_TOO_LARGE')
      assert(encodeCalls == 0 and databaseCalls == 0)

      local created = assert(reliability.sagas:start(
        'synex_fixture', 'fixture.workflow', 'correlation-b', { value = 'small' }))
      assert(created.publicId ~= nil and encodeCalls == 1 and databaseCalls == 1)
      return table.concat({payloadError.code, encodeCalls, databaseCalls}, ':')
    `);
    assert.equal(result, 'PAYLOAD_TOO_LARGE:1:1');
  } finally {
    engine.global.close();
  }
});
