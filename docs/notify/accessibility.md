# Notification accessibility

The Signal Surface is passive presentation backed by one central announcement
pipeline. It communicates state without moving browser focus, capturing a
pointer, or taking keyboard/gamepad navigation from an open inventory, phone,
dialog, or other UI.

## Live-region policy

| Projection | Browser semantics |
| --- | --- |
| visual Signal card | named `role="group"`; never an independent live region |
| central critical announcement | stable `role="alert"`, atomic/assertive endpoint |
| central non-critical announcement | stable `role="status"`, atomic/polite endpoint |
| determinate progress | named `role="progressbar"` with minimum, maximum, and current value |
| indeterminate progress | named `role="progressbar"` without a fabricated current value |

Success is not automatically assertive. High priority is still a polite status;
only the separately capability-gated critical class can interrupt the assistive
technology announcement queue.

This matches the WAI-ARIA distinction: [`status` is advisory and implicitly
polite](https://www.w3.org/TR/wai-aria-1.2/#status), while [`alert` is important,
time-sensitive, and implicitly assertive](https://www.w3.org/TR/wai-aria-1.2/#alert).
Neither role requires focus. If a response or focus move is required, use a
[`dialog` or `alertdialog`](https://www.w3.org/TR/wai-aria-1.2/#alertdialog)
through `synex_ui`, not a notification.

## Announcement pressure

Visual cards never carry `aria-live` themselves. `synex_ui` projects their
plain text through one serialized queue into the two stable polite/assertive
endpoints. This prevents a four-card render or an `x2` through `x20` grouping
burst from becoming parallel live-region spam.

The queue applies fixed bounds:

- updates to the same owner/epoch/signal identity coalesce for an anchored
  120 ms window; more updates cannot extend that window indefinitely;
- at most 32 announcements wait, while at most 64 delivered signatures are
  retained solely to reject unchanged re-projections;
- exactly one coalesce timer and one playback/gap timer can exist;
- one item occupies a live endpoint for 800 ms, followed by an 80 ms clear gap;
- critical, high, normal, and low entries are ordered by priority, then FIFO;
  a critical entry takes the next slot ahead of waiting normal entries without
  deleting them;
- only at the hard pending limit may a higher-priority entry replace the newest
  lowest-priority pending entry. Equal/lower-priority overflow is rejected
  rather than displacing older queued speech;
- pending entries are removed when their Signal card is no longer active.

A counted duplicate updates one staged announcement, so the spoken result uses
the latest grouped count. Stale revisions and unchanged newer projections do
not announce again. The accessible string is constructed as text from the
validated title, optional message, group count, progress state, and action
labels. Payload markup is never interpreted, and device-hint changes do not
reannounce an otherwise unchanged notification.

Callers should keep titles specific and messages short. Do not send timer ticks,
fake progress values, or repeated “still working” text. Real progress updates
are coalesced before browser projection and again inside the bounded 120 ms
announcement window.

## Non-color semantics

Tone is expressed through all of:

- plain text title/message;
- a controlled semantic icon;
- the compact signal marker;
- progress state text and rail state where applicable;
- the priority/live-region policy.

Color is supplementary. Payloads cannot provide arbitrary color, SVG, or HTML.
Grouped counts have an accessible label in addition to the visible multiplication
mark.

## Motion, transparency, contrast, and scale

The surface inherits independent `synex_ui` preferences:

- `reducedMotion` removes nonessential translation/blur and looping
  indeterminate motion while retaining visible state changes;
- `reducedTransparency` replaces translucent material with the solid surface
  fallback;
- `highContrast` strengthens the shared token contrast and state separation;
- UI scale and density adjust the shared type/spacing system and may reduce the
  visible stack from the hard maximum of four when the safe viewport cannot fit
  the conservative maximum surface envelope.

No notification performs idle pulse, glow, bounce, or continuous movement.
Animation is limited to enter, update/morph, progress, and dismiss state.

## Actions and input

Action labels and device hints are plain, non-focusable presentation. The Signal
Surface has `pointer-events: none`; it never becomes a row of tiny browser
buttons. When a caller omits `hint`, the Signal Surface uses `synex_ui`'s central
input-device state to show F9/F10 for keyboard or mouse and D-pad Left/Right for
gamepad. Notify does not independently guess the active device. A caller-supplied
hint is text only and cannot create a binding. Notify's client action binding
invokes the associated short-lived token and the server revalidates the exact
session, notification revision, owner epoch, expiry, and replay state. While at
least one passive signal exists, the central UI runtime samples FiveM's current
keyboard-versus-gamepad mode every 250 ms so the first visible action hint does
not require a blind controller command.

Hints are initially withheld until the browser acknowledges that the signal is
actually in its `active` phase. The resulting action-bearing revision needs its
own current ACK before F9/F10 is enabled. The 140 ms dismissing phase is not
reported as actionable. A missing or stale visibility ACK, CEF/UI restart, or
failed callback disables F9/F10 until bounded retry/reconciliation succeeds;
accessibility text never implies that a displayed hint is gameplay authority.

The central device state is shared with focused `synex_ui` surfaces and changes
from validated browser keyboard/pointer reports, focused native gamepad intent,
or an actual registered Notify action command. Passive signal sampling only reads
`IsUsingKeyboard`; it never disables or captures a control. F9/F10 reports
`keyboard`; the separate D-pad Left/Right command paths report `gamepad`. The
report is bound to the current `synex_notify` UI facade and accepts no
caller-selected owner. It
updates presentation hints only and is not gameplay authorization. No focus
lease, disabled control, cursor, or keep-input state is introduced. The bounded
sampling loop exists only while a signal is retained and stops with the final
signal. A hint can therefore describe the current shared input mode without
taking focus from another UI. Exact keyboard and controller behavior remains a
real-client acceptance item.

An action must remain understandable without its hint and must not be the only
way to perform a safety-critical decision. More than two choices, text entry,
confirmation, editing, or details require a normal focused UI surface.

## Content resilience

Titles and messages are bounded before rendering. The surface truncates the
single-line heading and clamps the message visually while keeping the full
validated UI projection in accessible content. The orchestration message limit
is 720 bytes; the client-to-UI projection is a Unicode-safe prefix of at most
512 bytes. Resource authors must put detailed instructions or durable facts in
a domain UI rather than depending on either boundary.

Test at every supported scale with localized text, unbroken identifiers, Unicode
edge cases, and no message body. Never put a secret, account identifier, token,
or technical exception into user-facing text.

## Verification boundary

Automated TypeScript/browser tests cover parsing, dedicated role selection,
plain-text projection, serialization, grouped-burst coalescing, critical
priority, unchanged-content dedupe, timer cleanup, progress ARIA attributes,
stale revisions, visible bounds, preferences, and closed-state DOM. They do not
prove how a specific assistive technology voices live-region changes in the
target FiveM CEF. Keyboard/controller action hints, real screen-reader output,
contrast over live gameplay, reduced preferences, and coexistence with focused
domain UIs still require an exact-candidate real-client pass.
