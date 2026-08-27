import assert from "node:assert/strict";
import { access, readFile } from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { Ajv2020, type AnySchema, type ValidateFunction } from "ajv/dist/2020.js";

const root = process.cwd();
const compatibilityRoot = path.join(root, "libraries", "synex_bridge", "compatibility");

const artifacts = [
  { artifact: "surfaces/qb.json", schema: "schemas/surfaces.schema.json" },
  { artifact: "surfaces/qbx.json", schema: "schemas/surfaces.schema.json" },
  { artifact: "surfaces/esx.json", schema: "schemas/surfaces.schema.json" },
  { artifact: "profiles.json", schema: "schemas/profiles.schema.json" },
  { artifact: "consumers.json", schema: "schemas/consumers.schema.json" },
  { artifact: "money-policies.json", schema: "schemas/money-policies.schema.json" },
  { artifact: "mappings.json", schema: "schemas/mappings.schema.json" },
  { artifact: "review-lock.json", schema: "schemas/review-lock.schema.json" },
] as const;

type CompatibilitySurface = {
  name: string;
  status: string;
  requiredAdapter: string | null;
  requiredCatalog?: string | null;
  catalogOperations?: Array<{ name: string; nativeCapabilities: string[] }>;
  modes: string[];
  tests: string[];
};

type SurfaceCatalog = {
  kind: string;
  provider: "qb" | "qbx" | "esx";
  providerResource: string;
  providerVersion: string;
  targetFrameworkApiRange: string | null;
  upstream: {
    repository: string;
    branch: "main";
    revision: string;
    sources: Array<{ id: string; path: string; bytes: number; sha256: string }>;
    evidenceUrls: string[];
  };
  surfaces: CompatibilitySurface[];
};

async function readJson(relativePath: string): Promise<unknown> {
  return JSON.parse(await readFile(path.join(compatibilityRoot, relativePath), "utf8")) as unknown;
}

async function validator(schemaPath: string): Promise<ValidateFunction> {
  const schema = (await readJson(schemaPath)) as AnySchema;
  return new Ajv2020({ allErrors: true, strict: true, validateFormats: false }).compile(schema);
}

test("bridge compatibility artifacts validate against their strict bounded schemas", async () => {
  const validators = new Map<string, ValidateFunction>();

  for (const entry of artifacts) {
    let validate = validators.get(entry.schema);
    if (validate === undefined) {
      validate = await validator(entry.schema);
      validators.set(entry.schema, validate);
    }

    const document = await readJson(entry.artifact);
    assert.equal(
      validate(document),
      true,
      `${entry.artifact}: ${JSON.stringify(validate.errors)}`,
    );
  }
});

test("bridge catalogs start fail-closed without fabricated consumers, identities, domain mappings, or adapters", async () => {
  const profiles = (await readJson("profiles.json")) as {
    kind: string;
    profiles: unknown[];
  };
  const consumers = (await readJson("consumers.json")) as {
    kind: string;
    defaultMode: string;
    consumers: unknown[];
  };
  const moneyPolicies = (await readJson("money-policies.json")) as {
    kind: string;
    policies: unknown[];
  };
  const mappings = (await readJson("mappings.json")) as {
    kind: string;
    identity: unknown[];
    accounts: Array<{
      provider: string;
      alias: string;
      version: string;
      currencyCode: string;
      accountKey: string;
      accountRole: string;
      minorUnit: number;
      legacyName: string;
      label: string;
      round: boolean;
      status: string;
      fundingPolicy: { kind: string; accountRef: null };
      sinkPolicy: { kind: string; accountRef: null };
    }>;
    groups: unknown[];
    permissions: unknown[];
    metadata: Array<{
      id: string;
      version: string;
      provider: string;
      key: string;
      valueType: string;
      minimum: number | null;
      maximum: number | null;
      maxLength: number | null;
      storageKey: string;
      status: string;
      sensitive: boolean;
    }>;
    forbiddenMetadataFields: string[];
  };

  assert.equal(profiles.kind, "synex-compatibility-profiles");
  assert.deepEqual(profiles.profiles, []);
  assert.equal(consumers.kind, "synex-compatibility-consumers");
  assert.equal(consumers.defaultMode, "strict");
  assert.deepEqual(consumers.consumers, []);
  assert.equal(moneyPolicies.kind, "synex-compatibility-money-policies");
  assert.deepEqual(moneyPolicies.policies, []);

  assert.equal(mappings.kind, "synex-compatibility-mappings");
  assert.deepEqual(mappings.identity, []);
  assert.deepEqual(
    mappings.accounts.map((entry) => `${entry.provider}:${entry.alias}`).sort(),
    ["esx:bank", "esx:cash", "qb:bank", "qb:cash", "qbx:bank", "qbx:cash"],
  );
  for (const entry of mappings.accounts) {
    assert.equal(entry.version, "2.0.0");
    assert.equal(entry.currencyCode, "usd");
    assert.equal(entry.accountKey, entry.alias);
    assert.equal(entry.accountRole, "asset");
    assert.equal(entry.minorUnit, 0);
    assert.equal(entry.legacyName, entry.provider === "esx" && entry.alias === "cash"
      ? "money" : entry.alias);
    assert.ok(entry.label === "Cash" || entry.label === "Bank");
    assert.equal(entry.round, true);
    assert.equal(entry.status, "PARTIAL");
    assert.deepEqual(entry.fundingPolicy, { kind: "deny", accountRef: null });
    assert.deepEqual(entry.sinkPolicy, { kind: "deny", accountRef: null });
  }
  assert.deepEqual(mappings.groups, []);
  assert.deepEqual(mappings.permissions, []);
  assert.deepEqual(
    mappings.metadata.map((entry) => entry.id).sort(),
    ["esx.hunger", "qb.hunger", "qbx.hunger"],
  );
  for (const entry of mappings.metadata) {
    assert.equal(entry.version, "1.0.0");
    assert.equal(entry.key, "hunger");
    assert.equal(entry.valueType, "integer");
    assert.equal(entry.minimum, 0);
    assert.equal(entry.maximum, 100);
    assert.equal(entry.maxLength, null);
    assert.equal(entry.storageKey, "needs.hunger");
    assert.equal(entry.status, "PARTIAL");
    assert.equal(entry.sensitive, false);
    assert.ok(["qb", "qbx", "esx"].includes(entry.provider));
  }
  assert.ok(mappings.forbiddenMetadataFields.length > 0);
  assert.equal(new Set(mappings.forbiddenMetadataFields).size, mappings.forbiddenMetadataFields.length);
  for (const authorityField of [
    "session_id",
    "source_generation",
    "user_id",
    "character_id",
    "permissions",
    "capabilities",
    "accounts",
    "balances",
    "password_hash",
    "access_token",
  ]) {
    assert.ok(
      mappings.forbiddenMetadataFields.includes(authorityField),
      `${authorityField} must not be admitted through legacy metadata mappings`,
    );
  }
});

test("surface evidence is official and never claims certification or an available adapter", async () => {
  const allowedStatuses = new Set([
    "CERTIFIED",
    "COMPATIBLE",
    "PARTIAL",
    "UNSUPPORTED",
    "UNKNOWN",
  ]);
  const truthfulInitialStatuses = new Set(["PARTIAL", "UNSUPPORTED"]);
  const officialHosts: Record<SurfaceCatalog["provider"], Set<string>> = {
    qb: new Set(["github.com"]),
    qbx: new Set(["docs.qbox.re", "github.com"]),
    esx: new Set(["docs.esx-framework.org", "github.com"]),
  };
  const officialGithubOwners: Record<SurfaceCatalog["provider"], string> = {
    qb: "qbcore-framework",
    qbx: "qbox-project",
    esx: "esx-framework",
  };
  const names = new Set<string>();

  for (const provider of ["qb", "qbx", "esx"] as const) {
    const catalog = (await readJson(`surfaces/${provider}.json`)) as SurfaceCatalog;
    assert.equal(catalog.kind, "synex-compatibility-surfaces");
    assert.equal(catalog.provider, provider);
    assert.equal(catalog.providerResource, `synex_bridge_${provider}`);
    assert.equal(catalog.providerVersion, "0.1.0");
    assert.equal(catalog.targetFrameworkApiRange, null);
    assert.ok(catalog.surfaces.length > 0);
    assert.equal(new URL(catalog.upstream.repository).hostname, "github.com");
    assert.equal(
      new URL(catalog.upstream.repository).pathname.split("/")[1]?.toLowerCase(),
      officialGithubOwners[provider],
    );
    assert.equal(catalog.upstream.branch, "main");
    assert.match(catalog.upstream.revision, /^[0-9a-f]{40}$/u);
    assert.ok(catalog.upstream.sources.length > 0);
    assert.equal(new Set(catalog.upstream.sources.map((source) => source.id)).size,
      catalog.upstream.sources.length);
    for (const source of catalog.upstream.sources) {
      assert.equal(source.path.startsWith("/"), false);
      assert.equal(source.path.split("/").includes(".."), false);
      assert.ok(source.bytes > 0 && source.bytes <= 262144);
      assert.match(source.sha256, /^[0-9a-f]{64}$/u);
    }

    for (const evidenceUrl of catalog.upstream.evidenceUrls) {
      const parsed = new URL(evidenceUrl);
      assert.equal(parsed.protocol, "https:");
      assert.ok(officialHosts[provider].has(parsed.hostname), evidenceUrl);
      if (parsed.hostname === "github.com") {
        assert.equal(
          parsed.pathname.split("/")[1]?.toLowerCase(),
          officialGithubOwners[provider],
        );
      }
    }

    for (const surface of catalog.surfaces) {
      assert.ok(allowedStatuses.has(surface.status));
      assert.ok(truthfulInitialStatuses.has(surface.status));
      assert.notEqual(surface.status, "CERTIFIED");
      assert.notEqual(surface.status, "COMPATIBLE");
      assert.equal(surface.requiredAdapter, null);
      assert.equal(names.has(surface.name), false, `duplicate surface ${surface.name}`);
      names.add(surface.name);
      if (surface.status === "PARTIAL") {
        assert.equal(surface.modes.includes("strict"), false);
      }
      for (const evidenceTest of surface.tests) {
        await access(path.join(root, evidenceTest));
      }
    }
  }
});

test("artifact schemas reject unbounded or unknown catalog input", async () => {
  const validateCertification = await validator("schemas/certification.schema.json");
  assert.equal(validateCertification({}), false);
  assert.equal(validateCertification({ status: "CERTIFIED", certified: true }), false);

  const validateConsumers = await validator("schemas/consumers.schema.json");
  const consumers = (await readJson("consumers.json")) as Record<string, unknown>;
  assert.equal(validateConsumers({ ...consumers, unexpected: true }), false);

  const validateMoneyPolicies = await validator("schemas/money-policies.schema.json");
  const moneyPolicies = (await readJson("money-policies.json")) as Record<string, unknown>;
  const transferPolicy = {
    id: "qb.fixture.cash.add",
    version: "1.0.0",
    provider: "qb",
    consumer: "fixture_consumer",
    moneyAlias: "cash",
    direction: "add",
    legacyReason: "fixture",
    action: "transfer",
    accountId: "11111111-1111-4111-8111-111111111111",
    nativeReasonCode: "compat.qb.fixture_consumer.fixture",
    status: "ACTIVE",
  };
  assert.equal(validateMoneyPolicies({ ...moneyPolicies, policies: [transferPolicy] }), true);
  const { accountId: _accountId, ...transferWithoutAccount } = transferPolicy;
  assert.equal(validateMoneyPolicies({
    ...moneyPolicies, policies: [transferWithoutAccount],
  }), false, "transfer requires an exact counterparty accountId");
  assert.equal(validateMoneyPolicies({
    ...moneyPolicies,
    policies: [{ ...transferWithoutAccount, action: "mint", direction: "remove" }],
  }), false, "mint cannot remove supply");
  assert.equal(validateMoneyPolicies({
    ...moneyPolicies,
    policies: [{ ...transferWithoutAccount, action: "burn", direction: "add" }],
  }), false, "burn cannot add supply");
  assert.equal(validateMoneyPolicies({
    ...moneyPolicies,
    policies: [{ ...transferPolicy, action: "mint", direction: "add" }],
  }), false, "mint cannot select a counterparty accountId");

  const validateSurfaces = await validator("schemas/surfaces.schema.json");
  const qb = (await readJson("surfaces/qb.json")) as SurfaceCatalog & Record<string, unknown>;
  const first = qb.surfaces[0];
  assert.notEqual(first, undefined);
  assert.equal(
    validateSurfaces({
      ...qb,
      surfaces: [{ ...first, modes: ["permissive"] }],
    }),
    false,
  );
  assert.equal(
    validateSurfaces({
      ...qb,
      surfaces: [{ ...first, name: "x".repeat(129) }],
    }),
    false,
  );
  const catalogSurface = {
    ...first,
    status: "PARTIAL",
    requiredCapability: "synex.compat.qb.read",
    requiredAdapter: null,
    adapterOperations: [],
    requiredCatalog: "inventory.items",
    catalogOperations: [{
      name: "item.lookup",
      nativeCapabilities: ["synex.inventory.read", "synex.identity.read"],
    }],
  };
  assert.equal(
    validateSurfaces({ ...qb, surfaces: [catalogSurface] }),
    true,
    JSON.stringify(validateSurfaces.errors),
  );
  assert.equal(validateSurfaces({
    ...qb,
    surfaces: [{ ...catalogSurface, requiredAdapter: "qb.inventory" }],
  }), false);
  assert.equal(validateSurfaces({
    ...qb,
    surfaces: [{ ...catalogSurface, catalogOperations: [] }],
  }), false);
  assert.equal(validateSurfaces({
    ...qb,
    surfaces: [{
      ...catalogSurface,
      catalogOperations: [{
        name: "item.lookup",
        nativeCapabilities: [],
      }],
    }],
  }), false);

  const validateProfiles = await validator("schemas/profiles.schema.json");
  const profiles = (await readJson("profiles.json")) as Record<string, unknown>;
  const uncertifiedVersion = {
    id: "qb.fixture",
    version: "1.0.0",
    script: { name: "legacy_resource", testedVersion: null },
    provider: "qb",
    mode: "compat",
    status: "CERTIFIED",
    failurePolicy: "fail_start",
    providerVersion: "0.1.0",
    targetFrameworkApiRange: "^7.0.0",
    certificationArtifact: "compatibility/certifications/qb.fixture.json",
    requiredSurfaces: [{
      name: "qb.server.player_lookup",
      acceptedStatuses: ["PARTIAL"],
    }],
    requiredAdapters: [{ name: "fixture.adapter", versionRange: null }],
    evidence: {
      tests: ["compatibility/evidence/fixture.test.json"],
      sourceUrls: ["https://example.invalid/fixture"],
    },
  };
  assert.equal(validateProfiles({ ...profiles, profiles: [uncertifiedVersion] }), false);
  assert.equal(validateProfiles({
    ...profiles,
    profiles: [{
      ...uncertifiedVersion,
      script: { name: "legacy_resource", testedVersion: "2.0.0" },
    }],
  }), true, JSON.stringify(validateProfiles.errors));
  const catalogProfile = {
    ...uncertifiedVersion,
    script: { name: "legacy_resource", testedVersion: "2.0.0" },
    requiredCatalogs: [{
      name: "inventory.items",
      versionRange: "^1.0.0",
      domain: "inventory",
      revision: 7,
    }],
  };
  assert.equal(
    validateProfiles({ ...profiles, profiles: [catalogProfile] }),
    true,
    JSON.stringify(validateProfiles.errors),
  );
  assert.equal(validateProfiles({
    ...profiles,
    profiles: [{
      ...catalogProfile,
      requiredCatalogs: [{ ...catalogProfile.requiredCatalogs[0], revision: 0 }],
    }],
  }), false);
  assert.equal(validateProfiles({
    ...profiles,
    profiles: [{
      ...catalogProfile,
      requiredCatalogs: [{ ...catalogProfile.requiredCatalogs[0], authority: "domain" }],
    }],
  }), false);
});
