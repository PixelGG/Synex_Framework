# Doors

A World door is one logical, stateful gate with one to eight physical leaves. Static placement/model data stays in the bundle; dynamic state stays in the door engine.

## Definition

A door requires:

- a namespaced key and valid location/interior/room/zone parent;
- logical position;
- one or more uniquely named leaves with unsigned model hash and position;
- `defaultState` of `LOCKED`, `UNLOCKED` or `DISABLED`;
- an explicit `persistent` flag.

Optional fields include heading, explicit per-leaf door hashes, an access policy, tags and `autoRelockSeconds`. Multiple leaves share one logical state and version.

Every leaf receives one deterministic unsigned 32-bit DoorSystem identity. An omitted hash is derived with the same FNV-1a algorithm in compiler, server projection and offline tooling; explicit and derived identities share one global collision domain across all active bundles. A collision fails the combined candidate before registry activation or replacement. Client ingestion normalizes signed/unsigned native representations (for example `-1` and `4294967295`) to the same identity and still rejects a duplicate slice fail-closed.

After a successful non-replayed transition to `UNLOCKED`, `autoRelockSeconds` schedules one Core-owned delayed relock. The callback is fenced by the active definition revision, configured delay and expected door version, so a replacement or intervening mutation makes the old callback a no-op. The timer itself is process-local; a persistent door already left unlocked across a World/Core restart does not currently reconstruct its previous timer.

## State authority

The experimental server-only `synex.world.door.set_state@1.0.0` contract requires `synex.world.door.write`, a revisioned Door `WorldRef`, a reason code and an 8–36 character idempotency key. Mutations use optimistic `expectedVersion` handling in the engine. Runtime doors remain in memory; persistent doors use `synex_world_door_states` and atomically append `synex.world.door.state_changed` to the outbox.

Core caller identity and mutation provenance are server-derived. The client cannot select an actor or mutate door state directly.

The exact public request, response and error set is defined in [`world.contracts.json`](../../resources/synex_world/contracts/world.contracts.json).

## Client reconciliation

Nearby door definitions and their current logical state are projected in a bounded slice. The client:

1. registers an absent leaf with `AddDoorToSystem`;
2. waits until DoorSystem physics is loaded;
3. applies locked/unlocked/disabled state idempotently;
4. accepts only a matching definition revision and a strictly increasing logical `stateVersion`, while keeping the client stream revision separate;
5. removes only DoorSystem registrations created by `synex_world` when they leave the desired set or the resource stops.

This uses real client-only Cfx natives and therefore remains subject to the open real-client acceptance run. A valid model/position in JSON does not prove that the intended custom door exists in the loaded map.

## Access boundary

Door tags are not permissions. The contract capability protects mutation at Core. If a door has an `accessPolicy`, `door.set_state` requires a player `source`; it obtains server coordinates, requires the player inside the compiled door boundary and evaluates the current policy before applying the optimistic mutation. Supplying a source to an unpolicied door also enables the same proximity/access validation. A policy-bearing mutation without a source fails closed. Client DoorSystem state is never access evidence.
