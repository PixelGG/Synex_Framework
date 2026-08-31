# Threat model

## Binding assumption

Synex assumes the FiveM client is fully compromised. An attacker may inspect or
change client Lua, JavaScript, NUI, events, state, natives, cameras, peds,
weapons, locally controlled entities, and every Sentinel report.

Client event names, contract names, resource files, challenge formats, and code
constants are public. Obfuscation and undisclosed event names are not security
boundaries.

The attacker does not automatically control the Synex server process, MariaDB,
Core's capability policy, current sessions/source generations, domain state
machines, the Accounts ledger, World authority, Entity authority, or server-side
Interaction Leases. A compromised server resource is outside the trust provided
by a resource capability declaration alone and still requires supply-chain and
code review.

## Capability-oriented model

Runtime code uses generic capabilities, not product or menu names. Publicly
described attacker capabilities are mapped as follows:

| Capability | Primary prevention | Security evidence | Default response | Main false-positive risk |
| --- | --- | --- | --- | --- |
| Event discovery/trigger/replay | Core contract schemas, active session, source generation, capabilities, rate limits | Core/domain denial signal | Observe or bounded mitigation | Client retries, stale UI |
| Economy/inventory manipulation | Domain authorization, idempotency, server-derived values | Domain-authoritative rejection | Observe, correlate | Integration bugs, duplicate delivery |
| Resource/client modification | Server authority; no client secrets | Sentinel liveness and inconsistent advisory state | Observe | Crash, load, resource restart |
| Teleport/noclip/freecam/super jump | World transition grants and server state | Bounded movement patterns plus expectations | Observe | Streaming, vehicles, respawn, scripted scenes |
| Health/armor/invisibility/model manipulation | Character/domain expected state | Repeated Sentinel mismatch and server-derived events | Observe | Spawn protection, medical/admin actions |
| Weapon/damage manipulation | Server weapon/damage policy | Cfx damage event plus domain policy | Observe or deterministic mitigation | Custom weapons, scripted damage |
| Entity/object/vehicle spam | Entity authority, OneSync lockdown policy | `entityCreating`, model/bucket/authority/burst checks | Mitigate deterministic violations | Legitimate burst spawning |
| Explosion/projectile/PTFX abuse | Server configuration and cancelable event policy | Cfx event envelope/type/rate | Mitigate only supported, configured paths | Scripted effects, artifact differences |
| Aim assistance/trigger automation | No universal deterministic prevention in this resource | Bounded combat behavior correlation | Observe/manual review | Skilled play, latency, weapon balance |
| Identifier spoofing or ban evasion claims | Core connection/identity/access policy | Connection and resource signals where available | Operator policy | Provider changes, shared environments |
| Screenshot or local stream manipulation | Not treated as server truth | No strong evidence in this implementation | None | Client completely controls presentation |

The table describes defensive coverage, not a guarantee that every capability is
detected. No current implementation can prove an unmodified client solely from
client telemetry.

## Public defensive research basis

Last reviewed: **2026-08-31**.

This threat model includes a bounded review of public, vendor-controlled or
seller-published descriptions for [redENGINE](https://redengine.cc/),
[a public redENGINE capability description](https://help.shamods.com/our-products/fivem/quickstart-1/redengine-executor-information),
[Snaily](https://snaily.dev/), and
[Phaze/Nexus](https://tgmodz-1.gitbook.io/tgmodz-documentation/product-documentation/fivem/phaze-menu-nexus/phaze-nexus-information).
Those pages publicly claim capability classes including client-side Lua
execution, custom-script execution, movement or player-state modification,
aim/visual assistance, resource or event interaction, and evasion/privacy
features. These are unverified marketing claims, not trusted technical facts,
not Synex signatures, and not evidence against a player.

The defensive mapping is cross-checked against the Cfx documentation for
[secure event handling](https://docs.fivem.net/docs/developers/server-security/),
[network game events](https://docs.fivem.net/docs/game-references/net-game-events/),
[state bags](https://docs.fivem.net/docs/scripting-manual/networking/state-bags/),
and [OneSync](https://docs.fivem.net/docs/scripting-reference/onesync/). Those
sources support the model's platform boundaries: client-originated values need
server-side validation, relevant game events have artifact-defined server
envelopes, and entity/scope state is subject to OneSync ownership, migration,
and culling behavior.

The review is intentionally reproducible and non-operational:

1. Record the UTC review date and the exact public URLs above.
2. Read only public capability and platform descriptions; do not download,
   purchase, execute, inject, reverse engineer, or retain offensive binaries.
3. Normalize claims into the generic capability classes in this document;
   never copy installation, usage, evasion, or bypass instructions.
4. Compare the resulting classes with server-authoritative Core/domain controls
   and documented Cfx event/OneSync semantics.
5. Add or change runtime coverage only from independently validated platform
   behavior and repository tests, never from a product name or marketing claim.

Product names therefore remain confined to this dated research record. Runtime
detectors use generic, behavior-based codes and cannot infer which tool, if any,
produced an observation.

## Evidence constraints

Strong enforcement requires independent evidence. Signals that share a root
event, request, or trace are collapsed for independence. Client telemetry and
behavioral heuristics are weak classes and their correlated confidence is capped.
An active expectation can remove a matching unusual state from the actionable
hypothesis while preserving operational counters.

## Explicit non-goals

`synex_security` does not:

- download, execute, or fingerprint offensive software;
- scan client memory or arbitrary files;
- claim cryptographic client attestation;
- use cheat-product names as signatures;
- hide secret keys in client code;
- replace domain validation;
- guarantee prevention of local visual modifications;
- automatically ban from a single heuristic or Sentinel report.

## Trust failure handling

If server-side authority is unavailable or stale, protected Security operations
fail closed. If Security itself is degraded, domains must continue enforcing
their own rules. A Security outage must never make an invalid financial, entity,
world, or interaction operation valid.
