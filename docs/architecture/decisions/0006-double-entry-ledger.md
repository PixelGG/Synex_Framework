# ADR-0006: Double-entry economy foundation

Status: Accepted

Scope: design direction implemented by the server-only `synex_accounts` Experimental Alpha. This ADR does not place that resource, its schema, or its APIs inside `synex_core` Production-Beta acceptance.

## Decision

Keep Accounts based on integer minor units and balanced signed multi-leg entries for committed value movement. A transaction contains 2–16 unique-account entries in one currency and sums to zero. Mint, burn, holds, partial release/capture, reversal, and refund remain explicit operations with principal-scoped idempotency keys and transactional domain audit/outbox evidence.

## Consequences

Accounts treats balances as projections of an append-only ledger rather than freely mutable fields, and its reconciliation model records severity-bearing invariant findings without automatic repair. The automated implementation remains Experimental Alpha until the exact candidate completes real database, FXServer, concurrency, restart/recovery, upgrade, security, and operational acceptance. Gameplay banking and UI remain separate `synex_banking` concerns.
