# Synex Interact security model

`synex_interact` treats all client context as untrusted observation. A client may influence what it asks to interact with, but it cannot authoritatively choose a slot, lease lifetime, capability result, World state, entity identity, destination, or gameplay mutation.

## Server checks

Before a lease is created the server checks:

- the Core session exists and is `ACTIVE`;
- the source still belongs to the same `sourceGeneration`;
- the smart-object definition and action exist;
- the client's definition revision is current;
- the player's server-observed position is within the action range;
- supplied World context still verifies through `synex_world`;
- any declared character capability is currently allowed;
- the server-owned smart-object slot is available.

Before execution, the lease/session binding, target, slot, distance, and capability are checked again. A lease is short lived and cannot be reused after release.

## Entity identity

Client hit entities are observations only. A Net ID is sent solely as a bounded lookup hint. The server resolves it through `synex.entities.query.by_net_id` and matches the returned generation-safe `EntityRef` against registered smart objects. Execution resolves the `EntityRef` again and uses the server entity position. Net IDs are not persisted or treated as stable authority.

## Resource ownership

Every definition belongs to the invoking resource. Cross-resource overwrite is rejected. Owner stop removes definitions and active leases. Registration through the export facade additionally checks the caller's `synex.interact.register` capability; service registration is protected by the Core service capability boundary.

## Action Graph confused-deputy protection

A graph cannot execute arbitrary source code. `call` nodes must name an explicit delegated capability. Before the call, Synex Core verifies that the smart object's owner resource itself has that capability. Interact must never become a universal superuser for downstream gameplay services.

Keep `synex_interact`'s own capability grants minimal. Adding broad banking, inventory, vehicle, housing, or administration mutation capabilities to Interact defeats this boundary and requires explicit security review.

## Client predicates

Future local predicates such as visibility, animation state, model hints, or `canInteract` equivalents are UX filters only. They may reduce candidate noise but must never replace server validation.

## Failure behavior

Authorization uncertainty fails closed. Missing World/entity/group authority yields bounded interaction-domain errors rather than trusting stale client state. Internal database, stack, or capability details are not exposed directly to the client.
