# False-positive policy

False-positive control is an architectural requirement, not post-release tuning.

## Rules

1. Prevent invalid state in Core/domains before detecting intent.
2. Prefer server/domain facts over client telemetry.
3. Require repeated or independent evidence for ambiguous behavior.
4. Collapse signals sharing one root event.
5. Decay old behavior by category.
6. Register explicit, short-lived expectations for legitimate unusual state.
7. Keep heuristic families in `OBSERVE` until live data is reviewed.
8. Revalidate subject authority immediately before an action.
9. Never permanently ban from one Sentinel report or one movement/combat
   heuristic.

## Known high-risk contexts

| Detector area | Legitimate causes to test |
| --- | --- |
| Sentinel liveness | crash, loading, restart, packet loss, hitch |
| Visibility/invulnerability | spawn protection, cutscene, passive/admin/medical state |
| Model/weapon | character change, loadout transition, custom content |
| Movement | respawn, portal, elevator, interior, vehicle transport, streaming, map scripts |
| Entity bursts | garages, map loading, scene setup, server-owned batch spawning |
| Explosions/projectiles/PTFX | jobs, effects, scripted missions, custom weapons |
| Combat analytics | skilled play, latency, unusual weapons, spectating, NPC behavior |
| Interaction denials | stale UI, movement, contention, restart, latency |

## Expectation discipline

Expectations must be scoped to one subject and explicit selectors, carry an
owner/reason/revision, and expire quickly. A broad or long-lived expectation can
hide real evidence; an omitted expectation can make legitimate state noisy.

Do not use expectations to bypass domain authorization. The real domain grant or
state must exist independently.

## Calibration workflow

For each detector:

1. run in `OBSERVE`;
2. capture aggregate counts and bounded case summaries, not raw personal data;
3. label expected contexts and integration defects;
4. add/fix authoritative context or expectations;
5. replay repository tests and run the live scenario matrix;
6. only then consider deterministic mitigation;
7. require a separate policy review for any restrict/kick/ban path.

Changing a threshold to silence all findings is not calibration. Investigate
input authority, timing, context, and cleanup first.

## Review evidence

A reviewer should see stable codes, evidence classes, root independence,
expectation count, current/peak confidence, subject freshness, policy ID, and
action provenance. Client claims and heuristic labels must remain visibly weak.

The present implementation has repository regression tests but no production
dataset or completed real-server false-positive baseline. It remains
Experimental / Alpha.
