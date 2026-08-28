import assert from 'node:assert/strict';
import test from 'node:test';
import { runWorldLua } from './helpers.ts';

test('all supported geometry primitives compile and produce deterministic containment', async () => {
  const result = await runWorldLua<string>(String.raw`
    local shapes = {
      point = assert(SynexWorldGeometry.compile({
        type = 'point', position = { x = 1, y = 2, z = 3 }
      })),
      largePoint = assert(SynexWorldGeometry.compile({
        type = 'point', position = { x = 20000, y = -20000, z = 19999.999 }
      })),
      sphere = assert(SynexWorldGeometry.compile({
        type = 'sphere', center = { x = 0, y = 0, z = 0 }, radius = 5
      })),
      aabb = assert(SynexWorldGeometry.compile({
        type = 'aabb', min = { x = -2, y = -2, z = -1 },
        max = { x = 2, y = 2, z = 1 }
      })),
      box = assert(SynexWorldGeometry.compile({
        type = 'box', center = { x = 10, y = 10, z = 1 },
        size = { x = 4, y = 2, z = 2 }, heading = 90
      })),
      polygon = assert(SynexWorldGeometry.compile({
        type = 'polygon', minZ = 0, maxZ = 3,
        vertices = { { x = 0, y = 0 }, { x = 10, y = 0 },
          { x = 10, y = 10 }, { x = 0, y = 10 } }
      })),
      composite = assert(SynexWorldGeometry.compile({
        type = 'composite', operation = 'union', geometries = {
          { type = 'sphere', center = { x = 0, y = 0, z = 0 }, radius = 2 },
          { type = 'sphere', center = { x = 8, y = 0, z = 0 }, radius = 2 }
        }
      }))
    }
    assert(SynexWorldGeometry.contains(shapes.point, { x = 1, y = 2, z = 3 }, 0))
    assert(not SynexWorldGeometry.contains(shapes.point, { x = 1.1, y = 2, z = 3 }, 0))
    assert(SynexWorldGeometry.contains(shapes.largePoint,
      { x = 20000, y = -20000, z = 19999.999 }, 0))
    assert(SynexWorldGeometry.contains(shapes.sphere, { x = 3, y = 4, z = 0 }, 0))
    assert(not SynexWorldGeometry.contains(shapes.sphere, { x = 5.01, y = 0, z = 0 }, 0))
    assert(SynexWorldGeometry.contains(shapes.aabb, { x = 2, y = 2, z = 1 }, 0))
    assert(SynexWorldGeometry.contains(shapes.box, { x = 10, y = 10, z = 1 }, 0))
    assert(SynexWorldGeometry.contains(shapes.box,
      { x = 10, y = 12, z = 2 }, 0))
    assert(not SynexWorldGeometry.contains(shapes.box,
      { x = 10, y = 12.01, z = 1 }, 0))
    assert(SynexWorldGeometry.contains(shapes.polygon, { x = 5, y = 5, z = 2 }, 0))
    assert(SynexWorldGeometry.contains(shapes.polygon, { x = 5, y = 5, z = 0 }, 0))
    assert(SynexWorldGeometry.contains(shapes.polygon, { x = 5, y = 5, z = 3 }, 0))
    assert(not SynexWorldGeometry.contains(shapes.polygon, { x = 5, y = 5, z = -0.001 }, 0))
    assert(not SynexWorldGeometry.contains(shapes.polygon, { x = 5, y = 5, z = 3.001 }, 0))
    assert(not SynexWorldGeometry.contains(shapes.polygon, { x = 11, y = 5, z = 2 }, 0))
    assert(SynexWorldGeometry.contains(shapes.composite, { x = 8, y = 0, z = 0 }, 0))
    assert(not SynexWorldGeometry.contains(shapes.composite, { x = 4, y = 0, z = 0 }, 0))
    return table.concat({ shapes.point.kind, shapes.sphere.kind, shapes.aabb.kind,
      shapes.box.kind, shapes.polygon.kind, shapes.composite.kind }, ':')
  `);
  assert.equal(result, 'point:sphere:aabb:box:polygon:composite');
});

test('geometry compiler rejects non-finite, degenerate, intersecting, and oversized input', async () => {
  const result = await runWorldLua<string>(String.raw`
    local _, nanError = SynexWorldGeometry.compile({
      type = 'sphere', center = { x = 0/0, y = 0, z = 0 }, radius = 1
    })
    local _, infinityError = SynexWorldGeometry.compile({
      type = 'sphere', center = { x = math.huge, y = 0, z = 0 }, radius = 1
    })
    local _, negativeInfinityError = SynexWorldGeometry.compile({
      type = 'point', position = { x = 0, y = -math.huge, z = 0 }
    })
    local _, extentError = SynexWorldGeometry.compile({
      type = 'aabb', min = { x = 0, y = 0, z = 0 }, max = { x = 0, y = 1, z = 1 }
    })
    local _, crossingError = SynexWorldGeometry.compile({
      type = 'polygon', minZ = 0, maxZ = 2,
      vertices = { { x = 0, y = 0 }, { x = 10, y = 10 },
        { x = 0, y = 10 }, { x = 10, y = 0 } }
    })
    local vertices = {}
    for index = 1, SynexWorldLimits.maximumPolygonVertices + 1 do
      vertices[index] = { x = index, y = index % 2 }
    end
    local _, oversizedError = SynexWorldGeometry.compile({
      type = 'polygon', minZ = 0, maxZ = 2, vertices = vertices
    })
    assert(nanError.code == 'WORLD_GEOMETRY_INVALID')
    assert(infinityError.code == 'WORLD_GEOMETRY_INVALID'
      and negativeInfinityError.code == 'WORLD_GEOMETRY_INVALID')
    assert(extentError.code == 'WORLD_GEOMETRY_INVALID')
    assert(crossingError.code == 'WORLD_GEOMETRY_INVALID')
    assert(oversizedError.code == 'WORLD_GEOMETRY_INVALID')
    return nanError.code .. ':' .. crossingError.code
  `);
  assert.equal(result, 'WORLD_GEOMETRY_INVALID:WORLD_GEOMETRY_INVALID');
});

test('seeded geometry fuzz terminates and rejects every malformed candidate', async () => {
  const rejected = await runWorldLua<number>(String.raw`
    local state, rejected = 73428767, 0
    local function random(maximum)
      state = (1103515245 * state + 12345) % 2147483648
      return state % maximum
    end
    for index = 1, 1500 do
      local candidate
      if index % 3 == 0 then
        candidate = { type = 'sphere', center = {
          x = random(39999) - 19999, y = random(39999) - 19999,
          z = random(39999) - 19999 }, radius = random(1000) / 10 + 0.01 }
        assert(SynexWorldGeometry.compile(candidate))
      elseif index % 3 == 1 then
        candidate = { type = 'sphere', center = { x = 0/0, y = 0, z = 0 }, radius = 1 }
        local value = SynexWorldGeometry.compile(candidate)
        if not value then rejected = rejected + 1 end
      else
        candidate = { type = 'composite', operation = 'union', geometries = {} }
        local value = SynexWorldGeometry.compile(candidate)
        if not value then rejected = rejected + 1 end
      end
    end
    return rejected
  `);
  assert.equal(rejected, 1000);
});
