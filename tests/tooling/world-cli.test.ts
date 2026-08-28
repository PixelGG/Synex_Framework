import assert from "node:assert/strict";
import { copyFile, mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { runCli } from "../../tools/cli/src/cli.ts";
import { worldBundleFixture } from "./world-fixtures.ts";

async function prepareWorldRepository(): Promise<string> {
  const root = await mkdtemp(join(tmpdir(), "synex-world-cli-"));
  await mkdir(join(root, "schemas"), { recursive: true });
  await Promise.all([
    "contract.schema.json",
    "resource.schema.json",
    "state.schema.json",
    "config.schema.json",
    "capability-policy.schema.json",
    "world-bundle.schema.json",
  ].map((name) => copyFile(join(process.cwd(), "schemas", name), join(root, "schemas", name))));
  await writeFile(join(root, "package.json"), `${JSON.stringify({
    name: "synex-world-test",
    version: "0.1.0",
    type: "module",
    synex: { apiVersion: "1.0.0" },
  })}\n`, "utf8");
  const resource = join(root, "resources", "synex_fixture");
  await mkdir(join(resource, "world"), { recursive: true });
  const bundle = worldBundleFixture();
  (bundle.objects as Array<Record<string, unknown>>).push({
    kind: "zone",
    key: "synex_fixture:counter_zone_overlap",
    parent: "synex_fixture:lobby",
    geometry: {
      type: "aabb",
      min: { x: -3, y: -3, z: 5 },
      max: { x: 3, y: 3, z: 15 },
    },
  });
  await writeFile(join(resource, "world", "fixture.world.json"), `${JSON.stringify(bundle)}\n`, "utf8");
  await writeFile(join(resource, "synex.resource.json"), `${JSON.stringify({
    schema: 1,
    name: "synex_fixture",
    version: "0.1.0",
    synex: "^1.0.0",
    critical: false,
    capabilities: { request: [] },
    services: { provide: [], require: [], optional: [] },
    contracts: { provide: [], consume: [] },
    events: { publish: [], subscribe: [] },
    hooks: { register: [], run: [] },
    dependencies: { required: [], optional: [], development: [] },
    migrations: [],
    dataOwnership: { tables: [], characterDelete: "none" },
    stateSnapshot: { supported: false, schemaVersion: 1 },
    worldBundles: ["world/fixture.world.json"],
  })}\n`, "utf8");
  return root;
}

async function execute(root: string, argumentsList: string[]): Promise<{ code: number; report: Record<string, unknown> }> {
  const output: string[] = [];
  const errors: string[] = [];
  const code = await runCli([...argumentsList, "--json", "--root", root], {
    log: (message) => output.push(message),
    error: (message) => errors.push(message),
  });
  assert.deepEqual(errors, []);
  return { code, report: JSON.parse(output.join("\n")) as Record<string, unknown> };
}

test("world CLI validates, inspects, locates, graphs, lists bundles, and reports bounded overlaps", async (context) => {
  const root = await prepareWorldRepository();
  context.after(async () => rm(root, { recursive: true, force: true }));

  const validation = await execute(root, ["world", "validate"]);
  assert.equal(validation.code, 0);
  assert.equal(validation.report.status, "PASS");
  assert.equal(validation.report.bundles, 1);

  const bundles = await execute(root, ["world", "bundles"]);
  assert.equal((bundles.report.bundles as unknown[]).length, 1);

  const inspection = await execute(root, ["world", "inspect", "synex_fixture:station"]);
  assert.equal((inspection.report.object as Record<string, unknown>).ownerResource, "synex_fixture");

  const location = await execute(root, ["world", "locate", "0", "0", "10"]);
  assert.equal((location.report.containing as Array<Record<string, unknown>>)
    .some((entry) => entry.key === "synex_fixture:station"), true);

  const graph = await execute(root, ["world", "graph", "synex_fixture:station"]);
  assert.equal((graph.report.ancestors as string[]).includes("synex_fixture:city"), true);

  const overlaps = await execute(root, ["world", "overlaps"]);
  assert.equal((overlaps.report.findings as unknown[]).length > 0, true);
  assert.match(String(overlaps.report.disclaimer), /broad-phase/u);
});

test("doctor world alias reports runtime truth as UNKNOWN without failing valid static data", async (context) => {
  const root = await prepareWorldRepository();
  context.after(async () => rm(root, { recursive: true, force: true }));
  const result = await execute(root, ["doctor", "world"]);
  assert.equal(result.code, 0);
  assert.equal(result.report.status, "UNKNOWN");
  assert.equal((result.report.runtime as Record<string, unknown>).status, "UNKNOWN");
  assert.match(String((result.report.runtime as Record<string, unknown>).detail), /Offline tooling/u);
});
