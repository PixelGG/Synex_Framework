# Interact testing and open acceptance

`synex_interact` is **Experimental / Alpha**. Repository checks prove deterministic source/schema behavior only; they do not accept the deployable runtime.

## Repository gates

Run from the repository root:

```text
npm run validate
npm run test:interact
npm run test:tooling
npm run check
npm test
npm run test:ui:visual
npm run security
npm run certify
```

The relevant repository surface must cover, without weakening bounds:

- bundle schema/path validation, compiler references/conflicts/revisions and atomic activation;
- Context Sensor camera/ray lifecycle, spatial broadphase and World/Entity/actor-provider bounds;
- candidate caps, no global entity-pool scan, provider interval/cache scheduling, round-robin start/concurrency budgets and adaptive cadence;
- transport-safe discovery chunking, UTF-8 boundaries, envelope/object/aggregate bounds, revision drift, timeout and atomic full-snapshot activation;
- intent scoring, deterministic ties, hysteresis, history, aggregate client-safe rejection reasons, unknown-condition behavior and isolated deterministic context replay;
- direct anchor/door/portal `WorldRef` discovery plus server kind/key/revision/session fences;
- static/dynamic availability, slot/exclusive concurrency and owner-fenced extension timeouts;
- slot capacity, required-role atomic multi-slot reservations, separate optional-role claims, canonical slot fencing, TTL and cleanup;
- actor/session/source-generation, target/intent/revision-bound leases, active-plus-pending admission capacity and pre-yield activation replay denial;
- owner-issued actor/role/session-bound invitation theft, wrong-role/source-generation use, expiry and one-time replay denial;
- single/multi-actor ready barriers, optional roles, explicit late join, participant loss/replacement, actor/source indexes and actor-lock conflicts;
- graph validation/control/presentation/adapters, mandatory pre-commit authority fencing, adapter non-invocation on guard failure, timeouts/cancellation/cleanup and server-side running-graph renewal;
- post-yield actor, target revision, World instance/position, policy, availability, reservation and lock revalidation before mutations;
- owner/Core/UI/Interact restart fencing and stale callbacks/facades;
- hostile/malformed client requests, rate limits, payload bounds and public-error redaction;
- cue, Action Bloom and progress behavior across keyboard, mouse, gamepad and accessibility profiles, including live hint fallback, disabled-item roving focus and monotonic/capped timer cleanup;
- client telemetry epoch baselines, monotonic/bounded deltas and advisory-only health behavior;
- manifest/contracts/Control/Doctor and example bundle validation.

Do not publish virtual fixture cardinalities or local timing as server capacity or FiveM performance.

## Required live gates

Before any maturity promotion, test the exact candidate on the intended FXServer artifact with OneSync and a real FiveM/CEF client:

1. dependency start order and exact `READY`/health behavior;
2. companion World/Interaction bundle discovery, multi-page transfer, stop/start, replacement, interrupted staging and stale-revision rejection;
3. real camera ray, asynchronous shape-test lifecycle, soft aim cone, bone lookup and LOS behavior;
4. world anchor, managed EntityRef, ambient entity and routing-bucket target validation;
5. primary activation, more-action bloom, cancel, timed progress and server graph acknowledgement;
6. keyboard, mouse and gamepad mappings plus passive device-hint switching;
7. reduced motion, high contrast, Interaction Assist, live CEF accessibility and screen-edge/safe-zone behavior;
8. one- and multi-actor slot/session flows, owner-issued invitations, theft/replay/source-reuse attempts, running-graph renewal, loss policy and disconnect/reconnect cleanup;
9. owner, `synex_ui`, `synex_interact` and Core restart during discovery, lease and graph phases;
10. forged/replayed/concurrent/stale/oversized/flooded requests, source reuse, owner restart and capability denials, including a target/World change while a yielding evaluator is in flight;
11. measured idle/near/focused/bloom/graph, maximum-provider/discovery and populated-server cost using Resmon/profiler evidence;
12. final diff, generated-artifact, secret and exact-candidate review.

Until these gates pass and an explicit owner decision is recorded, documentation must retain **Experimental / Alpha** and must not claim production compatibility or performance.
