# Synex Security

> **Maturity: Experimental / Alpha.** `synex_security` is observe-first and has
> not completed real FXServer, OneSync, MariaDB, restart, or gameplay acceptance.
> It must not be represented as production-ready.

`synex_security` is the framework-wide detection, expectation, correlation,
case, mitigation, and enforcement foundation. It consumes bounded evidence from
Core, domains, Cfx server events, and a small client Sentinel. It does not replace
server-authoritative domain validation.

The operating model is:

```text
PREVENTION -> DETECTION -> NORMALIZATION -> EXPECTATIONS
           -> CORRELATION -> CASE -> MITIGATION / ENFORCEMENT
```

Core and domain resources prevent invalid operations. Security records and
correlates the attempted abuse. Accounts remains the financial authority,
Entities remains the entity authority, World remains the spatial authority, and
Core Access remains the ban authority. Security has no parallel balance, entity,
world, or ban store.

## Documentation map

### Foundation

- [Overview](overview.md)
- [Architecture](architecture.md)
- [Threat model](threat-model.md)
- [Signals](signals.md)
- [Evidence model](evidence.md)
- [Expectations](expectations.md)
- [Detector model](detectors.md)

### Detection surfaces

- [Player integrity](player-integrity.md)
- [Movement](movement.md)
- [Entity guards](entities.md)
- [Cfx game events](game-events.md)
- [Combat and weapon analysis](combat.md)
- [Economy boundaries](economy.md)
- [Interaction boundaries](interaction.md)
- [Client Sentinel](sentinel.md)

### Decisions and operations

- [Correlation](correlation.md)
- [Cases](cases.md)
- [Enforcement](enforcement.md)
- [Cfx hardening advisor](hardening.md)
- [False-positive policy](false-positives.md)
- [Development and verification](development.md)

Related framework material:

- [Framework security architecture](../architecture/security.md)
- [ADR-0012: assume the client is fully compromised](../architecture/decisions/0012-client-fully-compromised.md)
- [ADR-0013: separate prevention from detection](../architecture/decisions/0013-prevention-detection-separation.md)

## Implemented surface

The resource currently contains:

- `synex.security@1`, an experimental Core service;
- eight contract definitions, of which only the Sentinel report is
  client-to-server;
- bounded signal, expectation, correlation, case, and enforcement engines;
- engine modules for player-integrity, movement, entity, damage, explosion,
  projectile, and PTFX observations;
- active fail-open reporting of selected authoritative denials from Accounts,
  Entities, and Interact after each owning domain has already failed closed;
- a World integration for narrowly scoped movement expectations around valid
  transitions;
- a small sequence-, freshness-, session-, generation-, and challenge-bound
  client Sentinel;
- a read-only `security` Control provider and console diagnostics;
- read-only Cfx hardening findings;
- three owned persistence tables for cases, case signals, and enforcement
  records.

The default profile keeps Sentinel, player integrity, movement, weapon
integrity, combat analytics, and domain-abuse detection in `OBSERVE`.
Transport, entity, and game-event families are configured for `MITIGATE`.
Transport findings remain evidence/case inputs; the default policy keeps every
entity/game-event deny catalog empty, legacy client creation non-deterministic,
and all burst cancellation disabled. The opt-in `strict` profile can classify
client-created Entities deterministically, but remains live-gated.
Projectile/PTFX cancellation is disabled. Automatic kick and
automatic ban are disabled.

The runtime injects server-native ped model and maximum-health observation.
Armor, weapon-authority, invulnerability, and damage-policy adapters remain
unwired rather than guessing domain truth. A bounded damage-taken
observation is active when `weaponDamageEvent` can be resolved to the current
server player ped; it remains event-coverage-limited and does not claim to see
all damage. The default conservative `entityCreating` policy is observe-only for
legacy client creation, while the opt-in strict profile applies a deterministic
client-created-entity boundary. Bounded hook-based intent correlation attributes
concrete Synex server spawns without becoming a second entity authority. Those integrations, every strict entity path,
all Cfx cancellation behavior, and their false-positive calibration remain
live-gated until tested on the exact deployed FXServer/OneSync profile.

## Open acceptance gates

Repository tests exercise the pure Lua engines and injected Cfx ports. They do
not prove deployed event payloads, cancellation, OneSync ownership, network
timing, database recovery, or gameplay false-positive behavior.

In particular, cancellation behavior for `startProjectileEvent` and
`ptFxEvent` remains disabled unless explicitly enabled after validation and is
**unverified until tested on the exact real FXServer artifact**. All other live
behavior is also unverified until the resource completes its documented live
test matrix.
