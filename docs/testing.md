# Testing

Synex uses Node.js' built-in test runner. TypeScript tests compile into `.build/tests`; Lua modules run headlessly inside Wasmoon with deterministic platform fakes.

The frozen Production-Beta acceptance decision covers one exact `synex_core` tree only. Dedicated `groups`, `accounts` and `entities` suites protect the three Experimental Alpha domains; suites for Control, bridges, SDKs, examples, or migration tooling have the same non-release boundary. Passing repository suites does not extend the accepted Core deployment profile or complete a domain's runtime acceptance.

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
node tools/test-runner.mjs groups
node tools/test-runner.mjs accounts
node tools/test-runner.mjs entities
node tools/test-runner.mjs control
node tools/test-runner.mjs compatibility
node tools/test-runner.mjs documentation
```

The test runner fails if the selected compiled suite does not exist. This prevents a missing build or misspelled scope from appearing green.

## Current Entities Alpha boundary

`synex_entities` is Development / Experimental Alpha; its optional read-only diagnostics are exposed through the separate Control provider boundary. On 2026-08-26 the working tree passed `npm run check`, the focused Entities suite (128/128), the full repository run (815 passed, 0 failed, 29 expected live-database skips out of 844), the database scope with its gate closed (72 passed, 0 failed, 29 skipped), security (228 scanned files, 0 findings), dependency audit (0 vulnerabilities), documentation (5/5), and the deterministic local benchmark. The focused suite checks 33 server-only versioned definitions across 32 contract names, capability/descriptor closure, exact public-error normalization, four migrations and eight-table ownership, authority/extension repositories, lifecycle policy, bounded runtime/spatial indexes, routing policy, Doctor diagnostics, closed-state NUI behavior, stable-Entity-ID/bucket inspection, Core metric projection, and the transport-only network-owner label. These focused tests do not launch MariaDB, FXServer, OneSync or a FiveM client. The database scope additionally contains a gated disposable-MariaDB case for persistent-key and binding races, single-winner authority claims, expired takeover, Entity/lease generation advancement and stale-lease fencing; it is not evidence until run against the exact candidate. The remaining exact-candidate gates are listed under [Entity verification status](reference/entities.md#verification-status).

## Current Control Alpha boundary

`synex_control` is a separate optional Development / Experimental Alpha operations surface, not an Entity-owned NUI projection. Its source-level gates cover the Core provider registry and 32 Core views, ascending keyset Session pages, a payload/header-free Core outbox snapshot, bounded RPC/hook owner-outcome-timeout-latency projections, bounded process-local trace/span and slow-operation histories without payloads/SQL, a newest-first process-local Security rejection history plus ID-free stale-session aggregation, exact user-to-active-session lookup without user-ID output, audit keyset pagination, capability explain, persisted-instance projections, cursor-paged migration diagnostics, count-only isolated Character domain aggregates and the three provider-owned `character_relations` views, Group/Membership aggregates, read-only policy simulation, Entity recovery-circuit inspection, descriptor/runtime parity, mandatory view access classes and closed input/per-kind search metadata, request envelopes, closed schemas, request/response byte limits, provider timeout/busy/restart isolation, sanitizer redaction and identifier masking, specialist ACE routing, targeted responses, separate summary/catalog loading, player/scope-bound 120-second cursor handles, resource invalidation, domain pagination, bounded Entity quota projections, fixed presentation primitives, diagnostic-bundle runtime-evidence ingestion and transparent/non-interactive closed-state behavior. Headless scale fixtures exercise 10,000 Groups, 100,000 Accounts, 20,000 Entities and 1,000,000 Transactions without presenting those virtual cardinalities as runtime capacity. Compatibility-provider checks run in the separate `compatibility` scope. Database-pool telemetry remains intentionally unavailable because public oxmysql exposes no pool snapshot.

Repository tests and static NUI checks do not launch the exact FXServer or CEF runtime. Before any maturity promotion, run the current candidate with Core and the declared domain providers and verify registration/unavailability across resource restarts, event-driven catalog/active-view invalidation, cursor expiry and scope isolation, provider timeout/large logical dataset behavior, browser ready-before-focus, open/close/Escape, ACE revocation, no closed overlay or input capture, visibility timer suspension, responsive keyboard navigation, render failure cleanup, reconnect, and OneSync-backed Entity projections. Record the exact revision and environment; do not rewrite these open gates as passed from headless evidence.

## Current acceptance baseline

The frozen Core-only single-instance Production-Beta profile is accepted. On 2026-08-25, commit `7ad4b72ee9bcd0a2a0481cfacfe5f807eb1b3ec5` with Core tree `9f0960f1e27fe43195ae4602cb2ef447cbc0509b` completed the repository, live-database, fresh-boot, public-API, capacity, restart, crash-recovery, stale-facade, database-outage/recovery, final automated, real-client, and review gates. Manual FXServer results remain separate from repository automation because the ordinary test suite does not launch FXServer or a FiveM client. The decision applies only to that exact supported Core profile. Current Core migration `027_domain_primitives` and the Groups Experimental Alpha are later work and do not inherit it.

| Gate | Status | Current evidence |
| --- | --- | --- |
| Final automated validation | **PASS** | `npm ci`, `npm run check`, `npm test`, `npm run security`, `npm run certify`, and the high-severity dependency audit exited successfully; 416 tests passed, 0 failed, 19 expected live-database cases were gated, security reported 0 findings, and `npm audit` reported 0 vulnerabilities |
| Live database, fresh boot, and public Core API | **PASS ON FROZEN CORE TREE** | 26 Core migrations, caller-bound API/Cfx callables, RPC, services, events, hooks, scheduler, idempotency, connection gates, and persisted Saga execution passed |
| Capacity boundary | **PASS ON FROZEN CORE TREE** | Configured boundary and one-over-bound behavior fail closed with the expected bounded results |
| Probe, prepared/unprepared restart, crash recovery, and stale facades | **PASS ON FROZEN CORE TREE** | Restart ownership, cleanup, fresh facade acquisition, and next-boot recovery passed |
| Runtime database outage and recovery | **PASS** | `DEGRADED` with admission closed in 6.73 s; full FXServer stop; MariaDB plus fresh FXServer `READY` in 10.86 s; 26/26 migrations, attempts, and fences applied; zero nonterminal migration or open session/authority/Saga/outbox/idempotency work; idempotent probe replay |
| Documentation, final diff, and secret review | **PASS** | Technical docs, commands, links, maturity statements, dependency audit, secrets, and final candidate integrity/diff were reviewed without an unresolved blocker |
| Commit and publication to `main` | **PASS** | The reviewed candidate is committed and published without private test assets or unrelated files |
| Exact-candidate FiveM client smoke | **PASS** | Join, clean disconnect, reconnect, and final cleanup passed; both connections completed all nine ordered stages, Doctor remained `PASS`, all 26 migrations were applied, and the final database aggregate was `3 / 0 / 0 / 0` |
| Soak, permanent evidence runner, historical upgrade, extensive restore drill, and extra non-critical ABI cases | **POST-BETA** | Deliberately deferred until work begins on moving out of Beta; these do not block the initial Production-Beta decision |
| Two-instance and alternate duplicate policies | **OUTSIDE BETA SCOPE** | Strict production accepts only the single-instance `deny_new` profile; `kick_old`, `replace_old`, and `allow` remain development/staging verification modes |

The automated artifact intentionally labels every manual field `NOT_RUN`; it reports only work executed by that command. Separate runtime evidence never rewrites those artifact fields. This is not a stable-release, downstream-resource, external-framework, or deployment-certification claim.

## Current Groups Alpha evidence

The expanded `synex_groups` working tree has the following evidence boundary on **2026-08-25**:

| Gate | Result |
| --- | --- |
| Focused Groups headless suite | **PASS** — 197 passed, 0 failed, 0 skipped |
| Historical source catalog | **PASS** — 68 Groups contracts / 143 total at the tested revision; 67 Groups contracts were server-only and exactly `synex.groups.self.snapshot` was `client-to-server` |
| Groups migration declaration | **PASS** — 30 files through ID `031`; ID `016` is intentionally absent |
| Complete repository suite | **PASS** — `npm run check`; `npm test` 668 total, 644 passed, 0 failed, 24 expected live-DB skips; security scan 174 files / 0 findings; `npm audit` 0 vulnerabilities |
| Real Groups Lua benchmark | **PASS** — all six production Lua hot paths completed within the declared local-regression thresholds |
| Separate live database suite | **PASS** — 96/96 passed, 0 failed, 0 skipped against disposable MariaDB |
| Isolated FXServer startup and runtime catalog | **PASS** — fresh Git-ignored local environment applied Core 27/27 and Groups 30/30 migrations (57/57 total); Core reached `READY`, both resources were `HEALTHY`, and Doctor returned `PASS` |
| Groups and Core restart recovery | **PASS** — Groups restart restored health with an advanced owner epoch; Core restart caused the expected dependency stop, and `ensure synex_groups` restored both resources to `HEALTHY` with Doctor `PASS` |
| FiveM client self-projection smoke | **NOT RUN** — no manual FiveM client test has run for the sole client-to-server Groups contract |
| Exact candidate and maturity decision | **PENDING** — review the final committed revision, then record the owner's explicit maturity/support/publication decision |

These results describe the uncommitted working tree exercised on 2026-08-25. They do not certify changed bytes in a later commit. The remaining technical smoke is one manual active-session and reconnect check of `synex.groups.self.snapshot`; the final committed candidate also needs diff/secret review and an explicit owner maturity/support/publication decision. The current evidence preserves **Experimental Alpha** only; it is not a Production-Beta, production-readiness, support, publication, or stable-contract decision.

## Current Accounts Alpha boundary

The current `synex_accounts` source is a server-only Experimental Alpha. Automated implementation is largely complete, but no production or runtime acceptance claim has been made.

| Gate | Current state |
| --- | --- |
| Working-tree automated gate | **PASS (2026-08-26)** — `npm run check`; focused Accounts 57/57; repository 707 passed, 0 failed, 28 expected live-DB skips out of 735; security 201 files / 0 findings; dependency audit 0 vulnerabilities |
| Focused Accounts suite | **IMPLEMENTED** — contract, policy, idempotency/access, lifecycle, observability, operator integration, upgrade-projection, persistence-boundary, runtime-module, and local hot-path tests are present |
| Source catalog | **IMPLEMENTED** — 59 experimental Accounts contracts; all declare `network: none` |
| Migration declaration | **IMPLEMENTED** — 17 ordered files through `017_idempotency_principal_scope` |
| Static/shared database regression | **IMPLEMENTED** — schema inventory and historical ledger/database cases are covered by repository tests |
| Dedicated disposable MariaDB candidate | **DEFERRED** — the exact 17-migration Accounts candidate has not completed its separate live gate; the new 100-spend, concurrent-hold, randomized-transfer, and commit/outbox-recovery cases were discovered but skipped because no disposable database URL was supplied |
| Isolated FXServer and workers | **DEFERRED** — service, Doctor, holds/outbox/retention/reconciliation workers still need real execution |
| Prepared/unplanned restart and recovery | **DEFERRED** — idempotency replay, in-flight recovery, dead outbox, expiry, and lifecycle cleanup still need runtime evidence |
| Restored-copy upgrade and rollback | **DEFERRED** |
| Exact candidate and maturity decision | **PENDING** — final diff/secret review and explicit owner decision |

Accounts has no client/NUI contract, so it does not need a direct Accounts client smoke. Any later `synex_banking` or gameplay consumer that exposes financial actions must receive its own hostile-client, join/reconnect, authorization, and NUI acceptance.

## Framework CI

[`framework-ci.yml`](../.github/workflows/framework-ci.yml) runs with read-only repository permissions, fully pinned official checkout/setup actions, Node.js 24, and `npm ci`. Its quality job verifies generated consistency, compiles TypeScript, validates manifests and schemas, executes every non-database test scope, runs compatibility and security analysis, certifies the repository, and audits the locked npm graph. Pull requests use the ordinary `pull_request` event; the workflow does not reference repository secrets or execute through `pull_request_target`.

After the quality job passes, a separate job starts an isolated MariaDB service, enables the destructive-test gate for its `synex_test_ci` schema, applies every currently owned migration, and checks live schema invariants. This repository-wide regression job includes experimental domain-resource migrations; it does not make those resources part of Core certification or broaden the default local test gate.

## Coverage present in the repository

| Suite | Verified behavior |
| --- | --- |
| `lua` | SHA-256, Cfx JSON containers with decoder-created metatables across persisted Saga redispatch, migration lease expiry during an in-flight statement with single execution and owner/token marker fencing, caller-/epoch-/ownership-bound Core DataPort validation and idempotent transaction receipts, coordinated domain-deletion provider/plan fencing, persisted source-generation seeding/exhaustion, boot-fenced session leases/inserts/status/cleanup, acquisition-unique runtime worker owners, failed-boot runtime-gate closure and owner/scheduler purge, cluster same-name duplicate handling, global/fixed-kind lease denial, existing-name cap bypass, unknown-name classification, drift/rollback protection and counter-releasing terminal compaction, synchronous connection quiesce, database-before-owner prepared-restart draining, restart-fenced remote controls, session-control exact/foreign replay at quota, global/requester denial, drift/overflow fail-closed behavior, atomic reservation rollback and fair exact terminal compaction, failed-cleanup admission closure, atomic bounded local session/admission authority cleanup, instance heartbeat status preservation and transient status-write recovery, single-pass queue arbitration with O(1) waiter state, exact queue-capacity boundary plus `QUEUE_FULL`, timeout cleanup and capacity reuse, immutable staff priority, reserved-slot skipping, grant timeout and quiesce races, maintenance gating, persistent RBAC, local and cross-instance character activation exclusion, both select/delete commit orders, source-generation and boot/lease swaps across character yields, required-participant compensation, fail-closed partial unload, soft-deleted slot reuse, character-deletion and unload-persistence reconciliation, non-destructive retention batches, owner cleanup/restarts, schema fuzzing, state authority, bounded pending diagnostics, dynamic admission/resource-health parity, operator commands, scheduler health, disconnect cleanup, and durable saga retry/deadline/compensation |
| `core` | bounded owner quiesce/drain, pending-operation abort, reconstructable state handoff, malformed/replayed snapshot rejection, and repeated same-core restarts |
| `stress` | 1,000 sequential session/index lifecycles through the Core registry implementation and 100,000 deterministic transfer commands through the experimental accounts validation path against an in-memory double-entry model, including nonnegative-total and idempotent-replay properties |
| `tooling` | deterministic multi-target generation, drift/version metadata, graph and unused-declaration analysis, diagnostics redaction, scaffolding, upgrade/certification artifacts, reload plans/adapters, executable fuzzing, benchmark labeling, and AST security findings |
| `database` | migration ordering/checksums/ownership, Core domain-receipt/deletion and Groups/Accounts/Entities schema invariants through their currently declared migrations, SQL/caller invariants, domain validation, archive-mirror constraints/no-source-delete guards, permanent-idempotency quota metadata/backfill and a gated exact-winner capacity race, retained session-control and cluster-lease all-state quota backfills, migration `026` owner-aware lease-index metadata, bounded local connection-authority recovery with unrelated-kind isolation and residual-phantom rollback, exact constraint/FK/generated-classifier/index metadata, malicious-check/classifier/unenforced-check rejection, terminal counter release, independent-connection Groups slug/create/rename approval races, Entity persistent-key/binding races and authority takeover fencing, a two-connection READ-COMMITTED same-name lease race, live DDL, parallel transfer/idempotency, migration statement/marker fencing across lease expiry, cluster lease fencing, and reconciled legacy import/replay |
| `groups` | organization and membership lifecycles, hierarchy/reporting cycle detection, deny-wins scoped capability composition, authorization preflight ordering and concealment, revision-keyed definition caching and metrics, stored and transition-policy gates, begin-per-epoch extension registries with stale-stop fencing, creation/deletion coordination, typed attribute scopes, runtime indices, contract/service/network boundaries, 30,000-byte response and contract page bounds, relationship/assignment/duty reads, relationship expiry, self projection, durable workflows, definition drift/reconciliation, persistence handlers, real-module headless performance paths, and additive Groups schema/ownership invariants; these protect the Experimental Alpha, not a release decision |
| `accounts` | 59 server-only contract and service declarations, principal-scoped idempotency, multi-account lock order, access/policy/restriction guards, lifecycle decisions, upgrade projections, bounded Doctor/control/transaction/account/outbox reads, economy aggregates, metrics and operator integration, server-only persistence boundaries, and schema ownership; these protect the Experimental Alpha, not runtime acceptance |
| `entities` | 33 server-only definitions / 32 names, closed/bounded schemas and exact public-error closure, four-migration/eight-table ownership, lease/recovery repositories, generation-fenced registry and spatial indexes, archetype/component/state ownership, spawn admission and routing policy, bounded/deduplicated cleanup retries with recycled-handle protection, NetID reuse defense, deterministic rate limiting, query/Doctor diagnostics, injectable database port, manifest/descriptor boundaries, stable-ID/bucket Control inspection, Core metric projection, and closed-state read-only NUI behavior; these protect the Development Alpha, not runtime acceptance |
| `compatibility` | caller-bound native bridge facades, bounded callback source/session fencing, balanced counterparty transfers, deterministic migration plans, bundle tamper checks, and import idempotency |
| `documentation` | local link targets, balanced Markdown/Mermaid fences, supported diagram roots, synchronized landing pages, pinned CI actions, manifest paths, and orphaned resource Lua detection |

The `groups`, `accounts`, `entities`, `control`, `compatibility`, shared `database`/`stress`, and SDK/tooling integration checks protect current source work. Groups has separate working-tree runtime evidence with remaining client/exact-candidate/owner gates. Accounts currently has automated implementation evidence only; its real database/server/restart/upgrade acceptance is deferred. Entities has repository evidence only; fresh MariaDB, FXServer/OneSync, restart/recovery and cluster gates remain open. Control has separate provider-runtime and real CEF client gates. Every non-Core pass remains regression evidence rather than a runtime support claim. See [Groups maturity and acceptance](groups/overview.md#maturity-and-acceptance), [Accounts testing boundary](reference/accounts.md#testing-and-acceptance-boundary), [Entity verification status](reference/entities.md#verification-status), and [Control Alpha boundary](#current-control-alpha-boundary).

Current-candidate coverage additionally exercises DataPort's per-key handler concurrency and late global/owner capacity locking; DomainDeletion's 10,000-global/1,000-requester all-state accounting, provider-schema upgrade/persistence guards, 30-day terminal replay window, and bounded compare-and-swap purge; and Groups' resumable generation-fenced registration, readiness barrier, scheduler-token cleanup, five-second retryable recovery, and non-retryable fail-closed path. The shared database-health tests distinguish synchronized healthy-probe reuse from confirmed-outage suspension. These cases are later-work regression evidence and do not rewrite the frozen Core Production-Beta results above.

## Live database gate

Database tests can create and mutate schema. They run only when both variables are set and the database name starts with `synex_test_`:

```text
SYNEX_TEST_DATABASE_LIVE=1
SYNEX_TEST_DATABASE_URL=mysql://...
```

Use only a disposable database. The test opens the configured schema, applies every current migration, inspects InnoDB/check/foreign-key/generated-column/index metadata, proves that migration `018` rejects a malformed marker without dropping the legacy key, and verifies the all-state migration `022` idempotency, `024` session-control, and `025` cluster-lease capacity backfills. It also verifies migration `026`, rejects a MariaDB `IGNORED` or MySQL `INVISIBLE` forced runtime index, and exercises the bounded owner-aware local connection-authority recovery path, including isolation from local Saga, character, and other leases plus fail-closed rollback when a residual phantom appears. It proves that weakened checks/classifiers and, on MySQL, a named `NOT ENFORCED` check are rejected, then checks soft-deleted character-slot reuse plus duplicate-active rejection. Independent connections exercise opposite-direction transfers, duplicate idempotency, an exact-winner namespace-capacity race, Entity persistent-key/binding uniqueness and expired authority takeover with stale-lease denial, the ordinary cluster-lease fence, and the READ-COMMITTED same-name row-first claim with exactly one counter charge. The suite also imports a unique synthetic reviewed plan and verifies native identities, experimental accounts/groups data, reconciliation, and no-write replay. It does not drop or reset a database for you. For the Core Production-Beta decision, evaluate the Core-owned migration and runtime evidence separately from these repository-wide rework checks.

GitHub Actions supplies an isolated MariaDB service and enables this gate. A normal local `npm test` skips the live case when the gate is closed; static migration tests still run.

## Static analysis boundaries

`npm run security` is a review aid. It identifies patterns with severity and confidence; it does not prove safety. `npm run certify` evaluates repository policy and produces PASS/WARN/FAIL findings; it is not a production guarantee. `npm run benchmark` is a local microbenchmark and must not be presented as FXServer or competitor performance evidence.

The Groups benchmark paths execute the actual Lua organization-read, membership-read, capability-evaluation, runtime-index online/on-duty, and stored-policy modules inside an embedded Wasmoon VM. Deterministic in-memory transaction adapters isolate module-regression cost; they deliberately exclude MariaDB I/O, FXServer/Cfx networking, OneSync scheduling, and production load. Reported timings are local comparison evidence only, never a server-capacity or competitor claim.

The Accounts benchmark paths execute the actual Lua balance, available-balance, access-check, transfer, multi-leg posting, hold-create, hold-capture, and reconciliation modules in the same embedded environment. Its deterministic in-memory adapter validates local module regressions and financial invariants only; it does not measure MariaDB locking, worker scheduling, FXServer/Cfx transport, or concurrent production load.

The Bridge benchmark paths execute actual compatibility-kernel DTO copying with the production projection and callback bounds, indexed account-mapping resolution, surface-policy resolution, and bounded telemetry aggregation. Fixed reviewed-format fixtures run in the embedded Wasmoon VM. The measurements exclude provider resources, historical facades, external framework runtimes, FXServer/Cfx transport, MariaDB, client callbacks, network latency, and production concurrency; they are local regression evidence only and cannot certify QB, QBX, or ESX compatibility.

## Coverage not present

The stress suite is a deterministic, sequential Wasmoon model. It does not run FXServer, OneSync/network scheduling, concurrent Lua threads, or the SQL ledger path, and its operation counts are not benchmark results.

The repository currently does not start FXServer in CI. There is no automated end-to-end Cfx client/server test, external-framework integration environment, browser automation run, production load test, or multi-instance `kick_old` requester-restart test. The final Core real-client smoke test was therefore manual. Groups still needs its self-projection client smoke. Accounts has no direct client surface, but its exact candidate still lacks disposable-MariaDB, FXServer, worker, prepared/unplanned restart, crash-recovery, and restored-upgrade evidence. Entities still needs a fresh execution of its gated MariaDB case plus real vehicle/ped/object OneSync lifecycle, resource/Core restart, live cluster/recovery-failure, bucket-player, NetID-reuse and Control CEF/client evidence. Multi-instance and alternate duplicate policies remain outside the supported Beta profile rather than being treated as accepted untested behavior.

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
> **Frozen Core status: PASS.** On 2026-08-25, one real FiveM client completed join, clean disconnect, reconnect, and final cleanup against the selected single-instance `deny_new` candidate. Both accepted connections completed all nine ordered connection stages; Core remained `READY`, Doctor returned `PASS`, and all 26 migrations were applied. This status does not cover current migration `027`, Groups, or Accounts.

The prepared-restart evidence included a pending connection blocked on database work. Preparation closed the normal database activity gate, waited for the tracked work to drain, and only then quiesced resource owners before using its private database control lane. It did not unload a live database callback.

The accepted run completed the following sequence. Repeat it after any change that invalidates the runtime evidence:

1. Start the server, wait for Core `READY`, then run `synex overview` and `synex doctor`. Core resource health must be `HEALTHY` and Doctor must not report `UNKNOWN` as a pass.
2. Join once without an immediate retry. One correlation ID must progress through `received`, `identity_ok`, `access_ok`, `lease_acquired`, `deferral_accepted`, `player_joining_received`, `join_identity_verified`, `join_lease_verified`, and `session_opened`, in that order.
3. Run `synex sessions`. The accepted attempt must no longer be pending and must own exactly one persisted session. No successful deferral may produce the generic Cfx `Unknown error` rejection.
4. Disconnect and confirm that the session closes, its network state is purged, and no active fenced session lease remains.
5. Reconnect once. Require a fresh session/source generation without `LEASE_BUSY`, a duplicate active session, or stale source authority.
6. Run `synex sessions` and `synex doctor` again. The accepted attempt must no longer be pending, exactly one new session may be active, and Core health must remain consistent.

After the final cleanup, the privacy-safe database aggregate was `3 / 0 / 0 / 0`: three retained closed sessions, zero open sessions, zero active session leases, and zero active admission leases. No raw player identity, source, session, or endpoint value is part of the retained acceptance record.

The more extensive aborted-deferral, repeated-retry, active-player restart, two-instance, soak, and load scenarios remain valuable later hardening work. They are not part of the frozen initial Production-Beta completion scope.

Connection-stage records intentionally contain a correlation ID, stage, elapsed time, and stable code only. Do not add raw identifiers, player names, source IDs, or database error text while collecting this evidence.
