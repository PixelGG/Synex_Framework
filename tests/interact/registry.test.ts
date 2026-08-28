import assert from 'node:assert/strict';
import test from 'node:test';
import { runInteractLua } from './helpers.ts';

test('interaction registry validates and orders bounded nearby smart objects', async () => {
  const result = await runInteractLua<string>(String.raw`
    local registry = SynexInteractRegistry.create()
    local registered, operationError = registry.register('synex_test', {
      {
        key = 'synex_test:near', position = { x = 1, y = 0, z = 0 }, radius = 4,
        entityRef = { entityId = 'entity_0001', generation = 2 },
        actions = {
          { key = 'synex_test:open', label = 'Open', priority = 5, maxDistance = 3,
            slot = 'door', leaseSeconds = 4 }
        }
      },
      {
        key = 'synex_test:far', position = { x = 2, y = 0, z = 0 }, radius = 4,
        actions = { { key = 'synex_test:inspect', label = 'Inspect', maxDistance = 3 } }
      }
    })
    assert(registered and not operationError and registered.count == 2)
    local nearby = registry.findNearby({ x = 0, y = 0, z = 0 }, 4, 8)
    assert(#nearby == 2)
    assert(nearby[1].object.key == 'synex_test:near')
    assert(nearby[2].object.key == 'synex_test:far')
    local entityObjects = registry.forEntity({ entityId = 'entity_0001', generation = 2 })
    assert(#entityObjects == 1 and entityObjects[1].key == 'synex_test:near')
    assert(entityObjects[1].actions[1].slot == 'door')
    assert(entityObjects[1].actions[1].leaseSeconds == 4)
    return tostring(registered.revision) .. ':' .. tostring(registry.revision())
  `);
  assert.equal(result, '1:1');
});

test('interaction registry fails atomically on invalid batches and foreign conflicts', async () => {
  const result = await runInteractLua<string>(String.raw`
    local registry = SynexInteractRegistry.create()
    assert(registry.register('synex_alpha', {
      { key = 'synex_alpha:terminal', position = { x = 0, y = 0, z = 0 },
        actions = { { key = 'synex_alpha:use', label = 'Use' } } }
    }))
    local revision = registry.revision()
    local _, invalidError = registry.register('synex_beta', {
      { key = 'synex_beta:valid', position = { x = 1, y = 0, z = 0 },
        actions = { { key = 'synex_beta:use', label = 'Use' } } },
      { key = 'not_namespaced', position = { x = 2, y = 0, z = 0 },
        actions = { { key = 'synex_beta:broken', label = 'Broken' } } }
    })
    assert(invalidError and invalidError.code == 'INTERACT_INVALID_ARGUMENT')
    assert(registry.get('synex_beta:valid') == nil)
    assert(registry.revision() == revision)
    local _, conflictError = registry.register('synex_beta', {
      { key = 'synex_alpha:terminal', position = { x = 0, y = 0, z = 0 },
        actions = { { key = 'synex_beta:takeover', label = 'Take over' } } }
    })
    assert(conflictError and conflictError.code == 'INTERACT_DEFINITION_CONFLICT')
    assert(registry.get('synex_alpha:terminal').ownerResource == 'synex_alpha')
    return invalidError.code .. ':' .. conflictError.code
  `);
  assert.equal(result, 'INTERACT_INVALID_ARGUMENT:INTERACT_DEFINITION_CONFLICT');
});
