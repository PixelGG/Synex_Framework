# Getting started

Synex `0.1.0` is an experimental source release, not a packaged drag-and-drop server distribution. The accepted Production-Beta profile covers `synex_core` only. `synex_groups` is an Experimental Alpha Organizations Engine with separate working-tree evidence and open acceptance items. `synex_accounts` is a server-only Experimental Alpha Financial Engine whose current working tree passed the isolated MariaDB 11.8.8 database scope; FXServer, restart/recovery, restored-upgrade, exact-candidate acceptance, and a maturity decision remain open. `synex_entities` is a server-only Development / Experimental Alpha Entity Authority Engine whose implementation and repository regression surface are present; fresh MariaDB, live FXServer/OneSync, restart/recovery, cluster, real-client/Control, and exact-candidate acceptance remain open. Its read-only `synex_control` projection is experimental. Every later resource and all non-Core libraries, bridges, SDK integrations, and examples remain rework snapshots or scaffolds. All downstream components are outside Core certification.

This guide installs only the accepted Core profile. Do not add `synex_groups`, `synex_accounts`, `synex_entities`, `synex_control`, compatibility bridges, or other downstream modules to a deployment that is intended to match the documented Core acceptance profile.

Developers reviewing the Financial Engine should use the [Accounts reference](reference/accounts.md) and [server-only consumer example](../examples/synex_accounts-server.md). Those pages describe an Alpha candidate and do not extend this Core installation guide. Accounts exposes no client or NUI; future gameplay and UI belong to `synex_banking`.

## Requirements

- the current Windows acceptance target with Cfx.re FXServer artifact `35245` and the `cerulean` resource manifest format;
- MariaDB `11.8.8` with InnoDB;
- `oxmysql` `2.14.1`;
- an oxmysql database session configured and verified to use UTC;
- a dedicated MariaDB principal with the normal schema/DML rights required by Core plus `CREATE ROUTINE`, table `ALTER`, `EXECUTE`, and `ALTER ROUTINE`; MariaDB uses `ALTER ROUTINE` to authorize removal of the temporary migration procedures and has no separate `DROP ROUTINE` privilege (see [Database foundation](reference/database.md#migration-protocol));
- one `synex_core` instance using strict production mode and duplicate policy `deny_new`;
- Node.js `22.12.0` or newer and npm `10` or newer for generation, validation, and tests. CI uses Node.js 24.

Node.js is a repository-development dependency. The Lua resources do not install npm packages on the game server.

Other FXServer artifacts, operating systems, oxmysql versions, MySQL, multi-instance operation, and the non-production duplicate policies are not part of the initial Production-Beta support matrix. See [Release readiness](release-readiness.md) and [Known limitations](known-limitations.md) before deployment.

## Validate the source tree

For a fresh checkout of the current development candidate:

```bash
git clone https://github.com/PixelGG/Synex_Framework.git
cd Synex_Framework
npm ci
npm run check
npm test
npm run security
npm run certify
```

`npm run check` verifies generated contract consistency, compiles TypeScript, and validates contracts, resource manifests, state definitions, runtime configuration, capability policy, and explicit configuration cross-field rules. The default local test run is headless; the live database test is skipped unless its destructive-test gate is explicitly enabled. These commands validate the checked-out candidate; they do not make its current Core additions part of the frozen acceptance decision. See [Testing](testing.md).

## Place the resources

FXServer must discover each runnable directory as a resource. To run the accepted Core-only profile, deploy:

```text
core/synex_core
```

Do not place the unchanged repository root beneath the server's `resources/` directory and expect nested paths such as `core/synex_core` to be discovered. Deploy each runnable directory itself as a direct child of a FiveM resource collection. A category directory in square brackets is suitable, for example:

```text
server-data/
└── resources/
    └── [synex]/
        └── synex_core/
```

Copy or link only the selected resource directories while preserving the contents and names inside each one. This repository does not provide a deploy command that flattens the monorepo automatically. Reproducing the accepted profile requires the exact frozen Core revision named in [Release readiness](release-readiness.md); the current workspace includes later Core domain primitives and is a separate candidate.

Do not start the other repository entries automatically. Groups, Accounts, Entities, and the read-only Entity Control projection are implemented experimental candidates, while other entries may still be rework snapshots or scaffolds. None is supported by the Core Production-Beta profile. Directories that contain only `.gitkeep` are planned boundaries and are not runnable resources.

## Configure and start

Strict production mode requires a stable instance identifier. The value is ASCII, contains only letters, digits, `_` or `-`, and is at most 36 bytes.

```cfg
set synex_instance_id "primary-eu"
set synex_environment "production"
set synex_strict "1"
set synex_duplicate_policy "deny_new"
set mysql_transaction_isolation_level 2

ensure oxmysql
ensure synex_core
```

The sequential start order is intentional. Core validates installed Synex manifests and critical dependencies before it opens admission. The accepted Core-only installation includes no downstream critical resource; adding an experimental resource can introduce new critical dependencies and makes that deployment different from the accepted profile.

Configure the database connection according to the installed oxmysql release before starting `oxmysql`. Keep credentials outside this repository and never put them in `config/default.json`. Grant the dedicated principal the normal schema/DML rights required by Core and the migration-specific `CREATE ROUTINE`, table `ALTER`, `EXECUTE`, and `ALTER ROUTINE` rights listed above; do not look for a MariaDB `DROP ROUTINE` privilege. The Core transaction model expects oxmysql isolation level `2` (`READ COMMITTED`); set it explicitly and verify the effective server configuration rather than relying on an adapter default.

The database session used by oxmysql must use UTC. Synex stores and compares `DATETIME(6)` values with `CURRENT_TIMESTAMP(6)` throughout persistence and uses `UTC_TIMESTAMP(6)` for archive cutoffs; a non-UTC session can shift expiry, lease, queue, outbox, audit, and retention decisions. Before running any migration, Core compares both functions in one database statement and refuses to start when the offset is not zero or the validation query fails. Synex does not set the database session time zone, and this guide intentionally does not assume a connection-string option for a particular oxmysql/database build.

At Core boot, Synex applies its documented ConVar overrides and validates `config/default.json` plus `config/capabilities.json` before database access. It then verifies the UTC database session, discovers `synex.resource.json` through each resource's `synex_manifest` metadata, acquires a database-time migration lease, verifies checksums, applies the migrations declared by that exact Core revision, and validates declared service dependencies and generated contracts before entering `READY`. A boot failure is fail-closed. The frozen accepted revision declares 26 Core migrations; the current candidate declares the additional `027_domain_primitives` migration and does not inherit that evidence. Migrations owned by experimental resources are intentionally absent from the Core-only installation.

## Verify the runtime

The implemented restricted, console-only read commands are:

```text
synex overview
synex status
synex doctor
synex resources
synex sessions
synex permissions
synex trace <trace|character|transaction|resource> <value> [limit]
synex migrations
synex ledger
synex entities
synex access <userId> [limit]
```

`synex overview` prints the compact human-readable boot, database, resource, session, worker, cluster, and migration summary. `synex status` prints the structured Core lifecycle snapshot. `synex doctor` checks database connectivity and UTC session semantics, incomplete or failed migration attempts, the oxmysql version, service dependency declarations, generated contract registration, and lifecycle state. `synex_status` and `synex_doctor` remain compatibility aliases. Every command is registered as restricted and also rejects player execution explicitly. Access mutation commands and exact argument rules are documented under [Operations](operations.md).

In the Core-only profile, the optional `synex ledger` and `synex entities` summaries are expected to report their provider as not installed. That is not a Core health failure.

## First resource

The current [`examples/synex_example`](../examples/synex_example/) and [resource-development guide](development/creating-resources.md) demonstrate the experimental API model. They are reference material for the downstream rework, not a production-ready extension template and not part of Core certification.

## Current platform limits

- There is no packaged release installer or automatic updater.
- Repository tests do not launch FXServer or a FiveM client. Current-tree live-database, fresh-boot, public-API, capacity, restart, crash-recovery, and stale-facade evidence is separate from the headless suite. See [Testing](testing.md#current-acceptance-baseline).
- The documented Core-only profile reached Production Beta on 2026-08-25. Database-outage/recovery, the final automated run, documentation/final-diff/secret review, publication to `main`, and the real-client join/clean-disconnect/reconnect smoke passed for the accepted Core tree. This does not certify another host, dependency combination, topology, or downstream resource.
- A lost oxmysql callback does not imply automatic recovery. Admission remains closed; after restoring the database service, restart the complete FXServer process before reopening admission.
- Public contracts and the consumer API surface remain `experimental` even when the Core runtime reaches Production-Beta acceptance.
- MySQL, multi-instance operation, `kick_old`, `replace_old`, and `allow` are outside the initial acceptance target. Strict production configuration accepts only `deny_new`.
- `synex_groups` is an Experimental Alpha Organizations Engine, `synex_accounts` is a server-only Experimental Alpha Financial Engine, and `synex_entities` is a server-only Development / Experimental Alpha Entity Authority Engine with an experimental read-only Control projection. Entity implementation and repository checks are present, but fresh MariaDB, live FXServer/OneSync, restart/recovery, cluster, real-client/Control, and exact-candidate acceptance remain open. Later resources, bridges, libraries, integrations, and examples remain rework snapshots or scaffolds. None is included in Core Production-Beta certification.
- A 125-minute soak, permanent evidence runner, historical supported-version upgrade drill, extensive backup/restore certification, and extra non-critical ABI cases are deferred to the post-Beta promotion phase.
