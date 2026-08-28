import assert from 'node:assert/strict';
import test from 'node:test';
import { runWorldLua } from './helpers.ts';

test('compiler accepts only closed bounded structured state schemas and defaults', async () => {
  const result = await runWorldLua<string>(String.raw`
    local function definition()
      return {
        kind = 'world_state_definition', key = 'synex_test:profile',
        stateType = 'structured', scope = 'global', persistence = 'runtime',
        schemaVersion = 1,
        structuredSchema = {
          type = 'object', maximumBytes = 256, maximumDepth = 3, maximumEntries = 10,
          properties = {
            enabled = { type = 'boolean' },
            count = { type = 'integer', minimum = 0, maximum = 10 },
            label = { type = 'string', maxLength = 12 },
            mode = { type = 'enum', allowed = { 'active', 'idle' } },
            flags = { type = 'array', maximumItems = 2,
              items = { type = 'boolean' } },
            nested = { type = 'object', properties = {
                name = { type = 'string', maxLength = 8 },
              }, required = { 'name' }, additionalProperties = false },
          },
          required = { 'enabled', 'count' }, additionalProperties = false,
        },
        default = { enabled = false, count = 0, mode = 'idle',
          flags = { true }, nested = { name = 'safe' } },
      }
    end
    local function bundle(state)
      return { schema = 1, key = 'synex_test:states', version = '1.0.0',
        dependencies = {}, objects = { state } }
    end
    local compiled = assert(SynexWorldCompiler.compileBundle(bundle(definition()), 'synex_test', 1))
    local schema = compiled.objects['synex_test:profile'].structuredSchema
    assert(schema.additionalProperties == false and schema.properties.count.type == 'integer')

    local missing = definition()
    missing.default = { enabled = true }
    local _, missingError = SynexWorldCompiler.compileBundle(bundle(missing), 'synex_test', 1)
    assert(missingError.code == 'WORLD_STATE_SCHEMA_INVALID')

    local undeclared = definition()
    undeclared.default.extra = true
    local _, undeclaredError = SynexWorldCompiler.compileBundle(bundle(undeclared), 'synex_test', 1)
    assert(undeclaredError.code == 'WORLD_STATE_SCHEMA_INVALID')

    local wrong = definition()
    wrong.default.count = 'two'
    local _, wrongError = SynexWorldCompiler.compileBundle(bundle(wrong), 'synex_test', 1)
    assert(wrongError.code == 'WORLD_STATE_SCHEMA_INVALID')

    local unknown = definition()
    unknown.structuredSchema.properties.enabled.description = 'not allowed'
    local _, unknownError = SynexWorldCompiler.compileBundle(bundle(unknown), 'synex_test', 1)
    assert(unknownError.code == 'WORLD_STATE_SCHEMA_INVALID')

    local deep = definition()
    deep.structuredSchema.maximumDepth = 1
    local _, deepError = SynexWorldCompiler.compileBundle(bundle(deep), 'synex_test', 1)
    assert(deepError.code == 'WORLD_STATE_SCHEMA_INVALID')

    local badRequired = definition()
    badRequired.structuredSchema.required = { 'missing' }
    local _, requiredError = SynexWorldCompiler.compileBundle(bundle(badRequired), 'synex_test', 1)
    assert(requiredError.code == 'WORLD_STATE_SCHEMA_INVALID')
    return table.concat({ missingError.code, undeclaredError.code, wrongError.code,
      unknownError.code, deepError.code, requiredError.code }, ':')
  `);
  assert.equal(result, Array(6).fill('WORLD_STATE_SCHEMA_INVALID').join(':'));
});
