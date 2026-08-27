# Accounts Financial Engine

> [!WARNING]
> `synex_accounts` is an **Experimental Alpha**. Its automated implementation is largely complete, but the current candidate has not yet completed the separate real-MariaDB, FXServer, restart, crash-recovery, or upgrade acceptance required for a production ledger. It remains outside the frozen `synex_core` Production-Beta boundary.

`synex_accounts` is the server-owned financial domain for Synex. It provides currencies, accounts, an immutable multi-leg ledger, balance snapshots, holds, account-local access policy, reversals and refunds, reconciliation, audit evidence, and a durable outbox. It is not a player-facing banking UI and does not replace a future `synex_banking` gameplay resource.

## Boundary and maturity

| Property | Current source state |
| --- | --- |
| Resource | `synex_accounts` `0.1.0` |
| Runtime | server-only FiveM resource |
| Core health role | `critical: true` when installed/discovered; incomplete registration or a stopped installed resource fails closed |
| Dependencies | `synex_core >=0.1.0`, `oxmysql >=2.14.1` |
| Public contracts | 59 experimental contracts; all declare `network: none` |
| Service | `synex.accounts@1`, experimental and server-local |
| Schema | 17 ordered resource migrations, `001` through `017` |
| Maturity | Experimental Alpha |
| Acceptance | automated source tests exist; real MariaDB/FXServer/restart acceptance is deferred |

No Accounts operation is client-callable. A gameplay resource must resolve the authenticated actor and all authoritative economic inputs on the server, declare the exact contract and capability, and call through `synex_core`.

## Financial truth

- Amounts are signed integer **minor units**. A currency fixes its precision from `0` through `6`; floating-point money is not accepted.
- Account rows contain identity, role, owner, lifecycle state, and policy references. Booked and reserved values come from append-only balance snapshots, not a mutable balance column.
- A posted transaction contains **2 through 16** signed ledger entries in one currency. Entries must sum to zero and may not repeat an account.
- Each mutation locks affected accounts in a deterministic order and uses version/sequence checks. Deadlocks and lock-wait timeouts receive bounded retries; other database failures do not.
- `available_minor = booked_minor - active, unexpired remaining holds` for an asset account.
- Transaction, snapshot, audit, and outbox rows are written in the same domain database transaction. External event delivery happens later and is at least once.

This is a game-economy ledger, not a general-purpose GAAP accounting system or a financial-services compliance certification.

## Contract and service surface

The exact request, output, version, capability, and error schemas are generated from [`accounts.contracts.json`](../../resources/synex_accounts/accounts.contracts.json) into the [contract catalog](../../packages/contracts/generated/docs/contracts.md). The 59 current source contracts are grouped below.

| Area | Current contracts |
| --- | --- |
| Currency | `currency.register`, `currency.get`, `currency.list`, `currency.update` |
| Accounts | `get`, `list_by_owner`, `freeze`, `unfreeze`, `close` |
| Balances | `balance.get`, `balance.get_at` |
| Ledger | `transfer_v2@2.0.0`, `post`, `mint_v2@2.0.0`, `burn_v2@2.0.0` |
| Holds | `hold.get`, `hold.create`, `hold.capture`, `hold.release` |
| Transactions | `transaction.get`, `transaction.list`, `transaction.reverse`, `transaction.refund` |
| Access | `access.role.create`, `access.grant`, `access.revoke`, `access.check`, `access.explain` |
| Policy and restrictions | `policy.get`, `policy.set`, `restriction.create`, `restriction.revoke`, `restriction.get`, `restriction.list` |
| Reasons | `reason.register`, `reason.get`, `reason.list` |
| Integrity | `integrity.get`, `integrity.reconcile` |
| Outbox operations | `outbox.retry` |
| Compatibility | 19 legacy `register_currency`, account/snapshot, transfer/debit/credit, mint/burn, hold, reversal, access, and reconciliation contracts |

All names above use the `synex.accounts.` prefix. Except for the three `2.0.0` ledger contracts shown explicitly, current versions are `1.0.0`. All 59 are marked `experimental` and `network: none`.

`synex.accounts@1` exposes the same schema-validated server operations, mapping dotted contract suffixes to underscore method names. It also exposes bounded operator reads: `get_control_summary`, `doctor`, `inspect_transaction`, `inspect_account`, and `inspect_outbox`. `outbox_retry` is not a read: it retains its own privileged capability, idempotency fence, durable request record, and audit path. The registry enforces the same per-method capabilities; using the service is not a capability or caller-identity bypass.

## Currency and topology

Currency registration creates the currency and an `incomplete` topology record. Dedicated system-owned accounts are then created explicitly and assigned to the topology; it becomes `ready` only when both sides are present:

- an `asset` account holds normal user, character, group, or system value;
- a `mint` system account is the only allowed source topology for creating supply;
- a `burn` system account is the only allowed sink topology for destroying supply.

Mint and burn are ledger transactions, not direct balance edits. They require separate capabilities, validated reason codes, topology checks, and authoritative system-account ownership. The committed Core policy grants them only to the reviewed compatibility provider executors; those paths remain consumer-bound and policy-gated, and no ordinary resource receives either capability by default.

## Multi-leg posting, transfer, reversal, and refund

`synex.accounts.post` accepts a balanced set of 2–16 signed entries. `transfer_v2` is the two-account convenience operation built on the same ledger rules. Asset accounts cannot be driven below the permitted available value, and all entries in a transaction use the same currency.

For atomic compare-and-adjust flows, `transfer_v2` optionally accepts `expected_source_sequence` and `expected_destination_sequence`. Each value is a non-negative JavaScript-safe integer read from the current account projection. Accounts locks both rows first, then compares the supplied sequences before any ledger, usage, snapshot, audit, or outbox write; a mismatch fails deterministically with `WRITE_CONFLICT`. Omitting both fields preserves ordinary transfer behavior. This guard does not expose a direct balance-write operation: callers still submit a balanced transfer, and exact completed idempotent requests continue to replay their stored result without executing the sequence check again.

A reversal appends a new inverse transaction and an immutable link; it never edits the original. A transaction can be reversed only within the supported topology, and reversal-of-reversal is rejected. A refund also appends a new transaction, records its original anchor, and enforces the cumulative refundable amount. Full reversal and refund paths are mutually exclusive for the same original transaction.

## Holds

Holds reserve funds on a source asset account for a target asset account in the same currency. The current lifecycle supports:

- an atomic creation transition that persists the reservation directly as `active` and records the immutable `created` event;
- multiple active holds per account;
- partial capture and repeated capture while value remains;
- partial or complete release;
- automatic expiry of remaining value;
- immutable hold-event history.

Capture posts a real ledger transaction; reservation alone does not. State and amount invariants ensure `captured + released + remaining = original amount`. A separate dormant `created` database state is intentionally absent: exposing a non-reserving hold would require a distinct, versioned two-phase activate/recovery protocol. Closed accounts and invalid source/target topology fail closed.

## Access, policy, and restrictions

Account ownership and access grants are domain facts, not proof of the current caller. A consumer must establish the real `system`, `resource`, `user`, `character`, or `group` actor in its own server-side domain before invoking Accounts.

Account-local roles hold bounded permission sets, and grants can be time-bounded or revoked. Policy and restriction records add operation allowlists, limits, and explicit account/principal constraints. `access.check` returns the account-domain authorization result. `access.explain` additionally preflights the real caller resource capability through Core and, when operation/amount/direction are supplied, evaluates the same account state, permission, restrictions, balance, transfer/daily limits, allowlist, funds, and close-lifecycle rules used by execution. Neither surface grants Core capabilities, ACE permissions, a current session, or ownership of another resource.

The current contract capabilities are:

```text
synex.accounts.read
synex.accounts.create
synex.accounts.configure
synex.accounts.transfer
synex.accounts.post
synex.accounts.hold
synex.accounts.reverse
synex.accounts.refund
synex.accounts.access.read
synex.accounts.access.manage
synex.accounts.integrity.read
synex.accounts.integrity.run
synex.accounts.mint
synex.accounts.burn
synex.accounts.outbox.retry
```

Capability authorization occurs before the domain operation. Domain authorization, ownership, policy, restriction, reason-code ownership, account state, and value checks still occur inside Accounts.

## Idempotency and concurrency

Every financial mutation carries a UUID idempotency key. Migration `017_idempotency_principal_scope` scopes the operation record to:

```text
caller resource + actor kind + actor reference + operation + idempotency key
```

An exact completed request replays its stored result without executing again. Reusing a key with a different request fingerprint fails with `IDEMPOTENCY_CONFLICT`; an unresolved in-flight operation fails closed. Idempotency prevents duplicate execution for one principal scope, but it does not replace account locks, optimistic versions, or reconciliation.

## Events, hooks, audit, and outbox

Accounts publishes only its declared `synex.accounts.*` namespace. Domain events cover currency/account lifecycle, ledger postings, reversal/refund, holds, access/policy/restriction changes, integrity findings, and completed reconciliation. Compatibility events remain for the legacy contract surface.

Three reject-only hook points run before protected mutations:

```text
synex.accounts.before_transaction
synex.accounts.before_transfer
synex.accounts.before_hold_capture
```

Hook input and context are bounded. A hook may reject the proposed operation but cannot rewrite authoritative financial entries.

The local account audit record and durable outbox row are committed with the financial change. A supplemental Core audit append runs after commit on a best-effort basis and does not replace domain audit evidence. Outbox publication uses a stable event ID and bounded exponential retry; after the tenth failed delivery the row becomes `dead`. Consumers must deduplicate at-least-once delivery by event ID.

Runtime errors and operator reads carry a bounded trace ID. Financial handlers emit operation, transaction, retry, idempotency, access-denial, hold, outbox, and reconciliation metrics through the Core metrics API when it is available.

## Integrity, reconciliation, and economy views

`integrity.reconcile` is a mutating diagnostic operation because it persists a reconciliation run, findings, audit evidence, and outbox events. It checks the authoritative ledger and read models for zero-sum, snapshot, supply/topology, hold, reversal/refund, outbox, access-grant, sequence, and idempotency anomalies. Finding severities are `info`, `warn`, `error`, or `critical`.

Reconciliation **does not repair, delete, freeze, ban, mint, burn, or rewrite data**. Its result and persisted read model use decimal strings for database `BIGINT`/`DECIMAL(36,0)` aggregates that may exceed Lua/JSON safe integers.

The bounded Accounts control summary includes overview, currencies, account dimensions, ledger, transaction kinds, holds, access, integrity models, reconciliation, anomalies, outbox, and real 24-hour/7-day/30-day economy aggregates. Every period remains partitioned by currency and carries that currency's code and minor-unit precision; unlike currencies are never summed into one monetary total. Per-currency aggregates include transaction and entry counts, positive-side volume, sources, sinks, net inflation, and bounded attribution by reason and source resource. They are operational observations, not business analytics or capacity claims.

Current metric names include:

```text
synex_accounts_operations_total
synex_accounts_operation_duration_ms
synex_accounts_transactions_total
synex_accounts_transaction_duration_ms
synex_accounts_transaction_failures_total
synex_accounts_retries_total
synex_accounts_deadlocks_total
synex_accounts_lock_timeouts_total
synex_accounts_idempotency_replays_total
synex_accounts_idempotency_conflicts_total
synex_accounts_access_denials_total
synex_accounts_holds_active
synex_accounts_holds_expired_pending
synex_accounts_holds_expired_total
synex_accounts_outbox_pending
synex_accounts_outbox_publishing
synex_accounts_outbox_dead
synex_accounts_outbox_published_total
synex_accounts_outbox_retries_total
synex_accounts_outbox_dead_total
synex_accounts_reconciliation_findings
```

## Operator commands

The current Core command implementation exposes these exact Accounts operations:

```text
synex doctor accounts
synex ledger
synex accounts status
synex accounts trace <transaction>
synex accounts inspect <account>
synex accounts outbox [limit]
synex accounts outbox-retry <event-uuid> <idempotency-uuid>
synex accounts reconcile <currency> <idempotency-uuid>
```

`outbox` defaults to 25 rows and accepts `1..50`. `trace` and `inspect` require public UUIDs. The commands are console-only, registered as restricted Cfx commands, and return bounded structured output. Their service calls are trace-bound and capability-declared.

`reconcile` and `outbox-retry` are the only mutations. `synex accounts reconcile` requires a currency code and idempotency UUID, invokes `synex.accounts.integrity.run`, and writes reconciliation, audit, and outbox evidence without repairing data. `synex accounts outbox-retry` requires the dead event UUID plus an idempotency UUID and invokes the separately privileged `synex.accounts.outbox.retry` operation. It can only move one eligible dead event back to `pending`; a durable retry-request row and Core audit record retain who requested it. Every other Accounts command is read-only.

The experimental `synex_control` snapshot can render the bounded Accounts summary, exact account/transaction investigations, and a financial-class `character_relations` inspector with the exact account-link count and at most eight links. The relation projection exposes no balances, and the NUI has its own unsupported acceptance boundary. It does not add a financial mutation surface.

## Lifecycle and retention

Accounts binds to the current Core owner epoch and does not mark its registration ready until the service, all 59 server RPCs, the character participant, group-deletion provider, and scheduled workers are registered. A Core restart invalidates the old binding and starts a fresh bounded rebind; stale handlers and worker callbacks fail closed.

Accounts participates in character deletion and the Core domain-deletion workflow for groups. A deletion preflight blocks while nonterminal financial obligations make the transition unsafe. Idempotent execution closes/anonymizes owned accounts as applicable, revokes affected access, and retains ledger history plus audit/outbox evidence. Accounts never queries another domain's tables directly.

The effective Core retention default is `retain_forever`. When an operator explicitly selects `archive`, Accounts copies eligible transactions and entries into its V2 financial archive tables in bounded, UTC-based, idempotent batches. Archive mode is a non-destructive mirror: source transactions, entries, snapshots, operations, accounts, audit, and outbox rows are not deleted.

## Migrations

| ID | Purpose |
| --- | --- |
| `001_accounts` | currencies, accounts, owners, operations, snapshots |
| `002_ledger` | transactions, postings, audit, outbox |
| `003_holds` | hold state and events |
| `004_access_integrity` | roles, grants, reversals, reconciliation, integrity models |
| `005_character_lifecycle` | character-deletion journal |
| `006_financial_archive` | first non-destructive transaction archive |
| `007_operation_scope_and_provenance` | caller/actor operation scope and provenance |
| `008_reason_currency_topology` | reason registry and mint/burn topology |
| `009_multileg_ledger` | signed multi-leg transactions and entries |
| `010_refunds` | refund anchors and cumulative refunds |
| `011_hold_lifecycle_v2` | partial/multiple hold lifecycle |
| `012_access_policies` | policies, restrictions, usage, and access extensions |
| `013_group_deletion_journal` | idempotent group-deletion participation |
| `014_integrity_outbox_control` | expanded integrity, outbox attempts/retry evidence, control read models |
| `015_financial_archive_v2` | multi-leg transaction and entry archive mirrors |
| `016_financial_entry_bounds` | authoritative 2–16 entry bound |
| `017_idempotency_principal_scope` | principal-scoped operation uniqueness |

Migration files are forward-only and owned by `synex_accounts`. Do not edit an applied migration or apply this Alpha schema to a deployment that is intended to reproduce the frozen Core-only acceptance profile. See [Migrations](../migrations.md) and [Database model](database.md).

## Testing and acceptance boundary

The repository contains Accounts-focused source, contract, static-schema, security, database, concurrency, outbox-recovery, and local hot-path tests. On 2026-08-26 the working tree passed the 57-test focused Accounts suite and the complete 735-test repository run with 707 passes, no failures, and 28 expected live-database skips; security reported 0 findings across 201 scanned files and the dependency audit reported 0 vulnerabilities. The four new gated MariaDB concurrency/recovery cases were discovered but not executed because no disposable database URL was supplied. This is implementation evidence, not production acceptance. Before changing the maturity label, the exact committed candidate still needs:

1. a clean disposable MariaDB migration and live-database run;
2. an isolated FXServer start with Core and Accounts reaching healthy state;
3. real contract/service, worker, outbox, hold-expiry, and reconciliation execution;
4. prepared and unplanned restart/recovery checks with idempotency replay;
5. restored-copy upgrade and rollback evidence;
6. exact-candidate diff, secret, and documentation review.

Accounts itself has no client or NUI surface, so no direct Accounts client smoke is required. Downstream gameplay resources that expose financial actions will require their own hostile-client and reconnect tests.

For a minimal server-consumer pattern, see [Server-only Accounts example](../../examples/synex_accounts-server.md). Use generated contract descriptors for complete schemas; do not copy this reference into runtime validation.
