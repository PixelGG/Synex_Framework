import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory, type LuaEngine } from 'wasmoon';

const root = process.cwd();

async function preload(engine: LuaEngine, name: string, relativePath: string): Promise<void> {
  const source = await readFile(path.join(root, relativePath), 'utf8');
  await engine.doString(
    `package.preload[${JSON.stringify(name)}] = assert(load(${JSON.stringify(source)}, ${JSON.stringify(`@${relativePath}`)}))`,
  );
}

async function createEngine(): Promise<LuaEngine> {
  const engine = await new LuaFactory().createEngine();
  await preload(engine, 'server.foundation', 'resources/synex_groups/server/foundation.lua');
  await preload(engine, 'server.runtime_index', 'resources/synex_groups/server/runtime_index.lua');
  await preload(
    engine,
    'server.persistence.runtime_context',
    'resources/synex_groups/server/persistence/runtime_context.lua',
  );
  return engine;
}

test('runtime index maintains online and duty maps with defensive reads', async () => {
  const engine = await createEngine();
  try {
    const result = await engine.doString(`
      local Foundation = require 'server.foundation'
      local RuntimeIndex = require('server.runtime_index')(Foundation)
      local index = RuntimeIndex({ maximumCharacters = 32, maximumMemberships = 128 })

      assert(index:replaceCharacter('character_alpha_0001', {
        characterId = 'character_alpha_0001',
        memberships = {
          {
            membershipId = 'membership_alpha_0001', groupId = 'group_shared_0001',
            characterId = 'character_alpha_0001', lifecycleState = 'ACTIVE',
            dutySession = {
              sessionId = 'duty_alpha_0001', state = 'available',
              countsAsOnDuty = true, assignmentId = 'assignment_alpha_0001', version = 1
            }
          },
          {
            membershipId = 'membership_alpha_0002', groupId = 'group_other_0002',
            characterId = 'character_alpha_0001', lifecycleState = 'SUSPENDED'
          }
        }
      }))
      assert(index:replaceCharacter('character_bravo_0002', {
        characterId = 'character_bravo_0002',
        memberships = {
          {
            membershipId = 'membership_bravo_0001', groupId = 'group_shared_0001',
            characterId = 'character_bravo_0002', lifecycleState = 'ACTIVE',
            dutySession = {
              sessionId = 'duty_bravo_0002', state = 'break',
              countsAsOnDuty = false, version = 3
            }
          }
        }
      }))

      assert(index:countOnlineMembers('group_shared_0001') == 2)
      assert(index:countActiveDutyMembers('group_shared_0001') == 1)
      assert(#index:getOnlineMembers('group_shared_0001') == 2)
      assert(#index:getActiveDutyMembers('group_shared_0001') == 1)

      local session = assert(index:getActiveDutySession('membership_bravo_0001'))
      assert(session.sessionId == 'duty_bravo_0002' and session.countsAsOnDuty == false)
      session.state = 'tampered'
      assert(index:getActiveDutySession('membership_bravo_0001').state == 'break')

      local context = assert(index:getCharacterContext('character_alpha_0001'))
      context.memberships[1].groupId = 'group_tampered_9999'
      assert(index:countOnlineMembers('group_shared_0001') == 2)

      assert(index:replaceCharacter('character_alpha_0001', {
        characterId = 'character_alpha_0001',
        memberships = {
          {
            membershipId = 'membership_alpha_0001', groupId = 'group_shared_0001',
            characterId = 'character_alpha_0001', lifecycleState = 'ACTIVE',
            dutySession = {
              sessionId = 'duty_alpha_0001', state = 'break',
              countsAsOnDuty = false, version = 2
            }
          }
        }
      }))
      assert(index:countOnlineMembers('group_other_0002') == 0)
      assert(index:countActiveDutyMembers('group_shared_0001') == 0)
      assert(index:getActiveDutySession('membership_alpha_0001').version == 2)

      assert(index:removeCharacter('character_bravo_0002') == 1)
      assert(index:removeCharacter('character_missing_9999') == 0)
      local snapshot = index:snapshot()
      assert(snapshot.characters == 1 and snapshot.memberships == 1)
      assert(snapshot.dutySessions == 1 and snapshot.onlineGroups == 1)
      return table.concat({ snapshot.characters, snapshot.memberships,
        snapshot.dutySessions, snapshot.loads, snapshot.unloads }, ':')
    `);
    assert.equal(result, '1:1:1:3:1');
  } finally {
    engine.global.close();
  }
});

test('runtime index rejects overflows and conflicts without partial mutation', async () => {
  const engine = await createEngine();
  try {
    const result = await engine.doString(`
      local Foundation = require 'server.foundation'
      local RuntimeIndex = require('server.runtime_index')(Foundation)
      local index = RuntimeIndex({
        maximumCharacters = 65,
        maximumMemberships = 64,
        maximumMembershipsPerCharacter = 1
      })
      for number = 1, 64 do
        local suffix = string.format('%04d', number)
        local characterId = 'character_capacity_' .. suffix
        assert(index:replaceCharacter(characterId, {
          characterId = characterId,
          memberships = {{
            membershipId = 'membership_capacity_' .. suffix,
            groupId = 'group_capacity_0001',
            characterId = characterId,
            lifecycleState = 'ACTIVE'
          }}
        }))
      end
      local overflow, overflowError = index:replaceCharacter('character_capacity_0065', {
        characterId = 'character_capacity_0065',
        memberships = {{
          membershipId = 'membership_capacity_0065', groupId = 'group_capacity_0001',
          characterId = 'character_capacity_0065', lifecycleState = 'ACTIVE'
        }}
      })
      assert(overflow == nil and overflowError.code == 'RUNTIME_INDEX_CAPACITY_EXCEEDED')
      assert(index:countOnlineMembers('group_capacity_0001') == 64)

      local perCharacter, perCharacterError = index:replaceCharacter(
        'character_capacity_0001', {
          characterId = 'character_capacity_0001', memberships = {
            {
              membershipId = 'membership_replacement_0001', groupId = 'group_capacity_0001',
              characterId = 'character_capacity_0001', lifecycleState = 'ACTIVE'
            },
            {
              membershipId = 'membership_replacement_0002', groupId = 'group_capacity_0001',
              characterId = 'character_capacity_0001', lifecycleState = 'ACTIVE'
            }
          }
        })
      assert(perCharacter == nil
        and perCharacterError.code == 'RUNTIME_INDEX_CAPACITY_EXCEEDED')
      assert(index:getCharacterContext('character_capacity_0001')
        .memberships[1].membershipId == 'membership_capacity_0001')

      local conflict, conflictError = index:replaceCharacter('character_capacity_0064', {
        characterId = 'character_capacity_0064', memberships = {{
          membershipId = 'membership_capacity_0001', groupId = 'group_capacity_0001',
          characterId = 'character_capacity_0064', lifecycleState = 'ACTIVE'
        }}
      })
      assert(conflict == nil and conflictError.code == 'RUNTIME_INDEX_INVALID')
      assert(index:getCharacterContext('character_capacity_0064')
        .memberships[1].membershipId == 'membership_capacity_0064')
      local sparseMemberships = {}
      sparseMemberships[2] = {
        membershipId = 'membership_sparse_0002', groupId = 'group_capacity_0001',
        characterId = 'character_capacity_0064', lifecycleState = 'ACTIVE'
      }
      local sparse, sparseError = index:replaceCharacter('character_capacity_0064', {
        characterId = 'character_capacity_0064', memberships = sparseMemberships
      })
      assert(sparse == nil and sparseError.code == 'RUNTIME_INDEX_INVALID')
      assert(index:getCharacterContext('character_capacity_0064')
        .memberships[1].membershipId == 'membership_capacity_0064')
      local preJoin, preJoinError = index:replaceCharacter('character_capacity_0064', {
        characterId = 'character_capacity_0064', memberships = {{
          membershipId = 'membership_prejoin_0001', groupId = 'group_capacity_0001',
          characterId = 'character_capacity_0064', lifecycleState = 'INVITED'
        }}
      })
      assert(preJoin == nil and preJoinError.code == 'RUNTIME_INDEX_INVALID')
      assert(index:getCharacterContext('character_capacity_0064')
        .memberships[1].membershipId == 'membership_capacity_0064')
      local snapshot = index:snapshot()
      assert(snapshot.characters == 64 and snapshot.memberships == 64)
      return overflowError.code .. ':' .. perCharacterError.code .. ':'
        .. conflictError.code .. ':' .. snapshot.memberships
    `);
    assert.equal(
      result,
      'RUNTIME_INDEX_CAPACITY_EXCEEDED:RUNTIME_INDEX_CAPACITY_EXCEEDED:RUNTIME_INDEX_INVALID:64',
    );
  } finally {
    engine.global.close();
  }
});

test('runtime rebuild is atomic, repeatable, and clears stale restart state', async () => {
  const engine = await createEngine();
  try {
    const result = await engine.doString(`
      local Foundation = require 'server.foundation'
      local RuntimeIndex = require('server.runtime_index')(Foundation)
      local index = RuntimeIndex({ maximumCharacters = 32, maximumMemberships = 128 })
      assert(index:replaceCharacter('character_stale_0001', {
        characterId = 'character_stale_0001', memberships = {{
          membershipId = 'membership_stale_0001', groupId = 'group_stale_0001',
          characterId = 'character_stale_0001', lifecycleState = 'ACTIVE'
        }}
      }))
      local active = {
        {
          characterId = 'character_active_0001', memberships = {{
            membershipId = 'membership_active_0001', groupId = 'group_active_0001',
            characterId = 'character_active_0001', lifecycleState = 'ACTIVE'
          }}
        },
        { characterId = 'character_empty_0002', memberships = {} }
      }
      assert(index:rebuild(active))
      assert(index:isCharacterOnline('character_stale_0001') == false)
      assert(index:isCharacterOnline('character_active_0001') == true)
      assert(index:isCharacterOnline('character_empty_0002') == true)
      assert(index:rebuild(active))
      assert(index:countOnlineMembers('group_active_0001') == 1)

      local invalid, invalidError = index:rebuild({ active[1], active[1] })
      assert(invalid == nil and invalidError.code == 'RUNTIME_INDEX_INVALID')
      assert(index:countOnlineMembers('group_active_0001') == 1)
      assert(index:clear() == 1)
      local snapshot = index:snapshot()
      assert(snapshot.characters == 0 and snapshot.memberships == 0)
      assert(snapshot.rebuilds == 2 and snapshot.clears == 1)
      return table.concat({ snapshot.rebuilds, snapshot.clears,
        snapshot.characters, snapshot.memberships }, ':')
    `);
    assert.equal(result, '2:1:0:0');
  } finally {
    engine.global.close();
  }
});

test('runtime effect refreshes online characters and fails closed on loader errors', async () => {
  const engine = await createEngine();
  try {
    const result = await engine.doString(`
      local Foundation = require 'server.foundation'
      local RuntimeIndex = require('server.runtime_index')(Foundation)
      local index = RuntimeIndex({ maximumCharacters = 32, maximumMemberships = 128 })
      local characterId = 'character_effect_0001'
      assert(index:replaceCharacter(characterId, {
        characterId = characterId, memberships = {{
          membershipId = 'membership_effect_0001', groupId = 'group_effect_0001',
          characterId = characterId, lifecycleState = 'ACTIVE',
          dutySession = {
            sessionId = 'duty_effect_0001', state = 'available',
            countsAsOnDuty = true, version = 1
          }
        }}
      }))
      local calls = 0
      assert(index:applyEffect({
        action = 'duty.ended', entityType = 'duty_session', entityId = 'duty_effect_0001',
        groupId = 'group_effect_0001', characterId = characterId
      }, function(requestedCharacterId)
        calls = calls + 1
        assert(requestedCharacterId == characterId)
        return {
          characterId = characterId, memberships = {{
            membershipId = 'membership_effect_0001', groupId = 'group_effect_0001',
            characterId = characterId, lifecycleState = 'ACTIVE'
          }}
        }, nil
      end))
      assert(calls == 1 and index:countActiveDutyMembers('group_effect_0001') == 0)

      assert(index:applyEffect({
        action = 'duty.started', entityType = 'duty_session', entityId = 'duty_offline_0002',
        groupId = 'group_effect_0001', characterId = 'character_offline_0002'
      }, function() calls = calls + 1 return nil end))
      assert(calls == 1)

      local refreshed, refreshError = index:applyEffect({
        action = 'membership.activated', entityType = 'membership',
        entityId = 'membership_effect_0001',
        groupId = 'group_effect_0001', characterId = characterId
      }, function()
        calls = calls + 1
        return nil, { code = 'DATABASE_ERROR', message = 'unavailable', retryable = true }
      end)
      assert(refreshed == nil and refreshError.code == 'DATABASE_ERROR')
      assert(index:isCharacterOnline(characterId) == false)
      local snapshot = index:snapshot()
      assert(snapshot.refreshes == 1 and snapshot.refreshFailures == 1)
      return table.concat({ calls, snapshot.refreshes, snapshot.refreshFailures,
        snapshot.characters, snapshot.memberships }, ':')
    `);
    assert.equal(result, '2:1:1:0:0');
  } finally {
    engine.global.close();
  }
});

test('group and global refreshes use stable indexed character snapshots', async () => {
  const engine = await createEngine();
  try {
    const result = await engine.doString(`
      local Foundation = require 'server.foundation'
      local RuntimeIndex = require('server.runtime_index')(Foundation)
      local index = RuntimeIndex({ maximumCharacters = 32, maximumMemberships = 128 })
      local definitions = {
        character_alpha_0001 = { membershipId = 'membership_alpha_0001',
          groupId = 'group_shared_0001' },
        character_bravo_0002 = { membershipId = 'membership_bravo_0002',
          groupId = 'group_shared_0001' },
        character_charlie_0003 = { membershipId = 'membership_charlie_0003',
          groupId = 'group_other_0002' }
      }
      for characterId, membership in pairs(definitions) do
        assert(index:replaceCharacter(characterId, {
          characterId = characterId,
          memberships = {{
            membershipId = membership.membershipId,
            groupId = membership.groupId,
            characterId = characterId,
            lifecycleState = 'ACTIVE'
          }}
        }))
      end
      assert(table.concat(index:characterIds(), ',') ==
        'character_alpha_0001,character_bravo_0002,character_charlie_0003')

      local groupCalls = {}
      assert(index:refreshGroup('group_shared_0001', function(characterId)
        groupCalls[#groupCalls + 1] = characterId
        local membership = definitions[characterId]
        return {
          characterId = characterId,
          memberships = characterId == 'character_alpha_0001' and {} or {{
            membershipId = membership.membershipId,
            groupId = membership.groupId,
            characterId = characterId,
            lifecycleState = 'ACTIVE'
          }}
        }
      end))
      assert(table.concat(groupCalls, ',') ==
        'character_alpha_0001,character_bravo_0002')
      assert(index:countOnlineMembers('group_shared_0001') == 1)
      assert(index:countOnlineMembers('group_other_0002') == 1)

      GetPlayers = function() error('runtime refreshes must use the index snapshot') end
      local allCalls = {}
      assert(index:refreshAll(function(characterId)
        allCalls[#allCalls + 1] = characterId
        return { characterId = characterId, memberships = {} }
      end))
      assert(table.concat(allCalls, ',') ==
        'character_alpha_0001,character_bravo_0002,character_charlie_0003')
      local snapshot = index:snapshot()
      assert(snapshot.characters == 3 and snapshot.memberships == 0)
      return table.concat({ #groupCalls, #allCalls, snapshot.refreshes }, ':')
    `);
    assert.equal(result, '2:3:5');
  } finally {
    engine.global.close();
  }
});

test('hot count and membership-to-duty reads never scan FiveM players', async () => {
  const engine = await createEngine();
  try {
    const result = await engine.doString(`
      local Foundation = require 'server.foundation'
      local RuntimeIndex = require('server.runtime_index')(Foundation)
      local index = RuntimeIndex({ maximumCharacters = 32, maximumMemberships = 128 })
      assert(index:replaceCharacter('character_lookup_0001', {
        characterId = 'character_lookup_0001', memberships = {{
          membershipId = 'membership_lookup_0001', groupId = 'group_lookup_0001',
          characterId = 'character_lookup_0001', lifecycleState = 'ACTIVE',
          dutySession = {
            sessionId = 'duty_lookup_0001', state = 'responding',
            countsAsOnDuty = true, version = 1
          }
        }}
      }))
      GetPlayers = function() error('hot runtime reads must not scan players') end
      local originalPairs = pairs
      pairs = function() error('O(1) count and direct duty reads must not enumerate maps') end
      local online = index:countOnlineMembers('group_lookup_0001')
      local onDuty = index:countActiveDutyMembers('group_lookup_0001')
      local duty = index:getActiveDutySession('membership_lookup_0001')
      pairs = originalPairs
      assert(online == 1 and onDuty == 1 and duty.sessionId == 'duty_lookup_0001')
      return table.concat({ online, onDuty, duty.version }, ':')
    `);
    assert.equal(result, '1:1:1');
  } finally {
    engine.global.close();
  }
});

test('runtime context loader performs one bounded relational read and normalizes duty', async () => {
  const engine = await createEngine();
  try {
    const result = await engine.doString(`
      local Foundation = require 'server.foundation'
      local RuntimeContextLoader = require('server.persistence.runtime_context')(Foundation)
      local calls, observedSql, observedCharacter = 0, nil, nil
      local loader = RuntimeContextLoader({
        maximumMembershipsPerCharacter = 4,
        query = function(sql, parameters)
          calls = calls + 1
          observedSql = sql
          observedCharacter = parameters[1]
          return {
            {
              character_id = 'character_loader_0001',
              membership_id = 'membership_loader_0001', group_id = 'group_loader_0001',
              membership_state = 'ACTIVE', duty_session_id = 'duty_loader_0001',
              duty_state = 'responding', duty_version = 7,
              duty_assignment_id = 'assignment_loader_0001', duty_counts_as_on_duty = 1
            },
            {
              character_id = 'character_loader_0001',
              membership_id = 'membership_loader_0002', group_id = 'group_loader_0002',
              membership_state = 'SUSPENDED'
            }
          }, nil
        end
      })
      local context = assert(loader:loadCharacter('character_loader_0001'))
      assert(calls == 1 and observedCharacter == 'character_loader_0001')
      assert(#context.memberships == 2)
      local duty = context.memberships[1].dutySession
      assert(duty.sessionId == 'duty_loader_0001' and duty.state == 'responding')
      assert(duty.countsAsOnDuty == true and duty.version == 7)
      assert(observedSql:find('synex_group_membership_profiles', 1, true))
      assert(observedSql:find('synex_group_duty_sessions', 1, true))
      assert(observedSql:find('synex_group_duty_states', 1, true))
      assert(observedSql:find('session.+status.+open') ~= nil)
      assert(observedSql:find("'PROBATION', 'ACTIVE', 'SUSPENDED', 'LEAVE', 'INACTIVE'", 1, true))
      assert(not observedSql:find("'INVITED'", 1, true))
      assert(observedSql:find("'ARCHIVED', 'DISSOLVING', 'DELETED'", 1, true))
      assert(observedSql:find('LIMIT 5', 1, true))
      return table.concat({ calls, #context.memberships, duty.state, duty.version }, ':')
    `);
    assert.equal(result, '1:2:responding:7');
  } finally {
    engine.global.close();
  }
});

test('runtime context loader rejects overflow and malformed database rows', async () => {
  const engine = await createEngine();
  try {
    const result = await engine.doString(`
      local Foundation = require 'server.foundation'
      local RuntimeContextLoader = require('server.persistence.runtime_context')(Foundation)
      local overflowLoader = RuntimeContextLoader({
        maximumMembershipsPerCharacter = 1,
        query = function()
          return {
            {
              character_id = 'character_loader_0001',
              membership_id = 'membership_loader_0001', group_id = 'group_loader_0001',
              membership_state = 'ACTIVE'
            },
            {
              character_id = 'character_loader_0001',
              membership_id = 'membership_loader_0002', group_id = 'group_loader_0002',
              membership_state = 'ACTIVE'
            }
          }
        end
      })
      local overflow, overflowError = overflowLoader:loadCharacter('character_loader_0001')
      assert(overflow == nil and overflowError.code == 'RUNTIME_INDEX_CAPACITY_EXCEEDED')

      local invalidLoader = RuntimeContextLoader({
        query = function()
          return {{
            character_id = 'character_wrong_0002',
            membership_id = 'membership_loader_0001', group_id = 'group_loader_0001',
            membership_state = 'ACTIVE'
          }}
        end
      })
      local invalid, invalidError = invalidLoader:loadCharacter('character_loader_0001')
      assert(invalid == nil and invalidError.code == 'DATABASE_ERROR')

      local preJoinLoader = RuntimeContextLoader({
        query = function()
          return {{
            character_id = 'character_loader_0001',
            membership_id = 'membership_loader_0001', group_id = 'group_loader_0001',
            membership_state = 'APPLICANT'
          }}
        end
      })
      local preJoin, preJoinError = preJoinLoader:loadCharacter('character_loader_0001')
      assert(preJoin == nil and preJoinError.code == 'DATABASE_ERROR')

      local thrownLoader = RuntimeContextLoader({
        query = function()
          error({ code = 'DATABASE_UNAVAILABLE', message = 'offline', retryable = true }, 0)
        end
      })
      local thrown, thrownError = thrownLoader:loadCharacter('character_loader_0001')
      assert(thrown == nil and thrownError.code == 'DATABASE_UNAVAILABLE')
      return overflowError.code .. ':' .. invalidError.code .. ':'
        .. preJoinError.code .. ':' .. thrownError.code
    `);
    assert.equal(
      result,
      'RUNTIME_INDEX_CAPACITY_EXCEEDED:DATABASE_ERROR:DATABASE_ERROR:DATABASE_UNAVAILABLE',
    );
  } finally {
    engine.global.close();
  }
});

test('runtime index is composed through Core APIs without hot-path player scans', async () => {
  const [main, runtimeRegistration, scheduler, bootstrap, service, manifest, deletion] = await Promise.all([
    readFile(path.join(root, 'resources/synex_groups/server/main.lua'), 'utf8'),
    readFile(path.join(root, 'resources/synex_groups/server/runtime_registration.lua'), 'utf8'),
    readFile(path.join(root, 'resources/synex_groups/server/scheduler.lua'), 'utf8'),
    readFile(path.join(root, 'resources/synex_groups/server/core_bootstrap.lua'), 'utf8'),
    readFile(path.join(root, 'resources/synex_groups/server/service.lua'), 'utf8'),
    readFile(path.join(root, 'resources/synex_groups/fxmanifest.lua'), 'utf8'),
    readFile(path.join(root, 'resources/synex_groups/server/group_deletions.lua'), 'utf8'),
  ]);
  assert.match(main, /createRuntimeContextLoader[\s\S]*?coreDataPort:readOrError/u);
  assert.match(main, /Characters\.getActive\(source\)/u);
  assert.equal(main.match(/GetPlayers\(\)/gu)?.length, 1);
  assert.match(main, /prepare = function[\s\S]*?replaceRuntimeCharacter/u);
  assert.match(main, /rollback = function[\s\S]*?removeRuntimeCharacter/u);
  assert.match(main, /unload = function[\s\S]*?removeRuntimeCharacter/u);
  assert.match(scheduler, /report\.assignments[\s\S]*?runtimeIndex:refreshAll/u);
  assert.match(bootstrap, /registerLifecycleParticipant[\s\S]*?options\.rebuild\(api, binding\)[\s\S]*?Services\.provide/u);
  assert.match(main, /effect\.action == 'group\.suspended'[\s\S]*?refreshGroup/u);
  assert.match(main, /effect\.action == 'type\.registered'[\s\S]*?'duty_state\.registered'/u);
  assert.match(runtimeRegistration, /onResourceStop[\s\S]*?runtimeIndex:clear\(\)/u);
  const stopHandler = runtimeRegistration.slice(
    runtimeRegistration.indexOf("AddEventHandler('onResourceStop'"),
  );
  const coreStop = stopHandler.indexOf("if resourceName == 'synex_core' then");
  const generationFence = stopHandler.indexOf(
    'coreRebindGeneration = coreRebindGeneration + 1',
    coreStop,
  );
  const apiFence = stopHandler.indexOf('setCurrentApi(nil)', generationFence);
  const registrationFence = stopHandler.indexOf(
    'coreRegistration:invalidate()',
    apiFence,
  );
  const coreStopReturn = stopHandler.indexOf('return', registrationFence);
  const extensionCleanup = stopHandler.indexOf(
    'extensionRegistries:latestEpoch(resourceName)',
  );
  assert.ok(
    coreStop >= 0 &&
      generationFence > coreStop &&
      apiFence > generationFence &&
      registrationFence > apiFence &&
      coreStopReturn > registrationFence &&
      extensionCleanup > coreStopReturn,
  );
  assert.match(service, /runtimeEffects\.apply/u);
  assert.match(deletion, /onLifecycleChanged/u);
  assert.match(manifest, /'server\/runtime_index\.lua'/u);
  assert.match(manifest, /'server\/persistence\/runtime_context\.lua'/u);
});
