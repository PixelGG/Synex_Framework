# Cluster authority

Entity authority answers one question: which FXServer instance may control a durable Entity definition now? It is independent from logical ownership, resource ownership, Cfx network ownership and future player interaction leases.

## Lease identity

`synex_entity_authority_leases` records:

- Entity ID;
- server scope;
- FXServer instance ID;
- opaque authority token;
- Core resource epoch;
- monotonically increasing lease generation;
- active/released state;
- database-time claim, heartbeat, expiry and release timestamps;
- trace and optimistic version.

All lease validity decisions use `CURRENT_TIMESTAMP(6)`. A host clock cannot extend its own authority.

## Claim and fencing

Definition reservation or materialization locks the Entity row and claims the authority row in the same transactional workflow. A live foreign lease returns `AUTHORITY_LEASE_CONFLICT`. An expired or released lease can be claimed by a current contender, which advances the lease generation.

Persistent activation, dematerialization, bucket change, checkpoint, logical-owner change, durable component/state/tag mutation and termination recheck the exact current authority tuple and lease generation. An old instance or resource epoch cannot continue mutating after lease loss.

Per-Entity and per-binding mutation lanes reduce same-process overlap, while database row locks, versions, unique constraints and leases remain the cross-process authority.

## Heartbeat failure

The authority heartbeat renews the current instance's exact live set. The runtime compares the renewed row count with its managed persistent Entities. A mismatch invalidates local authority, detaches/deletes its managed runtime set where possible, records a lease conflict and degrades health. It does not keep serving on assumed ownership.

## Boot reconciliation

On startup, the resource receives Core's instance ID and owner epoch, creates a new authority token and reconciles a bounded page for its server scope. Current-instance leases are refreshed; expired previous authority is released into recoverable/dormant state; live foreign authority remains a conflict. Recovery ticks continue reconciliation until its backlog is empty.

`serverScope` partitions independent Entity datasets intentionally. It is validated and fixed at resource start. Changing it is an operational migration decision, not a way to bypass a live lease.

## Resource stop

A prepared resource stop dematerializes owned durable runtime Entities, removes temporary runtime Entities, then releases the current authority set. Stale callbacks remain fenced by the old Core resource epoch.

## Prepared cross-server handoff

The v1 preparation is an authority workflow, not a transfer of a live FiveM network Entity:

1. instance A writes an explicit checkpoint;
2. instance A dematerializes the runtime Entity and releases its database authority lease;
3. instance B, operating in the same configured `serverScope`, claims only the released or database-expired lease;
4. the lease generation and Entity generation advance before instance B materializes a new runtime Entity;
5. cached handles, NetIDs and older `EntityRef` values remain stale.

A live foreign lease always wins and returns `AUTHORITY_LEASE_CONFLICT`; no instance may force a takeover. The resource owner does not change during this workflow. There is intentionally no v1 UI and no public resource-owner handoff contract.

## Not an interaction lease

An Entity authority lease belongs to an FXServer instance and protects persistence. An interaction lease would belong to gameplay/user intent and must be implemented by a separate domain such as `synex_interact`. Network control and player proximity do not satisfy the Entity lease.

## Acceptance boundary

The repository contains lease/recovery tests, but the current Entity candidate has no accepted two-instance live topology. Expired takeover, simultaneous claims, lease loss mid-operation and two recoveries for one Entity remain required exact-candidate MariaDB/FXServer gates.
