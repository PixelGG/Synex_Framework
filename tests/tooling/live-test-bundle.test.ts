import assert from "node:assert/strict";
import { createHash, randomUUID } from "node:crypto";
import { spawnSync } from "node:child_process";
import {
  cp,
  mkdir,
  mkdtemp,
  readFile,
  rm,
  symlink,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve, sep } from "node:path";
import test, { type TestContext } from "node:test";

import {
  CORE_PROBE_CAPABILITIES,
  prepareCoreLiveTestBundle,
  validateRepository,
} from "../../tools/cli/src/cli.js";

function sha256(value: string): string {
  return createHash("sha256").update(value, "utf8").digest("hex");
}

function git(repository: string, argumentsList: string[]): string {
  const result = spawnSync("git", argumentsList, {
    cwd: repository,
    encoding: "utf8",
    timeout: 30_000,
    windowsHide: true,
  });
  assert.equal(result.status, 0, `${result.stderr}\n${result.stdout}`);
  return result.stdout.trim();
}

async function removeFixture(path: string): Promise<void> {
  const temporaryRoot = `${resolve(tmpdir())}${sep}`;
  assert.ok(resolve(path).startsWith(temporaryRoot));
  await rm(path, { recursive: true, force: true });
}

async function commitFixture(repository: string, message: string): Promise<void> {
  git(repository, ["add", "."]);
  git(repository, [
    "-c",
    "user.name=Synex Test",
    "-c",
    "user.email=synex-test@example.invalid",
    "-c",
    "commit.gpgsign=false",
    "commit",
    "-m",
    message,
  ]);
}

async function createRepositoryFixture(context: TestContext): Promise<string> {
  const repository = await mkdtemp(join(tmpdir(), "synex-live-bundle-repository-"));
  context.after(() => removeFixture(repository));
  await Promise.all([
    cp(join(process.cwd(), "schemas"), join(repository, "schemas"), { recursive: true }),
    cp(join(process.cwd(), "core", "synex_core"), join(repository, "core", "synex_core"), { recursive: true }),
    cp(join(process.cwd(), ".gitignore"), join(repository, ".gitignore")),
    writeFile(
      join(repository, "package.json"),
      `${JSON.stringify({
        name: "synex-live-test-fixture",
        version: "0.1.0",
        private: true,
        type: "module",
        synex: { apiVersion: "1.0.0" },
      }, null, 2)}\n`,
      "utf8",
    ),
  ]);
  git(repository, ["-c", "init.defaultBranch=main", "init"]);
  await commitFixture(repository, "test: create live bundle fixture");
  return repository;
}

function probeManifest(capabilities: string[] = [...CORE_PROBE_CAPABILITIES]): Record<string, unknown> {
  return {
    $schema: "https://synex.dev/schemas/resource.schema.json",
    schema: 1,
    name: "synex_core_probe",
    version: "0.1.0",
    synex: "^1.0.0",
    critical: false,
    capabilities: { request: capabilities },
    services: { provide: [], require: [], optional: [] },
    contracts: { provide: ["synex.core_probe.acceptance"], consume: [] },
    events: { publish: [], subscribe: [] },
    hooks: { register: [], run: [] },
    dependencies: {
      required: [{ name: "synex_core", version: ">=0.1.0" }],
      optional: [],
      development: [],
    },
    migrations: [],
    dataOwnership: { tables: [], characterDelete: "none" },
    stateSnapshot: { supported: false, schemaVersion: 1 },
  };
}

const SAFE_PROBE_SOURCE = `local runId = GetConvar('synex_probe_run_id', '')
assert(runId:match('^probe_%x+$'), 'probe run id is required')
local key = 'synex_core_probe.owner_epoch.v1:' .. runId
local previous = GetResourceKvpInt(key)
SetResourceKvpInt(key, previous + 1)
DeleteResourceKvp(key)

local api, apiError = exports.synex_core:GetAPI()
assert(api ~= nil and apiError == nil, 'core API is required')
`;

const PROBE_CONTRACTS = {
  $schema: "https://synex.dev/schemas/contract.schema.json",
  schema: 1,
  domain: "synex.core_probe",
  contracts: [{
    name: "synex.core_probe.acceptance",
    version: "1.0.0",
    kind: "rpc",
    provider: "synex_core_probe",
    stability: "internal",
    network: "none",
    capability: null,
    input: { type: "object", additionalProperties: false },
    output: { type: "object", additionalProperties: false },
    errors: ["PROBE_FAILED"],
    idempotent: false,
  }],
};

async function createExternalProbe(
  context: TestContext,
  options: { capabilities?: string[]; source?: string } = {},
): Promise<string> {
  const parent = await mkdtemp(join(tmpdir(), "synex-live-bundle-probe-"));
  context.after(() => removeFixture(parent));
  const probe = join(parent, "synex_core_probe");
  await mkdir(probe);
  await Promise.all([
    writeFile(
      join(probe, "synex.resource.json"),
      `${JSON.stringify(probeManifest(options.capabilities), null, 2)}\n`,
      "utf8",
    ),
    writeFile(
      join(probe, "fxmanifest.lua"),
      `fx_version 'cerulean'
game 'gta5'

name 'synex_core_probe'
description 'Disposable Synex Core acceptance probe'
version '0.1.0'
server_only 'yes'

dependency 'synex_core'
synex_manifest 'synex.resource.json'
synex_contracts 'probe.contracts.json'

server_script 'server.lua'

files {
    'probe.contracts.json',
    'synex.resource.json'
}
`,
      "utf8",
    ),
    writeFile(join(probe, "probe.contracts.json"), `${JSON.stringify(PROBE_CONTRACTS, null, 2)}\n`, "utf8"),
    writeFile(join(probe, "server.lua"), options.source ?? SAFE_PROBE_SOURCE, "utf8"),
  ]);
  return probe;
}

test("live-test builder derives an exact disposable policy without touching production", async (context) => {
  const repository = await createRepositoryFixture(context);
  const probe = await createExternalProbe(context);
  const outputRelative = join(".temp", "live-test", `unit-${randomUUID()}`);
  const productionPolicyPath = join(repository, "core", "synex_core", "config", "capabilities.json");
  const productionBefore = await readFile(productionPolicyPath, "utf8");
  await Promise.all([
    writeFile(join(repository, "core", "synex_core", ".env"), "PRIVATE_TOKEN=must-not-copy\n", "utf8"),
    writeFile(join(repository, "core", "synex_core", "ignored.log"), "private ignored log\n", "utf8"),
  ]);
  assert.equal(git(repository, ["status", "--porcelain=v1", "--untracked-files=normal"]), "");

  const report = await prepareCoreLiveTestBundle(repository, probe, outputRelative);
  const bundle = join(repository, report.bundle);
  const testPolicy = JSON.parse(await readFile(
    join(bundle, "server-data", "resources", "synex_core", "config", "capabilities.json"),
    "utf8",
  )) as { resources: Record<string, { allow: string[]; deny: string[] }> };
  const productionAfter = await readFile(productionPolicyPath, "utf8");

  assert.equal(report.status, "PREPARED");
  assert.equal(report.schema, 2);
  assert.match(report.revision, /^[0-9a-f]{40,64}$/u);
  assert.match(report.runId, /^probe_[0-9a-f]{32}$/u);
  assert.match(report.instanceId, /^probe_[0-9a-f]{24}$/u);
  assert.deepEqual(report.kvpIsolation, {
    strategy: "run-scoped-resource-key",
    key: `synex_core_probe.owner_epoch.v1:${report.runId}`,
    cleanupRequired: true,
  });
  assert.match(report.resources.core, /server-data\/resources\/synex_core$/u);
  assert.match(report.resources.probe, /server-data\/resources\/synex_core_probe$/u);
  assert.deepEqual(report.grants, CORE_PROBE_CAPABILITIES);
  assert.deepEqual(report.runtimeRequirements, {
    resources: [{ name: "oxmysql", version: "2.14.1" }],
    operatorConfiguration: ["mysql_connection_string", "sv_licenseKey", "endpoint_add_tcp", "endpoint_add_udp"],
  });
  assert.equal(report.probe.kvpStaticKeyScoped, true);
  assert.equal(productionAfter, productionBefore);
  assert.equal(report.hashes.productionPolicy, sha256(productionBefore));
  assert.deepEqual(testPolicy.resources.synex_core_probe, {
    allow: [...CORE_PROBE_CAPABILITIES],
    deny: [],
  });

  const configuration = await readFile(join(repository, report.configuration), "utf8");
  assert.match(configuration, /DO NOT DEPLOY/u);
  assert.match(configuration, /mysql_connection_string/u);
  assert.doesNotMatch(configuration, /sv_kvsName/u);
  assert.doesNotMatch(configuration, /;/u);
  const commands = configuration
    .split(/\r?\n/u)
    .filter((line) => line.length > 0 && !line.startsWith("#"));
  assert.deepEqual(commands, [
    'set synex_environment "production"',
    'set synex_strict "1"',
    'set synex_duplicate_policy "deny_new"',
    `set synex_instance_id "${report.instanceId}"`,
    `set synex_probe_run_id "${report.runId}"`,
    "ensure oxmysql",
    "ensure synex_core",
    "ensure synex_core_probe",
  ]);
  assert.doesNotMatch(configuration, /\bset[rs]\s+synex_probe_run_id/u);
  assert.equal(report.hashes.configuration, sha256(configuration));
  assert.equal(report.safeguards.runScopedKvpKey, true);

  const metadata = await readFile(join(bundle, "bundle.json"), "utf8");
  assert.equal(metadata.includes(repository), false);
  assert.equal(metadata.includes(dirname(probe)), false);
  await assert.rejects(
    readFile(join(bundle, "server-data", "resources", "synex_core", ".env"), "utf8"),
    /ENOENT/u,
  );
  await assert.rejects(
    readFile(join(bundle, "server-data", "resources", "synex_core", "ignored.log"), "utf8"),
    /ENOENT/u,
  );
  assert.equal(git(repository, ["status", "--porcelain=v1", "--untracked-files=normal"]), "");
  const repositoryValidation = await validateRepository(repository);
  assert.equal(repositoryValidation.resources, 1);
  assert.equal(repositoryValidation.diagnostics.some((diagnostic) => diagnostic.level === "error"), false);
});

test("live-test builder rejects probes inside the tracked repository", async (context) => {
  const repository = await createRepositoryFixture(context);
  const externalProbe = await createExternalProbe(context);
  const internalProbe = join(repository, "synex_core_probe");
  await cp(externalProbe, internalProbe, { recursive: true });
  await commitFixture(repository, "test: add unsafe in-repository probe");

  await assert.rejects(
    prepareCoreLiveTestBundle(repository, internalProbe),
    /outside the repository checkout/u,
  );
});

test("live-test builder rejects missing, wildcard, and additional capability requests", async (context) => {
  const repository = await createRepositoryFixture(context);
  const variants = [
    CORE_PROBE_CAPABILITIES.slice(0, 3),
    ["synex.connections.gate", "synex.sagas.*"],
    [...CORE_PROBE_CAPABILITIES, "synex.runtime.read"],
  ];
  for (const capabilities of variants) {
    const probe = await createExternalProbe(context, { capabilities: [...capabilities] });
    await assert.rejects(
      prepareCoreLiveTestBundle(repository, probe),
      /(?:must contain exactly|resource manifest is invalid)/u,
    );
  }
});

test("live-test builder rejects unscoped or asynchronous KVP state", async (context) => {
  const repository = await createRepositoryFixture(context);
  const probe = await createExternalProbe(context, {
    source: `local key = 'owner_epoch'
local previous = GetResourceKvpInt(key)
SetResourceKvpIntNoSync(key, previous + 1)
DeleteResourceKvp(key)
`,
  });
  await assert.rejects(
    prepareCoreLiveTestBundle(repository, probe),
    /KVP enumeration, external access, asynchronous writes/u,
  );

  const reassignedProbe = await createExternalProbe(context, {
    source: SAFE_PROBE_SOURCE.replace(
      "local previous = GetResourceKvpInt(key)",
      "key = 'global'\nlocal previous = GetResourceKvpInt(key)",
    ),
  });
  await assert.rejects(
    prepareCoreLiveTestBundle(repository, reassignedProbe),
    /unique, immutable, and unshadowed/u,
  );

  const markerProbe = await createExternalProbe(context, {
    source: `local marker = 'GetResourceKvpInt(key) SetResourceKvpInt(key, 1) DeleteResourceKvp(key)'
local api, apiError = exports.synex_core:GetAPI()
assert(api ~= nil and apiError == nil and marker ~= '', 'core API is required')
`,
  });
  const markerOutput = join(".temp", "live-test", `marker-${randomUUID()}`);
  const markerReport = await prepareCoreLiveTestBundle(repository, markerProbe, markerOutput);
  assert.equal(markerReport.probe.kvpStaticKeyScoped, false);

  const commentProbe = await createExternalProbe(context, {
    source: `--[=[
ExecuteCommand('comment only')
SetResourceKvpInt('unscoped', 1)
]=]
local marker = '--'
local open = '--[['
${SAFE_PROBE_SOURCE}`,
  });
  const commentOutput = join(".temp", "live-test", `comments-${randomUUID()}`);
  const commentReport = await prepareCoreLiveTestBundle(repository, commentProbe, commentOutput);
  assert.equal(commentReport.probe.kvpStaticKeyScoped, true);
});

test("live-test builder requires a server-only manifest with explicit local scripts", async (context) => {
  const repository = await createRepositoryFixture(context);

  const clientProbe = await createExternalProbe(context);
  const clientManifestPath = join(clientProbe, "fxmanifest.lua");
  const clientManifest = (await readFile(clientManifestPath, "utf8"))
    .replace("server_only 'yes'", "client_script 'client.lua'");
  await Promise.all([
    writeFile(clientManifestPath, clientManifest, "utf8"),
    writeFile(join(clientProbe, "client.lua"), "return true\n", "utf8"),
  ]);
  await assert.rejects(
    prepareCoreLiveTestBundle(repository, clientProbe),
    /server-only|server_only/u,
  );

  const externalScriptProbe = await createExternalProbe(context);
  const externalManifestPath = join(externalScriptProbe, "fxmanifest.lua");
  await writeFile(
    externalManifestPath,
    (await readFile(externalManifestPath, "utf8")).replace("'server.lua'", "'@other_resource/payload.lua'"),
    "utf8",
  );
  await assert.rejects(
    prepareCoreLiveTestBundle(repository, externalScriptProbe),
    /fxmanifest must identify|explicit local/u,
  );

  const missingScriptProbe = await createExternalProbe(context);
  const missingManifestPath = join(missingScriptProbe, "fxmanifest.lua");
  await writeFile(
    missingManifestPath,
    (await readFile(missingManifestPath, "utf8")).replace("'server.lua'", "'missing.lua'"),
    "utf8",
  );
  await assert.rejects(
    prepareCoreLiveTestBundle(repository, missingScriptProbe),
    /server script missing\.lua is missing/u,
  );

  const javascriptProbe = await createExternalProbe(context);
  const javascriptManifestPath = join(javascriptProbe, "fxmanifest.lua");
  await Promise.all([
    writeFile(
      javascriptManifestPath,
      (await readFile(javascriptManifestPath, "utf8")).replace("'server.lua'", "'server.js'"),
      "utf8",
    ),
    writeFile(join(javascriptProbe, "server.js"), "require('node:https')\n", "utf8"),
    rm(join(javascriptProbe, "server.lua")),
  ]);
  await assert.rejects(
    prepareCoreLiveTestBundle(repository, javascriptProbe),
    /(?:explicit local \.lua files|operation forbidden)/u,
  );

  const executableManifestProbe = await createExternalProbe(context);
  const executableManifestPath = join(executableManifestProbe, "fxmanifest.lua");
  await writeFile(
    executableManifestPath,
    `${await readFile(executableManifestPath, "utf8")}\nerror('abort probe')\n`,
    "utf8",
  );
  await assert.rejects(
    prepareCoreLiveTestBundle(repository, executableManifestProbe),
    /approved static server-only directives/u,
  );

  const quotedDirectiveProbe = await createExternalProbe(context);
  const quotedDirectivePath = join(quotedDirectiveProbe, "fxmanifest.lua");
  const quotedDirectiveManifest = (await readFile(quotedDirectivePath, "utf8"))
    .replace("description 'Disposable Synex Core acceptance probe'", "description \"server_script 'server.lua'\"")
    .replace("server_script 'server.lua'\n", "");
  await writeFile(quotedDirectivePath, quotedDirectiveManifest, "utf8");
  await assert.rejects(
    prepareCoreLiveTestBundle(repository, quotedDirectiveProbe),
    /explicit local server-script form/u,
  );

  const quotedCommentProbe = await createExternalProbe(context);
  const quotedCommentPath = join(quotedCommentProbe, "fxmanifest.lua");
  const quotedCommentManifest = (await readFile(quotedCommentPath, "utf8"))
    .replace(
      "description 'Disposable Synex Core acceptance probe'",
      "description '--[['\nserver_script '@other_resource/payload.lua'\ndescription ']]'",
    )
    .replace("server_script 'server.lua'\n", "");
  await writeFile(quotedCommentPath, quotedCommentManifest, "utf8");
  await assert.rejects(
    prepareCoreLiveTestBundle(repository, quotedCommentProbe),
    /(?:fxmanifest must identify|explicit local)/u,
  );
});

test("live-test builder limits ConVars, exports, and direct connection control", async (context) => {
  const repository = await createRepositoryFixture(context);
  const variants = [
    {
      source: "local license = GetConvar('sv_licenseKey', '')\n",
      error: /may read only the literal/u,
    },
    {
      source: "local database = exports.oxmysql\n",
      error: /exports from synex_core only/u,
    },
    {
      source: "AddEventHandler('playerConnecting', function() end)\n",
      error: /operation forbidden/u,
    },
    {
      source: "AddEventHandler('synex:probe:run', function() end)\n",
      error: /operation forbidden/u,
    },
    {
      source: "RegisterCommand('synex_probe_run', function() end, true)\n",
      error: /operation forbidden/u,
    },
    {
      source: "local register = RegisterCommand\nregister('synex_probe_run', function() end, false)\n",
      error: /operation forbidden/u,
    },
    {
      source: "local request = PerformHttpRequest\nrequest('https://example.invalid')\n",
      error: /operation forbidden/u,
    },
    {
      source: "TriggerLatentClientEvent('probe:unsafe', -1, 1024, '{}')\n",
      error: /operation forbidden/u,
    },
    {
      source: "_ENV['RegisterCommand']('synex_probe_run', function() end, false)\n",
      error: /operation forbidden/u,
    },
    {
      source: "local identifiers = GetPlayerIdentifiers(1)\n",
      error: /operation forbidden/u,
    },
    {
      source: "GlobalState.synexProbe = true\n",
      error: /operation forbidden/u,
    },
    {
      source: "Citizen['Invoke' .. 'Native'](0xDEADBEEF)\n",
      error: /operation forbidden/u,
    },
    {
      source: "Citizen['InvokeNative'](0xDEADBEEF)\n",
      error: /operation forbidden/u,
    },
    {
      source: "local marker = '--'; ExecuteCommand('quit')\n",
      error: /operation forbidden/u,
    },
    {
      source: `local marker = '--[['
rawget(_G, 'SetResourceKvpInt')('unscoped', 1)
local closing = ']]'
`,
      error: /operation forbidden/u,
    },
  ];
  for (const variant of variants) {
    const probe = await createExternalProbe(context, { source: variant.source });
    await assert.rejects(prepareCoreLiveTestBundle(repository, probe), variant.error);
  }
});

test("live-test builder rejects undeclared capability use found in probe code", async (context) => {
  const repository = await createRepositoryFixture(context);
  const probe = await createExternalProbe(context, {
    source: `${SAFE_PROBE_SOURCE}\nrequireCapability('synex.admin.raw')\n`,
  });
  const outputRelative = join(".temp", "live-test", `permission-${randomUUID()}`);
  await assert.rejects(
    prepareCoreLiveTestBundle(repository, probe, outputRelative),
    /permission analysis found [1-9][0-9]* error/u,
  );
  await assert.rejects(readFile(join(repository, outputRelative, "bundle.json"), "utf8"), /ENOENT/u);
});

test("live-test builder rejects nested links and output outside the ignored boundary", async (context) => {
  const repository = await createRepositoryFixture(context);
  const linkedProbe = await createExternalProbe(context);
  const linkTargetParent = await mkdtemp(join(tmpdir(), "synex-live-bundle-link-target-"));
  context.after(() => removeFixture(linkTargetParent));
  const linkTarget = join(linkTargetParent, "linked");
  await mkdir(linkTarget);
  await writeFile(join(linkTarget, "linked.lua"), "return true\n", "utf8");
  await symlink(linkTarget, join(linkedProbe, "linked"), "junction");
  await assert.rejects(
    prepareCoreLiveTestBundle(repository, linkedProbe),
    /symbolic links or junctions/u,
  );

  const safeProbe = await createExternalProbe(context);
  await assert.rejects(
    prepareCoreLiveTestBundle(repository, safeProbe, join("artifacts", "live-test")),
    /child directory of \.temp\/live-test/u,
  );
});

test("live-test builder preserves future production defaults and removes a failed bundle", async (context) => {
  const repository = await createRepositoryFixture(context);
  const probe = await createExternalProbe(context);
  const policyPath = join(repository, "core", "synex_core", "config", "capabilities.json");
  const policy = JSON.parse(await readFile(policyPath, "utf8")) as {
    default: { deny: string[] };
  };
  policy.default.deny.push("synex.sagas.*");
  await writeFile(policyPath, `${JSON.stringify(policy, null, 2)}\n`, "utf8");
  await commitFixture(repository, "test: deny sagas by default");
  const productionBefore = await readFile(policyPath, "utf8");
  const outputRelative = join(".temp", "live-test", `denied-${randomUUID()}`);
  const output = join(repository, outputRelative);

  await assert.rejects(
    prepareCoreLiveTestBundle(repository, probe, outputRelative),
    /default deny covers synex\.sagas\.read/u,
  );
  assert.equal(await readFile(policyPath, "utf8"), productionBefore);
  await assert.rejects(readFile(join(output, "bundle.json"), "utf8"), /ENOENT/u);
  assert.equal(git(repository, ["status", "--porcelain=v1", "--untracked-files=normal"]), "");

  const allowRepository = await createRepositoryFixture(context);
  const allowProbe = await createExternalProbe(context);
  const allowPolicyPath = join(allowRepository, "core", "synex_core", "config", "capabilities.json");
  const allowPolicy = JSON.parse(await readFile(allowPolicyPath, "utf8")) as {
    default: { allow: string[] };
  };
  allowPolicy.default.allow.push("synex.runtime.read");
  await writeFile(allowPolicyPath, `${JSON.stringify(allowPolicy, null, 2)}\n`, "utf8");
  await commitFixture(allowRepository, "test: grant runtime reads by default");
  await assert.rejects(
    prepareCoreLiveTestBundle(allowRepository, allowProbe),
    /would grant the probe more than the four reviewed capabilities/u,
  );
});

test("live-test builder refuses dirty revisions and pre-existing targets", async (context) => {
  const repository = await createRepositoryFixture(context);
  const probe = await createExternalProbe(context);
  await writeFile(join(repository, "untracked.txt"), "operator work\n", "utf8");
  await assert.rejects(
    prepareCoreLiveTestBundle(repository, probe),
    /requires a clean Git checkout/u,
  );
  await rm(join(repository, "untracked.txt"));

  const outputRelative = join(".temp", "live-test", `existing-${randomUUID()}`);
  await mkdir(join(repository, outputRelative), { recursive: true });
  await assert.rejects(
    prepareCoreLiveTestBundle(repository, probe, outputRelative),
    /already exists/u,
  );
});
