# Interaction leases

An Interaction Lease is the server's short-lived authorization to activate one exact intent against one exact target for one exact actor and definition revision. A client-observed prompt is not a lease.

## Request

The client request is deliberately small:

```lua
{
    intent = { key = 'my_resource:inspect', revision = 3 },
    target = canonicalTargetRef,
    slotKey = 'operator', -- optional
    clientRevision = discoveryRevision,
}
```

Core injects the active session, source generation and trace context. Interact first claims capacity against active plus in-flight leases, then resolves the canonical bundle definition and checks target binding, World/Entity authority, live distance, execution policy, owner epoch, slot capacity and per-actor rate/capacity. ID allocation and target/policy/availability lookups may yield, so actor, definition, target revision, World instance and current position evidence are reacquired immediately before the session/reservation/lease mutation. The pending capacity claim is always released when the request returns or fails.

## Binding and TTL

An issued lease records actor/source generation, session identity, character, target, canonical target revision, intent/bundle revision, owner epoch, reservation, participant role, nonce, issuance/activation deadline and maximum lifetime. Current hard bounds are a 2.5-second default request TTL, 3-second maximum activation window and 120-second maximum lifetime; a stricter declared policy may apply.

## Activation and replay

Activation must present the lease ID and nonce. The server:

1. resolves the current active actor session again;
2. rejects an expired, revoked, terminal or differently owned lease;
3. changes `ISSUED` to `ACTIVATING` and destroys the nonce before the first potentially yielding check;
4. re-resolves the bundle/intent, repeats target, World, policy and availability checks, then reacquires the same authority after those calls;
5. occupies the reserved slot and advances the session ready barrier;
6. starts the Action Graph only when required participants are ready.

Concurrent, replayed or stale activation fails closed. An unexpected activation exception cleans the `ACTIVATING` lease instead of returning it to an issuable state.

## Renewal

Renewal is not a client heartbeat. The runtime renews active leases for a `RUNNING` Action Graph shortly before expiry and only after repeating the full actor/source-generation/Core-session, owner/definition/dependency, canonical target/World/range, policy, availability and reservation-ownership checks. A failed authoritative renewal applies the declared participant-loss/session cleanup path.

An owning server resource may also call capability-gated `renewLease(leaseId, extensionMs)` or `renew_lease`. The caller is derived from the facade/service context and can renew only a lease created by the same current owner epoch. An extension is 100 through 10,000 milliseconds, is calculated from the current server time and cannot cross the lease's immutable maximum lifetime. There is no unrestricted client renewal RPC.

See [security](security.md) for the complete trust boundary.
