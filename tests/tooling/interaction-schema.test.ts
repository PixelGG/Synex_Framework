import assert from "node:assert/strict";
import { cp, mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { loadSchemaRegistry } from "../../tools/cli/src/schemas.ts";
import { validateRepository } from "../../tools/cli/src/validation.ts";

function interactionBundleFixture(): Record<string, unknown> {
  return {
    schemaVersion: 1,
    key: "synex_fixture:terminal",
    revision: 1,
    smartObjects: [{
      key: "synex_fixture:terminal",
      binding: {
        type: "staticTransform",
        position: { x: 100, y: -200, z: 30 },
        heading: 90,
        tags: ["synex.fixture.terminal"],
      },
      slots: [{
        key: "user",
        localTransform: { position: { x: 0, y: -1, z: 0 }, heading: 0 },
        interactionRadius: 2,
        facingTolerance: 90,
        tags: ["synex.fixture.user"],
        capacity: 1,
        initialState: "FREE",
        availabilityPolicy: {},
      }],
      activities: ["synex_fixture:inspect"],
      tags: ["synex.fixture.terminal"],
      availabilityPolicy: {},
      concurrencyPolicy: { mode: "exclusive" },
      presentation: { variant: "terminal" },
    }],
    intents: [{
      key: "synex_fixture:inspect",
      smartObjectKey: "synex_fixture:terminal",
      verb: "inspect",
      label: "Inspect terminal",
      icon: "terminal",
      basePriority: 10,
      specificity: 1,
      trigger: "primary",
      slotSelector: "user",
      visibilityConditions: [{
        kind: "declarative",
        path: "actor.onFoot",
        operator: "truthy",
      }],
      executionPolicy: {
        maximumDistance: 2,
        managedOnly: false,
        leaseTtlMs: 2500,
        maximumLifetimeMs: 10000,
        lockChannels: ["actor.hands"],
        cancel: { cancelOnMove: true },
        privileged: false,
      },
      actionGraphRef: "synex_fixture:graph.inspect",
      presentation: { cue: "primary" },
      participants: [{
        role: "operator",
        required: true,
        slotKey: "user",
        capacity: 1,
        lossPolicy: "ABORT",
      }],
    }],
    graphs: [{
      key: "synex_fixture:graph.inspect",
      entry: "verify",
      nodes: [
        { key: "verify", type: "verifyLease", next: "finish" },
        { key: "finish", type: "complete" },
      ],
      locks: ["actor.hands"],
      timeoutMs: 10000,
      cancelPolicy: { cancelOnDeath: true },
      participantLossPolicy: "ABORT",
    }],
    metadata: { purpose: "tooling fixture" },
  };
}

function resourceManifest(interactionBundles: string[]): Record<string, unknown> {
  return {
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
    interactionBundles,
  };
}

async function prepareRepository(): Promise<{
  root: string;
  resource: string;
  manifestFile: string;
  bundleFile: string;
}> {
  const root = await mkdtemp(join(tmpdir(), "synex-interaction-schema-"));
  await cp(join(process.cwd(), "schemas"), join(root, "schemas"), { recursive: true });
  const resource = join(root, "resources", "synex_fixture");
  const interactions = join(resource, "interactions");
  await mkdir(interactions, { recursive: true });
  const manifestFile = join(resource, "synex.resource.json");
  const bundleFile = join(interactions, "terminal.interact.json");
  await writeFile(manifestFile, `${JSON.stringify(resourceManifest([
    "interactions/terminal.interact.json",
  ]), null, 2)}\n`, "utf8");
  await writeFile(bundleFile, `${JSON.stringify(interactionBundleFixture(), null, 2)}\n`, "utf8");
  await writeFile(
    join(resource, "fxmanifest.lua"),
    "fx_version 'cerulean'\ngame 'gta5'\nversion '0.1.0'\n",
    "utf8",
  );
  return { root, resource, manifestFile, bundleFile };
}

test("interaction and resource schemas enforce the canonical bundle shapes and paths", async () => {
  const schemas = await loadSchemaRegistry(process.cwd());
  const bundle = interactionBundleFixture();
  assert.equal(schemas.interactionBundle(bundle), true, JSON.stringify(schemas.interactionBundle.errors));

  const unknown = structuredClone(bundle);
  unknown.unknown = true;
  assert.equal(schemas.interactionBundle(unknown), false);

  const malformedBinding = structuredClone(bundle);
  const smartObjects = malformedBinding.smartObjects as Array<Record<string, unknown>>;
  smartObjects[0]!.binding = {
    type: "entityBone",
    model: 1,
    bone: "boot",
    unexpected: true,
  };
  assert.equal(schemas.interactionBundle(malformedBinding), false);

  assert.equal(schemas.resource(resourceManifest([
    "interactions/terminal.interact.json",
    "interactions/vehicles/trunk-1.interact.json",
  ])), true, JSON.stringify(schemas.resource.errors));
  for (const paths of [
    ["interactions/../outside.interact.json"],
    ["interactions/vehicles/./trunk.interact.json"],
    ["interactions/vehicles//trunk.interact.json"],
    ["world/terminal.interact.json"],
    ["interactions/terminal.json"],
    ["interactions/terminal.interact.json", "interactions/terminal.interact.json"],
  ]) {
    assert.equal(schemas.resource(resourceManifest(paths)), false, paths.join(","));
  }
});

test("repository validation loads and counts declared interaction bundles", async (context) => {
  const fixture = await prepareRepository();
  context.after(async () => rm(fixture.root, { recursive: true, force: true }));

  const report = await validateRepository(fixture.root, fixture.resource);
  assert.deepEqual(report.diagnostics.filter((entry) => entry.level === "error"), []);
  assert.equal(report.interactionBundles, 1);
  assert.equal(report.filesChecked, 3);
});

test("repository validation rejects missing, invalid, foreign, and duplicate bundle declarations", async (context) => {
  const fixture = await prepareRepository();
  context.after(async () => rm(fixture.root, { recursive: true, force: true }));

  await writeFile(fixture.bundleFile, "{invalid", "utf8");
  let report = await validateRepository(fixture.root, fixture.resource);
  assert.equal(report.diagnostics.some((entry) => entry.rule === "interaction-bundle-json"), true);

  await writeFile(
    fixture.bundleFile,
    `${JSON.stringify({ ...interactionBundleFixture(), unknown: true })}\n`,
    "utf8",
  );
  report = await validateRepository(fixture.root, fixture.resource);
  assert.equal(report.diagnostics.some((entry) => entry.rule === "interaction-bundle-schema"), true);

  const foreign = interactionBundleFixture();
  foreign.key = "synex_other:terminal";
  await writeFile(fixture.bundleFile, `${JSON.stringify(foreign)}\n`, "utf8");
  report = await validateRepository(fixture.root, fixture.resource);
  assert.equal(report.diagnostics.some((entry) => entry.rule === "interaction-bundle-ownership"), true);

  const duplicateDefinition = interactionBundleFixture();
  const objects = duplicateDefinition.smartObjects as Array<Record<string, unknown>>;
  objects.push({
    ...structuredClone(objects[0]!),
    tags: ["synex_fixture.duplicate"],
  });
  await writeFile(fixture.bundleFile, `${JSON.stringify(duplicateDefinition)}\n`, "utf8");
  report = await validateRepository(fixture.root, fixture.resource);
  assert.equal(report.diagnostics.some((entry) =>
    entry.rule === "interaction-definition-key-unique"
  ), true);

  const secondFile = join(fixture.resource, "interactions", "second.interact.json");
  await writeFile(fixture.bundleFile, `${JSON.stringify(interactionBundleFixture())}\n`, "utf8");
  await writeFile(secondFile, `${JSON.stringify(interactionBundleFixture())}\n`, "utf8");
  await writeFile(fixture.manifestFile, `${JSON.stringify(resourceManifest([
    "interactions/terminal.interact.json",
    "interactions/second.interact.json",
  ]))}\n`, "utf8");
  report = await validateRepository(fixture.root, fixture.resource);
  assert.equal(report.diagnostics.some((entry) => entry.rule === "interaction-bundle-key-unique"), true);

  await writeFile(fixture.manifestFile, `${JSON.stringify(resourceManifest([
    "interactions/missing.interact.json",
  ]))}\n`, "utf8");
  report = await validateRepository(fixture.root, fixture.resource);
  assert.equal(report.diagnostics.some((entry) => entry.rule === "interaction-bundle-path"), true);
});
