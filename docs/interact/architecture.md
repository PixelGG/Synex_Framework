# Synex Interact architecture

## Authority split

The client is an observation and presentation surface. It may sample gaze, perform LOS checks, rank candidates, and decide what to draw. None of those observations authorize a gameplay mutation.

The server is the admission authority. `begin` re-resolves the definition and validates revision, active character session, server-side distance, verified World context, and capability before issuing an Interaction Lease. `execute` fences the same lease against `sessionId` and `sourceGeneration`, re-checks range and capability, and only then dispatches an action.

## Candidate pipeline

The hot path is intentionally staged:

```text
client camera / shape test
  -> bounded nearby query
  -> optional hit Net ID resolution
  -> semantic smart-object candidates
  -> cheap eligibility filters
  -> local LOS + gaze scoring
  -> deterministic intent ranking
  -> one primary affordance
```

The current static-position broadphase is bounded by registration limits and candidate limits. World anchors are resolved to positions at registration. Entity-only interactions use the gaze-hit path and `synex.entities.query.by_net_id` rather than trusting a client-provided entity identity.

The interaction layer must not evolve into a second World spatial database. Large static semantic discovery belongs in `synex_world`; dynamic entity identity belongs in `synex_entities`.

## Smart objects and slots

A smart object is resource-owned and contains one or more actions. Each action names a server-owned slot, such as `default`, `door`, `seat.1`, or `terminal`. The client cannot choose the slot or lease duration. These values come from the registered definition, preventing a client from bypassing exclusivity by inventing a unique slot.

The v1 lease engine provides exclusive slot reservation. Its data model is intentionally compatible with future multi-role/multi-actor coordination, but multi-participant synchronization is not claimed by the current implementation.

## Interaction leases

A lease is ephemeral and contains at least:

- lease ID;
- source;
- Synex session ID;
- `sourceGeneration`;
- object key;
- action key;
- resource owner;
- slot key;
- acquisition/expiry times;
- renewal count;
- context fingerprint.

Leases expire automatically, are released when a source leaves, and are removed when the definition owner stops. One source cannot keep multiple active leases through the current API, and an exclusive slot cannot be held by two sources simultaneously.

A lease is proof that an interaction was recently admitted; it is not proof that the world has remained unchanged. `execute` therefore revalidates authoritative conditions.

## Action graphs

Graphs are declarative and bounded by maximum nodes, maximum execution depth, bounded waits, and a closed node-type set:

```text
call
wait
emit
branch
complete
fail
```

Graphs are validated before registration becomes active and again defensively by the executor. There is no arbitrary Lua/JavaScript evaluation node.

A `call` node must declare the capability required by the target domain operation. Before Synex Interact attempts the call, Core checks that the *owning resource* is itself authorized for that capability. This explicit delegated check prevents a resource from using Interact as a confused deputy. The downstream Core service/RPC boundary still performs its normal authorization as well.

Because Synex Interact itself intentionally requests only foundation-level permissions, domain mutation capabilities are not silently inherited by the interaction engine.

## Action dispatch boundary

If no graph is configured, a successful interaction emits `synex.interact.action.requested` with server-established session and lease context. This is an intent handoff, not a mutation result. The domain owner validates its own current business state before changing it.

## Resource lifecycle

Registration is caller-bound. Definitions carry `ownerResource`, and foreign overwrite is rejected. `onResourceStop` removes the owner's definitions and leases. Registry revisions change when definitions change; stale client candidates are rejected by `begin`.

## Integration map

```text
synex_world        locations / anchors / verified context
       \
        \
synex_entities ---- synex_interact ---- synex_ui
 stable refs          authority          presentation
        /                  |
       /                   |
synex_groups          owner domain
 capabilities          resources
```

`synex_notify` is optional and is intentionally not required for execution correctness.
