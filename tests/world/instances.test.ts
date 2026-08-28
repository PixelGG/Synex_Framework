import assert from 'node:assert/strict';
import test from 'node:test';

import { runWorldLua } from './helpers.ts';

const instanceFiles = [
  'shared/limits.lua',
  'shared/validation.lua',
  'server/instances.lua',
] as const;

test('instance cleanup policies use empty-state TTL, owner-stop, and manual lifecycles', async () => {
  const result = await runWorldLua<string>(String.raw`
    local nowMs, nextInstance, nextBucket = 1000, 0, 0
    local templates = {
      ['synex_test:empty'] = { kind = 'instance_template', key = 'synex_test:empty',
        revision = 1, capacity = 4, isolationProfile = 'isolated_strict',
        cleanupPolicy = 'empty_ttl', ttlSeconds = 10, exit = { x = 1, y = 2, z = 3 } },
      ['synex_test:owner'] = { kind = 'instance_template', key = 'synex_test:owner',
        revision = 1, capacity = 4, isolationProfile = 'isolated_strict',
        cleanupPolicy = 'owner_stop', exit = { x = 1, y = 2, z = 3 } },
      ['synex_test:manual'] = { kind = 'instance_template', key = 'synex_test:manual',
        revision = 1, capacity = 4, isolationProfile = 'isolated_strict',
        cleanupPolicy = 'manual', exit = { x = 1, y = 2, z = 3 } },
    }
    local registry = {}
    function registry.get(key, kind)
      local value = templates[key]
      return value and value.kind == kind and value or nil
    end
    function registry.resolve(reference, kind)
      return type(reference) == 'table' and registry.get(reference.key, kind) or nil
    end
    function registry.ref(value)
      return { kind = value.kind, key = value.key, revision = value.revision }
    end
    local sessions = {
      [41] = { state = 'ACTIVE', id = 'session_00000041', sourceGeneration = 1,
        characterId = 'character_000041' },
      [42] = { state = 'ACTIVE', id = 'session_00000042', sourceGeneration = 1,
        characterId = 'character_000042' },
    }
    local destroyed, destroyCalls, joinMoveKeys = {}, 0, {}
    local function callContract(name, _, request, options)
      if name == 'synex.entities.bucket.create' then
        nextBucket = nextBucket + 1
        return { bucket = { bucket = nextBucket, generation = 1 } }
      end
      if name == 'synex.entities.bucket.move_player' then
        if request.bucket ~= 0 then joinMoveKeys[#joinMoveKeys + 1] = options.idempotencyKey end
        return { moved = true }
      end
      if name == 'synex.entities.bucket.destroy' then
        destroyCalls = destroyCalls + 1
        destroyed[request.bucket] = true
        return { destroyed = true }
      end
      error('unexpected entity contract')
    end
    local closedCalls, cleanupErrors = 0, 0
    local instances = SynexWorldInstances.create({
      mapRegistry = { objectAvailability = function() return { available = true } end,
        summary = function() return { generation = 1 } end },
      triggerClient = function() end,
      registry = registry,
      callContract = callContract,
      getPlayer = function(source) return sessions[source] end,
      nextId = function()
        nextInstance = nextInstance + 1
        return ('world_instance_%08d'):format(nextInstance)
      end,
      now = function() return nowMs end,
      utc = function() return '2026-08-27T12:00:00Z' end,
      onClosed = function(instanceId, closedSnapshot, callbackContext)
        closedCalls = closedCalls + 1
        assert(instanceId == closedSnapshot.instanceId)
        assert(closedSnapshot.state == 'CLOSED' and closedSnapshot.bucketRef == nil)
        assert(type(callbackContext) == 'table' and destroyCalls == closedCalls)
        if closedSnapshot.cleanupPolicy == 'owner_stop' then
          error('private cleanup implementation detail')
        end
        return true
      end,
      onCleanupError = function(failure)
        cleanupErrors = cleanupErrors + 1
        assert(failure.operation == 'instance.on_closed')
        assert(failure.code == 'INSTANCE_CLEANUP_CALLBACK_FAILED')
        assert(failure.message == nil)
      end,
    })
    local emptyContext = { caller = 'synex_empty_owner', callerEpoch = 4,
      traceId = 'trace_instance_empty_0001' }
    local lifecycleContext = { caller = 'synex_lifecycle_owner', callerEpoch = 4,
      traceId = 'trace_instance_lifecycle_0001' }
    local function create(key, suffix, context)
      return assert(instances.create({ templateKey = key,
        idempotencyKey = 'create_instance_' .. suffix }, context))
    end

    local empty = create('synex_test:empty', 'empty', emptyContext)
    local owner = create('synex_test:owner', 'owner', lifecycleContext)
    local manual = create('synex_test:manual', 'manual', lifecycleContext)
    assert(empty.expiresAtMs == 11000)
    assert(owner.expiresAtMs == nil and manual.expiresAtMs == nil)

    local joinedOne = assert(instances.join({ instanceId = empty.instanceId, source = 41,
      idempotencyKey = 'join_instance_shared' }, emptyContext))
    local joinedTwo = assert(instances.join({ instanceId = empty.instanceId, source = 42,
      idempotencyKey = 'join_instance_shared' }, emptyContext))
    assert(joinMoveKeys[1] ~= joinMoveKeys[2]
      and joinMoveKeys[1] ~= 'join_instance_shared'
      and joinMoveKeys[2] ~= 'join_instance_shared')
    assert(joinedOne.expiresAtMs == nil and joinedTwo.expiresAtMs == nil)
    nowMs = 3000
    local oneLeft = assert(instances.leave({ instanceId = empty.instanceId, source = 41,
      idempotencyKey = 'leave_instance_0041' }, emptyContext))
    assert(oneLeft.members == 1 and oneLeft.expiresAtMs == nil)
    local becameEmpty = assert(instances.leave({ instanceId = empty.instanceId, source = 42,
      idempotencyKey = 'leave_instance_0042' }, emptyContext))
    assert(becameEmpty.state == 'READY' and becameEmpty.expiresAtMs == 13000)

    nowMs = 4000
    local rejoined = assert(instances.join({ instanceId = empty.instanceId, source = 41,
      idempotencyKey = 'join_instance_again_0041' }, emptyContext))
    assert(rejoined.expiresAtMs == nil)
    instances.playerDropped(41)
    local dropped = assert(instances.get(empty.instanceId))
    assert(dropped.state == 'READY' and dropped.expiresAtMs == 14000)

    local ownerClosed = assert(instances.ownerStopped('synex_lifecycle_owner', 4,
      { traceId = 'trace_owner_stopped_0001' }))
    assert(ownerClosed == 2 and instances.get(owner.instanceId).state == 'CLOSED')
    assert(instances.get(manual.instanceId).state == 'CLOSED')
    assert(instances.close({ instanceId = owner.instanceId,
      idempotencyKey = 'owner_close_replay_0001' }, lifecycleContext).state == 'CLOSED')
    assert(instances.close({ instanceId = manual.instanceId,
      idempotencyKey = 'manual_close_replay_0001' }, lifecycleContext).state == 'CLOSED')
    assert(closedCalls == 2 and cleanupErrors == 1)
    assert(instances.get(empty.instanceId).state == 'READY')

    nowMs = 13999
    assert(instances.expire({ traceId = 'trace_expire_before_0001' }) == 0)
    nowMs = 14000
    assert(instances.expire({ traceId = 'trace_expire_due_0001' }) == 1)
    assert(instances.get(empty.instanceId).state == 'CLOSED')
    nowMs = 86400000
    assert(instances.expire({ traceId = 'trace_expire_policy_0001' }) == 0)
    local manualClosed = assert(instances.get(manual.instanceId))
    assert(manualClosed.state == 'CLOSED')
    assert(destroyed[1] and destroyed[2] and destroyed[3])
    assert(closedCalls == 3 and cleanupErrors == 1)
    return table.concat({ empty.expiresAtMs, becameEmpty.expiresAtMs,
      dropped.expiresAtMs, ownerClosed, manualClosed.state,
      closedCalls, cleanupErrors }, ':')
  `, instanceFiles);
  assert.equal(result, '11000:13000:14000:2:CLOSED:3:1');
});

test('instance ownership and source-generation fences reject stale or foreign mutations', async () => {
  const result = await runWorldLua<string>(String.raw`
    local template = { kind = 'instance_template', key = 'synex_test:fenced',
      revision = 1, capacity = 2, isolationProfile = 'isolated_strict',
      cleanupPolicy = 'manual', exit = { x = 4, y = 5, z = 6 } }
    local generation, moves, destroys, identifiers = 1, 0, 0, 0
    local instances = SynexWorldInstances.create({
      mapRegistry = { objectAvailability = function() return { available = true } end,
        summary = function() return { generation = 1 } end },
      triggerClient = function() end,
      registry = {
        get = function(key, kind)
          return key == template.key and kind == template.kind and template or nil
        end,
        resolve = function(reference, kind)
          return reference.key == template.key and kind == template.kind and template or nil
        end,
        ref = function(value) return { kind = value.kind, key = value.key,
          revision = value.revision } end,
      },
      callContract = function(name)
        if name == 'synex.entities.bucket.create' then
          return { bucket = { bucket = 71, generation = 'bucket_generation_0071' } }
        end
        if name == 'synex.entities.bucket.move_player' then moves = moves + 1; return { moved = true } end
        if name == 'synex.entities.bucket.destroy' then destroys = destroys + 1; return { destroyed = true } end
      end,
      getPlayer = function(source)
        return { state = 'ACTIVE', id = 'session_' .. generation,
          sourceGeneration = generation, characterId = 'character_00000051', source = source }
      end,
      nextId = function(namespace)
        identifiers = identifiers + 1
        return ('%s_%08d'):format(namespace or 'world', identifiers)
      end,
      now = function() return 1000 end,
      utc = function() return '2026-08-27T12:00:00Z' end,
    })
    local owner = { caller = 'synex_owner', callerEpoch = 4,
      traceId = 'trace_instance_fenced_0001' }
    local created = assert(instances.create({ templateKey = template.key,
      idempotencyKey = 'fenced_create_0001' }, owner))
    local _, foreignError = instances.join({ instanceId = created.instanceId, source = 51,
      idempotencyKey = 'fenced_join_foreign' }, { caller = 'synex_foreign',
        callerEpoch = 4, traceId = 'trace_instance_foreign_0001' })
    local _, epochError = instances.join({ instanceId = created.instanceId, source = 51,
      idempotencyKey = 'fenced_join_epoch' }, { caller = owner.caller,
        callerEpoch = 3, traceId = 'trace_instance_epoch_0001' })
    assert(foreignError.code == 'WORLD_ACCESS_DENIED' and epochError.code == 'STALE_RESOURCE')
    assert(instances.join({ instanceId = created.instanceId, source = 51,
      idempotencyKey = 'fenced_join_owner' }, owner))
    generation = 2
    local rejoined = assert(instances.join({ instanceId = created.instanceId, source = 51,
      idempotencyKey = 'fenced_join_reused' }, owner))
    assert(rejoined.members == 1 and moves == 2)
    generation = 3
    local left, leaveError = instances.leave({ instanceId = created.instanceId, source = 51,
      idempotencyKey = 'fenced_leave_stale' }, owner)
    assert(left == nil and leaveError.code == 'STALE_RESOURCE' and moves == 2)
    assert(instances.get(created.instanceId).members == 0)
    assert(instances.close({ instanceId = created.instanceId,
      idempotencyKey = 'fenced_close_0001' }, owner).state == 'CLOSED')
    assert(destroys == 1)
    return table.concat({ foreignError.code, epochError.code, leaveError.code,
      moves, destroys }, ':')
  `, instanceFiles);
  assert.equal(result, 'WORLD_ACCESS_DENIED:STALE_RESOURCE:STALE_RESOURCE:2:1');
});

test('instance join retries one ambiguous Entity move with the same internal receipt key', async () => {
  const result = await runWorldLua<string>(String.raw`
    local template = { kind = 'instance_template', key = 'synex_test:ambiguous',
      revision = 1, capacity = 2, isolationProfile = 'isolated_strict',
      cleanupPolicy = 'manual', exit = { x = 0, y = 0, z = 0 } }
    local identifiers, moveCalls, appliedMoves, moveKeys = 0, 0, 0, {}
    local instances = SynexWorldInstances.create({
      mapRegistry = { objectAvailability = function() return { available = true } end,
        summary = function() return { generation = 1 } end },
      triggerClient = function() end,
      registry = {
        get = function(key, kind)
          return key == template.key and kind == template.kind and template or nil
        end,
        resolve = function(reference, kind)
          return reference.key == template.key and kind == template.kind and template or nil
        end,
        ref = function(value)
          return { kind = value.kind, key = value.key, revision = value.revision }
        end,
      },
      callContract = function(name, _, request, options)
        if name == 'synex.entities.bucket.create' then
          return { bucket = { bucket = 91, generation = 3 } }
        end
        if name == 'synex.entities.bucket.move_player' then
          moveCalls = moveCalls + 1
          moveKeys[#moveKeys + 1] = options.idempotencyKey
          if moveCalls == 1 then
            return nil, { code = 'UNAVAILABLE', retryable = true }
          end
          appliedMoves = appliedMoves + 1
          return { moved = true }
        end
        if name == 'synex.entities.bucket.destroy' then return { destroyed = true } end
      end,
      getPlayer = function()
        return { state = 'ACTIVE', id = 'session_00000061', sourceGeneration = 4,
          characterId = 'character_00000061' }
      end,
      nextId = function(namespace)
        identifiers = identifiers + 1
        return ('%s_%08d'):format(namespace, identifiers)
      end,
      now = function() return 1000 end,
      utc = function() return '2026-08-28T12:00:00Z' end,
    })
    local context = { caller = 'synex_ambiguous', callerEpoch = 2,
      traceId = 'trace_ambiguous_join_0001' }
    local created = assert(instances.create({ templateKey = template.key,
      idempotencyKey = 'ambiguous_create_0001' }, context))
    local joined = assert(instances.join({ instanceId = created.instanceId, source = 61,
      idempotencyKey = 'ambiguous_join_0001' }, context))
    assert(moveCalls == 2 and appliedMoves == 1 and joined.members == 1)
    assert(moveKeys[1] == moveKeys[2] and moveKeys[1] ~= 'ambiguous_join_0001')
    assert(instances.getForSource(61).instanceId == created.instanceId)
    return table.concat({ moveCalls, appliedMoves, joined.members,
      moveKeys[1] == moveKeys[2] and 'same' or 'different' }, ':')
  `, instanceFiles);

  assert.equal(result, '2:1:1:same');
});

test('instance mutations serialize capacity, source ownership, close, and creating cancellation', async () => {
  const result = await runWorldLua<string>(String.raw`
    local templates = {
      ['synex_test:one'] = { kind = 'instance_template', key = 'synex_test:one',
        revision = 1, capacity = 1, isolationProfile = 'isolated_strict',
        cleanupPolicy = 'manual', exit = { x = 1, y = 2, z = 3 } },
      ['synex_test:cancel'] = { kind = 'instance_template', key = 'synex_test:cancel',
        revision = 1, capacity = 1, isolationProfile = 'isolated_strict',
        cleanupPolicy = 'owner_stop', exit = { x = 1, y = 2, z = 3 } },
    }
    local nextId, nextBucket, mode, nestedError, cancelDestroy = 0, 80, nil, nil, 0
    local instances
    local owner = { caller = 'synex_owner', callerEpoch = 7,
      traceId = 'trace_instance_serial_0001' }
    local cancelOwner = { caller = 'synex_cancel_owner', callerEpoch = 2,
      traceId = 'trace_instance_cancel_0001' }
    local sessions = {}
    for source = 61, 63 do sessions[source] = { state = 'ACTIVE',
      id = 'session_' .. source, sourceGeneration = 1,
      characterId = 'character_' .. source, source = source } end
    local function contract(name, _, request)
      if name == 'synex.entities.bucket.create' then
        nextBucket = nextBucket + 1
        if mode == 'cancel_create' then
          mode = nil
          assert(instances.ownerStopped(cancelOwner.caller, cancelOwner.callerEpoch,
            { traceId = cancelOwner.traceId }) == 1)
        end
        return { bucket = { bucket = nextBucket,
          generation = 'bucket_generation_' .. nextBucket } }
      end
      if name == 'synex.entities.bucket.move_player' then
        if mode == 'same_source' then
          mode = nil
          local _, operationError = instances.join({ instanceId = request.nestedInstance,
            source = request.source, idempotencyKey = 'nested_same_source_0001' }, owner)
          nestedError = operationError
        elseif mode == 'same_record' then
          mode = nil
          local _, operationError = instances.join({ instanceId = request.outerInstance,
            source = 63, idempotencyKey = 'nested_same_record_0001' }, owner)
          nestedError = operationError
        end
        return { moved = true }
      end
      if name == 'synex.entities.bucket.destroy' then
        if mode == 'double_close' then
          mode = nil
          local _, operationError = instances.close({ instanceId = request.outerInstance,
            idempotencyKey = 'nested_close_0001' }, owner)
          nestedError = operationError
        else
          cancelDestroy = cancelDestroy + 1
        end
        return { destroyed = true }
      end
    end
    -- Attach test-only nested identifiers to requests without changing production input.
    local currentOuter, currentNested
    local function callContract(name, version, request, options)
      request.outerInstance, request.nestedInstance = currentOuter, currentNested
      return contract(name, version, request, options)
    end
    instances = SynexWorldInstances.create({
      mapRegistry = { objectAvailability = function() return { available = true } end,
        summary = function() return { generation = 1 } end },
      triggerClient = function() end,
      registry = {
        get = function(key, kind)
          local value = templates[key]
          return value and value.kind == kind and value or nil
        end,
        resolve = function(reference, kind)
          local value = templates[reference.key]
          return value and value.kind == kind and value or nil
        end,
        ref = function(value) return { kind = value.kind, key = value.key,
          revision = value.revision } end,
      }, callContract = callContract,
      getPlayer = function(source) return sessions[source] end,
      nextId = function() nextId = nextId + 1; return ('world_instance_serial_%04d'):format(nextId) end,
      now = function() return 1000 end,
      utc = function() return '2026-08-27T12:00:00Z' end,
    })
    local function create(context, suffix, key)
      return assert(instances.create({ templateKey = key or 'synex_test:one',
        idempotencyKey = 'serial_create_' .. suffix }, context))
    end
    local first, second, capacity = create(owner, 'first'), create(owner, 'second'),
      create(owner, 'capacity')
    currentOuter, currentNested, mode = first.instanceId, second.instanceId, 'same_source'
    assert(instances.join({ instanceId = first.instanceId, source = 61,
      idempotencyKey = 'serial_join_first_0001' }, owner))
    assert(nestedError and nestedError.code == 'CONCURRENT_MODIFICATION')
    currentOuter, currentNested, mode = capacity.instanceId, nil, 'same_record'
    assert(instances.join({ instanceId = capacity.instanceId, source = 62,
      idempotencyKey = 'serial_join_capacity_0001' }, owner))
    assert(nestedError and nestedError.code == 'CONCURRENT_MODIFICATION'
      and instances.get(capacity.instanceId).members == 1)
    currentOuter, mode = capacity.instanceId, 'double_close'
    assert(instances.close({ instanceId = capacity.instanceId,
      idempotencyKey = 'serial_close_capacity_0001' }, owner).state == 'CLOSED')
    assert(nestedError and nestedError.code == 'CONCURRENT_MODIFICATION')
    mode = 'cancel_create'
    local cancelled, cancelError = instances.create({ templateKey = 'synex_test:cancel',
      idempotencyKey = 'serial_create_cancel' }, cancelOwner)
    assert(cancelled == nil and cancelError.code == 'STALE_RESOURCE' and cancelDestroy == 1)
    return table.concat({ nestedError.code, instances.get(capacity.instanceId).state,
      cancelError.code, cancelDestroy }, ':')
  `, instanceFiles);
  assert.equal(result, 'CONCURRENT_MODIFICATION:CLOSED:STALE_RESOURCE:1');
});

test('template deactivation and map outage drain foreign-owned instances with bounded retry', async () => {
  const result = await runWorldLua<string>(String.raw`
    local templates = {
      ['synex_companion:map_template'] = { kind = 'instance_template',
        key = 'synex_companion:map_template', revision = 1, capacity = 4,
        isolationProfile = 'isolated_strict', cleanupPolicy = 'manual',
        exit = { x = 11, y = 12, z = 13 } },
      ['synex_companion:bundle_template'] = { kind = 'instance_template',
        key = 'synex_companion:bundle_template', revision = 1, capacity = 4,
        isolationProfile = 'isolated_strict', cleanupPolicy = 'manual',
        exit = { x = 11, y = 12, z = 13 } },
    }
    local nextInstance, nextBucket, failedDestroy = 0, 100, false
    local moves, destroys, cleanupAudits = 0, 0, 0
    local registry = {}
    function registry.get(key, kind)
      local value = templates[key]
      return value and value.kind == kind and value or nil
    end
    function registry.resolve(reference, kind) return registry.get(reference.key, kind) end
    function registry.ref(value)
      return { kind = value.kind, key = value.key, revision = value.revision }
    end
    local instances = SynexWorldInstances.create({
      mapRegistry = { objectAvailability = function() return { available = true } end,
        summary = function() return { generation = 1 } end },
      triggerClient = function() end,
      registry = registry,
      callContract = function(name, _, request)
        if name == 'synex.entities.bucket.create' then
          nextBucket = nextBucket + 1
          return { bucket = { bucket = nextBucket, generation = nextBucket } }
        end
        if name == 'synex.entities.bucket.move_player' then
          if request.bucket == 0 then
            assert(request.bucketGeneration == 0)
            moves = moves + 1
          end
          return { moved = true }
        end
        if name == 'synex.entities.bucket.destroy' then
          destroys = destroys + 1
          if failedDestroy then
            failedDestroy = false
            return nil, { code = 'ENTITY_AUTHORITY_UNAVAILABLE', retryable = true }
          end
          return { destroyed = true }
        end
      end,
      getPlayer = function(source)
        return { state = 'ACTIVE', id = 'session_' .. source,
          sourceGeneration = 1, characterId = 'character_' .. source, source = source }
      end,
      nextId = function()
        nextInstance = nextInstance + 1
        return ('world_instance_template_%04d'):format(nextInstance)
      end,
      now = function() return 1000 end,
      utc = function() return '2026-08-27T12:00:00Z' end,
      audit = function(action)
        if action == 'world.instance_template_cleanup_failed' then
          cleanupAudits = cleanupAudits + 1
        end
      end,
    })
    local owner = { caller = 'synex_gameplay', callerEpoch = 9,
      traceId = 'trace_template_cleanup_0001' }
    local mapInstance = assert(instances.create({
      templateKey = 'synex_companion:map_template',
      idempotencyKey = 'template_map_create_0001' }, owner))
    assert(instances.join({ instanceId = mapInstance.instanceId, source = 81,
      idempotencyKey = 'template_map_join_0001' }, owner))
    local mapReport = assert(instances.reconcileTemplateAvailability(function(template)
      return template.key ~= 'synex_companion:map_template'
    end, { traceId = 'trace_map_outage_0001' }))
    local drained = assert(instances.get(mapInstance.instanceId))
    assert(mapReport.matched == 1 and mapReport.closed == 1 and mapReport.pending == 0)
    assert(drained.state == 'CLOSED' and drained.members == 0 and moves == 1)

    templates['synex_companion:map_template'].revision = 2
    local replacement = assert(instances.create({
      templateKey = 'synex_companion:map_template',
      idempotencyKey = 'template_map_create_0002' }, owner))
    assert(replacement.template.revision == 2 and replacement.state == 'READY')

    local bundleInstance = assert(instances.create({
      templateKey = 'synex_companion:bundle_template',
      idempotencyKey = 'template_bundle_create_0001' }, owner))
    failedDestroy = true
    local failed = assert(instances.deactivateTemplates({
      'synex_companion:bundle_template' }, { traceId = 'trace_bundle_stop_0001' }))
    assert(failed.matched == 1 and failed.failures == 1 and failed.pending == 1)
    assert(instances.get(bundleInstance.instanceId).state == 'FAILED')
    local retried = assert(instances.retryTemplateCleanup({
      traceId = 'trace_bundle_retry_0001' }))
    assert(retried.closed == 1 and retried.failures == 0 and retried.pending == 0)
    assert(instances.get(bundleInstance.instanceId).state == 'CLOSED')
    assert(cleanupAudits == 1 and destroys == 3)
    return table.concat({ mapReport.closed, moves, replacement.template.revision,
      failed.failures, retried.closed, cleanupAudits, destroys }, ':')
  `, instanceFiles);
  assert.equal(result, '1:1:2:1:1:1:3');
});

test('failed creates release capacity and closed history, list, and summary stay bounded', async () => {
  const result = await runWorldLua<string>(String.raw`
    local template = { kind = 'instance_template', key = 'synex_test:history',
      revision = 1, capacity = 1, isolationProfile = 'isolated_strict',
      cleanupPolicy = 'manual', exit = { x = 1, y = 2, z = 3 } }
    local nextId, nextInstance, nextBucket, failCreate, destroys = 0, 0, 200, true, 0
    local ids = {}
    local instances = SynexWorldInstances.create({
      mapRegistry = { objectAvailability = function() return { available = true } end,
        summary = function() return { generation = 1 } end },
      triggerClient = function() end,
      maximumClosedInstances = 3,
      registry = {
        get = function(key, kind)
          return key == template.key and kind == template.kind and template or nil
        end,
        resolve = function(reference, kind)
          return reference.key == template.key and kind == template.kind and template or nil
        end,
        ref = function(value) return { kind = value.kind, key = value.key,
          revision = value.revision } end,
      },
      callContract = function(name)
        if name == 'synex.entities.bucket.create' then
          if failCreate then failCreate = false; return nil,
            { code = 'ENTITY_UNAVAILABLE', retryable = false } end
          nextBucket = nextBucket + 1
          return { bucket = { bucket = nextBucket, generation = nextBucket } }
        end
        if name == 'synex.entities.bucket.destroy' then
          destroys = destroys + 1
          return { destroyed = true }
        end
      end,
      getPlayer = function() return nil end,
      nextId = function(namespace)
        nextId = nextId + 1
        if namespace == 'world_instance' then
          nextInstance = nextInstance + 1
          local id = ('world_instance_history_%04d'):format(nextInstance)
          ids[nextInstance] = id
          return id
        end
        return ('%s_%08d'):format(namespace or 'world', nextId)
      end,
      now = function() return 1000 end,
      utc = function() return '2026-08-27T12:00:00Z' end,
    })
    local owner = { caller = 'synex_history', callerEpoch = 1,
      traceId = 'trace_history_0001' }
    local failed, failedError = instances.create({ templateKey = template.key,
      idempotencyKey = 'history_create_failed_0001' }, owner)
    assert(failed == nil and failedError.code == 'INSTANCE_BUCKET_UNAVAILABLE')
    local afterFailure = instances.summary()
    assert(afterFailure.live == 0 and afterFailure.closed == 1
      and afterFailure.total == 1 and afterFailure.failed == 0)
    assert(instances.close({ instanceId = ids[1],
      idempotencyKey = 'history_close_failed_0001' }, owner).state == 'CLOSED')
    assert(destroys == 0)

    for index = 2, 6 do
      local created = assert(instances.create({ templateKey = template.key,
        idempotencyKey = 'history_create_' .. index }, owner))
      assert(instances.close({ instanceId = created.instanceId,
        idempotencyKey = 'history_close_' .. index }, owner).state == 'CLOSED')
    end
    local summary = instances.summary()
    assert(summary.total == 3 and summary.closed == 3 and summary.closedRetained == 3
      and summary.live == 0 and summary.members == 0 and summary.ready == 0)
    assert(instances.get(ids[1]) == nil and instances.get(ids[3]) == nil)
    local replay = assert(instances.close({ instanceId = ids[6],
      idempotencyKey = 'history_close_replay_0001' }, owner))
    assert(replay.state == 'CLOSED' and destroys == 5)

    local first, cursor = instances.list('', 2)
    local second, finalCursor = instances.list(cursor, 2)
    assert(#first == 2 and first[1].instanceId == ids[4]
      and first[2].instanceId == ids[5] and cursor == ids[5])
    assert(#second == 1 and second[1].instanceId == ids[6] and finalCursor == nil)
    return table.concat({ afterFailure.live, summary.total, summary.closedRetained,
      #first, #second, destroys }, ':')
  `, instanceFiles);
  assert.equal(result, '0:3:3:2:1:5');
});

test('join source reuse rolls back to bucket zero and owner cleanup remains exhaustive', async () => {
  const result = await runWorldLua<string>(String.raw`
    local template = { kind = 'instance_template', key = 'synex_test:rollback',
      revision = 1, capacity = 2, isolationProfile = 'isolated_strict',
      cleanupPolicy = 'owner_stop', exit = { x = 1, y = 2, z = 3 } }
    local nextId, nextBucket, generation = 0, 300, 1
    local rollbackMoves, destroyCalls, failFirstDestroy = 0, 0, false
    local instances = SynexWorldInstances.create({
      mapRegistry = { objectAvailability = function() return { available = true } end,
        summary = function() return { generation = 1 } end },
      triggerClient = function() end,
      registry = {
        get = function(key, kind)
          return key == template.key and kind == template.kind and template or nil
        end,
        resolve = function(reference, kind)
          return reference.key == template.key and kind == template.kind and template or nil
        end,
        ref = function(value) return { kind = value.kind, key = value.key,
          revision = value.revision } end,
      },
      callContract = function(name, _, request)
        if name == 'synex.entities.bucket.create' then
          nextBucket = nextBucket + 1
          return { bucket = { bucket = nextBucket, generation = nextBucket } }
        end
        if name == 'synex.entities.bucket.move_player' then
          if request.bucket == 0 then rollbackMoves = rollbackMoves + 1
          else generation = generation + 1 end
          return { moved = true }
        end
        if name == 'synex.entities.bucket.destroy' then
          destroyCalls = destroyCalls + 1
          if failFirstDestroy then failFirstDestroy = false
            return nil, { code = 'ENTITY_UNAVAILABLE', retryable = true } end
          return { destroyed = true }
        end
      end,
      getPlayer = function(source)
        return { state = 'ACTIVE', id = 'session_' .. generation,
          sourceGeneration = generation, characterId = 'character_' .. source, source = source }
      end,
      nextId = function()
        nextId = nextId + 1
        return ('world_instance_rollback_%04d'):format(nextId)
      end,
      now = function() return 1000 end,
      utc = function() return '2026-08-27T12:00:00Z' end,
    })
    local owner = { caller = 'synex_owner', callerEpoch = 4,
      traceId = 'trace_join_rollback_0001' }
    local sourceReuse = assert(instances.create({ templateKey = template.key,
      idempotencyKey = 'rollback_create_source_0001' }, owner))
    local joined, joinError = instances.join({ instanceId = sourceReuse.instanceId,
      source = 91, idempotencyKey = 'rollback_join_source_0001' }, owner)
    assert(joined == nil and joinError.code == 'STALE_RESOURCE' and rollbackMoves == 1)
    assert(instances.get(sourceReuse.instanceId).state == 'READY'
      and instances.get(sourceReuse.instanceId).members == 0)
    assert(instances.close({ instanceId = sourceReuse.instanceId,
      idempotencyKey = 'rollback_close_source_0001' }, owner))

    local first = assert(instances.create({ templateKey = template.key,
      idempotencyKey = 'rollback_create_first_0001' }, owner))
    local second = assert(instances.create({ templateKey = template.key,
      idempotencyKey = 'rollback_create_second_0001' }, owner))
    failFirstDestroy = true
    local cleaned, cleanupError = instances.ownerStopped(owner.caller, owner.callerEpoch,
      { traceId = 'trace_owner_exhaustive_0001' })
    assert(cleaned == nil and cleanupError.code == 'INSTANCE_BUCKET_UNAVAILABLE')
    assert(destroyCalls == 3)
    local firstState, secondState = instances.get(first.instanceId).state,
      instances.get(second.instanceId).state
    assert((firstState == 'FAILED' and secondState == 'CLOSED')
      or (firstState == 'CLOSED' and secondState == 'FAILED'))
    assert(instances.ownerStopped(owner.caller, owner.callerEpoch,
      { traceId = 'trace_owner_retry_0001' }) == 1)
    assert(instances.get(first.instanceId).state == 'CLOSED'
      and instances.get(second.instanceId).state == 'CLOSED')
    return table.concat({ joinError.code, rollbackMoves, destroyCalls,
      instances.summary().live }, ':')
  `, instanceFiles);
  assert.equal(result, 'STALE_RESOURCE:1:4:0');
});

test('closed instance state cleanup retries from a bounded queue until completion', async () => {
  const result = await runWorldLua<string>(String.raw`
    local template = { kind = 'instance_template', key = 'synex_test:cleanup_retry',
      revision = 1, capacity = 1, isolationProfile = 'isolated_strict',
      cleanupPolicy = 'manual', exit = { x = 1, y = 2, z = 3 } }
    local callbackCalls, cleanupErrors = 0, 0
    local instances = SynexWorldInstances.create({
      mapRegistry = { objectAvailability = function() return { available = true } end,
        summary = function() return { generation = 1 } end },
      triggerClient = function() end,
      registry = {
        get = function(key, kind)
          return key == template.key and kind == template.kind and template or nil
        end,
        resolve = function(reference, kind)
          return reference.key == template.key and kind == template.kind and template or nil
        end,
        ref = function(value) return { kind = value.kind, key = value.key,
          revision = value.revision } end,
      },
      callContract = function(name)
        if name == 'synex.entities.bucket.create' then
          return { bucket = { bucket = 401, generation = 1 } }
        end
        if name == 'synex.entities.bucket.destroy' then return { destroyed = true } end
      end,
      getPlayer = function() return nil end,
      nextId = function(namespace)
        if namespace == 'world_instance' then
          return 'world_instance_cleanup_retry_0001'
        end
        return namespace .. '_cleanup_retry_0001'
      end,
      now = function() return 1000 end,
      utc = function() return '2026-08-27T12:00:00Z' end,
      onClosed = function(instanceId, snapshot)
        callbackCalls = callbackCalls + 1
        assert(instanceId == snapshot.instanceId and snapshot.state == 'CLOSED')
        if callbackCalls == 1 then
          return nil, { code = 'DATABASE_UNAVAILABLE', retryable = true }
        end
        return true
      end,
      onCleanupError = function(failure)
        cleanupErrors = cleanupErrors + 1
        assert(failure.instanceId == 'world_instance_cleanup_retry_0001')
      end,
    })
    local owner = { caller = 'synex_cleanup', callerEpoch = 1,
      traceId = 'trace_cleanup_retry_0001' }
    local created = assert(instances.create({ templateKey = template.key,
      idempotencyKey = 'cleanup_retry_create_0001' }, owner))
    assert(instances.close({ instanceId = created.instanceId,
      idempotencyKey = 'cleanup_retry_close_0001' }, owner).state == 'CLOSED')
    assert(instances.summary().pendingStateCleanups == 1 and cleanupErrors == 1)
    local retried = assert(instances.retryClosedCleanup(25,
      { traceId = 'trace_cleanup_retry_worker_0001' }))
    assert(retried.attempted == 1 and retried.completed == 1
      and retried.failures == 0 and retried.pending == 0)
    assert(instances.summary().pendingStateCleanups == 0 and callbackCalls == 2)
    return table.concat({ cleanupErrors, callbackCalls, retried.completed,
      instances.summary().pendingStateCleanups }, ':')
  `, instanceFiles);
  assert.equal(result, '1:2:1:0');
});

test('lost bucket-create responses and failed destroys converge through bounded stable-key recovery', async () => {
  const result = await runWorldLua<string>(String.raw`
    local template = { kind = 'instance_template', key = 'synex_test:bucket_recovery',
      revision = 1, capacity = 1, isolationProfile = 'isolated_strict',
      cleanupPolicy = 'owner_stop', exit = { x = 1, y = 2, z = 3 } }
    local instances
    local createCalls, destroyCalls, ids = 0, 0, {}
    local createKey, destroyKey
    local callContract = function(name, _, request, options)
      assert(type(options.idempotencyKey) == 'string'
        and #options.idempotencyKey <= 36)
      if name == 'synex.entities.bucket.create' then
        createCalls = createCalls + 1
        createKey = createKey or options.idempotencyKey
        assert(options.idempotencyKey == createKey)
        if createCalls == 1 then
          assert(instances.ownerStopped('synex_recovery', 4,
            { traceId = 'trace_owner_stop_during_create' }) == 1)
          return nil, { code = 'CORE_TIMEOUT', retryable = true }
        end
        return { bucket = { bucket = 611, generation = 'bucket_generation_0611' } }
      end
      if name == 'synex.entities.bucket.destroy' then
        destroyCalls = destroyCalls + 1
        destroyKey = destroyKey or options.idempotencyKey
        assert(options.idempotencyKey == destroyKey and destroyKey ~= createKey)
        if destroyCalls == 1 then
          return nil, { code = 'ENTITY_UNAVAILABLE', retryable = true }
        end
        return { destroyed = true }
      end
    end
    instances = SynexWorldInstances.create({
      mapRegistry = { objectAvailability = function() return { available = true } end,
        summary = function() return { generation = 1 } end },
      triggerClient = function() end,
      registry = {
        get = function(key, kind)
          return key == template.key and kind == template.kind and template or nil
        end,
        resolve = function(reference, kind)
          return reference.key == template.key and kind == template.kind and template or nil
        end,
        ref = function(value) return { kind = value.kind, key = value.key,
          revision = value.revision } end,
      },
      callContract = callContract, getPlayer = function() return nil end,
      nextId = function(namespace)
        ids[namespace] = (ids[namespace] or 0) + 1
        return ('%s_%08d'):format(namespace, ids[namespace])
      end,
      now = function() return 1000 end,
      utc = function() return '2026-08-27T12:00:00Z' end,
    })
    local created, createError = instances.create({ templateKey = template.key,
      idempotencyKey = 'external_create_0001' }, {
      caller = 'synex_recovery', callerEpoch = 4, traceId = 'trace_create_lost' })
    assert(created == nil and createError.code == 'STALE_RESOURCE')
    local failed = instances.summary()
    assert(failed.failed == 1 and failed.pendingBucketRecoveries == 1
      and failed.live == 1)
    local first = assert(instances.retryBucketRecovery(1,
      { traceId = 'trace_recovery_first' }))
    assert(first.attempted == 1 and first.failures == 1 and first.pending == 1
      and instances.get('world_instance_00000001').state == 'FAILED')
    local second = assert(instances.retryBucketRecovery(1,
      { traceId = 'trace_recovery_second' }))
    local closed = assert(instances.get('world_instance_00000001'))
    assert(second.completed == 1 and second.pending == 0 and closed.state == 'CLOSED'
      and closed.bucketRef == nil and instances.summary().live == 0)
    return table.concat({ createCalls, destroyCalls, failed.pendingBucketRecoveries,
      second.pending, closed.state }, ':')
  `, instanceFiles);
  assert.equal(result, '2:2:1:0:CLOSED');
});

test('template exits are server-authoritative, fenced, compensated, and applied during drain', async () => {
  const result = await runWorldLua<string>(String.raw`
    local template = { kind = 'instance_template', key = 'synex_test:exit',
      revision = 7, capacity = 4, isolationProfile = 'isolated_strict',
      cleanupPolicy = 'manual', exit = { x = 410.5, y = -20.25, z = 31.0 } }
    local registryRevision, mapGeneration, mapAvailable = 7, 3, true
    local identifier, bucket, sessionGeneration = 0, 700, 1
    local mode, exitMoves, rollbackMoves, joinRollbacks, destroys, clientCalls =
      nil, 0, 0, 0, 0, {}
    local generatedKeys = {}
    local registry = {
      get = function(key, kind)
        return key == template.key and kind == template.kind and template or nil
      end,
      resolve = function(reference, kind)
        if reference.key == template.key and reference.revision == template.revision
          and kind == template.kind then return template end
        return nil, { code = 'STALE_WORLD_REF', retryable = true }
      end,
      ref = function(value) return { kind = value.kind, key = value.key,
        revision = value.revision } end,
      currentRevision = function() return registryRevision end,
    }
    local mapRegistry = {
      objectAvailability = function() return { available = mapAvailable, reasons = {} } end,
      summary = function() return { generation = mapGeneration } end,
    }
    local function nextId(namespace)
      identifier = identifier + 1
      return ('%s_%08d'):format(namespace or 'world', identifier)
    end
    local instances = SynexWorldInstances.create({
      registry = registry, mapRegistry = mapRegistry,
      callContract = function(name, _, request, options)
        if name == 'synex.entities.bucket.create' then
          bucket = bucket + 1
          if mode == 'create_refresh' then registryRevision = registryRevision + 1 end
          return { bucket = { bucket = bucket, generation = 'bucket_generation_0701' } }
        end
        if name == 'synex.entities.bucket.move_player' then
          if request.bucket == 0 and options.idempotencyKey:match('^wxm_') then
            exitMoves = exitMoves + 1
            assert(#options.idempotencyKey >= 8 and #options.idempotencyKey <= 36)
            assert(not generatedKeys[options.idempotencyKey])
            generatedKeys[options.idempotencyKey] = true
            if mode == 'source_reuse' then sessionGeneration = sessionGeneration + 1 end
            if mode == 'definition_refresh' then registryRevision = registryRevision + 1 end
          elseif request.bucket == bucket and options.idempotencyKey:match('^wxr_') then
            rollbackMoves = rollbackMoves + 1
            assert(#options.idempotencyKey >= 8 and #options.idempotencyKey <= 36)
            assert(not generatedKeys[options.idempotencyKey])
            generatedKeys[options.idempotencyKey] = true
          elseif request.bucket == bucket and mode == 'join_map_outage' then
            mapAvailable = false
          elseif request.bucket == 0 and options.idempotencyKey:match('^wxjr_') then
            joinRollbacks = joinRollbacks + 1
            assert(#options.idempotencyKey <= 36)
          end
          return { moved = true }
        end
        if name == 'synex.entities.bucket.destroy' then
          destroys = destroys + 1
          return { destroyed = true }
        end
        error('unexpected Entity contract')
      end,
      getPlayer = function(source)
        return { state = 'ACTIVE', id = 'session_' .. sessionGeneration,
          sourceGeneration = sessionGeneration, characterId = 'character_' .. source,
          source = source }
      end,
      nextId = nextId, now = function() return 1000 end,
      utc = function() return '2026-08-27T12:00:00Z' end,
      triggerClient = function(source, event, payload)
        assert(event == 'synex_world:client:apply_transition')
        assert(payload.destination.x == template.exit.x
          and payload.destination.y == template.exit.y
          and payload.destination.z == template.exit.z)
        assert(payload.revision == template.revision and #payload.grantId <= 36)
        clientCalls[#clientCalls + 1] = { source = source, grantId = payload.grantId }
      end,
    })
    local owner = { caller = 'synex_exit_owner', callerEpoch = 2,
      traceId = 'trace_exit_authority_0001' }

    mapAvailable = false
    local unavailableCreate, unavailableCreateError = instances.create({
      templateKey = template.key, idempotencyKey = 'exit_create_map_off01' }, owner)
    assert(unavailableCreate == nil
      and unavailableCreateError.code == 'MAP_PACKAGE_UNAVAILABLE' and bucket == 700)
    mapAvailable, mode = true, 'create_refresh'
    local staleCreate, staleCreateError = instances.create({ templateKey = template.key,
      idempotencyKey = 'exit_create_stale001' }, owner)
    mode = nil
    assert(staleCreate == nil and staleCreateError.code == 'STALE_WORLD_REF'
      and destroys == 1)

    local created = assert(instances.create({ templateKey = template.key,
      idempotencyKey = 'exit_create_00000001' }, owner))

    mode = 'join_map_outage'
    local unavailableJoin, unavailableJoinError = instances.join({
      instanceId = created.instanceId, source = 99,
      idempotencyKey = 'exit_join_map_000099' }, owner)
    mode, mapAvailable = nil, true
    assert(unavailableJoin == nil and unavailableJoinError.code == 'MAP_PACKAGE_UNAVAILABLE'
      and joinRollbacks == 1 and instances.get(created.instanceId).members == 0)

    assert(instances.join({ instanceId = created.instanceId, source = 101,
      idempotencyKey = 'exit_join_00000101' }, owner))
    local left = assert(instances.leave({ instanceId = created.instanceId, source = 101,
      idempotencyKey = 'exit_leave_0000101' }, owner))
    assert(left.transitioned == true and left.grantId == clientCalls[1].grantId
      and left.members == 0 and clientCalls[1].source == 101)

    assert(instances.join({ instanceId = created.instanceId, source = 101,
      idempotencyKey = 'exit_rejoin_0000101' }, owner))
    mode = 'source_reuse'
    local stale, staleError = instances.leave({ instanceId = created.instanceId,
      source = 101, idempotencyKey = 'exit_stale_00000101' }, owner)
    mode = nil
    assert(stale == nil and staleError.code == 'STALE_RESOURCE'
      and instances.get(created.instanceId).members == 0 and #clientCalls == 1)

    assert(instances.join({ instanceId = created.instanceId, source = 102,
      idempotencyKey = 'exit_join_00000102' }, owner))
    mode = 'definition_refresh'
    local refreshed, refreshError = instances.leave({ instanceId = created.instanceId,
      source = 102, idempotencyKey = 'exit_refresh_000102' }, owner)
    mode = nil
    assert(refreshed == nil and refreshError.code == 'STALE_WORLD_REF'
      and instances.get(created.instanceId).members == 1 and rollbackMoves == 1
      and #clientCalls == 1)

    mapAvailable = false
    local unavailable, unavailableError = instances.leave({ instanceId = created.instanceId,
      source = 102, idempotencyKey = 'exit_map_off_000102' }, owner)
    assert(unavailable == nil and unavailableError.code == 'MAP_PACKAGE_UNAVAILABLE'
      and instances.get(created.instanceId).members == 1)
    local closed = assert(instances.close({ instanceId = created.instanceId,
      idempotencyKey = 'exit_close_000001' }, owner))
    assert(closed.state == 'CLOSED' and closed.transitionedMembers == 1
      and closed.members == 0 and #clientCalls == 2 and clientCalls[2].source == 102)
    assert(instances.summary().pendingExitTransitions == 0)
    return table.concat({ unavailableCreateError.code, staleCreateError.code,
      unavailableJoinError.code, left.transitioned and 'exit', staleError.code,
      refreshError.code, unavailableError.code, exitMoves, rollbackMoves,
      joinRollbacks, destroys, closed.transitionedMembers, #clientCalls }, ':')
  `, instanceFiles);
  assert.equal(result,
    'MAP_PACKAGE_UNAVAILABLE:STALE_WORLD_REF:MAP_PACKAGE_UNAVAILABLE:exit:'
    + 'STALE_RESOURCE:STALE_WORLD_REF:MAP_PACKAGE_UNAVAILABLE:4:1:1:2:1:2');
});

test('empty instance TTL remains monotonic across signed GetGameTimer wrap', async () => {
  const result = await runWorldLua<string>(String.raw`
    local raw = 2147483646
    local clock = SynexWorldValidation.monotonicClock(function() return raw end)
    local template = { kind = 'instance_template', key = 'synex_test:timer', revision = 1,
      capacity = 2, isolationProfile = 'isolated_strict', cleanupPolicy = 'empty_ttl',
      ttlSeconds = 10, exit = { x = 0, y = 0, z = 0 } }
    local registry = {
      get = function(key, kind)
        return key == template.key and kind == template.kind and template or nil
      end,
      resolve = function(reference, kind)
        return reference.key == template.key and reference.revision == template.revision
          and kind == template.kind and template or nil
      end,
      ref = function(value) return { kind = value.kind, key = value.key,
        revision = value.revision } end,
    }
    local ids, destroys = {}, 0
    local instances = SynexWorldInstances.create({
      registry = registry,
      mapRegistry = { objectAvailability = function() return { available = true } end,
        summary = function() return { generation = 1 } end },
      callContract = function(name)
        if name == 'synex.entities.bucket.create' then
          return { bucket = { bucket = 42, generation = 3 } }
        end
        if name == 'synex.entities.bucket.destroy' then
          destroys = destroys + 1
          return { destroyed = true }
        end
        error('unexpected entity operation')
      end,
      getPlayer = function() return nil end,
      nextId = function(namespace)
        ids[namespace] = (ids[namespace] or 0) + 1
        return ('%s_%08d'):format(namespace, ids[namespace])
      end,
      now = clock, utc = function() return '2026-08-27T12:00:00Z' end,
      triggerClient = function() end,
    })
    local owner = { caller = 'synex_timer', callerEpoch = 1,
      traceId = 'trace_timer_wrap_0001' }
    local created = assert(instances.create({ templateKey = template.key,
      idempotencyKey = 'timer_create_0001' }, owner))
    raw = -2147473651 -- 9,999 milliseconds after the initial signed value
    assert(instances.expire({ traceId = 'trace_timer_before' }) == 0)
    raw = -2147473650 -- exactly 10,000 milliseconds after creation
    assert(instances.expire({ traceId = 'trace_timer_due' }) == 1)
    local closed = assert(instances.get(created.instanceId))
    assert(closed.state == 'CLOSED' and destroys == 1)
    return table.concat({ created.instanceId, created.expiresAtMs,
      closed.state, destroys }, ':')
  `, instanceFiles);
  assert.equal(result, 'world_instance_00000001:2147493646:CLOSED:1');
});
