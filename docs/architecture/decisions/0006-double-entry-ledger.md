# ADR-0006: Double-entry economy foundation

Status: Accepted

## Decision

Represent money as integer minor units. Every committed value movement has balanced debit and credit entries. Mint, burn, holds, releases, captures, and reversals are explicit operations with idempotency keys and audit records.

## Consequences

Balances are projections of an append-only ledger, not freely mutable fields. Reconciliation can prove invariants and flag anomalies. Gameplay banking remains a separate concern.
