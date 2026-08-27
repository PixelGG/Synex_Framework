# Entity state

Entity state provides schema-checked, granular values associated with one generation-protected Entity. It does not expose a client-write event and it does not replace a domain resource's durable model.

Prefer narrow keys:

```text
synex:vehicle:locked
synex:vehicle:engine
synex:entity:status
```

Do not place a large nested `synex` object into one state-bag key.

## Schema definition

`synex.entities.state.schema.register` declares:

- a resource-owned key;
- positive schema version;
- `boolean`, `integer`, `number`, `string` or `json` value type;
- `server` or `client_observed` authority metadata;
- replication policy;
- maximum encoded size (`1..8192` bytes);
- bounded JSON constraints;
- resource-owned reason code.

The schema registry is resource-epoch-bound. Payloads are decoded, shape-checked, canonicalized and validated before a write.

## Authority

All current public state contracts are server-only. `server` means the server resource supplies and validates the authoritative value. `client_observed` is metadata for a future or domain-specific observation workflow; it does not create a client-callable Entity mutation boundary by itself. A consuming server must still establish plausibility and policy before submitting a value.

A server-mediated observation therefore follows this order:

1. the gameplay resource receives a bounded client observation through its own authenticated and rate-limited server endpoint;
2. it resolves the active Core session and invokes `synex.entities.context.validate` with the current `EntityRef`, source, bucket, distance and any required owner/tag/component predicates;
3. it applies its domain-specific plausibility and authorization rules;
4. only then may that same server resource invoke `synex.entities.state.set` with the registered `client_observed` schema, current expected version, reason code and idempotency key.

The observation is never proof by itself. A failed or stale context validation ends the workflow; the client cannot invoke `state.set`, select another resource principal or bypass the Entity generation and authority fences.

## Replication

The public replication vocabulary is deliberately limited to `none` and `scoped`. `none` remains server-only and unprojected. `scoped` uses the explicit Entity State Bag projection and rehydration path. There is no `owner` mode: FiveM Entity State Bags do not provide a distinct owner-only delivery path that this resource can promise as an authority-safe contract.

`client_observed` authority metadata is valid only with `scoped` replication. This restriction is checked at schema registration and repeated by database constraints; it does not create a client-write endpoint.

`scoped` values are written to the Entity State Bag with their granular registered key and are reprojected after materialization only after schema, owner, authority, replication and version metadata agree. The Entity resource never changes global `sv_stateBagStrictMode` or related server policy.

## Durable mutation

`state.set` requires:

- a current resource-owned `EntityRef`;
- a schema owned by that resource and the exact schema version;
- current Entity authority lease;
- expected state version;
- bounded canonical JSON;
- reason code, idempotency key and write capability.

The database primary key is `(entity_id, state_key)`. Durable writes repeat generation, resource-owner, lease and version checks atomically. A stale version returns a structured conflict rather than silently overwriting another mutation.

## Security boundary

A replicated value is visibility, not authorization. Never trust a client-observed State Bag value to decide money, inventory, permissions, ownership, deletion, routing or another persistent mutation. Re-resolve the current Entity, generation, caller and policy on the server.
