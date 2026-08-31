import assert from 'node:assert/strict';
import test from 'node:test';

import { runInteractLua } from './helpers.js';

test('legacy target normalization is bounded, declarative, and explicitly partial', async () => {
  const result = await runInteractLua<{
    status: string;
    authority: string;
    system: string;
    unsupported: number;
    groupAuthority: string;
  }>(`
    local compatibility = SynexInteractCompatibility.create()
    local value = assert(compatibility.normalize({ consumer = 'fixture_resource' }, {
      system = 'ox_target',
      selector = { kind = 'model', models = { 12345 }, bones = { 'boot' }, distance = 2.5 },
      options = {{ name = 'open_trunk', label = 'Open trunk', icon = 'vehicle.trunk',
        groups = { ['police.grade'] = 2 }, items = { ['vehicle.key'] = true },
        actionAdapter = 'fixture_resource:vehicle_action', actionRequest = { verb = 'open' } }},
    }))
    return { status = value.status, authority = value.authority,
      system = value.sourceSystem, unsupported = #value.unsupported,
      groupAuthority = value.options[1].visibilityHints.authority }
  `);

  assert.deepEqual(result, {
    status: 'PARTIAL',
    authority: 'server-revalidation-required',
    system: 'ox_target',
    unsupported: 3,
    groupAuthority: 'observed-only',
  });
});

test('legacy mapping rejects arbitrary callbacks, too many options, and foreign action adapters', async () => {
  const result = await runInteractLua<{
    callback: string;
    capacity: string;
    foreign: string;
  }>(`
    local compatibility = SynexInteractCompatibility.create()
    local base = { system = 'qb-target', selector = { kind = 'entity' },
      options = {{ name = 'inspect', label = 'Inspect' }} }
    local callback = SynexInteractValidation.copy(base)
    callback.options[1].onSelect = 'legacy:event'
    local _, callbackError = compatibility.normalize({ consumer = 'fixture_resource' }, callback)
    local capacity = SynexInteractValidation.copy(base)
    for index = 2, SynexInteractLimits.maximumVisibleIntents + 1 do
      capacity.options[index] = { name = 'option_' .. index, label = 'Option' }
    end
    local _, capacityError = compatibility.normalize({ consumer = 'fixture_resource' }, capacity)
    local foreign = SynexInteractValidation.copy(base)
    foreign.options[1].actionAdapter = 'other_resource:action'
    local _, foreignError = compatibility.normalize({ consumer = 'fixture_resource' }, foreign)
    return { callback = callbackError.code, capacity = capacityError.code,
      foreign = foreignError.code }
  `);

  assert.deepEqual(result, {
    callback: 'COMPAT_INVALID_ARGUMENT',
    capacity: 'COMPAT_INVALID_ARGUMENT',
    foreign: 'COMPAT_CONSUMER_DENIED',
  });
});
