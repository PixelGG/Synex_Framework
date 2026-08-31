# Player integrity

Player-integrity detection compares advisory client observations with
server-owned expectations and bounded server observations. It does not treat a
single native value as proof.

## Current observations

The Sentinel reports bounded values for:

- health and armor;
- visibility and alpha;
- ped model hash;
- selected weapon hash;
- movement state used by the movement detector.

`server/detectors.lua` can consume an injected expected-player-state adapter
containing visibility, model, health/armor limits, and invulnerability context.
It can also consume a weapon-authority adapter and explicit damage observations.

The runtime injects a narrow native observer for the current server-side ped
model and maximum health. This is observation context, not a parallel character
authority. Armor, weapon, invulnerability, and damage-policy paths stay inactive
until a real owning domain supplies explicit authority. A bounded damage-taken observation can feed the damage-immunity
path when `weaponDamageEvent` resolves its victim to the current server-side
player ped. That event-limited observation does not cover every damage path.

## Emitted patterns

| Signal | Trigger shape | Evidence |
| --- | --- | --- |
| `VISIBILITY_STATE_MISMATCH` | Repeated invisible/low-alpha reports while visible is expected | `CLIENT_TELEMETRY` |
| `PLAYER_MODEL_MISMATCH` | Repeated model mismatch against an explicit expected model | `CLIENT_TELEMETRY` |
| `PLAYER_HEALTH_LIMIT_MISMATCH` | Repeated health above an explicit server-owned limit | `CLIENT_TELEMETRY` |
| `PLAYER_ARMOR_LIMIT_MISMATCH` | Repeated armor above an explicit server-owned limit | `CLIENT_TELEMETRY` |
| `WEAPON_STATE_UNAUTHORIZED` | Repeated selected-weapon denial by the weapon adapter | `CLIENT_TELEMETRY` |
| `PLAYER_DAMAGE_IMMUNITY_PATTERN` | Multiple damage observations followed by advisory combined health/armor that did not decrease from a known baseline while invulnerability was not expected | `BEHAVIORAL_HEURISTIC` |

These implemented engine signals are low or medium severity and observe-first.
Each path uses repetition or correlation rather than one sample. Adapter-backed
signals are not emitted by the current runtime without their missing adapter;
damage immunity additionally requires the bounded Cfx damage observation. The
underlying Sentinel can be forged, suppressed, or stopped.

## Expectations and legitimate states

Spawn protection, passive mode, cutscenes, model transitions, medical actions,
administrative tools, and scripted invisibility can all be legitimate. The
owning domain should expose its expected state or issue a narrowly scoped,
short-lived expectation such as `combat.invulnerable`, `combat.passive`,
`visibility.hidden`, or `player.model`.

An expectation does not grant the state. The character, medical, world, or admin
domain remains responsible for the real permission and lifecycle.

## Damage immunity

Damage-immunity evaluation accepts named damage classes and keeps a short,
bounded observation window. It needs several observations and checks that the
server expected no invulnerability. It does not claim to distinguish every GTA
damage proof or network condition, and it does not ban from one unusual damage
event.

## Missing coverage

The current implementation does not provide cryptographic client attestation,
memory scanning, screenshot analysis, or a deterministic detector for every
health/proof native. It also does not implement an automatic model correction or
weapon removal path in this detector module.

## Acceptance

Repository tests cover repeated samples, explicit expectations, stale source
generations, and damage-pattern behavior. Gameplay calibration, spawn/respawn
integration, custom models, medical scripts, latency, and all real native values
remain unverified until a real FXServer client test.
