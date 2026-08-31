# `synex_entities` integration

Entities owns persistent Entity identity, generation, materialization, model/type, logical ownership and routing-bucket authority. Interact uses those facts for target resolution.

## Binding choices

- `entityRef` targets one exact stable Entity ID and generation.
- `entityArchetype` describes an interaction for an admitted archetype or model.
- `entityBone` adds a local bone hit/position to an archetype/model selector.
- ambient targets may carry a transient network ID plus an exact model for live server verification; they are never persisted as identity. Archetype selectors are accepted only through a canonical managed EntityRef because Cfx ambient entities do not carry an authoritative Synex archetype fact.

## Generation safety

A Cfx network ID is 16-bit, local/reused runtime data and must not be stored as the durable reference. For a managed entity, use `{ entityId, generation }`. The server resolves the current entity, validates the generation, existence, type/model, bucket and live coordinates, and rejects a stale or mismatched ref.

The client never discovers managed identities through a global entity-pool scan. Its active-session runtime periodically requests a bounded projection from Interact. Interact first obtains the player's session-bound routing-bucket fence from `synex_entities`, performs the bucket-generation-fenced nearby query, filters it against the current Smart Object selectors, verifies the live network entity, and rechecks both the session and bucket generation before returning the projection. The client discards stale discovery revisions, source generations and bucket changes.

Client bone lookup and ray hits only improve discovery. The lease request must repeat the binding's exact bone name, while the server independently checks the canonical managed entity or the ambient entity's live type/model, bucket and distance. It does not trust a client entity handle, bone coordinate, model claim or distance.

## Vehicle bone example

An interaction author can use an `entityBone` binding such as `bonnet` or `boot` with an exact model/archetype selector. This does not implement vehicle ownership, keys, repair, storage or inventory. A typed adapter must call the owning domain, which rechecks its own policy and makes any effect idempotent.

See the [Entity identity guide](../entities/identity.md), [bindings](../entities/bindings.md) and [routing-bucket rules](../entities/routing-buckets.md).
