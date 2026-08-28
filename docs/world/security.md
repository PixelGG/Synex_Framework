# World security boundary

All persistent, access, door, portal and instance authority remains on the server.

Portal admission never treats a pre-authorization position as durable truth. After potentially yielding access checks, the server fences the same session generation and resolves position and Context again before granting, completing a physical transition or mutating instance membership. Instance joins reserve a bounded pending grant whose expiry starts only after the yielding bucket move succeeds.

Instance exits never accept a destination from the caller or client. The destination is the immutable `instance_template.exit` captured from the compiled server registry. Leave and close reserve bounded internal transition identities before their Entity move, fence the active session/source generation, membership, bucket generation, template and map lifecycle after the yield, remove membership, and only then send a server-origin client transition. Create and join apply the same pre-/post-yield template and map-availability boundary; post-move refreshes are compensated instead of being committed.

## Trust rules

- Core determines the immediate calling resource and its owner epoch.
- Bundle owner/namespace comes from Core resource discovery, not the JSON payload.
- Public mutation contracts are `network: none` and capability-gated.
- Player position comes from the server-side player ped, not a client-supplied vector.
- Slice delivery rechecks session ID and source generation after any yielding state reads.
- Source generation/session is checked before and, for instance movement, after sensitive work.
- Revisioned references fail closed after bundle replacement or removal.
- Optimistic versions and idempotency keys protect dynamic state changes.
- Portal grants are source/session-bound, short-lived and single-use.
- Grant, pending-transition and empty-instance deadlines use a wrap-safe monotonic view of `GetGameTimer`.
- Cross-domain behavior uses Groups and Entities contracts, never their tables.
- Database access is parameterized, table-owned and bounded through Core's DataPort.

Server-observed coordinates are an authority/plausibility input, not a promise of deterministic client physics or immediate OneSync scope. Position-sensitive operations fail when the server ped/coordinates are unavailable, and the exact artifact still requires live verification.

## Client boundary

The three internal client messages accept only server transport source `65535`, closed bounded payloads and valid revisions. There is no client-to-server door/state/portal mutation event. Client exports and local context events are read models only and label cached context `OBSERVED`; server-sensitive operations resolve or verify a fresh `VERIFIED` context.

State bags are not used as access authority or confidential storage. DoorSystem, interior and IPL native state is presentation/streaming state and cannot prove permission.

Relevant World-state values are projected into bounded client slices. World-state definitions must therefore contain environmental presentation facts only, never credentials, private identifiers or another secret. A projected value remains observational; sensitive server work reads and validates the authoritative state again.

## Failure behavior

Unavailable maps, stale references, session changes, missing capability ports, invalid geometry, query/overlap pressure, bucket failure, database errors and incompatible persisted schemas return bounded structured errors. Context resolution rejects truncated overlap sets instead of treating a partial result as authority. Unexpected internal errors are mapped to `INTERNAL_ERROR`; raw SQL/driver/native details are not part of the public result.

Health states are `READY`, `DEGRADED` and `UNHEALTHY`, with bounded reason records. Repository health and automated tests are not substitutes for runtime acceptance.

## Remaining acceptance work

The exact candidate still needs a disposable live deployment that exercises:

- bundle discovery and owner restart;
- MariaDB migrations, persistent state/doors and outbox recovery;
- server ped coordinates and context/presence;
- actual DoorSystem leaves, IPL and interior entity sets;
- teleport plus instance routing-bucket transitions;
- disconnect/reconnect and resource-stop cleanup;
- malformed/spoofed client messages in the live Cfx runtime.
