# Interiors and rooms

World interiors and rooms are semantic spatial definitions. GTA interior metadata is optional supporting information, not the only authority.

## Interior

An `interior`:

- has a `location` parent;
- has required World geometry;
- may carry an integer `gameInteriorId`;
- may reference map packages and IPL bundles;
- may own rooms, zones, anchors, doors, portals and state definitions.

## Room

A `room`:

- has an `interior` parent;
- has required World geometry;
- may carry a bounded `gameRoomKey` string;
- may own zones, anchors, doors, portals and state definitions.

The server determines interior/room context from compiled World geometry and server-observed player coordinates. It does not trust a client-reported GTA interior or room value.

## Client entity sets

`ipl_bundle` definitions may add `{ interiorId, name, color? }` entity-set requirements. Client slices deduplicate those requirements. The client activates/deactivates sets and refreshes valid interiors on a 250 ms reconciliation cadence, preserving entity sets it did not activate itself.

This native path still requires a real-client acceptance run against the intended map and FXServer artifact. Schema validity cannot prove that an interior ID or entity-set name exists in a third-party MLO.
