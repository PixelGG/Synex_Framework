# Assignments

> [!NOTE]
> This page documents the current Experimental Alpha. See [Organizations Engine status](overview.md#maturity-and-acceptance) before deploying it.

Assignments model temporary organization work units such as a shift, case, patrol, operation, project, team, or event. They are group-owned domain entities, not world entities or gameplay scripts.

## Model

An assignment stores:

- an opaque public ID, owning group, name, and extension-defined type;
- optional active parent assignment;
- optional start/end window and bounded metadata;
- `active`, `completed`, `cancelled`, or maintenance-managed `expired` status;
- optimistic version;
- zero or more membership participants with a bounded role key.

## Contracts

| Contract | Behavior |
| --- | --- |
| `synex.groups.assignments.get` | Read one assignment, including bounded metadata, after actor authorization in its owning group |
| `synex.groups.assignments.list` | Cursor-page assignments in one group, optionally filtered by lifecycle status; list items omit metadata |
| `synex.groups.assignments.create` | Create an active assignment, optionally below another active assignment in the same group |
| `synex.groups.assignments.join` | Add one active membership from the same group |
| `synex.groups.assignments.leave` | End one active participant row using `expected_version` and reason |
| `synex.groups.assignments.complete` | Complete an active assignment optimistically |
| `synex.groups.assignments.cancel` | Cancel an active assignment optimistically |

The two read contracts require Core resource capability `synex.groups.assignments.read` and actor capability `synex.groups.assignments.read`. List pages are capped at 40 and report the active participant count without exposing participant identities. Detail metadata is capped at 16 KiB, and every encoded read response must fit the shared 30,000-byte Groups transport guard.

`assignments.get` deliberately returns the same `ASSIGNMENT_NOT_FOUND` shape when the assignment is absent or the caller is not allowed to observe it. Retryable Core or database failures remain generic retryable infrastructure errors. This prevents detail-read error differences from becoming an assignment-enumeration oracle.

Mutation contracts use `synex.groups.assignments.manage` at both resource and actor layers. A participant may leave its own assignment; changing another character's participation requires group authority.

## Invariants and cleanup

- A participant needs an active membership in the assignment's group.
- One active participant row per membership/assignment is enforced.
- Parent assignments must already be active and belong to the same group.
- Participation can begin only while the assignment is inside its configured window.
- Duty may reference an assignment only while both assignment and participant link are active.
- Leaving a participant closes an open duty session linked to that assignment.
- Completing, cancelling, or expiring an assignment closes all linked open duty sessions and removes active participation transactionally.
- A membership transition away from active removes its assignment participation and closes duty.

The schema contains an optional assignment member limit, but `assignments.create` does not currently expose it. Do not advertise configurable assignment capacity through the public API.

## Domain boundary

Assignments do not spawn vehicles, entities, markers, routes, inventories, radio channels, or NUI. Other resources may persist the public assignment ID and react to durable events through their own authority checks.
