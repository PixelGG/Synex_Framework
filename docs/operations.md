# Operations

Synex is fail-closed during boot. `synex_core` does not accept gated contract work until its lifecycle reaches `READY`.

## Boot sequence

The core loads configuration, applies supported ConVar overrides, validates runtime configuration and capability policy before database access, and configures the structured-log threshold. It then checks oxmysql, creates migration-control tables, acquires a fenced migration lease, discovers Synex manifests, applies forward-only migrations, validates generated contracts and declared service dependencies, registers core handlers, and transitions to `READY`.

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
| `synex access <userId> [limit]` | Restricted, console-only Cfx command | Bounded ban/allowlist history for one user; optional limit `1..64` per list |
| `synex ban` / `unban` / `allow` / `unallow` | Restricted, console-only Cfx commands | Audited mutation of Core-owned durable access records |
| `GetRuntimeStatus` | Caller-bound export with `synex.runtime.read` | Redacted lifecycle snapshot |
| `api.Runtime.getSnapshot()` | Caller-bound facade with `synex.runtime.read` | Runtime/resource/player/service/state summaries |
| `api.Runtime.getRetentionPolicy()` | Caller-bound facade with `synex.runtime.read` | Defensive copy of the effective audit/financial retention policy and worker bounds |
| `api.Metrics.getSnapshot()` | Caller-bound facade with `synex.metrics.read` | In-memory counters, gauges, and bounded histograms |
| `synex_control` | In-game read-only NUI | Sanitized Core and optional domain operational views plus exact audit search |

All existing diagnostic and mutation commands continue to emit structured JSON and reject player execution even when a Cfx command principal was misconfigured. `synex overview` is the single human-oriented exception and emits eight bounded `[synex]` lines without identifiers or payloads. `synex_status` and `synex_doctor` remain restricted aliases. Access mutations use an operator-supplied record ID, user ID where applicable, and bounded reason; quote multi-word reasons. `ban` and `allow` create records, while `unban` and `unallow` revoke an existing record by ID. The change and its before/after audit evidence share one transaction.

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

## Retention operations

The safe committed default is `retain_forever` for both Core audit and financial history; under that mode no retention archive worker is scheduled. Selecting `archive` schedules the owner-specific `core.retention.audit_archive` and/or `synex_accounts.retention.financial_archive` worker at the configured bounded interval. Workers copy only rows older than `archiveAfterDays`, use UTC database time, and process at most the configured batch size per run.

Archive mode is deliberately non-destructive. It creates idempotent mirror rows in `synex_audit_archive` or `synex_financial_transaction_archive` and reports `sourceRowsDeleted = 0`; it never deletes or mutates source audit or ledger history. Synex provides no purge command. Operators must capacity-plan both source and archive tables, protect the mirrors as sensitive data, monitor worker health, and define any legally required destruction process outside this automatic path. The effective read-only policy is available to reviewed resources through `api.Runtime.getRetentionPolicy()`.

## Degraded dependencies

- Core revalidates resource state, capability grants, service registration, provider health, and circuit state every five seconds. After kernel boot, an installed but stopped `critical` Synex resource is an error finding. A critical finding moves `READY` to `DEGRADED`; clearing every Core health reason restores `READY`. The refresh preserves each resource's lifecycle state while clearing dependency-owned health findings after recovery.
- Player admission is stricter than internal kernel availability: new connections are accepted only while Core is exactly `READY`, the post-boot critical-foundation validation has completed, and no Core health reason is present. `DEGRADED` remains available to server resources for diagnostics and recovery but never admits a player.
- Database errors return bounded `DATABASE_ERROR` results; persistent mutations must not report success.
- When durable events are enabled, Core and the groups/accounts domain workers process bounded outbox batches and report dispatch failures. Domain events are delivered at least once through the capability-gated outbox publication path; consumers deduplicate by stable event ID. Disabled Core outbox operations fail with `FEATURE_DISABLED`.
- The dependency-health worker reconciles the persisted Core instance status from effective lifecycle health: only healthy `READY` with open admission is `ready`; health reasons or blocked admission persist as `degraded`. Component callbacks update the in-memory lifecycle and registry immediately without adding a database write to every health signal. The Core instance heartbeat preserves that explicit status and may recover only a row another node marked `stale`; it cannot overwrite a concurrent `ready`/`degraded` update. Cluster session leases are renewed by heartbeat for authenticated pending connections and bound sessions. `playerJoining` revalidates the server-derived identifier fingerprint and fenced lease immediately before binding; losing ownership fails closed rather than allowing two authoritative sessions.
- `kick_old` replaces a local session only after the incoming connection passes every gate. For remote ownership it writes a bounded persisted control request for the owning instance, waits for that instance to close the old session and release its fenced lease, and rejects fail-closed when the handoff does not complete. `replace_old` remains a compatibility alias for this policy; no client-provided kick target is trusted.
- Source IDs are ephemeral. Async work must retain and revalidate the Synex source generation.
- Resource-stop cleanup is synchronous and owner-aware; handlers, subscriptions, services, state definitions, schedules, and pending ownership tokens are revoked by epoch.

Cfx stop handlers cannot guarantee completion of new asynchronous persistence work. Durable state must already be committed before acknowledging a mutation.

### Resource restart boundary in 0.1.0

When a non-Core resource stops, Synex marks its owner epoch as quiescing so new tracked operations fail. It waits for tracked work for at most 250 ms, aborts any remainder through registered abort callbacks, and then purges the epoch's handlers, subscriptions, services, state definitions, schedules, and facades.

A manifest with `stateSnapshot.supported: true` and `schemaVersion: 1` opts into a bounded same-Core handoff. At most 512 non-sensitive state values marked `persistent` are captured in a 64 KiB in-memory envelope and may be restored once into the next activated owner epoch after the resource starts and redefines them. Envelope, owner/epoch, schema, size, duplicate, and replay checks are fail-closed. This handoff is not database persistence, does not survive a `synex_core` restart, and is not a cross-version state migration.

Core shutdown uses immediate best-effort abort/purge and does not capture these handoffs. `synex dev reload` can calculate a dependency-ordered quiesce/drain/snapshot/reload/validate/restore plan and can submit each stage to an explicitly configured local or remote operator adapter. Synex does not ship a privileged FXServer restart endpoint, and the CLI cannot make arbitrary resources transactionally rollback-safe. Perform upgrades in a controlled maintenance window, commit durable state before acknowledging `QUIESCE`, and reacquire every facade/provider registration after start. See [Developer CLI](reference/cli.md).

## Backup and migration operations

Back up and test restore procedures before every deployment that introduces migration files. Never edit a migration already recorded in `synex_schema_migrations` or its attempt history; Synex will reject the checksum mismatch. Attempt state records `applying`, `applied`, or `failed` so an incomplete DDL run is visible on the next boot. See [Migrations](migrations.md).

## Production readiness gate

Before using `0.1.0` outside an isolated environment, operators must independently validate:

- exact FXServer, oxmysql, database, OneSync, and optional bridge versions;
- server-specific ACE and capability policy;
- migrations on a restored production-size copy;
- reconnect, source reuse, resource restart, database outage, and shutdown behavior;
- capacity and latency under the server's actual resources;
- retention, backup, privacy, and incident-response policy.

The repository contains headless and database tests, but no production certification claim.
