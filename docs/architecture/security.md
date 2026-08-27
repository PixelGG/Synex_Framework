# Security model

Synex assumes the client is hostile, server resources can be buggy, identifiers and network IDs can be stale, and database or provider failures can occur between steps.

This page documents the Core security model and the architectural rules expected of integrations. The Production-Beta security target is one frozen `synex_core` tree only. Groups is an Experimental Alpha Organizations Engine and Accounts is a server-only Experimental Alpha Financial Engine. Optional-resource endpoints, bridges, libraries, SDKs, and NUI behavior remain separate unsupported boundaries. Every downstream surface stays outside Core support until separately released.

## Trust boundaries

- Client payloads are untrusted. The shared transport validates envelope shape and size, contract input, session/source generation, and rate; the domain handler must validate current ownership, proximity, and other operation-specific facts.
- A client cannot assert a server resource identity or invoke arbitrary services.
- Resource manifests request capabilities; an operator policy grants them. A declaration is never a grant.
- `GetInvokingResource()` attributes server-side export calls but does not sandbox Lua resources.
- ACE principals, Core resource-capability grants, Core RBAC subjects, and Groups character capabilities are separate authorization domains. The Groups Alpha requires both the immediate resource grant and the current actor's exact organization authority for actor-driven operations; Core does not infer equivalence between those layers.
- The sole Groups client contract is `synex.groups.self.snapshot`. Core requires an active session and current source generation, applies the contract rate bucket, and supplies the character identity server-side; the closed request schema contains no actor field. The response is a bounded projection of that character's memberships, public grade/roles, and current duty state. Every other Groups contract remains server-only.
- Groups mutations perform a read-only aggregate/actor authorization preflight before Core character verification and before hooks; the authoritative transaction repeats the operation checks. Sensitive attribute and assignment detail reads conceal unauthorized and missing targets behind the same typed not-found result, while retryable infrastructure errors remain generic and retryable.
- Extension registry writes require a begin-per-resource-epoch synchronization session. Hydration and stop cleanup are bound to the exact active owner epoch, so a stale callback or older stop cannot cross a provider restart.
- Database operations use parameters. The Groups Alpha accesses only manifest-owned tables through Core's caller- and epoch-bound DataPort; SQL kind, identifiers, statement shape, limits, and table ownership are checked before execution. Other snapshots must not be treated as inheriting that boundary.
- DataPort idempotency serializes one exact receipt key, not an entire domain. Different keys may execute concurrently; handlers retain responsibility for deterministic row locks or compare-and-swap state and must not perform irreversible external effects inside a transaction that can roll back or retry. Global and owner receipt-capacity authority is acquired only after the handler result validates.
- Domain-deletion provider schema changes fail closed while pending actions require the previous version, and plan persistence rechecks the catalog under lock after preflight. Retained-plan limits are 10,000 globally and 1,000 per requester; every state counts until purge, while pending/executing plans are never automatically purged. Terminal replay expires with the physical 30-day retention boundary.
- A returned runtime database-health failure or adapter exception closes player admission and suspends ordinary database-backed recurring work. Because the call completed, two consecutive successful probes plus lifecycle/instance reconciliation can recover it automatically; independent health faults continue to block admission.
- The five-second watchdog is only a fail-closed fence and cannot cancel a Lua `Await`. If oxmysql `2.14.1` loses the callback for a rejected pool `getConnection()`, Core retains the outstanding probe, admission stays closed, and no superseding-probe or restart loop is started. After MariaDB is restored and independently verified, the safe incident boundary is one controlled restart of the complete FXServer process, not a raw Core or oxmysql-only restart.

## Capability classes

| Class | Intended use | Committed posture |
| --- | --- | --- |
| `normal` | Read-only or low-risk bounded operations | Explicit grant |
| `sensitive` | Personal, durable-event, or operational data | Explicit reviewed grant |
| `privileged` | Administrative or high-impact mutation | Explicit reviewed grant; operation-specific audit where implemented |
| `destructive` | Irreversible or high-impact mutation | Applicable deny must be removed deliberately before a dedicated grant can take effect |

Deny rules take precedence. The class is diagnostic metadata, not an additional RBAC decision; resource capability policy and Core RBAC are separate authorization domains. Capability checks occur before input reaches a handler and are repeated where ownership or state can change across an await boundary.

## Network boundary

The Core RPC layer uses one bounded request, response, and cancellation transport. A Core RPC procedure must be explicitly marked as network-callable. The server binds the request to the current session/source generation, applies token buckets, validates the request contract, authorizes the principal, invokes with a deadline, revalidates the generation, validates the response, and replies only to that source. Optional resources that expose their own narrow Cfx events remain separate reviewed trust boundaries; they do not bypass or extend the Core RPC registry.

Timeouts are cooperative in Cfx Lua: late results are discarded, but a blocking third-party handler cannot be forcibly preempted. A configured deadline is therefore not an isolation boundary; operators must exercise provider latency and failure behavior in the target FXServer.

## Sensitive data

Secrets, raw identifiers, tokens, full request bodies, and financial metadata are redacted from routine logs and diagnostics. State bags contain only small, non-sensitive projections. Server-authoritative storage remains the source of truth.

## Current acceptance status

The frozen accepted Core tree passed repository security analysis and its final documentation/diff/secret review without a confirmed finding. That runtime revision is published to `main`, and its real-client smoke completed without a security or authority regression. The aggregate decision for that exact Core-only profile is **PASS**. Current Core domain primitives and the Groups Alpha remain outside that security and exact-tree decision; this paragraph does not pre-approve them.

A prior manual static security and operations review found no release blocker or confirmed Critical, High, Medium, or Low finding. It covered the Core client transport handlers, caller-bound exports/facades, local Cfx events, contract/capability ownership, Core persistence call shapes, log redaction, resource/player/timer/deferral cleanup, dependency locks, SHA-pinned workflows, secrets, executable/malware indicators, and the then-current absence of an active client-callable domain contract. That review predates `synex.groups.self.snapshot`; it is regression context and not security acceptance of the new endpoint, downstream resources, provider handlers, or alternate runtime versions.

Database-outage/recovery, the final automated run, documentation/final-diff/secret review, publication to `main`, and the client join/clean-disconnect/reconnect smoke have passed for commit `7ad4b72ee9bcd0a2a0481cfacfe5f807eb1b3ec5` and Core tree `9f0960f1e27fe43195ae4602cb2ef447cbc0509b`. Doctor remained `PASS`; final cleanup left zero open sessions, active session leases, and active admission leases. Longer soak, permanent evidence-runner, historical upgrade, extensive restore certification, and extra non-critical ABI work are post-Beta promotion items rather than initial Beta security blockers.
