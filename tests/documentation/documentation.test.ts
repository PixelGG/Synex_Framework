import assert from "node:assert/strict";
import { access, readFile, readdir } from "node:fs/promises";
import path from "node:path";
import test from "node:test";

const root = process.cwd();

async function documentationMarkdown(): Promise<string[]> {
  return [
    path.join(root, "README.md"),
    path.join(root, "libraries", "synex_ui", "README.md"),
    ...await collectMarkdown(path.join(root, "docs")),
    ...await collectMarkdown(path.join(root, "packages")),
  ].sort();
}

async function collectMarkdown(directory: string): Promise<string[]> {
  const entries = await readdir(directory, { withFileTypes: true });
  const files: string[] = [];
  for (const entry of entries) {
    const absolute = path.join(directory, entry.name);
    if (entry.isDirectory()) files.push(...await collectMarkdown(absolute));
    if (entry.isFile() && entry.name.endsWith(".md")) files.push(absolute);
  }
  return files;
}

async function collectFiles(directory: string): Promise<string[]> {
  const entries = await readdir(directory, { withFileTypes: true });
  const files: string[] = [];
  for (const entry of entries) {
    const absolute = path.join(directory, entry.name);
    if (entry.isDirectory()) files.push(...await collectFiles(absolute));
    if (entry.isFile()) files.push(absolute);
  }
  return files;
}

function fxmanifestReferences(contents: string): string[] {
  const references: string[] = [];
  const single = /^\s*(?:shared_script|client_script|server_script|ui_page|file|synex_manifest|synex_contracts)\s+["']([^"']+)["']/gmu;
  for (const match of contents.matchAll(single)) {
    if (match[1]) references.push(match[1]);
  }
  const blocks = /^\s*(?:shared_scripts|client_scripts|server_scripts|files)\s*\{([\s\S]*?)^\s*\}/gmu;
  for (const block of contents.matchAll(blocks)) {
    for (const match of (block[1] ?? "").matchAll(/["']([^"']+)["']/gu)) {
      if (match[1]) references.push(match[1]);
    }
  }
  return references;
}

function manifestGlob(pattern: string): RegExp {
  const escaped = pattern
    .split("*")
    .map((part) => part.replace(/[\\^$.*+?()[\]{}|]/gu, "\\$&"))
    .join("[^/]*");
  return new RegExp(`^${escaped}$`, "u");
}

function localTargets(markdown: string): string[] {
  const targets: string[] = [];
  for (const match of markdown.matchAll(/!?\[[^\]]*\]\(([^)]+)\)/gu)) {
    const target = match[1]?.trim();
    if (target) targets.push(target.replace(/^<|>$/gu, ""));
  }
  for (const match of markdown.matchAll(/\b(?:href|src)="([^"]+)"/gu)) {
    const target = match[1]?.trim();
    if (target) targets.push(target);
  }
  return targets.filter((target) =>
    !/^(?:https?:|mailto:|data:|javascript:)/iu.test(target),
  );
}

function githubHeadingAnchors(markdown: string): Set<string> {
  const headings: string[] = [];
  for (const match of markdown.matchAll(/^#{1,6}\s+(.+?)\s*#*$/gmu)) {
    if (match[1]) headings.push(match[1]);
  }
  for (const match of markdown.matchAll(/<h[1-6][^>]*>([\s\S]*?)<\/h[1-6]>/giu)) {
    if (match[1]) headings.push(match[1]);
  }

  const counts = new Map<string, number>();
  const anchors = new Set<string>();
  for (const heading of headings) {
    const base = heading
      .replace(/<[^>]+>/gu, "")
      .replace(/!?\[([^\]]+)\]\([^)]+\)/gu, "$1")
      .replace(/[`*_~]/gu, "")
      .toLocaleLowerCase("en")
      .trim()
      .replace(/[^\p{L}\p{N}\s-]/gu, "")
      .replace(/\s+/gu, "-");
    const count = counts.get(base) ?? 0;
    counts.set(base, count + 1);
    anchors.add(count === 0 ? base : `${base}-${count}`);
  }
  return anchors;
}

async function exists(target: string): Promise<boolean> {
  try {
    await access(target);
    return true;
  } catch {
    return false;
  }
}

test("all repository documentation uses existing relative link targets", async () => {
  const files = await documentationMarkdown();
  const failures: string[] = [];

  for (const file of files) {
    const markdown = await readFile(file, "utf8");
    for (const rawTarget of localTargets(markdown)) {
      const [rawPath = "", rawFragment] = rawTarget.split("#", 2);
      const targetWithoutFragment = rawPath.split("?", 1)[0] ?? "";
      let decoded: string;
      try {
        decoded = decodeURIComponent(targetWithoutFragment);
      } catch {
        failures.push(`${path.relative(root, file)} -> malformed URI: ${rawTarget}`);
        continue;
      }
      const absolute = decoded.length === 0
        ? file
        : decoded.startsWith("/")
        ? path.join(root, decoded.slice(1))
        : path.resolve(path.dirname(file), decoded);
      const relative = path.relative(root, absolute);
      if (relative === ".." || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
        failures.push(`${path.relative(root, file)} -> outside repository: ${rawTarget}`);
      } else if (!await exists(absolute)) {
        failures.push(`${path.relative(root, file)} -> missing: ${rawTarget}`);
      } else if (rawFragment && /^(?:[a-z0-9]+-?)+$/u.test(rawFragment)) {
        const targetMarkdown = await readFile(absolute, "utf8");
        if (!githubHeadingAnchors(targetMarkdown).has(rawFragment)) {
          failures.push(`${path.relative(root, file)} -> missing anchor: ${rawTarget}`);
        }
      }
    }
  }

  assert.deepEqual(failures, []);
});

test("markdown fences close and Mermaid blocks use supported diagram roots", async () => {
  const failures: string[] = [];
  for (const file of await documentationMarkdown()) {
    const markdown = await readFile(file, "utf8");
    const fences = [...markdown.matchAll(/^```[^\r\n]*$/gmu)];
    if (fences.length % 2 !== 0) {
      failures.push(`${path.relative(root, file)} -> unclosed fenced code block`);
    }

    const mermaidOpenings = [...markdown.matchAll(/^```mermaid\s*$/gmu)].length;
    const mermaidBlocks = [...markdown.matchAll(/^```mermaid\s*\r?\n([\s\S]*?)^```\s*$/gmu)];
    if (mermaidOpenings !== mermaidBlocks.length) {
      failures.push(`${path.relative(root, file)} -> unclosed Mermaid block`);
    }
    for (const block of mermaidBlocks) {
      const rootLine = block[1]?.trimStart().split(/\r?\n/u, 1)[0] ?? "";
      if (!/^(?:flowchart\s+(?:TB|TD|BT|RL|LR)|stateDiagram-v2)$/u.test(rootLine)) {
        failures.push(`${path.relative(root, file)} -> unsupported Mermaid root: ${rootLine}`);
      }
    }
  }

  assert.deepEqual(failures, []);
});

test("fxmanifests reference existing files and declare every resource Lua file", async () => {
  const runtimeRoots = ["core", "resources", "libraries", "examples"];
  const manifests: string[] = [];
  for (const runtimeRoot of runtimeRoots) {
    const files = await collectFiles(path.join(root, runtimeRoot));
    manifests.push(...files.filter((file) => path.basename(file) === "fxmanifest.lua"));
  }

  const failures: string[] = [];
  for (const manifest of manifests.sort()) {
    const resourceDirectory = path.dirname(manifest);
    const files = await collectFiles(resourceDirectory);
    const relativeFiles = new Map(files.map((file) => [
      path.relative(resourceDirectory, file).replaceAll(path.sep, "/"),
      file,
    ]));
    const referencedLua = new Set<string>();
    const contents = await readFile(manifest, "utf8");

    for (const rawReference of fxmanifestReferences(contents)) {
      if (rawReference.startsWith("@")) continue;
      const reference = rawReference.replaceAll("\\", "/");
      if (reference.startsWith("/") || reference.split("/").includes("..")) {
        failures.push(`${path.relative(root, manifest)} -> unsafe reference: ${rawReference}`);
        continue;
      }
      const matches = reference.includes("*")
        ? [...relativeFiles.keys()].filter((file) => manifestGlob(reference).test(file))
        : relativeFiles.has(reference) ? [reference] : [];
      if (matches.length === 0) {
        failures.push(`${path.relative(root, manifest)} -> missing reference: ${rawReference}`);
      }
      for (const match of matches) {
        if (match.endsWith(".lua")) referencedLua.add(match);
      }
    }

    for (const relative of relativeFiles.keys()) {
      if (relative === "fxmanifest.lua" || !relative.endsWith(".lua")) continue;
      if (!referencedLua.has(relative)) {
        failures.push(`${path.relative(root, manifest)} -> undeclared Lua file: ${relative}`);
      }
    }
  }

  assert.ok(manifests.length > 0, "no runtime fxmanifest.lua files were found");
  assert.deepEqual(failures, []);
});

test("canonical and localized landing pages share the experimental platform boundary", async () => {
  const pages = [
    "README.md",
    "docs/locales/de/README.md",
    "docs/locales/fr/README.md",
    "docs/locales/es/README.md",
    "docs/locales/pt-BR/README.md",
  ];
  const requiredMarkers = [
    "0.1.0",
    "experimental",
    "synex_core",
    "synex_groups",
    "synex_accounts",
    "synex_entities",
    "synex_control",
    "synex_bridge",
    "synex_ui",
    "oxmysql",
    "OneSync",
    "MariaDB",
    "npm run check",
  ];

  for (const page of pages) {
    const contents = await readFile(path.join(root, page), "utf8");
    for (const marker of requiredMarkers) {
      assert.ok(contents.includes(marker), `${page} is missing synchronized marker ${marker}`);
    }
  }
});

test("framework CI pins official actions and runs the required untrusted-safe gates", async () => {
  const workflow = await readFile(path.join(root, ".github/workflows/framework-ci.yml"), "utf8");
  const actionLines = workflow.split(/\r?\n/gu).filter((line) => /^\s+uses:/u.test(line));
  assert.ok(actionLines.length >= 4);
  for (const line of actionLines) {
    assert.match(line, /^\s+uses: actions\/(?:checkout|setup-node)@[0-9a-f]{40}\s+# v\d/u);
  }

  assert.match(workflow, /^permissions:\s*\n\s+contents: read$/mu);
  assert.match(workflow, /^\s{2}push:\s*\n\s{4}branches: \["\*\*"\]$/mu);
  assert.match(workflow, /^\s{2}pull_request:\s*$/mu);
  assert.doesNotMatch(workflow, /pull_request_target/gu);
  assert.doesNotMatch(workflow, /\$\{\{\s*secrets\./gu);
  assert.doesNotMatch(workflow, /^\s+[a-z-]+: write$/gmu);
  const workflowLines = workflow.split(/\r?\n/gu);
  const uiVisualStart = workflowLines.findIndex((line) => line === "  ui-visual:");
  assert.notEqual(uiVisualStart, -1, "framework CI must define the ui-visual job");
  const uiVisualEnd = workflowLines.findIndex(
    (line, index) => index > uiVisualStart && /^\s{2}[a-z][a-z0-9-]*:\s*$/u.test(line),
  );
  const uiVisualJob = workflowLines
    .slice(uiVisualStart, uiVisualEnd === -1 ? workflowLines.length : uiVisualEnd)
    .join("\n");
  const checkoutIndexes = workflowLines.flatMap((line, index) =>
    /^\s+uses: actions\/checkout@[0-9a-f]{40}\s+# v\d/u.test(line) ? [index] : [],
  );
  assert.ok(checkoutIndexes.length > 0, "framework CI must check out the repository");
  for (const checkoutIndex of checkoutIndexes) {
    const usesIndent = workflowLines[checkoutIndex]?.match(/^\s*/u)?.[0].length ?? 0;
    const stepIndent = Math.max(0, usesIndent - 2);
    const stepPattern = new RegExp(`^\\s{${stepIndent}}-\\s`, "u");
    let stepStart = checkoutIndex;
    while (stepStart > 0 && !stepPattern.test(workflowLines[stepStart] ?? "")) stepStart -= 1;
    let stepEnd = checkoutIndex + 1;
    while (stepEnd < workflowLines.length && !stepPattern.test(workflowLines[stepEnd] ?? "")) stepEnd += 1;
    const checkoutStep = workflowLines.slice(stepStart, stepEnd).join("\n");
    assert.match(
      checkoutStep,
      /^\s+persist-credentials:\s+false\s*$/mu,
      "every checkout step must disable credential persistence with the literal false value",
    );
    assert.doesNotMatch(
      checkoutStep,
      /persist-credentials:\s*\$\{\{/u,
      "checkout credential persistence must not be configured through an expression",
    );
  }
  assert.match(workflow, /node-version: "24"/u);
  assert.match(workflow, /run: npm ci/u);
  assert.match(workflow, /run: npm run check:ui/u);
  assert.match(workflow, /run: npm run test:ui/u);
  assert.match(workflow, /run: npm run build:ui/u);
  assert.match(workflow, /git status --porcelain --untracked-files=all -- libraries\/synex_ui\/dist libraries\/synex_ui\/web\/dist/u);
  assert.match(uiVisualJob, /^\s{4}runs-on: windows-2022$/mu);
  assert.match(uiVisualJob, /run: npx playwright install chromium/u);
  assert.doesNotMatch(uiVisualJob, /run: npx playwright install --with-deps chromium/u);
  assert.match(uiVisualJob, /run: npm run test:ui:visual/u);
  assert.match(workflow, /run: npm run generate:check/u);
  assert.match(workflow, /run: npm run test:lua/u);
  assert.match(workflow, /tools\/test-runner\.mjs core/u);
  assert.match(workflow, /tools\/test-runner\.mjs stress/u);
  assert.match(workflow, /tools\/test-runner\.mjs compatibility/u);
  assert.match(workflow, /tools\/cli\/src\/bin\.ts compat scan \./u);
  assert.match(workflow, /tools\/test-runner\.mjs documentation/u);
  assert.match(workflow, /run: npm run security/u);
  assert.match(workflow, /run: npm run certify/u);
  assert.match(workflow, /run: npm audit --audit-level=high/u);
  assert.match(workflow, /image: mariadb:/u);
  assert.match(workflow, /SYNEX_TEST_DATABASE_LIVE: "1"/u);
  assert.match(workflow, /run: npm run test:database/u);
});
