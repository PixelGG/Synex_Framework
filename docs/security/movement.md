# Movement integrity

Movement detection uses bounded history and temporal patterns. It does not apply
a global "distance greater than N means ban" rule.

## Sample inputs

Each accepted Sentinel sample contains position, velocity, camera position,
vehicle state, ragdoll state, falling state, and parachute state. The server
prefers an injected server position when available; otherwise position remains
client telemetry.

The default in-memory state is bounded to 1,024 subjects, 24 samples per subject,
and 120 seconds of subject retention. A player drop/source-generation cleanup
removes matching history.

## Context filters

Before assessing continuity, the engine can filter:

- too-short or stale sample intervals;
- explicit authorized transitions;
- spawn and respawn state;
- administrative or instance transitions;
- unstable falling, parachute, or ragdoll intervals where relevant;
- vehicle context.

The runtime supplies the authoritative routing bucket on every accepted sample.
A bounded server-native adapter marks the first ped sample, ped-handle
replacement, dead-to-alive transition, and routing-bucket change. Administrative
transitions are never inferred and still require an explicit owner expectation.

Active expectations are matched before a movement signal contributes to a case.
The current World portal path requests a short-lived `movement.teleport`
expectation before emitting the client transition. Failure to report an
expectation does not authorize or deny the portal itself; World remains the
authority.

## Current patterns

- `MOVEMENT_TELEPORT_ANOMALY`: a large transition with no supplied transition
  context, adjusted for elapsed time and vehicle state;
- `MOVEMENT_NOCLIP_PATTERN`: repeated continuity anomalies, not one traversal;
- `CAMERA_FREECAM_ANOMALY`: repeated camera-to-player separation from advisory
  telemetry;
- `MOVEMENT_SUPER_JUMP_PATTERN`: repeated bounded vertical movement shape.

Teleport evidence is `SERVER_DERIVED` only when the server supplied the
position; otherwise it is `CLIENT_TELEMETRY`. Noclip and repeated-jump signals
are `BEHAVIORAL_HEURISTIC`. Camera separation is client telemetry.

## Enforcement posture

Movement defaults to `OBSERVE`. Noclip, freecam, and repeated-jump signals are
explicitly advisory. Weak-only evidence cannot become kick or ban merely by
raising the detector mode.

Legitimate movement can be caused by streaming, elevators, interiors, moving
platforms, vehicle transport, map scripts, admin tools, respawns, routing-bucket
changes, or a long frame/network gap. Each integration must provide context or
expectations and must be tested in the deployed map and artifact.

## Current limits

The implementation does not claim deterministic collision traversal, ground
truth for client camera state, or infinite-stamina detection. It does not retain
long-term movement tracks.

Pure Lua tests cover history bounds, transition filtering, stale intervals, and
pattern emission. Real OneSync position timing and gameplay false-positive rates
remain unverified.
