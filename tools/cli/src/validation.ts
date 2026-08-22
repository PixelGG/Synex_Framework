import { basename, dirname, join, resolve } from "node:path";

import type { Diagnostic } from "./types.ts";
import { CliError } from "./errors.ts";
import {
  compareText,
  containsPath,
  displayPath,
  isDirectory,
  isRecord,
  pathExists,
  readJsonFile,
  readTextFile,
  resolveWithin,
  walkFiles,
} from "./filesystem.ts";
import type { SchemaRegistry } from "./schemas.ts";
import {
  configurationSemanticDiagnostics,
  loadSchemaRegistry,
  schemaDiagnostics,
} from "./schemas.ts";
import { flattenContracts, loadContractSources } from "./contracts.ts";
import { parseVersion, satisfiesVersionRange } from "./semver.ts";

export interface ResourceManifest {
  schema: number;
  name: string;
  version: string;
  synex: string;
  critical: boolean;
  capabilities: { request: string[] };
  services: { provide: string[]; require: string[]; optional: string[] };
  contracts: { provide: string[]; consume: string[] };
  dependencies: {
    required: Array<{ name: string; version: string }>;
    optional: Array<{ name: string; version: string }>;
    development: Array<{ name: string; version: string }>;
  };
  migrations: Array<{ id: string; path: string; transactional: boolean }>;
  dataOwnership: { tables: string[]; characterDelete: string };
  stateSnapshot: { supported: boolean; schemaVersion: number };
}

export interface LoadedResourceManifest {
  file: string;
  directory: string;
  manifest: ResourceManifest;
}

export interface ValidationReport {
  target: string;
  filesChecked: number;
  resources: number;
  contracts: number;
  states: number;
  diagnostics: Diagnostic[];
}

export type FxmanifestVersionStatus = "valid" | "missing" | "invalid" | "ambiguous";

export interface FxmanifestResourceMetadata {
  name: string;
  directory: string;
  files: string[];
  version: string | null;
  versionStatus: FxmanifestVersionStatus;
}

export function parseFxmanifestVersionMetadata(text: string): {
  version: string | null;
  status: FxmanifestVersionStatus;
} {
  const values = [...text.matchAll(/\bversion\s+["']([^"']+)["']/gu)]
    .map((match) => match[1] ?? "");
  if (values.length === 0) return { version: null, status: "missing" };
  if (values.length > 1) return { version: null, status: "ambiguous" };
  const version = values[0] ?? "";
  return parseVersion(version)
    ? { version, status: "valid" }
    : { version, status: "invalid" };
}

export async function loadFxmanifestResourceMetadata(
  repositoryRoot: string,
): Promise<Map<string, FxmanifestResourceMetadata>> {
  const files = await walkFiles(resolve(repositoryRoot), (path) => basename(path) === "fxmanifest.lua");
  const inventory = new Map<string, FxmanifestResourceMetadata>();
  for (const file of files) {
    const name = basename(dirname(file));
    let parsed: ReturnType<typeof parseFxmanifestVersionMetadata>;
    try {
      parsed = parseFxmanifestVersionMetadata(await readTextFile(file));
    } catch {
      parsed = { version: null, status: "invalid" };
    }
    const previous = inventory.get(name);
    if (previous) {
      inventory.set(name, {
        name,
        directory: previous.directory,
        files: [...previous.files, file].sort(compareText),
        version: null,
        versionStatus: "ambiguous",
      });
    } else {
      inventory.set(name, {
        name,
        directory: dirname(file),
        files: [file],
        version: parsed.version,
        versionStatus: parsed.status,
      });
    }
  }
  return inventory;
}

export function isResourceManifest(value: unknown): value is ResourceManifest {
  return (
    isRecord(value) &&
    typeof value.name === "string" &&
    typeof value.version === "string" &&
    isRecord(value.capabilities) &&
    isRecord(value.services) &&
    isRecord(value.contracts) &&
    isRecord(value.dependencies) &&
    Array.isArray(value.migrations) &&
    isRecord(value.dataOwnership) &&
    isRecord(value.stateSnapshot)
  );
}

function lineNumberFor(text: string, pattern: RegExp): number | undefined {
  const match = pattern.exec(text);
  if (!match?.index) return match ? 1 : undefined;
  return text.slice(0, match.index).split("\n").length;
}

function validateFxmanifest(
  text: string,
  file: string,
  repositoryRoot: string,
  expectedVersion: string,
): Diagnostic[] {
  const diagnostics: Diagnostic[] = [];
  if (!/\bfx_version\s+["']cerulean["']/u.test(text)) {
    diagnostics.push({
      level: "error",
      rule: "fxmanifest-version",
      file: displayPath(repositoryRoot, file),
      message: "fxmanifest.lua must declare fx_version 'cerulean'.",
    });
  }
  if (!/\bgame\s+["']gta5["']/u.test(text)) {
    diagnostics.push({
      level: "error",
      rule: "fxmanifest-game",
      file: displayPath(repositoryRoot, file),
      message: "fxmanifest.lua must declare game 'gta5'.",
    });
  }
  const deprecatedLine = lineNumberFor(text, /\blua54\s+["']yes["']/u);
  if (deprecatedLine !== undefined) {
    diagnostics.push({
      level: "warning",
      rule: "fxmanifest-lua54-deprecated",
      file: displayPath(repositoryRoot, file),
      line: deprecatedLine,
      message: "The lua54 directive is deprecated and should be removed.",
    });
  }
  const versionMetadata = parseFxmanifestVersionMetadata(text);
  if (versionMetadata.status === "missing") {
    diagnostics.push({
      level: "error",
      rule: "fxmanifest-metadata",
      file: displayPath(repositoryRoot, file),
      message: "Resource version metadata is not declared.",
    });
  } else if (versionMetadata.status === "ambiguous") {
    diagnostics.push({
      level: "error",
      rule: "fxmanifest-version-ambiguous",
      file: displayPath(repositoryRoot, file),
      message: "Resource version metadata must be declared exactly once.",
    });
  } else if (versionMetadata.status === "invalid") {
    diagnostics.push({
      level: "error",
      rule: "fxmanifest-version-invalid",
      file: displayPath(repositoryRoot, file),
      message: "Resource version metadata must use canonical semantic versioning.",
    });
  } else if (versionMetadata.version !== expectedVersion) {
    diagnostics.push({
      level: "error",
      rule: "fxmanifest-version-mismatch",
      file: displayPath(repositoryRoot, file),
      message: `fxmanifest.lua declares ${versionMetadata.version}, but synex.resource.json declares ${expectedVersion}.`,
    });
  }
  return diagnostics;
}

export async function loadResourceManifests(
  repositoryRoot: string,
  target: string,
  registry: SchemaRegistry,
): Promise<{ manifests: LoadedResourceManifest[]; diagnostics: Diagnostic[] }> {
  const files = await walkFiles(target, (path) => basename(path) === "synex.resource.json");
  const manifests: LoadedResourceManifest[] = [];
  const diagnostics: Diagnostic[] = [];
  const names = new Map<string, string>();

  for (const file of files) {
    let value: unknown;
    try {
      value = await readJsonFile(file);
    } catch (error) {
      diagnostics.push({
        level: "error",
        rule: "resource-json",
        file: displayPath(repositoryRoot, file),
        message: error instanceof Error ? error.message : "Resource manifest could not be read.",
      });
      continue;
    }
    if (!registry.resource(value) || !isResourceManifest(value)) {
      diagnostics.push(
        ...schemaDiagnostics(registry.resource.errors, file, repositoryRoot, "resource-schema"),
      );
      continue;
    }
    const previous = names.get(value.name);
    if (previous) {
      diagnostics.push({
        level: "error",
        rule: "resource-name-unique",
        file: displayPath(repositoryRoot, file),
        message: `Resource name ${value.name} is already declared in ${previous}.`,
      });
    } else {
      names.set(value.name, displayPath(repositoryRoot, file));
    }
    manifests.push({ file, directory: dirname(file), manifest: value });
  }

  manifests.sort((left, right) => compareText(left.manifest.name, right.manifest.name));
  return { manifests, diagnostics };
}

export async function validateRepository(
  repositoryRoot: string,
  target = repositoryRoot,
): Promise<ValidationReport> {
  const schemas = await loadSchemaRegistry(repositoryRoot);
  const selectedTarget = resolve(target);
  if (!(await isDirectory(selectedTarget))) throw new CliError("Validation target is not a directory.", 2);

  const diagnostics: Diagnostic[] = [];
  const resources = await loadResourceManifests(repositoryRoot, selectedTarget, schemas);
  diagnostics.push(...resources.diagnostics);
  const globalResources = selectedTarget === resolve(repositoryRoot)
    ? resources
    : await loadResourceManifests(repositoryRoot, resolve(repositoryRoot), schemas);
  const knownResources = new Map(
    globalResources.manifests.map((resource) => [resource.manifest.name, resource]),
  );
  const fxmanifestResources = await loadFxmanifestResourceMetadata(repositoryRoot);

  const contractSources = await loadContractSources(repositoryRoot, schemas, selectedTarget);
  diagnostics.push(...contractSources.diagnostics);
  const globalContractSources = selectedTarget === resolve(repositoryRoot)
    ? contractSources
    : await loadContractSources(repositoryRoot, schemas);
  const knownContracts = new Map(
    flattenContracts(globalContractSources.sources).map((contract) => [contract.name, contract]),
  );

  const stateFiles = await walkFiles(selectedTarget, (path) => path.endsWith(".state.json"));
  for (const file of stateFiles) {
    try {
      const value = await readJsonFile(file);
      if (!schemas.state(value)) {
        diagnostics.push(...schemaDiagnostics(schemas.state.errors, file, repositoryRoot, "state-schema"));
      }
    } catch (error) {
      diagnostics.push({
        level: "error",
        rule: "state-json",
        file: displayPath(repositoryRoot, file),
        message: error instanceof Error ? error.message : "State definition could not be read.",
      });
    }
  }

  const configurationFiles = [
    {
      file: join(repositoryRoot, "core", "synex_core", "config", "default.json"),
      validate: schemas.configuration,
      rule: "configuration-schema",
    },
    {
      file: join(repositoryRoot, "core", "synex_core", "config", "capabilities.json"),
      validate: schemas.capabilityPolicy,
      rule: "capability-policy-schema",
    },
  ].filter(({ file }) => containsPath(selectedTarget, file));
  for (const { file, validate, rule } of configurationFiles) {
    try {
      if (!(await pathExists(file))) {
        diagnostics.push({ level: "error", rule, file: displayPath(repositoryRoot, file), message: "Required core configuration is missing." });
        continue;
      }
      const value = await readJsonFile(file);
      if (!validate(value)) {
        diagnostics.push(...schemaDiagnostics(validate.errors, file, repositoryRoot, rule));
      } else if (rule === "configuration-schema") {
        diagnostics.push(...configurationSemanticDiagnostics(value, file, repositoryRoot));
      }
    } catch (error) {
      diagnostics.push({
        level: "error",
        rule,
        file: displayPath(repositoryRoot, file),
        message: error instanceof Error ? error.message : "Configuration JSON could not be read.",
      });
    }
  }

  for (const loaded of resources.manifests) {
    const fxmanifest = join(loaded.directory, "fxmanifest.lua");
    if (!(await pathExists(fxmanifest))) {
      diagnostics.push({
        level: "error",
        rule: "resource-fxmanifest",
        file: displayPath(repositoryRoot, loaded.file),
        message: "Runnable Synex resources require an adjacent fxmanifest.lua.",
      });
    } else {
      diagnostics.push(
        ...validateFxmanifest(
          await readTextFile(fxmanifest),
          fxmanifest,
          repositoryRoot,
          loaded.manifest.version,
        ),
      );
    }

    const dependencyNames = [
      ...loaded.manifest.dependencies.required,
      ...loaded.manifest.dependencies.optional,
      ...loaded.manifest.dependencies.development,
    ].map((dependency) => dependency.name);
    if (dependencyNames.includes(loaded.manifest.name)) {
      diagnostics.push({
        level: "error",
        rule: "resource-self-dependency",
        file: displayPath(repositoryRoot, loaded.file),
        message: "A resource cannot depend on itself.",
      });
    }

    for (const [dependencyClass, dependencies] of [
      ["required", loaded.manifest.dependencies.required],
      ["optional", loaded.manifest.dependencies.optional],
      ["development", loaded.manifest.dependencies.development],
    ] as const) {
      for (const dependency of dependencies) {
        const provider = knownResources.get(dependency.name);
        const runtimeMetadata = fxmanifestResources.get(dependency.name);
        if (!provider) {
          if (dependency.name.startsWith("synex_") && dependencyClass !== "development") {
            diagnostics.push({
              level: dependencyClass === "required" ? "error" : "warning",
              rule: "resource-dependency-missing",
              file: displayPath(repositoryRoot, loaded.file),
              message: `${dependencyClass} dependency ${dependency.name} is not present in this checkout.`,
            });
          } else if (runtimeMetadata && runtimeMetadata.versionStatus !== "valid") {
            diagnostics.push({
              level: dependencyClass === "required" ? "error" : "warning",
              rule: "resource-dependency-metadata",
              file: displayPath(repositoryRoot, loaded.file),
              message: `${dependencyClass} dependency ${dependency.name} has ${runtimeMetadata.versionStatus} fxmanifest version metadata.`,
            });
          } else if (runtimeMetadata?.version
            && !satisfiesVersionRange(runtimeMetadata.version, dependency.version)) {
            diagnostics.push({
              level: dependencyClass === "required" ? "error" : "warning",
              rule: "resource-dependency-version",
              file: displayPath(repositoryRoot, loaded.file),
              message: `${dependencyClass} dependency ${dependency.name} requires ${dependency.version}, but this checkout provides ${runtimeMetadata.version}.`,
            });
          } else if (!runtimeMetadata && dependencyClass !== "development"
            && !dependency.name.startsWith("synex_")) {
            diagnostics.push({
              level: "warning",
              rule: "resource-dependency-runtime-unverified",
              file: displayPath(repositoryRoot, loaded.file),
              message: `${dependencyClass} external dependency ${dependency.name}@${dependency.version} is not vendored; its deployed fxmanifest version must be verified at runtime.`,
            });
          }
          continue;
        }
        if (!runtimeMetadata || runtimeMetadata.versionStatus !== "valid") {
          diagnostics.push({
            level: dependencyClass === "required" ? "error" : "warning",
            rule: "resource-dependency-metadata",
            file: displayPath(repositoryRoot, loaded.file),
            message: `${dependencyClass} dependency ${dependency.name} has ${runtimeMetadata?.versionStatus ?? "missing"} fxmanifest version metadata.`,
          });
        } else if (!runtimeMetadata.version
          || !satisfiesVersionRange(runtimeMetadata.version, dependency.version)) {
          diagnostics.push({
            level: dependencyClass === "required" ? "error" : "warning",
            rule: "resource-dependency-version",
            file: displayPath(repositoryRoot, loaded.file),
            message: `${dependencyClass} dependency ${dependency.name} requires ${dependency.version}, but this checkout provides ${runtimeMetadata.version ?? "no valid version"}.`,
          });
        }
      }
    }

    for (const migration of loaded.manifest.migrations) {
      let migrationFile: string;
      try {
        migrationFile = resolveWithin(loaded.directory, migration.path);
      } catch {
        diagnostics.push({
          level: "error",
          rule: "migration-path",
          file: displayPath(repositoryRoot, loaded.file),
          message: `Migration ${migration.id} escapes the resource directory.`,
        });
        continue;
      }
      if (!(await pathExists(migrationFile))) {
        diagnostics.push({
          level: "error",
          rule: "migration-missing",
          file: displayPath(repositoryRoot, loaded.file),
          message: `Migration ${migration.id} references a missing file.`,
        });
      }
    }

    for (const contract of loaded.manifest.contracts.provide) {
      const definition = knownContracts.get(contract);
      if (!definition) {
        diagnostics.push({
          level: "error",
          rule: "contract-provider-missing",
          file: displayPath(repositoryRoot, loaded.file),
          message: `Provided contract ${contract} has no canonical definition.`,
        });
      } else if (definition.provider !== loaded.manifest.name) {
        diagnostics.push({
          level: "error",
          rule: "contract-provider-mismatch",
          file: displayPath(repositoryRoot, loaded.file),
          message: `Contract ${contract} declares provider ${definition.provider}, not ${loaded.manifest.name}.`,
        });
      }
    }
    for (const contract of loaded.manifest.contracts.consume) {
      if (!knownContracts.has(contract)) {
        diagnostics.push({
          level: "warning",
          rule: "contract-consumer-unresolved",
          file: displayPath(repositoryRoot, loaded.file),
          message: `Consumed contract ${contract} is not defined in this checkout.`,
        });
      }
    }
  }

  const fxmanifests = await walkFiles(selectedTarget, (path) => basename(path) === "fxmanifest.lua");
  const manifestDirectories = new Set(resources.manifests.map((manifest) => manifest.directory));
  for (const file of fxmanifests) {
    if (basename(dirname(file)).startsWith("synex_") && !manifestDirectories.has(dirname(file))) {
      diagnostics.push({
        level: "error",
        rule: "resource-manifest-missing",
        file: displayPath(repositoryRoot, file),
        message: "Synex resources require synex.resource.json.",
      });
    }
  }

  diagnostics.sort((left, right) => {
    const byFile = compareText(left.file, right.file);
    if (byFile !== 0) return byFile;
    return (left.line ?? 0) - (right.line ?? 0) || compareText(left.rule, right.rule);
  });

  return {
    target: displayPath(repositoryRoot, selectedTarget),
    filesChecked: resources.manifests.length + contractSources.sources.length + stateFiles.length
      + configurationFiles.length + fxmanifests.length,
    resources: resources.manifests.length,
    contracts: contractSources.sources.reduce((total, source) => total + source.collection.contracts.length, 0),
    states: stateFiles.length,
    diagnostics,
  };
}
