# Testing

Synex uses Node.js' built-in test runner. TypeScript tests compile into `.build/tests`; Lua modules run headlessly inside Wasmoon with deterministic platform fakes.

The Production-Beta acceptance decision covers `synex_core` only. Repository suites for `synex_groups`, `synex_accounts`, `synex_entities`, `synex_control`, bridges, SDKs, examples, or migration tooling are regression evidence for rework snapshots; a passing suite does not add those components to the Core candidate deployment profile.

## Local workflow

```bash
npm ci
npm run check
npm test
npm run security
npm run certify
```

Focused suites can be run after `npm run check` or `npm run build`:

```bash
npm run test:lua
node tools/test-runner.mjs core
node tools/test-runner.mjs stress
node tools/test-runner.mjs tooling
node tools/test-runner.mjs database
node tools/test-runner.mjs entities
node tools/test-runner.mjs compatibility
node tools/test-runner.mjs documentation
```

The test runner fails if the selected compiled suite does not exist. This prevents a missing build or misspelled scope from appearing green.

## Current acceptance baseline

The next clean post-documentation revision will be the current exact-revision acceptance target. Its runtime tree contains the trusted Cfx JSON-container fix introduced by `e0cbf45` and exact connection-queue capacity coverage; repository validation passes. Predecessor `888a7326` passed the automated and major server-side stages, but its planned minimum 120-minute soak exposed `INVALID_OUTBOX_RETENTION` at the first hourly outbox execution and ended **FAIL / NO-GO** before the minimum duration completed. The selected revision must repeat the complete exact automated/server gate, a fresh soak, backup/upgrade evidence, and the real-client lifecycle. Manual FXServer results remain separate from the automated artifact because repository automation does not launch FXServer or a FiveM client.

| Gate | Status | Current evidence |
| --- | --- | --- |
| Repository/headless validation | **PASS ON CURRENT RUNTIME TREE** | `npm run check` passed; Lua 232/232; repository tests 413 passed, 0 failed, 19 live-database skips; static security 0 findings; `git diff --check` passed |
| Exact automated Core evidence gate | **PENDING** | Regenerate the full clean-checkout artifact, including live database, certification, audit, and integrity stages, for the selected post-documentation revision |
| Fresh MariaDB / FXServer boot | **PENDING** | Predecessor evidence does not certify the current runtime tree |
| Public Core API and probe | **PENDING** | Repeat caller-bound API, Cfx callables, RPC, services, events, hooks, scheduler, idempotency metadata, Connection Gate, and persisted Saga execution |
| Probe restart protocol | **PENDING** | Repeat both phases and confirm run-scoped KVP cleanup on the current candidate |
| Restart and process recovery | **PENDING** | Repeat prepared restart, unprepared recovery, full-process termination, and next-boot recovery |
| Runtime database outage | **PENDING** | Repeat fail-closed fencing and the documented full-process recovery after database restoration |
| Backup/restore and rehearsal upgrade | **PENDING; RPO/RTO REVIEW PENDING** | Repeat encrypted recovery/parity and the retained 25-to-26 rehearsal; explicit operator RPO/RTO approval remains open |
| Server-only soak | **PENDING** | Start a new minimum 120-minute run; the predecessor run failed and cannot be resumed or transferred |
| Exact-candidate FiveM client lifecycle | **PENDING** | Join, disconnect, and reconnect must run against the selected revision; predecessor evidence does not transfer |
| Two-instance and alternate duplicate policies | **OUTSIDE BETA SCOPE** | Strict production accepts only the single-instance `deny_new` profile; `kick_old`, `replace_old`, and `allow` remain development/staging verification modes |

The automated artifact intentionally labels every manual field `NOT_RUN`; it reports only work executed by that command. Separate runtime evidence never rewrites those artifact fields. This is not a stable-release, downstream-resource, external-framework, or deployment-certification claim.

## Framework CI

[`framework-ci.yml`](../.github/workflows/framework-ci.yml) runs with read-only repository permissions, fully pinned official checkout/setup actions, Node.js 24, and `npm ci`. Its quality job verifies generated consistency, compiles TypeScript, validates manifests and schemas, executes every non-database test scope, runs compatibility and security analysis, certifies the repository, and audits the locked npm graph. Pull requests use the ordinary `pull_request` event; the workflow does not reference repository secrets or execute through `pull_request_target`.

After the quality job passes, a separate job starts an isolated MariaDB service, enables the destructive-test gate for its `synex_test_ci` schema, applies every currently owned migration, and checks live schema invariants. This repository-wide regression job includes experimental domain-resource migrations; it does not make those resources part of Core certification or broaden the default local test gate.

## Coverage present in the repository

| Suite | Verified behavior |
| --- | --- |
| `lua` | SHA-256, Cfx JSON containers with decoder-created metatables across persisted Saga redispatch, migration lease expiry during an in-flight statement with single execution and owner/token marker fencing, persisted source-generation seeding/exhaustion, boot-fenced session leases/inserts/status/cleanup, acquisition-unique runtime worker owners, failed-boot runtime-gate closure and owner/scheduler purge, cluster same-name duplicate handling, global/fixed-kind lease denial, existing-name cap bypass, unknown-name classification, drift/rollback protection and counter-releasing terminal compaction, synchronous connection quiesce, database-before-owner prepared-restart draining, restart-fenced remote controls, session-control exact/foreign replay at quota, global/requester denial, drift/overflow fail-closed behavior, atomic reservation rollback and fair exact terminal compaction, failed-cleanup admission closure, atomic bounded local session/admission authority cleanup, instance heartbeat status preservation and transient status-write recovery, single-pass queue arbitration with O(1) waiter state, exact queue-capacity boundary plus `QUEUE_FULL`, timeout cleanup and capacity reuse, immutable staff priority, reserved-slot skipping, grant timeout and quiesce races, maintenance gating, persistent RBAC, local and cross-instance character activation exclusion, both select/delete commit orders, source-generation and boot/lease swaps across character yields, required-participant compensation, fail-closed partial unload, soft-deleted slot reuse, character-deletion and unload-persistence reconciliation, non-destructive retention batches, owner cleanup/restarts, schema fuzzing, state authority, bounded pending diagnostics, dynamic admission/resource-health parity, operator commands, scheduler health, disconnect cleanup, and durable saga retry/deadline/compensation |
| `core` | bounded owner quiesce/drain, pending-operation abort, reconstructable state handoff, malformed/replayed snapshot rejection, and repeated same-core restarts |
| `stress` | 1,000 sequential session/index lifecycles through the Core registry implementation and 100,000 deterministic transfer commands through the experimental accounts validation path against an in-memory double-entry model, including nonnegative-total and idempotent-replay properties |
| `tooling` | deterministic multi-target generation, drift/version metadata, graph and unused-declaration analysis, diagnostics redaction, scaffolding, upgrade/certification artifacts, reload plans/adapters, executable fuzzing, benchmark labeling, and AST security findings |
| `database` | migration ordering/checksums/ownership, SQL/caller invariants, domain validation, archive-mirror constraints/no-source-delete guards, permanent-idempotency quota metadata/backfill and a gated exact-winner capacity race, retained session-control and cluster-lease all-state quota backfills, migration `026` owner-aware lease-index metadata, bounded local connection-authority recovery with unrelated-kind isolation and residual-phantom rollback, exact constraint/FK/generated-classifier/index metadata, malicious-check/classifier/unenforced-check rejection, terminal counter release, a two-connection READ-COMMITTED same-name lease race, live DDL, parallel transfer/idempotency, migration statement/marker fencing across lease expiry, cluster lease fencing, and reconciled legacy import/replay |
| `entities` | spawn/bucket validation, Net ID reuse defense, deterministic rate limiting, injectable database port, entity manifest boundaries, closed-state NUI and read-only callbacks |
| `compatibility` | caller-bound native bridge facades, bounded callback source/session fencing, balanced counterparty transfers, deterministic migration plans, bundle tamper checks, and import idempotency |
| `documentation` | local link targets, balanced Markdown/Mermaid fences, supported diagram roots, synchronized landing pages, pinned CI actions, manifest paths, and orphaned resource Lua detection |

The `entities`, `compatibility`, accounts/groups portions of `database` and `stress`, and SDK/tooling integration checks protect the current source snapshots during rework. Their presence and pass status are not runtime support claims.

## Live database gate

Database tests can create and mutate schema. They run only when both variables are set and the database name starts with `synex_test_`:

```text
SYNEX_TEST_DATABASE_LIVE=1
SYNEX_TEST_DATABASE_URL=mysql://...
```

Use only a disposable database. The test opens the configured schema, applies every current migration, inspects InnoDB/check/foreign-key/generated-column/index metadata, proves that migration `018` rejects a malformed marker without dropping the legacy key, and verifies the all-state migration `022` idempotency, `024` session-control, and `025` cluster-lease capacity backfills. It also verifies migration `026`, rejects a MariaDB `IGNORED` or MySQL `INVISIBLE` forced runtime index, and exercises the bounded owner-aware local connection-authority recovery path, including isolation from local Saga, character, and other leases plus fail-closed rollback when a residual phantom appears. It proves that weakened checks/classifiers and, on MySQL, a named `NOT ENFORCED` check are rejected, then checks soft-deleted character-slot reuse plus duplicate-active rejection. Independent connections exercise opposite-direction transfers, duplicate idempotency, an exact-winner namespace-capacity race, the ordinary cluster-lease fence, and the READ-COMMITTED same-name row-first claim with exactly one counter charge. The suite also imports a unique synthetic reviewed plan and verifies native identities, experimental accounts/groups data, reconciliation, and no-write replay. It does not drop or reset a database for you. For the Core Production-Beta decision, evaluate the Core-owned migration and runtime evidence separately from these repository-wide rework checks.

GitHub Actions supplies an isolated MariaDB service and enables this gate. A normal local `npm test` skips the live case when the gate is closed; static migration tests still run.

## Static analysis boundaries

`npm run security` is a review aid. It identifies patterns with severity and confidence; it does not prove safety. `npm run certify` evaluates repository policy and produces PASS/WARN/FAIL findings; it is not a production guarantee. `npm run benchmark` is a local microbenchmark and must not be presented as FXServer or competitor performance evidence.

## Coverage not present

The stress suite is a deterministic, sequential Wasmoon model. It does not run FXServer, OneSync/network scheduling, concurrent Lua threads, or the SQL ledger path, and its operation counts are not benchmark results.

The repository currently does not start FXServer in CI. Predecessor `888a7326` has separate evidence for fresh boot, public API/probe behavior, restart/process-crash recovery, live database-outage fencing and full-process recovery, backup/restore, and the retained 25-to-26 rehearsal, but its planned minimum soak failed before completion. The selected post-documentation revision must repeat every applicable runtime stage. There is no automated end-to-end Cfx client/server test, external-framework integration environment, browser automation run, production load test, or multi-instance `kick_old` requester-restart test. Strict production excludes that mode rather than treating the gap as accepted risk.

## Disposable Core live-test bundle

Privileged cross-resource acceptance probes must never be added to the production capability policy. Synex instead prepares a disposable copy of `synex_core` under the Git-ignored `.temp/live-test/` tree and adds exactly these grants to that copy only:

- `synex.connections.gate`
- `synex.sagas.read`
- `synex.sagas.register`
- `synex.sagas.write`

Keep the probe in a directory named `synex_core_probe` outside the repository. In particular, do not leave it untracked under `tools/live-test/`: repository certification intentionally discovers untracked resource manifests. The probe must be server-only, depend only on `synex_core`, request exactly the four capabilities above, and own no migrations or tables. Contract descriptors are allowed only as explicit local `.contracts.json` files declared identically through `synex_contracts` and the manifest `files` block.

Run the ordinary gates against a clean checkout first, then prepare the isolated bundle:

```bash
npm run certify
node --experimental-strip-types tools/cli/src/bin.ts live-test prepare --probe "../synex_core_probe"
```

The command refuses a dirty revision, in-repository probes, symlinks, non-text payloads, recognized secret patterns, non-Lua executables, known unsafe execution/network/database primitives, wildcard or additional capabilities, and an existing output directory. These bounded static checks complement review of the external probe; they are not proof that arbitrary source is safe. The builder copies only tracked Core and schema files plus the inspected probe into a fresh `.temp/live-test/core-probe_<id>/` bundle, verifies the copied bytes, validates the combined resources, checks the effective grants, runs static security analysis, and verifies that the tracked production policy remains byte-for-byte unchanged. `server-data/live-test.cfg.example` contains the generated server-only probe run ID and safe Core ConVars; database credentials and the Cfx license key are intentionally absent.

Use only the bundle's `server-data/resources/synex_core` and `server-data/resources/synex_core_probe` resources with the generated disposable `server-data` profile, a disposable database/schema, and a separate port. Before including the generated fragment, the primary startup configuration must define isolated TCP/UDP endpoints, `sv_licenseKey`, and `mysql_connection_string`, and the resource search path must provide the exact candidate `oxmysql 2.14.1`; none of those operator-owned dependencies or credentials is copied into the bundle. The generated fragment selects `production`, strict validation, and `deny_new` so acceptance exercises the exact target configuration rather than a staging variant. It uses documented Core ConVars and resource commands only. Its comments contain no semicolon-separated text that FXServer could interpret as another command. Never copy the derived `capabilities.json` into the repository or a persistent server installation, and remove the bundle after the acceptance run.

If the probe persists restart evidence with resource KVP, all direct KVP access must stay in one reviewed helper. Scope the exact key as `synex_core_probe.owner_epoch.v1:<synex_probe_run_id>` and use synchronous reads/writes. The protocol is deliberately two-phase: the first PASS writes the owner epoch, reports `restartRequired = true`, and does **not** claim cleanup; restart only `synex_core_probe` while the same Core process stays running. The second PASS must observe a greater owner epoch, report `restartRequired = false`, delete the exact key, and report `kvpCleaned = true`. Every FAIL path deletes the exact key and reports cleanup. The bundle report records the run-scoped key; no FXServer-wide KVP namespace command is required. The builder rejects KVP enumeration, external KVP access, and `_NO_SYNC` writes. After an interrupted first phase, do not reuse the evidence as a PASS; complete controlled cleanup or discard the private bundle.

Owner epochs are process-local. Assert only that the new owner epoch is greater after restarting `synex_core_probe` while the same Core process remains running. Never compare the numeric epoch across a `synex_core` or FXServer restart; those stages must instead verify stale-facade rejection, a fresh `GetAPI()` facade, and boot/session recovery. Reuse the generated instance ID only for the related multi-boot recovery scenario, after the owner-epoch helper has confirmed cleanup; create a new bundle for an unrelated acceptance run.

## FXServer join acceptance

> [!IMPORTANT]
> **Current status: pending for the selected post-documentation revision.** Earlier real-client evidence remains useful regression history but does not certify that exact revision. Join, disconnect, and reconnect are still required before the current NO-GO decision can change. The acceptance target is the single-instance `deny_new` profile; the multi-instance duplicate-policy scenario below remains future development evidence, not an initial Beta release gate.

The prepared-restart evidence included a pending connection blocked on database work. Preparation closed the normal database activity gate, waited for the tracked work to drain, and only then quiesced resource owners before using its private database control lane. It did not unload a live database callback.

Treat a join fix as live-verified only after the exact deployment has passed this sequence with a real FiveM client:

1. Start the server, wait for Core `READY`, then run `synex overview` and `synex doctor`. Core resource health must be `HEALTHY` and Doctor must not report `UNKNOWN` as a pass.
2. Join once without an immediate retry. One correlation ID must progress through `received`, `identity_ok`, `access_ok`, `lease_acquired`, `deferral_accepted`, `player_joining_received`, `join_identity_verified`, `join_lease_verified`, and `session_opened`, in that order.
3. Run `synex sessions`. The accepted attempt must no longer be pending and must own exactly one persisted session. No successful deferral may produce the generic Cfx `Unknown error` rejection.
4. Disconnect and confirm that the session closes, its network state is purged, and no active fenced session lease remains.
5. Abort one connection after deferral acceptance. Without manual database intervention, pending count and admission reservation count must return to zero after `connections.pendingTtlMs` plus the bounded connection-heartbeat and batch-cleanup delay; a later retry must not remain blocked by `LEASE_BUSY`.
6. Repeat ten clean join/disconnect cycles and five rapid retry attempts. For each planned restart, run `synex prepare-restart`, require its structured result to report `state = "prepared"`, and only then run the returned `restart synex_core` command. Test once while a player is pending and once while a player is active: connected players must be disconnected, prior local sessions must be `CLOSED`, local session leases and pending control requests must be expired, and reconnects must receive fresh sessions without `LEASE_BUSY`. Hold a disposable database row lock during the pending case, release it before the bounded preparation drain expires, and require preparation to wait for database activity to reach zero before owner/producer quiesce rather than unload a live callback. Separately exercise one unprepared restart without an injected database blocker to verify next-boot durable recovery; do not misclassify its non-yielding stop handler as a graceful drain. An isolated raw Core restart during blocked interactive oxmysql work is outside the callback-clean guarantee and must be tested as an expected operational rejection/incident path, not as the supported restart workflow. Every deliberate rejection must carry a stable `Synex [CODE]` message, and `synex status`, `synex resources`, and `synex doctor` must agree on health.
7. Keep Core running and stop only the verified disposable MariaDB process. Once the runtime database-health probe fails or reaches its five-second watchdog, require lifecycle `DEGRADED` with `operational = true`, admission closed, and only the redacted `database-runtime` reason. Ordinary database-backed workers suspend while the bounded connection cleanup path remains fail-closed. A timed-out oxmysql await is not claimed as cancelled and no replacement probe may accumulate beside it. After MariaDB returns, use the documented full FXServer-process recovery path: stop the isolated process, start a new process, and require recovery reconciliation, Core `READY`, admission open, persisted instance `ready`, Doctor `PASS`, healthy workers, and no leaked session/admission authority. Same-process recovery after an unsettled driver promise is not part of the supported beta profile.
8. Outside the initial Beta support profile, a future two-instance test must start a `kick_old` replacement and restart the requesting Core while the control request is in flight. The target instance must not consume a request from a `stopping`, `stopped`, stale, or previous-boot requester. Until this passes, strict production continues to reject `kick_old`, `replace_old`, and `allow`.

Connection-stage records intentionally contain a correlation ID, stage, elapsed time, and stable code only. Do not add raw identifiers, player names, source IDs, or database error text while collecting this evidence.
