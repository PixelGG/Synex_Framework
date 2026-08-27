import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import test from "node:test";

const root = process.cwd();
const catalogRoot = join(root, "libraries", "synex_bridge", "compatibility", "surfaces");

type Provider = "qb" | "qbx" | "esx";
type Surface = {
  name: string;
  status: "CERTIFIED" | "COMPATIBLE" | "PARTIAL" | "UNSUPPORTED" | "UNKNOWN";
  nativeMapping: string | null;
  requiredCapability: string | null;
  requiredAdapter: string | null;
  modes: string[];
  tests: string[];
};

const unsupported: Record<Provider, string[]> = {
  qb: [
    "qb.shared.jobs_registry",
    "qb.shared.gangs_registry",
    "qb.shared.vehicles_registry",
    "qb.shared.items_registry",
    "qb.server.permission_admin",
  ],
  qbx: [
    "qbx.server.jobs_registry",
    "qbx.server.gangs_registry",
    "qbx.server.vehicles_registry",
    "qbx.server.routing_bucket_management",
    "qbx.compat.qb_core_object",
    "qbx.server.permission_admin",
  ],
  esx: [
    "esx.xplayer.inventory",
    "esx.xplayer.duty_mutation",
    "esx.server.permission_admin",
  ],
};

const implemented: Record<Provider, string[]> = {
  qb: [
    "qb.server.core_object",
    "qb.server.core_object_filtering",
    "qb.server.player_lookup",
    "qb.server.identifier_player_lookup",
    "qb.server.player_enumeration",
    "qb.server.permission_view",
    "qb.player.money_mutation",
    "qb.player.metadata_mutation",
    "qb.player.group_mutation",
    "qb.player.duty_mutation",
    "qb.shared.lifecycle_events",
    "qb.shared.job_update_events",
    "qb.shared.gang_update_events",
    "qb.shared.duty_update_events",
    "qb.shared.money_update_events",
    "qb.client.player_data",
    "qb.client.callback_invocation",
  ],
  qbx: [
    "qbx.server.player_lookup",
    "qbx.server.identifier_player_lookup",
    "qbx.server.offline_player_lookup",
    "qbx.server.money_read",
    "qbx.server.money_mutation",
    "qbx.server.metadata_read",
    "qbx.server.groups_read",
    "qbx.server.group_mutation",
    "qbx.server.primary_group_mutation",
    "qbx.server.duty_mutation",
    "qbx.shared.lifecycle_events",
    "qbx.shared.group_update_events",
    "qbx.shared.duty_update_events",
    "qbx.shared.money_update_events",
    "qbx.client.player_data",
  ],
  esx: [
    "esx.server.shared_object",
    "esx.server.player_lookup",
    "esx.server.identifier_player_lookup",
    "esx.server.player_enumeration",
    "esx.xplayer.accounts_read",
    "esx.xplayer.custom_accounts",
    "esx.xplayer.permission_group",
    "esx.xplayer.money_mutation",
    "esx.xplayer.job_read",
    "esx.xplayer.job_mutation",
    "esx.shared.lifecycle_events",
    "esx.shared.job_update_events",
    "esx.shared.account_update_events",
    "esx.client.player_data",
    "esx.client.callback_invocation",
  ],
};

async function readCatalog(provider: Provider): Promise<Map<string, Surface>> {
  const document = JSON.parse(
    await readFile(join(catalogRoot, `${provider}.json`), "utf8"),
  ) as { provider: Provider; surfaces: Surface[] };
  assert.equal(document.provider, provider);
  const entries = new Map(document.surfaces.map((surface) => [surface.name, surface]));
  assert.equal(entries.size, document.surfaces.length, `${provider} surface names must be unique`);
  return entries;
}

test("reviewed legacy gaps are explicit unsupported surfaces without invented adapters", async () => {
  for (const provider of ["qb", "qbx", "esx"] as const) {
    const catalog = await readCatalog(provider);
    for (const name of unsupported[provider]) {
      const surface = catalog.get(name);
      assert.ok(surface, `${name} must be represented in the machine-readable catalog`);
      assert.equal(surface.status, "UNSUPPORTED", name);
      assert.equal(surface.nativeMapping, null, name);
      assert.equal(surface.requiredCapability, null, name);
      assert.equal(surface.requiredAdapter, null, name);
      assert.deepEqual([...surface.modes].sort(), ["compat", "silent", "strict"], name);
      assert.ok(
        surface.tests.includes("tests/compatibility/bridge-surface-coverage.test.ts"),
        `${name} must retain its static evidence`,
      );
    }
    for (const name of implemented[provider]) {
      assert.equal(catalog.get(name)?.status, "PARTIAL", `${name} remains implemented only in part`);
    }
  }
});

test("coordinator operations bind to reachable capabilities in the checked-in surface catalogs", async () => {
  const coordinator = await readFile(
    join(root, "libraries", "synex_bridge", "server.lua"),
    "utf8",
  );
  const operationSection = coordinator.match(
    /local OPERATION_SURFACES = \{([\s\S]*?)\n\}\nlocal OPERATION_SUFFIXES/u,
  )?.[1];
  const suffixSection = coordinator.match(
    /local OPERATION_SUFFIXES = \{([\s\S]*?)\n\}\nlocal NATIVE_CAPABILITIES_BY_OPERATION/u,
  )?.[1];
  if (!operationSection || !suffixSection) {
    assert.fail("coordinator operation tables must remain inspectable");
  }

  const suffixes = new Map<string, string>();
  for (const match of suffixSection.matchAll(/\['([^']+)'\]\s*=\s*'([^']+)'/gu)) {
    const operation = match[1];
    const suffix = match[2];
    assert.ok(operation && suffix);
    suffixes.set(operation, suffix);
  }

  for (const provider of ["qb", "qbx", "esx"] as const) {
    const providerMatch: RegExpMatchArray | null = operationSection.match(
      new RegExp(`\\n\\s*${provider} = \\{([\\s\\S]*?)\\n\\s*\\},`, "u"),
    );
    const providerSection: string | undefined = providerMatch?.[1];
    if (!providerSection) {
      assert.fail(`${provider} coordinator operations must remain inspectable`);
    }
    const catalog = await readCatalog(provider);
    const operationMatches: IterableIterator<RegExpExecArray> = providerSection.matchAll(
      /\['([^']+)'\]\s*=\s*'([^']+)'/gu,
    );
    for (const operationMatch of operationMatches) {
      const operation: string | undefined = operationMatch[1];
      const surfaceName: string | undefined = operationMatch[2];
      assert.ok(operation && surfaceName);
      const surface = catalog.get(surfaceName);
      assert.ok(surface, `${provider} operation ${operation} references ${surfaceName}`);
      if (surface.status === "UNSUPPORTED") {
        assert.equal(
          surface.requiredCapability,
          null,
          `${surfaceName} must stay unreachable while it is UNSUPPORTED`,
        );
        continue;
      }
      const suffix = suffixes.get(operation);
      assert.ok(suffix, `${operation} requires a compatibility capability suffix`);
      assert.equal(
        surface.requiredCapability,
        `synex.compat.${provider}.${suffix}`,
        `${surfaceName} must be reachable through its coordinator operation`,
      );
    }
  }
});

test("unsupported catalogs agree with the intentionally absent or rejecting provider APIs", async () => {
  const [qb, qbx, esx, coordinator, native] = await Promise.all([
    readFile(join(root, "resources", "synex_bridge_qb", "server.lua"), "utf8"),
    readFile(join(root, "resources", "synex_bridge_qbx", "server.lua"), "utf8"),
    readFile(join(root, "resources", "synex_bridge_esx", "server.lua"), "utf8"),
    readFile(join(root, "libraries", "synex_bridge", "server.lua"), "utf8"),
    readFile(join(root, "libraries", "synex_bridge", "native_server.lua"), "utf8"),
  ]);

  assert.match(qb, /GetPlayerByCitizenId\s*=\s*function\(citizenId\)[\s\S]{0,200}playerByCitizenIdFor/u);
  assert.match(qb, /GetPlayers\s*=\s*function\(\)[\s\S]{0,200}playerSourcesFor/u);
  assert.match(qb, /HasPermission\s*=\s*function\(playerSource, permission\)/u);
  assert.match(qb, /GetPermission\s*=\s*function\(playerSource\)/u);
  assert.match(qb, /SetJob[\s\S]{0,300}adapter:setGroup/u);
  assert.match(qb, /SetGang[\s\S]{0,300}adapter:setGroup/u);
  assert.doesNotMatch(qb, /exports\(['"](?:GetPlayers|SetJobDuty|AddPermission)/u);

  assert.match(qbx, /exports\(['"]GetPlayerByCitizenId['"]/u);
  assert.match(qbx, /exports\(['"]GetOfflinePlayer['"]/u);
  assert.match(qbx, /exports\(['"]SetPlayerPrimaryJob['"]/u);
  assert.match(qbx, /exports\(['"]SetPlayerPrimaryGang['"]/u);
  assert.match(qbx, /setPrimaryGroup[\s\S]{0,600}adapter:setPrimaryGroup/u);
  assert.match(
    coordinator,
    /\['groups\.set_primary'\]\s*=\s*'qbx\.server\.primary_group_mutation'/u,
  );
  assert.match(native, /function adapter:setPrimaryGroup\(/u);
  assert.doesNotMatch(qbx, /exports\(['"]GetCoreObject/u);
  assert.doesNotMatch(
    qbx,
    /exports\(['"](?:AddPlayerToGroup|RemovePlayerFromGroup|SetPlayerPrimaryGroup|SetPlayerBucket)/u,
  );

  assert.match(esx, /getGroup[\s\S]{0,300}readPermissionGroups/u);
  assert.match(esx, /getAccount[\s\S]{0,300}refreshCustomAccounts/u);
  assert.match(
    coordinator,
    /\['accounts\.custom_read'\]\s*=\s*'esx\.xplayer\.custom_accounts'/u,
  );
  assert.match(native, /function adapter:readCustomAccountsFenced\(/u);
  assert.match(esx, /setJob[\s\S]{0,600}adapter:setGroup/u);
  assert.match(esx, /setJob[\s\S]{0,300}job\.set_with_duty/u);
  assert.match(esx, /exports\(['"]GetPlayerFromIdentifier['"]/u);
  assert.match(esx, /exports\(['"]GetExtendedPlayers['"]/u);
  assert.doesNotMatch(
    esx,
    /exports\(['"]AddGroupCommand/u,
  );
  assert.doesNotMatch(esx, /player\.(?:getInventory|addInventoryItem|removeInventoryItem)\s*=/u);
});
