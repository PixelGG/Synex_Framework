import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';

const resource = path.join(process.cwd(), 'resources', 'synex_entities');

async function source(relativePath: string): Promise<string> {
  return readFile(path.join(resource, relativePath), 'utf8');
}

test('owner lifecycle policy blocks durable ownership and deletes bounded owner-lifetime state', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await engine.doString(await source('server/lifecycle_policy.lua'));
    const result = await engine.doString(String.raw`
      local records = {
        { entityId = 'entity_1', generation = 1, persistencePolicy = 'session' },
        { entityId = 'entity_2', generation = 1, persistencePolicy = 'owner_lifetime' },
      }
      local deletedRuntime, deletedDefinitions = 0, 0
      local summaries = {
        character_persistent = {
          total = 1, materialized = 1, persistent = 1,
          ownerLifetime = 0, session = 0, temporary = 0,
        },
        character_ephemeral = {
          total = 1, materialized = 1, persistent = 0,
          ownerLifetime = 0, session = 1, temporary = 0,
        },
        group_persistent = {
          total = 1, materialized = 1, persistent = 1,
          ownerLifetime = 0, session = 0, temporary = 0,
        },
        group_ephemeral = {
          total = 2, materialized = 2, persistent = 0,
          ownerLifetime = 1, session = 1, temporary = 0,
        },
      }
      local currentSummary
      local policy = SynexEntityLifecyclePolicy.create({
        authorityRepository = {
          getOwnerDeletionSummary = function(ownerType, ownerId)
            currentSummary = summaries[ownerType .. '_' .. ownerId]
            return currentSummary
          end,
          applyOwnerDeletion = function(ownerType, ownerId, mode, replacement, reason, limit)
            assert(mode == 'delete' and replacement == nil and limit == 64)
            assert(reason == 'synex.entities.group_deleted'
              or reason == 'synex.entities.character_deleted')
            deletedDefinitions = deletedDefinitions + currentSummary.total
            return {
              affected = currentSummary.total,
              complete = true,
              remaining = 0,
            }
          end,
        },
        entityRuntime = {
          delete = function(record)
            deletedRuntime = deletedRuntime + 1
            return record.entityId ~= nil
          end,
        },
        foundation = {
          failure = function(code, message, retryable)
            return nil, { code = code, message = message, retryable = retryable }
          end,
          setHealth = function() end,
        },
        observability = {
          audit = function() return true end,
          gauge = function() return true end,
          increment = function() return true end,
          lifecycle = function() return true end,
        },
        ports = { getGameTimer = function() return 1000 end },
        registry = {
          count = function() return #records end,
          forLogicalOwner = function() return records end,
        },
        resourceName = 'synex_entities',
        config = { lifecycleCleanupTimeoutMs = 5000, maxOwnerEntities = 64 },
      })

      local character = policy.characterParticipant()
      local characterBlock = character.deletePreflight({
        character = { id = 'persistent' },
      })
      assert(characterBlock.action == 'block'
        and characterBlock.code == 'CHARACTER_DELETE_BLOCKED')
      local unload = assert(character.unload({ character = { id = 'ephemeral' } }))
      assert(unload.removed == 1 and deletedRuntime == 1)

      local provider = policy.groupDeletionProvider()
      local groupBlock = provider.preflight({
        domain = 'group', subjectId = 'persistent', context = {},
      })
      assert(groupBlock.decision == 'block' and groupBlock.metadata.persistent == 1)
      local groupDelete = provider.preflight({
        domain = 'group', subjectId = 'ephemeral', context = {},
      })
      assert(groupDelete.decision == 'delete' and groupDelete.metadata.expected == 2)
      local executed = assert(provider.execute({
        domain = 'group', subjectId = 'ephemeral', decision = 'delete', context = {},
      }))
      assert(executed.completed and executed.definitions == 2
        and executed.runtimeEntities == 2)
      return deletedRuntime .. ':' .. deletedDefinitions
    `);
    assert.equal(result, '3:2');
  } finally {
    engine.global.close();
  }
});

test('Entities binds both character and group deletion lifecycles through Core', async () => {
  const [runtime, manifest, descriptor, policy] = await Promise.all([
    source('server/runtime.lua'),
    source('fxmanifest.lua'),
    source('synex.resource.json'),
    source('server/lifecycle_policy.lua'),
  ]);
  assert.match(runtime, /DomainDeletions\.registerProvider/u);
  assert.match(runtime, /lifecyclePolicy\.groupDeletionProvider\(\)/u);
  assert.match(runtime, /lifecyclePolicy\.characterParticipant\(\)/u);
  assert.match(manifest, /'server\/lifecycle_policy\.lua'/u);
  assert.match(policy, /Persistent entities must be transferred or deleted explicitly first/u);
  const parsed = JSON.parse(descriptor) as {
    capabilities: { request: string[] };
    services: { optional: string[] };
  };
  assert.ok(parsed.capabilities.request.includes('synex.deletions.provider'));
  assert.ok(parsed.capabilities.request.includes('synex.groups.read'));
  assert.deepEqual(parsed.services.optional, ['synex.groups@1']);
});
