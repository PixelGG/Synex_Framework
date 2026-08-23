import assert from 'node:assert/strict';
import { Ajv2020 } from 'ajv/dist/2020.js';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory, type LuaEngine } from 'wasmoon';

const root = process.cwd();

async function load(engine: LuaEngine, relativePath: string): Promise<void> {
  await engine.doString(await readFile(path.join(root, relativePath), 'utf8'));
}

async function createEngine(files: string[]): Promise<LuaEngine> {
  const engine = await new LuaFactory().createEngine();
  await load(engine, 'core/synex_core/shared/protocol.lua');
  await load(engine, 'core/synex_core/server/factories.lua');
  for (const file of files) await load(engine, `core/synex_core/server/${file}.lua`);
  await engine.doString(`
    local now = 1000
    FakePlatform = {
      nowGame = function() now = now + 1 return now end,
      random = function(_, maximum) return math.min(maximum or 1, 123456) end,
      print = function() end,
      jsonEncode = function() return '{}' end,
      jsonDecode = function() return {} end,
      loadResourceFile = function() return nil end,
      setTimeout = function(_, callback) callback() end,
      resourceState = function() return 'started' end
    }
  `);
  return engine;
}

function collectPatterns(value: unknown, output = new Set<string>()): Set<string> {
  if (Array.isArray(value)) {
    for (const item of value) collectPatterns(item, output);
  } else if (value !== null && typeof value === 'object') {
    for (const [key, item] of Object.entries(value)) {
      if (key === 'pattern' && typeof item === 'string') output.add(item);
      collectPatterns(item, output);
    }
  }
  return output;
}

test('bounded ECMAScript subset matches JavaScript for every generated contract pattern', async () => {
  const runtime = JSON.parse(
    await readFile(path.join(root, 'packages/contracts/generated/runtime/contracts.json'), 'utf8'),
  ) as unknown;
  const generatedPatterns = [...collectPatterns(runtime)].sort();
  assert.ok(generatedPatterns.length > 0);
  const patterns = [...new Set([
    ...generatedPatterns,
    '^a\\.b\\+c\\?$',
    '^a.+z$',
    '^[^0-9]{1,3}$',
    '^ab?c*$',
    '^x{0}y{2,4}$',
    'b+',
    '^abc$',
  ])];
  const corpus = [
    '', 'a', 'ab', 'abc', 'abc_123', 'a'.repeat(64), 'a'.repeat(65),
    '01234567-89ab-cdef-0123-456789abcdef',
    '01234567-89AB-CDEF-0123-456789ABCDEF',
    'a{36}', 'A9.node:slot%branch-1', '-bad', 'bad/slash',
    'a.b+c?', 'abcz', 'a🚀z', 'abc\n', 'abc\r\n', 'é', 'é🚀',
    '12', 'xy', 'yyy', 'yyyy', 'xyyyy', 'bbb', 'cabbd',
  ];
  const cases = patterns.flatMap((patternValue) =>
    corpus.map((value) => ({ pattern: patternValue, value })),
  );
  assert.equal(new RegExp('^abc$', 'u').test('abc\n'), false);
  assert.equal(new RegExp('^abc$', 'u').test('abc\r\n'), false);
  const validators = new Map(patterns.map((patternValue) => [
    patternValue,
    new Ajv2020({ strict: true, validateFormats: false }).compile({ type: 'string', pattern: patternValue }),
  ]));
  const expected = cases
    .map((entry) => {
      const regexpResult = new RegExp(entry.pattern, 'u').test(entry.value);
      const ajvResult = validators.get(entry.pattern)?.(entry.value) === true;
      assert.equal(ajvResult, regexpResult, `Ajv/RegExp parity for ${entry.pattern}`);
      return ajvResult ? '1' : '0';
    })
    .join('');
  const luaCases = cases
    .map((entry) => `{ pattern = ${JSON.stringify(entry.pattern)}, value = ${JSON.stringify(entry.value)} }`)
    .join(',\n');
  const engine = await createEngine(['foundation', 'contracts']);
  try {
    const actual = await engine.doString(`
      local foundation = SynexCoreFactories.foundation({ platform = FakePlatform })
      local contracts = SynexCoreFactories.contracts({ foundation = foundation, protocol = SynexProtocol })
      local cases = { ${luaCases} }
      local results = {}
      for index, item in ipairs(cases) do
        local valid = contracts.validate({ type = 'string', pattern = item.pattern }, item.value)
        results[index] = valid and '1' or '0'
      end
      return table.concat(results)
    `);
    assert.equal(actual.length, expected.length);
    for (let index = 0; index < cases.length; index += 1) {
      assert.equal(
        actual[index],
        expected[index],
        `${cases[index]?.pattern} against ${JSON.stringify(cases[index]?.value)}`,
      );
    }
  } finally {
    engine.global.close();
  }
});

test('schema validation counts Unicode codepoints and rejects invalid UTF-8 and unsupported assertions', async () => {
  const engine = await createEngine(['foundation', 'contracts']);
  try {
    const result = await engine.doString(`
      local foundation = SynexCoreFactories.foundation({ platform = FakePlatform })
      local contracts = SynexCoreFactories.contracts({ foundation = foundation, protocol = SynexProtocol })
      assert(contracts.validate({ type = 'string', minLength = 2, maxLength = 2 }, 'é🚀'))
      local short, shortFinding = contracts.validate({ type = 'string', minLength = 2 }, '🚀')
      assert(short == nil and shortFinding.rule == 'minLength')
      assert(contracts.validate({ type = 'string', pattern = '^..$' }, 'é🚀'))
      assert(contracts.validate({ type = {'array', 'null'} }, {'a', 'b'}))
      assert(contracts.validate({}, {{'nested', 'array'}}))
      assert(contracts.validate({ type = {'array', 'object'} }, {'union', 'array'}))
      local arrayAsObject, objectFinding = contracts.validate({ type = 'object' }, {'a'})
      assert(arrayAsObject == nil and objectFinding.rule == 'type')
      local combinedAlternatives = {
        oneOf = {{ type = 'string' }, { type = 'number' }},
        anyOf = {{ type = 'string', pattern = '^a' }, { type = 'integer', minimum = 10 }}
      }
      assert(contracts.validate(combinedAlternatives, 'abc'))
      local missedAnyOf, anyOfFinding = contracts.validate(combinedAlternatives, 'xbc')
      assert(missedAnyOf == nil and anyOfFinding.rule == 'anyOf')
      local invalidUtf8, utf8Finding = contracts.validate(
        { type = 'string', minLength = 1 }, string.char(0xc3, 0x28))
      assert(invalidUtf8 == nil and utf8Finding.rule == 'utf8')

      local supported = assert(contracts.validateSchemaDefinition({
        type = 'array', uniqueItems = true, maxItems = 4,
        items = { type = 'string', pattern = '^[a-z]+$' },
        title = 'Fixture', description = 'Supported annotation', readOnly = false
      }))
      assert(supported == true)
      local duplicate, duplicateFinding = contracts.validate(
        { type = 'array', uniqueItems = true, items = { type = 'string' } }, {'a', 'a'})
      assert(duplicate == nil and duplicateFinding.rule == 'uniqueItems')

      local unsupportedPattern, patternFinding = contracts.validatePattern('^(foo|bar)$')
      assert(unsupportedPattern == nil and patternFinding.rule == 'unsupportedPattern')
      assert(contracts.validatePattern('^a{257}$') == nil)
      assert(contracts.validatePattern('^a{1,}$') == nil)
      assert(contracts.validatePattern(string.rep('a', 65)) == nil)
      assert(contracts.validatePattern('^a{64}$'))
      assert(contracts.validatePattern(string.rep('a', 17)) == nil)
      assert(contracts.validatePattern('^' .. string.rep('a*', 9) .. '$') == nil)
      assert(contracts.validate({ type = 'string', pattern = '^a*$' }, string.rep('a', 16384)))
      local expensivePattern, expensivePatternFinding = contracts.validate(
        { type = 'string', pattern = '^a*a*a*a*a*a*a*a*$' }, string.rep('a', 16384))
      assert(expensivePattern == nil and expensivePatternFinding.rule == 'patternBudget')
      local newlineEnd, newlineEndFinding = contracts.validate(
        { type = 'string', pattern = '^abc$' }, string.char(97, 98, 99, 10))
      assert(newlineEnd == nil and newlineEndFinding.rule == 'pattern')

      local metatableInput, metatableFinding = contracts.validate(
        {}, setmetatable({}, { __pairs = function() error('must not execute') end }))
      assert(metatableInput == nil and metatableFinding.rule == 'plainJson')
      local nestedMetatableInput, nestedMetatableFinding = contracts.validate(
        {}, { child = setmetatable({}, { __index = function() error('must not execute') end }) })
      assert(nestedMetatableInput == nil and nestedMetatableFinding.rule == 'plainJson')
      local cyclic = {}
      cyclic.self = cyclic
      local cyclicInput, cyclicFinding = contracts.validate({}, cyclic)
      assert(cyclicInput == nil and cyclicFinding.rule == 'cycle')
      local manyUnique = {}
      for index = 1, 33 do manyUnique[index] = index end
      local uniqueBudget, uniqueBudgetFinding = contracts.validate(
        { type = 'array', uniqueItems = true }, manyUnique)
      assert(uniqueBudget == nil and uniqueBudgetFinding.rule == 'validationBudget')
      local unsupportedSchema, schemaFinding = contracts.validateSchemaDefinition({
        type = 'string', allOf = {{ minLength = 1 }}
      })
      assert(unsupportedSchema == nil and schemaFinding.rule == 'unsupportedKeyword')
      local referencedSchema, referenceFinding = contracts.validateSchemaDefinition({ ['$ref'] = '#/$defs/value' })
      assert(referencedSchema == nil and referenceFinding.rule == 'unsupportedKeyword')
      local malformedRequired, requiredFinding = contracts.validateSchemaDefinition({ required = 'value' })
      assert(malformedRequired == nil and requiredFinding.rule == 'arrayShape')
      local unboundedUnique, unboundedUniqueFinding = contracts.validateSchemaDefinition({
        type = 'array', uniqueItems = true, items = { type = 'string' }
      })
      assert(unboundedUnique == nil and unboundedUniqueFinding.rule == 'maximum')
      return table.concat({ shortFinding.rule, utf8Finding.rule, duplicateFinding.rule,
        patternFinding.rule, schemaFinding.rule, referenceFinding.rule, requiredFinding.rule,
        expensivePatternFinding.rule, metatableFinding.rule, cyclicFinding.rule,
        uniqueBudgetFinding.rule, unboundedUniqueFinding.rule }, ':')
    `);
    assert.equal(
      result,
      'minLength:utf8:uniqueItems:unsupportedPattern:unsupportedKeyword:unsupportedKeyword:arrayShape:'
        + 'patternBudget:plainJson:cycle:validationBudget:maximum',
    );
  } finally {
    engine.global.close();
  }
});

test('contract definitions are immutable per version across handler cleanup and restart', async () => {
  const engine = await createEngine([
    'foundation', 'registries', 'lifecycle', 'contracts', 'security', 'messaging',
  ]);
  try {
    const result = await engine.doString(`
      local foundation = SynexCoreFactories.foundation({ platform = FakePlatform })
      foundation.configureIds('contract-runtime-hardening')
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      local owners = registries.owners
      owners:activate('synex_core')
      local providerEpoch = owners:activate('synex_provider')
      local consumerEpoch = owners:activate('synex_consumer')
      local lifecycle = SynexCoreFactories.lifecycle({
        platform = FakePlatform, foundation = foundation, owners = owners
      })
      local security = SynexCoreFactories.security({
        platform = FakePlatform, foundation = foundation, coreResource = 'synex_core',
        policy = { default = { allow = {}, deny = {} }, resources = {} }
      })
      local contracts = SynexCoreFactories.contracts({ foundation = foundation, protocol = SynexProtocol })
      local messaging = SynexCoreFactories.messaging({
        platform = FakePlatform, foundation = foundation, contracts = contracts,
        security = security, owners = owners, players = registries.players,
        lifecycle = lifecycle, dependencies = lifecycle.dependencies,
        protocol = SynexProtocol, config = {}, coreResource = 'synex_core'
      })
      local contract = {
        name = 'synex.fixture.echo', version = '1.0.0', provider = 'synex_provider',
        kind = 'rpc', stability = 'experimental', network = 'none', errors = {},
        input = {
          type = 'object', additionalProperties = false, required = {'id'},
          properties = { id = { type = 'string', pattern = '^[a-z]{3,8}$' } }
        },
        output = {
          type = 'object', additionalProperties = false, required = {'accepted'},
          properties = { accepted = { type = 'boolean' } }
        }
      }
      local canonical = assert(contracts.registry:register(contract))
      local identical = assert(contracts.registry:register(foundation.copy(contract)))
      assert(canonical.name == identical.name and canonical.major == 1 and identical.major == 1)
      assert(contracts.registry:register(canonical))
      assert(contracts.registry:resolve(contract.name, '^1.0.0'))
      for _, invalidVersion in ipairs({ false, 12, {}, string.rep('1', 129), '||1.0.0' }) do
        local invoked, resolved, resolveError = pcall(
          contracts.registry.resolve, contracts.registry, contract.name, invalidVersion)
        assert(invoked and resolved == nil and resolveError.code == 'INVALID_CONTRACT_VERSION')
      end
      local nilInvoked, nilResolved, nilResolveError = pcall(
        contracts.registry.resolve, contracts.registry, contract.name, nil)
      assert(nilInvoked and nilResolved == nil and nilResolveError.code == 'INVALID_CONTRACT_VERSION')
      local nameInvoked, nameResolved, nameResolveError = pcall(
        contracts.registry.resolve, contracts.registry, {}, '1.0.0')
      assert(nameInvoked and nameResolved == nil and nameResolveError.code == 'INVALID_CONTRACT')

      local inherited = setmetatable({}, { __index = contract })
      local inheritedResult, inheritedError = contracts.registry:register(inherited)
      assert(inheritedResult == nil and inheritedError.code == 'INVALID_CONTRACT')
      local unknown = foundation.copy(contract)
      unknown.undocumentedSecurityMode = true
      local unknownResult, unknownError = contracts.registry:register(unknown)
      assert(unknownResult == nil and unknownError.code == 'INVALID_CONTRACT')
      local cyclicDefinition = foundation.copy(contract)
      cyclicDefinition.extension = cyclicDefinition
      local cyclicResult, cyclicError = contracts.registry:register(cyclicDefinition)
      assert(cyclicResult == nil and cyclicError.code == 'INVALID_CONTRACT')
      local oversizedDefinition = foundation.copy(contract)
      oversizedDefinition.extension = {}
      for index = 1, 8193 do oversizedDefinition.extension['key_' .. index] = index end
      local oversizedInvoked, oversizedResult, oversizedError = pcall(
        contracts.registry.register, contracts.registry, oversizedDefinition)
      assert(oversizedInvoked and oversizedResult == nil and oversizedError.code == 'INVALID_CONTRACT')

      local securityDrift = foundation.copy(contract)
      securityDrift.capability = 'synex.fixture.admin'
      local drifted, driftError = contracts.registry:register(securityDrift)
      assert(drifted == nil and driftError.code == 'CONTRACT_DEFINITION_CONFLICT')
      local schemaDrift = foundation.copy(contract)
      schemaDrift.input.properties.id.maxLength = 64
      local schemaChanged, schemaError = contracts.registry:register(schemaDrift)
      assert(schemaChanged == nil and schemaError.code == 'CONTRACT_DEFINITION_CONFLICT')
      local networkDrift = foundation.copy(contract)
      networkDrift.network = 'client-to-server'
      local exposed, networkError = contracts.registry:register(networkDrift)
      assert(exposed == nil and networkError.code == 'CONTRACT_DEFINITION_CONFLICT')
      local ownershipDrift = foundation.copy(contract)
      ownershipDrift.provider = 'synex_other_provider'
      local reassigned, ownershipError = contracts.registry:register(ownershipDrift)
      assert(reassigned == nil and ownershipError.code == 'CONTRACT_DEFINITION_CONFLICT')

      local gatewayCandidate = foundation.copy(contract)
      assert(messaging.gateway:register('synex_provider', providerEpoch, gatewayCandidate, function(request)
        return { accepted = request.id == 'valid' }, nil
      end))
      gatewayCandidate.input.properties.id.pattern = '^x$'
      local value = assert(messaging.gateway:invoke(
        'synex_consumer', consumerEpoch, contract.name, contract.version, { id = 'valid' },
        { allowDuringBoot = true }
      ))
      assert(value.accepted == true)
      local invalid, invalidError = messaging.gateway:invoke(
        'synex_consumer', consumerEpoch, contract.name, contract.version, { id = 'x' },
        { allowDuringBoot = true }
      )
      assert(invalid == nil and invalidError.code == 'VALIDATION_FAILED')

      local cleanup = owners:purge('synex_provider', providerEpoch, 'fixture restart')
      assert(#cleanup.errors == 0)
      providerEpoch = owners:activate('synex_provider')
      local changedHandler, changedError = messaging.gateway:register(
        'synex_provider', providerEpoch, schemaDrift, function() return { accepted = true }, nil end)
      assert(changedHandler == nil and changedError.code == 'CONTRACT_DEFINITION_CONFLICT')
      assert(messaging.gateway:register(
        'synex_provider', providerEpoch, foundation.copy(contract),
        function() return { accepted = true }, nil end))
      return table.concat({ driftError.code, schemaError.code, networkError.code,
        ownershipError.code, changedError.code }, ':')
    `);
    assert.equal(
      result,
      'CONTRACT_DEFINITION_CONFLICT:CONTRACT_DEFINITION_CONFLICT:'
        + 'CONTRACT_DEFINITION_CONFLICT:CONTRACT_DEFINITION_CONFLICT:'
        + 'CONTRACT_DEFINITION_CONFLICT',
    );
  } finally {
    engine.global.close();
  }
});

test('canonical contract catalogs remain bounded across persistent version churn', async () => {
  const engine = await createEngine(['foundation', 'contracts']);
  try {
    const result = await engine.doString(`
      local foundation = SynexCoreFactories.foundation({ platform = FakePlatform })
      local contracts = SynexCoreFactories.contracts({
        foundation = foundation,
        protocol = SynexProtocol,
        maximumContracts = 4,
        maximumContractsPerProvider = 2,
        maximumVersionsPerName = 2
      })
      local function definition(version)
        return {
          name = 'synex.fixture.bounded', version = version,
          provider = 'synex_provider', kind = 'rpc', stability = 'experimental',
          network = 'none', errors = {}, input = { type = 'object' },
          output = { type = 'object' }
        }
      end
      assert(contracts.registry:register(definition('1.0.0')))
      assert(contracts.registry:register(definition('1.0.1')))
      local overflow, overflowError = contracts.registry:register(definition('1.0.2'))
      assert(overflow == nil and overflowError.code == 'CONTRACT_REGISTRY_LIMIT')
      assert(contracts.registry:register(definition('1.0.1')),
        'idempotent re-registration must remain available at capacity')
      local snapshot = contracts.registry:snapshot()
      assert(snapshot.contracts == 2 and snapshot.names == 1
        and snapshot.providers.synex_provider == 2)
      assert(#contracts.registry:list() == 2)
      for index = 1, 64 do
        local rejected = definition(('2.0.%d'):format(index))
        rejected.name = ('synex.fixture.rejected_%d'):format(index)
        local value, rejection = contracts.registry:register(rejected)
        assert(value == nil and rejection.code == 'CONTRACT_REGISTRY_LIMIT')
      end
      assert(contracts.registry:snapshot().names == 1,
        'rejected contracts must not retain empty name buckets')

      local byteBounded = SynexCoreFactories.contracts({
        foundation = foundation,
        protocol = SynexProtocol,
        maximumContractDefinitionBytes = 512
      })
      local oversized = definition('2.0.0')
      oversized.input.description = string.rep('x', 500)
      local retained, retainedError = byteBounded.registry:register(oversized)
      assert(retained == nil and retainedError.code == 'INVALID_CONTRACT')
      assert(byteBounded.registry:snapshot().contracts == 0)
      return table.concat({overflowError.code, snapshot.contracts,
        retainedError.code}, ':')
    `);
    assert.equal(result, 'CONTRACT_REGISTRY_LIMIT:2:INVALID_CONTRACT');
  } finally {
    engine.global.close();
  }
});
