# ADR-0005: Source generations and durable identity

Status: Accepted

## Decision

Never use a FiveM source or entity network ID as durable identity. Pair sources and network IDs with monotonically changing generations and revalidate them after asynchronous work.

## Consequences

Reused transport identifiers cannot silently attach late results to a different session or entity. Registries maintain O(1) reverse indexes and update them atomically.
