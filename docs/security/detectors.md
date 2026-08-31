# Detector model

Detectors convert bounded observations into canonical signals. They do not own
the underlying gameplay state.

## Modes

Each detector family uses one mode:

| Mode | Behavior |
| --- | --- |
| `DISABLED` | Do not evaluate or emit |
| `OBSERVE` | Emit evidence; no corrective action |
| `MITIGATE` | Permit deterministic correction/cancellation but not strong enforcement |
| `ENFORCE` | Permit policy-selected actions when every evidence and authority gate passes |

Modes are ceilings, not evidence upgrades. Weak-only evidence remains review
only, and automatic kick/ban are disabled in the committed default profile.

## Current families

| Family | Default | Inputs | Current output |
| --- | --- | --- | --- |
| Sentinel | `OBSERVE` | Report sequence, challenge, freshness, liveness | Replay/stale rejection and missing-liveness signal |
| Player integrity | `OBSERVE` | Advisory visibility/model/health/armor/weapon plus expected state | Repeated mismatch signals |
| Movement | `OBSERVE` | Bounded history, server position where available, advisory camera/motion | Teleport, noclip, freecam, repeated-jump patterns |
| Entity guard | `MITIGATE` | `entityCreating`, Entity authority adapter, model/bucket/burst policy | Signal and deterministic cancellation |
| Game events | `MITIGATE` | Damage, explosion, projectile, PTFX server events | Envelope/type/burst signals and supported cancellation |
| Weapon integrity | `OBSERVE` | Advisory selected weapon plus domain authorization adapter | Repeated unauthorized-state signal |
| Combat analytics | `OBSERVE` | Bounded anomaly classes | Correlated advisory behavior signal |

Transport and domain-abuse inputs can arrive as signals from Core/domains even
though they are not independent local detector objects in `server/detectors.lua`.

The table describes implemented engine paths. The runtime wires Sentinel
sampling plus a narrow server-native ped-model/maximum-health observer. It does
not inject armor, weapon-authority, damage-policy, or combat-anomaly providers.
A bounded damage-taken observation is
active only when `weaponDamageEvent` resolves its target to the current
server-side player ped; it does not provide complete damage coverage. Remaining
paths stay dormant rather than guessing domain truth. The current entity adapter
also does not claim deterministic authority over client-created entities.

## Common gates

Before a signal is accepted, the runtime checks:

- owner resource and owner epoch;
- namespace ownership;
- current session/source generation when session-bound;
- closed category/severity/evidence values;
- bounded summary and evidence;
- expectation matches;
- duplicate/root identity.

Per-player detector state and event windows are bounded and cleaned on player
drop. Periodic pruning removes stale state. Resource stop uninstalls registered
Cfx handlers where the runtime can remove their tokens.

## Deterministic versus heuristic paths

The guard engine supports deterministic examples such as an explicitly denied
entity model, a confirmed Entity-authority rejection, an expected-bucket
mismatch, a malformed supported game-event envelope, or an explicitly denied
explosion type. The default configuration supplies empty deny sets. Managed
Entity spawn intents add provenance without denial; only the opt-in `strict`
profile treats client-created Entities as a deterministic authority violation.
Every path must also be validated on the deployed artifact and configuration.

Movement continuity, camera separation, repeated jump shape, damage-immunity
patterns, and combat behavior are heuristic or client-informed. They default to
observe and require calibration.

## Health and diagnostics

The runtime exposes bounded detector names, modes, counters, and health through
the `security` Control provider and console diagnostics. These views are
read-only. Changing detector configuration is not a Control operation.

## Acceptance

Unit tests cover injected clocks, session adapters, expected-state adapters, Cfx
ports, cleanup, and mode behavior. They do not prove native/event behavior on a
real server. All detector claims remain **Experimental / Alpha** until live
acceptance, and cancellation for `startProjectileEvent` and `ptFxEvent` is
specifically unverified.
