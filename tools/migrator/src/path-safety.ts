import { lstat } from "node:fs/promises";
import { parse, relative, resolve, sep } from "node:path";

export async function pathContainsSymbolicLink(path: string): Promise<boolean> {
  const absolute = resolve(path);
  const root = parse(absolute).root;
  let current = root;
  for (const segment of relative(root, absolute).split(sep).filter(Boolean)) {
    current = resolve(current, segment);
    if ((await lstat(current)).isSymbolicLink()) return true;
  }
  return false;
}
