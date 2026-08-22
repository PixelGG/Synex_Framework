# Security model

Synex assumes the client is hostile, server resources can be buggy, identifiers and network IDs can be stale, and database or provider failures can occur between steps.

## Trust boundaries

- Client payloads are untrusted. The shared transport validates envelope shape and size, contract input, session/source generation, and rate; the domain handler must validate current ownership, proximity, and other operation-specific facts.
- A client cannot assert a server resource identity or invoke arbitrary services.
- Resource manifests request capabilities; an operator policy grants them. A declaration is never a grant.
- `GetInvokingResource()` attributes server-side export calls but does not sandbox Lua resources.
- ACE principals, Core RBAC subjects, group capability rules, and account access roles are separate authorization domains. Core does not infer equivalence; any mapping must be explicit in a reviewed server-side integration.
- Database operations use parameters. Dynamic identifiers must be selected from code-owned allowlists.

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
