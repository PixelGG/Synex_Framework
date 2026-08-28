# Geometry

Bundle activation compiles declarative shapes once. Runtime queries operate on normalized values and precomputed bounds rather than reparsing JSON.

## Supported shapes

| Type | Required data | Exact test |
| --- | --- | --- |
| `point` | `position` | coordinate equality, with optional query margin |
| `sphere` | `center`, positive `radius` | 3D distance |
| `aabb` | `min`, `max` | axis-aligned containment |
| `box` | `center`, positive `size`, `heading` | rotated local-space containment |
| `polygon` | 2D `vertices`, `minZ`, `maxZ` | ray crossing plus vertical bounds |
| `composite` | `operation: "union"`, `geometries` | any child contains the point |

Only union composites are implemented. Intersection and exclusion are not accepted.

## Safety bounds

Current runtime limits are:

- each coordinate: `-20000..20000`;
- geometry extent: `0.001..40000`;
- polygon vertices: at most 128;
- composite parts: at most 16;
- geometry nesting depth: at most 4.

The compiler rejects non-finite values, unsupported fields, inverted/zero-volume boxes, degenerate polygons, repeated closing vertices, adjacent duplicate vertices, self-intersecting polygon edges and invalid vertical bounds. Headings are normalized after bounded validation.

## Compiled representation

Every accepted spatial object receives a compiled shape and axis-aligned bounds. Polygons keep normalized vertices; rotated boxes keep sine/cosine and half-extents; composites keep compiled children and merged bounds. These internal values are derived data and are not part of the public bundle schema.

Anchors derive point or sphere geometry from `position` and `radius`. Doors derive an 8-unit sphere around their logical position. Portals derive a sphere from their source position and radius.

## Validation source

Use the canonical [JSON Schema](../../schemas/world-bundle.schema.json) for authoring and the offline [World CLI](../reference/cli.md) for schema and semantic validation. Passing offline geometry checks is not proof that a custom map's collision or MLO rooms match those coordinates in a live client.
