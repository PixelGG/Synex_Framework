# Database migrations

Synex migrations are resource-owned, forward-only SQL files. Each runnable data-owning resource declares its ordered files in `synex.resource.json`. The current `synex_core` manifest declares 26 migrations in strict order.

Only those 26 Core migrations belong to the current Production-Beta candidate. Migration files under `synex_groups`, `synex_accounts`, `synex_entities`, or any future downstream resource are experimental rework snapshots; they are retained for review and repository regression tests but are not part of the Core candidate installation or upgrade path.

## Discovery and execution

During core boot, `synex_core`:

1. discovers resources with `synex_manifest` metadata;
2. validates their manifest and migration entries;
3. acquires the `schema_migrations` database-time lease;
4. reads each migration through the owning resource;
5. normalizes line endings and computes SHA-256;
6. claims an `applying` fence containing the immutable checksum, restart-unique owner, lease fencing token, and statement boundary;
7. verifies the current lease and fence before execution, renews the lease independently while a statement is in flight, and verifies both again after every statement;
8. atomically records resource, migration ID, checksum, duration, and owner while marking the fence and attempt `applied`.

The lease uses an expiry and monotonically increasing fencing token stored in `synex_cluster_leases`; the canonical per-migration ownership record lives in `synex_schema_migration_fences`. Synex does not use connection-scoped `GET_LOCK` through the oxmysql pool. An expired lease never authorizes another worker to reclaim an `applying`, legacy `failed`, or `indeterminate` fence. A pre-fence attempt row in any non-applied state is converted to an indeterminate operational block, never a retry claim. This is intentional: after a submitted DDL statement returns an error, times out, loses its lease, or loses its response, Core cannot prove whether the database committed an implicit DDL boundary. It therefore fails boot with `MIGRATION_INDETERMINATE` or `LEASE_LOST`, and neither worker may write a foreign `applied`/`failed` marker or execute the migration again automatically.

The independent heartbeat is a liveness aid, not the safety boundary. If it cannot renew during a long statement, the durable attempt fence still prevents parallel execution. Resolve an indeterminate migration only in a maintenance window after inspecting the exact database state and restoring or completing it from a tested backup procedure; do not delete or rewrite the fence merely to make startup continue.

## File contract

Migration IDs and files use the same ordered prefix:

```text
migrations/007_descriptive_name.sql
```

Separate statements with a line containing only:

```sql
-- synex:statement
```

The runtime executes statements in order. DDL migrations are declared `transactional: false` because MariaDB/MySQL DDL can commit implicitly. A migration should still use guarded DDL such as `CREATE TABLE IF NOT EXISTS`, but the runtime does not treat idempotent-looking SQL as proof that an unknown in-flight statement is safe to run concurrently or reclaim automatically.

Core migration `014_runtime_owner_attribution.sql` uses a temporary metadata-guarded stored procedure because MariaDB 11.8 and MySQL 8.4 do not share one portable `ALTER TABLE ... ADD COLUMN IF NOT EXISTS` form. The migration principal needs `CREATE ROUTINE`, table `ALTER`, `EXECUTE`, and `ALTER ROUTINE`; MariaDB uses `ALTER ROUTINE` to authorize dropping the temporary procedure after the migration. It introduces saga/outbox owner columns as nullable solely for existing rows and adds generic-outbox `last_error_code`, `payload_compacted_at`, and the terminal-compaction index. New runtime writes require owner attribution, while legacy `NULL` rows remain quarantined from owner-scoped recovery and event publication.

The migration creates and verifies `uq_sagas_owner_type_correlation` before removing the legacy cross-owner key. If the new unique index cannot be built or does not have the exact expected ordered columns, the routine signals an error while the legacy uniqueness constraint still exists.

Core migration `015_character_reconciliation_fencing.sql` is an additive upgrade for existing character-deletion plans. Its metadata-guarded procedure adds `attempt_count`, `last_attempt_at`, `next_attempt_at`, `lease_fencing_token`, and the due-work index over `(state, next_attempt_at, created_at, id)`. Existing nonterminal rows receive the due timestamp default; the upgraded worker records retry timing and requires both the optimistic plan version and active lease token before terminal completion. It needs the same routine and `ALTER` privileges as `014` and drops its temporary procedure afterward. Stop older Core instances before enabling the upgraded worker, then verify this migration through the disposable live-database gate and a restored-copy upgrade; the repository's static migration checks are not proof that a particular deployment has applied it successfully.

Core migration `016_rbac_policy_revision.sql` creates the single-row `synex_rbac_policy_revisions` authority and initializes revision `1` without resetting an existing value. Every persistent role-definition transaction locks and advances this row before it publishes its complete role snapshot. Authorization checks compare their local snapshot revision with this durable value and fail closed if the comparison or refresh cannot be completed. Deploy it only after every older Core instance has stopped: pre-`016` role writers do not advance the revision and are therefore incompatible with the new cache-coherence invariant.

Core migration `017_runtime_scalability.sql` adds indexed instance-generation and open-session access, exact lease-owner lookup, the durable-lease discriminator retained for schema compatibility, and the nullable audit archive checkpoint plus its work-queue index. These structures keep boot cleanup, generation recovery, and repeated empty archive runs independent of unrelated historical rows; migration `020` supplies the final terminal-lease eligibility queue. The Core audit worker copies and checkpoints one locked bounded batch atomically; existing mirror rows are reconciled lazily through the same bounded path. `017` uses the metadata-guarded routine workflow and privileges described for `014`. Stop every older Core and archive worker before applying it.

Core migration `018_character_slot_reuse.sql` replaces the lifetime `(user_id, slot)` character key with `uq_characters_user_slot_active` over `(user_id, slot, active_slot_marker)`. The nullable unsigned `TINYINT` marker is stored-generated as `1` only while `deleted_at IS NULL` and otherwise `NULL`, so one active character may occupy a slot while soft-deleted historical rows remain. The routine fail-closes if an existing marker has a different type, nullability, storage mode, or normalized MariaDB/MySQL expression. It creates and verifies the exact replacement key before dropping the legacy key. It uses the same routine/`ALTER` privileges and coordinated full-stop upgrade rule as `014`; verify both the generated expression and duplicate-active rejection through the disposable live-database gate before reopening admission.

Core migration `019_session_control_target_authority.sql` materializes the target instance on every persisted session-control request. Existing rows are repaired from their referenced session before the column becomes mandatory; an unresolved request aborts the migration. The exact target-pending index bounds owner polling, while the `(state, request_id)` cursor index lets the heartbeat audit invalid pending authority without repeatedly scanning the complete request history. New requests derive this value only from the target session row locked by Core; it is never accepted from a client or caller.

Core migration `020_terminal_lease_eligibility.sql` adds an explicit terminal-compaction timestamp and its ordered work-queue index to cluster leases. Saga and character-deletion terminal transitions mark or invalidate the corresponding lease in the same transaction as the terminal domain CAS; the compactor therefore reads only durable eligibility rows and never joins an unbounded expired-lease history to domain tables. The migration backfills existing terminal domains during the full-stop upgrade. It also adds `(character_id, closed_at, id)` for bounded open-character-session conflict locking and `(user_id, closed_at, connected_at, id)` for bounded duplicate-session authority checks. Apply `019` and `020` only after all older Core workers and their outstanding database work have stopped.

Core migration `021_worker_queue_scalability.sql` installs the exact ordered queues used by saga recovery and terminal Core-outbox retention. It also adds the nullable idempotency `response_compaction_at` eligibility marker, backfills already-empty completed responses as ineligible, and creates the exact `(state, response_compaction_at, expires_at, namespace, idempotency_key)` response queue. All four indexes and the marker definition are metadata-verified; the nullable-default check accepts both SQL `NULL` and MariaDB's unquoted `NULL` metadata representation while still rejecting a literal `'NULL'` string default. An existing incompatible object aborts the migration instead of being replaced. The backfill and new worker predicates are not compatible with an older response compactor, so this migration requires the same coordinated full stop, drained oxmysql work, routine privileges, restored-copy test, and disposable live-schema verification as `014` through `020`.

Core migration `022_idempotency_capacity.sql` creates the single-row cluster limit/global-counter authority and exact owner/namespace counters used by generic Core idempotency claims. Its full-stop backfill counts every existing key regardless of state; it does not delete, expire, or reclaim any tombstone and deliberately accepts counts already above a configured limit. The routine verifies table, column, key, check, and foreign-key metadata, reconciles each derived group and both aggregate sums against the permanent key table, and aborts on range overflow or drift. All older Core writers and their oxmysql work must stop before `022`, because they do not increment these counters. The three limits remain database-owned operator policy and are not reset when the guarded migration procedure is revalidated.

Core migration `023_lease_authority_recovery.sql` adds a stored generated `lease_authority_kind` that classifies exactly `session:` and `admission:` names, the indexed bounded expired-authority recovery queue, and the ordered stale open-session heartbeat queue. The routine verifies the normalized generation expression exactly; additional branches, altered type/collation/nullability, or incompatible index shapes fail closed. Stop every older Core and drain its database work before applying `023`: the upgraded acquire/reacquire path clears retirement eligibility atomically, while the recurring worker retires only expired marker-`NULL` session/admission authority before the generic terminal compactor runs.

Core migration `024_session_control_capacity.sql` creates the single-row global limit/counter authority plus exact per-requester counters for retained session-control requests. Its full-stop backfill counts all `pending`, `completed`, and `expired` rows, accepts an existing count above a configured limit, and aborts on unsigned overflow or reconciliation drift. The metadata guard verifies exact normalized check clauses, the one-column requester FK, and the additive `(state, completed_at, request_id)` retention queue; it intentionally has no `entry_count <= limit` check. Stop all pre-`024` issuers and maintenance workers and drain oxmysql work before applying it. The upgraded issuer charges only a new request, while terminal compaction releases both counters atomically after the configured grace. Stored limits remain operator policy and are never raised or reset automatically.

Core migration `025_cluster_lease_capacity.sql` adds a global retained-row counter and five fixed kind counters for cluster leases. The stored generated classifier maps `session:`, `admission:`, `saga:`, and `character-delete:` names to their dedicated kinds, maps every other runtime name to `other`, and excludes only the exact bootstrap lease `schema_migrations`. The full-stop backfill counts active, expired, and terminal rows alike, preserves operator limits, permits existing use above a limit, and has no counter-to-limit check. It verifies the exact classifier, index, normalized check clauses, and, when MySQL exposes `TABLE_CONSTRAINTS.ENFORCED`, requires all four named checks to be enforced. Stop every pre-`025` Core writer and compactor and drain oxmysql work before applying it: an older acquire path can insert an uncharged lease, while an older compactor can delete one without releasing its counters. The upgraded runtime charges only a newly claimed name and releases capacity only in exact terminal compaction; it never raises a limit automatically.

Core migration `026_lease_authority_owner_index.sql` adds the exact non-unique BTREE index `(lease_authority_kind, terminal_compaction_at, owner_id, lease_name)` used by bounded next-boot connection-authority cleanup. The guarded procedure first verifies the required generated kind, terminal marker, owner, and name columns, then verifies every index column, order, direction, lack of prefixing, and type. It capability-detects MariaDB's `STATISTICS.IGNORED` or MySQL's `STATISTICS.IS_VISIBLE`, requires every index entry to be optimizer-usable, and runs a harmless runtime-shaped `FORCE INDEX` probe as a semantic backstop. An ignored, invisible, or otherwise unusable index fails closed instead of allowing the forced runtime query to fail later. The runtime performs separate equality scans for `admission` and `session` within the exact local owner prefix, retires only the selected primary-key names, and rolls back when a residual recheck detects an over-bound or concurrent matching row. It does not reclassify leases, alter capacity counters, or authorize cleanup of Saga, character-deletion, `other`, foreign-owner, or similar-prefix rows. Apply it after `025` in the same full-stop window before code that forces the index starts. Like every forward migration, it has no automatic down migration; rollback remains restore plus a compatible application version.

## Immutability

Never change, reorder, or reuse an applied migration. If the stored SHA-256 differs from the current file, startup fails with `MIGRATION_CHECKSUM_MISMATCH`. Add a new forward migration for every schema change.

The sole registered checksum correction is the metadata-only portability fix for `synex_core/021_worker_queue_scalability`. Core accepts its exact earlier checksum only when the authoritative applied marker proves that earlier file completed; its fence and attempt checksum must still be either that exact earlier value or the corrected value. A failed, applying, indeterminate, unknown, or marker-less earlier attempt is never promoted or retried automatically and remains a maintenance-window recovery case.

The current runner has no automatic down migration and does not infer destructive rollback SQL. Rollback is an operator procedure using a tested backup and a compatible application version.

## Ownership

Every created `synex_` table is listed under the owning manifest's `dataOwnership.tables`. Resources must not mutate another domain's tables. Cross-domain operations use contracts or versioned services.

The checked-in manifests currently declare these ownership snapshots:

- `synex_core` — migration control, identity/session/character, reliability, access, saga, audit plus its non-destructive archive mirror, deletion plans, cluster session control, persistent RBAC and its policy-revision authority, and reviewed legacy-import journals/mappings;
- `synex_groups` — **experimental rework snapshot:** groups, grades and rules, memberships and history, primary selections, read-model versions, operation idempotency, character-deletion journals, and outbox;
- `synex_accounts` — **experimental rework snapshot:** currencies, accounts and owners, access roles and grants, ledger and reversals, snapshots, holds, reconciliation, a non-destructive financial transaction archive mirror, character-deletion journals, audit, and outbox;
- `synex_entities` — **experimental rework snapshot:** persistent entity identity and serialized durable properties, never runtime handles or Net IDs.

Do not apply the three non-Core migration sets to a database intended to represent the Core-only acceptance target. Their future rework may require a new migration and upgrade decision.

The exact table model and constraints are documented in [Database model](reference/database.md).

## Development checklist

1. Add the next numeric migration to the owning resource.
2. Add it to that resource's `synex.resource.json`.
3. Update `dataOwnership.tables` if ownership changes.
4. Run `npm run check` and `npm test`.
5. Run the gated live-database test against a new disposable schema.
6. Test upgrade on a restored copy; keep the backup until rollback criteria expire.

Do not point the test gate at a development or production schema.
