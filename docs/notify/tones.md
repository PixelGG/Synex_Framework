# Notification tones

`tone` communicates semantic meaning. It does not decide lifetime, placement,
queue precedence, or accessibility urgency.

| Tone | Meaning | Typical example |
| --- | --- | --- |
| `neutral` | No success/failure implication. | “Map marker updated.” |
| `info` | Useful explanatory information. | “Garage closes in 10 minutes.” |
| `success` | A confirmed successful outcome. | “Vehicle stored.” |
| `warning` | Recoverable risk or degraded state. | “Inventory nearly full.” |
| `danger` | Failure or harmful condition. | “Purchase failed.” |

Tone is rendered through a controlled Synex icon and compact signal marker, not
by tinting the whole surface. Text, iconography, state labels, and progress state
carry the meaning in addition to color. Payloads cannot submit arbitrary SVG,
HTML, URLs, CSS, or color values.

## Tone is not priority

A danger message can still be normal priority. A neutral system announcement
can be critical. Choose priority according to how urgently the player must know,
not according to red/green styling.

```lua
-- A failed background refresh is useful but not necessarily interruptive.
{
    kind = 'toast',
    tone = 'danger',
    priority = 'normal',
    title = 'Map data unavailable',
    message = 'Try again in a moment.',
}
```

Likewise, `success` never implies an assertive live region. Only an admitted
critical priority uses alert semantics; other tones/priorities remain polite.

## Legacy mappings

Compatibility adapters must use an explicit provider-specific map, for example
`primary -> info`, `success -> success`, and `error -> danger`. Unknown legacy
values must map conservatively or fail according to the reviewed adapter policy;
they must never become critical merely because the original API called them an
error.
