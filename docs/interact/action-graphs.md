# Action Graphs

An Action Graph is a bounded, compiled server workflow for one interaction session. It orchestrates checks, presentation and typed domain calls; it is not a generic arbitrary-event executor.

## Compiler guarantees

The compiler enforces namespaced graph keys, a valid entry, unique node keys, closed node types, valid references, bounded nodes/branches/depth, reachability and no unsupported cycle. Every successful root path must reach an explicit `complete` terminal; `fail` is the only other valid terminal outcome. A terminal reachable only from a `cleanup` reference does not make the normal graph path valid. Retry count, timeouts and graph lifetime are capped.

Supported node vocabulary includes:

- control: `sequence`, `branch`, `parallel`, `race`, `barrier`, `timeout`, `retry`, `wait`;
- validation: `verifyLease`, `verifyContext`, `verifyTarget`, `verifyPolicy`;
- presentation: `faceTarget`, `moveToSlot`, `animation`, `scenario`, `progress`, `sound`, `interactionCue`;
- synchronization/domain: `serviceCall`, `contractCall`, `awaitEvent`, `participantBarrier`;
- cleanup: `stopAnimation`, `releaseSlot`, `releaseLease`, `releaseLocks`, `removeTemporaryEntity`;
- terminal/control: `commit`, `complete`, `fail`.

## Domain adapters

`serviceCall` and `contractCall` require a registered, namespaced typed adapter. Adapter registration is owner/epoch-bound and capability-gated. The graph supplies canonical session/target context; a bundle cannot choose an arbitrary event name, SQL statement, price, inventory mutation or animation function from a client payload.

Owning domains must still validate and make side effects idempotent. Interact does not transact across domain databases.

## Mandatory pre-commit authority guard

Every `commit` node runs a non-optional server guard before its typed adapter, independently of any authored `verifyLease`, `verifyTarget` or `verifyPolicy` node. The guard verifies that the exact execution is still the session's running execution and that its owner epoch, bundle revision, intent, graph and runtime dependencies are unchanged. For every ready participant it verifies the current Core player session, active unexpired lease, occupied reservation, actor locks, policy, availability and canonical target/World revision.

Policy and availability callbacks may yield, so target and actor authority is reacquired after them. A final yield-free pass fences the participant signature, session/execution identity, leases, occupied reservations and locks immediately before the adapter can run. Failure never invokes the adapter and does not mark the execution committed.

## Commit and cancellation

Before `commit`, cancellation may unwind presentation and reservations without claiming a durable gameplay result. After the mandatory guard succeeds, the typed domain adapter decides and records its own durable result. After commit, cleanup continues, but cancellation must not falsely reverse an effect unless that domain exposes a real compensating operation.

Graph execution is bounded by the compiled graph timeout, each node timeout and the registered adapter budget. A yielding adapter that exceeds its budget fails with a structured timeout; commit adapters are never retried implicitly. Client presentation nodes use revision/sequence acknowledgements; duplicate acknowledgements are accepted idempotently, while a stale session/execution/node fails closed.

A `progress` presentation has one explicit mode. `determinate` requires bounded `value` and `maximum` fields and forwards those exact values to `synex_ui`; `timed` requires a real positive node/presentation duration; `indeterminate` contains neither values nor a synthetic percentage. Missing mode defaults to `timed` only when a real duration exists, otherwise to `indeterminate`. Conflicting durations, out-of-range values and unknown progress fields fail bundle compilation.

FiveM Lua cannot preempt a CPU-bound callback that never yields. Extension owners therefore remain trusted code and must not busy-loop or perform unbounded synchronous work. Time budgets isolate yielding/asynchronous handlers and provide observability; they do not turn arbitrary Lua into a preemptible sandbox.

`complete` is a control-flow terminal, including when nested below `sequence`, `branch`, `retry`, `timeout`, `parallel` or `race`. Its signal propagates to the root, cancels sibling branches and prevents later children or `next` nodes from running. The runtime records `COMPLETED` only after receiving that explicit terminal signal; an uncompiled graph that merely falls through is failed with `INTERACT_GRAPH_INVALID`.

See [actor locks](actor-locks.md) and [cancellation](cancellation.md).
