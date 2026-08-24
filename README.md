<p align="center">
  <img src="./.github/assets/branding/synex-mark.svg" width="96" height="96" alt="Synex mark">
</p>

<h1 align="center">Synex</h1>

<p align="center">
  <strong>A contract-first FiveM Core built around explicit ownership and fail-closed boundaries.</strong>
</p>

<p align="center">
  <code>synex_core</code> binds resource identity, lifecycle, policy, persistence, and observability behind a versioned API.<br>
  Downstream modules remain outside the current certification boundary while they are reworked.
</p>

<p align="center">
  <strong>EN</strong>
  &nbsp;&middot;&nbsp;
  <a href="./docs/locales/de/README.md">DE</a>
  &nbsp;&middot;&nbsp;
  <a href="./docs/locales/fr/README.md">FR</a>
  &nbsp;&middot;&nbsp;
  <a href="./docs/locales/es/README.md">ES</a>
  &nbsp;&middot;&nbsp;
  <a href="./docs/locales/pt-BR/README.md">PT-BR</a>
</p>

<p align="center">
  <a href="#current-verification">Verification</a> &middot;
  <a href="#architecture">Architecture</a> &middot;
  <a href="#getting-started">Getting started</a> &middot;
  <a href="./docs/README.md">Documentation</a> &middot;
  <a href="https://discord.gg/heJU5t2Hfa">Discord</a>
</p>

<p align="center">
  <img alt="Target: FiveM" src="https://img.shields.io/badge/target-FiveM-5ed7ff?style=flat-square&amp;labelColor=111827">
  <img alt="Version: 0.1.0" src="https://img.shields.io/badge/version-0.1.0-4b94ff?style=flat-square&amp;labelColor=111827">
  <img alt="Maturity: experimental" src="https://img.shields.io/badge/maturity-experimental-8b73ff?style=flat-square&amp;labelColor=111827">
  <a href="https://github.com/PixelGG/Synex_Framework/actions/workflows/framework-ci.yml?query=branch%3Amain"><img alt="Framework CI" src="https://github.com/PixelGG/Synex_Framework/actions/workflows/framework-ci.yml/badge.svg?branch=main"></a>
  <a href="./LICENSE"><img alt="License: AGPL-3.0-only" src="https://img.shields.io/badge/license-AGPL--3.0--only-45c9a5?style=flat-square&amp;labelColor=111827"></a>
</p>

<p align="center">
  <img src="./.github/assets/readme/runtime-flow.svg" width="1200" alt="Synex modular runtime flow">
</p>

> [!CAUTION]
> **Core Production-Beta candidate — IN PROGRESS / NO-GO.** Synex `0.1.0` is still an experimental source release. Only `synex_core` is being evaluated for the first Production-Beta profile, and the exact current candidate has not completed every mandatory acceptance gate. Public contracts remain `experimental`; there is no framework-wide stable release or production-support claim.

## Current verification

Development runs have already exercised repository checks, the 26-migration MariaDB chain, isolated FXServer boot, public Core APIs, recovery paths, and a real-client join/disconnect/reconnect sequence. That evidence does **not** certify a different revision. The final decision remains NO-GO until the complete gate is repeated and retained for one clean, immutable candidate.

- **VERIFIED DURING DEVELOPMENT.** Generation, validation, headless suites, static security analysis, dependency audit, live MariaDB regression tests, and earlier FXServer/client stages have passed.
- **IMPLEMENTED; LIVE RETEST PENDING.** The runtime database-health circuit moves Core to recoverable `DEGRADED` with `operational = true` and player admission closed after a returned probe failure, adapter exception, or the fixed five-second fail-closed watchdog. It suspends ordinary database-backed workers while retaining bounded connection-heartbeat cleanup, and requires two successful probes plus reconciliation before work and admission resume. This behavior has focused headless and Cfx-like coroutine coverage but is not a live PASS until the exact candidate completes the outage/recovery gate.
- **IN PROGRESS.** Fresh install, upgrade, backup/restore, restart/crash recovery, database outage/recovery, bounded load/soak, security review, documentation audit, and the complete real-client sequence must agree on the same exact revision.
- **NOT CERTIFIED.** MySQL and multi-instance operation, including `kick_old`, are outside the first candidate profile.
- **OUT OF SCOPE.** Every runtime resource, library, bridge, and example downstream of `synex_core` is an experimental rework snapshot or scaffold and is not part of Core certification.

[Release gate](./docs/release-readiness.md) &middot; [Current test coverage](./docs/testing.md) &middot; [Known limitations](./docs/known-limitations.md)

### First acceptance target profile

| Boundary | Candidate value |
| --- | --- |
| Product | `synex_core` only |
| Host | Windows |
| Runtime | FXServer build `35245` |
| Database adapter | `oxmysql 2.14.1` |
| Database | MariaDB `11.8.8`, UTC session time |
| Topology | One active Core instance |
| Production policy | `synex_environment "production"`, `synex_strict "1"`, `synex_duplicate_policy "deny_new"` |

These are candidate boundaries, not a PASS statement. A different platform or dependency version requires its own acceptance evidence.

## Why Synex

- **Caller-bound APIs.** Core exports capture the immediate resource principal and return epoch-bound facades that expire on restart.
- **Contract-first boundaries.** Versioned JSON contracts generate runtime descriptors, Lua metadata, TypeScript types, and API reference material.
- **Server authority.** Network entry points are explicit and bounded; client and NUI input remains untrusted.
- **Owned persistence.** Migrations and tables belong to one resource, with checksums, database-time leases, and forward-only history.
- **Lifecycle cleanup.** RPC handlers, services, hooks, subscriptions, states, schedules, and pending ownership are tracked by resource epoch.
- **Evidence over claims.** Headless, static, compatibility, and live MariaDB tests are present; their platform limits are documented.

## Core beta scope

| Area | Repository path | Current role |
| --- | --- | --- |
| Runtime candidate | [`synex_core`](./core/synex_core/) | Boot, connection/session/character lifecycle, contracts, RPC, events, hooks, services, capabilities, persistent access policy, state, reliability, audit, metrics, health, and owned migrations |
| Contract pipeline | [`packages/contracts`](./packages/contracts/) | Canonical inputs and deterministic generated runtime/reference artifacts used to validate Core development |
| SDK and tooling | [`packages`](./packages/) / [`tools`](./tools/) | Generated clients/types, validation, migration, security, certification, and test tooling; not separately certified server features |

The current certification target is deliberately narrow: **only `core/synex_core` may become Production-Beta-ready.** Its public API remains experimental even if the runtime acceptance target passes the beta gate.

### Downstream rework boundary

`synex_groups`, `synex_accounts`, `synex_entities`, `synex_control`, every other directory under `resources/`, all libraries and bridges under `libraries/` (including `synex_bridge`), and the runnable examples are **experimental rework snapshots or scaffolds**. They are unsupported for the Core beta and must not be started, bundled, or advertised as certified components. OneSync-dependent downstream behavior is likewise outside this Core-only profile.

This also applies to the reserved gameplay names `synex_character`, `synex_identity`, `synex_inventory`, `synex_banking`, `synex_phone`, `synex_radio`, `synex_jobs`, `synex_shops`, `synex_vehicles`, `synex_garages`, and `synex_ui`. Directory presence does not imply a finished feature. Character and session behavior that exists in the current candidate belongs to `synex_core`.

## Architecture

```mermaid
flowchart TB
    CFX["Cfx.re / FXServer 35245"] --> CORE["synex_core"]
    DB[("MariaDB 11.8.8")] --> OX["oxmysql 2.14.1"]
    OX --> CORE

    CONTRACTS["Versioned JSON contracts"] --> GENERATED["Generated runtime + Lua + TypeScript"]
    GENERATED --> CORE
    CORE --> API["Caller-bound Core API"]
    API -. "experimental boundary" .-> REWORK["Downstream rework snapshots — not certified"]
```

Solid arrows show the first Core candidate's runtime or generated-input flow. The dashed edge marks an API boundary that exists for development but does not certify any downstream consumer.

The core separates users, sessions, characters, ephemeral player sources, and source generations. Resource manifests declare API ranges, services, contracts, capabilities, migrations, and data ownership. A capability declaration records intent; operator policy must grant it, and deny rules take precedence.

[Read the architecture documentation](./docs/architecture/README.md)

## Getting started

The first candidate profile requires Windows, FXServer build `35245`, `oxmysql 2.14.1`, MariaDB `11.8.8`, one stable unique `synex_instance_id`, strict production mode, and `deny_new`. Node.js `>=22.12.0` with npm `>=10.0.0` is required for repository generation and tests, not for the Lua runtime.

```bash
git clone https://github.com/PixelGG/Synex_Framework.git
cd Synex_Framework
npm ci
npm run check
npm test
npm run security
npm run certify
```

These checks are required development gates; they are not by themselves Production-Beta evidence. This repository remains a development monorepo rather than a packaged server release. Deploy only `oxmysql` and `synex_core` for the initial candidate, keep credentials in an operator-owned local file, and follow the reviewed configuration and acceptance instructions:

[Getting started](./docs/getting-started.md) &middot; [Core server configuration](./examples/server.cfg.example) &middot; [Release readiness](./docs/release-readiness.md)

## Development model

```lua
local api, apiError = exports.synex_core:GetAPI('^1.0.0')
if not api then error(apiError.message) end

local status, statusError = api.Runtime.status()
if not status then error(statusError.message) end

print(('Synex Core state: %s'):format(status.state))
```

The calling server resource must declare `synex.runtime.read`, and operator policy must grant it. Calls return `value, nil` or `nil, error`; capability and caller-epoch validation remains active. This example uses only the Core facade and does not depend on a downstream module.

[Public API](./docs/api/README.md) &middot; [Create a resource](./docs/development/creating-resources.md) &middot; [Generated contracts](./packages/contracts/generated/docs/contracts.md)

## Technology

- Lua for the FiveM Core runtime
- SQL with MariaDB `11.8.8` through `oxmysql 2.14.1` in the first acceptance target profile
- TypeScript and Node.js for contracts, SDKs, CLI, analyzers, and tests
- JSON Schema for contract, resource-manifest, state, and configuration validation
- GitHub Actions with an isolated MariaDB integration job

MySQL remains a code-compatibility target, not a certified Production-Beta database. Repository snapshots outside the Core scope may use additional technologies, but they are not part of this runtime claim. There is no external telemetry service, hosted control API, or automatic remote updater in the current repository.

## Documentation

- [Documentation index](./docs/README.md)
- [Core Production-Beta release gate](./docs/release-readiness.md)
- [Known limitations](./docs/known-limitations.md)
- [Backup and restore](./docs/backup-and-restore.md)
- [Runtime model](./docs/architecture/runtime.md)
- [Security model](./docs/architecture/security.md)
- [Security policy](./SECURITY.md)
- [Database and migrations](./docs/reference/database.md)
- [Operations](./docs/operations.md)
- [Testing and CI](./docs/testing.md)

## Community

Development discussion, implementation feedback, and framework updates are available in the official Synex community.

<p align="center">
  <a href="https://discord.gg/heJU5t2Hfa">
    <img src="./.github/assets/readme/discord-community.svg" width="720" alt="Join the official Synex Discord">
  </a>
</p>

## License

Copyright &copy; 2026 PixelGG. Synex is licensed under the [GNU Affero General Public License v3.0 only](./LICENSE).

## Repository structure

```text
Synex_Framework/
├── core/synex_core/           # only current Production-Beta runtime candidate
├── resources/                 # unsupported downstream rework snapshots and scaffolds
├── libraries/                 # unsupported libraries and bridge rework snapshots
├── packages/                  # contracts and generated development SDKs
├── schemas/                   # JSON Schemas
├── tools/                     # CLI and migration planner
├── tests/                     # headless, static, compatibility, docs, and database tests
├── examples/                  # configuration templates and unsupported development examples
└── docs/                      # architecture, operations, references, and translations
```

---

<p align="center">
  <sub>Synex Framework &middot; Explicit contracts. Owned state. Honest boundaries.</sub>
</p>
