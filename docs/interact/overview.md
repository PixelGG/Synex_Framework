# Interact overview and maturity

`synex_interact` turns nearby world and entity context into a small, stable set of possible player intents. A normal interaction follows this path:

```text
observed context -> bounded candidates -> primary intent -> server lease
                 -> slot/session/actor locks -> Action Graph -> cleanup
```

## What Interact owns

- client observation, candidate ranking and intent hysteresis;
- resource-owned Smart Object, intent and Action Graph definitions;
- runtime-only slots, reservations, leases, sessions and actor locks;
- server-side target/policy revalidation, replay-resistant activation and mandatory pre-commit authority fencing;
- owner-issued, actor/role-bound one-time admission for additional participants;
- bounded diagnostics, metrics, denial history and traces;
- presentation orchestration through the shared `synex_ui` runtime.

## What Interact does not own

- locations, doors, portals, interiors or instance truth (`synex_world`);
- persistent identity, model, generation, ownership or routing-bucket truth (`synex_entities`);
- groups, money, inventory, vehicles or another gameplay domain;
- durable interaction history, mail, audit retention or database tables;
- authorization derived from prompts, ray hits, NUI state, state bags or client coordinates.

The resource declares no migrations and no tables. Active interaction state is bounded and process-local. A restart invalidates leases, sessions, reservations, owner registrations and client presentation; owning domains remain responsible for durable facts and idempotent effects.

## Current maturity

The source includes the schema/compiler/registry, client sensor and intent engine, slot/session/lease/lock and Action Graph foundations, Core contracts/service integration, Control diagnostics, and the shared UI Interaction Surface. This remains **Experimental / Alpha** because repository checks cannot prove Cfx scheduling, OneSync authority, native shape-test behavior, real input devices, CEF focus/accessibility, resource restart timing or runtime cost on a populated server.

No public API in this module should be treated as stable before an exact-candidate release decision. See [testing](testing.md) and [known limitations](../known-limitations.md).
