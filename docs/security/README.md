# Capability policy and resource security

Private vulnerability reporting, supported versions, and disclosure guidance are defined in the repository [Security policy](../../SECURITY.md). The current Production-Beta security target is `synex_core` only; non-Core resources and libraries are experimental rework snapshots and unsupported for that deployment profile.

Synex applies two checks before a resource can use a protected core facade:

1. the caller's validated `synex.resource.json` must request the exact capability;
2. `core/synex_core/config/capabilities.json` must grant it and must not deny it.

Resource identity comes from `GetInvokingResource()` captured at the export boundary. It is useful attribution and policy context, not a Lua sandbox. Any server resource can call Cfx APIs outside Synex, so resource review remains mandatory.

Resource manifests are checked by Ajv during repository validation and by a closed-shape Lua validator during Core discovery. The runtime rejects unknown fields, sparse or duplicate declarations, incompatible API ranges, unsafe/duplicate migration paths, undeclared data ownership, malformed or oversized event/hook declaration sets, and any snapshot declaration other than schema `1`; it does not trust a file merely because it is local.

Event and hook authority is separate from general capability grants. A current owner epoch may publish, subscribe, register, or run only names declared for that operation in its currently validated manifest. Non-Core event publishers and hook callers are additionally confined to their resource-owned namespace. Self-declaration does not grant critical foreign-hook policy: a foreign provider is optional and cannot deny, while only Core or the hook namespace owner may register a required hook or deny an operation. A future third-party critical-hook model requires a centrally managed trust policy. Hook data and context are plain, closed and byte bounded, and absolute caller deadlines are rejected. Delivery rechecks consumer/provider authority, restart cleanup removes registrations and empty topic buckets, and fixed per-owner/global registration ceilings prevent a terminal wildcard from creating unbounded runtime state. Subscriber and hook exception details never enter logs; only bounded stable codes are recorded.

## Policy evaluation

- Exact requests and segment-bounded `.*` patterns are supported.
- Resource denies and default denies take precedence over all allows.
- An undeclared request returns `CAPABILITY_UNDECLARED`.
- A declared but ungranted or denied request returns `CAPABILITY_DENIED`.
- Denials produce bounded metrics and redacted structured logs and are rate-bounded into the durable Core audit sink; an audit-write failure never changes the denial into an allow.
- Contract and service providers must also declare what they provide; capability grants cannot bypass provider ownership.

The committed policy denies destructive/high-impact capabilities such as `synex.characters.delete`, `synex.entities.delete_persistent`, `synex.accounts.mint`, and `synex.accounts.burn` by default. Because deny wins, enabling one requires deliberately removing every applicable deny and then granting it only to a reviewed resource with a concrete operational need.

## Domain authorization

Capabilities answer whether a resource may attempt an operation. They do not prove that a user owns a character, account, group, or entity. Handlers must validate the current session, source generation, domain ownership, expected record version, and operation-specific rules after every yield that can make those facts stale.

Core RBAC is persisted in the Core-owned role, permission, assignment, and subject-version tables introduced by migration `008_core_rbac.sql`. Migration `016_rbac_policy_revision.sql` adds the singleton, monotonically increasing role-policy revision used to invalidate role definitions across runtime instances. The caller-bound `api.Permissions` facade exposes `defineRole`, `assign`, and `revoke` behind `synex.permissions.manage`, and `check` behind `synex.permissions.read`. Mutations require a bounded reason and write their before/after state, actor, reason, and trace to the Core audit log in the same database transaction as the RBAC change. Callers must declare and receive those capabilities; the committed policy grants neither capability by default.

Role permissions are bounded allow/deny entries and use the same segment-aware wildcard matching as the capability model. The optional explicit deny set supplied to `check` is evaluated first, and any matching role deny wins over role allows. Before an authorization decision or role-existence check for assignment, a persistent runtime reads the current global policy revision. A changed revision reloads one transactionally consistent role snapshot; a revision or snapshot error denies the operation instead of using stale grants. Role definition and snapshot transactions lock the singleton revision before reading roles, so concurrent definitions have one deterministic order. Assignments may carry a validated expiry. Subject lookups use a bounded TTL cache over versioned durable assignments; local mutations invalidate affected entries, while the cache TTL bounds observations of assignment changes made by another runtime instance.

The console `synex permissions` command is a redacted read surface only. Synex does not ship an RBAC mutation NUI or an automatic mapping from ACE, group membership, or account access roles into Core RBAC subjects. Any such mapping belongs to a reviewed server-side integration.

## Ban and allowlist administration

The server-only `api.Access` facade manages the durable access records used by the connection pipeline. `ban`, `unban`, `allow`, and `revokeAllowlist` require `synex.access.manage`; `list` requires `synex.access.read`. Neither capability is granted by the committed policy. Mutations are user-ID scoped in the current public surface, require a caller-provided idempotency key and reason, accept only bounded record/user IDs, and may use an expiry formatted `YYYY-MM-DD HH:MM:SS` when creating a ban or allowlist entry. The mutation, before/after audit record, actor, reason, and trace commit atomically.

The restricted console commands `synex ban`, `unban`, `allow`, and `unallow` are the operator path for the same durable records; `synex access` is a bounded user-scoped read. They remain console-only even if their Cfx command ACE is granted incorrectly to a player. The public mutation API does not currently expose identifier-targeted creation, bulk changes, wildcard subjects, or a client/NUI endpoint.

## Connection ingress

`playerConnecting` is bounded immediately after the Cfx deferral starts and before authentication, access checks, leases, gates, queues, or database work. Core holds at most `connections.maximumConcurrentConnections` ingress reservations across open deferral terminals and pending accepted connections. A reservation survives acceptance until the matching join consumes it, preventing clients that never finish joining from bypassing the bound; drop, pending expiry, rejection, pipeline cleanup, and Core quiesce release it.

Each attempt also consumes a token from a bucket keyed by a process-salted SHA-256 digest of the strongest server-provided connection identifier available. The raw identifier or IP value is used only as transient hash input and is never retained in the reservation, snapshot, metric, or log. Anonymous attempts share a fail-closed bucket. The shared Core limiter caps all keys at `8192` and sweeps keys idle for five minutes, so rotating identifiers cannot create unbounded in-memory state.

## Client and NUI boundary

Within the Core RPC transport, only contracts explicitly registered through `api.RPC.registerNetwork` are client-callable. That transport validates its closed plain wire envelope, procedure/version formats, finite integer deadline, idempotency key, cycle-safe depth/key/string bounds before payload encoding, encoded request-payload size, complete serialized response-envelope size, pending count, the aggregate source bucket and resolved contract-specific rate bucket, current session/source generation, request schema, capability, and response schema. Its monotonic handler deadline is capped by both the RPC timeout and the current local session-authority deadline. Deadlines remain cooperative, so a handler must reacquire the current session/source generation and changing domain authority after every yield before a protected mutation. Provider errors are copied into a closed bounded error object only when their code is declared by that contract; metatable-backed, malformed, or undeclared errors become `INTERNAL_ERROR` without exposing provider data. Optional compatibility and control resources own separate, narrowly scoped events; their server-side source/session/ACE/capability validation is part of those resources and does not turn them into arbitrary Core RPC entry points.

The cancellation event is a separate guarded transport boundary: it requires an active session, a syntactically valid request ID within the 8–96 character bound, the current source generation, and a per-source rate token. It only marks a matching in-flight request as cancelled; handlers must still treat cancellation as cooperative and preserve transaction/idempotency guarantees.

Domain handlers remain responsible for proximity, ownership, server-authoritative values, entity type/model/bucket, and any state that can change while awaiting a database or provider.

NUI callbacks are client input. `synex_control` exposes only a bounded read request, keeps the closed DOM transparent and non-interactive, and does not implement an administrative mutation callback.

## State and sensitive data

State definitions are namespaced to their owner and schema-validated. Sensitive state cannot be replicated. Core replication supports only global and player state; persistent and runtime entity authority belongs to `synex_entities`. Keep projections small and shallow and store authoritative data server-side.

Routine logs redact common secret and platform-identifier keys. Do not place secrets in `synex.resource.json`, contract files, state bags, NUI messages, generated artifacts, or audit context.

Audit and financial archive mode creates additional durable copies; it is not deletion or anonymization. Archive tables retain the source row identity and sensitive operational or financial context, so apply the same least-privilege database access, backup, incident-response, and legal retention controls as for their source tables. The committed `retain_forever` defaults make no automated deletion claim.

## Resource review checklist

- All client/NUI data is typed, bounded, authorized, and rate-limited server-side.
- Database values use positional parameters; dynamic identifiers come from code-owned allowlists.
- The resource declares only required capabilities and owns only its tables.
- No dynamic remote code, obfuscation, credential access, unknown HTTP, or cross-resource modification exists.
- Stop/restart removes registrations, timers, focus, entities, caches, and pending work.
- Errors expose stable codes, not SQL, stack traces, tokens, or full requests.
- Tests cover denial, malformed input, stale sessions/entities, replay/idempotency, and failure paths.

Run `npm run security` and `npm run certify`, then perform a manual review. The scanner explicitly does not prove security. See the broader [security model](../architecture/security.md).
