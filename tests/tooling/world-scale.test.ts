import assert from "node:assert/strict";
import test from "node:test";

import { runWorldCommand, type WorldCatalog, type WorldObjectRecord } from "../../tools/cli/src/world.ts";
import { loadSchemaRegistry } from "../../tools/cli/src/schemas.ts";
import { worldBundleFixture } from "./world-fixtures.ts";

function zone(index: number): WorldObjectRecord {
  return {
    key: `synex_fixture:zone_${index}`,
    kind: "zone",
    ownerResource: "synex_fixture",
    bundleKey: "synex_fixture:base",
    bundleFile: "resources/synex_fixture/world/fixture.world.json",
    definition: {
      kind: "zone",
      key: `synex_fixture:zone_${index}`,
      parent: "synex_fixture:root",
      geometry: {
        type: "aabb",
        min: { x: 0, y: 0, z: 0 },
        max: { x: 10, y: 10, z: 10 },
      },
    },
  };
}

test("world schema rejects non-finite geometry fuzz input", async () => {
  const schemas = await loadSchemaRegistry(process.cwd());
  const nonFinite = worldBundleFixture();
  const first = (nonFinite.objects as Array<Record<string, unknown>>)[0];
  assert.ok(first);
  first.geometry = {
    type: "sphere",
    center: { x: Number.NaN, y: 0, z: 0 },
    radius: 1,
  };
  assert.equal(schemas.worldBundle(nonFinite), false);
});

test("world graph, bundle, and overlap reports remain bounded at scale", () => {
  const root: WorldObjectRecord = {
    key: "synex_fixture:root",
    kind: "region",
    ownerResource: "synex_fixture",
    bundleKey: "synex_fixture:base",
    bundleFile: "resources/synex_fixture/world/fixture.world.json",
    definition: { kind: "region", key: "synex_fixture:root", geometry: {
      type: "sphere", center: { x: 0, y: 0, z: 0 }, radius: 100,
    } },
  };
  const objects = [root, ...Array.from({ length: 700 }, (_, index) => zone(index))];
  const catalog: WorldCatalog = {
    bundles: Array.from({ length: 300 }, (_, index) => ({
      key: `synex_fixture:bundle_${index}`,
      version: "1.0.0",
      ownerResource: "synex_fixture",
      file: `resources/synex_fixture/world/${index}.world.json`,
      dependencies: [],
      objects: index === 0 ? objects : [],
    })),
    objects: new Map(objects.map((object) => [object.key, object])),
    diagnostics: [],
    declaredBundleFiles: 300,
  };

  const bundles = runWorldCommand(catalog, "bundles", []).report;
  assert.equal((bundles.bundles as unknown[]).length, 256);
  assert.equal(bundles.truncated, true);

  const graph = runWorldCommand(catalog, "graph", [root.key]).report;
  assert.equal((graph.descendants as unknown[]).length, 256);
  assert.equal(graph.truncated, true);

  const overlaps = runWorldCommand(catalog, "overlaps", []).report;
  assert.equal((overlaps.findings as unknown[]).length, 256);
  assert.equal(overlaps.truncated, true);
  assert.equal(Number(overlaps.comparisons) <= 200_000, true);
});
