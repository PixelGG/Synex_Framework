# Interaction UI

`synex_interact` uses the shared `synex_ui` runtime. It does not ship a second fullscreen NUI, target eye or radial-menu clone.

## Surfaces

The checked-in Interaction Surface supports three bounded modes:

- `cue`: one compact target-relative primary intent and optional alternative count;
- `bloom`: a short list of already relevant alternatives;
- `progress`: determinate, timed or indeterminate interaction progress.

Client integration uses the caller/epoch-bound UI facade:

```text
upsertInteraction
removeInteraction
getInteractionSnapshot
bindInteractionActions
getPreferences
```

Descriptors are revisioned and schema-closed. Stale updates/removals fail closed. UI callbacks return only the selected intent/cancel intent for the current owner, epoch, interaction ID and revision; the Interact client then sends the canonical server request.

## Zero-mode and focus

Normal play has no interaction mode. The primary input activates the current primary intent; the more input opens the Action Bloom. The bloom does not enumerate arbitrary nearby targets.

The cue and progress surfaces are passive. Mouse/pointer focus is acquired only for a descriptor that explicitly opens a pointer-enabled bloom; mapped gamepad actions remain on the shared input route. The bloom uses roving keyboard focus, skips disabled intents, supports arrows or WASD plus Home/End, and activates only the focused enabled intent with Enter/Space. Pointer activation is bound to the button that was actually clicked. Closed or absent interaction state renders no surface, keeps `html`, `body` and `#root` transparent, and must not block input.

## Input and accessibility

Interact registers primary, more and cancel through Cfx command/key-mapping paths. Primary and cancel also have documented `MOUSE_BUTTON` mappings (`MOUSE_LEFT` and `MOUSE_RIGHT`); pointer selection and right-click cancellation inside an open bloom are handled by the focused NUI. Display hints are resolved from the current registered binding through Cfx's instructional-button path. If that path does not return a bounded printable text token, the UI shows the semantic action name instead of guessing the default E/G/X binding. The UI runtime provides keyboard and pointer bloom navigation, reduced motion, high contrast, safe-zone-aware projection, screen-edge clamping and Interaction Assist preferences. No accessibility preference changes server authority, distance, capability or lease rules.

Timed progress starts from the server-declared elapsed/duration pair and advances on the browser's monotonic clock until it reaches, but never exceeds, the declared duration. Its timer is removed on completion, descriptor replacement and unmount. Determinate progress renders only the graph-declared `value` and `maximum`; indeterminate progress contains no invented percentage.

The client reads the bounded local preference facade when binding and then polls it at most once per second. Interaction Assist widens only the observed gaze cone and increases focus-switch dwell; `reducedMotion` and `highContrast` remain presentation-only. Preference values are not added to lease or activation requests.

## Presentation boundary

Projection is stabilized to avoid jitter and kept compact to minimize screen obstruction. `synex_notify` is not used for immediate interaction progress; Notify remains appropriate only for a separate result that would otherwise be missed.

Automated browser checks do not prove real CEF focus, controller, safe-zone, ultra-wide, gameplay readability or performance. Those remain [live gates](testing.md).
