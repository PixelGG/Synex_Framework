# Design language

Synex uses a precision-oriented dark interface language: mineral graphite
planes, cool neutral text, mapped cyan/blue signals, and restrained violet
transition accents. It should read as software infrastructure, not a generic
dark dashboard or gaming overlay.

## Visual grammar

- **Precision rails:** active routes and focus are communicated with paired
  rails or short directional markers rather than broad neon glow.
- **Notched geometry:** controlled clipped corners and offsets establish a
  technical silhouette without making every container decorative.
- **Material hierarchy:** depth comes from surface material, border contrast,
  tonal separation, and shadow discipline before blur.
- **Sparse signal color:** accent color identifies interaction, selection, or
  state. It is not a background decoration.
- **Square labels:** compact metadata, shortcuts, and status identifiers use
  restrained mono typography and crisp geometry.
- **Measured motion:** movement explains entry, exit, focus, or state change.
  Idle decoration is avoided.

## Quality principles

1. Clarity before decoration.
2. Hierarchy before effects.
3. Material before glow.
4. Interaction feedback before animation.
5. Consistency before novelty.
6. Identity without visual noise.

Minimal does not mean empty black boxes or an interchangeable corporate
dashboard. Synex should feel recognizable, premium, confident, technical, and
modern without becoming gimmicky or visually eccentric.

## Typography

IBM Plex Sans Variable is the primary interface family. JetBrains Mono Variable is
reserved for identifiers, numeric telemetry, key hints, and code-like metadata.
Both are packaged locally; production UI does not depend on remote font hosts.

Use the type scale rather than ad-hoc font sizes. Text must remain readable at
all supported UI scales, density modes, constrained heights, and ultrawide
layouts. Do not reduce important copy to decorative microtext.

The shared roles are `display`, three heading levels, `body`, `body-small`,
`caption`, `label`, `numeric`, `code`, and `monospace`. Display and headings
establish hierarchy; body roles carry prose; labels/captions support controls
and metadata. Numeric, code, and monospace roles use tabular figures and the
local mono family for balances, telemetry, timers, identifiers, and timestamps.
They do not replace readable labels or units.

## Motion

Motion is named by purpose: enter, exit, focus, selection, confirmation,
loading, drag, error, and success. Each intent resolves to the shared
instant/fast/normal/slow scale and an approved easing curve. This lets domain
applications communicate the same state change in the same visual language
without copying raw timing values.

Prefer opacity and transform. Animate layout dimensions only when the spatial
change itself carries meaning. Loading may repeat while work is active; other
motion should settle. Reduced-motion preference collapses non-instant timings
without hiding feedback, focus, confirmation, success, or error state.

## Color and status

Neutral graphite establishes structure. Cyan and blue communicate selection,
focus, and active routes. Violet is a secondary transition accent, not a global
gradient default. Success, warning, danger, and information retain distinct
semantic channels and pair color with text, shape, or iconography.

Do not use:

- purple gradient backgrounds as the main identity;
- glow around every element;
- glass on every surface;
- excessive pill containers or nested cards;
- fake terminal/code decoration;
- gameplay-specific imagery in generic components;
- animation whose only purpose is spectacle.

## Responsive composition

Composition follows safe-area variables and container constraints rather than a
single 1920x1080 canvas. Important actions remain reachable on constrained
height, 21:9, and 32:9 displays. Ultrawide space is not permission to stretch
reading measures or controls indefinitely.

The final appearance over bright, dark, and moving gameplay scenes remains a
real FiveM/CEF acceptance gate and is **NOT YET VERIFIED**.

## Domain personalities

Domain resources may adjust expression without breaking the shared DNA. An
inventory can be denser and tactile, banking calmer and more numerical, a phone
more layered and personal, and low-obstruction interaction prompts substantially
quieter. They still use the same typography foundation, controls, focus and
selection language, icon direction, motion logic, spacing system, and material
engine.
