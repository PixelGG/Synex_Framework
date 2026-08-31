# Context Sensor

The Context Sensor creates a client-observed snapshot for discovery. It does not create an authorization fact.

## Observed context

The current sensor assembles a bounded structure containing:

- actor handle, position, velocity/speed, heading, vehicle, weapon, dead and ragdoll state;
- final rendered camera position, rotation and derived forward direction;
- cached `synex_world` context and optional instance projection;
- current input-device presentation hint;
- previous focus and intent continuity hints;
- current discovery revision.

Every sample carries `authority = "OBSERVED"`. Server code must re-read authoritative state before granting or activating a lease.

## Native observation

The client uses final-rendered-camera coordinates/rotation and derives a forward vector for gaze scoring. It uses asynchronous shape tests for line-of-sight candidates; a result is consumed only after Cfx reports completion. Entity handles and bone positions are local observation details and are never sent as durable identity.

## Adaptive cadence

Cadence is state-dependent, not a permanent `Wait(0)` scan. The checked-in bounds are:

| State | Interval |
| --- | ---: |
| no local definitions | 500 ms |
| definitions present, no candidate | 200 ms |
| nearby candidates | 75 ms |
| stable focused intent | 33 ms |

These values are implementation bounds, not performance claims. The live gate must measure actual idle and active cost with the intended FXServer artifact and gameplay load.

Custom candidate providers have a second bounded cadence inside that sample loop. Up to 64 owner-bound registrations are admitted, but a sample starts at most four due callbacks and allows at most 16 callbacks in flight. A deterministic round-robin over priority/key order prevents a large provider set from restarting on every 33-ms focused sample. Each provider selects a minimum `intervalMs` and a result `cacheTtlMs`; the defaults are 250 ms and 1,000 ms. Expired, pending, failed, malformed or timed-out data fails closed. Providers without a current canonical dynamic binding are not scheduled, and owner cleanup invalidates pending callback generations before they can publish a result.

## Interaction Assist boundary

The client reads the bounded `synex_ui` preference snapshot once when binding and then at most once per second. When Interaction Assist is enabled, observed gaze discovery uses an 18-degree cone instead of 13 degrees and intent switching uses a minimum 240 ms dwell instead of 120 ms. These values affect only local candidate observation and focus stability. They are never sent as target facts and never relax the server-side EntityRef, selector, routing-bucket, distance, session, capability or lease checks.

`reducedMotion` and `highContrast` remain presentation preferences in `synex_ui`; the sensor records their bounded state only for local diagnostics.

## Failure behavior

Missing actor/camera state yields `INTERACT_CONTEXT_INVALID`; it does not reuse an old authorization. Resource cleanup clears indexes, providers, pending ray state and continuity history. See [candidate pipeline](candidate-pipeline.md) and [security](security.md).

Discovery paging is fail-closed and atomic. A partial transfer never clears or mutates the active definition indexes. Revision drift, inconsistent page metadata, page-count overflow, timeout or transport failure discards only the staged transfer; the polling worker retries from page one against the latest registry revision.
