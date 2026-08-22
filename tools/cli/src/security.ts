import * as luaparse from "luaparse";
import { API as TypeScriptApi } from "typescript/unstable/sync";
import {
  createScanner,
  isBinaryExpression,
  isCallExpression,
  isElementAccessExpression,
  isIdentifier,
  isNewExpression,
  isNoSubstitutionTemplateLiteral,
  isObjectLiteralExpression,
  isPropertyAccessExpression,
  isPropertyAssignment,
  isStringLiteral,
  isTemplateExpression,
  LanguageVariant,
  SyntaxKind,
  type Expression,
  type Node,
  type Scanner,
  type SourceFile,
} from "typescript/unstable/ast";
import { join, resolve } from "node:path";

import type {
  FindingConfidence,
  SecurityFinding,
  SecurityReport,
  SecuritySeverity,
} from "./types.ts";
import {
  compareText,
  displayPath,
  isDirectory,
  isRecord,
  pathExists,
  readTextFile,
  walkFiles,
} from "./filesystem.ts";

const SECURITY_DISCLAIMER =
  "Static analysis reports review candidates; it does not prove that a resource is secure or production-ready.";
const LUA_DYNAMIC_CODE_PATTERN = /(?<![:.])\b(?:loadstring|load)\s*\(/u;
const SEVERITY_ORDER: Record<SecuritySeverity, number> = {
  critical: 0,
  high: 1,
  medium: 2,
  low: 3,
  info: 4,
};

function lineNumberFor(text: string, pattern: RegExp): number | undefined {
  const match = pattern.exec(text);
  if (!match?.index) return match ? 1 : undefined;
  return text.slice(0, match.index).split("\n").length;
}

function redactEvidence(value: string): string {
  return value
    .replace(/https:\/\/(?:canary\.|ptb\.)?discord(?:app)?\.com\/api(?:\/v\d+)?\/webhooks\/[^\s"']+/giu, "[REDACTED_WEBHOOK]")
    .replace(/(?:mysql|mariadb):\/\/[^\s"']+/giu, "[REDACTED_DATABASE_URL]")
    .replace(/\b(?:github_pat_[A-Za-z0-9_]+|gh[pousr]_[A-Za-z0-9_]{20,}|cfxk_[A-Za-z0-9_-]{20,})\b/gu, "[REDACTED_TOKEN]")
    .replace(/\bAKIA[A-Z0-9]{16}\b/gu, "[REDACTED_ACCESS_KEY]")
    .replace(/(authorization\s*[:=]\s*["']?bearer\s+)[^\s"']+/giu, "$1[REDACTED]")
    .replace(/([?&](?:access[_-]?token|api[_-]?key|key|secret|token)=)[^&\s"']+/giu, "$1[REDACTED]")
    .replace(/(["']?(?:token|password|secret|api[_-]?key)["']?\s*[:=]\s*["'])[^"']+(["'])/giu, "$1[REDACTED]$2")
    .trim()
    .slice(0, 240);
}

export type LuaAstNode = Record<string, unknown> & {
  type?: string;
  loc?: { start?: { line?: number }; end?: { line?: number } };
};

function normalizeCfxNativeHashes(text: string): string {
  let output = "";
  let index = 0;

  const longBracketAt = (offset: number): { close: string; length: number } | null => {
    if (text[offset] !== "[") return null;
    let cursor = offset + 1;
    while (text[cursor] === "=") cursor += 1;
    if (text[cursor] !== "[") return null;
    const equals = text.slice(offset + 1, cursor);
    return { close: `]${equals}]`, length: cursor - offset + 1 };
  };

  const copyLongBracket = (offset: number): number => {
    const bracket = longBracketAt(offset);
    if (!bracket) return offset;
    const end = text.indexOf(bracket.close, offset + bracket.length);
    const exclusiveEnd = end < 0 ? text.length : end + bracket.close.length;
    output += text.slice(offset, exclusiveEnd);
    return exclusiveEnd;
  };

  while (index < text.length) {
    const character = text[index];

    if (character === "'" || character === '"') {
      const quote = character;
      const start = index;
      index += 1;
      while (index < text.length) {
        if (text[index] === "\\") {
          index = Math.min(text.length, index + 2);
          continue;
        }
        if (text[index] === quote) {
          index += 1;
          break;
        }
        index += 1;
      }
      output += text.slice(start, index);
      continue;
    }

    if (character === "-" && text[index + 1] === "-") {
      const longComment = longBracketAt(index + 2);
      if (longComment) {
        output += "--";
        index = copyLongBracket(index + 2);
        continue;
      }
      const end = text.indexOf("\n", index + 2);
      const exclusiveEnd = end < 0 ? text.length : end + 1;
      output += text.slice(index, exclusiveEnd);
      index = exclusiveEnd;
      continue;
    }

    if (character === "[") {
      const next = copyLongBracket(index);
      if (next !== index) {
        index = next;
        continue;
      }
    }

    if (character === "`") {
      const end = text.indexOf("`", index + 1);
      const newline = text.indexOf("\n", index + 1);
      if (end >= 0 && (newline < 0 || end < newline)) {
        output += '"__CFX_NATIVE_HASH__"';
        index = end + 1;
        continue;
      }
    }

    output += character;
    index += 1;
  }

  return output;
}

export function parseLuaAst(text: string): { ast: LuaAstNode | null; error: string | null } {
  try {
    // Cfx native hash literals are not part of stock Lua syntax. Normalize
    // only lexical backtick literals; SQL identifiers inside quoted or long
    // strings and comments must remain untouched.
    const normalized = normalizeCfxNativeHashes(text);
    const ast = luaparse.parse(normalized, {
      comments: false,
      locations: true,
      luaVersion: "5.3",
      scope: true,
    }) as unknown as LuaAstNode;
    return { ast, error: null };
  } catch (error) {
    return { ast: null, error: error instanceof Error ? error.message : "Lua AST parser failed." };
  }
}

export function walkLuaAst(node: unknown, visitor: (node: LuaAstNode) => void): void {
  if (Array.isArray(node)) {
    for (const entry of node) walkLuaAst(entry, visitor);
    return;
  }
  if (!isRecord(node)) return;
  const typed = node as LuaAstNode;
  if (typeof typed.type === "string") visitor(typed);
  for (const [key, value] of Object.entries(typed)) {
    if (key === "loc" || key === "range" || key === "scope") continue;
    if (Array.isArray(value) || isRecord(value)) walkLuaAst(value, visitor);
  }
}

export function luaExpressionName(node: unknown): string | null {
  if (!isRecord(node) || typeof node.type !== "string") return null;
  if (node.type === "Identifier" && typeof node.name === "string") return node.name;
  if (node.type === "MemberExpression") {
    const base = luaExpressionName(node.base);
    const identifier = luaExpressionName(node.identifier);
    return base && identifier ? `${base}.${identifier}` : null;
  }
  if (node.type === "IndexExpression") {
    const base = luaExpressionName(node.base);
    const index = luaStringLiteral(node.index);
    return base && index ? `${base}.${index}` : null;
  }
  return null;
}

export function luaStringLiteral(node: unknown): string | null {
  if (!isRecord(node) || node.type !== "StringLiteral") return null;
  return typeof node.value === "string" ? node.value : null;
}

export function luaCallArguments(node: LuaAstNode): unknown[] {
  return Array.isArray(node.arguments) ? node.arguments : [];
}

function luaNodeLine(node: LuaAstNode): number {
  return node.loc?.start?.line ?? 1;
}

function addLineFinding(
  findings: SecurityFinding[],
  lines: string[],
  file: string,
  rule: string,
  severity: SecuritySeverity,
  confidence: FindingConfidence,
  pattern: RegExp,
  explanation: string,
): void {
  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index];
    if (line !== undefined && pattern.test(line)) {
      findings.push({
        severity,
        confidence,
        rule,
        file,
        line: index + 1,
        explanation,
        evidence: redactEvidence(line),
      });
    }
  }
}

const KNOWN_MALICIOUS_HOSTS = [
  "cipher-panel.me",
  "ciphercheats.com",
  "blum-panel.me",
  "warden-panel.me",
  "fivehub-panel.site",
  "fivehub.xyz",
  "dark-utilities.xyz",
  "giithub.net",
  "gfxpanel.org",
  "kutingplays.com",
];

export function scanLuaText(text: string, file = "<memory>"): SecurityFinding[] {
  const lines = text.replace(/\r\n?/gu, "\n").split("\n");
  const findings: SecurityFinding[] = [];

  addLineFinding(
    findings,
    lines,
    file,
    "lua-os-command",
    "critical",
    "high",
    /\b(?:os\.execute|io\.popen)\s*\(/u,
    "OS command execution has no expected role in a FiveM resource and requires immediate review.",
  );
  addLineFinding(
    findings,
    lines,
    file,
    "lua-dynamic-code",
    "high",
    "medium",
    LUA_DYNAMIC_CODE_PATTERN,
    "Dynamic Lua execution is dangerous; confirm that the code is local, fixed, and never attacker-controlled.",
  );
  addLineFinding(
    findings,
    lines,
    file,
    "lua-webhook-literal",
    "high",
    "high",
    /https:\/\/(?:canary\.|ptb\.)?discord(?:app)?\.com\/api(?:\/v\d+)?\/webhooks\//iu,
    "A Discord webhook literal is committed in Lua source; rotate it and move delivery behind a server-only secret boundary.",
  );
  addLineFinding(
    findings,
    lines,
    file,
    "lua-dynamic-command",
    "high",
    "medium",
    /\bExecuteCommand\s*\(\s*(?!["'][^"']*["']\s*\))/u,
    "ExecuteCommand appears to receive a dynamic expression; use a fixed allowlist and server-side authorization.",
  );
  addLineFinding(
    findings,
    lines,
    file,
    "lua-sql-concatenation",
    "high",
    "medium",
    /(?:MySQL\.|oxmysql).*(?:query|execute|insert|update|prepare).*\.\./iu,
    "A database call appears to concatenate SQL; parameterize values and allowlist identifiers.",
  );
  addLineFinding(
    findings,
    lines,
    file,
    "lua-cross-resource-write",
    "high",
    "medium",
    /\bSaveResourceFile\s*\([^,]+,[^,]*\.(?:lua|js)["']/iu,
    "Writing executable resource files can create persistence or cross-resource injection.",
  );
  addLineFinding(
    findings,
    lines,
    file,
    "lua-deprecated-server-event",
    "low",
    "high",
    /\bRegisterServerEvent\s*\(/u,
    "RegisterServerEvent is deprecated; use RegisterNetEvent and retain equivalent server validation.",
  );
  addLineFinding(
    findings,
    lines,
    file,
    "fxmanifest-wildcard-executable",
    "medium",
    "high",
    /\b(?:server_script|client_script|shared_script)\s+["'][^"']*\*\.lua["']/u,
    "Wildcard executable includes can silently load injected Lua files.",
  );

  const wildcardManifestPattern = /\b(?:server_scripts|client_scripts|shared_scripts)\s*\{[\s\S]{0,4096}?["'][^"']*\*\.lua["'][\s\S]{0,4096}?\}/u;
  const wildcardLine = lineNumberFor(text, wildcardManifestPattern);
  if (wildcardLine !== undefined) {
    findings.push({
      severity: "medium",
      confidence: "high",
      rule: "fxmanifest-wildcard-executable",
      file,
      line: wildcardLine,
      explanation: "Wildcard executable includes can silently load injected Lua files.",
      evidence: "Executable Lua wildcard in fxmanifest declaration.",
    });
  }

  const lowerText = text.toLowerCase();
  for (const host of KNOWN_MALICIOUS_HOSTS) {
    const index = lowerText.indexOf(host);
    if (index >= 0) {
      const line = text.slice(0, index).split(/\r?\n/u).length;
      findings.push({
        severity: "critical",
        confidence: "high",
        rule: "known-malicious-host",
        file,
        line,
        explanation: `Source references the known malicious host ${host}.`,
        evidence: redactEvidence(lines[line - 1] ?? host),
      });
    }
  }

  const httpLines = lines
    .map((line, index) => (/\bPerformHttpRequest\s*\(/u.test(line) ? index : -1))
    .filter((index) => index >= 0);
  const loadLines = lines
    .map((line, index) => (LUA_DYNAMIC_CODE_PATTERN.test(line) ? index : -1))
    .filter((index) => index >= 0);
  for (const loadLine of loadLines) {
    if (httpLines.some((httpLine) => Math.abs(httpLine - loadLine) <= 40)) {
      findings.push({
        severity: "critical",
        confidence: "medium",
        rule: "remote-code-execution-chain",
        file,
        line: loadLine + 1,
        explanation: "HTTP retrieval and dynamic execution occur in the same local code region; verify data flow immediately.",
        evidence: redactEvidence(lines[loadLine] ?? ""),
      });
    }
  }

  if (
    httpLines.length > 0 &&
    /GetConvar\s*\(\s*["'](?:sv_licenseKey|rcon_password|mysql_connection_string|steam_webApiKey)["']/iu.test(text)
  ) {
    const line = httpLines[0] ?? 0;
    findings.push({
      severity: "critical",
      confidence: "high",
      rule: "credential-exfiltration-chain",
      file,
      line: line + 1,
      explanation: "Sensitive ConVar access and outbound HTTP coexist in this file, matching a credential-exfiltration chain.",
      evidence: redactEvidence(lines[line] ?? ""),
    });
  }

  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index];
    if (!line || !/\bRegisterNetEvent\s*\(/u.test(line)) continue;
    const nearby = lines.slice(index, index + 35).join("\n");
    const validationSignals = /\b(?:type\s*\(|source\b|IsPlayerAceAllowed|hasPermission|rateLimit|cooldown|validate)/iu;
    if (!validationSignals.test(nearby)) {
      findings.push({
        severity: "low",
        confidence: "low",
        rule: "network-event-manual-review",
        file,
        line: index + 1,
        explanation: "No validation signal was found near this network event. Helpers or generated guards may exist elsewhere; review manually.",
        evidence: redactEvidence(line),
      });
    }
  }

  const parsed = parseLuaAst(text);
  if (parsed.ast) {
    walkLuaAst(parsed.ast, (node) => {
      if (node.type !== "CallExpression") return;
      const call = luaExpressionName(node.base);
      if (!call) return;
      const line = luaNodeLine(node);
      const argumentsList = luaCallArguments(node);
      if (call === "os.execute" || call === "io.popen") {
        findings.push({
          severity: "critical",
          confidence: "high",
          rule: "lua-os-command",
          file,
          line,
          explanation: "The Lua AST contains a direct OS command execution call and requires immediate review.",
          evidence: call,
        });
      }
      if (call === "load" || call === "loadstring") {
        findings.push({
          severity: "high",
          confidence: "high",
          rule: "lua-dynamic-code",
          file,
          line,
          explanation: "The Lua AST contains dynamic code compilation; prove that its source is fixed and local.",
          evidence: call,
        });
      }
      if (call === "ExecuteCommand" && luaStringLiteral(argumentsList[0]) === null) {
        findings.push({
          severity: "high",
          confidence: "high",
          rule: "lua-dynamic-command",
          file,
          line,
          explanation: "The Lua AST shows ExecuteCommand receiving a non-literal expression.",
          evidence: "ExecuteCommand(<dynamic>)",
        });
      }
      if (/^(?:MySQL|oxmysql)\.(?:query|execute|insert|update|prepare)/u.test(call)) {
        const concatenatesSql = argumentsList.some(
          (argument) => isRecord(argument) && argument.type === "BinaryExpression" && argument.operator === "..",
        );
        if (concatenatesSql) {
          findings.push({
            severity: "high",
            confidence: "high",
            rule: "lua-sql-concatenation",
            file,
            line,
            explanation: "The Lua AST shows a database call receiving a concatenated expression.",
            evidence: `${call}(<concatenated>)`,
          });
        }
      }
    });
  }

  const unique = new Map<string, SecurityFinding>();
  for (const finding of findings) {
    unique.set(`${finding.rule}:${finding.line}`, finding);
  }
  return [...unique.values()].sort((left, right) => {
    const bySeverity = SEVERITY_ORDER[left.severity] - SEVERITY_ORDER[right.severity];
    if (bySeverity !== 0) return bySeverity;
    return left.line - right.line || compareText(left.rule, right.rule);
  });
}

interface TypeScriptToken {
  kind: SyntaxKind;
  text: string;
  start: number;
  end: number;
}

interface TypeScriptCallNode {
  name: string;
  start: number;
  end: number;
  arguments: TypeScriptToken[][];
}

function scanTypeScriptTokens(text: string): TypeScriptToken[] {
  const scanner: Scanner = createScanner(true, LanguageVariant.Standard, text);
  const tokens: TypeScriptToken[] = [];
  while (true) {
    const kind = scanner.scan();
    if (kind === SyntaxKind.EndOfFile) break;
    tokens.push({ kind, text: scanner.getTokenText(), start: scanner.getTokenStart(), end: scanner.getTokenEnd() });
  }
  return tokens;
}

function tokenLine(text: string, token: TypeScriptToken): number {
  return text.slice(0, token.start).split("\n").length;
}

function callNodes(tokens: TypeScriptToken[]): TypeScriptCallNode[] {
  const calls: TypeScriptCallNode[] = [];
  for (let index = 0; index < tokens.length; index += 1) {
    const first = tokens[index];
    if (!first || first.kind !== SyntaxKind.Identifier) continue;
    const names = [first.text];
    let cursor = index + 1;
    while (tokens[cursor]?.kind === SyntaxKind.DotToken && tokens[cursor + 1]?.kind === SyntaxKind.Identifier) {
      names.push(tokens[cursor + 1]?.text ?? "");
      cursor += 2;
    }
    if (tokens[cursor]?.kind !== SyntaxKind.OpenParenToken) continue;
    let depth = 0;
    const argumentsList: TypeScriptToken[][] = [[]];
    let end = tokens[cursor]?.end ?? first.end;
    for (let nested = cursor + 1; nested < tokens.length; nested += 1) {
      const token = tokens[nested];
      if (!token) break;
      if ([SyntaxKind.OpenParenToken, SyntaxKind.OpenBraceToken, SyntaxKind.OpenBracketToken].includes(token.kind)) depth += 1;
      if ([SyntaxKind.CloseParenToken, SyntaxKind.CloseBraceToken, SyntaxKind.CloseBracketToken].includes(token.kind)) {
        if (token.kind === SyntaxKind.CloseParenToken && depth === 0) {
          end = token.end;
          break;
        }
        depth -= 1;
      }
      if (token.kind === SyntaxKind.CommaToken && depth === 0) argumentsList.push([]);
      else argumentsList[argumentsList.length - 1]?.push(token);
    }
    calls.push({ name: names.join("."), start: first.start, end, arguments: argumentsList });
  }
  return calls;
}

function hasShellTrue(call: TypeScriptCallNode): boolean {
  return call.arguments.some((argument) => argument.some((token, index) =>
    token.text.replace(/["']/gu, "") === "shell"
      && argument[index + 1]?.kind === SyntaxKind.ColonToken
      && argument[index + 2]?.kind === SyntaxKind.TrueKeyword,
  ));
}

function syntaxEvidence(text: string, start: number, end: number): string {
  return redactEvidence(text.slice(start, end).replace(/\s+/gu, " "));
}

function astExpressionName(expression: Expression): string | null {
  if (isIdentifier(expression)) return expression.text;
  if (isPropertyAccessExpression(expression) && isIdentifier(expression.name)) {
    const base = astExpressionName(expression.expression);
    return base ? `${base}.${expression.name.text}` : expression.name.text;
  }
  if (isElementAccessExpression(expression) && isStringLiteral(expression.argumentExpression)) {
    const base = astExpressionName(expression.expression);
    return base ? `${base}.${expression.argumentExpression.text}` : expression.argumentExpression.text;
  }
  return null;
}

function astPropertyName(node: Node): string | null {
  if (isIdentifier(node) || isStringLiteral(node) || isNoSubstitutionTemplateLiteral(node)) return node.text;
  return null;
}

function astContains(node: Node, predicate: (candidate: Node) => boolean): boolean {
  if (predicate(node)) return true;
  let found = false;
  node.forEachChild((child) => {
    if (!found && astContains(child, predicate)) found = true;
    return undefined;
  });
  return found;
}

function astHasShellTrue(argumentsList: readonly Expression[]): boolean {
  return argumentsList.some((argument) => isObjectLiteralExpression(argument) && argument.properties.some((property) =>
    isPropertyAssignment(property)
      && astPropertyName(property.name) === "shell"
      && property.initializer.kind === SyntaxKind.TrueKeyword,
  ));
}

function astEvidence(sourceFile: SourceFile, node: Node): string {
  return redactEvidence(node.getText(sourceFile).replace(/\s+/gu, " "));
}

export function scanTypeScriptAst(sourceFile: SourceFile, file = "<memory>"): SecurityFinding[] {
  const findings: SecurityFinding[] = [];
  let hasOutboundRequest = false;
  let hasDynamicEvaluation = false;
  const visit = (node: Node): void => {
    if (isCallExpression(node)) {
      const call = astExpressionName(node.expression);
      const line = sourceFile.getLineAndCharacterOfPosition(node.getStart(sourceFile)).line + 1;
      if (call && ["eval", "global.eval", "Function"].includes(call)) {
        hasDynamicEvaluation = true;
        findings.push({
          severity: "high",
          confidence: "high",
          rule: "typescript-dynamic-code",
          file,
          line,
          explanation: "The TypeScript compiler AST contains dynamic code evaluation.",
          evidence: astEvidence(sourceFile, node),
        });
      }
      if (call && /(?:^|\.)(?:fetch|request|get)$/u.test(call)) hasOutboundRequest = true;
      if (call && /(?:^|\.)(?:exec|execSync)$/u.test(call)) {
        const shell = astHasShellTrue(node.arguments);
        findings.push({
          severity: shell ? "critical" : "high",
          confidence: "high",
          rule: shell ? "typescript-shell-execution" : "typescript-process-execution",
          file,
          line,
          explanation: shell
            ? "The TypeScript compiler AST shows a child process call with shell execution enabled."
            : "The TypeScript compiler AST contains direct command execution; require a fixed executable boundary and trusted arguments.",
          evidence: astEvidence(sourceFile, node),
        });
      }
      if (call && /(?:^|\.)(?:spawn|spawnSync)$/u.test(call)) {
        const shell = astHasShellTrue(node.arguments);
        const executable = node.arguments[0];
        if (shell || !executable || (!isStringLiteral(executable) && !isNoSubstitutionTemplateLiteral(executable))) {
          findings.push({
            severity: shell ? "critical" : "high",
            confidence: "high",
            rule: shell ? "typescript-shell-execution" : "typescript-dynamic-command",
            file,
            line,
            explanation: shell
              ? "The TypeScript compiler AST shows a spawned process with shell execution enabled."
              : "The TypeScript compiler AST shows a dynamically selected executable; constrain it to a fixed allowlist.",
            evidence: astEvidence(sourceFile, node),
          });
        }
      }
      if (call && /(?:^|\.)(?:query|execute)$/u.test(call)) {
        const statement = node.arguments[0];
        if (statement && astContains(statement, (candidate) =>
          (isBinaryExpression(candidate) && candidate.operatorToken.kind === SyntaxKind.PlusToken)
            || isTemplateExpression(candidate),
        )) {
          findings.push({
            severity: "high",
            confidence: "high",
            rule: "typescript-sql-concatenation",
            file,
            line,
            explanation: "The TypeScript compiler AST shows an interpolated or concatenated SQL statement; parameterize values and allowlist identifiers.",
            evidence: astEvidence(sourceFile, node),
          });
        }
      }
    } else if (isNewExpression(node) && astExpressionName(node.expression) === "Function") {
      hasDynamicEvaluation = true;
      findings.push({
        severity: "high",
        confidence: "high",
        rule: "typescript-dynamic-code",
        file,
        line: sourceFile.getLineAndCharacterOfPosition(node.getStart(sourceFile)).line + 1,
        explanation: "The TypeScript compiler AST constructs a dynamic function.",
        evidence: "new Function(<dynamic>)",
      });
    } else if (isBinaryExpression(node) && node.operatorToken.kind === SyntaxKind.EqualsToken) {
      const target = astExpressionName(node.left);
      if (target === "innerHTML" || target?.endsWith(".innerHTML")) {
        findings.push({
          severity: "medium",
          confidence: "high",
          rule: "typescript-inner-html",
          file,
          line: sourceFile.getLineAndCharacterOfPosition(node.getStart(sourceFile)).line + 1,
          explanation: "The TypeScript compiler AST contains direct innerHTML assignment; use textContent or a trusted sanitizer.",
          evidence: astEvidence(sourceFile, node),
        });
      }
    }
    node.forEachChild((child) => {
      visit(child);
      return undefined;
    });
  };
  visit(sourceFile);

  const text = sourceFile.text;
  const readsSensitiveEnvironment = /process\.env(?:\.|\[['"])(?:CFX|RCON|MYSQL|DATABASE|TOKEN|PASSWORD|SECRET|WEBHOOK|LICENSE)/iu.test(text);
  if (hasOutboundRequest && readsSensitiveEnvironment) {
    findings.push({
      severity: "critical",
      confidence: "medium",
      rule: "typescript-credential-exfiltration-chain",
      file,
      line: lineNumberFor(text, /process\.env/iu) ?? 1,
      explanation: "The TypeScript compiler AST contains outbound networking in a file that reads sensitive environment values; verify data flow immediately.",
      evidence: "process.env.<sensitive> + outbound request",
    });
  }
  if (hasOutboundRequest && hasDynamicEvaluation) {
    findings.push({
      severity: "critical",
      confidence: "medium",
      rule: "typescript-remote-code-execution-chain",
      file,
      line: 1,
      explanation: "The TypeScript compiler AST contains outbound retrieval and dynamic evaluation in the same file; verify data flow immediately.",
      evidence: "outbound request + dynamic evaluation",
    });
  }
  const unique = new Map<string, SecurityFinding>();
  for (const finding of findings) unique.set(`${finding.rule}:${finding.line}`, finding);
  return [...unique.values()].sort((left, right) =>
    SEVERITY_ORDER[left.severity] - SEVERITY_ORDER[right.severity]
      || left.line - right.line
      || compareText(left.rule, right.rule),
  );
}

export function scanTypeScriptText(text: string, file = "<memory>"): SecurityFinding[] {
  const findings: SecurityFinding[] = [];
  const lines = text.replace(/\r\n?/gu, "\n").split("\n");

  addLineFinding(
    findings,
    lines,
    file,
    "typescript-webhook-literal",
    "high",
    "high",
    /https:\/\/(?:canary\.|ptb\.)?discord(?:app)?\.com\/api(?:\/v\d+)?\/webhooks\//iu,
    "A Discord webhook literal is committed in script source; rotate it and use a server-only secret boundary.",
  );
  addLineFinding(
    findings,
    lines,
    file,
    "typescript-database-url-literal",
    "high",
    "high",
    /(?:mysql|mariadb):\/\/[^\s"']+/iu,
    "A database connection URL is committed in script source; rotate it and load it from server-only configuration.",
  );
  const lowerText = text.toLowerCase();
  for (const host of KNOWN_MALICIOUS_HOSTS) {
    const index = lowerText.indexOf(host);
    if (index < 0) continue;
    const line = text.slice(0, index).split(/\r?\n/u).length;
    findings.push({
      severity: "critical",
      confidence: "high",
      rule: "known-malicious-host",
      file,
      line,
      explanation: `Source references the known malicious host ${host}.`,
      evidence: redactEvidence(lines[line - 1] ?? host),
    });
  }

  const tokens = scanTypeScriptTokens(text);
  const calls = callNodes(tokens);
  let hasOutboundRequest = false;
  let hasDynamicEvaluation = false;
  for (const node of calls) {
      const call = node.name;
      const firstToken = tokens.find((token) => token.start === node.start) ?? tokens[0];
      const line = firstToken ? tokenLine(text, firstToken) : 1;
      if (["eval", "global.eval", "Function"].includes(call)) {
        hasDynamicEvaluation = true;
        findings.push({
          severity: "high",
          confidence: "high",
          rule: "typescript-dynamic-code",
          file,
          line,
          explanation: "The TypeScript AST contains dynamic code evaluation.",
          evidence: syntaxEvidence(text, node.start, node.end),
        });
      }
      if (/(?:^|\.)(?:fetch|request|get)$/u.test(call)) hasOutboundRequest = true;
      if (/(?:^|\.)(?:exec|execSync)$/u.test(call)) {
        findings.push({
          severity: hasShellTrue(node) ? "critical" : "high",
          confidence: "high",
          rule: hasShellTrue(node) ? "typescript-shell-execution" : "typescript-process-execution",
          file,
          line,
          explanation: hasShellTrue(node)
            ? "A child process call explicitly enables a shell, expanding command-injection risk."
            : "Direct command execution requires a fixed executable boundary and trusted arguments.",
          evidence: syntaxEvidence(text, node.start, node.end),
        });
      }
      if (/(?:^|\.)(?:spawn|spawnSync)$/u.test(call)) {
        if (hasShellTrue(node)) {
          findings.push({
            severity: "critical",
            confidence: "high",
            rule: "typescript-shell-execution",
            file,
            line,
            explanation: "A spawned process explicitly enables a shell, expanding command-injection risk.",
            evidence: syntaxEvidence(text, node.start, node.end),
          });
        } else {
          const executable = node.arguments[0]?.[0];
          if (!executable || ![SyntaxKind.StringLiteral, SyntaxKind.NoSubstitutionTemplateLiteral].includes(executable.kind)) {
            findings.push({
              severity: "high",
              confidence: "high",
              rule: "typescript-dynamic-command",
              file,
              line,
              explanation: "A spawned executable is selected dynamically; constrain it to a fixed allowlist.",
              evidence: syntaxEvidence(text, node.start, node.end),
            });
          }
        }
      }
      if (/(?:^|\.)(?:query|execute)$/u.test(call)) {
        const statement = node.arguments[0] ?? [];
        if (statement.some((token) => token.kind === SyntaxKind.PlusToken
          || token.kind === SyntaxKind.TemplateHead
          || token.kind === SyntaxKind.TemplateMiddle)) {
          findings.push({
            severity: "high",
            confidence: "high",
            rule: "typescript-sql-concatenation",
            file,
            line,
            explanation: "A database call receives a concatenated or interpolated SQL statement; parameterize values and allowlist identifiers.",
            evidence: syntaxEvidence(text, node.start, node.end),
          });
        }
      }
  }
  for (let index = 0; index < tokens.length - 1; index += 1) {
    const token = tokens[index];
    const next = tokens[index + 1];
    if (token?.kind === SyntaxKind.NewKeyword && next?.kind === SyntaxKind.Identifier && next.text === "Function") {
      hasDynamicEvaluation = true;
      findings.push({
        severity: "high",
        confidence: "high",
        rule: "typescript-dynamic-code",
        file,
        line: tokenLine(text, token),
        explanation: "The TypeScript AST constructs a dynamic function.",
        evidence: "new Function(<dynamic>)",
      });
    }
    if (token?.kind === SyntaxKind.Identifier && token.text === "innerHTML" && next?.kind === SyntaxKind.EqualsToken) {
      findings.push({
        severity: "medium",
        confidence: "high",
        rule: "typescript-inner-html",
        file,
        line: tokenLine(text, token),
        explanation: "Direct innerHTML assignment can turn NUI data into script execution; use textContent or a trusted sanitizer.",
        evidence: syntaxEvidence(text, token.start, tokens[index + 3]?.end ?? next.end),
      });
    }
  }

  const readsSensitiveEnvironment = /process\.env(?:\.|\[['"])(?:CFX|RCON|MYSQL|DATABASE|TOKEN|PASSWORD|SECRET|WEBHOOK|LICENSE)/iu.test(text);
  if (hasOutboundRequest && readsSensitiveEnvironment) {
    findings.push({
      severity: "critical",
      confidence: "medium",
      rule: "typescript-credential-exfiltration-chain",
      file,
      line: lineNumberFor(text, /process\.env/iu) ?? 1,
      explanation: "Sensitive environment access and outbound networking coexist in this file; verify data flow immediately.",
      evidence: "process.env.<sensitive> + outbound request",
    });
  }
  if (hasOutboundRequest && hasDynamicEvaluation) {
    findings.push({
      severity: "critical",
      confidence: "medium",
      rule: "typescript-remote-code-execution-chain",
      file,
      line: 1,
      explanation: "Outbound retrieval and dynamic evaluation coexist in this file; verify that remote content cannot reach evaluation.",
      evidence: "outbound request + dynamic evaluation",
    });
  }

  const unique = new Map<string, SecurityFinding>();
  for (const finding of findings) unique.set(`${finding.rule}:${finding.line}`, finding);
  return [...unique.values()].sort((left, right) =>
    SEVERITY_ORDER[left.severity] - SEVERITY_ORDER[right.severity]
      || left.line - right.line
      || compareText(left.rule, right.rule),
  );
}

async function securityScanRoots(repositoryRoot: string, target: string): Promise<string[]> {
  if (resolve(target) !== resolve(repositoryRoot)) return [resolve(target)];
  const roots: string[] = [];
  for (const path of ["resources", "core", "libraries", "examples"]) {
    const candidate = join(repositoryRoot, path);
    if (await isDirectory(candidate)) roots.push(candidate);
  }
  return roots;
}

async function compilerAstFindings(
  repositoryRoot: string,
  files: string[],
): Promise<Map<string, SecurityFinding[]>> {
  const findings = new Map<string, SecurityFinding[]>();
  if (files.length === 0) return findings;
  let api: TypeScriptApi | null = null;
  try {
    api = new TypeScriptApi({ cwd: repositoryRoot });
    const config = join(repositoryRoot, "tsconfig.json");
    const snapshot = api.updateSnapshot({
      ...((await pathExists(config)) ? { openProjects: [config] } : {}),
      openFiles: files,
    });
    try {
      const projects = snapshot.getProjects();
      for (const file of files) {
        const project = snapshot.getDefaultProjectForFile(file)
          ?? projects.find((candidate) => candidate.program.getSourceFile(file) !== undefined);
        const sourceFile = project?.program.getSourceFile(file);
        if (!sourceFile) continue;
        findings.set(file, scanTypeScriptAst(sourceFile, displayPath(repositoryRoot, file)));
      }
    } finally {
      snapshot.dispose();
    }
  } catch {
    // The compiler AST API has a platform-specific optional runtime. The
    // bounded syntax scanner remains available and the report exposes fallback use.
  } finally {
    api?.close();
  }
  return findings;
}

export async function scanSecurity(
  repositoryRoot: string,
  target = repositoryRoot,
): Promise<SecurityReport> {
  const roots = await securityScanRoots(repositoryRoot, target);
  const luaFiles = (
    await Promise.all(
      roots.map((root) => walkFiles(root, (path) => path.endsWith(".lua"), { skipTopLevelTests: true })),
    )
  )
    .flat()
    .sort(compareText);
  const typeScriptFiles = (
    await Promise.all(
      roots.map((root) => walkFiles(root, (path) => /\.(?:[cm]?[jt]s|[jt]sx)$/u.test(path), { skipTopLevelTests: true })),
    )
  )
    .flat()
    .sort(compareText);
  const findings: SecurityFinding[] = [];
  const astFindings = await compilerAstFindings(repositoryRoot, typeScriptFiles);
  let skippedLuaFiles = 0;
  let skippedTypeScriptFiles = 0;
  let astFiles = 0;
  let syntaxFallbackFiles = 0;

  for (const file of luaFiles) {
    try {
      findings.push(...scanLuaText(await readTextFile(file), displayPath(repositoryRoot, file)));
    } catch {
      skippedLuaFiles += 1;
    }
  }
  for (const file of typeScriptFiles) {
    try {
      const fileName = displayPath(repositoryRoot, file);
      const fallback = scanTypeScriptText(await readTextFile(file), fileName);
      const compiler = astFindings.get(file);
      const merged = new Map<string, SecurityFinding>();
      for (const finding of fallback) merged.set(`${finding.rule}:${finding.line}`, finding);
      if (compiler) {
        astFiles += 1;
        for (const finding of compiler) merged.set(`${finding.rule}:${finding.line}`, finding);
      } else {
        syntaxFallbackFiles += 1;
      }
      findings.push(...merged.values());
    } catch {
      skippedTypeScriptFiles += 1;
    }
  }
  findings.sort((left, right) => {
    const bySeverity = SEVERITY_ORDER[left.severity] - SEVERITY_ORDER[right.severity];
    if (bySeverity !== 0) return bySeverity;
    const byFile = compareText(left.file, right.file);
    return byFile !== 0 ? byFile : left.line - right.line;
  });

  return {
    target: displayPath(repositoryRoot, resolve(target)),
    filesScanned: luaFiles.length + typeScriptFiles.length - skippedLuaFiles - skippedTypeScriptFiles,
    filesByLanguage: {
      lua: luaFiles.length - skippedLuaFiles,
      typescript: typeScriptFiles.length - skippedTypeScriptFiles,
    },
    typescriptAnalysis: {
      astFiles,
      syntaxFallbackFiles,
      engine: "TypeScript compiler AST; bounded syntax fallback when the optional native API is unavailable",
    },
    skippedFiles: skippedLuaFiles + skippedTypeScriptFiles,
    findings,
    disclaimer: SECURITY_DISCLAIMER,
  };
}
