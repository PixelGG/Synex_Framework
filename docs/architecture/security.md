# Security model

Synex assumes the client is hostile, server resources can be buggy, identifiers and network IDs can be stale, and database or provider failures can occur between steps.

This page documents the Core security model and the architectural rules expected of future integrations. The current Production-Beta security target is `synex_core` only; group/account rules, optional-resource endpoints, bridges, libraries, SDKs, and NUI behavior belong to unsupported rework snapshots until separately accepted.

## Trust boundaries

- Client payloads are untrusted. The shared transport validates envelope shape and size, contract input, session/source generation, and rate; the domain handler must validate current ownership, proximity, and other operation-specific facts.
- A client cannot assert a server resource identity or invoke arbitrary services.
- Resource manifests request capabilities; an operator policy grants them. A declaration is never a grant.
- `GetInvokingResource()` attributes server-side export calls but does not sandbox Lua resources.
- ACE principals and Core RBAC subjects are separate authorization domains. The experimental group capability and account access-role snapshots are separate again; Core does not infer equivalence, and any future mapping must be explicit in a reviewed server-side integration.
- Database operations use parameters. Dynamic identifiers must be selected from code-owned allowlists.
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

Current-tree repository security analysis and the final documentation/diff/secret review passed without a confirmed finding. The accepted runtime revision is published to `main`, and the real-client smoke completed without a security or authority regression. The aggregate Core-only Production-Beta decision is **PASS**.

A prior manual static security and operations review found no release blocker or confirmed Critical, High, Medium, or Low finding. It covered the two client-to-server RPC handlers, caller-bound exports/facades, local Cfx events, contract/capability ownership, Core persistence call shapes, log redaction, resource/player/timer/deferral cleanup, dependency locks, SHA-pinned workflows, secrets, executable/malware indicators, and the absence of NUI or active client-callable contracts. That review is regression context and not a claim that future contracts, downstream resources, provider handlers, or alternate runtime versions are secure without their own review.

Database-outage/recovery, the final automated run, documentation/final-diff/secret review, publication to `main`, and the client join/clean-disconnect/reconnect smoke have passed for commit `7ad4b72ee9bcd0a2a0481cfacfe5f807eb1b3ec5` and Core tree `9f0960f1e27fe43195ae4602cb2ef447cbc0509b`. Doctor remained `PASS`; final cleanup left zero open sessions, active session leases, and active admission leases. Longer soak, permanent evidence-runner, historical upgrade, extensive restore certification, and extra non-critical ABI work are post-Beta promotion items rather than initial Beta security blockers.
