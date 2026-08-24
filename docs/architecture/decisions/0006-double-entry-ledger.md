# ADR-0006: Double-entry economy foundation

Status: Accepted

Scope: design direction for the `synex_accounts` rework snapshot. This ADR does not place that resource, its schema, or its APIs inside `synex_core` Production-Beta acceptance.

## Decision

Keep the future accounts design based on integer minor units and balanced debit/credit entries for committed value movement. Mint, burn, holds, releases, captures, and reversals remain explicit operations with idempotency keys and audit records in the current design snapshot.

## Consequences

The snapshot treats balances as projections of an append-only ledger rather than freely mutable fields, and its reconciliation model flags invariant violations. These properties require fresh implementation, security, database, concurrency, and operational acceptance after rework. Gameplay banking remains a separate concern.
