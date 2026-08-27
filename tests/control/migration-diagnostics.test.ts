import assert from 'node:assert/strict';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';
import { source } from './helpers.js';

test('MigrationManager returns bounded keyset pages with manifest drift findings', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    for (const relativePath of [
      'core/synex_core/server/factories.lua',
      'core/synex_core/server/foundation.lua',
      'core/synex_core/server/persistence.lua',
      'core/synex_core/server/control_providers.lua',
    ]) {
      await engine.doString(await source(relativePath));
    }
    const result = await engine.doString(`
      local files = {
        ['synex_a:migrations/001_first.sql'] = 'SELECT 1;',
        ['synex_a:migrations/002_changed.sql'] = 'SELECT 2;',
        ['synex_a:migrations/003_missing.sql'] = 'SELECT 3;',
        ['synex_a_b:migrations/001_prefix.sql'] = 'SELECT 4;'
      }
      local manifests = {
        synex_a = {
          name = 'synex_a',
          migrations = {
            { id = '001_first', path = 'migrations/001_first.sql' },
            { id = '002_changed', path = 'migrations/002_changed.sql' },
            { id = '003_missing', path = 'migrations/003_missing.sql' }
          }
        },
        synex_a_b = {
          name = 'synex_a_b',
          migrations = {
            { id = '001_prefix', path = 'migrations/001_prefix.sql' }
          }
        }
      }
      local platform = {
        nowGame = function() return 1000 end,
        random = function() return 17 end,
        print = function() end,
        jsonEncode = function() return '{}' end,
        jsonDecode = function() return {} end,
        wait = function() end,
        loadResourceFile = function(resource, path)
          return files[resource .. ':' .. path]
        end
      }
      local foundation = SynexCoreFactories.foundation({
        platform = platform,
        nextId = function(prefix) return prefix .. '_fixture' end
      })
      local checksums = {}
      local databaseRows = {}
      local adapter = {
        query = function(sql, parameters)
          assert(sql:find('UNION', 1, true))
          assert(not sql:find('CONCAT(', 1, true))
          assert(sql:find('observed', 1, true))
          local cursorResource = #parameters == 4 and parameters[1] or nil
          local cursorMigration = #parameters == 4 and parameters[3] or nil
          local maximum = parameters[#parameters]
          local output = {}
          for _, row in ipairs(databaseRows) do
            if cursorResource == nil or row.resource_name > cursorResource
              or row.resource_name == cursorResource
                and row.migration_id > cursorMigration then
              output[#output + 1] = foundation.copy(row)
              if #output >= maximum then break end
            end
          end
          return output
        end,
        scalar = function() return nil end,
        insert = function() return 0 end,
        update = function() return 0 end,
        transaction = function() return true end,
        startTransaction = function() return true end
      }
      local persistence = SynexCoreFactories.persistence({
        platform = platform,
        foundation = foundation,
        db = adapter,
        instanceId = 'instance-a',
        manifestSnapshot = function() return manifests end
      })
      for key, contents in pairs(files) do checksums[key] = persistence.sha256(contents) end
      local changedChecksum = string.rep('f', 64)
      databaseRows = {
        {
          resource_name = 'synex_a', migration_id = '001_first',
          marker_checksum = checksums['synex_a:migrations/001_first.sql'],
          attempt_checksum = checksums['synex_a:migrations/001_first.sql'],
          fence_checksum = checksums['synex_a:migrations/001_first.sql'],
          attempt_state = 'applied', fence_state = 'applied', attempts = '1',
          applied_at = '2026-08-26T10:00:00.000000Z', duration_ms = '8'
        },
        {
          resource_name = 'synex_a', migration_id = '002_changed',
          marker_checksum = changedChecksum, attempt_checksum = changedChecksum,
          fence_checksum = changedChecksum, attempt_state = 'applied',
          fence_state = 'applied', attempts = '2',
          applied_at = '2026-08-26T10:01:00.000000Z', duration_ms = '13'
        },
        {
          resource_name = 'synex_a_b', migration_id = '001_prefix',
          marker_checksum = checksums['synex_a_b:migrations/001_prefix.sql'],
          attempt_checksum = checksums['synex_a_b:migrations/001_prefix.sql'],
          fence_checksum = checksums['synex_a_b:migrations/001_prefix.sql'],
          attempt_state = 'applied', fence_state = 'applied', attempts = '1',
          applied_at = '2026-08-26T10:02:00.000000Z', duration_ms = '5'
        },
        {
          resource_name = 'synex_orphan', migration_id = '900_removed',
          marker_checksum = string.rep('a', 64), attempts = nil,
          applied_at = '2026-08-26T10:03:00.000000Z', duration_ms = '3'
        }
      }

      local first = assert(persistence.migrations:details({ limit = 2 }))
      assert(#first.items == 2 and first.hasMore and first.nextCursor == 'synex_a|002_changed')
      assert(first.items[1].status == 'applied' and first.items[1].finding == nil)
      assert(first.items[1].appliedAt == '2026-08-26T10:00:00.000000Z'
        and first.items[1].durationMs == 8)
      assert(first.items[2].finding == 'CHECKSUM_MISMATCH'
        and first.items[2].checksum ~= first.items[2].recordedChecksum)
      assert(first.pageFindings.CHECKSUM_MISMATCH == 1 and #first.columns == 10)
      assert(first.findingScope == 'MANIFEST_AND_MIGRATION_MARKERS'
        and first.physicalSchemaInspection == false)
      for _, row in ipairs(first.items) do
        local columns = 0
        for _ in pairs(row) do columns = columns + 1 end
        assert(columns <= 12)
      end

      local second = assert(persistence.migrations:details({
        limit = 2, cursor = first.nextCursor
      }))
      assert(second.items[1].migration == '003_missing'
        and second.items[1].finding == 'MISSING_MIGRATION'
        and second.items[1].status == 'missing')
      assert(second.items[2].resource == 'synex_a_b'
        and second.items[2].migration == '001_prefix')
      assert(second.hasMore and second.nextCursor == 'synex_a_b|001_prefix')

      local third = assert(persistence.migrations:details({
        limit = 2, cursor = second.nextCursor
      }))
      assert(#third.items == 1 and third.items[1].resource == 'synex_orphan')
      assert(third.items[1].finding == 'SCHEMA_DRIFT' and not third.hasMore)

      local invalid, invalidError = persistence.migrations:details({
        cursor = 'synex_a|002_changed|extra'
      })
      assert(invalid == nil and invalidError.code == 'INVALID_ARGUMENT')
      invalid, invalidError = persistence.migrations:details({ limit = 51 })
      assert(invalid == nil and invalidError.code == 'INVALID_ARGUMENT')
      invalid, invalidError = persistence.migrations:details({ sort = 'migration' })
      assert(invalid == nil and invalidError.code == 'INVALID_ARGUMENT')

      local owners = {
        isCurrent = function() return true end,
        track = function() return {}, nil end,
        beginOperation = function() return {}, nil end,
        finishOperation = function() return true end
      }
      local providers = SynexCoreFactories.controlProviders({
        platform = platform,
        foundation = foundation,
        owners = owners,
        coreResource = 'synex_core',
        manifestFor = function() return nil end
      })
      assert(providers:register('synex_core', 1, {
        schemaVersion = 1,
        namespace = 'core',
        label = 'Core',
        category = 'framework',
        version = '1.0.0',
        operations = {
          list = function(request)
            local page, pageError = persistence.migrations:details({
              cursor = request.cursor,
              limit = request.limit
            })
            if not page then return nil, pageError end
            page.view = 'migrations'
            return page, nil
          end
        },
        views = {{
          id = 'migrations', label = 'Migrations', operation = 'list',
          presentation = 'table', accessClass = 'general', order = 110
        }}
      }))
      local envelope, providerError = providers:invoke('synex_control', 1,
        'core', 'list', { view = 'migrations', limit = 2 }, {}, 'trace-fixture')
      assert(envelope and providerError == nil and envelope.data.items[1].migration == '001_first')
      return table.concat({
        first.items[2].finding,
        second.items[1].finding,
        third.items[1].finding,
        tostring(#first.columns)
      }, ':')
    `);
    assert.equal(result, 'CHECKSUM_MISMATCH:MISSING_MIGRATION:SCHEMA_DRIFT:10');
  } finally {
    engine.global.close();
  }
});

test('Core exposes migrations as a list view and Control contains no SQL console path', async () => {
  const [controlShared, controlQueries, diagnosticsRoot, controlServer, controlProtocol] = await Promise.all([
    source('core/synex_core/server/bootstrap_diagnostics_control_shared.lua'),
    source('core/synex_core/server/bootstrap_diagnostics_control_queries.lua'),
    source('core/synex_core/server/bootstrap_diagnostics.lua'),
    source('resources/synex_control/server/server.lua'),
    source('resources/synex_control/server/request_protocol.lua'),
  ]);
  const diagnostics = `${controlShared}\n${controlQueries}\n${diagnosticsRoot}`;
  const listStart = diagnostics.indexOf('local coreListViews = {');
  const inspectStart = diagnostics.indexOf('local coreInspectViews = {');
  const inspectEnd = diagnostics.indexOf('local coreInspectIdViews = {');
  assert.ok(listStart >= 0 && inspectStart > listStart && inspectEnd > inspectStart);
  assert.match(diagnostics.slice(listStart, inspectStart), /migrations = true/u);
  assert.doesNotMatch(diagnostics.slice(inspectStart, inspectEnd), /migrations = true/u);
  assert.match(
    diagnostics,
    /\{ id = 'migrations', label = 'Migrations', operation = 'list', presentation = 'table'/u,
  );
  assert.match(diagnostics, /persistence\.migrations:details\(\{/u);
  assert.doesNotMatch(`${controlServer}\n${controlProtocol}`, /\b(?:SELECT|UPDATE|DELETE|DROP)\b\s+[\s\S]{0,80}\b(?:FROM|TABLE|SET)\b/iu);
});
