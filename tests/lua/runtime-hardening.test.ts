import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory, type LuaEngine } from 'wasmoon';

const root = process.cwd();

async function load(engine: LuaEngine, relativePath: string): Promise<void> {
  await engine.doString(await readFile(path.join(root, relativePath), 'utf8'));
}

async function coreEngine(modules: string[]): Promise<LuaEngine> {
  const engine = await new LuaFactory().createEngine();
  await load(engine, 'core/synex_core/shared/protocol.lua');
  await load(engine, 'core/synex_core/server/factories.lua');
  for (const module of modules) {
    if (module === 'identity_repository') {
      await load(engine, 'core/synex_core/server/identity_session_fencing.lua');
    }
    if (module === 'identity_characters') {
      await load(engine, 'core/synex_core/server/identity_character_deletion_reconciliation.lua');
      await load(engine, 'core/synex_core/server/identity_character_unloads.lua');
    }
    if (module === 'runtime_persistence') {
      for (const dependency of [
        'runtime_persistence_instances',
        'runtime_persistence_control',
        'runtime_persistence_control_retention',
        'runtime_persistence_rbac',
      ]) await load(engine, `core/synex_core/server/${dependency}.lua`);
    }
    await load(engine, `core/synex_core/server/${module}.lua`);
  }
  return engine;
}

test('persistent RBAC caches subjects, enforces deny precedence, and invalidates on writes', async () => {
  const engine = await coreEngine(['foundation', 'security']);
  try {
    const result = await engine.doString(`
      local now, subjectLoads, subjectVersion = 1000, 0, 1
      local assigned = true
      local platform = {
        nowGame = function() return now end,
        random = function() return 1 end,
        print = function() end,
        jsonEncode = function() return '{}' end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      local store = {}
      function store:loadRoleSnapshot()
        return { revision = 1, rows = {
          { role_name = 'operator', version = 3, permission_key = 'fixture.*', effect = 'allow' },
          { role_name = 'operator', version = 3, permission_key = 'fixture.delete', effect = 'deny' }
        } }, nil
      end
      function store:loadPolicyRevision() return 1, nil end
      function store:loadSubject()
        subjectLoads = subjectLoads + 1
        return { version = subjectVersion, roles = assigned and {'operator'} or {} }, nil
      end
      function store:loadSubjectVersion() return subjectVersion, nil end
      function store:defineRole() return true, nil end
      function store:assign() assigned = true subjectVersion = subjectVersion + 1 return true, nil end
      function store:revoke() assigned = false subjectVersion = subjectVersion + 1 return true, nil end

      local security = SynexCoreFactories.security({
        platform = platform, foundation = foundation, coreResource = 'synex_core',
        policy = { default = { allow = {}, deny = {} }, resources = {} },
        rbacStore = store, rbacCacheTtlMs = 5000, rbacCacheMaximum = 64
      })
      assert(security.rbac:hydrate())
      assert(security.rbac:check('user:fixture', 'fixture.read'))
      assert(not security.rbac:check('user:fixture', 'fixture.delete'))
      assert(subjectLoads == 1)
      assert(security.rbac:revoke('user:fixture', 'operator', {
        actor = 'synex_fixture', actorType = 'resource', reason = 'fixture revoke', traceId = 'trace-fixture'
      }))
      assert(not security.rbac:check('user:fixture', 'fixture.read'))
      assert(subjectLoads == 2)
      local invalid, invalidError = security.rbac:defineRole('Invalid Role', {'fixture.read'}, {
        actor = 'synex_fixture', reason = 'fixture define', traceId = 'trace-fixture'
      })
      assert(invalid == nil and invalidError.code == 'INVALID_ROLE')
      local snapshot = security.rbac:snapshot()
      assert(snapshot.persistent and snapshot.hydrated and snapshot.roles == 1)
      return table.concat({subjectLoads, snapshot.roles, snapshot.cachedSubjects}, ':')
    `);
    assert.equal(result, '2:1:1');
  } finally {
    engine.global.close();
  }
});

test('access management commits audit atomically and replays identical deterministic entries', async () => {
  const engine = await coreEngine(['foundation', 'identity_repository']);
  try {
    const result = await engine.doString(`
      local auditCount, banRow, allowRow = 0, nil, nil
      local platform = {
        nowGame = function() return 1000 end,
        random = function() return 1 end,
        print = function() end,
        jsonEncode = function(value)
          if type(value) == 'table' and type(value.reason) == 'string' then
            return 'reason:' .. value.reason
          end
          return '{}'
        end,
        jsonDecode = function(value)
          local reason = type(value) == 'string' and value:match('^reason:(.+)$') or nil
          if not reason then error('invalid fixture JSON') end
          return { reason = reason }
        end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('access-replay')
      local database = {}
      function database:withTransaction(handler)
        local function query(sql, parameters)
          if sql:find('FROM synex_access_bans', 1, true)
            or sql:find('synex_access_bans', 1, true) and sql:find('SELECT', 1, true) then
            return banRow and { foundation.copy(banRow) } or {}
          end
          if sql:find('synex_allowlist_entries', 1, true) and sql:find('SELECT', 1, true) then
            return allowRow and { foundation.copy(allowRow) } or {}
          end
          if sql:find('synex_access_bans', 1, true) and sql:find('INSERT INTO', 1, true) then
            banRow = {
              user_id = parameters[2], reason = parameters[3], expires_at = parameters[5],
              revoked_at = nil
            }
            return { affectedRows = 1 }
          end
          if sql:find('synex_allowlist_entries', 1, true) and sql:find('INSERT INTO', 1, true) then
            allowRow = {
              user_id = parameters[2], expires_at = parameters[4], revoked_at = nil,
              audit_context_json = nil
            }
            return { affectedRows = 1 }
          end
          if sql:find('synex_audit_log', 1, true) and sql:find('INSERT INTO', 1, true) then
            auditCount = auditCount + 1
            if parameters[5] == 'access.allow' then allowRow.audit_context_json = parameters[10] end
            return { affectedRows = 1 }
          end
          error('unexpected SQL: ' .. sql)
        end
        local committed = handler(query)
        return committed, committed and nil or foundation.error('TRANSACTION_ABORTED', 'fixture abort')
      end
      local repositories = SynexCoreFactories.identityRepository({
        platform = platform, foundation = foundation, database = database,
        players = { bindIdentifier = function() end }, config = {}, instanceId = 'instance-a',
        normalizeIdentifiers = function() return {} end
      })
      local context = {
        actor = 'synex_control', actorType = 'resource', reason = 'unused', traceId = 'trace-access-01'
      }
      local ban = { id = 'ban-entry-01', userId = 'user-0001', reason = 'policy violation' }
      assert(repositories.access:ban(ban, context))
      assert(repositories.access:ban(foundation.copy(ban), context))
      local changedBan, changedBanError = repositories.access:ban({
        id = ban.id, userId = ban.userId, reason = 'different reason'
      }, context)
      assert(changedBan == nil and changedBanError.code == 'ACCESS_ENTRY_CONFLICT')
      local allow = { id = 'allow-entry-01', userId = 'user-0001', reason = 'approved' }
      assert(repositories.access:allow(allow, context))
      assert(repositories.access:allow(foundation.copy(allow), context))
      local changedAllow, changedAllowError = repositories.access:allow({
        id = allow.id, userId = allow.userId, reason = 'different approval'
      }, context)
      assert(changedAllow == nil and changedAllowError.code == 'ACCESS_ENTRY_CONFLICT')
      assert(auditCount == 2)
      return table.concat({auditCount, changedBanError.code, changedAllowError.code}, ':')
    `);
    assert.equal(result, '2:ACCESS_ENTRY_CONFLICT:ACCESS_ENTRY_CONFLICT');
  } finally {
    engine.global.close();
  }
});

test('cluster heartbeat preserves the explicit local lifecycle status', async () => {
  const engine = await coreEngine(['foundation', 'runtime_persistence']);
  try {
    const result = await engine.doString(`
      local heartbeatWrites, explicitStatuses, databaseStatus = 0, {}, 'starting'
      local registeredBoot = nil
      local platform = {
        nowGame = function() return 1000 end, random = function() return 1 end,
        print = function() end, jsonEncode = function() return '{}' end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      local database = {}
      function database:transaction(statements)
        assert(#statements == 2)
        assert(statements[1].query:find('synex_instances', 1, true))
        assert(statements[2].query:find('synex_instance_boots', 1, true))
        registeredBoot = statements[2].values[2]
        assert(type(registeredBoot) == 'string' and registeredBoot ~= '')
        return true, nil
      end
      function database:update(sql, parameters)
        if sql:find("NOT IN ('stopping', 'stopped')", 1, true)
            and sql:find('CASE WHEN', 1, true) then
          heartbeatWrites = heartbeatWrites + 1
          assert(#parameters == 3 and parameters[1] == registeredBoot
            and parameters[3] == 'instance-a')
          if databaseStatus == 'stale' then databaseStatus = parameters[2] end
        elseif #parameters == 5 and parameters[1] == registeredBoot
            and parameters[3] == 'instance-a' then
          assert(parameters[4] == parameters[2] and parameters[5] == parameters[2])
          local target = parameters[2]
          if (target == 'ready' or target == 'degraded')
              and (databaseStatus == 'stopping' or databaseStatus == 'stopped') then
            return 0, nil
          end
          if (target == 'starting' or target == 'stopping' or target == 'stale')
              and databaseStatus == 'stopped' then
            return 0, nil
          end
          if target == 'degraded' or target == 'ready' then
            explicitStatuses[#explicitStatuses + 1] = target
          end
          databaseStatus = target
        end
        return 1, nil
      end
      function database:withTransaction(handler)
        local committed = handler(function(sql, parameters)
          if sql:find('synex_instance_boots', 1, true) then
            return {{ boot_id = registeredBoot }}
          end
          assert(sql:find('stale_session', 1, true)
            and sql:find('LIMIT ?', 1, true) and parameters[2] == 250)
          return {}
        end)
        return committed == true and true or nil,
          committed == true and nil or foundation.error('TRANSACTION_REJECTED', 'fixture rejected')
      end
      function database:query(sql, parameters)
        if sql:find('idx_session_control_state_scan', 1, true) then
          assert(parameters[1] == '' and parameters[2] == 250)
          return {}, nil
        end
        assert(sql:find('ORDER BY \`instance_id\` ASC LIMIT ?', 1, true))
        assert(parameters[1] == 251)
        return {{ status = databaseStatus }}, nil
      end
      function database:scalar(sql, parameters)
        assert(sql:find('bounded_pending_requests', 1, true))
        assert(parameters[1] == 251)
        return 0, nil
      end
      local instances = SynexCoreFactories.runtimePersistence({
        foundation = foundation, database = database, platform = platform,
        instanceId = 'instance-a'
      }).instances
      assert(instances:register('Instance A'))
      assert(instances:bootId() == registeredBoot)
      assert(instances:setStatus('degraded'))
      local degraded = assert(instances:heartbeat(45))
      assert(degraded.status == 'degraded' and instances:snapshot().status == 'degraded')
      assert(databaseStatus == 'degraded')
      assert(instances:setStatus('ready'))
      databaseStatus = 'degraded'
      local concurrent = assert(instances:heartbeat(45))
      assert(concurrent.status == 'ready' and databaseStatus == 'degraded')
      databaseStatus = 'stale'
      local ready = assert(instances:heartbeat(45))
      assert(ready.status == 'ready' and instances:snapshot().status == 'ready')
      assert(databaseStatus == 'ready')
      assert(heartbeatWrites == 3)
      assert(explicitStatuses[1] == 'degraded' and explicitStatuses[2] == 'ready')
      assert(instances:setStatus('stopping') and instances:setStatus('stopped'))
      local lateReady, lateReadyError = instances:setStatus('ready')
      assert(lateReady == nil and lateReadyError.code == 'INSTANCE_NOT_REGISTERED')
      assert(databaseStatus == 'stopped' and instances:snapshot().status == 'stopped')
      return table.concat(explicitStatuses, ':') .. ':' .. heartbeatWrites .. ':' .. lateReadyError.code
    `);
    assert.equal(result, 'degraded:ready:3:INSTANCE_NOT_REGISTERED');
  } finally {
    engine.global.close();
  }
});

test('cluster heartbeat catch-up mutations are deterministic bounded batches', async () => {
  const engine = await coreEngine(['foundation', 'runtime_persistence']);
  try {
    const result = await engine.doString(`
      local platform = {
        nowGame = function() return 1000 end, random = function() return 1 end,
        print = function() end, jsonEncode = function() return '{}' end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('heartbeat-batch-bound')
      local maintenanceCalls = 0
      local database = {
        transaction = function() return true, nil end,
        update = function(_, sql, parameters)
          if sql:find('CASE WHEN', 1, true) then return 1, nil end
          if sql:find('selected_instance', 1, true) then
            maintenanceCalls = maintenanceCalls + 1
            assert(sql:find('ORDER BY \`stale_candidate\`.\`heartbeat_at\` ASC', 1, true)
              and sql:find('LIMIT ?', 1, true) and parameters[3] == 7)
            return 7, nil
          end
          if sql:find('selected_session', 1, true) then
            maintenanceCalls = maintenanceCalls + 1
            assert(sql:find('ORDER BY \`stale_session\`.\`last_seen_at\` ASC', 1, true)
              and sql:find('LIMIT ?', 1, true) and parameters[2] == 7)
            return 7, nil
          end
          if sql:find('selected_request', 1, true) then
            maintenanceCalls = maintenanceCalls + 1
            assert(sql:find('ORDER BY \`candidate_request\`.\`expires_at\` ASC', 1, true)
              and sql:find('LIMIT ?', 1, true) and parameters[1] == 7)
            return 7, nil
          end
          if sql:find('request_claim', 1, true) and sql:find(' IN (', 1, true) then
            maintenanceCalls = maintenanceCalls + 1
            assert(#parameters == 9 and parameters[1] == 'instance-a')
            return 7, nil
          end
          error('unexpected heartbeat update')
        end,
        query = function(_, sql, parameters)
          if sql:find('idx_session_control_state_scan', 1, true) then
            assert(parameters[1] == '' and parameters[2] == 7)
            local controls = {}
            for index = 1, 7 do
              controls[index] = { request_id = ('control-%02d'):format(index) }
            end
            return controls, nil
          end
          assert(sql:find('ORDER BY \`instance_id\` ASC LIMIT ?', 1, true)
            and parameters[1] == 8)
          return {
            { status = 'ready' },
            { status = 'stale' }, { status = 'stale' }, { status = 'stale' },
            { status = 'stale' }, { status = 'stale' }, { status = 'stale' },
            { status = 'stale' }
          }, nil
        end,
        scalar = function(_, sql, parameters)
          assert(sql:find('bounded_pending_requests', 1, true)
            and sql:find('LIMIT ?', 1, true) and parameters[1] == 8)
          return 8, nil
        end,
        withTransaction = function(_, handler)
          local committed = handler(function(sql, parameters)
            if sql:find('synex_instance_boots', 1, true) then return {{ boot_id = 'boot-a' }} end
            if sql:find('SELECT', 1, true) and sql:find('stale_session', 1, true) then
              local rows = {}
              for index = 1, 7 do
                rows[index] = { id = ('stale-%02d'):format(index), user_id = 'user-' .. index,
                  server_instance_id = 'stale-instance-' .. index }
              end
              return rows
            end
            if sql:find('synex_cluster_leases', 1, true) then
              maintenanceCalls = maintenanceCalls + 1
              return { affectedRows = 7 }
            end
            if sql:find('instance heartbeat expired', 1, true) then
              maintenanceCalls = maintenanceCalls + 1
              return { affectedRows = 7 }
            end
            error('unexpected heartbeat transaction query')
          end)
          return committed == true and true or nil,
            committed == true and nil or foundation.error('TRANSACTION_REJECTED', 'fixture rejected')
        end
      }
      local instances = SynexCoreFactories.runtimePersistence({
        foundation = foundation, database = database, platform = platform,
        instanceId = 'instance-a', maintenanceBatchMaximum = 7
      }).instances
      assert(instances:register('Instance A'))
      local snapshot = assert(instances:heartbeat(45))
      assert(maintenanceCalls == 5 and snapshot.total == 7
        and snapshot.healthy == 1 and snapshot.stale == 6
        and snapshot.pendingControlRequests == 7
        and snapshot.instanceSummaryTruncated == true
        and snapshot.pendingControlRequestsTruncated == true)

      local invalidMaintenanceCalls = 0
      local invalidDatabase = {
        transaction = function() return true, nil end,
        update = function(_, sql)
          if sql:find('CASE WHEN', 1, true) then return 1, nil end
          invalidMaintenanceCalls = invalidMaintenanceCalls + 1
          return 8, nil
        end,
        query = function() error('invalid batch must fail before summary') end,
        scalar = function() error('invalid batch must fail before summary') end
      }
      local invalidInstances = SynexCoreFactories.runtimePersistence({
        foundation = foundation, database = invalidDatabase, platform = platform,
        instanceId = 'instance-b', maintenanceBatchMaximum = 7
      }).instances
      assert(invalidInstances:register('Instance B'))
      local invalid, failure = invalidInstances:heartbeat(45)
      assert(invalid == nil and failure.code == 'MAINTENANCE_BATCH_INVALID'
        and invalidMaintenanceCalls == 1)

      local overlongRows = {}
      for index = 1, 9 do overlongRows[index] = { status = 'ready' } end
      local invalidSummaryDatabase = {
        transaction = function() return true, nil end,
        update = function() return 1, nil end,
        query = function(_, sql)
          if sql:find('idx_session_control_state_scan', 1, true) then return {}, nil end
          return overlongRows, nil
        end,
        scalar = function() error('overlong instance rows must fail before pending summary') end,
        withTransaction = function(_, handler)
          local committed = handler(function(sql)
            if sql:find('synex_instance_boots', 1, true) then return {{ boot_id = 'boot-c' }} end
            return {}
          end)
          return committed == true and true or nil,
            committed == true and nil or foundation.error('TRANSACTION_REJECTED', 'fixture rejected')
        end
      }
      local invalidSummaryInstances = SynexCoreFactories.runtimePersistence({
        foundation = foundation, database = invalidSummaryDatabase, platform = platform,
        instanceId = 'instance-c', maintenanceBatchMaximum = 7
      }).instances
      assert(invalidSummaryInstances:register('Instance C'))
      local invalidSummary, invalidSummaryError = invalidSummaryInstances:heartbeat(45)
      assert(invalidSummary == nil and invalidSummaryError.code == 'CLUSTER_SUMMARY_INVALID')

      local invalidPendingDatabase = {
        transaction = function() return true, nil end,
        update = function() return 1, nil end,
        query = function(_, sql)
          if sql:find('idx_session_control_state_scan', 1, true) then return {}, nil end
          return {{ status = 'ready' }}, nil
        end,
        scalar = function() return 9, nil end,
        withTransaction = function(_, handler)
          local committed = handler(function(sql)
            if sql:find('synex_instance_boots', 1, true) then return {{ boot_id = 'boot-d' }} end
            return {}
          end)
          return committed == true and true or nil,
            committed == true and nil or foundation.error('TRANSACTION_REJECTED', 'fixture rejected')
        end
      }
      local invalidPendingInstances = SynexCoreFactories.runtimePersistence({
        foundation = foundation, database = invalidPendingDatabase, platform = platform,
        instanceId = 'instance-d', maintenanceBatchMaximum = 7
      }).instances
      assert(invalidPendingInstances:register('Instance D'))
      local invalidPending, invalidPendingError = invalidPendingInstances:heartbeat(45)
      assert(invalidPending == nil and invalidPendingError.code == 'CLUSTER_SUMMARY_INVALID')
      return table.concat({maintenanceCalls, snapshot.stale,
        snapshot.pendingControlRequests, failure.code,
        invalidSummaryError.code, invalidPendingError.code}, ':')
    `);
    assert.equal(result, '5:6:7:MAINTENANCE_BATCH_INVALID:'
      + 'CLUSTER_SUMMARY_INVALID:CLUSTER_SUMMARY_INVALID');
  } finally {
    engine.global.close();
  }
});

test('cluster control-authority audit advances a bounded cursor across valid requests', async () => {
  const engine = await coreEngine(['foundation', 'runtime_persistence']);
  try {
    const result = await engine.doString(`
      local platform = {
        nowGame = function() return 1000 end, random = function() return 1 end,
        print = function() end, jsonEncode = function() return '{}' end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      local cursors, auditUpdates, registeredBoot = {}, 0, nil
      local database = {
        transaction = function(_, statements)
          registeredBoot = statements[2].values[2]
          return true, nil
        end,
        update = function(_, sql)
          if sql:find('request_claim', 1, true) and sql:find(' IN (', 1, true) then
            auditUpdates = auditUpdates + 1
          end
          return sql:find('CASE WHEN', 1, true) and 1 or 0, nil
        end,
        query = function(_, sql, parameters)
          if sql:find('idx_session_control_state_scan', 1, true) then
            cursors[#cursors + 1] = parameters[1]
            assert(parameters[2] == 2)
            if parameters[1] == '' then
              return {{ request_id = 'control-a' }, { request_id = 'control-b' }}, nil
            end
            if parameters[1] == 'control-b' then
              return {{ request_id = 'control-c' }, { request_id = 'control-d' }}, nil
            end
            return {}, nil
          end
          return {{ status = 'ready' }}, nil
        end,
        scalar = function() return 0, nil end,
        withTransaction = function(_, handler)
          local committed = handler(function(sql)
            if sql:find('synex_instance_boots', 1, true) then
              return {{ boot_id = registeredBoot }}
            end
            return {}
          end)
          return committed == true and true or nil,
            committed == true and nil or foundation.error('TRANSACTION_REJECTED', 'fixture rejected')
        end
      }
      local instances = SynexCoreFactories.runtimePersistence({
        foundation = foundation, database = database, platform = platform,
        instanceId = 'instance-a', maintenanceBatchMaximum = 2
      }).instances
      assert(instances:register('Instance A'))
      for _ = 1, 4 do assert(instances:heartbeat(45)) end
      assert(table.concat(cursors, ':') == ':control-b:control-d:')
      assert(auditUpdates == 3)
      return table.concat({#cursors, auditUpdates, cursors[2], cursors[3]}, ':')
    `);
    assert.equal(result, '4:3:control-b:control-d');
  } finally {
    engine.global.close();
  }
});

test('runtime boot generations fence delayed status, cleanup, and source-floor work', async () => {
  const engine = await coreEngine(['foundation', 'runtime_persistence']);
  try {
    const result = await engine.doString(`
      local platform = {
        nowGame = function() return 1000 end, random = function() return 17 end,
        print = function() end, jsonEncode = function() return '{}' end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('runtime-boot-fence')
      local currentBoot, floorValue, guardedWrites = nil, 37, 0
      local database = {}
      function database:transaction(statements)
        assert(#statements == 2)
        currentBoot = statements[2].values[2]
        return true, nil
      end
      local function hasCurrentBoot(parameters)
        for _, value in ipairs(parameters or {}) do
          if value == currentBoot then return true end
        end
        return false
      end
      function database:update(sql, parameters)
        assert(sql:find('synex_instance_boots', 1, true))
        if hasCurrentBoot(parameters) then guardedWrites = guardedWrites + 1 return 1, nil end
        return 0, nil
      end
      function database:query(sql, parameters)
        assert(not sql:find('MAX(', 1, true) and sql:find('source_generation', 1, true))
        assert(sql:find('ORDER BY', 1, true) and sql:find('DESC LIMIT 1', 1, true))
        assert(sql:find('synex_instance_boots', 1, true)
          and sql:find('server_instance_id', 1, true)
          and not sql:find('closed_at', 1, true))
        if not hasCurrentBoot(parameters) then return {}, nil end
        return {{ source_generation_floor = floorValue }}, nil
      end
      function database:withTransaction(handler)
        local committed = handler(function(sql, parameters)
          if sql:find('FOR UPDATE', 1, true) then
            return hasCurrentBoot(parameters) and {{ boot_id = currentBoot }} or {}
          end
          guardedWrites = guardedWrites + 1
          return 1
        end)
        return committed == true and true or nil,
          committed == true and nil or foundation.error('TRANSACTION_REJECTED', 'fixture rejected')
      end

      local bootA = SynexCoreFactories.runtimePersistence({
        foundation = foundation, database = database, platform = platform, instanceId = 'instance-a'
      }).instances
      assert(bootA:register('Instance A'))
      local bootAId = assert(bootA:bootId())
      local bootB = SynexCoreFactories.runtimePersistence({
        foundation = foundation, database = database, platform = platform, instanceId = 'instance-a'
      }).instances
      assert(bootB:register('Instance A'))
      local bootBId = assert(bootB:bootId())
      assert(bootAId ~= bootBId and currentBoot == bootBId)

      local status, statusError = bootA:setStatus('stopping')
      assert(status == nil and statusError.code == 'INSTANCE_NOT_REGISTERED')
      local heartbeat, heartbeatError = bootA:heartbeat(45)
      assert(heartbeat == nil and heartbeatError.code == 'INSTANCE_HEARTBEAT_REJECTED')
      local terminated, terminationError = bootA:terminateLocalSessions('stale cleanup')
      assert(terminated == nil and terminationError.code == 'INSTANCE_BOOT_AUTHORITY_LOST')
      local staleFloor, staleFloorError = bootA:sourceGenerationFloor()
      assert(staleFloor == nil and staleFloorError.code == 'INSTANCE_BOOT_AUTHORITY_LOST')
      assert(guardedWrites == 0)

      assert(bootB:sourceGenerationFloor() == 37)
      floorValue = -1
      local negative, negativeError = bootB:sourceGenerationFloor()
      assert(negative == nil and negativeError.code == 'INVALID_SOURCE_GENERATION')
      floorValue = 1.5
      local fractional, fractionalError = bootB:sourceGenerationFloor()
      assert(fractional == nil and fractionalError.code == 'INVALID_SOURCE_GENERATION')
      floorValue = 9007199254740991
      local exhausted, exhaustedError = bootB:sourceGenerationFloor()
      assert(exhausted == nil and exhaustedError.code == 'INVALID_SOURCE_GENERATION')
      return table.concat({statusError.code, heartbeatError.code, terminationError.code,
        staleFloorError.code, negativeError.code, fractionalError.code, exhaustedError.code}, ':')
    `);
    assert.equal(result,
      'INSTANCE_NOT_REGISTERED:INSTANCE_HEARTBEAT_REJECTED:INSTANCE_BOOT_AUTHORITY_LOST:'
      + 'INSTANCE_BOOT_AUTHORITY_LOST:INVALID_SOURCE_GENERATION:INVALID_SOURCE_GENERATION:'
      + 'INVALID_SOURCE_GENERATION');
  } finally {
    engine.global.close();
  }
});

test('local session termination atomically revokes orphaned runtime authority', async () => {
  const engine = await coreEngine(['foundation', 'runtime_persistence']);
  try {
    const result = await engine.doString(`
      local statements, operations, registeredBoot = nil, {}, nil
      local platform = {
        nowGame = function() return 1000 end, random = function() return 1 end,
        print = function() end, jsonEncode = function() return '{}' end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      local database = {}
      function database:transaction(candidate)
        statements = candidate
        registeredBoot = candidate[2].values[2]
        return true, nil
      end
      function database:withTransaction(handler)
        local committed = handler(function(sql, parameters)
          operations[#operations + 1] = { sql = sql, parameters = parameters }
          if sql:find('FOR UPDATE', 1, true) then return {{ boot_id = registeredBoot }} end
          return 1
        end)
        return committed == true and true or nil,
          committed == true and nil or foundation.error('TRANSACTION_REJECTED', 'fixture rejected')
      end
      local instances = SynexCoreFactories.runtimePersistence({
        foundation = foundation, database = database, platform = platform,
        instanceId = 'instance-a'
      }).instances
      assert(instances:register('Instance A'))
      assert(instances:terminateLocalSessions('synex_core restarted'))
      assert(#statements == 2 and #operations == 4)
      assert(operations[1].sql:find('synex_instance_boots', 1, true)
        and operations[1].sql:find('FOR UPDATE', 1, true)
        and operations[1].parameters[1] == 'instance-a'
        and operations[1].parameters[2] == registeredBoot)
      assert(operations[2].sql:find('synex_cluster_leases', 1, true)
        and operations[2].sql:find('INNER JOIN', 1, true)
        and operations[2].sql:find('synex_sessions', 1, true)
        and operations[2].sql:find('lease_name', 1, true)
        and operations[2].sql:find("'session:'", 1, true)
        and operations[2].sql:find('closed_at', 1, true)
        and operations[2].sql:find('expires_at', 1, true)
        and operations[2].sql:find('CONCAT', 1, true)
        and #operations[2].parameters == 1
        and operations[2].parameters[1] == 'instance-a')
      assert(operations[3].sql:find('synex_session_control_requests', 1, true)
        and operations[3].sql:find("'pending'", 1, true)
        and operations[3].sql:find('requested_by_instance_id', 1, true)
        and operations[3].sql:find('target_instance_id', 1, true)
        and operations[3].sql:find('idx_session_control_requester_pending', 1, true)
        and operations[3].sql:find('idx_session_control_target_pending', 1, true)
        and operations[3].sql:find('UNION', 1, true)
        and operations[3].sql:find('LIMIT ?', 1, true)
        and not operations[3].sql:find('closed_at', 1, true)
        and operations[3].parameters[1] == 'instance-a'
        and operations[3].parameters[2] == 250
        and operations[3].parameters[3] == 'instance-a'
        and operations[3].parameters[4] == 250
        and operations[3].parameters[5] == 250
        and operations[3].parameters[6] == 'instance-a'
        and operations[3].parameters[7] == 'instance-a',
        'incoming and outgoing pending controls, including closed local targets, must expire')
      assert(operations[4].sql:find('synex_sessions', 1, true)
        and operations[4].sql:find("'CLOSED'", 1, true)
        and operations[4].parameters[1] == 'synex_core restarted'
        and operations[4].parameters[2] == 'instance-a')
      return table.concat({#operations, operations[2].parameters[1], operations[4].parameters[1]}, ':')
    `);
    assert.equal(result, '4:instance-a:synex_core restarted');
  } finally {
    engine.global.close();
  }
});

test('local session termination propagates transaction failure without partial success', async () => {
  const engine = await coreEngine(['foundation', 'runtime_persistence']);
  try {
    const result = await engine.doString(`
      local transactions, registered = 0, false
      local platform = {
        nowGame = function() return 1000 end, random = function() return 1 end,
        print = function() end, jsonEncode = function() return '{}' end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      local database = {}
      function database:transaction()
        registered = true
        return true, nil
      end
      function database:withTransaction()
        transactions = transactions + 1
        return nil, foundation.error('TRANSACTION_REJECTED', 'fixture cleanup failure')
      end
      local instances = SynexCoreFactories.runtimePersistence({
        foundation = foundation, database = database, platform = platform,
        instanceId = 'instance-a'
      }).instances
      assert(instances:register('Instance A') and registered)
      local terminated, terminationError = instances:terminateLocalSessions('synex_core restarted')
      assert(terminated == nil and terminationError.code == 'TRANSACTION_REJECTED')
      assert(transactions == 1)
      return terminationError.code .. ':' .. transactions
    `);
    assert.equal(result, 'TRANSACTION_REJECTED:1');
  } finally {
    engine.global.close();
  }
});

test('local session termination rejects cleanup work beyond the configured live-session bound', async () => {
  const engine = await coreEngine(['foundation', 'runtime_persistence']);
  try {
    const result = await engine.doString(`
      local platform = {
        nowGame = function() return 1000 end, random = function() return 1 end,
        print = function() end, jsonEncode = function() return '{}' end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      local registeredBoot, rolledBack, writes = nil, false, 0
      local database = {}
      function database:transaction(statements)
        registeredBoot = statements[2].values[2]
        return true, nil
      end
      function database:withTransaction(handler)
        local committed = handler(function(sql)
          if sql:find('FOR UPDATE', 1, true) then return {{ boot_id = registeredBoot }} end
          writes = writes + 1
          if sql:find('synex_cluster_leases', 1, true) then return { affectedRows = 7 } end
          return { affectedRows = 1 }
        end)
        rolledBack = committed ~= true
        return committed == true and true or nil,
          committed == true and nil or foundation.error('TRANSACTION_REJECTED', 'fixture rollback')
      end
      local instances = SynexCoreFactories.runtimePersistence({
        foundation = foundation, database = database, platform = platform,
        instanceId = 'instance-a', maximumLocalSessions = 3
      }).instances
      assert(instances:register('Instance A'))
      local terminated, terminationError = instances:terminateLocalSessions('bounded cleanup')
      assert(terminated == nil and terminationError.code == 'RUNTIME_MUTATION_BOUND_INVALID')
      assert(rolledBack and writes == 1)
      return terminationError.code
    `);
    assert.equal(result, 'RUNTIME_MUTATION_BOUND_INVALID');
  } finally {
    engine.global.close();
  }
});

test('local session termination rolls back when boot control cleanup exceeds its batch', async () => {
  const engine = await coreEngine(['foundation', 'runtime_persistence']);
  try {
    const result = await engine.doString(`
      local platform = {
        nowGame = function() return 1000 end, random = function() return 1 end,
        print = function() end, jsonEncode = function() return '{}' end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      local registeredBoot, rolledBack, writes = nil, false, 0
      local database = {}
      function database:transaction(statements)
        registeredBoot = statements[2].values[2]
        return true, nil
      end
      function database:withTransaction(handler)
        local committed = handler(function(sql)
          if sql:find('FOR UPDATE', 1, true) then return {{ boot_id = registeredBoot }} end
          writes = writes + 1
          if sql:find('synex_session_control_requests', 1, true) then
            return { affectedRows = 4 }
          end
          return { affectedRows = 1 }
        end)
        rolledBack = committed ~= true
        return committed == true and true or nil,
          committed == true and nil or foundation.error('TRANSACTION_REJECTED', 'fixture rollback')
      end
      local instances = SynexCoreFactories.runtimePersistence({
        foundation = foundation, database = database, platform = platform,
        instanceId = 'instance-a', maintenanceBatchMaximum = 3,
        maximumLocalSessions = 10
      }).instances
      assert(instances:register('Instance A'))
      local terminated, terminationError = instances:terminateLocalSessions('bounded cleanup')
      assert(terminated == nil and terminationError.code == 'MAINTENANCE_BATCH_INVALID')
      assert(rolledBack and writes == 2)
      return terminationError.code
    `);
    assert.equal(result, 'MAINTENANCE_BATCH_INVALID');
  } finally {
    engine.global.close();
  }
});

test('remote replacement controls are fenced across quiesce and requester restarts', async () => {
  const engine = await coreEngine(['foundation', 'runtime_persistence']);
  try {
    const result = await engine.doString(`
      local platform = {
        nowGame = function() return 1000 end, random = function() return 41 end,
        print = function() end, jsonEncode = function() return '{}' end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('control-fence-test')

      local queryGuard = true
      local queryTransactions, queryBoot = 0, nil
      local queryDatabase = {
        transaction = function(_, statements)
          queryBoot = statements[2].values[2]
          return true, nil
        end,
        query = function() return {}, nil end,
        update = function() error('query guard must abort before compensation') end,
        withTransaction = function(_, handler)
          queryTransactions = queryTransactions + 1
          local committed = handler(function(sql, parameters)
            if sql:find('synex_instances', 1, true) then return {{ instance_id = 'instance-a' }} end
            if sql:find('synex_cluster_leases', 1, true) then
              return {{ owner_id = 'instance-a:admission-a', fencing_token = 3, valid = 1 }}
            end
            assert(sql:find('idx_sessions_user_open', 1, true)
              and sql:find('ORDER BY \`connected_at\` ASC, \`id\` ASC LIMIT 32', 1, true))
            queryGuard = false
            return {{ id = 'remote-session-a', server_instance_id = 'instance-b' }}
          end)
          return committed == true and true or nil,
            committed == true and nil or foundation.error('TRANSACTION_REJECTED', 'fixture rejected')
        end
      }
      local queryInstances = SynexCoreFactories.runtimePersistence({
        foundation = foundation, database = queryDatabase, platform = platform,
        instanceId = 'instance-a'
      }).instances
      assert(queryInstances:register('Instance A') and queryInstances:bootId() == queryBoot)
      local queryGate = { name = 'admission:user-a', owner = 'instance-a:admission-a',
        fencingToken = 3, requesterInstanceId = 'instance-a', requesterBootId = queryBoot }
      local queryRequest, queryError = queryInstances:requestRemoteKicks(
        'user-a', 45, function() return queryGuard end, queryGate)
      assert(queryRequest == nil and queryError.code == 'CORE_STOPPING' and queryTransactions == 1)

      local insertGuard, inserts, claims, expiries, expiredIds = true, 0, 0, 0, nil
      local insertBoot = nil
      local insertDatabase = {
        transaction = function(_, statements)
          insertBoot = statements[2].values[2]
          return true, nil
        end,
        query = function()
          return {
            { id = 'remote-session-a', server_instance_id = 'instance-b' },
            { id = 'remote-session-b', server_instance_id = 'instance-b' }
          }, nil
        end,
        update = function(_, sql, parameters)
          assert(sql:find('request_id', 1, true) and sql:find(' IN (', 1, true))
          expiries = expiries + 1
          expiredIds = parameters
          return 1, nil
        end,
        withTransaction = function(_, handler)
          local committed = handler(function(sql, parameters)
            if sql:find('SELECT \`requester\`.\`instance_id\`', 1, true) then
              assert(parameters[1] == insertBoot and parameters[2] == 'instance-a')
              return {{ instance_id = 'instance-a' }}
            end
            if sql:find('synex_cluster_leases', 1, true) then
              return {{ owner_id = 'instance-a:admission-a', fencing_token = 4, valid = 1 }}
            end
            if sql:find('connected_at', 1, true) and sql:find('synex_sessions', 1, true) then
              return {
                { id = 'remote-session-a', server_instance_id = 'instance-b' },
                { id = 'remote-session-b', server_instance_id = 'instance-b' }
              }
            end
            if sql:find('synex_sessions', 1, true) and sql:find('FOR UPDATE', 1, true) then
              return {{ id = parameters[1], server_instance_id = 'instance-b' }}
            end
            if sql:find('FROM \`synex_session_control_capacity\`', 1, true) then
              return {{ entry_count = 0, global_limit = 100000, requester_limit = 10000 }}
            end
            if sql:find('INSERT IGNORE INTO', 1, true)
              and sql:find('synex_session_control_requester_capacity', 1, true) then
              return 1
            end
            if sql:find('FROM \`synex_session_control_requester_capacity\`', 1, true) then
              return {{ requested_by_instance_id = 'instance-a', entry_count = 0 }}
            end
            if sql:find('UPDATE \`synex_session_control_capacity\`', 1, true)
              or (sql:find('UPDATE', 1, true)
                and sql:find('synex_session_control_requester_capacity', 1, true)) then
              return 1
            end
            if sql:find('SELECT', 1, true) and sql:find('request_id', 1, true) then return {} end
            if sql:find('INSERT INTO', 1, true)
              and sql:find('synex_session_control_requests', 1, true) then
              inserts = inserts + 1
              insertGuard = false
              return 1
            end
            if sql:find('synex_session_control_authority', 1, true) then
              claims = claims + 1
              assert(parameters[2] == insertBoot)
              return 1
            end
            error('unexpected insert transaction SQL')
          end)
          return committed == true and true or nil,
            committed == true and nil or foundation.error('TRANSACTION_REJECTED', 'fixture rejected')
        end
      }
      local insertInstances = SynexCoreFactories.runtimePersistence({
        foundation = foundation, database = insertDatabase, platform = platform,
        instanceId = 'instance-a'
      }).instances
      assert(insertInstances:register('Instance A'))
      local insertGate = { name = 'admission:user-a', owner = 'instance-a:admission-a',
        fencingToken = 4, requesterInstanceId = 'instance-a', requesterBootId = insertBoot }
      local insertRequest, insertError = insertInstances:requestRemoteKicks(
        'user-a', 45, function() return insertGuard end, insertGate)
      assert(insertRequest == nil and insertError.code == 'CORE_STOPPING')
      assert(inserts == 1 and claims == 1 and expiries == 1 and #expiredIds == 3)
      assert(expiredIds[1] == insertBoot and expiredIds[2] == 'instance-a')

      local transactionSql, pollSql, completionSql, completionParameters = {}, nil, nil, nil
      local currentBoot, controlWrites = nil, 0
      local successDatabase = {}
      function successDatabase:transaction(statements)
        currentBoot = statements[2].values[2]
        return true, nil
      end
      function successDatabase:query(sql)
        pollSql = sql
        return {}, nil
      end
      function successDatabase:update(sql, parameters)
        completionSql = sql
        completionParameters = parameters
        return 1, nil
      end
      function successDatabase:withTransaction(handler)
        local committed = handler(function(sql, parameters)
          transactionSql[#transactionSql + 1] = sql
          if sql:find('SELECT \`requester\`.\`instance_id\`', 1, true) then
            if parameters[1] ~= currentBoot then return {} end
            return {{ instance_id = 'instance-a' }}
          end
          if sql:find('synex_cluster_leases', 1, true) then
            return {{ owner_id = 'instance-a:admission-a', fencing_token = 5, valid = 1 }}
          end
          if sql:find('connected_at', 1, true) and sql:find('synex_sessions', 1, true) then
            assert(sql:find('idx_sessions_user_open', 1, true)
              and sql:find('ORDER BY \`connected_at\` ASC, \`id\` ASC LIMIT 32', 1, true))
            return {{ id = 'remote-session-c', server_instance_id = 'instance-b' }}
          end
          if sql:find('synex_sessions', 1, true) and sql:find('FOR UPDATE', 1, true) then
            return {{ id = parameters[1], server_instance_id = 'instance-b' }}
          end
          if sql:find('FROM \`synex_session_control_capacity\`', 1, true) then
            return {{ entry_count = 0, global_limit = 100000, requester_limit = 10000 }}
          end
          if sql:find('INSERT IGNORE INTO', 1, true)
            and sql:find('synex_session_control_requester_capacity', 1, true) then
            return 1
          end
          if sql:find('FROM \`synex_session_control_requester_capacity\`', 1, true) then
            return {{ requested_by_instance_id = 'instance-a', entry_count = 0 }}
          end
          if sql:find('UPDATE \`synex_session_control_capacity\`', 1, true)
            or (sql:find('UPDATE', 1, true)
              and sql:find('synex_session_control_requester_capacity', 1, true)) then
            return 1
          end
          if sql:find('SELECT', 1, true) and sql:find('request_id', 1, true) then return {} end
          if sql:find('synex_session_control_requests', 1, true)
            or sql:find('synex_session_control_authority', 1, true) then
            controlWrites = controlWrites + 1
            return 1
          end
          error('unexpected success transaction SQL')
        end)
        return committed == true and true or nil,
          committed == true and nil or foundation.error('TRANSACTION_REJECTED', 'fixture rejected')
      end
      local staleInstances = SynexCoreFactories.runtimePersistence({
        foundation = foundation, database = successDatabase, platform = platform,
        instanceId = 'instance-a'
      }).instances
      assert(staleInstances:register('Instance A'))
      local staleBoot = assert(staleInstances:bootId())
      local successInstances = SynexCoreFactories.runtimePersistence({
        foundation = foundation, database = successDatabase, platform = platform,
        instanceId = 'instance-a'
      }).instances
      assert(successInstances:register('Instance A'))
      local activeBoot = assert(successInstances:bootId())
      assert(staleBoot ~= activeBoot and currentBoot == activeBoot)
      local staleGate = { name = 'admission:user-a', owner = 'instance-a:admission-a',
        fencingToken = 5, requesterInstanceId = 'instance-a', requesterBootId = staleBoot }
      local staleRequest, staleError = staleInstances:requestRemoteKicks(
        'user-a', 45, function() return true end, staleGate)
      assert(staleRequest == nil and staleError.code == 'ADMISSION_GATE_LOST' and controlWrites == 0)
      transactionSql = {}
      local activeGate = { name = 'admission:user-a', owner = 'instance-a:admission-a',
        fencingToken = 5, requesterInstanceId = 'instance-a', requesterBootId = activeBoot }
      assert(successInstances:requestRemoteKicks(
        'user-a', 45, function() return true end, activeGate) == 1)
      assert(controlWrites == 2 and #transactionSql == 15)
      assert(successInstances:pendingLocalControls())
      assert(successInstances:completeControl({
        request_id = 'control-a', target_session_id = 'remote-session-c',
        target_instance_id = 'instance-a', action = 'kick'
      }, true))
      assert(transactionSql[1]:find('synex_instance_boots', 1, true)
        and transactionSql[1]:find("'ready'", 1, true)
        and transactionSql[2]:find('synex_cluster_leases', 1, true)
        and transactionSql[3]:find('idx_sessions_user_open', 1, true)
        and transactionSql[14]:find('synex_session_control_requests', 1, true)
        and transactionSql[15]:find('synex_session_control_authority', 1, true))
      assert(pollSql:find('requester', 1, true)
        and pollSql:find('request_claim', 1, true)
        and pollSql:find('requester_boot', 1, true)
        and pollSql:find("'ready'", 1, true)
        and pollSql:find('created_at', 1, true)
        and pollSql:find('started_at', 1, true))
      assert(completionSql:find('requester', 1, true)
        and completionSql:find('request_claim', 1, true)
        and completionSql:find('requester_boot', 1, true)
        and completionSql:find("'ready'", 1, true)
        and completionSql:find('target_session_id', 1, true)
        and completionSql:find('target_instance_id', 1, true)
        and completionSql:find('closed_at', 1, true)
        and completionSql:find('created_at', 1, true)
        and completionSql:find('started_at', 1, true))
      assert(completionParameters[2] == 'control-a'
        and completionParameters[3] == 'remote-session-c'
        and completionParameters[4] == 'instance-a'
        and completionParameters[5] == 'kick' and completionParameters[6] == 1)
      return table.concat({queryError.code, insertError.code, staleError.code,
        inserts, claims, expiries, controlWrites}, ':')
    `);
    assert.equal(result, 'CORE_STOPPING:CORE_STOPPING:ADMISSION_GATE_LOST:1:1:1:2');
  } finally {
    engine.global.close();
  }
});

test('failed restart cleanup keeps the persisted instance fenced and admission closed', async () => {
  const engine = await coreEngine(['foundation', 'registries', 'lifecycle', 'bootstrap_restart', 'bootstrap_resource_events', 'bootstrap_lifecycle']);
  try {
    const result = await engine.doString(`
      local calls, persistedStatus = {}, 'ready'
      local fatalDiagnostic = nil
      local connectionQuiesceCalls, connectionLeaseReleaseCalls = 0, 0
      local platform = {
        nowGame = function() return 1000 end, random = function() return 43 end,
        print = function() end, jsonEncode = function() return '{}' end,
        resourceState = function() return 'started' end,
        resourceMetadata = function(name, key)
          if name == 'oxmysql' and key == 'version' then return '2.14.1' end
        end,
        getPlayers = function() return {} end,
        dropPlayer = function() error('no connected fixture player may be dropped') end
      }
      local logger = {}
      for _, level in ipairs({'trace', 'debug', 'info', 'warn', 'error'}) do
        logger[level] = function() end
      end
      logger.fatal = function(_, _, fields) fatalDiagnostic = fields end
      local foundation = SynexCoreFactories.foundation({ platform = platform, logger = logger })
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      registries.owners:activate('synex_core')
      local lifecycle = SynexCoreFactories.lifecycle({
        platform = platform, foundation = foundation, owners = registries.owners
      })
      local instances = {}
      function instances:register()
        calls[#calls + 1] = 'register:starting'
        persistedStatus = 'starting'
        return true, nil
      end
      function instances:terminateLocalSessions()
        calls[#calls + 1] = 'terminate:failed'
        return nil, foundation.error('TRANSACTION_REJECTED', 'fixture cleanup failure')
      end
      function instances:setStatus(status)
        calls[#calls + 1] = 'status:' .. status
        persistedStatus = status
        return true, nil
      end
      local releaseCalls = 0
      local migrations = {
        bootstrap = function() return true, nil end,
        acquireLease = function() return true, nil end,
        apply = function() return true, nil end,
        releaseLease = function() releaseCalls = releaseCalls + 1 return true, nil end
      }
      SynexCoreFactories.commands = function() return { bind = function() return true end } end
      local noop = function() calls[#calls + 1] = 'unexpected-service' return true, nil end
      local runtime = {}
      SynexCoreFactories.bootstrapLifecycle({
        runtime = runtime, platform = platform, foundation = foundation,
        runtimeGate = {
          beginBoot = function() end, open = function() end,
          fail = function() end, stop = function() end
        },
        coreResource = 'synex_core', registries = registries, lifecycle = lifecycle,
        reloadSnapshots = {}, facadeCache = {},
        manifests = { synex_core = { migrations = {} } }, reliability = {},
        sagaRuntime = {}, retention = {}, messaging = { network = {} },
        identity = {
          connections = {
            quiesce = function()
              connectionQuiesceCalls = connectionQuiesceCalls + 1
              return { removedPending = 0 }, nil
            end,
            releaseQuiescedLeases = function()
              connectionLeaseReleaseCalls = connectionLeaseReleaseCalls + 1
              return { leaseReleaseFailures = 0 }, nil
            end
          },
          characters = {}
        },
        security = { rbac = { hydrate = noop } },
        persistence = {
          database = { validateUtcSession = function() return true, nil end },
          migrations = migrations, instances = instances
        },
        defaultConfig = {
          instanceName = 'Instance A', database = { minimumOxmysqlVersion = '2.14.1' },
          features = { durableEvents = false, sagas = false },
          retention = { audit = { mode = 'retain_forever' }, workerIntervalMs = 60000 },
          connections = { clusterHeartbeatMs = 10000 }
        },
        api = {
          getAPIForCaller = noop, invokeForCaller = noop, guarded = noop,
          registerCoreContracts = noop, registerCoreServices = noop
        },
        discovery = {
          discoverResource = noop, invalidateResource = noop,
          discoverAll = function() return true, nil end,
          validateActive = function() return {} end, ensureOwner = noop,
          supportsStateHandoff = noop, captureStateHandoff = noop, restoreStateHandoff = noop
        }
      })
      local started, bootError = runtime:start()
      assert(started == nil and bootError.code == 'BOOT_FAILED')
      assert(calls[1] == 'register:starting' and calls[2] == 'terminate:failed')
      assert(calls[3] == 'status:stopping' and calls[4] == 'terminate:failed' and #calls == 4)
      assert(persistedStatus == 'stopping')
      assert(lifecycle.core:get() == 'FAILED' and lifecycle.core:canAdmitPlayers() == false)
      assert(connectionQuiesceCalls == 1 and connectionLeaseReleaseCalls == 1)
      assert(releaseCalls == 2)
      assert(fatalDiagnostic.code == 'TRANSACTION_REJECTED'
        and fatalDiagnostic.stage == 'terminate_local_sessions'
        and fatalDiagnostic.failureType == 'table')
      return table.concat({bootError.code, persistedStatus, lifecycle.core:get(), releaseCalls,
        connectionQuiesceCalls, connectionLeaseReleaseCalls}, ':')
    `);
    assert.equal(result, 'BOOT_FAILED:stopping:FAILED:2:1:1');
  } finally {
    engine.global.close();
  }
});

test('late boot failure purges scheduled workers and stale timeout callbacks remain inert', async () => {
  const engine = await coreEngine(['foundation', 'registries', 'lifecycle', 'bootstrap_restart', 'bootstrap_resource_events', 'bootstrap_lifecycle']);
  try {
    const result = await engine.doString(`
      local now, callbacks, statusWrites = 1000, {}, {}
      local connectionQuiesced, releaseCalls, terminateCalls = false, 0, 0
      local validationCalls = 0
      local mutations = {
        outbox = 0, publish = 0, saga = 0, archive = 0,
        deletion = 0, unload = 0, heartbeat = 0
      }
      local platform = {
        nowGame = function() now = now + 1 return now end,
        random = function() return 47 end,
        print = function() end,
        jsonEncode = function() return '{}' end,
        resourceState = function() return 'started' end,
        resourceMetadata = function(name, key)
          if name == 'oxmysql' and key == 'version' then return '2.14.1' end
        end,
        getPlayers = function() return {} end,
        dropPlayer = function() error('the fixture has no connected players') end,
        setTimeout = function(_, callback) callbacks[#callbacks + 1] = callback end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('late-boot-failure')
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      registries.owners:activate('synex_core')
      local lifecycle = SynexCoreFactories.lifecycle({
        platform = platform, foundation = foundation, owners = registries.owners
      })
      local instances = {}
      function instances:register() return true, nil end
      function instances:sourceGenerationFloor() return 0, nil end
      function instances:terminateLocalSessions()
        terminateCalls = terminateCalls + 1
        return true, nil
      end
      function instances:setStatus(status)
        statusWrites[#statusWrites + 1] = status
        if status == 'ready' then
          return nil, foundation.error('FINAL_STATUS_REJECTED', 'fixture final status failure')
        end
        return true, nil
      end
      local migrations = {
        bootstrap = function() return true, nil end,
        acquireLease = function() return true, nil end,
        apply = function() return true, nil end,
        releaseLease = function() return true, nil end
      }
      local connections = {
        quiesce = function()
          connectionQuiesced = true
          return { removedPending = 0 }, nil
        end,
        releaseQuiescedLeases = function()
          releaseCalls = releaseCalls + 1
          return { leaseReleaseFailures = 0 }, nil
        end,
        heartbeat = function()
          mutations.heartbeat = mutations.heartbeat + 1
          return true, nil
        end
      }
      local facadeCache = { ['synex_core:fixture'] = true }
      SynexCoreFactories.commands = function()
        return { bind = function() return true end }
      end
      local noop = function() return true, nil end
      local runtime = {}
      SynexCoreFactories.bootstrapLifecycle({
        runtime = runtime, platform = platform, foundation = foundation,
        runtimeGate = { beginBoot = noop, open = noop, fail = noop, stop = noop },
        coreResource = 'synex_core', registries = registries, lifecycle = lifecycle,
        reloadSnapshots = {}, facadeCache = facadeCache,
        manifests = { synex_core = { migrations = {} } },
        reliability = { outbox = { dispatchBatch = function()
          mutations.outbox = mutations.outbox + 1
          return {}, nil
        end } },
        sagaRuntime = { dispatchBatch = function()
          mutations.saga = mutations.saga + 1
          return true, nil
        end },
        retention = { audit = { archiveBatch = function()
          mutations.archive = mutations.archive + 1
          return true, nil
        end } },
        messaging = {
          network = {},
          events = { publishOutbox = function()
            mutations.publish = mutations.publish + 1
            return true, nil
          end }
        },
        identity = {
          connections = connections,
          characters = {
            reconcileDeletions = function()
              mutations.deletion = mutations.deletion + 1
              return true, nil
            end,
            reconcileUnloads = function()
              mutations.unload = mutations.unload + 1
              return true, nil
            end
          }
        },
        security = { rbac = { hydrate = noop } },
        persistence = {
          database = { validateUtcSession = noop }, migrations = migrations, instances = instances
        },
        defaultConfig = {
          instanceName = 'Instance A', database = { minimumOxmysqlVersion = '2.14.1' },
          features = { durableEvents = true, sagas = true },
          retention = {
            audit = { mode = 'archive' }, workerIntervalMs = 60000
          },
          connections = { clusterHeartbeatMs = 10000 }
        },
        api = {
          getAPIForCaller = noop, invokeForCaller = noop, guarded = noop,
          registerCoreContracts = noop,
          registerCoreServices = function() return 'service-token', nil end
        },
        discovery = {
          discoverResource = noop, invalidateResource = noop, discoverAll = noop, ensureOwner = noop,
          supportsStateHandoff = noop, captureStateHandoff = noop, restoreStateHandoff = noop,
          validateActive = function()
            validationCalls = validationCalls + 1
            return {}
          end
        }
      })

      local started, bootError = runtime:start()
      assert(started == nil and bootError.code == 'BOOT_FAILED')
      assert(connectionQuiesced == true and releaseCalls == 1)
      assert(terminateCalls == 2)
      assert(#callbacks == 1,
        'all recurring workers must share one bounded scheduler pump timer')
      assert(#statusWrites == 3 and statusWrites[1] == 'ready'
        and statusWrites[2] == 'stopping' and statusWrites[3] == 'stopped')
      assert(lifecycle.core:get() == 'FAILED' and lifecycle.core:canAdmitPlayers() == false)
      assert(lifecycle.scheduler:count() == 0 and #lifecycle.scheduler:snapshot() == 0)
      assert(#registries.owners:list() == 0 and next(facadeCache) == nil)

      local callbackCount, validationCount, statusCount = #callbacks, validationCalls, #statusWrites
      for index = 1, callbackCount do callbacks[index]() end
      assert(#callbacks == callbackCount, 'cancelled callbacks must not schedule successors')
      assert(validationCalls == validationCount and #statusWrites == statusCount)
      assert(mutations.outbox == 0 and mutations.publish == 0 and mutations.saga == 0
        and mutations.archive == 0 and mutations.deletion == 0 and mutations.unload == 0
        and mutations.heartbeat == 0)
      assert(lifecycle.scheduler:count() == 0 and #registries.owners:list() == 0)
      return table.concat({bootError.code, callbackCount, releaseCalls, terminateCalls,
        mutations.outbox, mutations.saga, mutations.deletion, mutations.heartbeat}, ':')
    `);
    assert.equal(result, 'BOOT_FAILED:1:1:2:0:0:0:0');
  } finally {
    engine.global.close();
  }
});

test('core raw stop is synchronous while explicit restart preparation drains durable authority', async () => {
  const engine = await coreEngine(['foundation', 'bootstrap_restart', 'bootstrap_resource_events', 'bootstrap_lifecycle']);
  try {
    const result = await engine.doString(`
      SynexCoreFactories.commands = function()
        return { bind = function() return true end }
      end
      local noop = function() return true, nil end

      local function fixture()
        local calls, handlers, state, quiesced = {}, {}, 'READY', false
        local cancelCalls, connectingCalls, lateKickReason = 0, 0, nil
        local facadeCache = { ['synex_core:fixture'] = true }
        local platform = {
          nowGame = function() return 1000 end, random = function() return 1 end,
          print = function() end, jsonEncode = function() return '{}' end,
          export = function() end,
          addEventHandler = function(name, handler) handlers[name] = handler end,
          cancelEvent = function() cancelCalls = cancelCalls + 1 end,
          getPlayers = function() return {'41', '42'} end,
          dropPlayer = function(playerSource) calls[#calls + 1] = 'drop:' .. playerSource end
        }
        local foundation = SynexCoreFactories.foundation({ platform = platform })
        local lifecycle = {
          core = {
            setHealthObserver = function() return true, nil end,
            setCriticalFoundationsValidated = function() end,
            get = function() return state end,
            transition = function(_, target)
              state = target
              calls[#calls + 1] = 'state:' .. target
              return 1, nil
            end
          },
          reload = { quiesce = function(_, owner)
            calls[#calls + 1] = 'owner:' .. owner
            return { abortErrors = {}, cleanup = { errors = {} } }, nil
          end }
        }
        local registries = {
          resources = { get = function() return nil end },
          owners = {
            list = function() return {{ resource = 'synex_core', epoch = 1 }} end,
            epoch = function() return 1 end,
            isEpoch = function() return true end
          }
        }
        local connections = {
          handleConnecting = function() connectingCalls = connectingCalls + 1 return true, nil end,
          handleJoining = noop, handleDropped = noop,
          snapshot = function() return { quiesced = quiesced } end,
          quiesce = function()
            quiesced = true
            calls[#calls + 1] = 'connections:quiesce'
            return { removedPending = 0 }, nil
          end,
          flushReadyQuiescedTerminals = function()
            calls[#calls + 1] = 'connections:flush-ready'
            return { completed = 1, failures = 0, remaining = 1 }, nil
          end,
          drainQuiescedTerminals = function()
            calls[#calls + 1] = 'tick'
            calls[#calls + 1] = 'connections:drain'
            return { completed = 1, failures = 0, remaining = 0 }, nil
          end,
          releaseQuiescedLeases = function()
            calls[#calls + 1] = 'connections:release-leases'
            return { leaseReleaseFailures = 0 }, nil
          end
        }
        local instances = {
          setStatus = function(_, status)
            calls[#calls + 1] = 'status:' .. status
            return true, nil
          end,
          terminateLocalSessions = function(_, reason)
            calls[#calls + 1] = 'terminate:' .. reason
            return true, nil
          end
        }
        local runtime = {}
        SynexCoreFactories.bootstrapLifecycle({
          runtime = runtime, platform = platform, foundation = foundation,
          runtimeGate = {
            beginBoot = noop, open = noop, fail = noop,
            stop = function() calls[#calls + 1] = 'gate:stop' end
          },
          coreResource = 'synex_core', registries = registries, lifecycle = lifecycle,
          reloadSnapshots = {}, facadeCache = facadeCache, manifests = {}, reliability = {},
          sagaRuntime = {}, retention = {}, security = {}, defaultConfig = {},
          messaging = { network = { bind = function() return true end } },
          identity = { connections = connections },
          persistence = { instances = instances },
          api = {
            getAPIForCaller = noop, invokeForCaller = noop, guarded = noop,
            registerCoreContracts = noop, registerCoreServices = noop
          },
          discovery = {
            discoverResource = noop, invalidateResource = noop,
            discoverAll = noop, validateActive = function() return {} end,
            ensureOwner = noop, supportsStateHandoff = noop,
            captureStateHandoff = noop, restoreStateHandoff = noop
          }
        })
        assert(runtime:bind())
        return {
          runtime = runtime, handlers = handlers, calls = calls, facadeCache = facadeCache,
          lateConnect = function()
            source = -2
            handlers.playerConnecting('Late', function(reason) lateKickReason = reason end, {})
            return cancelCalls, connectingCalls, lateKickReason
          end
        }
      end

      local raw = fixture()
      assert(raw.handlers.onResourceStop)
      raw.handlers.onResourceStop('synex_core')
      local rawOrder = table.concat(raw.calls, '|')
      assert(rawOrder == table.concat({
        'gate:stop', 'state:QUIESCING', 'connections:quiesce', 'drop:41', 'drop:42',
        'connections:flush-ready', 'state:STOPPING', 'state:STOPPED'
      }, '|'))
      assert(not rawOrder:find('tick', 1, true)
        and not rawOrder:find('status:', 1, true)
        and not rawOrder:find('terminate:', 1, true)
        and not rawOrder:find('release-leases', 1, true)
        and not rawOrder:find('owner:', 1, true))
      assert(next(raw.facadeCache) == nil)
      local cancelCalls, connectingCalls, lateKickReason = raw.lateConnect()
      assert(cancelCalls == 1 and connectingCalls == 0)
      assert(lateKickReason:find('[CORE_STOPPING]', 1, true))

      local prepared = fixture()
      local preparation = assert(prepared.runtime:prepareRestart())
      assert(preparation.state == 'prepared'
        and preparation.restartCommand == 'restart synex_core'
        and preparation.durableAuthorityClosed == true)
      local preparedOrder = table.concat(prepared.calls, '|')
      assert(preparedOrder == table.concat({
        'gate:stop', 'state:QUIESCING', 'connections:quiesce', 'drop:41', 'drop:42',
        'tick', 'connections:drain', 'status:stopping', 'connections:release-leases',
        'owner:synex_core', 'terminate:synex_core restart prepared', 'status:stopped',
        'state:STOPPING', 'state:STOPPED'
      }, '|'))
      local callCount = #prepared.calls
      assert(prepared.runtime:prepareRestart())
      assert(#prepared.calls == callCount, 'completed preparation must be idempotent')
      return rawOrder .. '||' .. preparedOrder
    `);
    assert.match(result, /connections:flush-ready[\s\S]*\|\|[\s\S]*connections:drain/u);
  } finally {
    engine.global.close();
  }
});

test('persistent RBAC mutations write actor, reason, before, and after in the same transaction', async () => {
  const engine = await coreEngine(['foundation', 'runtime_persistence']);
  try {
    const result = await engine.doString(`
      local auditRows, assignment = {}, nil
      local platform = {
        nowGame = function() return 1000 end,
        random = function() return 1 end,
        print = function() end,
        jsonEncode = function(value)
          if type(value) == 'table' and value.reason then return 'reason:' .. value.reason end
          if type(value) == 'table' and value.assigned ~= nil then return 'assigned:' .. tostring(value.assigned) end
          return '{}'
        end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('rbac-audit')
      local database = {}
      function database:withTransaction(handler)
        local function query(sql, parameters)
          if sql:find('synex_rbac_policy_revisions', 1, true)
            and sql:find('SELECT', 1, true) then return {{ revision = 1 }} end
          if sql:find('synex_rbac_roles', 1, true) and sql:find('SELECT', 1, true) then return {} end
          if sql:find('assigned_by_ref', 1, true) and sql:find('SELECT', 1, true) then
            return assignment and {{ assigned_by_ref = 'synex_control', expires_at = nil }} or {}
          end
          if sql:find('synex_rbac_subject_roles', 1, true) and sql:find('INSERT INTO', 1, true) then
            assignment = true
          elseif sql:find('synex_rbac_subject_roles', 1, true) and sql:find('DELETE FROM', 1, true) then
            assignment = nil
          elseif sql:find('synex_audit_log', 1, true) and sql:find('INSERT INTO', 1, true) then
            auditRows[#auditRows + 1] = foundation.copy(parameters)
          end
          return { affectedRows = 1 }
        end
        local committed = handler(query)
        return committed, committed and nil or foundation.error('TRANSACTION_ABORTED', 'fixture abort')
      end
      local persistence = SynexCoreFactories.runtimePersistence({
        foundation = foundation, database = database, platform = platform,
        instanceId = 'instance-a'
      })
      local context = {
        actor = 'synex_control', actorType = 'resource', reason = 'operator request',
        traceId = 'trace-rbac-01'
      }
      assert(persistence.rbac:defineRole('operator', {
        { permission = 'fixture.read', effect = 'allow' }
      }, context))
      assert(persistence.rbac:assign('user:fixture', 'operator', context))
      assert(persistence.rbac:revoke('user:fixture', 'operator', context))
      assert(#auditRows == 3)
      assert(auditRows[1][2] == context.traceId and auditRows[1][4] == context.actor)
      assert(auditRows[1][5] == 'rbac.role.define' and auditRows[1][9] ~= nil)
      assert(auditRows[2][5] == 'rbac.assignment.assign'
        and auditRows[2][8] == 'assigned:false' and auditRows[2][9] == 'assigned:true')
      assert(auditRows[3][5] == 'rbac.assignment.revoke'
        and auditRows[3][8] == 'assigned:true' and auditRows[3][9] == 'assigned:false')
      for _, row in ipairs(auditRows) do assert(row[10] == 'reason:operator request') end
      return table.concat({#auditRows, auditRows[1][5], auditRows[3][5]}, ':')
    `);
    assert.equal(result, '3:rbac.role.define:rbac.assignment.revoke');
  } finally {
    engine.global.close();
  }
});

test('offline-first character reads use a bounded TTL cache and return defensive copies', async () => {
  const engine = await coreEngine(['foundation', 'identity_characters']);
  try {
    const result = await engine.doString(`
      local now, fetches = 1000, 0
      local platform = {
        nowGame = function() return now end,
        random = function() return 1 end,
        print = function() end,
        jsonEncode = function() return '{}' end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('character-cache')
      local repository = {}
      function repository:get(characterId)
        fetches = fetches + 1
        return {
          id = characterId, userId = 'user-fixture', slot = 1, status = 'active',
          firstName = 'Ada', lastName = 'Lovelace', metadata = { nested = { value = fetches } }, version = fetches
        }, nil
      end
      local players = {
        getSession = function(_, id)
          if id == 'session-fixture' then return { id = id, state = 'ACTIVE', characterId = 'char-fixture' } end
        end,
        getBySource = function(_, source)
          if source == 42 then return { id = 'session-fixture', state = 'ACTIVE', characterId = 'char-fixture' } end
        end
      }
      local characters = SynexCoreFactories.identityCharacters({
        platform = platform, foundation = foundation, database = {}, players = players,
        owners = {}, messaging = {}, coreResource = 'synex_core', characterRepository = repository,
        sessionRepository = {}, invokeOwned = function() end, transition = function() end,
        leases = { acquire = function() return {}, nil end, release = function() return true, nil end },
        instances = { bootId = function() return 'boot-a', nil end },
        instanceId = 'instance-a',
        cacheMaximum = 64, cacheTtlMs = 1000
      })
      local first = assert(characters:get('char-fixture'))
      first.metadata.nested.value = 999
      local second = assert(characters:getActive(42))
      assert(second.metadata.nested.value == 1 and fetches == 1)
      now = now + 1001
      local refreshed = assert(characters:get('char-fixture'))
      assert(refreshed.version == 2 and fetches == 2)
      for index = 1, 70 do assert(characters:get(('char-%02d'):format(index))) end
      local snapshot = characters:cacheSnapshot()
      assert(snapshot.entries == 64 and snapshot.maximum == 64 and snapshot.ttlMs == 1000)
      return table.concat({fetches, snapshot.entries, refreshed.version}, ':')
    `);
    assert.equal(result, '72:64:2');
  } finally {
    engine.global.close();
  }
});

test('character deletion persists reconciliation and retries domain commit errors', async () => {
  const engine = await coreEngine(['foundation', 'registries', 'identity_characters']);
  try {
    const result = await engine.doString(`
      local foundation, persistedPlan
      local now, participantCalls, leaseCount, leaseRenewals, published, statePurges,
        terminalRetirements = 1000, 0, 0, 0, 0, 0, 0
      local leaseOwners = {}
      local planState, planId, planVersion = nil, nil, 0
      local platform = {
        nowGame = function() now = now + 1 return now end,
        random = function() return 1 end,
        print = function() end,
        jsonEncode = function(value)
          if type(value) == 'table' and value.schema == 1 then
            persistedPlan = foundation.copy(value)
            return '{"schema":1}'
          end
          return '{}'
        end,
        jsonDecode = function() return foundation.copy(persistedPlan) end
      }
      foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('delete-reconcile')
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      local coreEpoch = registries.owners:activate('synex_core')
      local domainEpoch = registries.owners:activate('synex_domain')
      local database = {}
      function database:withTransaction(handler)
        local function query(sql, parameters)
          if sql:find('SELECT', 1, true) and sql:find('synex_characters', 1, true) then
            return {{ version = 1, status = 'active', deleted_at = nil }}
          end
          if sql:find('INSERT INTO', 1, true) and sql:find('synex_character_deletion_plans', 1, true) then
            planId, planState, planVersion = parameters[1], 'executing', 1
            return { affectedRows = 1 }
          end
          if sql:find('UPDATE', 1, true)
              and sql:find('synex_character_deletion_plans', 1, true)
              and sql:find("'completed'", 1, true) then
            assert(planState == 'executing' and planId == parameters[1]
              and planVersion == parameters[2])
            planState, planVersion = 'completed', planVersion + 1
            return { affectedRows = 1 }
          end
          if sql:find('UPDATE', 1, true) and sql:find('synex_cluster_leases', 1, true) then
            assert(sql:find('terminal_compaction_at', 1, true)
              and parameters[1] == 'character-delete:' .. planId
              and type(parameters[2]) == 'string' and parameters[3] == leaseCount)
            terminalRetirements = terminalRetirements + 1
            return { affectedRows = 1 }
          end
          if sql:find('UPDATE', 1, true) and sql:find('synex_characters', 1, true) then return { affectedRows = 1 } end
          return { affectedRows = 1 }
        end
        return handler(query), nil
      end
      function database:update(sql)
        if sql:find("state", 1, true) and sql:find("completed", 1, true) then planState = 'completed' end
        planVersion = planVersion + 1
        return 1, nil
      end
      function database:query(sql)
        assert(sql:find('synex_character_deletion_plans', 1, true))
        if planState == 'executing' then
          return {{
            id = planId, character_id = 'character-a',
            version = planVersion, plan_json = '{"schema":1}'
          }}, nil
        end
        return {}, nil
      end
      local deletionSession = {
        id = 'session-a', userId = 'user-a', state = 'SELECTING_CHARACTER',
        source = 41, sourceGeneration = 1, persistedSource = 41,
        persistedSourceGeneration = 1, version = 1, persistedVersion = 1,
        clusterLease = { name = 'session:user-a', owner = 'instance-a:session-a',
          fencingToken = 1, requesterInstanceId = 'instance-a', requesterBootId = 'boot-a' }
      }
      local players = {
        getSession = function(_, sessionId)
          if sessionId == deletionSession.id then return foundation.copy(deletionSession) end
        end,
        isCurrent = function(_, sessionId, source, generation)
          return sessionId == deletionSession.id and source == 41 and generation == 1
        end
      }
      local messaging = {
        hooks = {},
        events = { publish = function()
          published = published + 1
          return true, nil
        end }
      }
      local leases = {
        acquire = function(_, name, owner, ttl)
          leaseCount = leaseCount + 1
          assert(name:find('character-delete:', 1, true) == 1
            and owner:find(':character-delete', 1, true) and ttl == 120)
          assert(leaseOwners[owner] == nil, 'each character deletion attempt needs a unique lease owner')
          leaseOwners[owner] = true
          return { name = name, owner = owner, fencingToken = leaseCount }, nil
        end,
        renew = function()
          leaseRenewals = leaseRenewals + 1
          return true, nil
        end,
        release = function() return true, nil end
      }
      local characters = SynexCoreFactories.identityCharacters({
        platform = platform, foundation = foundation, database = database, players = players,
        owners = registries.owners, messaging = messaging, coreResource = 'synex_core',
        characterRepository = { getOwned = function()
          return { id = 'character-a', userId = 'user-a', version = 1 }, nil
        end },
        sessionRepository = {}, leases = leases,
        instances = { bootId = function() return 'boot-a', nil end }, instanceId = 'instance-a',
        stateService = { purgeSubject = function(_, scope, subject)
          assert(scope == 'character' and subject == 'character-a')
          statePurges = statePurges + 1
          return { cleared = 1 }, nil
        end },
        invokeOwned = function(entry, handler, ...)
          assert(registries.owners:isCurrent(entry.owner, entry.epoch))
          return foundation.safeCall(handler, ...)
        end,
        transition = function() return true, nil end
      })
      assert(characters:registerParticipant('synex_domain', domainEpoch, {
        name = 'synex_domain', prepare = function() return true end,
        rollback = function() return true end,
        deletePreflight = function() return { action = 'anonymize' }, nil end,
        deleteCommit = function()
          participantCalls = participantCalls + 1
          if participantCalls == 1 then
            return nil, { code = 'DOMAIN_RETRY', message = 'retry', retryable = true }
          end
          return { applied = true }, nil
        end
      }))
      local invalidParticipant, invalidParticipantError = characters:registerParticipant('synex_domain', domainEpoch, {
        name = 'invalid_timeout', prepare = function() return true end, timeoutMs = 99
      })
      assert(invalidParticipant == nil and invalidParticipantError.code == 'INVALID_PARTICIPANT')
      assert(characters:registerParticipant('synex_domain', domainEpoch, {
        name = 'optional_slow', required = false, timeoutMs = 100,
        prepare = function() return true end,
        deletePreflight = function() now = now + 101 return { action = 'allow' }, nil end
      }))
      local deletion = assert(characters:delete('session-a', 'character-a'))
      assert(deletion.state == 'reconciling' and planState == 'executing')
      assert(participantCalls == 1 and published == 0)
      local report = assert(characters:reconcileDeletions(10))
      assert(report.completed == 1 and report.deferred == 0 and planState == 'completed')
      assert(participantCalls == 2 and published == 1 and leaseCount == 2 and statePurges == 1)
      assert(leaseRenewals >= 7 and terminalRetirements == 1)
      return table.concat({deletion.state, report.completed, participantCalls, published,
        statePurges}, ':')
    `);
    assert.equal(result, 'reconciling:1:2:1:1');
  } finally {
    engine.global.close();
  }
});

test('required character participant deadlines fail closed for load and unload', async () => {
  const engine = await coreEngine(['foundation', 'registries', 'identity_characters']);
  try {
    const result = await engine.doString(`
      local now = 1000
      local platform = {
        nowGame = function() return now end,
        random = function() return 1 end,
        print = function() end,
        jsonEncode = function() return '{}' end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('participant-deadline')
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      registries.owners:activate('synex_core')
      local session = {
        id = 'session-a', userId = 'user-a', state = 'SELECTING_CHARACTER',
        characterId = nil, source = 42, sourceGeneration = 1,
        persistedSource = 42, persistedSourceGeneration = 1,
        version = 1, persistedVersion = 1,
        clusterLease = { name = 'session:user-a', owner = 'instance-a:session-a',
          fencingToken = 1, requesterInstanceId = 'instance-a', requesterBootId = 'boot-a' }
      }
      local players = {}
      function players:getSession(id) if id == session.id then return foundation.copy(session) end end
      function players:isCurrent(id, source, generation)
        return id == session.id and source == session.source and generation == session.sourceGeneration
      end
      function players:updateSession(id, mutator)
        if id ~= session.id then return nil, foundation.error('SESSION_NOT_FOUND', 'missing') end
        local candidate = foundation.copy(session)
        mutator(candidate)
        session = candidate
        return foundation.copy(session), nil
      end
      function players:bindCharacter(id, characterId)
        if id ~= session.id or session.characterId ~= nil then return nil, foundation.error('BIND_FAILED', 'fixture') end
        session.characterId = characterId
        return foundation.copy(session), nil
      end
      function players:unbindCharacter(id)
        if id ~= session.id then return nil, foundation.error('SESSION_NOT_FOUND', 'fixture') end
        session.characterId = nil
        return foundation.copy(session), nil
      end
      local characters = SynexCoreFactories.identityCharacters({
        platform = platform, foundation = foundation, database = {}, players = players,
        owners = registries.owners,
        messaging = { hooks = {}, events = {} }, coreResource = 'synex_core',
        characterRepository = { getOwned = function()
          return { id = 'character-a', userId = 'user-a', version = 1 }, nil
        end },
        sessionRepository = { update = function() return true, nil end },
        invokeOwned = function(entry, handler, ...)
          assert(registries.owners:isCurrent(entry.owner, entry.epoch))
          return foundation.safeCall(handler, ...)
        end,
        transition = function(candidate, target)
          candidate.state = target
          candidate.version = (candidate.version or 0) + 1
          return candidate, nil
        end,
        leases = { acquire = function() return {}, nil end, release = function() return true, nil end },
        instances = { bootId = function() return 'boot-a', nil end },
        instanceId = 'instance-a'
      })
      local invalidEpoch = registries.owners:activate('synex_invalid_commit')
      local invalidParticipant, invalidParticipantError = characters:registerParticipant(
        'synex_invalid_commit', invalidEpoch, {
          name = 'invalid_required_commit', prepare = function() return true end,
          rollback = function() return true end,
          commit = function() return true end
        }
      )
      assert(invalidParticipant == nil and invalidParticipantError.code == 'INVALID_PARTICIPANT')
      assert(invalidParticipantError.message:find('cannot define commit', 1, true))
      local missingRollbackEpoch = registries.owners:activate('synex_missing_rollback')
      local missingRollback, missingRollbackError = characters:registerParticipant(
        'synex_missing_rollback', missingRollbackEpoch, {
          name = 'missing_required_rollback', prepare = function() return true end
        }
      )
      assert(missingRollback == nil and missingRollbackError.code == 'INVALID_PARTICIPANT')
      assert(missingRollbackError.message:find('must define rollback', 1, true))
      local optionalCommitCalls = 0
      local notificationEpoch = registries.owners:activate('synex_optional_commit')
      assert(characters:registerParticipant('synex_optional_commit', notificationEpoch, {
        name = 'optional_commit', required = false, priority = 10,
        prepare = function() return true end,
        commit = function()
          optionalCommitCalls = optionalCommitCalls + 1
          return nil, foundation.error('OPTIONAL_NOTIFICATION_FAILED', 'fixture')
        end
      }))
      local requiredEpoch = registries.owners:activate('synex_required_load')
      local loadRollbacks, requiredPrepareCalls = 0, 0
      local requiredPrepare = setmetatable({ __cfx_functionReference = 'fixture-character-prepare' }, {
        __metatable = 'protected-cfx-funcref',
        __call = function()
          requiredPrepareCalls = requiredPrepareCalls + 1
          now = now + 101
          return { prepared = true }
        end
      })
      assert(characters:registerParticipant('synex_required_load', requiredEpoch, {
        name = 'required_load', timeoutMs = 100,
        prepare = requiredPrepare,
        rollback = function(prepared)
          assert(prepared and prepared.prepared)
          loadRollbacks = loadRollbacks + 1
          return true
        end
      }))
      local loaded, loadError = characters:select('session-a', 'character-a')
      assert(loaded == nil and loadError.code == 'PARTICIPANT_TIMEOUT')
      assert(session.state == 'SELECTING_CHARACTER' and session.characterId == nil
        and requiredPrepareCalls == 1 and loadRollbacks == 1)
      registries.owners:purge('synex_required_load', requiredEpoch, 'fixture')
      local optionalEpoch = registries.owners:activate('synex_optional_load')
      assert(characters:registerParticipant('synex_optional_load', optionalEpoch, {
        name = 'optional_load', required = false, timeoutMs = 100,
        prepare = function() now = now + 101 return true end
      }))
      assert(characters:select('session-a', 'character-a'))
      assert(session.state == 'ACTIVE' and session.characterId == 'character-a')
      local unloadOrder = {}
      local firstUnloadEpoch = registries.owners:activate('synex_first_unload')
      assert(characters:registerParticipant('synex_first_unload', firstUnloadEpoch, {
        name = 'first_unload', priority = -10, prepare = function() return true end,
        rollback = function() return true end,
        unload = function()
          unloadOrder[#unloadOrder + 1] = 'first'
          return true
        end
      }))
      local unloadEpoch = registries.owners:activate('synex_required_unload')
      assert(characters:registerParticipant('synex_required_unload', unloadEpoch, {
        name = 'required_unload', timeoutMs = 100, prepare = function() return true end,
        rollback = function() return true end,
        unload = function()
          unloadOrder[#unloadOrder + 1] = 'failure'
          now = now + 101
          return true
        end
      }))
      local finalUnloadEpoch = registries.owners:activate('synex_final_unload')
      assert(characters:registerParticipant('synex_final_unload', finalUnloadEpoch, {
        name = 'final_unload', priority = 10, prepare = function() return true end,
        rollback = function() return true end,
        unload = function()
          unloadOrder[#unloadOrder + 1] = 'final'
          return true
        end
      }))
      local unloaded, unloadError = characters:unload('session-a', 'fixture')
      assert(unloaded == nil and unloadError.code == 'CHARACTER_UNLOAD_FAILED')
      assert(unloadError.details.cause == 'PARTICIPANT_TIMEOUT'
        and unloadError.details.cleanupContinued and not unloadError.details.stateRestored
        and unloadError.details.persisted and unloadError.details.state == 'SELECTING_CHARACTER')
      assert(table.concat(unloadOrder, ',') == 'first,failure,final')
      assert(session.state == 'SELECTING_CHARACTER' and session.characterId == nil)
      assert(optionalCommitCalls == 1)
      return table.concat({invalidParticipantError.code, missingRollbackError.code,
        optionalCommitCalls, loadRollbacks, loadError.code, unloadError.code, session.state}, ':')
    `);
    assert.equal(result,
      'INVALID_PARTICIPANT:INVALID_PARTICIPANT:1:1:PARTICIPANT_TIMEOUT:CHARACTER_UNLOAD_FAILED:SELECTING_CHARACTER');
  } finally {
    engine.global.close();
  }
});

test('failed character unload persistence blocks reuse and reconciles bounded pending sessions', async () => {
  const engine = await coreEngine(['foundation', 'registries', 'identity_characters']);
  try {
    const result = await engine.doString(`
      local platform = {
        nowGame = function() return 1000 end,
        random = function() return 1 end,
        print = function() end,
        jsonEncode = function() return '{}' end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('unload-reconciliation')
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      registries.owners:activate('synex_core')
      local players = registries.players
      local function addSession(tempSource, source, id, state, characterId)
        assert(players:createPending(tempSource, { sessionId = id }))
        assert(players:bindJoined(tempSource, source, {
          id = id, userId = 'user-a', state = state, characterId = characterId,
          version = 5, persistedVersion = 5, persistedSource = source,
          persistedSourceGeneration = 1,
          clusterLease = { name = 'session:user-a:' .. id, owner = 'instance-a:' .. id,
            fencingToken = 1, requesterInstanceId = 'instance-a', requesterBootId = 'boot-a' },
          clusterLeaseDeadlineAt = 26000, authorityDeadlineAt = 26000
        }))
        if characterId then assert(players:bindCharacter(id, characterId)) end
      end
      addSession(-1, 41, 'session-a', 'ACTIVE', 'character-a')
      addSession(-2, 42, 'session-b', 'SELECTING_CHARACTER', nil)
      local persisted = {
        ['session-a'] = { state = 'ACTIVE', characterId = 'character-a', version = 5 }
      }
      local failNext = { ['session-a'] = true }
      local failAlways = {}
      local sessionRepository = {}
      function sessionRepository:update(candidate)
        if failAlways[candidate.id] then
          return nil, foundation.error('DATABASE_ERROR', 'persistent fixture outage', {
            retryable = true
          })
        end
        if failNext[candidate.id] then
          failNext[candidate.id] = nil
          return nil, foundation.error('DATABASE_ERROR', 'fixture outage', { retryable = true })
        end
        persisted[candidate.id] = {
          state = candidate.state, characterId = candidate.characterId, version = candidate.version
        }
        return true, nil
      end
      function sessionRepository:getState(sessionId)
        return foundation.copy(persisted[sessionId]), nil
      end
      local repositoryCalls = 0
      local characterRepository = {
        create = function() repositoryCalls = repositoryCalls + 1 return nil end,
        getOwned = function() repositoryCalls = repositoryCalls + 1 return nil end
      }
      local function transition(candidate, target)
        local allowed = (candidate.state == 'ACTIVE' and target == 'UNLOADING_CHARACTER')
          or (candidate.state == 'UNLOADING_CHARACTER' and target == 'SELECTING_CHARACTER')
        if not allowed then return nil, foundation.error('INVALID_SESSION_TRANSITION', 'fixture') end
        candidate.state = target
        candidate.version = candidate.version + 1
        return candidate, nil
      end
      local characters = SynexCoreFactories.identityCharacters({
        platform = platform, foundation = foundation, database = {}, players = players,
        owners = registries.owners, messaging = { hooks = {}, events = {} },
        coreResource = 'synex_core', characterRepository = characterRepository,
        sessionRepository = sessionRepository,
        invokeOwned = function(entry, handler, ...) return foundation.safeCall(handler, ...) end,
        transition = transition,
        leases = { acquire = function() return {}, nil end, release = function() return true, nil end },
        instances = { bootId = function() return 'boot-a', nil end },
        instanceId = 'instance-a', pendingUnloadMaximum = 64
      })
      local unloaded, unloadError = characters:unload('session-a', 'fixture')
      assert(unloaded == nil and unloadError.code == 'SESSION_PERSISTENCE_PENDING')
      local pending = assert(players:getSession('session-a'))
      assert(pending.state == 'SELECTING_CHARACTER' and pending.characterId == nil
        and pending.persistencePending == true)
      local selected, selectError = characters:select('session-b', 'character-a')
      local created, createError = characters:create('session-a', {})
      local deleted, deleteError = characters:delete('session-a', 'character-a')
      assert(selected == nil and selectError.code == 'SESSION_PERSISTENCE_PENDING')
      assert(created == nil and createError.code == 'SESSION_PERSISTENCE_PENDING')
      assert(deleted == nil and deleteError.code == 'SESSION_PERSISTENCE_PENDING')
      assert(repositoryCalls == 0)
      local report = assert(characters:reconcileUnloads(1))
      local reconciled = assert(players:getSession('session-a'))
      assert(report.completed == 1 and report.pending == 0 and reconciled.persistencePending == nil)
      assert(reconciled.persistedVersion == reconciled.version)

      addSession(-3, 43, 'session-c', 'ACTIVE', 'character-c')
      persisted['session-c'] = { state = 'ACTIVE', characterId = 'character-c', version = 5 }
      failNext['session-c'] = true
      assert(characters:unload('session-c', 'fixture') == nil)
      players:removeSession('session-c')
      local abandoned = assert(characters:reconcileUnloads(1))
      local snapshot = characters:cacheSnapshot()
      assert(abandoned.abandoned == 1 and abandoned.pending == 0
        and snapshot.pendingSessionWrites == 0 and snapshot.pendingSessionWriteMaximum == 64)

      addSession(-4, 44, 'session-d', 'ACTIVE', 'character-d')
      addSession(-5, 45, 'session-e', 'ACTIVE', 'character-e')
      persisted['session-d'] = { state = 'ACTIVE', characterId = 'character-d', version = 5 }
      persisted['session-e'] = { state = 'ACTIVE', characterId = 'character-e', version = 5 }
      failNext['session-d'] = true
      failNext['session-e'] = true
      assert(characters:unload('session-d', 'fixture') == nil)
      assert(characters:unload('session-e', 'fixture') == nil)
      failAlways['session-d'] = true
      local blockedHead = assert(characters:reconcileUnloads(1))
      local rotated = assert(characters:reconcileUnloads(1))
      assert(blockedHead.deferred == 1 and rotated.completed == 1)
      assert(players:getSession('session-d').persistencePending == true)
      assert(players:getSession('session-e').persistencePending == nil)
      return table.concat({unloadError.code, report.completed, abandoned.abandoned,
        blockedHead.deferred, rotated.completed, repositoryCalls}, ':')
    `);
    assert.equal(result, 'SESSION_PERSISTENCE_PENDING:1:1:1:1:0');
  } finally {
    engine.global.close();
  }
});

test('recurring scheduler entries expose bounded worker health and recover after failures', async () => {
  const engine = await coreEngine(['foundation', 'registries', 'lifecycle']);
  try {
    const result = await engine.doString(`
      local now, callbacks, attempts = 1000, {}, 0
      local platform = {
        nowGame = function() return now end,
        random = function() return 1 end,
        print = function() end,
        jsonEncode = function() return '{}' end,
        setTimeout = function(delay, callback) callbacks[#callbacks + 1] = callback end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('worker-health')
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      local epoch = registries.owners:activate('synex_fixture')
      local lifecycle = SynexCoreFactories.lifecycle({
        platform = platform, foundation = foundation, owners = registries.owners
      })
      local schedulerHandler = setmetatable({ __cfx_functionReference = 'fixture-scheduler' }, {
        __metatable = 'protected-cfx-funcref',
        __call = function()
          attempts = attempts + 1
          now = now + 5
          if attempts <= 3 then return nil, { code = 'FIXTURE_FAILURE' } end
          return true, nil
        end
      })
      assert(lifecycle.scheduler:every(
        'synex_fixture', epoch, 100, schedulerHandler, { name = 'fixture.worker' }))
      for index = 1, 3 do now = now + 100 callbacks[index]() end
      local unhealthy = lifecycle.scheduler:snapshot()[1]
      assert(unhealthy.health == 'UNHEALTHY' and unhealthy.runs == 3 and unhealthy.lastError == 'FIXTURE_FAILURE')
      now = now + 100
      callbacks[4]()
      local recovered = lifecycle.scheduler:snapshot()[1]
      assert(recovered.health == 'HEALTHY' and recovered.runs == 4 and recovered.lastError == nil)
      return table.concat({unhealthy.health, recovered.health, recovered.durationMs}, ':')
    `);
    assert.equal(result, 'UNHEALTHY:HEALTHY:5');
  } finally {
    engine.global.close();
  }
});

test('scheduler bounds active work, shares one timer, and rolls back failed timer arms', async () => {
  const engine = await coreEngine(['foundation', 'registries', 'lifecycle']);
  try {
    const result = await engine.doString(`
      local callbacks, throwOnArm = {}, false
      local platform = {
        nowGame = function() return 1000 end,
        random = function() return 1 end,
        print = function() end,
        jsonEncode = function() return '{}' end,
        setTimeout = function(_, callback)
          if throwOnArm then error('timer adapter fixture secret') end
          callbacks[#callbacks + 1] = callback
        end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('scheduler-capacity')
      local registries = SynexCoreFactories.registries({
        foundation = foundation,
        maximumArtifactsPerOwner = 8,
        maximumArtifactsPerKind = 8
      })
      local epoch = registries.owners:activate('synex_fixture')
      local lifecycle = SynexCoreFactories.lifecycle({
        platform = platform,
        foundation = foundation,
        owners = registries.owners,
        maximumSchedules = 2,
        maximumSchedulesPerOwner = 2
      })

      local nanSchedule, nanError = lifecycle.scheduler:after(
        'synex_fixture', epoch, 0 / 0, function() end)
      local fractional, fractionalError = lifecycle.scheduler:after(
        'synex_fixture', epoch, 1.5, function() end)
      assert(nanSchedule == nil and nanError.code == 'INVALID_ARGUMENT')
      assert(fractional == nil and fractionalError.code == 'INVALID_ARGUMENT')

      local first = assert(lifecycle.scheduler:after(
        'synex_fixture', epoch, 86400000, function() end))
      local second = assert(lifecycle.scheduler:after(
        'synex_fixture', epoch, 86400000, function() end))
      local overflow, overflowError = lifecycle.scheduler:after(
        'synex_fixture', epoch, 86400000, function() end)
      assert(overflow == nil and overflowError.code == 'SCHEDULER_LIMIT')
      assert(lifecycle.scheduler:cancel('synex_fixture', first))
      assert(lifecycle.scheduler:cancel('synex_fixture', second))
      assert(lifecycle.scheduler:count() == 0)
      local retained = assert(lifecycle.scheduler:after(
        'synex_fixture', epoch, 86400000, function() end))
      assert(#callbacks == 1, 'schedule churn must not allocate more native timers')
      assert(lifecycle.scheduler:cancel('synex_fixture', retained))
      assert(lifecycle.scheduler:count() == 0)
      assert(registries.owners:list()[1].artifacts == 0)

      callbacks[1]()
      assert(lifecycle.scheduler:capacity().pendingTimers == 0)
      local reusable = assert(lifecycle.scheduler:after(
        'synex_fixture', epoch, 86400000, function() end))
      assert(lifecycle.scheduler:cancel('synex_fixture', reusable))
      callbacks[2]()

      local old = assert(lifecycle.scheduler:after(
        'synex_fixture', epoch, 86400000, function() end))
      local purge = registries.owners:purge('synex_fixture', epoch, 'fixture restart')
      assert(purge.cleaned == 1 and lifecycle.scheduler:count() == 0)
      local nextEpoch = registries.owners:activate('synex_fixture')
      local afterRestart = assert(lifecycle.scheduler:after(
        'synex_fixture', nextEpoch, 86400000, function() end))
      assert(#callbacks == 3, 'restart must reuse the already armed shared timer')
      assert(lifecycle.scheduler:cancel('synex_fixture', afterRestart))
      callbacks[3]()

      throwOnArm = true
      local failed, failedError = lifecycle.scheduler:after(
        'synex_fixture', nextEpoch, 100, function() end)
      assert(failed == nil and failedError.code == 'SCHEDULER_ARM_FAILED')
      assert(lifecycle.scheduler:count() == 0)
      local capacity = lifecycle.scheduler:capacity()
      assert(capacity.pendingTimers == 0)
      assert(registries.owners:list()[1].artifacts == 0)
      return table.concat({overflowError.code, failedError.code,
        capacity.schedules, capacity.pendingTimers}, ':')
    `);
    assert.equal(result, 'SCHEDULER_LIMIT:SCHEDULER_ARM_FAILED:0:0');
  } finally {
    engine.global.close();
  }
});

test('yielding scheduler handlers are isolated across owners', async () => {
  const engine = await coreEngine(['foundation', 'registries', 'lifecycle']);
  try {
    const result = await engine.doString(`
      local now, callbacks, threads = 1000, {}, {}
      local firstRuns, secondRuns = 0, 0
      local platform = {
        nowGame = function() return now end,
        random = function() return 1 end,
        print = function() end,
        jsonEncode = function() return '{}' end,
        setTimeout = function(_, callback) callbacks[#callbacks + 1] = callback end,
        createThread = function(handler)
          threads[#threads + 1] = coroutine.create(handler)
        end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('scheduler-isolation')
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      local firstEpoch = registries.owners:activate('synex_first')
      local secondEpoch = registries.owners:activate('synex_second')
      local lifecycle = SynexCoreFactories.lifecycle({
        platform = platform, foundation = foundation, owners = registries.owners
      })
      assert(lifecycle.scheduler:after('synex_first', firstEpoch, 50, function()
        coroutine.yield('fixture wait')
        firstRuns = firstRuns + 1
        return true
      end, { name = 'first.blocking' }))
      assert(lifecycle.scheduler:after('synex_second', secondEpoch, 50, function()
        secondRuns = secondRuns + 1
        return true
      end, { name = 'second.ready' }))
      assert(#callbacks == 1)
      now = 1050
      callbacks[1]()
      assert(#threads == 2, 'the pump must dispatch both due handlers without running either inline')
      local firstOk = coroutine.resume(threads[1])
      assert(firstOk and coroutine.status(threads[1]) == 'suspended')
      local secondOk, secondError = coroutine.resume(threads[2])
      assert(secondOk, tostring(secondError))
      assert(secondRuns == 1 and firstRuns == 0)
      local resumed, resumeError = coroutine.resume(threads[1])
      assert(resumed, tostring(resumeError))
      assert(firstRuns == 1 and lifecycle.scheduler:count() == 0)
      return table.concat({firstRuns, secondRuns, #threads}, ':')
    `);
    assert.equal(result, '1:1:2');
  } finally {
    engine.global.close();
  }
});

test('failed runtime gate blocks owner discovery and cached facade mutations', async () => {
  const engine = await coreEngine([
    'foundation', 'registries', 'lifecycle', 'runtime_gate', 'bootstrap_discovery', 'bootstrap_api',
  ]);
  try {
    const result = await engine.doString(`
      local discoveryReads, registrationMutations, timeoutMutations = 0, 0, 0
      local platform = {
        nowGame = function() return 1000 end,
        random = function() return 1 end,
        print = function() end,
        jsonEncode = function() return '{}' end,
        resourceState = function() return 'started' end,
        resourceMetadata = function()
          discoveryReads = discoveryReads + 1
          return 'synex.resource.json'
        end,
        loadResourceFile = function()
          discoveryReads = discoveryReads + 1
          return '{}'
        end,
        jsonDecode = function()
          return {
            critical = false, capabilities = { request = {} }, contracts = { provide = {}, consume = {} },
            events = { publish = {}, subscribe = {} },
            hooks = { register = {}, run = {} },
            services = { provide = {}, require = {}, optional = {} },
            dependencies = { required = {}, optional = {}, development = {} },
            migrations = {}, stateSnapshot = { supported = false, schemaVersion = 1 }
          }
        end,
        setTimeout = function()
          timeoutMutations = timeoutMutations + 1
        end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('failed-runtime-gate')
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      local lifecycle = SynexCoreFactories.lifecycle({
        platform = platform, foundation = foundation, owners = registries.owners
      })
      local runtimeGate = SynexCoreFactories.runtimeGate({ foundation = foundation })

      local manifests = {}
      local security = {
        capabilities = {
          registerManifest = function() return true, nil end,
          unregisterManifest = function() return true end,
          preflight = function() return {} end
        }
      }
      local stateService = {
        captureOwner = function() return {}, nil end,
        restoreOwner = function() return true, nil end
      }
      local discovery = SynexCoreFactories.bootstrapDiscovery({
        platform = platform, foundation = foundation,
        resourceManifest = { validate = function() return true, nil end },
        security = security, registries = registries, lifecycle = lifecycle,
        stateService = stateService, manifests = manifests, runtimeGate = runtimeGate
      })
      local facadeCache = {}
      local api = SynexCoreFactories.bootstrapApi({
        platform = platform, foundation = foundation, registries = registries,
        security = security, identity = {}, contractSystem = {},
        messaging = { events = { subscribe = function()
          registrationMutations = registrationMutations + 1
          return 'subscription-fixture', nil
        end } },
        coreResource = 'synex_core', runtime = {}, stateService = stateService,
        lifecycle = lifecycle, reliability = {}, sagaRuntime = {},
        facadeCache = facadeCache, runtimeGate = runtimeGate,
        ensureOwner = discovery.ensureOwner, defaultConfig = { retention = {} }
      })

      runtimeGate:open()
      local facade = assert(api.getAPIForCaller('synex_fixture', '^1.0.0'))
      local cached = assert(api.getAPIForCaller('synex_fixture', '^1.0.0'))
      assert(cached == facade and registries.owners:epoch('synex_fixture') == 1)
      assert(#registries.owners:list() == 1 and discoveryReads == 2)

      runtimeGate:fail()
      local owner, ownerError = discovery.ensureOwner('synex_missing')
      assert(owner == nil and ownerError.code == 'CORE_FAILED' and ownerError.retryable == false)
      assert(discoveryReads == 2 and registries.owners:epoch('synex_missing') == 0)
      assert(#registries.owners:list() == 1)

      local schedule, scheduleError = facade.Scheduler.after(100, function() end)
      local registration, registrationError = facade.Events.subscribe(
        'synex.fixture.event', function() end)
      assert(schedule == nil and scheduleError.code == 'CORE_FAILED')
      assert(registration == nil and registrationError.code == 'CORE_FAILED')
      assert(lifecycle.scheduler:count() == 0 and timeoutMutations == 0)
      assert(registrationMutations == 0 and registries.owners:pendingCount('synex_fixture', 1) == 0)
      return table.concat({ownerError.code, scheduleError.code, registrationError.code,
        discoveryReads, timeoutMutations, registrationMutations}, ':')
    `);
    assert.equal(result, 'CORE_FAILED:CORE_FAILED:CORE_FAILED:2:0:0');
  } finally {
    engine.global.close();
  }
});

test('live dependency validation requires running providers, real registration, and granted capabilities', async () => {
  const engine = await coreEngine([
    'foundation', 'registries', 'lifecycle', 'security', 'bootstrap_discovery',
  ]);
  try {
    const result = await engine.doString(`
      local states = {
        synex_provider = 'started', synex_consumer = 'started',
        synex_optional = 'started', synex_blocked = 'started'
      }
      local manifests = {
        synex_provider = {
          critical = true, capabilities = { request = {} },
          services = { provide = {'synex.fixture@1'}, require = {}, optional = {} }
        },
        synex_consumer = {
          critical = true, capabilities = { request = {'synex.fixture.read'} },
          services = { provide = {}, require = {'synex.fixture@1'}, optional = {} }
        },
        synex_optional = {
          critical = true, capabilities = { request = {} },
          services = { provide = {}, require = {}, optional = {'synex.fixture@1'} }
        },
        synex_blocked = {
          critical = true, capabilities = { request = {'synex.fixture.write'} },
          services = { provide = {}, require = {}, optional = {} }
        }
      }
      local names = {'synex_provider', 'synex_consumer', 'synex_optional', 'synex_blocked'}
      local platform = {
        nowGame = function() return 1000 end, random = function() return 1 end,
        print = function() end, jsonEncode = function() return '{}' end,
        jsonDecode = function(raw) return manifests[raw] end,
        numResources = function() return #names end,
        resourceByIndex = function(index) return names[index + 1] end,
        resourceMetadata = function(name, key)
          if key == 'synex_manifest' then return 'synex.resource.json' end
        end,
        loadResourceFile = function(name) return name end,
        resourceState = function(name) return states[name] or 'missing' end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      local lifecycle = SynexCoreFactories.lifecycle({
        platform = platform, foundation = foundation, owners = registries.owners
      })
      local security = SynexCoreFactories.security({
        platform = platform, foundation = foundation, coreResource = 'synex_core',
        policy = {
          default = { allow = {}, deny = {} },
          resources = {
            synex_consumer = { allow = {'synex.fixture.read'}, deny = {} },
            synex_blocked = { allow = {}, deny = {} }
          }
        }
      })
      local discovery = SynexCoreFactories.bootstrapDiscovery({
        platform = platform, foundation = foundation,
        runtimeGate = { requireAvailable = function() return true, nil end },
        resourceManifest = { validate = function(_, name, manifest)
          assert(name == manifest.name or manifest.name == nil)
          return true, nil
        end },
        security = security, registries = registries, lifecycle = lifecycle,
        stateService = { captureOwner = function() end, restoreOwner = function() end }
      })
      assert(discovery.discoverAll())
      local initial = discovery.validateActive()
      assert(#initial == 4)
      local sawOptional = false
      for _, finding in ipairs(initial) do
        if finding.consumer == 'synex_optional' then
          assert(finding.kind == 'dependency' and finding.severity == 'warning')
          sawOptional = true
        end
      end
      assert(sawOptional)
      lifecycle.dependencies:provide('synex_provider', 'synex.fixture', '1.0.0')
      local registered = discovery.validateActive()
      assert(#registered == 1 and registered[1].kind == 'capability'
        and registered[1].resource == 'synex_blocked' and registered[1].severity == 'error')
      assert(lifecycle.dependencies:setProviderHealth(
        'synex_provider', 'synex.fixture', '1.0.0', 'UNHEALTHY', 'CLOSED'))
      local unhealthy = discovery.validateActive()
      assert(#unhealthy == 4)
      assert(lifecycle.dependencies:setProviderHealth(
        'synex_provider', 'synex.fixture', '1.0.0', 'HEALTHY', 'OPEN'))
      local opened = discovery.validateActive()
      assert(#opened == 4)
      assert(lifecycle.dependencies:setProviderHealth(
        'synex_provider', 'synex.fixture', '1.0.0', 'HEALTHY', 'CLOSED'))
      assert(#discovery.validateActive() == 1)
      states.synex_provider = 'stopped'
      local stopped = discovery.validateActive()
      assert(#stopped == 3)
      local stoppedEnforced = discovery.validateActive(nil, true)
      local sawStoppedCritical = false
      for _, finding in ipairs(stoppedEnforced) do
        if finding.kind == 'resource' and finding.resource == 'synex_provider'
            and finding.state == 'stopped' and finding.severity == 'error' then
          sawStoppedCritical = true
        end
      end
      assert(#stoppedEnforced == 4 and sawStoppedCritical)
      states.synex_blocked = 'stopped'
      states.synex_provider = 'started'
      assert(#discovery.validateActive() == 0)
      local inactiveBlocked = discovery.validateActive(nil, true)
      assert(#inactiveBlocked == 1 and inactiveBlocked[1].kind == 'resource'
        and inactiveBlocked[1].resource == 'synex_blocked')
      lifecycle.dependencies:removeProvider('synex_provider')
      local missingRegistration = discovery.validateActive()
      assert(#missingRegistration == 3)
      return table.concat({
        #initial, #registered, #unhealthy, #opened, #stopped,
        #stoppedEnforced, #inactiveBlocked, #missingRegistration
      }, ':')
    `);
    assert.equal(result, '4:1:4:4:3:4:1:3');
  } finally {
    engine.global.close();
  }
});

test('resource dependency versions fail closed at runtime and optional metadata degrades to warnings', async () => {
  const engine = await coreEngine(['foundation', 'resource_manifest', 'bootstrap_discovery']);
  try {
    const result = await engine.doString(`
      local states = { synex_entities = 'started', synex_core = 'started', oxmysql = 'started' }
      local versions = { synex_core = '0.1.0', oxmysql = '2.14.1' }
      local duplicateVersions = {}
      local manifest = {
        critical = true,
        capabilities = { request = {} },
        services = { provide = {}, require = {}, optional = {} },
        dependencies = {
          required = {
            { name = 'synex_core', version = '>=0.1.0' },
            { name = 'oxmysql', version = '>=2.14.1 <3.0.0' }
          },
          optional = {}, development = {}
        }
      }
      local platform = {
        nowGame = function() return 1000 end, random = function() return 1 end,
        resourceState = function(name) return states[name] or 'missing' end,
        resourceMetadata = function(name, key, index)
          if key ~= 'version' then return nil end
          if index == 1 then return duplicateVersions[name] end
          return versions[name]
        end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      local resourceManifest = SynexCoreFactories.resourceManifest({ foundation = foundation })
      local discovery = SynexCoreFactories.bootstrapDiscovery({
        platform = platform, foundation = foundation, resourceManifest = resourceManifest,
        runtimeGate = { requireAvailable = function() return true, nil end },
        security = { capabilities = { preflight = function() return {} end } },
        registries = {},
        lifecycle = { dependencies = {
          validate = function() return {} end,
          snapshot = function() return { providers = {}, providerHealth = {} } end
        } },
        stateService = {}, manifests = { synex_entities = manifest }
      })

      assert(#discovery.validateActive() == 0)
      versions.oxmysql = '3.0.0'
      local incompatible = discovery.validateActive()
      assert(#incompatible == 1 and incompatible[1].dependency == 'oxmysql'
        and incompatible[1].code == 'DEPENDENCY_VERSION_INCOMPATIBLE'
        and incompatible[1].severity == 'error')
      manifest.critical = false
      local nonCritical = discovery.validateActive()
      assert(#nonCritical == 1 and nonCritical[1].code == 'DEPENDENCY_VERSION_INCOMPATIBLE'
        and nonCritical[1].severity == 'warning')
      manifest.critical = true
      versions.oxmysql = nil
      local missing = discovery.validateActive()
      assert(#missing == 1 and missing[1].code == 'DEPENDENCY_VERSION_METADATA_MISSING'
        and missing[1].severity == 'error')
      versions.oxmysql = 'v2.14.1'
      local invalid = discovery.validateActive()
      assert(#invalid == 1 and invalid[1].code == 'DEPENDENCY_VERSION_METADATA_INVALID'
        and invalid[1].severity == 'error')
      versions.oxmysql = '2.14.1'
      duplicateVersions.oxmysql = '2.14.2'
      local ambiguous = discovery.validateActive()
      assert(#ambiguous == 1 and ambiguous[1].code == 'DEPENDENCY_VERSION_METADATA_AMBIGUOUS'
        and ambiguous[1].severity == 'error')
      duplicateVersions.oxmysql = nil
      states.oxmysql = 'stopped'
      local unavailable = discovery.validateActive()
      assert(#unavailable == 1 and unavailable[1].code == 'DEPENDENCY_RESOURCE_UNAVAILABLE'
        and unavailable[1].severity == 'error')
      states.oxmysql = 'started'
      manifest.dependencies.optional = {{ name = 'synex_observer', version = '^1.0.0' }}
      local optional = discovery.validateActive()
      assert(#optional == 1 and optional[1].dependency == 'synex_observer'
        and optional[1].code == 'DEPENDENCY_RESOURCE_UNAVAILABLE'
        and optional[1].severity == 'warning')
      return table.concat({
        incompatible[1].code, missing[1].code, invalid[1].code,
        ambiguous[1].code, unavailable[1].code, optional[1].severity
      }, ':')
    `);
    assert.equal(
      result,
      'DEPENDENCY_VERSION_INCOMPATIBLE:DEPENDENCY_VERSION_METADATA_MISSING:'
        + 'DEPENDENCY_VERSION_METADATA_INVALID:DEPENDENCY_VERSION_METADATA_AMBIGUOUS:'
        + 'DEPENDENCY_RESOURCE_UNAVAILABLE:warning',
    );
  } finally {
    engine.global.close();
  }
});

test('dependency health refresh clears recovered registry findings without changing resource state', async () => {
  const engine = await coreEngine(['foundation', 'registries', 'lifecycle', 'bootstrap_restart', 'bootstrap_resource_events', 'bootstrap_lifecycle']);
  try {
    const result = await engine.doString(`
      local findings = {
        { kind = 'provider', resource = 'synex_provider', service = 'synex.fixture', severity = 'error' },
        { kind = 'resource-dependency', resource = 'synex_consumer', dependency = 'oxmysql', severity = 'warning' }
      }
      local platform = {
        nowGame = function() return 1000 end, random = function() return 1 end,
        print = function() end, jsonEncode = function() return '{}' end,
        resourceState = function() return 'started' end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      registries.owners:activate('synex_core')
      registries.resources:upsert('synex_core', {
        name = 'synex_core', critical = true, services = { provide = {'synex.runtime@1'} }
      }, 'started')
      registries.resources:upsert('synex_provider', {
        name = 'synex_provider', critical = true, services = { provide = {'synex.fixture@1'} }
      }, 'STARTED')
      registries.resources:upsert('synex_consumer', {
        name = 'synex_consumer', critical = false, services = { provide = {} }
      }, 'STARTED')
      local lifecycle = SynexCoreFactories.lifecycle({
        platform = platform, foundation = foundation, owners = registries.owners
      })
      for _, target in ipairs({
        'CONFIGURING', 'DATABASE_CONNECTING', 'MIGRATING', 'DISCOVERING_RESOURCES',
        'VALIDATING_CONTRACTS', 'VALIDATING_CAPABILITIES', 'STARTING_SERVICES', 'READY'
      }) do assert(lifecycle.core:transition(target, 'fixture')) end
      SynexCoreFactories.commands = function() return { bind = function() return true end } end
      local noop = function() return true end
      local runtime = {}
      SynexCoreFactories.bootstrapLifecycle({
        runtime = runtime, platform = platform, foundation = foundation,
        runtimeGate = { beginBoot = noop, open = noop, fail = noop, stop = noop },
        coreResource = 'synex_core', messaging = {}, identity = {}, reloadSnapshots = {},
        registries = registries, lifecycle = lifecycle, facadeCache = {}, defaultConfig = {},
        persistence = {}, manifests = { synex_provider = {}, synex_consumer = {} }, reliability = {},
        sagaRuntime = {}, retention = {}, security = {},
        api = {
          getAPIForCaller = noop, invokeForCaller = noop, guarded = noop,
          registerCoreContracts = noop, registerCoreServices = noop
        },
        discovery = {
          discoverResource = noop, invalidateResource = noop, discoverAll = noop,
          validateActive = function() return findings end,
          ensureOwner = noop, supportsStateHandoff = noop,
          captureStateHandoff = noop, restoreStateHandoff = noop
        }
      })
      local first, firstCritical = runtime:refreshDependencyHealth()
      local degraded = assert(registries.resources:get('synex_provider'))
      local dependencyDegraded = assert(registries.resources:get('synex_consumer'))
      local coreDegraded = assert(registries.resources:get('synex_core'))
      assert(#first == 2 and firstCritical == 1)
      assert(degraded.state == 'STARTED' and degraded.health.status == 'UNHEALTHY')
      assert(dependencyDegraded.state == 'STARTED' and dependencyDegraded.health.status == 'DEGRADED')
      assert(coreDegraded.state == 'STARTED' and coreDegraded.health.status == 'DEGRADED')
      assert(lifecycle.core:get() == 'DEGRADED')
      findings = {}
      local recovered, recoveredCritical = runtime:refreshDependencyHealth()
      local healthy = assert(registries.resources:get('synex_provider'))
      local dependencyHealthy = assert(registries.resources:get('synex_consumer'))
      lifecycle.core:setCriticalFoundationsValidated(true)
      local coreHealthy = assert(registries.resources:get('synex_core'))
      assert(#recovered == 0 and recoveredCritical == 0)
      assert(healthy.state == 'STARTED' and healthy.health.status == 'HEALTHY')
      assert(dependencyHealthy.state == 'STARTED' and dependencyHealthy.health.status == 'HEALTHY')
      assert(coreHealthy.state == 'STARTED' and coreHealthy.health.status == 'HEALTHY')
      assert(#healthy.health.reasons == 0 and lifecycle.core:get() == 'READY')
      lifecycle.core:setHealth('cluster', 'DEGRADED', 'fixture heartbeat failure')
      local dynamicallyDegraded = assert(registries.resources:get('synex_core'))
      assert(dynamicallyDegraded.health.status == 'DEGRADED')
      lifecycle.core:setHealth('cluster', 'HEALTHY')
      local dynamicallyRecovered = assert(registries.resources:get('synex_core'))
      assert(dynamicallyRecovered.health.status == 'HEALTHY')
      lifecycle.core:setCriticalFoundationsValidated(false)
      local admissionBlocked = assert(registries.resources:get('synex_core'))
      assert(admissionBlocked.health.status == 'DEGRADED')
      assert(admissionBlocked.health.reasons[1].component == 'player-admission')
      lifecycle.core:setCriticalFoundationsValidated(true)
      local admissionRecovered = assert(registries.resources:get('synex_core'))
      assert(admissionRecovered.health.status == 'HEALTHY')
      return table.concat({
        degraded.health.status, dependencyDegraded.health.status,
        healthy.health.status, dependencyHealthy.health.status, coreDegraded.health.status,
        coreHealthy.health.status, dynamicallyDegraded.health.status,
        dynamicallyRecovered.health.status, admissionBlocked.health.status,
        admissionRecovered.health.status, healthy.state
      }, ':')
    `);
    assert.equal(
      result,
      'UNHEALTHY:DEGRADED:HEALTHY:HEALTHY:DEGRADED:HEALTHY:DEGRADED:HEALTHY:DEGRADED:HEALTHY:STARTED',
    );
  } finally {
    engine.global.close();
  }
});

test('instance status synchronization clears a failed write after desired status reverses', async () => {
  const engine = await coreEngine(['foundation', 'registries', 'lifecycle', 'bootstrap_restart', 'bootstrap_resource_events', 'bootstrap_lifecycle']);
  try {
    const result = await engine.doString(`
      local criticalFinding, failNextReady = true, false
      local droppedPlayers, startupCalls = {}, {}
      local persistedStatus, statusWrites = 'starting', {}
      local platform = {
        nowGame = function() return 1000 end, random = function() return 1 end,
        print = function() end, jsonEncode = function() return '{}' end,
        resourceState = function() return 'started' end,
        resourceMetadata = function(name, key)
          if name == 'oxmysql' and key == 'version' then return '2.14.1' end
        end,
        setTimeout = function() end,
        getPlayers = function() return {'41', '42'} end,
        dropPlayer = function(source, reason)
          droppedPlayers[#droppedPlayers + 1] = { source = source, reason = reason }
          startupCalls[#startupCalls + 1] = 'drop:' .. source
        end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      registries.owners:activate('synex_core')
      registries.resources:upsert('synex_core', {
        name = 'synex_core', critical = true, services = { provide = {'synex.runtime@1'} }
      }, 'STARTED')
      local lifecycle = SynexCoreFactories.lifecycle({
        platform = platform, foundation = foundation, owners = registries.owners
      })
      local instances = {}
      function instances:terminateLocalSessions(reason)
        startupCalls[#startupCalls + 1] = 'terminate:' .. reason
        return true, nil
      end
      function instances:register()
        startupCalls[#startupCalls + 1] = 'register'
        persistedStatus = 'starting'
        return true, nil
      end
      function instances:sourceGenerationFloor()
        startupCalls[#startupCalls + 1] = 'source-generation:37'
        return 37, nil
      end
      function instances:setStatus(status)
        statusWrites[#statusWrites + 1] = status
        if status == 'ready' and failNextReady then
          failNextReady = false
          persistedStatus = status
          return nil, foundation.error('TRANSIENT_STATUS_WRITE', 'fixture transient failure')
        end
        persistedStatus = status
        return true, nil
      end
      local migrations = {
        bootstrap = function() return true, nil end,
        acquireLease = function() return true, nil end,
        apply = function() return true, nil end,
        releaseLease = function() return true, nil end
      }
      SynexCoreFactories.commands = function() return { bind = function() return true end } end
      local noop = function() return true, nil end
      local runtime = {}
      SynexCoreFactories.bootstrapLifecycle({
        runtime = runtime, platform = platform, foundation = foundation,
        runtimeGate = { beginBoot = noop, open = noop, fail = noop, stop = noop },
        coreResource = 'synex_core', registries = registries, lifecycle = lifecycle,
        reloadSnapshots = {}, facadeCache = {},
        manifests = { synex_core = { migrations = {} } }, reliability = {},
        sagaRuntime = {}, retention = {},
        messaging = { network = {} },
        identity = {
          connections = { heartbeat = noop },
          characters = { reconcileDeletions = noop, reconcileUnloads = noop }
        },
        security = { rbac = { hydrate = noop } },
        persistence = {
          database = { validateUtcSession = noop }, migrations = migrations, instances = instances
        },
        defaultConfig = {
          instanceName = 'Instance A', database = { minimumOxmysqlVersion = '2.14.1' },
          features = { durableEvents = false, sagas = false },
          retention = { audit = { mode = 'retain_forever' }, workerIntervalMs = 60000 },
          connections = { clusterHeartbeatMs = 10000 }
        },
        api = {
          getAPIForCaller = noop, invokeForCaller = noop, guarded = noop,
          registerCoreContracts = noop, registerCoreServices = noop
        },
        discovery = {
          discoverResource = noop, invalidateResource = noop, discoverAll = noop, ensureOwner = noop,
          supportsStateHandoff = noop, captureStateHandoff = noop, restoreStateHandoff = noop,
          validateActive = function(_, enforceCritical)
            if enforceCritical and criticalFinding then
              return {{ kind = 'resource', severity = 'error' }}
            end
            return {}
          end
        }
      })
      assert(runtime:start())
      assert(#droppedPlayers == 2)
      assert(droppedPlayers[1].source == 41 and droppedPlayers[2].source == 42)
      assert(droppedPlayers[1].reason == 'Synex Core restarted. Please reconnect.')
      assert(startupCalls[1] == 'drop:41' and startupCalls[2] == 'drop:42')
      assert(startupCalls[3] == 'register' and startupCalls[4] == 'terminate:synex_core restarted'
        and startupCalls[5] == 'source-generation:37')
      assert(lifecycle.core:get() == 'DEGRADED' and persistedStatus == 'degraded')

      criticalFinding, failNextReady = false, true
      local _, _, firstError = runtime:refreshDependencyHealth()
      local failedSnapshot = lifecycle.core:snapshot()
      assert(firstError and firstError.code == 'TRANSIENT_STATUS_WRITE')
      assert(persistedStatus == 'ready' and failedSnapshot.state == 'READY')
      assert(failedSnapshot.reasons['instance-status'] ~= nil)
      assert(failedSnapshot.playerAdmission == false)

      criticalFinding = true
      local _, _, reversedError = runtime:refreshDependencyHealth()
      local reversedSnapshot = lifecycle.core:snapshot()
      assert(reversedError == nil and persistedStatus == 'degraded')
      assert(reversedSnapshot.state == 'DEGRADED')
      assert(reversedSnapshot.reasons['instance-status'] == nil)
      assert(reversedSnapshot.reasons['runtime-dependencies'] ~= nil)
      assert(reversedSnapshot.playerAdmission == false)
      assert(#statusWrites == 3 and statusWrites[3] == 'degraded',
        'unexpected writes before recovery: ' .. table.concat(statusWrites, ':'))

      criticalFinding = false
      local _, _, recoveredError = runtime:refreshDependencyHealth()
      local recoveredSnapshot = lifecycle.core:snapshot()
      assert(recoveredError == nil and persistedStatus == 'ready')
      assert(recoveredSnapshot.state == 'READY')
      assert(recoveredSnapshot.reasons['instance-status'] == nil)
      assert(recoveredSnapshot.playerAdmission == true)
      assert(statusWrites[1] == 'degraded')
      assert(statusWrites[2] == 'ready' and statusWrites[4] == 'ready')
      return table.concat({
        statusWrites[1], statusWrites[2], statusWrites[3], statusWrites[4],
        failedSnapshot.playerAdmission and 'open' or 'blocked',
        reversedSnapshot.playerAdmission and 'open' or 'blocked',
        recoveredSnapshot.playerAdmission and 'open' or 'blocked'
      }, ':')
    `);
    assert.equal(result, 'degraded:ready:degraded:ready:blocked:blocked:open');
  } finally {
    engine.global.close();
  }
});

test('capability delegation is bridge-granted, target-declared, and limited to active resources', async () => {
  const engine = await coreEngine(['foundation', 'security', 'bootstrap_api']);
  try {
    const result = await engine.doString(`
      local states = { synex_bridge = 'started', synex_consumer = 'started', synex_attacker = 'started' }
      local platform = {
        nowGame = function() return 1000 end, random = function() return 1 end,
        print = function() end, jsonEncode = function() return '{}' end,
        invokingResource = function() return nil end,
        resourceState = function(name) return states[name] or 'missing' end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('delegate-test')
      local owners = {
        isCurrent = function(_, resource, epoch) return epoch == 1 and states[resource] == 'started' end,
        beginOperation = function() return 'operation-a', nil end,
        finishOperation = function() return true end
      }
      local security = SynexCoreFactories.security({
        platform = platform, foundation = foundation, coreResource = 'synex_core',
        policy = {
          default = { allow = {}, deny = {} },
          resources = {
            synex_bridge = { allow = {'synex.capabilities.delegate'}, deny = {} },
            synex_consumer = { allow = {'synex.compat.qb.read'}, deny = {} },
            synex_attacker = { allow = {}, deny = {} }
          }
        }
      })
      security.capabilities:registerManifest('synex_bridge', {
        capabilities = { request = {'synex.capabilities.delegate'} }
      })
      security.capabilities:registerManifest('synex_consumer', {
        capabilities = { request = {'synex.compat.qb.read'} }
      })
      security.capabilities:registerManifest('synex_attacker', {
        capabilities = { request = {'synex.capabilities.delegate'} }
      })
      local api = SynexCoreFactories.bootstrapApi({
        platform = platform, foundation = foundation, registries = { owners = owners },
        runtimeGate = { requireAvailable = function() return true, nil end },
        security = security, identity = {}, contractSystem = {}, messaging = {},
        coreResource = 'synex_core', runtime = {}, stateService = {}, lifecycle = {},
        reliability = {}, sagaRuntime = {}, facadeCache = {}, defaultConfig = { retention = {} },
        ensureOwner = function(resource)
          if states[resource] ~= 'started' then return nil, foundation.error('RESOURCE_NOT_STARTED', 'stopped') end
          return 1, nil
        end
      })
      local bridge = assert(api.getAPIForCaller('synex_bridge', '^1.0.0'))
      assert(bridge.Capabilities.checkResource('synex_consumer', 'synex.compat.qb.read', 'GetPlayerData'))
      local malformed, malformedError = bridge.Capabilities.checkResource('../consumer', 'synex.compat.qb.read')
      assert(malformed == nil and malformedError.code == 'INVALID_DELEGATION_TARGET')
      states.synex_consumer = 'stopped'
      local stopped, stoppedError = bridge.Capabilities.checkResource(
        'synex_consumer', 'synex.compat.qb.read', 'GetPlayerData')
      assert(stopped == nil and stoppedError.code == 'DELEGATION_TARGET_UNAVAILABLE')
      local attacker = assert(api.getAPIForCaller('synex_attacker', '^1.0.0'))
      local denied, deniedError = attacker.Capabilities.checkResource(
        'synex_bridge', 'synex.capabilities.delegate', 'impersonate')
      assert(denied == nil and deniedError.code == 'CAPABILITY_DENIED')
      return table.concat({malformedError.code, stoppedError.code, deniedError.code}, ':')
    `);
    assert.equal(result,
      'INVALID_DELEGATION_TARGET:DELEGATION_TARGET_UNAVAILABLE:CAPABILITY_DENIED');
  } finally {
    engine.global.close();
  }
});

test('control diagnostic search crosses its declared and granted capability gateway', async () => {
  const [descriptorSource, policySource] = await Promise.all([
    readFile(path.join(root, 'resources/synex_control/synex.resource.json'), 'utf8'),
    readFile(path.join(root, 'core/synex_core/config/capabilities.json'), 'utf8'),
  ]);
  const descriptor = JSON.parse(descriptorSource) as {
    capabilities: { request: string[] };
  };
  const policy = JSON.parse(policySource) as {
    default: { allow: string[]; deny: string[] };
    resources: { synex_control: { allow: string[]; deny: string[] } };
  };
  const luaList = (values: string[]): string =>
    `{${values.map((value) => JSON.stringify(value)).join(',')}}`;
  const engine = await coreEngine(['foundation', 'security', 'bootstrap_api']);
  try {
    const result = await engine.doString(`
      local platform = {
        nowGame = function() return 1000 end,
        random = function() return 1 end,
        print = function() end,
        jsonEncode = function() return '{}' end,
        invokingResource = function() return nil end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('control-search-test')
      local owners = {
        isCurrent = function(_, resource, epoch)
          return resource == 'synex_control' and epoch == 1
        end,
        beginOperation = function() return 'operation-control-search', nil end,
        finishOperation = function() return true end
      }
      local security = SynexCoreFactories.security({
        platform = platform,
        foundation = foundation,
        coreResource = 'synex_core',
        policy = {
          default = {
            allow = ${luaList(policy.default.allow)},
            deny = ${luaList(policy.default.deny)}
          },
          resources = {
            synex_control = {
              allow = ${luaList(policy.resources.synex_control.allow)},
              deny = ${luaList(policy.resources.synex_control.deny)}
            }
          }
        }
      })
      security.capabilities:registerManifest('synex_control', {
        capabilities = { request = ${luaList(descriptor.capabilities.request)} }
      })
      local searches = 0
      local api = SynexCoreFactories.bootstrapApi({
        platform = platform,
        foundation = foundation,
        runtimeGate = { requireAvailable = function() return true, nil end },
        registries = { owners = owners },
        security = security,
        identity = {},
        contractSystem = {},
        messaging = {},
        coreResource = 'synex_core',
        runtime = {},
        stateService = {},
        lifecycle = {},
        reliability = {
          audit = {
            search = function(_, request)
              searches = searches + 1
              return { kind = request.kind, value = request.value }, nil
            end
          }
        },
        sagaRuntime = {},
        facadeCache = {},
        defaultConfig = { retention = {} },
        ensureOwner = function(resource)
          if resource == 'synex_control' then return 1, nil end
          return nil, foundation.error('RESOURCE_NOT_STARTED', 'stopped')
        end
      })
      local control = assert(api.getAPIForCaller('synex_control', '^1.0.0'))
      local value, searchError = control.Diagnostics.search({
        kind = 'trace', value = 'trace-control-search'
      })
      assert(searchError == nil, searchError and searchError.code or 'search failed')
      assert(value ~= nil)
      assert(searches == 1)
      return value.kind .. ':' .. value.value
    `);
    assert.equal(result, 'trace:trace-control-search');
  } finally {
    engine.global.close();
  }
});

test('queue admission preserves reserved slots for ACE staff and maintenance fails closed', async () => {
  const engine = await coreEngine([
    'foundation', 'registries', 'identity_connection_replacement',
    'identity_connection_claims', 'identity_connection_authority', 'identity_connection_ingress',
    'identity_connection_terminals',
    'identity_connection_join',
    'identity_connection_connecting', 'identity_connection_heartbeat',
    'identity_connection_maintenance', 'identity_connections',
  ]);
  try {
    const result = await engine.doString(`
      local now, completions, leaseNames = 1000, {}, {}
      local staff, admission = false, false
      local platform = {
        nowGame = function() return now end,
        random = function() return 1 end,
        print = function() end,
        jsonEncode = function() return '{}' end,
        getPlayerIdentifiers = function(source) return {'license:' .. tostring(source)} end,
        isPlayerAceAllowed = function(source, ace) return staff and source == -3 and ace == 'synex.queue.staff' end,
        defer = function() end,
        wait = function(delay) now = now + delay end,
        dropPlayer = function() end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('queue-test')
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      local players, owners = registries.players, registries.owners
      owners:activate('synex_core')
      assert(players:createPending(-1, { sessionId = 'occupied' }))
      assert(players:bindJoined(-1, 11, {
        id = 'occupied', userId = 'existing-user', state = 'SELECTING_CHARACTER', version = 1
      }))
      local config = {
        duplicatePolicy = 'allow', allowlistRequired = false, queueEnabled = false,
        pendingTtlMs = 120000, gateTimeoutMs = 10000, clusterSessionLeaseSeconds = 45,
        maximumActiveSessions = 2, maximumQueued = 4, queueReservedSlots = 1,
        queueStaffAce = 'synex.queue.staff', maintenanceMode = false
      }
      local leases = {
        acquire = function(_, name, owner, ttl)
          leaseNames[#leaseNames + 1] = name
          return { name = name, owner = owner, fencingToken = 1, ttlSeconds = ttl }, nil
        end,
        release = function() return true, nil end,
        renew = function() return true, nil end
      }
      local instances = {
        bootId = function() return 'boot-a', nil end,
        requestRemoteKicks = function() return 0, nil end,
        hasOpenUserSessions = function() return false, nil end,
        touchSessions = function() return true, nil end,
        heartbeat = function() return {}, nil end,
        pendingLocalControls = function() return {}, nil end,
        completeControl = function() return true, nil end
      }
      local connection = SynexCoreFactories.identityConnections({
        platform = platform, foundation = foundation, players = players, owners = owners,
        lifecycle = { core = {
          canAdmitPlayers = function() return admission end,
          setHealth = function() end
        } },
        messaging = { network = { purgeSource = function() end } }, config = config,
        instanceId = 'instance-a', coreResource = 'synex_core', leases = leases, instances = instances,
        rateLimiter = { consume = function() return true, nil end, purge = function() end },
        sha256 = function(value)
          local hash = 2166136261
          for index = 1, #value do hash = ((hash ~ value:byte(index)) * 16777619) & 0xffffffff end
          return string.rep(('%08x'):format(hash), 8)
        end,
        characters = {}, userRepository = { authenticate = function(_, identifiers)
          return { id = identifiers[1]:gsub('[^A-Za-z0-9_-]', '_'), status = 'active' }, nil
        end },
        sessionRepository = {}, accessRepository = { check = function() return true, nil end },
        invokeOwned = function() return true, true, nil end,
        normalizeIdentifiers = function(values) return {{ type = 'license', value = values[1] }} end,
        sessionTransitions = {}, transition = function() return true, nil end
      })
      local function deferrals(source)
        return {
          defer = function() end, update = function() end,
          done = function(reason) completions[source] = reason == nil and '<accepted>' or reason end
        }
      end
      connection:handleConnecting(-5, 'NotReady', deferrals(-5))
      assert(completions[-5]:find('[CORE_NOT_READY]', 1, true) and players:getPending(-5) == nil)
      admission = true
      connection:handleConnecting(-2, 'Ordinary', deferrals(-2))
      assert(completions[-2]:find('active session limit', 1, true))
      staff = true
      connection:handleConnecting(-3, 'Staff', deferrals(-3))
      assert(completions[-3] == '<accepted>' and players:getPending(-3).staff == true)
      assert(leaseNames[1]:match('^admission:')
        and leaseNames[2]:match('^session:') and leaseNames[2]:find(':sessi_', 1, true))
      config.maintenanceMode = true
      staff = false
      connection:handleConnecting(-4, 'Maintenance', deferrals(-4))
      assert(completions[-4]:find('maintenance mode', 1, true))
      local snapshot = connection:snapshot()
      assert(snapshot.reservedSlots == 1 and snapshot.rejected == 1 and snapshot.maintenance)
      return table.concat({snapshot.rejected, snapshot.reservedSlots, #leaseNames}, ':')
    `);
    assert.equal(result, '1:1:2');
  } finally {
    engine.global.close();
  }
});

test('disconnect close failure retains capacity and recovers the exact durable authority', async () => {
  const engine = await coreEngine([
    'foundation', 'registries', 'identity_connection_replacement',
    'identity_connection_claims', 'identity_connection_authority', 'identity_connection_ingress',
    'identity_connection_terminals',
    'identity_connection_join',
    'identity_connection_connecting', 'identity_connection_heartbeat',
    'identity_connection_maintenance', 'identity_connections',
  ]);
  try {
    const result = await engine.doString(`
      local now, closeAttempts, purges, releases = 1000, 0, 0, 0
      local platform = {
        nowGame = function() return now end, random = function() return 1 end,
        print = function() end, jsonEncode = function() return '{}' end,
        wait = function(delay) now = now + delay end, dropPlayer = function() end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('disconnect-test')
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      local players, owners = registries.players, registries.owners
      owners:activate('synex_core')
      assert(players:createPending(-1, { sessionId = 'session-fixture' }))
      assert(players:bindJoined(-1, 42, {
        id = 'session-fixture', userId = 'user-fixture', state = 'ACTIVE', version = 1,
        clusterLease = { name = 'session:user-fixture', owner = 'instance-a:session-fixture', fencingToken = 1, ttlSeconds = 45 },
        clusterLeaseDeadlineAt = 26000, authorityDeadlineAt = 26000
      }))
      local lifecycleHealth = nil
      local connection = SynexCoreFactories.identityConnections({
        platform = platform, foundation = foundation, players = players, owners = owners,
        lifecycle = { core = {
          canAdmitPlayers = function() return true end,
          setHealth = function(_, _, status) lifecycleHealth = status end
        } },
        messaging = { network = { purgeSource = function() purges = purges + 1 error('purge failed') end } },
        config = { duplicatePolicy = 'deny_new', clusterSessionLeaseSeconds = 45, queueReconnectGraceMs = 60000 },
        instanceId = 'instance-a', coreResource = 'synex_core',
        rateLimiter = { consume = function() return true, nil end, purge = function() end },
        sha256 = function(value)
          local hash = 2166136261
          for index = 1, #value do hash = ((hash ~ value:byte(index)) * 16777619) & 0xffffffff end
          return string.rep(('%08x'):format(hash), 8)
        end,
        leases = { release = function()
          releases = releases + 1
          return true, nil
        end },
        instances = { bootId = function() return 'boot-a', nil end },
        characters = { unload = function() return nil, { code = 'UNLOAD_FAILED' } end },
        userRepository = {}, accessRepository = {},
        sessionRepository = { close = function(_, candidate)
          closeAttempts = closeAttempts + 1
          assert(candidate.id == 'session-fixture' and candidate.userId == 'user-fixture')
          assert(candidate.persistedSource == nil or candidate.persistedSource == 42)
          if closeAttempts <= 2 then return nil, { code = 'CLOSE_FAILED' } end
          return true, nil
        end },
        invokeOwned = function() end, normalizeIdentifiers = function() return {} end,
        sessionTransitions = { ACTIVE = { DISCONNECTING = true } },
        transition = function(session, target) session.state = target return true, nil end
      })
      local report = connection:handleDropped(42, 'fixture')
      assert(report.closed == false and #report.failures >= 3)
      local retained = assert(players:getSession('session-fixture'))
      assert(retained.source == nil and players:getBySource(42) == nil)
      assert(closeAttempts == 2 and purges == 1 and releases == 0)
      assert(connection:snapshot().activeSessions == 1)
      assert(connection:snapshot().reconnectGraceEntries == 0)
      local reconciled = assert(connection:reconcileClosures(1))
      assert(reconciled.inspected == 1 and reconciled.closed == 1 and reconciled.pending == 0)
      assert(players:getSession('session-fixture') == nil and releases == 1)
      assert(lifecycleHealth == 'DEGRADED' and connection:snapshot().reconnectGraceEntries == 1)
      return table.concat({#report.failures, closeAttempts, purges, releases, lifecycleHealth}, ':')
    `);
    assert.match(String(result), /^\d+:3:1:1:DEGRADED$/u);
  } finally {
    engine.global.close();
  }
});

test('diagnostic audit search is bounded, exact, and redacts unsafe references', async () => {
  const engine = await coreEngine(['foundation', 'reliability']);
  try {
    const result = await engine.doString(`
      local capturedSql, capturedParameters
      local platform = {
        nowGame = function() return 1000 end,
        random = function() return 1 end,
        print = function() end,
        jsonEncode = function() return '{}' end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('audit-search')
      local database = {}
      function database:query(sql, parameters)
        capturedSql, capturedParameters = sql, parameters
        return {
          {
            event_id = 'event-1', occurred_at = '2026-08-22 12:00:00',
            actor_type = 'resource', actor_id = 'synex_fixture', action = 'fixture.read',
            target_type = 'character', target_id = 'character-fixture', trace_id = 'trace-1'
          },
          {
            event_id = 'event-2', occurred_at = '2026-08-22 11:59:00',
            actor_type = 'user', actor_id = 'license:private', action = 'fixture.change',
            target_type = 'identifier', target_id = 'license:private', trace_id = 'trace-2'
          },
          {
            event_id = 'event-3', occurred_at = '2026-08-22 11:58:00',
            actor_type = 'system', actor_id = 'synex_core', action = 'fixture.old',
            target_type = 'resource', target_id = 'synex_fixture', trace_id = 'trace-3'
          }
        }, nil
      end
      local reliability = SynexCoreFactories.reliability({
        foundation = foundation, database = database, platform = platform,
        instanceId = 'instance-a', features = {}, sha256 = function() return 'hash' end
      })
      local search = assert(reliability.audit:search({
        kind = 'resource', value = 'synex_fixture', limit = 2
      }))
      assert(search.kind == 'resource' and search.limit == 2 and search.truncated == true)
      assert(#search.entries == 2 and search.entries[1].actor.reference == 'synex_fixture')
      assert(search.entries[2].actor.reference == '[redacted]')
      assert(search.entries[2].target.reference == '[redacted]' and search.entries[2].masked == true)
      assert(capturedSql:find("actor_type", 1, true) and capturedSql:find("target_type", 1, true))
      assert(capturedParameters[1] == 'synex_fixture' and capturedParameters[2] == 'synex_fixture')
      assert(capturedParameters[3] == 3)
      local invalid, invalidError = reliability.audit:search({
        kind = 'resource', value = 'synex_fixture', limit = 65
      })
      assert(invalid == nil and invalidError.code == 'INVALID_AUDIT_SEARCH')
      local unknown, unknownError = reliability.audit:search({
        kind = 'resource', value = 'synex_fixture', extra = true
      })
      assert(unknown == nil and unknownError.code == 'INVALID_AUDIT_SEARCH')
      return table.concat({search.kind, #search.entries, tostring(search.truncated)}, ':')
    `);
    assert.equal(result, 'resource:2:true');
  } finally {
    engine.global.close();
  }
});

test('runtime doctor reports unknown resource health, bounded pending age, and oxmysql isolation config', async () => {
  const engine = await coreEngine(['foundation', 'registries', 'bootstrap_diagnostics']);
  try {
    const result = await engine.doString(`
      local now, isolation = 1000, '2'
      local lifecycleReasons, playerAdmission = {}, true
      local platform = {
        nowGame = function() return now end, random = function() return 1 end,
        resourceMetadata = function(name, key)
          if name == 'oxmysql' and key == 'version' then return '2.14.1' end
        end,
        getConvar = function(name, fallback)
          if name == 'mysql_transaction_isolation_level' then return isolation end
          return fallback
        end,
        print = function() end, jsonEncode = function() return '{}' end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      registries.resources:upsert('synex_core', { version = '0.1.0', critical = true }, 'STARTED')
      assert(registries.players:createPending(-1, { sessionId = 'session-pending', expiresAt = 1050 }))
      now = 700001
      local runtime = {}
      SynexCoreFactories.bootstrapDiagnostics({
        runtime = runtime, reloadSnapshots = {},
        defaultConfig = {
          instanceId = 'instance-a', environment = 'development', features = {},
          database = { minimumOxmysqlVersion = '2.14.1' }
        },
        lifecycle = {
          core = { snapshot = function() return {
            state = 'READY', operational = true,
            playerAdmission = playerAdmission, reasons = lifecycleReasons
          } end },
          dependencies = { snapshot = function() return {} end, validate = function() return {} end },
          scheduler = { snapshot = function() return {} end, count = function() return 0 end }
        },
        registries = registries,
        messaging = {
          services = { snapshot = function() return {} end },
          network = { snapshot = function() return {} end },
          events = { snapshot = function() return {} end },
          hooks = { snapshot = function() return {} end },
          deprecations = { snapshot = function() return {} end }
        },
        stateService = { snapshot = function() return {} end }, foundation = foundation,
        persistence = {
          database = {
            scalar = function(_, sql)
              if sql:find('COUNT', 1, true) then return 0, nil end
              return 1, nil
            end,
            validateUtcSession = function() return true, nil end
          },
          instances = { snapshot = function() return { healthy = 1, stale = 0, total = 1 } end },
          migrations = { snapshot = function() return { resources = {}, totals = {} }, nil end },
          rbac = { summary = function() return { roles = 1, activeAssignments = 0 }, nil end }
        },
        platform = platform,
        contractSystem = { registry = { list = function() return {{ name = 'synex.runtime.status' }} end } },
        security = {
          rbac = { snapshot = function() return { hydrated = true, persistent = true, cachedSubjects = 0 } end },
          capabilities = { snapshot = function() return {} end }
        },
        identity = {
          connections = { snapshot = function() return {
            queued = 0, maximumQueued = 128, duplicatePolicy = 'deny_new'
          } end },
          characters = { cacheSnapshot = function() return {} end }
        },
        sagaRuntime = { snapshot = function() return { handlers = {}, persisted = { available = true, total = 0 } } end }
      })
      local function check(report, name)
        for _, entry in ipairs(report.checks) do if entry.name == name then return entry end end
      end
      local unknown = assert(runtime:doctor())
      local unknownHealth = assert(check(unknown, 'resource-health'))
      local pending = assert(check(unknown, 'connection-queue'))
      local configured = assert(check(unknown, 'database-transaction-isolation'))
      assert(unknown.status == 'WARN' and unknownHealth.status == 'WARN')
      assert(unknownHealth.detail:find('1 unknown', 1, true))
      assert(pending.status == 'WARN' and pending.detail:find('oldest=600000ms+', 1, true))
      assert(configured.status == 'PASS' and configured.detail:find('READ COMMITTED', 1, true))

      registries.players:removePending(-1)
      assert(registries.resources:setState('synex_core', 'STARTED', { status = 'HEALTHY', reasons = {} }))
      local healthy = assert(runtime:doctor())
      assert(healthy.status == 'PASS' and check(healthy, 'resource-health').status == 'PASS')
      playerAdmission = false
      lifecycleReasons = { cluster = { status = 'DEGRADED', reason = 'fixture' } }
      local blocked = assert(runtime:doctor())
      assert(blocked.status == 'WARN' and check(blocked, 'lifecycle').status == 'WARN')
      isolation = '1'
      local invalid = assert(runtime:doctor())
      assert(invalid.status == 'FAIL' and check(invalid, 'database-transaction-isolation').status == 'FAIL')
      return table.concat({unknown.status, pending.status, healthy.status, blocked.status, invalid.status}, ':')
    `);
    assert.equal(result, 'WARN:WARN:PASS:WARN:FAIL');
  } finally {
    engine.global.close();
  }
});

test('operator command registry is console-only, typed, bounded, and service-backed', async () => {
  const engine = await coreEngine(['foundation', 'commands']);
  try {
    const result = await engine.doString(`
      local registered, emitted, printed, serviceCalls, auditCalls = {}, {}, {}, 0, 0
      local restartPreparations = 0
      local resourceStates = { synex_accounts = 'started', synex_entities = 'started' }
      local platform = {
        nowGame = function() return 1000 end, random = function() return 1 end,
        print = function(line)
          if type(line) == 'string' and line:sub(1, 7) == '[synex]' then printed[#printed + 1] = line end
        end,
        jsonEncode = function(value) emitted[#emitted + 1] = value return '{}' end,
        resourceState = function(name)
          if resourceStates[name] == false then return nil end
          return resourceStates[name] or 'missing'
        end,
        resourceMetadata = function(name, key)
          if name == 'synex_core' and key == 'version' then return '0.1.0' end
        end,
        registerCommand = function(name, handler, restricted)
          registered[name] = { handler = handler, restricted = restricted }
        end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('commands-test')
      local owners = {
        epoch = function() return 7 end,
        isCurrent = function(_, resource, epoch) return resource == 'synex_core' and epoch == 7 end
      }
      local commands = SynexCoreFactories.commands({
        platform = platform, foundation = foundation, coreResource = 'synex_core',
        runtime = {
          doctor = function() return {
            status = 'PASS', checks = {
              { name = 'database', status = 'PASS' },
              { name = 'database-utc', status = 'PASS' },
              { name = 'database-transaction-isolation', status = 'PASS' }
            }
          }, nil end,
          prepareRestart = function()
            restartPreparations = restartPreparations + 1
            return { state = 'prepared', restartCommand = 'restart synex_core' }, nil
          end
        },
        lifecycle = {
          core = { snapshot = function() return { state = 'READY', operational = true } end },
          scheduler = { snapshot = function() return {{ health = 'HEALTHY' }} end }
        },
        registries = {
          owners = owners,
          resources = { list = function() return {{
            name = 'synex_fixture', state = 'STARTED', epoch = 1,
            manifest = { version = '1.0.0' }, health = { status = 'HEALTHY' }
          }} end, summary = function() return {
            total = 1, healthy = 1, degraded = 0, unhealthy = 0, unknown = 0
          } end },
          players = { summary = function() return {
            activeSessions = 0, pendingConnections = 0,
            oldestPendingAgeMs = 600000, pendingAgeCapped = true,
            expiredPendingConnections = 0
          } end }
        },
        identity = { connections = { snapshot = function() return { queued = 0, maximumQueued = 128 } end } },
        persistence = {
          instances = { snapshot = function() return { total = 1, healthy = 1, stale = 0 } end },
          migrations = { snapshot = function() return {
            resources = {}, totals = { defined = 10, applied = 10, applying = 0, failed = 0 }, truncated = false
          }, nil end },
          rbac = { summary = function() return { roles = 1, activeAssignments = 0 }, nil end }
        },
        reliability = { audit = { search = function(_, request)
          auditCalls = auditCalls + 1
          return { kind = request.kind, entries = {}, limit = request.limit, truncated = false }, nil
        end } },
        messaging = { services = { call = function(_, caller, epoch, name, range, method, request)
          serviceCalls = serviceCalls + 1
          assert(caller == 'synex_core' and epoch == 7 and range == '^1.0.0' and next(request) == nil)
          return { service = name, method = method }, nil
        end } },
        security = {
          rbac = { snapshot = function() return { persistent = true, hydrated = true } end },
          capabilities = { snapshot = function() return {
            synex_fixture = { requested = { ['synex.fixture.read'] = true }, policy = {
              allow = {'synex.fixture.read'}, deny = {}
            } }
          } end }
        }
      })
      assert(commands:bind())
      assert(registered.synex.restricted and registered.synex_status.restricted and registered.synex_doctor.restricted)
      local denied, deniedError = commands:dispatch(42, {'status'})
      assert(denied == nil and deniedError.code == 'CONSOLE_ONLY')
      local invalid, invalidError = commands:dispatch(0, {'trace', 'resource', 'synex_fixture', '65'})
      assert(invalid == nil and invalidError.code == 'INVALID_ARGUMENT' and auditCalls == 0)
      local trace = assert(commands:dispatch(0, {'trace', 'resource', 'synex_fixture', '8'}))
      assert(trace.kind == 'resource' and trace.limit == 8 and auditCalls == 1)
      local ledger = assert(commands:dispatch(0, {'ledger'}))
      local entities = assert(commands:dispatch(0, {'entities'}))
      assert(ledger.available and ledger.summary.service == 'synex.accounts')
      assert(entities.available and entities.summary.service == 'synex.entities')
      assert(ledger.status == 'HEALTHY' and entities.status == 'HEALTHY')
      resourceStates.synex_accounts = 'missing'
      local notInstalled = assert(commands:dispatch(0, {'ledger'}))
      assert(notInstalled.available == false and notInstalled.status == 'NOT_INSTALLED' and serviceCalls == 2)
      resourceStates.synex_accounts = false
      local unknownState = assert(commands:dispatch(0, {'ledger'}))
      assert(unknownState.available == false and unknownState.status == 'DEGRADED')
      assert(unknownState.error.code == 'RESOURCE_STATE_UNAVAILABLE' and serviceCalls == 2)
      local overview = assert(commands:dispatch(0, {'overview'}))
      assert(overview.status == 'PASS' and #overview.lines == 8 and #printed == 8)
      assert(printed[1]:find('lifecycle READY', 1, true))
      assert(printed[4]:find('oldest pending 600000ms+', 1, true))
      local prepared = assert(commands:dispatch(0, {'prepare-restart'}))
      assert(prepared.state == 'prepared' and prepared.restartCommand == 'restart synex_core')
      assert(restartPreparations == 1)
      assert(emitted[#emitted].ok == true)
      return table.concat({
        deniedError.code, invalidError.code, trace.limit, serviceCalls,
        notInstalled.status, unknownState.status, #printed, restartPreparations
      }, ':')
    `);
    assert.equal(result, 'CONSOLE_ONLY:INVALID_ARGUMENT:8:2:NOT_INSTALLED:DEGRADED:8:1');
  } finally {
    engine.global.close();
  }
});

test('durable saga runtime resumes with leases, retries, deadlines, and reverse compensation', async () => {
  const engine = await coreEngine(['foundation', 'registries', 'saga_runtime']);
  try {
    const result = await engine.doString(`
      local now, saga, sequence = 1000, nil, 0
      local runs, reserveRuns, compensations = 0, 0, {}
      local leasesAcquired, leasesReleased, leaseRenewals, audits = 0, 0, 0, 0
      local leaseOwners = {}
      local platform = {
        nowGame = function() return now end, random = function() return 1 end,
        print = function() end, jsonEncode = function() return '{}' end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('saga-runtime')
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      local epoch = registries.owners:activate('synex_fixture')
      local store = {}
      function store:start(ownerResource, sagaType, correlationId, context, options)
        assert(ownerResource == 'synex_fixture')
        sequence = sequence + 1
        saga = {
          publicId = ('saga-%d'):format(sequence), sagaType = sagaType, correlationId = correlationId,
          ownerResource = ownerResource,
          state = 'pending', currentStep = 0, version = 1, context = foundation.copy(context),
          steps = {}, ageMs = 100000, deadlineExpired = false, deadlineAt = options.deadlineAt
        }
        return { publicId = saga.publicId, state = saga.state, currentStep = 0, version = 1 }, nil
      end
      function store:candidates()
        if not saga or saga.state == 'completed' or saga.state == 'failed' then return {}, nil end
        return {{ publicId = saga.publicId, ownerResource = saga.ownerResource,
          sagaType = saga.sagaType, state = saga.state, version = saga.version }}, nil
      end
      function store:load(publicId, ownerResource)
        assert(saga and publicId == saga.publicId)
        if ownerResource ~= saga.ownerResource then
          return nil, foundation.error('SAGA_NOT_FOUND', 'The saga does not exist.')
        end
        return foundation.copy(saga), nil
      end
      function store:appendRuntimeEvent(command)
        assert(command.publicId == saga.publicId and command.expectedVersion == saga.version
          and command.ownerResource == saga.ownerResource)
        saga.currentStep = saga.currentStep + 1
        saga.version = saga.version + 1
        saga.state = command.nextState
        saga.context = foundation.copy(command.context)
        saga.steps[#saga.steps + 1] = {
          sequence = saga.currentStep, name = command.stepName, event = command.eventType,
          attempt = command.attempt, payload = foundation.copy(command.payload), error = foundation.copy(command.error)
        }
        if command.error then saga.lastError = foundation.copy(command.error) end
        saga.ageMs = 100000
        return { publicId = saga.publicId, state = saga.state, currentStep = saga.currentStep, version = saga.version }, nil
      end
      function store:snapshot()
        return { enabled = true, total = saga and 1 or 0, states = saga and {[saga.state] = 1} or {} }, nil
      end
      local audit = { append = function(_, entry)
        audits = audits + 1
        assert(entry.targetType == 'saga' and entry.targetId == saga.publicId)
        return { eventId = ('audit-%d'):format(audits) }, nil
      end }
      local leases = {
        acquire = function(_, name, owner, ttl, requesterInstanceId, requesterBootId)
          leasesAcquired = leasesAcquired + 1
          assert(name == 'saga:' .. saga.publicId
            and owner:find('instance-a:saga:', 1, true) == 1 and #owner <= 96 and ttl == 300
            and requesterInstanceId == 'instance-a' and requesterBootId == 'boot-a')
          assert(leaseOwners[owner] == nil, 'each saga attempt needs a unique lease owner')
          leaseOwners[owner] = true
          return { name = name, owner = owner, fencingToken = leasesAcquired, ttlSeconds = ttl,
            requesterInstanceId = requesterInstanceId, requesterBootId = requesterBootId }, nil
        end,
        renew = function(_, lease)
          leaseRenewals = leaseRenewals + 1
          assert(lease and lease.requesterInstanceId == 'instance-a'
            and lease.requesterBootId == 'boot-a' and lease.ttlSeconds == 300)
          return true, nil
        end,
        release = function() leasesReleased = leasesReleased + 1 return true, nil end
      }
      local runtime = SynexCoreFactories.sagaRuntime({
        foundation = foundation, platform = platform, sagas = store, audit = audit,
        leases = leases, owners = registries.owners,
        instances = { bootId = function() return 'boot-a', nil end },
        instanceId = 'instance-a', enabled = true
      })
      local invalid, invalidError = runtime:register('synex_fixture', epoch, {
        name = 'fixture.invalid', steps = {{ name = 'step', run = function() return {} end }}
      })
      assert(invalid == nil and invalidError.code == 'INVALID_SAGA_DEFINITION')
      assert(runtime:register('synex_fixture', epoch, {
        name = 'fixture.purchase', timeoutMs = 60000, steps = {
          {
            name = 'reserve', maxAttempts = 2, retryDelayMs = 100,
            run = setmetatable({ __cfx_functionReference = 'fixture-saga-reserve' }, {
              __metatable = 'protected-cfx-funcref',
              __call = function(_, context)
                reserveRuns = reserveRuns + 1
                context.reserved = true
                return { context = context, output = { reservation = 'opaque' } }, nil
              end
            }),
            compensate = setmetatable({ __cfx_functionReference = 'fixture-saga-release' }, {
              __metatable = 'protected-cfx-funcref',
              __call = function()
                compensations[#compensations + 1] = 'reserve'
                return { output = { released = true } }, nil
              end
            })
          },
          {
            name = 'commit', maxAttempts = 2, retryDelayMs = 100,
            run = function()
              runs = runs + 1
              return nil, { code = 'FIXTURE_RETRY', retryable = true }
            end,
            compensate = function()
              compensations[#compensations + 1] = 'commit'
              return { output = { reverted = true } }, nil
            end
          }
        }
      }))
      assert(runtime:start('synex_fixture', 'fixture.purchase', 'correlation-1', { value = 1 }, {}, 'trace-start'))
      local foreignStart, foreignStartError = runtime:start(
        'synex_attacker', 'fixture.purchase', 'foreign-correlation', {}, {}, 'trace-foreign')
      assert(foreignStart == nil and foreignStartError.code == 'SAGA_OWNER_DENIED')
      local foreignRead, foreignReadError = runtime:get('synex_attacker', saga.publicId)
      assert(foreignRead == nil and foreignReadError.code == 'SAGA_NOT_FOUND')
      local foreignRecord, foreignRecordError = runtime:record(
        'synex_attacker', saga.publicId, saga.version, 'reserve', 'started', {}, nil)
      assert(foreignRecord == nil and foreignRecordError.code == 'SAGA_NOT_FOUND')
      for index = 1, 5 do
        local report, dispatchError = runtime:dispatchBatch(10)
        assert(report and dispatchError == nil)
      end
      assert(saga.state == 'failed' and runs == 2 and reserveRuns == 1)
      assert(#compensations == 2 and compensations[1] == 'commit' and compensations[2] == 'reserve')
      assert(leasesAcquired == 5 and leasesReleased == 5)
      local forwardFailures = 0
      for _, event in ipairs(saga.steps) do
        if event.name == 'commit' and event.event == 'failed' and event.payload.phase == 'forward' then
          forwardFailures = forwardFailures + 1
        end
      end
      assert(forwardFailures == 2)

      local runsBeforeDeadline = runs
      assert(runtime:start('synex_fixture', 'fixture.purchase', 'correlation-2', {}, {}, 'trace-deadline'))
      saga.deadlineExpired = true
      assert(runtime:dispatchBatch(10))
      assert(saga.state == 'failed' and saga.lastError.code == 'SAGA_DEADLINE_EXCEEDED')
      assert(runs == runsBeforeDeadline)
      local snapshot = runtime:snapshot()
      assert(snapshot.enabled and #snapshot.handlers == 1 and snapshot.persisted.total == 1)

      assert(runtime:register('synex_fixture', epoch, {
        name = 'fixture.explode', steps = {{
          name = 'explode', maxAttempts = 1,
          run = function() error('database password must never escape') end,
          compensate = function() return { output = {} }, nil end
        }}
      }))
      assert(runtime:start('synex_fixture', 'fixture.explode', 'correlation-3', {}, {}, 'trace-explode'))
      assert(runtime:dispatchBatch(10))
      assert(saga.lastError.code == 'SAGA_HANDLER_FAILED')
      assert(saga.lastError.details.cause == 'SAGA_HANDLER_FAILED')
      assert(not tostring(saga.lastError.message):find('password', 1, true))
      assert(leaseRenewals >= 13)
      return table.concat({runs, compensations[1], compensations[2], leasesAcquired, audits}, ':')
    `);
    assert.match(String(result), /^2:commit:reserve:7:\d+$/u);
  } finally {
    engine.global.close();
  }
});

test('saga dispatch rotates unavailable owners so runnable work cannot starve behind the queue head', async () => {
  const engine = await coreEngine(['foundation', 'registries', 'saga_runtime']);
  try {
    const result = await engine.doString(`
      local now, healthyRuns, healthyState, healthyVersion = 1000, 0, 'pending', 1
      local platform = {
        nowGame = function() now = now + 1 return now end,
        random = function() return 1 end,
        print = function() end,
        jsonEncode = function() return '{}' end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('saga-starvation')
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      local epoch = registries.owners:activate('synex_fixture')
      local store = {}
      local orphan = {
        publicId = 'saga-orphan', ownerResource = 'synex_stopped',
        sagaType = 'stopped.workflow', state = 'pending', version = 1
      }
      local healthy = {
        publicId = 'saga-healthy', ownerResource = 'synex_fixture',
        sagaType = 'fixture.healthy', state = 'pending', version = 1
      }
      function store:candidates(maximum, selectors)
        assert(maximum == 50 and #selectors == 1)
        assert(selectors[1].ownerResource == 'synex_fixture'
          and selectors[1].sagaType == 'fixture.healthy')
        if healthyState == 'completed' then return {orphan}, nil end
        return {orphan, healthy}, nil
      end
      function store:load(publicId, owner)
        assert(publicId == healthy.publicId and owner == healthy.ownerResource)
        return {
          publicId = healthy.publicId, ownerResource = healthy.ownerResource,
          sagaType = healthy.sagaType, correlationId = 'correlation-healthy',
          state = healthyState, currentStep = 0, version = healthyVersion,
          context = {}, steps = {}, ageMs = 100000, deadlineExpired = false
        }, nil
      end
      function store:appendRuntimeEvent(command)
        assert(command.publicId == healthy.publicId
          and command.ownerResource == healthy.ownerResource
          and command.expectedVersion == healthyVersion)
        healthyVersion = healthyVersion + 1
        healthyState = command.nextState
        healthy.state = healthyState
        healthy.version = healthyVersion
        return {
          publicId = healthy.publicId, state = healthyState,
          currentStep = 1, version = healthyVersion
        }, nil
      end
      function store:snapshot()
        return { enabled = true, total = 2, states = { [healthyState] = 1, pending = 1 } }, nil
      end
      local leases = {
        acquire = function(_, name, owner, ttl, instanceId, bootId)
          return {
            name = name, owner = owner, fencingToken = 1, ttlSeconds = ttl,
            requesterInstanceId = instanceId, requesterBootId = bootId
          }, nil
        end,
        renew = function() return true, nil end,
        release = function() return true, nil end
      }
      local runtime = SynexCoreFactories.sagaRuntime({
        foundation = foundation, platform = platform, sagas = store,
        audit = { append = function() return { eventId = 'audit' }, nil end },
        leases = leases, owners = registries.owners,
        instances = { bootId = function() return 'boot-a', nil end },
        instanceId = 'instance-a', enabled = true
      })
      assert(runtime:register('synex_fixture', epoch, {
        name = 'fixture.healthy', steps = {{
          name = 'complete',
          run = function()
            healthyRuns = healthyRuns + 1
            return { context = {}, output = { ok = true } }, nil
          end,
          compensate = function() return { output = {} }, nil end
        }}
      }))
      local first = assert(runtime:dispatchBatch(1))
      assert(first.claimed == 2 and first.deferred == 1 and first.processed == 1
        and healthyRuns == 1 and healthyState == 'completed')
      return table.concat({first.deferred, healthyRuns, healthyState}, ':')
    `);
    assert.equal(result, '1:1:completed');
  } finally {
    engine.global.close();
  }
});

test('saga retry deferrals preserve elapsed backoff and eventually resume', async () => {
  const engine = await coreEngine(['foundation', 'registries', 'saga_runtime']);
  try {
    const result = await engine.doString(`
      local now, ageMs, runs, version, state = 1000, 1000, 0, 1, 'pending'
      local history = {}
      local platform = {
        nowGame = function() return now end,
        random = function() return 1 end,
        print = function() end,
        jsonEncode = function() return '{}' end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('saga-backoff')
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      local epoch = registries.owners:activate('synex_fixture')
      local store = {}
      function store:candidates(maximum, selectors)
        assert(maximum == 50 and #selectors == 1)
        if state == 'completed' then return {}, nil end
        return {{
          publicId = 'saga-backoff', ownerResource = 'synex_fixture',
          sagaType = 'fixture.backoff', state = state, version = version
        }}, nil
      end
      function store:load(publicId, owner)
        assert(publicId == 'saga-backoff' and owner == 'synex_fixture')
        return {
          publicId = publicId, ownerResource = owner, sagaType = 'fixture.backoff',
          correlationId = 'correlation-backoff', state = state, currentStep = #history,
          version = version, context = {}, steps = foundation.copy(history),
          ageMs = ageMs, deadlineExpired = false
        }, nil
      end
      function store:appendRuntimeEvent(command)
        assert(command.expectedVersion == version)
        version = version + 1
        state = command.nextState
        history[#history + 1] = {
          sequence = #history + 1,
          name = command.stepName,
          event = command.eventType,
          attempt = command.attempt,
          payload = foundation.copy(command.payload),
          error = foundation.copy(command.error)
        }
        ageMs = 0
        return {
          publicId = 'saga-backoff', state = state,
          currentStep = #history, version = version
        }, nil
      end
      function store:snapshot()
        return { enabled = true, total = 1, states = { [state] = 1 } }, nil
      end
      local leases = {
        acquire = function(_, name, owner, ttl, instanceId, bootId)
          return {
            name = name, owner = owner, fencingToken = version, ttlSeconds = ttl,
            requesterInstanceId = instanceId, requesterBootId = bootId
          }, nil
        end,
        renew = function() return true, nil end,
        release = function() return true, nil end
      }
      local runtime = SynexCoreFactories.sagaRuntime({
        foundation = foundation, platform = platform, sagas = store,
        audit = { append = function() return { eventId = 'audit' }, nil end },
        leases = leases, owners = registries.owners,
        instances = { bootId = function() return 'boot-a', nil end },
        instanceId = 'instance-a', enabled = true
      })
      assert(runtime:register('synex_fixture', epoch, {
        name = 'fixture.backoff', steps = {{
          name = 'commit', maxAttempts = 2, retryDelayMs = 100,
          run = function()
            runs = runs + 1
            if runs == 1 then return nil, { code = 'FIXTURE_RETRY', retryable = true } end
            return { context = {}, output = { ok = true } }, nil
          end,
          compensate = function() return { output = {} }, nil end
        }}
      }))

      local first = assert(runtime:dispatchBatch(1))
      assert(first.processed == 1 and runs == 1 and state == 'running')
      ageMs = 50
      local early = assert(runtime:dispatchBatch(1))
      assert(early.deferred == 1 and runs == 1 and ageMs == 50)
      ageMs = 99
      local stillEarly = assert(runtime:dispatchBatch(1))
      assert(stillEarly.deferred == 1 and runs == 1 and ageMs == 99)
      ageMs = 100
      local ready = assert(runtime:dispatchBatch(1))
      assert(ready.processed == 1 and runs == 2 and state == 'completed')
      return table.concat({early.deferred, stillEarly.deferred, runs, state, #history}, ':')
    `);
    assert.equal(result, '1:1:2:completed:4');
  } finally {
    engine.global.close();
  }
});
