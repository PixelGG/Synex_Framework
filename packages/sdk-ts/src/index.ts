import {
  GENERATED_CONTRACTS,
  GENERATED_CONTRACT_VERSIONS,
} from "./generated/contracts.js";
import type {
  GeneratedContractMap,
  GeneratedVersionedContractMap,
} from "./generated/contracts.js";

export type ContractName = keyof GeneratedContractMap;
export type ContractVersionKey = keyof GeneratedVersionedContractMap;

export type ContractInput<Name extends ContractName> = GeneratedContractMap[Name]["input"];

export type ContractOutput<Name extends ContractName> = GeneratedContractMap[Name]["output"];

export type ContractError<Name extends ContractName> = GeneratedContractMap[Name]["error"];

export type VersionedContractInput<Key extends ContractVersionKey> =
  GeneratedVersionedContractMap[Key]["input"];

export type VersionedContractOutput<Key extends ContractVersionKey> =
  GeneratedVersionedContractMap[Key]["output"];

export type VersionedContractError<Key extends ContractVersionKey> =
  GeneratedVersionedContractMap[Key]["error"];

export interface SynexTransport {
  request(contract: string, version: string, input: unknown): Promise<unknown>;
}

export class SynexClient {
  readonly #transport: SynexTransport;

  public constructor(transport: SynexTransport) {
    this.#transport = transport;
  }

  public async request<Name extends ContractName>(
    contract: Name,
    input: ContractInput<Name>,
  ): Promise<ContractOutput<Name>> {
    const descriptors: Readonly<Record<string, { readonly name: string; readonly version: string }>> = GENERATED_CONTRACTS;
    const descriptor = descriptors[String(contract)];
    if (!descriptor) throw new Error(`Unknown Synex contract: ${String(contract)}`);
    const output = await this.#transport.request(descriptor.name, descriptor.version, input);
    return output as ContractOutput<Name>;
  }

  public async requestVersion<Key extends ContractVersionKey>(
    contract: Key,
    input: VersionedContractInput<Key>,
  ): Promise<VersionedContractOutput<Key>> {
    const descriptors: Readonly<Record<string, { readonly name: string; readonly version: string }>> =
      GENERATED_CONTRACT_VERSIONS;
    const descriptor = descriptors[String(contract)];
    if (!descriptor) throw new Error(`Unknown Synex contract version: ${String(contract)}`);
    const output = await this.#transport.request(descriptor.name, descriptor.version, input);
    return output as VersionedContractOutput<Key>;
  }
}

export {
  GENERATED_CONTRACTS,
  GENERATED_CONTRACT_VERSIONS,
  GENERATED_SOURCE_HASH,
} from "./generated/contracts.js";
