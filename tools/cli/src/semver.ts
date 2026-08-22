import { compareText } from "./filesystem.ts";

export interface ParsedVersion {
  major: number;
  minor: number;
  patch: number;
  prerelease: string | null;
}

export function parseVersion(value: string): ParsedVersion | null {
  const match = /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z.-]+))?$/u.exec(value);
  if (!match) return null;
  const prerelease = match[4] ?? null;
  if (prerelease !== null) {
    const identifiers = prerelease.split('.');
    if (identifiers.some((identifier) =>
      identifier.length === 0 || !/^[0-9A-Za-z-]+$/u.test(identifier)
      || (/^[0-9]+$/u.test(identifier) && identifier.length > 1 && identifier.startsWith('0'))
    )) return null;
  }
  return {
    major: Number(match[1]),
    minor: Number(match[2]),
    patch: Number(match[3]),
    prerelease,
  };
}

export function compareVersion(left: ParsedVersion, right: ParsedVersion): number {
  for (const key of ["major", "minor", "patch"] as const) {
    if (left[key] !== right[key]) return left[key] - right[key];
  }
  if (left.prerelease === right.prerelease) return 0;
  if (left.prerelease === null) return 1;
  if (right.prerelease === null) return -1;
  const leftIdentifiers = left.prerelease.split('.');
  const rightIdentifiers = right.prerelease.split('.');
  for (let index = 0; index < Math.max(leftIdentifiers.length, rightIdentifiers.length); index += 1) {
    const leftIdentifier = leftIdentifiers[index];
    const rightIdentifier = rightIdentifiers[index];
    if (leftIdentifier === undefined) return -1;
    if (rightIdentifier === undefined) return 1;
    if (leftIdentifier === rightIdentifier) continue;
    const leftNumeric = /^[0-9]+$/u.test(leftIdentifier);
    const rightNumeric = /^[0-9]+$/u.test(rightIdentifier);
    if (leftNumeric && rightNumeric) {
      if (leftIdentifier.length !== rightIdentifier.length) return leftIdentifier.length - rightIdentifier.length;
      return compareText(leftIdentifier, rightIdentifier);
    }
    if (leftNumeric !== rightNumeric) return leftNumeric ? -1 : 1;
    return compareText(leftIdentifier, rightIdentifier);
  }
  return 0;
}

function comparatorSatisfied(version: ParsedVersion, token: string): boolean {
  const match = /^(\^|~|>=|<=|>|<|=)?\s*(.+)$/u.exec(token);
  if (!match) return false;
  const operator = match[1] ?? "=";
  const requested = parseVersion(match[2] ?? "");
  if (!requested) return false;
  const comparison = compareVersion(version, requested);
  if (operator === ">=") return comparison >= 0;
  if (operator === "<=") return comparison <= 0;
  if (operator === ">") return comparison > 0;
  if (operator === "<") return comparison < 0;
  if (operator === "~") {
    return comparison >= 0 && version.major === requested.major && version.minor === requested.minor;
  }
  if (operator === "^") {
    if (comparison < 0) return false;
    if (requested.major > 0) return version.major === requested.major;
    if (requested.minor > 0) return version.major === 0 && version.minor === requested.minor;
    return version.major === 0 && version.minor === 0 && version.patch === requested.patch;
  }
  return comparison === 0;
}

export function satisfiesVersionRange(versionValue: string, range: string): boolean {
  const version = parseVersion(versionValue);
  if (!version || version.prerelease !== null) return false;
  const tokens = range.trim().split(/\s+/u).filter(Boolean);
  return tokens.length > 0 && tokens.every((token) => comparatorSatisfied(version, token));
}
