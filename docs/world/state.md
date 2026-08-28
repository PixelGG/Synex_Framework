# Dynamic world state

`world_state_definition` objects describe validated, typed and bounded state without moving static World definitions into the database.

## Definition fields

Supported value types are:

- `boolean`;
- `integer` and finite `number`, with optional minimum/maximum;
- `string`, with optional maximum length;
- `enum`, with 1–64 allowed strings;
- `structured`, with a bounded root container schema.

Supported scopes are `global`, `region`, `location`, `interior`, `room` and `instance`. Persistence is explicitly `runtime` or `persistent`. Every definition carries its own positive `schemaVersion` and may define a default value. Non-global reads and writes resolve the scope reference against an active World object of the declared kind or a non-closed World instance; a syntactically valid but missing/wrong-kind scope fails closed.

Structured state is intentionally limited rather than an arbitrary document store. Its schema declares a root `object` or `array`, maximum encoded bytes (up to 16 KiB), maximum container depth (up to 4) and maximum total entries (up to 64). Object nodes declare at most 32 named `properties`, a bounded `required` list and `additionalProperties: false`. Array nodes declare one `items` schema and a maximum of 64 items. Leaf nodes are limited to bounded booleans, safe integers/numbers, strings and string enums; the complete schema is limited to 64 nodes. Undeclared or missing properties, wrong value types, oversized arrays/strings, mixed or sparse containers, cycles, untrusted metatables and non-finite values fail closed. The two Cfx JSON container metatables produced by the runtime decoder are normalized as trusted object/array containers. This subset deliberately does not implement arbitrary JSON Schema keywords.

## Reads and defaults

A missing stored value returns its schema-validated default with version `0` when one exists. Without a value or default, the engine returns `WORLD_STATE_NOT_FOUND`. Stored values are checked against the active value type and schema version on every read; incompatible data fails with `STATE_SCHEMA_MISMATCH`.

## Mutations

`synex.world.state.set@1.0.0` is a server-only experimental contract protected by `synex.world.state.write`. The engine requires a current expected version, an operation-specific 8–36 character idempotency key, bounded reason code and server-derived actor/caller/trace provenance.

Runtime state is held in memory and discarded when purged/restarted. Persistent state is written through the Core DataPort to `synex_world_state`. The state update and `synex.world.state.changed` outbox row share one transaction. Competing expected versions fail rather than overwrite. Definition replacement or owner stop retains compatible persistent rows; closing an instance deliberately removes both runtime and persistent rows scoped to that now-closed instance ID.

Migration `001_world` gives state a composite primary key over definition/scope, a scope lookup index and an update-time index. Door state is keyed by `door_key`; the outbox has unique event identity plus bounded dispatch, lease and aggregate indexes. Static definitions are not duplicated into those tables.

The exact contract schema remains canonical in [`world.contracts.json`](../../resources/synex_world/contracts/world.contracts.json).

There is no automatic state-schema migration executor in this candidate. A persisted row whose type or schema version no longer matches fails with `STATE_SCHEMA_MISMATCH`; operators must use a reviewed forward migration or deliberately establish a compatible default before activating the changed definition.
