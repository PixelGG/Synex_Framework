# Changelog

All notable project changes are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project intends to use semantic versioning once a public release line is established.

## [Unreleased]

### Release status

- The immutable Core tree `9f0960f1e27fe43195ae4602cb2ef447cbc0509b` has passed the complete frozen Production-Beta gate: repository, live-database, fresh-boot, capacity, restart, crash-recovery, stale-facade, database-outage/recovery, automated closure, documentation/final-diff/secret review, publication, and the real-client join/disconnect/reconnect smoke test.
- The aggregate decision for the documented Core-only profile is **PASS — Production Beta**. This is not a Stable/1.0 or framework-wide production-support claim; the canonical evidence and exact runtime profile remain defined in [release readiness](docs/release-readiness.md).
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
- Core documentation keeps the five-item Beta closure line separate from post-Beta soak, evidence-runner, historical-upgrade, extensive restore, and additional non-critical ABI work, and keeps every non-Core rework snapshot outside the beta claim.

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
