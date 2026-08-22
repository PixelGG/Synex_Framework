# Database foundation

Synex persistence targets InnoDB with a MariaDB 11.8 or MySQL 8.4 deployment baseline. CI exercises MariaDB 11.8; MySQL 8.4 remains a documented target that operators must verify against their exact server because the repository does not run a MySQL service job. Older installations are outside this `0.1.0` baseline even when the DDL happens to apply. Runtime SQL uses positional `?` parameters only. Named placeholders and cross-resource table access are prohibited.

The database session used by oxmysql must be UTC. Synex deliberately relies on database time for leases, expiries, queues, outboxes, audit timestamps, and retention cutoffs; most persistence uses `CURRENT_TIMESTAMP(6)`, while archive cutoff/copy operations use `UTC_TIMESTAMP(6)`. Before migration bootstrap, Core executes `TIMESTAMPDIFF(SECOND, UTC_TIMESTAMP(), CURRENT_TIMESTAMP())` through the normal persistence adapter and requires an exact zero result. A nonzero result, malformed result, or database error fails boot; `synex doctor` repeats the same check. Synex does not issue a session-time-zone command, and no connection-string parameter is assumed here.

## Migration protocol

Migration files are UTF-8, LF-normalized, forward-only inputs. The Core migration runner computes SHA-256 over LF-normalized bytes and records the digest in `synex_schema_migrations`. An already-applied `(resource_name, migration_id)` whose digest changes is a startup error; repair is always a new migration.

Each top-level statement is separated by a line containing exactly:

```sql
-- synex:statement
```

The runner does not enable multi-statement queries. Every current migration containing DDL is declared `transactional: false`: both MariaDB and MySQL can implicitly commit DDL. A migration may append idempotent `INSERT ... SELECT ... WHERE NOT EXISTS` backfills after its tables; each backfill is its own delimited statement. `synex_cluster_leases` provides a time-bounded lease plus monotonically increasing fencing token so only the current holder may apply migrations. Database time, never host clock time, determines lease expiry.

Apply resources in dependency order:

1. `synex_core`: `001_migration_control.sql`, `002_identity.sql`, `003_reliability.sql`, `004_access_control.sql`, `005_sagas.sql`, `006_character_deletion.sql`, `007_cluster_runtime.sql`, `008_core_rbac.sql`, `009_legacy_import.sql`, `010_retention_archive.sql`
2. `synex_groups`: `001_groups.sql`, `002_grades_primary_read_models.sql`, `003_character_lifecycle.sql`
3. `synex_accounts`: `001_accounts.sql`, `002_ledger.sql`, `003_holds.sql`, `004_access_integrity.sql`, `005_character_lifecycle.sql`, `006_financial_archive.sql`
4. `synex_entities`: `001_entities.sql`

The migration IDs in each `synex.resource.json` are the public installation order. Never rename, reorder, or edit a released file.

## Ownership boundaries

Core owns users, raw identifiers, sessions, characters, access decisions, migration state, kernel idempotency, the kernel outbox, sagas, deletion plans, append-only audit and its non-destructive archive mirror, cluster-instance/session-control records, persistent RBAC, and the reviewed legacy-import journal plus hashed legacy-ID mappings. Raw identifier values are sensitive: they are used only for server-side lookup and DB uniqueness, and must never enter logs, state bags, client payloads, traces, or outbox events.

`synex_groups` owns groups, memberships, grades, grade capability rules, grade assignments, primary-membership pointers/events, read-model versions, immutable membership events, local idempotency records, its local outbox, and an idempotent character-deletion journal. A membership stores an opaque `(subject_kind, subject_ref)`; it does not query Core identity tables.

`synex_accounts` owns currencies, accounts, owner bindings, account-local access roles/grants, operations, ledger transactions, paired postings, reversal links, balance snapshots, audit, outbox, holds, hold events, reconciliation runs, warning findings, the versioned integrity read model, its non-destructive financial transaction archive mirror, and an idempotent character-deletion journal. Owner and principal references are opaque. It does not query group or Core identity tables. Cross-domain existence and authorization are established before calling the service through contracts, never by cross-resource joins.

`synex_entities` owns the durable entity registry. The database harness includes its `001_entities.sql` migration so live schema validation reflects the complete currently runnable foundation set.

Lifetime-coupled tables use foreign keys inside each owner boundary and deletes default to `RESTRICT`; lifecycle work anonymizes or appends terminal state rather than cascading economic or audit history. The two archive mirrors are intentionally self-contained and have unique source-row identifiers instead of foreign keys, so preserving them never depends on the source row's lifetime.

## Foundation ABI

The groups and accounts domains are server-only. They acquire the kernel facade with:

```lua
local api, err = exports.synex_core:GetAPI('^1.0.0')
```

They register provider discovery through `api.Services.provide` and register every Invoke operation through `api.RPC.registerServer`. Consumers call a separate contract name and version:

```lua
local result, err = exports.synex_core:Invoke(
    'synex.accounts.transfer',
    '1.0.0',
    request,
    options
)
```

Contract names never contain `@1`. All 45 generated contracts in this checkout use `network: none`, and their providers make no `registerNetwork` registrations. Domain resources deliberately expose no convenience exports: a nested export would cause Core to observe the provider resource instead of the original caller and would destroy the capability boundary. Consumers call `exports.synex_core:Invoke` directly; `options` must never be used to assert or override caller identity. The optional compatibility/control events are separate bounded resource interfaces, not generated domain contracts.

The optional service-discovery surface is read-only and declares a capability for every exposed method. `synex.groups` exposes `get`, `get_read_model`, `list_subject_memberships`, `check_capability`, and `get_control_summary` under `synex.groups.read`. `list_subject_memberships` returns at most 64 active memberships plus an explicit `truncated` flag. `synex.accounts` exposes `get_snapshot`, `list_owner_accounts`, and `get_hold` under `synex.accounts.read`, `get_access` under `synex.accounts.access.read`, and `get_integrity` plus `get_control_summary` under `synex.accounts.integrity.read`. `list_owner_accounts` is the compatibility projection: it returns at most 64 active `cash`/`bank` asset accounts plus `truncated`, not an unbounded general account search. `synex.entities` exposes `getHealth` under `synex.entities.health` and `getControlSummary` under `synex.entities.read`. Mutations in these three domain resources are registered only as server RPC contracts, so they pass through Core's caller identity and capability checks.

Every mutation requires a lowercase UUID `idempotency_key`. A key is bound to the operation name and a canonical request fingerprint. Reuse with the same request returns the stored response; reuse with different input returns `IDEMPOTENCY_CONFLICT`. The idempotency insert, domain changes, immutable audit/outbox event, and stored response commit in one local transaction.

Entity persistence also uses the caller-bound Core API, but its lifecycle, service health, and generation-token rules are documented separately in [Entity authority](entities.md).

## Concurrency and retries

The account concurrency model expects oxmysql `READ COMMITTED` (`mysql_transaction_isolation_level 2`); Synex does not set that operator ConVar. `synex doctor` reports the current Cfx ConVar expected by the adapter. Set it before oxmysql starts and restart the adapter after any change; that report does not prove what an existing pooled connection previously applied. It also deliberately does not label a query on an arbitrary pooled or independent session as proof of the active transaction: oxmysql applies `SET TRANSACTION ISOLATION LEVEL` when establishing its transaction path, while session-variable reporting has different next-transaction semantics across supported servers. Verify the Doctor result and the exact deployed adapter/database pair. Account operations use explicit `SELECT ... FOR UPDATE`, sort both public IDs, and acquire each account row and latest-snapshot row through separate statements in that ascending order. Writes use optimistic versions or unique sequence constraints as a second line of defense.

Deadlocks remain normal under concurrency. Core batch and interactive transaction wrappers recognize error `1213`, SQLSTATE `40001`, or a deadlock diagnostic and retry up to `database.deadlockRetries` with a bounded wait (two retries by default, five at most). After exhaustion the error remains retryable; any caller-level replay must use the original idempotency key and exact request. Do not retry validation errors, authorization failures, insufficient funds, terminal holds, or idempotency conflicts. A network failure after commit is resolved by replaying the same idempotency key.

Outbox delivery is at least once. The Core, groups, and accounts dispatchers claim ready rows in short transactions, publish outside the claim transaction, and mark success afterward. The groups and accounts workers run once per second with batches of at most 25 and use the capability-gated Core `Events.publishOutbox` path. Consumers deduplicate on `event_id`. Attempts use bounded exponential backoff; the tenth failed attempt becomes `dead` and requires an explicit operator action. Domain writes never publish directly.

## Retention archive mirrors

The committed retention policy defaults both `audit` and `financial` to `retain_forever`, so no archive worker is scheduled by default. In `archive` mode, Core schedules `core.retention.audit_archive` and accounts schedules `synex_accounts.retention.financial_archive` at the configured `workerIntervalMs`. Each run uses an idempotent, UTC-based `INSERT IGNORE ... SELECT` with `archiveAfterDays` and `batchSize` bounds.

`synex_audit_archive` mirrors eligible rows from `synex_audit_log`; `synex_financial_transaction_archive` stores a self-contained projection of eligible ledger transactions, their unique posting, operation, currency, and account public IDs. Unique source-row keys make repeated batches safe. Archiving never updates or deletes the source audit, transaction, posting, snapshot, operation, account, or character-deletion history. There is no purge command or public deletion service; archive storage, access control, backup, and any separately approved destruction workflow remain operator responsibilities.

## Account invariants

All amounts are integer minor units in the range `1..9007199254740991`. Floating-point amounts are rejected.

| Invariant | Enforcement |
| --- | --- |
| No mutable balance on `synex_accounts` | Booked and reserved values exist only in append-only `synex_account_balance_snapshots`. |
| Every value movement has two sides | One `synex_ledger_postings` row names a distinct debit account and credit account. |
| Debit equals credit | `debit_minor > 0` and `debit_minor = credit_minor` are DB checks; one paired posting is unique per ledger transaction. |
| Currency cannot cross | Transaction creation joins both accounts on the same `currency_id`. |
| Available funds cannot be overspent | The locked latest snapshot must satisfy `booked_minor - reserved_minor >= amount_minor`. |
| Mint and burn are explicit | Mint requires `mint -> asset`; burn requires `asset -> burn`. Only a system-owned mint account may be negative. |
| Audit and event are atomic | Ledger, snapshots, `synex_account_audit`, local outbox, and idempotent response share one transaction. |
| Reversal never edits history | `synex.accounts.reverse` appends one inverse posting and a unique `synex_ledger_reversals` link; neither the original nor its reversal may be reversed again. |

In this API, the debit account is the value source whose booked amount decreases; the credit account is the destination whose booked amount increases. This naming is a game-economy transfer convention, not a general-purpose GAAP chart-of-accounts implementation.

A hold does not move booked value. Creation appends a snapshot that increases `reserved_minor`, reducing available value. Release appends a snapshot that removes the reservation. Capture is the only hold transition that moves booked value and therefore must create a balanced ledger transaction. `synex_account_hold_events` allows one creation event and at most one terminal event, so capture and release cannot both succeed.

Account-local access uses immutable role definitions plus versioned grants. A role contains a unique subset of exactly these permission keys: `view`, `deposit`, `withdraw`, `transfer`, `history`, `manage`, and `close`. At most one active grant exists for an account/principal tuple; revocation clears the active marker and appends audit/outbox records. The owner receives an `owner` role and grant when the account is created, and migration `004_access_integrity.sql` idempotently backfills that role, all seven permissions, and an owner grant for pre-existing accounts. These grants are domain facts, not caller identity: a server-local caller must resolve the authoritative user/character/group in its own server-side domain and query `synex.accounts.get_access`. Request fields may never assert that identity.

`synex.accounts.run_reconciliation` advances a per-currency model version and writes an immutable run plus zero to five findings. Rules cover debit/credit imbalance, aggregate snapshot drift, negative asset snapshots, reservations exceeding booked value, and orphan transactions. Every finding is severity `warn`; reconciliation only records audit/outbox evidence and never bans a principal, mutates ledger history, or repairs balances. Aggregate `BIGINT` counts and `DECIMAL(36,0)` totals are returned as decimal strings to avoid Lua/JSON safe-integer loss.

Group capability evaluation accepts exact rules and trailing segment wildcards such as `synex.accounts.*`. Any matching `deny` wins over every matching `allow`. Primary membership is a separate per-subject pointer: selecting a new primary never removes the subject's other memberships. Every grade, membership, capability, and primary change increments the affected `synex_group_read_model_versions.model_version`; consumers use that version as the cache invalidation token.

Snapshots, ledger rows, membership events, audit entries, and saga steps are append-only. APIs return defensive copies; callers cannot mutate persisted history by changing a returned Lua table.

## Character deletion and durable access policy

Access bans and allowlist entries are relational durable records. The schema can target exactly one user or identifier, supports expiry and revocation, and is queried by the server-side connection pipeline. The current public `api.Access` mutation/list surface and console commands are user-ID scoped; they do not expose identifier-target creation. Resource mutations require `synex.access.manage` plus a bounded idempotency key and commit the access change with before/after audit evidence. Listing requires `synex.access.read` and returns at most 64 bans and 64 allowlist rows for one user, each with an explicit truncation flag. Neither capability is granted by default. JSON configuration is not a replacement for these records.

`synex_character_deletion_plans` coordinates owner-specific character cleanup. `plan_json` may contain only bounded resource owner and action metadata; it must never contain SQL. The coordinator uses optimistic `version` transitions and retains the plan and append-only audit after completion or failure.

The current lifecycle participants are explicit. `synex_accounts` blocks deletion while a character-owned account has a nonterminal hold; during idempotent `deleteCommit` reconciliation it closes and anonymizes the character's owned accounts, revokes affected active grants, and retains ledger history in one domain transaction. `synex_groups` replaces character subject references with a generated anonymous reference and invalidates affected read models while retaining event history. `synex_entities` deletes runtime-temporary entities and retains persistent records under a generated retained owner reference. Each participant consumes only the bounded plan action prepared for its own resource.

## Database test gate

`npm run test:database` always runs static checksum, delimiter, ownership, Lua parse, and ledger-invariant tests. The live suite is skipped unless both variables are present:

```text
SYNEX_TEST_DATABASE_LIVE=1
SYNEX_TEST_DATABASE_URL=mysql://user:password@host:3306/synex_test_local
```

The database name must match `synex_test_[a-z0-9_]+`. The harness applies project-owned statements one at a time with multi-statements disabled, inspects InnoDB/check/FK metadata, then runs real parallel counter-direction transfers and a duplicate idempotency race on independent connections. It verifies balanced ledger rows, immutable snapshot sequencing, reconstructed/nonnegative balances, atomic audit/outbox counts, and single-winner cluster-lease fencing. It does not create or drop a database and leaves schema cleanup to the test operator. Never point the gate at production or a shared development schema.

Primary references: [oxmysql transactions](https://overextended.dev/oxmysql/Functions/transaction), [oxmysql prepared queries](https://overextended.dev/oxmysql/Functions/prepare), [MariaDB InnoDB transactions](https://mariadb.com/docs/server/server-usage/storage-engines/innodb/innodb-system-variables), [MariaDB `FOR UPDATE`](https://mariadb.com/docs/server/reference/sql-statements/data-manipulation/selecting-data/for-update), [MySQL InnoDB locking reads](https://dev.mysql.com/doc/refman/8.4/en/innodb-locking-reads.html), and [MySQL deadlocks](https://dev.mysql.com/doc/refman/8.4/en/innodb-deadlocks-handling.html).
