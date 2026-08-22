# ADR-0003: Relational persistence and forward-only migrations

Status: Accepted

## Decision

Use MariaDB or MySQL with InnoDB, relational columns for queried domain state, positional parameters, explicit transactions, optimistic versions, and forward-only checksummed migrations. Use JSON only for bounded opaque metadata.

## Consequences

Schema changes are reviewable and integrity constraints live close to the data. DDL is never mixed with assumptions about transactional rollback. Production rollback uses a compensating forward migration or application rollback compatible with the newer schema.
