import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import test from "node:test";
import { LuaFactory } from "wasmoon";

const root = process.cwd();

test("QB permission checks are bounded read-only projections over explicit mappings", async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await engine.doString(String.raw`
      registered, permissionReads = {}, 0
      local adapter = {}
      function adapter:authorize() return { traceId = 'permission-qb' }, nil end
      function adapter:trace(_, _, _, handler) return handler() end
      function adapter:readPermissionGroups(consumer, playerSource, fence)
        assert(consumer == 'legacy_consumer' and playerSource == 42 and fence == nil)
        permissionReads = permissionReads + 1
        return {
          groups = { 'admin', 'mod' }, primary = 'admin', fallback = 'user',
        }, nil
      end
      function adapter:registerLifecycle() return 'lifecycle-qb', nil end
      SynexBridgeNative = { create = function() return adapter end }
      exports = setmetatable({ synex_bridge = {} }, {
        __call = function(_, name, handler) registered[name] = handler end,
      })
      GetInvokingResource = function() return 'legacy_consumer' end
      AddEventHandler = function() end
    `);
    await engine.doString(await readFile(
      join(root, "resources", "synex_bridge_qb", "server.lua"), "utf8",
    ));
    const result = await engine.doString(String.raw`
      local core = assert(registered.GetCoreObject())
      assert(core.Functions.HasPermission(42, 'admin') == true)
      assert(core.Functions.HasPermission(42, 'user') == true)
      assert(core.Functions.HasPermission(42, 'god') == false)
      assert(core.Functions.HasPermission(42, { 'god', 'mod' }) == true)
      local projected = assert(core.Functions.GetPermission(42))
      assert(projected.admin == true and projected.mod == true and projected.user == true)
      projected.admin = false
      assert(core.Functions.GetPermission(42).admin == true)

      local before = permissionReads
      local invalid, invalidError = core.Functions.HasPermission(42, {})
      assert(invalid == false and invalidError.code == 'COMPAT_DTO_INVALID')
      local sparse, sparseError = core.Functions.HasPermission(
        42, { [1] = 'admin', [3] = 'mod' })
      assert(sparse == false and sparseError.code == 'COMPAT_DTO_INVALID')
      local duplicate, duplicateError = core.Functions.HasPermission(
        42, { 'admin', 'admin' })
      assert(duplicate == false and duplicateError.code == 'COMPAT_DTO_INVALID')
      assert(permissionReads == before)
      return permissionReads
    `);
    assert.equal(result, 6);
  } finally {
    engine.global.close();
  }
});

test("ESX getGroup uses the fenced permission view and propagates mapping failures", async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await engine.doString(String.raw`
      registered, permissionFailure, permissionReads = {}, false, 0
      snapshot = {
        source = 42,
        identity = { identifier = 'legacy-42' },
        character = { id = 'character-42', firstName = 'Ada', lastName = 'Lovelace' },
        money = { cash = 10, bank = 20 },
        accountDefinitions = {
          cash = { alias = 'cash', name = 'money', label = 'Cash',
            round = true, minorUnit = 0 },
          bank = { alias = 'bank', name = 'bank', label = 'Bank',
            round = true, minorUnit = 0 },
        },
        groups = { items = {{
          is_primary = true,
          group = { type = 'job', key = 'police', label = 'Police' },
          grade = { key = 'officer', name = 'Officer', rank = 1 },
          duty = { counts_as_on_duty = true }, roles = {},
        }}, truncated = false },
        metadata = {}, metadataVersions = {},
        fence = {
          sessionId = 'session-42', sourceGeneration = 7,
          characterId = 'character-42',
        },
      }
      local adapter = {}
      function adapter:authorize() return { traceId = 'permission-esx' }, nil end
      function adapter:trace(_, _, _, handler) return handler() end
      function adapter:readPlayer(_, playerSource)
        assert(playerSource == 42)
        return snapshot, nil
      end
      function adapter:readPermissionGroups(consumer, playerSource, fence)
        assert(consumer == 'legacy_consumer' and playerSource == 42)
        assert(fence.sessionId == 'session-42' and fence.sourceGeneration == 7)
        permissionReads = permissionReads + 1
        if permissionFailure then
          return nil, { code = 'COMPAT_MAPPING_MISSING', retryable = false }
        end
        return { groups = { 'admin' }, primary = 'admin', fallback = 'user' }, nil
      end
      function adapter:registerLifecycle() return 'lifecycle-esx', nil end
      SynexBridgeNative = { create = function() return adapter end }
      exports = setmetatable({ synex_bridge = {} }, {
        __call = function(_, name, handler) registered[name] = handler end,
      })
      GetInvokingResource = function() return 'legacy_consumer' end
      AddEventHandler = function() end
    `);
    await engine.doString(await readFile(
      join(root, "resources", "synex_bridge_esx", "server.lua"), "utf8",
    ));
    const result = await engine.doString(String.raw`
      local player = assert(registered.GetPlayerFromId(42))
      local group, groupError = player.getGroup()
      assert(group == 'admin' and groupError == nil)
      permissionFailure = true
      local missing, missingError = player.getGroup()
      assert(missing == nil and missingError.code == 'COMPAT_MAPPING_MISSING')
      return permissionReads
    `);
    assert.equal(result, 2);
  } finally {
    engine.global.close();
  }
});
