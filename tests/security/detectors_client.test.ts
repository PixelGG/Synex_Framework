import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';

const root = process.cwd();

test('Client Sentinel sends a closed advisory sample and retries the same envelope', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await engine.doString(`
      __test = { clock = 100, calls = {}, waits = 0, handlers = {} }
      function GetGameTimer() return __test.clock end
      function PlayerPedId() return 17 end
      function GetEntityCoords() return { x = 1, y = 2, z = 3 } end
      function GetEntityVelocity() return { x = 4, y = 5, z = 6 } end
      function GetGameplayCamCoord() return { x = 7, y = 8, z = 9 } end
      function GetEntityHealth() return 200 end
      function GetPedArmour() return 25 end
      function IsEntityVisible() return true end
      function GetEntityAlpha() return 255 end
      function GetEntityModel() return -1 end
      function GetSelectedPedWeapon() return -2 end
      function IsPedInAnyVehicle() return false end
      function IsPedRagdoll() return false end
      function IsPedFalling() return false end
      function GetPedParachuteState() return -1 end
      function GetCurrentResourceName() return 'synex_security' end
      function AddEventHandler(name, handler) __test.handlers[name] = handler end
      function CreateThread(handler) __test.thread = handler end
      function Wait(value)
        __test.waits = __test.waits + 1
        __test.clock = __test.clock + value
        if __test.waits >= 2 then __test.handlers.onResourceStop('synex_security') end
      end
      exports = { synex_core = {
        Call = function(_, name, version, payload, options)
          __test.calls[#__test.calls + 1] = { name = name, version = version,
            payload = payload, timeoutMs = options.timeoutMs }
          if #__test.calls == 1 then return false, { code = 'TIMEOUT' } end
          return { accepted = true, duplicate = true,
            nextChallengeRef = 'sec-chal-00000001', nextReportAfterMs = 3000 }
        end,
      } }
    `);
    await engine.doString(await readFile(path.join(root,
      'resources/synex_security/client/sentinel.lua'), 'utf8'));
    const result = await engine.doString(`
      __test.thread()
      local first, second = __test.calls[1], __test.calls[2]
      local fields = 0
      for _ in pairs(first.payload.sample) do fields = fields + 1 end
      return { calls = #__test.calls, sameSequence = first.payload.sequence
          == second.payload.sequence,
        sameChallenge = first.payload.challengeRef == second.payload.challengeRef,
        contract = first.name, version = first.version, timeout = first.timeoutMs,
        sampleFields = fields, model = first.payload.sample.model,
        weapon = first.payload.sample.weapon,
        positionX = first.payload.sample.position[1] }
    `) as {
      calls: number;
      sameSequence: boolean;
      sameChallenge: boolean;
      contract: string;
      version: string;
      timeout: number;
      sampleFields: number;
      model: number;
      weapon: number;
      positionX: number;
    };
    assert.deepEqual(result, {
      calls: 2,
      sameSequence: true,
      sameChallenge: true,
      contract: 'synex.security.sentinel.report',
      version: '1.0.0',
      timeout: 5000,
      sampleFields: 10,
      model: 4294967295,
      weapon: 4294967294,
      positionX: 1,
    });
  } finally {
    engine.global.close();
  }
});

test('Client Sentinel reboots its freshness epoch after a server-side stale fence', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await engine.doString(`
      __test = { clock = 100, calls = {}, waits = 0, handlers = {} }
      function GetGameTimer() return __test.clock end
      function PlayerPedId() return 0 end
      function GetGameplayCamCoord() return { x = 0, y = 0, z = 0 } end
      function GetCurrentResourceName() return 'synex_security' end
      function AddEventHandler(name, handler) __test.handlers[name] = handler end
      function CreateThread(handler) __test.thread = handler end
      function Wait(value)
        __test.waits = __test.waits + 1
        __test.clock = __test.clock + value
        if __test.waits >= 2 then __test.handlers.onResourceStop('synex_security') end
      end
      exports = { synex_core = {
        Call = function(_, name, version, payload)
          __test.calls[#__test.calls + 1] = payload
          if #__test.calls == 1 then
            return false, { code = 'SECURITY_SENTINEL_STALE' }
          end
          return { accepted = true, duplicate = false,
            nextChallengeRef = 'sec-chal-00000002', nextReportAfterMs = 3000 }
        end,
      } }
    `);
    await engine.doString(await readFile(path.join(root,
      'resources/synex_security/client/sentinel.lua'), 'utf8'));
    const result = await engine.doString(`
      __test.thread()
      local first, second = __test.calls[1], __test.calls[2]
      return { calls = #__test.calls, firstSequence = first.sequence,
        secondSequence = second.sequence, firstEpoch = first.clientEpoch,
        secondEpoch = second.clientEpoch, firstChallenge = first.challengeRef,
        secondChallenge = second.challengeRef }
    `) as {
      calls: number;
      firstSequence: number;
      secondSequence: number;
      firstEpoch: number;
      secondEpoch: number;
      firstChallenge: string;
      secondChallenge: string;
    };
    assert.equal(result.calls, 2);
    assert.equal(result.firstSequence, 1);
    assert.equal(result.secondSequence, 1);
    assert.notEqual(result.firstEpoch, result.secondEpoch);
    assert.equal(result.firstChallenge, 'bootstrap');
    assert.equal(result.secondChallenge, 'bootstrap');
  } finally {
    engine.global.close();
  }
});
