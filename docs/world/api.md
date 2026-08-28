# Server API and contracts

`synex_world` defines one local multi-method service and seven experimental RPC contracts. All are server-to-server surfaces. They preserve Core's immediate caller and capability checks; no convenience export may substitute the provider as the consumer principal.

## `synex.world@1` service

Consumers acquire Core directly and call the service:

```lua
local api, apiError = exports.synex_core:GetAPI('^1.0.0')
if not api then return nil, apiError end

local result, worldError = api.Services.call(
    'synex.world',
    '^1.0.0',
    'queryNearby',
    {
        position = { x = 0.0, y = 0.0, z = 0.0 },
        radius = 25.0,
        filters = { kind = 'anchor', tags = { 'synex.anchor.counter' } },
        limit = 16,
    },
    { timeoutMs = 3000 }
)
```

The second return value is authoritative for failure across a Cfx resource boundary.

| Methods | Capability | Boundary |
| --- | --- | --- |
| `getHealth`, `getControlSummary`, `listBundles`, `doctor` | `synex.world.diagnostics.read` | bounded operational reads |
| `resolve`, `get`, `getChildren`, `checkAccess`, `explainAccess` | `synex.world.read` | key/ref and policy reads |
| `queryAt`, `queryNearby`, `getContext`, `verifyContext`, `getAnchors`, `getDoors`, `getPortals` | `synex.world.query` | bounded spatial/context reads |
| `getState` | `synex.world.state.read` | schema-checked state read |
| `getDoorState` | `synex.world.door.read` | logical door-state read |
| `registerBundle`, `replaceBundle`, `unregisterBundle` | `synex.world.bundle.register` | caller-owned declared bundle lifecycle |

Service calls share a per-resource, owner-epoch-reset token bucket. Query radius is at most 1,000, normal result limit at most 256, bundle pages at most 100, and doctor results at most 250.

`getContext` accepts exactly one of a position or player source. A source request uses the server-observed player ped position and current instance, fenced by the same active session ID and source generation before and after position, instance and Context resolution. `verifyContext` always recomputes from a similarly fenced player source. Its expected value must be the exact bounded server Context shape; registry revision, singular hierarchy, sorted region/zone sets and instance ID/revision/template/lifecycle-state identity must all match. Internal ownership, capacity and bucket metadata are deliberately excluded from the Context and client slice. Supplied Context remains comparison input, never authority.

## Mutation contracts

| Contract | Capability | Purpose |
| --- | --- | --- |
| `synex.world.state.set@1.0.0` | `synex.world.state.write` | optimistic runtime/persistent state mutation |
| `synex.world.door.set_state@1.0.0` | `synex.world.door.write` | revision-safe logical door mutation |
| `synex.world.portal.transition@1.0.0` | `synex.world.transition` | validated physical/teleport/instance transition |
| `synex.world.instance.create@1.0.0` | `synex.world.instance.create` | create a map-/revision-fenced Entity-backed instance bucket |
| `synex.world.instance.join@1.0.0` | `synex.world.instance.manage` | join an active source with post-move session/template/map fences |
| `synex.world.instance.leave@1.0.0` | `synex.world.instance.manage` | apply the server-owned template exit after safe membership removal |
| `synex.world.instance.close@1.0.0` | `synex.world.instance.manage` | exit all connected members, then drain and destroy an owned instance |

Every contract is `network: none`, idempotent and rate-limited in the canonical [`world.contracts.json`](../../resources/synex_world/contracts/world.contracts.json). Mutations require an operation-specific 8–36 character `idempotencyKey`. World scopes that key by the immediate calling resource and fixed, versioned contract operation, fingerprints the remaining bounded request together with the current World process incarnation, and delegates durable claim/replay authority to Core before executing the handler. The caller suffix is encoded losslessly into Core's bounded operation alphabet, so every valid resource name—including maximum-length names and repeated underscores—retains an independent namespace. Every successful output includes `replayed`; it is `false` for the claimed execution and `true` when Core returns the stored response without invoking the World handler in the same World incarnation. Reusing the key with a different request, or retrying a receipt created by an earlier World process, fails closed with `CONCURRENT_MODIFICATION`. Use `api.RPC.call` or generated SDK metadata from a server resource; never expose the contract directly to an unvalidated client request.

## Read-model caveats

Object projections omit internal compiled geometry/index entries and database handles. Detailed resolve includes declarative geometry and selected definition metadata; Door projections use the canonical `autoRelockSeconds` field from the bundle schema. Client exports are a separate stale-tolerant UX cache and must not be confused with this server service.
