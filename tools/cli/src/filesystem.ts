import { createHash } from "node:crypto";
import {
  access,
  lstat,
  mkdir,
  readFile,
  readdir,
  rename,
  rm,
  writeFile,
} from "node:fs/promises";
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from "node:path";

import { CliError } from "./errors.ts";

const RESOURCE_SCHEMA_PATH = "schemas/resource.schema.json";
const MAX_TEXT_FILE_BYTES = 2 * 1024 * 1024;
const MAX_SCAN_FILES = 20_000;
const SKIPPED_DIRECTORIES = new Set([
  ".build",
  ".git",
  ".synex",
  ".temp",
  "artifacts",
  "coverage",
  "dist",
  "node_modules",
  "tmp",
]);

export function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

export function compareText(left: string, right: string): number {
  if (left < right) return -1;
  if (left > right) return 1;
  return 0;
}

export async function pathExists(path: string): Promise<boolean> {
  try {
    await access(path);
    return true;
  } catch {
    return false;
  }
}

export async function isDirectory(path: string): Promise<boolean> {
  try {
    return (await lstat(path)).isDirectory();
  } catch {
    return false;
  }
}

export function toPosixPath(path: string): string {
  return path.split(sep).join("/");
}

export function displayPath(root: string, path: string): string {
  const value = relative(root, path);
  return toPosixPath(value || ".");
}

export function containsPath(base: string, target: string): boolean {
  const value = relative(resolve(base), resolve(target));
  return value === "" || (!isAbsolute(value) && value !== ".." && !value.startsWith(`..${sep}`));
}

export function resolveWithin(root: string, requested: string): string {
  const base = resolve(root);
  const target = resolve(base, requested);
  const rel = relative(base, target);
  if (rel === ".." || rel.startsWith(`..${sep}`) || isAbsolute(rel)) {
    throw new CliError("Path must remain inside the selected repository root.", 2);
  }
  return target;
}

export async function readTextFile(path: string): Promise<string> {
  const metadata = await lstat(path);
  if (!metadata.isFile() || metadata.size > MAX_TEXT_FILE_BYTES) {
    throw new CliError(`Refusing to read oversized or non-regular file: ${basename(path)}`);
  }
  return readFile(path, "utf8");
}

export async function readJsonFile(path: string): Promise<unknown> {
  try {
    return JSON.parse(await readTextFile(path)) as unknown;
  } catch (error) {
    if (error instanceof CliError) throw error;
    if (error instanceof SyntaxError) throw new CliError(`Invalid JSON in ${basename(path)}.`);
    const code = isRecord(error) && typeof error.code === "string" ? error.code : "READ_FAILED";
    throw new CliError(`Unable to read required JSON file ${basename(path)} (${code}).`);
  }
}

export async function walkFiles(
  root: string,
  predicate: (path: string) => boolean,
  options: { skipTopLevelTests?: boolean } = {},
): Promise<string[]> {
  if (!(await isDirectory(root))) return [];

  const files: string[] = [];
  const pending = [resolve(root)];
  while (pending.length > 0) {
    const directory = pending.pop();
    if (!directory) break;

    const entries = (await readdir(directory, { withFileTypes: true })).sort((left, right) =>
      compareText(left.name, right.name),
    );
    for (const entry of entries) {
      const path = join(directory, entry.name);
      if (entry.isSymbolicLink()) continue;
      if (entry.isDirectory()) {
        const topLevelRelative = relative(root, path).split(sep)[0];
        if (SKIPPED_DIRECTORIES.has(entry.name)) continue;
        if (options.skipTopLevelTests && topLevelRelative === "tests") continue;
        pending.push(path);
      } else if (entry.isFile() && predicate(path)) {
        files.push(path);
        if (files.length > MAX_SCAN_FILES) {
          throw new CliError(`File scan exceeded the ${MAX_SCAN_FILES} file safety limit.`);
        }
      }
    }
  }

  return files.sort(compareText);
}

export async function findRepositoryRoot(start = process.cwd()): Promise<string> {
  let current = resolve(start);
  while (true) {
    if (
      (await pathExists(join(current, "package.json"))) &&
      (await pathExists(join(current, RESOURCE_SCHEMA_PATH)))
    ) {
      return current;
    }
    const parent = dirname(current);
    if (parent === current) break;
    current = parent;
  }
  throw new CliError("Synex repository root could not be located.", 2);
}

export function canonicalize(value: unknown): unknown {
  if (Array.isArray(value)) return value.map((entry) => canonicalize(entry));
  if (value !== null && typeof value === "object") {
    const output: Record<string, unknown> = {};
    for (const key of Object.keys(value).sort(compareText)) {
      output[key] = canonicalize((value as Record<string, unknown>)[key]);
    }
    return output;
  }
  return value;
}

export function canonicalJson(value: unknown): string {
  return JSON.stringify(canonicalize(value));
}

export function prettyJson(value: unknown): string {
  return `${JSON.stringify(canonicalize(value), null, 2)}\n`;
}

export function sha256(value: string): string {
  return createHash("sha256").update(value, "utf8").digest("hex");
}


export async function writeFileAtomic(path: string, contents: string): Promise<void> {
  await mkdir(dirname(path), { recursive: true });
  const temporary = join(dirname(path), `.${basename(path)}.${process.pid}.tmp`);
  await writeFile(temporary, contents, { encoding: "utf8", flag: "wx" });
  try {
    await rename(temporary, path);
  } catch (error) {
    const code = isRecord(error) && typeof error.code === "string" ? error.code : "";
    if (!["EEXIST", "EPERM"].includes(code)) throw error;
    await rm(path, { force: true });
    await rename(temporary, path);
  } finally {
    await rm(temporary, { force: true });
  }
}
