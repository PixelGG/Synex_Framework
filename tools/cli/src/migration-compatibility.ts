export interface MigrationChecksumCorrection {
  previous: string;
  current: string;
}

export const MIGRATION_CHECKSUM_CORRECTIONS: Readonly<Record<string, MigrationChecksumCorrection>> = Object.freeze({
  "synex_core:021_worker_queue_scalability": Object.freeze({
    previous: "6d314f977f47fa39125c9597172e75fa05d80bfbd310aaf6be4c5584f6823b59",
    current: "5add0fed6935b83e7fd0905c188c1e534a6636d5d935fea1a28a145f7b533b7c",
  }),
});

export function isRegisteredMigrationChecksumCorrection(
  identity: string,
  previous: string,
  current: string,
): boolean {
  const correction = MIGRATION_CHECKSUM_CORRECTIONS[identity];
  return correction?.previous === previous && correction.current === current;
}

export function isAcceptedAppliedMigrationChecksum(
  identity: string,
  expected: string,
  applied: string,
): boolean {
  return expected === applied || isRegisteredMigrationChecksumCorrection(identity, applied, expected);
}

export function isAcceptedMigrationControlChecksum(
  identity: string,
  expected: string,
  control: string,
  applied: string | undefined,
): boolean {
  return control === expected
    || (applied !== undefined
      && control === applied
      && isRegisteredMigrationChecksumCorrection(identity, applied, expected));
}
