import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';

const repositoryPath = path.join(
  process.cwd(),
  'resources',
  'synex_entities',
  'server',
  'extension_repository.lua',
);

async function runLua<T>(fixture: string): Promise<T> {
  const engine = await new LuaFactory().createEngine();
  try {
    await engine.doString(await readFile(repositoryPath, 'utf8'));
    return await engine.doString(fixture) as T;
  } finally {
    engine.global.close();
  }
}

test('component and state expectedVersion fences execute inside the transaction', async () => {
  const result = await runLua<string>(String.raw`
    local componentVersion, stateVersion = 4, 7
    local updates, requests = {}, {}
    local authority = { instanceId = 'instance_001', resourceEpoch = 4,
      serverScope = 'roleplay-main', token = 'authority_001' }
    local transaction = {}
    function transaction.one(sql)
      if sql:find('synex_entity_authority_leases', 1, true) then
        return { lease_generation = 5 }
      end
      if sql:find('synex_entities', 1, true) then
        return { generation = 1, resource_owner = 'synex_vehicles',
          status = 'active', version = 20 }
      end
      if sql:find('synex_entity_components', 1, true) then
        return { owner_resource = 'synex_vehicles', version = componentVersion }
      end
      if sql:find('synex_entity_states', 1, true) then
        return { owner_resource = 'synex_vehicles', version = stateVersion }
      end
      error('unexpected one query')
    end
    function transaction.update(sql, parameters)
      updates[#updates + 1] = { sql = sql, parameters = parameters }
      return 1
    end
    local database = {
      maintenance = function() error('idempotent mutation used maintenance') end,
      transaction = function(request, handler)
        requests[#requests + 1] = request
        local value, operationError = handler(transaction)
        if not value then error(operationError, 0) end
        return value
      end,
      query = function() return {} end,
    }
    local foundation = {
      failure = function(code, message, retryable, context)
        return nil, { code = code, message = message, retryable = retryable,
          traceId = context and context.traceId }
      end,
      reportUnexpected = function() error('unexpected repository failure') end,
    }
    local repository = SynexEntityExtensionRepository.create({
      database = database, foundation = foundation, health = {},
    })
    local context = { traceId = 'trace_repository_0001',
      idempotencyKey = 'component:set:0001', idempotencyRequest = { version = 4 } }
    local stale, staleError = repository.setComponent('entity_repo_0001', 1,
      'synex_vehicles', { namespace = 'synex_vehicles.runtime', schemaVersion = 1,
        persistenceMode = 'persistent' }, '{}', 3, authority, 5, context)
    assert(stale == nil and staleError.code == 'CONCURRENT_MODIFICATION')
    assert(#updates == 0)
    local stored = assert(repository.setComponent('entity_repo_0001', 1,
      'synex_vehicles', { namespace = 'synex_vehicles.runtime', schemaVersion = 1,
        persistenceMode = 'persistent' }, '{}', 4, authority, 5, context))
    assert(stored.version == 5 and #updates == 1)
    assert(updates[1].parameters[6] == 4)
    assert(requests[2].idempotencyKey == context.idempotencyKey)

    context.idempotencyKey = 'state:set:0000001'
    local staleState, staleStateError = repository.setState('entity_repo_0001', 1,
      'synex_vehicles', { key = 'synex_vehicles:locked', schemaVersion = 1,
        authority = 'server', replication = 'scoped' }, 'true', 6,
      authority, 5, context)
    assert(staleState == nil and staleStateError.code == 'CONCURRENT_MODIFICATION')
    local state = assert(repository.setState('entity_repo_0001', 1,
      'synex_vehicles', { key = 'synex_vehicles:locked', schemaVersion = 1,
        authority = 'server', replication = 'scoped' }, 'true', 7,
      authority, 5, context))
    assert(state.version == 8 and updates[2].parameters[7] == 7)
    return staleStateError.code
  `);
  assert.equal(result, 'CONCURRENT_MODIFICATION');
});

test('component removal fences its DELETE and tag batches serialize on the entity row', async () => {
  const result = await runLua<number>(String.raw`
    local componentVersion, updateCalls = 9, {}
    local authority = { instanceId = 'instance_002', resourceEpoch = 6,
      serverScope = 'roleplay-main', token = 'authority_002' }
    local transaction = {}
    function transaction.one(sql)
      if sql:find('synex_entity_authority_leases', 1, true) then
        return { lease_generation = 8 }
      end
      if sql:find('synex_entities', 1, true) then
        return { generation = 2, resource_owner = 'synex_vehicles',
          status = 'active', version = 3 }
      end
      if sql:find('synex_entity_components', 1, true) then
        return { owner_resource = 'synex_vehicles', version = componentVersion }
      end
      error('unexpected one query')
    end
    function transaction.query(sql)
      assert(not sql:find('COUNT', 1, true))
      assert(sql:find('ORDER BY', 1, true))
      return { { tag = 'synex_vehicles.existing', owner_resource = 'synex_vehicles' } }
    end
    function transaction.update(sql, parameters)
      updateCalls[#updateCalls + 1] = { sql = sql, parameters = parameters }
      return 1
    end
    local database = {
      maintenance = function() error('idempotent mutation used maintenance') end,
      transaction = function(_, handler)
        local value, operationError = handler(transaction)
        if not value then error(operationError, 0) end
        return value
      end,
      query = function() return {} end,
    }
    local foundation = {
      failure = function(code, message, retryable)
        return nil, { code = code, message = message, retryable = retryable }
      end,
      reportUnexpected = function() error('unexpected repository failure') end,
    }
    local repository = SynexEntityExtensionRepository.create({
      database = database, foundation = foundation, health = {},
    })
    local context = { idempotencyKey = 'remove:component:01',
      idempotencyRequest = { expectedVersion = 9 } }
    local stale, staleError = repository.removeComponent('entity_repo_0002', 2,
      'synex_vehicles', 'synex_vehicles.runtime', 8, authority, 8, context)
    assert(stale == nil and staleError.code == 'CONCURRENT_MODIFICATION')
    assert(#updateCalls == 0)
    assert(repository.removeComponent('entity_repo_0002', 2,
      'synex_vehicles', 'synex_vehicles.runtime', 9, authority, 8, context))
    assert(#updateCalls == 1 and updateCalls[1].parameters[4] == 9)

    context.idempotencyKey = 'tags:add:repository'
    local tags = assert(repository.mutateTags('entity_repo_0002', 2,
      'synex_vehicles', { 'synex_vehicles.existing', 'synex_vehicles.new' },
      'add', authority, 8, context))
    assert(tags.changed and #updateCalls == 2)
    assert(updateCalls[2].sql:find('INSERT INTO', 1, true))
    return #updateCalls
  `);
  assert.equal(result, 2);
});

test('repository source has no aggregate FOR UPDATE tag-limit query', async () => {
  const source = await readFile(repositoryPath, 'utf8');
  assert.doesNotMatch(source, /COUNT\(\*\)[\s\S]{0,120}FOR UPDATE/u);
  assert.match(source, /AND `version` = \?/u);
  for (const fence of [
    '`server_scope` = ?',
    '`instance_id` = ?',
    '`authority_token` = ?',
    '`resource_epoch` = ?',
    '`lease_generation` = ?',
    '`lease_until` > CURRENT_TIMESTAMP(6)',
  ]) {
    assert.ok(source.includes(fence), `missing authority fence: ${fence}`);
  }
});

test('every persistent extension mutation rejects an absent exact live lease', async () => {
  const result = await runLua<number>(String.raw`
    local transaction = {}
    function transaction.one(sql)
      if sql:find('synex_entity_authority_leases', 1, true) then return nil end
      if sql:find('synex_entities', 1, true) then
        return { generation = 3, resource_owner = 'synex_vehicles',
          status = 'active', version = 11 }
      end
      error('mutation crossed a rejected authority fence')
    end
    function transaction.query() error('tag read crossed a rejected authority fence') end
    function transaction.update() error('write crossed a rejected authority fence') end
    local database = {
      transaction = function(_, handler)
        local value, operationError = handler(transaction)
        if not value then error(operationError, 0) end
        return value
      end,
      query = function() return {} end,
    }
    local foundation = {
      failure = function(code, message, retryable)
        return nil, { code = code, message = message, retryable = retryable }
      end,
      reportUnexpected = function() error('unexpected repository failure') end,
    }
    local repository = SynexEntityExtensionRepository.create({
      database = database, foundation = foundation, health = {},
    })
    local authority = { instanceId = 'instance_003', resourceEpoch = 9,
      serverScope = 'roleplay-main', token = 'authority_003' }
    local context = { idempotencyKey = 'lease:fence:0001',
      idempotencyRequest = { entityId = 'entity_repo_0003' } }
    local calls = {
      function() return repository.setComponent('entity_repo_0003', 3,
        'synex_vehicles', { namespace = 'synex_vehicles.runtime', schemaVersion = 1,
          persistenceMode = 'persistent' }, '{}', 0, authority, 4, context) end,
      function() return repository.removeComponent('entity_repo_0003', 3,
        'synex_vehicles', 'synex_vehicles.runtime', 1, authority, 4, context) end,
      function() return repository.setState('entity_repo_0003', 3,
        'synex_vehicles', { key = 'synex_vehicles:locked', schemaVersion = 1,
          authority = 'server', replication = 'scoped' }, 'true', 0,
        authority, 4, context) end,
      function() return repository.mutateTags('entity_repo_0003', 3,
        'synex_vehicles', { 'synex_vehicles.managed' }, 'add',
        authority, 4, context) end,
      function() return repository.checkpoint('entity_repo_0003', 3, 11,
        'synex_vehicles', authority, 4, { bucket = 0, heading = 0,
          position = { x = 0, y = 0, z = 0 }, reasonCode = 'synex_vehicles.test' },
        '{}', context) end,
      function() return repository.changeOwner('entity_repo_0003', 3,
        'synex_vehicles', { type = 'resource', id = 'synex_vehicles' }, 11,
        authority, 4, 'synex_vehicles.test', context) end,
    }
    for _, call in ipairs(calls) do
      local value, operationError = call()
      assert(value == nil and operationError.code == 'AUTHORITY_LEASE_CONFLICT')
    end
    return #calls
  `);
  assert.equal(result, 6);
});

test('dormant delete succeeds without a lease but rejects a live foreign lease', async () => {
  const result = await runLua<string>(String.raw`
    local liveForeign = true
    local updates = {}
    local transaction = {}
    function transaction.one(sql)
      if sql:find('synex_entity_authority_leases', 1, true) then
        if not liveForeign then return nil end
        return { server_scope = 'other', instance_id = 'foreign',
          authority_token = 'foreign-token', resource_epoch = 2,
          lease_generation = 7 }
      end
      if sql:find('synex_entities', 1, true) then
        return { generation = 4, resource_owner = 'synex_vehicles',
          status = 'dormant', version = 12 }
      end
      error('unexpected terminal read')
    end
    function transaction.update(sql)
      updates[#updates + 1] = sql
      return 1
    end
    local database = {
      transaction = function(_, handler)
        local value, operationError = handler(transaction)
        if not value then error(operationError, 0) end
        return value
      end,
      query = function() return {} end,
    }
    local foundation = {
      failure = function(code, message, retryable)
        return nil, { code = code, message = message, retryable = retryable }
      end,
      reportUnexpected = function() error('unexpected repository failure') end,
    }
    local repository = SynexEntityExtensionRepository.create({
      database = database, foundation = foundation, health = {},
    })
    local authority = { instanceId = 'instance_004', resourceEpoch = 10,
      serverScope = 'roleplay-main', token = 'authority_004' }
    local context = { idempotencyKey = 'terminal:delete:0001',
      idempotencyRequest = { entityId = 'entity_repo_0004' } }
    local blocked, blockedError = repository.terminate('entity_repo_0004', 4,
      'synex_vehicles', authority, nil, 'synex_vehicles.delete', context)
    assert(blocked == nil and blockedError.code == 'AUTHORITY_LEASE_CONFLICT')
    assert(#updates == 0)
    liveForeign = false
    local deleted = assert(repository.terminate('entity_repo_0004', 4,
      'synex_vehicles', authority, nil, 'synex_vehicles.delete', context))
    assert(deleted.deleted and #updates == 5)
    assert(updates[1]:find('synex_entity_components', 1, true))
    assert(updates[2]:find('synex_entity_states', 1, true))
    assert(updates[3]:find('UPDATE ', 1, true)
      and updates[3]:find('synex_entities', 1, true))
    return blockedError.code
  `);
  assert.equal(result, 'AUTHORITY_LEASE_CONFLICT');
});
