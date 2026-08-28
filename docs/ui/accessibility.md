# Accessibility

Accessibility behavior is part of each component contract, not a theme option.

## Baseline

- Use semantic HTML controls and landmarks before ARIA substitutes.
- Every input has a visible label or explicit accessible name.
- Validation is linked with `aria-describedby` and `aria-invalid`.
- Modal focus is trapped, Escape/Back requests close, and focus is restored.
- Roving-focus composites keep one tab stop and support directional keys.
- Visible focus uses the Synex paired-rail treatment and is never removed.
- Status and validation never rely on color alone.
- Loading and progress expose meaningful text or ARIA state.
- Text and actions remain usable at all supported scales and densities.

## Preferences

`reducedMotion` suppresses nonessential transforms, sweeps, and looping motion.
It does not remove state feedback. `reducedTransparency` replaces blur with
opaque hierarchy. `highContrast` strengthens text, borders, focus, and status
separation. These flags are independent and may be active together.

## Keyboard and controller

Tab moves between independent controls. Arrow keys move inside composite widgets
such as tabs, segmented controls, menus, and trees. Home/End behavior is used
where the component supports it. Enter/Space activates the focused control.
Escape closes the innermost dismissible layer through the runtime lifecycle.

Controller intents mirror the same conceptual operations. Device-specific hints
supplement, rather than replace, accessible labels.

## Content resilience

Consumers must test long labels, unbroken identifiers, localized text, empty
states, validation errors, constrained height, and ultrawide screens. Truncation
must not hide the only copy of a protected value or required instruction.

## Acceptance gate

Automated semantic and browser tests cannot prove assistive-technology behavior
inside the target CEF. Keyboard-only, controller, screen-reader-relevant naming,
contrast over gameplay, reduced-motion, reduced-transparency, and high-contrast
passes in real FiveM remain **NOT YET VERIFIED**.
