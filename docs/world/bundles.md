# Declarative world bundles

World topology is delivered as JSON files owned by a started Synex resource. The owner declares each file in `synex.resource.json`:

```json
{
  "worldBundles": [
    "world/site.world.json"
  ]
}
```

The path must begin with `world/`, end with `.world.json`, contain no traversal segment or backslash, and be declared in the resource's FiveM `files` set for distribution.

## Envelope

```json
{
  "$schema": "../../../schemas/world-bundle.schema.json",
  "schema": 1,
  "key": "synex_world_companion:site",
  "version": "0.1.0",
  "dependencies": [],
  "objects": []
}
```

The closed [bundle schema](../../schemas/world-bundle.schema.json) defines every supported field. Unknown fields are rejected. Bundle and map-package versions are canonical semantic versions without build metadata. Map-package types are limited to `mlo`, `ymap`, `ipl`, `interior` and `custom`; package and dependency resource names cannot contain empty `..` segments. The runtime compiler repeats these envelope checks and semantic checks that JSON Schema alone cannot prove, including owner namespace, graph constraints, cross-resource references and dependency cycles. Direct runtime registration therefore cannot bypass the same closed contract used by offline validation.

## Ownership and capability

The declaring resource must:

- use a `synex_...` resource name;
- request `synex.world.bundle.register` in its resource descriptor;
- receive an operator grant for that capability;
- keep every owned bundle/object key in its own namespace;
- be `STARTED` in Core and `started` in Cfx at activation time.

A payload cannot claim another owner. The loader derives owner and epoch from Core's resource registry.

## Atomic activation

Activation compiles the full bundle, merges it with all active bundles, validates the combined graph, rebuilds a candidate spatial index, and swaps the registry only after every step succeeds. One invalid object therefore activates none of the candidate.

Replacement increments the global registry revision. The revision is bound before discovery to a disjoint 65,536-value range derived from the current Core-issued `synex_world` owner epoch, with at most 65,535 successful changes per World process. This prevents a fresh `synex_world` process under the same Core from reusing an earlier process's object revision. Removing or replacing a bundle tombstones its previous object keys so recent old `WorldRef` values fail closed. The registry retains at most 100,000 tombstone keys in recency order; an older evicted key resolves as `WORLD_NOT_FOUND` instead of being allowed to alias a different object.

## Lifecycle

Declared bundles are discovered from started resources. Up to 64 bounded discovery passes allow cross-resource dependency order to settle. A resource stop unregisters all bundles from that owner epoch. Explicit removal, manifest removal and owner stop also deactivate transitive bundles whose declared owner dependency or object reference would otherwise become invalid. The complete closure is validated and swapped atomically; dependent path mappings are discarded so a later dependency restart can rediscover them. Deactivating or replacing a bundle also drains live instances referencing one of its `instance_template` definitions, even when the gameplay instance has a different owner. World remains degraded while declared bundles are unresolved and clears that condition only after a complete discovery pass succeeds.

Runtime-only state for removed definitions is purgeable; durable state is intentionally retained for a compatible future definition and is schema-checked when read.

See [Companion-resource development](development.md) for a complete minimal layout.
