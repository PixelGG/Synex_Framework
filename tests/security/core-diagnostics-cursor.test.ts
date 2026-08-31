import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';

import { LuaFactory } from 'wasmoon';

const root = process.cwd();
const files = [
  'resources/synex_security/shared/limits.lua',
  'resources/synex_security/shared/validation.lua',
  'resources/synex_security/server/core_diagnostics_cursor.lua',
] as const;

async function run<T>(source: string): Promise<T> {
  const engine = await new LuaFactory().createEngine();
  try {
    for (const file of files) {
      await engine.doString(await readFile(path.join(root, file), 'utf8'));
    }
    return await engine.doString(source) as T;
  } finally {
    engine.global.close();
  }
}

test('Core diagnostic cursor is restart-safe, generation-aware and gap-visible', async () => {
  const result = await run<{
    first: number;
    restarted: number;
    regenerated: number;
    failure: string;
    retried: number;
    gapProcessed: number;
    checkpoint: string;
    roots: string;
    gaps: string;
  }>(`
    local kvp, roots, gaps, failId = nil, {}, {}, nil
    local function cursor()
      return SynexSecurityCoreDiagnosticsCursor.create({
        getCheckpoint = function() return kvp end,
        setCheckpoint = function(value) kvp = value; return true end,
        deleteCheckpoint = function() kvp = nil; return true end,
        onGap = function(reason) gaps[#gaps + 1] = reason end,
      })
    end
    local function provider(stream, ids, oldest, latest, dropped)
      return { Diagnostics = { getSecurityFindings = function(request)
        assert(request.limit == 50 and request.cursor == nil)
        local items = {}
        for _, id in ipairs(ids) do items[#items + 1] = { id = id } end
        return { status = 'AVAILABLE', streamId = stream, items = items,
          oldestId = oldest, latestId = latest, retained = #ids,
          dropped = dropped or 0, hasMore = false, truncated = false }
      end } }
    end
    local function emit(finding, stream)
      if failId == finding.id then
        failId = nil
        return nil, { code = 'EMIT_FAILED' }
      end
      roots[#roots + 1] = stream .. ':' .. tostring(finding.id)
      return true
    end

    local first = assert(cursor().drain(provider('stream_primary_0001',
      { 3, 2, 1 }, 1, 3), emit))
    local restarted = assert(cursor().drain(provider('stream_primary_0001',
      { 4, 3, 2, 1 }, 1, 4), emit))
    local regenerated = assert(cursor().drain(provider('stream_secondary_02',
      { 2, 1 }, 1, 2), emit))

    local retryCursor = cursor()
    failId = 2
    local _, failure = retryCursor.drain(provider('stream_failure_0003',
      { 3, 2, 1 }, 1, 3), emit)
    local retried = assert(retryCursor.drain(provider('stream_failure_0003',
      { 3, 2, 1 }, 1, 3), emit))

    kvp = 'v1|stream_retention_04|3'
    local gapProcessed = assert(cursor().drain(provider('stream_retention_04',
      { 10, 9 }, 9, 10, 8), emit))
    return { first = first, restarted = restarted, regenerated = regenerated,
      failure = failure.code, retried = retried, gapProcessed = gapProcessed,
      checkpoint = kvp, roots = table.concat(roots, ','),
      gaps = table.concat(gaps, ',') }
  `);

  assert.deepEqual(result, {
    first: 3,
    restarted: 1,
    regenerated: 2,
    failure: 'EMIT_FAILED',
    retried: 2,
    gapProcessed: 2,
    checkpoint: 'v1|stream_retention_04|10',
    roots: [
      'stream_primary_0001:1',
      'stream_primary_0001:2',
      'stream_primary_0001:3',
      'stream_primary_0001:4',
      'stream_secondary_02:1',
      'stream_secondary_02:2',
      'stream_failure_0003:1',
      'stream_failure_0003:2',
      'stream_failure_0003:3',
      'stream_retention_04:9',
      'stream_retention_04:10',
    ].join(','),
    gaps: 'RETENTION_GAP',
  });
});
