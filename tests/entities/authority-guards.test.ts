import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';

const root = path.join(process.cwd(), 'resources', 'synex_entities');

test('checkpoint debounce is EntityRef-scoped and consumes only committed checkpoints', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await engine.doString(await readFile(
      path.join(root, 'server', 'checkpoint_guard.lua'), 'utf8'));
    const result = await engine.doString(String.raw`
      local now = 1000
      local guard = SynexEntityCheckpointGuard.create({
        debounceMs = 5000, getGameTimer = function() return now end,
        maximumEntries = 2,
      })
      local first = assert(guard.check('entity_0001', 1, { traceId = 'trace_guard_0001' }))
      -- A failed DB write never calls commit, so the immediate retry remains valid.
      local retry = assert(guard.check('entity_0001', 1, { traceId = 'trace_guard_0002' }))
      assert(guard.commit(retry) and guard.size() == 1)
      local blocked, blockedError = guard.check(
        'entity_0001', 1, { traceId = 'trace_guard_0003' })
      assert(blocked == nil and blockedError.code == 'RATE_LIMITED')
      -- A new materialization generation has an independent debounce fence.
      assert(guard.check('entity_0001', 2, { traceId = 'trace_guard_0004' }))
      now = 6000
      assert(guard.check('entity_0001', 1, { traceId = 'trace_guard_0005' }))
      assert(guard.clear('entity_0001', 1) and guard.size() == 0)
      return first.observedAt .. ':' .. blockedError.code
    `) as string;
    assert.equal(result, '1000:RATE_LIMITED');
  } finally {
    engine.global.close();
  }
});

test('non-serial owner epoch fence rejects success after a resource restart and triggers cleanup', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    for (const relative of ['shared/validation.lua', 'server/foundation.lua']) {
      await engine.doString(await readFile(path.join(root, relative), 'utf8'));
    }
    const result = await engine.doString(String.raw`
      local active, cleanupCalls = true, 0
      local foundation = SynexEntityFoundation.create({
        errorSink = function() end,
        health = {},
        limits = { maxEntities = 8, maxOwnerEntities = 8, maxBucketEntities = 8 },
        ports = {
          getGameTimer = function() return 1000 end,
          getResourceState = function() return active and 'started' or 'stopped' end,
        },
        registry = { count = function() return 0 end, forOwner = function() return {} end },
        resourceName = 'synex_entities', state = { buckets = {} },
        validation = SynexEntityValidation,
      })
      foundation.setCleanupOwner(function(owner, cycle)
        assert(owner == 'synex_vehicles' and cycle == 0)
        cleanupCalls = cleanupCalls + 1
      end)
      local value, staleError = foundation.withOwnerEpoch(
        'synex_vehicles', { traceId = 'trace_epoch_0001' }, function()
          local cycle, inflight = foundation.advanceOwnerCycle('synex_vehicles')
          assert(cycle == 0 and inflight == true)
          return 'must_not_escape'
        end)
      assert(value == nil and staleError.code == 'STALE_RESOURCE' and cleanupCalls == 1)
      local outer = assert(foundation.withOwnerEpoch(
        'synex_vehicles', { traceId = 'trace_epoch_0002' }, function()
          return foundation.withOwnerEpoch(
            'synex_vehicles', { traceId = 'trace_epoch_0003' }, function() return 'nested' end)
        end))
      assert(outer == 'nested')
      return staleError.code .. ':' .. cleanupCalls
    `) as string;
    assert.equal(result, 'STALE_RESOURCE:1');
  } finally {
    engine.global.close();
  }
});

test('persistent authority mutations use owner-epoch fencing and checkpoint config is bounded', async () => {
  const [authority, lifecycle, config] = await Promise.all([
    readFile(path.join(root, 'server', 'authority_service.lua'), 'utf8'),
    readFile(path.join(root, 'server', 'authority_lifecycle.lua'), 'utf8'),
    readFile(path.join(root, 'server', 'bootstrap_config.lua'), 'utf8'),
  ]);
  assert.ok((authority.match(/foundation\.withOwnerEpoch\(/gu) ?? []).length >= 4);
  assert.ok((lifecycle.match(/foundation\.withOwnerEpoch\(/gu) ?? []).length >= 2);
  assert.match(config, /synex_entities_checkpoint_debounce_ms/u);
  assert.match(config, /math\.max\(1000, math\.min\(/u);
});
