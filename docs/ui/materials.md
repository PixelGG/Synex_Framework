# Material system

Materials communicate hierarchy and context. They are not interchangeable
decorations.

## Variants

| Material | Intended role |
| --- | --- |
| `solid` | Reliable default for content and constrained profiles. |
| `elevated` | Important content above a base plane without transparency. |
| `translucent` | Context-preserving surface with an opaque fallback. |
| `glass` | Select overlays where background context is useful. |
| `frosted` | Stronger separation for modal or dense overlay content. |
| `acrylic` | Richest layered material for sparse, high-priority surfaces. |
| `floating` | Compact menus, popovers, and transient controls. |
| `immersive` | Large focused flow with deliberate backdrop treatment. |

## Selection rules

- Start with `solid` or `elevated`.
- Use transparent materials only when seeing context improves the task.
- Keep primary text and actions on a reliably contrasted inner plane.
- Use one dominant material per region; avoid stacked blur panes.
- Prefer border and tone separation over larger shadows or stronger glow.
- `floating` does not imply modality. Focus behavior comes from the component
  and runtime lease, not its appearance.
- `immersive` is not permission to leave an opaque fullscreen layer mounted
  after close.

## Quality degradation

Every transparent material has a solid/translucent fallback. LOW and reduced-
transparency modes remove expensive blur and increase opacity. BALANCED keeps
limited transparency. HIGH and ULTRA may add controlled blur and depth when the
component and scene justify it.

The fallback must preserve boundaries, readable contrast, focus indication,
and semantic status. Visual quality profiles never change available operations.

## Verification

Browser screenshots can establish internal consistency, but they do not prove
how backdrop filters compose with the gameplay framebuffer. Glass, frosted, and
acrylic materials over real gameplay and their GPU cost are **NOT YET VERIFIED**
and remain a FiveM/CEF acceptance gate.
