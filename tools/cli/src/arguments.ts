import { CliError } from "./errors.ts";
import { findRepositoryRoot } from "./filesystem.ts";

export interface ParsedArguments {
  positionals: string[];
  options: Map<string, string | boolean>;
}

const BOOLEAN_OPTIONS = new Set(["bundle", "check", "force", "help", "json"]);
const VALUE_OPTIONS = new Set(["adapter", "against", "baseline", "iterations", "output", "path", "probe", "root", "timeout"]);

export function parseArguments(argumentsList: string[]): ParsedArguments {
  const positionals: string[] = [];
  const options = new Map<string, string | boolean>();
  let positionalOnly = false;

  for (let index = 0; index < argumentsList.length; index += 1) {
    const argument = argumentsList[index];
    if (argument === undefined) continue;
    if (argument === "--") {
      positionalOnly = true;
      continue;
    }
    if (!positionalOnly && (argument === "-h" || argument === "--help")) {
      options.set("help", true);
      continue;
    }
    if (!positionalOnly && argument.startsWith("--")) {
      const separatorIndex = argument.indexOf("=");
      const name = argument.slice(2, separatorIndex < 0 ? undefined : separatorIndex);
      if (BOOLEAN_OPTIONS.has(name)) {
        if (separatorIndex >= 0) throw new CliError(`Option --${name} does not accept a value.`, 2);
        options.set(name, true);
        continue;
      }
      if (!VALUE_OPTIONS.has(name)) throw new CliError(`Unknown option --${name}.`, 2);
      const inlineValue = separatorIndex >= 0 ? argument.slice(separatorIndex + 1) : undefined;
      const nextValue = inlineValue ?? argumentsList[index + 1];
      if (!nextValue || (!inlineValue && nextValue.startsWith("--"))) {
        throw new CliError(`Option --${name} requires a value.`, 2);
      }
      options.set(name, nextValue);
      if (inlineValue === undefined) index += 1;
      continue;
    }
    positionals.push(argument);
  }

  return { positionals, options };
}

export function optionString(parsed: ParsedArguments, name: string): string | null {
  const value = parsed.options.get(name);
  return typeof value === "string" ? value : null;
}

export function optionBoolean(parsed: ParsedArguments, name: string): boolean {
  return parsed.options.get(name) === true;
}

export async function resolveRepositoryRoot(parsed: ParsedArguments): Promise<string> {
  const requestedRoot = optionString(parsed, "root");
  return findRepositoryRoot(requestedRoot ?? process.cwd());
}
