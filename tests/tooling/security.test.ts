import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { scanLuaText, scanSecurity, scanTypeScriptText } from "../../tools/cli/src/cli.js";

const groupsModuleLoaderPath = "resources/synex_groups/server/module_loader.lua";

test("static scanner assigns severity and confidence without claiming safety", () => {
  const findings = scanLuaText("os.execute('whoami')", "server/main.lua");
  assert.deepEqual(
    findings.map(({ rule, severity, confidence }) => ({ rule, severity, confidence })),
    [{ rule: "lua-os-command", severity: "critical", confidence: "high" }],
  );
});

test("scanner redacts committed webhook details from evidence", () => {
  const secretPath = "123456789/abcdefghijklmnopqrstuvwxyz";
  const webhookUrl = ["https://discord.com", "api", "webhooks", secretPath].join("/");
  const findings = scanLuaText(
    `PerformHttpRequest("${webhookUrl}", function() end)`,
    "server/logging.lua",
  );
  const webhook = findings.find((finding) => finding.rule === "lua-webhook-literal");
  assert.ok(webhook);
  assert.equal(webhook.confidence, "high");
  assert.match(webhook.evidence, /\[REDACTED_WEBHOOK\]/u);
  assert.doesNotMatch(webhook.evidence, /abcdefghijklmnopqrstuvwxyz/u);
});

test("ordinary outbound HTTP is not mislabeled as remote code execution", () => {
  const findings = scanLuaText(
    "PerformHttpRequest(endpoint, function(status) print(status) end, 'POST', payload)",
    "server/http.lua",
  );
  assert.equal(findings.some((finding) => finding.rule === "remote-code-execution-chain"), false);
});

test("ordinary object load methods are not mislabeled as dynamic Lua compilation", () => {
  const findings = scanLuaText("function sagas:load(publicId) return self.repository:load(publicId) end", "server/sagas.lua");
  assert.equal(findings.some((finding) => finding.rule === "lua-dynamic-code"), false);
});

test("reviewed manifest-bound Groups loader is not mislabeled as generic dynamic code", async () => {
  const source = await readFile(groupsModuleLoaderPath, "utf8");
  const findings = scanLuaText(source, groupsModuleLoaderPath);
  assert.equal(findings.some((finding) => finding.rule === "lua-dynamic-code"), false);
});

test("manifest-bound loader approval fails closed for source, guard, and path mutations", async () => {
  const source = await readFile(groupsModuleLoaderPath, "utf8");
  const mutations = [
    source.replace(
      "local source = LoadResourceFile(RESOURCE_NAME, path)",
      "local source = remotePayload",
    ),
    source.replace("        or name:find('..', 1, true) then\n", ""),
    `${source}\nos.execute('whoami')\n`,
  ];

  for (const mutated of mutations) {
    const findings = scanLuaText(mutated, groupsModuleLoaderPath);
    assert.equal(
      findings.some((finding) => finding.rule === "lua-dynamic-code"),
      true,
      "mutated loader must return to the generic dynamic-code review path",
    );
  }

  const relocated = scanLuaText(source, "resources/other/server/module_loader.lua");
  assert.equal(relocated.some((finding) => finding.rule === "lua-dynamic-code"), true);

  const additionalRule = scanLuaText(mutations[2] ?? "", groupsModuleLoaderPath);
  assert.equal(additionalRule.some((finding) => finding.rule === "lua-os-command"), true);
});

test("nearby HTTP retrieval and dynamic execution receives a review finding", () => {
  const findings = scanLuaText(
    "PerformHttpRequest(endpoint, function(status, body)\n  local chunk = load(body)\n  chunk()\nend)",
    "server/update.lua",
  );
  const chain = findings.find((finding) => finding.rule === "remote-code-execution-chain");
  assert.ok(chain);
  assert.equal(chain.severity, "critical");
  assert.equal(chain.confidence, "medium");
});

test("multiline executable wildcards in fxmanifest files are detected", () => {
  const findings = scanLuaText(
    "server_scripts {\n  'server/*.lua'\n}\n",
    "fxmanifest.lua",
  );
  assert.equal(findings.some((finding) => finding.rule === "fxmanifest-wildcard-executable"), true);
});

test("Lua AST normalization preserves SQL backticks inside strings", () => {
  const findings = scanLuaText(`
    local sql = "SELECT \`target_id\` FROM \`synex_audit_log\` WHERE \`target_type\` = 'character'"
    ExecuteCommand(command)
  `, "server/audit.lua");
  const command = findings.find((finding) => finding.rule === "lua-dynamic-command");
  assert.ok(command);
  assert.equal(command.confidence, "high");
});

test("Lua AST normalization accepts Cfx native hash literals outside strings", () => {
  const findings = scanLuaText(`
    local model = \`adder\`
    ExecuteCommand(command)
  `, "server/entities.lua");
  const command = findings.find((finding) => finding.rule === "lua-dynamic-command");
  assert.ok(command);
  assert.equal(command.confidence, "high");
});

test("TypeScript syntax fallback detects dynamic process and SQL boundaries", () => {
  const findings = scanTypeScriptText(`
    import { spawn } from 'node:child_process';
    spawn(command, [argument]);
    database.query('SELECT * FROM users WHERE id=' + userId);
  `, "server/main.ts");
  assert.equal(findings.some((finding) => finding.rule === "typescript-dynamic-command" && finding.confidence === "high"), true);
  assert.equal(findings.some((finding) => finding.rule === "typescript-sql-concatenation"), true);
});

test("repository security analysis executes the TypeScript compiler AST", async () => {
  const report = await scanSecurity(process.cwd(), process.cwd());
  assert.ok(report.filesByLanguage.typescript > 0);
  assert.equal(report.typescriptAnalysis.astFiles, report.filesByLanguage.typescript);
  assert.equal(report.typescriptAnalysis.syntaxFallbackFiles, 0);
});

test("TypeScript evidence redacts committed credentials", () => {
  const findings = scanTypeScriptText(
    "const endpoint = 'mysql://operator:secret@private-host/database';",
    "server/config.ts",
  );
  const finding = findings.find((entry) => entry.rule === "typescript-database-url-literal");
  assert.ok(finding);
  assert.doesNotMatch(finding.evidence, /operator|private-host|secret/u);
});
