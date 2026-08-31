# Interact security model

> **The client discovers. The server authorizes.**

Assume a hostile client can invoke every registered RPC/event, forge NUI callbacks, replay old IDs, alter state bags, claim arbitrary coordinates/entities and flood handlers.

## Network surface

The canonical descriptor defines 12 contracts. Bundle register/replace/unregister are server-local. Client-to-server RPCs are limited to bundle discovery, generation-fenced managed-entity discovery, lease request/activation, session cancel/join/leave, graph acknowledgement and aggregate-only metrics. Core requires an `ACTIVE` session for every network contract and supplies the current source generation.

There is no arbitrary client event, callback name, service name, SQL statement, price, capability, target resource or animation name in the public request vocabulary. Participant join additionally requires the exact one-time invitation issued by the owning resource for that session, role and active player incarnation. `synex_interact:client:graph` is a server-to-client presentation command; any client acknowledgement is separately fenced by session, execution, node and sequence.

## Lease checks

Before issuance and activation, the server re-resolves or rechecks:

- active session, source and source generation;
- intent key, bundle revision and owner epoch;
- target kind and canonical binding;
- WorldRef revision or EntityRef generation;
- live player/target coordinates and maximum distance;
- live server-side player ped existence and health viability;
- entity existence/type/model/archetype and same routing context where applicable;
- exact `entityBone` selector equality; ambient archetype selectors fail closed without a managed EntityRef;
- declared execution policy and required capability;
- slot availability/capacity and actor locks;
- per-source rate/capacity budgets.

Global and per-actor lease capacity counts both installed leases and admissions currently inside yielding validation. This closes the check/yield/install race without treating client rate limiting as the capacity fence.

The activation nonce is actor/target/intent/revision-bound, short-lived and single-use. The server changes the lease to `ACTIVATING` and destroys the nonce before the first potentially yielding activation check, so two concurrent calls cannot both pass preflight. An old lease cannot be redirected to another player, target, intent or resource incarnation.

## Yield and commit fences

Policy/availability evaluators and World/Entity resolution may yield. Request, join, activation and renewal therefore reacquire the current Core player session, owner/definition dependencies, canonical target revision, authoritative position and World instance after those calls and immediately before mutation. World validation resolves context and the canonical object before sampling current player position, so pre-yield coordinates are not reused.

Every Action Graph `commit` node has a mandatory runtime guard even when the authored graph already contains `verify*` nodes. It checks the running execution and participant set, every ready participant's current Core session and server-side ped health, active unexpired lease, occupied reservation and actor locks, plus policy, availability and post-yield canonical target/World evidence. A final yield-free fence repeats viability, session, participant, lease, reservation and lock identity checks. The domain adapter is not called unless the guard returns strict success.

## Participant invitations

Only the session owner/current owner epoch with `synex.interact.runtime.manage` can issue an invitation. The token is process-local, expires within ten seconds, is capped per session and is bound to source, source generation, Core session identity, session and role. Theft, wrong-role use, source reuse, owner restart, expiry and replay are denied. The token is consumed once after final authority refresh and is not restored after a later admission failure.

## Extension security

Bundle, provider, evaluator and adapter registrations capture the immediate resource and Core owner epoch. They require explicit capabilities and namespaced keys. Owner stop removes registrations. Typed adapters must independently validate their domain operation; Interact is not a superuser and does not make cross-domain SQL calls.

## Data and observability

Runtime interaction state is process-local and contains no database tables. Metrics use fixed, low-cardinality labels; client metrics are aggregate hints, not authorization, delivery or server-health evidence. The first report of each client epoch is stored as a zero-delta baseline, same-epoch counters must remain monotonic and an implausible delta above the configured bound is rejected. Client transport/provider signals appear only as informational advisories; they cannot by themselves degrade the server health state. Denial history and traces are bounded and should avoid player/target identifiers or raw payloads. Stable public errors omit stacks and internal provider details.

Run the repository security and certification gates, then perform a manual endpoint review. Static scanning cannot establish live security.
