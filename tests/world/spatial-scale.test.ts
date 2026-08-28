import assert from 'node:assert/strict';
import test from 'node:test';
import { runWorldLua } from './helpers.ts';

test('hierarchical spatial index bounds candidates at planned world scale', { timeout: 30_000 }, async () => {
  const result = await runWorldLua<string>(String.raw`
    local index = SynexWorldSpatialIndex.create({
      maximumQueryCandidates = 4096, maximumCellsPerObject = 64,
      maximumGlobalObjects = 128
    })
    local function pointGeometry(x, y, z, radius)
      return assert(SynexWorldGeometry.compile({
        type = 'sphere', center = { x = x, y = y, z = z }, radius = radius
      }))
    end
    local count = 0
    local function insert(kind, amount, spacing, radius)
      local columns = math.max(1, math.min(500, math.floor(38000 / spacing)))
      for current = 1, amount do
        local x = ((current - 1) % columns) * spacing - 19000
        local y = math.floor((current - 1) / columns) * spacing - 19000
        local key = ('%s:%06d'):format(kind, current)
        assert(index.insert(key, { key = key, kind = kind }, pointGeometry(x, y, 20, radius)))
        count = count + 1
      end
    end
    insert('anchor', 50000, 40, 0.01)
    insert('zone', 10000, 80, 12)
    insert('door', 5000, 60, 5)
    insert('location', 1000, 300, 80)
    assert(count == 66000 and index.count() == 66000)
    local results, metadata = assert(index.queryNearby(
      { x = -18980, y = -18980, z = 20 }, 100,
      function() return true end, 100))
    assert(#results > 0 and metadata.candidates < 500)
    local diagnostics = index.diagnostics(8)
    assert(diagnostics.entries == 66000)
    assert(diagnostics.maximumCandidates < 500)
    assert(diagnostics.fineCells > 0 and diagnostics.coarseCells > 0)
    return diagnostics.entries .. ':' .. metadata.candidates .. ':' .. #results
  `);
  const parts = result.split(':').map(Number);
  assert.equal(parts.length, 3);
  const entries = parts[0] as number;
  const candidates = parts[1] as number;
  const results = parts[2] as number;
  assert.equal(entries, 66_000);
  assert.ok(candidates > 0 && candidates < 500);
  assert.ok(results > 0 && results <= 100);
});

test('sparse maximum-radius queries traverse occupied hierarchy instead of empty fine cells', async () => {
  const result = await runWorldLua<string>(String.raw`
    local index = SynexWorldSpatialIndex.create({ maximumQueryCandidates = 4096,
      maximumQueryCells = 8192, maximumCellsPerObject = 64 })
    local function geometry(x, y)
      return assert(SynexWorldGeometry.compile({ type = 'sphere',
        center = { x = x, y = y, z = 20 }, radius = 0.01 }))
    end
    for current = 1, 1000 do
      local x = (current % 100) * 200 - 10000
      local y = math.floor(current / 100) * 200 - 1000
      local key = ('anchor:%04d'):format(current)
      assert(index.insert(key, { key = key, kind = 'anchor' }, geometry(x, y)))
    end
    local empty, emptyMeta = assert(index.queryNearby(
      { x = 15000, y = 15000, z = 20 }, 1000, function() return true end, 10))
    local sparse, sparseMeta = index.queryNearby(
      { x = 0, y = 0, z = 20 }, 1000, function() return true end, 10)
    assert(sparse, sparseMeta and sparseMeta.code)
    assert(#empty == 0 and emptyMeta.traversedCells < 2048)
    assert(sparseMeta.traversedCells <= SynexWorldLimits.maximumQueryCells)
    assert(sparseMeta.candidates <= SynexWorldLimits.maximumQueryCandidates)
    return table.concat({ emptyMeta.traversedCells, sparseMeta.traversedCells,
      sparseMeta.candidates }, ':')
  `);
  const [emptyCells, sparseCells, candidates] = result.split(':').map(Number);
  assert.ok((emptyCells ?? 10_000) < 2048);
  assert.ok((sparseCells ?? 10_000) <= 8192);
  assert.ok((candidates ?? 10_000) <= 4096);
});
