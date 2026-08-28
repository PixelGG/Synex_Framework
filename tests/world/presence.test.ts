import assert from 'node:assert/strict';
import test from 'node:test';

import { runWorldLua } from './helpers.ts';

test('presence emits debounced enter/leave changes only after minimum dwell', async () => {
  const result = await runWorldLua<string>(String.raw`
    local clock, events = 0, {}
    local presence = SynexWorldPresence.create({
      now = function() return clock end,
      debounceMs = 500,
      minimumDwellMs = 1000,
      emit = function(name, payload)
        events[#events + 1] = { name = name, payload = payload }
      end,
    })
    local session = { characterId = 'character_00000041' }
    local function context(location, room)
      return {
        location = location and { key = location } or nil,
        room = room and { key = room } or nil,
      }
    end

    presence.observe(41, session, context('synex_test:alpha', 'synex_test:room.a'), {})
    clock = 499
    presence.observe(41, session, context('synex_test:alpha', 'synex_test:room.a'), {})
    assert(#events == 0)
    clock = 500
    presence.observe(41, session, context('synex_test:alpha', 'synex_test:room.a'), {})
    assert(#events == 2 and events[1].name == 'synex.world.location.entered'
      and events[2].name == 'synex.world.room.entered')
    assert(events[1].payload.authority == 'VERIFIED'
      and events[1].payload.characterId == session.characterId)

    clock = 700
    presence.observe(41, session, context('synex_test:beta', 'synex_test:room.b'), {})
    clock = 1200
    presence.observe(41, session, context('synex_test:beta', 'synex_test:room.b'), {})
    assert(#events == 2)
    clock = 1500
    presence.observe(41, session, context('synex_test:beta', 'synex_test:room.b'), {})
    assert(#events == 6)
    assert(events[3].name == 'synex.world.location.left'
      and events[4].name == 'synex.world.location.entered')
    assert(events[5].name == 'synex.world.room.left'
      and events[6].name == 'synex.world.room.entered')

    clock = 1600
    presence.observe(41, session, context(nil, nil), {})
    clock = 2100
    presence.observe(41, session, context(nil, nil), {})
    assert(#events == 6)
    clock = 2500
    local stable = presence.observe(41, session, context(nil, nil), {})
    assert(#events == 8 and events[7].name == 'synex.world.location.left'
      and events[8].name == 'synex.world.room.left')
    assert(stable.location == nil and stable.room == nil and presence.count() == 1)
    presence.remove(41)
    assert(presence.count() == 0)
    return table.concat({ #events, events[1].payload.ref,
      events[8].payload.ref, presence.count() }, ':')
  `, [
    'server/presence.lua',
  ]);
  assert.equal(result, '8:synex_test:alpha:synex_test:room.b:0');
});

test('presence cancels transient boundary jitter before debounce elapses', async () => {
  const result = await runWorldLua<string>(String.raw`
    local clock, emitted = 0, 0
    local presence = SynexWorldPresence.create({
      now = function() return clock end,
      debounceMs = 250,
      minimumDwellMs = 500,
      emit = function() emitted = emitted + 1 end,
    })
    local session = { characterId = 'character_00000042' }
    local alpha = { location = { key = 'synex_test:alpha' } }
    local beta = { location = { key = 'synex_test:beta' } }
    presence.observe(42, session, alpha, {})
    clock = 250; presence.observe(42, session, alpha, {})
    assert(emitted == 1)
    clock = 350; presence.observe(42, session, beta, {})
    clock = 450; presence.observe(42, session, alpha, {})
    clock = 900; local stable = presence.observe(42, session, alpha, {})
    assert(emitted == 1 and stable.location == 'synex_test:alpha')
    return table.concat({ emitted, stable.location }, ':')
  `, ['server/presence.lua']);
  assert.equal(result, '1:synex_test:alpha');
});
