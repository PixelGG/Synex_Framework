import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';

const root = process.cwd();

test('compatibility identities preserve imported values and allocate one stable runtime mapping', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    const source = await readFile(
      path.join(root, 'libraries/synex_bridge/identity_store.lua'), 'utf8',
    );
    await engine.doString(`
      local identities = {
        ['qb:citizenid:character_imported_0001'] = {
          legacy_identifier = 'OLD-CITIZEN-42', import_source = 'qb_import'
        }
      }
      writes = 0
      database = {}
      function database.read(request)
        local provider, identifierType, characterId =
          request.parameters[1], request.parameters[2], request.parameters[3]
        local row = identities[provider .. ':' .. identifierType .. ':' .. characterId]
        return row and { row } or {}, nil
      end
      function database.write(request)
        writes = writes + 1
        local provider, identifierType, legacyIdentifier, characterId =
          request.parameters[1], request.parameters[2],
          request.parameters[3], request.parameters[4]
        local key = provider .. ':' .. identifierType .. ':' .. characterId
        if not identities[key] then
          identities[key] = {
            legacy_identifier = legacyIdentifier,
            import_source = 'runtime_generated'
          }
        end
        return { affectedRows = 1 }, nil
      end
      function database.transaction() error('not used') end
      exports = {}
      json = {
        encode = function() return '{}' end,
        decode = function() return {} end
      }
    `);
    await engine.doString(source);
    const result = await engine.doString(`
      local store = SynexBridgeIdentityStore.create({
        getApi = function() return { Database = database }, nil end,
        jsonEncode = json.encode, jsonDecode = json.decode
      })
      local imported, importError = store:resolve(
        'qb', 'citizenid', 'character_imported_0001')
      assert(imported, importError and importError.code or 'identity import failed')
      assert(imported.identifier == 'OLD-CITIZEN-42'
        and imported.importSource == 'qb_import')

      local first, firstError = store:resolve(
        'qbx', 'citizenid', 'character_runtime_0002')
      assert(first, firstError and firstError.code or 'identity allocation failed')
      local second, secondError = store:resolve(
        'qbx', 'citizenid', 'character_runtime_0002')
      assert(second, secondError and secondError.code or 'identity replay failed')
      assert(first.identifier == second.identifier)
      assert(first.identifier:match('^SX[0-9A-F]+$') and #first.identifier == 18)
      assert(writes == 1)

      local invalid, invalidError = store:resolve(
        'unknown', 'citizenid', 'character_runtime_0002')
      assert(invalid == nil and invalidError.code == 'COMPAT_VALIDATION_FAILED')
      return imported.identifier .. ':' .. first.identifier .. ':' .. writes
    `);
    assert.match(String(result), /^OLD-CITIZEN-42:SX[0-9A-F]{16}:1$/u);
  } finally {
    engine.global.close();
  }
});

test('compatibility metadata is bounded, versioned with CAS, and deleted transactionally', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    const source = await readFile(
      path.join(root, 'libraries/synex_bridge/identity_store.lua'), 'utf8',
    );
    await engine.doString(`
      local metadata = {}
      deletedMetadata, deletedIdentities = 0, 0
      database = {}
      function database.read(request)
        if request.sql:find('synex_compatibility_metadata', 1, true) then
          local prefix = request.parameters[1] .. ':' .. request.parameters[2] .. ':'
          local rows = {}
          for key, row in pairs(metadata) do
            if key:sub(1, #prefix) == prefix then rows[#rows + 1] = row end
          end
          table.sort(rows, function(a, b) return a.metadata_key < b.metadata_key end)
          return rows, nil
        end
        return {}, nil
      end
      function database.write() return { affectedRows = 1 }, nil end
      function database.transaction(request, handler)
        local tx = {}
        function tx.one(sql, parameters)
          local key = parameters[1] .. ':' .. parameters[2] .. ':' .. parameters[3]
          local row = metadata[key]
          return row and { version = row.version } or nil
        end
        function tx.affected(sql, parameters)
          if sql:find('INSERT INTO', 1, true) then
            local key = parameters[1] .. ':' .. parameters[2] .. ':' .. parameters[3]
            if metadata[key] then return 0 end
            metadata[key] = {
              metadata_key = parameters[3], value_json = parameters[4], version = 1
            }
            return 1
          end
          if sql:find('UPDATE', 1, true) then
            local key = parameters[2] .. ':' .. parameters[3] .. ':' .. parameters[4]
            local row = metadata[key]
            if not row or row.version ~= parameters[5] then return 0 end
            row.value_json = parameters[1]
            row.version = row.version + 1
            return 1
          end
          if sql:find('synex_compatibility_metadata', 1, true) then
            deletedMetadata = deletedMetadata + 1
            return 1
          end
          deletedIdentities = deletedIdentities + 1
          return 1
        end
        return handler(tx)
      end
      json = {
        encode = function(value)
          if value == 'enabled' then return '"enabled"' end
          return '{}'
        end,
        decode = function(value)
          if value == '"enabled"' then return 'enabled' end
          return {}
        end
      }
    `);
    await engine.doString(source);
    const result = await engine.doString(`
      local store = SynexBridgeIdentityStore.create({
        getApi = function() return { Database = database }, nil end,
        jsonEncode = json.encode, jsonDecode = json.decode
      })
      local inserted, insertError = store:setMetadata(
        'qb', 'character_runtime_0002', 'hunger', 'enabled')
      assert(inserted, insertError and insertError.code or 'metadata insert failed')
      assert(inserted.version == 1)
      local updated = assert(store:setMetadata(
        'qb', 'character_runtime_0002', 'hunger', 'enabled', 1))
      assert(updated.version == 2)
      local conflict, conflictError = store:setMetadata(
        'qb', 'character_runtime_0002', 'hunger', 'enabled', 1)
      assert(conflict == nil and conflictError.code == 'COMPAT_WRITE_CONFLICT')
      local snapshot = assert(store:listMetadata('qb', 'character_runtime_0002'))
      assert(snapshot.values.hunger == 'enabled' and snapshot.versions.hunger == 2)
      local deletion = assert(store:deleteCharacter(
        'delete_plan_0001', 'character_runtime_0002'))
      assert(deletion.metadataDeleted == 1 and deletion.identitiesDeleted == 1)
      return table.concat({
        inserted.version, updated.version, snapshot.versions.hunger,
        deletedMetadata, deletedIdentities
      }, ':')
    `);
    assert.equal(result, '1:2:2:1:1');
  } finally {
    engine.global.close();
  }
});

test('compatibility persistence migration owns only identity and metadata tables with uniqueness and JSON constraints', async () => {
  const [migration, descriptor] = await Promise.all([
    readFile(path.join(
      root,
      'libraries/synex_bridge/migrations/001_compatibility_identity_metadata.sql',
    ), 'utf8'),
    readFile(path.join(root, 'libraries/synex_bridge/synex.resource.json'), 'utf8'),
  ]);
  const manifest = JSON.parse(descriptor) as {
    migrations: Array<{ id: string; path: string }>;
    dataOwnership: { tables: string[]; characterDelete: string };
  };
  assert.match(migration, /uq_compat_identity_legacy/u);
  assert.match(migration, /uq_compat_identity_character/u);
  assert.match(migration, /CHECK \(JSON_VALID\(`value_json`\)\)/u);
  assert.deepEqual(manifest.dataOwnership.tables.sort(), [
    'synex_compatibility_identities',
    'synex_compatibility_metadata',
  ]);
  assert.equal(manifest.dataOwnership.characterDelete, 'delete');
  assert.equal(manifest.migrations[0]?.id, '001_compatibility_identity_metadata');
});
