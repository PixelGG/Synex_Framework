# ADR-0013: Separate prevention from detection and enforcement

- Status: Accepted design; Security implementation Experimental / Alpha
- Date: 2026-08-31
- Scope: `synex_core`, Synex domains, `synex_security`

## Context

A detector that observes an invalid operation after a domain accepted it cannot
restore correctness reliably. Conversely, placing balances, entity ownership,
world grants, interaction leases, and bans inside one security resource would
duplicate authorities and create a cross-domain superuser.

Synex already has server-authoritative Core and domain primitives: closed RPC
contracts, active sessions and source generations, capabilities, idempotency,
the Accounts ledger, Entity/World authority, Interaction Leases, and Core Access.

## Decision

Adopt this order:

```text
Core/domain validates and prevents
  -> emits bounded security evidence after denial or observation
  -> Security normalizes and applies expectations
  -> Security correlates independent evidence
  -> Security opens/updates a case
  -> a separate policy selects mitigation or enforcement
```

The owning domain remains authoritative for its state. Security never directly
writes account, inventory, entity, world, interaction, or Core access tables.
Deterministic Cfx event cancellation is allowed as a narrow early mitigation,
subject to detector mode, expectations, configuration, and live platform
verification.

Permanent or temporary ban creation delegates to Core Access with idempotency,
current user identity, bounded reason, and optional expiry. Security does not
create a second ban authority.

If Security is unavailable, an invalid domain operation remains denied. Security
reporting is fail-open only after domain correctness is already established.

## Consequences

- Domain handlers cannot outsource input validation or authorization to
  Security.
- Security can evolve correlation and policy without owning business state.
- Evidence from different domains has consistent bounds and trust classes.
- A Security outage reduces observability but must not reduce domain integrity.
- Cross-domain corrective actions require reviewed domain adapters, not direct
  table writes.
- Enforcement is auditable and independently testable from detection.
- The architecture is accepted, but real event cancellation, persistence,
  restart behavior, and gameplay calibration remain open Experimental / Alpha
  gates.
