# ADR-0003: Relational persistence and forward-only migrations

Status: Accepted

Scope: the relational and forward-only direction is accepted for Core. `synex_groups` exercises that direction as an Experimental Alpha Organizations Engine, `synex_accounts` as an Experimental Alpha Financial Engine, and `synex_entities` as a Development / Experimental Alpha Entity Authority Engine. Other non-Core schemas remain rework snapshots or scaffolds. No downstream schema or migration set is an accepted deployment or upgrade path until its exact revision receives a separate release decision.

## Decision

Use InnoDB, relational columns for queried domain state, positional parameters, explicit transactions, optimistic versions, and forward-only checksummed migrations. Use JSON only for bounded opaque metadata. The accepted initial Core Production-Beta profile targets MariaDB `11.8.8`; MySQL and any downstream schema require separate acceptance.

## Consequences

Schema changes are reviewable and integrity constraints live close to the data. DDL is never mixed with assumptions about transactional rollback. A deployment must use a compensating forward migration or an application rollback paired with a separately preserved schema compatible with that older version; in-place downgrade is unsupported.
