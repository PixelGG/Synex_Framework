# Synex Interact

`synex_interact` is the context-aware interaction authority for Synex. It is deliberately not an ALT/target-mode replacement with a client-authoritative `canInteract` callback. The runtime discovers likely intents locally for responsiveness, while the server owns authorization, distance/context verification, slot reservation, and execution admission.

## Runtime model

```text
Context Sensor
    -> Intent Engine
    -> Smart Object
    -> Interaction Lease
    -> Action Graph / owner-domain dispatch
```

- **Context Sensor** samples gaze, distance, line of sight, movement, hit entities, and the nearby World context.
- **Intent Engine** ranks bounded candidates and presents one primary action without entering a separate targeting mode.
- **Smart Objects** are resource-owned semantic interaction definitions attached to a World anchor, Synex `EntityRef`, static position, or a combination of them.
- **Interaction Leases** are short-lived server-side reservations bound to the current session, `sourceGeneration`, smart-object slot, action, and owner resource.
- **Action Graphs** provide a bounded declarative execution sequence. A graph never turns client observations into authority.

## Design boundaries

`synex_world` owns semantic locations, rooms, zones, doors, portals, anchors, and World context. `synex_entities` owns stable entity identity and network-generation safety. `synex_ui` owns the visual language and focused menu/dialog primitives. `synex_notify` may later provide non-blocking feedback. `synex_interact` owns only interaction discovery, intent arbitration, reservation, and execution admission.

Gameplay resources retain their domain truth. Inventory, banking, vehicle ownership, jobs, housing, shops, and similar state do not move into `synex_interact`.

## Zero-mode interaction

There is no mandatory ALT target mode. The client continuously performs a bounded context sample and selects the strongest eligible intent. A subtle world affordance is rendered only when a candidate exists. `E` invokes the primary intent. When one smart object exposes multiple eligible actions, `G` can open the Synex context menu.

The local ranking is presentation logic only. Before execution the server revalidates the active session, source generation, current server position, target revision, World context, capability, target materialization, and lease ownership.

## Registration

A native Synex resource with the `synex.interact.register` capability may register bounded definitions through the `synex.interact@1` service or the caller-bound server export facade.

```lua
local interact = assert(exports.synex_interact:GetAPI('^1.0.0'))

assert(interact.register({
    {
        key = 'synex_example:evidence.counter',
        anchorRef = {
            kind = 'anchor',
            key = 'synex_example:evidence.counter',
            revision = 1,
        },
        radius = 3.0,
        actions = {
            {
                key = 'synex_example:evidence.open',
                label = 'Evidence öffnen',
                icon = 'archive',
                maxDistance = 1.8,
                priority = 20,
                slot = 'counter',
                leaseSeconds = 6,
                capability = 'synex.police.evidence.open',
            },
        },
    },
}))
```

Keys are namespaced. Definitions are owned by their registering resource and are removed automatically when that owner stops. A foreign resource cannot overwrite another owner's key.

## Entity-bound smart objects

An interaction may bind to a Synex `EntityRef`. The client shape test sends only a bounded hit Net ID as an observation. The server resolves the Net ID through `synex_entities`, matches it to a generation-safe `EntityRef`, obtains the authoritative server entity position, and performs distance validation. Net IDs are never persistent interaction identity.

## Non-graph actions

An action without an Action Graph publishes the bounded `synex.interact.action.requested` domain event after all lease and authority checks. The owner resource remains responsible for validating and performing its gameplay mutation. Consumers must not treat the client action request itself as authority.

## Current visual integration

The multi-action surface uses `synex_ui`. The passive zero-mode hint intentionally does not acquire NUI focus. Until `synex_ui` exposes a dedicated passive world-affordance surface, the interaction runtime uses a small direct-draw fallback instead of introducing a competing NUI layer.
