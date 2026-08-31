# Gamepad support

Controller navigation is part of the Synex interaction model. It is not inferred
from mouse hover and it must not depend on a permanently visible cursor.

## Intent mapping

The client maps the standard frontend controls to the bounded intent vocabulary:
directional navigation, confirm, back, previous/next tab, and page up/down. The
browser receives intents rather than raw native identifiers.

When an applicable lease is active, the runtime observes disabled-control
presses and identifies whether the last input source is keyboard/mouse or
controller. Passive Notify signals use only a 250 ms `IsUsingKeyboard` sample;
they never disable or capture controls. Both loops stop when the relevant lease
or final passive signal is gone.

## Component behavior

- Lists, menus, segmented controls, tabs, and trees use a single roving tab stop.
- Confirm activates the focused option.
- Back closes the innermost dismissible surface through Lua.
- Previous/next tab changes a tab group without forcing pointer movement.
- Page intents move bounded data views by a visible page or viewport.
- Focus remains visible in controller mode even when the mouse is idle.

Adaptive `KeyHint` content may change with the active device, but the label and
operation remain the same.

## Design constraints

- Do not require hover to discover an action.
- Avoid tiny targets and dense side-by-side destructive actions.
- Keep focus inside modal surfaces and restore it after close.
- Preserve an escape route when validation fails or data is unavailable.
- Do not depend on vibration or audio as the only feedback channel.

## Acceptance gate

The current browser/component behavior is development evidence only. A physical
controller must still verify device switching, focus order, repeats, text-input
handoff, close behavior, suspended leases, and restart recovery in FiveM. This
gate is **NOT YET VERIFIED**.
