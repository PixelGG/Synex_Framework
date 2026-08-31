# Smart Objects

A Smart Object is a declarative interaction affordance bound to a World, Entity or runtime target. It describes where actors can stand, which intents apply and how presentation should identify the target. It contains no gameplay side effect.

## Required shape

Each definition has:

- a namespaced `key` owned by the declaring resource;
- exactly one binding;
- one or more unique slots;
- one or more namespaced activity/intent keys;
- optional tags, availability/concurrency policy and presentation metadata.

Supported bindings are:

| Binding | Canonical identity |
| --- | --- |
| `worldRef` | exact World `anchor`, `door` or `portal` key; requests carry its revision |
| `worldAnchor` | backwards-compatible shorthand for an anchor key |
| `entityRef` | stable Entity ID plus positive generation |
| `entityArchetype` | declared archetype and/or model selector |
| `entityBone` | archetype/model selector plus local bone name |
| `staticTransform` | bounded position and optional heading |
| `dynamic` | owner resource, provider and bounded binding key |

`worldRef` is the preferred form for new World-bound interactions because the object kind is explicit. Neither World binding embeds door, portal or location business logic in Interact.

Tags are discovery filters and presentation hints. They never grant permission.

## Availability and concurrency

`availabilityPolicy` is a closed object with a static `enabled` flag and, when needed, one namespaced evaluator plus bounded arguments. Object and slot policies are owner-fenced dependencies. The server invokes them within the registered budget and rechecks the result during lease request, participant join, activation and renewal. Missing, stale, malformed, denied or timed-out evaluators fail closed.

`concurrencyPolicy.mode` is either `slot` (the default) or `exclusive`. Slot mode coordinates each declared slot independently. Exclusive mode prevents a foreign session from claiming another slot on the same Smart Object while the object is in use. Neither policy is gameplay-domain authorization; the intent execution policy and typed domain adapter still make their own decisions.

## Ownership and revisions

The compiler requires the bundle, Smart Object, intents and graphs to use the owner's namespace. Registry conflicts fail closed; unrelated resources cannot silently replace another owner's object. A compiled object inherits its active bundle revision and owner epoch. Replacement revokes affected runtime state before the new definition becomes authoritative.

See the canonical [bundle schema](../../schemas/interaction-bundle.schema.json), [slots](slots.md) and [bundle guide](bundles.md).
