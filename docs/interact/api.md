# Interact API and contracts

All APIs are **experimental**. The canonical request/response/error shapes are in [`interact.contracts.json`](../../resources/synex_interact/contracts/interact.contracts.json).

## Caller-bound server facade

```lua
local interact, interactError = exports.synex_interact:GetAPI('^1.0.0')
if not interact then return nil, interactError end
```

The facade captures the immediate resource and its current owner epoch. A stopped/restarted owner cannot continue through the old facade.

| Method | Purpose | Capability |
| --- | --- | --- |
| `registerBundle(bundle)` | compile and atomically register one owned bundle | `synex.interact.bundle.register` |
| `replaceBundle(bundle, expectedRevision)` | revision-checked replacement | `synex.interact.bundle.register` |
| `unregisterBundle(key, expectedRevision)` | revision-checked removal | `synex.interact.bundle.register` |
| `registerProvider(definition, handler)` | bounded server validation for dynamic bindings | `synex.interact.provider.register` |
| `registerEvaluator(definition, handler)` | namespaced custom condition evaluator | `synex.interact.provider.register` |
| `registerAdapter(definition, handler)` | typed Action Graph domain adapter | `synex.interact.adapter.register` |
| `inviteParticipant(request)` | issue a short-lived, actor/role-bound invitation for one owned session | `synex.interact.runtime.manage` |
| `renewLease(leaseId, extensionMs)` | fully revalidate and extend one active lease owned by this resource incarnation | `synex.interact.runtime.manage` |

Manifest-declared bundles are preferred for stable definitions. Direct registration still enforces namespace, owner epoch, capability, bounds and conflicts.

`inviteParticipant` accepts exactly `sessionId`, `role`, `source` and an optional `ttlMs` from 500 through 10,000. The returned `invitationId` is bound to that session, role, player source, source generation, Core session identity, owner and owner epoch. It is consumed once by `synex.interact.session.join`; it is not a reusable lobby credential. `renewLease` accepts an extension from 100 through 10,000 milliseconds, can address only a lease belonging to the captured owner/epoch and still runs the full actor, session, target, World, policy, availability and slot checks.

## Caller-bound client facade

Client resources can add bounded local discovery candidates without receiving lease or gameplay authority:

```lua
local interact, interactError = exports.synex_interact:GetAPI('^1.0.0')
if not interact then return nil, interactError end
```

| Method | Purpose |
| --- | --- |
| `registerCandidateProvider(definition, handler)` | owner/epoch-bound `actor`, `dynamic` or `ephemeral` local candidates |
| `registerConditionEvaluator(definition, handler)` | owner/epoch-bound custom visibility predicate for observed client context |
| `getDiagnostics()` | copied sensor/UI/session counters, redacted intent scores and aggregate rejection reasons, gauges, local duration totals and the optional bounded development trace |

The provider definition is namespaced and bounded; its handler returns observed positions/binding keys only. It may set `priority`, `kind`, `timeoutMs`, `intervalMs` and `cacheTtlMs`. `intervalMs` (`33..5000`, default `250`) is a minimum refresh cadence, while `cacheTtlMs` (`0..5000`, default `1000`) controls how long the last valid observed result remains eligible. A deterministic priority/key-ordered round-robin starts at most four due providers per sample and keeps at most 16 provider callbacks in flight. Only providers referenced by the current dynamic discovery index are scheduled. Missing, pending, expired, timed-out and malformed results contribute no candidates. `actor` providers are useful for a deliberately selected, bounded actor set and do not scan global ped/player pools. Dynamic candidates require a matching canonical binding/server provider before authorization; no provider output is authority. The facade and every pending generation become stale when its owning client resource stops or restarts.

A condition evaluator receives a copied `OBSERVED` visibility context plus the bundle-declared `arguments` and must return one boolean. Calls run outside the sensor hot path, use a short bounded cache, and fail closed while missing, pending, saturated, timed out, failed, or malformed. Registration and cached results are removed with the client owner's epoch. Its output can hide or show a prompt only; the canonical server execution policy still decides whether a lease may be issued.

Client visibility evaluators and server evaluators are deliberately separate registries. A `visibilityConditions` evaluator needs only `registerConditionEvaluator` on the client; bundle activation does not require a same-key server callback. Server `registerEvaluator` remains required for server availability policies and Action Graph evaluator conditions, where the callback participates in authority or execution.

Intent diagnostics intentionally omit candidate/player/entity/session identifiers, target payloads and coordinates. They expose stable rejection/advisory codes, bounded counts, namespaced intent keys, score terms and aggregate evaluator invocation/failure/timeout/cache counts. Deterministic fixture replay remains an internal Lua test/diagnostic utility and is not exposed as a client facade mutation or an authorization path.

## Core service

`synex.interact@1` exposes the snake_case equivalents:

```text
register_bundle  replace_bundle  unregister_bundle
register_provider  register_evaluator  register_adapter
invite_participant  renew_lease
summary  doctor  inspect  replay_trace
```

`invite_participant` and `renew_lease` require `synex.interact.runtime.manage`; summary and diagnostic methods require their declared diagnostic capability. Both runtime methods derive the owner and current owner epoch from service context, so a request cannot invite into or renew a lease from another owner incarnation. `inspect` accepts one exact namespaced key and returns only bounded Smart Object or Action Graph metadata; it omits player identities, target IDs and domain request payloads. `replay_trace` accepts one exact trace ID and returns at most 100 retained development frames from the process-local, time- and capacity-bounded ring.

## Canonical contracts

| Contract | Network | Intended caller |
| --- | --- | --- |
| `synex.interact.bundle.register` | none | authorized server resource |
| `synex.interact.bundle.replace` | none | authorized server resource |
| `synex.interact.bundle.unregister` | none | authorized server resource |
| `synex.interact.discovery.snapshot` | client-to-server | internal active-session client runtime |
| `synex.interact.discovery.entities` | client-to-server | internal active-session client runtime |
| `synex.interact.lease.request` | client-to-server | internal active-session client runtime |
| `synex.interact.lease.activate` | client-to-server | internal active-session client runtime |
| `synex.interact.session.cancel` | client-to-server | current session participant |
| `synex.interact.session.join` | client-to-server | invited active player presenting the exact owner-issued session/role token |
| `synex.interact.session.leave` | client-to-server | current session participant |
| `synex.interact.graph.ack` | client-to-server | internal presentation acknowledgement |
| `synex.interact.metrics.report` | client-to-server | internal aggregate-only telemetry |

Application resources normally integrate through a manifest bundle or caller-bound server facade. Discovery, lease, graph and metrics contracts are runtime internals, not a shortcut around server policy.

`synex.interact.discovery.snapshot` is a deterministic, revision-fenced paging protocol. The first request uses `snapshotRevision = 0` and `page = 1`; continuation requests echo the returned `revision` and advance `page` sequentially. The server encodes the complete registry-ordered discovery array once per revision, caps it at 2,048 objects and 262,144 encoded bytes, then transfers it through at most 24 UTF-8-safe chunks. Each chunk is at most 14,000 bytes and its complete encoded response envelope is verified at no more than 28,672 bytes, leaving headroom below Core's 32 KiB transport ceiling. Keeping the snapshot inside a bounded string also avoids exhausting Core's table-key/depth budget with a deeply nested object page. Every page repeats the snapshot `objectCount` and `totalBytes`. Any registry revision change makes the in-flight transfer stale. The client checks all metadata, stages the transfer for at most ten seconds, concatenates and decodes the complete payload, and replaces its discovery indexes only after the declared final page has arrived; failed or incomplete transfers leave the previous snapshot active.

## UI boundary

The Interact client uses the caller-bound `synex_ui` facade methods `upsertInteraction`, `removeInteraction`, `getInteractionSnapshot` and `bindInteractionActions`. `synex_interact:client:graph` carries bounded server presentation commands. Neither interface is a gameplay-authority API.

## Error shape

```lua
{
    code = 'INTERACT_LEASE_DENIED',
    message = 'The interaction target is outside the allowed range.',
    retryable = false,
}
```

Branch on stable `code`, not human text. Expected failures include invalid/stale bundle, owner, intent, target, slot, lease/session/graph, actor busy, rate limit, payload/capacity and unavailable conditions. Internal stacks/provider details are not public errors.
