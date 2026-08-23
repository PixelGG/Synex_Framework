# Operations

Synex is fail-closed during boot. `synex_core` does not accept gated contract work until its lifecycle reaches `READY`.

## Boot sequence

The core loads configuration, applies supported ConVar overrides, validates runtime configuration and capability policy before database access, and configures the structured-log threshold. It then checks oxmysql, creates migration-control tables, acquires a fenced migration lease, discovers Synex manifests, applies forward-only migrations under per-migration owner/token fences, validates generated contracts and declared service dependencies, registers core handlers, and transitions to `READY`.

Every discovered `synex.resource.json` is also revalidated inside FXServer: closed objects/dense arrays, canonical versions and API ranges, capabilities, services, contracts, dependency classes, bounded migration IDs/paths without traversal or duplicates, declared table ownership, deletion policy, and snapshot schema `1`. A manifest that passed the Node.js schema gate but violates this runtime boundary still fails discovery.

The complete lifecycle and allowed transitions are documented in [Runtime model](architecture/runtime.md). A resource with a missing manifest, incompatible Synex API range, altered or inconsistent migration history, or an unresolved required service declaration can make boot fail.

## Health and diagnostics

| Surface | Access | Scope |
| --- | --- | --- |
| `synex overview` | Restricted, console-only Cfx command | Compact human-readable boot, database, resource, session, worker, cluster, and migration summary |
| `synex status` | Restricted, console-only Cfx command | Lifecycle, cluster, resource, session, and worker summary |
| `synex doctor` | Restricted, console-only Cfx command | Database, migration attempts, oxmysql, services, contracts, RBAC, and lifecycle checks |
| `synex resources` / `sessions` / `permissions` / `migrations` | Restricted, console-only Cfx commands | Bounded redacted operational read models |
| `synex trace <kind> <value> [limit]` | Restricted, console-only Cfx command | Exact audit search for `trace`, `character`, `transaction`, or `resource`; optional limit `1..64` |
| `synex ledger` / `entities` | Restricted, console-only Cfx commands | Read-only optional service summaries with explicit `NOT_INSTALLED`, `STOPPED`, `STARTING`, `DEGRADED`, or `HEALTHY` status |
| `synex prepare-restart` | Restricted, console-only Cfx command | Fail-closes admission, drains deferrals and owners, and closes current-boot durable authority before a planned Core restart |
| `synex access <userId> [limit]` | Restricted, console-only Cfx command | Bounded ban/allowlist history for one user; optional limit `1..64` per list |
| `synex ban` / `unban` / `allow` / `unallow` | Restricted, console-only Cfx commands | Audited mutation of Core-owned durable access records |
| `GetRuntimeStatus` | Caller-bound export with `synex.runtime.read` | Redacted lifecycle snapshot |
| `api.Runtime.getSnapshot()` | Caller-bound facade with `synex.runtime.read` | Runtime/resource/player/service/state summaries |
| `api.Runtime.getRetentionPolicy()` | Caller-bound facade with `synex.runtime.read` | Defensive copy of the effective audit/financial/session-control retention policy and worker bounds |
| `api.Metrics.getSnapshot()` | Caller-bound facade with `synex.metrics.read` | In-memory counters, gauges, and bounded histograms |
| `synex_control` | In-game read-only NUI | Sanitized Core and optional domain operational views plus exact audit search |

All existing diagnostic and mutation commands continue to emit structured JSON and reject player execution even when a Cfx command principal was misconfigured. `synex overview` is the single human-oriented exception and emits eight bounded `[synex]` lines without identifiers or payloads. `synex_status` and `synex_doctor` remain restricted aliases. `prepare-restart` is a one-way operational transition: after it begins, Core remains fail-closed until the resource is restarted. Access mutations use an operator-supplied record ID, user ID where applicable, and bounded reason; quote multi-word reasons. `ban` and `allow` create records, while `unban` and `unallow` revoke an existing record by ID. The change and its before/after audit evidence share one transaction.

Core health changes are synchronized into the resource registry through the lifecycle observer, including post-boot health reasons and admission changes. Only `READY` with player admission open and no health reasons is `HEALTHY`; blocked admission or degradation is `DEGRADED`, failed boot is `UNHEALTHY`, and `UNKNOWN` is never a Doctor pass. Resource counts in `status`, `resources`, `doctor`, and `overview` use the same registry semantics. Session summaries expose only bounded aggregates: pending count, expired count, and an oldest age capped at 600000 ms with an explicit cap marker.

```text
synex ban <id> <userId> <reason>
synex unban <id> <reason>
synex allow <id> <userId> <reason>
synex unallow <id> <reason>
synex access <userId> [limit]
```

The optional access limit is `1..64`.

The control plane is not a remote administration server; it has no state-changing NUI callback and no external HTTP API. See [Control plane](reference/control-plane.md).

## Logs and privacy

Core logs are JSON records with UTC timestamps and the configured minimum level. Keys associated with passwords, secrets, tokens, platform identifiers, licenses, authorization, Discord, and webhooks are redacted recursively. Slow and single-operation database records identify a statement by SHA-256 rather than deliberately logging its SQL. Transaction failures retain a classified driver detail; parameterized queries and secret-free SQL literals remain mandatory.

This redaction is defense in depth, not permission to log sensitive payloads. Resource authors should log references, result codes, and trace IDs rather than complete requests, identifiers, account metadata, or character data.

No call-home or external telemetry path is implemented. Metrics remain in process unless an operator builds a separate, explicitly authorized integration.

## Idempotency capacity

Core idempotency keys are permanent execution tombstones. Migration `022_idempotency_capacity` installs one database-authoritative capacity row plus derived owner and namespace counters. The committed defaults are 1,000,000 keys globally, 100,000 per owner, and 10,000 per namespace. Every `pending`, `completed`, and `failed` row counts. Response compaction may clear expired response JSON, but it never removes the namespace, key, request hash, terminal state, or capacity charge.

Claims lock and validate the global, owner, and namespace counters in that order before locking the exact key. An existing key is still hash-checked and can replay or return its permanent conflict/terminal result when a counter is at or above its limit. Only a previously absent key is denied with `IDEMPOTENCY_CAPACITY_EXCEEDED`. Missing, malformed, drifting, or overflowing authority fails closed with `IDEMPOTENCY_CAPACITY_INVALID`; do not bypass this by deleting tombstones or guessing counter values.

Monitor `synex_idempotency_capacity_entries`, `synex_idempotency_capacity_limit`, `synex_idempotency_capacity_utilization`, and the per-process `synex_idempotency_capacity_utilization_high_watermark` by the fixed `scope` label (`global`, `owner`, or `namespace`). The owner and namespace series intentionally contain no resource or namespace label and represent the last scope observed by a claim; their high-watermarks retain the highest ratio that process has observed without creating unbounded metric cardinality. Alert before exhaustion—for example at sustained utilization of 0.80 and again at 0.90—and alert immediately on `synex_idempotency_capacity_denials_total{scope="integrity"}` or sustained capacity denials. Use database size and key-ingress trends alongside these gauges when forecasting storage.

Limits are uniform cluster policy stored only in `synex_idempotency_capacity`; do not add per-instance overrides. To raise them, first back up and test the change, choose values within unsigned-`INT` range, preserve `namespace_limit <= owner_limit <= global_limit`, and update the singleton in one operator transaction:

```sql
START TRANSACTION;
SELECT entry_count, global_limit, owner_limit, namespace_limit
FROM synex_idempotency_capacity
WHERE singleton_id = 1
FOR UPDATE;

UPDATE synex_idempotency_capacity
SET global_limit = 2000000,
    owner_limit = 200000,
    namespace_limit = 20000
WHERE singleton_id = 1;
COMMIT;
```

The numbers above illustrate a proportional raise; calculate production values from the observed ingress and storage budget. Verify the stored row and capacity metrics afterward. If a counter-integrity denial occurs, stop every Core instance and reconcile against a restored/tested copy of all `synex_idempotency_keys`; never delete or expire keys to recover capacity, and never lower a limit below current use without accepting that all new keys in that scope will remain denied.

## Session-control capacity and retention

Migration `024_session_control_capacity` installs a cluster-wide retained-row counter and one counter per `requested_by_instance_id`. The committed limits are 100,000 rows globally and 10,000 per requester. Every persisted `pending`, `completed`, and `expired` request counts until terminal retention deletes it. Existing counts above either limit are valid state: an exact valid pending request can still be refreshed or replayed, but an absent request is denied until compaction drains capacity or an operator deliberately raises the limit. Core never raises limits automatically.

Issuance locks admission authority, the target session and exact pending identity, the global counter, and requester counters in stable ID order. A valid pending request owned by another current requester is replayed without rebinding it or charging capacity again. A stale or invalid pending request is terminalized first; any replacement is then subject to both quotas. Missing counters, malformed values, impossible relationships, unsigned overflow, or non-exact compare-and-swap results fail closed with `SESSION_CONTROL_CAPACITY_INVALID`. Exhaustion returns `SESSION_CONTROL_CAPACITY_EXCEEDED` with only the fixed `global` or `requester` scope.

Monitor `synex_session_control_capacity_entries`, `synex_session_control_capacity_limit`, `synex_session_control_capacity_utilization`, and `synex_session_control_capacity_utilization_high_watermark` by the fixed `scope` label (`global` or `requester`). Requester metrics intentionally expose no instance ID. Alert before sustained exhaustion and on `synex_session_control_capacity_denials_total` for either `scope="global"` or `scope="requester"`; any `scope="integrity"` event is an immediate stop-and-reconcile condition. The retention worker exposes `synex_session_control_compaction_runs_total` with fixed `state` (`completed` or `expired`) and `result` (`completed` or `failed`) labels plus `synex_session_control_compacted_rows_total` with the same fixed states. A rising utilization high-watermark with no successful compaction, repeated capacity denials, or a failed queue are operationally blocked states.

Limits live only in `synex_session_control_capacity`. Back up and test first, keep both values inside unsigned-`INT`, preserve `requester_limit <= global_limit`, and make a reviewed raise under the singleton lock. This example doubles the committed defaults; replace both expected and target values with the reviewed production values:

```sql
START TRANSACTION;
SELECT entry_count, global_limit, requester_limit
FROM synex_session_control_capacity
WHERE singleton_id = 1
FOR UPDATE;

UPDATE synex_session_control_capacity
SET global_limit = 200000,
    requester_limit = 20000
WHERE singleton_id = 1
  AND global_limit = 100000
  AND requester_limit = 10000;
SELECT ROW_COUNT() AS exactly_one_limit_row_updated;
COMMIT;
```

Require the update count to be exactly one and verify the stored row and metrics before reopening admission. Lowering a limit below current use is allowed by design but blocks only new requests until drain; it does not discard existing controls. Never edit counters, delete pending rows, or purge terminal rows manually to recover capacity. On integrity denial, stop all Core writers and reconcile exact all-state `COUNT(*)`/`GROUP BY requested_by_instance_id` results on a restored copy before applying a reviewed forward repair.

`core.session_controls.compact_terminal` alternates the ordered `completed` and `expired` queues. It deletes only rows with `completed_at` at or before the configured `retention.sessionControlAfterDays` cutoff, removes the exact authority child before its parent, and releases both counters in the same transaction. A pending row is never deleted, even if `expires_at` has elapsed; existing authority maintenance must terminalize it first. Legacy terminal parents without an authority child are counted explicitly and may be removed only after the same state/cutoff validation. After this grace, control rows are ephemeral operational coordination state rather than audit history. Generated request IDs are never reused; retain separate immutable audit evidence when longer operational history is required.

## Cluster-lease capacity

Migration `025_cluster_lease_capacity` makes every retained cluster-lease row capacity-authoritative except the exact `schema_migrations` bootstrap lease. The committed defaults are 1,000,000 rows globally, 500,000 for `session`, 250,000 each for `admission` and `saga`, and 100,000 each for `character` and `other`. Active, expired, retired, and terminal rows all remain charged until exact terminal compaction deletes them. Existing counts above policy are valid; Core permits an existing lease name to renew, reacquire, or return `LEASE_BUSY` without another charge, while an absent name remains blocked until drain or a reviewed raise. Limits are never raised automatically.

Acquisition locks boot/domain authority and the exact name first. An absent name is provisionally inserted before capacity locks; a concurrent duplicate is reread under lock and follows the existing-name path. Only the transaction that created a non-migration name then locks global and fixed-kind authority, increments both counters with exact compare-and-swap updates, verifies the lease, and commits. Capacity exhaustion is retryable `LEASE_CAPACITY_EXCEEDED` with a fixed `global`, `session`, `admission`, `saga`, `character`, or `other` scope. Missing/malformed counters, impossible relationships, overflow, unexpected affected-row counts, or classifier drift fail closed with `LEASE_CAPACITY_INVALID`. The provisional row and every partial counter update roll back together.

The existing five-second lease cycle first terminalizes eligible expired session/admission authority. `core.leases.compact_terminal` then locks at most 250 ordered terminal rows, locks global and affected kind counters in stable order, exact-deletes only rows still terminal, and decrements every counter in the same transaction. It never deletes a merely expired active row and cannot select `schema_migrations`. Do not manually delete lease rows or edit counters; that creates integrity drift.

Monitor `synex_cluster_lease_capacity_entries`, `synex_cluster_lease_capacity_limit`, `synex_cluster_lease_capacity_utilization`, and the per-process `synex_cluster_lease_capacity_utilization_high_watermark` by the fixed `scope` labels `global`, `session`, `admission`, `saga`, `character`, and `other`. Alert before sustained exhaustion and on `synex_cluster_lease_capacity_denials_total`; `scope="integrity"` is an immediate stop-and-reconcile condition. `synex_cluster_lease_compaction_total` uses only fixed `result="complete"` or `result="failed"` labels. These metrics remain in process unless an operator provides an approved exporter.

Limits live in the two 025 authority tables. Back up and test first, keep every value inside unsigned-`INT`, and keep each kind limit at or below the global limit. Lock global before all kinds, inspect current use, then apply reviewed policy in one transaction. This example doubles the committed defaults:

```sql
START TRANSACTION;
SELECT entry_count, global_limit
FROM synex_cluster_lease_capacity
WHERE singleton_id = 1
FOR UPDATE;

SELECT lease_capacity_kind, entry_count, kind_limit
FROM synex_cluster_lease_kind_capacity
ORDER BY lease_capacity_kind
FOR UPDATE;

UPDATE synex_cluster_lease_capacity
SET global_limit = 2000000
WHERE singleton_id = 1 AND global_limit = 1000000;
SELECT ROW_COUNT() AS exactly_one_global_limit_updated;

UPDATE synex_cluster_lease_kind_capacity
SET kind_limit = CASE lease_capacity_kind
    WHEN 'session' THEN 1000000
    WHEN 'admission' THEN 500000
    WHEN 'saga' THEN 500000
    WHEN 'character' THEN 200000
    WHEN 'other' THEN 200000
END
WHERE (lease_capacity_kind = 'session' AND kind_limit = 500000)
   OR (lease_capacity_kind IN ('admission', 'saga') AND kind_limit = 250000)
   OR (lease_capacity_kind IN ('character', 'other') AND kind_limit = 100000);
SELECT ROW_COUNT() AS exactly_five_kind_limits_updated;
COMMIT;
```

Require update counts of exactly one and five and verify stored limits plus metrics before reopening admission. Lowering a limit below current use is allowed but blocks only absent names until terminal drain. On an integrity denial, stop every Core writer and compactor, compare exact non-`NULL` `lease_capacity_kind` counts and grouped counts against both authority tables on a restored/tested copy, and ship a reviewed forward repair. Never repair by deleting retained rows, rewriting counters ad hoc, or exempting another lease name. The `schema_migrations` exception is exact and exists only so migration bootstrap can run before 025 creates its own capacity tables.

## Retention operations

The safe committed default is `retain_forever` for both Core audit and financial history; under that mode no retention archive worker is scheduled. Selecting `archive` schedules the owner-specific `core.retention.audit_archive` and/or `synex_accounts.retention.financial_archive` worker at the configured bounded interval. Workers copy only rows older than `archiveAfterDays`, use UTC database time, and process at most the configured batch size per run.

Archive mode is deliberately non-destructive. It creates idempotent mirror rows in `synex_audit_archive` or `synex_financial_transaction_archive` and reports `sourceRowsDeleted = 0`. Core sets only the indexed `archive_recorded_at` checkpoint after the matching audit mirror exists in the same transaction; audit evidence and ledger history are never rewritten or deleted. Synex provides no purge command. Operators must capacity-plan both source and archive tables, protect the mirrors as sensitive data, monitor worker health, and define any legally required destruction process outside this automatic path. The effective read-only policy is available to reviewed resources through `api.Runtime.getRetentionPolicy()`.

## Degraded dependencies

- Core revalidates resource state, capability grants, service registration, provider health, and circuit state every five seconds. After kernel boot, an installed but stopped `critical` Synex resource is an error finding. A critical finding moves `READY` to `DEGRADED`; clearing every Core health reason restores `READY`. The refresh preserves each resource's lifecycle state while clearing dependency-owned health findings after recovery.
- Player admission is stricter than internal kernel availability: new connections are accepted only while Core is exactly `READY`, the post-boot critical-foundation validation has completed, and no Core health reason is present. `DEGRADED` remains available to server resources for diagnostics and recovery but never admits a player.
- Database errors return bounded `DATABASE_ERROR` results; persistent mutations must not report success.
- When durable events are enabled, Core and the groups/accounts domain workers process bounded outbox batches and report dispatch failures. Domain events are delivered at least once through the capability-gated outbox publication path; consumers deduplicate by stable event ID. Generic Core outbox delivery retains the original producer and rechecks that producer's current epoch and manifest declaration. Legacy rows without `producer_resource`, stopped producers, and revoked declarations retry and eventually dead-letter instead of inheriting Core authority. Disabled Core outbox operations fail with `FEATURE_DISABLED`.
- The bounded `core.idempotency.compact_expired` worker runs at the configured retention interval. It reads only expired completed rows whose indexed `response_compaction_at` eligibility marker is still `NULL`, then clears response JSON and records that marker atomically. Already-empty historical rows are outside the queue; namespace/key/request-hash tombstones remain durable, and pending or indeterminate execution records are never deleted or reclaimed automatically.
- The bounded `core.outbox.compact_terminal` worker uses separate ordered range queues for `published` and `dead` generic Core-outbox rows after their independently configured age windows. It rotates which queue receives the first chance even when the shared batch maximum is one. Event/producer/aggregate identity, attempts, terminal timestamps, and `last_error_code` remain available for operations; only payload/header JSON and `payload_compacted_at` change, while `pending` and `publishing` rows never enter either queue.
- The bounded `core.session_controls.compact_terminal` worker fairly alternates the indexed `completed` and `expired` queues under the shared retention batch maximum. It deletes only deterministic terminal rows past `sessionControlAfterDays` and atomically releases their global/requester capacity. Elapsed pending rows remain untouched until authority maintenance terminalizes them.
- Saga recovery rotates `pending`, `running`, and `compensating` states. Each state scan is an exact indexed keyset window bounded by a cycle high-watermark; selector matching occurs only over that bounded result. A cursor advances only through rows actually inspected, and every finite cycle wraps independently of later inserts, so deferred, lease-busy, or poisoned work cannot permanently pin the oldest page or starve another active state when the dispatch maximum is one. A saga stores at most 2,048 step events; both public and runtime append paths reject the next event before inserting history or changing state/version.
- The lease-maintenance cycle runs every five seconds. It first alternates a bounded indexed recovery scan between expired `session:` and `admission:` authority and retires only rows whose generated authority kind, expiry, and marker are still unchanged under lock. Exact reacquire clears the marker before new authority becomes valid. `core.leases.compact_terminal` then deletes at most 250 rows from the ordered `terminal_compaction_at` queue. Saga/deletion terminal transitions and exact session/admission release populate that queue transactionally; migration, active-domain, unknown, and generic expired leases never enter it. Terminal domain IDs remain durable and cannot reacquire a lease, preserving ABA protection after the retired lease row is removed.
- The bounded `core.state.replication_cleanup` worker retries failed global/player state-bag clears and failed remote compensation after a rolled-back snapshot restore. Cleanup tombstones remain accounted but are hidden from reads and state handoff, are generation-fenced for player sources, and are removed only after replication succeeds, the exact old player generation is gone, or a newer write safely supersedes the cleanup token. Restore compensation is deduplicated and separately bounded by entry and payload-byte caps. Poison entries rotate behind other work instead of blocking either queue.
- The dependency-health worker reconciles the persisted Core instance status from effective lifecycle health: only healthy `READY` with open admission is `ready`; health reasons or blocked admission persist as `degraded`. Component callbacks update the in-memory lifecycle and registry immediately without adding a database write to every health signal. The Core instance heartbeat preserves that explicit status under the current boot claim and may recover only a row another node marked `stale`; it cannot overwrite a concurrent `ready`/`degraded` update. Stale-instance, stale-session, and elapsed-control catch-up writes each process at most `retention.batchSize` deterministic rows per tick. Invalid pending-control authority is audited through a separate bounded `(state, request_id)` cursor page that advances only after a validated mutation and wraps at the end. Instance and pending-control diagnostic summaries inspect at most `batchSize + 1` rows and expose truncation instead of issuing exact full-table counts. Cluster session leases are acquired and renewed only for the current boot and are refreshed by heartbeat for authenticated pending connections and bound sessions. Each success publishes a conservative monotonic deadline measured from the attempt start; public player/state/RPC access rejects an expired local snapshot before heartbeat cleanup. Lease loss synchronously detaches the exact raw source generation, excludes it from durable touch, and retains bounded close reconciliation until the durable session is closed. A rejected or throwing native disconnect is retried through a bounded exact-generation queue; binding or admitting a replacement on that source cancels the stale retry before another drop. `playerJoining` revalidates the server-derived identifier fingerprint and both fenced lease deadlines immediately before binding and publication.
- `kick_old` replaces a local session only after the incoming connection passes every gate. For remote ownership it writes a bounded persisted control request for the owning instance, waits for that instance to close the old session and release its fenced lease, and rejects fail-closed when the handoff does not complete. `replace_old` remains a compatibility alias for this policy; no client-provided kick target is trusted.
- Source IDs are ephemeral. Async work must retain and revalidate the Synex source generation.
- Non-Core resource-stop cleanup is owner-aware; handlers, subscriptions, services, state definitions, schedules, and pending ownership tokens are revoked by epoch while `synex_core` remains available to execute the bounded drain.

Cfx does not keep a stopping resource alive for yielded continuations. The Core's own `onResourceStop` handler therefore performs only synchronous in-memory/native fencing and never claims completion of a tick wait, database write, lease release, or owner callback. Durable state must already be committed before acknowledging a mutation.

### Resource restart boundary in 0.1.0

When a non-Core resource stops, Synex marks its owner epoch as quiescing so new tracked operations fail. It waits for tracked work for at most 250 ms, aborts any remainder through registered abort callbacks, and then purges the epoch's handlers, subscriptions, services, state definitions, schedules, and facades.

A manifest with `stateSnapshot.supported: true` and `schemaVersion: 1` opts into a bounded same-Core handoff. At most 512 non-sensitive state values marked `persistent` are captured in a 64 KiB in-memory envelope and may be restored once after the resource starts and redefines them. The Core retains a claimable envelope until restoration succeeds, retries transient definition/replication races at most eight times within a bounded sub-second window, and quarantines terminal failures while marking the resource degraded. A stop that wins before the queued restore callback invalidates that claim and carries the same envelope to the next owner epoch; stale callbacks cannot consume it. Discovery failures likewise leave it pending. Envelope, owner/epoch, schema, size, duplicate, and replay checks are fail-closed. This handoff is not database persistence, does not survive a `synex_core` restart, and is not a cross-version state migration.

For a planned Core restart, first run `synex prepare-restart` while the resource is still started. The command synchronously closes the external runtime gate and admission, invalidates join claims, removes pending/queued authority, and evicts the captured players. It can then yield one mandatory deferral tick, flush the captured terminal set, persist `stopping`, release captured leases best-effort, drain/purge owners, and atomically expire current-boot session leases and pending controls while closing local durable sessions. It reports `state = "prepared"` and `restartCommand = "restart synex_core"` only after the instance is persisted as `stopped`. Execute that restart command only after the prepared result is printed. A failed preparation leaves the runtime fail-closed; inspect the stable error, retry preparation where appropriate, or perform recovery through the next boot.

A direct `stop`, `restart`, `ensure`, process exit, or crash can bypass that preparation. The raw Core stop handler closes the runtime gate and admission, quiesces connection authority, evicts the current player snapshot, finalizes only deferrals whose previous tick is already certified, clears cached facades, and returns without yielding. Deferrals still awaiting a mandatory tick are left to Cfx resource teardown. It performs no oxmysql call and makes no durable-cleanup claim. The next Core boot registers a fresh boot ID under a database lock and performs the boot-fenced session/lease/control cleanup before admission opens; a stop without a subsequent boot remains dependent on existing lease expiry and cluster stale-instance handling.

On Core boot, residual players are evicted and the stable instance is atomically registered as `starting` with a fresh boot ID before the durable authority cleanup barrier runs. Core then loads the maximum persisted source generation for that instance and seeds the empty runtime registry so a reused Cfx source cannot collide with a prior boot. The external runtime gate and player admission remain closed until every final boot write succeeds. A late failure closes that gate before connection quiesce and owner purge, rejects new export/facade work with `CORE_FAILED`, moves the lifecycle to `FAILED`, and leaves the persisted instance non-ready. Session leases and remote controls are bound to the current boot claim. The migration worker uses a restart-unique owner; each saga and character-deletion acquisition uses a unique owner plus the current boot claim. Players must reconnect through the normal admission pipeline. Neither raw stop nor prepared restart captures state-handoff envelopes.

`synex dev reload` can calculate a dependency-ordered quiesce/drain/snapshot/reload/validate/restore plan and can submit each stage to an explicitly configured local or remote operator adapter. Synex does not ship a privileged FXServer restart endpoint, and the CLI cannot make arbitrary resources transactionally rollback-safe. Perform upgrades in a controlled maintenance window, commit durable state before acknowledging `QUIESCE`, and reacquire every facade/provider registration after start. See [Developer CLI](reference/cli.md).

## Backup and migration operations

The first rollout that introduces migrations `011_instance_boot_authority`, `012_session_control_boot_authority`, and `013_migration_fencing` must be a coordinated cluster maintenance deployment. Close player admission on every instance, stop every pre-upgrade `synex_core`, and wait for its oxmysql work and open transactions to drain before starting any upgraded instance. Do not run mixed pre-fence and fenced Core versions: SQL already submitted by the older code cannot be retroactively given a boot or migration claim.

Apply the same full-stop rule for the first rollout of `016_rbac_policy_revision`. A pre-`016` runtime can redefine a role without advancing the cluster policy revision, which would make its change invisible to upgraded instances. Start upgraded instances only after all older Core processes and their outstanding database work have stopped.

Migration `017_runtime_scalability` adds the indexed boot/session lookups, durable-lease domain discriminator, and audit archive checkpoint required by the bounded runtime paths. Deploy it in the same full-stop window: the upgraded runtime must not start before `017` has completed, and an older archive worker must not overlap the checkpointed worker. The migration performs metadata-guarded DDL and requires the routine/alter privileges described in [Migrations](migrations.md).

Migrations `018_character_slot_reuse`, `019_session_control_target_authority`, and `020_terminal_lease_eligibility` are part of the same full-stop Core upgrade. `018` changes active-slot uniqueness, `019` backfills mandatory target-instance authority and bounded control indexes, and `020` backfills the terminal lease queue plus the bounded open-character and open-user session indexes. Do not overlap old workers with these backfills or start upgraded admission before all three metadata-guarded procedures have completed and been verified.

Migration `021_worker_queue_scalability` is also a full-stop Core upgrade. It adds the saga cursor index, two terminal-outbox range indexes, and the idempotency response-eligibility marker/index; its one-time backfill marks existing empty completed responses as already compacted. Stop old saga and retention workers, drain their database work, apply and verify `021`, and only then start the upgraded Core. Mixed pre-/post-`021` workers are unsupported.

Migration `022_idempotency_capacity` requires the same full-stop boundary. It counts every existing permanent Core idempotency key into new global, owner, and namespace authority rows. Existing counts may already exceed a committed limit; the migration preserves them and the upgraded runtime permits exact-key replay/conflict while denying only new keys. Stop every older Core writer, drain oxmysql transactions, apply and metadata-verify `022`, and start only upgraded instances. A mixed deployment can insert a key without charging the counters and is unsupported. Do not reopen admission after a failed backfill or reconciliation check.

Migration `023_lease_authority_recovery` must be applied in that full-stop window after `022`. It installs the exact generated session/admission lease discriminator, the bounded expired-authority queue, and the stale open-session heartbeat index. Older runtimes neither maintain the recovery marker lifecycle nor use these verified queues, so stop all old Core instances, drain oxmysql work, apply and metadata-verify `023`, and only then start upgraded instances. A failed generated-expression or index check keeps admission closed.

Migration `024_session_control_capacity` is another full-stop Core upgrade. It counts every pending and terminal session-control request into the new global/requester authority, verifies the exact constraint/FK/index definitions, and installs the terminal retention queue. Stop every pre-`024` Core and drain its transactions before the backfill; an older issuer can otherwise create an uncharged request and an older worker can race retention. Counts above the configured limits are preserved, but new absent requests remain blocked until drain or a controlled raise. Do not reopen admission after any metadata, overflow, or reconciliation failure.

Migration `025_cluster_lease_capacity` must follow `024` under the same full-stop boundary. It classifies and counts every retained cluster lease except exact `schema_migrations`, installs global/fixed-kind authority, and makes terminal compaction release those counters. Stop every pre-`025` Core and drain its oxmysql work before applying and verifying the migration. Mixed writers are unsupported: an older acquirer can create an uncharged row and an older compactor can delete a charged row. Do not reopen admission after a classifier, check-enforcement, overflow, or reconciliation failure.

If startup reports `MIGRATION_INDETERMINATE` or loses its migration lease after submitting a statement, leave the affected fence intact and keep every Core instance stopped. The block means the database outcome cannot be proven from the adapter response. Inspect the exact statement boundary against a restored/tested copy and use the operator's backup/recovery procedure; deleting the attempt or fence and restarting can execute an already-applied DDL statement again.

Back up and test restore procedures before every deployment that introduces migration files. Never edit a migration already recorded in `synex_schema_migrations` or its attempt history; Synex rejects checksum mismatches except for the one exact, registered metadata-only correction to `synex_core/021_worker_queue_scalability`. That correction is accepted only when its earlier checksum already has an authoritative applied marker. A marker-less, `applying`, legacy `failed`, or `indeterminate` earlier `021` remains fail-closed and requires operator reconciliation rather than automatic retry. See [Migrations](migrations.md).

## Production readiness gate

Before using `0.1.0` outside an isolated environment, operators must independently validate:

- exact FXServer, oxmysql, database, OneSync, and optional bridge versions;
- server-specific ACE and capability policy;
- migrations on a restored production-size copy;
- reconnect, source reuse, resource restart, database outage, and shutdown behavior;
- capacity and latency under the server's actual resources;
- retention, backup, privacy, and incident-response policy.

The repository contains headless and database tests, but no production certification claim.
