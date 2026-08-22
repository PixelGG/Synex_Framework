# Database migrations

Synex migrations are resource-owned, forward-only SQL files. Each runnable data-owning resource declares its ordered files in `synex.resource.json`.

## Discovery and execution

During core boot, `synex_core`:

1. discovers resources with `synex_manifest` metadata;
2. validates their manifest and migration entries;
3. acquires the `schema_migrations` database-time lease;
4. reads each migration through the owning resource;
5. normalizes line endings and computes SHA-256;
6. records an `applying` attempt before DDL, including its immutable checksum and attempt count;
7. verifies an existing applied record or executes each delimited statement;
8. records resource, migration ID, checksum, duration, and instance ID, then marks the attempt `applied`.

The lease uses an expiry and monotonically increasing fencing token stored in `synex_cluster_leases`. It does not rely on a pooled connection owning `GET_LOCK`. A lease, statement, or final-record failure marks the attempt `failed` with a bounded error code. An `applying` row at the next boot is treated as an incomplete/dirty attempt and retried only when its checksum still matches.

## File contract

Migration IDs and files use the same ordered prefix:

```text
migrations/007_descriptive_name.sql
```

Separate statements with a line containing only:

```sql
-- synex:statement
```

The runtime executes statements in order. DDL migrations are declared `transactional: false` because MariaDB/MySQL DDL can commit implicitly. A migration must therefore be safe to resume at the statement boundary and should use guarded DDL such as `CREATE TABLE IF NOT EXISTS` where appropriate.

## Immutability

Never change, reorder, or reuse an applied migration. If the stored SHA-256 differs from the current file, startup fails with `MIGRATION_CHECKSUM_MISMATCH`. Add a new forward migration for every schema change.

The current runner has no automatic down migration and does not infer destructive rollback SQL. Rollback is an operator procedure using a tested backup and a compatible application version.

## Ownership

Every created `synex_` table is listed under the owning manifest's `dataOwnership.tables`. Resources must not mutate another domain's tables. Cross-domain operations use contracts or versioned services.

Current data-owning resources are:

- `synex_core` — migration control, identity/session/character, reliability, access, saga, audit plus its non-destructive archive mirror, deletion plans, cluster session control, persistent RBAC, and reviewed legacy-import journals/mappings;
- `synex_groups` — groups, grades and rules, memberships and history, primary selections, read-model versions, operation idempotency, character-deletion journals, and outbox;
- `synex_accounts` — currencies, accounts and owners, access roles and grants, ledger and reversals, snapshots, holds, reconciliation, a non-destructive financial transaction archive mirror, character-deletion journals, audit, and outbox;
- `synex_entities` — persistent entity identity and serialized durable properties, never runtime handles or Net IDs.

The exact table model and constraints are documented in [Database model](reference/database.md).

## Development checklist

1. Add the next numeric migration to the owning resource.
2. Add it to that resource's `synex.resource.json`.
3. Update `dataOwnership.tables` if ownership changes.
4. Run `npm run check` and `npm test`.
5. Run the gated live-database test against a new disposable schema.
6. Test upgrade on a restored copy; keep the backup until rollback criteria expire.

Do not point the test gate at a development or production schema.
