import assert from "node:assert/strict";
import { mkdir, mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { loadWorldBundleCatalog } from "../../tools/cli/src/world.ts";
import { loadSchemaRegistry } from "../../tools/cli/src/schemas.ts";
import { worldBundleFixture } from "./world-fixtures.ts";

test("world bundle schema accepts every canonical definition kind and rejects asserted ownership", async () => {
  const schemas = await loadSchemaRegistry(process.cwd());
  const fixture = worldBundleFixture();
  assert.equal(schemas.worldBundle(fixture), true, JSON.stringify(schemas.worldBundle.errors));

  const spoofed = structuredClone(fixture) as Record<string, unknown>;
  spoofed.ownerResource = "synex_other";
  assert.equal(schemas.worldBundle(spoofed), false);

  const objects = fixture.objects as Array<Record<string, unknown>>;
  assert.deepEqual(
    new Set(objects.map((object) => object.kind)),
    new Set(["region", "location", "interior", "room", "zone", "anchor", "door", "portal",
      "instance_template", "map_package", "ipl_bundle", "world_state_definition"]),
  );
});

test("instance template schema requires TTL only for empty cleanup", async () => {
  const schemas = await loadSchemaRegistry(process.cwd());
  const fixture = worldBundleFixture();
  const template = (fixture.objects as Array<Record<string, unknown>>)
    .find((object) => object.kind === "instance_template");
  assert.ok(template);

  delete template.ttlSeconds;
  assert.equal(schemas.worldBundle(fixture), false);

  template.cleanupPolicy = "owner_stop";
  assert.equal(schemas.worldBundle(fixture), true, JSON.stringify(schemas.worldBundle.errors));
  template.ttlSeconds = 30;
  assert.equal(schemas.worldBundle(fixture), false);

  delete template.ttlSeconds;
  template.cleanupPolicy = "manual";
  assert.equal(schemas.worldBundle(fixture), true, JSON.stringify(schemas.worldBundle.errors));
});

test("world bundle schema rejects DEL in every projected free-string boundary", async () => {
  const schemas = await loadSchemaRegistry(process.cwd());
  const invalid = (mutate: (objects: Array<Record<string, unknown>>,
    fixture: Record<string, unknown>) => void): void => {
    const fixture = worldBundleFixture();
    mutate(fixture.objects as Array<Record<string, unknown>>, fixture);
    assert.equal(schemas.worldBundle(fixture), false,
      `unexpected schema pass: ${JSON.stringify(fixture)}`);
  };
  invalid((objects) => { objects[0]!.label = "bad\u007f"; });
  invalid((objects) => {
    const room = objects.find((object) => object.kind === "room");
    assert.ok(room); room.gameRoomKey = "bad\u007f";
  });
  invalid((objects) => {
    const ipls = objects.find((object) => object.kind === "ipl_bundle");
    assert.ok(ipls); ipls.ipls = ["bad\u007f"];
  });
  invalid((objects) => {
    const ipls = objects.find((object) => object.kind === "ipl_bundle");
    assert.ok(ipls); ipls.interiorSets = [{ interiorId: 1, name: "bad\u007f" }];
  });
  invalid((objects) => {
    const state = objects.find((object) => object.kind === "world_state_definition");
    assert.ok(state); state.stateType = "string"; state.maxLength = 32;
    state.default = "bad\u007f";
  });
  invalid((objects) => {
    const state = objects.find((object) => object.kind === "world_state_definition");
    assert.ok(state); state.stateType = "enum"; state.allowed = ["bad\u007f"];
  });
  invalid((objects) => {
    const door = objects.find((object) => object.kind === "door");
    assert.ok(door); door.accessPolicy = { stateRequirements: [{
      key: "synex_fixture:alarm_state", operator: "equals", value: "bad\u007f",
    }] };
  });
});

test("world bundle schema source contains no duplicate location property", async () => {
  const source = await readFile("schemas/world-bundle.schema.json", "utf8");
  const start = source.indexOf('    "location": {');
  const end = source.indexOf('    "interior": {', start);
  assert.ok(start >= 0 && end > start);
  const location = source.slice(start, end);
  assert.equal((location.match(/^\s*"geometry":/gmu) ?? []).length, 1);
});

test("structured state schema and defaults use the same closed bounded subset offline", async (context) => {
  const root = await mkdtemp(join(tmpdir(), "synex-world-structured-"));
  context.after(async () => rm(root, { recursive: true, force: true }));
  const resource = join(root, "resources", "synex_fixture");
  await mkdir(join(resource, "world"), { recursive: true });
  const fixture = worldBundleFixture();
  const state = (fixture.objects as Array<Record<string, unknown>>)
    .find((object) => object.kind === "world_state_definition");
  assert.ok(state);
  state.stateType = "structured";
  state.structuredSchema = {
    type: "object", maximumBytes: 256, maximumDepth: 3, maximumEntries: 8,
    properties: {
      enabled: { type: "boolean" },
      count: { type: "integer", minimum: 0, maximum: 10 },
      flags: { type: "array", maximumItems: 2, items: { type: "boolean" } },
    },
    required: ["enabled", "count"], additionalProperties: false,
  };
  state.default = { enabled: true, count: 2, flags: [true] };
  const file = join(resource, "world", "fixture.world.json");
  await writeFile(file, `${JSON.stringify(fixture)}\n`, "utf8");
  const schemas = await loadSchemaRegistry(process.cwd());
  assert.equal(schemas.worldBundle(fixture), true, JSON.stringify(schemas.worldBundle.errors));
  const manifest = [{
    file: join(resource, "synex.resource.json"), directory: resource,
    manifest: { name: "synex_fixture", worldBundles: ["world/fixture.world.json"] },
  }];
  const valid = await loadWorldBundleCatalog(root, manifest, schemas);
  assert.equal(valid.diagnostics.some((entry) => entry.rule.startsWith("world-state-")), false,
    JSON.stringify(valid.diagnostics));

  (state.default as Record<string, unknown>).undeclared = true;
  await writeFile(file, `${JSON.stringify(fixture)}\n`, "utf8");
  const invalidDefault = await loadWorldBundleCatalog(root, manifest, schemas);
  assert.equal(invalidDefault.diagnostics.some((entry) => entry.rule === "world-state-default-type"), true);

  delete (state.default as Record<string, unknown>).undeclared;
  (state.structuredSchema as Record<string, unknown>).required = ["missing"];
  await writeFile(file, `${JSON.stringify(fixture)}\n`, "utf8");
  const invalidSchema = await loadWorldBundleCatalog(root, manifest, schemas);
  assert.equal(invalidSchema.diagnostics.some(
    (entry) => entry.rule === "world-state-structured-schema"), true);
});

test("world catalog enforces ownership, global references, parent cycles, portal targets, and geometry", async (context) => {
  const root = await mkdtemp(join(tmpdir(), "synex-world-schema-"));
  context.after(async () => rm(root, { recursive: true, force: true }));
  const resource = join(root, "resources", "synex_fixture");
  await mkdir(join(resource, "world"), { recursive: true });
  const fixture = worldBundleFixture();
  const objects = fixture.objects as Array<Record<string, unknown>>;
  const city = objects.find((object) => object.key === "synex_fixture:city");
  const station = objects.find((object) => object.key === "synex_fixture:station");
  const zone = objects.find((object) => object.key === "synex_fixture:counter_zone");
  const portal = objects.find((object) => object.key === "synex_fixture:exit");
  assert.ok(city && station && zone && portal);
  city.parent = "synex_fixture:station";
  station.parent = "synex_fixture:city";
  zone.geometry = {
    type: "polygon",
    vertices: [{ x: 0, y: 0 }, { x: 4, y: 4 }, { x: 0, y: 4 }, { x: 4, y: 0 }],
    minZ: 5,
    maxZ: 15,
  };
  portal.destination = { target: "synex_fixture:missing" };
  objects.push({
    kind: "anchor",
    key: "synex_fixture:counter",
    parent: "synex_fixture:station",
    position: { x: 1, y: 1, z: 1 },
  });
  await writeFile(join(resource, "world", "fixture.world.json"), `${JSON.stringify(fixture)}\n`, "utf8");

  const schemas = await loadSchemaRegistry(process.cwd());
  const catalog = await loadWorldBundleCatalog(root, [{
    file: join(resource, "synex.resource.json"),
    directory: resource,
    manifest: { name: "synex_fixture", worldBundles: ["world/fixture.world.json"] },
  }], schemas);
  const rules = new Set(catalog.diagnostics.map((entry) => entry.rule));
  assert.equal(rules.has("world-object-key-unique"), true);
  assert.equal(rules.has("world-reference-missing"), true);
  assert.equal(rules.has("world-parent-cycle"), true);
  assert.equal(rules.has("world-geometry"), true);
});

test("offline World validation rejects normalized DoorSystem hash collisions", async (context) => {
  const root = await mkdtemp(join(tmpdir(), "synex-world-door-hash-"));
  context.after(async () => rm(root, { recursive: true, force: true }));
  const resource = join(root, "resources", "synex_fixture");
  await mkdir(join(resource, "world"), { recursive: true });
  const fixture = worldBundleFixture();
  const objects = fixture.objects as Array<Record<string, unknown>>;
  const first = objects.find((object) => object.kind === "door");
  assert.ok(first);
  (first.leaves as Array<Record<string, unknown>>)[0]!.doorHash = 4_294_967_295;
  objects.push({
    kind: "door", key: "synex_fixture:second_door", parent: "synex_fixture:lobby",
    position: { x: 1, y: -8, z: 10 },
    leaves: [{ id: "main", model: 5678, doorHash: 4_294_967_295,
      position: { x: 1, y: -8, z: 10 }, heading: 0 }],
    defaultState: "LOCKED", persistent: false,
  });
  const file = join(resource, "world", "fixture.world.json");
  await writeFile(file, `${JSON.stringify(fixture)}\n`, "utf8");
  const schemas = await loadSchemaRegistry(process.cwd());
  assert.equal(schemas.worldBundle(fixture), true, JSON.stringify(schemas.worldBundle.errors));
  const catalog = await loadWorldBundleCatalog(root, [{
    file: join(resource, "synex.resource.json"), directory: resource,
    manifest: { name: "synex_fixture", worldBundles: ["world/fixture.world.json"] },
  }], schemas);
  assert.equal(catalog.diagnostics.some(
    (entry) => entry.rule === "world-door-hash-collision"), true,
  JSON.stringify(catalog.diagnostics));
});

test("world bundle loading refuses intermediate symlink escapes", async (context) => {
  const root = await mkdtemp(join(tmpdir(), "synex-world-link-"));
  const outside = await mkdtemp(join(tmpdir(), "synex-world-outside-"));
  context.after(async () => {
    await rm(root, { recursive: true, force: true });
    await rm(outside, { recursive: true, force: true });
  });
  const resource = join(root, "resources", "synex_fixture");
  await mkdir(resource, { recursive: true });
  await writeFile(join(outside, "escaped.world.json"), `${JSON.stringify(worldBundleFixture())}\n`, "utf8");
  await symlink(outside, join(resource, "world"), "junction");
  const schemas = await loadSchemaRegistry(process.cwd());
  const catalog = await loadWorldBundleCatalog(root, [{
    file: join(resource, "synex.resource.json"),
    directory: resource,
    manifest: { name: "synex_fixture", worldBundles: ["world/escaped.world.json"] },
  }], schemas);
  assert.equal(catalog.bundles.length, 0);
  assert.equal(catalog.diagnostics.some((entry) => entry.rule === "world-bundle-path"), true);
});
