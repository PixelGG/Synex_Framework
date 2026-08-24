# Getting started

Synex `0.1.0` is an experimental source release, not a packaged drag-and-drop server distribution. Validate the repository first, then place the runnable resource directories where your FXServer can discover them.

## Requirements

- a current Cfx.re FXServer artifact with the `cerulean` resource manifest format;
- MariaDB 11.8 or MySQL 8.4 configured for oxmysql;
- `oxmysql` `2.14.1` or newer for Core; the current `synex_entities` manifest additionally requires a version below `3.0.0`;
- an oxmysql database session configured and verified to use UTC;
- OneSync in `on` mode when `synex_entities` is enabled;
- Node.js `22.12.0` or newer and npm `10` or newer for generation, validation, and tests. CI uses Node.js 24.

Node.js is a repository-development dependency. The Lua resources do not install npm packages on the game server.

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

FXServer must discover each runnable directory as a resource. The monorepo directories are:

```text
core/synex_core
resources/synex_groups
resources/synex_accounts
resources/synex_entities
resources/synex_control
libraries/synex_bridge
resources/synex_bridge_qb
resources/synex_bridge_qbx
resources/synex_bridge_esx
examples/synex_example
```

Do not place the unchanged repository root beneath the server's `resources/` directory and expect nested paths such as `core/synex_core` to be discovered. Deploy each runnable directory itself as a direct child of a FiveM resource collection. A category directory in square brackets is suitable, for example:

```text
server-data/
└── resources/
    └── [synex]/
        ├── synex_core/
        ├── synex_groups/
        ├── synex_accounts/
        ├── synex_entities/
        ├── synex_control/
        ├── synex_bridge/
        ├── synex_bridge_qb/
        ├── synex_bridge_qbx/
        ├── synex_bridge_esx/
        └── synex_example/
```

Copy or link only the selected resource directories while preserving the contents and names inside each one. This repository does not provide a deploy command that flattens the monorepo automatically.

Do not start every entry automatically. `synex_control`, compatibility bridges, and `synex_example` are optional. The native compatibility bridges do not require the corresponding external framework; they expose a limited legacy-shaped surface backed by Synex. Enable only the selected bridge and follow the [compatibility guide](compatibility/README.md). Directories that contain only `.gitkeep` are planned boundaries and are not runnable resources.

## Configure and start

Strict production mode requires a stable instance identifier. The value is ASCII, contains only letters, digits, `_` or `-`, and is at most 36 bytes.

```cfg
set synex_instance_id "primary-eu"
set synex_environment "production"
set synex_strict "1"
set mysql_transaction_isolation_level 2

ensure oxmysql
ensure synex_core
ensure synex_groups
ensure synex_accounts
ensure synex_entities
ensure synex_control
```

The sequential start order is intentional. Core exposes its kernel API first, then performs an admission validation against all installed `critical` Synex resources. Until groups, accounts, and entities have started and registered their required services, Core reports `DEGRADED` and rejects new player connections. Resource-start events trigger immediate revalidation; a successful full set moves Core to `READY` without a server restart.

Configure the database connection according to the installed oxmysql release before starting `oxmysql`. Keep credentials outside this repository and never put them in `config/default.json`. The account lock model expects oxmysql isolation level `2` (`READ COMMITTED`); set it explicitly and verify the effective server configuration rather than relying on an adapter default.

The database session used by oxmysql must use UTC. Synex stores and compares `DATETIME(6)` values with `CURRENT_TIMESTAMP(6)` throughout persistence and uses `UTC_TIMESTAMP(6)` for archive cutoffs; a non-UTC session can shift expiry, lease, queue, outbox, audit, and retention decisions. Before running any migration, Core compares both functions in one database statement and refuses to start when the offset is not zero or the validation query fails. Synex does not set the database session time zone, and this guide intentionally does not assume a connection-string option for a particular oxmysql/database build.

At Core boot, Synex applies its supported ConVar overrides and validates `config/default.json` plus `config/capabilities.json` before database access. It then verifies the UTC database session, discovers `synex.resource.json` through each resource's `synex_manifest` metadata, acquires a database-time migration lease, verifies checksums, applies the 26 declared Core migrations plus the migrations owned by installed domain resources, and validates declared service dependencies and generated contracts before entering `READY`. A boot failure is fail-closed.

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

## First resource

Study [`examples/synex_example`](../examples/synex_example/) and then follow [Creating a resource](development/creating-resources.md). The example registers a server-only contract and a versioned service without exposing a network endpoint.

## Current platform limits

- There is no packaged release installer or automatic updater.
- Repository tests do not launch FXServer. The 2026-08-24 acceptance build passed manual FXServer/MariaDB stages, including 26/26 Core migrations, persisted Saga execution, restart recovery, real-client join/disconnect/reconnect, and a pending-database-work prepared restart. The current tree then added two hardening corrections that passed repository and live-database regression gates; the complete manual FXServer/client sequence has not yet been repeated against that combined revision. The two-instance `kick_old` requester-restart scenario also remains untested. See [Testing](testing.md#current-acceptance-baseline).
- Public contracts are marked `experimental`.
- `synex_control` is an in-game, read-only NUI; no remote HTTP control API is implemented.
- The planned phone, inventory, banking UI, jobs, shops, vehicle, garage, radio, character-resource, identity-resource, and shared UI directories are not implemented gameplay resources.
