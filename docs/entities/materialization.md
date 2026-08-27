# Materialization

Materialization turns a durable Entity definition into one verified OneSync Entity. The definition may exist without a runtime Entity; `dormant` is therefore a valid durable state.

## Server-created paths

The current server-only runtime uses:

- `CreateVehicleServerSetter` for vehicles;
- server-side `CreatePed` for peds;
- `CreateObjectNoOffset` for objects.

Player peds are excluded. There is no client spawn contract and no NUI spawn path.

After native creation, the runtime waits only until the bounded spawn deadline. It then applies the requested routing bucket and orphan policy, resolves a NetID and verifies existence, Entity type, normalized model, bucket, NetID and network-owner shape. A native returning a handle is not treated as successful activation by itself.

## Spawn request validation

The closed request schema rejects unknown fields and validates:

- Entity type and type-specific vehicle/ped/object fields;
- a 32-bit model hash;
- finite coordinates within the supported world bounds;
- normalized heading;
- a current managed bucket generation, or default bucket `0/0`;
- logical owner shape and cross-domain existence where implemented;
- resource-owned binding and persistent key rules;
- persistence and recovery policy compatibility;
- optional archetype version, tags, reason code, idempotency key and timeout;
- total, per-resource, logical-owner, bucket, persistent and per-type quotas;
- resource/type/bucket spawn-rate windows.

Typed spawn capability is required for the selected Entity type. A request without an archetype additionally requires the privileged raw-spawn capability.

## Archetypes

`synex.entities.archetype.register` registers a resource-epoch-owned descriptor containing:

- Entity type and up to 32 allowed model hashes;
- spawn defaults;
- persistence and recovery defaults;
- default tags;
- referenced component/state schema versions;
- a bounded domain descriptor.

The namespace, tags, reason code and referenced schemas must belong to the registering resource. A spawn using an archetype resolves and freezes the effective descriptor into the durable Entity definition. Runtime registrations are removed on resource restart; the frozen descriptor remains available for that definition.

## Reservation and activation

For the authority-backed path, the order is:

```text
validate caller and request
  -> validate logical owner and archetype
  -> apply admission limits
  -> serialize binding/Entity lane
  -> reserve definition + active binding + authority lease
  -> create and verify OneSync Entity
  -> hydrate replicated extensions
  -> activate the durable definition
```

The unique active binding and namespaced persistent-key constraints provide the final database duplicate fence. An active or in-progress definition returns `ENTITY_ALREADY_MATERIALIZED`; a competing binding returns `BINDING_CONFLICT`.

## Failure compensation

If the runtime path fails before registration, it requests deletion and waits only until the bounded delete deadline. Registry insertion or verification failure also detaches the Synex mapping. If durable activation fails after runtime creation, the runtime Entity is deleted and the durable definition is marked failed when applicable.

If immediate compensation cannot verify deletion, the resource records a bounded cleanup finding instead of forgetting the possible runtime leak. Findings are deduplicated by Entity ID/generation for registered Entities or by the available handle/NetID/model fingerprint for an unregistered spawn. Enqueue marks Entity health `DEGRADED` with `ENTITY_CLEANUP_PENDING`; exhausting the bounded queue marks it `UNHEALTHY` with `ENTITY_CLEANUP_QUEUE_EXHAUSTED`.

Delayed cleanup never deletes solely by a remembered native handle. Before retrying an unregistered spawn, it re-reads Entity type, model and the NetID when one was obtained. A mismatch means the handle has been recycled: the finding is resolved without deleting the unrelated replacement. Registered cleanup goes through the full runtime identity inspection and detaches a stale Synex mapping without deleting its current occupant.

Queued and resolved findings, and capacity exhaustion, produce bounded audit/metric evidence. This process-local queue is compensation for a running resource, not durable persistence and not a production cleanup guarantee. The exact path still needs FXServer failure injection and leak-diagnostics acceptance before promotion.

## Dematerialization and deletion

`synex.entities.dematerialize` accepts only a current, resource-owned persistent `EntityRef`. Policy `checkpoint` records a checkpoint before removing the runtime Entity; the discard policy omits that checkpoint. The durable row becomes `dormant` and keeps its identity.

`synex.entities.delete` is terminal. Persistent deletion additionally requires the separately denied-by-default `synex.entities.delete_persistent` capability. Deletion is never equivalent to merely calling a FiveM native.
