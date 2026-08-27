# Organization relationships

> [!NOTE]
> This page documents the current Experimental Alpha. See [Organizations Engine status](overview.md#maturity-and-acceptance) before deploying it.

Parent hierarchy and organization relationships are separate models:

- hierarchy describes containment and has at most one direct parent per child;
- a relationship is a versioned edge between two independent groups.

## Relation-type registry

The schema seeds these neutral types:

| Type | Direction |
| --- | --- |
| `subdivision_of` | directed |
| `subsidiary_of` | directed |
| `ally_of` | symmetric |
| `hostile_to` | symmetric |
| `partner_of` | symmetric |
| `affiliated_with` | symmetric |

After the owner has opened its current synchronization session with `synex.groups.registries.begin`, `synex.groups.relation_types.register` lets that server resource register or advance a custom type with a label, `directed`/`symmetric` direction, and schema version. Ownership is derived from Core caller context, persisted with an owner epoch, and restored into the bounded runtime registry only while the exact owner session remains active. Another resource or stale owner epoch cannot replace it.

Relation types are metadata only. They do not make organizations friendly, hostile, financially linked, or access-compatible.

## Relationship entity

A relationship stores its public ID, registered type, source and target groups, `active`/`suspended`/`ended` status, validity window, bounded metadata, actor/reason, and optimistic version.

- Both groups must exist and be active at creation.
- The source group type must permit relationships.
- Self-relations are rejected.
- Symmetric types canonicalize endpoint order so `A ally_of B` and `B ally_of A` cannot become separate active rows.
- The seeded acyclic directed types use bounded recursive cycle and depth checks.

Mutation contracts are `synex.groups.relationships.create` and `.update`; both require `synex.groups.relationships.manage`. Updates require `expected_version`, and an ended edge cannot be reopened.

Authorized server resources can use:

| Contract | Behavior |
| --- | --- |
| `synex.groups.relationships.get` | Read one edge inside the supplied source-or-target group scope |
| `synex.groups.relationships.list` | Cursor-page a group's incoming, outgoing, or all edges, optionally filtered by relation type and effective status |

Both reads require Core resource capability `synex.groups.relationships.read` and actor capability `synex.groups.relationships.read` in the requested group. List pages are capped at 40 entries and expose `next_cursor`/`truncated`; relationship detail metadata is capped at 16 KiB, and every encoded read must fit the shared 30,000-byte Groups response guard. Callers must not query the Groups tables directly.

## Expiry behavior

Relationship reads are expiry-aware. When an `active` or `suspended` row has reached `valid_until`, `relationships.get` and `.list` report effective status `ended` immediately using database time, even if the maintenance pass has not yet persisted the transition. Status filtering uses that same effective value.

The bounded lifecycle-maintenance worker runs through Core's scheduler every 30 seconds. It locks due rows, changes them to `ended` with optimistic versioning, records `ended_at` and reason `relationship_window_expired`, advances both organizations' read-model revisions, and writes the durable `relationship.expired` effect. Cache invalidation follows the committed maintenance batch. The read-time projection closes the scheduling window; it does not replace the durable worker transition.

The expanded working tree passed the dedicated live-MariaDB suite and isolated FXServer restart/Doctor acceptance on 2026-08-25. That evidence covers the registered read/expiry runtime without promoting Groups beyond Experimental Alpha or certifying a later changed commit.

## Example

```text
Holding Company --subsidiary_of--> Restaurant Group
Medical Department <--ally_of--> Fire Department
```

This is organization metadata. Accounts, storage, dispatch, doors, vehicles, and other effects require explicit contracts in their owning resources.
