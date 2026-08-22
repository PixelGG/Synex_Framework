export const CONTRACT_SCHEMA_VERSION = 1 as const;

export function contractKey(name: string, version: string): string {
  return `${name}@${version}`;
}

export type {
  ContractCollection,
  ContractDefinition,
  ContractKind,
  ContractNetwork,
  ContractRateLimit,
  ContractStability,
  JsonSchema,
  LoadedContractCollection,
  RuntimeContractDescriptor,
  RuntimeContractRegistry,
  SessionState,
} from "./types.js";
