import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';

const root = process.cwd();

test('metrics reject malformed samples and bound global series cardinality', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await engine.doString(await readFile(
      path.join(root, 'core/synex_core/server/factories.lua'), 'utf8'));
    await engine.doString(await readFile(
      path.join(root, 'core/synex_core/server/foundation.lua'), 'utf8'));
    const result = await engine.doString(`
      local platform = {
        nowGame = function() return 1 end,
        random = function() return 1 end,
        print = function() end,
        jsonEncode = function() return '{}' end
      }
      local foundation = SynexCoreFactories.foundation({
        platform = platform,
        maximumMetricSeries = 10
      })
      local metrics = foundation.metrics
      assert(metrics:increment('synex_fixture_total', { result = 'ok' }))
      assert(metrics:observe('synex_fixture_total', { result = 'ok' }, 10))
      assert(metrics:increment('synex_typed_label_total', { value = true }))
      assert(metrics:increment('synex_typed_label_total', { value = 'true' }))
      for index = 1, 7 do
        assert(metrics:gauge('synex_dynamic_value', { topic = 'topic_' .. index }, index))
      end
      assert(metrics:increment('synex_overflow_total', { topic = 'overflow' }) == false)
      assert(metrics:increment('invalid metric', {}, 1) == false)
      assert(metrics:gauge('synex_invalid_value', {}, 0 / 0) == false)
      assert(metrics:observe('synex_invalid_label', { topic = {} }, 1) == false)
      local snapshot = metrics:snapshot()
      assert(snapshot.cardinality.series == 10)
      assert(snapshot.cardinality.maximumSeries == 10)
      assert(snapshot.cardinality.droppedSamples == 1)
      assert(snapshot.cardinality.invalidSamples == 3)
      local fixtureKey = 'synex_fixture_total:6:result=string:2:ok'
      assert(snapshot.values[fixtureKey] == 1)
      assert(snapshot.histograms[fixtureKey].count == 1)
      assert(snapshot.values['synex_typed_label_total:5:value=boolean:4:true'] == 1)
      assert(snapshot.values['synex_typed_label_total:5:value=string:4:true'] == 1)
      return table.concat({
        snapshot.cardinality.series,
        snapshot.cardinality.droppedSamples,
        snapshot.cardinality.invalidSamples
      }, ':')
    `);
    assert.equal(result, '10:1:3');
  } finally {
    engine.global.close();
  }
});

test('structured logging redaction is bounded and hostile tables cannot execute metamethods', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await engine.doString(await readFile(
      path.join(root, 'core/synex_core/server/factories.lua'), 'utf8'));
    await engine.doString(await readFile(
      path.join(root, 'core/synex_core/server/foundation.lua'), 'utf8'));
    const result = await engine.doString(`
      local writes = 0
      local platform = {
        nowGame = function() return 1 end,
        random = function() return 1 end,
        print = function() writes = writes + 1 end,
        jsonEncode = function() return '{}' end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      local cyclic = { password = 'must-not-escape', value = string.rep('x', 5000) }
      cyclic.self = cyclic
      local redacted = foundation.redact(cyclic)
      assert(redacted.password == '[REDACTED]')
      assert(redacted.self == '[CYCLE]')
      assert(#redacted.value < 4200 and redacted.value:sub(-11) == '[TRUNCATED]')

      local hostile = setmetatable({}, {
        __pairs = function() error('hostile pairs') end,
        __tostring = function() error('hostile tostring') end
      })
      assert(foundation.redact(hostile) == '[UNSAFE_TABLE]')
      foundation.logger:write('info', hostile, { payload = hostile })
      assert(writes == 1)
      return true
    `);
    assert.equal(result, true);
  } finally {
    engine.global.close();
  }
});
