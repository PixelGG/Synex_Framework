# Glass and transparency

Glass is an optional material treatment, not the Synex design system itself.
It must earn its use through preserved spatial context or a clearer overlay
relationship.

## Required fallback

Every glass-like surface starts from a readable opaque or strongly translucent
background. `backdrop-filter` enhances that base only when the active profile
permits it. Content must remain understandable if blur is unsupported, disabled,
or too expensive.

Reduced-transparency mode disables blur and raises surface opacity. LOW quality
does the same. High contrast strengthens text, borders, focus rails, and state
separation independently of blur.

## Safe use

- Keep body text on a stable tonal plane.
- Use restrained blur radii and shadows.
- Avoid multiple overlapping blur surfaces.
- Never rely on game-scene darkness for contrast.
- Do not animate blur continuously.
- Test bright sky, night, vegetation, interiors, movement, and rapid camera
  changes in the actual client.

## Closed state

No material, overlay, pseudo-element, vignette, or backdrop may remain visible
when the runtime is closed. The React surface tree is unmounted, root elements
are transparent and pointer-free, and hidden surface timer work is stopped. The
shared frame retains no focus; native focus is released when no separate
resource-owned NUI holds an active lease. An active external lease may keep only
its bounded input-arbitration work running; it never makes this frame visible.

## Acceptance gate

CEF support declarations and browser previews are not sufficient evidence.
Glass composition over gameplay, fallback quality, text contrast, and GPU cost
in the exact production build are **NOT YET VERIFIED**.
