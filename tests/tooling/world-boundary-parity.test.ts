import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { loadSchemaRegistry } from "../../tools/cli/src/schemas.ts";
import { loadWorldBundleCatalog, type WorldManifestSource } from "../../tools/cli/src/world.ts";
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

function nestedComposite(levels: number): Record<string, unknown> {
  let geometry: Record<string, unknown> = {
    type: "point",
    position: { x: 0, y: 0, z: 0 },
  };
  for (let depth = 0; depth < levels; depth += 1) {
    geometry = { type: "composite", operation: "union", geometries: [geometry] };
  }
  return geometry;
}

test("offline World geometry boundaries match the Lua compiler", async (context) => {
  const root = await mkdtemp(join(tmpdir(), "synex-world-boundary-"));
  context.after(async () => rm(root, { recursive: true, force: true }));
  const resource = join(root, "resources", "synex_fixture");
  const bundleFile = join(resource, "world", "fixture.world.json");
  await mkdir(join(resource, "world"), { recursive: true });
  const manifest: WorldManifestSource = {
    file: join(resource, "synex.resource.json"),
    directory: resource,
    manifest: { name: "synex_fixture", worldBundles: ["world/fixture.world.json"] },
  };
  const schemas = await loadSchemaRegistry(process.cwd());
  const cases: Array<{ name: string; geometry: Record<string, unknown>; accepted: boolean }> = [
    { name: "depth-four", geometry: nestedComposite(4), accepted: true },
    { name: "depth-five", geometry: nestedComposite(5), accepted: false },
    { name: "aabb-minimum", geometry: { type: "aabb", min: { x: 0, y: 0, z: 0 },
      max: { x: 0.001, y: 1, z: 1 } }, accepted: true },
    { name: "aabb-below-minimum", geometry: { type: "aabb", min: { x: 0, y: 0, z: 0 },
      max: { x: 0.0001, y: 1, z: 1 } }, accepted: false },
    { name: "polygon-z-minimum", geometry: { type: "polygon",
      vertices: [{ x: 0, y: 0 }, { x: 2, y: 0 }, { x: 0, y: 2 }],
      minZ: 0, maxZ: 0.001 }, accepted: true },
    { name: "polygon-z-below-minimum", geometry: { type: "polygon",
      vertices: [{ x: 0, y: 0 }, { x: 2, y: 0 }, { x: 0, y: 2 }],
      minZ: 0, maxZ: 0.0001 }, accepted: false },
    { name: "polygon-area-minimum", geometry: { type: "polygon",
      vertices: [{ x: 0, y: 0 }, { x: 0.001, y: 0 }, { x: 0, y: 1 }],
      minZ: 0, maxZ: 1 }, accepted: true },
    { name: "polygon-area-below-minimum", geometry: { type: "polygon",
      vertices: [{ x: 0, y: 0 }, { x: 0.0001, y: 0 }, { x: 0, y: 1 }],
      minZ: 0, maxZ: 1 }, accepted: false },
  ];

  for (const candidate of cases) {
    const fixture = worldBundleFixture();
    const first = (fixture.objects as Array<Record<string, unknown>>)[0];
    assert.ok(first);
    first.geometry = candidate.geometry;
    await writeFile(bundleFile, `${JSON.stringify(fixture)}\n`, "utf8");
    const catalog = await loadWorldBundleCatalog(root, [manifest], schemas);
    const offlineAccepted = !catalog.diagnostics.some((finding) => finding.rule === "world-geometry");
    const runtimeAccepted = await runWorldLua<boolean>(`
      local compiled = SynexWorldCompiler.compileBundle(
        ${luaLiteral(fixture)}, 'synex_fixture', 1)
      return compiled ~= nil
    `);
    assert.equal(offlineAccepted, candidate.accepted, `${candidate.name}: offline`);
    assert.equal(runtimeAccepted, candidate.accepted, `${candidate.name}: runtime`);
  }
});

test("offline catalog rejects the 1025th declared World bundle", async () => {
  const schemas = await loadSchemaRegistry(process.cwd());
  const root = join(tmpdir(), "synex-world-bundle-boundary");
  const source: WorldManifestSource = {
    file: join(root, "resources", "synex_fixture", "synex.resource.json"),
    directory: join(root, "resources", "synex_fixture"),
    manifest: {
      name: "synex_fixture",
      worldBundles: Array.from({ length: 1_025 }, (_, index) =>
        `world/missing-${index.toString().padStart(4, "0")}.world.json`),
    },
  };
  const catalog = await loadWorldBundleCatalog(root, [source], schemas);
  const finding = catalog.diagnostics.find((entry) => entry.rule === "world-bundle-limit");
  assert.ok(finding);
  assert.match(finding.message, /1024 bundle safety limit/u);
  assert.equal(catalog.declaredBundleFiles, 1_025);
});

test("offline byte limits match Lua for Unicode labels and state defaults", async (context) => {
  const root = await mkdtemp(join(tmpdir(), "synex-world-byte-parity-"));
  context.after(async () => rm(root, { recursive: true, force: true }));
  const resource = join(root, "resources", "synex_fixture");
  const bundleFile = join(resource, "world", "fixture.world.json");
  await mkdir(join(resource, "world"), { recursive: true });
  const manifest: WorldManifestSource = {
    file: join(resource, "synex.resource.json"), directory: resource,
    manifest: { name: "synex_fixture", worldBundles: ["world/fixture.world.json"] },
  };
  const schemas = await loadSchemaRegistry(process.cwd());
  const cases: Array<{ name: string; rule: string; mutate: (fixture: Record<string, unknown>) => void }> = [
    { name: "label-bytes", rule: "world-string-byte-bound", mutate: (fixture) => {
      (fixture.objects as Array<Record<string, unknown>>)[0]!.label = "😀".repeat(96);
    } },
    { name: "state-default-bytes", rule: "world-state-default-value", mutate: (fixture) => {
      const state = (fixture.objects as Array<Record<string, unknown>>)
        .find((object) => object.kind === "world_state_definition");
      assert.ok(state);
      state.stateType = "string"; state.maxLength = 1; state.default = "😀";
    } },
  ];
  for (const candidate of cases) {
    const fixture = worldBundleFixture();
    candidate.mutate(fixture);
    assert.equal(schemas.worldBundle(fixture), true,
      `${candidate.name}: schema unexpectedly rejected codepoint-valid input`);
    await writeFile(bundleFile, `${JSON.stringify(fixture)}\n`, "utf8");
    const catalog = await loadWorldBundleCatalog(root, [manifest], schemas);
    assert.equal(catalog.diagnostics.some((finding) => finding.rule === candidate.rule), true,
      `${candidate.name}: ${JSON.stringify(catalog.diagnostics)}`);
    const runtimeAccepted = await runWorldLua<boolean>(`
      local compiled = SynexWorldCompiler.compileBundle(
        ${luaLiteral(fixture)}, 'synex_fixture', 1)
      return compiled ~= nil
    `);
    assert.equal(runtimeAccepted, false, `${candidate.name}: runtime`);
  }
});

test("offline access-state and definition-scope rules match Lua validateCombined", async (context) => {
  const root = await mkdtemp(join(tmpdir(), "synex-world-access-parity-"));
  context.after(async () => rm(root, { recursive: true, force: true }));
  const resource = join(root, "resources", "synex_fixture");
  const bundleFile = join(resource, "world", "fixture.world.json");
  await mkdir(join(resource, "world"), { recursive: true });
  const schemas = await loadSchemaRegistry(process.cwd());
  const manifest: WorldManifestSource = {
    file: join(resource, "synex.resource.json"),
    directory: resource,
    manifest: { name: "synex_fixture", worldBundles: ["world/fixture.world.json"] },
  };
  type MutableFixture = Record<string, unknown> & { objects: Array<Record<string, unknown>> };
  const alarm = (fixture: MutableFixture): Record<string, unknown> => {
    const value = fixture.objects.find((object) => object.key === "synex_fixture:alarm_state");
    assert.ok(value);
    return value;
  };
  const door = (fixture: MutableFixture): Record<string, unknown> => {
    const value = fixture.objects.find((object) => object.key === "synex_fixture:lobby_door");
    assert.ok(value);
    return value;
  };
  const requireState = (
    fixture: MutableFixture,
    key: string,
    value: unknown,
    scopeRef?: string,
  ): void => {
    const policy = door(fixture).accessPolicy as Record<string, unknown>;
    policy.stateRequirements = [{ key, operator: "equals", value,
      ...(scopeRef === undefined ? {} : { scopeRef }) }];
  };
  const addSiblingRoom = (fixture: MutableFixture): void => {
    fixture.objects.push({
      kind: "room",
      key: "synex_fixture:backroom",
      parent: "synex_fixture:station_interior",
      geometry: { type: "aabb", min: { x: 20, y: 20, z: 5 },
        max: { x: 30, y: 30, z: 15 } },
    });
  };
  const cases: Array<{
    name: string;
    rule: string | null;
    runtime: "PASS" | "WORLD_REFERENCE_INVALID" | "WORLD_STATE_SCHEMA_INVALID";
    mutate: (fixture: MutableFixture) => void;
  }> = [
    {
      name: "valid-room-boolean",
      rule: null,
      runtime: "PASS",
      mutate: (fixture) => requireState(fixture, "synex_fixture:alarm_state", false,
        "synex_fixture:lobby"),
    },
    {
      name: "boolean-value-type",
      rule: "world-access-state-value",
      runtime: "WORLD_STATE_SCHEMA_INVALID",
      mutate: (fixture) => requireState(fixture, "synex_fixture:alarm_state", "false",
        "synex_fixture:lobby"),
    },
    {
      name: "integer-bounds",
      rule: "world-access-state-value",
      runtime: "WORLD_STATE_SCHEMA_INVALID",
      mutate: (fixture) => {
        fixture.objects.push({ kind: "world_state_definition", key: "synex_fixture:temperature",
          parent: "synex_fixture:lobby", stateType: "integer", scope: "room",
          persistence: "runtime", schemaVersion: 1, minimum: 0, maximum: 10, default: 5 });
        requireState(fixture, "synex_fixture:temperature", 11, "synex_fixture:lobby");
      },
    },
    {
      name: "enum-membership",
      rule: "world-access-state-value",
      runtime: "WORLD_STATE_SCHEMA_INVALID",
      mutate: (fixture) => {
        fixture.objects.push({ kind: "world_state_definition", key: "synex_fixture:mode",
          parent: "synex_fixture:lobby", stateType: "enum", scope: "room",
          persistence: "runtime", schemaVersion: 1, allowed: ["safe"], default: "safe" });
        requireState(fixture, "synex_fixture:mode", "unsafe", "synex_fixture:lobby");
      },
    },
    {
      name: "structured-requirement",
      rule: "world-access-state-value",
      runtime: "WORLD_STATE_SCHEMA_INVALID",
      mutate: (fixture) => {
        fixture.objects.push({ kind: "world_state_definition", key: "synex_fixture:structured",
          parent: "synex_fixture:lobby", stateType: "structured", scope: "room",
          persistence: "runtime", schemaVersion: 1,
          structuredSchema: { type: "object", maximumBytes: 256, maximumDepth: 2,
            maximumEntries: 8, properties: { flag: { type: "boolean" } },
            required: ["flag"], additionalProperties: false }, default: { flag: true } });
        requireState(fixture, "synex_fixture:structured", false, "synex_fixture:lobby");
      },
    },
    {
      name: "global-explicit-scope",
      rule: "world-access-state-scope",
      runtime: "WORLD_REFERENCE_INVALID",
      mutate: (fixture) => {
        delete alarm(fixture).parent;
        alarm(fixture).scope = "global";
        requireState(fixture, "synex_fixture:alarm_state", false, "synex_fixture:lobby");
      },
    },
    {
      name: "instance-explicit-scope",
      rule: "world-access-state-scope",
      runtime: "WORLD_REFERENCE_INVALID",
      mutate: (fixture) => {
        alarm(fixture).scope = "instance";
        requireState(fixture, "synex_fixture:alarm_state", false, "synex_fixture:lobby");
      },
    },
    {
      name: "scope-kind",
      rule: "world-reference-kind",
      runtime: "WORLD_REFERENCE_INVALID",
      mutate: (fixture) => requireState(fixture, "synex_fixture:alarm_state", false,
        "synex_fixture:station"),
    },
    {
      name: "definition-outside-target-hierarchy",
      rule: "world-access-state-hierarchy",
      runtime: "WORLD_REFERENCE_INVALID",
      mutate: (fixture) => {
        addSiblingRoom(fixture);
        alarm(fixture).parent = "synex_fixture:backroom";
        requireState(fixture, "synex_fixture:alarm_state", false,
          "synex_fixture:backroom");
      },
    },
    {
      name: "scope-outside-definition-hierarchy",
      rule: "world-access-state-hierarchy",
      runtime: "WORLD_REFERENCE_INVALID",
      mutate: (fixture) => {
        addSiblingRoom(fixture);
        requireState(fixture, "synex_fixture:alarm_state", false,
          "synex_fixture:backroom");
      },
    },
    {
      name: "global-state-parent",
      rule: "world-state-parent-scope",
      runtime: "WORLD_REFERENCE_INVALID",
      mutate: (fixture) => { alarm(fixture).scope = "global"; },
    },
    {
      name: "state-parent-deeper-than-scope",
      rule: "world-state-parent-scope",
      runtime: "WORLD_REFERENCE_INVALID",
      mutate: (fixture) => { alarm(fixture).scope = "location"; },
    },
  ];

  for (const candidate of cases) {
    const fixture = worldBundleFixture() as MutableFixture;
    candidate.mutate(fixture);
    await writeFile(bundleFile, `${JSON.stringify(fixture)}\n`, "utf8");
    const catalog = await loadWorldBundleCatalog(root, [manifest], schemas);
    if (candidate.rule === null) {
      assert.equal(catalog.diagnostics.some((finding) => finding.level === "error"), false,
        `${candidate.name}: ${JSON.stringify(catalog.diagnostics)}`);
    } else {
      assert.equal(catalog.diagnostics.some((finding) => finding.rule === candidate.rule), true,
        `${candidate.name}: ${JSON.stringify(catalog.diagnostics)}`);
    }
    const runtime = await runWorldLua<string>(`
      local compiled, compileError = SynexWorldCompiler.compileBundle(
        ${luaLiteral(fixture)}, 'synex_fixture', 1)
      if not compiled then return 'COMPILE:' .. tostring(compileError and compileError.code) end
      local valid, combinedError = SynexWorldCompiler.validateCombined(
        compiled.objects, { [compiled.key] = compiled })
      return valid and 'PASS' or tostring(combinedError and combinedError.code)
    `);
    assert.equal(runtime, candidate.runtime, `${candidate.name}: runtime`);
  }
});
