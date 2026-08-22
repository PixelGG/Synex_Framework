# Configuration

Synex currently loads two committed JSON files from `synex_core`:

- [`config/default.json`](../core/synex_core/config/default.json) contains runtime defaults.
- [`config/capabilities.json`](../core/synex_core/config/capabilities.json) contains resource capability grants and denies.

Their canonical Draft 2020-12 schemas are [`config.schema.json`](../schemas/config.schema.json) and [`capability-policy.schema.json`](../schemas/capability-policy.schema.json). `npm run validate` compiles both with Ajv and applies cross-field rules for query warning/timeout, RPC timeout, session heartbeat/lease, queue update/timeout, and reserved-slot capacity.

FXServer does not embed Ajv. At runtime, `synex_core` validates committed defaults, applies the supported ConVar overrides, and validates the effective configuration again with the same closed shapes, types, ranges, capability-pattern rules, and cross-field constraints. Both files are validated before persistence is constructed or any database query runs. Unknown keys, malformed grant arrays, duplicate capabilities, and invalid effective ConVar values fail boot. Synex `0.1.0` has no layered environment-file loader.

## Runtime ConVars

Only these Synex ConVars are read by the current core:

| ConVar | Default | Current behavior |
| --- | --- | --- |
| `synex_instance_id` | empty | Required in strict production mode; seeds instance-scoped IDs and cluster lease ownership |
| `synex_environment` | `production` | Reported in runtime snapshots; controls the strict-production instance-ID check |
| `synex_strict` | `1` | Enables the strict-production instance-ID requirement |
| `synex_instance_name` | effective instance ID | Bounded operator-facing cluster instance name |
| `synex_duplicate_policy` | `deny_new` | `deny_new`, `kick_old`, or isolated multi-session `allow`; `replace_old` remains a compatibility alias for `kick_old` |
| `synex_queue_reserved_slots` | `0` | Preserves capacity for ACE-authorized staff, always below the active-session limit |
| `synex_queue_staff_priority` | `1000` | Queue priority added for `synex_queue_staff_ace` |
| `synex_queue_reconnect_priority` | `500` | Queue priority added during the bounded reconnect grace window |
| `synex_queue_reconnect_grace_ms` | `60000` | Reconnect priority lifetime; `0` disables it |
| `synex_queue_staff_ace` | `synex.queue.staff` | ACE used for staff priority and reserved-slot admission |
| `synex_maintenance` | `0` | Rejects new connections unless the maintenance-bypass ACE is present |
| `synex_maintenance_message` | `Synex is currently in maintenance mode.` | Bounded rejection text shown during maintenance |
| `synex_maintenance_bypass_ace` | `synex.maintenance.bypass` | ACE that bypasses maintenance and receives staff admission treatment |

An empty instance ID is allowed outside strict production and produces an ephemeral value plus a warning. Use a stable unique value for each production instance.

Database credentials belong to the database adapter's secure runtime configuration, not to these files.

The accounting concurrency model expects the oxmysql ConVar `mysql_transaction_isolation_level` to be `2` (`READ COMMITTED`). This is an operator setting, not a Synex setting, and Core does not override it. `synex doctor` reports the current Cfx ConVar and fails the isolation check unless its exact value is `2`. Set it before oxmysql starts and restart the adapter after changing it: a later ConVar read does not prove what existing pooled connections previously applied, nor the state of an arbitrary independent database session.

## Active default sections

| Section | Wired settings |
| --- | --- |
| `database` | minimum oxmysql version, slow-query warning threshold, bounded deadlock retry count, migration lease duration |
| `connections` | pending TTL, gate timeout, cluster-aware duplicate policy, allowlist switch, session lease/heartbeat, bounded queue priorities and reconnect grace, reserved slots, maintenance admission, and active-session bound |
| `rpc` | timeout, pending-per-source bound, encoded payload bound, token-bucket rate and burst |
| `logging` | structured-log threshold; `pretty` must remain `false` |
| `retention` | bounded audit and financial retention policies, archive cadence, and batch size |
| `features` | durable outbox operations/worker, saga operations, and global/player state replication |

The current runtime does not enforce `database.queryTimeoutMs` through its generic adapter. Batch and interactive transactions use `database.deadlockRetries` only for recognized deadlock signals (`1213`, SQLSTATE `40001`, or a deadlock diagnostic), with the configured bounded retry count and wait.

`connections.duplicatePolicy` is cluster-aware. `deny_new` rejects an existing local session or active remote authority. `kick_old` (and the deprecated `replace_old` alias) completes connection gates, cleans up local authority, requests a bounded persisted kick from the remote owning instance when necessary, waits for the fenced session lease, and rejects fail-closed if ownership cannot be transferred. `allow` uses a session-specific lease and permits isolated concurrent sessions. Remote control requests are consumed by the owning instance heartbeat worker; no client-provided identifier or kick target is trusted.

Setting `features.durableEvents` to `false` prevents outbox enqueue/dispatch and omits the worker schedule. Setting `features.sagas` to `false` rejects saga mutations. Setting `features.stateReplication` to `false` rejects replicated state definitions while leaving non-replicated owned state available. Each path returns `FEATURE_DISABLED` rather than silently running a partial implementation.

## Retention policy

Retention is configured only in `config/default.json`; there is no retention ConVar in `0.1.0`.

| Setting | Default | Accepted value | Runtime effect |
| --- | ---: | --- | --- |
| `retention.workerIntervalMs` | `3600000` | integer `60000..86400000` | Schedule interval for each enabled owner-specific archive worker |
| `retention.batchSize` | `250` | integer `1..1000` | Maximum source rows copied by one worker run |
| `retention.audit.mode` | `retain_forever` | `retain_forever` or `archive` | Enables Core's audit archive mirror only in `archive` mode |
| `retention.audit.archiveAfterDays` | `365` | integer `1..36500` | Minimum source-row age for the audit mirror when enabled |
| `retention.financial.mode` | `retain_forever` | `retain_forever` or `archive` | Enables the accounts financial archive mirror only in `archive` mode |
| `retention.financial.archiveAfterDays` | `365` | integer `1..36500` | Minimum source-transaction age for the financial mirror when enabled |

The safe committed defaults schedule no archive worker. In `archive` mode, `core.retention.audit_archive` copies eligible Core audit rows into `synex_audit_archive`, while `synex_accounts.retention.financial_archive` copies a self-contained transaction/posting projection into `synex_financial_transaction_archive`. Both use bounded, idempotent `INSERT IGNORE` batches and UTC database time. They never delete or mutate source audit, transaction, posting, snapshot, operation, or account rows; archive mode therefore creates another durable copy and does not reclaim storage.

Reviewed server resources with `synex.runtime.read` can obtain a defensive copy of the effective `{ audit, financial, workerIntervalMs, batchSize }` policy through `api.Runtime.getRetentionPolicy()`. It is a read surface, not a retention mutation or purge API. Changes require the same controlled Core restart as other settings.

`events.maximumQueueDepth` and the two `privacy` fields are schema-validated but remain reserved in `0.1.0`; event queue sizing is internal, and `privacy.identifierSaltConvar` is not consumed by the runtime. A valid reserved setting is not evidence that its intended behavior is active.

## Capability policy

A resource must both declare a requested capability in `synex.resource.json` and receive a matching operator grant. Denies win over allows.

```json
{
  "resources": {
    "synex_example": {
      "allow": ["synex.runtime.read"],
      "deny": []
    }
  }
}
```

Wildcard grants have a segment boundary: `synex.groups.*` matches descendants of `synex.groups`, not arbitrary prefixes. High-impact defaults such as persistent entity deletion, character deletion, and account mint/burn are denied in the committed policy. Review [Capability policy and resource security](security/README.md) before changing a grant.

Capability denials always remain denials if their audit write fails. The runtime emits bounded metrics and redacted logs and sends rate-bounded denial records to the durable Core audit sink.

## Change control

Treat configuration changes as deployment changes:

1. validate the repository with `npm run check`;
2. inspect the capability delta with `node --experimental-strip-types tools/cli/src/bin.ts permissions .`;
3. test against a disposable database and an isolated FXServer;
4. restart through the operator's controlled maintenance process;
5. confirm `synex_doctor` returns the expected checks.

The current runtime does not hot-reload these JSON files. Restart `synex_core` in a controlled maintenance window after a reviewed change.
