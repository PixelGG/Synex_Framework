# Known limitations

These boundaries are part of the current `0.1.x` release decision. They must not be hidden by a broader maturity label.

## Release and support boundary

- No stable Synex `1.0` release exists yet. The `synex_core` Production-Beta gate is in its [frozen completion phase](release-readiness.md). Recovery, automation, documentation/final-diff/secret review, and publication to `main` have passed. Only the client join/disconnect/reconnect smoke remains open, so the release decision is **NO-GO**.
- The beta target covers `synex_core` only. `synex_groups`, `synex_accounts`, `synex_entities`, `synex_control`, compatibility bridges, examples, and every other downstream resource/library are experimental rework snapshots or scaffolds. They are unsupported for the Core beta and must not be started or advertised as production-ready components.
- Public contracts are marked `experimental`; breaking API, schema, and migration changes remain possible before a stable release.
- There is no packaged installer, automatic updater, supported rollback migration, in-place downgrade, or zero-downtime upgrade path. Deployments use reviewed resource copies and forward-only migrations. Backout requires a separately preserved or restored schema compatible with the older Core; older code must never run against a schema already advanced to migration `026`.

## Candidate deployment profile

- MariaDB `11.8.8` is the Production-Beta database target. MySQL `8.4` is a documented compatibility target but remains outside the candidate until the complete live gate runs against MySQL.
- The initial target topology is one active Core instance using `deny_new`. Multi-instance operation, cross-instance replacement, and `kick_old` remain outside the beta profile until the dedicated two-instance gate passes.
- Exact FXServer artifact, oxmysql version, host operating system, and configuration must be recorded in release evidence. Passing headless tests on another environment does not accept an operator deployment.
- Automated repository tests do not replace a real FiveM client. The frozen Beta scope requires one exact-candidate join, disconnect, and reconnect smoke test. Aborted-deferral, repeated-retry, and active-player restart scenarios remain later hardening work unless a release-blocking defect appears.
- A long server soak, permanent evidence runner, historical supported-version upgrade drill, extensive backup/restore certification, and additional non-critical ABI coverage are post-Beta promotion work. Their deferral does not broaden the supported Beta profile or remove normal operator backup responsibilities.

## Runtime and operations

- Planned isolated Core restarts require `synex prepare-restart`. A raw Core restart cannot cancel an interactive oxmysql transaction whose callback is already blocked; use a complete FXServer-process restart for that incident path.
- `database.queryWarnMs` is a slow-operation warning threshold, not a cancellation deadline. Core does not advertise a hard per-query cancellation timeout; operators must monitor database latency and investigate blocked work.
- A returned runtime database-probe failure or adapter exception closes admission and suspends ordinary database-backed recurring workers. Because that failure has completed, MariaDB restoration can be reconciled automatically after two consecutive successful probes plus dependency and instance-status reconciliation. The fixed five-second watchdog closes the same fence but cannot cancel an oxmysql `Await`.
- oxmysql `2.14.1` can lose the Lua callback when pool `getConnection()` rejects. That timed-out probe never settles, so Core deliberately remains fail-closed and does not launch superseding probes. Restore and verify MariaDB, then perform one controlled restart of the complete FXServer process. A raw Core restart, an oxmysql-only restart, or any Core/FXServer restart loop is unsupported. The connection heartbeat remains active for bounded pending/session authority cleanup, so existing clients are not guaranteed to remain connected during an outage; unrenewable authority fails closed.
- Retention defaults to `retain_forever`. Archive mode mirrors data but does not purge source audit or financial history, so it can increase storage use. Synex does not define an operator's legal retention policy.
- Backup encryption, off-host copies, recovery-point objectives, recovery-time objectives, database privileges, firewalling, secrets, and disaster-recovery ownership remain operator responsibilities.
- The repository provides no high-availability, region-failover, orchestration, hosted control plane, support SLA, or uptime guarantee.

## Security and privacy

- Static security scans and repository certification are guardrails, not proof that a deployment is secure. Host, dependency, ACE, capability, database, and network policy require manual review.
- Logs and acceptance evidence must remain redacted. Never commit Cfx keys, database credentials, raw player identifiers, private endpoints, local test-server state, or database dumps.
- The committed archive/retention behavior is not a legal compliance program. Operators must establish lawful access, retention, erasure, disclosure, and incident-response processes for their jurisdiction.

Use the [release-readiness gate](release-readiness.md) as the canonical decision source and the [backup/restore runbook](backup-and-restore.md) before any candidate deployment.

## Current candidate evidence

Current-tree repository, live-database, fresh-boot, public-API, capacity, restart, crash-recovery, stale-facade, database-outage/recovery, final automated, documentation/final-diff/secret-review, and publication-to-`main` evidence has passed. Only one real-client join/disconnect/reconnect smoke test remains open. See [Release readiness](release-readiness.md) for the canonical status.
