# Recovery and drift

Recovery restores eligible durable Entity definitions after a runtime Entity disappears. It is separate from persistence: a definition can be durable and intentionally dormant without automatic recovery.

## Recovery policies

| Policy | Background recovery |
| --- | --- |
| `none` | Disabled |
| `manual` | Caller-driven materialization |
| `on_demand` | Caller-driven materialization when needed |
| `automatic` | Eligible for the bounded recovery worker |

Automatic recovery is accepted only for `persistent` and `owner_lifetime` definitions. An unexpected removal releases runtime mapping/authority and moves an automatic definition to `orphaned`; other durable definitions become `dormant`.

## Recovery worker

The scheduled worker:

- retries one bounded batch from the process-local runtime cleanup queue;
- continues paged boot-authority reconciliation;
- purges only recovery-history rows whose database retention deadline has passed;
- selects a bounded due page for the configured server scope;
- claims the current Entity authority lease;
- runs the pre-recovery hook;
- applies spawn admission limits;
- creates a new generation in the safe default bucket;
- verifies the OneSync Entity and rehydrates replicated extensions;
- records success or a structured failure.

Dynamic managed-bucket generations are not persisted as restart authority. Automatic recovery returns to bucket `0`; the owner resource may explicitly move/materialize into a current managed bucket afterward.

### Runtime cleanup queue

Failed native compensation and selected resource-stop/authority-loss deletion failures enter an in-memory queue capped between 64 and the configured maximum Entity count, with an absolute maximum of 20,000. Each recovery tick processes at most the configured recovery batch size (`1..128`) in insertion order. Duplicate findings replace the retry closure without consuming another slot.

Pending cleanup is surfaced in health and remains `DEGRADED` while findings exist; full capacity is fail-closed as `UNHEALTHY`. An empty queue restores `READY` only when `ENTITY_CLEANUP_PENDING` is still the active reason, so it cannot erase an unrelated degradation. The queue records bounded `entities.cleanup_queued`, `entities.cleanup_resolved` and `entities.cleanup_queue_exhausted` audit actions plus pending/retry/overflow metrics. It does not survive a resource or FXServer process restart, so restart reconciliation and live leak inspection remain separate acceptance requirements.

## Backoff and circuit

Failed automatic attempts use bounded exponential backoff plus deterministic jitter. Attempt count and recovery window are durable. When the configured maximum is reached, the definition becomes `failed`, the circuit becomes `paused`, and automatic selection stops with `RECOVERY_PAUSED` semantics.

The worker also compares per-run failures with the configured storm threshold and degrades health as `RECOVERY_STORM`. It never performs an aggressive unbounded retry loop.

## Drift reconciliation

Drift detection is paged and interval-driven. It compares bounded runtime and persistence pages rather than scanning the Entity world every frame. Current findings include:

- active database definition without a runtime mapping;
- persistent runtime record without a database definition;
- stale or invalid NetID mapping;
- generation mismatch;
- duplicate namespaced persistent key in the scanned runtime page;
- wrong Entity type, model, bucket, logical owner or resource owner;
- inactive resource owner;
- missing managed bucket, resource cleanup leak and authority conflict in diagnostics.

Missing active runtime definitions are authority-fenced into `orphaned` for automatic recovery or `dormant` otherwise. A recycled native handle is never deleted unless runtime inspection proves it is still the registered Entity.

## History and diagnostics

Recovery history records generation, lease generation, attempt, outcome, instance, failure code, next retry, duration, trace and bounded details. Each row has `retain_until`; the recovery worker purges due history in bounded batches.

The read-only Control Recovery inspector accepts one exact stable Entity ID. It exposes generation, recovery policy/status, attempt count, circuit, last failure, next retry, recovery-window start and a bounded recent timeline with a configurable request limit from 1 through 25 (default 10). `synex doctor entities` consumes a paged diagnostic snapshot and reports recovery backlogs/storms alongside stale runtime mappings and bindings, duplicate bindings/persistent keys, generation/NetID mismatches, persistent runtime orphans, invalid owners, stopped-resource leaks, missing or conflicting bucket membership/ownership, component/state schema mismatches, quota pressure, current terminal-materialization spawn-failure rate and lease conflicts. It also includes at most 50 ordered cleanup findings with queue capacity, count, truncation, attempts, timestamps and the last stable error code. Health/control summaries expose the first 10 findings. These are observer surfaces only; they do not open, close, retry or reset a recovery circuit and do not execute cleanup on demand.

## Acceptance boundary

Headless repository tests cover the state and repository rules. The exact candidate still requires live unexpected-removal, repeated failure/circuit, restart, expired-lease takeover, two-contender recovery and cleanup-failure injection before recovery can be described as runtime accepted.
