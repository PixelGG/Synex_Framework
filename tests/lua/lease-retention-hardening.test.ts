import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';

const root = process.cwd();

async function createPersistenceEngine() {
  const engine = await new LuaFactory().createEngine();
  for (const relativePath of [
    'core/synex_core/server/factories.lua',
    'core/synex_core/server/foundation.lua',
    'core/synex_core/server/persistence.lua',
  ]) {
    await engine.doString(await readFile(path.join(root, relativePath), 'utf8'));
  }
  return engine;
}

test('terminal lease compaction scans only the indexed durable eligibility queue', async () => {
  const engine = await createPersistenceEngine();
  try {
    const result = await engine.doString(`
      local selectSql, selectParameters, deleteSql
      local platform = {
        nowGame = function() return 1000 end,
        random = function() return 1 end,
        wait = function() end,
        print = function() end,
        jsonEncode = function() return '{}' end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      local persistence = SynexCoreFactories.persistence({
        platform = platform,
        foundation = foundation,
        instanceId = 'instance-a',
        db = {
          query = function() return {} end,
          scalar = function() return nil end,
          insert = function() return 0 end,
          update = function() return 0 end,
          transaction = function() return true end,
          startTransaction = function(handler)
            return handler(function(sql, parameters)
              if sql:find('SELECT', 1, true) and sql:find('synex_cluster_leases', 1, true) then
                selectSql, selectParameters = sql, parameters
                return {
                  { lease_name = 'saga:fixture', lease_capacity_kind = 'saga' },
                  { lease_name = 'character-delete:fixture', lease_capacity_kind = 'character' }
                }
              end
              if sql:find('FROM', 1, true) and sql:find('synex_cluster_lease_capacity', 1, true) then
                return {{ entry_count = 2, global_limit = 100 }}
              end
              if sql:find('FROM', 1, true)
                  and sql:find('synex_cluster_lease_kind_capacity', 1, true) then
                return {{ lease_capacity_kind = parameters[1], entry_count = 1, kind_limit = 100 }}
              end
              if sql:find('DELETE FROM', 1, true) then
                deleteSql = sql
                return { affectedRows = 2 }
              end
              if sql:find('UPDATE', 1, true) then return { affectedRows = 1 } end
              error('unexpected compaction fixture SQL')
            end)
          end
        }
      })

      local invalid, invalidError = persistence.leases:compactTerminal(1001)
      assert(invalid == nil and invalidError.code == 'INVALID_ARGUMENT')
      local report = assert(persistence.leases:compactTerminal(73))
      assert(report.deleted == 2 and report.maximum == 73)
      assert(selectParameters[1] == 73 and #selectParameters == 1)
      assert(deleteSql:find('DELETE FROM ' .. string.char(96) .. 'synex_cluster_leases', 1, true))
      assert(selectSql:find('LIMIT ?', 1, true))
      assert(selectSql:find('terminal_compaction_at', 1, true)
        and selectSql:find('idx_cluster_leases_terminal_compaction', 1, true)
        and selectSql:find('FORCE INDEX', 1, true))
      assert(selectSql:find('ORDER BY', 1, true)
        and selectSql:find('lease_name', 1, true)
        and selectSql:find('CURRENT_TIMESTAMP(6)', 1, true))
      assert(not selectSql:find('synex_sagas', 1, true))
      assert(not selectSql:find('synex_character_deletion_plans', 1, true))
      assert(not selectSql:find('lease_domain_kind', 1, true))
      assert(not selectSql:find('idx_cluster_leases_domain_expiry', 1, true))
      assert(not selectSql:find('UNION ALL', 1, true))
      assert(not selectSql:find('JOIN', 1, true))
      assert(not selectSql:find('expires_at', 1, true))
      assert(not selectSql:find("'session:'", 1, true))
      assert(selectSql:find("'schema_migrations'", 1, true))
      return report.deleted
    `);
    assert.equal(result, 2);
  } finally {
    engine.global.close();
  }
});

test('released session and admission leases retire exactly and reacquire clears eligibility', async () => {
  const engine = await createPersistenceEngine();
  try {
    const result = await engine.doString(`
      local updates, acquireSql, acquireParameters, unexpectedSql = {}, nil, nil, nil
      local releaseAffected = 1
      local leaseRows = {
        ['session:user-a:session-a'] = {
          owner_id = 'instance-a:session-a', fencing_token = 7,
          valid = 1, lease_capacity_kind = 'session'
        },
        ['admission:user-a'] = {
          owner_id = 'instance-a:session-a', fencing_token = 8,
          valid = 1, lease_capacity_kind = 'admission'
        }
      }
      local platform = {
        nowGame = function() return 1000 end, random = function() return 3 end,
        wait = function() end, print = function() end,
        jsonEncode = function() return '{}' end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      local persistence = SynexCoreFactories.persistence({
        platform = platform, foundation = foundation, instanceId = 'instance-a',
        db = {
          query = function() return {} end, scalar = function() return nil end,
          insert = function() return 0 end, transaction = function() return true end,
          update = function(sql, parameters)
            updates[#updates + 1] = { sql = sql, parameters = parameters }
            return releaseAffected
          end,
          startTransaction = function(handler)
            return handler(function(sql, parameters)
              if sql:find('SELECT', 1, true) and sql:find('synex_cluster_leases', 1, true) then
                local row = leaseRows[parameters[1]]
                return row and {{ owner_id = row.owner_id, fencing_token = row.fencing_token,
                  valid = row.valid, lease_capacity_kind = row.lease_capacity_kind }} or {}
              end
              if sql:find('synex_instances', 1, true) then return {{ status = 'ready' }} end
              if sql:find('synex_instance_boots', 1, true) then return {{ boot_id = 'boot-a' }} end
              if sql:find('UPDATE', 1, true) and sql:find('synex_cluster_leases', 1, true) then
                acquireSql, acquireParameters = sql, parameters
                local row = leaseRows[parameters[5]]
                if not row then return { affectedRows = 0 } end
                row.owner_id, row.fencing_token, row.valid =
                  parameters[3], row.fencing_token + 1, 1
                return { affectedRows = 1 }
              end
              unexpectedSql = sql
              error('unexpected fixture SQL')
            end)
          end
        }
      })
      local session = { name = 'session:user-a:session-a', owner = 'instance-a:session-a',
        fencingToken = 7 }
      local gate = { name = 'admission:user-a', owner = 'instance-a:session-a', fencingToken = 8 }
      for index = 1, 10 do
        assert(persistence.leases:release({
          name = 'session:user-a:session-' .. index,
          owner = 'instance-a:session-' .. index,
          fencingToken = index
        }))
      end
      assert(#updates == 10)
      for index, update in ipairs(updates) do
        assert(update.sql:find('terminal_compaction_at', 1, true)
          and update.parameters[1] == 'session:user-a:session-' .. index)
      end
      assert(persistence.leases:release(gate))
      assert(updates[11].sql:find('terminal_compaction_at', 1, true))

      releaseAffected = 0
      local stale, staleError = persistence.leases:release({
        name = gate.name, owner = 'instance-a:stale', fencingToken = 7
      })
      assert(stale == nil and staleError.code == 'LEASE_LOST')

      local acquired, acquireError = persistence.leases:acquire(
        session.name, session.owner, 45, 'instance-a', 'boot-a')
      assert(acquired, (acquireError and acquireError.code or 'unknown')
        .. ':' .. tostring(unexpectedSql))
      assert(acquired.fencingToken == 8)
      assert(acquireSql:find('terminal_compaction_at', 1, true)
        and acquireSql:find('NULL', 1, true))
      assert(acquireParameters[1] == 1 and acquireParameters[2] == 0
        and acquireParameters[5] == session.name)
      local sessionAcquireSql = acquireSql
      local reacquiredGate = assert(persistence.leases:acquire(
        gate.name, gate.owner, 45, 'instance-a', 'boot-a'))
      assert(reacquiredGate.fencingToken == 9)
      assert(acquireParameters[1] == 0 and acquireParameters[2] == 1
        and acquireParameters[5] == gate.name)

      local generic = { name = 'schema_migrations', owner = 'instance-a:migration', fencingToken = 1 }
      releaseAffected = 1
      assert(persistence.leases:release(generic))
      assert(not updates[#updates].sql:find('terminal_compaction_at', 1, true))
      return table.concat({#updates, staleError.code,
        tostring(sessionAcquireSql:find('terminal_compaction_at', 1, true) ~= nil)}, ':')
    `);
    assert.equal(result, '13:LEASE_LOST:true');
  } finally {
    engine.global.close();
  }
});

test('expired authority retirement is indexed, bounded, exact, and fair after failures', async () => {
  const engine = await createPersistenceEngine();
  try {
    const result = await engine.doString(`
      local selectedKinds, statements = {}, {}
      local failUpdate = false
      local platform = { nowGame = function() return 1000 end, random = function() return 5 end,
        wait = function() end, print = function() end, jsonEncode = function() return '{}' end }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      local persistence = SynexCoreFactories.persistence({
        platform = platform, foundation = foundation, instanceId = 'instance-a',
        db = {
          query = function() return {} end, scalar = function() return nil end,
          insert = function() return 0 end, update = function() return 0 end,
          transaction = function() return true end,
          startTransaction = function(handler)
            return handler(function(sql, parameters)
              statements[#statements + 1] = { sql = sql, parameters = parameters }
              if sql:find('SELECT', 1, true) then
                local kind = parameters[1]
                selectedKinds[#selectedKinds + 1] = kind
                return {{ lease_name = kind .. ':user-a' }}
              end
              if sql:find('UPDATE', 1, true) then
                return { affectedRows = failUpdate and 0 or 1 }
              end
              error('unexpected retirement SQL')
            end)
          end
        }
      })
      local invalid, invalidError = persistence.leases:retireExpiredAuthority(1001)
      assert(invalid == nil and invalidError.code == 'INVALID_ARGUMENT')
      local first = assert(persistence.leases:retireExpiredAuthority(1))
      assert(first.kind == 'session' and first.selected == 1 and first.retired == 1)
      failUpdate = true
      local failed, failure = persistence.leases:retireExpiredAuthority(1)
      assert(failed == nil and failure.code == 'DATABASE_RESULT_INVALID')
      failUpdate = false
      local retried = assert(persistence.leases:retireExpiredAuthority(1))
      assert(retried.kind == 'admission' and retried.retired == 1)
      assert(table.concat(selectedKinds, ',') == 'session,admission,admission')
      local selectSql, updateSql = statements[1].sql, statements[2].sql
      assert(selectSql:find('FORCE INDEX (' .. string.char(96)
        .. 'idx_cluster_leases_authority_expiry' .. string.char(96) .. ')', 1, true))
      assert(selectSql:find('lease_authority_kind', 1, true)
        and selectSql:find('terminal_compaction_at', 1, true)
        and selectSql:find('expires_at', 1, true)
        and selectSql:find('ORDER BY', 1, true)
        and selectSql:find('LIMIT ? FOR UPDATE', 1, true))
      assert(updateSql:find('owner_id', 1, true)
        and updateSql:find("'retired'", 1, true)
        and updateSql:find('fencing_token', 1, true)
        and updateSql:find('lease_authority_kind', 1, true)
        and updateSql:find('terminal_compaction_at', 1, true)
        and updateSql:find('expires_at', 1, true)
        and updateSql:find('lease_name', 1, true))
      assert(not selectSql:find('schema_migrations', 1, true)
        and not selectSql:find('lease_domain_kind', 1, true))
      return table.concat({first.kind, failure.code, retried.kind,
        table.concat(selectedKinds, ',')}, ':')
    `);
    assert.equal(result,
      'session:DATABASE_RESULT_INVALID:admission:session,admission,admission');
  } finally {
    engine.global.close();
  }
});

test('retired durable domain names cannot recreate a compacted fencing row', async () => {
  const engine = await createPersistenceEngine();
  try {
    const result = await engine.doString(`
      local domainState, domainExists, calls = 'completed', true, {}
      local leaseRows, globalCount, sagaCount = {}, 0, 0
      local expectedOwner = 'instance-a:saga-worker'
      local platform = {
        nowGame = function() return 1000 end,
        random = function() return 1 end,
        wait = function() end,
        print = function() end,
        jsonEncode = function() return '{}' end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      local persistence = SynexCoreFactories.persistence({
        platform = platform,
        foundation = foundation,
        instanceId = 'instance-a',
        db = {
          query = function() return {} end,
          scalar = function() return nil end,
          insert = function() return 0 end,
          update = function() return 1 end,
          transaction = function() return true end,
          startTransaction = function(handler)
            return handler(function(sql, parameters)
              calls[#calls + 1] = { sql = sql, parameters = parameters }
              if sql:find('synex_instances', 1, true) then return {{ status = 'ready' }} end
              if sql:find('synex_instance_boots', 1, true) then return {{ boot_id = 'boot-a' }} end
              if sql:find('synex_sagas', 1, true)
                or sql:find('synex_character_deletion_plans', 1, true) then
                return domainExists and {{ state = domainState }} or {}
              end
              if sql:find('SELECT', 1, true) and sql:find('synex_cluster_leases', 1, true) then
                local row = leaseRows[parameters[1]]
                return row and {{ owner_id = row.owner_id, fencing_token = row.fencing_token,
                  valid = row.valid, lease_capacity_kind = row.lease_capacity_kind }} or {}
              end
              if sql:find('INSERT IGNORE INTO', 1, true)
                  and sql:find('synex_cluster_leases', 1, true) then
                if leaseRows[parameters[1]] then return { affectedRows = 0 } end
                leaseRows[parameters[1]] = { owner_id = parameters[2], fencing_token = 1,
                  valid = 1, lease_capacity_kind = 'saga' }
                return { affectedRows = 1 }
              end
              if sql:find('FROM', 1, true) and sql:find('synex_cluster_lease_capacity', 1, true) then
                return {{ entry_count = globalCount, global_limit = 100 }}
              end
              if sql:find('FROM', 1, true)
                  and sql:find('synex_cluster_lease_kind_capacity', 1, true) then
                return {{ lease_capacity_kind = 'saga', entry_count = sagaCount, kind_limit = 100 }}
              end
              if sql:find('UPDATE', 1, true) and sql:find('synex_cluster_lease_capacity', 1, true) then
                globalCount = globalCount + 1
                return { affectedRows = 1 }
              end
              if sql:find('UPDATE', 1, true)
                  and sql:find('synex_cluster_lease_kind_capacity', 1, true) then
                sagaCount = sagaCount + 1
                return { affectedRows = 1 }
              end
              error('unexpected lease query')
            end)
          end
        }
      })

      local sagaId = foundation.nextId('saga')
      assert(#sagaId >= 1 and #sagaId < 36 and sagaId:match('^[a-z0-9_]+$'))
      local sagaName = 'saga:' .. sagaId
      local terminal, terminalError = persistence.leases:acquire(
        sagaName, expectedOwner, 45, 'instance-a', 'boot-a')
      assert(terminal == nil and terminalError.code == 'LEASE_DOMAIN_TERMINAL')
      assert(#calls == 3 and calls[3].sql:find('synex_sagas', 1, true)
        and calls[3].sql:find('FOR UPDATE', 1, true))
      for _, call in ipairs(calls) do assert(not call.sql:find('INSERT INTO', 1, true)) end

      calls, domainState = {}, 'running'
      local active = assert(persistence.leases:acquire(
        sagaName, expectedOwner, 45, 'instance-a', 'boot-a'))
      assert(active.fencingToken == 1 and #calls == 10)
      assert(calls[3].sql:find('synex_sagas', 1, true)
        and calls[5].sql:find('INSERT IGNORE INTO', 1, true)
        and calls[6].sql:find('synex_cluster_lease_capacity', 1, true))

      calls, domainState = {}, 'cancelled'
      local characterId = foundation.nextId('del')
      assert(#characterId >= 1 and #characterId < 36
        and characterId:match('^[a-z0-9_]+$'))
      local characterName = 'character-delete:' .. characterId
      local character, characterError = persistence.leases:acquire(
        characterName, 'instance-a:character-worker', 45, 'instance-a', 'boot-a')
      assert(character == nil and characterError.code == 'LEASE_DOMAIN_TERMINAL')
      assert(calls[3].sql:find('synex_character_deletion_plans', 1, true))

      calls, domainExists = {}, false
      local missing, missingError = persistence.leases:acquire(
        sagaName, expectedOwner, 45, 'instance-a', 'boot-a')
      assert(missing == nil and missingError.code == 'LEASE_DOMAIN_NOT_FOUND')

      local unfenced, unfencedError = persistence.leases:acquire(
        sagaName, expectedOwner, 45)
      assert(unfenced == nil and unfencedError.code == 'INVALID_LEASE_AUTHORITY')
      local renewed, renewError = persistence.leases:renew({
        name = sagaName, owner = expectedOwner, fencingToken = 1, ttlSeconds = 45
      })
      assert(renewed == nil and renewError.code == 'INVALID_LEASE_AUTHORITY')
      local malformed, malformedError = persistence.leases:acquire(
        'saga:INVALID', expectedOwner, 45, 'instance-a', 'boot-a')
      assert(malformed == nil and malformedError.code == 'INVALID_LEASE')
      return table.concat({terminalError.code, active.fencingToken,
        characterError.code, missingError.code, unfencedError.code, renewError.code,
        malformedError.code}, ':')
    `);
    assert.equal(result,
      'LEASE_DOMAIN_TERMINAL:1:LEASE_DOMAIN_TERMINAL:LEASE_DOMAIN_NOT_FOUND:'
      + 'INVALID_LEASE_AUTHORITY:INVALID_LEASE_AUTHORITY:INVALID_LEASE');
  } finally {
    engine.global.close();
  }
});

test('bootstrap schedules bounded lease and state cleanup maintenance', async () => {
  const source = await readFile(
    path.join(root, 'core/synex_core/server/bootstrap_lifecycle.lua'),
    'utf8',
  );
  assert.match(
    source,
    /scheduleDatabaseEvery\(5000,[\s\S]*?persistence\.leases:retireExpiredAuthority\(250\)[\s\S]*?persistence\.leases:compactTerminal\(250\)[\s\S]*?'core\.leases\.compact_terminal'/u,
  );
  assert.match(
    source,
    /type\(stateService\.retryReplicationCleanup\) == 'function'[\s\S]*?scheduleEvery\(5000,[\s\S]*?stateService:retryReplicationCleanup\(64\)[\s\S]*?'core\.state\.replication_cleanup'/u,
  );
});
