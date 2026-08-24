# Synex documentation

This documentation describes the code present in Synex `0.1.0`. The release is experimental: contracts, schemas, migrations, and operational behavior may change before a stable release. Passing repository tests does not by itself certify a production deployment.

The Production-Beta effort applies to `synex_core` only. `synex_groups`, `synex_accounts`, `synex_entities`, `synex_control`, every later resource, and all non-Core libraries, bridges, integrations, and examples are experimental rework snapshots or scaffolds. They are entirely excluded from this beta profile; do not start or advertise them as certified components.

Predecessor `888a7326` passed the automated gate and the major server-side stages, but its planned minimum 120-minute soak failed at the first hourly outbox-retention execution, before the minimum duration completed, and ended **FAIL / NO-GO**. The current runtime tree contains the trusted Cfx JSON-container fix introduced by `e0cbf45` and exact connection-queue capacity coverage. Repository validation passes; the clean post-documentation revision still needs the complete exact server gate, a fresh soak, and its client lifecycle. Acceptance is therefore **IN PROGRESS / NO-GO**, not a production-stable beta.

The tested oxmysql lost-callback condition keeps player admission closed. The documentation does not claim automatic recovery from that condition: restore the database service, then restart the complete FXServer process before reopening admission. Multi-instance and `kick_old` verification remain an explicitly out-of-scope future profile. The maintained boundary is recorded under [Current acceptance baseline](testing.md#current-acceptance-baseline).

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

## Foundation rework references

These non-Core implementations are development inputs for a planned full rework. They are not supported components of the Core Production-Beta profile.

- [Database model](reference/database.md)
- [Groups and memberships](reference/groups.md)
- [Accounts, ledger, and holds](reference/accounts.md)
- [Entity authority and routing buckets](reference/entities.md)
- [Read-only control plane](reference/control-plane.md)

## Security and compatibility

- [Capability policy and resource security](security/README.md)
- [Compatibility boundary](compatibility/README.md)
- [Compatibility matrix](compatibility/matrix.md)
- [Legacy migration pipeline](compatibility/migration.md)

## Repository operations

- [Discord notification automation](discord-notifications.md)
- [README translations](locales/README.md)

The root [README](../README.md) is the product landing page. Detailed implementation and operator guidance belongs here.
