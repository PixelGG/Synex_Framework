import { Ajv2020 } from "ajv/dist/2020.js";
import { readFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import type {
  ContractCollection,
  ContractDefinition,
  JsonSchema,
  LoadedContractCollection,
  RuntimeContractDescriptor,
  RuntimeContractRegistry,
} from "../../../packages/contracts/src/types.js";

import type { Diagnostic, GeneratedArtifactResult } from "./types.ts";
import { CliError } from "./errors.ts";
import {
  canonicalize,
  canonicalJson,
  compareText,
  displayPath,
  isDirectory,
  isRecord,
  prettyJson,
  readJsonFile,
  sha256,
  walkFiles,
  writeFileAtomic,
} from "./filesystem.ts";
import type { SchemaRegistry } from "./schemas.ts";
import { loadSchemaRegistry, schemaDiagnostics } from "./schemas.ts";
import { formatDiagnostic } from "./diagnostics.ts";
import { compareVersion, parseVersion } from "./semver.ts";

const MANAGED_ARTIFACTS = Object.freeze({
  lua: "packages/contracts/generated/lua/contracts.lua",
  sdkLua: "packages/sdk-lua/generated/contracts.lua",
  coreLua: "core/synex_core/shared/generated_contracts.lua",
  runtime: "packages/contracts/generated/runtime/contracts.json",
  docs: "packages/contracts/generated/docs/contracts.md",
  typescript: "packages/sdk-ts/src/generated/contracts.ts",
});

function isContractCollection(value: unknown): value is ContractCollection {
  return isRecord(value) && value.schema === 1 && typeof value.domain === "string" && Array.isArray(value.contracts);
}

function isContractDefinitionFile(path: string): boolean {
  return path.endsWith(".contract.json") || path.endsWith(".contracts.json");
}

function normalizedContractCollections(sources: LoadedContractCollection[]): ContractCollection[] {
  return sources
    .map(({ collection }) => ({
      schema: 1 as const,
      domain: collection.domain,
      contracts: [...collection.contracts].sort((left, right) => {
        const byName = compareText(left.name, right.name);
        return byName !== 0 ? byName : compareText(left.version, right.version);
      }),
    }))
    .sort((left, right) => compareText(left.domain, right.domain));
}

async function contractSearchRoots(repositoryRoot: string): Promise<string[]> {
  const candidates = [
    "packages/contracts/definitions",
    "resources",
    "core",
    "libraries",
    "examples",
  ].map((path) => join(repositoryRoot, path));
  const roots: string[] = [];
  for (const candidate of candidates) {
    if (await isDirectory(candidate)) roots.push(candidate);
  }
  return roots;
}

export async function loadContractSources(
  repositoryRoot: string,
  registry?: SchemaRegistry,
  explicitRoot?: string,
): Promise<{ sources: LoadedContractCollection[]; diagnostics: Diagnostic[] }> {
  const schemas = registry ?? (await loadSchemaRegistry(repositoryRoot));
  if (explicitRoot && !(await isDirectory(explicitRoot))) {
    throw new CliError("Contract source path is not a directory.", 2);
  }
  const roots = explicitRoot ? [resolve(explicitRoot)] : await contractSearchRoots(repositoryRoot);
  const files = (
    await Promise.all(
      roots.map((root) =>
        walkFiles(root, isContractDefinitionFile),
      ),
    )
  )
    .flat()
    .sort(compareText);
  const diagnostics: Diagnostic[] = [];
  const sources: LoadedContractCollection[] = [];
  const names = new Map<string, string>();

  for (const file of files) {
    let value: unknown;
    try {
      value = await readJsonFile(file);
    } catch (error) {
      diagnostics.push({
        level: "error",
        rule: "contract-json",
        file: displayPath(repositoryRoot, file),
        message: error instanceof Error ? error.message : "Contract JSON could not be read.",
      });
      continue;
    }

    if (!schemas.contract(value) || !isContractCollection(value)) {
      diagnostics.push(
        ...schemaDiagnostics(schemas.contract.errors, file, repositoryRoot, "contract-schema"),
      );
      continue;
    }

    let nestedSchemasValid = true;
    for (const contract of value.contracts) {
      for (const [direction, schema] of [
        ["input", contract.input],
        ["output", contract.output],
      ] as const) {
        try {
          // Contract payload schemas are independent documents. A fresh Ajv
          // instance avoids collisions when two payloads intentionally reuse
          // the same local `$id`.
          new Ajv2020({ allErrors: true, strict: true, validateFormats: false }).compile(schema);
        } catch {
          nestedSchemasValid = false;
          diagnostics.push({
            level: "error",
            rule: "contract-json-schema",
            file: displayPath(repositoryRoot, file),
            message: `${contract.name} ${direction} is not a valid JSON Schema.`,
          });
        }
      }

      const contractIdentity = `${contract.name}@${contract.version}`;
      const previous = names.get(contractIdentity);
      if (previous) {
        diagnostics.push({
          level: "error",
          rule: "contract-name-unique",
          file: displayPath(repositoryRoot, file),
          message: `Contract ${contractIdentity} is already defined in ${previous}.`,
        });
      } else {
        names.set(contractIdentity, displayPath(repositoryRoot, file));
      }
    }

    if (nestedSchemasValid) {
      sources.push({
        file,
        relativeFile: displayPath(repositoryRoot, file),
        collection: value,
      });
    }
  }

  sources.sort((left, right) => compareText(left.relativeFile, right.relativeFile));
  return { sources, diagnostics };
}

export function flattenContracts(sources: LoadedContractCollection[]): RuntimeContractDescriptor[] {
  return normalizedContractCollections(sources)
    .flatMap((collection) =>
      collection.contracts.map((contract) => ({ domain: collection.domain, ...contract })),
    )
    .sort((left, right) => compareText(left.name, right.name));
}

function schemaType(schema: JsonSchema, depth = 0): string {
  if (depth > 12) return "unknown";
  if (Array.isArray(schema.enum) && schema.enum.length > 0) {
    return schema.enum.map((value) => JSON.stringify(value)).join(" | ");
  }
  if (Object.hasOwn(schema, "const")) return JSON.stringify(schema.const);
  for (const union of ["oneOf", "anyOf"] as const) {
    const options = schema[union];
    if (Array.isArray(options) && options.length > 0) {
      return options
        .filter(isRecord)
        .map((entry) => schemaType(entry, depth + 1))
        .join(" | ") || "unknown";
    }
  }

  const type = schema.type;
  if (Array.isArray(type)) {
    return type
      .map((entry) => schemaType({ ...schema, type: entry }, depth + 1))
      .join(" | ");
  }
  if (type === "string") return "string";
  if (type === "number" || type === "integer") return "number";
  if (type === "boolean") return "boolean";
  if (type === "null") return "null";
  if (type === "array") {
    return `Array<${isRecord(schema.items) ? schemaType(schema.items, depth + 1) : "unknown"}>`;
  }
  if (type === "object" || isRecord(schema.properties)) {
    const properties = isRecord(schema.properties) ? schema.properties : {};
    const required = new Set(Array.isArray(schema.required) ? schema.required.filter((value): value is string => typeof value === "string") : []);
    const fields = Object.keys(properties)
      .sort(compareText)
      .map((name) => {
        const property = properties[name];
        const propertyType = isRecord(property) ? schemaType(property, depth + 1) : "unknown";
        return `${JSON.stringify(name)}${required.has(name) ? "" : "?"}: ${propertyType};`;
      });
    if (schema.additionalProperties !== false) {
      const additionalType = isRecord(schema.additionalProperties)
        ? schemaType(schema.additionalProperties, depth + 1)
        : "unknown";
      fields.push(`[key: string]: ${additionalType};`);
    }
    return fields.length > 0 ? `{ ${fields.join(" ")} }` : "Record<string, never>";
  }
  if (Array.isArray(schema.allOf) && schema.allOf.length > 0) {
    return schema.allOf
      .filter(isRecord)
      .map((entry) => schemaType(entry, depth + 1))
      .join(" & ") || "unknown";
  }
  return "unknown";
}

function contractTypePrefix(contract: ContractDefinition): string {
  const parts = contract.name.split(/[^A-Za-z0-9]+/u).filter(Boolean);
  return parts.map((part) => `${part.charAt(0).toUpperCase()}${part.slice(1)}`).join("");
}

function contractIdentity(contract: Pick<ContractDefinition, "name" | "version">): string {
  return `${contract.name}@${contract.version}`;
}

function contractTypePrefixes(contracts: RuntimeContractDescriptor[]): Map<string, string> {
  const baseNames = new Map<string, string>();
  const collisions = new Map<string, number>();
  for (const contract of contracts) {
    const baseName = contractTypePrefix(contract);
    baseNames.set(contractIdentity(contract), baseName);
    collisions.set(baseName, (collisions.get(baseName) ?? 0) + 1);
  }
  return new Map(
    contracts.map((contract) => {
      const identity = contractIdentity(contract);
      const baseName = baseNames.get(identity) ?? "Contract";
      const suffix = (collisions.get(baseName) ?? 0) > 1 ? sha256(identity).slice(0, 8) : "";
      return [identity, `${baseName}${suffix}`] as const;
    }),
  );
}

function latestContracts(contracts: RuntimeContractDescriptor[]): RuntimeContractDescriptor[] {
  const latest = new Map<string, RuntimeContractDescriptor>();
  for (const contract of contracts) {
    const current = latest.get(contract.name);
    const candidateVersion = parseVersion(contract.version);
    const currentVersion = current ? parseVersion(current.version) : null;
    if (!current || !currentVersion || (candidateVersion && compareVersion(candidateVersion, currentVersion) > 0)) {
      latest.set(contract.name, contract);
    }
  }
  return [...latest.values()].sort((left, right) => compareText(left.name, right.name));
}

function renderTypeScriptContracts(registry: RuntimeContractRegistry): string {
  const typePrefixes = contractTypePrefixes(registry.contracts);
  const latest = latestContracts(registry.contracts);
  const lines = [
    `export const GENERATED_SOURCE_HASH = ${JSON.stringify(registry.sourceHash)};`,
    "",
    "export const GENERATED_CONTRACT_VERSIONS = {",
  ];

  for (const contract of registry.contracts) {
    lines.push(
      `  ${JSON.stringify(contractIdentity(contract))}: { name: ${JSON.stringify(contract.name)}, version: ${JSON.stringify(contract.version)}, kind: ${JSON.stringify(contract.kind)}, provider: ${JSON.stringify(contract.provider)} },`,
    );
  }
  lines.push("} as const;", "", "export const GENERATED_CONTRACTS = {");

  for (const contract of latest) {
    lines.push(
      `  ${JSON.stringify(contract.name)}: GENERATED_CONTRACT_VERSIONS[${JSON.stringify(contractIdentity(contract))}],`,
    );
  }
  lines.push("} as const;", "");

  for (const contract of registry.contracts) {
    const prefix = typePrefixes.get(contractIdentity(contract)) ?? contractTypePrefix(contract);
    const errors = contract.errors.length > 0 ? contract.errors.map((error) => JSON.stringify(error)).join(" | ") : "never";
    lines.push(
      `export type ${prefix}Input = ${schemaType(contract.input)};`,
      `export type ${prefix}Output = ${schemaType(contract.output)};`,
      `export type ${prefix}Error = ${errors};`,
      "",
    );
  }

  lines.push("export interface GeneratedVersionedContractMap {");
  for (const contract of registry.contracts) {
    const prefix = typePrefixes.get(contractIdentity(contract)) ?? contractTypePrefix(contract);
    lines.push(
      `  ${JSON.stringify(contractIdentity(contract))}: { input: ${prefix}Input; output: ${prefix}Output; error: ${prefix}Error };`,
    );
  }
  lines.push("}", "", "export interface GeneratedContractMap {");
  for (const contract of latest) {
    const prefix = typePrefixes.get(contractIdentity(contract)) ?? contractTypePrefix(contract);
    lines.push(
      `  ${JSON.stringify(contract.name)}: { input: ${prefix}Input; output: ${prefix}Output; error: ${prefix}Error };`,
    );
  }
  lines.push("}", "");
  return lines.join("\n");
}

function renderLuaSdkContracts(registry: RuntimeContractRegistry): string {
  const versions: Record<string, { name: string; version: string; kind: string; provider: string }> = {};
  const latest: Record<string, { name: string; version: string; kind: string; provider: string }> = {};
  for (const contract of registry.contracts) {
    const descriptor = {
      name: contract.name,
      version: contract.version,
      kind: contract.kind,
      provider: contract.provider,
    };
    versions[contractIdentity(contract)] = descriptor;
  }
  for (const contract of latestContracts(registry.contracts)) {
    latest[contract.name] = versions[contractIdentity(contract)]!;
  }
  return `SynexLuaGeneratedContracts = ${luaValue({ sourceHash: registry.sourceHash, latest, versions })}\nreturn SynexLuaGeneratedContracts\n`;
}

function luaString(value: string): string {
  return `"${value
    .replace(/\\/gu, "\\\\")
    .replace(/"/gu, '\\"')
    .replace(/\r/gu, "\\r")
    .replace(/\n/gu, "\\n")
    .replace(/\t/gu, "\\t")
    .replace(/[\u0000-\u001f\u007f]/gu, (character) => `\\${character.codePointAt(0)?.toString().padStart(3, "0") ?? "000"}`)}"`;
}

function luaValue(value: unknown, depth = 0): string {
  if (value === null) return "nil";
  if (typeof value === "string") return luaString(value);
  if (typeof value === "number" || typeof value === "boolean") return String(value);
  if (Array.isArray(value)) {
    if (value.length === 0) return "{}";
    const indent = "  ".repeat(depth + 1);
    return `{\n${value.map((entry) => `${indent}${luaValue(entry, depth + 1)}`).join(",\n")}\n${"  ".repeat(depth)}}`;
  }
  if (isRecord(value)) {
    const keys = Object.keys(value).sort(compareText);
    if (keys.length === 0) return "{}";
    const indent = "  ".repeat(depth + 1);
    return `{\n${keys
      .map((key) => `${indent}[${luaString(key)}] = ${luaValue(value[key], depth + 1)}`)
      .join(",\n")}\n${"  ".repeat(depth)}}`;
  }
  throw new CliError("Contract data contains a value that cannot be emitted to Lua.");
}

function markdownCell(value: string): string {
  return value.replace(/\|/gu, "\\|").replace(/`/gu, "'").replace(/\r?\n/gu, " ");
}

function renderContractDocs(registry: RuntimeContractRegistry): string {
  const lines = [
    "# Synex Contract Reference",
    "",
    `Source hash: \`${registry.sourceHash}\``,
    "",
  ];
  if (registry.contracts.length === 0) {
    lines.push("No contract definitions are currently registered.", "");
    return lines.join("\n");
  }

  lines.push(
    "| Contract | Version | Kind | Provider | Network | Stability | Capability |",
    "| --- | --- | --- | --- | --- | --- | --- |",
  );
  for (const contract of registry.contracts) {
    lines.push(
      `| \`${markdownCell(contract.name)}\` | \`${contract.version}\` | ${contract.kind} | \`${contract.provider}\` | ${contract.network} | ${contract.stability} | ${contract.capability ? `\`${markdownCell(contract.capability)}\`` : "—"} |`,
    );
  }
  lines.push("");

  for (const contract of registry.contracts) {
    lines.push(
      `## \`${contract.name}\``,
      "",
      `- Version: \`${contract.version}\``,
      `- Provider: \`${contract.provider}\``,
      `- Idempotent: ${contract.idempotent === true ? "yes" : "no"}`,
      `- Errors: ${contract.errors.length > 0 ? contract.errors.map((error) => `\`${error}\``).join(", ") : "none"}`,
      "",
      "### Input",
      "",
      "```json",
      JSON.stringify(canonicalize(contract.input), null, 2),
      "```",
      "",
      "### Output",
      "",
      "```json",
      JSON.stringify(canonicalize(contract.output), null, 2),
      "```",
      "",
    );
  }
  return `${lines.join("\n").trimEnd()}\n`;
}

export function renderContractArtifacts(
  repositoryRoot: string,
  sources: LoadedContractCollection[],
): { registry: RuntimeContractRegistry; artifacts: Map<string, string> } {
  const normalized = normalizedContractCollections(sources);
  const sourceHash = sha256(canonicalJson(normalized));
  const registry: RuntimeContractRegistry = {
    schema: 1,
    sourceHash,
    contracts: flattenContracts(sources),
  };
  const artifacts = new Map<string, string>([
    [join(repositoryRoot, MANAGED_ARTIFACTS.runtime), prettyJson(registry)],
    [join(repositoryRoot, MANAGED_ARTIFACTS.lua), `return ${luaValue(registry)}\n`],
    [join(repositoryRoot, MANAGED_ARTIFACTS.sdkLua), renderLuaSdkContracts(registry)],
    [join(repositoryRoot, MANAGED_ARTIFACTS.coreLua), `SynexGeneratedContracts = ${luaValue(registry)}\n`],
    [join(repositoryRoot, MANAGED_ARTIFACTS.docs), renderContractDocs(registry)],
    [join(repositoryRoot, MANAGED_ARTIFACTS.typescript), renderTypeScriptContracts(registry)],
  ]);
  return { registry, artifacts };
}


export async function generateContracts(
  repositoryRoot: string,
  checkOnly: boolean,
): Promise<GeneratedArtifactResult> {
  const schemas = await loadSchemaRegistry(repositoryRoot);
  const loaded = await loadContractSources(repositoryRoot, schemas);
  const errors = loaded.diagnostics.filter((diagnostic) => diagnostic.level === "error");
  if (errors.length > 0) {
    throw new CliError(`Contract validation failed:\n${errors.map(formatDiagnostic).join("\n")}`);
  }

  const rendered = renderContractArtifacts(repositoryRoot, loaded.sources);
  const changed: string[] = [];
  for (const [path, contents] of rendered.artifacts) {
    let current: string | null = null;
    try {
      current = await readFile(path, "utf8");
    } catch {
      current = null;
    }
    if (current === contents) continue;
    changed.push(displayPath(repositoryRoot, path));
    if (!checkOnly) await writeFileAtomic(path, contents);
  }

  return {
    sourceHash: rendered.registry.sourceHash,
    contractCount: rendered.registry.contracts.length,
    changed,
    stale: checkOnly ? changed : [],
  };
}
