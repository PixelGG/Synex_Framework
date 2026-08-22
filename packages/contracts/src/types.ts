export type ContractKind = "rpc" | "event" | "hook" | "service";

export type ContractStability = "experimental" | "stable" | "deprecated" | "internal";

export type ContractNetwork = "none" | "client-to-server" | "server-to-client";

export type SessionState =
  | "CONNECTING"
  | "AUTHENTICATING"
  | "AUTHENTICATED"
  | "SELECTING_CHARACTER"
  | "LOADING_CHARACTER"
  | "ACTIVE"
  | "UNLOADING_CHARACTER"
  | "DISCONNECTING"
  | "CLOSED";

export type JsonSchema = Record<string, unknown>;

export interface ContractRateLimit {
  capacity: number;
  refillPerSecond: number;
}

export interface ContractDefinition {
  name: string;
  version: string;
  kind: ContractKind;
  provider: string;
  stability: ContractStability;
  network: ContractNetwork;
  capability?: string | null;
  sessionStates?: SessionState[];
  input: JsonSchema;
  output: JsonSchema;
  errors: string[];
  idempotent?: boolean;
  rateLimit?: ContractRateLimit;
  deprecatedSince?: string;
  replacement?: string;
}

export interface ContractCollection {
  $schema?: string;
  schema: 1;
  domain: string;
  contracts: ContractDefinition[];
}

export interface LoadedContractCollection {
  file: string;
  relativeFile: string;
  collection: ContractCollection;
}

export interface RuntimeContractDescriptor extends ContractDefinition {
  domain: string;
}

export interface RuntimeContractRegistry {
  schema: 1;
  sourceHash: string;
  contracts: RuntimeContractDescriptor[];
}
