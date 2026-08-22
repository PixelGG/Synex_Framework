import { statSync } from "node:fs";
import { basename, dirname, isAbsolute, join } from "node:path";

import { CliError } from "./errors.ts";

export interface PackageScriptInvocation {
  executable: string;
  arguments: string[];
}

function isRegularNpmCli(path: string): boolean {
  if (!isAbsolute(path) || !["npm-cli.js", "npm-cli.cjs"].includes(basename(path))) return false;
  try {
    return statSync(path).isFile();
  } catch {
    return false;
  }
}

export function npmScriptInvocation(script: string): PackageScriptInvocation {
  if (!/^[a-z][a-z0-9:_-]{0,63}$/u.test(script)) throw new CliError("Package script name is invalid.", 2);
  const candidates = [
    process.env.npm_execpath,
    join(dirname(process.execPath), "node_modules", "npm", "bin", "npm-cli.js"),
    join(dirname(dirname(process.execPath)), "lib", "node_modules", "npm", "bin", "npm-cli.js"),
  ].filter((candidate): candidate is string => typeof candidate === "string");
  const npmCli = candidates.find(isRegularNpmCli);
  if (npmCli) return { executable: process.execPath, arguments: [npmCli, "run", script] };
  if (process.platform === "win32") {
    throw new CliError("A safe npm-cli.js launcher could not be resolved for this Node installation.", 2);
  }
  return { executable: "npm", arguments: ["run", script] };
}
