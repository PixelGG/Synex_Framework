# Developing with Interact

Use declarative bundles for stable interactions. Register dynamic providers/evaluators/adapters only when a closed bundle cannot express the required integration.

The complete minimal example is [`examples/synex_interact_companion`](../../examples/synex_interact_companion/README.md).

## Make a World Anchor interactable

1. Declare the anchor in a `world/*.world.json` bundle owned by the same companion resource.
2. Declare a `worldRef` Smart Object binding with `kind: "anchor"` and that exact key. `worldAnchor` remains a compatibility shorthand.
3. Add at least one slot, intent and terminal Action Graph.
4. List both bundle paths in `synex.resource.json` and `fxmanifest.lua`.
5. Request and receive both bundle-registration capabilities.

World remains the source of anchor position/revision; Interact remains the source of intent/session/lease state.

## Add an interaction to an Entity

For one managed entity, bind an exact EntityRef:

```json
{
  "type": "entityRef",
  "entityId": "entity_01HXYZ",
  "generation": 4
}
```

For a class of entities, declare an `entityArchetype` with a real archetype or model selector. Do not persist or authorize by NetID. A managed target must pass live EntityRef generation, model/type, coordinate and routing-context checks on the server.

## Add a vehicle bone interaction

```json
{
  "type": "entityBone",
  "model": 123456789,
  "bone": "boot"
}
```

Replace the illustrative model with an exact verified hash. Bone lookup is client discovery only. Vehicle ownership, keys, storage and inventory remain typed calls to their owning domains and are revalidated there.

## Define a Smart Object and slots

```json
{
  "key": "synex_my_resource:terminal",
  "binding": {
    "type": "worldRef",
    "kind": "anchor",
    "key": "synex_my_resource:terminal_anchor"
  },
  "slots": [{
    "key": "operator",
    "interactionRadius": 2.0,
    "facingTolerance": 100,
    "capacity": 1
  }],
  "activities": ["synex_my_resource:inspect"],
  "presentation": { "label": "Terminal" }
}
```

Use multiple slots/roles only when the interaction genuinely requires them. The server aggregates every role's declared capacity, reserves all claims atomically and converts them to occupancy only after the required ready barrier.

Doors and portals use the same binding with `kind: "door"` or `kind: "portal"`. Interact discovers and leases the affordance; the typed World operation still owns door state or portal transition.

## Create an Action Graph

```json
{
  "key": "synex_my_resource:inspect",
  "entry": "verify",
  "timeoutMs": 10000,
  "locks": ["actor.hands"],
  "nodes": [
    { "key": "verify", "type": "verifyTarget", "next": "progress" },
    {
      "key": "progress",
      "type": "progress",
      "durationMs": 700,
      "presentation": {
        "label": "Inspecting terminal",
        "mode": "timed",
        "cancellable": true
      },
      "next": "complete"
    },
    { "key": "complete", "type": "complete" }
  ]
}
```

For a domain effect, use `serviceCall` or `contractCall` with a registered typed adapter and an explicit `commit`. Never add an arbitrary event node or direct cross-domain SQL.

Use `mode: "determinate"` only when the owning workflow has a real bounded value:

```json
{
  "key": "scan-progress",
  "type": "progress",
  "presentation": {
    "label": "Scanning records",
    "mode": "determinate",
    "value": 7,
    "maximum": 20
  },
  "next": "complete"
}
```

Do not convert an unknown operation into an artificial percentage. Use `indeterminate`, or `timed` only when the graph owns a real bounded duration.

## Secure an interaction

- Treat visibility and client context as hints.
- Put required capability and maximum distance in canonical execution policy.
- Use WorldRef/EntityRef revisions rather than source handles.
- Resolve prices, permissions, ownership and mutable state in the server/domain adapter.
- Keep adapters idempotent and decide durable commit in the owning domain.
- Handle stale, denied, busy, rate-limited and unavailable errors explicitly.

## Add a custom candidate provider

Custom observed candidate providers should declare their refresh and cache bounds explicitly:

```lua
local interact = assert(exports.synex_interact:GetAPI('^1.0.0'))
local provider = assert(interact.registerCandidateProvider({
    key = 'synex_my_resource:nearby_terminals',
    kind = 'dynamic',
    timeoutMs = 16,
    intervalMs = 250,
    cacheTtlMs = 1000,
}, function(context)
    return readBoundedNearbyTerminals(context)
end))
```

The handler runs only when an active discovery definition references its key. `intervalMs` is a minimum cadence, not a scheduling guarantee: the client starts at most four providers per sample and uses a deterministic round-robin when more are due. Return only bounded observed `bindingKey`/position records. Never scan the global entity or player pools, and never treat the cached result as authorization.

## Add a custom client visibility condition

Prefer a declarative condition whenever possible. For a condition that genuinely needs local observed state, declare an owner-namespaced evaluator key in `visibilityConditions`, then register that exact key from the owning client resource:

```lua
local interact = assert(exports.synex_interact:GetAPI('^1.0.0'))
local evaluator = assert(interact.registerConditionEvaluator({
    key = 'synex_my_resource:can_inspect',
    timeoutMs = 8,
    cacheTtlMs = 250,
}, function(request)
    return request.context.actor.dead == false
        and request.arguments.mode == 'inspect'
end))
```

The callback receives copied observed context and must return a boolean. Missing, pending, timed-out, failed and non-boolean results hide the candidate until a valid cached result exists. Interact removes the registration and cache when the owner resource epoch ends.

Do not register the same callback on the server merely to activate the bundle: client visibility evaluators are not server runtime dependencies. Use server `registerEvaluator` separately only for a Smart Object/slot availability policy or an Action Graph condition, and repeat every security-relevant rule in canonical execution policy or the owning domain.

## Invite another participant

Only the server resource that owns the interaction session may issue a join invitation:

```lua
local interact = assert(exports.synex_interact:GetAPI('^1.0.0'))
local invitation = assert(interact.inviteParticipant({
    sessionId = activeSessionId,
    role = 'assistant',
    source = invitedSource,
    ttlMs = 5000,
}))
```

The owner needs `synex.interact.runtime.manage`. The returned `invitationId` works only for the named active player incarnation, session and role and can be consumed once by the internal `synex.interact.session.join` contract. Interact does not provide a public lobby or matchmaking channel; the owning domain must select the participant server-side and must not issue an invitation solely from an unvalidated client-supplied source. A failed admission after token consumption requires a new invitation.

Do not build a client heartbeat for leases. Interact renews leases server-side while a graph is running. If the owning server resource has a separate bounded reason to renew an active lease, it may call `renewLease(leaseId, extensionMs)` with `synex.interact.runtime.manage`; the owner fence and full authoritative renewal checks still apply.

## Diagnose a missing intent

Check in this order:

1. resource manifest and bundle declaration/path;
2. capability grant and owner epoch;
3. bundle compiler/registry status and discovery revision;
4. World/Entity/actor-provider target availability and local candidate count;
5. visibility-condition result and score breakdown;
6. LOS/radius/slot selector and hysteresis state;
7. caller-bound client diagnostics for context, provider counts, score breakdown, primary intent and the bounded development trace;
8. Control `health`, `bundles`, `providers`, `smart_objects`, `slots`, `graphs` and `findings` views;
9. denial code when a visible intent fails at lease time.

Do not enable raw player/target payload logging to debug selection.

## Validate before live testing

From the repository root:

```text
npm run validate
npm run test:tooling
npm run check
npm test
npm run security
node --experimental-strip-types tools/cli/src/bin.ts certify resource examples/synex_interact_companion
```

These commands validate repository/schema behavior only. Complete the [live acceptance](testing.md) before any maturity or support claim.
