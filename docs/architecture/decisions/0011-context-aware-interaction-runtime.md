# ADR-0011: Context-aware, lease-gated interaction runtime

- Status: Accepted design; implementation Experimental / Alpha
- Date: 2026-08-29
- Scope: `synex_interact`, `synex_world`, `synex_entities`, `synex_ui`

## Context

FiveM interaction resources commonly make the player enter a target mode, scan large entity sets, put arbitrary action callbacks on the client, or trust a ray hit as permission. That couples UX, gameplay domains and security while creating unstable prompts, restart leaks and hot-path work proportional to the global target registry.

Synex already separates World semantics, Entity identity/authority, domain APIs and a shared UI runtime. It needs one interaction layer that composes those systems without becoming a second copy of them.

## Decision

Adopt `synex_interact` as a context-aware, runtime-only interaction and gameplay-orchestration layer with this pipeline:

```text
Context Sensor -> bounded candidates -> Intent Engine -> Smart Object
               -> server Interaction Lease -> Session/locks -> Action Graph
```

Normal play is zero-mode. The client continuously but adaptively observes a bounded local context, exposes one primary intent and opens a small Action Bloom only for already relevant alternatives. It does not expose an eye/target mode or generic radial menu.

The client observation carries no authority. A client request contains only canonical intent/revision and target-reference data. Core supplies the active session and source generation. The server resolves the owner/definition, revalidates WorldRef/EntityRef generation, live distance/context, policy/capability, slot capacity and rate budgets, then issues a short-lived actor/target/intent/revision-bound, single-use lease.

Smart Objects declare bindings, slots, activities and presentation but no business side effects. Interaction bundles are closed, namespaced and atomically activated under resource/owner-epoch ownership. The client receives a minimized discovery projection; execution policy and Action Graph internals stay server-side.

Action Graphs use a closed bounded node vocabulary. Domain effects are available only through registered typed adapters and explicit commit semantics; there is no arbitrary event or SQL node. The owning domain remains responsible for authorization, idempotency, persistence and compensation.

World continues to own anchors, doors, portals, instances and semantic context. Entities continues to own stable EntityRefs, generation, model/type, materialization and routing context. UI renders revisioned cue/bloom/progress projections through the shared runtime; it never becomes gameplay authority. Notify is reserved for a result that would otherwise be missed, not immediate interaction progress.

Active slots, reservations, leases, sessions, actor locks, graphs, traces and denial histories are bounded and process-local. Owner stop/replacement, player drop and resource restart invalidate stale runtime state rather than resuming it across incarnations.

## Consequences

- Global registry size is decoupled from client hot-path work through spatial/context filtering and hard candidate bounds.
- Intent hysteresis and deterministic ties improve prompt stability without creating a security dependency on scoring.
- Server revalidation and single-use leases make ray/NUI/state-bag forgery insufficient to authorize an effect.
- Multi-actor roles, atomic slot reservations and actor locks are available without implementing matchmaking or persistent occupancy.
- Domain teams must supply typed adapters and cannot use Interact as a cross-domain superuser.
- Restart intentionally cancels process-local interactions; durable domains recover only their own committed facts.
- Compatibility target adapters must preserve the lease boundary and remain unsupported until separately cataloged, tested and accepted.
- Repository tests cannot prove Cfx natives, OneSync, CEF, controller behavior, gameplay readability or measured runtime cost. Those gates remain open and keep the implementation at Experimental / Alpha.
