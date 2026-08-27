import assert from "node:assert/strict";
import test from "node:test";

import { doctorCompatibility } from "../../tools/cli/src/compatibility.js";
import type { RuntimeCompatibilityEvidence } from "../../tools/cli/src/compatibility/evidence.js";
import type { CompatibilityCatalog, CompatibilityMapping } from "../../tools/cli/src/compatibility/types.js";

function mapping(
  id: string,
  category: CompatibilityMapping["category"],
  provider: "qbx",
  legacy: string,
  native: string,
  raw: Record<string, unknown>,
): CompatibilityMapping {
  return { id, category, provider, legacy, native, adapter: null, status: "PARTIAL", raw };
}

function catalog(mappings: CompatibilityMapping[]): CompatibilityCatalog {
  return {
    schema: 1,
    root: "libraries/synex_bridge/compatibility",
    available: true,
    files: [],
    providerCatalogs: [{
      provider: "qbx", providerResource: "synex_bridge_qbx",
      providerVersion: "1.2.3", targetFrameworkApiRange: "^1.0.0",
    }],
    surfaces: [
      {
        provider: "qbx", providerVersion: "1.2.3", targetFrameworkApiRange: "^1.0.0",
        name: "qbx.server.money_mutation", scope: "server", type: "method",
        status: "PARTIAL", legacyVersionRange: null, nativeMapping: "synex.accounts.transfer_v2@2",
        requiredCapability: "synex.compat.qbx.write", requiredAdapter: null,
        adapterOperations: [], requiredCatalog: null, catalogOperations: [],
        modes: ["compat"], deprecated: true, tests: [],
      },
      {
        provider: "qbx", providerVersion: "1.2.3", targetFrameworkApiRange: "^1.0.0",
        name: "qbx.server.group_mutation", scope: "server", type: "method",
        status: "PARTIAL", legacyVersionRange: null,
        nativeMapping: "synex.groups.compatibility.set_primary_grade@1",
        requiredCapability: "synex.compat.qbx.write", requiredAdapter: null,
        adapterOperations: [], requiredCatalog: null, catalogOperations: [],
        modes: ["compat"], deprecated: true, tests: [],
      },
    ],
    profiles: [{
      id: "qbx.fixture", version: "1.0.0", script: "fixture", provider: "qbx",
      mode: "compat", status: "PARTIAL", effectiveStatus: "PARTIAL",
      testedVersion: "2.0.0", providerVersion: "1.2.3",
      targetFrameworkApiRange: "^1.0.0", certificationArtifact: null,
      requiredAdapters: [], requiredCatalogs: [], surfaces: [], evidence: [],
      failurePolicy: "fail_start", raw: {},
    }],
    consumers: [{
      id: "legacy_consumer", provider: "qbx", profile: "qbx.fixture", mode: "compat",
      enabled: true, failurePolicy: "fail_start", raw: {},
    }],
    moneyPolicies: [],
    mappings,
    forbiddenMetadataFields: ["password"],
    diagnostics: [],
  };
}

test("bridge doctor reports missing account coverage, invalid grade maps, and legacy ID collisions", async () => {
  const groups = mapping("qbx.police", "groups", "qbx", "job:police", "police", {
    nativeGroupType: "job",
    grades: [
      { legacyGrade: 0, gradeKey: "recruit" },
      { legacyGrade: 0, gradeKey: "officer" },
    ],
  });
  const identities = [
    mapping("qbx.identity.one", "identity", "qbx", "OLD-1", "char_public_1", {
      entityKind: "character",
    }),
    mapping("qbx.identity.two", "identity", "qbx", "OLD-2", "char_public_1", {
      entityKind: "character",
    }),
  ];
  const report = await doctorCompatibility(process.cwd(), catalog([groups, ...identities]));
  const codes = new Set(report.findings.map((finding) => finding.code));
  assert.equal(codes.has("ACCOUNT_MAPPING_MISSING"), true);
  assert.equal(codes.has("GROUP_GRADE_MAPPING_AMBIGUOUS"), true);
  assert.equal(codes.has("LEGACY_ID_NATIVE_COLLISION"), true);
  assert.equal(report.checks.find((check) => check.id === "mappings.accounts.coverage")?.status, "FAIL");
  assert.equal(report.checks.find((check) => check.id === "mappings.groups.integrity")?.status, "FAIL");
  assert.equal(report.checks.find((check) => check.id === "runtime.callback-cleanup")?.status, "UNKNOWN");
});

test("bridge doctor rejects ambiguous or unbound money policies and reports fail-closed coverage", async () => {
  const account = mapping("qbx.cash", "accounts", "qbx", "cash", "usd:cash:asset:0", {});
  const fixture = catalog([account]);
  fixture.profiles[0]!.surfaces = ["qbx.server.money_mutation"];
  fixture.moneyPolicies = [
    {
      id: "qbx.fixture.cash.add.one", version: "1.0.0", provider: "qbx",
      consumer: "legacy_consumer", moneyAlias: "cash", direction: "add",
      legacyReason: "salary", action: "transfer",
      accountId: "11111111-1111-4111-8111-111111111111",
      nativeReasonCode: "compat.qbx.legacy_consumer.salary", status: "ACTIVE", raw: {},
    },
    {
      id: "qbx.fixture.cash.add.two", version: "1.0.0", provider: "qbx",
      consumer: "legacy_consumer", moneyAlias: "cash", direction: "add",
      legacyReason: "salary", action: "mint", accountId: null,
      nativeReasonCode: "compat.qbx.legacy_consumer.salary", status: "ACTIVE", raw: {},
    },
    {
      id: "qbx.missing.bank.remove", version: "1.0.0", provider: "qbx",
      consumer: "missing_consumer", moneyAlias: "bank", direction: "remove",
      legacyReason: "purchase", action: "burn", accountId: null,
      nativeReasonCode: "compat.qbx.missing_consumer.purchase", status: "ACTIVE", raw: {},
    },
  ];
  const report = await doctorCompatibility(process.cwd(), fixture);
  const codes = new Set(report.findings.map((finding) => finding.code));
  assert.equal(codes.has("MONEY_POLICY_AMBIGUOUS"), true);
  assert.equal(codes.has("MONEY_POLICY_MAPPING_MISSING"), true);
  assert.equal(codes.has("MONEY_POLICY_CONSUMER_MISSING"), true);
  assert.equal(report.checks.find((check) => check.id === "money-policies.integrity")?.status, "FAIL");
  assert.equal(report.checks.find((check) => check.id === "money-policies.coverage")?.status, "PASS");

  fixture.moneyPolicies = [];
  const denied = await doctorCompatibility(process.cwd(), fixture);
  assert.equal(denied.findings.some((finding) => finding.code === "MONEY_POLICY_MISSING"), true);
  assert.equal(denied.checks.find((check) => check.id === "money-policies.coverage")?.status, "WARNING");
});

test("bridge doctor scopes static identity collision checks by provider and entity kind", async () => {
  const identities = [
    mapping("qbx.identity.user", "identity", "qbx", "SAME-ID", "user_public_1", {
      entityKind: "user",
    }),
    mapping("qbx.identity.character", "identity", "qbx", "SAME-ID", "char_public_1", {
      entityKind: "character",
    }),
  ];
  const report = await doctorCompatibility(process.cwd(), catalog(identities));
  assert.equal(report.findings.some((finding) => finding.code === "MAPPING_AMBIGUOUS"), false);
  assert.equal(report.findings.some((finding) => finding.code === "LEGACY_ID_COLLISION"), false);
});

test("bridge doctor evaluates callback cleanup, usage rates, conflicts, consumers, and profile versions", async () => {
  const mappings = [
    mapping("qbx.cash", "accounts", "qbx", "cash", "usd:cash:asset:0", {}),
    mapping("qbx.police", "groups", "qbx", "job:police", "police", {
      nativeGroupType: "job", grades: [{ legacyGrade: 0, gradeKey: "recruit" }],
    }),
  ];
  const evidence: RuntimeCompatibilityEvidence = {
    schema: 1,
    kind: "synex-compatibility-runtime-evidence",
    source: "operator",
    complete: true,
    expectedProviders: ["qbx"],
    providers: [{
      provider: "qbx", resource: "synex_bridge_qbx", version: "1.2.4", state: "started",
      health: {
        status: "READY", reasons: [], callbackPending: 1, callbackCapacity: 512,
        callbackRegistrations: 1, callbackRegistrationCapacity: 256,
      },
      capabilities: [],
      conflicts: [{ code: "COMPAT_FRAMEWORK_CONFLICT", active: true }],
      telemetry: {
        truncated: false,
        entries: [{
          consumer: "legacy_consumer", operation: "callback.invoke", calls: 20,
          outcomes: {
            success: 18, denied: 0, unsupported: 2, error: 0, timeout: 0,
            rateLimited: 0, deprecated: 10,
          },
          latency: { samples: 20, totalMs: 40, maximumMs: 4 },
        }],
      },
    }],
    consumers: [{ consumer: "legacy_consumer", provider: "qbx", active: false }],
    mappings: { ambiguous: 0, missing: 0, forbidden: 0 },
    certifications: [{
      profileId: "qbx.fixture", profileVersion: "2.0.0", provider: "qbx",
      providerVersion: "1.2.4", targetFrameworkApiRange: "^1.0.0",
      script: { name: "fixture", version: "2.0.0" },
      tests: [{ path: "tests/fixture.test.ts", sha256: "a".repeat(64), status: "PASS" }],
    }],
  };
  const report = await doctorCompatibility(process.cwd(), catalog(mappings), evidence);
  const codes = new Set(report.findings.map((finding) => finding.code));
  for (const code of [
    "RUNTIME_STALE_CALLBACK_PENDING",
    "RUNTIME_STALE_CALLBACK_REGISTRATION",
    "RUNTIME_STALE_CONSUMER_TELEMETRY",
    "RUNTIME_UNSUPPORTED_RATE_HIGH",
    "RUNTIME_DEPRECATED_RATE_HIGH",
    "RUNTIME_FRAMEWORK_RESOURCE_CONFLICT",
    "RUNTIME_PROVIDER_VERSION_MISMATCH",
    "RUNTIME_PROFILE_VERSION_MISMATCH",
  ]) assert.equal(codes.has(code), true, code);
  assert.equal(report.checks.find((check) => check.id === "runtime.callback-cleanup")?.status, "FAIL");
  assert.equal(report.checks.find((check) => check.id === "runtime.unsupported-rate")?.status, "WARNING");
  assert.equal(report.checks.find((check) => check.id === "runtime.deprecated-rate")?.status, "WARNING");
  assert.equal(report.checks.find((check) => check.id === "runtime.facade-framework-conflicts")?.status, "FAIL");
  assert.equal(report.checks.find((check) => check.id === "runtime.profile-versions")?.status, "FAIL");
  assert.equal(report.checked.runtime.callbackTelemetryProviders, 1);
});
