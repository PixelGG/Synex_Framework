export const COMPATIBILITY_STATUSES = [
  "CERTIFIED",
  "COMPATIBLE",
  "PARTIAL",
  "UNSUPPORTED",
  "UNKNOWN",
] as const;

export type CompatibilityStatus = typeof COMPATIBILITY_STATUSES[number];
export type CompatibilityProvider = "qb" | "qbx" | "esx";
export type CompatibilityFramework = "synex" | "qbcore" | "qbx" | "esx" | "vrp" | "ox_core";

export interface CompatibilityCatalogDiagnostic {
  severity: "error" | "warning";
  code: string;
  path: string;
  message: string;
}

export interface CompatibilitySurface {
  provider: CompatibilityProvider;
  providerVersion: string;
  targetFrameworkApiRange: string | null;
  name: string;
  scope: string;
  type: string;
  status: CompatibilityStatus;
  legacyVersionRange: string | null;
  nativeMapping: string | null;
  requiredCapability: string | null;
  requiredAdapter: string | null;
  adapterOperations: Array<{
    name: string;
    nativeCapabilities: string[];
  }>;
  requiredCatalog: string | null;
  catalogOperations: Array<{
    name: string;
    nativeCapabilities: string[];
  }>;
  modes: string[];
  deprecated: boolean;
  tests: string[];
}

export interface CompatibilityProfile {
  id: string;
  version: string;
  script: string;
  provider: CompatibilityProvider | null;
  mode: string;
  status: CompatibilityStatus;
  effectiveStatus: CompatibilityStatus;
  testedVersion: string | null;
  providerVersion: string | null;
  targetFrameworkApiRange: string | null;
  vendor?: string | null;
  upstream?: { repository: string; revision: string } | null;
  requiredDomains?: string[];
  requiredExports?: string[];
  requiredEvents?: string[];
  directSql?: string[];
  knownLimitations?: string[];
  testedFlows?: string[];
  certificationArtifact: string | null;
  requiredAdapters: string[];
  requiredCatalogs: string[];
  surfaces: string[];
  evidence: string[];
  failurePolicy: string;
  raw: Record<string, unknown>;
}

export interface CompatibilityProviderCatalog {
  provider: CompatibilityProvider;
  providerResource: string;
  providerVersion: string;
  targetFrameworkApiRange: string | null;
}

export interface CompatibilityConsumer {
  id: string;
  provider: CompatibilityProvider | null;
  profile: string | null;
  mode: string | null;
  enabled: boolean;
  failurePolicy: string | null;
  raw: Record<string, unknown>;
}

export interface CompatibilityMoneyPolicy {
  id: string;
  version: string;
  provider: CompatibilityProvider;
  consumer: string;
  moneyAlias: string;
  direction: "add" | "remove";
  legacyReason: string;
  action: "transfer" | "mint" | "burn";
  accountId: string | null;
  nativeReasonCode: string;
  status: "ACTIVE" | "DISABLED";
  raw: Record<string, unknown>;
}

export interface CompatibilityMapping {
  id: string;
  category: "identity" | "accounts" | "groups" | "metadata" | "permissions";
  provider: CompatibilityProvider | null;
  legacy: string;
  native: string | null;
  adapter: string | null;
  status: CompatibilityStatus;
  raw: Record<string, unknown>;
}

export interface CompatibilityCatalog {
  schema: 1;
  root: string;
  available: boolean;
  files: string[];
  providerCatalogs: CompatibilityProviderCatalog[];
  surfaces: CompatibilitySurface[];
  profiles: CompatibilityProfile[];
  consumers: CompatibilityConsumer[];
  moneyPolicies: CompatibilityMoneyPolicy[];
  mappings: CompatibilityMapping[];
  forbiddenMetadataFields: string[];
  diagnostics: CompatibilityCatalogDiagnostic[];
}

export interface CompatibilityFinding {
  category: "framework" | "surface" | "domain" | "direct_sql" | "manifest";
  framework: CompatibilityFramework;
  provider: CompatibilityProvider | null;
  domain: "accounts" | "callbacks" | "entities" | "groups" | "identity" | "inventory" | "vehicles" | null;
  file: string;
  line: number;
  signal: string;
  surface: string | null;
  migrationNote: string;
}

export interface CompatibilityReport {
  schema: 1;
  artifactKind: "synex-compatibility-scan";
  status: CompatibilityStatus;
  target: string;
  filesScanned: number;
  filesByLanguage: {
    lua: number;
    javascript: number;
    typescript: number;
    manifest: number;
  };
  bytesScanned: number;
  symlinksSkipped: number;
  signatureCounts: Record<CompatibilityFramework, number>;
  frameworks: CompatibilityFramework[];
  surfaces: string[];
  domainDependencies: string[];
  directLegacySql: number;
  findings: CompatibilityFinding[];
  disclaimer: string;
}

export interface CompatibilityDoctorFinding {
  severity: "error" | "warning";
  code: string;
  subject: string;
  message: string;
}

export type CompatibilityDoctorCheckStatus = "PASS" | "WARNING" | "FAIL" | "UNKNOWN";

export interface CompatibilityDoctorCheck {
  id: string;
  status: CompatibilityDoctorCheckStatus;
  subject: string;
  evidence: "catalog" | "runtime" | "catalog+runtime" | "deferred";
  message: string;
}

export interface CompatibilityDoctorReport {
  schema: 1;
  artifactKind: "synex-compatibility-doctor";
  status: CompatibilityStatus;
  catalogAvailable: boolean;
  checks: CompatibilityDoctorCheck[];
  findings: CompatibilityDoctorFinding[];
  checked: {
    surfaces: number;
    profiles: number;
    consumers: number;
    moneyPolicies: number;
    mappings: number;
    adapters: number;
    runtime: {
      provided: boolean;
      complete: boolean | null;
      expectedProviders: number;
      providers: number;
      capabilities: number;
      conflicts: number;
      consumerBindings: number;
      telemetryEntries: number;
      certifications: number;
      callbackTelemetryProviders: number;
    };
  };
  disclaimer: string;
}
