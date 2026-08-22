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

export interface SchemaRegistry {
  contract: ValidateFunction<unknown>;
  resource: ValidateFunction<unknown>;
  state: ValidateFunction<unknown>;
  configuration: ValidateFunction<unknown>;
  capabilityPolicy: ValidateFunction<unknown>;
}

export async function loadSchemaRegistry(repositoryRoot: string): Promise<SchemaRegistry> {
  const ajv = new Ajv2020({ allErrors: true, strict: true, validateFormats: false });
  const contractSchema = await readJsonFile(join(repositoryRoot, CONTRACT_SCHEMA_PATH));
  const resourceSchema = await readJsonFile(join(repositoryRoot, RESOURCE_SCHEMA_PATH));
  const stateSchema = await readJsonFile(join(repositoryRoot, STATE_SCHEMA_PATH));
  const configurationSchema = await readJsonFile(join(repositoryRoot, CONFIGURATION_SCHEMA_PATH));
  const capabilityPolicySchema = await readJsonFile(join(repositoryRoot, CAPABILITY_POLICY_SCHEMA_PATH));
  if (!isRecord(contractSchema) || !isRecord(resourceSchema) || !isRecord(stateSchema)
    || !isRecord(configurationSchema) || !isRecord(capabilityPolicySchema)) {
    throw new CliError("Synex schema documents must be JSON objects.");
  }

  return {
    contract: ajv.compile(contractSchema),
    resource: ajv.compile(resourceSchema),
    state: ajv.compile(stateSchema),
    configuration: ajv.compile(configurationSchema),
    capabilityPolicy: ajv.compile(capabilityPolicySchema),
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
  const database = isRecord(value.database) ? value.database : {};
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
  if (typeof database.queryWarnMs === "number" && typeof database.queryTimeoutMs === "number"
    && database.queryWarnMs > database.queryTimeoutMs) {
    add("/database/queryWarnMs", "must not exceed /database/queryTimeoutMs.");
  }
  if (typeof rpc.timeoutMs === "number" && typeof rpc.maximumTimeoutMs === "number"
    && rpc.timeoutMs > rpc.maximumTimeoutMs) {
    add("/rpc/timeoutMs", "must not exceed /rpc/maximumTimeoutMs.");
  }
  if (typeof connections.clusterHeartbeatMs === "number"
    && typeof connections.clusterSessionLeaseSeconds === "number"
    && connections.clusterHeartbeatMs >= connections.clusterSessionLeaseSeconds * 1000) {
    add("/connections/clusterHeartbeatMs", "must be shorter than the cluster session lease.");
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
