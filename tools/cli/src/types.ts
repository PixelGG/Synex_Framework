export type DiagnosticLevel = "error" | "warning" | "info";
export type SecuritySeverity = "critical" | "high" | "medium" | "low" | "info";
export type FindingConfidence = "high" | "medium" | "low";

export interface Diagnostic {
  level: DiagnosticLevel;
  rule: string;
  file: string;
  message: string;
  line?: number;
}

export interface SecurityFinding {
  severity: SecuritySeverity;
  confidence: FindingConfidence;
  rule: string;
  file: string;
  line: number;
  explanation: string;
  evidence: string;
}

export interface SecurityReport {
  target: string;
  filesScanned: number;
  filesByLanguage: { lua: number; typescript: number };
  typescriptAnalysis: {
    astFiles: number;
    syntaxFallbackFiles: number;
    engine: string;
  };
  skippedFiles: number;
  findings: SecurityFinding[];
  disclaimer: string;
}

export interface ContractFuzzReport {
  status: "PASS" | "WARN" | "FAIL";
  contracts: number;
  cases: number;
  rejected: number;
  unexpectedAccepted: Array<{ contract: string; version: string; case: string }>;
  skipped: Array<{ contract: string; version: string; reason: string }>;
  runtimeScenarios: {
    executed: boolean;
    reason: string;
    engine: string | null;
    passed: number;
    failed: number;
    scenarios: Array<{ name: string; status: "PASS" | "FAIL"; detail: string }>;
    limits: string[];
  };
  disclaimer: string;
}

export interface GeneratedArtifactResult {
  sourceHash: string;
  contractCount: number;
  changed: string[];
  stale: string[];
}

export interface CommandIo {
  log(message: string): void;
  error(message: string): void;
}
