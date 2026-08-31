# Entity guards

`synex_security` observes Cfx entity creation but does not become a second entity
authority. Stable identity, generation, ownership, bucket context,
materialization, and lifecycle remain owned by `synex_entities`.

## Creation guard

The current guard hooks `entityCreating`. For each event it collects bounded
server values for creator, model, entity type, and routing bucket, then consults
the synchronous authority callback injected by the Security runtime. That
callback correlates a short-lived, bounded spawn intent recorded through the
non-required `synex.entities.before_entity_spawn` hook. The hook always returns
`allow`; `synex_entities` remains the authority.

Because `entityCreating` is synchronous, the runtime does not yield into the
Entity service. A concrete model/type match attributes the server-created spawn.
Cfx creator `0` does not expose its resource, so unmatched/expired intents and
archetype requests remain unattributed rather than guessed. The requested
routing bucket is applied after entity creation, so it is provenance only and
never a synchronous wrong-bucket fence. In the conservative profile, client-created
entities remain legacy-allowed and non-deterministic; the default configuration
contains no denied-model entries and disables burst cancellation. The opt-in `strict` profile
instead treats every client-created entity as a deterministic authority denial.
Burst mitigation remains a separate explicit `cfxPolicy` gate. This strict boundary is only
appropriate after every required creation path is server-authoritative. Entity
lifecycle subscriptions build a bounded diagnostic projection, not a second
entity catalog.

It can signal:

- `ENTITY_MODEL_DENIED` for an explicitly configured denied model;
- `ENTITY_BUCKET_VIOLATION` for a deterministic expected-bucket mismatch;
- `ENTITY_UNAUTHORIZED_CREATE` for an explicit deterministic authority denial;
- `ENTITY_SPAWN_BURST` when a managed or strict policy exceeds the bounded
  creation window.

The default burst window is 18 creations in two seconds. Burst cancellation is
limited to attributable player creators under managed/strict policy and can be
disabled. Cfx creator `0` does not identify the originating server resource, so
server-created entities never share a global burst quota. A legacy/unknown path
is not converted into an automatic blanket denial.

## Cancellation

`entityCreating` is a cancelable server event. The reusable guard can call
`CancelEvent` only when its detector mode permits mitigation and a deterministic
or configured violation was accepted. The default conservative profile does not
activate a deterministic client-creation denial. The strict profile does, but
must remain deployment-gated until the live OneSync matrix proves all legitimate
server- and client-created paths. A matching `entity.spawn` expectation
suppresses both signal and cancellation.

The implementation still requires real FXServer validation for creator/model/
bucket timing, server-created entities, network ownership, and compatibility
with actual resources. Repository port tests do not prove live OneSync behavior.

## Domain integration

Security subscribes to declared Entity lifecycle topics such as created,
materialized, dematerialized, owner changed, bucket changed, and deleted. Those
events populate a bounded diagnostic projection for observation, cleanup, and
operator summaries. The projection is not consulted as spawn authority and does
not duplicate the Entity catalog. It feeds bounded observed-bucket metadata to
the read-only hardening advisor; absent lockdown metadata remains `unknown`.

`synex_entities` also reports a narrow allowlist of authoritative denials after
its own operation has failed closed: foreign bucket/owner/namespace access,
stale EntityRef or bucket generations, bucket mismatches, authority-lease
conflicts, quota abuse, and invalid interaction context. Reporting is fail-open;
Security availability can neither authorize nor block the Entity operation.

A domain that knows a spawn is legitimate should use its normal Entity authority
and, only where needed for transient detector suppression, a bounded
`entity.spawn` expectation. A Security expectation cannot manufacture an
EntityRef or allow a creation rejected by Entities.

## Hardening relationship

The read-only hardening advisor reports the global `sv_entityLockdown` ConVar
and bounded observed buckets, and never changes modes. It does not infer bucket
policy from ownership or player presence. Strict lockdown is appropriate only when all required creation paths
have been made server-authoritative and live-tested.

## Non-goals

The current guard is not a persistent entity store, ownership migration engine,
cleanup sweeper, model catalog, or cross-resource spawn API. Those remain Entity
or operator responsibilities.
