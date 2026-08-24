# Accounts, ledger, and holds

> [!WARNING]
> `synex_accounts` is an experimental rework snapshot. It is unsupported, outside the `synex_core` Production-Beta certification boundary, and must not be used as a production ledger based on this reference or its repository tests.

The current snapshot supplies currencies, owned accounts, immutable double-entry transactions/postings, balance snapshots, holds, access roles/grants, reversals, integrity read models, audit rows, an outbox, and an optional non-destructive financial archive mirror. It is not the planned `synex_banking` gameplay/UI resource, and its interfaces may change or be replaced during the rework. Everything below is a source catalog, not current ledger, integration, or deployment guidance.

## Contracts

The checked-in snapshot's local RPC declarations include:

- currency registration and account creation;
- account and hold snapshots;
- transfer, debit, credit, mint, and burn;
- hold creation, capture, and release;
- one-time transaction reversal;
- account-local access-role creation, grant, revoke, and lookup;
- currency reconciliation and integrity snapshots.

All 19 contracts are `network: none` and `experimental`. Use the exact generated request/output schemas in the [contract catalog](../../packages/contracts/generated/docs/contracts.md). The read-only `synex.accounts@1` service exposes `get_snapshot`, `list_owner_accounts`, and `get_hold` under `synex.accounts.read`; `get_access` under `synex.accounts.access.read`; and `get_integrity` plus `get_control_summary` under `synex.accounts.integrity.read`. The compatibility-oriented owner projection returns at most 64 active `cash`/`bank` asset accounts and an explicit `truncated` flag. Mutable methods remain contract-only, preserving the real resource caller at the core RPC boundary.

## Ledger model

- Amounts are integer minor units. Currency definitions declare a minor-unit scale.
- Account rows do not contain a directly mutable balance column.
- A posting names distinct debit and credit accounts and enforces equal debit/credit minor units.
- A unique transaction-to-posting constraint prevents a transaction from acquiring a second posting pair.
- Snapshots are derived records with a monotonic account sequence; they do not replace the immutable ledger history.
- Holds reserve available funds and use terminal-event uniqueness so capture/release cannot both win.
- Mutations record operation fingerprints/results for idempotency and use optimistic versions where required.
- A reversal creates a new balanced inverse transaction, links it to the original exactly once, rejects reversal-of-reversal, and does not rewrite ledger history.
- Account-local roles contain a unique subset of `view`, `deposit`, `withdraw`, `transfer`, `history`, `manage`, and `close`. Grants bind one role to a `system`, `resource`, `user`, `character`, or `group` principal, can expire, and use an explicit revoked state.
- Reconciliation advances a versioned per-currency integrity model and records bounded warning findings for imbalance, snapshot-sum drift, negative asset balance, excess reservation, or orphan transaction. It never repairs data automatically.

Mint and burn are explicit ledger roles and capabilities, not shortcuts that update a balance.

The checked-in snapshot defines an owner-aware `synex_accounts.outbox_dispatcher` scheduled once per second with at most 25 ready rows per batch. Its code publishes transactionally stored events through the capability-gated Core `Events.publishOutbox` surface with their stable `eventId`; subscriber failures use bounded retry/backoff and the tenth failed attempt moves the row to `dead`. This describes snapshot behavior only and is not accepted operational guidance.

## Capabilities

The current contracts distinguish `synex.accounts.read`, `create`, `configure`, `transfer`, `hold`, `reverse`, `access.read`, `access.manage`, `integrity.read`, `integrity.run`, `mint`, and `burn`. The committed default policy denies mint and burn and does not provide broad administrative grants; because denies take precedence, an operator must deliberately remove the applicable deny and add a reviewed resource-specific grant before either operation can be invoked through a non-Core caller.

Client-supplied prices, balances, currency precision, account ownership, or administrative intent must never be authoritative.

## Operational boundaries

Financial history is retained/anonymized according to the resource manifest rather than deleted with a character. The required Core lifecycle participant blocks deletion while any character-owned account has a nonterminal hold. Its idempotent `deleteCommit` closes and anonymizes owned accounts, revokes affected active grants, retains the ledger, and records domain audit/outbox evidence in the same transaction. Account access grants do not automatically become Core resource capabilities, ACE permissions, or proof of current session ownership; the calling domain must establish the correct principal before using them. The database reference documents ACL, reversal, reconciliation, and anomaly boundaries represented by the schema and implementation: [Database model](database.md).

Aggregate reconciliation counts and totals are exposed as decimal strings where a database `BIGINT` or `DECIMAL(36,0)` can exceed Lua/JSON safe integers. Findings are warn/audit-only: the resource contains no ban or automatic-repair action.

The effective Core retention policy defaults financial history to `retain_forever`. If an operator explicitly selects `archive`, `synex_accounts` schedules a bounded worker that copies eligible ledger transactions and their posting/currency/account context into `synex_financial_transaction_archive` using UTC database time and a unique source-transaction key. This is an idempotent archive mirror, not data minimization: it never removes or mutates the source ledger, postings, snapshots, operations, or accounts, and it does not weaken the character-deletion rule that retains financial history.

The CI live-database suite applies migrations and checks key constraints. It does not constitute a production ledger audit, load test, or legal/accounting compliance certification.
