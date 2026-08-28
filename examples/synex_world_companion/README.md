# Synex World companion example

This minimal resource shows how a custom map/MLO can declare Synex World semantics without modifying or redistributing the map resource.

> [!IMPORTANT]
> This is an authoring example, not a drop-in live map. `custom_mlo_example`, the coordinates and door model hash `1234` are illustrative. Replace them with values verified against the map you own before starting the companion. The example has not passed a real-client DoorSystem, IPL or transition test.

## Contents

```text
synex_world_companion/
├── fxmanifest.lua
├── synex.resource.json
└── world/
    └── example.world.json
```

The bundle demonstrates one map package, composite location, interior, room, anchor, double-leaf logical door, teleport portal and runtime state definition.

## Adapt it

1. Copy the directory and rename it to a unique `synex_...` resource.
2. Change `name` in both manifests.
3. Replace every `synex_world_companion:` key prefix with the new resource name.
4. Replace `custom_mlo_example` with the exact Cfx resource name of the map.
5. Replace all geometry, portal destinations, leaf positions and model hashes with values measured in that map.
6. Keep the map resource separate; list its actual dependencies in the map package when needed.
7. Request and receive an operator grant for `synex.world.bundle.register`.
8. Validate the repository bundle, then run a real-client acceptance test.

From the repository root:

```text
node --experimental-strip-types tools/cli/src/bin.ts world validate
node --experimental-strip-types tools/cli/src/bin.ts world inspect synex_world_companion:example_site
node --experimental-strip-types tools/cli/src/bin.ts world graph synex_world_companion:example_site
```

Start the real map resource before this companion. `synex_core` and `synex_world` must already be ready. An offline PASS proves schema/reference consistency only.

See the [World development guide](../../docs/world/development.md), [bundle rules](../../docs/world/bundles.md) and [security boundary](../../docs/world/security.md).
