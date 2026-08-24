# Changelog

All notable project changes are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project intends to use semantic versioning once a public release line is established.

## [Unreleased]

### Release status

- Predecessor `888a7326` passed the automated gate and the completed server-side stages, but its planned minimum 120-minute soak failed at the first hourly outbox-retention execution, before the minimum duration completed, and therefore ended **FAIL / NO-GO**.
- The current runtime tree contains the trusted Cfx JSON-container fix introduced by `e0cbf45` and exact queue-capacity coverage. Repository validation passes; a clean post-documentation revision must still complete the exact server gate, a fresh 120-minute soak, and FiveM client join/disconnect/reconnect. No production-stable beta is claimed until the [release-readiness document](docs/release-readiness.md) is complete for one immutable revision.
- The target applies to `synex_core` only. All non-Core resources and libraries are experimental rework snapshots and are not supported components of the Core beta.

### Added

- A fail-closed Core lifecycle with resource discovery, generated contracts, capability policy, runtime diagnostics, identity/session handling, reliability workers, state ownership, and forward-only database migrations.
- Repository validation, headless Lua tests, live MariaDB tests, static security scanning, certification tooling, and an isolated FXServer acceptance-bundle workflow.
- Restricted operator commands for health, migrations, resources, sessions, permissions, access records, traces, and prepared Core restarts.
- Canonical release-readiness, known-limitations, backup/restore, and vulnerability-reporting guidance.

### Changed

- Planned Core restarts use a fail-closed preparation and database-drain sequence before runtime ownership is quiesced.
- Connection, session-control, migration, idempotency, outbox, Saga, and lease paths use bounded work and durable authority checks.
- A runtime database-health circuit closes player admission on a returned UTC-probe failure, an adapter exception, or a fixed five-second fail-closed watchdog; it keeps bounded diagnostics and connection-heartbeat cleanup operational and suspends the other database-backed scheduled work. A completed failure can recover after two successful probes plus reconciliation. A watchdog cannot cancel an oxmysql `Await`; a lost oxmysql `2.14.1` callback stays fail-closed until MariaDB is restored and the complete FXServer process is restarted once.
- Core documentation records the predecessor evidence and failed soak separately from the current candidate's pending server/client gates, and keeps experimental APIs, compatibility targets, and every non-Core rework snapshot outside the beta claim.

### Fixed

- Cfx callable/funcref handling in the connection pipeline and cross-resource API.
- MariaDB migration metadata normalization and vendor-adaptive index validation.
- Cfx JSON container handling during persisted Saga execution.
- Boot diagnostics, restart retry terminalization, database draining, and next-boot local connection-authority recovery.
- False-ready behavior after a completed runtime database-probe failure; Core now reports recoverable `DEGRADED` with `operational = true` and player admission closed.

### Security

- Core capability checks remain caller-bound and fail closed; Core client and cross-resource transport inputs are bounded and validated at their server boundary. Non-Core NUI/resources remain outside the supported beta scope.
- Runtime and repository security checks redact sensitive values and reject secret-bearing or unsafe live-test bundles.

No production-stable version has been released yet. An entry will move out of **Unreleased** only after the exact release revision passes the canonical gate and the project owner explicitly publishes it.
