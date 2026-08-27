import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import { LuaFactory, type LuaEngine } from 'wasmoon';

async function load(engine: LuaEngine, file: string): Promise<void> {
  await engine.doString(await readFile(file, 'utf8'));
}

async function engine(): Promise<LuaEngine> {
  const runtime = await new LuaFactory().createEngine();
  await load(runtime, 'core/synex_core/server/factories.lua');
  await load(runtime, 'core/synex_core/server/foundation.lua');
  await load(runtime, 'core/synex_core/server/registries.lua');
  await load(runtime, 'core/synex_core/server/data_port.lua');
  const fixtureSource = String.raw`
    local clock = 1000
    local function encode(value)
      if value == nil then return 'null' end
      if type(value) == 'boolean' then return value and 'true' or 'false' end
      if type(value) == 'number' then return tostring(value) end
      if type(value) == 'string' then return '"' .. value:gsub('\\', '\\\\'):gsub('"', '\\"') .. '"' end
      if type(value) ~= 'table' then error('unsupported JSON') end
      if #value > 0 then
        local items = {}
        for index = 1, #value do items[index] = encode(value[index]) end
        return '[' .. table.concat(items, ',') .. ']'
      end
      local keys = {}
      for key in pairs(value) do keys[#keys + 1] = key end
      table.sort(keys)
      local properties = {}
      for index, key in ipairs(keys) do properties[index] = encode(key) .. ':' .. encode(value[key]) end
      return '{' .. table.concat(properties, ',') .. '}'
    end
    local function decode(value)
      if value == '{"ok":true}' then return { ok = true } end
      if value == '{"value":"first"}' then return { value = 'first' } end
      if value == '{"effects":[{"id":"effect-1"}],"registryMutations":[{"id":"mutation-1"}],"response":{"value":"first"}}' then
        return {
          effects = {{ id = 'effect-1' }},
          registryMutations = {{ id = 'mutation-1' }},
          response = { value = 'first' }
        }
      end
      if value == '{}' then return {} end
      error('unexpected JSON: ' .. tostring(value))
    end
    FakePlatform = {
      nowGame = function() return clock end,
      random = function() return 1 end,
      print = function() end,
      jsonEncode = encode,
      jsonDecode = decode
    }

    function NewDataPortFixture(options)
      options = options or {}
      clock = 1000
      local foundation = SynexCoreFactories.foundation({ platform = FakePlatform })
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      registries.owners:activate('synex_core')
      local epoch = registries.owners:activate('synex_fixture')
      local state = {
        global = options.global or 0,
        globalLimit = options.globalLimit or 100,
        owner = options.owner or 0,
        ownerLimit = options.ownerLimit or 10,
        ownerInitialized = options.ownerInitialized == true or (options.owner or 0) > 0,
        receipts = {},
        lastReceiptKey = nil,
        record = 'initial',
        lastParameters = nil,
        commits = 0,
        rollbacks = 0
      }
      local queryLog, nextTransactionId, globalLockOwner = {}, 0, nil
      local database = {}
      local function receiptKey(owner, operation, idempotencyKey)
        return owner .. ':' .. operation .. ':' .. idempotencyKey
      end
      local function copyReceipt(receipt)
        return receipt and {
          owner_resource = receipt.owner_resource,
          operation_name = receipt.operation_name,
          idempotency_key = receipt.idempotency_key,
          request_hash = receipt.request_hash,
          state = receipt.state,
          response_json = receipt.response_json,
          expired = receipt.expired
        } or nil
      end
      local function copyState()
        local receipts = {}
        for key, receipt in pairs(state.receipts) do receipts[key] = copyReceipt(receipt) end
        return {
          global = state.global, globalLimit = state.globalLimit,
          owner = state.owner, ownerLimit = state.ownerLimit,
          ownerInitialized = state.ownerInitialized,
          receipts = receipts, lastReceiptKey = state.lastReceiptKey,
          record = state.record,
          lastParameters = state.lastParameters,
          commits = state.commits,
          rollbacks = state.rollbacks
        }
      end
      local function query(sql, values, transactionId)
        if sql:find('FROM §synex_domain_receipt_capacity§', 1, true) then
          queryLog[#queryLog + 1] = 'global_lock'
          if transactionId and globalLockOwner and globalLockOwner ~= transactionId then
            error('global capacity lock contention')
          end
          globalLockOwner = transactionId or globalLockOwner
          return {{
            entry_count = state.global,
            global_limit = state.globalLimit,
            owner_limit = state.ownerLimit
          }}
        end
        if sql:find('INSERT IGNORE INTO §synex_domain_receipt_owner_capacity§', 1, true) then
          queryLog[#queryLog + 1] = 'owner_initialize'
          if state.ownerInitialized then return 0 end
          state.ownerInitialized = true
          return 1
        end
        if sql:find('FROM §synex_domain_receipt_owner_capacity§', 1, true) then
          queryLog[#queryLog + 1] = 'owner_lock'
          if not state.ownerInitialized then return {} end
          return {{ entry_count = state.owner }}
        end
        if sql:find('UPDATE §synex_domain_receipt_capacity§', 1, true) then
          if sql:find('SET §entry_count§ = §entry_count§ - ?', 1, true) then
            if state.global ~= values[2] or state.global < values[1] then return 0 end
            state.global = state.global - values[1]
            return 1
          end
          if state.global ~= values[1] then return 0 end
          state.global = state.global + 1
          return 1
        end
        if sql:find('UPDATE §synex_domain_receipt_owner_capacity§', 1, true) then
          if sql:find('SET §entry_count§ = §entry_count§ - ?', 1, true) then
            if state.owner ~= values[3] or state.owner < values[1] then return 0 end
            state.owner = state.owner - values[1]
            return 1
          end
          if state.owner ~= values[2] then return 0 end
          state.owner = state.owner + 1
          return 1
        end
        if sql:find('FORCE INDEX (§idx_domain_receipts_expiry§)', 1, true) then
          queryLog[#queryLog + 1] = 'compaction_receipt_lock'
          local keys = {}
          for key, receipt in pairs(state.receipts) do
            if receipt.expired then keys[#keys + 1] = key end
          end
          table.sort(keys)
          local rows = {}
          for index = 1, math.min(values[1], #keys) do
            local receipt = state.receipts[keys[index]]
            rows[index] = {
              owner_resource = receipt.owner_resource,
              operation_name = receipt.operation_name,
              idempotency_key = receipt.idempotency_key
            }
          end
          return rows
        end
        if sql:find('INSERT IGNORE INTO', 1, true)
          and sql:find('§synex_domain_operation_receipts§', 1, true) then
          local key = receiptKey(values[1], values[2], values[3])
          queryLog[#queryLog + 1] = 'receipt_claim:' .. key
          if state.receipts[key] then return 0 end
          state.receipts[key] = {
            owner_resource = values[1], operation_name = values[2],
            idempotency_key = values[3], request_hash = values[4],
            state = 'pending', response_json = nil, expired = false
          }
          state.lastReceiptKey = key
          return 1
        end
        if sql:find('DELETE FROM §synex_domain_operation_receipts§', 1, true) then
          local key = receiptKey(values[1], values[2], values[3])
          local receipt = state.receipts[key]
          if not receipt or not receipt.expired then return 0 end
          state.receipts[key] = nil
          return 1
        end
        if sql:find('FROM §synex_domain_operation_receipts§', 1, true) then
          local key = receiptKey(values[1], values[2], values[3])
          queryLog[#queryLog + 1] = 'receipt_lock:' .. key
          local receipt = state.receipts[key]
          return receipt and {{
            request_hash = receipt.request_hash,
            state = receipt.state,
            response_json = receipt.response_json
          }} or {}
        end
        if sql:find('UPDATE §synex_domain_operation_receipts§', 1, true) then
          local key = receiptKey(values[2], values[3], values[4])
          queryLog[#queryLog + 1] = 'receipt_complete:' .. key
          local receipt = state.receipts[key]
          if not receipt or receipt.state ~= 'pending'
            or receipt.request_hash ~= values[5] then return 0 end
          receipt.state = 'completed'
          receipt.response_json = values[1]
          return 1
        end
        if sql:find('SELECT §value§ FROM §synex_fixture_records§', 1, true) then
          return {{ value = state.record }}
        end
        if sql:find('UPDATE §synex_fixture_records§', 1, true) then
          state.record = values[1]
          return 1
        end
        if sql:find('SELECT value FROM synex_fixture_records', 1, true) then
          return {{ value = state.record }}
        end
        if sql:find('WITH RECURSIVE', 1, true) then
          local result = {}
          for index = 1, 257 do result[index] = { id = index } end
          return result
        end
        if sql:find('SELECT LOWER(SHA2(', 1, true) then
          return {{ digest = string.rep('a', 64) }}
        end
        if sql:find('INSERT INTO synex_fixture_records', 1, true) then
          state.record = values[1]
          state.lastParameters = values
          return { affectedRows = 1, insertId = 42 }
        end
        error('unexpected SQL: ' .. sql)
      end
      function database:query(sql, values) return query(sql, values, nil) end
      function database:withTransaction(handler)
        nextTransactionId = nextTransactionId + 1
        local transactionId = nextTransactionId
        local snapshot = copyState()
        local ok, accepted = pcall(handler, function(sql, values)
          return query(sql, values, transactionId)
        end)
        if globalLockOwner == transactionId then globalLockOwner = nil end
        if not ok or accepted ~= true then
          local rollbacks = state.rollbacks + 1
          state = snapshot
          state.rollbacks = rollbacks
          return nil, foundation.error('TRANSACTION_REJECTED', 'rolled back')
        end
        state.commits = state.commits + 1
        return true, nil
      end
      local port = SynexCoreFactories.dataPort({
        platform = FakePlatform,
        foundation = foundation,
        database = database,
        owners = registries.owners,
        sha256 = function(value)
          local digest = {}
          for index = 1, 64 do
            local sourceIndex = ((index - 1) % #value) + 1
            digest[index] = string.format('%x', (string.byte(value, sourceIndex) + index) % 16)
          end
          return table.concat(digest)
        end,
        manifestFor = function(owner)
          if owner == 'synex_fixture' then
            return { dataOwnership = { tables = { 'synex_fixture_records' } } }
          end
        end
      })
      return {
        port = port, owners = registries.owners, epoch = epoch,
        state = function()
          local result = copyState()
          result.receipt = result.lastReceiptKey and result.receipts[result.lastReceiptKey] or nil
          result.receiptCount = 0
          for _ in pairs(result.receipts) do result.receiptCount = result.receiptCount + 1 end
          result.queryLog = queryLog
          return result
        end,
        mark = function(value) queryLog[#queryLog + 1] = value end,
        seedExpired = function(idempotencyKey)
          local key = receiptKey('synex_fixture', 'fixture.expired', idempotencyKey)
          state.receipts[key] = {
            owner_resource = 'synex_fixture', operation_name = 'fixture.expired',
            idempotency_key = idempotencyKey, request_hash = string.rep('e', 64),
            state = 'completed', response_json = '{"ok":true}', expired = true
          }
          state.lastReceiptKey = key
          state.global = state.global + 1
          state.owner = state.owner + 1
          state.ownerInitialized = true
        end,
        advance = function(value) clock = clock + value end
      }
    end
  `;
  await runtime.doString(fixtureSource.replaceAll('§', '`'));
  return runtime;
}

test('Core data port confines SQL to manifest-owned tables and exact bindings', async () => {
  const runtime = await engine();
  try {
    const result = await runtime.doString(String.raw`
      local fixture = NewDataPortFixture()
      local rows = assert(fixture.port:read('synex_fixture', fixture.epoch, {
        sql = 'SELECT §value§ FROM §synex_fixture_records§ WHERE §id§ = ?',
        parameters = {'one'}, maximumRows = 1
      }))
      assert(rows[1].value == 'initial')
      local unowned, unownedError = fixture.port:read('synex_fixture', fixture.epoch, {
        sql = 'SELECT §id§ FROM §synex_users§ WHERE §id§ = ?', parameters = {'one'}
      })
      assert(unowned == nil and unownedError.code == 'DATABASE_TABLE_NOT_OWNED')
      local mismatch, mismatchError = fixture.port:read('synex_fixture', fixture.epoch, {
        sql = 'SELECT §value§ FROM §synex_fixture_records§ WHERE §id§ = ?', parameters = {}
      })
      assert(mismatch == nil and mismatchError.code == 'DATABASE_PARAMETER_MISMATCH')
      local comments, commentsError = fixture.port:read('synex_fixture', fixture.epoch, {
        sql = 'SELECT §value§ FROM §synex_fixture_records§ -- unsafe', parameters = {}
      })
      assert(comments == nil and commentsError.code == 'INVALID_DATABASE_STATEMENT')
      return table.concat({rows[1].value, unownedError.code, mismatchError.code, commentsError.code}, ':')
    `.replaceAll('§', '`'));
    assert.equal(result,
      'initial:DATABASE_TABLE_NOT_OWNED:DATABASE_PARAMETER_MISMATCH:INVALID_DATABASE_STATEMENT');
  } finally {
    runtime.global.close();
  }
});

test('Core data port commits domain writes with their receipt and replays atomically', async () => {
  const runtime = await engine();
  try {
    const result = await runtime.doString(String.raw`
      local fixture = NewDataPortFixture()
      local calls = 0
      local request = {
        operation = 'fixture.update', idempotencyKey = 'fixture-key-0001',
        request = { value = 'first' }, timeoutMs = 1000
      }
      local first, _, firstMeta = fixture.port:transaction(
        'synex_fixture', fixture.epoch, request, function(tx)
          calls = calls + 1
          local changed = assert(tx:update(
            'UPDATE §synex_fixture_records§ SET §value§ = ? WHERE §id§ = ?',
            {'first', 'one'}))
          assert(changed == 1)
          return {
            response = { value = 'first' },
            effects = {{ id = 'effect-1' }},
            registryMutations = {{ id = 'mutation-1' }}
          }, nil
        end)
      assert(first.response.value == 'first' and first.effects[1].id == 'effect-1'
        and first.registryMutations[1].id == 'mutation-1' and firstMeta.replayed == false)
      local replay, _, replayMeta = fixture.port:transaction(
        'synex_fixture', fixture.epoch, request, function()
          calls = calls + 1
          error('replay must not execute')
        end)
      local conflict, conflictError = fixture.port:transaction(
        'synex_fixture', fixture.epoch, {
          operation = request.operation, idempotencyKey = request.idempotencyKey,
          request = { value = 'different' }, timeoutMs = 1000
        }, function()
          calls = calls + 1
          error('conflicting replay must not execute')
        end)
      local state = fixture.state()
      assert(replay.response.value == 'first' and replay.effects[1].id == 'effect-1'
        and replay.registryMutations[1].id == 'mutation-1' and replayMeta.replayed == true)
      assert(conflict == nil and conflictError.code == 'IDEMPOTENCY_CONFLICT')
      assert(calls == 1 and state.record == 'first' and state.global == 1 and state.owner == 1)
      assert(state.receipt.state == 'completed' and state.commits == 2 and state.rollbacks == 1)
      return table.concat({calls, state.record, state.global, state.owner,
        state.receipt.state, conflictError.code}, ':')
    `.replaceAll('§', '`'));
    assert.equal(result, '1:first:1:1:completed:IDEMPOTENCY_CONFLICT');
  } finally {
    runtime.global.close();
  }
});

test('Core data port holds only per-key claims while different handlers execute', async () => {
  const runtime = await engine();
  try {
    const result = await runtime.doString(String.raw`
      local fixture = NewDataPortFixture()
      local outer = assert(fixture.port:transaction('synex_fixture', fixture.epoch, {
        operation = 'fixture.parallel', idempotencyKey = 'fixture-parallel-a', request = { id = 'a' }
      }, function()
        fixture.mark('handler:a:start')
        local inner = assert(fixture.port:transaction('synex_fixture', fixture.epoch, {
          operation = 'fixture.parallel', idempotencyKey = 'fixture-parallel-b', request = { id = 'b' }
        }, function()
          fixture.mark('handler:b')
          return { ok = true }, nil
        end))
        assert(inner.ok == true)
        fixture.mark('handler:a:end')
        return { ok = true }, nil
      end))
      assert(outer.ok == true)
      local state = fixture.state()
      local positions = {}
      for index, value in ipairs(state.queryLog) do
        if value == 'handler:a:start' or value == 'handler:b' or value == 'handler:a:end'
          or value == 'global_lock' and positions.firstGlobal == nil then
          positions[value] = positions[value] or index
          if value == 'global_lock' then positions.firstGlobal = index end
        end
        if value == 'global_lock' then positions.lastGlobal = index end
      end
      assert(positions['handler:a:start'] < positions['handler:b'])
      assert(positions['handler:b'] < positions.firstGlobal)
      assert(positions.firstGlobal < positions['handler:a:end'])
      assert(positions['handler:a:end'] < positions.lastGlobal)
      assert(state.global == 2 and state.owner == 2 and state.receiptCount == 2)
      return table.concat({state.global, state.owner, state.receiptCount,
        positions['handler:a:start'], positions['handler:b'], positions.firstGlobal}, ':')
    `);
    assert.match(result, /^2:2:2:\d+:\d+:\d+$/u);
  } finally {
    runtime.global.close();
  }
});

test('Core data port compaction follows receipt, global, owner lock order', async () => {
  const runtime = await engine();
  try {
    const result = await runtime.doString(String.raw`
      local fixture = NewDataPortFixture()
      fixture.seedExpired('fixture-expired-0001')
      fixture.seedExpired('fixture-expired-0002')
      local first, firstError = fixture.port:compactExpired(1)
      assert(first, firstError and (firstError.code .. ':' .. firstError.message))
      local firstState = fixture.state()
      assert(first.removed == 1 and first.owners == 1)
      assert(firstState.global == 1 and firstState.owner == 1 and firstState.receiptCount == 1)
      local receiptLockAt, globalLockAt, ownerLockAt
      for index, value in ipairs(firstState.queryLog) do
        if value == 'compaction_receipt_lock' and not receiptLockAt then receiptLockAt = index end
        if value == 'global_lock' and not globalLockAt then globalLockAt = index end
        if value == 'owner_lock' and not ownerLockAt then ownerLockAt = index end
      end
      assert(receiptLockAt < globalLockAt and globalLockAt < ownerLockAt)
      local second, secondError = fixture.port:compactExpired(2)
      assert(second, secondError and (secondError.code .. ':' .. secondError.message))
      local finalState = fixture.state()
      assert(second.removed == 1 and second.owners == 1)
      assert(finalState.global == 0 and finalState.owner == 0 and finalState.receiptCount == 0)
      return table.concat({first.removed, second.removed, finalState.global,
        finalState.owner, receiptLockAt, globalLockAt, ownerLockAt}, ':')
    `);
    assert.match(result, /^1:1:0:0:\d+:\d+:\d+$/u);
  } finally {
    runtime.global.close();
  }
});

test('Core data port reserves capacity after the handler and rolls back exhausted work', async () => {
  const runtime = await engine();
  try {
    const result = await runtime.doString(String.raw`
      local fixture = NewDataPortFixture({ globalLimit = 1, ownerLimit = 1 })
      assert(fixture.port:transaction('synex_fixture', fixture.epoch, {
        operation = 'fixture.capacity', idempotencyKey = 'fixture-capacity-a', request = { id = 'a' }
      }, function(tx)
        assert(tx:update('UPDATE §synex_fixture_records§ SET §value§ = ? WHERE §id§ = ?',
          {'admitted', 'one'}))
        return { ok = true }, nil
      end))
      local rejected, rejection = fixture.port:transaction('synex_fixture', fixture.epoch, {
        operation = 'fixture.capacity', idempotencyKey = 'fixture-capacity-b', request = { id = 'b' }
      }, function(tx)
        fixture.mark('capacity:handler')
        assert(tx:update('UPDATE §synex_fixture_records§ SET §value§ = ? WHERE §id§ = ?',
          {'must-rollback', 'one'}))
        return { ok = true }, nil
      end)
      local state = fixture.state()
      assert(rejected == nil and rejection.code == 'IDEMPOTENCY_CAPACITY_EXCEEDED')
      assert(rejection.details.scope == 'global')
      assert(state.record == 'admitted' and state.global == 1 and state.owner == 1)
      assert(state.receiptCount == 1 and state.rollbacks == 1)
      local handlerAt, finalGlobalAt
      for index, value in ipairs(state.queryLog) do
        if value == 'capacity:handler' then handlerAt = index end
        if value == 'global_lock' then finalGlobalAt = index end
      end
      assert(handlerAt and finalGlobalAt and handlerAt < finalGlobalAt)
      local ownerFixture = NewDataPortFixture({ globalLimit = 2, ownerLimit = 1 })
      assert(ownerFixture.port:transaction('synex_fixture', ownerFixture.epoch, {
        operation = 'fixture.owner_capacity', idempotencyKey = 'fixture-owner-capacity-a',
        request = { id = 'a' }
      }, function() return { ok = true }, nil end))
      local ownerRejected, ownerRejection = ownerFixture.port:transaction(
        'synex_fixture', ownerFixture.epoch, {
          operation = 'fixture.owner_capacity', idempotencyKey = 'fixture-owner-capacity-b',
          request = { id = 'b' }
        }, function()
          ownerFixture.mark('owner-capacity:handler')
          return { ok = true }, nil
        end)
      local ownerState = ownerFixture.state()
      assert(ownerRejected == nil and ownerRejection.code == 'IDEMPOTENCY_CAPACITY_EXCEEDED')
      assert(ownerRejection.details.scope == 'owner' and ownerState.global == 1
        and ownerState.owner == 1 and ownerState.receiptCount == 1)
      return table.concat({rejection.code, rejection.details.scope, state.record,
        state.global, state.owner, state.receiptCount, ownerRejection.details.scope}, ':')
    `.replaceAll('§', '`'));
    assert.equal(result, 'IDEMPOTENCY_CAPACITY_EXCEEDED:global:admitted:1:1:1:owner');
  } finally {
    runtime.global.close();
  }
});

test('Core data port rolls back if owner epoch or deadline changes before commit', async () => {
  const runtime = await engine();
  try {
    const result = await runtime.doString(String.raw`
      local ownerFixture = NewDataPortFixture()
      local value, ownerError = ownerFixture.port:transaction('synex_fixture', ownerFixture.epoch, {
        operation = 'fixture.owner_restart', idempotencyKey = 'fixture-key-0002', request = {}
      }, function(tx)
        assert(tx:update('UPDATE §synex_fixture_records§ SET §value§ = ? WHERE §id§ = ?',
          {'unsafe', 'one'}))
        ownerFixture.owners:purge('synex_fixture', ownerFixture.epoch, 'restart')
        return { ok = true }, nil
      end)
      local ownerState = ownerFixture.state()
      assert(value == nil and ownerError.code == 'STALE_RESOURCE')
      assert(ownerState.record == 'initial' and ownerState.receipt == nil and ownerState.global == 0)

      local deadlineFixture = NewDataPortFixture()
      local expired, deadlineError = deadlineFixture.port:transaction(
        'synex_fixture', deadlineFixture.epoch, {
          operation = 'fixture.deadline', idempotencyKey = 'fixture-key-0003',
          request = {}, timeoutMs = 100
        }, function(tx)
          assert(tx:update('UPDATE §synex_fixture_records§ SET §value§ = ? WHERE §id§ = ?',
            {'unsafe', 'one'}))
          deadlineFixture.advance(101)
          return { ok = true }, nil
        end)
      local deadlineState = deadlineFixture.state()
      assert(expired == nil and deadlineError.code == 'DATABASE_DEADLINE_EXCEEDED')
      assert(deadlineState.record == 'initial' and deadlineState.receipt == nil
        and deadlineState.rollbacks == 1)
      return ownerError.code .. ':' .. deadlineError.code
    `.replaceAll('§', '`'));
    assert.equal(result, 'STALE_RESOURCE:DATABASE_DEADLINE_EXCEEDED');
  } finally {
    runtime.global.close();
  }
});

test('Core data port supports Groups SQL forms, nullable bindings, and bounded sentinels', async () => {
  const runtime = await engine();
  try {
    const result = await runtime.doString(String.raw`
      local fixture = NewDataPortFixture()
      local scalar = assert(fixture.port:read('synex_fixture', fixture.epoch, {
        sql = 'SELECT LOWER(SHA2(?, 256)) AS digest', parameters = {'request'}
      }))
      assert(#scalar == 1 and #scalar[1].digest == 64)
      local recursive, recursiveError = fixture.port:read('synex_fixture', fixture.epoch, {
        sql = [[WITH RECURSIVE tree AS (
          SELECT id FROM synex_fixture_records WHERE parent_id = ?
          UNION ALL
          SELECT child.id FROM synex_fixture_records AS child
          INNER JOIN tree ON tree.id = child.parent_id
        ) SELECT id FROM tree]],
        parameters = {1}, maximumRows = 257, maximumResultBytes = 1048576
      })
      assert(recursive, recursiveError and recursiveError.code)
      assert(#recursive == 257)
      local inserted = assert(fixture.port:write('synex_fixture', fixture.epoch, {
        sql = [[INSERT INTO synex_fixture_records (value, optional_value, tail_value)
          VALUES (?, ?, ?)]],
        parameters = {'nullable', fixture.port:null(), 'tail'}
      }))
      local state = fixture.state()
      assert(inserted.kind == 'insert' and inserted.affectedRows == 1 and inserted.insertId == 42)
      assert(state.lastParameters[0] == false and state.lastParameters[1] == 'nullable'
        and state.lastParameters[2] == nil and state.lastParameters[3] == 'tail')
      local trailing = assert(fixture.port:write('synex_fixture', fixture.epoch, {
        sql = [[INSERT INTO synex_fixture_records (value, optional_value) VALUES (?, ?)]],
        parameters = {'trailing', fixture.port:null()}
      }))
      state = fixture.state()
      assert(trailing.insertId == 42 and state.lastParameters[0] == false
        and state.lastParameters[1] == 'trailing' and state.lastParameters[2] == nil)
      local unowned, ownershipError = fixture.port:read('synex_fixture', fixture.epoch, {
        sql = 'SELECT id FROM synex_users', parameters = {}
      })
      assert(unowned == nil and ownershipError.code == 'DATABASE_TABLE_NOT_OWNED')
      local hidden, hiddenError = fixture.port:read('synex_fixture', fixture.epoch, {
        sql = [[WITH hidden AS (SELECT id FROM synex_users) SELECT id FROM hidden]],
        parameters = {}
      })
      assert(hidden == nil and hiddenError.code == 'DATABASE_TABLE_NOT_OWNED')
      local collision, collisionError = fixture.port:read('synex_fixture', fixture.epoch, {
        sql = [[WITH synex_users AS (SELECT id FROM synex_users)
          SELECT id FROM synex_users]], parameters = {}
      })
      assert(collision == nil and collisionError.code == 'DATABASE_TABLE_NOT_OWNED')
      local qualified, qualifiedError = fixture.port:read('synex_fixture', fixture.epoch, {
        sql = 'SELECT id FROM other.synex_fixture_records', parameters = {}
      })
      assert(qualified == nil and qualifiedError.code == 'DATABASE_TABLE_REFERENCE_INVALID')
      local comma, commaError = fixture.port:read('synex_fixture', fixture.epoch, {
        sql = 'SELECT a.id FROM synex_fixture_records a, synex_users b', parameters = {}
      })
      assert(comma == nil and commaError.code == 'DATABASE_TABLE_REFERENCE_INVALID')
      local sleep, sleepError = fixture.port:read('synex_fixture', fixture.epoch, {
        sql = 'SELECT SLEEP(?)', parameters = {1}
      })
      assert(sleep == nil and sleepError.code == 'DATABASE_STATEMENT_FORBIDDEN')
      local udf, udfError = fixture.port:read('synex_fixture', fixture.epoch, {
        sql = 'SELECT arbitrary_udf(?) AS value', parameters = {'unsafe'}
      })
      assert(udf == nil and udfError.code == 'DATABASE_STATEMENT_FORBIDDEN')
      return table.concat({#recursive, inserted.insertId, trailing.insertId,
        ownershipError.code, hiddenError.code, collisionError.code, qualifiedError.code,
        commaError.code, sleepError.code, udfError.code}, ':')
    `);
    assert.equal(result, [
      '257', '42', '42', 'DATABASE_TABLE_NOT_OWNED', 'DATABASE_TABLE_NOT_OWNED',
      'DATABASE_TABLE_NOT_OWNED', 'DATABASE_TABLE_REFERENCE_INVALID',
      'DATABASE_TABLE_REFERENCE_INVALID', 'DATABASE_STATEMENT_FORBIDDEN',
      'DATABASE_STATEMENT_FORBIDDEN',
    ].join(':'));
  } finally {
    runtime.global.close();
  }
});

test('Core maintenance transactions are non-idempotent, adapter-shaped, and statement bounded', async () => {
  const runtime = await engine();
  try {
    const result = await runtime.doString(String.raw`
      local fixture = NewDataPortFixture()
      local calls = 0
      local function run(value)
        return fixture.port:maintenance('synex_fixture', fixture.epoch, {
          operation = 'fixture.worker_claim', maximumRows = 257,
          maximumStatements = 2, timeoutMs = 1000
        }, function(tx)
          calls = calls + 1
          local id, insertError = tx:insert(
            'INSERT INTO synex_fixture_records (value, optional_value) VALUES (?, ?)',
            {value, fixture.port:null()})
          assert(id, insertError and insertError.code)
          local row = assert(tx:one(
            'SELECT value FROM synex_fixture_records WHERE id = ?', {id}))
          return { id = id, value = row.value }, nil
        end)
      end
      local first = assert(run('worker-one'))
      local second = assert(run('worker-two'))
      assert(calls == 2 and first.id == 42 and second.value == 'worker-two')
      local limited, limitError = fixture.port:maintenance('synex_fixture', fixture.epoch, {
        operation = 'fixture.worker_limit', maximumStatements = 1
      }, function(tx)
        assert(tx:one('SELECT value FROM synex_fixture_records WHERE id = ?', {42}))
        local _, statementError = tx:one(
          'SELECT value FROM synex_fixture_records WHERE id = ?', {42})
        return nil, statementError
      end)
      assert(limited == nil and limitError.code == 'DATABASE_STATEMENT_LIMIT')
      return table.concat({calls, first.id, second.value, limitError.code}, ':')
    `);
    assert.equal(result, '2:42:worker-two:DATABASE_STATEMENT_LIMIT');
  } finally {
    runtime.global.close();
  }
});
