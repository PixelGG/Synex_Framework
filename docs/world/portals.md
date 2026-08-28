# Portals and transitions

Portals are server-authoritative transition definitions. Supported types are:

- `physical`: resolves a semantic target and emits a transition result without moving the client;
- `teleport`: supplies a bounded destination position and optional heading;
- `instance`: creates or reuses an owned instance, joins the source, then uses the template or portal entry position.

Every portal has a source position and radius between 0.5 and 25 units. It may be disabled and may carry an access policy.

## Server checks

`synex.world.portal.transition@1.0.0` is server-only and requires `synex.world.transition`. The runtime verifies:

- an active player session and source generation;
- a current server-observed player position inside the portal radius;
- a current, revision-safe portal definition;
- the source context for region, location, interior, room or zone parents;
- map availability, disabled state, optional same-instance/state/group policy;
- instance capacity and routing-bucket operations when applicable.

Physical and optional named teleport targets are reference-validated during bundle compilation. The transition handler checks both the portal's own map availability and the referenced destination object's availability. An instance transition also verifies the base location referenced by its template before creating or joining a bucket.

Access, instance creation and routing-bucket operations may yield. The runtime therefore re-reads the active session, server position and source Context after access returns and immediately before a physical completion, transition grant or instance mutation. It also fences the portal, destination, instance-template and base-location revisions and rechecks destination map availability immediately before and after an instance join. Leaving the radius or parent Context during that interval fails with `PORTAL_TOO_FAR` or `OUT_OF_CONTEXT`; a pre-join definition or map refresh fails before the bucket mutation.

## Transition grants

Teleport and instance transitions create a server-bound grant containing source session/generation, character, portal revision, source context and destination. Grants expire after 8 seconds, are bounded globally to 4,096 live queue entries and may be consumed only once by the same active source/session. An instance transition first reserves a bounded pending grant, revalidates its source and destination fences, performs the join, and only then activates the 8-second expiry window. Pending grants cannot expire during a yielding bucket move; a failed pre-join check or join cancels the reservation. If a portal/destination refresh, grant activation or grant consumption fails after a successful join, World invokes a bounded, independently idempotent instance leave before returning the failure. A failed compensation is surfaced as a retryable `INSTANCE_BUCKET_UNAVAILABLE` result and audited instead of being reported as a successful transition. Expiry/replay cleanup uses tokenized queue entries and an amortized queue head; it does not repeatedly shift the complete grant list.

After server consumption, the client receives a closed, bounded `synex_world:client:apply_transition` message. The client accepts it only from the server transport source, rejects stale/replayed grant IDs and applies coordinates/heading. There is no client-to-server mutation event.

The native coordinate move and instance handoff still require the open real FXServer/OneSync/client acceptance run.
