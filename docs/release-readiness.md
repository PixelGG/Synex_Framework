# Frozen Core Production-Beta release readiness

> [!IMPORTANT]
> **Frozen decision: PASS / Production Beta.** On 2026-08-25, the documented Core-only profile completed its repository, live-database, fresh-boot, public-API, capacity, restart, crash-recovery, stale-facade, database-outage/recovery, automated, real-client, and review gates. This is a production-oriented beta of `synex_core` for the exact immutable profile below; it is not a stable `1.0` or framework-wide release.

The runtime acceptance was performed on commit `7ad4b72ee9bcd0a2a0481cfacfe5f807eb1b3ec5` with tracked Core tree `9f0960f1e27fe43195ae4602cb2ef447cbc0509b`. Documentation-only synchronization may reuse that runtime evidence only while the tracked Core tree remains byte-identical. The current workspace adds Core domain-persistence/deletion primitives and migration `027_domain_primitives`; those later bytes are outside this decision and require fresh acceptance.

## Frozen Beta completion scope

The following frozen Production-Beta scope is complete. New non-critical hardening ideas do not retroactively extend it.

| Stage | Current status | Acceptance boundary |
| --- | --- | --- |
| Database outage and recovery | **PASS** | `DEGRADED` with admission closed in 6.73 s; full FXServer stop; MariaDB plus fresh FXServer `READY` in 10.86 s; 26/26 migrations, attempts, and fences applied; zero nonterminal migration or open session/authority/Saga/outbox/idempotency work; idempotent probe replay |
| Final automated run | **PASS** | `npm ci`, check, test, security, certification, and dependency audit exited successfully; 416 tests passed, 0 failed, 19 expected live-DB cases were gated, security reported 0 findings, and `npm audit` reported 0 vulnerabilities |
| Documentation, final diff, and secret review | **PASS** | Tracked documentation, links, paths, commands, maturity claims, dependency audit, secrets, and final candidate integrity/diff were reviewed without an unresolved blocker |
| Real-client smoke test | **PASS** | A real FiveM client completed join, clean disconnect, and reconnect; both connections traversed all nine ordered stages, Doctor remained `PASS`, and final cleanup left no open session or connection authority |
| Commit and publication | **PASS** | The reviewed candidate is committed and published to `main` without secrets, private test assets, or unrelated files |

Already completed runtime evidence remains valid across documentation-only changes when the release record proves that the tracked Core bytes and generated runtime artifacts did not change. Any later runtime, migration, dependency, generated-contract, or production-configuration change invalidates the affected runtime evidence and requires that stage to be repeated.

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

MySQL `8.4` remains a code and migration compatibility target, not a certified Production-Beta database. Multi-instance operation and `kick_old`, `replace_old`, or `allow` duplicate policies are outside this profile. `synex_groups` is Experimental Alpha with separate working-tree evidence and open client/exact-candidate/owner gates. `synex_accounts` is a server-only Experimental Alpha Financial Engine whose automated implementation is largely complete; real MariaDB, FXServer, restart/crash-recovery, restored-upgrade, exact-candidate review, and owner maturity/support/publication remain open. `synex_entities` is a separate server-only Development / Experimental Alpha Entity Authority Engine with implementation and repository regression coverage but open fresh MariaDB, live FXServer/OneSync, restart/recovery, cluster, real-client/Control and exact-candidate gates. Its implemented `synex_control` projection is read-only and experimental. `synex_bridge` is an implemented but unaccepted Experimental Alpha Compatibility Platform; exact database, FXServer, facade/restart, mixed-provider and real-client gates remain open. SDK integrations, examples, and later resources remain experimental rework snapshots or scaffolds. None may be advertised as a supported part of the Core beta.

Accounts has no client contract or NUI, so its own acceptance does not require a direct FiveM client smoke. Its later release decision must instead exercise the exact 17-migration schema, 59 server-local contract/service operations, financial concurrency and replay, hold/outbox/retention/reconciliation workers, prepared and unplanned restart recovery, restored-copy upgrade/rollback, and final diff/secret review. Any future `synex_banking` or gameplay client surface needs a separate hostile-client and UI gate.

Entities also has no client-callable contract or NUI, but its release decision does require a real FiveM client because player routing, source-generation reuse, same-bucket context, OneSync network ownership, entity removal and Control CEF observation are runtime concerns. Its exact candidate must exercise all four migrations; vehicle, ped and object spawn/materialize/dematerialize/delete; generation and NetID reuse; binding/persistent-key races; checkpoint and extension hydration; bucket lifecycle and out-of-band move rejection; resource/Core restart; expired authority takeover and recovery circuit; failure compensation; Doctor/Control read-only behavior; and final diff/secret review. See the [Entity verification status](reference/entities.md#verification-status).

Production-ready beta means that the documented single-instance Core profile has passed the frozen completion scope, has bounded known limitations, and has a documented recovery path. It does not mean API stability, zero defects, high-availability certification, a support SLA, or a stable `1.0` release.

## Decision rules

- Evidence identifies the full commit SHA, dirty/clean state, UTC date, operating system, FXServer artifact, oxmysql version, database version, and tested configuration profile.
- Runtime and client evidence from another runtime tree does not certify changed runtime bytes.
- A documentation-only correction may reuse runtime evidence only when Core and generated runtime bytes are unchanged; repository and documentation checks still run again.
- `PASS` requires privacy-safe evidence. `BLOCKED`, `NOT TESTED`, unexplained warnings, skipped mandatory checks, or manual database repair are not passes.
- A known limitation is acceptable only when it is outside the supported profile, documented before release, and protected by a fail-closed configuration or operating rule.
- Never weaken a test, capability, migration invariant, or runtime check merely to turn the gate green.

## Final server outage and recovery gate

Use an isolated FXServer profile and a disposable MariaDB schema. Do not run this procedure against a normal server or shared database.

1. Start the exact Core runtime and require lifecycle `READY`, player admission open, 26 applied Core migrations, no degraded or unhealthy resource/worker state, and no nonterminal migration state. Scheduled workers that are not yet due may remain `pending`; the server-only gate probe is verified separately.
2. Stop only the verified disposable MariaDB process while Core stays running.
3. Require the database-health fence to move Core to `DEGRADED`, keep bounded diagnostics available, close player admission, expose only the redacted database-runtime reason, and avoid duplicate replacement probes.
4. Restore MariaDB, then stop the isolated FXServer process. Do not claim that an unsettled oxmysql callback was cancelled or that same-process recovery is supported.
5. Start a fresh FXServer process against the same isolated schema and instance identity.
6. Require recovery reconciliation, lifecycle `READY`, admission open, persisted instance status `ready`, no degraded or unhealthy worker state, 26 applied migrations, and no leaked session/admission authority.
7. Stop the isolated processes and retain only sanitized counts, versions, timestamps, hashes, and stable codes.

## Final automated gate

Run from the selected repository revision with the repository-required Node.js and npm versions:

```bash
npm ci
npm run check
npm test
npm run security
npm run certify
```

The final report records the exact pass/fail/skip counts and explains gated live-database skips. Generated checks must not leave drift. Scanner and certification output are review aids, not stand-alone security guarantees.

The separate destructive live-database gate remains documented in [Testing](testing.md#live-database-gate). Existing current-tree live-database and capacity evidence can carry across documentation-only changes when Core bytes remain identical; it must be repeated after any affected product change.

## Final client smoke test — PASS

This gate passed on 2026-08-25 against the accepted runtime revision. Both accepted connections traversed `received`, `identity_ok`, `access_ok`, `lease_acquired`, `deferral_accepted`, `player_joining_received`, `join_identity_verified`, `join_lease_verified`, and `session_opened` in order. The clean disconnect and reconnect produced no stale session, duplicate authority, `LEASE_BUSY`, pending deferral, or admission reservation. Core remained `READY`, `synex doctor` returned `PASS`, all 26 Core migrations were applied, and the final database aggregate was `3 / 0 / 0 / 0`: three retained closed sessions, zero open sessions, zero active session leases, and zero active admission leases.

Use the following sequence to reproduce the gate after any runtime change:

1. Start the exact candidate and require `synex overview` plus `synex doctor` to agree on a healthy `READY` Core.
2. Join once with a real FiveM client and require exactly one active session with no generic Cfx rejection.
3. Disconnect and require the session, source state, pending connection, admission reservation, and local session lease to close or expire within their documented bound.
4. Reconnect and require a fresh session without `LEASE_BUSY`, a duplicate active session, or stale source authority.
5. Run `synex sessions` and `synex doctor` again; require no leaked pending admission and no health regression.

Connection evidence contains only correlation ID, stage, elapsed time, and stable code. Do not retain raw identifiers, player names, source IDs, endpoints, or database errors.

## Final documentation and publication gate

- Audit tracked Markdown and example configuration against the candidate code.
- Validate relative links, anchors, Mermaid blocks, commands, file paths, migration counts, dependency versions, module names, and maturity statements.
- Keep implemented Core behavior, unsupported non-Core snapshots, compatibility targets, and planned resources visibly separate.
- Review `git status`, the complete diff, staged diff, commit metadata, binary sizes, and the final candidate commit.
- Run `npm audit --audit-level=high` and `git diff --check`; review and resolve any finding before publication.
- Scan for credentials, connection strings, private endpoints, workstation paths, dumps, logs, temporary probes, generated evidence, and unrelated changes.
- Push only the intended branch and verify local/remote commit parity afterward.

## Post-Beta promotion work

These items are intentionally deferred until work begins on moving out of Beta. They are useful hardening and release-engineering work, but they do **not** block the initial Production-Beta decision:

1. a 125-minute or longer server-only soak with scheduled-worker and resource-growth evidence;
2. a permanent, maintained evidence runner;
3. a historical supported-version upgrade drill;
4. an extensive encrypted backup/restore and operator RPO/RTO drill;
5. additional non-critical ABI regression tests.

The [backup and restore runbook](backup-and-restore.md) remains required operational reading before handling real server data. Deferring its full certification drill does not remove the operator's responsibility to keep verified backups.

## Later optional profiles

The following work requires a separate acceptance decision and does not expand the initial Core beta:

- MariaDB/MySQL versions outside the supported target;
- Linux host certification;
- multi-instance operation and alternate duplicate policies;
- high availability, failover, and orchestrated deployment;
- every downstream resource, bridge, SDK integration, compatibility layer, and migration tool after its rework.

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
Database outage/recovery: <result>
Client join/disconnect/reconnect: <result>
Documentation and diff review: <result>
Known limitations accepted: <list>
```

The current PASS permits the wording **Production-ready beta for the documented Core profile**; it does not permit a framework-wide or stable-release claim. Any future release decision remains the project owner's responsibility.
