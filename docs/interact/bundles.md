# Interaction bundles

Interaction bundles are closed, resource-owned JSON documents discovered from `synex.resource.json`.

## Layout

```text
synex_my_resource/
├── fxmanifest.lua
├── synex.resource.json
└── interactions/
    └── terminal.interact.json
```

The resource descriptor lists strict relative paths:

```json
{
  "interactionBundles": ["interactions/terminal.interact.json"]
}
```

Paths must remain under `interactions/`, end in `.interact.json`, contain no traversal or double separator, and be unique. The file must also appear in the FiveM `files` declaration.

## Bundle document

Every bundle contains:

```json
{
  "schemaVersion": 1,
  "key": "synex_my_resource:terminal",
  "revision": 1,
  "smartObjects": [],
  "intents": [],
  "graphs": []
}
```

All owned keys use the exact resource namespace. The compiler validates field shapes, references, uniqueness, graph structure, bounds and discovery projection before activation.

## Activation and replacement

Discovery reads only files declared by the current started resource manifest. The owner must request and receive `synex.interact.bundle.register`; requesting it in JSON is not authorization. Registration is owner/epoch-bound. A conflicting key or child definition fails closed.

Activation is atomic: invalid candidate definitions do not partially change the active registry. Replacement requires the expected revision and revokes affected leases/sessions before applying the successor. Owner stop unregisters its bundles and extensions.

The client receives only the bounded discovery projection required for context and presentation. Execution policy and Action Graph internals remain server-side.

Use the [companion example](../../examples/synex_interact_companion/README.md) as a schema-valid starting point.
