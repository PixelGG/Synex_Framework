# Actor interaction locks

Actor locks prevent one source-generation-bound actor from running incompatible interaction work concurrently.

## Channels

Execution policy and graph definitions can request closed channels such as:

- `actor.movement`
- `actor.hands`
- `actor.weapon`
- `actor.fullbody`
- `actor.camera`
- `actor.input`
- `ui.primary`

The runtime combines intent and graph channels, removes duplicates, sorts them deterministically and claims all required channels atomically. If another session owns one channel, the claim fails with `INTERACT_ACTOR_BUSY` and installs no partial locks.

Locks are bound to actor key, session and execution. Cleanup can release by execution, session or actor and is safe to repeat. Player drop, cancellation, completion, timeout, owner stop and Interact stop must remove them.

Before a `commit` adapter can run, the mandatory authority guard checks that every ready participant still owns every channel declared by the execution for the same session and execution ID. It repeats that ownership check in the final yield-free commit fence; an authored verification node cannot bypass it.

An actor lock is runtime coordination only. It is not a Cfx entity network-ownership lock, a database transaction lock or a permission grant.
