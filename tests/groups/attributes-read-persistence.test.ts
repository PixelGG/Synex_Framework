import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';

const root = process.cwd();

test('membership attribute reads enforce public, member, management, private, and schema gates', async () => {
  const [foundationSource, sharedSource, valuesSource, attributesSource] = await Promise.all([
    readFile(path.join(root, 'resources/synex_groups/server/foundation.lua'), 'utf8'),
    readFile(path.join(
      root,
      'resources/synex_groups/server/persistence/governance_shared.lua',
    ), 'utf8'),
    readFile(path.join(
      root,
      'resources/synex_groups/server/persistence/governance_attribute_values.lua',
    ), 'utf8'),
    readFile(path.join(
      root,
      'resources/synex_groups/server/persistence/governance_attributes.lua',
    ), 'utf8'),
  ]);
  const engine = await new LuaFactory().createEngine();
  try {
    const result = await engine.doString(`
      local Foundation = assert(load(${JSON.stringify(foundationSource)},
        '@server/foundation.lua'))()
      package.preload['server.persistence.governance_shared'] = assert(load(
        ${JSON.stringify(sharedSource)}, '@server/persistence/governance_shared.lua'))
      package.preload['server.persistence.governance_attribute_values'] = assert(load(
        ${JSON.stringify(valuesSource)}, '@server/persistence/governance_attribute_values.lua'))
      local Attributes = assert(load(${JSON.stringify(attributesSource)},
        '@server/persistence/governance_attributes.lua'))()(Foundation)

      local function fixture(visibility, capability, actorIsMember)
        local authorization = {}
        local tx = {}
        function tx.one(sql)
          if sql:find('schema.namespace', 1, true) then
            return {
              attribute_public_id = 'group_attribute_00000001',
              membership_internal_id = 10,
              membership_public_id = 'group_member_00000001',
              group_internal_id = 20,
              group_public_id = 'groups_group_00000001',
              character_id = 'character_subject_0001', lifecycle_state = 'ACTIVE',
              namespace = 'police', attribute_key = 'callsign',
              visibility = visibility, capability = capability,
              value_kind = 'string', value_string = 'ADAM-12', version = 3
            }
          end
          if sql:find("profile.lifecycle_state = 'ACTIVE'", 1, true) then
            return actorIsMember and { id = 99 } or nil
          end
          error('unexpected attribute read query: ' .. sql)
        end
        local runtime = {
          jsonDecode = function() return {} end,
          authorize = function(_, groupId, actorId, requestedCapability)
            authorization[#authorization + 1] = requestedCapability
            assert(groupId == 'groups_group_00000001')
            assert(actorId == 'character_actor_0002'
              or actorId == 'character_subject_0001')
            return { id = 99 }, nil
          end
        }
        return tx, runtime, authorization
      end

      local publicTx, publicRuntime, publicAuthorization = fixture('public', nil, false)
      local public = assert(Attributes.read.attributes_get(publicTx, {
        actor_character_id = 'character_actor_0002',
        membership_id = 'group_member_00000001', namespace = 'police', key = 'callsign'
      }, publicRuntime))
      assert(public.value == 'ADAM-12' and public.version == 3
        and #publicAuthorization == 0)

      local privateTx, privateRuntime = fixture('private', nil, false)
      local denied, privateError = Attributes.read.attributes_get(privateTx, {
        actor_character_id = 'character_actor_0002',
        membership_id = 'group_member_00000001', namespace = 'police', key = 'callsign'
      }, privateRuntime)
      assert(denied == nil and privateError.code == 'ATTRIBUTE_NOT_FOUND')
      local own = assert(Attributes.read.attributes_get(privateTx, {
        actor_character_id = 'character_subject_0001',
        membership_id = 'group_member_00000001', namespace = 'police', key = 'callsign'
      }, privateRuntime))
      assert(own.value == 'ADAM-12')

      local memberTx, memberRuntime, memberAuthorization = fixture('members', nil, true)
      assert(Attributes.read.attributes_get(memberTx, {
        actor_character_id = 'character_actor_0002',
        membership_id = 'group_member_00000001', namespace = 'police', key = 'callsign'
      }, memberRuntime))
      assert(#memberAuthorization == 0)

      local managementTx, managementRuntime, managementAuthorization = fixture(
        'management', 'police.attributes.read', false)
      assert(Attributes.read.attributes_get(managementTx, {
        actor_character_id = 'character_actor_0002',
        membership_id = 'group_member_00000001', namespace = 'police', key = 'callsign'
      }, managementRuntime))
      assert(#managementAuthorization == 2)
      assert(managementAuthorization[1] == 'synex.groups.attributes.read')
      assert(managementAuthorization[2] == 'police.attributes.read')

      return table.concat({ public.value, privateError.code,
        #memberAuthorization, #managementAuthorization }, ':')
    `);
    assert.equal(result, 'ADAM-12:ATTRIBUTE_NOT_FOUND:0:2');
  } finally {
    engine.global.close();
  }
});
