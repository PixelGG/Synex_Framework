# Interaction slots

Slots model actor positions and concurrency around a Smart Object. They are runtime coordination, not persistent gameplay ownership.

## Definition

A slot requires a unique local key and may declare:

- local and approach transforms;
- interaction radius and facing tolerance;
- semantic tags;
- capacity from 1 through 32;
- initial `FREE` or `DISABLED` state;
- a closed availability policy (`enabled`, optional owner evaluator and bounded arguments).

`RESERVED` and `OCCUPIED` are runtime states produced by the server, not deployment defaults for a lasting claim.

## State model

```text
FREE -> RESERVED -> OCCUPIED -> FREE
  \         \           \
   +---------> DISABLED <-+
```

Static object/slot availability can disable a slot before it is admitted. Dynamic availability evaluators are rechecked by the server during request, join, activation and renewal; they do not turn a client visibility hint into authority. Disabling a slot releases its active reservations/occupants. Bundle revision, owner epoch, capacity or concurrency changes rebuild incompatible slot state rather than carrying an old claim into a new definition.

## Capacity

Capacity is checked before any reservation is committed. A participant role selects an explicit `slotKey`, the intent's `slotSelector`, or the object's first canonical slot. The session aggregates required roles per slot and claims that complete set atomically. Optional participants claim their own role capacity only when they join. Required occupancy begins when the ready barrier completes; optional occupancy begins when that participant activates. Capacity does not authorize the player and does not replace a lease.

The Smart Object concurrency mode defaults to `slot`. In `exclusive` mode, a foreign session cannot reserve any other slot on the same object while one session already has a reservation or occupant. Multiple claims belonging to the same session remain valid where the role model requires them.

For reservation lifecycle and atomic multi-slot behavior, see [reservations](reservations.md).
