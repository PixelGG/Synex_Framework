# Groups and memberships

> [!WARNING]
> `synex_groups` requires a complete rework. The entire current resource—including its manifest, contracts, service surface, runtime ownership, workers, migrations, tests, and documentation—is provisional. It is unsupported, excluded from the `synex_core` Production-Beta candidate, and must not be deployed or advertised as ready.

The checked-in snapshot models durable groups, grades, grade capability rules, primary selection, and versioned user/character memberships. It is regression input for the rework, not its accepted design. Nothing in this page freezes an API, table, event, capability, migration, or compatibility promise. The rework starts only after the Core Production-Beta gate is complete; its own Security, Runtime, and Database acceptance must then pass before any maturity claim changes.

## Rework boundary and acceptance

The rework may retain, replace, or remove any snapshot behavior below. It must be reviewed as a new domain resource rather than promoted from passing repository tests.

| Gate | Required acceptance evidence |
| --- | --- |
| Scope and contracts | Reviewed ownership boundaries; versioned contracts/services/events; explicit caller and capability requirements; generated artifacts and reference documentation agree |
| Security | Server-authoritative mutations; bounded and schema-validated input; caller binding; exact capability checks; no client-trusted rank, group, subject, actor, or permission; rate and replay controls; parameterized SQL; redacted audit/error output; static scan plus manual endpoint review |
| Runtime | Fresh FXServer boot with `synex_core`; public API calls through a real external resource; success and denial paths; owner restart cleanup; scheduler/outbox retry and terminal behavior; idempotency replay; stale-facade rejection; character lifecycle cleanup; no leaked handlers, timers, registrations, or pending work |
| Database | Fresh install and supported forward upgrade on disposable MariaDB; migration checksums and ownership; exact constraints/indexes/FKs; transactional mutation plus outbox atomicity; optimistic-version and idempotency races on independent connections; rollback/failure injection; backup/restore verification; no manual schema repair |
| Capacity and soak | Declared limits at boundary and one beyond; bounded read models and queues; at least the documented resource soak with per-minute worker, pending-row, latency, and memory evidence; no unbounded retained authority |
| Release | Exact clean candidate, complete diff/security review, synchronized docs, explicit known limitations, real runtime evidence, and a separate release decision; Core acceptance alone does not satisfy this gate |

Until all mandatory rows pass on one exact `synex_groups` candidate, its status remains **full rework / unsupported**.

## Snapshot contracts

The checked-in snapshot declares ten local RPC contracts:

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

## Snapshot model and invariants

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

The checked-in snapshot defines an owner-aware `synex_groups.outbox_dispatcher` scheduled once per second with at most 25 ready rows per batch. Its code publishes through the capability-gated Core `Events.publishOutbox` surface with the stored `eventId`; subscriber failures use bounded backoff, and the tenth failed attempt moves the row to `dead`. This describes snapshot behavior only and is not accepted operational guidance.

The implementation owns only the tables listed in its resource manifest. Its required Core character-lifecycle participant prepares an `anonymize` action, then transactionally replaces character subject references with a generated anonymous reference, updates related actor/snapshot references, invalidates affected read models, records an outbox event, and completes an idempotent deletion journal. Membership and primary-event history is retained rather than cascaded away.

## Snapshot capabilities

Reads and capability checks require `synex.groups.read`. Base membership mutations require `synex.groups.manage`, grade changes require `synex.groups.grades.manage`, and primary selection requires `synex.groups.memberships.primary`. A consumer must declare and receive the exact grant. `synex_groups` itself is granted its internal domain pattern in the committed core policy.

Group membership and grade rules are domain facts, not automatically ACE principals or Core resource-capability grants. Consumers decide how a reviewed group/grade maps to their own user authorization contract.

## Snapshot limits

The checked-in `0.1.0` snapshot has no job resource, group editor, hierarchy engine, payroll, client endpoint, or NUI. Existing headless/static and live-schema tests preserve observable snapshot regressions only. They are not rework acceptance and do not establish runtime support, schema stability, security certification, or compatibility.
