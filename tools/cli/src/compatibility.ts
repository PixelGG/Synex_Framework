import { resolve } from "node:path";
import type {
  JsonSchema,
  LoadedContractCollection,
  RuntimeContractDescriptor,
} from "../../../packages/contracts/src/types.js";

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

const SCHEMA_ANNOTATION_KEYS = new Set([
  "$schema", "$id", "$comment", "title", "description", "default", "examples",
  "deprecated", "readOnly", "writeOnly",
]);
const SCHEMA_ASSERTION_KEYS = new Set([
  "type", "const", "enum", "oneOf", "anyOf", "properties", "required",
  "additionalProperties", "items", "minItems", "maxItems", "uniqueItems",
  "minLength", "maxLength", "pattern", "minimum", "maximum",
  "exclusiveMinimum", "exclusiveMaximum",
]);

function schemaTypes(schema: JsonSchema): string[] | null {
  if (!Object.hasOwn(schema, "type")) return null;
  if (typeof schema.type === "string") return [schema.type];
  if (Array.isArray(schema.type) && schema.type.every((entry) => typeof entry === "string")) {
    return [...new Set(schema.type)].sort(compareText);
  }
  return [];
}

function typeAccepts(target: string, source: string): boolean {
  return target === source || (target === "number" && source === "integer");
}

function allowedValues(schema: JsonSchema): unknown[] | null {
  let values: unknown[] | null = Array.isArray(schema.enum) ? schema.enum : null;
  if (Object.hasOwn(schema, "const")) {
    const encoded = canonicalJson(schema.const);
    values = values === null || values.some((value) => canonicalJson(value) === encoded)
      ? [schema.const]
      : [];
  }
  return values;
}

interface NumericBound {
  value: number;
  exclusive: boolean;
}

function numericBound(schema: JsonSchema, direction: "lower" | "upper"): NumericBound | null {
  const inclusiveKey = direction === "lower" ? "minimum" : "maximum";
  const exclusiveKey = direction === "lower" ? "exclusiveMinimum" : "exclusiveMaximum";
  const candidates: NumericBound[] = [];
  if (typeof schema[inclusiveKey] === "number") {
    candidates.push({ value: schema[inclusiveKey] as number, exclusive: false });
  }
  if (typeof schema[exclusiveKey] === "number") {
    candidates.push({ value: schema[exclusiveKey] as number, exclusive: true });
  }
  if (candidates.length === 0) return null;
  return candidates.reduce((selected, candidate) => {
    if (candidate.value === selected.value) {
      return { value: selected.value, exclusive: selected.exclusive || candidate.exclusive };
    }
    const candidateIsStricter = direction === "lower"
      ? candidate.value > selected.value
      : candidate.value < selected.value;
    return candidateIsStricter ? candidate : selected;
  });
}

function boundIsAtLeastAsBroad(
  target: NumericBound | null,
  source: NumericBound | null,
  direction: "lower" | "upper",
): boolean {
  if (!target) return true;
  if (!source) return false;
  if (target.value === source.value) return !target.exclusive || source.exclusive;
  return direction === "lower" ? target.value < source.value : target.value > source.value;
}

function boundedNumber(schema: JsonSchema, key: string, fallback: number): number {
  return typeof schema[key] === "number" ? schema[key] as number : fallback;
}

function schemaAcceptsEveryValue(target: JsonSchema, source: JsonSchema, depth = 0): boolean {
  if (depth > 32) return false;
  for (const key of new Set([...Object.keys(target), ...Object.keys(source)])) {
    if (!SCHEMA_ANNOTATION_KEYS.has(key) && !SCHEMA_ASSERTION_KEYS.has(key)
      && canonicalJson(target[key]) !== canonicalJson(source[key])) return false;
  }

  const targetTypes = schemaTypes(target);
  const sourceTypes = schemaTypes(source);
  if (targetTypes !== null) {
    if (sourceTypes === null || sourceTypes.length === 0 || targetTypes.length === 0) return false;
    if (!sourceTypes.every((sourceType) => targetTypes.some((targetType) => typeAccepts(targetType, sourceType)))) {
      return false;
    }
  }

  const targetValues = allowedValues(target);
  const sourceValues = allowedValues(source);
  if (targetValues !== null) {
    if (sourceValues === null) return false;
    const accepted = new Set(targetValues.map(canonicalJson));
    if (!sourceValues.every((value) => accepted.has(canonicalJson(value)))) return false;
  }

  for (const keyword of ["oneOf", "anyOf"] as const) {
    const targetValue = target[keyword];
    const sourceValue = source[keyword];
    if (targetValue === undefined) continue;
    if (sourceValue === undefined || canonicalJson(targetValue) !== canonicalJson(sourceValue)) return false;
  }

  if (!boundIsAtLeastAsBroad(numericBound(target, "lower"), numericBound(source, "lower"), "lower")
    || !boundIsAtLeastAsBroad(numericBound(target, "upper"), numericBound(source, "upper"), "upper")) {
    return false;
  }
  for (const [minimum, maximum] of [
    ["minLength", "maxLength"],
    ["minItems", "maxItems"],
  ] as const) {
    if (boundedNumber(target, minimum, 0) > boundedNumber(source, minimum, 0)
      || boundedNumber(target, maximum, Number.POSITIVE_INFINITY)
        < boundedNumber(source, maximum, Number.POSITIVE_INFINITY)) return false;
  }
  if (target.uniqueItems === true && source.uniqueItems !== true) return false;
  if (target.pattern !== undefined
    && (source.pattern === undefined || target.pattern !== source.pattern)) return false;

  if (target.items !== undefined) {
    if (!isRecord(target.items) || !isRecord(source.items)
      || !schemaAcceptsEveryValue(target.items, source.items, depth + 1)) return false;
  }

  const targetProperties = isRecord(target.properties) ? target.properties : {};
  const sourceProperties = isRecord(source.properties) ? source.properties : {};
  const targetRequired = new Set(
    Array.isArray(target.required) ? target.required.filter((entry): entry is string => typeof entry === "string") : [],
  );
  const sourceRequired = new Set(
    Array.isArray(source.required) ? source.required.filter((entry): entry is string => typeof entry === "string") : [],
  );
  if (![...targetRequired].every((name) => sourceRequired.has(name))) return false;

  const targetAdditional = target.additionalProperties !== false;
  const sourceAdditional = source.additionalProperties !== false;
  if (!targetAdditional && sourceAdditional) return false;
  for (const [name, sourceProperty] of Object.entries(sourceProperties)) {
    if (!isRecord(sourceProperty)) return false;
    const targetProperty = targetProperties[name];
    if (targetProperty === undefined) {
      if (!targetAdditional) return false;
    } else if (!isRecord(targetProperty)
      || !schemaAcceptsEveryValue(targetProperty, sourceProperty, depth + 1)) return false;
  }
  if (sourceAdditional) {
    for (const [name, targetProperty] of Object.entries(targetProperties)) {
      if (!Object.hasOwn(sourceProperties, name)
        && (!isRecord(targetProperty) || !schemaAcceptsEveryValue(targetProperty, {}, depth + 1))) return false;
    }
  }
  return true;
}

function compareSchema(
  contract: string,
  label: "input" | "output",
  previous: JsonSchema,
  current: JsonSchema,
): ContractCompatibilityChange[] {
  const compatible = label === "input"
    ? schemaAcceptsEveryValue(current, previous)
    : schemaAcceptsEveryValue(previous, current);
  if (!compatible) {
    return [{ level: "breaking", contract, message: `${label} schema is not backward compatible.` }];
  }
  return canonicalJson(previous) === canonicalJson(current)
    ? []
    : [{ level: "non-breaking", contract, message: `${label} schema changed compatibly.` }];
}

export function compareContracts(
  previousSources: LoadedContractCollection[],
  currentSources: LoadedContractCollection[],
): ContractCompatibilityChange[] {
  const group = (sources: LoadedContractCollection[]): Map<string, Map<string, RuntimeContractDescriptor>> => {
    const grouped = new Map<string, Map<string, RuntimeContractDescriptor>>();
    for (const contract of flattenContracts(sources)) {
      const versions = grouped.get(contract.name) ?? new Map<string, RuntimeContractDescriptor>();
      versions.set(contract.version, contract);
      grouped.set(contract.name, versions);
    }
    return grouped;
  };
  const compareDefinition = (
    identity: string,
    previous: RuntimeContractDescriptor,
    current: RuntimeContractDescriptor,
  ): ContractCompatibilityChange[] => {
    const definitionChanges: ContractCompatibilityChange[] = [];
    for (const property of ["kind", "provider", "network", "capability"] as const) {
      if ((previous[property] ?? null) !== (current[property] ?? null)) {
        definitionChanges.push({ level: "breaking", contract: identity, message: `${property} changed.` });
      }
    }
    if ((previous.idempotent === true) !== (current.idempotent === true)) {
      definitionChanges.push({ level: "breaking", contract: identity, message: "idempotent behavior changed." });
    }
    const previousStates = previous.sessionStates ?? [];
    const currentStates = current.sessionStates ?? [];
    const previousUnrestricted = previousStates.length === 0;
    const currentUnrestricted = currentStates.length === 0;
    if (!currentUnrestricted && (previousUnrestricted
      || previousStates.some((state) => !currentStates.includes(state)))) {
      definitionChanges.push({ level: "breaking", contract: identity, message: "sessionStates were narrowed." });
    } else if (canonicalJson(previousStates) !== canonicalJson(currentStates)) {
      definitionChanges.push({ level: "non-breaking", contract: identity, message: "sessionStates were widened." });
    }
    const previousRate = previous.rateLimit;
    const currentRate = current.rateLimit;
    if (currentRate && (!previousRate || currentRate.capacity < previousRate.capacity
      || currentRate.refillPerSecond < previousRate.refillPerSecond)) {
      definitionChanges.push({ level: "breaking", contract: identity, message: "rateLimit was narrowed." });
    } else if (canonicalJson(previousRate ?? null) !== canonicalJson(currentRate ?? null)) {
      definitionChanges.push({ level: "non-breaking", contract: identity, message: "rateLimit was widened." });
    }
    definitionChanges.push(...compareSchema(identity, "input", previous.input, current.input));
    definitionChanges.push(...compareSchema(identity, "output", previous.output, current.output));
    const previousErrors = new Set(previous.errors);
    const currentErrors = new Set(current.errors);
    for (const error of currentErrors) {
      if (!previousErrors.has(error)) {
        definitionChanges.push({ level: "breaking", contract: identity, message: `Error ${error} was added.` });
      }
    }
    for (const error of previousErrors) {
      if (!currentErrors.has(error)) {
        definitionChanges.push({ level: "non-breaking", contract: identity, message: `Error ${error} was removed.` });
      }
    }
    return definitionChanges;
  };
  const previous = group(previousSources);
  const current = group(currentSources);
  const changes: ContractCompatibilityChange[] = [];

  for (const [name, previousVersions] of previous) {
    const currentVersions = current.get(name);
    for (const [version, previousContract] of previousVersions) {
      const identity = `${name}@${version}`;
      const currentContract = currentVersions?.get(version);
      if (!currentContract) {
        changes.push({ level: "breaking", contract: identity, message: "Contract version was removed." });
        continue;
      }
      if (canonicalJson(previousContract) !== canonicalJson(currentContract)) {
        changes.push(...compareDefinition(identity, previousContract, currentContract));
        changes.push({
          level: "breaking",
          contract: identity,
          message: "Published contract versions are immutable; publish a new semantic version instead.",
        });
      }
    }
  }

  for (const [name, currentVersions] of current) {
    const previousVersions = previous.get(name);
    for (const [version, currentContract] of currentVersions) {
      if (previousVersions?.has(version)) continue;
      const identity = `${name}@${version}`;
      const parsedCurrent = parseVersion(version);
      let previousSameMajor: RuntimeContractDescriptor | null = null;
      let parsedPreviousSameMajor = null as ReturnType<typeof parseVersion>;
      if (parsedCurrent && previousVersions) {
        for (const candidate of previousVersions.values()) {
          const parsedCandidate = parseVersion(candidate.version);
          if (!parsedCandidate || parsedCandidate.major !== parsedCurrent.major
            || compareVersion(parsedCandidate, parsedCurrent) >= 0) continue;
          if (!parsedPreviousSameMajor || compareVersion(parsedCandidate, parsedPreviousSameMajor) > 0) {
            previousSameMajor = candidate;
            parsedPreviousSameMajor = parsedCandidate;
          }
        }
      }
      if (previousSameMajor) {
        const versionChanges = compareDefinition(identity, previousSameMajor, currentContract);
        changes.push(...versionChanges);
        if (versionChanges.some((change) => change.level === "breaking")) {
          changes.push({
            level: "breaking",
            contract: identity,
            message: "Breaking changes require a higher major version.",
          });
          continue;
        }
      }
      changes.push({ level: "non-breaking", contract: identity, message: "Contract version was added." });
    }
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
