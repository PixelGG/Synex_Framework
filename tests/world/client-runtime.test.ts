import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory, type LuaEngine } from 'wasmoon';

const root = process.cwd();

async function source(relativePath: string): Promise<string> {
  return readFile(path.join(root, relativePath), 'utf8');
}

async function bootstrap(engine: LuaEngine): Promise<string> {
  const [limits, validation, runtime] = await Promise.all([
    source('resources/synex_world/shared/limits.lua'),
    source('resources/synex_world/shared/validation.lua'),
    source('resources/synex_world/client/runtime.lua'),
  ]);
  await engine.doString(`
    local function encodeString(value)
      return string.format('%q', value)
    end
    local function encodeValue(value, seen)
      local kind = type(value)
      if kind == 'nil' then return 'null' end
      if kind == 'boolean' or kind == 'number' then return tostring(value) end
      if kind == 'string' then return encodeString(value) end
      if kind ~= 'table' or seen[value] then error('unsupported JSON value') end
      seen[value] = true
      local count, maximum, array = 0, 0, true
      for key in pairs(value) do
        count = count + 1
        if type(key) ~= 'number' or key < 1 or key % 1 ~= 0 then array = false end
        if type(key) == 'number' then maximum = math.max(maximum, key) end
      end
      if array and maximum ~= count then array = false end
      local parts = {}
      if array then
        for index = 1, count do parts[#parts + 1] = encodeValue(value[index], seen) end
        seen[value] = nil
        return '[' .. table.concat(parts, ',') .. ']'
      end
      local keys = {}
      for key in pairs(value) do keys[#keys + 1] = key end
      table.sort(keys)
      for _, key in ipairs(keys) do
        parts[#parts + 1] = encodeString(key) .. ':' .. encodeValue(value[key], seen)
      end
      seen[value] = nil
      return '{' .. table.concat(parts, ',') .. '}'
    end
    json = { encode = function(value) return encodeValue(value, {}) end }
    assert(load(${JSON.stringify(limits)}, '@resources/synex_world/shared/limits.lua'))()
    assert(load(${JSON.stringify(validation)}, '@resources/synex_world/shared/validation.lua'))()
  `);
  return runtime;
}

test('world client accepts only server slices and reconciles bounded read models', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    const runtime = await bootstrap(engine);
    const result = await engine.doString(`
      local network, handlers, clientExports, threads = {}, {}, {}, {}
      local localEvents, doorCalls, iplCalls, interiorCalls, teleports = {}, {}, {}, {}, {}
      local registeredDoors, activeIpls, activeSets = {}, {}, {}
      local now = 1000

      RegisterNetEvent = function(name, handler) network[name] = handler end
      AddEventHandler = function(name, handler) handlers[name] = handler end
      exports = function(name, handler) clientExports[name] = handler end
      CreateThread = function(handler) threads[#threads + 1] = handler end
      Wait = function() error('test thread must not be driven as an unbounded loop') end
      TriggerEvent = function(name, current, previous, revision)
        localEvents[#localEvents + 1] = {
          name = name, current = current, previous = previous, revision = revision,
        }
      end
      GetCurrentResourceName = function() return 'synex_world' end
      GetGameTimer = function() return now end

      IsDoorRegisteredWithSystem = function(hash) return registeredDoors[hash] == true end
      AddDoorToSystem = function(hash, model, x, y, z, p5, scriptDoor, isLocal)
        assert(p5 == false and scriptDoor == false and isLocal == false)
        registeredDoors[hash] = true
        doorCalls[#doorCalls + 1] = { operation = 'add', hash = hash, model = model,
          position = { x = x, y = y, z = z } }
      end
      DoorSystemGetIsPhysicsLoaded = function(hash) return registeredDoors[hash] == true end
      DoorSystemSetDoorState = function(hash, state, requestDoor, forceUpdate)
        assert(requestDoor == false and forceUpdate == true)
        doorCalls[#doorCalls + 1] = { operation = 'state', hash = hash, state = state }
      end
      DoorSystemSetOpenRatio = function(hash, ratio, requestDoor, forceUpdate)
        assert(requestDoor == false and forceUpdate == true)
        doorCalls[#doorCalls + 1] = { operation = 'ratio', hash = hash, ratio = ratio }
      end
      DoorSystemSetAutomaticDistance = function(hash, distance, requestDoor, forceUpdate)
        assert(requestDoor == false and forceUpdate == true)
        doorCalls[#doorCalls + 1] = { operation = 'distance', hash = hash,
          distance = distance }
      end
      RemoveDoorFromSystem = function(hash)
        registeredDoors[hash] = nil
        doorCalls[#doorCalls + 1] = { operation = 'remove', hash = hash }
      end

      IsIplActive = function(name) return activeIpls[name] == true end
      RequestIpl = function(name)
        activeIpls[name] = true
        iplCalls[#iplCalls + 1] = { operation = 'request', name = name }
      end
      RemoveIpl = function(name)
        activeIpls[name] = nil
        iplCalls[#iplCalls + 1] = { operation = 'remove', name = name }
      end

      IsValidInterior = function(id) return id == 7 end
      IsInteriorEntitySetActive = function(id, name)
        return activeSets[tostring(id) .. ':' .. name] == true
      end
      ActivateInteriorEntitySet = function(id, name)
        activeSets[tostring(id) .. ':' .. name] = true
        interiorCalls[#interiorCalls + 1] = { operation = 'activate', id = id, name = name }
      end
      DeactivateInteriorEntitySet = function(id, name)
        activeSets[tostring(id) .. ':' .. name] = nil
        interiorCalls[#interiorCalls + 1] = { operation = 'deactivate', id = id, name = name }
      end
      SetInteriorEntitySetColor = function(id, name, color)
        interiorCalls[#interiorCalls + 1] = { operation = 'color', id = id,
          name = name, color = color }
      end
      RefreshInterior = function(id)
        interiorCalls[#interiorCalls + 1] = { operation = 'refresh', id = id }
      end

      local playerPed = 77
      PlayerPedId = function() return playerPed end
      SetEntityCoordsNoOffset = function(ped, x, y, z, keepTasks, keepIK, doWarp)
        assert(ped == 77 and keepTasks == true and keepIK == true and doWarp == true)
        teleports[#teleports + 1] = { ped = ped, x = x, y = y, z = z }
      end
      SetEntityHeading = function(ped, heading)
        teleports[#teleports].heading = heading
      end

      assert(load(${JSON.stringify(runtime)}, '@resources/synex_world/client/runtime.lua'))()
      assert(#threads == 1)
      assert(clientExports.GetContext and clientExports.CurrentLocation
        and clientExports.CurrentRoom and clientExports.NearbyAnchors
        and clientExports.NearbyObjects and clientExports.ResolveCached)

      local slice = {
        schemaVersion = 1,
        revision = 7,
        context = {
          location = { kind = 'location', key = 'fixture:station', revision = 7 },
          room = { kind = 'room', key = 'fixture:station.lobby', revision = 7 },
          instance = { instanceId = 'instance-a' },
        },
        bundleRevisions = { fixture = 7 },
        state = { lockdown = false },
        locations = {{ kind = 'location', key = 'fixture:station', revision = 7 }},
        rooms = {{ kind = 'room', key = 'fixture:station.lobby', revision = 7 }},
        anchors = {{ kind = 'anchor', key = 'fixture:reception', revision = 7,
          position = { x = 1.0, y = 2.0, z = 3.0 }, distance = 3.0,
          tags = { 'synex.anchor.counter' } }},
        doors = {{ kind = 'door', key = 'fixture:front.door', revision = 2,
          distance = 4.5, tags = { 'synex.door.entry' },
          state = 'LOCKED', stateVersion = 4,
          leaves = {{ doorHash = 101, modelHash = 202,
            position = { x = 4.0, y = 5.0, z = 6.0 }, openRatio = 0.0,
            automaticDistance = 2.5 }} }},
        portals = {{ kind = 'portal', key = 'fixture:platform.portal', revision = 3,
          position = { x = 7.0, y = 8.0, z = 9.0 }, distance = 8.0,
          tags = { 'synex.portal.transit' }, portalType = 'local', enabled = true }},
        ipls = {{ name = 'fixture_ipl', refCount = 2 }},
        interiorSets = {{ interiorId = 7, name = 'fixture_set', refCount = 1,
          color = 2 }},
      }

      source = 41
      network['synex_world:client:replace_slice'](slice)
      assert(clientExports.GetContext().revision == 0 and #doorCalls == 0)

      source = 65535
      network['synex_world:client:replace_slice'](slice)
      assert(clientExports.GetContext().revision == 7)
      assert(clientExports.GetContext().authority == 'OBSERVED')
      assert(clientExports.CurrentLocation().key == 'fixture:station')
      assert(clientExports.CurrentRoom().key == 'fixture:station.lobby')
      assert(#localEvents == 4 and localEvents[1].name == 'world:contextChanged')
      assert(localEvents[2].name == 'world:locationChanged')
      assert(localEvents[3].name == 'world:roomChanged')
      assert(localEvents[4].name == 'world:instanceChanged')
      assert(doorCalls[1].operation == 'add' and doorCalls[2].state == 1)
      assert(doorCalls[3].operation == 'ratio' and doorCalls[4].operation == 'distance')
      assert(iplCalls[1].operation == 'request' and iplCalls[1].name == 'fixture_ipl')
      assert(interiorCalls[1].operation == 'activate')
      assert(interiorCalls[2].operation == 'color' and interiorCalls[3].operation == 'refresh')

      local anchors = clientExports.NearbyAnchors({ limit = 1, maxDistance = 10,
        tag = 'synex.anchor.counter' })
      assert(#anchors == 1 and anchors[1].key == 'fixture:reception')
      local doors = clientExports.NearbyObjects('door', { limit = 1,
        maxDistance = 5, tag = 'synex.door.entry' })
      local portals = clientExports.NearbyObjects('portal', { limit = 1,
        maxDistance = 10, tag = 'synex.portal.transit' })
      assert(#doors == 1 and doors[1].key == 'fixture:front.door')
      assert(#portals == 1 and portals[1].key == 'fixture:platform.portal')
      doors[1].key = 'tampered:door'
      assert(clientExports.ResolveCached('door', 'fixture:front.door').key
        == 'fixture:front.door')
      assert(#clientExports.NearbyObjects('door', { maxDistance = 4 }) == 0)
      assert(#clientExports.NearbyObjects('room', {}) == 0)
      anchors[1].key = 'tampered:anchor'
      assert(clientExports.ResolveCached('anchor', 'fixture:reception').key
        == 'fixture:reception')
      local context = clientExports.GetContext()
      context.location.key = 'tampered:location'
      assert(clientExports.CurrentLocation().key == 'fixture:station')

      network['synex_world:client:replace_slice'](slice)
      assert(#localEvents == 4 and #doorCalls == 4)

      network['synex_world:client:door_state']({ schemaVersion = 1,
        key = 'fixture:front.door', state = 'UNLOCKED', stateVersion = 5,
        definitionRevision = 2, revision = 8 })
      assert(doorCalls[5].operation == 'state' and doorCalls[5].state == 0)
      local doorCallCount = #doorCalls
      network['synex_world:client:door_state']({ schemaVersion = 1,
        key = 'fixture:front.door', state = 'LOCKED', stateVersion = 4,
        definitionRevision = 2, revision = 9 })
      assert(#doorCalls == doorCallCount)
      assert(clientExports.ResolveCached('door', 'fixture:front.door').state == 'UNLOCKED')

      source = 41
      network['synex_world:client:apply_transition']({ schemaVersion = 1, revision = 7,
        grantId = 'grant-00000001', destination = { x = 10.0, y = 20.0, z = 30.0,
          heading = 90.0 } })
      assert(#teleports == 0)
      source = 65535
      network['synex_world:client:apply_transition']({ schemaVersion = 1, revision = 7,
        grantId = 'grant-00000001', destination = { x = 10.0, y = 20.0, z = 30.0,
          heading = 90.0 } })
      assert(#teleports == 1 and teleports[1].heading == 90.0)
      network['synex_world:client:apply_transition']({ schemaVersion = 1, revision = 7,
        grantId = 'grant-00000001', destination = { x = 11.0, y = 21.0, z = 31.0 } })
      assert(#teleports == 1)
      network['synex_world:client:apply_transition']({ schemaVersion = 1, revision = 7,
        grantId = 'grant-heading-boundary', destination = {
          x = 11.0, y = 21.0, z = 31.0, heading = 360000.0 } })
      assert(#teleports == 2 and teleports[2].heading == 360000.0)
      network['synex_world:client:apply_transition']({ schemaVersion = 1, revision = 7,
        grantId = 'grant-heading-overflow', destination = {
          x = 11.0, y = 21.0, z = 31.0, heading = 360001.0 } })
      assert(#teleports == 2)

      -- Pending transition deadlines remain monotonic across FiveM's signed
      -- 32-bit GetGameTimer wrap and therefore do not expire spuriously.
      now, playerPed = 2147483646, 0
      network['synex_world:client:apply_transition']({ schemaVersion = 1, revision = 8,
        grantId = 'grant-wrap-000001', destination = { x = 12.0, y = 22.0, z = 32.0,
          heading = 180.0 } })
      assert(#teleports == 2)
      now, playerPed = -2147483640, 77
      local waits = 0
      Wait = function(delay)
        assert(delay == 250)
        waits = waits + 1
        if waits > 1 then error('bounded test stop') end
      end
      local ran, runError = pcall(threads[1])
      assert(not ran and tostring(runError):find('bounded test stop', 1, true))
      assert(#teleports == 3 and teleports[3].heading == 180.0)

      handlers.onClientResourceStop('another_resource')
      assert(activeIpls.fixture_ipl == true and registeredDoors[101] == true)
      handlers.onClientResourceStop('synex_world')
      assert(activeIpls.fixture_ipl == nil and registeredDoors[101] == nil)
      assert(activeSets['7:fixture_set'] == nil)
      assert(clientExports.GetContext().revision == 0)
      return table.concat({ #localEvents, #doorCalls, #iplCalls,
        #interiorCalls, #teleports }, ':')
    `);
    assert.equal(result, '4:9:2:5:3');
  } finally {
    engine.global.close();
  }
});

test('world client rejects oversized, stale and malformed projections fail closed', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    const runtime = await bootstrap(engine);
    const result = await engine.doString(`
      local network, handlers, clientExports = {}, {}, {}
      local localEvents, nativeCalls = {}, 0
      RegisterNetEvent = function(name, handler) network[name] = handler end
      AddEventHandler = function(name, handler) handlers[name] = handler end
      exports = function(name, handler) clientExports[name] = handler end
      CreateThread = function() end
      TriggerEvent = function(name) localEvents[#localEvents + 1] = name end
      GetCurrentResourceName = function() return 'synex_world' end
      GetGameTimer = function() return 1000 end
      IsDoorRegisteredWithSystem = function() return false end
      AddDoorToSystem = function() nativeCalls = nativeCalls + 1 end
      DoorSystemGetIsPhysicsLoaded = function() return true end
      DoorSystemSetDoorState = function() nativeCalls = nativeCalls + 1 end
      IsIplActive = function() return false end
      RequestIpl = function() nativeCalls = nativeCalls + 1 end
      RemoveIpl = function() nativeCalls = nativeCalls + 1 end
      IsValidInterior = function() return true end
      IsInteriorEntitySetActive = function() return false end
      ActivateInteriorEntitySet = function() nativeCalls = nativeCalls + 1 end
      DeactivateInteriorEntitySet = function() nativeCalls = nativeCalls + 1 end
      RefreshInterior = function() nativeCalls = nativeCalls + 1 end
      PlayerPedId = function() return 11 end
      SetEntityCoordsNoOffset = function() nativeCalls = nativeCalls + 1 end
      SetEntityHeading = function() nativeCalls = nativeCalls + 1 end
      assert(load(${JSON.stringify(runtime)}, '@resources/synex_world/client/runtime.lua'))()

      source = 65535
      network['synex_world:client:replace_slice']({
        schemaVersion = 1, revision = 1, context = {},
      })
      assert(clientExports.GetContext().revision == 1 and nativeCalls == 0)

      local anchors = {}
      for index = 1, SynexWorldLimits.maximumSliceObjects + 1 do
        anchors[index] = { key = ('fixture:anchor.%04d'):format(index) }
      end
      network['synex_world:client:replace_slice']({
        schemaVersion = 1, revision = 2, context = {}, anchors = anchors,
      })
      assert(clientExports.GetContext().revision == 1)

      network['synex_world:client:replace_slice']({
        schemaVersion = 1, revision = 2, context = {}, unexpected = true,
      })
      network['synex_world:client:replace_slice']({
        schemaVersion = 1, revision = 2, context = {},
        ipls = {{ name = 'fixture_ipl', refCount = 0 }},
      })
      network['synex_world:client:replace_slice']({
        schemaVersion = 1, revision = 2, context = {},
        anchors = {{ key = 'fixture:anchor', label = 'bad' .. string.char(127) }},
      })
      network['synex_world:client:replace_slice']({
        schemaVersion = 1, revision = 2, context = {},
        doors = {{ key = 'fixture:door.a', state = 'LOCKED', revision = 1,
          leaves = {{ doorHash = -1, modelHash = 2, position = { x = 0, y = 0, z = 0 } }} },
          { key = 'fixture:door.b', state = 'LOCKED', revision = 1,
          leaves = {{ doorHash = 4294967295, modelHash = 3,
            position = { x = 1, y = 1, z = 1 } }} }},
      })
      assert(clientExports.GetContext().revision == 1 and nativeCalls == 0)

      network['synex_world:client:door_state']({ schemaVersion = 1,
        key = 'fixture:missing', state = 'LOCKED', revision = 2 })
      network['synex_world:client:apply_transition']({ schemaVersion = 1, revision = 1,
        grantId = 'grant-invalid-01', destination = { x = 0 / 0, y = 0, z = 0 } })
      assert(nativeCalls == 0)

      source = 41
      network['synex_world:client:replace_slice']({
        schemaVersion = 1, revision = 3, context = {
          location = { key = 'fixture:should_not_apply' },
        },
      })
      assert(clientExports.GetContext().revision == 1 and #localEvents == 0)
      return table.concat({ clientExports.GetContext().revision, nativeCalls,
        #localEvents }, ':')
    `);
    assert.equal(result, '1:0:0');
  } finally {
    engine.global.close();
  }
});

test('world client preserves pre-existing DoorSystem, IPL and interior ownership on cleanup', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    const runtime = await bootstrap(engine);
    const result = await engine.doString(`
      local network, handlers, clientExports = {}, {}, {}
      local addDoor, removeDoor, requestIpl, removeIpl, activateSet, deactivateSet = 0, 0, 0, 0, 0, 0
      RegisterNetEvent = function(name, handler) network[name] = handler end
      AddEventHandler = function(name, handler) handlers[name] = handler end
      exports = function(name, handler) clientExports[name] = handler end
      CreateThread = function() end
      TriggerEvent = function() end
      GetCurrentResourceName = function() return 'synex_world' end
      GetGameTimer = function() return 1000 end
      IsDoorRegisteredWithSystem = function(hash) return hash == 501 end
      AddDoorToSystem = function() addDoor = addDoor + 1 end
      DoorSystemGetIsPhysicsLoaded = function() return true end
      DoorSystemSetDoorState = function() end
      RemoveDoorFromSystem = function() removeDoor = removeDoor + 1 end
      IsIplActive = function(name) return name == 'external_ipl' end
      RequestIpl = function() requestIpl = requestIpl + 1 end
      RemoveIpl = function() removeIpl = removeIpl + 1 end
      IsValidInterior = function(id) return id == 9 end
      IsInteriorEntitySetActive = function(id, name)
        return id == 9 and name == 'external_set'
      end
      ActivateInteriorEntitySet = function() activateSet = activateSet + 1 end
      DeactivateInteriorEntitySet = function() deactivateSet = deactivateSet + 1 end
      RefreshInterior = function() end
      assert(load(${JSON.stringify(runtime)}, '@resources/synex_world/client/runtime.lua'))()

      source = 65535
      network['synex_world:client:replace_slice']({ schemaVersion = 1, revision = 1,
        context = {},
        doors = {{ key = 'fixture:external.door', state = 'LOCKED', revision = 1,
          leaves = {{ doorHash = 501, modelHash = 601,
            position = { x = 1, y = 2, z = 3 } }} }},
        ipls = { 'external_ipl' },
        interiorSets = {{ interiorId = 9, name = 'external_set' }},
      })
      assert(clientExports.GetContext().revision == 1)
      assert(addDoor == 0 and requestIpl == 0 and activateSet == 0)
      handlers.onClientResourceStop('synex_world')
      assert(removeDoor == 0 and removeIpl == 0 and deactivateSet == 0)
      return table.concat({ addDoor, removeDoor, requestIpl, removeIpl,
        activateSet, deactivateSet }, ':')
    `);
    assert.equal(result, '0:0:0:0:0:0');
  } finally {
    engine.global.close();
  }
});

test('world client source contains no client-to-server mutation path or frame loop', async () => {
  const runtime = await source('resources/synex_world/client/runtime.lua');
  assert.doesNotMatch(runtime, /TriggerServerEvent/u);
  assert.match(runtime, /RECONCILE_INTERVAL_MS = 250/u);
  assert.match(runtime, /Wait\(RECONCILE_INTERVAL_MS\)/u);
  assert.doesNotMatch(runtime, /Wait\(0\)/u);
  assert.match(runtime,
    /AddDoorToSystem,[\s\S]*false, false, false\)/u);
  assert.match(runtime,
    /DoorSystemSetDoorState,[\s\S]*false, true\)/u);
  assert.match(runtime,
    /SetEntityCoordsNoOffset\(ped,[\s\S]*true, true, true\)/u);
});

test('world client accepts definition revisions ahead of stream revisions and reconciles IPL references', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    const runtime = await bootstrap(engine);
    const result = await engine.doString(`
      local network, handlers, clientExports, threads = {}, {}, {}, {}
      local registered, activeIpls = {}, {}
      local stateCalls, requested, removed = {}, {}, {}
      RegisterNetEvent = function(name, handler) network[name] = handler end
      AddEventHandler = function(name, handler) handlers[name] = handler end
      exports = function(name, handler) clientExports[name] = handler end
      CreateThread = function(handler) threads[#threads + 1] = handler end
      Wait = function() end
      TriggerEvent = function() end
      GetCurrentResourceName = function() return 'synex_world' end
      GetGameTimer = function() return 1000 end
      IsDoorRegisteredWithSystem = function(hash) return registered[hash] == true end
      AddDoorToSystem = function(hash) registered[hash] = true end
      DoorSystemGetIsPhysicsLoaded = function() return true end
      DoorSystemSetDoorState = function(hash, state)
        stateCalls[#stateCalls + 1] = { hash = hash, state = state }
      end
      RemoveDoorFromSystem = function(hash) registered[hash] = nil end
      IsIplActive = function(name) return activeIpls[name] == true end
      RequestIpl = function(name)
        activeIpls[name] = true; requested[#requested + 1] = name
      end
      RemoveIpl = function(name)
        activeIpls[name] = nil; removed[#removed + 1] = name
      end
      IsValidInterior = function() return false end
      assert(load(${JSON.stringify(runtime)}, '@resources/synex_world/client/runtime.lua'))()

      source = 65535
      network['synex_world:client:replace_slice']({ schemaVersion = 1, revision = 1,
        context = {}, doors = {{ kind = 'door', key = 'synex_test:door', revision = 19,
          state = 'LOCKED', stateVersion = 3, leaves = {{ doorHash = 101,
            modelHash = 202, position = { x = 0, y = 0, z = 0 } }} }},
        ipls = {{ name = 'shared_ipl', refCount = 2 }} })
      assert(clientExports.GetContext().revision == 1 and #stateCalls == 1
        and stateCalls[1].state == 1 and #requested == 1 and #removed == 0)

      network['synex_world:client:door_state']({ schemaVersion = 1,
        key = 'synex_test:door', state = 'UNLOCKED', stateVersion = 4,
        definitionRevision = 19, revision = 2 })
      assert(clientExports.GetContext().revision == 2 and #stateCalls == 2
        and stateCalls[2].state == 0)
      network['synex_world:client:door_state']({ schemaVersion = 1,
        key = 'synex_test:door', state = 'LOCKED', stateVersion = 5,
        definitionRevision = 18, revision = 3 })
      assert(clientExports.GetContext().revision == 2 and #stateCalls == 2)

      network['synex_world:client:replace_slice']({ schemaVersion = 1, revision = 3,
        context = {}, doors = {{ kind = 'door', key = 'synex_test:door', revision = 19,
          state = 'UNLOCKED', stateVersion = 4, leaves = {{ doorHash = 101,
            modelHash = 202, position = { x = 0, y = 0, z = 0 } }} }},
        ipls = {{ name = 'shared_ipl', refCount = 1 }} })
      assert(#requested == 1 and #removed == 0 and activeIpls.shared_ipl == true)
      network['synex_world:client:replace_slice']({ schemaVersion = 1, revision = 4,
        context = {}, doors = {} })
      assert(#requested == 1 and #removed == 1 and activeIpls.shared_ipl == nil)
      network['synex_world:client:replace_slice']({ schemaVersion = 1, revision = 5,
        context = {}, doors = {}, ipls = { 'shared_ipl' } })
      assert(#requested == 2 and #removed == 1 and activeIpls.shared_ipl == true)
      handlers.onClientResourceStop('synex_world')
      assert(#removed == 2 and activeIpls.shared_ipl == nil)
      return table.concat({ #stateCalls, #requested, #removed,
        clientExports.GetContext().revision }, ':')
    `);
    assert.equal(result, '3:2:2:0');
  } finally {
    engine.global.close();
  }
});
