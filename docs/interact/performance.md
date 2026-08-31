# Interact performance model

Performance is enforced first through bounded work, then verified through measurement. The repository makes no `0.00 ms` claim.

## Client bounds

- spatially indexed static candidates instead of a global per-frame registry scan;
- no full GTA entity-pool scan;
- at most 128 admitted candidates per sample;
- at most eight expensive candidates;
- one tracked asynchronous ray at a time with a short LOS cache;
- at most six visible intents;
- adaptive 500/200/75/33 ms sensor intervals;
- change/revision-driven UI projection rather than one NUI message per frame.

Providers and evaluators are capped, resource-owned and timed. The client admits at most 64 candidate providers, starts at most four due providers per sensor sample, and keeps at most 16 provider callbacks in flight. Scheduling is deterministic round-robin over priority/key order; unreferenced providers are skipped. Provider definitions use a `33..5000 ms` minimum interval and `0..5000 ms` result TTL (defaults: `250 ms` and `1000 ms`). Client visibility evaluation separately admits at most 16 concurrently running callbacks and retains at most 32 short-lived cache entries per registered evaluator. Evaluator definitions can select a `1..1000 ms` timeout and `0..5000 ms` cache TTL; defaults are the shared evaluator timeout and a `250 ms` cache TTL. Slow, expired or malformed output fails closed and aggregate duration/failure/timeout counts remain inspectable.

Lua callbacks cannot be forcibly terminated safely. A timed-out callback therefore cannot publish a late result, and the global admission cap prevents abandoned callbacks from creating unbounded additional work. Evaluator handlers must still return promptly and must not poll or enumerate world state themselves.

## Server bounds

The runtime caps bundles, objects, intents, graphs, providers/evaluators/adapters, active leases/sessions/reservations/locks, graph nodes/steps/branches/retries, trace frames and denial records. Discovery is encoded in registry order once per revision and deterministically split into at most 24 revision-fenced string chunks. Each chunk is at most 14,000 bytes and its full response envelope is verified at no more than 28,672 bytes, safely under Core's 32 KiB transport cap without consuming the nested table-key budget. A complete snapshot remains capped at 2,048 objects and 262,144 encoded bytes. The client stages it for at most ten seconds and publishes it only after a complete consistent decode.

Participant membership has actor-key and source indexes, so cancellation/drop cleanup iterates only sessions for that actor/source. Exclusive Smart Object conflict checks use an object-local reservation index instead of scanning the complete reservation registry. Index entries are removed with the same join/leave/discard/release/session cleanup paths; the underlying session, participant and reservation caps still remain the safety bound. Actor viability uses an O(1) lease ring and checks at most 64 entries per 250 ms scheduled tick, while activation, renewal and commit retain immediate server-side fences. Runtime interactions do not write a database.

## Instrumentation

The current source tracks sensor/intent/provider/adapter durations, candidate/expensive counts, lease/activation/graph outcomes, active runtime gauges, denial counts and bounded traces. The client reports process-lifetime averages for `sensor_duration_ms`, `client_provider_duration_ms` and `intent_scoring_duration_ms`, plus the monotonic `client_provider_timeout_total`; the server validates and projects only these fixed aggregate fields. `lease_expired_total` advances only when a lease actually crosses its TTL or immutable maximum-lifetime fence, not when it is normally cancelled or completed.

The development trace recorder is disabled by default. On an isolated diagnostic server, `setr synex_interact_trace 1` enables both the caller-bound client ring and the server trace-context ring for the next resource start. Each ring is in-memory, redacted and bounded by capacity plus retention; client score frames include only aggregate rejection/advisory codes and counts. Disable tracing again after diagnosis. A context-fixture or trace replay is not an authority path, benchmark or durable audit trail.

Labels are categorical; player, target, lease, session and trace IDs must not become metric labels. Inspector participant and lease information is count/state based and is not reused as metric labels.

## Live acceptance

Measure the exact candidate with `resmon`, the Cfx profiler and server hitch telemetry in at least idle, dense-candidate, Action Bloom, active graph and multi-player scenarios. Record hardware, artifact, population, registry/local candidate sizes and settings. A deterministic headless result is regression evidence only and must not be presented as FiveM performance.
