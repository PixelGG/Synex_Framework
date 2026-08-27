import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import test from "node:test";
import { LuaFactory } from "wasmoon";

const root = process.cwd();

type Provider = "qb" | "qbx" | "esx";
type Projection = {
  identity: string;
  cash: number;
  bank: number;
  job: string;
  grade: number;
  onDuty: boolean;
  gang: string;
  gangGrade: number;
  unsupportedCode: string;
  fenced: boolean;
  mapping: string;
};

async function project(provider: Provider): Promise<Projection> {
  const engine = await new LuaFactory().createEngine();
  const source = await readFile(
    join(root, "resources", `synex_bridge_${provider}`, "server.lua"),
    "utf8",
  );
  try {
    await engine.doString(String.raw`
      registered, lastFence, options = {}, nil, nil
      snapshot = {
        source = 42,
        identity = { identifier = 'legacy-identity-42' },
        character = {
          id = 'internal-character-id', slot = 2,
          firstName = 'Ada', lastName = 'Lovelace', dateOfBirth = '1815-12-10',
        },
        money = { cash = 125, bank = 900 },
        accountDefinitions = {
          cash = { alias = 'cash', name = 'money', label = 'Cash',
            round = true, minorUnit = 0 },
          bank = { alias = 'bank', name = 'bank', label = 'Bank',
            round = true, minorUnit = 0 },
        },
        fence = {
          sessionId = 'internal-session-id', sourceGeneration = 7,
          characterId = 'internal-character-id',
        },
        metadata = { hunger = 40 }, metadataVersions = { hunger = 3 },
        groups = { items = {
          {
            membership_id = 'internal-membership-job', status = 'ACTIVE',
            is_primary = true, roles = {}, roles_truncated = false,
            group = {
              group_id = 'internal-group-job', key = 'police', type = 'job',
              name = 'Police', label = 'Police Department',
            },
            grade = { key = 'sergeant', name = 'Sergeant', rank = 3 },
            duty = { counts_as_on_duty = true },
          },
          {
            membership_id = 'internal-membership-gang', status = 'ACTIVE',
            is_primary = true, roles = {}, roles_truncated = false,
            group = {
              group_id = 'internal-group-gang', key = 'ballas', type = 'gang',
              name = 'Ballas', label = 'Ballas',
            },
            grade = { key = 'member', name = 'Member', rank = 1 },
            duty = { counts_as_on_duty = false },
          },
        }, truncated = false },
      }
      local adapter = {}
      function adapter:authorize()
        return { authority = 'operator_registry', mode = 'compat', traceId = 'fixture' }, nil
      end
      function adapter:trace(_, _, _, handler) return handler() end
      function adapter:readPlayer(_, playerSource)
        assert(playerSource == 42)
        return snapshot, nil
      end
      function adapter:readPlayerFenced(_, playerSource, fence)
        assert(playerSource == 42)
        lastFence = fence
        if fence.sessionId ~= snapshot.fence.sessionId
          or fence.sourceGeneration ~= snapshot.fence.sourceGeneration
          or fence.characterId ~= snapshot.fence.characterId then
          return nil, { code = 'COMPAT_STALE_SESSION' }
        end
        return snapshot, nil
      end
      function adapter:readMoney(_, playerSource)
        assert(playerSource == 42)
        return snapshot, nil
      end
      function adapter:readMoneyFenced(_, playerSource, fence)
        return adapter:readPlayerFenced(nil, playerSource, fence)
      end
      function adapter:readCustomAccountsFenced(_, playerSource, fence)
        return adapter:readPlayerFenced(nil, playerSource, fence)
      end
      function adapter:readGroups(_, playerSource)
        assert(playerSource == 42)
        return snapshot, nil
      end
      function adapter:readGroupsFenced(_, playerSource, fence)
        return adapter:readPlayerFenced(nil, playerSource, fence)
      end
      function adapter:unsupported()
        return nil, { code = 'COMPAT_API_UNSUPPORTED' }
      end
      function adapter:registerCallback() return true, nil end
      function adapter:setGroup()
        return nil, { code = 'COMPAT_API_UNSUPPORTED' }
      end
      function adapter:setDuty()
        return nil, { code = 'COMPAT_API_UNSUPPORTED' }
      end
      function adapter:registerLifecycle(mapper)
        assert(type(mapper(snapshot)) == 'table')
        return 'fixture-lifecycle', nil
      end
      function adapter:usageSnapshot() return { framework = '${provider}', entries = {} } end
      SynexBridgeNative = {
        create = function(value) options = value return adapter end,
      }
      exports = setmetatable({}, {
        __call = function(_, name, handler) registered[name] = handler end,
      })
      GetInvokingResource = function() return 'legacy_consumer' end
      AddEventHandler = function() end

      function fenced()
        return type(lastFence) == 'table'
          and lastFence.sessionId == snapshot.fence.sessionId
          and lastFence.sourceGeneration == snapshot.fence.sourceGeneration
          and lastFence.characterId == snapshot.fence.characterId
      end
      function mapping()
        if options.discoverAccountMappings == true then return 'cash:bank' end
        assert(options.moneyMappings == nil and #options.moneyAliases == 2)
        return table.concat(options.moneyAliases, ':')
      end
      function result(identity, cash, bank, job, grade, duty,
        gang, gangGrade, unsupportedCode)
        return table.concat({ identity, cash, bank, job, grade, tostring(duty),
          gang, gangGrade, unsupportedCode, tostring(fenced()), mapping() }, '\31')
      end
    `);
    await engine.doString(source);

    let encoded: unknown;
    if (provider === "qb") {
      encoded = await engine.doString(String.raw`
        local player = assert(registered.GetPlayer(42))
        assert(player.Functions.GetMoney('cash') == 125)
        local supported, unsupported = player.Functions.SetJob()
        assert(supported == false)
        return result(player.PlayerData.citizenid, player.PlayerData.money.cash,
          player.PlayerData.money.bank, player.PlayerData.job.name,
          player.PlayerData.job.grade.level, player.PlayerData.job.onduty,
          player.PlayerData.gang.name, player.PlayerData.gang.grade.level,
          unsupported.code)
      `);
    } else if (provider === "qbx") {
      encoded = await engine.doString(String.raw`
        local player = assert(registered.GetPlayer(42))
        assert(player.Functions.GetMoney('cash') == 125)
        local supported, unsupported = player.Functions.SetGang()
        assert(supported == false)
        return result(player.PlayerData.citizenid, player.PlayerData.money.cash,
          player.PlayerData.money.bank, player.PlayerData.job.name,
          player.PlayerData.job.grade.level, player.PlayerData.job.onduty,
          player.PlayerData.gang.name, player.PlayerData.gang.grade.level,
          unsupported.code)
      `);
    } else {
      encoded = await engine.doString(String.raw`
        local player = assert(registered.GetPlayerFromId(42))
        local identity = assert(player.getIdentifier())
        local cash = assert(player.getMoney())
        local bank = assert(player.getAccount('bank')).money
        local job = assert(player.getJob())
        local group, unsupported = player.getGroup()
        assert(group == nil)
        return result(identity, cash, bank, job.name, job.grade, job.onDuty,
          'not_projected', -1, unsupported.code)
      `);
    }

    const fields = String(encoded).split("\u001f");
    assert.equal(fields.length, 11);
    return {
      identity: fields[0]!,
      cash: Number(fields[1]),
      bank: Number(fields[2]),
      job: fields[3]!,
      grade: Number(fields[4]),
      onDuty: fields[5] === "true",
      gang: fields[6]!,
      gangGrade: Number(fields[7]),
      unsupportedCode: fields[8]!,
      fenced: fields[9] === "true",
      mapping: fields[10]!,
    };
  } finally {
    engine.global.close();
  }
}

test("QB, Qbox, and ESX project one canonical snapshot without cross-framework leakage", async () => {
  const [qb, qbx, esx] = await Promise.all([
    project("qb"), project("qbx"), project("esx"),
  ]);

  const common = ({ identity, cash, bank, job, grade, onDuty, mapping }: Projection) => ({
    identity, cash, bank, job, grade, onDuty, mapping,
  });
  assert.deepEqual(common(qb), common(qbx));
  assert.deepEqual(common(qb), common(esx));
  assert.deepEqual(common(qb), {
    identity: "legacy-identity-42",
    cash: 125,
    bank: 900,
    job: "police",
    grade: 3,
    onDuty: true,
    mapping: "cash:bank",
  });

  assert.deepEqual(
    { gang: qb.gang, grade: qb.gangGrade },
    { gang: qbx.gang, grade: qbx.gangGrade },
  );
  assert.deepEqual({ gang: qb.gang, grade: qb.gangGrade }, { gang: "ballas", grade: 1 });
  assert.equal(esx.gang, "not_projected");
  assert.equal(esx.gangGrade, -1);
  assert.ok([qb, qbx, esx].every((entry) => entry.fenced));
  assert.ok(
    [qb, qbx, esx].every((entry) => entry.unsupportedCode === "COMPAT_API_UNSUPPORTED"),
  );
});
