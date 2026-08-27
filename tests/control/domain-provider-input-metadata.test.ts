import assert from 'node:assert/strict';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';
import { source } from './helpers.js';

type Field = {
  key: string;
  source: 'id' | 'filter';
  type: 'string' | 'integer' | 'boolean';
  format: string;
  required: boolean;
  minLength?: number;
  maxLength?: number;
  minimum?: number;
  maximum?: number;
};

type SearchKind = { id: string; modes: string[]; accessClass: string };
type View = { id: string; operation: string; accessClass: string; input?: { fields: Field[] }; search?: { kinds: SearchKind[] } };

const encodeLua = String.raw`
  local function encode(value, seen)
    local kind = type(value)
    if kind == 'nil' then return 'null' end
    if kind == 'boolean' or kind == 'number' then return tostring(value) end
    if kind == 'string' then return string.format('%q', value) end
    assert(kind == 'table' and not seen[value], 'unsupported metadata value')
    seen[value] = true
    local array, count, maximum = true, 0, 0
    for key in pairs(value) do
      count = count + 1
      if type(key) ~= 'number' or key < 1 or key % 1 ~= 0 then array = false end
      if type(key) == 'number' then maximum = math.max(maximum, key) end
    end
    if maximum ~= count then array = false end
    local parts = {}
    if array then
      for index = 1, count do parts[#parts + 1] = encode(value[index], seen) end
      seen[value] = nil
      return '[' .. table.concat(parts, ',') .. ']'
    end
    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = key end
    table.sort(keys)
    for _, key in ipairs(keys) do
      parts[#parts + 1] = string.format('%q', key) .. ':' .. encode(value[key], seen)
    end
    seen[value] = nil
    return '{' .. table.concat(parts, ',') .. '}'
  end
`;

async function runtimeViews(resource: 'groups' | 'accounts' | 'entities'): Promise<View[]> {
  const engine = await new LuaFactory().createEngine();
  try {
    const provider = await source(`resources/synex_${resource}/server/control_provider.lua`);
    const support = resource === 'entities'
      ? await source('resources/synex_entities/server/control_provider_support.lua') : '';
    const inspect = resource === 'entities'
      ? await source('resources/synex_entities/server/control_provider_inspect.lua') : '';
    const result = await engine.doString(`
      ${encodeLua}
      ${resource === 'entities' ? `assert(load(${JSON.stringify(support)}, '@support'))()` : ''}
      ${resource === 'entities' ? `assert(load(${JSON.stringify(inspect)}, '@inspect'))()` : ''}
      ${resource === 'entities'
        ? `assert(load(${JSON.stringify(provider)}, '@provider'))()
          local instance = SynexEntityControlProvider.create({
            foundation = { isCallable = function(value) return type(value) == 'function' end },
            service = {}, queryOperations = {}, authorityRepository = {}, database = {}, state = {},
            registry = {}, config = {}, bucketPolicy = {}, spawnAdmission = {}, coreRef = {},
          })`
        : `Foundation = { isCallable = function(value) return type(value) == 'function' end }
          local factory = assert(load(${JSON.stringify(provider)}, '@provider'))()(Foundation)
          local instance = factory({ database = {}, methods = {}, operatorMethods = {}, query = function() end,
            errorSink = function() end, getApi = function() return {} end })`}
      local captured
      assert(instance${resource === 'entities' ? '.' : ':'}register({ ControlProviders = {
        register = function(definition) captured = definition return definition end,
      } }))
      return encode(captured.views, {})
    `);
    return JSON.parse(String(result)) as View[];
  } finally {
    engine.global.close();
  }
}

function inputs(views: View[]): Record<string, Field[]> {
  return Object.fromEntries(views.flatMap((view) => view.input ? [[view.id, view.input.fields]] : []));
}

function fieldsFor(viewInputs: Record<string, Field[]>, id: string): Field[] {
  const fields = viewInputs[id];
  assert.ok(fields, `${id} input metadata is required`);
  return fields;
}

test('domain provider input metadata has exact runtime and descriptor parity', async () => {
  for (const resource of ['groups', 'accounts', 'entities'] as const) {
    const descriptor = JSON.parse(await source(`resources/synex_${resource}/synex.resource.json`)) as {
      controlProvider: { views: View[] };
    };
    assert.deepEqual(await runtimeViews(resource), descriptor.controlProvider.views, resource);
  }
});

test('domain provider access classes and search kinds are declarative and ordered', async () => {
  const expected = {
    groups: { accessClass: 'general', kinds: ['group', 'membership'] },
    accounts: { accessClass: 'financial', kinds: ['account', 'transaction'] },
    entities: { accessClass: 'general', kinds: ['entity'] },
  } as const;
  for (const resource of ['groups', 'accounts', 'entities'] as const) {
    const views = await runtimeViews(resource);
    assert.ok(views.every((view) => view.accessClass === expected[resource].accessClass));
    const search = views.find((view) => view.operation === 'search');
    assert.deepEqual(search?.search?.kinds.map((kind) => kind.id), expected[resource].kinds);
    assert.ok(search?.search?.kinds.every((kind) => kind.accessClass === expected[resource].accessClass
      && kind.modes.length === 1 && kind.modes[0] === 'exact'));
  }
});

test('domain provider input metadata declares each required bounded control input', async () => {
  const [groups, accounts, entities] = await Promise.all([
    runtimeViews('groups'), runtimeViews('accounts'), runtimeViews('entities'),
  ]);
  const groupInputs = inputs(groups);
  for (const view of ['memberships', 'duty', 'assignments', 'relationships', 'history']) {
    assert.deepEqual(fieldsFor(groupInputs, view).map((field) => field.key), ['group_id', 'actor_character_id']);
  }
  for (const view of ['hierarchy', 'roles', 'grades', 'capabilities', 'delegations', 'policies']) {
    assert.deepEqual(fieldsFor(groupInputs, view).map((field) => field.key), ['group_id']);
  }
  const relationship = fieldsFor(groupInputs, 'relationship');
  const capability = fieldsFor(groupInputs, 'capability');
  const policySimulation = fieldsFor(groupInputs, 'policy_simulation');
  assert.deepEqual(relationship.map((field) => field.key),
    ['id', 'group_id', 'actor_character_id']);
  assert.deepEqual(capability.map((field) => field.key),
    ['id', 'character_id', 'capability', 'actor_character_id', 'scope']);
  assert.equal(capability[2]?.format, 'capability');
  assert.equal(capability[2]?.maxLength, 96);
  assert.deepEqual(policySimulation.map((field) => field.key),
    ['actor_character_id', 'group_id', 'action', 'target_membership_id', 'target_grade_id']);
  assert.equal(policySimulation[2]?.format, 'action');
  assert.equal(policySimulation[2]?.maxLength, 64);

  for (const view of ['account', 'transaction', 'hold', 'outbox_detail']) {
    const field = fieldsFor(inputs(accounts), view)[0];
    assert.deepEqual(field && {
      key: field.key, format: field.format, minLength: field.minLength, maxLength: field.maxLength,
    }, { key: 'id', format: 'uuid', minLength: 36, maxLength: 36 });
  }

  const entityInputs = inputs(entities);
  const bucketEntities = fieldsFor(entityInputs, 'bucket_entities');
  const component = fieldsFor(entityInputs, 'component');
  const bucket = fieldsFor(entityInputs, 'bucket');
  assert.deepEqual(bucketEntities.map((field) => field.key), ['bucket', 'generation']);
  assert.deepEqual(bucketEntities.map((field) => [field.minimum, field.maximum]),
    [[0, 2147483647], [0, 2147483647]]);
  assert.deepEqual(component.map((field) => field.key), ['id', 'namespace']);
  assert.equal(component[1]?.maxLength, 64);
  assert.deepEqual(bucket.map((field) => field.key), ['id', 'generation']);
  assert.equal(bucket[0]?.format, 'numeric-string');
});
