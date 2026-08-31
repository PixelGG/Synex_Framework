import { Ajv2020 } from "ajv/dist/2020.js";
import type { ErrorObject, ValidateFunction } from "ajv";
import { join } from "node:path";

import type { Diagnostic } from "./types.ts";
import { CliError } from "./errors.ts";
import { displayPath, isRecord, readJsonFile } from "./filesystem.ts";

const CONTRACT_SCHEMA_PATH = "schemas/contract.schema.json";
const RESOURCE_SCHEMA_PATH = "schemas/resource.schema.json";
const STATE_SCHEMA_PATH = "schemas/state.schema.json";
const CONFIGURATION_SCHEMA_PATH = "schemas/config.schema.json";
const CAPABILITY_POLICY_SCHEMA_PATH = "schemas/capability-policy.schema.json";
const WORLD_BUNDLE_SCHEMA_PATH = "schemas/world-bundle.schema.json";
const INTERACTION_BUNDLE_SCHEMA_PATH = "schemas/interaction-bundle.schema.json";

export interface SchemaRegistry {
  contract: ValidateFunction<unknown>;
  resource: ValidateFunction<unknown>;
  state: ValidateFunction<unknown>;
  configuration: ValidateFunction<unknown>;
  capabilityPolicy: ValidateFunction<unknown>;
  worldBundle: ValidateFunction<unknown>;
  interactionBundle: ValidateFunction<unknown>;
}

export async function loadSchemaRegistry(repositoryRoot: string): Promise<SchemaRegistry> {
  const ajv = new Ajv2020({ allErrors: true, strict: true, validateFormats: false });
  const contractSchema = await readJsonFile(join(repositoryRoot, CONTRACT_SCHEMA_PATH));
  const resourceSchema = await readJsonFile(join(repositoryRoot, RESOURCE_SCHEMA_PATH));
  const stateSchema = await readJsonFile(join(repositoryRoot, STATE_SCHEMA_PATH));
  const configurationSchema = await readJsonFile(join(repositoryRoot, CONFIGURATION_SCHEMA_PATH));
  const capabilityPolicySchema = await readJsonFile(join(repositoryRoot, CAPABILITY_POLICY_SCHEMA_PATH));
  const worldBundleSchema = await readJsonFile(join(repositoryRoot, WORLD_BUNDLE_SCHEMA_PATH));
  const interactionBundleSchema = await readJsonFile(join(repositoryRoot, INTERACTION_BUNDLE_SCHEMA_PATH));
  if (!isRecord(contractSchema) || !isRecord(resourceSchema) || !isRecord(stateSchema)
    || !isRecord(configurationSchema) || !isRecord(capabilityPolicySchema)
    || !isRecord(worldBundleSchema) || !isRecord(interactionBundleSchema)) {
    throw new CliError("Synex schema documents must be JSON objects.");
  }

  return {
    contract: ajv.compile(contractSchema),
    resource: ajv.compile(resourceSchema),
    state: ajv.compile(stateSchema),
    configuration: ajv.compile(configurationSchema),
    capabilityPolicy: ajv.compile(capabilityPolicySchema),
    worldBundle: ajv.compile(worldBundleSchema),
    interactionBundle: ajv.compile(interactionBundleSchema),
  };
}

export function schemaDiagnostics(
  errors: ErrorObject[] | null | undefined,
  file: string,
  repositoryRoot: string,
  rule: string,
): Diagnostic[] {
  return (errors ?? []).map((error) => ({
    level: "error",
    rule,
    file: displayPath(repositoryRoot, file),
    message: `${error.instancePath || "/"} ${error.message ?? "is invalid"}`,
  }));
}

export function configurationSemanticDiagnostics(
  value: unknown,
  file: string,
  repositoryRoot: string,
): Diagnostic[] {
  if (!isRecord(value)) return [];
  const connections = isRecord(value.connections) ? value.connections : {};
  const rpc = isRecord(value.rpc) ? value.rpc : {};
  const diagnostics: Diagnostic[] = [];
  const add = (path: string, message: string): void => {
    diagnostics.push({
      level: "error",
      rule: "configuration-semantic",
      file: displayPath(repositoryRoot, file),
      message: `${path} ${message}`,
    });
  };
  if (value.environment === "production" && value.strict === false) {
    add("/strict", "must be true when /environment is production.");
  }
  if (value.environment === "production" && value.strict === true
    && typeof connections.duplicatePolicy === "string"
    && connections.duplicatePolicy !== "deny_new") {
    add(
      "/connections/duplicatePolicy",
      "must be deny_new in strict production until multi-instance acceptance is complete.",
    );
  }
  if (typeof rpc.timeoutMs === "number" && typeof rpc.maximumTimeoutMs === "number"
    && rpc.timeoutMs > rpc.maximumTimeoutMs) {
    add("/rpc/timeoutMs", "must not exceed /rpc/maximumTimeoutMs.");
  }
  if (typeof connections.clusterHeartbeatMs === "number"
    && typeof connections.clusterSessionLeaseSeconds === "number"
    && connections.clusterHeartbeatMs * 3 > connections.clusterSessionLeaseSeconds * 1000) {
    add("/connections/clusterHeartbeatMs", "must not exceed one third of the cluster session lease.");
  }
  if (typeof connections.queueUpdateMs === "number" && typeof connections.queueTimeoutMs === "number"
    && connections.queueUpdateMs > connections.queueTimeoutMs) {
    add("/connections/queueUpdateMs", "must not exceed /connections/queueTimeoutMs.");
  }
  if (typeof connections.queueReservedSlots === "number"
    && typeof connections.maximumActiveSessions === "number"
    && connections.queueReservedSlots >= connections.maximumActiveSessions) {
    add("/connections/queueReservedSlots", "must be lower than /connections/maximumActiveSessions.");
  }
  return diagnostics;
}
