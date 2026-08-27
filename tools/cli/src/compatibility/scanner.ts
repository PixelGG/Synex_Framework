import { lstat, readFile, readdir } from "node:fs/promises";
import { basename, isAbsolute, join, relative, resolve, sep } from "node:path";

import { CliError } from "../errors.ts";
import { displayPath } from "../filesystem.ts";
import type {
  CompatibilityFinding,
  CompatibilityFramework,
  CompatibilityProvider,
  CompatibilityReport,
} from "./types.ts";

const MAX_FILES = 10_000;
const MAX_FILE_BYTES = 2 * 1024 * 1024;
const MAX_TOTAL_BYTES = 32 * 1024 * 1024;
const MAX_DEPTH = 32;
const SKIPPED_DIRECTORIES = new Set([
  ".build", ".git", ".synex", ".temp", "artifacts", "coverage", "dist", "node_modules", "tmp",
]);

interface ScanFile {
  path: string;
  language: "lua" | "javascript" | "typescript";
  manifest: boolean;
  bytes: number;
}

interface FrameworkPattern {
  framework: CompatibilityFramework;
  provider: CompatibilityProvider | null;
  pattern: RegExp;
  signal: string;
  note: string;
}

interface SurfacePattern {
  providers: CompatibilityProvider[];
  pattern: RegExp;
  surface: string;
  domain: CompatibilityFinding["domain"];
  note: string;
}

interface DomainPattern {
  pattern: RegExp;
  domain: Exclude<CompatibilityFinding["domain"], null>;
  signal: string;
  note: string;
}

const FRAMEWORK_PATTERNS: FrameworkPattern[] = [
  {
    framework: "synex", provider: null,
    pattern: /(?:exports\s*(?:\[\s*["']synex_core["']\s*\]|\.synex_core)|\bSynex\s*\.)/iu,
    signal: "Native Synex API", note: "No legacy bridge is indicated by this signal.",
  },
  {
    framework: "qbcore", provider: "qb", pattern: /(?:\bQBCore\b|["']qb-core["'])/iu,
    signal: "QBCore API", note: "Resolve each used surface against the checked-in QB catalog.",
  },
  {
    framework: "qbx", provider: "qbx", pattern: /(?:\bQBX\b|["']qbx_core["']|\bqbx_core\b)/iu,
    signal: "Qbox API", note: "Qbox and QBCore are separate providers and must not be conflated.",
  },
  {
    framework: "esx", provider: "esx", pattern: /(?:\bESX\b|["']es_extended["']|\bxPlayer\b)/iu,
    signal: "ESX API", note: "Resolve each used surface against the checked-in ESX catalog.",
  },
  {
    framework: "vrp", provider: null,
    pattern: /(?:\bvRP\b|Tunnel\s*\.\s*bindInterface|Proxy\s*\.\s*getInterface)/u,
    signal: "vRP API", note: "No vRP compatibility provider is cataloged in this snapshot.",
  },
  {
    framework: "ox_core", provider: null, pattern: /(?:["']ox_core["']|\bOxPlayer\b|\bOxAccount\b)/u,
    signal: "ox_core API", note: "No ox_core compatibility provider is cataloged in this snapshot.",
  },
];

const QB_EXPORT_RECEIVER = String.raw`\bexports\s*\[\s*["']qb-core["']\s*\]`;
const QBX_EXPORT_RECEIVER = String.raw`\bexports\s*(?:\[\s*["']qbx_core["']\s*\]|\.\s*qbx_core)`;
const ESX_EXPORT_RECEIVER = String.raw`\bexports\s*(?:\[\s*["']es_extended["']\s*\]|\.\s*es_extended)`;
const PLAYER_FUNCTIONS_RECEIVER = String.raw`\b(?:[A-Za-z_][A-Za-z0-9_]*)?[Pp]layer[A-Za-z0-9_]*\s*\.\s*Functions`;
const XPLAYER_RECEIVER = String.raw`\b(?:[A-Za-z_][A-Za-z0-9_]*)?[xX]Player[A-Za-z0-9_]*`;

function receiverCall(receivers: string[], methods: string[]): RegExp {
  return new RegExp(
    String.raw`(?:${receivers.join("|")})\s*[.:]\s*(?:${methods.join("|")})\s*\(`,
    "u",
  );
}

const qbServerCall = (methods: string[]): RegExp => receiverCall([
  String.raw`\bQBCore\s*\.\s*Functions`, QB_EXPORT_RECEIVER,
], methods);
const qbxServerCall = (methods: string[]): RegExp => receiverCall([
  String.raw`\bQBX(?:\s*\.\s*Functions)?`, QBX_EXPORT_RECEIVER,
], methods);
const esxServerCall = (methods: string[]): RegExp => receiverCall([
  String.raw`\bESX`, ESX_EXPORT_RECEIVER,
], methods);
const playerFunctionsCall = (methods: string[]): RegExp =>
  receiverCall([PLAYER_FUNCTIONS_RECEIVER], methods);
const xPlayerCall = (methods: string[]): RegExp => receiverCall([XPLAYER_RECEIVER], methods);

const SURFACE_PATTERNS: SurfacePattern[] = [
  { providers: ["qb"], pattern: receiverCall([QB_EXPORT_RECEIVER], ["GetCoreObject"]), surface: "qb.server.core_object", domain: null, note: "Core-object facades expose only cataloged detached behavior." },
  { providers: ["qb"], pattern: qbServerCall(["GetPlayer"]), surface: "qb.server.player_lookup", domain: "identity", note: "Connected-player projection support is provider- and profile-specific." },
  { providers: ["qb"], pattern: qbServerCall(["GetPlayerByCitizenId"]), surface: "qb.server.identifier_player_lookup", domain: "identity", note: "Citizen-identifier lookup remains an online, mapped projection." },
  { providers: ["qb"], pattern: qbServerCall(["GetPlayers", "GetQBPlayers"]), surface: "qb.server.player_enumeration", domain: "identity", note: "Enumeration is limited to connected, authorized player projections." },
  { providers: ["qb"], pattern: qbServerCall(["HasPermission", "GetPermission"]), surface: "qb.server.permission_view", domain: "identity", note: "Permission reads use the explicit Synex permission projection." },
  { providers: ["qb"], pattern: qbServerCall(["CreateCallback"]), surface: "qb.server.callback_registration", domain: "callbacks", note: "Callback ownership and bounds must be preserved." },
  { providers: ["qb"], pattern: qbServerCall(["TriggerCallback"]), surface: "qb.client.callback_invocation", domain: "callbacks", note: "Callback transport is not evidence of full player compatibility." },
  { providers: ["qb"], pattern: playerFunctionsCall(["AddMoney", "RemoveMoney", "SetMoney"]), surface: "qb.player.money_mutation", domain: "accounts", note: "Money mutations require explicit Accounts policies." },
  { providers: ["qb"], pattern: playerFunctionsCall(["SetJob", "SetGang"]), surface: "qb.player.group_mutation", domain: "groups", note: "Legacy jobs and gangs require explicit group and grade mappings." },
  { providers: ["qb"], pattern: playerFunctionsCall(["SetJobDuty"]), surface: "qb.player.duty_mutation", domain: "groups", note: "Duty mutation requires an online mapped primary job." },
  { providers: ["qb"], pattern: playerFunctionsCall(["SetMetaData"]), surface: "qb.player.metadata_mutation", domain: "identity", note: "Metadata writes remain allowlisted, fenced, and server-authoritative." },

  { providers: ["qbx"], pattern: qbxServerCall(["GetPlayer"]), surface: "qbx.server.player_lookup", domain: "identity", note: "Connected-player projection support is provider- and profile-specific." },
  { providers: ["qbx"], pattern: qbxServerCall(["GetPlayerByCitizenId"]), surface: "qbx.server.identifier_player_lookup", domain: "identity", note: "Citizen-identifier lookup remains an online, mapped projection." },
  { providers: ["qbx"], pattern: qbxServerCall(["GetOfflinePlayer"]), surface: "qbx.server.offline_player_lookup", domain: "identity", note: "Offline lookup returns a read-only detached projection." },
  { providers: ["qbx"], pattern: qbxServerCall(["GetMoney"]), surface: "qbx.server.money_read", domain: "accounts", note: "Money reads expose only mapped account aliases." },
  { providers: ["qbx"], pattern: qbxServerCall(["AddMoney", "RemoveMoney", "SetMoney"]), surface: "qbx.server.money_mutation", domain: "accounts", note: "Money mutations require explicit Accounts policies." },
  { providers: ["qbx"], pattern: qbxServerCall(["GetGroups", "HasGroup", "HasPrimaryGroup"]), surface: "qbx.server.groups_read", domain: "groups", note: "Group reads use mapped legacy names and bounded filters." },
  { providers: ["qbx"], pattern: qbxServerCall(["SetPlayerPrimaryJob", "SetPlayerPrimaryGang"]), surface: "qbx.server.primary_group_mutation", domain: "groups", note: "Primary group writes require an online mapped membership." },
  { providers: ["qbx"], pattern: qbxServerCall(["SetJob", "SetGang"]), surface: "qbx.server.group_mutation", domain: "groups", note: "Legacy jobs and gangs require explicit group and grade mappings." },
  { providers: ["qbx"], pattern: qbxServerCall(["SetJobDuty"]), surface: "qbx.server.duty_mutation", domain: "groups", note: "Duty mutation requires an online mapped primary job." },
  { providers: ["qbx"], pattern: playerFunctionsCall(["SetJob", "SetGang"]), surface: "qbx.server.group_mutation", domain: "groups", note: "Legacy player facades require explicit group and grade mappings." },
  { providers: ["qbx"], pattern: playerFunctionsCall(["SetJobDuty"]), surface: "qbx.server.duty_mutation", domain: "groups", note: "Legacy player-facade duty mutation requires an online mapped job." },
  { providers: ["qbx"], pattern: qbxServerCall(["GetMetadata"]), surface: "qbx.server.metadata_read", domain: "identity", note: "Metadata reads expose only the mapped compatibility projection." },
  { providers: ["qbx"], pattern: playerFunctionsCall(["GetMetaData"]), surface: "qbx.server.metadata_read", domain: "identity", note: "Player-facade metadata reads expose only the mapped compatibility projection." },
  { providers: ["qbx"], pattern: qbxServerCall(["SetMetadata"]), surface: "qbx.player.metadata_mutation", domain: "identity", note: "Metadata writes remain allowlisted, fenced, and server-authoritative." },
  { providers: ["qbx"], pattern: playerFunctionsCall(["SetMetaData"]), surface: "qbx.player.metadata_mutation", domain: "identity", note: "Player-facade metadata writes remain allowlisted and fenced." },

  { providers: ["esx"], pattern: esxServerCall(["getSharedObject"]), surface: "esx.server.shared_object", domain: null, note: "The shared object contains only cataloged surfaces." },
  { providers: ["esx"], pattern: esxServerCall(["GetPlayerFromId"]), surface: "esx.server.player_lookup", domain: "identity", note: "Connected-player projection support is profile-specific." },
  { providers: ["esx"], pattern: esxServerCall(["GetPlayerFromIdentifier", "GetPlayerIdFromIdentifier"]), surface: "esx.server.identifier_player_lookup", domain: "identity", note: "Identifier lookups remain limited to mapped online players." },
  { providers: ["esx"], pattern: esxServerCall(["GetPlayers", "GetExtendedPlayers"]), surface: "esx.server.player_enumeration", domain: "identity", note: "Enumeration is limited to connected, authorized player projections." },
  { providers: ["esx"], pattern: esxServerCall(["RegisterServerCallback"]), surface: "esx.server.callback_registration", domain: "callbacks", note: "Callback ownership and bounds must be preserved." },
  { providers: ["esx"], pattern: xPlayerCall(["getAccount", "getAccounts"]), surface: "esx.xplayer.accounts_read", domain: "accounts", note: "Account reads expose only mapped definitions and balances." },
  { providers: ["esx"], pattern: xPlayerCall(["addMoney", "removeMoney", "setMoney", "addAccountMoney", "removeAccountMoney", "setAccountMoney"]), surface: "esx.xplayer.money_mutation", domain: "accounts", note: "Account aliases require explicit catalog mappings." },
  { providers: ["esx"], pattern: xPlayerCall(["getAccount", "getAccounts", "addAccountMoney", "removeAccountMoney", "setAccountMoney"]), surface: "esx.xplayer.custom_accounts", domain: "accounts", note: "Custom account calls require a unique reviewed account definition." },
  { providers: ["esx"], pattern: xPlayerCall(["getGroup"]), surface: "esx.xplayer.permission_group", domain: "identity", note: "Permission-group reads use the explicit Synex permission projection." },
  { providers: ["esx"], pattern: xPlayerCall(["setMeta"]), surface: "esx.xplayer.metadata_mutation", domain: "identity", note: "Metadata writes remain allowlisted, fenced, and server-authoritative." },
  { providers: ["esx"], pattern: xPlayerCall(["setJob"]), surface: "esx.xplayer.job_mutation", domain: "groups", note: "Legacy jobs require explicit group and grade mappings." },
];

const DOMAIN_PATTERNS: DomainPattern[] = [
  { pattern: /(?:["'](?:ox_inventory|qb-inventory|qs-inventory|lj-inventory)["']|\b(?:ox_inventory|qb_inventory)\b)/iu, domain: "inventory", signal: "Legacy inventory dependency", note: "Inventory state is not translated by the current bridge catalog." },
  { pattern: /(?:["'](?:ox_target|qb-target|qtarget)["']|\b(?:ox_target|qb_target)\b)/iu, domain: "entities", signal: "Legacy interaction/target dependency", note: "Interaction targets and entity authority require a separate migration review." },
  { pattern: /\b(?:player_vehicles|owned_vehicles|vehiclemods|garage)\b/iu, domain: "vehicles", signal: "Legacy vehicle domain", note: "Vehicle rows and transient handles are not compatibility authority." },
  { pattern: /\b(?:job_grades|addon_account|management_funds|society)\b/iu, domain: "groups", signal: "Legacy organization domain", note: "Jobs, gangs, societies, and grades require explicit group mappings." },
  { pattern: /\b(?:citizenid|license2?|identifier)\b/iu, domain: "identity", signal: "Legacy identity field", note: "Legacy identity evidence must be preserved and reviewed without assuming login equivalence." },
];

const DIRECT_SQL_PATTERN = /\b(?:SELECT|INSERT\s+INTO|UPDATE|DELETE\s+FROM|REPLACE\s+INTO)\b[\s\S]{0,512}\b(?:players|users|player_vehicles|owned_vehicles|jobs|job_grades|gangs|addon_account|addon_account_data)\b/iu;
const MANIFEST_DEPENDENCY_PATTERN = /\b(?:dependency|dependencies|shared_script|server_script|client_script)\b[^\n]{0,256}["'](?:qb-core|qbx_core|es_extended|ox_core|ox_inventory|ox_target|qb-target|qb-inventory)["']/iu;

function compareText(left: string, right: string): number {
  return left < right ? -1 : left > right ? 1 : 0;
}

function languageFor(path: string): ScanFile["language"] | null {
  const lower = path.toLowerCase();
  if (lower.endsWith(".lua")) return "lua";
  if (lower.endsWith(".ts") || lower.endsWith(".mts") || lower.endsWith(".cts")) return "typescript";
  if (lower.endsWith(".js") || lower.endsWith(".mjs") || lower.endsWith(".cjs")) return "javascript";
  return null;
}

function pathInside(root: string, target: string): boolean {
  const value = relative(resolve(root), resolve(target));
  return value === "" || (!isAbsolute(value) && value !== ".." && !value.startsWith(`..${sep}`));
}

async function assertNoSymlinkComponents(root: string, target: string): Promise<void> {
  if (!pathInside(root, target)) throw new CliError("Compatibility scan target must remain inside the repository root.", 2);
  const value = relative(resolve(root), resolve(target));
  let current = resolve(root);
  for (const segment of value.split(sep).filter(Boolean)) {
    current = join(current, segment);
    const metadata = await lstat(current);
    if (metadata.isSymbolicLink()) {
      throw new CliError("Compatibility scan targets must not traverse symbolic links.", 2);
    }
  }
}

async function collectScanFiles(repositoryRoot: string, target: string): Promise<{
  files: ScanFile[];
  symlinksSkipped: number;
}> {
  await assertNoSymlinkComponents(repositoryRoot, target);
  const rootMetadata = await lstat(target);
  const files: ScanFile[] = [];
  let symlinksSkipped = 0;
  let totalBytes = 0;

  const acceptFile = (path: string, bytes: number): void => {
    const language = languageFor(path);
    if (!language) return;
    if (bytes > MAX_FILE_BYTES) throw new CliError(`Compatibility scan file exceeds ${MAX_FILE_BYTES} bytes: ${basename(path)}`);
    files.push({ path, language, manifest: basename(path).toLowerCase() === "fxmanifest.lua", bytes });
    totalBytes += bytes;
    if (files.length > MAX_FILES) throw new CliError(`Compatibility scan exceeded the ${MAX_FILES} file limit.`);
    if (totalBytes > MAX_TOTAL_BYTES) throw new CliError(`Compatibility scan exceeded the ${MAX_TOTAL_BYTES} byte limit.`);
  };

  if (rootMetadata.isFile()) {
    acceptFile(target, rootMetadata.size);
    return { files, symlinksSkipped };
  }
  if (!rootMetadata.isDirectory()) throw new CliError("Compatibility scan target must be a regular file or directory.", 2);

  const pending: Array<{ path: string; depth: number }> = [{ path: target, depth: 0 }];
  while (pending.length > 0) {
    const current = pending.pop();
    if (!current) break;
    if (current.depth > MAX_DEPTH) throw new CliError(`Compatibility scan exceeded the ${MAX_DEPTH} directory depth limit.`);
    const entries = (await readdir(current.path, { withFileTypes: true }))
      .sort((left, right) => compareText(left.name, right.name));
    for (const entry of entries) {
      const path = join(current.path, entry.name);
      if (entry.isSymbolicLink()) {
        symlinksSkipped += 1;
        continue;
      }
      if (entry.isDirectory()) {
        if (!SKIPPED_DIRECTORIES.has(entry.name)) pending.push({ path, depth: current.depth + 1 });
      } else if (entry.isFile()) {
        const metadata = await lstat(path);
        if (metadata.isSymbolicLink()) {
          symlinksSkipped += 1;
          continue;
        }
        acceptFile(path, metadata.size);
      }
    }
  }
  files.sort((left, right) => compareText(left.path, right.path));
  return { files, symlinksSkipped };
}

function stripLuaComments(text: string): string {
  let output = "";
  let index = 0;
  let quote: "'" | '"' | null = null;
  let longDelimiter: string | null = null;
  while (index < text.length) {
    const character = text[index] ?? "";
    if (quote) {
      output += character;
      if (character === "\\") {
        index += 1;
        if (index < text.length) output += text[index] ?? "";
      } else if (character === quote) {
        quote = null;
      }
      index += 1;
      continue;
    }
    if (longDelimiter) {
      const close = `]${longDelimiter}]`;
      if (text.startsWith(close, index)) {
        output += close;
        index += close.length;
        longDelimiter = null;
      } else {
        output += character;
        index += 1;
      }
      continue;
    }
    if (character === "'" || character === '"') {
      quote = character;
      output += character;
      index += 1;
      continue;
    }
    const longString = /^\[(=*)\[/u.exec(text.slice(index));
    if (longString) {
      longDelimiter = longString[1] ?? "";
      output += longString[0];
      index += longString[0].length;
      continue;
    }
    if (text.startsWith("--", index)) {
      const longComment = /^--\[(=*)\[/u.exec(text.slice(index));
      if (longComment) {
        const delimiter = longComment[1] ?? "";
        const close = `]${delimiter}]`;
        const startLength = longComment[0].length;
        output += " ".repeat(startLength);
        index += startLength;
        while (index < text.length && !text.startsWith(close, index)) {
          output += text[index] === "\n" ? "\n" : " ";
          index += 1;
        }
        if (text.startsWith(close, index)) {
          output += " ".repeat(close.length);
          index += close.length;
        }
      } else {
        while (index < text.length && text[index] !== "\n") {
          output += " ";
          index += 1;
        }
      }
      continue;
    }
    output += character;
    index += 1;
  }
  return output;
}

function stripJavascriptComments(text: string): string {
  let output = "";
  let index = 0;
  let quote: "'" | '"' | "`" | null = null;
  while (index < text.length) {
    const character = text[index] ?? "";
    if (quote) {
      output += character;
      if (character === "\\") {
        index += 1;
        if (index < text.length) output += text[index] ?? "";
      } else if (character === quote) {
        quote = null;
      }
      index += 1;
      continue;
    }
    if (character === "'" || character === '"' || character === "`") {
      quote = character;
      output += character;
      index += 1;
      continue;
    }
    if (text.startsWith("//", index)) {
      while (index < text.length && text[index] !== "\n") {
        output += " ";
        index += 1;
      }
      continue;
    }
    if (text.startsWith("/*", index)) {
      output += "  ";
      index += 2;
      while (index < text.length && !text.startsWith("*/", index)) {
        output += text[index] === "\n" ? "\n" : " ";
        index += 1;
      }
      if (text.startsWith("*/", index)) {
        output += "  ";
        index += 2;
      }
      continue;
    }
    output += character;
    index += 1;
  }
  return output;
}

function lineMatches(line: string, pattern: RegExp): boolean {
  pattern.lastIndex = 0;
  return pattern.test(line);
}

function frameworkForProvider(provider: CompatibilityProvider): CompatibilityFramework {
  return provider === "qb" ? "qbcore" : provider;
}

export async function scanCompatibility(
  repositoryRoot: string,
  target = repositoryRoot,
): Promise<CompatibilityReport> {
  const root = resolve(repositoryRoot);
  const selectedTarget = resolve(target);
  const collected = await collectScanFiles(root, selectedTarget);
  const findings: CompatibilityFinding[] = [];
  const seen = new Set<string>();
  const counts: Record<CompatibilityFramework, number> = {
    synex: 0, qbcore: 0, qbx: 0, esx: 0, vrp: 0, ox_core: 0,
  };
  const filesByLanguage = { lua: 0, javascript: 0, typescript: 0, manifest: 0 };

  const addFinding = (finding: CompatibilityFinding): void => {
    const key = [finding.category, finding.framework, finding.provider ?? "", finding.domain ?? "",
      finding.file, finding.line, finding.signal, finding.surface ?? ""].join("\u0000");
    if (seen.has(key)) return;
    seen.add(key);
    findings.push(finding);
    if (finding.category === "framework") counts[finding.framework] += 1;
  };

  for (const file of collected.files) {
    filesByLanguage[file.language] += 1;
    if (file.manifest) filesByLanguage.manifest += 1;
    const raw = await readFile(file.path, "utf8");
    const text = file.language === "lua" ? stripLuaComments(raw) : stripJavascriptComments(raw);
    const lines = text.replace(/\r\n?/gu, "\n").split("\n");
    const fileProviders = new Set<CompatibilityProvider>();
    for (const framework of FRAMEWORK_PATTERNS) {
      if (lineMatches(text, framework.pattern) && framework.provider) fileProviders.add(framework.provider);
    }
    const displayed = displayPath(root, file.path);

    for (let index = 0; index < lines.length; index += 1) {
      const line = lines[index] ?? "";
      for (const framework of FRAMEWORK_PATTERNS) {
        if (!lineMatches(line, framework.pattern)) continue;
        addFinding({
          category: "framework", framework: framework.framework, provider: framework.provider,
          domain: null, file: displayed, line: index + 1, signal: framework.signal,
          surface: null, migrationNote: framework.note,
        });
      }

      for (const surface of SURFACE_PATTERNS) {
        if (!lineMatches(line, surface.pattern)) continue;
        for (const provider of surface.providers.filter((candidate) => fileProviders.has(candidate))) {
          addFinding({
            category: "surface", framework: frameworkForProvider(provider), provider,
            domain: surface.domain, file: displayed, line: index + 1,
            signal: surface.surface, surface: surface.surface, migrationNote: surface.note,
          });
        }
      }

      for (const domain of DOMAIN_PATTERNS) {
        if (!lineMatches(line, domain.pattern)) continue;
        const provider = [...fileProviders].sort(compareText)[0] ?? null;
        addFinding({
          category: "domain", framework: provider ? frameworkForProvider(provider) : "synex",
          provider, domain: domain.domain, file: displayed, line: index + 1,
          signal: domain.signal, surface: null, migrationNote: domain.note,
        });
      }

      if (file.manifest && lineMatches(line, MANIFEST_DEPENDENCY_PATTERN)) {
        const provider = [...fileProviders].sort(compareText)[0] ?? null;
        addFinding({
          category: "manifest", framework: provider ? frameworkForProvider(provider) : "synex",
          provider, domain: null, file: displayed, line: index + 1,
          signal: "Legacy manifest dependency", surface: null,
          migrationNote: "Replace or isolate the dependency only after resolving every consumed surface.",
        });
      }
    }

    let sqlLine = 1;
    let previousSqlIndex = 0;
    const directSqlPattern = new RegExp(DIRECT_SQL_PATTERN.source, "giu");
    for (const match of text.matchAll(directSqlPattern)) {
      const matchIndex = match.index;
      sqlLine += (text.slice(previousSqlIndex, matchIndex).match(/\n/gu) ?? []).length;
      previousSqlIndex = matchIndex;
      const provider = [...fileProviders].sort(compareText)[0] ?? null;
      addFinding({
        category: "direct_sql", framework: provider ? frameworkForProvider(provider) : "synex",
        provider, domain: null, file: displayed, line: sqlLine,
        signal: "Direct legacy domain SQL", surface: null,
        migrationNote: "Direct legacy-table SQL bypasses Synex authority and requires a deliberate migration.",
      });
    }
  }

  findings.sort((left, right) => compareText(left.file, right.file)
    || left.line - right.line || compareText(left.category, right.category)
    || compareText(left.signal, right.signal));
  const frameworks = (Object.keys(counts) as CompatibilityFramework[])
    .filter((framework) => counts[framework] > 0)
    .sort(compareText);
  const surfaces = [...new Set(findings.flatMap((finding) => finding.surface ? [finding.surface] : []))]
    .sort(compareText);
  const domainDependencies = [...new Set(findings.flatMap((finding) => finding.domain ? [finding.domain] : []))]
    .sort(compareText);
  const directLegacySql = findings.filter((finding) => finding.category === "direct_sql").length;
  const legacySignals = frameworks.some((framework) => framework !== "synex");

  return {
    schema: 1,
    artifactKind: "synex-compatibility-scan",
    status: directLegacySql > 0 ? "UNSUPPORTED" : legacySignals ? "PARTIAL" : "UNKNOWN",
    target: displayPath(root, selectedTarget),
    filesScanned: collected.files.length,
    filesByLanguage,
    bytesScanned: collected.files.reduce((total, file) => total + file.bytes, 0),
    symlinksSkipped: collected.symlinksSkipped,
    signatureCounts: counts,
    frameworks,
    surfaces,
    domainDependencies,
    directLegacySql,
    findings,
    disclaimer: "Static signatures identify migration work only; they do not certify behavioral or runtime compatibility.",
  };
}
