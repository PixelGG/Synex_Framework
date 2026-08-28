import assert from 'node:assert/strict';
import test from 'node:test';
import { runWorldLua } from './helpers.ts';

const baseBundle = String.raw`{
  schema = 1, key = 'synex_world_example:mission_row', version = '1.0.0',
  dependencies = {}, objects = {
    { kind = 'region', key = 'synex_world_example:los_santos',
      geometry = { type = 'aabb', min = { x = -100, y = -100, z = -10 },
        max = { x = 100, y = 100, z = 100 } } },
    { kind = 'location', key = 'synex_world_example:mrpd',
      parent = 'synex_world_example:los_santos',
      geometry = { type = 'sphere', center = { x = 0, y = 0, z = 10 }, radius = 50 } },
    { kind = 'interior', key = 'synex_world_example:mrpd.main',
      parent = 'synex_world_example:mrpd',
      geometry = { type = 'aabb', min = { x = -20, y = -20, z = 0 },
        max = { x = 20, y = 20, z = 20 } } },
    { kind = 'room', key = 'synex_world_example:mrpd.lobby',
      parent = 'synex_world_example:mrpd.main',
      geometry = { type = 'aabb', min = { x = -5, y = -5, z = 0 },
        max = { x = 5, y = 5, z = 5 } } },
    { kind = 'anchor', key = 'synex_world_example:reception',
      parent = 'synex_world_example:mrpd.lobby',
      position = { x = 0, y = 0, z = 1 }, tags = { 'service.reception' } }
  }
}`;

test('bundle activation is atomic, owner-bound, revisioned, and stale-safe', async () => {
  const result = await runWorldLua<string>(String.raw`
    local activated, deactivated = 0, 0
    local registry = SynexWorldRegistry.create({
      onActivated = function() activated = activated + 1 end,
      onDeactivated = function() deactivated = deactivated + 1 end
    })
    local first = assert(registry.registerBundle(${baseBundle}, 'synex_world_example', 1))
    assert(first.revision == 1 and first.objects == 5 and activated == 1)
    local oldRef = registry.ref(assert(registry.get('synex_world_example:reception')))

    local invalid = ${baseBundle}
    invalid.objects[2].parent = 'synex_world_example:missing'
    local replacement, replacementError = registry.replaceBundle(
      invalid, 'synex_world_example', 1)
    assert(replacement == nil and replacementError.code == 'WORLD_REFERENCE_INVALID')
    assert(registry.currentRevision() == 1 and registry.objectCount() == 5)
    assert(registry.resolve(oldRef).key == oldRef.key)

    local replacementBundle = ${baseBundle}
    replacementBundle.version = '1.1.0'
    replacementBundle.objects[5].position = { x = 2, y = 0, z = 1 }
    local second = assert(registry.replaceBundle(
      replacementBundle, 'synex_world_example', 1))
    assert(second.revision == 2 and activated == 2 and deactivated == 1)
    local stale, staleError = registry.resolve(oldRef)
    assert(stale == nil and staleError.code == 'STALE_WORLD_REF')
    local current = assert(registry.get(oldRef.key))
    assert(current.position.x == 2 and current.revision == 2)
    return staleError.code .. ':' .. registry.currentRevision()
  `);
  assert.equal(result, 'STALE_WORLD_REF:2');
});

test('registry revisions are partitioned by World owner epoch across fresh runtimes', async () => {
  const result = await runWorldLua<string>(String.raw`
    local first = SynexWorldRegistry.create({})
    local firstBinding = assert(first.bindIncarnation(7))
    assert(firstBinding.baseRevision == 393216
      and firstBinding.maximumRevision == 458751)
    local firstBundle = assert(first.registerBundle(${baseBundle},
      'synex_world_example', 1))
    assert(firstBundle.revision == 393217)
    local oldRef = first.ref(assert(first.get('synex_world_example:mrpd')))

    local second = SynexWorldRegistry.create({})
    local secondBinding = assert(second.bindIncarnation(8))
    assert(secondBinding.baseRevision == 458752
      and secondBinding.maximumRevision == 524287)
    local secondBundle = assert(second.registerBundle(${baseBundle},
      'synex_world_example', 2))
    assert(secondBundle.revision == 458753 and second.objectCount() == 5)
    local stale, staleError = second.resolve(oldRef)
    assert(stale == nil and staleError.code == 'STALE_WORLD_REF')
    assert(assert(second.bindIncarnation(8)).baseRevision == 458752)
    local rebound, reboundError = second.bindIncarnation(9)
    assert(rebound == nil and reboundError.code == 'STALE_RESOURCE')

    local late = SynexWorldRegistry.create({})
    assert(late.registerBundle(${baseBundle}, 'synex_world_example', 1))
    local lateBinding, lateError = late.bindIncarnation(1)
    assert(lateBinding == nil and lateError.code == 'STALE_RESOURCE')
    local maximum = assert(SynexWorldRegistry.create({})
      .bindIncarnation(SynexWorldLimits.maximumRevisionOwnerEpoch))
    assert(maximum.baseRevision == 2147418112
      and maximum.maximumRevision == SynexWorldLimits.maximumRevision)
    local oversized, oversizedError = SynexWorldRegistry.create({})
      .bindIncarnation(SynexWorldLimits.maximumRevisionOwnerEpoch + 1)
    assert(oversized == nil and oversizedError.code == 'STALE_RESOURCE')
    local invalidRef, invalidRefError = second.resolve({
      kind = 'location', key = 'synex_world_example:mrpd',
      revision = SynexWorldLimits.maximumRevision + 1,
    })
    assert(invalidRef == nil and invalidRefError.code == 'WORLD_REFERENCE_INVALID')
    return table.concat({ firstBundle.revision, secondBundle.revision,
      staleError.code, reboundError.code, lateError.code, oversizedError.code,
      invalidRefError.code }, ':')
  `);
  assert.equal(result,
    '393217:458753:STALE_WORLD_REF:STALE_RESOURCE:STALE_RESOURCE:STALE_RESOURCE:'
      + 'WORLD_REFERENCE_INVALID');
});

test('bundle activation publishes zero definitions when one of 101 candidates is invalid', async () => {
  const result = await runWorldLua<string>(String.raw`
    local activated = 0
    local registry = SynexWorldRegistry.create({
      onActivated = function() activated = activated + 1 end,
    })
    local objects = {}
    for index = 1, 100 do
      objects[index] = {
        kind = 'region', key = ('synex_atomic:region.%03d'):format(index),
        geometry = { type = 'sphere',
          center = { x = index * 10, y = 0, z = 0 }, radius = 4 },
      }
    end
    objects[101] = {
      kind = 'location', key = 'synex_atomic:invalid',
      parent = 'synex_atomic:missing',
      geometry = { type = 'sphere', center = { x = 0, y = 0, z = 0 }, radius = 2 },
    }
    local registered, operationError = registry.registerBundle({
      schema = 1, key = 'synex_atomic:bundle', version = '1.0.0',
      dependencies = {}, objects = objects,
    }, 'synex_atomic', 1)
    assert(registered == nil and operationError.code == 'WORLD_REFERENCE_INVALID')
    assert(registry.objectCount() == 0 and registry.currentRevision() == 0
      and activated == 0 and next(registry.bundles()) == nil)
    return table.concat({ operationError.code, registry.objectCount(),
      registry.currentRevision(), activated }, ':')
  `);

  assert.equal(result, 'WORLD_REFERENCE_INVALID:0:0:0');
});

test('graph traversal and registry children are deterministic, bounded, and kind-aware', async () => {
  const result = await runWorldLua<string>(String.raw`
    local objects = {
      ['synex_graph:region'] = { kind = 'region', key = 'synex_graph:region' },
      ['synex_graph:location'] = { kind = 'location', key = 'synex_graph:location',
        parent = 'synex_graph:region' },
      ['synex_graph:interior'] = { kind = 'interior', key = 'synex_graph:interior',
        parent = 'synex_graph:location' },
      ['synex_graph:room'] = { kind = 'room', key = 'synex_graph:room',
        parent = 'synex_graph:interior' },
      ['synex_graph:zone'] = { kind = 'zone', key = 'synex_graph:zone',
        parent = 'synex_graph:location' },
    }
    local graph = assert(SynexWorldGraph.build(objects))
    local ancestors = SynexWorldGraph.ancestors(graph, objects, 'synex_graph:room', 8)
    assert(table.concat(ancestors, ',') == table.concat({
      'synex_graph:interior', 'synex_graph:location', 'synex_graph:region',
    }, ','))
    local subtree, truncated = SynexWorldGraph.subtree(graph, 'synex_graph:region', 8)
    assert(table.concat(subtree, ',') == table.concat({
      'synex_graph:region', 'synex_graph:location', 'synex_graph:interior',
      'synex_graph:zone', 'synex_graph:room',
    }, ',') and truncated == false)
    local bounded, boundedTruncated = SynexWorldGraph.subtree(graph, 'synex_graph:region', 2)
    assert(#bounded == 2 and bounded[1] == 'synex_graph:region'
      and bounded[2] == 'synex_graph:location' and boundedTruncated == true)

    local registry = SynexWorldRegistry.create({})
    assert(registry.registerBundle(${baseBundle}, 'synex_world_example', 1))
    local rootChildren = registry.children('synex_world_example:los_santos')
    local locationChildren = registry.children('synex_world_example:mrpd')
    local onlyInteriors = registry.children('synex_world_example:mrpd', 'interior', 1)
    assert(#rootChildren == 1 and rootChildren[1].key == 'synex_world_example:mrpd')
    assert(#locationChildren == 1 and locationChildren[1].kind == 'interior')
    assert(#onlyInteriors == 1 and onlyInteriors[1].key == 'synex_world_example:mrpd.main')
    return table.concat({ #ancestors, #subtree, tostring(truncated),
      #bounded, tostring(boundedTruncated), #onlyInteriors }, ':')
  `);
  assert.equal(result, '3:5:false:2:true:1');
});

test('graph cycles, duplicate keys, undeclared cross-owner references, and foreign replacements fail closed', async () => {
  const result = await runWorldLua<string>(String.raw`
    local registry = SynexWorldRegistry.create({})
    assert(registry.registerBundle(${baseBundle}, 'synex_world_example', 1))

    local duplicate = ${baseBundle}
    duplicate.key = 'synex_world_example:duplicate_bundle'
    local _, duplicateError = registry.registerBundle(duplicate, 'synex_world_example', 1)
    assert(duplicateError.code == 'WORLD_BUNDLE_CONFLICT',
      'duplicate:' .. tostring(duplicateError and duplicateError.code))

    local cycle = ${baseBundle}
    cycle.objects[1].parent = 'synex_world_example:los_santos_child'
    cycle.objects[#cycle.objects + 1] = {
      kind = 'region', key = 'synex_world_example:los_santos_child',
      parent = 'synex_world_example:los_santos',
      geometry = { type = 'sphere', center = { x = 0, y = 0, z = 0 }, radius = 2 }
    }
    local cycleRegistry = SynexWorldRegistry.create({})
    local _, cycleError = cycleRegistry.registerBundle(cycle, 'synex_world_example', 1)
    assert(cycleError.code == 'WORLD_GRAPH_CYCLE',
      'cycle:' .. tostring(cycleError and cycleError.code) .. ':'
        .. tostring(cycleError and cycleError.message) .. ':'
        .. tostring(cycleError and cycleError.details and cycleError.details.object))

    local deep = { schema = 1, key = 'synex_world_example:deep_cycle',
      version = '1.0.0', dependencies = {}, objects = {} }
    for index = 1, 8 do
      deep.objects[index] = {
        kind = 'region', key = ('synex_world_example:deep.%02d'):format(index),
        parent = ('synex_world_example:deep.%02d'):format(index % 8 + 1),
        geometry = { type = 'sphere', center = { x = index, y = 0, z = 0 }, radius = 1 },
      }
    end
    local _, deepCycleError = SynexWorldRegistry.create({}).registerBundle(
      deep, 'synex_world_example', 1)
    assert(deepCycleError.code == 'WORLD_GRAPH_CYCLE'
      and #deepCycleError.details.keys == 8)

    local wrongParent = ${baseBundle}
    wrongParent.key = 'synex_world_example:wrong_parent'
    wrongParent.objects[2].parent = 'synex_world_example:reception'
    local _, wrongParentError = SynexWorldRegistry.create({}).registerBundle(
      wrongParent, 'synex_world_example', 1)
    assert(wrongParentError.code == 'WORLD_REFERENCE_INVALID')

    local _, foreignError = registry.replaceBundle(${baseBundle}, 'synex_world_foreign', 1)
    assert(foreignError.code == 'WORLD_BUNDLE_CONFLICT'
      or foreignError.code == 'WORLD_REFERENCE_INVALID', foreignError.code)
    return duplicateError.code .. ':' .. cycleError.code .. ':' .. deepCycleError.code
      .. ':' .. wrongParentError.code
  `);
  assert.equal(result,
    'WORLD_BUNDLE_CONFLICT:WORLD_GRAPH_CYCLE:WORLD_GRAPH_CYCLE:WORLD_REFERENCE_INVALID');
});

test('direct bundle registration enforces schema-equivalent map package, semver and resource names', async () => {
  const result = await runWorldLua<string>(String.raw`
    local function withMap(packageType, version, resourceName, dependency)
      local bundle = ${baseBundle}
      bundle.objects[#bundle.objects + 1] = {
        kind = 'map_package', key = 'synex_world_example:map',
        resourceName = resourceName or 'map_asset', packageType = packageType,
        version = version, dependencies = dependency and { dependency } or {},
        locations = { 'synex_world_example:mrpd' },
      }
      return bundle
    end
    local valid = assert(SynexWorldRegistry.create({}).registerBundle(
      withMap('mlo', '1.0.0-alpha.1'), 'synex_world_example', 1))
    assert(valid.objects == 6)

    local invalidType, typeError = SynexWorldRegistry.create({}).registerBundle(
      withMap('arbitrary', '1.0.0'), 'synex_world_example', 1)
    local invalidVersion, versionError = SynexWorldRegistry.create({}).registerBundle(
      withMap('mlo', '01.0.0'), 'synex_world_example', 1)
    local buildVersion, buildError = SynexWorldRegistry.create({}).registerBundle(
      withMap('mlo', '1.0.0+build'), 'synex_world_example', 1)
    local invalidResource, resourceError = SynexWorldRegistry.create({}).registerBundle(
      withMap('mlo', '1.0.0', 'map..asset'), 'synex_world_example', 1)
    local invalidDependency, dependencyError = SynexWorldRegistry.create({}).registerBundle(
      withMap('mlo', '1.0.0', 'map_asset', 'dependency..name'),
      'synex_world_example', 1)
    local invalidEnvelope = ${baseBundle}
    invalidEnvelope.version = '1.0.0+build'
    local envelope, envelopeError = SynexWorldRegistry.create({}).registerBundle(
      invalidEnvelope, 'synex_world_example', 1)

    assert(invalidType == nil and typeError.code == 'WORLD_BUNDLE_INVALID')
    assert(invalidVersion == nil and versionError.code == 'WORLD_BUNDLE_INVALID')
    assert(buildVersion == nil and buildError.code == 'WORLD_BUNDLE_INVALID')
    assert(invalidResource == nil and resourceError.code == 'WORLD_DEPENDENCY_MISSING')
    assert(invalidDependency == nil and dependencyError.code == 'WORLD_DEPENDENCY_MISSING')
    assert(envelope == nil and envelopeError.code == 'WORLD_BUNDLE_INVALID')
    return table.concat({ typeError.code, versionError.code, buildError.code,
      resourceError.code, dependencyError.code, envelopeError.code }, ':')
  `);
  assert.equal(result, 'WORLD_BUNDLE_INVALID:WORLD_BUNDLE_INVALID:WORLD_BUNDLE_INVALID:'
    + 'WORLD_DEPENDENCY_MISSING:WORLD_DEPENDENCY_MISSING:WORLD_BUNDLE_INVALID');
});

test('DoorSystem hashes are unique across explicit, derived and replacement candidates', async () => {
  const result = await runWorldLua<string>(String.raw`
    local function door(owner, suffix, hash)
      local leaf = { id = 'main', model = 1234,
        position = { x = 0, y = 0, z = 0 } }
      leaf.doorHash = hash
      return { kind = 'door', key = owner .. ':' .. suffix,
        position = { x = 0, y = 0, z = 0 }, leaves = { leaf },
        defaultState = 'LOCKED', persistent = false }
    end
    local function bundle(owner, suffix, objects)
      return { schema = 1, key = owner .. ':' .. suffix, version = '1.0.0',
        dependencies = {}, objects = objects }
    end

    local intra = bundle('synex_doors', 'intra', {
      door('synex_doors', 'first', 99), door('synex_doors', 'second', 99),
    })
    local _, intraError = SynexWorldRegistry.create({}).registerBundle(
      intra, 'synex_doors', 1)
    assert(intraError and intraError.code == 'WORLD_BUNDLE_CONFLICT')

    local derived = door('synex_doors', 'derived', nil)
    local derivedHash = SynexWorldValidation.doorHash(derived.key, derived.leaves[1].id)
    local mixed = bundle('synex_doors', 'mixed', {
      derived, door('synex_doors', 'explicit', derivedHash),
    })
    local _, mixedError = SynexWorldRegistry.create({}).registerBundle(
      mixed, 'synex_doors', 1)
    assert(mixedError and mixedError.code == 'WORLD_BUNDLE_CONFLICT')

    local registry = SynexWorldRegistry.create({})
    assert(registry.registerBundle(bundle('synex_alpha', 'doors', {
      door('synex_alpha', 'door', 101),
    }), 'synex_alpha', 1))
    assert(registry.registerBundle(bundle('synex_beta', 'doors', {
      door('synex_beta', 'door', 202),
    }), 'synex_beta', 1))
    local replacement = bundle('synex_beta', 'doors', {
      door('synex_beta', 'door', 101),
    })
    local changed, crossError = registry.replaceBundle(replacement, 'synex_beta', 1)
    assert(changed == nil and crossError.code == 'WORLD_BUNDLE_CONFLICT')
    assert(registry.get('synex_beta:door').leaves[1].doorHash == 202)
    return table.concat({ intraError.code, mixedError.code, crossError.code,
      SynexWorldValidation.uint32(-1), SynexWorldValidation.uint32(4294967295) }, ':')
  `);
  assert.equal(result, 'WORLD_BUNDLE_CONFLICT:WORLD_BUNDLE_CONFLICT:'
    + 'WORLD_BUNDLE_CONFLICT:4294967295:4294967295');
});

test('direct bundle registration rejects projected control characters before activation', async () => {
  const result = await runWorldLua<string>(String.raw`
    local control = string.char(127)
    local function rejected(candidate)
      local value, valueError = SynexWorldRegistry.create({}).registerBundle(
        candidate, 'synex_world_example', 1)
      assert(value == nil and valueError ~= nil)
      return valueError.code
    end
    local results = {}
    local label = ${baseBundle}; label.objects[1].label = 'bad' .. control
    results[#results + 1] = rejected(label)
    local room = ${baseBundle}; room.objects[4].gameRoomKey = 'bad' .. control
    results[#results + 1] = rejected(room)
    local ipl = ${baseBundle}; ipl.objects[#ipl.objects + 1] = {
      kind = 'ipl_bundle', key = 'synex_world_example:ipls', scope = 'global',
      ipls = { 'bad' .. control } }
    results[#results + 1] = rejected(ipl)
    local interiorSet = ${baseBundle}; interiorSet.objects[#interiorSet.objects + 1] = {
      kind = 'ipl_bundle', key = 'synex_world_example:sets', scope = 'global',
      ipls = { 'valid_ipl' }, interiorSets = {
        { interiorId = 1, name = 'bad' .. control } } }
    results[#results + 1] = rejected(interiorSet)
    local scalar = ${baseBundle}; scalar.objects[#scalar.objects + 1] = {
      kind = 'world_state_definition', key = 'synex_world_example:text',
      stateType = 'string', scope = 'global', persistence = 'runtime',
      schemaVersion = 1, maxLength = 32, default = 'bad' .. control }
    results[#results + 1] = rejected(scalar)
    local enum = ${baseBundle}; enum.objects[#enum.objects + 1] = {
      kind = 'world_state_definition', key = 'synex_world_example:mode',
      stateType = 'enum', scope = 'global', persistence = 'runtime',
      schemaVersion = 1, allowed = { 'bad' .. control } }
    results[#results + 1] = rejected(enum)
    local structured = ${baseBundle}; structured.objects[#structured.objects + 1] = {
      kind = 'world_state_definition', key = 'synex_world_example:structured',
      stateType = 'structured', scope = 'global', persistence = 'runtime',
      schemaVersion = 1, structuredSchema = { type = 'object', maximumBytes = 128,
        maximumDepth = 2, maximumEntries = 4, properties = {
          value = { type = 'enum', allowed = { 'bad' .. control } } },
        required = { 'value' }, additionalProperties = false } }
    results[#results + 1] = rejected(structured)
    local envelope = ${baseBundle}; envelope['$schema'] = 'bad' .. control
    results[#results + 1] = rejected(envelope)

    local requirement = ${baseBundle}
    requirement.objects[#requirement.objects + 1] = {
      kind = 'world_state_definition', key = 'synex_world_example:requirement',
      stateType = 'string', scope = 'global', persistence = 'runtime',
      schemaVersion = 1, maxLength = 32 }
    requirement.objects[#requirement.objects + 1] = {
      kind = 'door', key = 'synex_world_example:controlled_door',
      position = { x = 0, y = 0, z = 0 }, defaultState = 'LOCKED', persistent = false,
      leaves = { { id = 'main', model = 1, position = { x = 0, y = 0, z = 0 } } },
      accessPolicy = { stateRequirements = { { key = 'synex_world_example:requirement',
        operator = 'equals', value = 'bad' .. control } } } }
    results[#results + 1] = rejected(requirement)
    assert(#results == 9)
    return table.concat(results, ':')
  `);
  assert.equal(result,
    'INVALID_ARGUMENT:WORLD_BUNDLE_INVALID:WORLD_BUNDLE_INVALID:WORLD_BUNDLE_INVALID:'
    + 'WORLD_STATE_SCHEMA_INVALID:WORLD_STATE_SCHEMA_INVALID:WORLD_STATE_SCHEMA_INVALID:'
    + 'WORLD_BUNDLE_INVALID:WORLD_BUNDLE_INVALID');
});

test('bundle key replacement and owner teardown remain atomic across references', async () => {
  const result = await runWorldLua<string>(String.raw`
    local registry = SynexWorldRegistry.create({})
    assert(registry.registerBundle(${baseBundle}, 'synex_world_example', 1))
    local invalid = ${baseBundle}
    invalid.key = 'synex_world_example:renamed'
    invalid.objects[2].parent = 'synex_world_example:missing'
    local failed, failure = registry.replaceOwnedBundle(
      'synex_world_example:mission_row', invalid, 'synex_world_example', 1)
    assert(failed == nil and failure.code == 'WORLD_REFERENCE_INVALID')
    assert(registry.get('synex_world_example:mrpd'))
    assert(registry.bundles()['synex_world_example:mission_row'])

    local renamed = ${baseBundle}
    renamed.key = 'synex_world_example:renamed'
    local swapped = assert(registry.replaceOwnedBundle(
      'synex_world_example:mission_row', renamed, 'synex_world_example', 1))
    assert(swapped.key == 'synex_world_example:renamed')
    assert(registry.bundles()['synex_world_example:mission_row'] == nil)
    local removed = assert(registry.unregisterOwner(
      'synex_world_example', 1, 'owner_stopped'))
    assert(#removed == 1 and registry.objectCount() == 0)
    return failure.code .. ':' .. swapped.key .. ':' .. #removed
  `);
  assert.equal(result,
    'WORLD_REFERENCE_INVALID:synex_world_example:renamed:1');
});

test('owner and explicit teardown atomically deactivate transitive cross-owner dependents', async () => {
  const result = await runWorldLua<string>(String.raw`
    local function bundle(owner, dependency, kind, key, parent)
      local object = { kind = kind, key = key, parent = parent }
      if kind == 'region' then
        object.geometry = { type = 'sphere', center = { x = 0, y = 0, z = 0 }, radius = 100 }
      elseif kind == 'location' then
        object.geometry = { type = 'sphere', center = { x = 0, y = 0, z = 0 }, radius = 50 }
      else
        object.position = { x = 0, y = 0, z = 0 }
      end
      return { schema = 1, key = owner .. ':bundle', version = '1.0.0',
        dependencies = dependency and { dependency } or {}, objects = { object } }
    end
    local alpha = bundle('synex_alpha', nil, 'region', 'synex_alpha:region')
    local beta = bundle('synex_beta', 'synex_alpha', 'location',
      'synex_beta:location', 'synex_alpha:region')
    local gamma = bundle('synex_gamma', 'synex_beta', 'anchor',
      'synex_gamma:anchor', 'synex_beta:location')

    local reasons = {}
    local ownerRegistry = SynexWorldRegistry.create({
      onDeactivated = function(value, reason) reasons[value.key] = reason end,
    })
    assert(ownerRegistry.registerBundle(alpha, 'synex_alpha', 1))
    assert(ownerRegistry.registerBundle(beta, 'synex_beta', 2))
    assert(ownerRegistry.registerBundle(gamma, 'synex_gamma', 3))
    local alphaRef = ownerRegistry.ref(assert(ownerRegistry.get('synex_alpha:region')))
    local gammaRef = ownerRegistry.ref(assert(ownerRegistry.get('synex_gamma:anchor')))
    local removed = assert(ownerRegistry.unregisterOwner('synex_alpha', 1, 'owner_stopped'))
    assert(#removed == 3 and ownerRegistry.bundleCount() == 0
      and ownerRegistry.objectCount() == 0 and ownerRegistry.currentRevision() == 4)
    assert(removed[1].key == 'synex_alpha:bundle' and removed[1].dependent == false)
    assert(removed[2].key == 'synex_beta:bundle' and removed[2].dependent == true)
    assert(removed[3].key == 'synex_gamma:bundle' and removed[3].dependent == true)
    assert(reasons['synex_alpha:bundle'] == 'owner_stopped'
      and reasons['synex_beta:bundle'] == 'dependency_unavailable'
      and reasons['synex_gamma:bundle'] == 'dependency_unavailable')
    local _, alphaError = ownerRegistry.resolve(alphaRef)
    local _, gammaError = ownerRegistry.resolve(gammaRef)
    assert(alphaError.code == 'STALE_WORLD_REF' and gammaError.code == 'STALE_WORLD_REF')

    local explicitRegistry = SynexWorldRegistry.create({})
    assert(explicitRegistry.registerBundle(alpha, 'synex_alpha', 1))
    assert(explicitRegistry.registerBundle(beta, 'synex_beta', 2))
    assert(explicitRegistry.registerBundle(gamma, 'synex_gamma', 3))
    local root = assert(explicitRegistry.unregisterBundle(
      'synex_alpha:bundle', 'synex_alpha', 1, 'caller_unregistered'))
    assert(root.key == 'synex_alpha:bundle' and #root.removed == 3
      and explicitRegistry.bundleCount() == 0)
    return table.concat({ #removed, #root.removed, alphaError.code,
      gammaError.code, reasons['synex_gamma:bundle'] }, ':')
  `);
  assert.equal(result,
    '3:3:STALE_WORLD_REF:STALE_WORLD_REF:dependency_unavailable');
});

test('stale-reference tombstones retain only the bounded most-recent key set', async () => {
  const result = await runWorldLua<string>(String.raw`
    local registry = SynexWorldRegistry.create({ maximumTombstones = 3 })
    local references = {}
    local function candidate(index)
      return { schema = 1, key = 'synex_history:bundle', version = '1.0.' .. index,
        dependencies = {}, objects = {
          { kind = 'region', key = 'synex_history:key_' .. index,
            geometry = { type = 'sphere', center = { x = index, y = 0, z = 0 }, radius = 1 } },
        } }
    end
    assert(registry.registerBundle(candidate(0), 'synex_history', 1))
    references[0] = registry.ref(assert(registry.get('synex_history:key_0')))
    for index = 1, 5 do
      assert(registry.replaceBundle(candidate(index), 'synex_history', 1))
      references[index] = registry.ref(assert(registry.get('synex_history:key_' .. index)))
      assert(registry.tombstoneCount() <= 3)
    end
    local _, oldestError = registry.resolve(references[0])
    local _, recentError = registry.resolve(references[4])
    assert(oldestError.code == 'WORLD_NOT_FOUND'
      and recentError.code == 'STALE_WORLD_REF' and registry.tombstoneCount() == 3)
    return oldestError.code .. ':' .. recentError.code .. ':' .. registry.tombstoneCount()
  `);
  assert.equal(result, 'WORLD_NOT_FOUND:STALE_WORLD_REF:3');
});
