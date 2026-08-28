# Database migrations

Synex migrations are resource-owned, forward-only SQL files. Each runnable data-owning resource declares its ordered files in `synex.resource.json`. The current `synex_core` manifest declares 27 migrations in strict order.

Only Core migrations `001` through `026` belong to the frozen Production-Beta profile. Current Core migration `027_domain_primitives` and every migration under `synex_groups`, `synex_accounts`, `synex_entities`, `synex_world`, `synex_bridge`, or a future downstream resource are outside that evidence. Groups, Accounts, Entities and World are separate Experimental Alpha domains; Bridge is a separate Experimental Alpha compatibility platform. None is part of the accepted Core installation or upgrade path.

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

Current Core migration `027_domain_primitives.sql` adds the bounded receipt/capacity tables used by the caller-bound domain DataPort and the durable domain-deletion domain, provider, plan, action, global-capacity, and requester-capacity catalog. Its guarded procedure verifies exact table, column, primary-key, check, retention-index, and provider-schema-index metadata; backfills terminal `purge_after` values at 30 days; clears invalid purge markers from pending/executing plans; rebuilds requester counters; and reconciles both counter levels against every retained plan. The exact `(provider_owner, provider_name, state, provider_schema_version, plan_id, action_index)` index supports the fail-closed pending-action schema-upgrade check. Stored deletion limits are preserved and bounded at 10,000 globally and 1,000 per requester. The migration is additive and creates no grant by itself: runtime access still requires a current caller epoch, a declared/operator-granted capability, and table ownership from the caller's manifest. It was added after the frozen 26-migration Core acceptance tree and therefore needs its own exact-candidate live-schema and FXServer acceptance before it may inherit a Production-Beta claim.

Groups migration `032_character_reference_contract.sql` widens the two compatibility-facing character-reference checks to the same bounded public-ID alphabet used by Core and the migrator, including UUID hyphens. It changes only `synex_group_membership_profiles.character_id` and `synex_group_primary_memberships_by_type.character_id`; all other membership authority and foreign-key semantics remain unchanged. The guarded procedure verifies both prerequisite tables and exact replacement checks, and aborts on incompatible schema state. This migration is required before catalog-bound compatibility imports can attach Core UUID characters to existing Groups memberships.

The current Core-plus-Groups source manifests declare 58 migrations: 27 Core and 31 Groups. An earlier 2026-08-25 local Alpha run applied a smaller 54-migration surface and passed its then-current disposable MariaDB checks; that evidence predates Groups migrations `029` through `032` and cannot certify this revision or extend the frozen Core Production-Beta migration set.

The Accounts Alpha manifest separately declares 17 ordered migrations, `001_accounts` through `017_idempotency_principal_scope`. They evolve the original paired ledger into signed 2–16-entry transactions, add reason/currency mint-burn topology, refunds, partial/multiple holds, access policies and restrictions, group-deletion participation, expanded integrity/outbox/control data, V2 archive mirrors, and principal-scoped idempotency.

The Entities Alpha manifest declares four ordered migrations: immutable base `001_entities`, lifecycle/authority extension `002`, bindings/components/states/tags/checkpoints `003`, and database-time authority leases/recovery history `004`.

The World Alpha manifest declares one ordered migration, `001_world`, for persistent typed state values, authoritative logical door state, and the bounded at-least-once outbox. Static world definitions, process-local instance sessions, routing buckets, runtime handles, NetIDs, diagnostic findings, and native client state are not database-owned World data.

The Bridge Alpha manifest declares one ordered migration, `001_compatibility_identity_metadata`, for provider-scoped legacy identity mappings and bounded compatibility metadata. It does not own Core identity, Groups memberships, Accounts ledger state, or gameplay authority.

Across Core, Groups, Accounts, Entities, World, and Bridge, the current manifests declare 81 migrations. That count is source inventory, not proof that any combined schema or downstream upgrade has passed real-database acceptance.

## Immutability

Never change, reorder, or reuse an applied migration. If the stored SHA-256 differs from the current file, startup fails with `MIGRATION_CHECKSUM_MISMATCH`. Add a new forward migration for every schema change.

The sole registered checksum correction is the metadata-only portability fix for `synex_core/021_worker_queue_scalability`. Core accepts its exact earlier checksum only when the authoritative applied marker proves that earlier file completed; its fence and attempt checksum must still be either that exact earlier value or the corrected value. A failed, applying, indeterminate, unknown, or marker-less earlier attempt is never promoted or retried automatically and remains a maintenance-window recovery case.

The current runner has no automatic down migration and does not infer destructive rollback SQL. Rollback is an operator procedure using a tested backup and a compatible application version.

## Ownership

Every created `synex_` table is listed under the owning manifest's `dataOwnership.tables`. Resources must not mutate another domain's tables. Cross-domain operations use contracts or versioned services.

The checked-in manifests currently declare these ownership snapshots:

- `synex_core` — migration control, identity/session/character, reliability, access, saga, audit plus its non-destructive archive mirror, deletion plans, cluster session control, persistent RBAC and its policy-revision authority, reviewed legacy-import journals/mappings, domain-operation receipts, and coordinated domain-deletion plans;
- `synex_groups` — **Experimental Alpha Organizations Engine:** 31 owned migrations comprising legacy-compatible foundations (`001`–`015`); static definition targets, default membership authority, applied-definition snapshots, capability delegability, persistent extension registries, workflow expiry, dynamic creation policy, deletion lifecycle, creation approvals and slug reservations, scoped attributes, identifier consistency, membership-transition policies, assignment active-member counts, first-class workflow entity identities, registry owner synchronization sessions, and the compatibility-facing character-reference contract (`017`–`032`). Migration ID `016` is intentionally reserved and is not declared in the current manifest;
- `synex_accounts` — **Experimental Alpha Financial Engine:** 17 owned migrations for currencies, accounts and owners, reason/topology registries, signed multi-leg ledger entries, reversals/refunds, snapshots, partial/multiple holds, roles/grants/policies/restrictions, integrity/reconciliation, character/group deletion journals, non-destructive V2 transaction/entry archive mirrors, audit, outbox attempts, and retry evidence;
- `synex_entities` — **Experimental Alpha Entity Authority Engine:** four owned migrations for stable definitions/tombstones, namespaced persistent keys, active bindings, components, states, tags, checkpoints, database-time authority leases and retention-bounded recovery history; never runtime handles, NetIDs or Cfx network owners.
- `synex_world` — **Experimental Alpha World Semantics & Spatial Authority Engine:** one owned migration for persistent typed state values, authoritative logical door rows and bounded at-least-once outbox delivery; never routing buckets, process-local instance sessions, runtime handles, NetIDs, diagnostic findings or client-native ownership.
- `synex_bridge` — **Experimental Alpha Compatibility Platform:** one owned migration for provider-scoped legacy identity mappings and bounded compatibility metadata; never Core identity authority, Groups membership authority, Accounts ledger state or gameplay ownership.

Do not apply the five non-Core migration sets to a database intended to represent the Core-only acceptance target. Groups, Accounts, Entities, World, and Bridge still require their separate clean-schema, restored-upgrade, FXServer and restart/recovery acceptance; future rework in any downstream domain may require a new migration and upgrade decision.

The exact table model and constraints are documented in [Database model](reference/database.md).

## Development checklist

1. Add the next numeric migration to the owning resource.
2. Add it to that resource's `synex.resource.json`.
3. Update `dataOwnership.tables` if ownership changes.
4. Run `npm run check` and `npm test`.
5. Run the gated live-database test against a new disposable schema.
6. Test upgrade on a restored copy; keep the backup until rollback criteria expire.

Do not point the test gate at a development or production schema.
