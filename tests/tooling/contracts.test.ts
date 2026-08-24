import assert from "node:assert/strict";
import { copyFile, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import type { ContractCollection, LoadedContractCollection } from "../../packages/contracts/src/types.js";
import {
  CliError,
  compareContracts,
  createResource,
  fuzzContractInputs,
  generateContracts,
  loadContractSources,
  renderContractArtifacts,
  validateRepository,
} from "../../tools/cli/src/cli.js";

const SAMPLE_CONTRACT: ContractCollection = {
  schema: 1,
  domain: "synex.sample",
  contracts: [
    {
      name: "synex.sample.echo",
      version: "1.0.0",
      kind: "service",
      provider: "synex_sample",
      stability: "experimental",
      network: "none",
      capability: "sample.echo",
      input: {
        type: "object",
        additionalProperties: false,
        required: ["message"],
        properties: { message: { type: "string", maxLength: 128 } },
      },
      output: {
        type: "object",
        additionalProperties: false,
        required: ["message"],
        properties: { message: { type: "string" } },
      },
      errors: ["INVALID_ARGUMENT"],
      idempotent: true,
    },
  ],
};

function loaded(file: string, collection: ContractCollection): LoadedContractCollection {
  return { file, relativeFile: file, collection };
}

async function prepareRepository(): Promise<string> {
  const root = await mkdtemp(join(tmpdir(), "synex-tooling-"));
  await mkdir(join(root, "schemas"), { recursive: true });
  await Promise.all(
    [
      "contract.schema.json",
      "resource.schema.json",
      "state.schema.json",
      "config.schema.json",
      "capability-policy.schema.json",
    ].map((name) =>
      copyFile(join(process.cwd(), "schemas", name), join(root, "schemas", name)),
    ),
  );
  await mkdir(join(root, "core", "synex_core", "config"), { recursive: true });
  await Promise.all(
    ["default.json", "capabilities.json"].map((name) =>
      copyFile(
        join(process.cwd(), "core", "synex_core", "config", name),
        join(root, "core", "synex_core", "config", name),
      ),
    ),
  );
  await writeFile(
    join(root, "package.json"),
    `${JSON.stringify({ name: "synex-test", version: "0.1.0", type: "module", synex: { apiVersion: "1.0.0" } }, null, 2)}\n`,
    "utf8",
  );
  return root;
}

test("contract rendering is byte-deterministic and emits every managed format", () => {
  const root = join(tmpdir(), "synex-deterministic-root");
  const source = loaded("resources/synex_sample/contracts/sample.contracts.json", SAMPLE_CONTRACT);
  const first = renderContractArtifacts(root, [source]);
  const second = renderContractArtifacts(root, [source]);

  assert.equal(first.registry.sourceHash, second.registry.sourceHash);
  assert.deepEqual([...first.artifacts], [...second.artifacts]);
  assert.equal(first.registry.contracts.length, 1);
  assert.equal(first.artifacts.size, 6);
  assert.match([...first.artifacts.values()].join("\n"), /synex\.sample\.echo/u);
});

test("TypeScript generation remains sound for open objects and colliding symbol names", () => {
  const template = SAMPLE_CONTRACT.contracts[0];
  assert.ok(template);
  const collection: ContractCollection = {
    schema: 1,
    domain: "synex.collision",
    contracts: [
      { ...template, name: "synex.collision.foo-bar", output: { type: "object" } },
      { ...template, name: "synex.collision.foo_bar", output: { type: "object" } },
    ],
  };
  const rendered = renderContractArtifacts(join(tmpdir(), "synex-symbol-root"), [loaded("collision.contracts.json", collection)]);
  const typescript = [...rendered.artifacts.entries()].find(([path]) => path.endsWith("contracts.ts"))?.[1];
  assert.ok(typescript);
  const outputTypes = [...typescript.matchAll(/export type ([A-Za-z0-9]+)Output = \{ \[key: string\]: unknown; \};/gu)]
    .map((match) => match[1]);
  assert.equal(outputTypes.length, 2);
  assert.equal(new Set(outputTypes).size, 2);
});

test("generated SDK metadata preserves simultaneous contract versions", () => {
  const template = SAMPLE_CONTRACT.contracts[0];
  assert.ok(template);
  const collection: ContractCollection = {
    schema: 1,
    domain: "synex.versioned",
    contracts: [
      { ...template, name: "synex.versioned.echo", version: "1.0.0" },
      { ...template, name: "synex.versioned.echo", version: "2.0.0" },
    ],
  };
  const rendered = renderContractArtifacts(
    join(tmpdir(), "synex-versioned-root"),
    [loaded("versioned.contracts.json", collection)],
  );
  const typescript = [...rendered.artifacts.entries()].find(([path]) => path.endsWith("contracts.ts"))?.[1];
  const luaSdk = [...rendered.artifacts.entries()].find(([path]) =>
    path.replaceAll("\\", "/").endsWith("packages/sdk-lua/generated/contracts.lua"),
  )?.[1];
  assert.ok(typescript);
  assert.ok(luaSdk);
  assert.match(typescript, /"synex\.versioned\.echo@1\.0\.0"/u);
  assert.match(typescript, /"synex\.versioned\.echo@2\.0\.0"/u);
  assert.match(
    typescript,
    /"synex\.versioned\.echo": GENERATED_CONTRACT_VERSIONS\["synex\.versioned\.echo@2\.0\.0"\]/u,
  );
  assert.match(luaSdk, /\["synex\.versioned\.echo@1\.0\.0"\]/u);
  assert.match(luaSdk, /\["synex\.versioned\.echo@2\.0\.0"\]/u);
  assert.match(
    luaSdk,
    /\["latest"\][\s\S]*?\["synex\.versioned\.echo"\][\s\S]*?\["version"\] = "2\.0\.0"/u,
  );
  assert.match(
    typescript,
    /export type SynexVersionedEchoInput = SynexVersionedEcho[a-f0-9]{8}Input;/u,
  );
  assert.match(
    typescript,
    /export type SynexVersionedEchoOutput = SynexVersionedEcho[a-f0-9]{8}Output;/u,
  );
  assert.match(
    typescript,
    /export type SynexVersionedEchoError = SynexVersionedEcho[a-f0-9]{8}Error;/u,
  );
});

test("contract compatibility preserves published versions and permits additive major versions", () => {
  const previous = loaded("previous.contracts.json", structuredClone(SAMPLE_CONTRACT));
  const versionOne = structuredClone(SAMPLE_CONTRACT.contracts[0]);
  assert.ok(versionOne);
  const versionTwo = structuredClone(versionOne);
  versionTwo.version = "2.0.0";
  versionTwo.output = {
    type: "object",
    additionalProperties: false,
    required: ["message", "accepted"],
    properties: {
      message: { type: "string" },
      accepted: { type: "boolean" },
    },
  };

  const additive = compareContracts(
    [previous],
    [loaded("current.contracts.json", {
      schema: 1,
      domain: SAMPLE_CONTRACT.domain,
      contracts: [versionOne, versionTwo],
    })],
  );
  assert.equal(additive.some((change) => change.level === "breaking"), false);
  assert.ok(additive.some((change) =>
    change.contract === "synex.sample.echo@2.0.0"
      && change.message === "Contract version was added."
  ));

  const mutatedVersionOne = structuredClone(versionTwo);
  mutatedVersionOne.version = "1.0.0";
  const mutation = compareContracts(
    [previous],
    [loaded("mutated.contracts.json", {
      schema: 1,
      domain: SAMPLE_CONTRACT.domain,
      contracts: [mutatedVersionOne],
    })],
  );
  assert.ok(mutation.some((change) =>
    change.level === "breaking" && /immutable/u.test(change.message)
  ));

  const removed = compareContracts(
    [previous],
    [loaded("removed.contracts.json", {
      schema: 1,
      domain: SAMPLE_CONTRACT.domain,
      contracts: [versionTwo],
    })],
  );
  assert.ok(removed.some((change) =>
    change.contract === "synex.sample.echo@1.0.0"
      && change.message === "Contract version was removed."
      && change.level === "breaking"
  ));

  const sameMajor = structuredClone(versionTwo);
  sameMajor.version = "1.1.0";
  const invalidMinor = compareContracts(
    [previous],
    [loaded("minor.contracts.json", {
      schema: 1,
      domain: SAMPLE_CONTRACT.domain,
      contracts: [versionOne, sameMajor],
    })],
  );
  assert.ok(invalidMinor.some((change) =>
    change.contract === "synex.sample.echo@1.1.0"
      && change.message === "Breaking changes require a higher major version."
      && change.level === "breaking"
  ));

  const widenedMinor = structuredClone(versionOne);
  widenedMinor.version = "1.1.0";
  const widenedMessage = (widenedMinor.input.properties as Record<string, Record<string, unknown>>).message;
  assert.ok(widenedMessage);
  widenedMessage.maxLength = 256;
  const validMinor = compareContracts(
    [previous],
    [loaded("widened-minor.contracts.json", {
      schema: 1,
      domain: SAMPLE_CONTRACT.domain,
      contracts: [versionOne, widenedMinor],
    })],
  );
  assert.equal(validMinor.some((change) =>
    change.contract === "synex.sample.echo@1.1.0" && change.level === "breaking"
  ), false);

  const narrowedMinor = structuredClone(versionOne);
  narrowedMinor.version = "1.1.0";
  const narrowedMessage = (narrowedMinor.input.properties as Record<string, Record<string, unknown>>).message;
  assert.ok(narrowedMessage);
  narrowedMessage.maxLength = 64;
  const invalidNarrowing = compareContracts(
    [previous],
    [loaded("narrowed-minor.contracts.json", {
      schema: 1,
      domain: SAMPLE_CONTRACT.domain,
      contracts: [versionOne, narrowedMinor],
    })],
  );
  assert.ok(invalidNarrowing.some((change) =>
    change.contract === "synex.sample.echo@1.1.0"
      && change.message === "input schema is not backward compatible."
      && change.level === "breaking"
  ));

  const changedConstMinor = structuredClone(versionOne);
  changedConstMinor.version = "1.1.0";
  changedConstMinor.input = {
    type: "object",
    additionalProperties: false,
    required: ["mode"],
    properties: { mode: { const: "new" } },
  };
  const constBaseline = structuredClone(versionOne);
  constBaseline.input = {
    type: "object",
    additionalProperties: false,
    required: ["mode"],
    properties: { mode: { const: "old" } },
  };
  const invalidConstChange = compareContracts(
    [loaded("const-previous.contracts.json", {
      schema: 1,
      domain: SAMPLE_CONTRACT.domain,
      contracts: [constBaseline],
    })],
    [loaded("const-minor.contracts.json", {
      schema: 1,
      domain: SAMPLE_CONTRACT.domain,
      contracts: [constBaseline, changedConstMinor],
    })],
  );
  assert.ok(invalidConstChange.some((change) =>
    change.contract === "synex.sample.echo@1.1.0"
      && change.message === "input schema is not backward compatible."
      && change.level === "breaking"
  ));

  const addedErrorMinor = structuredClone(versionOne);
  addedErrorMinor.version = "1.1.0";
  addedErrorMinor.errors.push("TEMPORARILY_UNAVAILABLE");
  const invalidErrorExpansion = compareContracts(
    [previous],
    [loaded("error-minor.contracts.json", {
      schema: 1,
      domain: SAMPLE_CONTRACT.domain,
      contracts: [versionOne, addedErrorMinor],
    })],
  );
  assert.ok(invalidErrorExpansion.some((change) =>
    change.contract === "synex.sample.echo@1.1.0"
      && change.message === "Error TEMPORARILY_UNAVAILABLE was added."
      && change.level === "breaking"
  ));

  const changedBehaviorMinor = structuredClone(versionOne);
  changedBehaviorMinor.version = "1.1.0";
  changedBehaviorMinor.idempotent = false;
  changedBehaviorMinor.sessionStates = ["ACTIVE"];
  changedBehaviorMinor.rateLimit = { capacity: 1, refillPerSecond: 1 };
  const invalidBehaviorChange = compareContracts(
    [previous],
    [loaded("behavior-minor.contracts.json", {
      schema: 1,
      domain: SAMPLE_CONTRACT.domain,
      contracts: [versionOne, changedBehaviorMinor],
    })],
  );
  for (const message of [
    "idempotent behavior changed.",
    "sessionStates were narrowed.",
    "rateLimit was narrowed.",
  ]) {
    assert.ok(invalidBehaviorChange.some((change) =>
      change.contract === "synex.sample.echo@1.1.0"
        && change.message === message
        && change.level === "breaking"
    ));
  }
});

test("contract fuzzer rejects malformed schemas and executes bounded Core runtime scenarios", async () => {
  const report = await fuzzContractInputs(process.cwd());
  assert.equal(report.status, "PASS");
  assert.ok(report.contracts > 0);
  assert.ok(report.cases > report.contracts);
  assert.equal(report.rejected, report.cases);
  assert.deepEqual(report.unexpectedAccepted, []);
  assert.equal(report.runtimeScenarios.executed, true);
  assert.equal(report.runtimeScenarios.failed, 0);
  assert.ok(report.runtimeScenarios.scenarios.some((scenario) => scenario.name === "stale-session"));
  assert.ok(report.runtimeScenarios.scenarios.some((scenario) => scenario.name === "duplicate-idempotency-key"));
  assert.match(report.disclaimer, /do not prove Cfx transport/u);
});

test("contract discovery accepts the repository's plural .contracts.json convention", async (context) => {
  const root = await prepareRepository();
  context.after(async () => rm(root, { recursive: true, force: true }));
  const contractsDirectory = join(root, "resources", "synex_sample", "contracts");
  await mkdir(contractsDirectory, { recursive: true });
  await writeFile(
    join(contractsDirectory, "sample.contracts.json"),
    `${JSON.stringify(SAMPLE_CONTRACT, null, 2)}\n`,
    "utf8",
  );

  const loadedContracts = await loadContractSources(root);
  assert.deepEqual(loadedContracts.diagnostics, []);
  assert.equal(loadedContracts.sources.length, 1);
  assert.equal(loadedContracts.sources[0]?.collection.contracts[0]?.name, "synex.sample.echo");
  await assert.rejects(loadContractSources(root, undefined, join(root, "missing-baseline")), CliError);
});

test("generate --check detects drift without modifying generated files", async (context) => {
  const root = await prepareRepository();
  context.after(async () => rm(root, { recursive: true, force: true }));
  const contractsDirectory = join(root, "resources", "synex_sample", "contracts");
  await mkdir(contractsDirectory, { recursive: true });
  await writeFile(join(contractsDirectory, "sample.contracts.json"), JSON.stringify(SAMPLE_CONTRACT), "utf8");

  const check = await generateContracts(root, true);
  assert.equal(check.contractCount, 1);
  assert.equal(check.stale.length, 6);
  assert.equal(await readFile(join(root, "package.json"), "utf8").then(() => true), true);
  await assert.rejects(readFile(join(root, "packages", "contracts", "generated", "runtime", "contracts.json"), "utf8"));

  const generated = await generateContracts(root, false);
  assert.equal(generated.changed.length, 6);
  const current = await generateContracts(root, true);
  assert.deepEqual(current.stale, []);
});

test("resource scaffolding creates missing parents and validates cleanly", async (context) => {
  const root = await prepareRepository();
  context.after(async () => rm(root, { recursive: true, force: true }));

  await writeFile(
    join(root, "core", "synex_core", "synex.resource.json"),
    `${JSON.stringify({
      schema: 1,
      name: "synex_core",
      version: "0.1.0",
      synex: "^1.0.0",
      critical: true,
      capabilities: { request: [] },
      services: { provide: [], require: [], optional: [] },
      contracts: { provide: [], consume: [] },
      events: { publish: [], subscribe: [] },
      hooks: { register: [], run: [] },
      dependencies: { required: [], optional: [], development: [] },
      migrations: [],
      dataOwnership: { tables: [], characterDelete: "none" },
      stateSnapshot: { supported: false, schemaVersion: 1 },
    }, null, 2)}\n`,
    "utf8",
  );
  await writeFile(
    join(root, "core", "synex_core", "fxmanifest.lua"),
    "fx_version 'cerulean'\ngame 'gta5'\nversion '0.1.0'\nsynex_manifest 'synex.resource.json'\n",
    "utf8",
  );

  const created = await createResource(root, "synex_sample");
  assert.equal(created.length, 9);
  const manifest = await readFile(join(root, "resources", "synex_sample", "fxmanifest.lua"), "utf8");
  const resourceManifest = JSON.parse(
    await readFile(join(root, "resources", "synex_sample", "synex.resource.json"), "utf8"),
  ) as { synex: string };
  assert.match(manifest, /synex_manifest 'synex\.resource\.json'/u);
  assert.match(manifest, /server_script 'server\/main\.lua'/u);
  assert.match(await readFile(join(root, "resources", "synex_sample", "tests", "resource.test.mjs"), "utf8"), /manifest identity/u);
  assert.equal(resourceManifest.synex, "^1.0.0");
  assert.equal(manifest.endsWith("\n"), true);
  await assert.rejects(createResource(root, "synex_sample", "libraries"), /already declared/u);

  const validation = await validateRepository(root);
  assert.deepEqual(validation.diagnostics.filter((entry) => entry.level === "error"), []);
});

test("repository validation enforces cross-field runtime configuration invariants", async (context) => {
  const root = await prepareRepository();
  context.after(async () => rm(root, { recursive: true, force: true }));
  const configurationPath = join(root, "core", "synex_core", "config", "default.json");
  const configuration = JSON.parse(await readFile(configurationPath, "utf8")) as {
    environment: string;
    strict: boolean;
    rpc: { timeoutMs: number; maximumTimeoutMs: number };
    connections: {
      duplicatePolicy: string;
      queueReservedSlots: number;
      maximumActiveSessions: number;
      clusterSessionLeaseSeconds: number;
      clusterHeartbeatMs: number;
    };
  };
  configuration.rpc.timeoutMs = 5_000;
  configuration.rpc.maximumTimeoutMs = 1_000;
  await writeFile(configurationPath, `${JSON.stringify(configuration, null, 2)}\n`, "utf8");

  const validation = await validateRepository(root);
  const finding = validation.diagnostics.find((entry) => entry.rule === "configuration-semantic");
  assert.ok(finding);
  assert.match(finding.message, /\/rpc\/timeoutMs/u);

  configuration.rpc.maximumTimeoutMs = 15_000;
  configuration.connections.queueReservedSlots = configuration.connections.maximumActiveSessions;
  await writeFile(configurationPath, `${JSON.stringify(configuration, null, 2)}\n`, "utf8");
  const reservedValidation = await validateRepository(root);
  const reservedFinding = reservedValidation.diagnostics.find((entry) =>
    entry.rule === "configuration-semantic" && entry.message.includes("/connections/queueReservedSlots")
  );
  assert.ok(reservedFinding);

  configuration.connections.queueReservedSlots = 0;
  configuration.connections.clusterSessionLeaseSeconds = 10;
  configuration.connections.clusterHeartbeatMs = 9_999;
  await writeFile(configurationPath, `${JSON.stringify(configuration, null, 2)}\n`, "utf8");
  const heartbeatValidation = await validateRepository(root);
  const heartbeatFinding = heartbeatValidation.diagnostics.find((entry) =>
    entry.rule === "configuration-semantic" && entry.message.includes("/connections/clusterHeartbeatMs")
  );
  assert.ok(heartbeatFinding);

  configuration.connections.clusterHeartbeatMs = 3_333;
  await writeFile(configurationPath, `${JSON.stringify(configuration, null, 2)}\n`, "utf8");
  const safeHeartbeatValidation = await validateRepository(root);
  assert.equal(safeHeartbeatValidation.diagnostics.some((entry) =>
    entry.rule === "configuration-semantic" && entry.message.includes("/connections/clusterHeartbeatMs")
  ), false);

  configuration.strict = false;
  await writeFile(configurationPath, `${JSON.stringify(configuration, null, 2)}\n`, "utf8");
  const productionStrictValidation = await validateRepository(root);
  assert.ok(productionStrictValidation.diagnostics.some((entry) =>
    entry.rule === "configuration-semantic" && entry.message.includes("/strict")
  ));

  configuration.strict = true;
  configuration.connections.duplicatePolicy = "kick_old";
  await writeFile(configurationPath, `${JSON.stringify(configuration, null, 2)}\n`, "utf8");
  const productionPolicyValidation = await validateRepository(root);
  assert.ok(productionPolicyValidation.diagnostics.some((entry) =>
    entry.rule === "configuration-semantic" && entry.message.includes("/connections/duplicatePolicy")
  ));

  configuration.environment = "staging";
  configuration.strict = false;
  await writeFile(configurationPath, `${JSON.stringify(configuration, null, 2)}\n`, "utf8");
  const stagingPolicyValidation = await validateRepository(root);
  assert.equal(stagingPolicyValidation.diagnostics.some((entry) =>
    entry.rule === "configuration-semantic"
      && (entry.message.includes("/strict") || entry.message.includes("/connections/duplicatePolicy"))
  ), false);
});

test("repository validation rejects removed runtime configuration placeholders", async (context) => {
  const root = await prepareRepository();
  context.after(async () => rm(root, { recursive: true, force: true }));
  const configurationPath = join(root, "core", "synex_core", "config", "default.json");
  const configuration = JSON.parse(await readFile(configurationPath, "utf8")) as Record<string, unknown>;
  const database = configuration.database as Record<string, unknown>;
  database.queryTimeoutMs = 5_000;
  configuration.events = { maximumQueueDepth: 1_024 };
  configuration.privacy = {
    identifierSaltConvar: "synex_identifier_salt",
    diagnosticIdentifierPrefix: 8,
  };
  await writeFile(configurationPath, `${JSON.stringify(configuration, null, 2)}\n`, "utf8");

  const validation = await validateRepository(root);
  const findings = validation.diagnostics.filter((entry) => entry.rule === "configuration-schema");
  assert.ok(findings.length >= 3);
  assert.ok(findings.some((entry) => entry.message.includes("/database")));
});
