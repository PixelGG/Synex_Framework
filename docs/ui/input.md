# Input model

Synex UI normalizes input into device state and navigation intent. Components
remain semantic browser controls; intent routing supplements their native
keyboard behavior for a consistent FiveM controller path.

## Devices

The runtime recognizes `mouse`, `keyboard`, and `gamepad`. The active device is
used for adaptive hints, not for hiding functionality. A user can switch device
without reopening a surface.

## Navigation intents

The public intent vocabulary is deliberately finite:

- `UP`, `DOWN`, `LEFT`, `RIGHT`
- `CONFIRM`, `BACK`
- `NEXT_TAB`, `PREVIOUS_TAB`
- `PAGE_UP`, `PAGE_DOWN`

Browser payloads cannot name an arbitrary game control, command, native, route,
or event. New intents require a protocol change and tests.

## Ownership and routing

Intents are routed only while a valid focus lease is active. Owner resource,
owner epoch, active lease, current surface, and revision remain correlated.
Late input for a stopped or replaced owner cannot operate its successor.

Text entry continues to use native browser inputs. Directional controls use
roving focus or component-specific navigation. `BACK` requests a runtime close;
React hiding alone never releases native focus.

## Work while closed

There is no permanent frame loop for an inactive UI. Full navigation-control
polling is enabled only while an applicable focus lease exists. A separate
250 ms input-source sample runs while at least one passive Notify signal is
retained and stops with the final signal or runtime shutdown.

Passive Notify actions use the same central device state without acquiring a
focus lease. The caller-bound `synex_notify` UI facade accepts only the exact
`keyboard` and `gamepad` reports emitted by its registered F9/F10 and D-pad
command paths. In addition, the central runtime reads `IsUsingKeyboard` during
the bounded passive-signal sample so the first hint can distinguish keyboard
from gamepad before a player invokes an action. A changed state is sent to the
shared browser as a bounded `runtime:sync`; a state observed before browser
readiness is carried by the next ready snapshot. Duplicate states do not send
another message. This path never disables or captures controls, focuses the
NUI, shows a cursor, or enables keep-input.

## Consumer guidance

- Give every action an accessible name independent of its input hint.
- Do not bind product semantics directly to raw key codes in package components.
- Do not show controller-only or keyboard-only paths for required operations.
- Do not interpret a client-side input result as authorization.
- Do not use passive device reports for gameplay authority. They select
  presentation hints only.

Input switching, key repeat, text entry, pause-menu interaction, and resource
restart behavior in FiveM/CEF are **NOT YET VERIFIED**.
