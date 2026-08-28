import assert from 'node:assert/strict';
import test from 'node:test';

import { runWorldLua } from './helpers.ts';

const portalFiles = [
  'shared/limits.lua',
  'shared/validation.lua',
  'server/portals.lua',
] as const;

test('portal transitions validate proximity, context, access, revisions and destination maps', async () => {
  const result = await runWorldLua<string>(String.raw`
    local sourceLocation = { kind = 'location', key = 'synex_test:source', revision = 2 }
    local otherLocation = { kind = 'location', key = 'synex_test:other', revision = 2 }
    local destination = { kind = 'location', key = 'synex_test:destination', revision = 4 }
    local unavailable = { kind = 'location', key = 'synex_test:unavailable', revision = 4,
      unavailable = true }
    local teleport = { kind = 'portal', key = 'synex_test:teleport', revision = 7,
      parent = sourceLocation.key, portalType = 'teleport', enabled = true,
      source = { position = { x = 0, y = 0, z = 0 }, radius = 2 },
      destination = { target = destination.key,
        position = { x = 10, y = 20, z = 30 }, heading = 90 } }
    local blockedDestination = { kind = 'portal', key = 'synex_test:blocked.map', revision = 8,
      parent = sourceLocation.key, portalType = 'teleport', enabled = true,
      source = { position = { x = 0, y = 0, z = 0 }, radius = 2 },
      destination = { target = unavailable.key,
        position = { x = 40, y = 50, z = 60 }, heading = 180 } }
    local physical = { kind = 'portal', key = 'synex_test:physical', revision = 5,
      parent = sourceLocation.key, portalType = 'physical', enabled = true,
      source = { position = { x = 0, y = 0, z = 0 }, radius = 2 },
      destination = { target = destination.key } }
    local disabled = { kind = 'portal', key = 'synex_test:disabled', revision = 3,
      parent = sourceLocation.key, portalType = 'teleport', enabled = false,
      source = { position = { x = 0, y = 0, z = 0 }, radius = 2 },
      destination = { position = { x = 1, y = 1, z = 1 }, heading = 0 } }
    local objects = {
      [sourceLocation.key] = sourceLocation, [otherLocation.key] = otherLocation,
      [destination.key] = destination, [unavailable.key] = unavailable,
      [teleport.key] = teleport, [blockedDestination.key] = blockedDestination,
      [physical.key] = physical, [disabled.key] = disabled,
    }
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

    local clock, nextGrant = 1000, 0
    local position = { x = 0, y = 0, z = 0 }
    local contextLocation = sourceLocation
    local accessDecision = { decision = 'ALLOW', reason = 'ACCESS_GRANTED' }
    local clientCalls, emitted, audits = {}, {}, {}
    local session = { state = 'ACTIVE', id = 'session_00000041', source = 41,
      sourceGeneration = 5, characterId = 'character_00000041' }
    local portals = SynexWorldPortals.create({
      registry = registry,
      mapRegistry = { objectAvailability = function(value)
        return { available = value.unavailable ~= true }
      end },
      contextResolver = { resolve = function()
        return { location = registry.ref(contextLocation), zones = {} }
      end },
      access = { check = function() return accessDecision end },
      instances = {
        getForSource = function() return nil end,
        get = function() return nil end,
        findReadyByTemplate = function() return nil end,
        create = function() error('instance create is not expected') end,
        join = function() error('instance join is not expected') end,
      },
      getPlayer = function(source) assert(source == 41); return session end,
      getPlayerPosition = function() return position end,
      nextId = function()
        nextGrant = nextGrant + 1
        return ('world_transition_%08d'):format(nextGrant)
      end,
      now = function() return clock end,
      triggerClient = function(source, event, payload)
        clientCalls[#clientCalls + 1] = { source = source, event = event, payload = payload }
      end,
      emit = function(event, payload) emitted[#emitted + 1] = { event, payload } end,
      audit = function(event, kind, key, fields)
        audits[#audits + 1] = { event, kind, key, fields }
      end,
    })
    local contractContext = { caller = 'synex_test', callerEpoch = 4,
      traceId = 'trace_portal_runtime_0001' }

    local transitioned = assert(portals.transition({ source = 41,
      portalKey = teleport.key, idempotencyKey = 'portal_valid_0001' }, contractContext))
    assert(transitioned.transitioned == true and #clientCalls == 1 and #emitted == 1)
    assert(clientCalls[1].source == 41
      and clientCalls[1].event == 'synex_world:client:apply_transition')
    assert(clientCalls[1].payload.destination.x == 10
      and clientCalls[1].payload.destination.heading == 90)
    local linked = assert(portals.transition({ source = 41,
      portalKey = physical.key }, contractContext))
    assert(linked.transitioned == true and linked.grantId == nil
      and #clientCalls == 1 and #emitted == 2)

    local _, replayError = portals.consumeGrant(transitioned.grantId, 41)
    assert(replayError and replayError.code == 'TRANSITION_GRANT_REPLAYED')
    local expiring = assert(portals.createGrant(teleport, session,
      { location = registry.ref(sourceLocation) }, { x = 1, y = 2, z = 3 }))
    clock = clock + SynexWorldLimits.transitionGrantTtlMs + 1
    local _, expiryError = portals.consumeGrant(expiring.grantId, 41)
    assert(expiryError and expiryError.code == 'TRANSITION_GRANT_EXPIRED')

    position = { x = 3, y = 0, z = 0 }
    local _, farError = portals.transition({ source = 41, portalKey = teleport.key,
      position = { x = 0, y = 0, z = 0 } }, contractContext)
    assert(farError and farError.code == 'PORTAL_TOO_FAR')
    position = { x = 0, y = 0, z = 0 }

    contextLocation = otherLocation
    local _, contextError = portals.transition({ source = 41,
      portalKey = teleport.key }, contractContext)
    assert(contextError and contextError.code == 'OUT_OF_CONTEXT')
    contextLocation = sourceLocation

    accessDecision = { decision = 'DENY', reason = 'MISSING_CAPABILITY' }
    local _, accessError = portals.transition({ source = 41,
      portalKey = teleport.key }, contractContext)
    assert(accessError and accessError.code == 'TRANSITION_DENIED'
      and accessError.details.reason == 'MISSING_CAPABILITY')
    accessDecision = { decision = 'ALLOW', reason = 'ACCESS_GRANTED' }

    local _, disabledError = portals.transition({ source = 41,
      portalKey = disabled.key }, contractContext)
    assert(disabledError and disabledError.code == 'PORTAL_UNAVAILABLE')

    local _, staleError = portals.transition({ source = 41,
      portalRef = { kind = 'portal', key = teleport.key, revision = 6 } }, contractContext)
    assert(staleError and staleError.code == 'STALE_WORLD_REF')

    local _, mapError = portals.transition({ source = 41,
      portalKey = blockedDestination.key }, contractContext)
    assert(mapError and mapError.code == 'MAP_PACKAGE_UNAVAILABLE'
      and mapError.retryable == true)
    return table.concat({ transitioned.transitioned and linked.transitioned and 'valid', replayError.code,
      expiryError.code, farError.code, contextError.code, accessError.code,
      disabledError.code, staleError.code, mapError.code }, ':')
  `, portalFiles);

  assert.equal(result,
    'valid:TRANSITION_GRANT_REPLAYED:TRANSITION_GRANT_EXPIRED:PORTAL_TOO_FAR:'
      + 'OUT_OF_CONTEXT:TRANSITION_DENIED:PORTAL_UNAVAILABLE:STALE_WORLD_REF:'
      + 'MAP_PACKAGE_UNAVAILABLE');
});

test('instance portal creates, joins and projects exactly one server-authorized transition', async () => {
  const result = await runWorldLua<string>(String.raw`
    local sourceLocation = { kind = 'location', key = 'synex_test:source', revision = 1 }
    local baseLocation = { kind = 'location', key = 'synex_test:instance.base', revision = 2 }
    local template = { kind = 'instance_template', key = 'synex_test:instance.template',
      revision = 3, baseLocation = baseLocation.key,
      entry = { x = 100, y = 200, z = 300 } }
    local portal = { kind = 'portal', key = 'synex_test:instance.portal', revision = 4,
      parent = sourceLocation.key, portalType = 'instance', enabled = true,
      source = { position = { x = 0, y = 0, z = 0 }, radius = 2 },
      destination = { instanceTemplate = template.key,
        entry = { x = 101, y = 201, z = 301 } } }
    local objects = { [sourceLocation.key] = sourceLocation,
      [baseLocation.key] = baseLocation, [template.key] = template, [portal.key] = portal }
    local registry = {
      get = function(key, kind)
        local value = objects[key]
        return value and (kind == nil or value.kind == kind) and value or nil
      end,
      resolve = function(reference, kind)
        local value = objects[reference.key]
        return value and value.revision == reference.revision
          and (kind == nil or value.kind == kind) and value or nil
      end,
      ref = function(value) return { kind = value.kind, key = value.key,
        revision = value.revision } end,
    }
    local created, joined, clientCalls, clock, nextGrant = 0, 0, 0, 5000, 0
    local accessCalls, denySecondAccess = 0, false
    local portals
    local instance
    local instances = {
      getForSource = function() return nil end,
      get = function(id)
        if id == 'world_instance_wrong_000001' then
          return { instanceId = id, state = 'READY', template = {
            kind = 'instance_template', key = 'synex_test:other.template', revision = 9 } }
        end
        return instance and id == instance.instanceId and instance or nil
      end,
      findReadyByTemplate = function(key, owner)
        assert(key == template.key and owner == 'synex_companion')
        return nil
      end,
      create = function(request, context)
        created = created + 1
        assert(request.templateKey == template.key
          and request.idempotencyKey == 'instance_portal_0001')
        assert(context.caller == 'synex_companion')
        instance = { instanceId = 'world_instance_00000001',
          template = registry.ref(template), state = 'READY' }
        return instance
      end,
      join = function(request)
        joined = joined + 1
        assert(request.instanceId == instance.instanceId and request.source == 52)
        clock = clock + SynexWorldLimits.transitionGrantTtlMs + 1
        assert(portals.expire() == 1)
        instance.state = 'ACTIVE'
        return instance
      end,
    }
    portals = SynexWorldPortals.create({
      registry = registry,
      mapRegistry = { objectAvailability = function() return { available = true } end },
      contextResolver = { resolve = function()
        return { location = registry.ref(sourceLocation), zones = {} }
      end },
      access = { check = function()
        accessCalls = accessCalls + 1
        if denySecondAccess and accessCalls == 2 then
          return { decision = 'DENY', reason = 'POLICY_CHANGED' }
        end
        return { decision = 'ALLOW' }
      end },
      instances = instances,
      getPlayer = function() return { state = 'ACTIVE', id = 'session_00000052',
        source = 52, sourceGeneration = 2, characterId = 'character_00000052' } end,
      getPlayerPosition = function() return { x = 0, y = 0, z = 0 } end,
      nextId = function(namespace)
        nextGrant = nextGrant + 1
        return ('%s_%08d'):format(namespace or 'world', nextGrant)
      end,
      now = function() return clock end,
      triggerClient = function(source, event, payload)
        clientCalls = clientCalls + 1
        assert(source == 52 and event == 'synex_world:client:apply_transition')
        assert(payload.destination.x == 101 and payload.destination.z == 301)
      end,
    })
    local wrong, wrongError = portals.transition({ source = 52,
      portalKey = portal.key, instanceId = 'world_instance_wrong_000001',
      idempotencyKey = 'instance_portal_wrong01' }, {
      caller = 'synex_companion', callerEpoch = 2,
      traceId = 'trace_instance_wrong_0001',
    })
    assert(wrong == nil and wrongError.code == 'WRONG_INSTANCE'
      and created == 0 and joined == 0 and clientCalls == 0)

    instance = { instanceId = 'world_instance_00000001',
      template = registry.ref(template), state = 'READY' }
    accessCalls, denySecondAccess = 0, true
    local denied, deniedError = portals.transition({ source = 52,
      portalKey = portal.key, instanceId = instance.instanceId,
      idempotencyKey = 'instance_portal_denied1' }, {
      caller = 'synex_companion', callerEpoch = 2,
      traceId = 'trace_instance_denied_0001',
    })
    assert(denied == nil and deniedError.code == 'TRANSITION_DENIED'
      and created == 0 and joined == 0 and clientCalls == 0)
    instance, accessCalls, denySecondAccess = nil, 0, false
    local transitioned = assert(portals.transition({ source = 52,
      portalKey = portal.key, idempotencyKey = 'instance_portal_0001' }, {
      caller = 'synex_companion', callerEpoch = 2,
      traceId = 'trace_instance_portal_0001',
    }))
    assert(transitioned.instanceId == 'world_instance_00000001'
      and created == 1 and joined == 1 and clientCalls == 1)
    return table.concat({ wrongError.code, deniedError.code, transitioned.instanceId,
      created, joined, clientCalls }, ':')
  `, portalFiles);
  assert.equal(result,
    'WRONG_INSTANCE:TRANSITION_DENIED:world_instance_00000001:1:1:1');
});

test('portal transition revalidates server position and context after yielding access checks', async () => {
  const result = await runWorldLua<string>(String.raw`
    local sourceLocation = { kind = 'location', key = 'synex_test:source', revision = 1 }
    local otherLocation = { kind = 'location', key = 'synex_test:other', revision = 1 }
    local baseLocation = { kind = 'location', key = 'synex_test:base', revision = 1 }
    local template = { kind = 'instance_template', key = 'synex_test:template', revision = 1,
      baseLocation = baseLocation.key, entry = { x = 100, y = 0, z = 0 } }
    local teleport = { kind = 'portal', key = 'synex_test:teleport', revision = 1,
      parent = sourceLocation.key, portalType = 'teleport', enabled = true,
      source = { position = { x = 0, y = 0, z = 0 }, radius = 2 },
      destination = { position = { x = 10, y = 0, z = 0 }, heading = 0 } }
    local instancePortal = { kind = 'portal', key = 'synex_test:instance', revision = 1,
      parent = sourceLocation.key, portalType = 'instance', enabled = true,
      source = { position = { x = 0, y = 0, z = 0 }, radius = 2 },
      destination = { instanceTemplate = template.key } }
    local objects = { [sourceLocation.key] = sourceLocation,
      [otherLocation.key] = otherLocation, [baseLocation.key] = baseLocation,
      [template.key] = template, [teleport.key] = teleport,
      [instancePortal.key] = instancePortal }
    local registry = {
      get = function(key, kind)
        local value = objects[key]
        return value and (kind == nil or value.kind == kind) and value or nil
      end,
      resolve = function(reference, kind)
        local value = objects[reference.key]
        return value and value.revision == reference.revision
          and (kind == nil or value.kind == kind) and value or nil
      end,
      ref = function(value) return { kind = value.kind, key = value.key,
        revision = value.revision } end,
    }
    local position = { x = 0, y = 0, z = 0 }
    local contextLocation = sourceLocation
    local accessMode = 'far'
    local grantIds, creates, joins, clientCalls, emits = 0, 0, 0, 0, 0
    local session = { state = 'ACTIVE', id = 'session_00000073', source = 73,
      sourceGeneration = 9, characterId = 'character_00000073' }
    local instances = {
      getForSource = function() return nil end,
      get = function() return nil end,
      findReadyByTemplate = function() return nil end,
      create = function()
        creates = creates + 1
        return { instanceId = 'world_instance_00000001', template = registry.ref(template) }
      end,
      join = function(value) joins = joins + 1; return value end,
    }
    local portals = SynexWorldPortals.create({
      registry = registry,
      mapRegistry = { objectAvailability = function() return { available = true } end },
      contextResolver = { resolve = function()
        return { location = registry.ref(contextLocation), zones = {} }
      end },
      access = { check = function()
        if accessMode == 'far' then position = { x = 10, y = 0, z = 0 }
        elseif accessMode == 'context' then contextLocation = otherLocation end
        return { decision = 'ALLOW', reason = 'ACCESS_GRANTED' }
      end },
      instances = instances,
      getPlayer = function() return session end,
      getPlayerPosition = function() return position end,
      nextId = function(namespace)
        grantIds = grantIds + 1
        return ('%s_%08d'):format(namespace or 'world', grantIds)
      end,
      now = function() return 1000 end,
      triggerClient = function() clientCalls = clientCalls + 1 end,
      emit = function() emits = emits + 1 end,
    })
    local contractContext = { caller = 'synex_test', callerEpoch = 1,
      traceId = 'trace_portal_toctou_0001' }

    local _, farError = portals.transition({ source = 73,
      portalKey = teleport.key }, contractContext)
    assert(farError and farError.code == 'PORTAL_TOO_FAR')
    assert(grantIds == 0 and creates == 0 and joins == 0 and clientCalls == 0 and emits == 0)

    position, contextLocation, accessMode = { x = 0, y = 0, z = 0 }, sourceLocation, 'context'
    local _, contextError = portals.transition({ source = 73,
      portalKey = teleport.key }, contractContext)
    assert(contextError and contextError.code == 'OUT_OF_CONTEXT')
    assert(grantIds == 0 and creates == 0 and joins == 0 and clientCalls == 0 and emits == 0)

    position, contextLocation, accessMode = { x = 0, y = 0, z = 0 }, sourceLocation, 'far'
    local _, instanceError = portals.transition({ source = 73,
      portalKey = instancePortal.key, idempotencyKey = 'portal_toctou_0001' }, contractContext)
    assert(instanceError and instanceError.code == 'PORTAL_TOO_FAR')
    assert(grantIds == 0 and creates == 0 and joins == 0 and clientCalls == 0 and emits == 0)
    return table.concat({ farError.code, contextError.code, instanceError.code,
      grantIds, creates, joins, clientCalls, emits }, ':')
  `, portalFiles);
  assert.equal(result, 'PORTAL_TOO_FAR:OUT_OF_CONTEXT:PORTAL_TOO_FAR:0:0:0:0:0');
});

test('instance portal fences destination refreshes and compensates a post-join hot reload', async () => {
  const result = await runWorldLua<string>(String.raw`
    local sourceLocation = { kind = 'location', key = 'synex_test:source', revision = 1 }
    local baseLocation = { kind = 'location', key = 'synex_test:base', revision = 1 }
    local template = { kind = 'instance_template', key = 'synex_test:template', revision = 1,
      baseLocation = baseLocation.key, entry = { x = 100, y = 0, z = 0 } }
    local portal = { kind = 'portal', key = 'synex_test:portal', revision = 1,
      parent = sourceLocation.key, portalType = 'instance', enabled = true,
      source = { position = { x = 0, y = 0, z = 0 }, radius = 2 },
      destination = { instanceTemplate = template.key } }
    local objects = { [sourceLocation.key] = sourceLocation,
      [baseLocation.key] = baseLocation, [template.key] = template, [portal.key] = portal }
    local registry = {}
    function registry.get(key, kind)
      local value = objects[key]
      if not value or kind and value.kind ~= kind then
        return SynexWorldValidation.failure('WORLD_NOT_FOUND', 'not found')
      end
      return value
    end
    function registry.resolve(reference, kind)
      local value = objects[reference.key]
      if not value or kind and value.kind ~= kind then
        return SynexWorldValidation.failure('WORLD_NOT_FOUND', 'not found')
      end
      if value.revision ~= reference.revision then
        return SynexWorldValidation.failure('STALE_WORLD_REF', 'stale')
      end
      return value
    end
    function registry.ref(value)
      return { kind = value.kind, key = value.key, revision = value.revision }
    end

    local mode, nextGrant = 'template_before_join', 0
    local creates, joins, leaves, clientCalls = 0, 0, 0, 0
    local instance = { instanceId = 'world_instance_00000001',
      template = registry.ref(template), state = 'READY' }
    local instances = {
      getForSource = function() return nil end,
      get = function() return nil end,
      findReadyByTemplate = function() return nil end,
      create = function()
        creates = creates + 1
        if mode == 'template_before_join' then
          local refreshed = SynexWorldValidation.copy(template)
          refreshed.revision = 2
          objects[template.key] = refreshed
        end
        return instance
      end,
      join = function()
        joins = joins + 1
        if mode == 'portal_during_join' then
          local refreshed = SynexWorldValidation.copy(portal)
          refreshed.revision = 2
          objects[portal.key] = refreshed
        end
        instance.state = 'ACTIVE'
        return instance
      end,
      leave = function(request)
        leaves = leaves + 1
        assert(request.instanceId == instance.instanceId and request.source == 81)
        assert(#request.idempotencyKey >= 8 and #request.idempotencyKey <= 36)
        assert(request.idempotencyKey ~= 'world_transition_00000001')
        instance.state = 'READY'
        return instance
      end,
    }
    local portals = SynexWorldPortals.create({
      registry = registry,
      mapRegistry = { objectAvailability = function() return { available = true } end },
      contextResolver = { resolve = function()
        return { location = registry.ref(sourceLocation), zones = {} }
      end },
      access = { check = function() return { decision = 'ALLOW' } end },
      instances = instances,
      getPlayer = function() return { state = 'ACTIVE', id = 'session_00000081',
        source = 81, sourceGeneration = 4, characterId = 'character_00000081' } end,
      getPlayerPosition = function() return { x = 0, y = 0, z = 0 } end,
      nextId = function()
        nextGrant = nextGrant + 1
        return ('world_transition_%08d'):format(nextGrant)
      end,
      now = function() return 1000 end,
      triggerClient = function() clientCalls = clientCalls + 1 end,
    })
    local contractContext = { caller = 'synex_test', callerEpoch = 1,
      traceId = 'trace_portal_hot_reload_0001' }

    local _, templateError = portals.transition({ source = 81, portalKey = portal.key,
      idempotencyKey = 'portal_hot_reload_0001' }, contractContext)
    assert(templateError and templateError.code == 'STALE_WORLD_REF')
    assert(creates == 1 and joins == 0 and leaves == 0 and clientCalls == 0)

    objects[template.key], mode = template, 'portal_during_join'
    instance.template, instance.state = registry.ref(template), 'READY'
    local _, portalError = portals.transition({ source = 81, portalKey = portal.key,
      idempotencyKey = 'portal_hot_reload_0002' }, contractContext)
    assert(portalError and portalError.code == 'STALE_WORLD_REF')
    assert(creates == 2 and joins == 1 and leaves == 1 and clientCalls == 0)
    assert(portals.expire() == 0)
    return table.concat({ templateError.code, portalError.code,
      creates, joins, leaves, clientCalls }, ':')
  `, portalFiles);
  assert.equal(result, 'STALE_WORLD_REF:STALE_WORLD_REF:2:1:1:0');
});

test('transition grant queue remains bounded across capacity, replay and expiry', async () => {
  const result = await runWorldLua<string>(String.raw`
    local clock, nextGrant = 1000, 0
    local portal = { kind = 'portal', key = 'synex_test:capacity.portal', revision = 1 }
    local session = { state = 'ACTIVE', id = 'session_capacity_0001', source = 61,
      sourceGeneration = 3, characterId = 'character_capacity_0001' }
    local registry = {
      ref = function(value) return { kind = value.kind, key = value.key,
        revision = value.revision } end,
      resolve = function(reference) return portal end,
    }
    local portals = SynexWorldPortals.create({
      registry = registry,
      mapRegistry = { objectAvailability = function() return { available = true } end },
      contextResolver = { resolve = function() return {} end },
      access = { check = function() return { decision = 'ALLOW' } end },
      instances = {},
      getPlayer = function() return session end,
      getPlayerPosition = function() return { x = 0, y = 0, z = 0 } end,
      nextId = function()
        nextGrant = nextGrant + 1
        return ('world_transition_%08d'):format(nextGrant)
      end,
      now = function() return clock end,
      triggerClient = function() end,
    })
    local grants = {}
    for index = 1, 4096 do
      grants[index] = assert(portals.createGrant(portal, session, {},
        { x = index, y = 0, z = 0 }))
    end
    assert(portals.expire() == 4096)
    local _, capacityError = portals.createGrant(portal, session, {}, { x = 0, y = 0, z = 0 })
    assert(capacityError and capacityError.code == 'PORTAL_UNAVAILABLE')

    assert(portals.consumeGrant(grants[1].grantId, 61))
    local _, replayError = portals.consumeGrant(grants[1].grantId, 61)
    assert(replayError and replayError.code == 'TRANSITION_GRANT_REPLAYED')
    assert(portals.createGrant(portal, session, {}, { x = 1, y = 1, z = 1 }))
    assert(portals.expire() == 4096)

    clock = clock + SynexWorldLimits.transitionGrantTtlMs + 1
    assert(portals.expire() == 0)
    local replacement = assert(portals.createGrant(portal, session, {},
      { x = 2, y = 2, z = 2 }))
    assert(portals.expire() == 1)
    return table.concat({ capacityError.code, replayError.code,
      replacement.grantId, portals.expire() }, ':')
  `, portalFiles);
  assert.equal(result,
    'PORTAL_UNAVAILABLE:TRANSITION_GRANT_REPLAYED:world_transition_00004098:1');
});

test('portal grant TTL remains monotonic across signed GetGameTimer wrap', async () => {
  const result = await runWorldLua<string>(String.raw`
    local raw, identifiers = 2147483646, 0
    local clock = SynexWorldValidation.monotonicClock(function() return raw end)
    local portal = { kind = 'portal', key = 'synex_test:timer.portal', revision = 1 }
    local session = { state = 'ACTIVE', id = 'session_timer_0001', source = 62,
      sourceGeneration = 4, characterId = 'character_timer_0001' }
    local registry = {
      ref = function(value) return { kind = value.kind, key = value.key,
        revision = value.revision } end,
      resolve = function() return portal end,
    }
    local portals = SynexWorldPortals.create({
      registry = registry,
      mapRegistry = { objectAvailability = function() return { available = true } end },
      contextResolver = { resolve = function() return {} end },
      access = { check = function() return { decision = 'ALLOW' } end },
      instances = {}, getPlayer = function() return session end,
      getPlayerPosition = function() return { x = 0, y = 0, z = 0 } end,
      nextId = function()
        identifiers = identifiers + 1
        return ('world_transition_%08d'):format(identifiers)
      end,
      now = clock, triggerClient = function() end,
    })
    local first = assert(portals.createGrant(portal, session, {}, { x = 0, y = 0, z = 0 }))
    raw = -2147483640 -- unsigned 2147483656: ten milliseconds later
    assert(portals.consumeGrant(first.grantId, 62))
    local second = assert(portals.createGrant(portal, session, {}, { x = 1, y = 0, z = 0 }))
    raw = -2147475639 -- 8001 milliseconds later
    local expired, expiryError = portals.consumeGrant(second.grantId, 62)
    assert(expired == nil and expiryError.code == 'TRANSITION_GRANT_EXPIRED')
    return table.concat({ first.grantId, second.grantId, expiryError.code }, ':')
  `, portalFiles);
  assert.equal(result,
    'world_transition_00000001:world_transition_00000002:TRANSITION_GRANT_EXPIRED');
});
