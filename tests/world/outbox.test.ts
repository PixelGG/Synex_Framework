import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import { LuaFactory, type LuaEngine } from 'wasmoon';

async function runtime(): Promise<LuaEngine> {
  const engine = await new LuaFactory().createEngine();
  for (const path of [
    'resources/synex_world/shared/limits.lua',
    'resources/synex_world/shared/validation.lua',
    'resources/synex_world/server/outbox.lua',
  ]) {
    await engine.doString(await readFile(path, 'utf8'));
  }
  await engine.doString(String.raw`
    function NewWorldOutboxFixture(options)
      options = options or {}
      local state = {
        id = 1,
        event_id = 'world_000000000000000000000000000001',
        aggregate_id = 'synex_test:alarm',
        event_type = 'synex.world.state.changed',
        schema_version = 1,
        payload_json = options.payload or '{"ok":true}',
        trace_id = 'trace_outbox_0001',
        attempts = options.attempts or 0,
        status = 'pending',
        claim = nil,
        failure = nil,
        delay = nil,
        published = 0,
        calls = {}
      }
      local database = {}
      function database:maintenance(operation, handler)
        state.calls[#state.calls + 1] = operation
        local transaction = {}
        function transaction.affected(sql, parameters)
          if sql:find('OUTBOX_CLAIM_EXPIRED', 1, true) then return 0 end
          if sql:find('attempts', 1, true) and sql:find('+ 1', 1, true) then
            if state.status ~= 'pending' then return 0 end
            state.status, state.claim = 'publishing', parameters[1]
            state.attempts = state.attempts + 1
            return 1
          end
          if operation == 'world.outbox.renew' then
            return options.loseRenew == true and 0 or state.status == 'publishing'
              and state.claim == parameters[3] and 1 or 0
          end
          if operation == 'world.outbox.complete' then
            if state.status ~= 'publishing' or state.claim ~= parameters[2] then return 0 end
            state.status, state.claim, state.published = 'published', nil, state.published + 1
            return 1
          end
          if operation == 'world.outbox.retry' then
            if state.status ~= 'publishing' or state.claim ~= parameters[5] then return 0 end
            state.status, state.delay, state.failure = parameters[1], parameters[2], parameters[3]
            state.claim = nil
            return 1
          end
          error('unexpected outbox SQL')
        end
        function transaction.many()
          if state.status ~= 'publishing' then return {} end
          return {{
            id = state.id, event_id = state.event_id, aggregate_id = state.aggregate_id,
            event_type = state.event_type, schema_version = state.schema_version,
            payload_json = state.payload_json, trace_id = state.trace_id,
            attempts = state.attempts
          }}
        end
        return handler(transaction)
      end
      function database:read()
        return {{ state = state.status, entries = 1, maximum_attempts = state.attempts }}
      end
      local function decode(value)
        if value ~= '{"ok":true}' then error('invalid JSON') end
        return setmetatable({ ok = true }, { __jsontype = 'object' })
      end
      return database, decode, state
    end
  `);
  return engine;
}

test('World outbox publishes a bounded claimed batch with durable metadata', async () => {
  const engine = await runtime();
  try {
    const result = await engine.doString(String.raw`
      local database, decode, state = NewWorldOutboxFixture()
      local published
      local outbox = SynexWorldOutbox.create({
        database = database,
        jsonDecode = decode,
        publish = function(topic, payload, metadata)
          published = { topic = topic, payload = payload, metadata = metadata }
          return { delivered = 1, failed = 0 }, nil
        end
      })
      local report = assert(outbox:dispatchBatch('world_claim_0001', { maximum = 1 }))
      assert(report.delivery == 'at-least-once' and report.claimed == 1
        and report.published == 1 and report.retried == 0 and report.dead == 0)
      assert(state.status == 'published' and state.attempts == 1 and state.published == 1)
      assert(published.topic == 'synex.world.state.changed' and published.payload.ok == true)
      assert(published.metadata.eventId == state.event_id
        and published.metadata.aggregateId == state.aggregate_id
        and published.metadata.traceId == state.trace_id
        and published.metadata.schemaVersion == 1)
      local status = assert(outbox:status())
      assert(status.published == 1 and status.maximumAttempts == 1
        and status.delivery == 'at-least-once')
      return table.concat({ report.claimed, report.published, state.attempts,
        published.metadata.schemaVersion, status.published }, ':')
    `);
    assert.equal(result, '1:1:1:1:1');
  } finally {
    engine.global.close();
  }
});

test('World outbox retries subscriber failure and dead-letters at the bounded attempt limit', async () => {
  const engine = await runtime();
  try {
    const result = await engine.doString(String.raw`
      local database, decode, state = NewWorldOutboxFixture({ attempts = 9 })
      local outbox = SynexWorldOutbox.create({
        database = database,
        jsonDecode = decode,
        publish = function()
          return nil, { code = 'OUTBOX_DELIVERY_FAILED',
            message = 'private subscriber details must not escape' }
        end
      })
      local report = assert(outbox:dispatchBatch('world_claim_0002', { maximum = 1 }))
      assert(report.claimed == 1 and report.dead == 1 and report.retried == 0)
      assert(state.status == 'dead' and state.attempts == 10
        and state.failure == 'OUTBOX_DELIVERY_FAILED')
      assert(report.failures[1].code == 'OUTBOX_DELIVERY_FAILED'
        and report.failures[1].dead == true)
      assert(report.failures[1].message == nil)
      return state.status .. ':' .. state.attempts .. ':' .. state.failure
    `);
    assert.equal(result, 'dead:10:OUTBOX_DELIVERY_FAILED');
  } finally {
    engine.global.close();
  }
});

test('World outbox quarantines invalid payloads and never publishes without a live claim', async () => {
  const engine = await runtime();
  try {
    const result = await engine.doString(String.raw`
      local database, decode, state = NewWorldOutboxFixture({ payload = '{invalid' })
      local calls = 0
      local outbox = SynexWorldOutbox.create({
        database = database, jsonDecode = decode,
        publish = function() calls = calls + 1; return { delivered = 1, failed = 0 } end
      })
      local report = assert(outbox:dispatchBatch('world_claim_0003', { maximum = 1 }))
      assert(calls == 0 and report.retried == 1 and state.status == 'pending'
        and state.failure == 'OUTBOX_INVALID_PAYLOAD' and state.delay >= 2)

      local lostDatabase, lostDecode = NewWorldOutboxFixture({ loseRenew = true })
      local lost = SynexWorldOutbox.create({ database = lostDatabase, jsonDecode = lostDecode,
        publish = function() error('publisher must not run after claim loss') end })
      local value, claimError = lost:dispatchBatch('world_claim_0004', { maximum = 1 })
      assert(value == nil and claimError.code == 'OUTBOX_CLAIM_LOST')
      return report.retried .. ':' .. state.failure .. ':' .. claimError.code
    `);
    assert.equal(result, '1:OUTBOX_INVALID_PAYLOAD:OUTBOX_CLAIM_LOST');
  } finally {
    engine.global.close();
  }
});
