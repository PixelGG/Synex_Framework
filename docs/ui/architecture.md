# Architecture

## Two delivery boundaries

```text
Build time                              Runtime

domain resource NUI                     domain resource client
        |                                        |
        | imports @synex/ui                      | obtains owner-bound facade
        v                                        v
resource-owned JS/CSS bundle        synex_ui focus arbiter
        ^                                        |
        | owner-scoped messages                  | versioned pull/ack state
        | and focus natives                      v
        +----------------------- owner_focus.lua helper

                                      shared descriptors
                                               |
                                               v
                                      synex_ui React NUI
```

The package side is copied into each consumer's compiled bundle. It does not
require a running central browser to render domain applications. The runtime
side exists only for shared surfaces and cross-resource coordination.

Separate NUI frames do not share a CSS stacking context. Global ordering and
focus therefore depend on every participating Synex resource using the arbiter;
one resource that calls focus natives directly can still violate the system.

Cfx focus and browser-message natives act on the invoking resource's NUI frame.
The central runtime therefore applies natives only for its shared frame. A
consumer with a dedicated NUI loads `@synex_ui/client/owner_focus.lua`, which
pulls the authoritative desired state and applies it inside the owner resource.
Boot generation, owner epoch, monotonic revision, and exact acknowledgement
fence restart and stale-delivery races. The fixed local wake event is only a
notification; it never carries trusted desired state.

## Ownership model

The Cfx export boundary captures the invoking resource. The returned facade is
bound to that owner and to an owner epoch. Callers cannot choose an alternate
owner in a payload. When a resource stops, the runtime expires its epoch,
cancels pending requests, closes its surfaces, removes queued/active focus
leases, and restores the next valid focus owner.

Epoch fencing prevents a facade or late browser response from a previous
resource incarnation from mutating the current one. Surface revisions and
request identifiers protect against stale or out-of-order work within the same
owner epoch.

## Runtime responsibilities

The client runtime is the sole authority for:

- the active, suspended, and queued focus stack;
- desired focus state and owner-agent revision fencing;
- shared surface identity and lifecycle;
- browser readiness and runtime synchronization;
- static NUI callback routes and response correlation;
- local preference validation and persistence;
- runtime metrics and health reasons;
- bounded, owner/revision-fenced passive Signal projections for `synex_notify`.

The React runtime renders validated descriptors. It does not infer ownership or
dispatch arbitrary Lua/server behavior.

Passive signals are not generic interactive surfaces and never acquire a focus
lease. `synex_notify` decides queueing, priority, deduplication, grouping,
progress and action eligibility, then projects at most the visible bounded set
through `upsertSignal`/`removeSignal`. The UI runtime validates and renders that
projection, retains short exit motion, and reconciles a complete snapshot after
a browser restart. It never becomes notification domain truth.

Those raw signal operations are private transport, not a general UI facade:
only a facade whose immediate owner is `synex_notify` may call `upsertSignal`,
`removeSignal`, `getSignalSnapshot`, or bind the adaptive visible capacity;
other owners receive `UI_SIGNAL_DENIED` for transport and no capacity-binding
method. The browser reports only signals actually in its `active`
phase, excluding the 140 ms dismissing retention and any planned signal that has
not obtained a slot. Each report carries the browser boot, current signal
generation, exact signal revisions, current adaptive capacity, and a strictly
increasing per-browser-boot `presentationRevision`. Transient callback failures retry;
Notify keeps action descriptors initially withheld until the surface is active
and keeps F9/F10 fail-closed until the resulting action-bearing revision is
confirmed.

`upsertSignal` separates store admission from browser delivery. A successful
call returns the retained signal generation plus `delivered`; `false` means the
bounded UI store accepted the revision while CEF was not ready or
`SendNUIMessage` did not report success. The later full sync can reconcile that
state, but callers must not count it as display/paint. `synex_notify` treats it
as a transport failure, suppresses sound, and permits only its critical
once-per-content-generation text fallback. Even after a successful synchronous
send, a critical signal must receive its exact browser-active ACK within 1,250 ms
or the same bounded fallback is attempted.

Native execution is deliberately split: the central resource calls
`SetNuiFocus` and `SendNUIMessage` for the shared frame; the owner-focus helper
calls them for a direct resource-owned frame. Direct interactive acquisition is
denied until that owner has a compatible, acknowledged helper, and it is also
denied while any shared surface is active. The helper releases fail-safe on
owner or central stop and re-registers after a central restart.

## Domain boundary

Domain resources remain responsible for their own state, permissions, server
operations, persistence, and dedicated large-screen UIs. The generic runtime
may collect or display bounded values, but a returned form value is untrusted
input. Money, inventory, permission, ownership, and other protected changes must
be re-derived and validated by the domain server.

`synex_control` is intentionally independent. It may consume static package
artifacts in a future build-time migration, but it must never require the
`synex_ui` runtime to start, diagnose, or recover the framework.

## Failure behavior

The runtime fails closed:

- no focus is taken before the browser ready handshake;
- unsupported API/protocol versions are rejected;
- invalid, oversized, stale, or owner-mismatched input is rejected;
- every accepted static NUI callback receives exactly one response envelope;
- timeouts and owner stops settle pending requests;
- resource shutdown releases focus and clears browser state;
- passive signal owner stop and runtime restart clear or reconcile bounded state
  without mounting an opaque full-screen layer;
- stale/missing passive-signal visibility ACKs cannot grant action eligibility;
- store-retained but `delivered = false` signals cannot be treated as browser
  display success.

The focus-agent bridge coordinates client resources; it is not an authorization
or hostile-client security boundary. Protected domain operations remain
server-authoritative.

See [Transport](transport.md), [Focus](focus.md), and [NUI safety](nui-safety.md)
for the concrete contracts.

## Diagnostics contract

Facade diagnostics report `READY`, `DEGRADED`, or `UNHEALTHY` with bounded
reason codes: `NUI_NOT_READY`, `FOCUS_DESYNC`, `TRANSPORT_DEGRADED`,
`RUNTIME_RELOAD`, and `REQUEST_PRESSURE`.

Counters are intentionally low-cardinality:

```text
ui_focus_acquire_total       ui_focus_denied_total
ui_surface_open_total        ui_surface_close_total
ui_request_total             ui_request_timeout_total
ui_payload_bytes             ui_runtime_errors
ui_owner_cleanup_total       ui_active_surfaces
```

Diagnostics also include owner/epoch-scoped focus/queue summaries, surfaces and
passive signals, plus input device, limits, pending-request count, and the most
recently sampled screen metrics. One resource cannot read another resource's
surface or signal content. Global health and metrics remain bounded and
low-cardinality; diagnostics contain coordination metadata, not domain or player
data.

Stable public error codes are:

```text
UI_NOT_READY                 UI_FOCUS_BUSY
UI_FOCUS_DENIED              UI_FOCUS_LEASE_INVALID
UI_OWNER_STOPPED             UI_OWNER_STALE
UI_REQUEST_INVALID           UI_REQUEST_TIMEOUT
UI_REQUEST_CANCELLED         UI_REQUEST_STALE
UI_SURFACE_CONFLICT          UI_PAYLOAD_TOO_LARGE
UI_PROTOCOL_UNSUPPORTED      UI_SIGNAL_DENIED
```

## Acceptance gate

Browser and automated tests do not prove the Cfx boundary. Exact production
output still requires a real FiveM/CEF smoke test covering start, open, all
input modes, close, owner stop, runtime restart, reconnect, safe zone, and
performance, including controller, accessibility, and measured Resmon behavior.
That live acceptance is **NOT YET VERIFIED**.
