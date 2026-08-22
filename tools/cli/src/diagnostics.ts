import type { Diagnostic } from "./types.ts";

export function formatDiagnostic(diagnostic: Diagnostic): string {
  const location = diagnostic.line ? `${diagnostic.file}:${diagnostic.line}` : diagnostic.file;
  return `${diagnostic.level.toUpperCase()} ${diagnostic.rule} ${location} — ${diagnostic.message}`;
}
