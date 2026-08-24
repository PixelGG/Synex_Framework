# Getting started

Synex `0.1.0` is an experimental source release, not a packaged drag-and-drop server distribution. The current Production-Beta candidate covers `synex_core` only. `synex_groups`, `synex_accounts`, `synex_entities`, `synex_control`, every later resource, and all non-Core libraries, bridges, SDK integrations, and examples are experimental rework snapshots or scaffolds entirely outside that certification boundary.

This guide installs only the Core candidate. Do not add `synex_groups`, `synex_accounts`, `synex_entities`, `synex_control`, compatibility bridges, or other downstream modules to a deployment that is intended to match the documented Core acceptance profile.

## Requirements

- the current Windows acceptance target with Cfx.re FXServer artifact `35245` and the `cerulean` resource manifest format;
- MariaDB `11.8.8` with InnoDB;
- `oxmysql` `2.14.1`;
- an oxmysql database session configured and verified to use UTC;
- one `synex_core` instance using strict production mode and duplicate policy `deny_new`;
- Node.js `22.12.0` or newer and npm `10` or newer for generation, validation, and tests. CI uses Node.js 24.

Node.js is a repository-development dependency. The Lua resources do not install npm packages on the game server.

Other FXServer artifacts, operating systems, oxmysql versions, MySQL, multi-instance operation, and the non-production duplicate policies are not part of the initial Production-Beta support matrix. See [Release readiness](release-readiness.md) and [Known limitations](known-limitations.md) before deployment.

## Validate the source tree

For a fresh checkout:

```bash
git clone https://github.com/PixelGG/Synex_Framework.git
cd Synex_Framework
npm ci
npm run check
npm test
npm run security
npm run certify
```

`npm run check` verifies generated contract consistency, compiles TypeScript, and validates contracts, resource manifests, state definitions, runtime configuration, capability policy, and explicit configuration cross-field rules. The default local test run is headless; the live database test is skipped unless its destructive-test gate is explicitly enabled. See [Testing](testing.md).

## Place the resources

FXServer must discover each runnable directory as a resource. To exercise the current Core-only candidate profile, deploy:

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

Copy or link only the selected resource directories while preserving the contents and names inside each one. This repository does not provide a deploy command that flattens the monorepo automatically.

Do not start the other repository entries automatically. They remain useful implementation and contract references while their rework is in progress, but they are unsupported in the Core Production-Beta profile. Directories that contain only `.gitkeep` are planned boundaries and are not runnable resources.

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

The sequential start order is intentional. Core validates installed Synex manifests and critical dependencies before it opens admission. A Core-only candidate installation includes no downstream critical resource; adding an experimental resource can introduce new critical dependencies and makes that deployment different from the acceptance target.

Configure the database connection according to the installed oxmysql release before starting `oxmysql`. Keep credentials outside this repository and never put them in `config/default.json`. The Core transaction model expects oxmysql isolation level `2` (`READ COMMITTED`); set it explicitly and verify the effective server configuration rather than relying on an adapter default.

The database session used by oxmysql must use UTC. Synex stores and compares `DATETIME(6)` values with `CURRENT_TIMESTAMP(6)` throughout persistence and uses `UTC_TIMESTAMP(6)` for archive cutoffs; a non-UTC session can shift expiry, lease, queue, outbox, audit, and retention decisions. Before running any migration, Core compares both functions in one database statement and refuses to start when the offset is not zero or the validation query fails. Synex does not set the database session time zone, and this guide intentionally does not assume a connection-string option for a particular oxmysql/database build.

At Core boot, Synex applies its documented ConVar overrides and validates `config/default.json` plus `config/capabilities.json` before database access. It then verifies the UTC database session, discovers `synex.resource.json` through each resource's `synex_manifest` metadata, acquires a database-time migration lease, verifies checksums, applies the 26 declared Core migrations, and validates declared service dependencies and generated contracts before entering `READY`. A boot failure is fail-closed. Migrations owned by experimental resources are intentionally absent from the Core-only installation.

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
- Repository tests do not launch FXServer. Predecessor `888a7326` passed the automated gate and the major server stages, including the retained `cd4b3cd5` 25-to-26 rehearsal, but its planned minimum soak failed at the first hourly outbox-retention execution before the minimum duration completed. The current runtime tree contains the trusted Cfx JSON-container fix introduced by `e0cbf45`. See [Testing](testing.md#current-acceptance-baseline).
- Repository validation passes on that runtime tree; the selected clean post-documentation revision still needs its complete exact server gate, fresh 120-minute soak, and client lifecycle. Acceptance therefore remains **IN PROGRESS / NO-GO**; this is not yet a production-stable beta.
- A lost oxmysql callback does not imply automatic recovery. Admission remains closed; after restoring the database service, restart the complete FXServer process before reopening admission.
- Public contracts and the consumer API surface remain `experimental` even when the Core runtime reaches Production-Beta acceptance.
- MySQL, multi-instance operation, `kick_old`, `replace_old`, and `allow` are outside the initial acceptance target. Strict production configuration accepts only `deny_new`.
- `synex_groups`, `synex_accounts`, `synex_entities`, `synex_control`, all later resources, bridges, libraries, integrations, and examples are rework snapshots or scaffolds. None is included in Core Production-Beta certification.
