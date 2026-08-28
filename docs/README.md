# Synex documentation

This documentation describes the code present in Synex `0.1.0`. The release is experimental: contracts, schemas, migrations, and operational behavior may change before a stable release. Passing repository tests does not by itself certify a production deployment.

The frozen Production-Beta decision applies to one exact `synex_core` tree only. The current workspace extends Core with additive domain persistence, deletion and Control-provider primitives, so those later Core changes do not inherit that decision. `synex_groups` is an Experimental Alpha Organizations Engine with 71 contracts and 31 owned migrations; its earlier working-tree evidence predates migration `032`, and its current acceptance remains open. `synex_accounts` is a server-only Experimental Alpha Financial Engine with 59 contracts and 18 owned migrations. Its current working tree passed the isolated MariaDB 11.8.8 database scope on 2026-08-28; FXServer, restart/recovery, restored-upgrade, exact-candidate acceptance, and a maturity decision remain open. `synex_entities` is Development / Experimental Alpha until its live MariaDB, FXServer/OneSync, restart/recovery and exact-candidate acceptance is complete. `synex_world` is Development / Experimental Alpha until its MariaDB, FXServer/OneSync, real-client, native Door/IPL/interior, transition and restart acceptance is complete. The separate optional `synex_control` read-only operations surface is also Development / Experimental Alpha until its provider-runtime and real CEF client acceptance is complete. `synex_bridge` is an implemented but unaccepted Experimental Alpha Compatibility Platform with separate QB/QBX/ESX providers and fail-closed checked-in configuration. Every later resource, remaining library, integration, and example remains experimental. Every non-Core component is excluded from the frozen Core profile.

`synex_ui` is an implemented Experimental Alpha UI foundation with a build-time React package and a separately deployable client runtime. Repository type, unit, browser, build, transport, and closed-state checks are development evidence; real FiveM/CEF loading, safe-zone behavior, controller navigation, focus recovery, gameplay-background readability, and performance acceptance remain open. It does not inherit the Core Production-Beta decision.

The documented Core-only profile reached **Production Beta** on 2026-08-25. Commit `7ad4b72ee9bcd0a2a0481cfacfe5f807eb1b3ec5` with Core tree `9f0960f1e27fe43195ae4602cb2ef447cbc0509b` passed its repository, live-database, fresh-boot, public-API, capacity, restart, crash-recovery, stale-facade, database-outage/recovery, automated, real-client, and review gates. The result is a production-oriented beta for that immutable profile, not acceptance of the current working tree, a stable `1.0`, or a framework-wide release.

The tested oxmysql lost-callback condition keeps player admission closed. The documentation does not claim automatic recovery from that condition: restore the database service, then restart the complete FXServer process before reopening admission. Multi-instance and alternate duplicate-policy verification remain explicitly out of scope. The maintained boundary is recorded under [Current acceptance baseline](testing.md#current-acceptance-baseline).

## Start here

- [Getting started](getting-started.md) — prerequisites, source checks, resource placement, start order, and runtime verification
- [Configuration](configuration.md) — settings that are wired today and settings that remain reserved
- [Operations](operations.md) — lifecycle, health, console commands, failure behavior, and backups
- [Testing](testing.md) — local suites, live-database gate, CI, and current coverage boundaries
- [Migrations](migrations.md) — forward-only SQL files, checksums, leases, and ownership

- [Core server configuration example](../examples/server.cfg.example) — secret-free single-instance baseline

## Release and support

- [Core Production-Beta release readiness](release-readiness.md) — canonical gate and evidence requirements
- [Known limitations](known-limitations.md) — current support, topology, compatibility, and operations boundary
- [MariaDB backup and restore](backup-and-restore.md) — safe logical-backup and isolated restore drill
- [Security policy](../SECURITY.md) — supported scope and private vulnerability reporting
- [Changelog](../CHANGELOG.md) — unreleased technical changes and maturity status

## Architecture and public interfaces

- [Architecture overview](architecture/README.md)
- [Runtime and session lifecycle](architecture/runtime.md)
- [Contracts and API stability](architecture/contracts.md)
- [Security model](architecture/security.md)
- [Public API and generated contract reference](api/README.md)
- [Creating a resource](development/creating-resources.md)
- [Lua and TypeScript SDKs](reference/sdks.md)
- [Developer CLI](reference/cli.md)
- [Generated contract catalog](../packages/contracts/generated/docs/contracts.md)
- [Architecture decisions](architecture/decisions/README.md)

## Experimental domain and rework references

`synex_groups`, `synex_accounts`, `synex_entities`, and `synex_world` are separate Experimental Alpha domains. The current source catalog contains 178 versioned contract definitions: exactly `synex.groups.self.snapshot` is `client-to-server`; the other 177 are server-only. Entities contributes 33 definitions across 32 names because `synex.entities.bucket.create` retains v1 and adds v2. Accounts, Entities and World have no client-callable contract or NUI contract surface. The separate `synex_control` Alpha discovers bounded read-only Core, Groups, Accounts, Entities, World, Control-self and optional Bridge-compatibility providers; it is operator tooling, not a gameplay or banking UI. Future financial gameplay/UI belongs to `synex_banking`. None is a supported component of the frozen Core Production-Beta profile.

`@synex/ui` provides build-time components, tokens, materials, accessibility primitives, and the browser Design Lab. The `synex_ui` client resource separately provides owner-bound focus leases, bounded input routing, generic shared surfaces, client-local preferences, and a versioned NUI transport. It owns no gameplay state, SQL, or server authority, and `synex_control` does not depend on it at runtime.

- [Database model](reference/database.md)
- [Organizations Engine guide](groups/overview.md)
- [Groups API reference](reference/groups.md)
- [Accounts Financial Engine](reference/accounts.md)
- [Server-only Accounts consumer example](../examples/synex_accounts-server.md)
- [Entity Authority Engine guide](entities/overview.md)
- [Entity contracts and configuration](reference/entities.md)
- [World Semantics & Spatial Authority guide](world/README.md)
- [World server API and contracts](world/api.md)
- [World testing and open acceptance](world/testing.md)
- [World companion-resource example](../examples/synex_world_companion/README.md)
- [UI Foundation overview](ui/README.md)
- [UI architecture and ownership boundary](ui/architecture.md)
- [UI components](ui/components.md)
- [UI development and open live acceptance](ui/development.md)
- [Control overview](control/overview.md)
- [Read-only control-plane reference](reference/control-plane.md)
- [Control architecture](control/architecture.md)
- [Control provider contract](control/providers.md)
- [Control diagnostics catalog](control/diagnostics.md)
- [Control permissions](control/permissions.md)
- [Control security boundary](control/security.md)
- [Control search and tracing](control/search-and-tracing.md)
- [Control performance and limits](control/performance.md)
- [Extending Control](control/extending-control.md)

## Security and compatibility

- [Capability policy and resource security](security/README.md)
- [Compatibility boundary](compatibility/README.md)
- [Compatibility architecture](compatibility/architecture.md)
- [QBCore](compatibility/qbcore.md), [Qbox](compatibility/qbox.md), and [ESX](compatibility/esx.md) provider surfaces
- [Compatibility modes and deployment](compatibility/modes.md)
- [Compatibility mappings](compatibility/mappings.md) and [domain adapters](compatibility/adapters.md)
- [Compatibility profiles](compatibility/profiles.md) and [certification](compatibility/certification.md)
- [Compatibility security](compatibility/security.md)
- [Compatibility matrix](compatibility/matrix.md)
- [Legacy migration pipeline](compatibility/migration.md)
- [Compatibility troubleshooting](compatibility/troubleshooting.md)

## Repository operations

- [Discord notification automation](discord-notifications.md)
- [README translations](locales/README.md)

The root [README](../README.md) is the product landing page. Detailed implementation and operator guidance belongs here.
