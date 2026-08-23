# Testing

Synex uses Node.js' built-in test runner. TypeScript tests compile into `.build/tests`; Lua modules run headlessly inside Wasmoon with deterministic platform fakes.

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

## Framework CI

[`framework-ci.yml`](../.github/workflows/framework-ci.yml) runs with read-only repository permissions, fully pinned official checkout/setup actions, Node.js 24, and `npm ci`. Its quality job verifies generated consistency, compiles TypeScript, validates manifests and schemas, executes every non-database test scope, runs compatibility and security analysis, certifies the repository, and audits the locked npm graph. Pull requests use the ordinary `pull_request` event; the workflow does not reference repository secrets or execute through `pull_request_target`.

After the quality job passes, a separate job starts an isolated MariaDB service, enables the destructive-test gate for its `synex_test_ci` schema, applies every currently owned migration, and checks live schema invariants. This job is the CI verification path for live database behavior; it does not broaden the default local test gate.

## Coverage present in the repository

| Suite | Verified behavior |
| --- | --- |
| `lua` | SHA-256, migration lease expiry during an in-flight statement with single execution and owner/token marker fencing, persisted source-generation seeding/exhaustion, boot-fenced session leases/inserts/status/cleanup, acquisition-unique runtime worker owners, failed-boot runtime-gate closure and owner/scheduler purge, cluster same-name duplicate handling, global/fixed-kind lease denial, existing-name cap bypass, unknown-name classification, drift/rollback protection and counter-releasing terminal compaction, synchronous connection quiesce, restart-fenced remote controls, session-control exact/foreign replay at quota, global/requester denial, drift/overflow fail-closed behavior, atomic reservation rollback and fair exact terminal compaction, failed-cleanup admission closure, atomic local session-authority cleanup, instance heartbeat status preservation and transient status-write recovery, single-pass queue arbitration with O(1) waiter state, immutable staff priority, reserved-slot skipping, grant timeout and quiesce races, maintenance gating, persistent RBAC, local and cross-instance character activation exclusion, both select/delete commit orders, source-generation and boot/lease swaps across character yields, required-participant compensation, fail-closed partial unload, soft-deleted slot reuse, character-deletion and unload-persistence reconciliation, non-destructive retention batches, owner cleanup/restarts, schema fuzzing, state authority, bounded pending diagnostics, dynamic admission/resource-health parity, operator commands, scheduler health, disconnect cleanup, and durable saga retry/deadline/compensation |
| `core` | bounded owner quiesce/drain, pending-operation abort, reconstructable state handoff, malformed/replayed snapshot rejection, and repeated same-core restarts |
| `stress` | 1,000 sequential session/index lifecycles through the production registry and 100,000 deterministic transfer commands through the real accounts validation path against an in-memory double-entry model, including nonnegative-total and idempotent-replay properties |
| `tooling` | deterministic multi-target generation, drift/version metadata, graph and unused-declaration analysis, diagnostics redaction, scaffolding, upgrade/certification artifacts, reload plans/adapters, executable fuzzing, benchmark labeling, and AST security findings |
| `database` | migration ordering/checksums/ownership, SQL/caller invariants, domain validation, archive-mirror constraints/no-source-delete guards, permanent-idempotency quota metadata/backfill and a gated exact-winner capacity race, retained session-control and cluster-lease all-state quota backfills, exact constraint/FK/generated-classifier/index metadata, malicious-check/classifier/unenforced-check rejection, terminal counter release, a two-connection READ-COMMITTED same-name lease race, live DDL, parallel transfer/idempotency, migration statement/marker fencing across lease expiry, cluster lease fencing, and reconciled legacy import/replay |
| `entities` | spawn/bucket validation, Net ID reuse defense, deterministic rate limiting, injectable database port, entity manifest boundaries, closed-state NUI and read-only callbacks |
| `compatibility` | caller-bound native bridge facades, bounded callback source/session fencing, balanced counterparty transfers, deterministic migration plans, bundle tamper checks, and import idempotency |
| `documentation` | local link targets, balanced Markdown/Mermaid fences, supported diagram roots, synchronized landing pages, pinned CI actions, manifest paths, and orphaned resource Lua detection |

## Live database gate

Database tests can create and mutate schema. They run only when both variables are set and the database name starts with `synex_test_`:

```text
SYNEX_TEST_DATABASE_LIVE=1
SYNEX_TEST_DATABASE_URL=mysql://...
```

Use only a disposable database. The test opens the configured schema, applies every current migration, inspects InnoDB/check/foreign-key/generated-column/index metadata, proves that migration `018` rejects a malformed marker without dropping the legacy key, and verifies the all-state migration `022` idempotency, `024` session-control, and `025` cluster-lease capacity backfills. It proves that weakened checks/classifiers and, on MySQL, a named `NOT ENFORCED` check are rejected, then checks soft-deleted character-slot reuse plus duplicate-active rejection. Independent connections exercise opposite-direction transfers, duplicate idempotency, an exact-winner namespace-capacity race, the ordinary cluster-lease fence, and the READ-COMMITTED same-name row-first claim with exactly one counter charge. The suite also imports a unique synthetic reviewed plan and verifies native identities, accounts, balanced openings, groups, reconciliation, and no-write replay. It does not drop or reset a database for you.

GitHub Actions supplies an isolated MariaDB service and enables this gate. A normal local `npm test` skips the live case when the gate is closed; static migration tests still run.

## Static analysis boundaries

`npm run security` is a review aid. It identifies patterns with severity and confidence; it does not prove safety. `npm run certify` evaluates repository policy and produces PASS/WARN/FAIL findings; it is not a production guarantee. `npm run benchmark` is a local microbenchmark and must not be presented as FXServer or competitor performance evidence.

## Coverage not present

The stress suite is a deterministic, sequential Wasmoon model. It does not run FXServer, OneSync/network scheduling, concurrent Lua threads, or the SQL ledger path, and its operation counts are not benchmark results.

The repository currently does not start FXServer in CI. There is no end-to-end Cfx client/server test, external-framework integration environment, browser automation run, production load test, or database-failure chaos environment. Run those checks against the exact deployment before release.

## FXServer join acceptance

Treat a join fix as live-verified only after the exact deployment has passed this sequence with a real FiveM client:

1. Start the server, wait for Core `READY`, then run `synex overview` and `synex doctor`. Core resource health must be `HEALTHY` and Doctor must not report `UNKNOWN` as a pass.
2. Join once without an immediate retry. One correlation ID must progress through `received`, `identity_ok`, `access_ok`, `lease_acquired`, `deferral_accepted`, `player_joining_received`, `join_identity_verified`, `join_lease_verified`, and `session_opened`, in that order.
3. Run `synex sessions`. The accepted attempt must no longer be pending and must own exactly one persisted session. No successful deferral may produce the generic Cfx `Unknown error` rejection.
4. Disconnect and confirm that the session closes, its network state is purged, and no active fenced session lease remains.
5. Abort one connection after deferral acceptance. Without manual database intervention, pending count and admission reservation count must return to zero after `connections.pendingTtlMs` plus the bounded connection-heartbeat and batch-cleanup delay; a later retry must not remain blocked by `LEASE_BUSY`.
6. Repeat ten clean join/disconnect cycles and five rapid retry attempts. For each planned restart, run `synex prepare-restart`, require its structured result to report `state = "prepared"`, and only then run the returned `restart synex_core` command. Test once while a player is pending and once while a player is active: connected players must be disconnected, prior local sessions must be `CLOSED`, local session leases and pending control requests must be expired, and reconnects must receive fresh sessions without `LEASE_BUSY`. Separately exercise one unprepared restart to verify next-boot recovery; do not misclassify its non-yielding stop handler as a graceful drain. Every deliberate rejection must carry a stable `Synex [CODE]` message, and `synex status`, `synex resources`, and `synex doctor` must agree on health.
7. In a two-instance test, start a `kick_old` replacement and restart the requesting Core while the control request is in flight. The target instance must not consume a request from a `stopping`, `stopped`, stale, or previous-boot requester.

Connection-stage records intentionally contain a correlation ID, stage, elapsed time, and stable code only. Do not add raw identifiers, player names, source IDs, or database error text while collecting this evidence.
