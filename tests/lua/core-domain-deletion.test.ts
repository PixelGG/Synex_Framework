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
  await load(runtime, 'core/synex_core/server/domain_deletion.lua');
  const source = String.raw`
    local function encode(value)
      if value == nil then return 'null' end
      if type(value) == 'boolean' then return value and 'true' or 'false' end
      if type(value) == 'number' then return tostring(value) end
      if type(value) == 'string' then return '"' .. value:gsub('\\', '\\\\'):gsub('"', '\\"') .. '"' end
      error('fixture JSON encoder only accepts scalars')
    end
    local function decode(value)
      if value == '{}' then return {} end
      if value == '{"marker":"x"}' then return { marker = 'x' } end
      if value == '{"request":"fixture"}' then return { request = 'fixture' } end
      error('unexpected JSON: ' .. tostring(value))
    end
    FakeDeletionPlatform = {
      nowGame = function() return 1000 end,
      random = function() return 1 end,
      print = function() end,
      jsonEncode = encode,
      jsonDecode = decode
    }

    function NewDeletionFixture(options)
      options = options or {}
      local foundation = SynexCoreFactories.foundation({ platform = FakeDeletionPlatform })
      foundation.configureIds('deletion-fixture')
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      registries.owners:activate('synex_core')
      local epoch = registries.owners:activate('synex_groups')
      local store = {
        domain = nil,
        providerCount = 0,
        catalog = nil,
        plan = nil,
        actions = {},
        planCapacity = options.planCapacity or 0,
        planGlobalLimit = options.planGlobalLimit or 10000,
        planOwnerCapacity = options.planOwnerCapacity or 0,
        planOwnerLimit = options.planOwnerLimit or 1000,
        planOwnerInitialized = options.planOwnerInitialized == true
          or (options.planOwnerCapacity or 0) > 0,
        purgeReady = false,
        failActionInsert = options.failActionInsert == true,
        queryLog = {},
        leaseFence = 0,
        released = 0,
        executeCalls = 0
      }
      local function planRow()
        local plan = store.plan
        if not plan then return nil end
        return {
          plan_id = plan.plan_id, domain_name = plan.domain_name,
          subject_id = plan.subject_id, requester_owner = plan.requester_owner,
          state = plan.state, version = plan.version, attempt_count = plan.attempt_count,
          failure_code = plan.failure_code, request_context_json = plan.request_context_json,
          reason = plan.reason, created_at = '2026-01-01', updated_at = '2026-01-01',
          completed_at = plan.completed_at, purge_after = plan.purge_after
        }
      end
      local function actionRows()
        local rows = {}
        for index, action in ipairs(store.actions) do
          rows[index] = {
            action_index = index, provider_owner = action.provider_owner,
            provider_name = action.provider_name,
            provider_schema_version = action.provider_schema_version,
            decision = action.decision, decision_reason = action.decision_reason,
            metadata_json = action.metadata_json,
            state = action.state, version = action.version,
            attempt_count = action.attempt_count, failure_code = action.failure_code,
            last_attempt_at = action.last_attempt_at, completed_at = action.completed_at
          }
        end
        return rows
      end
      local function snapshot()
        local actions = {}
        for index, action in ipairs(store.actions) do
          actions[index] = {}
          for key, value in pairs(action) do actions[index][key] = value end
        end
        local plan
        if store.plan then
          plan = {}
          for key, value in pairs(store.plan) do plan[key] = value end
        end
        local catalog
        if store.catalog then
          catalog = {}
          for key, value in pairs(store.catalog) do catalog[key] = value end
        end
        return {
          domain = store.domain, providerCount = store.providerCount,
          catalog = catalog, plan = plan, actions = actions,
          planCapacity = store.planCapacity,
          planGlobalLimit = store.planGlobalLimit,
          planOwnerCapacity = store.planOwnerCapacity,
          planOwnerLimit = store.planOwnerLimit,
          planOwnerInitialized = store.planOwnerInitialized,
          purgeReady = store.purgeReady,
          failActionInsert = store.failActionInsert,
          leaseFence = store.leaseFence, released = store.released,
          executeCalls = store.executeCalls
        }
      end
      local function restore(previous)
        store.domain = previous.domain
        store.providerCount = previous.providerCount
        store.catalog = previous.catalog
        store.plan = previous.plan
        store.actions = previous.actions
        store.planCapacity = previous.planCapacity
        store.planGlobalLimit = previous.planGlobalLimit
        store.planOwnerCapacity = previous.planOwnerCapacity
        store.planOwnerLimit = previous.planOwnerLimit
        store.planOwnerInitialized = previous.planOwnerInitialized
        store.purgeReady = previous.purgeReady
        store.failActionInsert = previous.failActionInsert
        store.leaseFence = previous.leaseFence
        store.released = previous.released
        store.executeCalls = previous.executeCalls
      end
      local function query(sql, values)
        if sql:find('INSERT IGNORE INTO §synex_domain_deletion_domains§', 1, true) then
          local created = store.domain == nil
          store.domain = values[1]
          return created and 1 or 0
        end
        if sql:find('FROM §synex_domain_deletion_domains§', 1, true) then
          return store.domain and {{ provider_count = store.providerCount }} or {}
        end
        if sql:find('FROM §synex_domain_deletion_providers§', 1, true)
          and sql:find('§provider_owner§ = ?', 1, true) then
          store.queryLog[#store.queryLog + 1] = 'provider_lock'
          if store.catalog and store.catalog.provider_owner == values[2]
            and store.catalog.provider_name == values[3] then
            return {{
              provider_owner = values[2], provider_name = values[3],
              schema_version = store.catalog.schema_version
            }}
          end
          return {}
        end
        if sql:find('FROM §synex_domain_deletion_actions§ AS §action§', 1, true)
          and sql:find('§provider_schema_version§ <> ?', 1, true) then
          store.queryLog[#store.queryLog + 1] = 'schema_upgrade_guard'
          for _, action in ipairs(store.actions) do
            if store.plan and store.plan.domain_name == values[1]
              and action.provider_owner == values[2]
              and action.provider_name == values[3]
              and action.state == 'pending'
              and (store.plan.state == 'pending' or store.plan.state == 'executing')
              and action.provider_schema_version ~= values[4] then
              return {{
                plan_id = store.plan.plan_id,
                provider_schema_version = action.provider_schema_version
              }}
            end
          end
          return {}
        end
        if sql:find('INSERT INTO §synex_domain_deletion_providers§', 1, true) then
          store.catalog = {
            domain_name = values[1], provider_owner = values[2],
            provider_name = values[3], schema_version = values[4]
          }
          return 1
        end
        if sql:find('UPDATE §synex_domain_deletion_domains§', 1, true) then
          if store.providerCount ~= values[2] then return 0 end
          store.providerCount = store.providerCount + 1
          return 1
        end
        if sql:find('FROM §synex_domain_deletion_providers§', 1, true) then
          return store.catalog and {{
            provider_owner = store.catalog.provider_owner,
            provider_name = store.catalog.provider_name,
            schema_version = store.catalog.schema_version
          }} or {}
        end
        if sql:find('SELECT', 1, true)
          and sql:find('FROM §synex_domain_deletion_plan_capacity§', 1, true) then
          store.queryLog[#store.queryLog + 1] = 'global_lock'
          return {{
            entry_count = store.planCapacity,
            global_limit = store.planGlobalLimit,
            owner_limit = store.planOwnerLimit
          }}
        end
        if sql:find('INSERT IGNORE INTO §synex_domain_deletion_plan_owner_capacity§', 1, true) then
          store.queryLog[#store.queryLog + 1] = 'owner_initialize'
          if store.planOwnerInitialized then return 0 end
          store.planOwnerInitialized = true
          return 1
        end
        if sql:find('SELECT', 1, true)
          and sql:find('FROM §synex_domain_deletion_plan_owner_capacity§', 1, true) then
          store.queryLog[#store.queryLog + 1] = 'owner_lock'
          return store.planOwnerInitialized
            and {{ entry_count = store.planOwnerCapacity }} or {}
        end
        if sql:find('UPDATE', 1, true)
          and sql:find('§synex_domain_deletion_plan_capacity§', 1, true) then
          if sql:find('SET §entry_count§ = §entry_count§ - ?', 1, true) then
            if store.planCapacity ~= values[2] or store.planCapacity < values[1] then return 0 end
            store.planCapacity = store.planCapacity - values[1]
          else
            if store.planCapacity ~= values[1] then return 0 end
            store.planCapacity = store.planCapacity + 1
          end
          return 1
        end
        if sql:find('UPDATE', 1, true)
          and sql:find('§synex_domain_deletion_plan_owner_capacity§', 1, true) then
          if sql:find('SET §entry_count§ = §entry_count§ - ?', 1, true) then
            if store.planOwnerCapacity ~= values[3]
              or store.planOwnerCapacity < values[1] then return 0 end
            store.planOwnerCapacity = store.planOwnerCapacity - values[1]
          else
            if store.planOwnerCapacity ~= values[2] then return 0 end
            store.planOwnerCapacity = store.planOwnerCapacity + 1
          end
          return 1
        end
        if sql:find('DELETE FROM §synex_domain_deletion_plan_owner_capacity§', 1, true) then
          if not store.planOwnerInitialized or store.planOwnerCapacity ~= values[2] then return 0 end
          store.planOwnerInitialized = false
          store.planOwnerCapacity = 0
          return 1
        end
        if sql:find('FORCE INDEX (§idx_domain_deletion_retention§)', 1, true) then
          store.queryLog[#store.queryLog + 1] = 'plan_lock'
          return store.plan and store.purgeReady and store.plan.purge_after == 'past'
            and (store.plan.state == 'completed' or store.plan.state == 'blocked'
              or store.plan.state == 'failed') and {{
            plan_id = store.plan.plan_id,
            requester_owner = store.plan.requester_owner,
            state = store.plan.state
          }} or {}
        end
        if sql:find('DELETE FROM §synex_domain_deletion_plans§', 1, true) then
          if not store.plan or store.plan.plan_id ~= values[1]
            or store.plan.requester_owner ~= values[2] or not store.purgeReady
            or store.plan.purge_after ~= 'past' then return 0 end
          store.plan = nil
          store.actions = {}
          return 1
        end
        if sql:find('FROM §synex_domain_deletion_plans§', 1, true)
          and sql:find('§requester_owner§ = ?', 1, true)
          and sql:find('§domain_name§ = ?', 1, true)
          and sql:find('§idempotency_key§ = ?', 1, true) then
          store.queryLog[#store.queryLog + 1] = 'request_lock'
          if store.plan and store.plan.requester_owner == values[1]
            and store.plan.domain_name == values[2]
            and store.plan.idempotency_key == values[3] then
            return {{ plan_id = store.plan.plan_id, request_hash = store.plan.request_hash }}
          end
          return {}
        end
        if sql:find('INSERT IGNORE INTO', 1, true)
          and sql:find('§synex_domain_deletion_plans§', 1, true) then
          store.queryLog[#store.queryLog + 1] = 'plan_claim'
          if store.plan and store.plan.requester_owner == values[4]
            and store.plan.domain_name == values[2]
            and store.plan.idempotency_key == values[5] then return 0 end
          local terminal = values[9] ~= 'pending'
          store.plan = {
            plan_id = values[1], domain_name = values[2], subject_id = values[3],
            requester_owner = values[4], idempotency_key = values[5], request_hash = values[6],
            request_context_json = values[7], reason = values[8], state = values[9],
            version = 1, attempt_count = 0,
            completed_at = terminal and 'now' or nil,
            purge_after = terminal and 'future' or nil
          }
          return 1
        end
        if sql:find('INSERT INTO §synex_domain_deletion_actions§', 1, true) then
          if store.failActionInsert then return 0 end
          store.actions[values[2]] = {
            provider_owner = values[3], provider_name = values[4],
            provider_schema_version = values[5], decision = values[6],
            decision_reason = values[7], metadata_json = values[8], state = values[9], version = 1,
            attempt_count = 0, completed_at = values[9] == 'completed' and 'now' or nil
          }
          return 1
        end
        if sql:find('FROM §synex_domain_deletion_plans§ WHERE §plan_id§ = ?', 1, true) then
          local row = planRow()
          if row and sql:find('§requester_owner§ = ?', 1, true)
            and row.requester_owner ~= values[2] then return {} end
          return row and {row} or {}
        end
        if sql:find('FROM §synex_domain_deletion_actions§', 1, true) then return actionRows() end
        if sql:find('SELECT §plan_id§', 1, true)
          and sql:find('FROM §synex_domain_deletion_plans§', 1, true) then
          return store.plan and store.plan.state == 'pending'
            and {{ plan_id = store.plan.plan_id }} or {}
        end
        error('unexpected query: ' .. sql)
      end
      local database = {}
      function database:query(sql, values) return query(sql, values) end
      function database:withTransaction(handler)
        local previous = snapshot()
        local ok, accepted = pcall(handler, query)
        if not ok or accepted ~= true then
          restore(previous)
          return nil, foundation.error('TRANSACTION_REJECTED', 'fixture rollback')
        end
        return true, nil
      end
      function database:update(sql, values)
        if sql:find("SET §state§ = 'executing'", 1, true) then
          local plan = store.plan
          if not plan or plan.version ~= values[3]
            or (plan.state ~= 'pending' and plan.state ~= 'executing') then return 0 end
          plan.state = 'executing'
          plan.lease_fencing_token = values[1]
          plan.attempt_count = plan.attempt_count + 1
          plan.failure_code = nil
          plan.version = plan.version + 1
          return 1
        end
        if sql:find("UPDATE §synex_domain_deletion_actions§", 1, true)
          and sql:find("SET §state§ = 'completed'", 1, true) then
          local action = store.actions[values[2]]
          if not action or action.version ~= values[3] or action.state ~= 'pending' then return 0 end
          action.state = 'completed'
          action.version = action.version + 1
          action.attempt_count = action.attempt_count + 1
          action.completed_at = 'now'
          return 1
        end
        if sql:find("UPDATE §synex_domain_deletion_actions§", 1, true) then
          local action = store.actions[values[3]]
          if action then
            action.attempt_count = action.attempt_count + 1
            action.failure_code = values[1]
          end
          return action and 1 or 0
        end
        if sql:find("SET §state§ = 'pending'", 1, true) then
          local plan = store.plan
          if not plan or plan.version ~= values[3]
            or plan.lease_fencing_token ~= values[4] then return 0 end
          plan.state = 'pending'
          plan.failure_code = values[1]
          plan.lease_fencing_token = nil
          plan.version = plan.version + 1
          return 1
        end
        if sql:find("SET §state§ = 'completed'", 1, true) then
          local plan = store.plan
          if not plan or plan.version ~= values[3]
            or plan.lease_fencing_token ~= values[4] then return 0 end
          for _, action in ipairs(store.actions) do if action.state ~= 'completed' then return 0 end end
          plan.state = 'completed'
          plan.failure_code = nil
          plan.lease_fencing_token = nil
          plan.completed_at = 'now'
          plan.purge_after = 'future'
          plan.version = plan.version + 1
          return 1
        end
        error('unexpected update: ' .. sql)
      end
      local leases = {}
      function leases:acquire(name, owner, ttl, requesterInstanceId, requesterBootId)
        assert(requesterInstanceId == 'instance-a' and requesterBootId == 'boot-a')
        store.leaseFence = store.leaseFence + 1
        return {
          name = name, owner = owner, fencingToken = store.leaseFence,
          ttlSeconds = ttl, requesterInstanceId = requesterInstanceId,
          requesterBootId = requesterBootId
        }
      end
      function leases:renew() return true end
      function leases:release() store.released = store.released + 1 return true end
      local service = SynexCoreFactories.domainDeletion({
        platform = FakeDeletionPlatform,
        foundation = foundation,
        database = database,
        owners = registries.owners,
        leases = leases,
        instances = { bootId = function() return 'boot-a' end },
        sha256 = function(value)
          local digest = 0
          for index = 1, #value do
            digest = (digest * 131 + value:byte(index)) % 4294967296
          end
          return string.rep(string.format('%08x', digest), 8)
        end,
        instanceId = 'instance-a'
      })
      return {
        service = service, owners = registries.owners, epoch = epoch,
        store = store,
        definition = function(decision)
          decision = decision or 'delete'
          return {
            domain = 'group', name = 'groups.records', schemaVersion = 1,
            preflight = function(request)
              assert(request.domain == 'group' and request.subjectId == 'group_001')
              return { decision = decision, metadata = { marker = 'x' } }
            end,
            execute = function(request)
              store.executeCalls = store.executeCalls + 1
              assert(request.actionId:find(request.planId, 1, true) == 1)
              assert(request.decision == decision and request.metadata.marker == 'x')
              return true
            end
          }
        end
      }
    end
  `;
  await runtime.doString(source.replaceAll('§', '`'));
  return runtime;
}

test('generic deletion providers are owner-epoch bound and must rebind from durable catalog', async () => {
  const runtime = await engine();
  try {
    const result = await runtime.doString(`
      local fixture = NewDeletionFixture()
      local registration = assert(fixture.service:registerProvider(
        'synex_groups', fixture.epoch, fixture.definition()))
      assert(registration.domain == 'group' and registration.ownerEpoch == fixture.epoch)
      local cleanup = fixture.owners:purge('synex_groups', fixture.epoch, 'restart')
      assert(#cleanup.errors == 0 and #fixture.service:snapshot().providers == 0)
      local unavailable, unavailableError = fixture.service:plan('synex_groups', fixture.epoch, {
        domain = 'group', subjectId = 'group_001', idempotencyKey = 'delete-key-0001',
        reason = 'fixture', context = { request = 'fixture' }
      })
      assert(unavailable == nil and unavailableError.code == 'STALE_RESOURCE')
      local nextEpoch = fixture.owners:activate('synex_groups')
      fixture.store.queryLog = {}
      assert(fixture.service:registerProvider('synex_groups', nextEpoch, fixture.definition()))
      for _, operation in ipairs(fixture.store.queryLog) do
        assert(operation ~= 'schema_upgrade_guard')
      end
      assert(fixture.store.providerCount == 1)
      return table.concat({registration.ownerEpoch, nextEpoch, fixture.store.providerCount}, ':')
    `);
    assert.equal(result, '1:3:1');
  } finally {
    runtime.global.close();
  }
});

test('deletion plan claims preserve replay and reserve capacity in a fixed lock order', async () => {
  const runtime = await engine();
  try {
    const result = await runtime.doString(`
      local fixture = NewDeletionFixture()
      assert(fixture.service:registerProvider(
        'synex_groups', fixture.epoch, fixture.definition('allow')))
      local request = {
        domain = 'group', subjectId = 'group_001',
        idempotencyKey = 'deletion-capacity-replay-0001',
        reason = 'fixture', context = { request = 'fixture' }
      }
      fixture.store.queryLog = {}
      local first = assert(fixture.service:plan('synex_groups', fixture.epoch, request))
      assert(first.state == 'completed' and first.purgeAfter == 'future')
      assert(fixture.store.planCapacity == 1 and fixture.store.planOwnerCapacity == 1)

      local claimAt, requestAt, providerAt, globalAt, ownerAt
      for index, operation in ipairs(fixture.store.queryLog) do
        if operation == 'plan_claim' then claimAt = index end
        if claimAt and index > claimAt and operation == 'request_lock' and not requestAt then
          requestAt = index
        end
        if operation == 'provider_lock' then providerAt = index end
        if operation == 'global_lock' then globalAt = index end
        if operation == 'owner_lock' then ownerAt = index end
      end
      assert(claimAt and requestAt and providerAt and globalAt and ownerAt)
      assert(claimAt < requestAt and requestAt < providerAt
        and providerAt < globalAt and globalAt < ownerAt)

      fixture.store.queryLog = {}
      local replay = assert(fixture.service:plan('synex_groups', fixture.epoch, request))
      assert(replay.planId == first.planId and replay.version == first.version)
      assert(fixture.store.planCapacity == 1 and fixture.store.planOwnerCapacity == 1)
      assert(fixture.store.queryLog[1] == 'request_lock')
      assert(fixture.store.queryLog[2] == 'global_lock')
      assert(fixture.store.queryLog[3] == 'owner_initialize')
      assert(fixture.store.queryLog[4] == 'owner_lock')
      for _, operation in ipairs(fixture.store.queryLog) do
        assert(operation ~= 'plan_claim' and operation ~= 'provider_lock')
      end

      local conflicting = {
        domain = request.domain, subjectId = request.subjectId,
        idempotencyKey = request.idempotencyKey,
        reason = 'different request', context = request.context
      }
      local rejected, conflict = fixture.service:plan(
        'synex_groups', fixture.epoch, conflicting)
      assert(rejected == nil and conflict.code == 'IDEMPOTENCY_CONFLICT')
      assert(fixture.store.planCapacity == 1 and fixture.store.planOwnerCapacity == 1)
      return first.state .. ':' .. conflict.code
    `);
    assert.equal(result, 'completed:IDEMPOTENCY_CONFLICT');
  } finally {
    runtime.global.close();
  }
});

test('deletion plan capacity fails closed at global and owner limits', async () => {
  const runtime = await engine();
  try {
    const result = await runtime.doString(`
      local function rejected(options, key)
        local fixture = NewDeletionFixture(options)
        assert(fixture.service:registerProvider(
          'synex_groups', fixture.epoch, fixture.definition('allow')))
        local plan, planError = fixture.service:plan('synex_groups', fixture.epoch, {
          domain = 'group', subjectId = 'group_001', idempotencyKey = key,
          reason = 'fixture', context = {}
        })
        assert(plan == nil and planError.code == 'DELETION_PLAN_CAPACITY_EXCEEDED')
        assert(fixture.store.plan == nil and #fixture.store.actions == 0)
        assert(fixture.store.planCapacity == options.planCapacity)
        assert(fixture.store.planOwnerCapacity == options.planOwnerCapacity)
        return planError.details.scope
      end
      local globalScope = rejected({
        planCapacity = 1, planGlobalLimit = 1,
        planOwnerCapacity = 1, planOwnerLimit = 1,
        planOwnerInitialized = true
      }, 'deletion-global-capacity-0001')
      local ownerScope = rejected({
        planCapacity = 1, planGlobalLimit = 2,
        planOwnerCapacity = 1, planOwnerLimit = 1,
        planOwnerInitialized = true
      }, 'deletion-owner-capacity-0001')
      return globalScope .. ':' .. ownerScope
    `);
    assert.equal(result, 'global:owner');
  } finally {
    runtime.global.close();
  }
});

test('deletion plan persistence rolls back its claim and counters after a late failure', async () => {
  const runtime = await engine();
  try {
    const result = await runtime.doString(`
      local fixture = NewDeletionFixture({ failActionInsert = true })
      assert(fixture.service:registerProvider(
        'synex_groups', fixture.epoch, fixture.definition('allow')))
      local plan, planError = fixture.service:plan('synex_groups', fixture.epoch, {
        domain = 'group', subjectId = 'group_001',
        idempotencyKey = 'deletion-late-rollback-0001',
        reason = 'fixture', context = {}
      })
      assert(plan == nil and planError.code == 'DELETION_PLAN_PERSISTENCE_FAILED')
      assert(fixture.store.plan == nil and #fixture.store.actions == 0)
      assert(fixture.store.planCapacity == 0 and fixture.store.planOwnerCapacity == 0)
      assert(fixture.store.planOwnerInitialized == false)
      return planError.code
    `);
    assert.equal(result, 'DELETION_PLAN_PERSISTENCE_FAILED');
  } finally {
    runtime.global.close();
  }
});

test('terminal deletion retention compacts a bounded batch and releases exact counters', async () => {
  const runtime = await engine();
  try {
    const result = await runtime.doString(`
      local fixture = NewDeletionFixture()
      assert(fixture.service:registerProvider(
        'synex_groups', fixture.epoch, fixture.definition('allow')))
      local request = {
        domain = 'group', subjectId = 'group_001',
        idempotencyKey = 'deletion-terminal-retention-0001',
        reason = 'fixture', context = {}
      }
      local first = assert(fixture.service:plan('synex_groups', fixture.epoch, request))
      assert(first.state == 'completed' and first.purgeAfter == 'future')
      local replay = assert(fixture.service:plan('synex_groups', fixture.epoch, request))
      assert(replay.planId == first.planId)
      fixture.store.plan.purge_after = 'past'
      fixture.store.purgeReady = true
      fixture.store.queryLog = {}
      local report, reportError = fixture.service:reconcile(1)
      assert(report, reportError and reportError.code .. ':'
        .. table.concat(fixture.store.queryLog, ','))
      assert(report.compacted == 1 and report.compactedOwners == 1)
      assert(report.examined == 0 and report.completed == 0 and report.deferred == 0)
      assert(fixture.store.plan == nil and #fixture.store.actions == 0)
      assert(fixture.store.planCapacity == 0 and fixture.store.planOwnerCapacity == 0)
      assert(fixture.store.planOwnerInitialized == false)
      assert(fixture.store.queryLog[1] == 'plan_lock')
      assert(fixture.store.queryLog[2] == 'global_lock')
      assert(fixture.store.queryLog[3] == 'owner_lock')
      local renewed = assert(fixture.service:plan('synex_groups', fixture.epoch, request))
      assert(renewed.planId ~= first.planId and fixture.store.planCapacity == 1)
      return table.concat({report.compacted, report.compactedOwners,
        fixture.store.planCapacity}, ':')
    `);
    assert.equal(result, '1:1:1');
  } finally {
    runtime.global.close();
  }
});

test('nonterminal deletion plans remain retained and capacity counted', async () => {
  const runtime = await engine();
  try {
    const result = await runtime.doString(`
      local fixture = NewDeletionFixture()
      assert(fixture.service:registerProvider(
        'synex_groups', fixture.epoch, fixture.definition('delete')))
      local plan = assert(fixture.service:plan('synex_groups', fixture.epoch, {
        domain = 'group', subjectId = 'group_001',
        idempotencyKey = 'deletion-nonterminal-retention-0001',
        reason = 'fixture', context = {}
      }))
      assert(plan.state == 'pending' and plan.purgeAfter == nil,
        tostring(plan.state) .. ':' .. tostring(plan.purgeAfter))
      assert(fixture.store.planCapacity == 1 and fixture.store.planOwnerCapacity == 1)
      fixture.owners:purge('synex_groups', fixture.epoch, 'provider unavailable')
      fixture.store.purgeReady = true
      local report = assert(fixture.service:reconcile(1))
      assert(report.compacted == 0 and report.compactedOwners == 0)
      assert(report.examined == 1 and report.deferred == 1)
      assert(fixture.store.plan and fixture.store.plan.state == 'pending')
      assert(fixture.store.plan.purge_after == nil)
      assert(fixture.store.planCapacity == 1 and fixture.store.planOwnerCapacity == 1)
      return table.concat({report.compacted, report.deferred,
        fixture.store.planCapacity}, ':')
    `);
    assert.equal(result, '0:1:1');
  } finally {
    runtime.global.close();
  }
});

test('provider schema upgrades fail closed until every nonterminal action is drained', async () => {
  const runtime = await engine();
  try {
    const result = await runtime.doString(`
      local fixture = NewDeletionFixture()
      assert(fixture.service:registerProvider(
        'synex_groups', fixture.epoch, fixture.definition()))
      local plan = assert(fixture.service:plan('synex_groups', fixture.epoch, {
        domain = 'group', subjectId = 'group_001',
        idempotencyKey = 'delete-key-schema-upgrade', reason = 'fixture', context = {}
      }))
      assert(plan.state == 'pending' and plan.actions[1].providerSchemaVersion == 1)

      fixture.owners:purge('synex_groups', fixture.epoch, 'schema upgrade')
      local upgradedEpoch = fixture.owners:activate('synex_groups')
      local upgradedDefinition = fixture.definition()
      upgradedDefinition.schemaVersion = 2
      local upgraded, upgradeError = fixture.service:registerProvider(
        'synex_groups', upgradedEpoch, upgradedDefinition)
      assert(upgraded == nil and upgradeError.code == 'DELETION_PROVIDER_SCHEMA_IN_USE')
      assert(upgradeError.details.requiredSchemaVersion == 1)
      assert(upgradeError.details.requestedSchemaVersion == 2)
      assert(fixture.store.catalog.schema_version == 1)
      assert(#fixture.service:snapshot().providers == 0)

      assert(fixture.service:registerProvider(
        'synex_groups', upgradedEpoch, fixture.definition()))
      local completed = assert(fixture.service:process(
        'synex_groups', upgradedEpoch, plan.planId))
      assert(completed.state == 'completed' and completed.actions[1].state == 'completed')

      fixture.owners:purge('synex_groups', upgradedEpoch, 'drained schema upgrade')
      local finalEpoch = fixture.owners:activate('synex_groups')
      local finalDefinition = fixture.definition()
      finalDefinition.schemaVersion = 2
      local finalRegistration = assert(fixture.service:registerProvider(
        'synex_groups', finalEpoch, finalDefinition))
      assert(finalRegistration.schemaVersion == 2 and fixture.store.catalog.schema_version == 2)
      return table.concat({upgradeError.code, completed.state,
        finalRegistration.schemaVersion}, ':')
    `);
    assert.equal(result, 'DELETION_PROVIDER_SCHEMA_IN_USE:completed:2');
  } finally {
    runtime.global.close();
  }
});

test('plan persistence fences a provider schema change after preflight', async () => {
  const runtime = await engine();
  try {
    const result = await runtime.doString(`
      local fixture = NewDeletionFixture()
      local definition = fixture.definition()
      definition.preflight = function()
        fixture.store.catalog.schema_version = 2
        return { decision = 'delete', metadata = { marker = 'x' } }
      end
      assert(fixture.service:registerProvider(
        'synex_groups', fixture.epoch, definition))
      local plan, planError = fixture.service:plan('synex_groups', fixture.epoch, {
        domain = 'group', subjectId = 'group_001',
        idempotencyKey = 'delete-key-schema-race', reason = 'fixture', context = {}
      })
      assert(plan == nil and planError.code == 'DELETION_PROVIDER_SCHEMA_CHANGED')
      assert(planError.retryable == true)
      assert(planError.details.expectedSchemaVersion == 1)
      assert(planError.details.actualSchemaVersion == 2)
      assert(fixture.store.plan == nil and #fixture.store.actions == 0)
      return planError.code
    `);
    assert.equal(result, 'DELETION_PROVIDER_SCHEMA_CHANGED');
  } finally {
    runtime.global.close();
  }
});

test('completed actions do not require historical provider bindings during execution', async () => {
  const runtime = await engine();
  try {
    const result = await runtime.doString(`
      local fixture = NewDeletionFixture()
      local currentDefinition = fixture.definition()
      currentDefinition.name = 'groups.current'
      currentDefinition.schemaVersion = 2
      assert(fixture.service:registerProvider(
        'synex_groups', fixture.epoch, currentDefinition))
      fixture.store.plan = {
        plan_id = 'dplan_completed_binding', domain_name = 'group',
        subject_id = 'group_001', requester_owner = 'synex_groups',
        idempotency_key = 'completed-binding-key', request_hash = string.rep('b', 64),
        request_context_json = '{}', reason = 'fixture', state = 'pending',
        version = 1, attempt_count = 0, completed_at = nil
      }
      fixture.store.actions = {
        {
          provider_owner = 'synex_legacy', provider_name = 'legacy.records',
          provider_schema_version = 1, decision = 'delete',
          decision_reason = nil, metadata_json = '{"marker":"x"}',
          state = 'completed', version = 2, attempt_count = 1, completed_at = 'now'
        },
        {
          provider_owner = 'synex_groups', provider_name = 'groups.current',
          provider_schema_version = 2, decision = 'delete',
          decision_reason = nil, metadata_json = '{"marker":"x"}',
          state = 'pending', version = 1, attempt_count = 0, completed_at = nil
        }
      }
      local completed = assert(fixture.service:process(
        'synex_groups', fixture.epoch, fixture.store.plan.plan_id))
      assert(completed.state == 'completed')
      assert(completed.actions[1].state == 'completed')
      assert(completed.actions[2].state == 'completed')
      assert(fixture.store.executeCalls == 1)
      return completed.state .. ':' .. tostring(fixture.store.executeCalls)
    `);
    assert.equal(result, 'completed:1');
  } finally {
    runtime.global.close();
  }
});

test('generic deletion get and process are confined to the current requester owner epoch', async () => {
  const runtime = await engine();
  try {
    const result = await runtime.doString(`
      local fixture = NewDeletionFixture()
      assert(fixture.service:registerProvider(
        'synex_groups', fixture.epoch, fixture.definition()))
      local plan = assert(fixture.service:plan('synex_groups', fixture.epoch, {
        domain = 'group', subjectId = 'group_001', idempotencyKey = 'delete-key-owner-0001',
        reason = 'fixture', context = { request = 'fixture' }
      }))
      local accountEpoch = fixture.owners:activate('synex_accounts')
      local leaked, readError = fixture.service:get(
        'synex_accounts', accountEpoch, plan.planId)
      assert(leaked == nil and readError.code == 'DELETION_PLAN_NOT_FOUND')
      local executed, processError = fixture.service:process(
        'synex_accounts', accountEpoch, plan.planId)
      assert(executed == nil and processError.code == 'DELETION_PLAN_NOT_FOUND')
      assert(fixture.store.executeCalls == 0 and fixture.store.plan.state == 'pending')
      local owned = assert(fixture.service:get(
        'synex_groups', fixture.epoch, plan.planId))
      assert(owned.requesterOwner == 'synex_groups' and owned.subjectId == 'group_001')
      fixture.owners:purge('synex_groups', fixture.epoch, 'requester restart')
      local stale, staleError = fixture.service:get(
        'synex_groups', fixture.epoch, plan.planId)
      assert(stale == nil and staleError.code == 'STALE_RESOURCE')
      return table.concat({readError.code, processError.code, staleError.code}, ':')
    `);
    assert.equal(result,
      'DELETION_PLAN_NOT_FOUND:DELETION_PLAN_NOT_FOUND:STALE_RESOURCE');
  } finally {
    runtime.global.close();
  }
});

test('generic deletion rejects stale provider results from preflight and execution', async () => {
  const runtime = await engine();
  try {
    const result = await runtime.doString(`
      local preflightFixture = NewDeletionFixture()
      local preflightDefinition = preflightFixture.definition()
      preflightDefinition.preflight = function()
        assert(preflightFixture.owners:pendingCount(
          'synex_groups', preflightFixture.epoch) == 1)
        preflightFixture.owners:purge(
          'synex_groups', preflightFixture.epoch, 'restart during preflight')
        return { decision = 'delete', metadata = { marker = 'x' } }
      end
      assert(preflightFixture.service:registerProvider(
        'synex_groups', preflightFixture.epoch, preflightDefinition))
      local planned, preflightError = preflightFixture.service:plan(
        'synex_groups', preflightFixture.epoch, {
          domain = 'group', subjectId = 'group_001',
          idempotencyKey = 'delete-key-stale-preflight', reason = 'fixture', context = {}
        })
      assert(planned == nil and preflightError.code == 'DELETION_PROVIDER_UNAVAILABLE')
      assert(preflightFixture.store.plan == nil)

      local executeFixture = NewDeletionFixture()
      local executeDefinition = executeFixture.definition()
      executeDefinition.execute = function()
        executeFixture.store.executeCalls = executeFixture.store.executeCalls + 1
        assert(executeFixture.owners:pendingCount(
          'synex_groups', executeFixture.epoch) == 1)
        executeFixture.owners:purge(
          'synex_groups', executeFixture.epoch, 'restart during execute')
        return true
      end
      assert(executeFixture.service:registerProvider(
        'synex_groups', executeFixture.epoch, executeDefinition))
      local plan = assert(executeFixture.service:plan(
        'synex_groups', executeFixture.epoch, {
          domain = 'group', subjectId = 'group_001',
          idempotencyKey = 'delete-key-stale-execute', reason = 'fixture', context = {}
        }))
      local completed, executeError = executeFixture.service:process(
        'synex_groups', executeFixture.epoch, plan.planId)
      assert(completed == nil and executeError.code == 'DELETION_PROVIDER_UNAVAILABLE')
      assert(executeFixture.store.executeCalls == 1)
      assert(executeFixture.store.plan.state == 'pending')
      assert(executeFixture.store.actions[1].state == 'pending')
      return preflightError.code .. ':' .. executeError.code
    `);
    assert.equal(result,
      'DELETION_PROVIDER_UNAVAILABLE:DELETION_PROVIDER_UNAVAILABLE');
  } finally {
    runtime.global.close();
  }
});

test('generic group deletion persists a plan, retries unavailable providers, and completes with CAS fencing', async () => {
  const runtime = await engine();
  try {
    const result = await runtime.doString(`
      local fixture = NewDeletionFixture()
      assert(fixture.service:registerProvider('synex_groups', fixture.epoch, fixture.definition()))
      local plan = assert(fixture.service:plan('synex_groups', fixture.epoch, {
        domain = 'group', subjectId = 'group_001', idempotencyKey = 'delete-key-0002',
        reason = 'fixture', context = { request = 'fixture' }
      }))
      assert(plan.state == 'pending' and #plan.actions == 1)
      assert(plan.actions[1].decision == 'delete' and plan.actions[1].providerSchemaVersion == 1)
      fixture.owners:purge('synex_groups', fixture.epoch, 'restart before execution')
      local reboundEpoch = fixture.owners:activate('synex_groups')
      local deferred, deferredError = fixture.service:process(
        'synex_groups', reboundEpoch, plan.planId)
      assert(deferred == nil and deferredError.code == 'DELETION_PROVIDER_UNAVAILABLE')
      assert(fixture.store.plan.state == 'pending' and fixture.store.plan.failure_code == nil)
      assert(fixture.store.executeCalls == 0)
      assert(fixture.service:registerProvider('synex_groups', reboundEpoch, fixture.definition()))
      local completed = assert(fixture.service:process(
        'synex_groups', reboundEpoch, plan.planId))
      assert(completed.state == 'completed' and completed.actions[1].state == 'completed')
      assert(fixture.store.executeCalls == 1 and fixture.store.released == 1)
      return table.concat({completed.state, completed.version, fixture.store.executeCalls,
        fixture.store.released, reboundEpoch}, ':')
    `);
    assert.equal(result, 'completed:3:1:1:3');
  } finally {
    runtime.global.close();
  }
});

test('generic deletion rejects foreign domain ownership and malformed provider decisions', async () => {
  const runtime = await engine();
  try {
    const result = await runtime.doString(`
      local fixture = NewDeletionFixture()
      local foreign, foreignError = fixture.service:plan('synex_groups', fixture.epoch, {
        domain = 'account', subjectId = 'account_001', idempotencyKey = 'delete-key-0003',
        reason = 'fixture', context = {}
      })
      assert(foreign == nil and foreignError.code == 'DELETION_DOMAIN_FORBIDDEN')
      local invalidDefinition = fixture.definition()
      invalidDefinition.preflight = function() return { decision = 'destroy' } end
      assert(fixture.service:registerProvider('synex_groups', fixture.epoch, invalidDefinition))
      local invalid, invalidError = fixture.service:plan('synex_groups', fixture.epoch, {
        domain = 'group', subjectId = 'group_001', idempotencyKey = 'delete-key-0004',
        reason = 'fixture', context = {}
      })
      assert(invalid == nil and invalidError.code == 'INVALID_DELETION_DECISION')
      return foreignError.code .. ':' .. invalidError.code
    `);
    assert.equal(result, 'DELETION_DOMAIN_FORBIDDEN:INVALID_DELETION_DECISION');
  } finally {
    runtime.global.close();
  }
});

test('generic deletion persists exact allow, block, delete, anonymize, and retain semantics', async () => {
  const runtime = await engine();
  try {
    const result = await runtime.doString(`
      local outcomes = {}
      local decisions = {'allow', 'block', 'delete', 'anonymize', 'retain'}
      for index, decision in ipairs(decisions) do
        local fixture = NewDeletionFixture()
        assert(fixture.service:registerProvider(
          'synex_groups', fixture.epoch, fixture.definition(decision)))
        local plan = assert(fixture.service:plan('synex_groups', fixture.epoch, {
          domain = 'group', subjectId = 'group_001',
          idempotencyKey = 'decision-key-000' .. tostring(index),
          reason = 'fixture', context = {}
        }))
        if decision == 'delete' or decision == 'anonymize' then
          assert(plan.state == 'pending' and plan.actions[1].state == 'pending')
          plan = assert(fixture.service:process(
            'synex_groups', fixture.epoch, plan.planId))
          assert(plan.state == 'completed' and fixture.store.executeCalls == 1)
        elseif decision == 'block' then
          assert(plan.state == 'blocked' and plan.actions[1].state == 'completed')
          assert(fixture.store.executeCalls == 0)
        else
          assert(plan.state == 'completed' and plan.actions[1].state == 'completed')
          assert(fixture.store.executeCalls == 0)
        end
        outcomes[index] = decision .. '=' .. plan.state
      end
      return table.concat(outcomes, ':')
    `);
    assert.equal(result,
      'allow=completed:block=blocked:delete=completed:anonymize=completed:retain=completed');
  } finally {
    runtime.global.close();
  }
});
