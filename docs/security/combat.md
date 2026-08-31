# Combat and weapon analysis

Combat analysis separates deterministic domain policy from behavioral
observation. It does not claim a universal deterministic detector for aiming or
reaction assistance.

## Weapon and damage policy

`weaponDamageEvent` is sanitized to a small descriptor and may be passed to two
injected adapters:

- the weapon-authority adapter can explicitly reject a weapon hash, producing
  `WEAPON_DAMAGE_UNAUTHORIZED` as `CFX_SERVER_EVENT` evidence;
- the damage-policy adapter can reject a damage descriptor, producing
  `COMBAT_DAMAGE_POLICY_MISMATCH` as `SERVER_DERIVED` evidence.

The selected weapon in Sentinel telemetry is a separate advisory path. A
repeated mismatch produces `WEAPON_STATE_UNAUTHORIZED` only when an authority
adapter explicitly rejects it.

The current runtime injects neither the weapon-authority nor damage-policy
adapter. `weaponDamageEvent` still reaches the guard for envelope/burst
observation, but these domain-policy signals remain inactive until a real owner
provides their inputs.

## Damage immunity

Server/domain code can report bounded damage-taken observations by semantic
damage class. The current Cfx guard also attempts one narrow active path: when
`weaponDamageEvent` resolves its victim to the current server-side player ped,
it records a bounded damage observation for that player. This path is limited
to events and victim relationships visible to that exact FXServer/OneSync
runtime; it is not complete combat telemetry.

When several recent observations are followed by advisory combined health and
armor that remains at or above a known pre-event baseline, while invulnerability
is not expected, the detector emits `PLAYER_DAMAGE_IMMUNITY_PATTERN`. A missing
baseline and damage absorbed by armor do not satisfy this pattern.

This is behavioral evidence, not proof. Network ownership, damage routing,
spawn protection, passive state, scripted healing, and game-mode rules can all
affect the observation.

## Behavioral analytics

The current combat accumulator accepts only three generic anomaly flags from a
server-side provider:

- `impossibleReaction`;
- `trajectoryMismatch`;
- `targetMismatch`.

It requires multiple samples and at least two anomaly classes before emitting
`COMBAT_BEHAVIOR_CORRELATION`. The signal is low-confidence
`BEHAVIORAL_HEURISTIC`, rate-limited, and observe-only. Headshot rate alone is
explicitly not used as the deciding signal.

No provider in this module invents those flags from raw client aim data. A future
provider must document its inputs, bounds, calibration, and false-positive
tests before use.

The current server runtime does not register a combat-anomaly provider, so this
analytics path is implemented and unit-tested but dormant.

## Expectations

`combat.invulnerable`, `combat.passive`, and `weapon.grant` expectations can
suppress matching unusual state during a legitimate bounded window. The owning
gameplay domain still grants and revokes the real state.

## Enforcement posture

Weapon integrity and combat analytics default to `OBSERVE`. A single damage
event, kill, headshot, unusual reaction, or Sentinel weapon sample cannot produce
an automatic permanent ban. Strong action requires current subject authority,
independent non-weak evidence, an explicit policy, and a live-validated handler.

Real weapon catalogs, custom damage systems, latency, routing behavior, and
event coverage remain open live-test gates.
