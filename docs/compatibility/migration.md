# Legacy data migration

> [!WARNING]
> The migrator, compatibility profiles, and target domain resources are experimental rework snapshots. This workflow is not part of `synex_core` Production-Beta certification and must not be used for a production cutover until the downstream rework receives its own acceptance.

`tools/migrator` implements a review-gated copy/transform/import pipeline for controlled QBCore, Qbox, and ESX JSON exports. It never connects to or mutates the legacy source database. The source export and mapping are regular, non-symlink files opened read-only; target database access exists only in the explicit import phase.

No preapproved migrator mapping or compatibility profile ships. `fields.money` maps legacy account aliases to source paths; it does not declare currencies. Each alias must exist for the selected provider in the same checked-in Bridge mapping catalog used at runtime. The current `cash` and `bank` definitions both target currency `usd`, role `asset`, minor unit `0`, and distinct owner-scoped account-key namespaces. Unknown aliases such as custom ESX accounts fail closed until an explicit, reviewed catalog entry exists. Build and review a source-field mapping for the exact pinned source schema. The mapped user ID must be a supported Cfx platform identifier with its prefix (`license`, `license2`, `fivem`, `discord`, `steam`, `xbl`, or `live`); an ambiguous database key cannot be presented as a login identity. Synthetic examples under [`tests/compatibility/fixtures`](../../tests/compatibility/fixtures/) are test data, not production templates.

> [!CAUTION]
> The workflow and commands below exercise the checked-in experimental snapshot. Use them only with reviewed exports and disposable target rehearsals. Do not prepare a production cutover while groups, accounts, bridges, and the migrator remain outside their own accepted release boundary.

## 1. Generate a deterministic dry-run

```text
node --experimental-strip-types tools/migrator/src/bin.ts --framework qbx --source legacy-export.json --mapping qbx-mapping.json --report migration-report.json
```

Dry-run is the default. Source and mapping files are capped at 16 MiB, must be regular non-symlink files, and the planner accepts at most 10,000 source records—the same character limit enforced by the importer. It validates bounded dot-separated paths, assigns deterministic Synex IDs and character slots, and reports users, characters, account-alias totals, group mappings, conflicts, omissions, and economy conservation. Between one and 32 aliases may be selected. The planner binds their exact catalog IDs, versions, currency codes, roles, minor units, and canonical owner-scoped keys into the reviewed report and bundle. Source digests are calculated from canonical parsed JSON, so whitespace and object-key ordering do not change semantic evidence. No current time, random ID, working-directory path, database URL, or credential enters the report digest.

For example, an ESX mapping may explicitly declare:

```json
{
  "money": {
    "cash": "accounts.money",
    "bank": "accounts.bank"
  }
}
```

No SQL, expressions, array selectors, or JavaScript can be supplied through a mapping. JSON object strings commonly found in controlled legacy exports are decoded only during bounded path traversal.

Every imported legacy job or gang also needs an exact group definition in the checked-in Bridge mapping catalog. The migration mapping selects reviewed definitions by ID and binds the canonical catalog digest:

```json
{
  "compatibilityGroups": {
    "catalogDigest": "<exact reviewed catalog SHA-256>",
    "mappingIds": ["<reviewed provider-specific mapping ID>"]
  }
}
```

Each selected catalog definition binds the provider, legacy job or gang name, native group type and key, and an exact legacy-number-to-native-grade-key table. Unknown names become blocking `unknown_job_mapping` or `unknown_gang_mapping` conflicts; an unmapped numeric grade becomes `unknown_job_grade_mapping` or `unknown_gang_grade_mapping`. `groupMappings` is obsolete and rejected. The checked-in catalog deliberately contains no group definitions, so an operator must first add and review mappings for organizations and grades that already exist in `synex_groups`.

The importer resolves exactly one active native group and grade for every planned membership while holding the target rows. It creates membership, membership-profile, grade-assignment, primary-membership, audit, read-model, and outbox records, but it never creates organizations or grade definitions. A missing, inactive, changed, or ambiguous target aborts the transaction. The reviewed report records `createsGroups: false` and `createsGrades: false`, and both the catalog digest and selected definitions are revalidated before any write.

Metadata migration is narrower than source-field mapping. `fields.metadata` may point to a legacy metadata object only when `compatibilityMetadata` selects exact provider mappings from the runtime Bridge catalog and binds its current canonical digest:

```json
{
  "fields": {
    "metadata": "metadata"
  },
  "compatibilityMetadata": {
    "catalogDigest": "<exact reviewed catalog SHA-256>",
    "mappingIds": ["qbx.hunger"]
  }
}
```

The planner accepts only the selected keys and applies their catalog type and range/length bounds. Unmapped and forbidden keys are omitted under one generic report finding, without copying their names or values; invalid selected values are blocking conflicts. The report exposes counts and a digest over the restricted transformed values, never a complete legacy metadata blob or credentials. A changed catalog digest fails closed during both planning and import.

The console dry-run omits the raw ID map. Its identity evidence contains only identifier-type counts, a digest over hashed legacy identifiers, and a preservation plan which explicitly captures no credentials. Raw platform identifiers remain necessary inside a materialized reviewed bundle so the importer can create the canonical login identity; treat that bundle as restricted personal data.

## 2. Materialize a reviewed bundle

Resolve all blocking conflicts and review the generated report before materializing:

```text
node --experimental-strip-types tools/migrator/src/bin.ts --framework qbx --source legacy-export.json --mapping qbx-mapping.json --apply --target reviewed-qbx-bundle --confirm-target reviewed-qbx-bundle
```

The target must be a new directory beneath a real parent directory. Nothing is overwritten or removed. If vehicles or unmapped metadata are reported but not transformed, materialization also requires the explicit `--allow-unsupported` acknowledgement.

The bundle contains exactly:

```text
migration-report.json
id-map.json
migration-bundle.json
```

These files contain sensitive legacy identifiers and names. Keep them outside version control with restricted access and a defined deletion date. The report's preservation plan binds the reviewed `id-map.json` to `synex_identifiers`, `synex_legacy_id_mappings`, and `synex_compatibility_identities`; the importer verifies that exact table set and the hashed identity evidence before any write.

## 3. Historical target-rehearsal design

The snapshot expected a new disposable database and the following dependency order. This block is retained to describe that design only; it is not a runnable instruction for the accepted Core Production-Beta profile:

```cfg
ensure oxmysql
ensure synex_core
ensure synex_groups
ensure synex_accounts
```

Stop application traffic before importing. Record the exact `reportDigest` from the reviewed report. The importer refuses a missing Synex schema, a malformed or database-less URL, a tampered bundle, a digest mismatch, inconsistent counts/totals, or a conflicting target identity.

## 4. Import explicitly

Place the target MySQL URL in an uppercase environment variable; never pass credentials on the command line or commit them:

```text
SYNEX_MIGRATION_DATABASE_URL=mysql://user:password@127.0.0.1:3306/synex_rehearsal
```

PowerShell example:

```powershell
$env:SYNEX_MIGRATION_DATABASE_URL = 'mysql://user:password@127.0.0.1:3306/synex_rehearsal'
node --experimental-strip-types tools/migrator/src/bin.ts --import --bundle reviewed-qbx-bundle --confirm-report-digest <reviewed-sha256> --database-env SYNEX_MIGRATION_DATABASE_URL
```

The import is one database transaction. It writes import journal and hashed legacy-ID mapping rows, users and normalized platform identifiers, character slots and characters, persistent bridge identities, selected compatibility metadata, one catalog-bound asset account per configured character/account alias, memberships against existing catalog-bound groups and grades, primary-membership projections, audit/outbox records, and reconciliation read models. Accounts that share a currency receive deterministic owner-scoped keys such as `cash_<normalized-character-id>` and `bank_<normalized-character-id>`; the Bridge derives the same hyphen-free character suffix when it projects that character. Every imported currency is attached to one ready mint/burn topology. Positive opening values are posted as principal-scoped, reason-coded `multi_leg` transactions with two signed `synex_ledger_entries`; the compatibility posting row is retained for older readers. No balance is assigned directly.

For each character, the importer preserves the reviewed legacy character ID in `synex_compatibility_identities`: QB and QBX use identifier type `citizenid`, while ESX uses `identifier`. The row is bound to the imported Synex character and records `import_source = migration:<reportDigest>`. This is the durable bridge lookup evidence; it is created in the same transaction as the character and cannot be partially applied. `synex_legacy_id_mappings` stores SHA-256 hashes rather than duplicate raw legacy IDs, while the canonical platform identifier and compatibility identity tables necessarily retain the normalized values required for later association. Protect all three as identity data.

Selected metadata is written to `synex_compatibility_metadata` with the provider, imported character, catalog storage key, canonical typed JSON value, and initial version. The importer revalidates the current catalog digest, mapping version, storage key, type/bounds, counts, and metadata evidence digest before beginning the transaction. The same report-digest journal makes this write idempotent with the rest of the import.

Re-running a completed report digest is an idempotent no-write replay and returns `alreadyApplied: true`. A failure rolls back the transaction.

## 5. Reconcile and cut over

Before any future production use after the downstream rework has its own release acceptance:

1. compare imported user/character/group counts with the signed-off report;
2. verify every currency reconciliation run is healthy, every transaction's signed entries sum to zero, and each mint/burn topology is ready;
3. test account ownership and group membership through native Synex APIs;
4. rehearse application startup and compatibility consumers on an isolated FXServer;
5. back up the production target and define rollback criteria;
6. repeat the same digest-confirmed import during a controlled maintenance window.

Vehicles remain unsupported and are never imported. Only exact catalog-selected compatibility metadata is imported; arbitrary metadata is omitted and never presented as migrated.
