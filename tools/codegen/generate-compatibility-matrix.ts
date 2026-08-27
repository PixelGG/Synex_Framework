import { readFile, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";

import { buildCompatibilityMatrix } from "../cli/src/compatibility/analysis.ts";
import { loadCompatibilityCatalog } from "../cli/src/compatibility/catalog.ts";
import type { CompatibilityCatalog } from "../cli/src/compatibility/types.ts";

function cell(value: string | null): string {
  return value === null || value.length === 0 ? "—" : value.replaceAll("|", "\\|");
}

function adapterContract(row: {
  requiredAdapter: string | null;
  adapterOperations: Array<{ name: string; nativeCapabilities: string[] }>;
}): string {
  if (!row.requiredAdapter || row.adapterOperations.length === 0) return "—";
  return row.adapterOperations.map((operation) => `\`${cell(row.requiredAdapter!)}:${
    cell(operation.name)
  }\` → ${operation.nativeCapabilities.map((capability) => `\`${cell(capability)}\``).join(", ")}`)
    .join("<br>");
}

function catalogContract(row: {
  requiredCatalog: string | null;
  catalogOperations: Array<{ name: string; nativeCapabilities: string[] }>;
}): string {
  if (!row.requiredCatalog || row.catalogOperations.length === 0) return "—";
  return row.catalogOperations.map((operation) => `\`${cell(row.requiredCatalog!)}:${
    cell(operation.name)
  }\` → ${operation.nativeCapabilities.map((capability) => `\`${cell(capability)}\``).join(", ")}`)
    .join("<br>");
}

export function renderCompatibilityMatrixMarkdown(catalog: CompatibilityCatalog): string {
  const matrix = buildCompatibilityMatrix(catalog);
  const rows = matrix.rows.map((row) => `| ${[
    row.provider.toUpperCase(),
    `\`${cell(row.providerVersion)}\``,
    row.targetFrameworkApiRange ? `\`${cell(row.targetFrameworkApiRange)}\`` : "unreviewed",
    `\`${cell(row.name)}\``,
    row.scope,
    row.type,
    `**${row.status}**`,
    row.legacyVersionRange ? `\`${cell(row.legacyVersionRange)}\`` : "—",
    row.nativeMapping ? `\`${cell(row.nativeMapping)}\`` : "—",
    adapterContract(row),
    catalogContract(row),
    cell(row.modes.join(", ")),
  ].join(" | ")} |`);
  const accountRows = catalog.mappings
    .filter((mapping) => mapping.category === "accounts")
    .map((mapping) => {
      const currencyCode = typeof mapping.raw.currencyCode === "string"
        ? mapping.raw.currencyCode
        : "";
      const accountKey = typeof mapping.raw.accountKey === "string"
        ? mapping.raw.accountKey
        : "";
      const accountRole = typeof mapping.raw.accountRole === "string"
        ? mapping.raw.accountRole
        : "";
      const minorUnit = typeof mapping.raw.minorUnit === "number"
        ? String(mapping.raw.minorUnit)
        : "";
      return `| ${[
        mapping.provider?.toUpperCase() ?? "UNKNOWN",
        `\`${cell(mapping.legacy)}\``,
        `\`${cell(currencyCode)}\``,
        `\`${cell(accountKey)}\``,
        cell(accountRole),
        minorUnit,
        `**${mapping.status}**`,
      ].join(" | ")} |`;
    });
  return [
    "# Compatibility matrix",
    "",
    "> [!WARNING]",
    "> This file is generated from the checked-in bridge catalog. A surface status is bounded to its named provider, mode, version evidence, and tests; it is not deployment certification.",
    "",
    `Catalog aggregate: **${matrix.status}**. No compatibility profile may be treated as certified without exact tested-version evidence.`,
    "",
    "| Provider | Provider version | Target framework API range | Surface | Scope | Type | Status | Legacy version | Native mapping | Adapter operation → native capabilities | Catalog operation → native capabilities | Modes |",
    "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |",
    ...rows,
    "",
    "## Central account aliases",
    "",
    "Providers declare supported alias names only. Currency, account key, role, and minor-unit scale are authoritative central mapping values; duplicate provider-scoped targets fail closed.",
    "",
    "| Provider | Legacy alias | Currency | Account key | Role | Minor unit | Status |",
    "| --- | --- | --- | --- | --- | --- | --- |",
    ...accountRows,
    "",
    "Status model:",
    "",
    "- **CERTIFIED** — exact profile and tested-version evidence satisfy every required surface; never inferred by scanning.",
    "- **COMPATIBLE** — the bounded cataloged behavior is compatible, without deployment certification.",
    "- **PARTIAL** — only the named subset or semantics exist.",
    "- **UNSUPPORTED** — the surface is rejected or intentionally absent.",
    "- **UNKNOWN** — evidence is absent or insufficient.",
    "",
    "The authoritative artifacts are under [`libraries/synex_bridge/compatibility`](../../libraries/synex_bridge/compatibility/). Regenerate this table with:",
    "",
    "```text",
    "node --experimental-strip-types tools/codegen/generate-compatibility-matrix.ts",
    "```",
    "",
  ].join("\n");
}

async function main(): Promise<void> {
  const repositoryRoot = resolve(process.cwd());
  const output = join(repositoryRoot, "docs", "compatibility", "matrix.md");
  const rendered = renderCompatibilityMatrixMarkdown(await loadCompatibilityCatalog(repositoryRoot));
  if (process.argv.includes("--check")) {
    let current = "";
    try {
      current = await readFile(output, "utf8");
    } catch {
      process.exitCode = 1;
      return;
    }
    if (current !== rendered) process.exitCode = 1;
    return;
  }
  await writeFile(output, rendered, "utf8");
}

if (process.argv[1] && resolve(process.argv[1]) === resolve(import.meta.filename)) {
  await main();
}
