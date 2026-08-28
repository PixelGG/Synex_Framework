import assert from 'node:assert/strict';
import test from 'node:test';

import { runWorldLua } from './helpers.ts';

const accessFiles = [
  'shared/limits.lua',
  'shared/validation.lua',
  'server/access.lua',
] as const;

test('world access composes map, instance, state and capability gates fail closed', async () => {
  const result = await runWorldLua<string>(String.raw`
    local location = { kind = 'location', key = 'synex_test:station', revision = 3 }
    local portal = { kind = 'portal', key = 'synex_test:secure.portal', revision = 7,
      parent = location.key, enabled = true,
      accessPolicy = {
        requireSameInstance = true,
        requiredCapability = 'world.secure.enter',
        groupId = 'group_00000001',
        scope = 'subtree',
        stateRequirements = {
          { key = 'synex_test:lockdown', operator = 'equals', value = false },
          { key = 'synex_test:station.open', operator = 'equals', value = true },
          { key = 'synex_test:instance.ready', operator = 'not_equals', value = false },
        },
      },
    }
    local door = { kind = 'door', key = 'synex_test:secure.door', revision = 4,
      parent = location.key, accessPolicy = {} }
    local definitions = {
      ['synex_test:lockdown'] = { kind = 'world_state_definition',
        key = 'synex_test:lockdown', revision = 1, scope = 'global' },
      ['synex_test:station.open'] = { kind = 'world_state_definition',
        key = 'synex_test:station.open', revision = 1, scope = 'location' },
      ['synex_test:instance.ready'] = { kind = 'world_state_definition',
        key = 'synex_test:instance.ready', revision = 1, scope = 'instance' },
    }
    local objects = {
      [location.key] = location,
      [portal.key] = portal,
      [door.key] = door,
    }
    for key, value in pairs(definitions) do objects[key] = value end

    local registry = {}
    function registry.get(key, kind)
      local value = objects[key]
      if not value or kind and value.kind ~= kind then
        return SynexWorldValidation.failure('WORLD_NOT_FOUND', 'not found')
      end
      return value
    end
    function registry.resolve(reference, kind)
      local normalized, referenceError = SynexWorldValidation.worldRef(reference, kind)
      if not normalized then return nil, referenceError end
      local value = objects[normalized.key]
      if not value then return SynexWorldValidation.failure('WORLD_NOT_FOUND', 'not found') end
      if value.revision ~= normalized.revision then
        return SynexWorldValidation.failure('STALE_WORLD_REF', 'stale')
      end
      return value
    end
    function registry.ref(value)
      return { kind = value.kind, key = value.key, revision = value.revision }
    end

    local mapAvailable, mapGeneration, capabilityDecision = true, 1, 'ALLOW'
    local membership = { instanceId = 'world_instance_00000001' }
    local stateValues = {
      ['synex_test:lockdown'] = false,
      ['synex_test:station.open'] = true,
      ['synex_test:instance.ready'] = true,
    }
    local capabilityCalls, explainCalls = 0, 0
    local access = SynexWorldAccess.create({
      registry = registry,
      mapRegistry = { objectAvailability = function()
        return { available = mapAvailable }
      end, summary = function() return { generation = mapGeneration } end },
      getPlayer = function(source)
        assert(source == 41)
        return { state = 'ACTIVE', characterId = 'character_00000041',
          id = 'session_00000041', source = source, sourceGeneration = 5 }
      end,
      groupCapability = function(request)
        capabilityCalls = capabilityCalls + 1
        assert(request.character_id == 'character_00000041')
        assert(request.group_id == 'group_00000001')
        assert(request.capability == 'world.secure.enter' and request.scope == 'subtree')
        return { decision = capabilityDecision, reason = 'fixture' }
      end,
      groupExplain = function(request)
        explainCalls = explainCalls + 1
        return { decision = capabilityDecision, reason = 'fixture_explain' }
      end,
      getState = function(request)
        local value = stateValues[request.key]
        if value == nil then return SynexWorldValidation.failure('WORLD_STATE_NOT_FOUND', 'missing') end
        if request.key == 'synex_test:station.open' then
          assert(request.scopeRef == location.key)
        elseif request.key == 'synex_test:instance.ready' then
          assert(request.scopeRef == membership.instanceId)
        else
          assert(request.scopeRef == nil)
        end
        return { value = value, version = 1, definitionRevision = 1 }
      end,
      getDoorState = function() return { state = 'LOCKED' } end,
      getInstanceForSource = function() return membership end,
    })

    local request = { source = 41, targetKey = portal.key,
      instanceId = membership.instanceId }
    local allowed = assert(access.check(request, { traceId = 'trace_access_allow_0001' }))
    assert(allowed.decision == 'ALLOW' and allowed.reason == 'ACCESS_GRANTED')
    local explained = assert(access.explain(request, { traceId = 'trace_access_explain_0001' }))
    assert(explained.decision == 'ALLOW' and #explained.evaluation == 6,
      'unexpected explain result ' .. tostring(explained.decision)
        .. ':' .. tostring(#explained.evaluation))
    assert(capabilityCalls == 1 and explainCalls == 1,
      'unexpected capability port calls ' .. capabilityCalls .. ':' .. explainCalls)

    capabilityDecision = 'DENY'
    local capabilityDenied = assert(access.check(request, {}))
    assert(capabilityDenied.decision == 'DENY'
      and capabilityDenied.reason == 'MISSING_CAPABILITY')
    capabilityDecision = 'ALLOW'

    stateValues['synex_test:station.open'] = false
    local stateDenied = assert(access.check(request, {}))
    assert(stateDenied.decision == 'DENY' and stateDenied.reason == 'WORLD_STATE_DENIED',
      'unexpected state denial ' .. tostring(stateDenied.decision)
        .. ':' .. tostring(stateDenied.reason))
    stateValues['synex_test:station.open'] = true

    membership = nil
    local instanceDenied = assert(access.check(request, {}))
    assert(instanceDenied.decision == 'DENY' and instanceDenied.reason == 'WRONG_INSTANCE',
      'unexpected instance denial ' .. tostring(instanceDenied.decision)
        .. ':' .. tostring(instanceDenied.reason))
    membership = { instanceId = 'world_instance_00000001' }

    mapAvailable = false
    local mapDenied = assert(access.check(request, {}))
    assert(mapDenied.decision == 'DENY' and mapDenied.reason == 'MAP_UNAVAILABLE'
      and mapDenied.retryable == true)
    mapAvailable = true

    portal.enabled = false
    local disabled = assert(access.check(request, {}))
    assert(disabled.decision == 'DENY' and disabled.reason == 'TARGET_DISABLED')
    portal.enabled = true

    local _, staleError = access.check({ source = 41,
      targetRef = { kind = 'portal', key = portal.key, revision = 6 },
      instanceId = membership.instanceId }, {})
    assert(staleError and staleError.code == 'STALE_WORLD_REF')
    return table.concat({ allowed.decision, stateDenied.reason,
      instanceDenied.reason, disabled.reason, staleError.code }, ':')
  `, accessFiles);

  assert.equal(result,
    'ALLOW:WORLD_STATE_DENIED:WRONG_INSTANCE:TARGET_DISABLED:STALE_WORLD_REF');
});

test('world access denies disabled door state without consulting capabilities', async () => {
  const result = await runWorldLua<string>(String.raw`
    local door = { kind = 'door', key = 'synex_test:disabled.door', revision = 2,
      accessPolicy = { requiredCapability = 'world.door.use',
        groupId = 'group_00000002', stateRequirements = {} } }
    local registry = {
      get = function(key) if key == door.key then return door end end,
      resolve = function(reference) return reference.revision == door.revision and door or nil end,
      ref = function(value) return { kind = value.kind, key = value.key,
        revision = value.revision } end,
    }
    local capabilityCalls, doorFailure = 0, false
    local access = SynexWorldAccess.create({
      registry = registry,
      mapRegistry = { objectAvailability = function() return { available = true } end,
        summary = function() return { generation = 1 } end },
      getPlayer = function() return { state = 'ACTIVE', characterId = 'character_00000042',
        id = 'session_00000042', source = 42, sourceGeneration = 1 } end,
      groupCapability = function() capabilityCalls = capabilityCalls + 1 end,
      getState = function() error('state must not be queried') end,
      getDoorState = function()
        if doorFailure then
          return SynexWorldValidation.failure('STATE_SCHEMA_MISMATCH', 'fixture failure')
        end
        return { state = 'DISABLED' }
      end,
      getInstanceForSource = function() return nil end,
    })
    local denied = assert(access.check({ source = 42, targetKey = door.key }, {}))
    assert(denied.reason == 'TARGET_DISABLED' and capabilityCalls == 0)
    doorFailure = true
    local allowed, doorError = access.check({ source = 42, targetKey = door.key }, {})
    assert(allowed == nil and doorError.code == 'STATE_SCHEMA_MISMATCH'
      and capabilityCalls == 0)
    return denied.reason .. ':' .. doorError.code
  `, accessFiles);
  assert.equal(result, 'TARGET_DISABLED:STATE_SCHEMA_MISMATCH');
});

test('world access rejects ambiguous inputs and fences source reuse after yielding gates', async () => {
  const result = await runWorldLua<string>(String.raw`
    local target = { kind = 'portal', key = 'synex_test:fenced.portal', revision = 1,
      enabled = true, accessPolicy = { requiredCapability = 'world.portal.use',
        groupId = 'group_00000003', stateRequirements = {} } }
    local generation, capabilityCalls = 1, 0
    local registry = {
      get = function(key) return key == target.key and target or nil end,
      resolve = function(reference)
        if reference.revision ~= target.revision then
          return SynexWorldValidation.failure('STALE_WORLD_REF', 'stale')
        end
        return target
      end,
      ref = function(value) return { kind = value.kind, key = value.key,
        revision = value.revision } end,
    }
    local access = SynexWorldAccess.create({
      registry = registry,
      mapRegistry = { objectAvailability = function() return { available = true } end,
        summary = function() return { generation = 1 } end },
      getPlayer = function(source)
        return { state = 'ACTIVE', characterId = 'character_00000043',
          id = generation == 1 and 'session_00000043' or 'session_reused_00000043',
          source = source, sourceGeneration = generation }
      end,
      groupCapability = function()
        capabilityCalls = capabilityCalls + 1
        generation = 2
        return { decision = 'ALLOW', reason = 'fixture' }
      end,
      getState = function() error('state must not be queried') end,
      getDoorState = function() return nil end,
      getInstanceForSource = function() return nil end,
    })

    local _, staleError = access.check({ source = 43, targetKey = target.key }, {})
    assert(staleError and staleError.code == 'STALE_RESOURCE' and staleError.retryable == true)
    assert(capabilityCalls == 1)

    local malformed = {
      { source = 43, characterId = 'character_00000043', targetKey = target.key },
      { source = 43, targetKey = target.key,
        targetRef = { kind = 'portal', key = target.key, revision = 1 } },
      { source = 43, targetKey = target.key, ignoreDisabled = 'yes' },
      { source = 43, targetKey = target.key, ignoreDisabled = true },
      { source = 43, targetKey = target.key, unknown = true },
      { characterId = string.rep('x', 37), targetKey = target.key },
    }
    for _, request in ipairs(malformed) do
      local value, inputError = access.check(request, {})
      assert(value == nil and inputError.code == 'INVALID_ARGUMENT')
    end
    return staleError.code .. ':' .. #malformed
  `, accessFiles);
  assert.equal(result, 'STALE_RESOURCE:6');
});

test('world access fences target replacement while an authority port yields', async () => {
  const result = await runWorldLua<string>(String.raw`
    local target = { kind = 'door', key = 'synex_test:replaced.door', revision = 1,
      accessPolicy = { requiredCapability = 'world.door.use',
        groupId = 'group_00000004', stateRequirements = {} } }
    local registry = {}
    function registry.get(key) return key == target.key and target or nil end
    function registry.ref(value)
      return { kind = value.kind, key = value.key, revision = value.revision }
    end
    function registry.resolve(reference)
      if reference.revision ~= target.revision then
        return SynexWorldValidation.failure('STALE_WORLD_REF', 'target replaced')
      end
      return target
    end
    local access = SynexWorldAccess.create({
      registry = registry,
      mapRegistry = { objectAvailability = function() return { available = true } end,
        summary = function() return { generation = 1 } end },
      getPlayer = function(source) return { state = 'ACTIVE', characterId = 'character_00000044',
        id = 'session_00000044', source = source, sourceGeneration = 1 } end,
      groupCapability = function()
        target = { kind = target.kind, key = target.key, revision = 2,
          accessPolicy = target.accessPolicy }
        return { decision = 'ALLOW', reason = 'fixture' }
      end,
      getState = function() error('state must not be queried') end,
      getDoorState = function() return { state = 'LOCKED' } end,
      getInstanceForSource = function() return nil end,
    })
    local allowed, staleError = access.check({ source = 44, targetKey = target.key }, {})
    assert(allowed == nil and staleError.code == 'STALE_WORLD_REF')
    return staleError.code
  `, accessFiles);
  assert.equal(result, 'STALE_WORLD_REF');
});

test('world access cannot bypass same-instance or disabled gates through public inputs', async () => {
  const result = await runWorldLua<string>(String.raw`
    local target = { kind = 'portal', key = 'synex_test:instance.portal', revision = 1,
      enabled = false, accessPolicy = { requireSameInstance = true,
        requiredCapability = 'world.portal.use', groupId = 'group_00000005',
        stateRequirements = {} } }
    local door = { kind = 'door', key = 'synex_test:internal.door', revision = 1,
      accessPolicy = { stateRequirements = {} } }
    local objects = { [target.key] = target, [door.key] = door }
    local registry = {
      get = function(key) return objects[key] end,
      resolve = function(reference)
        local value = objects[reference.key]
        if value and value.revision == reference.revision then return value end
        return SynexWorldValidation.failure('STALE_WORLD_REF', 'stale')
      end,
      ref = function(value) return { kind = value.kind, key = value.key,
        revision = value.revision } end,
    }
    local membership = { instanceId = 'world_instance_00000005' }
    local capabilityCalls = 0
    local access = SynexWorldAccess.create({
      registry = registry,
      mapRegistry = { objectAvailability = function() return { available = true } end,
        summary = function() return { generation = 1 } end },
      getPlayer = function(source) return { state = 'ACTIVE', characterId = 'character_00000045',
        id = 'session_00000045', source = source, sourceGeneration = 1 } end,
      groupCapability = function()
        capabilityCalls = capabilityCalls + 1
        membership = nil
        return { decision = 'ALLOW', reason = 'fixture' }
      end,
      getState = function() error('state must not be queried') end,
      getDoorState = function() return { state = 'DISABLED' } end,
      getInstanceForSource = function() return membership end,
    })

    target.enabled = true
    local offline = assert(access.check({ characterId = 'character_00000045',
      targetKey = target.key, instanceId = 'world_instance_00000005' }, {}))
    assert(offline.decision == 'DENY' and offline.reason == 'WRONG_INSTANCE'
      and capabilityCalls == 0)
    local changedMembership = assert(access.check({ source = 45, targetKey = target.key,
      instanceId = 'world_instance_00000005' }, {}))
    assert(changedMembership.decision == 'DENY' and changedMembership.reason == 'WRONG_INSTANCE')
    local publicBypass, bypassError = access.check({ source = 45, targetKey = door.key,
      ignoreDisabled = true }, {})
    assert(publicBypass == nil and bypassError.code == 'INVALID_ARGUMENT')
    membership = { instanceId = 'world_instance_00000005' }
    local internal = assert(access.checkDoorMutation({ source = 45, targetKey = door.key }, {}))
    assert(internal.decision == 'ALLOW')
    return table.concat({ offline.reason, changedMembership.reason, bypassError.code,
      internal.decision }, ':')
  `, accessFiles);
  assert.equal(result, 'WRONG_INSTANCE:WRONG_INSTANCE:INVALID_ARGUMENT:ALLOW');
});

test('world access revalidates state and map evidence after yielding authority ports', async () => {
  const result = await runWorldLua<string>(String.raw`
    local definition = { kind = 'world_state_definition', key = 'synex_test:lockdown',
      revision = 1, scope = 'global' }
    local target = { kind = 'portal', key = 'synex_test:lockdown.portal', revision = 1,
      enabled = true, accessPolicy = { requiredCapability = 'world.portal.use',
        groupId = 'group_00000006', stateRequirements = {
          { key = definition.key, operator = 'equals', value = false },
        } } }
    local objects = { [definition.key] = definition, [target.key] = target }
    local registry = {
      get = function(key, kind)
        local value = objects[key]
        return value and (kind == nil or value.kind == kind) and value or nil
      end,
      resolve = function(reference, kind)
        local value = objects[reference.key]
        if value and value.revision == reference.revision
          and (kind == nil or value.kind == kind) then return value end
        return SynexWorldValidation.failure('STALE_WORLD_REF', 'stale')
      end,
      ref = function(value) return { kind = value.kind, key = value.key,
        revision = value.revision } end,
    }
    local mode, stateValue, stateVersion, mapGeneration, mapAvailable =
      'state', false, 1, 1, true
    local access = SynexWorldAccess.create({
      registry = registry,
      mapRegistry = {
        objectAvailability = function() return { available = mapAvailable } end,
        summary = function() return { generation = mapGeneration } end,
      },
      getPlayer = function(source) return { state = 'ACTIVE', characterId = 'character_00000046',
        id = 'session_00000046', source = source, sourceGeneration = 1 } end,
      groupCapability = function()
        if mode == 'state' then stateValue, stateVersion = true, 2
        else mapGeneration, mapAvailable = 2, false end
        return { decision = 'ALLOW', reason = 'fixture' }
      end,
      getState = function() return { value = stateValue, version = stateVersion,
        definitionRevision = definition.revision } end,
      getDoorState = function() error('door must not be queried') end,
      getInstanceForSource = function() return nil end,
    })
    local stateAllowed, stateError = access.check({ source = 46, targetKey = target.key }, {})
    assert(stateAllowed == nil and stateError.code == 'STALE_RESOURCE')
    mode, stateValue, stateVersion, mapGeneration, mapAvailable = 'map', false, 1, 1, true
    local mapAllowed, mapError = access.check({ source = 46, targetKey = target.key }, {})
    assert(mapAllowed == nil and mapError.code == 'STALE_RESOURCE')
    return stateError.code .. ':' .. mapError.code
  `, accessFiles);
  assert.equal(result, 'STALE_RESOURCE:STALE_RESOURCE');
});
