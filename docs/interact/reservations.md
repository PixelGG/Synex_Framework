# Slot reservations

A reservation is a short server-owned claim that prevents incompatible sessions or participants from consuming the same slot capacity concurrently. Required roles use one session-wide atomic reservation; optional participants use a separate one-role reservation.

## Atomic claim

The slot runtime validates every requested claim first. It verifies that each slot exists, is enabled, belongs to the expected owner epoch/bundle revision, has capacity and is not duplicated. Only after every claim passes are all claims installed. A failure creates no partial reservation.

The reservation is bound to:

- reservation and session IDs;
- initiating actor key (`source:sourceGeneration`) and the shared session;
- one or more Smart Object/slot IDs;
- owner resource and epoch;
- bundle revision;
- a monotonic expiry.

Exclusive-object checks use an object-local reservation index. They inspect only active claims for the selected Smart Object instead of scanning every reservation in the runtime. The index is coordination state only and is removed together with reservation release/cleanup; it does not change capacity or authorization semantics.

## Lifecycle

The initial lease aggregates only required participant roles and reserves their complete slot set in one yield-free transaction. Every required participant lease references that shared reservation. Optional roles do not block session creation or graph start: when one joins, the server creates a separate atomic claim for that role's declared capacity. The optional slot in a client request may select a valid object slot only when the canonical role/intent does not already declare one. A conflicting declared-slot claim is denied.

The required-role reservation is bounded by the checked-in 5-second reservation TTL until the ready barrier completes. The final required activation converts that complete claim set to occupancy atomically and fences its expiry to the immutable session lifetime. An optional participant's reservation is occupied on that participant's activation, including an explicitly allowed late join. A `REPLACE` loss preserves the affected reservation for the replacement; `CONTINUE` releases an optional participant's reservation without disturbing the running session.

Explicit release, expiry, terminal cancellation, player loss according to the declared loss policy, owner replacement/stop and resource cleanup remove every applicable claim idempotently. A failure during optional admission, activation or actor-lock acquisition releases its newly created claim and does not mutate the shared required-role reservation.

Reservations live only in memory. They are not locks for accounts, inventory, vehicles or another persistent domain. A typed domain adapter must still use the owning domain's transaction/idempotency rules at its own commit boundary.
