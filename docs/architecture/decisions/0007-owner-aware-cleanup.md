# ADR-0007: Owner-aware lifecycle cleanup

Status: Accepted

## Decision

Track every runtime registration and in-flight operation by resource and epoch. On a non-Core stop, mark the epoch quiescing, reject new work, drain for a bounded interval, abort the remainder, and purge all owned registrations. Permit only a size-bounded, schema-checked, same-Core handoff for explicitly reconstructable non-sensitive state. Durable correctness must not depend on stop-time work.

## Consequences

Repeated resource restarts do not accumulate stale handlers or timers. A normal Cfx resource restart can restore the bounded state handoff once into the next epoch. Core shutdown receives immediate best-effort cleanup only; it does not persist or restore the handoff.
