import { lstat, realpath } from "node:fs/promises";
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
import { loadWorldBundleCatalog } from "./world.ts";

export interface ResourceManifest {
  schema: number;
  name: string;
  version: string;
  synex: string;
  critical: boolean;
  controlProvider?: {
    schemaVersion: 1;
    namespace: string;
    label: string;
    category: string;
    version: string;
    operations: Array<"summary" | "health" | "list" | "inspect" | "search" | "metrics" | "findings" | "simulate">;
    views: Array<{
      id: string;
      label: string;
      operation: "summary" | "health" | "list" | "inspect" | "search" | "metrics" | "findings" | "simulate";
      presentation: "metrics" | "key-value" | "table" | "detail" | "timeline" | "graph" | "findings";
      accessClass: "general" | "audit" | "security" | "financial" | "identifiers";
      order?: number;
      description?: string;
      search?: {
        kinds: Array<{
          id: string;
          modes: Array<"exact" | "prefix">;
          accessClass: "general" | "audit" | "security" | "financial" | "identifiers";
        }>;
      };
      input?: {
        fields: Array<{
          key: string;
          label: string;
          source: "id" | "filter";
          type: "string" | "integer" | "boolean";
          format: "identifier" | "lookup" | "uuid" | "resource" | "capability" | "action" | "integer" | "numeric-string" | "boolean" | "text";
          required: boolean;
          minLength?: number;
          maxLength?: number;
          minimum?: number;
          maximum?: number;
        }>;
      };
    }>;
  };
  capabilities: { request: string[] };
  services: { provide: string[]; require: string[]; optional: string[] };
  contracts: { provide: string[]; consume: string[] };
  events: { publish: string[]; subscribe: string[] };
  hooks: { register: string[]; run: string[] };
  dependencies: {
    required: Array<{ name: string; version: string }>;
    optional: Array<{ name: string; version: string }>;
    development: Array<{ name: string; version: string }>;
  };
  migrations: Array<{ id: string; path: string; transactional: boolean }>;
  dataOwnership: { tables: string[]; characterDelete: string };
  stateSnapshot: { supported: boolean; schemaVersion: number };
  worldBundles?: string[];
  interactionBundles?: string[];
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
  worldBundles: number;
  interactionBundles: number;
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
    isRecord(value.events) &&
    isRecord(value.hooks) &&
    isRecord(value.dependencies) &&
    Array.isArray(value.migrations) &&
    isRecord(value.dataOwnership) &&
    isRecord(value.stateSnapshot)
  );
}

function materializeResourceManifest(value: unknown): ResourceManifest | null {
  if (!isRecord(value)) return null;
  const candidate = {
    ...value,
    events: value.events ?? { publish: [], subscribe: [] },
    hooks: value.hooks ?? { register: [], run: [] },
  };
  return isResourceManifest(candidate) ? candidate : null;
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
    const schemaValid = registry.resource(value);
    const manifest = schemaValid ? materializeResourceManifest(value) : null;
    if (!schemaValid || !manifest) {
      diagnostics.push(
        ...schemaDiagnostics(registry.resource.errors, file, repositoryRoot, "resource-schema"),
      );
      if (schemaValid && !manifest) {
        diagnostics.push({
          level: "error",
          rule: "resource-schema",
          file: displayPath(repositoryRoot, file),
          message: "The schema-valid manifest cannot be represented by this Synex CLI version.",
        });
      }
      continue;
    }
    const previous = names.get(manifest.name);
    if (previous) {
      diagnostics.push({
        level: "error",
        rule: "resource-name-unique",
        file: displayPath(repositoryRoot, file),
        message: `Resource name ${manifest.name} is already declared in ${previous}.`,
      });
    } else {
      names.set(manifest.name, displayPath(repositoryRoot, file));
    }
    manifests.push({ file, directory: dirname(file), manifest });
  }

  manifests.sort((left, right) => compareText(left.manifest.name, right.manifest.name));
  return { manifests, diagnostics };
}

interface InteractionBundleRecord {
  key: string;
  ownerResource: string;
  file: string;
}

interface InteractionBundleCatalog {
  bundles: InteractionBundleRecord[];
  diagnostics: Diagnostic[];
  declaredBundleFiles: number;
}

async function interactionBundlePathIsContained(
  resourceDirectory: string,
  bundleFile: string,
): Promise<boolean> {
  try {
    const metadata = await lstat(bundleFile);
    if (!metadata.isFile() || metadata.isSymbolicLink()) return false;
    const [realResource, realBundle] = await Promise.all([
      realpath(resourceDirectory),
      realpath(bundleFile),
    ]);
    return containsPath(realResource, realBundle);
  } catch {
    return false;
  }
}

function interactionNamespace(key: string): string | null {
  const separator = key.indexOf(":");
  return separator > 0 ? key.slice(0, separator) : null;
}

async function loadInteractionBundleCatalog(
  repositoryRoot: string,
  manifests: LoadedResourceManifest[],
  schemas: SchemaRegistry,
  selectedResources: ReadonlySet<string>,
): Promise<InteractionBundleCatalog> {
  const diagnostics: Diagnostic[] = [];
  const bundles: InteractionBundleRecord[] = [];
  const bundleKeys = new Map<string, InteractionBundleRecord>();
  let declaredBundleFiles = 0;

  const add = (
    ownerResource: string,
    rule: string,
    file: string,
    message: string,
  ): void => {
    if (!selectedResources.has(ownerResource)) return;
    diagnostics.push({ level: "error", rule, file, message });
  };

  for (const loaded of manifests) {
    for (const relativeBundle of loaded.manifest.interactionBundles ?? []) {
      if (selectedResources.has(loaded.manifest.name)) declaredBundleFiles += 1;
      let bundleFile: string;
      try {
        bundleFile = resolveWithin(loaded.directory, relativeBundle);
      } catch {
        add(
          loaded.manifest.name,
          "interaction-bundle-path",
          displayPath(repositoryRoot, loaded.file),
          `Interaction bundle path ${relativeBundle} escapes its resource.`,
        );
        continue;
      }

      const shownFile = displayPath(repositoryRoot, bundleFile);
      if (!(await interactionBundlePathIsContained(loaded.directory, bundleFile))) {
        add(
          loaded.manifest.name,
          "interaction-bundle-path",
          shownFile,
          "Interaction bundle must be a regular file contained by its declaring resource.",
        );
        continue;
      }

      let value: unknown;
      try {
        value = await readJsonFile(bundleFile);
      } catch (error) {
        add(
          loaded.manifest.name,
          "interaction-bundle-json",
          shownFile,
          error instanceof Error ? error.message : "Interaction bundle could not be read.",
        );
        continue;
      }
      if (!schemas.interactionBundle(value)) {
        if (selectedResources.has(loaded.manifest.name)) {
          diagnostics.push(...schemaDiagnostics(
            schemas.interactionBundle.errors,
            bundleFile,
            repositoryRoot,
            "interaction-bundle-schema",
          ));
        }
        continue;
      }
      if (!isRecord(value) || typeof value.key !== "string") continue;

      const bundle: InteractionBundleRecord = {
        key: value.key,
        ownerResource: loaded.manifest.name,
        file: shownFile,
      };
      bundles.push(bundle);
      if (interactionNamespace(bundle.key) !== loaded.manifest.name) {
        add(
          loaded.manifest.name,
          "interaction-bundle-ownership",
          shownFile,
          `Bundle key ${bundle.key} must use declaring resource namespace ${loaded.manifest.name}.`,
        );
      }

      const previousBundle = bundleKeys.get(bundle.key);
      if (previousBundle) {
        if (selectedResources.has(bundle.ownerResource)
          || selectedResources.has(previousBundle.ownerResource)) {
          diagnostics.push({
            level: "error",
            rule: "interaction-bundle-key-unique",
            file: shownFile,
            message: `Bundle key ${bundle.key} is already declared in ${previousBundle.file}.`,
          });
        }
      } else {
        bundleKeys.set(bundle.key, bundle);
      }

      for (const collectionName of ["smartObjects", "intents", "graphs"] as const) {
        const definitions = value[collectionName];
        if (!Array.isArray(definitions)) continue;
        const keys = new Set<string>();
        for (const definition of definitions) {
          if (!isRecord(definition) || typeof definition.key !== "string") continue;
          if (interactionNamespace(definition.key) !== loaded.manifest.name) {
            add(
              loaded.manifest.name,
              "interaction-definition-ownership",
              shownFile,
              `${collectionName} key ${definition.key} must use declaring resource namespace ${loaded.manifest.name}.`,
            );
          }
          if (keys.has(definition.key)) {
            add(
              loaded.manifest.name,
              "interaction-definition-key-unique",
              shownFile,
              `${collectionName} key ${definition.key} is duplicated within the bundle.`,
            );
          } else {
            keys.add(definition.key);
          }
        }
      }
    }
  }

  diagnostics.sort((left, right) => compareText(
    `${left.file}:${left.rule}:${left.message}`,
    `${right.file}:${right.rule}:${right.message}`,
  ));
  return {
    bundles: bundles.sort((left, right) => compareText(left.key, right.key)),
    diagnostics,
    declaredBundleFiles,
  };
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
  const controlProviderNamespaces = new Map<string, LoadedResourceManifest>();
  for (const loaded of globalResources.manifests) {
    const provider = loaded.manifest.controlProvider;
    if (!provider) continue;
    const previous = controlProviderNamespaces.get(provider.namespace);
    if (previous) {
      if (resources.manifests.some((candidate) => candidate.file === loaded.file
        || candidate.file === previous.file)) {
        diagnostics.push({
          level: "error",
          rule: "control-provider-namespace-unique",
          file: displayPath(repositoryRoot, loaded.file),
          message: `Control provider namespace ${provider.namespace} is already declared by ${previous.manifest.name}.`,
        });
      }
    } else {
      controlProviderNamespaces.set(provider.namespace, loaded);
    }
  }
  const fxmanifestResources = await loadFxmanifestResourceMetadata(repositoryRoot);

  const contractSources = await loadContractSources(repositoryRoot, schemas, selectedTarget);
  diagnostics.push(...contractSources.diagnostics);
  const globalContractSources = selectedTarget === resolve(repositoryRoot)
    ? contractSources
    : await loadContractSources(repositoryRoot, schemas);
  const knownContracts = new Map(
    flattenContracts(globalContractSources.sources).map((contract) => [contract.name, contract]),
  );

  const selectedResourceNames = new Set(
    resources.manifests.map((resource) => resource.manifest.name),
  );
  const worldCatalog = await loadWorldBundleCatalog(
    repositoryRoot,
    globalResources.manifests,
    schemas,
    selectedResourceNames,
  );
  diagnostics.push(...worldCatalog.diagnostics);
  const interactionCatalog = await loadInteractionBundleCatalog(
    repositoryRoot,
    globalResources.manifests,
    schemas,
    selectedResourceNames,
  );
  diagnostics.push(...interactionCatalog.diagnostics);

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
    const controlProvider = loaded.manifest.controlProvider;
    if (controlProvider) {
      const declaredOperations = new Set(controlProvider.operations);
      for (const view of controlProvider.views) {
        if (!declaredOperations.has(view.operation)) {
          diagnostics.push({
            level: "error",
            rule: "control-provider-view-operation",
            file: displayPath(repositoryRoot, loaded.file),
            message: `Control provider view ${view.id} uses undeclared operation ${view.operation}.`,
          });
        }
      }
      for (const requiredOperation of ["summary", "health"] as const) {
        if (!declaredOperations.has(requiredOperation)
          || !controlProvider.views.some((view) => view.operation === requiredOperation)) {
          diagnostics.push({
            level: "error",
            rule: "control-provider-health-contract",
            file: displayPath(repositoryRoot, loaded.file),
            message: `A Control provider must declare ${requiredOperation} and expose a matching bounded view.`,
          });
        }
      }
      if (!loaded.manifest.capabilities.request.includes("synex.control.provider.register")) {
        diagnostics.push({
          level: "error",
          rule: "control-provider-registration-capability",
          file: displayPath(repositoryRoot, loaded.file),
          message: "A declared Control provider must request synex.control.provider.register.",
        });
      }
      if (loaded.manifest.name !== "synex_control") {
        const dependsOnControl = [
          ...loaded.manifest.dependencies.required,
          ...loaded.manifest.dependencies.optional,
          ...loaded.manifest.dependencies.development,
        ].some((dependency) => dependency.name === "synex_control");
        if (dependsOnControl) {
          diagnostics.push({
            level: "error",
            rule: "control-provider-dependency-direction",
            file: displayPath(repositoryRoot, loaded.file),
            message: "A Control provider must not depend on the optional synex_control resource.",
          });
        }
      }
    }
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
      + configurationFiles.length + fxmanifests.length + worldCatalog.declaredBundleFiles
      + interactionCatalog.declaredBundleFiles,
    resources: resources.manifests.length,
    contracts: contractSources.sources.reduce((total, source) => total + source.collection.contracts.length, 0),
    states: stateFiles.length,
    worldBundles: worldCatalog.bundles.filter((bundle) => selectedResourceNames.has(bundle.ownerResource)).length,
    interactionBundles: interactionCatalog.bundles.filter((bundle) =>
      selectedResourceNames.has(bundle.ownerResource)
    ).length,
    diagnostics,
  };
}
