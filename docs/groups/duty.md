# Duty sessions

> [!NOTE]
> This page documents the current Experimental Alpha. See [Organizations Engine status](overview.md#maturity-and-acceptance) before deploying it.

Duty is durable organization state attached to a membership. It is not an online-player permission flag and does not implement payroll, time rewards, uniforms, loadouts, blips, dispatch, or gameplay actions.

## State model

A duty session records:

- an opaque public ID and membership reference;
- one enabled state accepted by the membership's group type;
- `open` or `closed` lifecycle status;
- start/end timestamps and optimistic version;
- optional active assignment participation;
- bounded metadata and immutable duty events.

The schema seeds `on_duty` and `paused`. After the owner opens its current synchronization session with `synex.groups.registries.begin`, `synex.groups.duty_states.register` lets that resource register a versioned state and whether it contributes to the internal on-duty index. A group type declares which registered states it allows. State keys do not carry gameplay behavior.

Only one open session is permitted per membership. Start requires an active membership, active group, type-approved state, group authority, and—when supplied—active participation in the assignment. Update and stop use the current session version.

## Contracts

| Contract | Behavior |
| --- | --- |
| `synex.groups.duty.list` | Cursor-page one group's sessions, optionally filtered by membership and `open`/`closed` status |
| `synex.groups.duty.start` | Open a session in an allowed state, optionally attached to an assignment |
| `synex.groups.duty.update` | Change state, assignment, and metadata optimistically |
| `synex.groups.duty.stop` | Close the session with a reason |

Mutations require Core resource capability `synex.groups.duty`. Actor authorization uses the operation-specific character capability `synex.groups.duty.start`, `.update`, or `.stop` in the group.

`duty.list` is server-local and requires `synex.groups.duty.read` at both resource and actor layers. Pages are capped at 40 and return membership, state, status, optional assignment, effective `counts_as_on_duty`, timestamps, and version. They do not expose character IDs or session metadata. The final encoded response must also remain within the shared 30,000-byte Groups read bound.

The only client-visible duty projection is the connected character's own open duty entry inside `synex.groups.self.snapshot`; it is not a group duty roster and cannot select another membership.

## History, cleanup, and runtime projection

Start, update, and stop write a versioned duty event and domain effect transactionally. Leaving active membership state closes open duty. Leaving, completing, cancelling, or expiring a linked assignment also closes affected sessions.

For connected characters, a bounded internal runtime index projects open sessions by membership and the subset whose state has `counts_as_on_duty = true` by group. The projection rebuilds from durable state and is an optimization, never the authority source.

The generic history contract can expose authorized duty changes; it is not a payroll timesheet.

## Integration rule

A later police resource may decide that an `on_duty` fact enables dispatch participation, and a later accounts resource may use verified history as one input to payroll policy. Neither concern exists in `synex_groups`. Duty alone never grants Core caller-resource authority.
