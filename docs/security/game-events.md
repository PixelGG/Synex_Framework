# Cfx game-event guards

The Cfx guard uses server events as evidence and, where supported, as an early
mitigation point. Values supplied in these events can still originate from a
compromised client; "server event" does not mean every payload field is trusted.

## Installed hooks

| Event | Current use | Cancellation status |
| --- | --- | --- |
| `entityCreating` | Entity authority/model/bucket/burst guard | Documented cancelable; live behavior still requires acceptance |
| `weaponDamageEvent` | Weapon/damage policy and event burst observation | Documented cancelable; event does not represent every local damage path |
| `explosionEvent` | Denied type and burst guard | Documented cancelable |
| `startProjectileEvent` | Denied projectile and burst observation | Artifact-observed, cancellation live-gated and unverified |
| `ptFxEvent` | Denied effect and burst observation | Artifact-observed, cancellation live-gated and unverified |

The last two hooks must not have cancellation enabled solely because unit tests
pass. Their event and cancellation behavior must be verified on the exact
deployed FXServer artifact.

## Validation and burst windows

The guard rejects malformed sender/envelope shapes and emits
`CFX_GAME_EVENT_INVALID`. In `MITIGATE`, that malformed-envelope path can call
`CancelEvent`. It normalizes only a small allowlist of fields.
Default burst windows are bounded:

- weapon damage: more than 120 events in 2 seconds;
- explosion: more than 18 in 2.5 seconds;
- projectile: more than 16 in 2 seconds;
- PTFX: more than 40 in 2 seconds.

Configured denied type/hash sets can produce stronger signals. `cfxPolicy` is
strictly validated at startup with exact keys, bounded unique integer sets, and
boolean gates. The default deny sets are empty.
A deployment must review game content and compatibility before adding one.

## Default mitigation

The reusable guard supports option-gated burst cancellation. Every burst gate
defaults to `false`. Projectile/PTFX cancellation additionally requires both
`supported` and `liveVerified`; both default to `false`. Consequently current
burst paths observe and signal but do not cancel.

Cancellation is prevention for that event only. It does not prove intent and is
not by itself a permanent-ban decision.

## Root correlation

Every emitted Cfx observation receives a bounded root-event identity. Derived
weapon and combat signals can share that root so correlation counts the
underlying event once rather than treating each detector result as independent.

## Acceptance checklist

For each deployed artifact and gameplay stack, verify event delivery, exact
payload types/ranges, cancellation outcome, server-created effects, ownership,
routing buckets, legitimate scripted bursts, reconnect cleanup, and resmon cost.
Until that matrix is complete, every live behavior remains Experimental / Alpha.
