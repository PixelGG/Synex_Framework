# Developing a World companion resource

A companion resource adds Synex semantics without modifying the map/MLO resource itself.

## Minimal layout

```text
synex_world_my_map/
├── fxmanifest.lua
├── synex.resource.json
└── world/
    └── my-map.world.json
```

Use the checked-in [`synex_world_companion`](../../examples/synex_world_companion/README.md) example as a schema-valid starting point. Its coordinates and model hash are illustrative and are not live certification for a map.

## Resource descriptor

Declare each file through `worldBundles` and request the registration capability:

```json
{
  "capabilities": {
    "request": ["synex.world.bundle.register"]
  },
  "worldBundles": ["world/my-map.world.json"]
}
```

The operator must separately grant `synex.world.bundle.register`; a request alone is not authorization. Declare `synex_core` and `synex_world` as required resource dependencies. Add each bundle to the FiveM `files` list.

## Authoring rules

1. Name the resource `synex_...` and use that exact prefix before `:` for every owned key.
2. Create the map package first, then locations and containment parents before their children for readability (the compiler does not depend on file order).
3. Keep map assets in their original resource and reference its actual resource name. Associate the package with its root locations; availability then propagates through their containment children.
4. Use composite unions for disconnected location shapes.
5. Keep anchors, doors and portals semantic; put prompts/actions in `synex_interact` bundles.
6. Treat tags as filters, never authorization.
7. Add access policies only with real Groups IDs/capabilities and World state definitions.
8. Use revisioned refs returned by the runtime; do not hard-code a runtime revision in source.

## Offline checks

Run from the repository root:

```text
node --experimental-strip-types tools/cli/src/bin.ts world validate
node --experimental-strip-types tools/cli/src/bin.ts world inspect synex_world_my_map:site
node --experimental-strip-types tools/cli/src/bin.ts world graph synex_world_my_map:site
node --experimental-strip-types tools/cli/src/bin.ts world locate <x> <y> <z>
node --experimental-strip-types tools/cli/src/bin.ts world overlaps
node --experimental-strip-types tools/cli/src/bin.ts doctor world
node --experimental-strip-types tools/cli/src/bin.ts benchmark --iterations 100 --json
```

`world doctor` deliberately reports runtime status `UNKNOWN`: offline tooling cannot prove Cfx resource state, client streaming, door entities, routing buckets or live presence.

Offline validation mirrors the runtime's 1,024-bundle/100,000-object catalog bounds, composite depth `4`, minimum geometry extent/vertical span/shoelace area `0.001`, state parent/scope rules and primitive access-state value/hierarchy checks. The schema cannot express every cross-object or cross-field rule by itself, so `world validate` must remain part of authoring review.

The benchmark command includes seven actual World Lua paths over its fixed 66,000-object fixture and caps World iterations at 5,000. It is useful only for deterministic local regression comparison; it does not run FXServer, FiveM natives, OneSync, MariaDB, a client or concurrent workload.

## Live acceptance

Before deployment, test the exact map and bundle on the intended FXServer artifact with OneSync and a real client. Verify context boundaries, door hashes/models, IPL/entity-set names, teleport destinations, map stop/restart, companion stop/restart and cleanup. Record failures as candidate-specific evidence; do not convert an offline PASS into a live certification claim.
