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

test("compatibility resources have valid manifests and depend only on native Synex foundations", async () => {
  const sharedManifest = await readFile(join("libraries", "synex_bridge", "fxmanifest.lua"), "utf8");
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
    assert.match(manifest, /@synex_bridge\/native_server\.lua/u);
    assert.match(manifest, /@synex_bridge\/native_client\.lua/u);
    assert.match(manifest, /dependency 'synex_accounts'/u);
    assert.match(manifest, /dependency 'synex_groups'/u);
    assert.doesNotMatch(manifest, /dependency '(?:qb-core|qbx_core|es_extended)'/u);

    const resource = JSON.parse(await readFile(join(root, "synex.resource.json"), "utf8")) as {
      capabilities: { request: string[] };
      contracts: { consume: string[] };
    };
    assert.ok(resource.capabilities.request.includes("synex.capabilities.delegate"));
    assert.ok(resource.capabilities.request.includes("synex.accounts.transfer"));
    assert.ok(resource.contracts.consume.includes("synex.accounts.transfer"));
  }
});

test("native bridge network endpoint is bounded, rate-limited, session-bound, and delegated", async () => {
  const server = await readFile(join("libraries", "synex_bridge", "native_server.lua"), "utf8");
  assert.equal(server.match(/RegisterNetEvent\(/gu)?.length, 1, "one reviewed client-to-server endpoint is exposed");
  assert.match(server, /Capabilities\.checkResource/u);
  assert.match(server, /callbackPendingPerSource/u);
  assert.match(server, /callbackBytes/u);
  assert.match(server, /takeCallbackToken/u);
  assert.match(server, /session\.sourceGeneration == generation/u);
  assert.match(server, /GetPlayerName/u);
  assert.match(server, /onResourceStop/u);
  assert.match(server, /playerDropped/u);
  assert.match(server, /assert\(type\(toLegacyPlayerData\) == 'function'/u);
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

test("legacy money mutations translate to balanced Synex transfers with reviewed counterparties", async () => {
  const server = await readFile(join("libraries", "synex_bridge", "native_server.lua"), "utf8");
  assert.match(server, /synex\.accounts\.transfer/u);
  assert.match(server, /MONEY_COUNTERPARTY_NOT_CONFIGURED/u);
  assert.match(server, /ACCOUNT_PROJECTION_TRUNCATED/u);
  assert.match(server, /source_account_id = sourceAccount/u);
  assert.match(server, /destination_account_id = destinationAccount/u);
  assert.doesNotMatch(server, /synex\.accounts\.(?:mint|burn)/u);
});
