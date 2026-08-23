import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory, type LuaEngine } from 'wasmoon';
import { Ajv2020 } from 'ajv/dist/2020.js';

const root = process.cwd();

async function load(engine: LuaEngine, relativePath: string): Promise<void> {
  await engine.doString(await readFile(path.join(root, relativePath), 'utf8'));
}

async function createEngine(): Promise<LuaEngine> {
  const engine = await new LuaFactory().createEngine();
  await load(engine, 'core/synex_core/shared/protocol.lua');
  await load(engine, 'core/synex_core/server/factories.lua');
  for (const file of ['foundation', 'registries', 'contracts', 'security', 'state']) {
    await load(engine, `core/synex_core/server/${file}.lua`);
  }
  await engine.doString(`
    local now = 1000
    FakePlatform = {
      nowGame = function() now = now + 1 return now end,
      random = function(_, maximum) return math.min(maximum or 1, 123456) end,
      print = function() end,
      jsonEncode = function() return '{}' end,
      jsonDecode = function() return {} end,
      setTimeout = function(_, callback) callback() end
    }

    function NewStateDefinitionFixture(replicationEnabled, limits)
      limits = limits or {}
      local foundation = SynexCoreFactories.foundation({ platform = FakePlatform })
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      registries.owners:activate('synex_core')
      local ownerEpoch = registries.owners:activate('synex_fixture')
      local contracts = SynexCoreFactories.contracts({
        foundation = foundation,
        protocol = SynexProtocol
      })
      local security = SynexCoreFactories.security({
        platform = FakePlatform,
        foundation = foundation,
        coreResource = 'synex_core',
        policy = { default = { allow = {}, deny = {} }, resources = {} }
      })
      local state = SynexCoreFactories.state({
        platform = FakePlatform,
        foundation = foundation,
        contracts = contracts,
        owners = registries.owners,
        security = security,
        coreResource = 'synex_core',
        replicationEnabled = replicationEnabled,
        replicate = function() return true end,
        maximumDefinitions = limits.maximumDefinitions,
        maximumDefinitionsPerOwner = limits.maximumDefinitionsPerOwner,
        maximumValues = limits.maximumValues,
        maximumValuesPerOwner = limits.maximumValuesPerOwner,
        maximumValueBytes = limits.maximumValueBytes,
        maximumValueBytesPerOwner = limits.maximumValueBytesPerOwner
      })
      return {
        state = state,
        owners = registries.owners,
        ownerEpoch = ownerEpoch
      }
    end
  `);
  return engine;
}

test('runtime state definitions are closed and security booleans cannot bypass policy', async () => {
  const engine = await createEngine();
  const result = await engine.doString(`
    local disabled = NewStateDefinitionFixture(false)
    local function definition()
      return {
        ['$schema'] = 'https://synex.dev/schemas/state.schema.json',
        name = 'synex_fixture.status',
        scope = 'global',
        authority = 'owner',
        schema = { type = 'boolean' }
      }
    end
    local function rejected(value, expectedCode)
      local token, rejection = disabled.state:define(
        'synex_fixture', disabled.ownerEpoch, value)
      assert(token == nil and rejection.code == expectedCode)
      assert(disabled.state:snapshot().definitions[value.name] == nil)
    end

    local candidate = definition()
    candidate.untracked = true
    rejected(candidate, 'INVALID_STATE_DEFINITION')
    candidate = definition()
    candidate['$schema'] = false
    rejected(candidate, 'INVALID_STATE_DEFINITION')
    candidate = definition()
    candidate.sensitive = 'true'
    candidate.replicated = true
    rejected(candidate, 'INVALID_STATE_DEFINITION')
    candidate = definition()
    candidate.replicated = 'false'
    rejected(candidate, 'INVALID_STATE_DEFINITION')
    candidate = definition()
    candidate.persistent = 1
    rejected(candidate, 'INVALID_STATE_DEFINITION')
    for _, maximumBytes in ipairs({0, 16385, 1.5, '4096'}) do
      candidate = definition()
      candidate.maximumBytes = maximumBytes
      rejected(candidate, 'INVALID_STATE_DEFINITION')
    end
    candidate = definition()
    candidate.replicated = true
    rejected(candidate, 'FEATURE_DISABLED')

    local enabled = NewStateDefinitionFixture(true)
    candidate = definition()
    candidate.sensitive = true
    candidate.replicated = true
    local sensitiveToken, sensitiveError = enabled.state:define(
      'synex_fixture', enabled.ownerEpoch, candidate)
    assert(sensitiveToken == nil and sensitiveError.code == 'SENSITIVE_STATE_REPLICATION')

    candidate = definition()
    candidate.replicated = true
    candidate.sensitive = false
    candidate.persistent = false
    candidate.maximumBytes = 1024
    assert(enabled.state:define('synex_fixture', enabled.ownerEpoch, candidate))
    candidate.name = 'synex_fixture.mutated_after_registration'
    assert(enabled.state:snapshot().definitions['synex_fixture.status'] ~= nil)
    local cleanup = enabled.owners:purge('synex_fixture', enabled.ownerEpoch, 'test cleanup')
    assert(#cleanup.errors == 0)
    assert(enabled.state:snapshot().definitions['synex_fixture.status'] == nil)
    return sensitiveError.code
  `);
  assert.equal(result, 'SENSITIVE_STATE_REPLICATION');
  engine.global.close();
});

test('runtime rejects malformed cyclic and oversized schemas without destabilizing state access', async () => {
  const engine = await createEngine();
  const result = await engine.doString(`
    local fixture = NewStateDefinitionFixture(true)
    local sequence = 0
    local function rejected(schema)
      sequence = sequence + 1
      local callOk, token, rejection = pcall(function()
        return fixture.state:define('synex_fixture', fixture.ownerEpoch, {
          name = 'synex_fixture.invalid_' .. tostring(sequence),
          scope = 'global',
          authority = 'owner',
          schema = schema
        })
      end)
      assert(callOk and token == nil and rejection.code == 'INVALID_STATE_DEFINITION',
        'invalid state schema #' .. tostring(sequence) .. ' was not rejected')
    end

    rejected({ required = 'value' })
    rejected({ type = 'string', pattern = {} })
    rejected({ type = 'object', properties = { value = 'invalid' } })
    rejected({ type = 'array', items = 'invalid' })
    rejected({ type = 'object', additionalProperties = 'false' })
    rejected({ type = 'string', minLength = '1' })
    rejected({ type = 'unsupported' })
    local sparse = {}
    sparse[2] = { type = 'string' }
    rejected({ oneOf = sparse })
    local cyclic = { type = 'object' }
    cyclic.properties = { self = cyclic }
    rejected(cyclic)
    local deep = { type = 'object' }
    local cursor = deep
    for _ = 1, 30 do
      cursor.properties = { child = { type = 'object' } }
      cursor = cursor.properties.child
    end
    rejected(deep)
    rejected({ type = 'string', description = string.rep('x', 33000) })
    rejected(setmetatable({ type = 'string' }, {}))

    assert(fixture.state:define('synex_fixture', fixture.ownerEpoch, {
      name = 'synex_fixture.profile',
      scope = 'global',
      authority = 'owner',
      schema = {
        type = 'object',
        additionalProperties = false,
        required = {'label', 'count'},
        properties = {
          label = { type = 'string', minLength = 1, maxLength = 32, pattern = '^[a-z]+$' },
          count = { type = 'integer', minimum = 0, maximum = 10 },
          tags = { type = 'array', maxItems = 3, items = { type = 'string', maxLength = 8 } }
        }
      }
    }))
    assert(fixture.state:set('synex_fixture', fixture.ownerEpoch, 'synex_fixture.profile', nil, {
      label = 'ready', count = 2, tags = {'core', 'safe'}
    }))
    local current = assert(fixture.state:get(
      'synex_fixture', fixture.ownerEpoch, 'synex_fixture.profile', nil))
    assert(current.label == 'ready' and current.count == 2 and #current.tags == 2)

    assert(fixture.state:define('synex_fixture', fixture.ownerEpoch, {
      name = 'synex_fixture.unstructured',
      scope = 'global',
      authority = 'owner',
      schema = {}
    }))
    local oversizedValue = {}
    cursor = oversizedValue
    for _ = 1, 40 do
      cursor.child = {}
      cursor = cursor.child
    end
    local callOk, stored, storeError = pcall(function()
      return fixture.state:set(
        'synex_fixture', fixture.ownerEpoch, 'synex_fixture.unstructured', nil, oversizedValue)
    end)
    assert(callOk and stored == nil and storeError.code == 'VALIDATION_FAILED')
    return table.concat({sequence, current.label, storeError.code}, ':')
  `);
  assert.equal(result, '12:ready:VALIDATION_FAILED');
  engine.global.close();
});

test('state registries bound definitions, subjects, values, and retained bytes with cleanup recovery', async () => {
  const engine = await createEngine();
  const result = await engine.doString(`
    local definitions = NewStateDefinitionFixture(true, {
      maximumDefinitions = 3,
      maximumDefinitionsPerOwner = 2
    })
    local function definition(name, scope, maximumBytes)
      return {
        name = name,
        scope = scope,
        authority = 'owner',
        maximumBytes = maximumBytes or 128,
        schema = { type = 'string', minLength = 1, maxLength = 512 }
      }
    end
    assert(definitions.state:define('synex_fixture', definitions.ownerEpoch,
      definition('synex_fixture.first', 'global')))
    assert(definitions.state:define('synex_fixture', definitions.ownerEpoch,
      definition('synex_fixture.second', 'global')))
    local third, thirdError = definitions.state:define(
      'synex_fixture', definitions.ownerEpoch,
      definition('synex_fixture.third', 'global'))
    assert(third == nil and thirdError.code == 'STATE_DEFINITION_LIMIT')
    assert(definitions.state:snapshot().storage.definitions == 2)
    local purgedDefinitions = definitions.owners:purge(
      'synex_fixture', definitions.ownerEpoch, 'definition capacity test')
    assert(#purgedDefinitions.errors == 0)
    assert(definitions.state:snapshot().storage.definitions == 0)

    local values = NewStateDefinitionFixture(true, {
      maximumDefinitions = 8,
      maximumDefinitionsPerOwner = 8,
      maximumValues = 3,
      maximumValuesPerOwner = 2,
      maximumValueBytes = 1024,
      maximumValueBytesPerOwner = 512
    })
    local secondEpoch = values.owners:activate('synex_second')
    assert(values.state:define('synex_fixture', values.ownerEpoch,
      definition('synex_fixture.entity_state', 'entity')))
    assert(values.state:define('synex_fixture', values.ownerEpoch,
      definition('synex_fixture.character_state', 'character')))
    assert(values.state:define('synex_second', secondEpoch,
      definition('synex_second.entity_state', 'entity')))

    for _, invalidSubject in ipairs({string.rep('x', 65), 'bad/subject', '', -1, 1.5}) do
      local stored, subjectError = values.state:set('synex_fixture', values.ownerEpoch,
        'synex_fixture.entity_state', invalidSubject, 'value')
      assert(stored == nil and subjectError.code == 'INVALID_STATE_SUBJECT')
    end
    for _, invalidSubject in ipairs({string.rep('x', 37), 'bad/character', ''}) do
      local stored, subjectError = values.state:set('synex_fixture', values.ownerEpoch,
        'synex_fixture.character_state', invalidSubject, 'value')
      assert(stored == nil and subjectError.code == 'INVALID_STATE_SUBJECT')
    end
    local oversized, oversizedError = values.state:set('synex_fixture', values.ownerEpoch,
      'synex_fixture.entity_state', 'entity_large', string.rep('x', 200))
    assert(oversized == nil and oversizedError.code == 'STATE_PAYLOAD_TOO_LARGE')

    assert(values.state:set('synex_fixture', values.ownerEpoch,
      'synex_fixture.entity_state', 'entity_1', 'first'))
    assert(values.state:set('synex_fixture', values.ownerEpoch,
      'synex_fixture.character_state', 'char_1', 'second'))
    assert(values.state:set('synex_fixture', values.ownerEpoch,
      'synex_fixture.entity_state', 'entity_1', 'updated'))
    local ownerOverflow, ownerOverflowError = values.state:set(
      'synex_fixture', values.ownerEpoch,
      'synex_fixture.entity_state', 'entity_2', 'third')
    assert(ownerOverflow == nil and ownerOverflowError.code == 'STATE_STORAGE_LIMIT')
    assert(values.state:set('synex_second', secondEpoch,
      'synex_second.entity_state', 'entity_3', 'third'))
    local globalOverflow, globalOverflowError = values.state:set(
      'synex_second', secondEpoch,
      'synex_second.entity_state', 'entity_4', 'fourth')
    assert(globalOverflow == nil and globalOverflowError.code == 'STATE_STORAGE_LIMIT')
    local cleared = assert(values.state:clear('synex_fixture', values.ownerEpoch,
      'synex_fixture.entity_state', 'entity_1'))
    assert(cleared.cleared == true)
    assert(values.state:set('synex_fixture', values.ownerEpoch,
      'synex_fixture.entity_state', 'entity_2', 'third'))
    local subjectPurge = assert(values.state:purgeSubject('character', 'char_1'))
    assert(subjectPurge.cleared == 1)
    assert(values.state:set('synex_fixture', values.ownerEpoch,
      'synex_fixture.entity_state', 'entity_4', 'fourth'))
    local valueSnapshot = values.state:snapshot()
    assert(valueSnapshot.storage.values == 3 and valueSnapshot.storage.bytes > 0)
    local purgedValues = values.owners:purge(
      'synex_fixture', values.ownerEpoch, 'value capacity test')
    assert(#purgedValues.errors == 0)
    valueSnapshot = values.state:snapshot()
    assert(valueSnapshot.storage.values == 1 and valueSnapshot.storage.bytes > 0)

    local bytes = NewStateDefinitionFixture(true, {
      maximumValues = 10,
      maximumValuesPerOwner = 10,
      maximumValueBytes = 512,
      maximumValueBytesPerOwner = 128
    })
    assert(bytes.state:define('synex_fixture', bytes.ownerEpoch,
      definition('synex_fixture.byte_state', 'entity', 128)))
    assert(bytes.state:set('synex_fixture', bytes.ownerEpoch,
      'synex_fixture.byte_state', 'one', string.rep('x', 70)))
    local byteOverflow, byteOverflowError = bytes.state:set(
      'synex_fixture', bytes.ownerEpoch,
      'synex_fixture.byte_state', 'two', string.rep('y', 70))
    assert(byteOverflow == nil and byteOverflowError.code == 'STATE_STORAGE_LIMIT')
    assert(bytes.state:set('synex_fixture', bytes.ownerEpoch,
      'synex_fixture.byte_state', 'one', 'small'))
    assert(bytes.state:set('synex_fixture', bytes.ownerEpoch,
      'synex_fixture.byte_state', 'two', string.rep('y', 70)))
    local byteSnapshot = bytes.state:snapshot()
    assert(byteSnapshot.storage.values == 2 and byteSnapshot.storage.bytes <= 128)
    return table.concat({
      thirdError.code,
      ownerOverflowError.code,
      globalOverflowError.code,
      byteOverflowError.code,
      valueSnapshot.storage.values,
      byteSnapshot.storage.values
    }, ':')
  `);
  assert.equal(result,
    'STATE_DEFINITION_LIMIT:STATE_STORAGE_LIMIT:STATE_STORAGE_LIMIT:STATE_STORAGE_LIMIT:1:2');
  engine.global.close();
});

test('canonical state schema matches runtime definition fields and byte limits', async () => {
  const canonicalSchema = JSON.parse(
    await readFile(path.join(root, 'schemas/state.schema.json'), 'utf8'),
  ) as object;
  const validate = new Ajv2020({ allErrors: true, strict: true, validateFormats: false })
    .compile(canonicalSchema);
  const definition = {
    $schema: 'https://synex.dev/schemas/state.schema.json',
    name: 'synex_fixture.status',
    scope: 'global',
    authority: 'owner',
    schema: { type: 'boolean' },
    sensitive: false,
    replicated: true,
    persistent: false,
    maximumBytes: 16384,
  };
  assert.equal(validate(definition), true);
  assert.equal(validate({ ...definition, maximumBytes: 0 }), false);
  assert.equal(validate({ ...definition, maximumBytes: 16385 }), false);
  assert.equal(validate({ ...definition, maximumBytes: '4096' }), false);
  assert.equal(validate({ ...definition, sensitive: 'false' }), false);
  assert.equal(validate({ ...definition, untracked: true }), false);
});
