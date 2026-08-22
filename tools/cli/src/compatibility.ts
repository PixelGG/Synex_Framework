import { resolve } from "node:path";
import type { JsonSchema, LoadedContractCollection } from "../../../packages/contracts/src/types.js";

import {
  canonicalJson,
  compareText,
  displayPath,
  isRecord,
  readTextFile,
  walkFiles,
} from "./filesystem.ts";
import { flattenContracts } from "./contracts.ts";
import { compareVersion, parseVersion } from "./semver.ts";

export interface ContractCompatibilityChange {
  level: "breaking" | "non-breaking" | "informational";
  contract: string;
  message: string;
}

function propertyMap(schema: JsonSchema): Map<string, JsonSchema> {
  if (!isRecord(schema.properties)) return new Map();
  return new Map(
    Object.entries(schema.properties)
      .filter((entry): entry is [string, JsonSchema] => isRecord(entry[1]))
      .sort(([left], [right]) => compareText(left, right)),
  );
}

function schemaTypeFingerprint(schema: JsonSchema): string {
  const relevant = {
    type: schema.type,
    enum: schema.enum,
    const: schema.const,
    oneOf: schema.oneOf,
    anyOf: schema.anyOf,
    allOf: schema.allOf,
    items: schema.items,
  };
  return canonicalJson(relevant);
}

function compareSchema(
  contract: string,
  label: "input" | "output",
  previous: JsonSchema,
  current: JsonSchema,
): ContractCompatibilityChange[] {
  const changes: ContractCompatibilityChange[] = [];
  if (schemaTypeFingerprint(previous) !== schemaTypeFingerprint(current)) {
    changes.push({
      level: "breaking",
      contract,
      message: `${label} type constraints changed.`,
    });
  }

  const previousProperties = propertyMap(previous);
  const currentProperties = propertyMap(current);
  const previousRequired = new Set(
    Array.isArray(previous.required) ? previous.required.filter((value): value is string => typeof value === "string") : [],
  );
  const currentRequired = new Set(
    Array.isArray(current.required) ? current.required.filter((value): value is string => typeof value === "string") : [],
  );

  for (const [name, oldProperty] of previousProperties) {
    const newProperty = currentProperties.get(name);
    if (!newProperty) {
      changes.push({ level: "breaking", contract, message: `${label} field ${name} was removed.` });
    } else if (schemaTypeFingerprint(oldProperty) !== schemaTypeFingerprint(newProperty)) {
      changes.push({ level: "breaking", contract, message: `${label} field ${name} changed type.` });
    }
  }
  for (const [name] of currentProperties) {
    if (!previousProperties.has(name)) {
      changes.push({
        level: currentRequired.has(name) ? "breaking" : "non-breaking",
        contract,
        message: `${currentRequired.has(name) ? "Required" : "Optional"} ${label} field ${name} was added.`,
      });
    }
  }
  for (const name of currentRequired) {
    if (!previousRequired.has(name) && previousProperties.has(name)) {
      changes.push({ level: "breaking", contract, message: `${label} field ${name} became required.` });
    }
  }
  return changes;
}

export function compareContracts(
  previousSources: LoadedContractCollection[],
  currentSources: LoadedContractCollection[],
): ContractCompatibilityChange[] {
  const previous = new Map(flattenContracts(previousSources).map((contract) => [contract.name, contract]));
  const current = new Map(flattenContracts(currentSources).map((contract) => [contract.name, contract]));
  const changes: ContractCompatibilityChange[] = [];

  for (const [name, oldContract] of previous) {
    const nextContract = current.get(name);
    if (!nextContract) {
      changes.push({ level: "breaking", contract: name, message: "Contract was removed." });
      continue;
    }
    for (const property of ["kind", "provider", "network", "capability"] as const) {
      if ((oldContract[property] ?? null) !== (nextContract[property] ?? null)) {
        changes.push({ level: "breaking", contract: name, message: `${property} changed.` });
      }
    }
    changes.push(...compareSchema(name, "input", oldContract.input, nextContract.input));
    changes.push(...compareSchema(name, "output", oldContract.output, nextContract.output));

    const oldErrors = new Set(oldContract.errors);
    const nextErrors = new Set(nextContract.errors);
    for (const error of oldErrors) {
      if (!nextErrors.has(error)) changes.push({ level: "breaking", contract: name, message: `Error ${error} was removed.` });
    }
    for (const error of nextErrors) {
      if (!oldErrors.has(error)) changes.push({ level: "non-breaking", contract: name, message: `Error ${error} was added.` });
    }

    const oldVersion = parseVersion(oldContract.version);
    const nextVersion = parseVersion(nextContract.version);
    if (oldVersion && nextVersion && compareVersion(nextVersion, oldVersion) < 0) {
      changes.push({ level: "breaking", contract: name, message: "Contract version moved backwards." });
    }
    const hasBreaking = changes.some((change) => change.contract === name && change.level === "breaking");
    if (hasBreaking && oldVersion && nextVersion && nextVersion.major <= oldVersion.major) {
      changes.push({
        level: "breaking",
        contract: name,
        message: "Breaking changes require a higher major version.",
      });
    }
  }
  for (const [name] of current) {
    if (!previous.has(name)) changes.push({ level: "non-breaking", contract: name, message: "Contract was added." });
  }

  return changes.sort((left, right) => {
    const byContract = compareText(left.contract, right.contract);
    return byContract !== 0 ? byContract : compareText(left.message, right.message);
  });
}

interface CompatibilityFinding {
  framework: "synex" | "qbcore" | "qbx" | "esx" | "vrp" | "ox_core";
  file: string;
  line: number;
  signal: string;
  migrationNote: string;
}

interface CompatibilityReport {
  target: string;
  filesScanned: number;
  signatureCounts: Record<CompatibilityFinding["framework"], number>;
  findings: CompatibilityFinding[];
  disclaimer: string;
}

const COMPATIBILITY_PATTERNS: Array<{
  framework: CompatibilityFinding["framework"];
  pattern: RegExp;
  signal: string;
  migrationNote: string;
}> = [
  { framework: "synex", pattern: /(?:exports[\[.]?["']?synex_core|\bSynex\.)/u, signal: "Native Synex API", migrationNote: "No bridge indicated by this signal." },
  { framework: "qbcore", pattern: /(?:\bQBCore\b|qb-core)/iu, signal: "QBCore API", migrationNote: "Review the QB bridge matrix and mutable PlayerData assumptions." },
  { framework: "qbx", pattern: /(?:qbx_core|\bQBX\b)/iu, signal: "Qbox API", migrationNote: "Use the QBX-specific bridge; do not treat it as identical to QBCore." },
  { framework: "esx", pattern: /(?:\bESX\b|es_extended|\bxPlayer\b)/u, signal: "ESX API", migrationNote: "Review xPlayer, callback, account, and job mappings." },
  { framework: "vrp", pattern: /(?:\bvRP\b|Tunnel\.bindInterface|Proxy\.getInterface)/u, signal: "vRP API", migrationNote: "Review extension and Tunnel semantics manually." },
  { framework: "ox_core", pattern: /(?:ox_core|OxPlayer|OxAccount)/u, signal: "ox_core API", migrationNote: "Review relational domain and group/account mappings." },
];

export async function scanCompatibility(
  repositoryRoot: string,
  target = repositoryRoot,
): Promise<CompatibilityReport> {
  const files = await walkFiles(resolve(target), (path) => path.endsWith(".lua"), { skipTopLevelTests: true });
  const findings: CompatibilityFinding[] = [];
  const counts: CompatibilityReport["signatureCounts"] = {
    synex: 0,
    qbcore: 0,
    qbx: 0,
    esx: 0,
    vrp: 0,
    ox_core: 0,
  };

  for (const file of files) {
    let text: string;
    try {
      text = await readTextFile(file);
    } catch {
      continue;
    }
    const lines = text.replace(/\r\n?/gu, "\n").split("\n");
    for (let index = 0; index < lines.length; index += 1) {
      const line = lines[index] ?? "";
      for (const definition of COMPATIBILITY_PATTERNS) {
        if (!definition.pattern.test(line)) continue;
        counts[definition.framework] += 1;
        findings.push({
          framework: definition.framework,
          file: displayPath(repositoryRoot, file),
          line: index + 1,
          signal: definition.signal,
          migrationNote: definition.migrationNote,
        });
      }
    }
  }

  return {
    target: displayPath(repositoryRoot, resolve(target)),
    filesScanned: files.length,
    signatureCounts: counts,
    findings,
    disclaimer: "Signature detection identifies APIs for migration review; it does not prove behavioral compatibility.",
  };
}
