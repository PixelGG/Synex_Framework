# Notification kinds

`kind` describes presentation and lifecycle. It is independent of semantic
`tone` and scheduling `priority`.

| Kind | Use | Avoid |
| --- | --- | --- |
| `toast` | Short, non-blocking information the player could otherwise miss. | Confirming every directly visible interaction. |
| `progress` | One mutable surface for one running operation. | Simulated percentages or a toast per stage. |
| `persistent` | A bounded ongoing condition that should not auto-dismiss quickly. | Durable records, large explanations, or unlimited warnings. |
| `banner` | Rare framework-wide or operationally important announcement. | Routine gameplay; it is capability-protected. |
| `status` | Quiet, low-emphasis ongoing state. | Repeated toast-like updates. |

## Choosing a kind

Use this order:

1. If the result is already visible, use no additional feedback.
2. If the relevant UI is open, show the state inline.
3. If the player must make a decision, use a dialog.
4. If one bounded background operation is changing, use `progress`.
5. If an ongoing condition would otherwise be missed, use `status` or
   `persistent` according to its lifetime.
6. Use a `toast` for a short missed-information case.
7. Reserve `banner` for reviewed exceptional announcements.

Examples:

- Moving an item inside an open inventory: inline state, no notification.
- Inventory becomes full after background pickup: `toast`, `warning`, `normal`.
- Vehicle purchase while the app closes: one `progress` surface that morphs to
  success or failure.
- Voice connection degraded: `persistent`, `warning`, usually `normal` or
  `high` only when genuinely time-sensitive.
- Planned server restart: privileged `banner`, with priority justified by the
  remaining time.

## Kind constraints

- A progress object belongs only to `kind = 'progress'`.
- Progress updates preserve the same notification identity.
- Progress rejects `dedupeKey` and `groupKey`; one operation keeps one explicit
  mutable handle.
- A `banner` requires `synex.notify.banner` in addition to normal send
  authority.
- Persistent signals remain bounded by the record and maximum-lifetime
  limits.
- Actions are limited to short hints; a kind does not turn a notification into
  a modal surface.
- `loading` is not a kind or tone. Use `progress.state = 'RUNNING'` with
  determinate or indeterminate mode.
