import assert from 'node:assert/strict';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';
import { bootstrapDomain, preload } from './helpers.js';

test('dead outbox events can be retried exactly once and replay by scoped key', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrapDomain(engine);
    await preload(
      engine,
      'server.outbox',
      'resources/synex_accounts/server/outbox.lua',
    );
    const result = await engine.doString(`
      local eventId = '11111111-1111-4111-8111-111111111111'
      local applied = false
      local writes = 0
      local function transaction(handler)
        local committed = handler(function(sql, parameters)
          if sql:find('FROM \`synex_account_outbox_retry_requests\`', 1, true) then
            if not applied then return {} end
            return {{
              public_id = '22222222-2222-4222-8222-222222222222',
              outbox_id = 7,
              state = 'applied',
              requested_by_ref = 'synex_test',
              reason = 'operator reviewed retry',
              event_id = eventId,
            }}
          end
          if sql:find('FROM \`synex_account_outbox\`', 1, true) then
            return {{ id = 7, event_id = eventId, state = 'dead',
              attempts = 10, manual_retry_count = 0 }}
          end
          if sql:find('INSERT INTO \`synex_account_outbox_retry_requests\`', 1, true) then
            writes = writes + 1
            return { affectedRows = 1 }
          end
          if sql:find('UPDATE \`synex_account_outbox\`', 1, true) then
            writes = writes + 1
            return { affectedRows = 1 }
          end
          if sql:find('UPDATE \`synex_account_outbox_retry_requests\`', 1, true) then
            writes = writes + 1
            applied = true
            return { affectedRows = 1 }
          end
          error('unexpected outbox retry query')
        end)
        return committed == true and true or nil
      end
      local dispatcher = require('server.outbox')(Foundation)({
        update = function() return 0 end,
        query = function() return {} end,
        jsonDecode = function() return {} end,
        random = function() return 0 end,
        withTransaction = transaction,
      })
      local command = {
        eventId = eventId,
        idempotencyKey = '33333333-3333-4333-8333-333333333333',
        requestedByResource = 'synex_test',
        requestedByRef = 'synex_test',
        reason = 'operator reviewed retry',
      }
      local first, firstError = dispatcher:requestRetry(command)
      assert(first and not firstError and first.accepted and not first.replayed)
      assert(first.eventId == eventId and writes == 3)
      local replay, replayError = dispatcher:requestRetry(command)
      assert(replay and not replayError and replay.accepted and replay.replayed)
      assert(replay.retryRequestId == '22222222-2222-4222-8222-222222222222')
      assert(writes == 3)
      return tostring(first.accepted) .. ':' .. tostring(replay.replayed) .. ':' .. writes
    `);
    assert.equal(result, 'true:true:3');
  } finally {
    engine.global.close();
  }
});

test('outbox retry rejects payload conflicts and events that are not dead', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrapDomain(engine);
    await preload(
      engine,
      'server.outbox',
      'resources/synex_accounts/server/outbox.lua',
    );
    const result = await engine.doString(`
      local eventId = '11111111-1111-4111-8111-111111111111'
      local mode = 'conflict'
      local function transaction(handler)
        local committed = handler(function(sql)
          if sql:find('FROM \`synex_account_outbox_retry_requests\`', 1, true) then
            if mode == 'conflict' then return {{
              public_id = '22222222-2222-4222-8222-222222222222',
              state = 'applied', requested_by_ref = 'synex_test',
              reason = 'different reason',
              event_id = '44444444-4444-4444-8444-444444444444',
            }} end
            return {}
          end
          if sql:find('FROM \`synex_account_outbox\`', 1, true) then
            return {{ id = 7, event_id = eventId, state = 'published',
              attempts = 1, manual_retry_count = 0 }}
          end
          error('a rejected retry must not write')
        end)
        return committed == true and true or nil
      end
      local dispatcher = require('server.outbox')(Foundation)({
        update = function() return 0 end,
        query = function() return {} end,
        jsonDecode = function() return {} end,
        random = function() return 0 end,
        withTransaction = transaction,
      })
      local command = {
        eventId = eventId,
        idempotencyKey = '33333333-3333-4333-8333-333333333333',
        requestedByResource = 'synex_test', requestedByRef = 'synex_test',
        reason = 'operator reviewed retry',
      }
      local conflicted, conflict = dispatcher:requestRetry(command)
      assert(conflicted == nil and conflict.code == 'OUTBOX_RETRY_IDEMPOTENCY_CONFLICT')
      mode = 'not_dead'
      local rejected, rejection = dispatcher:requestRetry(command)
      assert(rejected == nil and rejection.code == 'OUTBOX_EVENT_NOT_RETRYABLE')
      return conflict.code .. ':' .. rejection.code
    `);
    assert.equal(
      result,
      'OUTBOX_RETRY_IDEMPOTENCY_CONFLICT:OUTBOX_EVENT_NOT_RETRYABLE',
    );
  } finally {
    engine.global.close();
  }
});
