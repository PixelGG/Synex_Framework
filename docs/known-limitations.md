# Known limitations

These boundaries are part of the current `0.1.x` release decision. They must not be hidden by a broader maturity label.

## Release and support boundary

- No production-stable Synex release exists yet. The `synex_core` Production-Beta gate is [in progress](release-readiness.md).
- The beta target covers `synex_core` only. `synex_groups`, `synex_accounts`, `synex_entities`, `synex_control`, compatibility bridges, examples, and every other downstream resource/library are experimental rework snapshots or scaffolds. They are unsupported for the Core beta and must not be started or advertised as production-ready components.
- Public contracts are marked `experimental`; breaking API, schema, and migration changes remain possible before a stable release.
- There is no packaged installer, automatic updater, supported rollback migration, or zero-downtime upgrade path. Deployments use reviewed resource copies and forward-only migrations.

## Candidate deployment profile

- MariaDB `11.8.8` is the Production-Beta database target. MySQL `8.4` is a documented compatibility target but remains outside the candidate until the complete live gate runs against MySQL.
- The initial target topology is one active Core instance using `deny_new`. Multi-instance operation, cross-instance replacement, and `kick_old` remain outside the beta profile until the dedicated two-instance gate passes.
- Exact FXServer artifact, oxmysql version, host operating system, and configuration must be recorded in release evidence. Passing headless tests on another environment does not accept an operator deployment.
- Automated repository tests do not replace a real FiveM client. Join, disconnect, reconnect, aborted-deferral, and restart behavior require manual client evidence on the exact candidate.

## Runtime and operations

- Planned isolated Core restarts require `synex prepare-restart`. A raw Core restart cannot cancel an interactive oxmysql transaction whose callback is already blocked; use a complete FXServer-process restart for that incident path.
- `database.queryWarnMs` is a slow-operation warning threshold, not a cancellation deadline. Core does not advertise a hard per-query cancellation timeout; operators must monitor database latency and investigate blocked work.
- A returned runtime database-probe failure, adapter exception, or fixed five-second watchdog closes admission and suspends ordinary database-backed recurring workers. The watchdog does not cancel the oxmysql promise: if that probe never settles, Core remains fenced and cannot automatically begin its two-probe recovery, so the documented full FXServer-process incident recovery is required. The connection heartbeat is deliberately exempt and remains active for pending/session authority cleanup, so existing clients are not guaranteed to remain connected during a database outage; unrenewable authority fails closed.
- Retention defaults to `retain_forever`. Archive mode mirrors data but does not purge source audit or financial history, so it can increase storage use. Synex does not define an operator's legal retention policy.
- Backup encryption, off-host copies, recovery-point objectives, recovery-time objectives, database privileges, firewalling, secrets, and disaster-recovery ownership remain operator responsibilities.
- The repository provides no high-availability, region-failover, orchestration, hosted control plane, support SLA, or uptime guarantee.

## Security and privacy

- Static security scans and repository certification are guardrails, not proof that a deployment is secure. Host, dependency, ACE, capability, database, and network policy require manual review.
- Logs and acceptance evidence must remain redacted. Never commit Cfx keys, database credentials, raw player identifiers, private endpoints, local test-server state, or database dumps.
- The committed archive/retention behavior is not a legal compliance program. Operators must establish lawful access, retention, erasure, disclosure, and incident-response processes for their jurisdiction.

Use the [release-readiness gate](release-readiness.md) as the canonical decision source and the [backup/restore runbook](backup-and-restore.md) before any candidate deployment.
