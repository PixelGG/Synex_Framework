# Synex documentation

This documentation describes the code present in Synex `0.1.0`. The release is experimental: contracts, schemas, migrations, and operational behavior may change before a stable release. Passing repository tests does not by itself certify a production deployment.

Core runtime commit `510053e` passed its server-only FXServer/MariaDB acceptance path on 2026-08-24. Real FiveM client join, disconnect, reconnect, and live cleanup acceptance remains pending; the maintained boundary is recorded under [Current acceptance baseline](testing.md#current-acceptance-baseline).

## Start here

- [Getting started](getting-started.md) — prerequisites, source checks, resource placement, start order, and runtime verification
- [Configuration](configuration.md) — settings that are wired today and settings that remain reserved
- [Operations](operations.md) — lifecycle, health, console commands, failure behavior, and backups
- [Testing](testing.md) — local suites, live-database gate, CI, and current coverage boundaries
- [Migrations](migrations.md) — forward-only SQL files, checksums, leases, and ownership

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

## Foundation resources

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
