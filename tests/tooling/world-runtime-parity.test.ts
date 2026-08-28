import assert from "node:assert/strict";
import test from "node:test";

import { loadSchemaRegistry } from "../../tools/cli/src/schemas.ts";
import { runWorldLua } from "../world/helpers.ts";
import { worldBundleFixture } from "./world-fixtures.ts";

function luaLiteral(value: unknown): string {
  if (value === null || value === undefined) return "nil";
  if (typeof value === "boolean" || typeof value === "number") return String(value);
  if (typeof value === "string") return JSON.stringify(value);
  if (Array.isArray(value)) return `{${value.map(luaLiteral).join(",")}}`;
  if (typeof value === "object") {
    return `{${Object.entries(value as Record<string, unknown>)
      .sort(([left], [right]) => left.localeCompare(right, "en"))
      .map(([key, entry]) => `[${JSON.stringify(key)}]=${luaLiteral(entry)}`)
      .join(",")}}`;
  }
  throw new TypeError("Unsupported fixture value.");
}

test("canonical world bundle is accepted by both JSON Schema and the Lua runtime compiler", async () => {
  const fixture = worldBundleFixture();
  const schemas = await loadSchemaRegistry(process.cwd());
  assert.equal(schemas.worldBundle(fixture), true, JSON.stringify(schemas.worldBundle.errors));
  const result = await runWorldLua<string>(`
    local compiled, compileError = SynexWorldCompiler.compileBundle(
      ${luaLiteral(fixture)}, 'synex_fixture', 1)
    assert(compiled, compileError and compileError.code)
    return compiled.key .. ':' .. tostring(#compiled.orderedKeys)
  `);
  assert.equal(result, "synex_fixture:base:14");
});

test("legacy geometry aliases are rejected by the canonical schema", async () => {
  const fixture = worldBundleFixture();
  const first = (fixture.objects as Array<Record<string, unknown>>)[0];
  assert.ok(first);
  first.geometry = {
    kind: "axis_aligned_box",
    minimum: { x: -1, y: -1, z: -1 },
    maximum: { x: 1, y: 1, z: 1 },
  };
  const schemas = await loadSchemaRegistry(process.cwd());
  assert.equal(schemas.worldBundle(fixture), false);
});

test("runtime compiler matches conditional instance cleanup TTL semantics", async () => {
  const fixture = worldBundleFixture();
  const template = (fixture.objects as Array<Record<string, unknown>>)
    .find((object) => object.kind === "instance_template");
  assert.ok(template);

  delete template.ttlSeconds;
  const emptyMissing = structuredClone(fixture);
  template.cleanupPolicy = "owner_stop";
  const ownerWithoutTtl = structuredClone(fixture);
  template.ttlSeconds = 30;
  const ownerWithTtl = structuredClone(fixture);

  const result = await runWorldLua<string>(`
    local missing, missingError = SynexWorldCompiler.compileBundle(
      ${luaLiteral(emptyMissing)}, 'synex_fixture', 1)
    local owner = assert(SynexWorldCompiler.compileBundle(
      ${luaLiteral(ownerWithoutTtl)}, 'synex_fixture', 1))
    local extra, extraError = SynexWorldCompiler.compileBundle(
      ${luaLiteral(ownerWithTtl)}, 'synex_fixture', 1)
    assert(missing == nil and missingError.code == 'WORLD_BUNDLE_INVALID')
    assert(owner.objects['synex_fixture:training_instance'].ttlSeconds == nil)
    assert(extra == nil and extraError.code == 'WORLD_BUNDLE_INVALID')
    return missingError.code .. ':' .. owner.objects['synex_fixture:training_instance'].cleanupPolicy
      .. ':' .. extraError.code
  `);
  assert.equal(result, "WORLD_BUNDLE_INVALID:owner_stop:WORLD_BUNDLE_INVALID");
});

test("schema and runtime compiler reject access, heading, package and numeric boundary drift", async () => {
  const schemas = await loadSchemaRegistry(process.cwd());
  const cases: Array<{ name: string; mutate: (fixture: Record<string, unknown>) => void }> = [
    { name: "empty-access-policy", mutate: (fixture) => {
      const door = (fixture.objects as Array<Record<string, unknown>>)
        .find((object) => object.kind === "door");
      assert.ok(door); door.accessPolicy = {};
    } },
    { name: "non-scalar-state-requirement", mutate: (fixture) => {
      const door = (fixture.objects as Array<Record<string, unknown>>)
        .find((object) => object.kind === "door");
      assert.ok(door); door.accessPolicy = { stateRequirements: [{
        key: "synex_fixture:alarm_state", operator: "equals", value: { hostile: true },
      }] };
    } },
    { name: "door-heading", mutate: (fixture) => {
      const door = (fixture.objects as Array<Record<string, unknown>>)
        .find((object) => object.kind === "door");
      assert.ok(door); door.heading = 360_001;
    } },
    { name: "door-leaf-heading", mutate: (fixture) => {
      const door = (fixture.objects as Array<Record<string, unknown>>)
        .find((object) => object.kind === "door");
      assert.ok(door); (door.leaves as Array<Record<string, unknown>>)[0]!.heading = -360_001;
    } },
    { name: "portal-heading", mutate: (fixture) => {
      const portal = (fixture.objects as Array<Record<string, unknown>>)
        .find((object) => object.kind === "portal" && object.portalType === "teleport");
      assert.ok(portal); (portal.destination as Record<string, unknown>).heading = 360_001;
    } },
    { name: "state-minimum", mutate: (fixture) => {
      const state = (fixture.objects as Array<Record<string, unknown>>)
        .find((object) => object.kind === "world_state_definition");
      assert.ok(state); state.minimum = 9_007_199_254_740_992;
    } },
    { name: "map-package-type", mutate: (fixture) => {
      const map = (fixture.objects as Array<Record<string, unknown>>)
        .find((object) => object.kind === "map_package");
      assert.ok(map); map.packageType = "unknown";
    } },
    { name: "map-package-version", mutate: (fixture) => {
      const map = (fixture.objects as Array<Record<string, unknown>>)
        .find((object) => object.kind === "map_package");
      assert.ok(map); map.version = "01.0.0";
    } },
    { name: "resource-double-dot", mutate: (fixture) => {
      const map = (fixture.objects as Array<Record<string, unknown>>)
        .find((object) => object.kind === "map_package");
      assert.ok(map); map.resourceName = "foo..bar";
    } },
  ];

  for (const candidate of cases) {
    const fixture = worldBundleFixture();
    candidate.mutate(fixture);
    assert.equal(schemas.worldBundle(fixture), false, `${candidate.name}: schema`);
    const runtimeAccepted = await runWorldLua<boolean>(`
      local compiled = SynexWorldCompiler.compileBundle(
        ${luaLiteral(fixture)}, 'synex_fixture', 1)
      return compiled ~= nil
    `);
    assert.equal(runtimeAccepted, false, `${candidate.name}: runtime`);
  }
});
