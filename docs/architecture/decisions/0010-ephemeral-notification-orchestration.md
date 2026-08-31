# ADR-0010: Ephemeral notification orchestration and passive Signal Surface

- Status: Accepted
- Date: 2026-08-28
- Scope: `synex_notify`, `synex_ui`

## Context

Framework resources need consistent feedback without each domain inventing its own
toast lifecycle, priority rules, spam protection, progress behavior, action
transport, and visual language. A simple notification export would leave queue
pressure, duplicate bursts, owner restarts, source reuse, and accessibility to
every caller. A separate notification NUI would also compete with the shared UI
runtime for full-screen layering and input focus.

Notifications are not durable business facts. A transfer, inventory mutation, or
vehicle purchase remains authoritative in its owning domain. Persisting every
temporary message as an inbox would introduce a database and offline-delivery
contract that the feedback layer does not need.

## Decision

Adopt `synex_notify` as the resource-owned Feedback & Notification Orchestration
Engine. It owns validation, lifecycle, revisions, rate limits, priority
arbitration, queueing, deduplication, grouping, progress, action tokens,
presentation policy, cleanup, and bounded diagnostics. Its canonical service is
`synex.notify@1`; the resource also exposes caller-bound `GetAPI('^1.0.0')`
facades on the server and client.

Generic client presentation contexts are bounded and owner/epoch-scoped. They
may express quiet state, canonical position reservations, and preferred/fallback
positions, but not domain rules or arbitrary pixel geometry.

All notification, queue, history, action, owner, and delivery state is bounded
and in memory. There is no notification table, offline inbox, or replay after a
Notify process restart. Domain resources must retain their own durable truth.

`synex_core` is required. Core supplies server caller identity, owner epochs,
capabilities, active session resolution, source-generation fencing, services,
metrics, and optional Control-provider registration. Server delivery accepts an
exact `{ source, sessionId, sourceGeneration }` reference; a bare source is not a
safe target. Client callers can create only local feedback and cannot select
another player.

The raw Cfx server-to-client event is a wake-up mechanism, not a payload trust
boundary. Canonical server commands are retained briefly in a bounded Notify
registry and referenced by an opaque ID. The client redeems that ID through an
ACTIVE-session Core RPC; Notify atomically releases it only when source,
session ID, and source generation match the recorded target. Raw wake input
cannot choose origin, owner, generation, action data, or presentation content.

`synex_ui` is a controlled optional dependency. When available, Notify projects
plain, bounded, revisioned signal DTOs into its shared browser runtime. The
runtime renders a passive Synex Signal Surface and Signal Rail using shared
tokens, materials, icons, motion, preferences, and screen metrics. Notifications
never acquire keyboard, pointer, or gamepad focus; a complex decision belongs in
a proper `synex_ui` dialog. When the UI runtime is unavailable, Notify reports a
degraded state and admits only its deliberately narrow, text-only critical
fallback path. It does not redirect ordinary gameplay feedback into a noisy
native feed.

Requests pass through a fixed bounded pipeline:

```text
request -> validation -> owner/session fence -> capability -> rate budget
        -> deduplication -> grouping -> presentation policy -> priority queue
        -> visible Signal Surface
```

Mutable notifications carry monotonic revisions. Handles include notification
identity, owner resource, owner epoch, and revision; stale owners and stale
handles fail closed. Actions cross the browser/client/server boundary as
short-lived, notification-bound, owner-bound, single-use tokens rather than
serialized functions or caller-selected event names. Owner stop invalidates the
owner's notifications, queued work, progress operations, and actions.

The compatibility bridge may map legacy QB, QBX, or ESX notification calls only
after it gains a reviewed client-side adapter boundary that preserves the real
consumer and local owner. The existing generic server adapter vocabulary alone
does not make those legacy client notification APIs supported.

## Consequences

- One policy engine provides quiet-by-default feedback and bounded behavior for
  every participating resource.
- Restart cleanup and owner epochs prevent an old resource instance from
  mutating a new instance's notification.
- Session ID plus source generation prevents a delayed server delivery from
  reaching a different player after Cfx source reuse.
- The opaque wake plus target-fenced, single-consumer Core pull prevents another
  server resource from forging `SERVER`/`SYSTEM` presentation payloads through
  the shared Cfx event channel.
- Dedupe, grouping, queueing, and rate limits cap memory and render pressure, but
  callers must handle suppression, rate-limit, queue-full, stale, and degraded
  outcomes instead of assuming every request becomes visible.
- A Notify restart intentionally loses ephemeral notifications, action tokens,
  and history. Durable workflows must reconstruct their own current state and
  decide whether new feedback is still useful.
- UI restart requires a bounded generation/revision resynchronization. It cannot
  justify focus acquisition or a second full-screen notification application.
- Accepting this design direction does not establish production maturity.
  Automated Lua and browser tests do not prove live FXServer source reuse,
  resource-restart timing, CEF accessibility, controller behavior, focus
  coexistence, safe-zone placement, or gameplay performance.
