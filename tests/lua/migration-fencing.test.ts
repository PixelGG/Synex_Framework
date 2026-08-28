import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';

import { MIGRATION_CHECKSUM_CORRECTIONS } from '../../tools/cli/src/migration-compatibility.js';

const root = process.cwd();

test('migration execution is fenced across lease expiry, errors, release, and restart', async () => {
  const engine = await new LuaFactory().createEngine();
  for (const relativePath of [
    'core/synex_core/server/factories.lua',
    'core/synex_core/server/foundation.lua',
    'core/synex_core/server/persistence.lua',
  ]) {
    await engine.doString(await readFile(path.join(root, relativePath), 'utf8'));
  }
  const migration021 = (await readFile(
    path.join(root, 'core/synex_core/migrations/021_worker_queue_scalability.sql'),
    'utf8',
  )).replace(/\r\n?/gu, '\n');
  const correctionPaths: Readonly<Record<string, string>> = {
    'synex_core:021_worker_queue_scalability': 'core/synex_core/migrations/021_worker_queue_scalability.sql',
    'synex_accounts:011_hold_lifecycle_v2': 'resources/synex_accounts/migrations/011_hold_lifecycle_v2.sql',
    'synex_accounts:015_financial_archive_v2': 'resources/synex_accounts/migrations/015_financial_archive_v2.sql',
    'synex_entities:002_entity_lifecycle_authority': 'resources/synex_entities/migrations/002_entity_lifecycle_authority.sql',
  };
  const correctionFixtures = await Promise.all(
    Object.entries(MIGRATION_CHECKSUM_CORRECTIONS).map(async ([identity, correction]) => {
      const migrationPath = correctionPaths[identity];
      assert.ok(migrationPath, `missing migration fixture path for ${identity}`);
      const [resource, id] = identity.split(':');
      assert.ok(resource && id, `invalid migration identity ${identity}`);
      return {
        resource,
        id,
        path: migrationPath,
        previous: correction.previous,
        current: correction.current,
        contents: (await readFile(path.join(root, migrationPath), 'utf8')).replace(/\r\n?/gu, '\n'),
      };
    }),
  );
  const correctionFixturesLua = `{${correctionFixtures.map((correction) => `{
    resource=${JSON.stringify(correction.resource)},
    id=${JSON.stringify(correction.id)},
    path=${JSON.stringify(correction.path)},
    previous=${JSON.stringify(correction.previous)},
    current=${JSON.stringify(correction.current)},
    contents=${JSON.stringify(correction.contents)}
  }`).join(',')}}`;

  const result = await engine.doString(`
    local clock, idSequence = 1000, 0
    local files, threads = {}, {}
    local migration021Contents = ${JSON.stringify(migration021)}
    local migrationChecksumCorrections = ${correctionFixturesLua}
    local shared = nil
    local contender, contenderError = nil, nil

    local FakePlatform = {
      nowGame = function() clock = clock + 1 return clock end,
      random = function() return 17 end,
      print = function() end,
      jsonEncode = function() return '{}' end,
      jsonDecode = function() return {} end,
      loadResourceFile = function(_, filePath) return files[filePath] end,
      createThread = function(handler)
        local thread = coroutine.create(handler)
        threads[#threads + 1] = thread
        assert(coroutine.resume(thread))
      end,
      wait = function()
        local _, isMain = coroutine.running()
        if not isMain then coroutine.yield() end
      end
    }
    local foundation = SynexCoreFactories.foundation({
      platform = FakePlatform,
      nextId = function(prefix)
        idSequence = idSequence + 1
        return tostring(prefix) .. '_' .. tostring(idSequence)
      end
    })

    local function resetState()
      shared = {
        lease = { owner = nil, token = 0, valid = false },
        fences = {}, attempts = {}, markers = {}, executions = {}, renewals = 0
      }
      contender, contenderError = nil, nil
    end

    local function key(parameters)
      return tostring(parameters[1]) .. '|' .. tostring(parameters[2])
    end

    local function makeAdapter()
      local function transactionQuery(sql, parameters)
        parameters = parameters or {}
        if sql:find('FROM ' .. string.char(96) .. 'synex_cluster_leases' .. string.char(96), 1, true) then
          local lease = shared.lease
          if not lease.owner then return {} end
          return {{ owner_id = lease.owner, fencing_token = lease.token,
            valid = lease.valid and 1 or 0 }}
        end

        local rowKey = key(parameters)
        if sql:find('FROM ' .. string.char(96) .. 'synex_schema_migrations' .. string.char(96), 1, true) then
          local row = shared.markers[rowKey]
          return row and { foundation.copy(row) } or {}
        end
        if sql:find('FROM ' .. string.char(96) .. 'synex_schema_migration_fences' .. string.char(96), 1, true) then
          local row = shared.fences[rowKey]
          return row and { foundation.copy(row) } or {}
        end
        if sql:find('FROM ' .. string.char(96) .. 'synex_schema_migration_attempts' .. string.char(96), 1, true) then
          local row = shared.attempts[rowKey]
          return row and { foundation.copy(row) } or {}
        end

        if sql:find('INSERT INTO ' .. string.char(96) .. 'synex_schema_migration_fences' .. string.char(96), 1, true) then
          local state = sql:find("'applied'", 1, true) and 'applied'
            or (sql:find("'indeterminate'", 1, true) and 'indeterminate' or 'applying')
          shared.fences[rowKey] = {
            resource_name = parameters[1], migration_id = parameters[2],
            checksum_sha256 = parameters[3], owner_id = parameters[4],
            fencing_token = parameters[5], state = state,
            statement_count = parameters[6],
            completed_statements = state == 'applied' and parameters[7] or 0,
            last_error_code = state == 'indeterminate' and 'LEGACY_ATTEMPT' or nil
          }
          return 1
        end
        if sql:find('UPDATE ' .. string.char(96) .. 'synex_schema_migration_fences' .. string.char(96), 1, true) then
          if sql:find('SET ' .. string.char(96) .. 'owner_id' .. string.char(96) .. ' = ?', 1, true) then
            rowKey = tostring(parameters[4]) .. '|' .. tostring(parameters[5])
            local row = assert(shared.fences[rowKey])
            row.owner_id, row.fencing_token, row.state = parameters[1], parameters[2], 'applying'
            row.statement_count, row.completed_statements = parameters[3], 0
          elseif sql:find('SET ' .. string.char(96) .. 'completed_statements' .. string.char(96) .. ' = ?', 1, true) then
            rowKey = tostring(parameters[2]) .. '|' .. tostring(parameters[3])
            local row = assert(shared.fences[rowKey])
            if row.owner_id == parameters[4] and row.fencing_token == parameters[5]
              and row.state == 'applying' and row.checksum_sha256 == parameters[6]
              and row.completed_statements == parameters[7] then
              row.completed_statements = parameters[1]
            end
          elseif sql:find("SET " .. string.char(96) .. "state" .. string.char(96) .. " = 'indeterminate'", 1, true) then
            rowKey = tostring(parameters[2]) .. '|' .. tostring(parameters[3])
            local row = assert(shared.fences[rowKey])
            if row.owner_id == parameters[4] and row.fencing_token == parameters[5]
              and row.state == 'applying' and row.checksum_sha256 == parameters[6] then
              row.state, row.last_error_code = 'indeterminate', parameters[1]
            end
          elseif sql:find("SET " .. string.char(96) .. "state" .. string.char(96) .. " = 'applied'", 1, true) then
            rowKey = tostring(parameters[1]) .. '|' .. tostring(parameters[2])
            local row = assert(shared.fences[rowKey])
            if row.owner_id == parameters[3] and row.fencing_token == parameters[4]
              and row.state == 'applying' and row.checksum_sha256 == parameters[5] then
              row.state = 'applied'
            end
          end
          return 1
        end

        if sql:find('INSERT INTO ' .. string.char(96) .. 'synex_schema_migration_attempts' .. string.char(96), 1, true) then
          local state = sql:find("'applied'", 1, true) and 'applied' or 'applying'
          local existing = shared.attempts[rowKey]
          shared.attempts[rowKey] = {
            checksum_sha256 = parameters[3], state = state,
            attempts = existing and existing.attempts or 1
          }
          return 1
        end
        if sql:find('UPDATE ' .. string.char(96) .. 'synex_schema_migration_attempts' .. string.char(96), 1, true) then
          if sql:find("SET " .. string.char(96) .. "state" .. string.char(96) .. " = 'applied'", 1, true) then
            rowKey = tostring(parameters[1]) .. '|' .. tostring(parameters[2])
            local row = assert(shared.attempts[rowKey])
            if row.checksum_sha256 == parameters[3] and row.state == 'applying' then row.state = 'applied' end
          else
            local row = assert(shared.attempts[rowKey])
            row.state, row.attempts = 'applying', math.min(row.attempts + 1, 65535)
          end
          return 1
        end

        if sql:find('INSERT INTO ' .. string.char(96) .. 'synex_schema_migrations' .. string.char(96), 1, true) then
          rowKey = tostring(parameters[2]) .. '|' .. tostring(parameters[1])
          assert(shared.markers[rowKey] == nil)
          shared.markers[rowKey] = {
            checksum_sha256 = parameters[3], duration_ms = parameters[4],
            instance_id = parameters[5]
          }
          return 1
        end
        error('unhandled transaction SQL: ' .. sql)
      end

      return {
        query = function(sql, parameters)
          if sql:find('FROM ' .. string.char(96) .. 'synex_schema_migration_attempts'
            .. string.char(96), 1, true) then
            assert(sql:find('ORDER BY ' .. string.char(96) .. 'resource_name' .. string.char(96)
              .. ', ' .. string.char(96) .. 'migration_id' .. string.char(96) .. ' LIMIT ?', 1, true))
            assert(parameters[1] == 161)
            return {
              { resource_name = 'synex_fixture', migration_id = '900_running',
                state = 'applying', attempts = 1 },
              { resource_name = 'synex_fixture', migration_id = '901_complete',
                state = 'applied', attempts = 1 },
              { resource_name = 'synex_fixture', migration_id = '902_failed',
                state = 'failed', attempts = 2 },
              { resource_name = 'synex_fixture', migration_id = '903_uncertain',
                state = 'failed', attempts = 3 }
            }
          end
          if sql:find('FROM ' .. string.char(96) .. 'synex_schema_migration_fences'
            .. string.char(96), 1, true) then
            assert(sql:find('ORDER BY ' .. string.char(96) .. 'resource_name' .. string.char(96)
              .. ', ' .. string.char(96) .. 'migration_id' .. string.char(96) .. ' LIMIT ?', 1, true))
            assert(parameters[1] == 161)
            assert(not sql:find('COUNT(', 1, true) and not sql:find('GROUP BY', 1, true))
            return {
              { resource_name = 'synex_fixture', migration_id = '900_running', state = 'applying' },
              { resource_name = 'synex_fixture', migration_id = '901_complete', state = 'applied' },
              { resource_name = 'synex_fixture', migration_id = '902_failed', state = 'failed' },
              { resource_name = 'synex_fixture', migration_id = '903_uncertain', state = 'indeterminate' }
            }
          end
          if sql:find('synex_cluster_leases', 1, true) then
            local lease = shared.lease
            return lease.owner and {{ owner_id = lease.owner, fencing_token = lease.token,
              valid = lease.valid and 1 or 0 }} or {}
          end
          return {}
        end,
        scalar = function() return nil end,
        insert = function() return 0 end,
        update = function(sql, parameters)
          parameters = parameters or {}
          local lease = shared.lease
          if sql:find('fencing_token' .. string.char(96) .. ' = ' .. string.char(96)
            .. 'fencing_token' .. string.char(96) .. ' + 1', 1, true) then
            if not lease.valid or lease.owner == parameters[4] then
              lease.owner, lease.token, lease.valid = parameters[1], lease.token + 1, true
              return 1
            end
            return 0
          end
          if sql:find('INSERT IGNORE INTO ' .. string.char(96) .. 'synex_cluster_leases' .. string.char(96), 1, true) then
            if not lease.owner then
              lease.owner, lease.token, lease.valid = parameters[2], 1, true
              return 1
            end
            return 0
          end
          if sql:find('TIMESTAMPADD(SECOND', 1, true)
            and sql:find('expires_at' .. string.char(96) .. ' > CURRENT_TIMESTAMP(6)', 1, true) then
            shared.renewals = shared.renewals + 1
            if lease.valid and lease.owner == parameters[3] and lease.token == parameters[4] then return 1 end
            return 0
          end
          if sql:find('expires_at' .. string.char(96) .. ' = CURRENT_TIMESTAMP(6)', 1, true) then
            if lease.owner == parameters[2] and lease.token == parameters[3] then
              lease.valid = false
              return 1
            end
            return 0
          end

          shared.executions[sql] = (shared.executions[sql] or 0) + 1
          if sql == 'LONG_DDL' then
            lease.valid = false
            assert(contender:acquireLease() == 2)
            local value
            value, contenderError = contender:apply('synex_fixture', {
              { id = '900_long', path = 'migrations/900_long.sql' }
            })
            assert(value == nil and contenderError.code == 'MIGRATION_INDETERMINATE')
            return 1
          end
          if sql == 'FAIL_DDL' then
            return nil, { code = 'PORT_FAILED', message = 'private driver detail' }
          end
          if sql == 'OK_DDL' then
            for _, thread in ipairs(threads) do
              if coroutine.status(thread) == 'suspended' then assert(coroutine.resume(thread)) end
            end
          end
          return 1
        end,
        transaction = function() return true end,
        startTransaction = function(handler)
          local snapshot = foundation.copy(shared)
          local ok, committed = pcall(handler, transactionQuery)
          if not ok then
            shared = snapshot
            error(committed)
          end
          if committed == false then
            shared = snapshot
            return false
          end
          return true
        end
      }
    end

    local function persistence(instanceId)
      return SynexCoreFactories.persistence({
        platform = FakePlatform, foundation = foundation, db = makeAdapter(),
        instanceId = instanceId, config = { migrationLeaseSeconds = 10 }
      })
    end

    local function manager(instanceId)
      return persistence(instanceId).migrations
    end

    resetState()
    files['migrations/900_long.sql'] = 'LONG_DDL'
    local first = manager('instance-a')
    contender = manager('instance-b')
    assert(first:acquireLease() == 1)
    local firstOwner = shared.lease.owner
    local applied, firstError = first:apply('synex_fixture', {
      { id = '900_long', path = 'migrations/900_long.sql' }
    })
    local longKey = 'synex_fixture|900_long'
    assert(applied == nil and firstError.code == 'LEASE_LOST')
    assert(contenderError.code == 'MIGRATION_INDETERMINATE')
    assert(shared.executions.LONG_DDL == 1)
    assert(shared.markers[longKey] == nil)
    assert(shared.fences[longKey].owner_id == firstOwner
      and shared.fences[longKey].fencing_token == 1
      and shared.fences[longKey].state == 'applying')
    assert(shared.attempts[longKey].state == 'applying')
    local contenderCode = contenderError.code
    assert(contender:releaseLease())

    resetState()
    files['migrations/901_ok.sql'] = 'OK_DDL'
    local successful = manager('instance-c')
    assert(successful:acquireLease() == 1)
    local successfulOwner = shared.lease.owner
    assert(successful:apply('synex_fixture', {
      { id = '901_ok', path = 'migrations/901_ok.sql' }
    }))
    local okKey = 'synex_fixture|901_ok'
    assert(shared.executions.OK_DDL == 1 and shared.renewals >= 3)
    assert(shared.markers[okKey].instance_id == successfulOwner)
    assert(shared.fences[okKey].owner_id == successfulOwner
      and shared.fences[okKey].fencing_token == 1
      and shared.fences[okKey].state == 'applied')
    assert(shared.attempts[okKey].state == 'applied')
    assert(successful:releaseLease())

    local restarted = manager('instance-d')
    assert(restarted:acquireLease() == 2)
    assert(restarted:apply('synex_fixture', {
      { id = '901_ok', path = 'migrations/901_ok.sql' }
    }))
    assert(shared.executions.OK_DDL == 1)
    assert(shared.markers[okKey].instance_id == successfulOwner
      and shared.fences[okKey].owner_id == successfulOwner
      and shared.fences[okKey].fencing_token == 1)
    assert(restarted:releaseLease())

    resetState()
    files['migrations/902_fail.sql'] = 'FAIL_DDL'
    local failing = manager('instance-e')
    assert(failing:acquireLease() == 1)
    local failingOwner = shared.lease.owner
    local failed, failureError = failing:apply('synex_fixture', {
      { id = '902_fail', path = 'migrations/902_fail.sql' }
    })
    local failKey = 'synex_fixture|902_fail'
    assert(failed == nil and failureError.code == 'MIGRATION_INDETERMINATE')
    assert(shared.executions.FAIL_DDL == 1 and shared.markers[failKey] == nil)
    assert(shared.fences[failKey].owner_id == failingOwner
      and shared.fences[failKey].fencing_token == 1
      and shared.fences[failKey].state == 'indeterminate')
    assert(shared.attempts[failKey].state == 'applying')
    assert(failing:releaseLease())

    local afterFailure = manager('instance-f')
    assert(afterFailure:acquireLease() == 2)
    local retried, retryError = afterFailure:apply('synex_fixture', {
      { id = '902_fail', path = 'migrations/902_fail.sql' }
    })
    assert(retried == nil and retryError.code == 'MIGRATION_INDETERMINATE')
    assert(shared.executions.FAIL_DDL == 1 and shared.markers[failKey] == nil)
    assert(shared.fences[failKey].owner_id == failingOwner
      and shared.fences[failKey].fencing_token == 1)
    assert(afterFailure:releaseLease())

    resetState()
    files['migrations/903_legacy_failed.sql'] = 'LEGACY_FAILED_DDL'
    local legacySystem = persistence('instance-g')
    local legacyChecksum = legacySystem.sha256('LEGACY_FAILED_DDL')
    local legacyKey = 'synex_fixture|903_legacy_failed'
    shared.attempts[legacyKey] = {
      checksum_sha256 = legacyChecksum, state = 'failed', attempts = 2
    }
    assert(legacySystem.migrations:acquireLease() == 1)
    local legacyResult, legacyError = legacySystem.migrations:apply('synex_fixture', {
      { id = '903_legacy_failed', path = 'migrations/903_legacy_failed.sql' }
    })
    assert(legacyResult == nil and legacyError.code == 'MIGRATION_INDETERMINATE')
    assert(shared.executions.LEGACY_FAILED_DDL == nil and shared.markers[legacyKey] == nil)
    assert(shared.attempts[legacyKey].state == 'failed'
      and shared.attempts[legacyKey].attempts == 2)
    assert(shared.fences[legacyKey].state == 'indeterminate'
      and shared.fences[legacyKey].last_error_code == 'LEGACY_ATTEMPT')
    assert(legacySystem.migrations:releaseLease())

    resetState()
    files['migrations/904_fenced_failed.sql'] = 'FENCED_FAILED_DDL'
    local fencedSystem = persistence('instance-h')
    local fencedChecksum = fencedSystem.sha256('FENCED_FAILED_DDL')
    local fencedKey = 'synex_fixture|904_fenced_failed'
    shared.attempts[fencedKey] = {
      checksum_sha256 = fencedChecksum, state = 'failed', attempts = 3
    }
    shared.fences[fencedKey] = {
      checksum_sha256 = fencedChecksum, owner_id = 'legacy-owner', fencing_token = 77,
      state = 'failed', statement_count = 1, completed_statements = 0
    }
    assert(fencedSystem.migrations:acquireLease() == 1)
    local fencedResult, fencedError = fencedSystem.migrations:apply('synex_fixture', {
      { id = '904_fenced_failed', path = 'migrations/904_fenced_failed.sql' }
    })
    assert(fencedResult == nil and fencedError.code == 'MIGRATION_INDETERMINATE')
    assert(shared.executions.FENCED_FAILED_DDL == nil and shared.markers[fencedKey] == nil)
    assert(shared.fences[fencedKey].owner_id == 'legacy-owner'
      and shared.fences[fencedKey].fencing_token == 77
      and shared.fences[fencedKey].state == 'failed')
    assert(shared.attempts[fencedKey].state == 'failed'
      and shared.attempts[fencedKey].attempts == 3)
    assert(fencedSystem.migrations:releaseLease())

    local previous021Checksum = '6d314f977f47fa39125c9597172e75fa05d80bfbd310aaf6be4c5584f6823b59'
    local current021Checksum = '5add0fed6935b83e7fd0905c188c1e534a6636d5d935fea1a28a145f7b533b7c'
    local migration021Path = 'migrations/021_worker_queue_scalability.sql'
    local migration021Key = 'synex_core|021_worker_queue_scalability'

    for correctionIndex, correction in ipairs(migrationChecksumCorrections) do
      resetState()
      files[correction.path] = correction.contents
      local correctedSystem = persistence('instance-correction-' .. tostring(correctionIndex))
      assert(correctedSystem.sha256(correction.contents) == correction.current)
      local correctionKey = correction.resource .. '|' .. correction.id
      shared.markers[correctionKey] = {
        checksum_sha256 = correction.previous, instance_id = 'legacy-instance'
      }
      shared.fences[correctionKey] = {
        checksum_sha256 = correction.previous, owner_id = 'legacy-instance', fencing_token = 42,
        state = 'applied', statement_count = 1, completed_statements = 1
      }
      shared.attempts[correctionKey] = {
        checksum_sha256 = correction.current, state = 'applied', attempts = 1
      }
      assert(correctedSystem.migrations:acquireLease() == 1)
      assert(correctedSystem.migrations:apply(correction.resource, {
        { id = correction.id, path = correction.path }
      }))
      assert(next(shared.executions) == nil)
      assert(shared.markers[correctionKey].checksum_sha256 == correction.previous)
      assert(correctedSystem.migrations:releaseLease())
    end

    resetState()
    files[migration021Path] = migration021Contents
    local failed021System = persistence('instance-021-failed')
    shared.fences[migration021Key] = {
      checksum_sha256 = previous021Checksum, owner_id = 'legacy-instance', fencing_token = 42,
      state = 'failed', statement_count = 1, completed_statements = 0
    }
    shared.attempts[migration021Key] = {
      checksum_sha256 = previous021Checksum, state = 'failed', attempts = 1
    }
    assert(failed021System.migrations:acquireLease() == 1)
    local failed021Result, failed021Error = failed021System.migrations:apply('synex_core', {
      { id = '021_worker_queue_scalability', path = migration021Path }
    })
    assert(failed021Result == nil and failed021Error.code == 'MIGRATION_CHECKSUM_MISMATCH')
    assert(next(shared.executions) == nil)
    assert(failed021System.migrations:releaseLease())

    local function markerless021StateBlocked(instanceId, fenceState, attemptState)
      resetState()
      files[migration021Path] = migration021Contents
      local system = persistence(instanceId)
      shared.fences[migration021Key] = {
        checksum_sha256 = previous021Checksum, owner_id = 'legacy-instance', fencing_token = 42,
        state = fenceState, statement_count = 1, completed_statements = 0
      }
      shared.attempts[migration021Key] = {
        checksum_sha256 = previous021Checksum, state = attemptState, attempts = 1
      }
      assert(system.migrations:acquireLease() == 1)
      local applyResult, applyError = system.migrations:apply('synex_core', {
        { id = '021_worker_queue_scalability', path = migration021Path }
      })
      assert(applyResult == nil and applyError.code == 'MIGRATION_CHECKSUM_MISMATCH')
      assert(next(shared.executions) == nil)
      assert(system.migrations:releaseLease())
      return applyError.code
    end
    local applying021Code = markerless021StateBlocked(
      'instance-021-applying', 'applying', 'applying')
    local indeterminate021Code = markerless021StateBlocked(
      'instance-021-indeterminate', 'indeterminate', 'failed')

    resetState()
    files[migration021Path] = migration021Contents
    local unknown021System = persistence('instance-021-unknown')
    shared.markers[migration021Key] = {
      checksum_sha256 = string.rep('f', 64), instance_id = 'unknown-instance'
    }
    assert(unknown021System.migrations:acquireLease() == 1)
    local unknown021Result, unknown021Error = unknown021System.migrations:apply('synex_core', {
      { id = '021_worker_queue_scalability', path = migration021Path }
    })
    assert(unknown021Result == nil and unknown021Error.code == 'MIGRATION_CHECKSUM_MISMATCH')
    assert(next(shared.executions) == nil)
    assert(unknown021System.migrations:releaseLease())

    local function applied021ControlBlocked(instanceId, fenceChecksum, fenceState,
        attemptChecksum, attemptState, expectedCode)
      resetState()
      files[migration021Path] = migration021Contents
      local system = persistence(instanceId)
      shared.markers[migration021Key] = {
        checksum_sha256 = previous021Checksum, instance_id = 'legacy-instance'
      }
      shared.fences[migration021Key] = {
        checksum_sha256 = fenceChecksum, owner_id = 'legacy-instance', fencing_token = 42,
        state = fenceState, statement_count = 1, completed_statements = 1
      }
      shared.attempts[migration021Key] = {
        checksum_sha256 = attemptChecksum, state = attemptState, attempts = 1
      }
      assert(system.migrations:acquireLease() == 1)
      local applyResult, applyError = system.migrations:apply('synex_core', {
        { id = '021_worker_queue_scalability', path = migration021Path }
      })
      assert(applyResult == nil and applyError.code == expectedCode)
      assert(next(shared.executions) == nil)
      assert(system.migrations:releaseLease())
      return applyError.code
    end
    local unknownFence021Code = applied021ControlBlocked('instance-021-unknown-fence',
      string.rep('e', 64), 'applied', previous021Checksum, 'applied',
      'MIGRATION_CHECKSUM_MISMATCH')
    local unknownAttempt021Code = applied021ControlBlocked('instance-021-unknown-attempt',
      previous021Checksum, 'applied', string.rep('d', 64), 'applied',
      'MIGRATION_CHECKSUM_MISMATCH')
    local failedAttempt021Code = applied021ControlBlocked('instance-021-failed-attempt',
      previous021Checksum, 'applied', previous021Checksum, 'failed',
      'MIGRATION_STATE_INCONSISTENT')

    resetState()
    files[migration021Path] = migration021Contents
    local inconsistent021System = persistence('instance-021-inconsistent')
    shared.markers[migration021Key] = {
      checksum_sha256 = previous021Checksum, instance_id = 'legacy-instance'
    }
    shared.fences[migration021Key] = {
      checksum_sha256 = previous021Checksum, owner_id = 'legacy-instance', fencing_token = 42,
      state = 'failed', statement_count = 1, completed_statements = 0
    }
    assert(inconsistent021System.migrations:acquireLease() == 1)
    local inconsistent021Result, inconsistent021Error = inconsistent021System.migrations:apply('synex_core', {
      { id = '021_worker_queue_scalability', path = migration021Path }
    })
    assert(inconsistent021Result == nil and inconsistent021Error.code == 'MIGRATION_STATE_INCONSISTENT')
    assert(next(shared.executions) == nil)
    assert(inconsistent021System.migrations:releaseLease())

    local migrationSnapshot = assert(manager('instance-i'):snapshot(10))
    assert(migrationSnapshot.totals.defined == 4
      and migrationSnapshot.totals.applied == 1
      and migrationSnapshot.totals.applying == 1
      and migrationSnapshot.totals.failed == 1
      and migrationSnapshot.totals.indeterminate == 1
      and migrationSnapshot.totals.attempts == 7)
    assert(migrationSnapshot.resources[1].indeterminate == 1)

    return table.concat({ firstError.code, contenderCode, failureError.code,
      retryError.code, legacyError.code, fencedError.code, failed021Error.code,
      applying021Code, indeterminate021Code, unknown021Error.code,
      unknownFence021Code, unknownAttempt021Code, failedAttempt021Code,
      inconsistent021Error.code }, ':')
  `);

  assert.equal(
    result,
    'LEASE_LOST:MIGRATION_INDETERMINATE:MIGRATION_INDETERMINATE:MIGRATION_INDETERMINATE:MIGRATION_INDETERMINATE:MIGRATION_INDETERMINATE:MIGRATION_CHECKSUM_MISMATCH:MIGRATION_CHECKSUM_MISMATCH:MIGRATION_CHECKSUM_MISMATCH:MIGRATION_CHECKSUM_MISMATCH:MIGRATION_CHECKSUM_MISMATCH:MIGRATION_CHECKSUM_MISMATCH:MIGRATION_STATE_INCONSISTENT:MIGRATION_STATE_INCONSISTENT',
  );
  engine.global.close();
});
