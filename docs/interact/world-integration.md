# `synex_world` integration

World owns semantic places and revisioned spatial truth. Interact consumes that truth; it does not duplicate it.

## Direct World references

A World bundle declares an anchor:

```json
{
  "kind": "anchor",
  "key": "synex_my_resource:terminal_anchor",
  "position": { "x": 0.0, "y": 0.0, "z": 72.0 },
  "radius": 0.75
}
```

The Interaction bundle binds its Smart Object to the exact kind and key:

```json
{
  "type": "worldRef",
  "kind": "anchor",
  "key": "synex_my_resource:terminal_anchor"
}
```

`kind` accepts only `anchor`, `door` or `portal`. The older `worldAnchor` binding remains a supported anchor shorthand. New bundles should prefer `worldRef` so the World object kind cannot be inferred incorrectly.

The client queries bounded nearby anchor/door/portal objects from the current World slice. A lease request carries the exact kind, key and revision. The server resolves that reference again, verifies the active source-generation/session fence before and after World calls, and resolves the current World context before the canonical object. Only then does it sample the current player position, resolve the canonical position (anchor position, declared door position with a nearest-leaf fallback, or portal source) and check distance. Authorization paths reacquire the reference and World-instance fence after yielding policy/availability work before mutation. Client World state remains observed discovery evidence only.

## Domain boundaries

- A World Anchor, Door or Portal describes spatial/semantic truth; it is not itself an action.
- Door state and access remain World operations. An Interact adapter may request a typed World operation only after lease/policy checks.
- Portal eligibility, grants, destinations and instance transitions remain World authority.
- World state requirements belong in canonical server execution policy/domain checks, never only in client visibility.
- State bags or the client World cache are hints, not authorization.

The checked-in [companion](../../examples/synex_interact_companion/README.md) pairs one concrete anchor with one inspection interaction and deliberately performs no domain mutation.
