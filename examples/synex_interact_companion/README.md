# Synex Interact companion example

This minimal declarative resource pairs one real `synex_world` Anchor definition with one `synex_interact` Smart Object, slot, intent and Action Graph. It contains no Lua handler, database table or gameplay-domain mutation.

> [!IMPORTANT]
> This is an **Experimental / Alpha integration fixture**, not a certified map placement. The concrete GTA coordinates are intentionally visible and schema-valid, but must be inspected and relocated for the map/server that will use them. Repository validation does not prove that the point aligns with a physical prop or remains unobstructed in a particular map build.

## Contents

```text
synex_interact_companion/
├── fxmanifest.lua
├── synex.resource.json
├── world/
│   └── terminal.world.json
└── interactions/
    └── terminal.interact.json
```

The World bundle owns `synex_interact_companion:terminal_anchor`. The Interaction bundle binds `synex_interact_companion:terminal` to that key, reserves one `operator` slot, exposes one `inspect` intent and executes `verifyTarget -> progress -> complete`. The graph has no commit or domain adapter, so it cannot change durable state.

## Adapt it

1. Copy the directory and rename it to a unique `synex_...` resource.
2. Change `name` in both manifests and every namespaced key prefix.
3. Measure the intended point in the exact map build; replace the location geometry and anchor coordinate.
4. Adjust slot radius/facing and presentation copy for the real object.
5. Add a typed domain adapter only if a real owning domain operation is required; do not add SQL or arbitrary events to the graph.
6. Request and obtain operator grants for `synex.world.bundle.register` and `synex.interact.bundle.register`. The checked-in policy grants only this exact canonical companion name; renamed or copied examples remain fail-closed until explicitly granted.
7. Start dependencies in manifest order and perform the exact live tests below.

## Repository validation

From the repository root:

```text
npm run validate
npm run test:tooling
node --experimental-strip-types tools/cli/src/bin.ts validate examples/synex_interact_companion --json
node --experimental-strip-types tools/cli/src/bin.ts certify resource examples/synex_interact_companion
```

The targeted `validate` command passes for the checked-in fixture, the committed policy grants its two exact bundle-registration capabilities, and the focused repository test verifies its cross-bundle references and side-effect-free graph. An offline PASS proves descriptor, schema, namespace and reference consistency only; it does not replace the live acceptance below.

## Live acceptance

With OneSync, the exact FXServer candidate and a real client, verify World/Interact discovery, cue position, camera/ray behavior, server distance/revision denial, lease activation, timed progress, cancellation, disconnect cleanup, companion stop/start and stale-owner rejection. Record Resmon/profiler evidence rather than making an unmeasured performance claim.

See the [Interact development guide](../../docs/interact/development.md), [bundle rules](../../docs/interact/bundles.md), [World integration](../../docs/interact/world-integration.md) and [security model](../../docs/interact/security.md).
