import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { LuaFactory, type LuaEngine } from "wasmoon";

import type { ContractFuzzReport } from "./types.ts";

type RuntimeReport = ContractFuzzReport["runtimeScenarios"];

async function load(engine: LuaEngine, repositoryRoot: string, path: string): Promise<void> {
  await engine.doString(await readFile(join(repositoryRoot, path), "utf8"));
}

export async function runHeadlessRuntimeFuzz(repositoryRoot: string): Promise<RuntimeReport> {
  const scenarios: RuntimeReport["scenarios"] = [];
  let engine: LuaEngine | null = null;
  try {
    engine = await new LuaFactory().createEngine();
    for (const path of [
      "core/synex_core/shared/protocol.lua",
      "core/synex_core/server/factories.lua",
      "core/synex_core/server/foundation.lua",
      "core/synex_core/server/contracts.lua",
      "core/synex_core/server/registries.lua",
      "core/synex_core/server/security.lua",
      "core/synex_core/server/reliability.lua",
    ]) {
      await load(engine, repositoryRoot, path);
    }
    await engine.doString(`
      local monotonic = 1000
      FuzzPlatform = {
        nowGame = function() monotonic = monotonic + 1 return monotonic end,
        random = function(_, maximum) return math.min(maximum or 1, 123456) end,
        print = function() end,
        jsonEncode = function(value)
          if type(value) ~= 'table' then return tostring(value) end
          local keys = {}
          for key in pairs(value) do keys[#keys + 1] = tostring(key) end
          table.sort(keys)
          local parts = {}
          for _, key in ipairs(keys) do parts[#parts + 1] = key .. '=' .. tostring(value[key]) end
          return '{' .. table.concat(parts, ',') .. '}'
        end,
        jsonDecode = function() return { ok = true } end,
        loadResourceFile = function() return nil end,
        setTimeout = function(_, callback) callback() end
      }
    `);

    const execute = async (name: string, detail: string, source: string): Promise<void> => {
      try {
        const result = await engine?.doString(source);
        if (result !== true) throw new Error("scenario did not return true");
        scenarios.push({ name, status: "PASS", detail });
      } catch (error) {
        scenarios.push({
          name,
          status: "FAIL",
          detail: `${detail} (${error instanceof Error ? error.message : "unknown Lua harness failure"})`,
        });
      }
    };

    await execute(
      "stale-session",
      "The real player registry rejected a reused source generation.",
      `
        local foundation = SynexCoreFactories.foundation({ platform = FuzzPlatform })
        local players = SynexCoreFactories.registries({ foundation = foundation }).players
        assert(players:createPending(1, { sessionId = 'session-one' }))
        local first = assert(players:bindJoined(1, 51, { id = 'session-one', userId = 'u1', state = 'ACTIVE' }))
        assert(players:isCurrent('session-one', 51, first.sourceGeneration))
        players:removeSession('session-one')
        assert(players:createPending(2, { sessionId = 'session-two' }))
        assert(players:bindJoined(2, 51, { id = 'session-two', userId = 'u2', state = 'ACTIVE' }))
        assert(not players:isCurrent('session-one', 51, first.sourceGeneration))
        return true
      `,
    );

    await execute(
      "duplicate-idempotency-key",
      "The real idempotency coordinator replayed a completed response without executing the handler twice.",
      `
        local foundation = SynexCoreFactories.foundation({ platform = FuzzPlatform })
        foundation.configureIds('fuzz')
        local records = {}
        local database = {}
        function database:update(statement, parameters)
          if statement:find('INSERT IGNORE', 1, true) then
            local key = parameters[1] .. ':' .. parameters[2]
            if records[key] then return 0 end
            records[key] = { request_hash = parameters[3], state = 'pending', owner_token = parameters[4], lock_expired = 0, record_expired = 0 }
            return 1
          end
          if statement:find("state", 1, true) and statement:find("completed", 1, true) then
            local key = parameters[2] .. ':' .. parameters[3]
            local record = records[key]
            if not record or record.owner_token ~= parameters[4] then return 0 end
            record.state = 'completed'; record.response_json = parameters[1]
            return 1
          end
          return 1
        end
        function database:query(_, parameters)
          local record = records[parameters[1] .. ':' .. parameters[2]]
          return record and { record } or {}
        end
        local reliability = SynexCoreFactories.reliability({
          foundation = foundation, platform = FuzzPlatform, database = database,
          instanceId = 'fuzz', sha256 = function(value) return value end, features = {}
        })
        local calls = 0
        local function handler() calls = calls + 1; return { ok = true } end
        local first, firstError, firstMeta = reliability.idempotency:run('synex_fuzz', 'transfer', 'fuzz-key-0001', { amount = 10 }, handler)
        assert(first and not firstError and firstMeta.replayed == false)
        local replay, replayError, replayMeta = reliability.idempotency:run('synex_fuzz', 'transfer', 'fuzz-key-0001', { amount = 10 }, handler)
        assert(replay and not replayError and replayMeta.replayed == true and calls == 1)
        return true
      `,
    );

    await execute(
      "flood",
      "The real token bucket rejected requests beyond its deterministic burst capacity.",
      `
        local foundation = SynexCoreFactories.foundation({ platform = FuzzPlatform })
        local security = SynexCoreFactories.security({
          platform = FuzzPlatform, foundation = foundation, coreResource = 'synex_core',
          policy = { default = { allow = {}, deny = {} }, resources = {} }
        })
        local accepted, rejected = 0, 0
        for _ = 1, 32 do
          local ok, err = security.rateLimiter:consume('rpc:51', 2, 0.01, 1)
          if ok then accepted = accepted + 1 else assert(err.code == 'RATE_LIMITED'); rejected = rejected + 1 end
        end
        assert(accepted == 2 and rejected == 30)
        return true
      `,
    );

    await execute(
      "unauthorized-operation",
      "The real capability firewall applied undeclared and deny precedence checks.",
      `
        local foundation = SynexCoreFactories.foundation({ platform = FuzzPlatform })
        local security = SynexCoreFactories.security({
          platform = FuzzPlatform, foundation = foundation, coreResource = 'synex_core',
          policy = {
            default = { allow = {}, deny = {} },
            resources = { synex_fuzz = { allow = {'synex.accounts.*'}, deny = {'synex.accounts.mint'} } }
          }
        })
        security.capabilities:registerManifest('synex_fuzz', { capabilities = { request = {'synex.accounts.mint'} } })
        local value, err = security.capabilities:check('synex_fuzz', 'synex.accounts.mint', {})
        assert(value == nil and err.code == 'CAPABILITY_DENIED')
        value, err = security.capabilities:check('synex_fuzz', 'synex.entities.delete', {})
        assert(value == nil and err.code == 'CAPABILITY_UNDECLARED')
        return true
      `,
    );

    await execute(
      "malformed-domain-input",
      "The real contract validator rejected negative, huge, wrong-type, nil, malformed, invalid entity/target, and oversized values.",
      `
        local foundation = SynexCoreFactories.foundation({ platform = FuzzPlatform })
        local contracts = SynexCoreFactories.contracts({ foundation = foundation, protocol = SynexProtocol })
        local schema = {
          type = 'object', additionalProperties = false,
          required = {'amount', 'entity_id', 'target', 'payload'},
          properties = {
            amount = { type = 'integer', minimum = 1, maximum = 1000000 },
            entity_id = { type = 'string', minLength = 8, maxLength = 64, pattern = '^[A-Za-z0-9_:%-]+$' },
            target = { type = 'integer', minimum = 1, maximum = 65535 },
            payload = { type = 'string', maxLength = 128 }
          }
        }
        local valid = { amount = 1, entity_id = 'entity_0001', target = 1, payload = 'ok' }
        assert(contracts.validate(schema, valid))
        local invalid = {
          { amount = -1, entity_id = valid.entity_id, target = 1, payload = 'ok' },
          { amount = 1000000000000, entity_id = valid.entity_id, target = 1, payload = 'ok' },
          { amount = '1', entity_id = valid.entity_id, target = 1, payload = 'ok' },
          { entity_id = valid.entity_id, target = 1, payload = 'ok' },
          { amount = 1, entity_id = {}, target = 1, payload = 'ok' },
          { amount = 1, entity_id = '!', target = 1, payload = 'ok' },
          { amount = 1, entity_id = valid.entity_id, target = 0, payload = 'ok' },
          { amount = 1, entity_id = valid.entity_id, target = 70000, payload = 'ok' },
          { amount = 1, entity_id = valid.entity_id, target = 1, payload = string.rep('x', 129) },
          { amount = 1, entity_id = valid.entity_id, target = 1, payload = 'ok', unexpected = true }
        }
        for _, value in ipairs(invalid) do assert(not contracts.validate(schema, value)) end
        return true
      `,
    );
  } catch (error) {
    return {
      executed: false,
      reason: `The headless Lua harness could not start: ${error instanceof Error ? error.message : "unknown failure"}`,
      engine: null,
      passed: 0,
      failed: 1,
      scenarios: [{ name: "harness-start", status: "FAIL", detail: "Core Lua modules were not executed." }],
      limits: ["No Cfx network transport, OneSync, or live database is present in the headless harness."],
    };
  } finally {
    engine?.global.close();
  }

  const failed = scenarios.filter((scenario) => scenario.status === "FAIL").length;
  return {
    executed: true,
    reason: failed === 0
      ? "Headless scenarios executed against the repository's real Core Lua factories."
      : `${failed} headless Core scenario(s) failed.`,
    engine: "wasmoon Lua VM",
    passed: scenarios.length - failed,
    failed,
    scenarios,
    limits: [
      "The harness executes Core Lua without Cfx networking, OneSync, or a live database.",
      "Flood timing is deterministic and does not replace an adversarial FXServer load test.",
    ],
  };
}
