# Groups and memberships

`synex_groups` is an experimental server-only foundation resource for durable groups, grades, grade capability rules, primary selection, and versioned user/character memberships. It is not job gameplay, a payroll system, or a UI.

## Contracts

The resource provides ten local RPC contracts:

- `synex.groups.create`
- `synex.groups.get`
- `synex.groups.add_membership`
- `synex.groups.change_membership`
- `synex.groups.remove_membership`
- `synex.groups.create_grade`
- `synex.groups.set_grade_capability`
- `synex.groups.set_primary_membership`
- `synex.groups.get_read_model`
- `synex.groups.check_capability`

The complete schemas, errors, and versions are generated in the [contract catalog](../../packages/contracts/generated/docs/contracts.md). All current contracts use `network: none`; consumers call through the core RPC gateway. The read-only `synex.groups@1` service exposes `get`, `get_read_model`, `list_subject_memberships`, `check_capability`, and `get_control_summary`, all under `synex.groups.read`. The membership projection returns at most 64 active entries and reports truncation explicitly; the control summary returns bounded operational aggregates. Mutations remain contract-only so the original caller and capability are preserved.

## Model and invariants

- Groups have a unique stable key, display name, type, status, metadata JSON, and optimistic version.
- Membership subjects are explicitly `user` or `character` references and point to one active grade in their group.
- Grades have group-local keys, a rank value, an active/disabled status, and a bounded set of exact or segment-wildcard capability rules.
- Capability evaluation gives matching deny rules precedence and returns the matched rules; it does not silently become a Core resource-capability grant.
- A subject can select one active membership as primary across groups, with an append-only primary-membership event and optimistic version; selecting it never removes or rewrites any other membership.
- Read models join membership, assigned grade, primary selection, and at most 128 grade rules under an explicit model version. That version is the cache invalidation token and advances on every relevant grade, rule, membership, or primary change.
- Membership changes record actor/reason and append a membership event.
- Mutations require an idempotency key and persist an operation fingerprint/result.
- Expected versions guard change/remove operations against lost updates.
- Domain events are written to the resource outbox in the same database transaction as the mutation.

An owner-aware scheduler runs the `synex_groups.outbox_dispatcher` once per second and claims at most 25 ready rows per batch. It publishes them through the capability-gated Core `Events.publishOutbox` surface with the stored `eventId`; subscriber failures are retried with bounded backoff, and the tenth failed attempt moves the row to `dead`. Delivery is at least once, so subscribers deduplicate by `eventId`.

The implementation owns only the tables listed in its resource manifest. Its required Core character-lifecycle participant prepares an `anonymize` action, then transactionally replaces character subject references with a generated anonymous reference, updates related actor/snapshot references, invalidates affected read models, records an outbox event, and completes an idempotent deletion journal. Membership and primary-event history is retained rather than cascaded away.

## Capabilities

Reads and capability checks require `synex.groups.read`. Base membership mutations require `synex.groups.manage`, grade changes require `synex.groups.grades.manage`, and primary selection requires `synex.groups.memberships.primary`. A consumer must declare and receive the exact grant. `synex_groups` itself is granted its internal domain pattern in the committed core policy.

Group membership and grade rules are domain facts, not automatically ACE principals or Core resource-capability grants. Consumers decide how a reviewed group/grade maps to their own user authorization contract.

## Limits

`0.1.0` has no job resource, group editor, hierarchy engine, payroll, client endpoint, or NUI. Integration has headless/static and live-schema coverage, but requires FXServer/database concurrency testing for the target deployment.
