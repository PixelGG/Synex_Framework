import assert from 'node:assert/strict';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';
import { bootstrapDomain, preload } from './helpers.js';

test('transfer_v2 validates and binds optional account sequence expectations', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrapDomain(engine);
    await preload(
      engine,
      'server.service_v2.runtime',
      'resources/synex_accounts/server/service_v2/runtime.lua',
    );
    await preload(
      engine,
      'server.service_v2.transactions_holds',
      'resources/synex_accounts/server/service_v2/transactions_holds.lua',
    );
    const result = await engine.doString(`
      local commands = {}
      local function jsonEncode(value)
        if type(value) == 'string' then
          return '"' .. value:gsub('\\\\', '\\\\\\\\'):gsub('"', '\\\\"') .. '"'
        end
        if type(value) == 'boolean' then return value and 'true' or 'false' end
        if type(value) == 'number' then return tostring(value) end
        error('fixture only encodes canonical primitives')
      end
      local db = {
        postTransaction = function(_, command)
          commands[#commands + 1] = command
          return { transaction_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' }, nil
        end,
        post = function() error('transfer_v2 must use multi-leg posting') end,
      }
      local createRuntime = require('server.service_v2.runtime')(Foundation, Domain)
      local service, runtime = createRuntime({
        db = db,
        jsonEncode = jsonEncode,
        jsonDecode = function() return {} end,
        errorSink = function() end,
        checkResourceCapability = function() return true end,
      })
      require('server.service_v2.transactions_holds')(service, runtime)

      local source = '11111111-1111-4111-8111-111111111111'
      local destination = '22222222-2222-4222-8222-222222222222'
      local function request(sourceSequence, destinationSequence)
        return {
          idempotency_key = '33333333-3333-4333-8333-333333333333',
          source_account_id = source,
          destination_account_id = destination,
          amount_minor = 25,
          reason_code = 'bridge.balance_adjust',
          actor_kind = 'resource',
          actor_ref = 'synex_bridge',
          expected_source_sequence = sourceSequence,
          expected_destination_sequence = destinationSequence,
        }
      end
      local context = {
        caller = 'synex_bridge', callerEpoch = 1, traceId = 'trace_sequence_01',
        idempotencyKey = '33333333-3333-4333-8333-333333333333',
      }

      assert(service.transfer_v2(request(0, 7), context))
      assert(commands[1].expectedSequences[source] == 0)
      assert(commands[1].expectedSequences[destination] == 7)
      local firstFingerprint = commands[1].fingerprint

      assert(service.transfer_v2(request(0, 7), context))
      assert(commands[2].fingerprint == firstFingerprint)
      assert(service.transfer_v2(request(1, 7), context))
      assert(commands[3].fingerprint ~= firstFingerprint)

      local invalid, invalidError = service.transfer_v2(request(-1, 7), context)
      assert(invalid == nil and invalidError.code == 'VALIDATION_FAILED')
      local fractional, fractionalError = service.transfer_v2(request(1.5, 7), context)
      assert(fractional == nil and fractionalError.code == 'VALIDATION_FAILED')

      local ordinary = request(nil, nil)
      assert(service.transfer_v2(ordinary, context))
      assert(commands[4].expectedSequences == nil)

      local legacy, legacyError = service.transfer(request(0, 7), context)
      assert(legacy == nil and legacyError.code == 'VALIDATION_FAILED')
      return table.concat({ #commands, invalidError.code, fractionalError.code,
        legacyError.code }, ':')
    `);
    assert.equal(
      result,
      '4:VALIDATION_FAILED:VALIDATION_FAILED:VALIDATION_FAILED',
    );
  } finally {
    engine.global.close();
  }
});

test('sequence expectations are checked after account locks and before any write', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrapDomain(engine);
    await preload(
      engine,
      'server.persistence.transactions',
      'resources/synex_accounts/server/persistence/transactions.lua',
    );
    const result = await engine.doString(`
      local source = '11111111-1111-4111-8111-111111111111'
      local destination = '22222222-2222-4222-8222-222222222222'
      local lockCalls, writeCalls = 0, 0
      local Engine = {
        loadAccounts = function()
          lockCalls = lockCalls + 1
          return {
            [source] = { sequence_no = 4, currency_status = 'disabled' },
            [destination] = { sequence_no = 9, currency_status = 'disabled' },
          }, nil
        end,
      }
      local port = {}
      require('server.persistence.transactions')(port, {
        foundation = Foundation,
        domain = Domain,
        engine = Engine,
        domainError = Foundation.domainError,
        uuidV4 = Foundation.uuidV4,
        random = function() return 1 end,
        one = function() return nil end,
        many = function() return {} end,
        txRows = function() writeCalls = writeCalls + 1 error('unexpected write') end,
        txOne = function() writeCalls = writeCalls + 1 error('unexpected write') end,
      })
      local entries = {
        { accountId = source, amountMinor = -25, metadataJson = '{}' },
        { accountId = destination, amountMinor = 25, metadataJson = '{}' },
      }
      local command = {}

      local sourceResult, sourceError = Engine:postWithin(function() error('query') end,
        1, command, {
          entries = entries, kind = 'transfer',
          expectedSequences = { [source] = 3, [destination] = 9 },
        })
      assert(sourceResult == nil and sourceError.code == 'WRITE_CONFLICT')
      assert(sourceError.retryable == false and lockCalls == 1 and writeCalls == 0)

      local destinationResult, destinationError = Engine:postWithin(function() error('query') end,
        2, command, {
          entries = entries, kind = 'transfer',
          expectedSequences = { [source] = 4, [destination] = 8 },
        })
      assert(destinationResult == nil and destinationError.code == 'WRITE_CONFLICT')
      assert(lockCalls == 2 and writeCalls == 0)

      local matchedResult, matchedError = Engine:postWithin(function() error('query') end,
        3, command, {
          entries = entries, kind = 'transfer',
          expectedSequences = { [source] = 4, [destination] = 9 },
        })
      assert(matchedResult == nil and matchedError.code == 'CURRENCY_UNAVAILABLE')
      assert(lockCalls == 3 and writeCalls == 0)

      local malformedResult, malformedError = Engine:postWithin(function() error('query') end,
        4, command, {
          entries = entries, kind = 'transfer',
          expectedSequences = { [source] = -1 },
        })
      assert(malformedResult == nil and malformedError.code == 'VALIDATION_FAILED')
      assert(lockCalls == 4 and writeCalls == 0)

      local forwarded
      Engine.mutation = function(_, _, _, handler)
        return handler(function() error('query') end, 5)
      end
      Engine.postWithin = function(_, _, _, _, specification)
        forwarded = specification.expectedSequences
        return { transaction_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' }, nil
      end
      assert(port:postTransaction({
        expectedSequences = { [source] = 4, [destination] = 9 },
        entries = entries, kind = 'transfer',
      }))
      assert(forwarded[source] == 4 and forwarded[destination] == 9)
      return table.concat({ lockCalls, writeCalls, sourceError.code,
        destinationError.code, matchedError.code, malformedError.code }, ':')
    `);
    assert.equal(
      result,
      '4:0:WRITE_CONFLICT:WRITE_CONFLICT:CURRENCY_UNAVAILABLE:VALIDATION_FAILED',
    );
  } finally {
    engine.global.close();
  }
});
