import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import test from "node:test";
import { validateRepository } from "../../tools/cli/src/cli.js";

const bridgeRoots = [
  join("libraries", "synex_bridge"),
  join("resources", "synex_bridge_qb"),
  join("resources", "synex_bridge_qbx"),
  join("resources", "synex_bridge_esx"),
];

const adapterRoots = bridgeRoots.slice(1);
const commonAdapterCapabilities = [
  "synex.capabilities.delegate",
  "synex.identity.read",
  "synex.accounts.read",
  "synex.accounts.transfer",
  "synex.accounts.mint",
  "synex.accounts.burn",
  "synex.groups.read",
  "synex.groups.compatibility.set_primary_grade",
  "synex.metrics.write",
  "synex.tracing.write",
];
const providerCapabilities: Record<string, string[]> = {
  synex_bridge_qb: ["synex.groups.duty", "synex.permissions.read"],
  synex_bridge_qbx: ["synex.groups.duty"],
  synex_bridge_esx: ["synex.permissions.read"],
};

test("compatibility resources have valid manifests and depend only on native Synex foundations", async () => {
  const sharedManifest = await readFile(join("libraries", "synex_bridge", "fxmanifest.lua"), "utf8");
  const operatorPolicy = JSON.parse(await readFile(
    join("core", "synex_core", "config", "capabilities.json"), "utf8",
  )) as { resources: Record<string, { allow: string[]; deny: string[] }> };
  assert.doesNotMatch(
    sharedManifest,
    /\bserver_only\s+['"]yes['"]/u,
    "the shared bridge must be downloadable because adapters load its native_client.lua on clients",
  );
  assert.match(sharedManifest, /['"]native_client\.lua['"]/u);

  for (const root of bridgeRoots) {
    const report = await validateRepository(process.cwd(), join(process.cwd(), root));
    assert.deepEqual(report.diagnostics.filter((diagnostic) => diagnostic.level === "error"), []);
  }
  for (const root of adapterRoots) {
    const manifest = await readFile(join(root, "fxmanifest.lua"), "utf8");
    assert.ok(
      manifest.indexOf("'@synex_bridge/kernel/foundation.lua'")
        < manifest.indexOf("'@synex_bridge/native_server.lua'"),
    );
    assert.match(manifest, /@synex_bridge\/native_server\.lua/u);
    assert.match(manifest, /@synex_bridge\/native_client\.lua/u);
    assert.match(manifest, /dependency 'synex_accounts'/u);
    assert.match(manifest, /dependency 'synex_groups'/u);
    assert.doesNotMatch(manifest, /dependency '(?:qb-core|qbx_core|es_extended)'/u);

    const resource = JSON.parse(await readFile(join(root, "synex.resource.json"), "utf8")) as {
      name: string;
      capabilities: { request: string[] };
      contracts: { consume: string[] };
      events: { subscribe: string[] };
    };
    const expectedCapabilities = [
      ...commonAdapterCapabilities,
      ...(providerCapabilities[resource.name] ?? []),
    ].sort();
    assert.deepEqual([...resource.capabilities.request].sort(), expectedCapabilities);
    assert.ok(resource.contracts.consume.includes("synex.accounts.transfer_v2"));
    assert.ok(resource.contracts.consume.includes("synex.accounts.mint_v2"));
    assert.ok(resource.contracts.consume.includes("synex.accounts.burn_v2"));
    const resourcePolicy = operatorPolicy.resources[resource.name];
    assert.ok(resourcePolicy, `missing operator capability policy for ${resource.name}`);
    assert.deepEqual([...resourcePolicy.allow].sort(), expectedCapabilities);
    assert.equal(resourcePolicy.deny.includes("synex.accounts.mint"), false);
    assert.equal(resourcePolicy.deny.includes("synex.accounts.burn"), false);
    assert.deepEqual(resource.events.subscribe, ["synex.accounts.*", "synex.groups.*"]);
  }
  const coordinator = JSON.parse(await readFile(
    join("libraries", "synex_bridge", "synex.resource.json"), "utf8",
  )) as { capabilities: { request: string[] } };
  assert.ok(coordinator.capabilities.request.includes("synex.tracing.write"));
  const tracingProviders = new Set([
    "synex_bridge", "synex_bridge_qb", "synex_bridge_qbx", "synex_bridge_esx",
  ]);
  for (const [resource, resourcePolicy] of Object.entries(operatorPolicy.resources)) {
    assert.equal(
      resourcePolicy.allow.includes("synex.tracing.write"),
      tracingProviders.has(resource),
      `unexpected compatibility trace writer policy for ${resource}`,
    );
  }
});

test("native bridge network endpoint is bounded, rate-limited, session-bound, and delegated", async () => {
  const server = await readFile(join("libraries", "synex_bridge", "native_server.lua"), "utf8");
  assert.equal(server.match(/RegisterNetEvent\(/gu)?.length, 1, "one reviewed client-to-server endpoint is exposed");
  assert.match(server, /AuthorizeCompatibilityConsumer/u);
  assert.match(server, /resolved\.Tracing/u);
  assert.match(server, /compat\.%s\.%s/u);
  assert.match(server, /capabilities\.checkResource/u);
  assert.match(server, /callbackPendingPerSource/u);
  assert.match(server, /callbackBytes/u);
  assert.match(server, /takeCallbackToken/u);
  assert.match(server, /session\.sourceGeneration == generation/u);
  assert.match(server, /GetPlayerName/u);
  assert.match(server, /onResourceStop/u);
  assert.match(server, /playerDropped/u);
  assert.match(server, /assert\(isCallable\(toLegacyPlayerData\)/u);
  assert.doesNotMatch(server, /MySQL\.|oxmysql|SELECT\s|INSERT\s|UPDATE\s|DELETE\s/iu);
});

test("client bridge responses and lifecycle projections accept only server-origin events", async () => {
  const sharedClient = await readFile(join("libraries", "synex_bridge", "native_client.lua"), "utf8");
  assert.match(sharedClient, /source ~= 65535/u);
  for (const root of adapterRoots) {
    const client = await readFile(join(root, "client.lua"), "utf8");
    assert.match(client, /source ~= 65535/u);
  }
});

test("framework facades bind the immediate consumer and never use direct SQL or mutable Synex objects", async () => {
  for (const root of adapterRoots) {
    const server = await readFile(join(root, "server.lua"), "utf8");
    assert.match(server, /GetInvokingResource\(\)/u);
    assert.match(server, /adapter:(?:readPlayer|authorize|changeMoney|setMoney|registerCallback)/u);
    assert.doesNotMatch(server, /MySQL\.|oxmysql|SELECT\s|INSERT\s|UPDATE\s|DELETE\s/iu);
    assert.doesNotMatch(server, /LoadResourceFile|GetAPIFor|targetResource/u);
  }
});

test("legacy money mutations use reviewed v2 account mappings and policy-selected ledger operations", async () => {
  const server = await readFile(join("libraries", "synex_bridge", "native_server.lua"), "utf8");
  assert.match(server, /synex\.accounts\.transfer_v2/u);
  assert.match(server, /synex\.accounts\.mint_v2/u);
  assert.match(server, /synex\.accounts\.burn_v2/u);
  assert.match(server, /['"]2\.0\.0['"]/u);
  assert.match(server, /['"]list_by_owner['"]/u);
  assert.match(server, /['"]compatibility_snapshot['"]/u);
  assert.match(server, /ProjectCompatibilityGroups/u);
  assert.match(server, /ResolveMoneyPolicy/u);
  assert.match(server, /moneyAliases/u);
  assert.match(server, /local scopedAccountKey = mapping\.accountKey/u);
  assert.match(server, /account\.account_key == mapping\.accountKey/u);
  assert.doesNotMatch(server, /options\.moneyMappings/u);
  assert.match(server, /actor_kind = 'character', actor_ref = character\.id/u);
  assert.match(server, /limit = 50/u);
  assert.match(server, /MONEY_COUNTERPARTY_NOT_CONFIGURED/u);
  assert.match(server, /ACCOUNT_PROJECTION_TRUNCATED/u);
  assert.match(server, /accounts\.next_cursor ~= nil/u);
  assert.match(server, /COMPAT_PROJECTION_UNAVAILABLE/u);
  assert.match(server, /mutationRequest\.source_account_id/u);
  assert.match(server, /mutationRequest\.destination_account_id/u);
  assert.match(server, /mutationRequest\.account_id = playerAccount/u);
  assert.match(server, /traceId = authorization\.traceId/u);
  assert.match(server, /idempotencyKey = operationId/u);
  assert.match(server, /mutationError\.retryable == true/u);
  assert.match(server, /resolved\.RPC\.call\([\s\S]*rpcName, '2\.0\.0', mutationRequest, rpcOptions\)/u);
  assert.match(server, /PROJECTION_INVALIDATION_TOPICS/u);
  assert.match(server, /events\.subscribe\(subscribedTopic/u);
  assert.doesNotMatch(server, /list_owner_accounts|list_subject_memberships/u);
});
