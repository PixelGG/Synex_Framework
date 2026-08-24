# Core Production-Beta release readiness

> [!IMPORTANT]
> **Current decision: IN PROGRESS / NO-GO.** Predecessor `888a7326` failed its planned minimum 120-minute soak at the first hourly outbox-retention execution, before the minimum duration completed. The current runtime tree contains the fix introduced by `e0cbf45`, but a clean immutable post-documentation revision must repeat every applicable gate below. A Production-Beta claim is valid only when all mandatory evidence belongs to that same selected revision.

## Current candidate evidence

| Stage | Status | Boundary |
| --- | --- | --- |
| Repository/headless validation | **PASS ON CURRENT RUNTIME TREE** | `check`, 232 Lua tests, 413 repository tests with 19 gated live-database skips, static security, and diff checks pass for the runtime tree introduced by `e0cbf45` |
| Exact automated Core evidence gate | **PENDING** | Bind a regenerated clean-checkout artifact to the selected post-documentation revision |
| Fresh boot and public API/probe | **PENDING** | Predecessor evidence does not certify the selected revision |
| Probe restart protocol | **PENDING** | Repeat both phases and confirm run-scoped KVP cleanup |
| Restart and crash recovery | **PENDING** | Repeat prepared restart, unprepared recovery, full-process crash, and next-boot reconciliation |
| Database outage | **PENDING** | Repeat fail-closed fencing and the documented full-process recovery after MariaDB restoration |
| Backup and restore drill | **PENDING; RELEASE REVIEW PENDING** | Repeat encrypted recovery and parity; operator approval of RPO/RTO is still open |
| Rehearsal 25-to-26 upgrade | **PENDING** | Repeat the retained baseline rehearsal on the selected revision |
| Manual Core security/operations review | **PENDING** | Revalidate the exact final Core tree and repository metadata |
| Minimum 120-minute server-only soak | **PENDING** | Start a new run; the predecessor soak failed and cannot transfer |
| Real FiveM client join/disconnect/reconnect | **PENDING** | Must run against the selected revision; predecessor client evidence does not transfer |

The checklist below remains the reusable release gate. Its checkboxes are not a second status ledger; the table above records the current candidate. The automated artifact keeps manual-stage fields at `NOT_RUN` by design even when separately retained runtime evidence records a PASS.

## Supported target

The initial Production-Beta target is a reliable, operator-tested beta of `synex_core`, not a stable framework-wide release.

| Area | Initial supported profile |
| --- | --- |
| Product scope | `synex_core` only |
| Host | Windows |
| FXServer | Artifact build `35245` |
| Database | MariaDB `11.8.8`, InnoDB, UTC session time |
| Adapter | `oxmysql 2.14.1` |
| Runtime topology | One active `synex_core` instance with `synex_duplicate_policy "deny_new"` |
| Configuration | `synex_environment "production"`, `synex_strict "1"`, stable unique instance ID, `mysql_transaction_isolation_level 2` |
| Deployment | Clean, immutable checkout of the accepted commit; operator-owned secrets outside the repository |

MySQL `8.4` remains a code and migration compatibility target, not a certified Production-Beta database, until the complete gate is repeated against a real MySQL service. Multi-instance operation and `kick_old` are not part of the initial supported profile until the optional multi-instance gate passes. `synex_groups`, `synex_accounts`, `synex_entities`, `synex_control`, all bridges, examples, and planned modules are experimental rework snapshots or scaffolds and must not be advertised or started as supported parts of the Core beta.

Production-ready beta means the supported profile has reproducible release evidence, bounded known limitations, a recovery procedure, and no open release blocker. It does not mean API stability, zero defects, high-availability certification, a support SLA, or a production-stable `1.0` release.

## Decision rules

- Evidence must name the full commit SHA, dirty/clean state, UTC date, operating system, FXServer artifact, oxmysql version, database version, and tested configuration profile.
- Runtime and client evidence from a different commit does not certify the candidate. Repeat affected stages after any runtime, migration, generated-contract, dependency, or configuration change.
- A documentation-only correction may reuse runtime evidence only when the release record proves the runtime bytes and generated artifacts are unchanged; all repository and documentation gates still run again.
- `PASS` requires retained, privacy-safe evidence. `BLOCKED`, `NOT TESTED`, unexplained warnings, flaky retries, skipped mandatory checks, or manual database repair are not passes.
- A known limitation can be accepted only when it is outside the declared supported profile, documented before release, and protected by a fail-closed configuration or operating rule.
- Never weaken a test, capability, migration invariant, or runtime check merely to turn the gate green.

## Gate 1 — Candidate identity and repository integrity

- [ ] Record the exact full commit SHA and confirm `git status --short` is empty.
- [ ] Confirm package, manifest, changelog, support, compatibility, and maturity statements agree.
- [ ] Review the complete candidate diff and generated artifacts.
- [ ] Confirm no secrets, private paths, local endpoints, logs, dumps, caches, temporary probes, or unrelated files are tracked.
- [ ] Confirm every runnable resource manifest references only existing files. For the initial beta deployment, deploy only `synex_core` and its reviewed `oxmysql` dependency.

## Gate 2 — Reproducible automated checks

Run from a clean checkout with the repository-required Node.js/npm versions:

```bash
npm ci
npm run check
npm test
npm run security
npm run certify
npm audit --audit-level=high
git diff --check
```

- [ ] Every command exits successfully on the candidate revision.
- [ ] The report records exact pass/fail/skip counts and explains every skip.
- [ ] Generated-file checks leave the checkout clean.
- [ ] No warning is silently treated as proof of compatibility or security.

## Gate 3 — MariaDB fresh install and upgrade

Use disposable schemas only. The database test guard and naming rules in [Testing](testing.md) remain mandatory.

- [ ] Run `npm run test:database` against a fresh MariaDB `11.8.8` schema with the explicit live/destructive-test gate enabled; all live cases pass.
- [ ] Boot an isolated FXServer against a second empty schema. Core reaches `READY` once, records exactly 26 applied Core migrations, and leaves no `applying`, `failed`, or `indeterminate` attempt/fence.
- [ ] Restore the database from the most recent publicly deployed pre-candidate Core revision, then start only the candidate Core. The supported forward upgrade completes without editing prior migration markers or manual schema repair.
- [ ] Run the same metadata, checksum, constraint, UTC, and `synex doctor` checks on both the fresh and upgraded schemas.
- [ ] Preserve only sanitized counts, versions, checksums, and stable error codes as evidence; remove disposable credentials.

For the first public beta, the accepted pre-candidate revision becomes the upgrade baseline. If no earlier deployment exists, record that fact and rehearse the full migration chain plus backup/restore; do not invent an older supported version.

## Gate 4 — Backup and restore

- [ ] Complete the [MariaDB backup and restore drill](backup-and-restore.md) against the candidate schema.
- [ ] Verify the dump hash, restore into a new isolated schema, migration counts/states, Core boot to `READY`, and `synex doctor`.
- [ ] Record operator-approved recovery-point and recovery-time objectives; Synex does not choose them automatically.
- [ ] Prove that the backup can be decrypted/read by the recovery operator without putting credentials or plaintext dumps in Git.

Predecessor `888a7326` completed the technical drill: the encrypted archive decrypted to the exact original SHA-256, the new isolated schema matched all 36 restored tables and their recorded row counts/metadata, and that predecessor reached `READY` with Doctor `PASS`. The measured 813 ms SQL import is only one component of recovery and is not an RTO. This historical evidence does not satisfy Gate 4 for the next selected revision; operator-approved RPO/RTO objectives also remain open.

Migrations are forward-only. Backout never means running an older Core against the candidate schema or reversing migration `026` in place. Preserve the pre-upgrade schema or restore its verified backup into a separate database, stop the candidate, validate the older Core against only that compatible schema, and switch the operator-owned connection during a controlled maintenance window.

## Gate 5 — Isolated FXServer and public Core API

- [ ] Prepare a clean disposable live-test bundle as documented in [Testing](testing.md); never grant probe capabilities in the production policy.
- [ ] Start only the reviewed FXServer base resources, `oxmysql`, `synex_core`, and the isolated server-only probe.
- [ ] Core reaches exactly `READY`; `synex overview`, `synex status`, `synex migrations`, `synex resources`, and `synex doctor` agree.
- [ ] GetAPI, Cfx callables, contracts/RPC, services, events, hooks, scheduler, character lifecycle registration, connection gates, idempotency, and Saga registration/execution pass.
- [ ] Complete the two-phase probe restart protocol. First PASS reports `restartRequired = true` and deliberately retains the run-scoped KVP; restart only the probe in the same Core process, require an increased owner epoch, then require `restartRequired = false` and `kvpCleaned = true`. Every FAIL path must clean the exact run-scoped key.
- [ ] Stop the probe and confirm owner registrations, timers, and pending callbacks are cleaned.

## Gate 6 — Real-client connection lifecycle

- [ ] A real FiveM client completes join, disconnect, and reconnect on the exact candidate.
- [ ] Ten clean join/disconnect cycles and five rapid retry attempts complete without duplicate active sessions, stale leases, `LEASE_BUSY`, generic `Unknown error`, or leaked pending admission.
- [ ] One aborted post-deferral connection returns pending/reservation counts to zero within the documented bound and a later join succeeds.
- [ ] Session/source generation changes across reconnects and every prior local session is closed.
- [ ] Connection-stage evidence contains only correlation ID, stage, duration, and stable code; no raw identifiers, names, endpoints, or database errors.

## Gate 7 — Restart, crash, and recovery

- [ ] `synex prepare-restart` passes while idle and while one player is active; only its returned restart command is used.
- [ ] Prepared restart passes with one pending connection held by disposable database work. Preparation waits for tracked database activity to drain before owner teardown.
- [ ] An unprepared full FXServer-process termination is recovered on the next boot: old local sessions/control authority are terminal, admission remains closed through recovery, and reconnect receives fresh authority.
- [ ] With Core still running, stop only the disposable MariaDB process. A returned failure or its five-second watchdog makes Core `DEGRADED` with `operational = true`, closes player admission, records only the redacted `database-runtime` reason, suspends ordinary database-backed workers, and preserves bounded fail-closed connection cleanup. A stalled oxmysql await is never reported as cancelled and must not cause replacement probes or abandoned coroutines to accumulate.
- [ ] After MariaDB returns, recover through a full FXServer-process restart. The fresh process completes dependency and instance reconciliation, reaches Core `READY`, reopens admission, persists instance `ready`, restores healthy workers, and leaves no leaked session/admission authority. Same-process recovery after an unsettled driver promise is outside the initial supported profile.
- [ ] The documented unsupported path—an isolated raw Core restart during blocked interactive oxmysql work—is not presented as a graceful restart. Recovery uses a full FXServer-process restart.
- [ ] Repeated restart stages leave no stale facade, owner registration, timer, pending request, session, or local session/admission lease.

## Gate 8 — Capacity, load, and soak

Define the intended beta server capacity before running this gate; the evidence must record the workload rather than use an unlabelled synthetic score.

Predecessor `888a7326` failed this gate at the first hourly outbox-retention execution, before the planned minimum duration completed, when the worker reported `INVALID_OUTBOX_RETENTION`. The current runtime tree contains the fix introduced by `e0cbf45`; every item remains open until a new exact-revision run and final invariant review pass. The overall decision remains NO-GO.

- [ ] Exercise configured connection, RPC, idempotency, worker-queue, session-control, and cluster-lease limits at the boundary and one request beyond it; overflow fails closed with stable codes.
- [ ] Run a minimum two-hour isolated Core/MariaDB soak with repeated API/probe work and scheduled workers.
- [ ] Sample memory, pending work, worker failures, database latency, sessions, controls, and leases at least once per minute.
- [ ] No queue or retained authority grows without a documented bounded reason; terminal work returns to its expected baseline.
- [ ] No worker enters a consecutive-failure loop, no database invariant drifts, and `synex doctor` remains healthy at the end.
- [ ] Record real-client and synthetic/database workloads separately. Synthetic probes are not evidence of real player concurrency.

## Gate 9 — Security and operations review

- [ ] Review every client-callable event, NUI callback, export, contract, service, and console mutation for caller binding, authorization, bounds, rate limits, stale authority, and server-owned values.
- [ ] Review SQL parameterization, code-owned dynamic identifiers, migration privileges, database least privilege, and backup access.
- [ ] Review readable source and dependencies for obfuscation, remote execution, credential access, unknown network calls, cross-resource modification, and unreferenced executable files.
- [ ] Verify cleanup for players, resources, deferrals, focus, state, timers, handlers, workers, and database activity.
- [ ] Triage dependency and scanner findings manually; a zero-finding scanner is not by itself a security certification.
- [ ] Confirm the private reporting path in the repository [security policy](../SECURITY.md) is available.

## Gate 10 — Documentation and release review

- [ ] Audit every tracked Markdown document and example configuration against the candidate code.
- [ ] Validate relative links, anchors, Mermaid blocks, commands, file paths, migration counts, dependency versions, module names, and maturity statements.
- [ ] Keep implemented Core behavior, unsupported non-Core snapshots, compatibility targets, and planned modules visibly separate.
- [ ] Ensure [known limitations](known-limitations.md), [backup and restore](backup-and-restore.md), [operations](operations.md), [testing](testing.md), [configuration](configuration.md), [security](../SECURITY.md), and the [changelog](../CHANGELOG.md) agree.
- [ ] Run the documentation test suite after the final edit and confirm the checkout remains free of generated drift.

## Optional gate — Multi-instance profile

This gate is mandatory before advertising multi-instance or `kick_old` support, but it is not a substitute for the single-instance gates above.

- [ ] Start two isolated Core/FXServer instances with distinct stable instance IDs against one test database.
- [ ] Exercise `deny_new`, `allow`, and `kick_old` separately with their documented session/lease model.
- [ ] During an in-flight `kick_old` request, restart the requesting Core. The target does not consume authority from a stopping, stopped, stale, or previous-boot requester.
- [ ] Stop each instance independently and verify that foreign authority is preserved while local authority is recovered or retired.

Until every item passes, the supported topology remains one Core instance with `deny_new`.

## Release evidence record

Keep the final record in the release or pull-request description, not in a secret-bearing log committed to the repository:

```text
Decision: PASS | FAIL | BLOCKED
Commit: <full SHA>
Dirty state: clean | dirty
UTC date: <timestamp>
Host OS: <name and version>
FXServer artifact: <exact build>
oxmysql: <exact version>
Database: MariaDB 11.8.8
Profile: synex_core / single instance / deny_new
Automated gates: <counts and result>
Fresh install: <result>
Upgrade: <source revision and result>
Backup/restore: <backup hash and result>
Client lifecycle: <result>
Restart/recovery: <result>
Database outage/recovery: <result>
Load/soak: <workload, duration, result>
Security review: <result>
Documentation audit: <result>
Known limitations accepted: <list>
```

The project owner makes the final release decision. A PASS permits the wording **Production-ready beta for the documented Core profile**; it does not permit a framework-wide or production-stable claim.
