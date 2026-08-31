# Notify security boundary

Notify treats every client, NUI message, and resource-supplied payload as
untrusted. It protects feedback orchestration and delivery; it does not
authorize the gameplay operation described by a message.

## Threat model

The boundary covers:

- a client executor forging or flooding server events;
- a browser/NUI request replaying an action or inventing a token;
- a resource trying to notify another player from the client;
- delayed server work reaching a reused Cfx source;
- an old resource epoch mutating a replacement instance;
- unprivileged high/critical/banner/broadcast requests;
- a normal resource attempting to claim reserved `SYSTEM` origin;
- oversized, cyclic, callable, markup-bearing, or otherwise malformed payloads;
- queue, action-token, history, and render-memory exhaustion;
- user-facing or diagnostic leakage of private implementation details.

A notification can say “purchase complete” only after the owning server domain
has authoritatively completed that purchase. Notify never proves a balance,
permission, inventory mutation, ownership transfer, or other domain fact.

## Caller and owner authority

`exports.synex_notify:GetAPI(...)` captures the immediate invoking resource. The
caller cannot submit `ownerResource` or `ownerEpoch`; each facade is bound to the
derived owner and current Notify-owned resource-incarnation epoch. The Core
service separately validates its incoming `callerEpoch`, but records from the
direct facade, service, and Bridge adapter all use the same canonical Notify
epoch rather than copying the Core epoch. Resource stop cleans that incarnation.
A stale facade or handle fails with `NOTIFY_OWNER_STOPPED` or
`NOTIFY_OWNER_STALE`.

The private client compatibility facade is callable only by the exact reviewed
QB, QBX, or ESX provider resource. The provider forwards the immediate Cfx
consumer identity obtained at its function/export boundary; the resulting
record remains owned by that consumer. The facade accepts only local normal
toasts and cannot select a target, server/system origin, actions, progress,
banner, high, or critical presentation. Raw legacy notification events are not
registered because they do not retain immediate caller provenance. Bridge's
server-origin consumer projection is a default-deny governance snapshot within
the trusted server-resource boundary, not a client-selected credential.

Server service calls preserve Core's immediate caller and capability checks.
Capability declaration is not a grant. The relevant gates are:

```text
synex.notify.send
synex.notify.update
synex.notify.priority.high
synex.notify.priority.critical
synex.notify.banner
synex.notify.broadcast
synex.notify.system
synex.notify.diagnostics.read
```

## Reserved system origin

`origin` is derived and output-only. Ordinary client and server payloads use
closed schemas, so supplying `origin = 'SYSTEM'` is rejected before admission.
The dedicated direct-facade and Core-service system methods attach the origin
inside `synex_notify`; the registry then independently requires the privileged
`synex.notify.system` capability alongside all ordinary send, priority, banner,
and broadcast gates. `synex_core` is the sole built-in system principal. Its
bypass applies only to records created through the explicit system path and does
not broaden an ordinary server send.

The raw Cfx server event is deliberately not a trust boundary. It carries only
a closed wake-up reference (`schemaVersion` and an opaque `commandId`), never a
notification payload, origin, owner epoch, target fence, or action token. The
client serially redeems that reference through the Core contract
`synex.notify.command.pull`; Core requires an active session and Notify matches
the exact source, session ID, and source generation recorded for the pending
command. Only the detached canonical result of that pull may update the client
session fence or enter presentation policy. Forged, replayed, expired, and
cross-session wake-ups therefore fail closed and cannot claim `SYSTEM` origin.

Pending commands and client wake work are short-lived and bounded. Pull is
single-consumer, so another server resource can at most cause a bounded failed
lookup; it cannot provide the object that is rendered. Once hydrated, the
client keeps `SERVER` and `SYSTEM` dedupe/group domains separate and rejects an
origin change on a later revision.

The three declared client-to-server Notify contracts are the internal command
pull, `synex.notify.action.invoke`, and the internal
`synex.notify.metrics.report` telemetry RPC. All require an active Core session.
Pull accepts only an opaque pending-command ID; action invocation accepts only a
token, notification ID, and revision. The metric report accepts only its closed
set of bounded aggregate counters and gauges, and the server binds it to the
current source/session generation before establishing or advancing a baseline.
No caller-selected event name, target, owner, callback, origin, notification
copy, gameplay payload, or authorization fact crosses these boundaries.

## Target and source-reuse safety

Server delivery requires:

```lua
{
    source = 42,
    sessionId = 'current-public-session-id',
    sourceGeneration = 7,
}
```

Notify resolves the active Core session before admission and before dispatch.
Action invocation must match the same session ID, source, and source generation.
If source 42 later belongs to generation 8, the old delivery/action returns
`NOTIFY_TARGET_STALE`; a numeric source alone is never accepted as durable
identity.

`sendMany` accepts at most 32 exact target references. Broadcast is separately
capability-gated, derives targets from current active Core sessions, audits only
bounded aggregate context, and refuses an oversized target set.

## Payload safety

The public DTO is a closed object. Unknown fields, metatables, invalid arrays,
control characters, non-finite numbers, invalid identifiers, and out-of-range
values fail before presentation. The encoded notification envelope is bounded
to 4 KiB and contains no arbitrary metadata blob.

Titles, messages, labels, and hints are text. React renders them as text nodes;
no `innerHTML`, arbitrary URL, image, iframe, SVG, CSS, event name, or script is
accepted. `iconKey` selects only a checked-in Synex icon. A browser payload is
validated independently again by `synex_ui` before entering the store.

The fullscreen NUI remains transparent and pointer-free for passive signals.
Notify does not expose a generic NUI callback that can choose prices, player
targets, permissions, or domain actions.

The raw `synex_ui` passive-signal facade is also not a public event bus.
`upsertSignal`, `removeSignal`, `getSignalSnapshot`, and the private adaptive
capacity binding are available only to the immediate `synex_notify` resource;
every other owner receives `UI_SIGNAL_DENIED` for transport and no binding
method. Capacity callbacks are exact, owner/epoch-fenced, next-turn coalesced,
and removed unless the current Notify binding explicitly returns `true`.

## Action tokens

Server action tokens are opaque Core-generated identifiers bound to:

```text
notificationId + revision + ownerResource + ownerEpoch
+ source + sessionId + sourceGeneration + actionId + expiresAt + used
```

The server checks every field before marking a token used. Expired, replayed,
missing, stale-revision, wrong-session, and stopped-owner cases fail closed.
Updating action definitions invalidates previous tokens. Actions expire after
1–30 seconds (10 seconds by default) and no later than their usable notification
context. The effective deadline is the earliest current presentation deadline,
hard lifetime, or requested TTL, and the exact deadline is expired. Server
tokens use a conservative send-time presentation bound and the client clips
again at actual visible promotion; queued work can therefore lose an action
before it is displayed rather than extending authority past its intended
surface.

The client will not initially expose or invoke that token merely because Notify
planned a surface. A browser report of the exact currently `active` Signal
Surface first permits hint projection; F9/F10 still requires an ACK for the
resulting current action-bearing revision, current generation, and a newer
per-browser-boot `presentationRevision`. Dismissing surfaces, stale ACKs, UI/CEF
restart, callback failure, and a missing confirmation leave F9/F10 fail-closed.
The browser and client retry bounded visibility synchronization without granting
action authority from a timeout.

The callback receives a freshly copied bounded payload. It is still responsible
for authorizing any gameplay mutation against current server state. A token
proves only that this exact notification action was admitted once; it does not
grant money, inventory, admin, or entity authority.

## Flood and memory protection

All registries and histories have hard bounds. Server global, owner,
kind, high, critical, and update buckets plus client owner/global/update/action
buckets reject bursts with `NOTIFY_RATE_LIMITED`. The queue has a hard maximum
and visible stack is capped. Dedupe/grouping reduce repeated presentation but
are not relied on as the only denial-of-service defense.

Privileged priority and banner requests have dedicated low-refill buckets and
weighted global/owner costs. Queue pressure can
evict or suppress low-value work; it cannot allocate unbounded tables. Player
disconnect, owner stop, periodic expiry, and resource stop clear retained
records and tokens.

Owner epochs are monotonic and authority-scoped on the client (`LOCAL` versus
`SERVER`). A newer epoch cleans only its older incarnation; an older command or
stop fence cannot erase newer state or reset its budgets. Server delivery and
actions additionally require the exact Core source/session/source-generation
tuple, so numeric source reuse fails stale.

## Diagnostics and privacy

Metrics and Control views use bounded aggregates. The internal client report is
accepted only from an active Core session/source generation, has an exact closed
shape, and is protected by rate, counter-delta, latency, generation-advance, and
registry-capacity bounds. A new client generation or session is baselined before
any delta is counted. Reports contain no title, message, resource/player/session
identifier, notification ID, character ID, action token, or trace ID, and no
such value is used as a metric label.

Client-reported presentation counters and gauges remain untrusted observational
data even after validation. They may inform queue-pressure and UI-latency
diagnostics, but never authorization, anti-abuse enforcement, delivery proof, or
domain state. Control marks the aggregates `presentation-telemetry-only` and
reports them unavailable when no session report is fresh. History can be
disabled per notification with `history = false` and is never persisted.

Core service and RPC entry points preserve the Core-owned trace context and run
as provider spans in that chain. The direct local export facade has no incoming
Core trace envelope and does not invent one. Traces and metrics never include
notification copy.

Notify deliberately avoids audit-per-toast behavior. Only privileged
broadcasts, critical deliveries, and reserved `SYSTEM` deliveries append Core
audit evidence. Multi-target operations append one aggregate record, not one
record per player. The bounded audit context is content-free and excludes
notification, target, session, player, character, and action-token identifiers;
an existing Core trace ID may be retained for correlation. Owning gameplay
domains remain responsible for auditing the authoritative operation that caused
the feedback.

Public errors contain only stable code, safe message, and retryability (plus a
Core trace ID where Core owns the envelope). Raw exceptions, stack traces, NUI
internals, SQL, paths, tokens, connection details, and private callback errors
are normalized to a public Notify error.

## Degraded UI behavior

Stopping `synex_ui` does not open a broad alternate transport. Ordinary
gameplay notifications remain degraded/suppressed. An upsert that is retained in
the UI store with `delivered = false` is also treated as a transport failure and
does not play sound. Only a separately admitted critical signal may use the
bounded native text fallback. Immediate delivery failure or absence of the exact
browser-active revision ACK for 1,250 ms can trigger it, at most once per content
generation; it has no actions, markup, sound contract, or pointer/focus path.

The optional local sound path is private to the exact `synex_notify` UI facade.
Callers can supply only a semantic tone and bounded integer volume; Lua injects
the current browser-boot ID. CEF rejects mismatched boots, recently replayed
message IDs, stale owner epochs, cooldown/window overflow, and more than four
simultaneous voices. Owner-epoch changes cannot reset the browser pressure
counters. Shutdown and unmount close the AudioContext and clear bounded sound
state.

Each UI facade diagnostic snapshot is owner/epoch-scoped. A resource sees only
its own focus leases, surfaces, and passive signal content; aggregate health and
low-cardinality metrics do not expose another owner's notification text or action
projection.

## Verification boundary

Static review and automated tests can verify closed shapes, limits, capability
denial, token expiry/replay, stale revisions, owner cleanup, and simulated source
reuse. They cannot prove live Core/network scheduling, hostile executor traffic,
CEF/NUI callback behavior, resource-stop ordering, or native fallback safety on
the deployment artifact. Run adversarial and restart tests with a real FXServer
and client before deployment; this document is not a production security
certification.
