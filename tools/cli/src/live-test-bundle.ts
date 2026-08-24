import { spawnSync } from "node:child_process";
import { constants } from "node:fs";
import {
  copyFile,
  lstat,
  mkdir,
  readFile,
  readdir,
  realpath,
  rename,
  rm,
  rmdir,
  writeFile,
} from "node:fs/promises";
import { basename, dirname, extname, join, relative, resolve, sep } from "node:path";
import { createHash, randomBytes } from "node:crypto";

import { CliError } from "./errors.ts";
import {
  canonicalJson,
  compareText,
  containsPath,
  displayPath,
  isRecord,
  pathExists,
  prettyJson,
  readJsonFile,
  readTextFile,
  resolveWithin,
  sha256,
} from "./filesystem.ts";
import { inspectPermissions } from "./resources.ts";
import {
  luaCallArguments,
  luaExpressionName,
  luaStringLiteral,
  parseLuaAst,
  scanSecurity,
  walkLuaAst,
  type LuaAstNode,
} from "./security.ts";
import { loadSchemaRegistry } from "./schemas.ts";
import { isResourceManifest, validateRepository } from "./validation.ts";

const PROBE_RESOURCE = "synex_core_probe";
const LIVE_TEST_ROOT = join(".temp", "live-test");
const MAX_PROBE_FILES = 256;
const MAX_PROBE_FILE_BYTES = 2 * 1024 * 1024;
const MAX_PROBE_TOTAL_BYTES = 8 * 1024 * 1024;
const MAX_PROBE_DEPTH = 16;

export const CORE_PROBE_CAPABILITIES = [
  "synex.connections.gate",
  "synex.sagas.read",
  "synex.sagas.register",
  "synex.sagas.write",
] as const;

const FORBIDDEN_PROBE_DIRECTORIES = new Set([
  ".build",
  ".git",
  ".synex",
  ".temp",
  "artifacts",
  "cache",
  "coverage",
  "dist",
  "node_modules",
  "server-cache",
  "server-cache-priv",
  "tmp",
  "txdata",
]);

const FORBIDDEN_PROBE_EXTENSIONS = new Set([
  ".7z",
  ".bat",
  ".cmd",
  ".dll",
  ".dump",
  ".dylib",
  ".exe",
  ".key",
  ".log",
  ".p12",
  ".pem",
  ".pfx",
  ".ps1",
  ".rar",
  ".sh",
  ".so",
  ".zip",
]);

const SECRET_PATTERNS = [
  /-----BEGIN [A-Z ]*PRIVATE KEY-----/u,
  /(?:discord(?:app)?\.com)\/api\/webhooks\/[0-9]+\/[A-Za-z0-9._-]+/iu,
  /\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})\b/u,
  /\bcfxk_[A-Za-z0-9_-]{20,}\b/u,
  /\bmysql:\/\/[^\s:@]+:[^\s@]+@[^\s/]+/iu,
  /\bsv_licenseKey\s+["'][^"']+["']/iu,
] as const;

const FORBIDDEN_PROBE_CODE = [
  /\bCitizen\b/u,
  /\bPerformHttpRequest[A-Za-z0-9_]*\b/u,
  /\bExecuteCommand\b/u,
  /\bLoadResourceFile\b/u,
  /\bSaveResourceFile\b/u,
  /\b(?:Citizen\.)?InvokeNative\b/u,
  /\b(?:AddEventHandler|AddStateBagChangeHandler|CancelEvent|DropPlayer|RegisterCommand|RegisterNetEvent|RegisterServerEvent|SetHttpHandler|StartResource|StopResource|TriggerClientEvent|TriggerEvent|TriggerLatentClientEvent|TriggerLatentServerEvent|TriggerServerEvent)\b/u,
  /\bSetConvar[A-Za-z0-9_]*\b/u,
  /\b(?:dofile|load|loadfile|loadstring|rawget|rawset|require)\b/u,
  /\b(?:_ENV|_G|debug|io|os|package)\b/u,
  /\b(?:child_process|XMLHttpRequest)\b/u,
  /\bfetch\b/u,
  /\bMySQL\b/u,
  /\b(?:Entity|GlobalState|Player)\b/u,
  /\b(?:CreateObject|CreatePed|CreateVehicle|DeleteEntity|EnsureEntityStateBag|GetAllObjects|GetAllPeds|GetAllVehicles|GetEntity[A-Za-z0-9_]*|GetPlayer[A-Za-z0-9_]*|GetPlayers|NetworkGetEntity[A-Za-z0-9_]*|SetEntity[A-Za-z0-9_]*|SetPlayer[A-Za-z0-9_]*)\b/u,
] as const;

const ALLOWED_KVP_FUNCTIONS = new Set([
  "DeleteResourceKvp",
  "GetResourceKvpInt",
  "GetResourceKvpString",
  "SetResourceKvp",
  "SetResourceKvpInt",
]);

interface TreeFile {
  absolutePath: string;
  relativePath: string;
  size: number;
}

interface ProbeInspection {
  files: TreeFile[];
  totalBytes: number;
  kvpStaticKeyScoped: boolean;
}

interface ProbeKvpCall {
  arguments: unknown[];
  base: unknown;
  name: string;
  node: LuaAstNode;
}

export interface CoreLiveTestBundleReport {
  schema: 2;
  artifactKind: "synex-core-live-test-bundle";
  status: "PREPARED";
  revision: string;
  runId: string;
  instanceId: string;
  kvpIsolation: {
    strategy: "run-scoped-resource-key";
    key: string;
    cleanupRequired: true;
  };
  bundle: string;
  resources: {
    core: string;
    probe: string;
  };
  configuration: string;
  grants: string[];
  validation: {
    warnings: number;
    permissionWarnings: number;
  };
  runtimeRequirements: {
    resources: Array<{ name: "oxmysql"; version: ">=2.14.1" }>;
    operatorConfiguration: ["mysql_connection_string", "sv_licenseKey", "endpoint_add_tcp", "endpoint_add_udp"];
  };
  hashes: {
    configuration: string;
    productionPolicy: string;
    testPolicy: string;
    sourceCoreTree: string;
    bundledCoreTree: string;
    sourceProbeTree: string;
    bundledProbeTree: string;
  };
  probe: {
    files: number;
    bytes: number;
    securityFindings: number;
    kvpStaticKeyScoped: boolean;
  };
  safeguards: {
    productionPolicyUnchanged: true;
    cleanRevision: true;
    ignoredDisposableOutput: true;
    exactCapabilitiesOnly: true;
    runScopedKvpKey: true;
    symlinksRejected: true;
  };
}

function gitOutput(repositoryRoot: string, argumentsList: string[]): string {
  const result = spawnSync("git", argumentsList, {
    cwd: repositoryRoot,
    encoding: "utf8",
    timeout: 10_000,
    windowsHide: true,
  });
  if (result.error || result.status !== 0) {
    throw new CliError("A readable Git revision is required to prepare a live-test bundle.", 2);
  }
  return result.stdout.trim();
}

function requireCleanRevision(repositoryRoot: string): string {
  const status = gitOutput(repositoryRoot, ["status", "--porcelain=v1", "--untracked-files=normal"]);
  if (status.length > 0) {
    throw new CliError(
      "Live-test preparation requires a clean Git checkout. Move the probe outside the repository and commit or preserve other work first.",
      2,
    );
  }
  const revision = gitOutput(repositoryRoot, ["rev-parse", "--verify", "HEAD"]);
  if (!/^[0-9a-f]{40,64}$/u.test(revision)) {
    throw new CliError("The current Git revision could not be identified safely.", 2);
  }
  return revision;
}

async function collectTreeFiles(
  sourceRoot: string,
  limits?: { maximumFiles: number; maximumFileBytes: number; maximumTotalBytes: number; maximumDepth: number },
): Promise<TreeFile[]> {
  const files: TreeFile[] = [];
  const pending = [sourceRoot];
  let totalBytes = 0;
  while (pending.length > 0) {
    const directory = pending.pop();
    if (!directory) break;
    const entries = (await readdir(directory, { withFileTypes: true })).sort((left, right) =>
      compareText(left.name, right.name)
    );
    for (const entry of entries) {
      const path = join(directory, entry.name);
      const metadata = await lstat(path);
      if (metadata.isSymbolicLink()) {
        throw new CliError("Live-test sources must not contain symbolic links or junctions.", 2);
      }
      const relativePath = relative(sourceRoot, path);
      const depth = relativePath.split(sep).length;
      if (limits && depth > limits.maximumDepth) {
        throw new CliError(`Probe tree exceeds the ${limits.maximumDepth}-level safety limit.`, 2);
      }
      if (metadata.isDirectory()) {
        if (limits && FORBIDDEN_PROBE_DIRECTORIES.has(entry.name.toLowerCase())) {
          throw new CliError(`Probe contains forbidden directory ${entry.name}.`, 2);
        }
        pending.push(path);
        continue;
      }
      if (!metadata.isFile()) {
        throw new CliError("Live-test sources may contain only regular files and directories.", 2);
      }
      if (limits && metadata.size > limits.maximumFileBytes) {
        throw new CliError(`Probe file ${entry.name} exceeds the per-file safety limit.`, 2);
      }
      totalBytes += metadata.size;
      files.push({ absolutePath: path, relativePath, size: metadata.size });
      if (limits && files.length > limits.maximumFiles) {
        throw new CliError(`Probe tree exceeds the ${limits.maximumFiles}-file safety limit.`, 2);
      }
      if (limits && totalBytes > limits.maximumTotalBytes) {
        throw new CliError("Probe tree exceeds the total-size safety limit.", 2);
      }
    }
  }
  return files.sort((left, right) => compareText(left.relativePath, right.relativePath));
}

function forbiddenProbeFile(relativePath: string): boolean {
  const name = basename(relativePath).toLowerCase();
  return name === ".env"
    || name.startsWith(".env.")
    || name === "credentials.json"
    || name === "id_ed25519"
    || name === "id_rsa"
    || name === "secrets.json"
    || name === "server.cfg"
    || name.endsWith(".local.cfg")
    || FORBIDDEN_PROBE_EXTENSIONS.has(extname(name));
}

function isCodeFile(path: string): boolean {
  return new Set([".cjs", ".js", ".lua", ".mjs", ".ts"]).has(extname(path).toLowerCase());
}

function stripLuaComments(source: string): string {
  let output = "";
  let index = 0;

  const longBracket = (offset: number): { closing: string; length: number } | null => {
    if (source[offset] !== "[") return null;
    let cursor = offset + 1;
    while (source[cursor] === "=") cursor += 1;
    if (source[cursor] !== "[") return null;
    const equals = source.slice(offset + 1, cursor);
    return { closing: `]${equals}]`, length: cursor - offset + 1 };
  };

  while (index < source.length) {
    const character = source[index] ?? "";
    const next = source[index + 1] ?? "";

    if (character === "'" || character === '"') {
      const quote = character;
      output += character;
      index += 1;
      while (index < source.length) {
        const stringCharacter = source[index] ?? "";
        output += stringCharacter;
        index += 1;
        if (stringCharacter === "\\" && index < source.length) {
          output += source[index] ?? "";
          index += 1;
          continue;
        }
        if (stringCharacter === quote) break;
      }
      continue;
    }

    const stringBracket = longBracket(index);
    if (stringBracket) {
      const closingIndex = source.indexOf(stringBracket.closing, index + stringBracket.length);
      if (closingIndex < 0) {
        output += source.slice(index);
        break;
      }
      const end = closingIndex + stringBracket.closing.length;
      output += source.slice(index, end);
      index = end;
      continue;
    }

    if (character === "-" && next === "-") {
      const commentBracket = longBracket(index + 2);
      if (commentBracket) {
        const contentStart = index + 2 + commentBracket.length;
        const closingIndex = source.indexOf(commentBracket.closing, contentStart);
        const end = closingIndex < 0 ? source.length : closingIndex + commentBracket.closing.length;
        const comment = source.slice(index, end);
        output += comment.replace(/[^\r\n]/gu, "");
        index = end;
        continue;
      }
      const lineEnd = source.slice(index).search(/[\r\n]/u);
      if (lineEnd < 0) break;
      index += lineEnd;
      continue;
    }

    output += character;
    index += 1;
  }

  return output;
}

function validateProbeCodeBoundaries(texts: Map<string, string>): void {
  for (const [path, rawSource] of texts) {
    if (!isCodeFile(path) || basename(path) === "fxmanifest.lua") continue;
    if (extname(path).toLowerCase() === ".lua") {
      const parsed = parseLuaAst(rawSource);
      if (!parsed.ast || parsed.error) {
        throw new CliError(`Probe Lua source ${basename(path)} could not be parsed for boundary verification.`, 2);
      }
      let forbiddenIdentifier: string | null = null;
      walkLuaAst(parsed.ast, (node) => {
        const name = luaIdentifier(node);
        if (name && FORBIDDEN_PROBE_CODE.some((pattern) => pattern.test(name))) {
          forbiddenIdentifier = name;
        }
      });
      if (forbiddenIdentifier) {
        throw new CliError(`Probe file ${basename(path)} contains an operation forbidden in the isolated probe.`, 2);
      }
    }
    const source = extname(path).toLowerCase() === ".lua" ? stripLuaComments(rawSource) : rawSource;
    const withoutAllowedConvars = source.replace(
      /\bGetConvar\s*\(\s*(["'])synex_probe_run_id\1\s*,/gu,
      "__SYNEX_ALLOWED_GET_CONVAR__(",
    );
    if (/\bGetConvar[A-Za-z0-9_]*\b/u.test(withoutAllowedConvars)) {
      throw new CliError("Probe may read only the literal server-side synex_probe_run_id ConVar.", 2);
    }

    const withoutCoreExports = withoutAllowedConvars
      .replace(/\bexports\s*\.\s*synex_core\b/gu, "__SYNEX_CORE_EXPORT__")
      .replace(/\bexports\s*\[\s*(["'])synex_core\1\s*\]/gu, "__SYNEX_CORE_EXPORT__");
    if (/\bexports\b/u.test(withoutCoreExports)) {
      throw new CliError("Probe may access exports from synex_core only.", 2);
    }
  }
}

const PROBE_SCALAR_DIRECTIVES = new Set([
  "author",
  "dependency",
  "description",
  "fx_version",
  "game",
  "name",
  "server_only",
  "synex_contracts",
  "synex_manifest",
  "version",
]);

interface ParsedProbeFxmanifest {
  directives: Map<string, string[]>;
  files: string[];
  serverScripts: string[];
}

function parseProbeFxmanifest(fxmanifestText: string): ParsedProbeFxmanifest {
  const directives = new Map<string, string[]>();
  const files: string[] = [];
  const serverScripts: string[] = [];
  let block: "files" | "server_scripts" | null = null;
  let filesBlocks = 0;
  let serverScriptBlocks = 0;
  let singularServerScripts = 0;

  for (const rawLine of stripLuaComments(fxmanifestText).split(/\r?\n/u)) {
    const line = rawLine.trim();
    if (line.length === 0) continue;
    if (block) {
      if (/^\}\s*$/u.test(line)) {
        block = null;
        continue;
      }
      const entry = /^(?:'([^'\r\n]+)'|"([^"\r\n]+)")\s*,?\s*$/u.exec(line);
      if (!entry) {
        throw new CliError("Probe fxmanifest blocks may contain only literal file paths.", 2);
      }
      (block === "files" ? files : serverScripts).push(entry[1] ?? entry[2] ?? "");
      continue;
    }

    const blockStart = /^(files|server_scripts)\s*\{\s*$/u.exec(line)?.[1];
    if (blockStart === "files") {
      filesBlocks += 1;
      block = "files";
      continue;
    }
    if (blockStart === "server_scripts") {
      serverScriptBlocks += 1;
      block = "server_scripts";
      continue;
    }

    const serverScript = /^server_script\s+(?:'([^'\r\n]+)'|"([^"\r\n]+)")\s*$/u.exec(line);
    if (serverScript) {
      singularServerScripts += 1;
      serverScripts.push(serverScript[1] ?? serverScript[2] ?? "");
      continue;
    }

    const scalar = /^([a-z_]+)\s+(?:'([^'\r\n]*)'|"([^"\r\n]*)")\s*$/u.exec(line);
    const directive = scalar?.[1] ?? "";
    if (!scalar || !PROBE_SCALAR_DIRECTIVES.has(directive)) {
      throw new CliError("Probe fxmanifest may contain only the approved static server-only directives.", 2);
    }
    const values = directives.get(directive) ?? [];
    values.push(scalar[2] ?? scalar[3] ?? "");
    directives.set(directive, values);
  }

  if (block) throw new CliError(`Probe fxmanifest ${block} block is not closed.`, 2);
  const contractFiles = directives.get("synex_contracts") ?? [];
  const uniqueContractFiles = [...new Set(contractFiles)].sort(compareText);
  const uniqueFiles = [...new Set(files)].sort(compareText);
  const expectedFiles = ["synex.resource.json", ...uniqueContractFiles].sort(compareText);
  if (filesBlocks !== 1 || uniqueContractFiles.length !== contractFiles.length
    || contractFiles.some((path) => !/\.contracts\.json$/u.test(path))
    || uniqueFiles.length !== files.length
    || uniqueFiles.length !== expectedFiles.length
    || uniqueFiles.some((path, index) => path !== expectedFiles[index])) {
    throw new CliError(
      "Probe fxmanifest files must contain only synex.resource.json and exact declared .contracts.json descriptors.",
      2,
    );
  }
  if (serverScriptBlocks > 1 || (serverScriptBlocks === 1 && singularServerScripts > 0)
    || serverScripts.length === 0) {
    throw new CliError("Probe fxmanifest must declare one explicit local server-script form.", 2);
  }
  return { directives, files, serverScripts };
}

function validateProbeExecutableInventory(
  probeRoot: string,
  files: TreeFile[],
  fxmanifestText: string,
): void {
  const manifest = parseProbeFxmanifest(fxmanifestText);
  const serverOnly = manifest.directives.get("server_only") ?? [];
  if (serverOnly.length !== 1 || serverOnly[0] !== "yes") {
    throw new CliError("Probe fxmanifest must declare server_only 'yes' exactly once.", 2);
  }

  const declared = new Set<string>();
  const available = new Set(files.map((file) => file.relativePath.replaceAll("\\", "/")));
  for (const rawReference of manifest.serverScripts) {
    const reference = rawReference.replaceAll("\\", "/");
    if (reference !== rawReference || reference.startsWith("@") || reference.startsWith("/")
      || /^[A-Za-z]:/u.test(reference) || reference.split("/").includes("..")
      || /[*?\[\]]/u.test(reference) || !/\.lua$/u.test(reference)) {
      throw new CliError("Probe server scripts must be explicit local .lua files without traversal or globs.", 2);
    }
    if (!containsPath(probeRoot, resolve(probeRoot, reference)) || !available.has(reference)) {
      throw new CliError(`Probe server script ${basename(reference)} is missing from the inspected source tree.`, 2);
    }
    if (declared.has(reference)) throw new CliError(`Probe server script ${basename(reference)} is declared more than once.`, 2);
    declared.add(reference);
  }
  const executable = [...available]
    .filter((path) => isCodeFile(path) && basename(path) !== "fxmanifest.lua")
    .sort(compareText);
  const declaredSorted = [...declared].sort(compareText);
  if (executable.length !== declaredSorted.length
    || executable.some((path, index) => path !== declaredSorted[index])) {
    throw new CliError("Every probe executable must be a declared local server script, with no unreferenced code.", 2);
  }
}

async function collectTrackedTreeFiles(repositoryRoot: string, prefix: string): Promise<TreeFile[]> {
  const normalizedPrefix = prefix.replaceAll("\\", "/").replace(/^\/+|\/+$/gu, "");
  const result = spawnSync("git", ["ls-files", "-z", "--stage", "--", normalizedPrefix], {
    cwd: repositoryRoot,
    encoding: "utf8",
    timeout: 10_000,
    windowsHide: true,
  });
  if (result.error || result.status !== 0) {
    throw new CliError(`Unable to enumerate tracked files for ${normalizedPrefix}.`, 2);
  }
  const realRepository = await realpath(repositoryRoot);
  const files: TreeFile[] = [];
  for (const entry of result.stdout.split("\0").filter(Boolean)) {
    const match = /^([0-9]{6}) ([0-9a-f]{40,64}) ([0-3])\t(.+)$/u.exec(entry);
    if (!match || match[3] !== "0" || !["100644", "100755"].includes(match[1] ?? "")) {
      throw new CliError(`Tracked ${normalizedPrefix} tree contains an unsupported Git entry.`, 2);
    }
    const trackedPath = match[4] ?? "";
    if (!trackedPath.startsWith(`${normalizedPrefix}/`)) {
      throw new CliError(`Tracked ${normalizedPrefix} path escaped its expected prefix.`, 2);
    }
    const relativePath = trackedPath.slice(normalizedPrefix.length + 1);
    const absolutePath = resolve(repositoryRoot, ...trackedPath.split("/"));
    const [metadata, resolvedFile] = await Promise.all([lstat(absolutePath), realpath(absolutePath)]);
    if (!metadata.isFile() || metadata.isSymbolicLink() || !containsPath(realRepository, resolvedFile)) {
      throw new CliError(`Tracked ${normalizedPrefix} source contains a link or non-regular file.`, 2);
    }
    files.push({ absolutePath, relativePath, size: metadata.size });
  }
  if (files.length === 0) throw new CliError(`Tracked ${normalizedPrefix} source tree is empty.`, 2);
  return files.sort((left, right) => compareText(left.relativePath, right.relativePath));
}

function luaNodeArray(node: unknown, key: string): LuaAstNode[] {
  if (!isRecord(node) || !Array.isArray(node[key])) return [];
  return node[key].filter((entry): entry is LuaAstNode => isRecord(entry));
}

function luaIdentifier(node: unknown): string | null {
  return isRecord(node) && node.type === "Identifier" && typeof node.name === "string"
    ? node.name
    : null;
}

function luaStaticString(node: unknown): string | null {
  const value = luaStringLiteral(node);
  if (value !== null) return value;
  if (!isRecord(node) || node.type !== "StringLiteral" || typeof node.raw !== "string") return null;
  const literal = /^(?:'([^'\\\r\n]*)'|"([^"\\\r\n]*)")$/u.exec(node.raw);
  return literal ? (literal[1] ?? literal[2] ?? "") : null;
}

function inspectProbeKvp(texts: Map<string, string>): boolean {
  const parsedFiles: Array<{
    path: string;
    ast: LuaAstNode;
    identifiers: Array<{ name: string; node: LuaAstNode }>;
    calls: ProbeKvpCall[];
  }> = [];
  for (const [path, source] of texts) {
    if (extname(path).toLowerCase() !== ".lua" || basename(path) === "fxmanifest.lua") continue;
    const parsed = parseLuaAst(source);
    if (!parsed.ast || parsed.error) {
      throw new CliError(`Probe Lua source ${basename(path)} could not be parsed for KVP verification.`, 2);
    }
    const identifiers: Array<{ name: string; node: LuaAstNode }> = [];
    const calls: ProbeKvpCall[] = [];
    walkLuaAst(parsed.ast, (node) => {
      if (node.type === "Identifier") {
        const name = luaIdentifier(node);
        if (name && /Kvp/u.test(name)) identifiers.push({ name, node });
      }
      if (node.type === "CallExpression") {
        const name = luaExpressionName(node.base);
        if (name && /Kvp/u.test(name)) {
          calls.push({ arguments: luaCallArguments(node), base: node.base, name, node });
        }
      }
    });
    if (identifiers.length > 0 || calls.length > 0) parsedFiles.push({ path, ast: parsed.ast, identifiers, calls });
  }

  if (parsedFiles.length > 1) {
    throw new CliError("Probe KVP access must be isolated in one reviewed source file.", 2);
  }
  const parsedFile = parsedFiles[0];
  if (!parsedFile) return false;
  if (parsedFile.identifiers.some((identifier) => !ALLOWED_KVP_FUNCTIONS.has(identifier.name))
    || parsedFile.calls.some((call) => !ALLOWED_KVP_FUNCTIONS.has(call.name))) {
    throw new CliError("Probe uses KVP enumeration, external access, asynchronous writes, or another unsupported KVP native.", 2);
  }
  const callNames = parsedFile.calls.map((call) => call.name);
  const hasGetter = callNames.includes("GetResourceKvpString") || callNames.includes("GetResourceKvpInt");
  const hasSetter = callNames.includes("SetResourceKvp") || callNames.includes("SetResourceKvpInt");
  if (!hasGetter || !hasSetter || !callNames.includes("DeleteResourceKvp")) {
    throw new CliError("Probe KVP state must use a synchronous getter/setter and delete its exact key after the restart check.", 2);
  }
  const callBases = new Set(parsedFile.calls.map((call) => call.base));
  if (parsedFile.identifiers.some((identifier) => !callBases.has(identifier.node))) {
    throw new CliError("Probe must not alias or indirectly invoke KVP natives.", 2);
  }

  const body = luaNodeArray(parsedFile.ast, "body");
  const runCandidates: Array<{ name: string; node: LuaAstNode }> = [];
  for (const statement of body) {
    if (statement.type !== "LocalStatement") continue;
    const variables = luaNodeArray(statement, "variables");
    const initializers = luaNodeArray(statement, "init");
    if (variables.length !== 1 || initializers.length !== 1) continue;
    const initializer = initializers[0];
    if (initializer?.type !== "CallExpression" || luaExpressionName(initializer.base) !== "GetConvar"
      || luaStaticString(luaCallArguments(initializer)[0]) !== "synex_probe_run_id") continue;
    const name = luaIdentifier(variables[0]);
    if (name) runCandidates.push({ name, node: statement });
  }
  if (runCandidates.length !== 1) {
    throw new CliError("Probe KVP state requires one top-level local synex_probe_run_id binding.", 2);
  }
  const runBinding = runCandidates[0];
  if (!runBinding) throw new CliError("Probe KVP run binding is unavailable.", 2);

  const keyCandidates: Array<{ name: string; node: LuaAstNode }> = [];
  for (const statement of body) {
    if (statement.type !== "LocalStatement") continue;
    const variables = luaNodeArray(statement, "variables");
    const initializers = luaNodeArray(statement, "init");
    const initializer = initializers[0];
    if (variables.length !== 1 || initializers.length !== 1 || initializer?.type !== "BinaryExpression"
      || initializer.operator !== ".."
      || luaStaticString(initializer.left) !== "synex_core_probe.owner_epoch.v1:"
      || luaIdentifier(initializer.right) !== runBinding.name) continue;
    const name = luaIdentifier(variables[0]);
    if (name) keyCandidates.push({ name, node: statement });
  }
  if (keyCandidates.length !== 1) {
    throw new CliError("Probe KVP state requires one top-level local reviewed owner-epoch key binding.", 2);
  }
  const keyBinding = keyCandidates[0];
  if (!keyBinding) throw new CliError("Probe KVP key binding is unavailable.", 2);

  let runDeclarations = 0;
  let keyDeclarations = 0;
  let reassigned = false;
  let getConvarCalls = 0;
  walkLuaAst(parsedFile.ast, (node) => {
    if (node.type === "LocalStatement") {
      for (const variable of luaNodeArray(node, "variables")) {
        const name = luaIdentifier(variable);
        if (name === runBinding.name) runDeclarations += 1;
        if (name === keyBinding.name) keyDeclarations += 1;
      }
    }
    if (node.type === "FunctionDeclaration") {
      const declaredName = luaIdentifier(node.identifier);
      if (declaredName === runBinding.name || declaredName === keyBinding.name) reassigned = true;
      for (const parameter of luaNodeArray(node, "parameters")) {
        const name = luaIdentifier(parameter);
        if (name === runBinding.name || name === keyBinding.name) reassigned = true;
      }
    }
    if (node.type === "ForGenericStatement" || node.type === "ForNumericStatement") {
      const variables = node.type === "ForNumericStatement" ? [node.variable] : node.variables;
      if (Array.isArray(variables) && variables.some((variable) => {
        const name = luaIdentifier(variable);
        return name === runBinding.name || name === keyBinding.name;
      })) reassigned = true;
    }
    if (node.type === "AssignmentStatement" && luaNodeArray(node, "variables").some((variable) => {
      const name = luaIdentifier(variable);
      return name === runBinding.name || name === keyBinding.name;
    })) reassigned = true;
    if (node.type === "CallExpression" && luaExpressionName(node.base) === "GetConvar") getConvarCalls += 1;
  });
  if (runDeclarations !== 1 || keyDeclarations !== 1 || reassigned || getConvarCalls !== 1) {
    throw new CliError("Probe KVP run and key bindings must be unique, immutable, and unshadowed.", 2);
  }

  const runLine = runBinding.node.loc?.start?.line ?? 0;
  const keyLine = keyBinding.node.loc?.start?.line ?? 0;
  if (runLine <= 0 || keyLine <= runLine || parsedFile.calls.some((call) =>
    (call.node.loc?.start?.line ?? 0) <= keyLine
    || luaIdentifier(call.arguments[0]) !== keyBinding.name
  )) {
    throw new CliError("Every probe KVP call must directly use the immutable reviewed run-scoped owner-epoch key.", 2);
  }
  return true;
}

async function inspectProbeTree(sourceRoot: string): Promise<ProbeInspection> {
  const files = await collectTreeFiles(sourceRoot, {
    maximumFiles: MAX_PROBE_FILES,
    maximumFileBytes: MAX_PROBE_FILE_BYTES,
    maximumTotalBytes: MAX_PROBE_TOTAL_BYTES,
    maximumDepth: MAX_PROBE_DEPTH,
  });
  const texts = new Map<string, string>();
  const decoder = new TextDecoder("utf-8", { fatal: true });
  for (const file of files) {
    if (forbiddenProbeFile(file.relativePath)) {
      throw new CliError(`Probe contains forbidden file ${basename(file.relativePath)}.`, 2);
    }
    const contents = await readFile(file.absolutePath);
    let decoded: string;
    try {
      decoded = decoder.decode(contents);
    } catch {
      throw new CliError(`Probe file ${basename(file.relativePath)} is not valid UTF-8 text.`, 2);
    }
    if (decoded.includes("\0")) {
      throw new CliError(`Probe file ${basename(file.relativePath)} contains forbidden NUL bytes.`, 2);
    }
    if (SECRET_PATTERNS.some((pattern) => pattern.test(decoded))) {
      throw new CliError(`Probe file ${basename(file.relativePath)} contains secret-like material.`, 2);
    }
    const reviewSource = extname(file.relativePath).toLowerCase() === ".lua"
      ? stripLuaComments(decoded)
      : decoded;
    if (isCodeFile(file.relativePath) && basename(file.relativePath) !== "fxmanifest.lua"
      && FORBIDDEN_PROBE_CODE.some((pattern) => pattern.test(reviewSource))) {
      throw new CliError(`Probe file ${basename(file.relativePath)} contains an operation forbidden in the isolated probe.`, 2);
    }
    texts.set(file.relativePath, decoded);
  }

  validateProbeCodeBoundaries(texts);
  const fxmanifest = texts.get("fxmanifest.lua");
  if (!fxmanifest) throw new CliError("Probe fxmanifest.lua was not included in the inspected source tree.", 2);
  validateProbeExecutableInventory(sourceRoot, files, fxmanifest);

  const kvpStaticKeyScoped = inspectProbeKvp(texts);
  return {
    files,
    totalBytes: files.reduce((total, file) => total + file.size, 0),
    kvpStaticKeyScoped,
  };
}

function assertExactStrings(actual: string[], expected: readonly string[], label: string): void {
  const normalized = [...actual].sort(compareText);
  const required = [...expected].sort(compareText);
  if (normalized.length !== required.length
    || normalized.some((entry, index) => entry !== required[index])) {
    throw new CliError(`${label} must contain exactly: ${required.join(", ")}.`, 2);
  }
}

async function validateProbeManifest(repositoryRoot: string, probeRoot: string): Promise<void> {
  const manifestPath = join(probeRoot, "synex.resource.json");
  const fxmanifestPath = join(probeRoot, "fxmanifest.lua");
  if (!(await pathExists(manifestPath)) || !(await pathExists(fxmanifestPath))) {
    throw new CliError("Probe requires adjacent synex.resource.json and fxmanifest.lua files.", 2);
  }
  const schemas = await loadSchemaRegistry(repositoryRoot);
  const value = await readJsonFile(manifestPath);
  if (!schemas.resource(value) || !isResourceManifest(value)) {
    const detail = schemas.resource.errors?.[0];
    throw new CliError(
      `Probe resource manifest is invalid${detail ? ` at ${detail.instancePath || "/"}: ${detail.message ?? "schema mismatch"}` : ""}.`,
      2,
    );
  }
  if (value.name !== PROBE_RESOURCE || basename(probeRoot) !== PROBE_RESOURCE) {
    throw new CliError(`Probe directory and manifest name must both be ${PROBE_RESOURCE}.`, 2);
  }
  if (value.critical || value.migrations.length > 0 || value.dataOwnership.tables.length > 0
    || value.stateSnapshot.supported) {
    throw new CliError("Probe must be non-critical and must not own migrations, tables, or persistent state snapshots.", 2);
  }
  assertExactStrings(value.capabilities.request, CORE_PROBE_CAPABILITIES, "Probe capability requests");
  const allDependencies = [
    ...value.dependencies.required,
    ...value.dependencies.optional,
    ...value.dependencies.development,
  ];
  if (allDependencies.length !== 1
    || value.dependencies.required.length !== 1
    || value.dependencies.required[0]?.name !== "synex_core") {
    throw new CliError("Probe must declare synex_core as its only dependency.", 2);
  }

  const fxmanifest = parseProbeFxmanifest(await readTextFile(fxmanifestPath));
  const values = [...fxmanifest.directives.values()].flat();
  const unsafeLiteral = [...values, ...fxmanifest.files, ...fxmanifest.serverScripts]
    .some((literal) => literal.startsWith("@") || literal.startsWith("/")
      || /^[A-Za-z]:[\\/]/u.test(literal) || /^https?:\/\//iu.test(literal)
      || literal.replaceAll("\\", "/").split("/").includes(".."));
  const directive = (name: string): string[] => fxmanifest.directives.get(name) ?? [];
  if (directive("fx_version").length !== 1 || directive("fx_version")[0] !== "cerulean"
    || directive("game").length !== 1 || directive("game")[0] !== "gta5"
    || directive("name").length !== 1 || directive("name")[0] !== PROBE_RESOURCE
    || directive("version").length !== 1 || directive("version")[0] !== value.version
    || directive("server_only").length !== 1 || directive("server_only")[0] !== "yes"
    || directive("synex_manifest").length !== 1 || directive("synex_manifest")[0] !== "synex.resource.json"
    || directive("dependency").length !== 1 || directive("dependency")[0] !== "synex_core"
    || directive("author").length > 1 || directive("description").length > 1
    || unsafeLiteral) {
    throw new CliError("Probe fxmanifest must identify synex_core_probe, its Synex manifest, one synex_core dependency, and server-only code exactly.", 2);
  }
}

async function ensureSafeOutputParent(repositoryRoot: string, outputParent: string): Promise<void> {
  const repository = resolve(repositoryRoot);
  const repositoryMetadata = await lstat(repository);
  if (!repositoryMetadata.isDirectory() || repositoryMetadata.isSymbolicLink()) {
    throw new CliError("Repository root must be a real directory.", 2);
  }
  const relativeParent = relative(repository, outputParent);
  let existingAncestor = repository;
  for (const component of relativeParent.split(/[\\/]/u).filter(Boolean)) {
    const candidate = join(existingAncestor, component);
    const metadata = await lstat(candidate).catch(() => null);
    if (!metadata) break;
    if (!metadata.isDirectory() || metadata.isSymbolicLink()) {
      throw new CliError("Live-test output must not traverse symbolic links or non-directory components.", 2);
    }
    existingAncestor = candidate;
  }
  const [realRepository, realAncestor] = await Promise.all([
    realpath(repository),
    realpath(existingAncestor),
  ]);
  if (!containsPath(realRepository, realAncestor)) {
    throw new CliError("Live-test output resolved outside the repository boundary.", 2);
  }
  await mkdir(outputParent, { recursive: true });
  const [realParent, parentMetadata] = await Promise.all([realpath(outputParent), lstat(outputParent)]);
  if (!parentMetadata.isDirectory() || parentMetadata.isSymbolicLink()
    || !containsPath(realRepository, realParent)) {
    throw new CliError("Live-test output parent is not a real repository directory.", 2);
  }
}

async function copyTree(files: TreeFile[], targetRoot: string): Promise<void> {
  for (const file of files) {
    const target = resolveWithin(targetRoot, file.relativePath);
    await mkdir(dirname(target), { recursive: true });
    await copyFile(file.absolutePath, target, constants.COPYFILE_EXCL);
  }
}

async function removeCreatedBundle(
  repositoryRoot: string,
  liveTestRoot: string,
  output: string,
): Promise<void> {
  if (output === liveTestRoot || !containsPath(liveTestRoot, output)) {
    throw new CliError("Refusing to clean an unverified live-test output path.", 2);
  }
  const metadata = await lstat(output).catch(() => null);
  if (!metadata) return;
  if (metadata.isSymbolicLink() || !metadata.isDirectory()) {
    await rm(output, { force: true });
    return;
  }
  const [realRepository, realLiveTestRoot, realOutput] = await Promise.all([
    realpath(repositoryRoot),
    realpath(liveTestRoot),
    realpath(output),
  ]);
  if (!containsPath(realRepository, realOutput)
    || realOutput === realLiveTestRoot
    || !containsPath(realLiveTestRoot, realOutput)) {
    throw new CliError("Refusing to clean a live-test directory outside the verified disposable boundary.", 2);
  }
  await rm(output, { recursive: true, force: true });
}

async function hashTree(root: string, files?: TreeFile[]): Promise<string> {
  const selected = files ?? await collectTreeFiles(root);
  const hash = createHash("sha256");
  for (const file of selected) {
    hash.update(file.relativePath.replaceAll("\\", "/"));
    hash.update("\0");
    hash.update(await readFile(file.absolutePath));
    hash.update("\0");
  }
  return hash.digest("hex");
}

function policyCovers(pattern: string, capability: string): boolean {
  if (pattern === "*" || pattern === capability) return true;
  return pattern.endsWith(".*") && capability.startsWith(pattern.slice(0, -1));
}

async function patchCopiedPolicy(
  repositoryRoot: string,
  copiedCore: string,
  productionPolicyText: string,
): Promise<string> {
  const policyPath = join(repositoryRoot, "core", "synex_core", "config", "capabilities.json");
  const schemas = await loadSchemaRegistry(repositoryRoot);
  const policy = JSON.parse(productionPolicyText) as unknown;
  if (!schemas.capabilityPolicy(policy) || !isRecord(policy)
    || !isRecord(policy.default) || !isRecord(policy.resources)) {
    throw new CliError("Production capability policy is invalid; refusing to derive a test policy.", 2);
  }
  if (Object.hasOwn(policy.resources, PROBE_RESOURCE)) {
    throw new CliError("Production capability policy already contains synex_core_probe; remove the test grant before preparing a bundle.", 2);
  }
  const defaultDenies = Array.isArray(policy.default.deny)
    ? policy.default.deny.filter((entry): entry is string => typeof entry === "string")
    : [];
  const defaultAllows = Array.isArray(policy.default.allow)
    ? policy.default.allow.filter((entry): entry is string => typeof entry === "string")
    : [];
  const additionalDefaultGrant = defaultAllows.find((pattern) =>
    !CORE_PROBE_CAPABILITIES.some((capability) => capability === pattern)
  );
  if (additionalDefaultGrant) {
    throw new CliError(
      `Production default allow ${additionalDefaultGrant} would grant the probe more than the four reviewed capabilities.`,
      2,
    );
  }
  const blocked = CORE_PROBE_CAPABILITIES.find((capability) =>
    defaultDenies.some((pattern) => policyCovers(pattern, capability))
  );
  if (blocked) {
    throw new CliError(`Production default deny covers ${blocked}; the test builder will not weaken it.`, 2);
  }

  const patched = structuredClone(policy);
  if (!isRecord(patched.resources)) throw new CliError("Capability policy resources are unavailable.", 2);
  patched.resources[PROBE_RESOURCE] = {
    allow: [...CORE_PROBE_CAPABILITIES],
    deny: [],
  };
  if (!schemas.capabilityPolicy(patched)) {
    throw new CliError("Derived test capability policy did not pass schema validation.", 2);
  }
  const testPolicyPath = join(copiedCore, "config", "capabilities.json");
  await writeFile(testPolicyPath, prettyJson(patched), { encoding: "utf8", flag: "w" });

  const reread = await readJsonFile(testPolicyPath);
  if (!isRecord(reread) || !isRecord(reread.resources)) {
    throw new CliError("Derived test capability policy could not be verified.", 2);
  }
  const probeGrant = reread.resources[PROBE_RESOURCE];
  if (!isRecord(probeGrant) || !Array.isArray(probeGrant.allow) || !Array.isArray(probeGrant.deny)) {
    throw new CliError("Derived probe grant could not be verified.", 2);
  }
  assertExactStrings(
    probeGrant.allow.filter((entry): entry is string => typeof entry === "string"),
    CORE_PROBE_CAPABILITIES,
    "Derived probe grants",
  );
  if (probeGrant.deny.length !== 0) throw new CliError("Derived probe deny list must be empty.", 2);

  const withoutProbe = structuredClone(reread);
  if (!isRecord(withoutProbe.resources)) throw new CliError("Derived policy resources are unavailable.", 2);
  delete withoutProbe.resources[PROBE_RESOURCE];
  if (canonicalJson(withoutProbe) !== canonicalJson(policy)) {
    throw new CliError("Derived test policy changed production policy entries beyond the probe grant.", 2);
  }
  if (await readTextFile(policyPath) !== productionPolicyText) {
    throw new CliError("Production capability policy changed during live-test preparation.", 2);
  }
  return await readTextFile(testPolicyPath);
}

export async function prepareCoreLiveTestBundle(
  repositoryRoot: string,
  requestedProbe: string,
  requestedOutput?: string,
): Promise<CoreLiveTestBundleReport> {
  const repository = resolve(repositoryRoot);
  const requestedProbePath = resolve(requestedProbe);
  const probeMetadata = await lstat(requestedProbePath).catch(() => null);
  if (!probeMetadata?.isDirectory() || probeMetadata.isSymbolicLink()) {
    throw new CliError("--probe must reference a real external directory.", 2);
  }
  const [realRepository, probeRoot] = await Promise.all([realpath(repository), realpath(requestedProbePath)]);
  if (containsPath(realRepository, probeRoot)) {
    throw new CliError("The live-test probe must remain outside the repository checkout.", 2);
  }

  await validateProbeManifest(repository, probeRoot);
  const probe = await inspectProbeTree(probeRoot);
  const probeSecurity = await scanSecurity(repository, probeRoot);
  if (probeSecurity.findings.length > 0) {
    throw new CliError(`Probe security scan found ${probeSecurity.findings.length} review finding(s); the privileged probe must scan cleanly.`, 2);
  }

  const revision = requireCleanRevision(repository);
  const repositoryValidation = await validateRepository(repository);
  const repositoryErrors = repositoryValidation.diagnostics.filter((diagnostic) => diagnostic.level === "error");
  if (repositoryErrors.length > 0) {
    throw new CliError(`Repository validation has ${repositoryErrors.length} error(s); run npm run certify before live testing.`, 2);
  }

  const runId = `probe_${randomBytes(16).toString("hex")}`;
  const instanceId = `probe_${runId.slice(-24)}`;
  const kvpKey = `synex_core_probe.owner_epoch.v1:${runId}`;
  const liveTestRoot = resolveWithin(repository, LIVE_TEST_ROOT);
  const output = requestedOutput
    ? resolveWithin(repository, requestedOutput)
    : resolveWithin(repository, join(LIVE_TEST_ROOT, `core-${runId}`));
  if (output === liveTestRoot || !containsPath(liveTestRoot, output)) {
    throw new CliError("Live-test output must be a new child directory of .temp/live-test.", 2);
  }
  if (await pathExists(output)) throw new CliError("Live-test output already exists; it will not be overwritten.", 2);

  const coreSource = join(repository, "core", "synex_core");
  const schemaSource = join(repository, "schemas");
  const policyPath = join(coreSource, "config", "capabilities.json");
  const productionPolicyText = await readTextFile(policyPath);
  const productionPolicyHash = sha256(productionPolicyText);
  const [coreFiles, schemaFiles, sourceProbeHash] = await Promise.all([
    collectTrackedTreeFiles(repository, join("core", "synex_core")),
    collectTrackedTreeFiles(repository, "schemas"),
    hashTree(probeRoot, probe.files),
  ]);
  const [sourceCoreHash, sourceSchemaHash] = await Promise.all([
    hashTree(coreSource, coreFiles),
    hashTree(schemaSource, schemaFiles),
  ]);

  await ensureSafeOutputParent(repository, dirname(output));
  await mkdir(output, { recursive: false });
  let created = true;
  try {
    const bundledCore = join(output, "core", "synex_core");
    const bundledProbe = join(output, "resources", PROBE_RESOURCE);
    const bundledSchemas = join(output, "schemas");
    await Promise.all([
      copyTree(coreFiles, bundledCore),
      copyTree(probe.files, bundledProbe),
      copyTree(schemaFiles, bundledSchemas),
    ]);
    const [copiedCoreHash, copiedProbeHash, copiedSchemaHash] = await Promise.all([
      hashTree(bundledCore),
      hashTree(bundledProbe),
      hashTree(bundledSchemas),
    ]);
    if (copiedCoreHash !== sourceCoreHash || copiedProbeHash !== sourceProbeHash
      || copiedSchemaHash !== sourceSchemaHash) {
      throw new CliError("Live-test resource copy verification failed.", 2);
    }

    await validateProbeManifest(output, bundledProbe);
    const copiedProbeInspection = await inspectProbeTree(bundledProbe);
    if (copiedProbeInspection.kvpStaticKeyScoped !== probe.kvpStaticKeyScoped
      || copiedProbeInspection.files.length !== probe.files.length
      || copiedProbeInspection.totalBytes !== probe.totalBytes) {
      throw new CliError("Copied probe failed strict source reinspection.", 2);
    }

    const testPolicyText = await patchCopiedPolicy(repository, bundledCore, productionPolicyText);
    const bundleValidation = await validateRepository(output);
    const validationErrors = bundleValidation.diagnostics.filter((diagnostic) => diagnostic.level === "error");
    if (validationErrors.length > 0) {
      throw new CliError(`Prepared bundle validation found ${validationErrors.length} error(s).`, 2);
    }
    const permissions = await inspectPermissions(output);
    const permissionErrors = permissions.diagnostics.filter((diagnostic) => diagnostic.level === "error");
    const permissionWarnings = permissions.diagnostics.filter((diagnostic) => diagnostic.level === "warning");
    if (permissionErrors.length > 0) {
      throw new CliError(`Prepared bundle permission analysis found ${permissionErrors.length} error(s).`, 2);
    }
    const probePermissions = permissions.resources.find((entry) => entry.resource === PROBE_RESOURCE);
    if (!probePermissions) throw new CliError("Prepared bundle did not expose probe permissions for verification.", 2);
    assertExactStrings(probePermissions.requested, CORE_PROBE_CAPABILITIES, "Prepared probe requests");
    assertExactStrings(probePermissions.granted, CORE_PROBE_CAPABILITIES, "Prepared probe grants");
    if (probePermissions.denied.length > 0 || probePermissions.notGranted.length > 0) {
      throw new CliError("Prepared probe contains denied or ungranted capabilities.", 2);
    }

    const serverData = join(output, "server-data");
    const runtimeResources = join(serverData, "resources");
    const runtimeCore = join(runtimeResources, "synex_core");
    const runtimeProbe = join(runtimeResources, PROBE_RESOURCE);
    const runtimeSchemas = join(serverData, "schemas");
    await mkdir(runtimeResources, { recursive: true });
    await Promise.all([
      rename(bundledCore, runtimeCore),
      rename(bundledProbe, runtimeProbe),
      rename(bundledSchemas, runtimeSchemas),
    ]);
    await Promise.all([rmdir(join(output, "core")), rmdir(join(output, "resources"))]);

    const configurationPath = join(serverData, "live-test.cfg.example");
    const configuration = [
      "# SYNEX DISPOSABLE LIVE TEST ONLY - DO NOT DEPLOY",
      "# Supply database and license settings separately.",
      "# This file intentionally contains no credentials.",
      "# Execute this fragment from the isolated server's startup configuration.",
      "# Required beforehand: endpoints, sv_licenseKey, mysql_connection_string, and reviewed oxmysql >= 2.14.1.",
      "set synex_environment \"staging\"",
      "set synex_strict \"1\"",
      `set synex_instance_id \"${instanceId}\"`,
      `set synex_probe_run_id \"${runId}\"`,
      "",
      "ensure oxmysql",
      "ensure synex_core",
      `ensure ${PROBE_RESOURCE}`,
      "",
    ].join("\n");
    await writeFile(configurationPath, configuration, { encoding: "utf8", flag: "wx" });

    const runtimeValidation = await validateRepository(serverData, runtimeResources);
    const runtimeValidationErrors = runtimeValidation.diagnostics.filter((diagnostic) => diagnostic.level === "error");
    const runtimeValidationWarnings = runtimeValidation.diagnostics.filter((diagnostic) => diagnostic.level === "warning");
    if (runtimeValidationErrors.length > 0) {
      throw new CliError(`Deployment-layout validation found ${runtimeValidationErrors.length} error(s).`, 2);
    }
    await validateProbeManifest(serverData, runtimeProbe);
    const runtimeProbeInspection = await inspectProbeTree(runtimeProbe);
    if (runtimeProbeInspection.kvpStaticKeyScoped !== probe.kvpStaticKeyScoped
      || runtimeProbeInspection.files.length !== probe.files.length
      || runtimeProbeInspection.totalBytes !== probe.totalBytes) {
      throw new CliError("Deployment-layout probe failed strict source reinspection.", 2);
    }
    const bundleSecurity = await scanSecurity(serverData, serverData);
    if (bundleSecurity.findings.length > 0) {
      throw new CliError(`Prepared bundle security scan found ${bundleSecurity.findings.length} review finding(s).`, 2);
    }

    const [bundledCoreHash, bundledProbeHash] = await Promise.all([
      hashTree(runtimeCore),
      hashTree(runtimeProbe),
    ]);
    if (bundledProbeHash !== sourceProbeHash) {
      throw new CliError("Deployment-layout probe hash differs from its inspected source.", 2);
    }
    const report: CoreLiveTestBundleReport = {
      schema: 2,
      artifactKind: "synex-core-live-test-bundle",
      status: "PREPARED",
      revision,
      runId,
      instanceId,
      kvpIsolation: {
        strategy: "run-scoped-resource-key",
        key: kvpKey,
        cleanupRequired: true,
      },
      bundle: displayPath(repository, output),
      resources: {
        core: displayPath(repository, runtimeCore),
        probe: displayPath(repository, runtimeProbe),
      },
      configuration: displayPath(repository, configurationPath),
      grants: [...CORE_PROBE_CAPABILITIES],
      validation: {
        warnings: runtimeValidationWarnings.length,
        permissionWarnings: permissionWarnings.length,
      },
      runtimeRequirements: {
        resources: [{ name: "oxmysql", version: ">=2.14.1" }],
        operatorConfiguration: ["mysql_connection_string", "sv_licenseKey", "endpoint_add_tcp", "endpoint_add_udp"],
      },
      hashes: {
        configuration: sha256(configuration),
        productionPolicy: productionPolicyHash,
        testPolicy: sha256(testPolicyText),
        sourceCoreTree: sourceCoreHash,
        bundledCoreTree: bundledCoreHash,
        sourceProbeTree: sourceProbeHash,
        bundledProbeTree: copiedProbeHash,
      },
      probe: {
        files: probe.files.length,
        bytes: probe.totalBytes,
        securityFindings: probeSecurity.findings.length,
        kvpStaticKeyScoped: probe.kvpStaticKeyScoped,
      },
      safeguards: {
        productionPolicyUnchanged: true,
        cleanRevision: true,
        ignoredDisposableOutput: true,
        exactCapabilitiesOnly: true,
        runScopedKvpKey: true,
        symlinksRejected: true,
      },
    };
    await writeFile(join(output, "bundle.json"), prettyJson(report), { encoding: "utf8", flag: "wx" });

    if (await readTextFile(policyPath) !== productionPolicyText
      || sha256(await readTextFile(policyPath)) !== productionPolicyHash) {
      throw new CliError("Production capability policy changed during bundle creation.", 2);
    }
    if (gitOutput(repository, ["status", "--porcelain=v1", "--untracked-files=normal"]).length > 0) {
      throw new CliError("Disposable output is not ignored cleanly; refusing to retain the bundle.", 2);
    }
    if (gitOutput(repository, ["rev-parse", "--verify", "HEAD"]) !== revision) {
      throw new CliError("Git HEAD changed during live-test preparation; refusing a mixed-revision bundle.", 2);
    }
    created = false;
    return report;
  } finally {
    if (created) await removeCreatedBundle(repository, liveTestRoot, output);
  }
}
