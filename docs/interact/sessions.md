# Interaction sessions

An `InteractionSession` coordinates one or more actor leases around a canonical intent, target and bundle revision.

## Model

A session stores its owner/epoch, bundle/intent revision, target, expiry, participant-role definitions, the required-role reservation and optional graph execution. Each participant is keyed by Cfx source plus source generation and owns a role and actor-bound lease. Required participants share the session reservation; an optional participant owns a separate, one-role reservation so it cannot consume capacity before it actually joins.

Roles declare:

- `role` name;
- whether the role is required;
- capacity;
- optional slot key;
- optional `lateJoin` admission for non-required roles only;
- participant-loss policy: `ABORT`, `CONTINUE` or `REPLACE`.

## Ready barrier

Activation marks that actor ready. A required role is satisfied only when its declared capacity has ready members; optional roles never hold the start barrier. The final required activation atomically converts the shared required-role reservation to occupancy, claims the ready actors' graph locks and starts the graph. An admitted optional participant converts only its own reservation and joins the running execution after its actor locks are acquired. This is server coordination; it does not promise frame-perfect client animation synchronization.

## Owner-issued invitations

The session owner must call the capability-gated `inviteParticipant` facade or `invite_participant` Core service before another player can join. The call names the exact session, declared role and current player source. Interact resolves that player's active Core session and issues a process-local invitation bound to:

- session, role, owner resource and owner epoch;
- player source, source generation and Core session identity;
- a monotonic expiry no later than the session expiry.

Invitation TTL is 500 through 10,000 milliseconds and a session retains at most 16 pending invitations. Issuance rechecks both the owner session and invited player after ID allocation. A join with a stolen token, different role, reused source generation, changed Core session, expired token or different owner incarnation fails closed. Successful admission consumes the invitation once after final actor/definition/target/World revalidation and before slot admission; any later failure requires a newly issued invitation.

## Join, leave and loss

The experimental `session.join` and `session.leave` RPCs are active-session fenced and rate-limited. A join accepts exactly `sessionId`, `role` and `invitationId`, resolves the declared role, revalidates the canonical target/policy and obtains a short actor-bound lease. Active plus in-flight lease admissions count against both global and per-actor limits, so concurrent yielding requests cannot overrun the configured capacity. Required roles use the shared required-role reservation. Optional roles claim only their declared role capacity in a separate atomic reservation. A failed slot or actor-lock admission rolls back any new reservation, but a consumed one-time invitation is never restored.

Leaving an `ABORT` role cancels the session. `CONTINUE` releases only that participant and its separate reservation while the graph continues. `REPLACE` pauses a running graph and preserves the affected reservation for one replacement; execution resumes only after the replacement activates and reacquires its locks.

Late-join behavior is deliberately narrow. A running graph accepts only a non-required role whose bundle explicitly declares `lateJoin: true`; required roles can join only while the session is waiting. A participant admitted before graph start may finish activating after the graph starts. There is no persistent lobby, matchmaking system or offline participant record.

Player drop, source-generation change, owner stop, bundle replacement, invitation/session/lease expiry and graph completion clean the associated invitations, leases, locks, graph state and every shared or participant reservation idempotently. Actor-key and source indexes make participant lookup/cleanup local to the affected actor or source instead of scanning every active session; the bounded indexes are updated on every join, leave, discard and session removal.
