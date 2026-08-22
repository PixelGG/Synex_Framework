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
| `lua` | SHA-256, lifecycle/source-generation reuse, cluster duplicate handling, reserved/staff/reconnect queue admission, maintenance gating, persistent RBAC, character-deletion and unload-persistence reconciliation, non-destructive retention batches, owner cleanup/restarts, schema fuzzing, state authority, bounded diagnostics/commands, scheduler health, disconnect cleanup, and durable saga retry/deadline/compensation |
| `core` | bounded owner quiesce/drain, pending-operation abort, reconstructable state handoff, malformed/replayed snapshot rejection, and repeated same-core restarts |
| `stress` | 1,000 sequential session/index lifecycles through the production registry and 100,000 deterministic transfer commands through the real accounts validation path against an in-memory double-entry model, including nonnegative-total and idempotent-replay properties |
| `tooling` | deterministic multi-target generation, drift/version metadata, graph and unused-declaration analysis, diagnostics redaction, scaffolding, upgrade/certification artifacts, reload plans/adapters, executable fuzzing, benchmark labeling, and AST security findings |
| `database` | migration ordering/checksums/ownership, SQL/caller invariants, domain validation, archive-mirror constraints/no-source-delete guards, and gated live DDL, parallel transfer/idempotency, lease fencing, and reconciled legacy import/replay |
| `entities` | spawn/bucket validation, Net ID reuse defense, deterministic rate limiting, injectable database port, entity manifest boundaries, closed-state NUI and read-only callbacks |
| `compatibility` | caller-bound native bridge facades, bounded callback source/session fencing, balanced counterparty transfers, deterministic migration plans, bundle tamper checks, and import idempotency |
| `documentation` | local link targets, balanced Markdown/Mermaid fences, supported diagram roots, synchronized landing pages, pinned CI actions, manifest paths, and orphaned resource Lua detection |

## Live database gate

Database tests can create and mutate schema. They run only when both variables are set and the database name starts with `synex_test_`:

```text
SYNEX_TEST_DATABASE_LIVE=1
SYNEX_TEST_DATABASE_URL=mysql://...
```

Use only a disposable database. The test opens the configured schema, applies every current migration, inspects InnoDB/check/foreign-key metadata, and uses independent connections for opposite-direction transfers, a duplicate-idempotency race, and a single-winner cluster-lease claim. It also imports a unique synthetic reviewed plan and verifies native identities, accounts, balanced openings, groups, reconciliation, and no-write replay. It does not drop or reset a database for you.

GitHub Actions supplies an isolated MariaDB service and enables this gate. A normal local `npm test` skips the live case when the gate is closed; static migration tests still run.

## Static analysis boundaries

`npm run security` is a review aid. It identifies patterns with severity and confidence; it does not prove safety. `npm run certify` evaluates repository policy and produces PASS/WARN/FAIL findings; it is not a production guarantee. `npm run benchmark` is a local microbenchmark and must not be presented as FXServer or competitor performance evidence.

## Coverage not present

The stress suite is a deterministic, sequential Wasmoon model. It does not run FXServer, OneSync/network scheduling, concurrent Lua threads, or the SQL ledger path, and its operation counts are not benchmark results.

The repository currently does not start FXServer in CI. There is no end-to-end Cfx client/server test, external-framework integration environment, browser automation run, production load test, or database-failure chaos environment. Run those checks against the exact deployment before release.
