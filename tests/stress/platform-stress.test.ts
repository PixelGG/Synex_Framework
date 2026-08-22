import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';

const root = process.cwd();

test('one thousand virtual sessions leave no stale source, character, or pending indexes', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    for (const relativePath of [
      'core/synex_core/shared/protocol.lua',
      'core/synex_core/server/factories.lua',
      'core/synex_core/server/foundation.lua',
      'core/synex_core/server/registries.lua',
    ]) {
      await engine.doString(await readFile(path.join(root, relativePath), 'utf8'));
    }
    const result = await engine.doString(`
      local now = 1000
      local foundation = SynexCoreFactories.foundation({ platform = {
        nowGame = function() now = now + 1 return now end,
        random = function(_, maximum) return math.min(maximum or 1, 7) end,
        print = function() end,
        jsonEncode = function() return '{}' end
      } })
      local players = SynexCoreFactories.registries({ foundation = foundation }).players
      local generations = {}
      for index = 1, 1000 do
        local sessionId = ('session_%04d'):format(index)
        local userId = ('user_%04d'):format(index)
        local characterId = ('character_%04d'):format(index)
        assert(players:createPending(-index, { sessionId = sessionId, accepted = true }))
        local joined = assert(players:bindJoined(-index, index, {
          id = sessionId, userId = userId, state = 'SELECTING_CHARACTER'
        }))
        generations[index] = joined.sourceGeneration
        assert(players:bindCharacter(sessionId, characterId))
        assert(players:isCurrent(sessionId, index, joined.sourceGeneration))
      end
      local active = players:summary()
      assert(active.activeSessions == 1000 and active.pendingConnections == 0)
      for index = 1000, 1, -1 do
        local sessionId = ('session_%04d'):format(index)
        assert(players:removeSession(sessionId))
        assert(not players:isCurrent(sessionId, index, generations[index]))
      end
      local empty = players:summary()
      assert(empty.activeSessions == 0 and empty.pendingConnections == 0)
      assert(#players:snapshot().sessions == 0)
      assert(players:createPending(-1001, { sessionId = 'session_reused', accepted = true }))
      local reused = assert(players:bindJoined(-1001, 1, {
        id = 'session_reused', userId = 'user_reused', state = 'SELECTING_CHARACTER'
      }))
      assert(reused.sourceGeneration == 3)
      return active.activeSessions
    `);
    assert.equal(result, 1_000);
  } finally {
    engine.global.close();
  }
});

test('one hundred thousand validated ledger commands preserve double-entry properties and idempotent replay', {
  timeout: 60_000,
}, async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await engine.doString('SYNEX_TEST_MODE = true');
    const [foundationSource, serviceSource] = await Promise.all([
      readFile(path.join(root, 'resources/synex_accounts/server/foundation.lua'), 'utf8'),
      readFile(path.join(root, 'resources/synex_accounts/server/service.lua'), 'utf8'),
    ]);
    const result = await engine.doString(`
      package.preload['server.foundation'] = assert(load(${JSON.stringify(foundationSource)}))
      package.preload['server.service'] = assert(load(${JSON.stringify(serviceSource)}))
      local Foundation = require 'server.foundation'
      local createService = require('server.service')(Foundation)
      local function uuid(index)
        return ('00000000-0000-4000-8000-%012d'):format(index)
      end
      local balances = {}
      for index = 1, 64 do balances[uuid(index)] = 1000000 end
      local initialTotal = 64000000
      local postings, debitTotal, creditTotal = 0, 0, 0
      local operations = {}
      local db = {}
      function db:post(command)
        local existing = operations[command.idempotencyKey]
        if existing then
          if existing.fingerprint ~= command.fingerprint then
            return nil, { code = 'IDEMPOTENCY_CONFLICT', message = 'conflict', retryable = false }
          end
          return existing.response, nil
        end
        local sourceBalance = assert(balances[command.sourceAccountId])
        local destinationBalance = assert(balances[command.destinationAccountId])
        if sourceBalance < command.amountMinor then
          return nil, { code = 'INSUFFICIENT_FUNDS', message = 'insufficient', retryable = false }
        end
        balances[command.sourceAccountId] = sourceBalance - command.amountMinor
        balances[command.destinationAccountId] = destinationBalance + command.amountMinor
        postings = postings + 1
        debitTotal = debitTotal + command.amountMinor
        creditTotal = creditTotal + command.amountMinor
        local response = { transaction_id = uuid(200000 + postings), amount_minor = command.amountMinor }
        operations[command.idempotencyKey] = { fingerprint = command.fingerprint, response = response }
        return response, nil
      end
      local service = createService({
        db = db,
        jsonEncode = function(value)
          if type(value) == 'string' then return string.format('%q', value) end
          if type(value) == 'boolean' or type(value) == 'number' then return tostring(value) end
          return '{}'
        end,
        jsonDecode = function() return {} end,
        errorSink = function() end
      })
      local seed = 104729
      local function randomIndex()
        seed = (seed * 48271) % 2147483647
        return (seed % 64) + 1
      end
      local requests = {}
      for index = 1, 100000 do
        local sourceIndex = randomIndex()
        local destinationIndex = randomIndex()
        if destinationIndex == sourceIndex then destinationIndex = (destinationIndex % 64) + 1 end
        local request = {
          idempotency_key = uuid(300000 + index),
          source_account_id = uuid(sourceIndex),
          destination_account_id = uuid(destinationIndex),
          amount_minor = (index % 10) + 1,
          actor_ref = 'resource:synex_stress'
        }
        if index <= 1000 then requests[index] = request end
        local value, err = service.transfer(request)
        assert(value ~= nil and err == nil)
      end
      assert(postings == 100000)
      for index = 1, 1000 do
        local value, err = service.transfer(requests[index])
        assert(value ~= nil and err == nil)
      end
      assert(postings == 100000)
      local conflict = {
        idempotency_key = requests[1].idempotency_key,
        source_account_id = requests[1].source_account_id,
        destination_account_id = requests[1].destination_account_id,
        amount_minor = requests[1].amount_minor + 1,
        actor_ref = requests[1].actor_ref
      }
      local _, conflictError = service.transfer(conflict)
      assert(conflictError.code == 'IDEMPOTENCY_CONFLICT')
      local finalTotal = 0
      for _, balance in pairs(balances) do
        assert(balance >= 0)
        finalTotal = finalTotal + balance
      end
      assert(finalTotal == initialTotal)
      assert(debitTotal == creditTotal)
      return postings
    `);
    assert.equal(result, 100_000);
  } finally {
    engine.global.close();
  }
});
