# Legacy data migration

> [!WARNING]
> The migrator, compatibility profiles, and target domain resources are experimental rework snapshots. This workflow is not part of `synex_core` Production-Beta certification and must not be used for a production cutover until the downstream rework receives its own acceptance.

`tools/migrator` implements a review-gated copy/transform/import pipeline for controlled QBCore, Qbox, and ESX JSON exports. It never connects to or mutates the legacy source database. The source export and mapping are regular, non-symlink files opened read-only; target database access exists only in the explicit import phase.

The built-in profiles describe mapping semantics, not every community schema. Build and review a mapping for the exact pinned source schema. The mapped user ID must be a supported Cfx platform identifier with its prefix (`license`, `license2`, `fivem`, `discord`, `steam`, `xbl`, or `live`); an ambiguous database key cannot be presented as a login identity. Synthetic examples under [`tests/compatibility/fixtures`](../../tests/compatibility/fixtures/) are test data, not production templates.

> [!CAUTION]
> The workflow and commands below document the checked-in historical snapshot for source review. Do not execute them against a deployment or prepare a cutover while groups, accounts, bridges, and the migrator are being reworked. A future release must publish a newly reviewed workflow and acceptance boundary.

## 1. Generate a deterministic dry-run

```text
node --experimental-strip-types tools/migrator/src/bin.ts --framework qbx --source legacy-export.json --mapping qbx-mapping.json --report migration-report.json
```

Dry-run is the default. The planner validates bounded dot-separated paths, assigns deterministic Synex IDs and character slots, and reports users, characters, cash/bank totals, group mappings, conflicts, omissions, and economy conservation. It embeds no current time, random ID, or working-directory path, so identical inputs and mapping produce the same report digest.

No SQL, expressions, array selectors, or JavaScript can be supplied through a mapping. JSON object strings commonly found in controlled legacy exports are decoded only during bounded path traversal.

## 2. Materialize a reviewed bundle

Resolve all blocking conflicts and review the generated report before materializing:

```text
node --experimental-strip-types tools/migrator/src/bin.ts --framework qbx --source legacy-export.json --mapping qbx-mapping.json --apply --target reviewed-qbx-bundle --confirm-target reviewed-qbx-bundle
```

The target must be a new directory beneath a real parent directory. Nothing is overwritten or removed. If vehicles or metadata are reported but not transformed, materialization also requires the explicit `--allow-unsupported` acknowledgement.

The bundle contains exactly:

```text
migration-report.json
id-map.json
migration-bundle.json
```

These files contain sensitive legacy identifiers and names. Keep them outside version control with restricted access and a defined deletion date.

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

The import is one database transaction. It writes import journal and hashed legacy-ID mapping rows, users and normalized platform identifiers, character slots and characters, compatible cash/bank accounts, balanced opening ledger entries, owner roles/grants, group grades/memberships, audit/outbox records, and reconciliation read models. The mapping table stores SHA-256 hashes rather than duplicate raw legacy IDs. The canonical identifier table necessarily stores the normalized platform identity needed to associate a later Cfx connection with the imported user and must receive the same privacy protection as other account identifiers.

Re-running a completed report digest is an idempotent no-write replay and returns `alreadyApplied: true`. A failure rolls back the transaction.

## 5. Reconcile and cut over

Before any future production use after the downstream rework has its own release acceptance:

1. compare imported user/character/group counts with the signed-off report;
2. verify every currency reconciliation run is healthy and ledger postings balance to zero;
3. test account ownership and group membership through native Synex APIs;
4. rehearse application startup and compatibility consumers on an isolated FXServer;
5. back up the production target and define rollback criteria;
6. repeat the same digest-confirmed import during a controlled maintenance window.

Vehicles and arbitrary metadata are not imported by this pipeline. Their presence is reported and never presented as a completed migration.
