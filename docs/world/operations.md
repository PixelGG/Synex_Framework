# Operations and diagnostics

World exposes bounded health, doctor, Control-provider and metric primitives. They describe the running candidate; they do not promote its maturity.

## Runtime prerequisites

The checked-in resource manifest requires OneSync, `synex_core` and `synex_entities`; `synex_groups` is an optional service dependency used only by access policies that request a Groups capability. Start order must make Core and Entity Authority available before World. The resource owns migration `001_world` and requests its exact Core, database, event, metric, audit, Control, Entity and optional Groups capabilities through [`synex.resource.json`](../../resources/synex_world/synex.resource.json). Declaration is not an operator grant: policy must authorize the requested capabilities before the candidate can become ready.

This is the implemented dependency model, not a production deployment recipe. The exact candidate still needs the live acceptance run described in [testing](testing.md).

## Health

The steady-state World health vocabulary is `READY`, `DEGRADED` and `UNHEALTHY`; snapshots may additionally expose the lifecycle states `STARTING` or `STOPPING` during transitions. A snapshot includes bounded reasons, registry revision, startup time, persistence status and service status. A fail-safe health observer keeps the registered Core service synchronized: `READY` maps to `HEALTHY`, `DEGRADED` maps to `DEGRADED`, and startup, stop or unhealthy states map to `UNHEALTHY`. Worker, doctor, cleanup, bundle-dependency and required-map-package reasons therefore cannot leave Core advertising a healthy World service. A required map outage remains degraded until map reconciliation succeeds; an unavailable template hierarchy additionally drains affected live instances.

## Doctor

The runtime doctor checks, within caller-selected bounds:

- stopped bundle dependencies;
- unavailable required/optional map resources, including a bounded semantic impact summary;
- observed spatial candidate and aggregate slice pressure;
- up to 32 entity-bound anchor references when the Entity resolver is available;
- failed instances and live buckets missing from Entity Authority;
- stale/incompatible persistent World and door state, including state left for a closed or unavailable instance;
- unavailable or dead outbox delivery records.

Each invocation rotates through fixed work budgets rather than rescanning the complete catalog: at most 64 bundle/map-package entries, two cold map-impact analyses, 64 anchor-index entries and 32 entity-authority resolutions. Instance inspection continues from its previous bounded cursor. Persistent World-state and door-state inspection uses rotating keyset cursors and shares the caller-selected result bound; it eventually reaches rows beyond the first page without an unbounded table scan. The report exposes `staticChecks`, `mapImpactsAnalyzed`, `authorityObjectsScanned`, `entityBindingsChecked`, `persistenceChecks`, `staticComplete`, `authorityComplete`, `persistenceComplete` and per-source `scanCoverage`; `hasMore`/`truncated` remain true until the current scan cycle is complete. Actionable severity is retained across pages and remains degraded until that source completes an entirely clean follow-up cycle. A partial clean page therefore cannot clear a finding observed earlier or make an incomplete first scan look ready.

The report is capped at 250 findings and marks truncation. It does not scan arbitrary map assets, validate native door models or prove that a client has streamed an IPL.

The offline `world doctor`/`doctor world` command is deliberately different: it validates repository bundles and returns runtime status `UNKNOWN` because it does not connect to FXServer.

## Control provider

The provider namespace is `world`, category `foundation`, version `1.0.0`. It offers read-only summary, health, cursor-based lists, exact-key search, object/graph/point inspectors, spatial metrics and doctor findings. Map-package rows include a revision-cached impact summary for affected bundles, locations, anchors and doors, with at most eight sorted sample keys per category. A list request performs at most two cold impact analyses; cached rows remain cheap, while remaining cold rows explicitly expose `impactPending: true` and the page reports `impactComplete: false` instead of implying a complete analysis. A later page/request can populate the rotating cache. List pages are at most 100 rows; point inspection uses a 25-unit nearby query capped at 64; search is exact-key only.

Control does not expose state values, mutation buttons, arbitrary predicates or unbounded catalog dumps.

## Current metrics

Core prefixes emitted names with `synex_world_`. The implemented suffixes are:

- gauges: `bundle_count`, `location_count`, `zone_count`, `anchor_count`, `door_count`, `instance_count`, `instance_bucket_recovery_pending`, `client_slice_bytes`;
- query counter: `query_total`, with bounded `operation` and `result` labels;
- query timing: `query_duration`, with bounded `operation` label;
- mutation counters: `state_change_total` and `door_state_change_total`, each with a bounded persistence label;
- context/transition counters: `context_change_total`, `transition_total` and `transition_denied_total`, with bounded kind/direction, outcome or error-code labels;
- relock failure counter: `door_auto_relock_failure_total`, with a bounded operation label;
- instance-state cleanup counters: `instance_state_cleanup_total` and `instance_state_cleanup_failure_total`, the latter with a bounded operation label;
- slice counter/observations: `client_slice_updates`, `client_slice_bytes` and `spatial_candidate_count`;
- bundle validation counter: `bundle_validation_failure_total`.

No character, instance, door or anchor ID is used as a metric label.

## Trace and redaction boundary

Core-provided trace IDs are carried through World mutations, Groups/Entities calls, events, audit records and persistent outbox rows. World does not claim a separate distributed-span exporter. Operational payloads contain bounded domain identifiers and status metadata; credentials, arbitrary SQL/native errors and state values are excluded from Control and audit projections.

## Audit and events

Implemented audit actions include bundle activation/deactivation, instance creation/closure, instance-state cleanup, bucket-recovery failure, auto-relock failure and denied/completed portal transitions. Persistent state and door changes are written to the outbox as `synex.world.state.changed` and `synex.world.door.state_changed` for at-least-once publication.

Successful state/door mutations additionally append bounded Core Audit records, and failed state/door/portal handlers append `world.privileged_request_rejected` with operation and public error code only. Capability enforcement remains owned by Core before the World handler runs.

At-least-once delivery means subscribers must be idempotent by event identity. Claims last 60 seconds, batch size is at most 50, retry backoff is bounded to 300 seconds, and a row becomes dead after 10 attempts.
