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

There is no permanent frame loop for an inactive UI. Controller polling is
enabled only while an applicable focus lease exists, and listeners/timers are
cleaned up when surfaces close or the runtime stops.

## Consumer guidance

- Give every action an accessible name independent of its input hint.
- Do not bind product semantics directly to raw key codes in package components.
- Do not show controller-only or keyboard-only paths for required operations.
- Do not interpret a client-side input result as authorization.

Input switching, key repeat, text entry, pause-menu interaction, and resource
restart behavior in FiveM/CEF are **NOT YET VERIFIED**.
