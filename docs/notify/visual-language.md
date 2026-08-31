# Signal Surface visual language

Notify uses the shared `synex_ui` visual foundation but has its own compact
feedback grammar: the **Signal Rail** places a bounded stack; each **Signal
Surface** combines a semantic marker, small icon, precise copy, optional count,
optional action hints, and the **Signal Rail progress line**.

The result is deliberately quieter than a marketplace-style toast card. Quality
does not come from a full-card red/green tint, giant icon, glowing outline,
sparkles, oversized pill, or unrestricted blur.

## Anatomy

```text
│  icon  Title                                  ×3
│        Optional message, bounded to two lines
│        ━━━━━━━━━━━━━ progress / state ━━━━━━━
│        [G] Undo
```

- The narrow marker and controlled icon communicate tone without dominating the
  surface.
- The title owns the primary hierarchy; the message is secondary.
- Count communicates dedupe/group compaction without adding cards.
- Progress uses a three-pixel integrated rail rather than a large standalone
  bar.
- Actions are hints, not pointer controls.

## Material and quality

The surface consumes `@synex/ui` `Surface`, typography, icon, shadow, spacing,
radius, color, motion, and quality tokens. Its normal material is a small subtle
translucent surface, never a full-screen backdrop. LOW quality and reduced
transparency use the solid Synex surface token with the same hierarchy.

Resources cannot submit material parameters, CSS, arbitrary colors, SVG, image
URLs, or HTML. `iconKey` is selected from the controlled registry; otherwise the
renderer chooses a tone/progress-state icon.

## Placement and screen geometry

Supported presentation positions are:

```text
top-right    top-center    top-left
bottom-right bottom-center bottom-left
```

The rail consumes `synex_ui` safe-area and overlay-reservation variables rather
than domain-specific pixel offsets. Right/left rails include the corresponding
safe inset and reserved edge; centered rails include their reserved center
offset. Bottom rails grow upward.

The client and browser derive the same visible capacity from the safe viewport,
UI scale, density, narrow-viewport wrapping allowance, and conservative maximum
Signal Surface height. The result is bounded from one through four; four remains
the hard maximum. The client engine owns promotion and demotion so browser-only
clipping cannot consume a hidden notification's visible lifetime. The rail width
is responsive and capped by the remaining safe viewport. The title ellipsizes,
the message wraps anywhere and clamps to two lines, and counts/progress use
tabular numerals.

Short exit motion retains a removed surface for 140 ms in a non-actionable
`dismissing` phase. During that interval it can occupy a physical rail slot, so
a newly selected signal is not considered visible merely because it is next in
the logical set. The browser ACK reports only entries actually in the `active`
phase and includes the calculated capacity; action hints and F9/F10 remain
unavailable until Notify confirms the exact generation, revision, and capacity.

A resource may request a valid position, but owner-scoped presentation contexts
can reserve positions and supply a preferred/fallback order. Selection falls
back through the deterministic canonical order and accepts no arbitrary pixel
offset. Do not repeatedly move a player's notification stack to suit one
domain.

The player can set one process-local preferred position or leave it on `auto`.
That preference is applied before the resource's requested position when the
rail is not reserved; presentation-context reservations and deterministic
fallbacks still prevent overlap. A 50-200 percent duration scale changes timed
surface lifetime within the canonical duration and hard-lifetime bounds. It
does not alter animation speed, queue priority, or critical semantics.

Action-hint glyphs follow the central `synex_ui` input-device state when a
resource does not provide explicit hint text. Keyboard/mouse state uses F9/F10;
gamepad state uses D-pad Left/Right. The visual hint never turns the passive
surface into a pointer control and never grants gameplay authority.

## Motion

Normal motion is short and state-driven:

```text
enter -> settle -> update/morph -> dismiss
```

Determinate progress changes the integrated rail. Indeterminate progress uses a
bounded rail segment only while the operation is genuinely indeterminate.
Terminal progress changes tone/icon/state on the same surface before dismissal.
No visible notification has an idle animation.

Reduced motion removes translation, blur, and unnecessary looping while keeping
opacity/state feedback. Stack reflow must remain controlled and must not cause
large screen travel.

## Closed and passive state

When there are no signals and no interactive shared UI surfaces, the runtime
returns no visible application subtree. `html`, `body`, and `#root` remain
transparent and non-interactive. A signal makes the root visible but does not
make it interactive; only an actual focused shared surface enables pointer
events.

This is especially important because Cfx fullscreen NUI pages are full-screen
iframes and focused resources occupy a limited focus stack. See the official
[Fullscreen NUI focus model](https://docs.fivem.net/docs/scripting-manual/nui-development/full-screen-nui/).

## Visual acceptance

Automated component and screenshot fixtures can detect deterministic layout,
role, quality-profile, long-copy, and resolution regressions. They cannot prove
readability over actual GTA scenes, safe-zone behavior on the target artifact,
CEF blur cost, perceived motion, or controller coexistence.

Before maturity promotion, review the exact candidate at 1080p, 1440p, 4K,
21:9, and 32:9; every supported scale and quality profile; reduced motion,
reduced transparency, and high contrast; all tones/kinds; grouped/count states;
determinate/indeterminate/terminal progress; and focused inventory/phone
coexistence. The current repository evidence is not a production visual
certification; the Signal Surface remains **Experimental Alpha** until its real
CEF, controller, accessibility, and measured Resmon gates pass.
