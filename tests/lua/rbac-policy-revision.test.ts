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

test('cluster RBAC revisions revoke stale grants and fail closed across refresh races', async () => {
  const engine = await coreEngine(['foundation', 'security']);
  try {
    const result = await engine.doString(`
      local platform = {
        nowGame = function() return 1000 end,
        random = function() return 1 end,
        print = function() end,
        jsonEncode = function() return '{}' end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      local shared = {
        revision = 1,
        roles = {
          operator = { version = 1, permissions = {
            { permission = 'fixture.read', effect = 'allow' },
            { permission = 'fixture.write', effect = 'allow' }
          } },
          auditor = { version = 1, permissions = {
            { permission = 'audit.legacy', effect = 'allow' }
          } }
        },
        assignments = { ['user:fixture'] = { operator = true, auditor = true } },
        subjectVersions = { ['user:fixture'] = 1 },
        assignmentWrites = 0,
        subjectLoads = 0
      }

      local function snapshot()
        local names, rows = {}, {}
        for name in pairs(shared.roles) do names[#names + 1] = name end
        table.sort(names)
        for _, name in ipairs(names) do
          local role = shared.roles[name]
          local permissions = {}
          for _, permission in ipairs(role.permissions) do permissions[#permissions + 1] = permission end
          table.sort(permissions, function(left, right)
            if left.permission == right.permission then return left.effect < right.effect end
            return left.permission < right.permission
          end)
          if #permissions == 0 then
            rows[#rows + 1] = { role_name = name, version = role.version }
          else
            for _, permission in ipairs(permissions) do
              rows[#rows + 1] = {
                role_name = name,
                version = role.version,
                permission_key = permission.permission,
                effect = permission.effect
              }
            end
          end
        end
        return { revision = shared.revision, rows = rows }
      end

      local function newStore()
        local store = {
          failRevision = false,
          failSnapshot = false,
          revisionOverride = nil,
          snapshotOverride = nil,
          snapshotLoads = 0
        }
        function store:loadPolicyRevision()
          if self.failRevision then
            return nil, foundation.error('REVISION_READ_FAILED', 'fixture revision failure', { retryable = true })
          end
          return self.revisionOverride or shared.revision, nil
        end
        function store:loadRoleSnapshot()
          self.snapshotLoads = self.snapshotLoads + 1
          if self.failSnapshot then
            return nil, foundation.error('SNAPSHOT_READ_FAILED', 'fixture snapshot failure', { retryable = true })
          end
          if self.snapshotOverride then return foundation.copy(self.snapshotOverride), nil end
          return snapshot(), nil
        end
        function store:loadSubject(subject)
          shared.subjectLoads = shared.subjectLoads + 1
          local roles = {}
          for role in pairs(shared.assignments[subject] or {}) do roles[#roles + 1] = role end
          table.sort(roles)
          return { version = shared.subjectVersions[subject] or 0, roles = roles }, nil
        end
        function store:loadSubjectVersion(subject)
          return shared.subjectVersions[subject] or 0, nil
        end
        function store:defineRole(name, permissions)
          local current = shared.roles[name]
          shared.roles[name] = {
            version = current and current.version + 1 or 1,
            permissions = foundation.copy(permissions)
          }
          shared.revision = shared.revision + 1
          local committed = snapshot()
          committed.committedRevision = shared.revision
          return committed, nil
        end
        function store:assign(subject, role)
          shared.assignmentWrites = shared.assignmentWrites + 1
          shared.assignments[subject] = shared.assignments[subject] or {}
          shared.assignments[subject][role] = true
          shared.subjectVersions[subject] = (shared.subjectVersions[subject] or 0) + 1
          return true, nil
        end
        function store:revoke(subject, role)
          if shared.assignments[subject] then shared.assignments[subject][role] = nil end
          shared.subjectVersions[subject] = (shared.subjectVersions[subject] or 0) + 1
          return true, nil
        end
        return store
      end

      local storeA, storeB = newStore(), newStore()
      local function runtime(store)
        return SynexCoreFactories.security({
          platform = platform,
          foundation = foundation,
          coreResource = 'synex_core',
          policy = { default = { allow = {}, deny = {} }, resources = {} },
          rbacStore = store,
          rbacCacheTtlMs = 60000,
          rbacCacheMaximum = 64
        }).rbac
      end
      local instanceA, instanceB = runtime(storeA), runtime(storeB)
      assert(instanceA:hydrate() and instanceB:hydrate())
      assert(instanceB:check('user:fixture', 'fixture.write'))

      local context = {
        actor = 'synex_control', actorType = 'resource', reason = 'cluster policy update',
        traceId = 'trace-rbac-cluster'
      }
      assert(instanceA:defineRole('operator', {{ permission = 'fixture.read', effect = 'allow' }}, context))
      assert(not instanceB:check('user:fixture', 'fixture.write'),
        'another instance must stop honoring a removed permission')

      assert(instanceB:defineRole('auditor', {{ permission = 'audit.current', effect = 'allow' }}, context))
      assert(instanceA:defineRole('operator', {{ permission = 'fixture.read', effect = 'allow' }}, context))
      assert(not instanceA:check('user:fixture', 'audit.legacy'),
        'a local define must not hide an intervening update to another role')
      assert(instanceA:check('user:fixture', 'audit.current'))

      storeB.failRevision = true
      local authorized, revisionError = instanceB:check('user:fixture', 'fixture.read')
      assert(not authorized and revisionError.code == 'REVISION_READ_FAILED')
      local writesBeforeFailure = shared.assignmentWrites
      local assigned, assignError = instanceB:assign('user:other', 'operator', context)
      assert(assigned == nil and assignError.code == 'REVISION_READ_FAILED')
      assert(shared.assignmentWrites == writesBeforeFailure,
        'assignment must not write when role existence cannot be checked against current policy')
      storeB.failRevision = false
      assert(instanceB:check('user:fixture', 'fixture.read'))

      shared.roles.operator = { version = shared.roles.operator.version + 1, permissions = {} }
      shared.revision = shared.revision + 1
      storeB.failSnapshot = true
      authorized, revisionError = instanceB:check('user:fixture', 'fixture.read')
      assert(not authorized and revisionError.code == 'SNAPSHOT_READ_FAILED')
      storeB.failSnapshot = false
      assert(not instanceB:check('user:fixture', 'fixture.read'))

      assert(instanceA:defineRole('dispatcher', {{ permission = 'dispatch.read', effect = 'allow' }}, context))
      assert(instanceB:assign('user:other', 'dispatcher', context))
      assert(shared.assignmentWrites == writesBeforeFailure + 1)

      storeB.revisionOverride = 1
      authorized, revisionError = instanceB:check('user:fixture', 'audit.current')
      assert(not authorized and revisionError.code == 'RBAC_POLICY_REVISION_REGRESSED')
      storeB.revisionOverride = nil
      assert(instanceB:check('user:fixture', 'audit.current'))

      local staleSnapshot = snapshot()
      shared.roles.auditor = { version = shared.roles.auditor.version + 1, permissions = {} }
      shared.revision = shared.revision + 1
      storeB.snapshotOverride = staleSnapshot
      local loadsBeforeStale = storeB.snapshotLoads
      authorized, revisionError = instanceB:check('user:fixture', 'audit.current')
      assert(not authorized and revisionError.code == 'RBAC_POLICY_SNAPSHOT_STALE')
      assert(storeB.snapshotLoads == loadsBeforeStale + 2,
        'a stale adapter snapshot must receive only one bounded retry')
      storeB.snapshotOverride = nil
      assert(not instanceB:check('user:fixture', 'audit.current'))

      local status = instanceB:snapshot()
      assert(status.policyRevision == shared.revision)
      return table.concat({shared.revision, shared.assignmentWrites, status.policyRevision}, ':')
    `);
    assert.equal(result, '7:1:7');
  } finally {
    engine.global.close();
  }
});

test('subject revision and database expiry invalidate persistent RBAC cache immediately', async () => {
  const engine = await coreEngine(['foundation', 'security']);
  try {
    const result = await engine.doString(`
      local now = 1000
      local platform = {
        nowGame = function() return now end, random = function() return 1 end,
        print = function() end, jsonEncode = function() return '{}' end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      local shared = { version = 1, assigned = true, expiresAt = nil }
      local function newStore()
        local store = {
          failVersion = false, advanceDuringVersionRead = false,
          subjectLoads = 0, versionReads = 0
        }
        function store:loadPolicyRevision() return 1, nil end
        function store:loadRoleSnapshot()
          return { revision = 1, rows = {{
            role_name = 'admin', version = 1,
            permission_key = 'economy.write', effect = 'allow'
          }}}, nil
        end
        function store:loadSubjectVersion()
          self.versionReads = self.versionReads + 1
          if self.failVersion then
            return nil, foundation.error('SUBJECT_VERSION_FAILED',
              'fixture subject revision failure', { retryable = true })
          end
          if self.advanceDuringVersionRead then
            self.advanceDuringVersionRead = false
            now = now + 6
          end
          return shared.version, nil
        end
        function store:loadSubject()
          self.subjectLoads = self.subjectLoads + 1
          local active = shared.assigned
            and (shared.expiresAt == nil or shared.expiresAt > now)
          local validFor = shared.expiresAt and math.max(0, shared.expiresAt - now) or nil
          return { version = shared.version, roles = active and {'admin'} or {},
            validForMs = validFor }, nil
        end
        function store:assign()
          shared.assigned = true
          shared.version = shared.version + 1
          return true, nil
        end
        function store:revoke()
          shared.assigned = false
          shared.version = shared.version + 1
          return true, nil
        end
        function store:defineRole()
          return { revision = 1, committedRevision = 1, rows = {} }, nil
        end
        return store
      end
      local storeA, storeB = newStore(), newStore()
      local function runtime(store)
        return SynexCoreFactories.security({
          platform = platform, foundation = foundation, coreResource = 'synex_core',
          policy = { default = { allow = {}, deny = {} }, resources = {} },
          rbacStore = store, rbacCacheTtlMs = 60000, rbacCacheMaximum = 64
        }).rbac
      end
      local instanceA, instanceB = runtime(storeA), runtime(storeB)
      assert(instanceA:hydrate() and instanceB:hydrate())
      assert(instanceA:check('user:fixture', 'economy.write'))
      local context = {
        actor = 'synex_control', actorType = 'resource', reason = 'revoke fixture',
        traceId = 'trace-subject-revision'
      }
      assert(instanceB:revoke('user:fixture', 'admin', context))
      assert(not instanceA:check('user:fixture', 'economy.write'),
        'a committed remote revoke must invalidate a warm subject cache')

      assert(instanceB:assign('user:fixture', 'admin', context))
      assert(instanceA:check('user:fixture', 'economy.write'))
      storeA.failVersion = true
      local allowed, versionError = instanceA:check('user:fixture', 'economy.write')
      assert(not allowed and versionError.code == 'SUBJECT_VERSION_FAILED')
      storeA.failVersion = false

      shared.expiresAt = now + 5
      shared.version = shared.version + 1
      assert(instanceA:check('user:fixture', 'economy.write'))
      storeA.advanceDuringVersionRead = true
      assert(not instanceA:check('user:fixture', 'economy.write'),
        'an assignment must not outlive its database expiry while its version is rechecked')
      return table.concat({shared.version, storeA.subjectLoads, storeA.versionReads}, ':')
    `);
    assert.equal(result, '4:5:5');
  } finally {
    engine.global.close();
  }
});

test('persistent RBAC snapshot drops an assignment that expires during its version recheck', async () => {
  const engine = await coreEngine(['foundation', 'runtime_persistence']);
  try {
    const result = await engine.doString(`
      local now, scalarCalls = 1000, 0
      local platform = {
        nowGame = function() return now end, random = function() return 1 end,
        print = function() end, jsonEncode = function() return '{}' end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      local database = {}
      function database:scalar()
        scalarCalls = scalarCalls + 1
        return 7, nil
      end
      function database:query(sql)
        assert(sql:find('remaining_ms', 1, true) and sql:find('LIMIT 513', 1, true))
        now = now + 2
        return {{ role_name = 'admin', remaining_ms = 1 }}, nil
      end
      local store = SynexCoreFactories.runtimePersistence({
        foundation = foundation, database = database, platform = platform,
        instanceId = 'instance-a'
      }).rbac
      local snapshot = assert(store:loadSubject('user:fixture'))
      assert(snapshot.version == 7 and #snapshot.roles == 0
        and snapshot.validForMs == 0 and scalarCalls == 2)
      return table.concat({snapshot.version, #snapshot.roles, snapshot.validForMs}, ':')
    `);
    assert.equal(result, '7:0:0');
  } finally {
    engine.global.close();
  }
});

test('RBAC persistence locks the singleton first and returns the exact committed snapshot', async () => {
  const engine = await coreEngine(['foundation', 'runtime_persistence']);
  try {
    const result = await engine.doString(`
      local platform = {
        nowGame = function() return 1000 end,
        random = function() return 1 end,
        print = function() end,
        jsonEncode = function() return '{}' end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('rbac-policy-lock')
      local revision = 7
      local roles = {
        operator = { version = 2, permissions = {
          { permission_key = 'fixture.read', effect = 'allow' }
        } },
        auditor = { version = 4, permissions = {
          { permission_key = 'audit.current', effect = 'allow' }
        } }
      }
      local transactions, scalarCalls, auditWrites = {}, 0, 0
      local revisionMissing, revisionConflict, corruptForeign = false, false, false

      local function roleRows()
        local result, names = {}, {}
        for name in pairs(roles) do names[#names + 1] = name end
        table.sort(names)
        for _, name in ipairs(names) do
          local role = roles[name]
          if #role.permissions == 0 then
            result[#result + 1] = { role_name = name, version = role.version }
          else
            for _, permission in ipairs(role.permissions) do
              result[#result + 1] = {
                role_name = name, version = role.version,
                permission_key = permission.permission_key, effect = permission.effect
              }
            end
          end
        end
        if corruptForeign then
          result[#result + 1] = {
            role_name = 'invalid role', version = 1,
            permission_key = 'fixture.corrupt', effect = 'allow'
          }
        end
        return result
      end

      local database = {}
      function database:scalar(sql, parameters)
        scalarCalls = scalarCalls + 1
        assert(sql:find('synex_rbac_policy_revisions', 1, true)
          and not sql:find('FOR UPDATE', 1, true) and parameters[1] == 1)
        return revision, nil
      end
      function database:withTransaction(handler)
        local calls = {}
        transactions[#transactions + 1] = calls
        local beforeRevision, beforeRoles, beforeAuditWrites =
          revision, foundation.copy(roles), auditWrites
        local function query(sql, parameters)
          calls[#calls + 1] = { sql = sql, parameters = foundation.copy(parameters or {}) }
          if sql:find('synex_rbac_policy_revisions', 1, true)
            and sql:find('SELECT', 1, true) then
            if revisionMissing then return {} end
            return {{ revision = revision }}
          end
          if sql:find('\`role\`.\`role_name\`', 1, true) then return roleRows() end
          if sql:find('SELECT \`version\`', 1, true)
            and sql:find('synex_rbac_roles', 1, true) then
            local role = roles[parameters[1]]
            return role and {{ version = role.version }} or {}
          end
          if sql:find('SELECT \`permission_key\`', 1, true) then
            return foundation.copy((roles[parameters[1]] or {}).permissions or {})
          end
          if sql:find('INSERT INTO \`synex_rbac_roles\`', 1, true) then
            local role = roles[parameters[1]]
            roles[parameters[1]] = role or { version = 0, permissions = {} }
            roles[parameters[1]].version = roles[parameters[1]].version + 1
            return { affectedRows = 1 }
          end
          if sql:find('DELETE FROM \`synex_rbac_role_permissions\`', 1, true) then
            roles[parameters[1]].permissions = {}
            return { affectedRows = 1 }
          end
          if sql:find('INSERT INTO \`synex_rbac_role_permissions\`', 1, true) then
            local role = roles[parameters[1]]
            role.permissions[#role.permissions + 1] = {
              permission_key = parameters[2], effect = parameters[3]
            }
            return { affectedRows = 1 }
          end
          if sql:find('UPDATE \`synex_rbac_policy_revisions\`', 1, true) then
            assert(parameters[1] == 1 and parameters[2] == revision)
            if revisionConflict then return { affectedRows = 0 } end
            revision = revision + 1
            return { affectedRows = 1 }
          end
          if sql:find('synex_audit_log', 1, true)
            and sql:find('INSERT INTO', 1, true) then
            auditWrites = auditWrites + 1
            return { affectedRows = 1 }
          end
          return { affectedRows = 1 }
        end
        local committed = handler(query)
        if not committed then
          revision, roles, auditWrites = beforeRevision, beforeRoles, beforeAuditWrites
        end
        return committed, committed and nil or foundation.error('TRANSACTION_ABORTED', 'fixture abort')
      end

      local rbac = SynexCoreFactories.runtimePersistence({
        foundation = foundation,
        database = database,
        platform = platform,
        instanceId = 'instance-a'
      }).rbac
      assert(rbac:loadPolicyRevision() == 7 and scalarCalls == 1)
      local loaded = assert(rbac:loadRoleSnapshot())
      assert(loaded.revision == 7 and #loaded.rows == 2)
      local loadCalls = transactions[1]
      assert(loadCalls[1].sql:find('synex_rbac_policy_revisions', 1, true)
        and loadCalls[1].sql:find('FOR UPDATE', 1, true))
      assert(loadCalls[2].sql:find('\`role\`.\`role_name\`', 1, true)
        and loadCalls[2].sql:find('LIMIT ?', 1, true)
        and loadCalls[2].parameters[1] == 16385)

      local changed = assert(rbac:defineRole('operator', {
        { permission = 'fixture.current', effect = 'allow' }
      }, {
        actor = 'synex_control', actorType = 'resource', reason = 'replace stale permission',
        traceId = 'trace-rbac-lock'
      }))
      assert(changed.revision == 8 and changed.committedRevision == 8 and #changed.rows == 2)
      local defineCalls = transactions[2]
      assert(defineCalls[1].sql:find('synex_rbac_policy_revisions', 1, true)
        and defineCalls[1].sql:find('FOR UPDATE', 1, true))
      assert(defineCalls[2].sql:find('synex_rbac_roles', 1, true)
        and defineCalls[2].sql:find('FOR UPDATE', 1, true))
      local revisionUpdateAt, snapshotAt = nil, nil
      for index, call in ipairs(defineCalls) do
        if call.sql:find('UPDATE \`synex_rbac_policy_revisions\`', 1, true) then revisionUpdateAt = index end
        if call.sql:find('\`role\`.\`role_name\`', 1, true) then snapshotAt = index end
      end
      assert(revisionUpdateAt and snapshotAt and revisionUpdateAt < snapshotAt)
      assert(changed.rows[2].role_name == 'operator'
        and changed.rows[2].permission_key == 'fixture.current')

      revisionMissing = true
      local missing, missingError = rbac:loadRoleSnapshot()
      assert(missing == nil and missingError.code == 'RBAC_POLICY_REVISION_INVALID')
      revisionMissing = false
      revisionConflict = true
      local conflicted, conflictError = rbac:defineRole('operator', {
        { permission = 'fixture.conflicted', effect = 'allow' }
      }, {
        actor = 'synex_control', actorType = 'resource', reason = 'force revision conflict',
        traceId = 'trace-rbac-conflict'
      })
      assert(conflicted == nil and conflictError.code == 'RBAC_POLICY_REVISION_CONFLICT')
      assert(revision == 8 and roles.operator.permissions[1].permission_key == 'fixture.current',
        'the failed revision CAS must roll back the role mutation')

      revisionConflict = false
      corruptForeign = true
      local auditBeforeCorruption = auditWrites
      local corrupted, corruptionError = rbac:defineRole('operator', {
        { permission = 'fixture.after-corruption', effect = 'allow' }
      }, {
        actor = 'synex_control', actorType = 'resource', reason = 'detect corrupt foreign role',
        traceId = 'trace-rbac-corrupt'
      })
      assert(corrupted == nil and corruptionError.code == 'RBAC_DATA_INVALID')
      assert(revision == 8 and auditWrites == auditBeforeCorruption
        and roles.operator.permissions[1].permission_key == 'fixture.current',
        'semantic snapshot validation must abort mutation, revision, and audit before commit')
      return table.concat({loaded.revision, changed.revision, #defineCalls}, ':')
    `);
    assert.match(String(result), /^7:8:\d+$/u);
  } finally {
    engine.global.close();
  }
});
