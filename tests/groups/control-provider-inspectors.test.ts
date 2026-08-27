import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';

const root = process.cwd();

test('Groups Control inspectors return real bounded same-domain related read models', async () => {
  const [foundationSource, providerSource] = await Promise.all([
    readFile(path.join(root, 'resources/synex_groups/server/foundation.lua'), 'utf8'),
    readFile(path.join(root, 'resources/synex_groups/server/control_provider.lua'), 'utf8'),
  ]);
  const engine = await new LuaFactory().createEngine();
  try {
    await engine.doString(`
      package.preload['server.foundation'] = assert(load(
        ${JSON.stringify(foundationSource)}, '@resources/synex_groups/server/foundation.lua'))
      local Foundation = require 'server.foundation'
      local createProvider = assert(load(
        ${JSON.stringify(providerSource)}, '@resources/synex_groups/server/control_provider.lua'))()(Foundation)

      local descriptor
      local queryKinds = {}
      local function relatedRows(kind, count)
        local rows = {}
        for index = 1, count do
          rows[index] = { item_id = kind .. '_' .. string.format('%04d', index) }
        end
        return rows
      end
      local provider = createProvider({
        database = {},
        methods = {
          get = function(request)
            assert(request.group_id == 'group_alpha_0001')
            return { group_id = request.group_id, type = 'law_enforcement', status = 'ACTIVE' }
          end,
          members_get = function(request)
            assert(request.membership_id == 'membership_alpha_0001')
            return {
              membership_id = request.membership_id,
              character_id = 'character_alpha_0001',
              group_id = 'group_alpha_0001',
              grade_id = 'grade_alpha_0001',
              status = 'ACTIVE',
            }
          end,
        },
        query = function(sql, parameters)
          if sql:find('integrity_issues', 1, true) then
            assert(parameters[1] == 'group_alpha_0001')
            return {{ members = 83, on_duty = 21, grades = 6,
              roles = 12, subgroups = 4, integrity_issues = 0 }}
          end
          local kind
          if sql:find('synex_group_membership_roles', 1, true) then kind = 'roles'
          elseif sql:find('synex_group_duty_sessions', 1, true) then kind = 'duty'
          elseif sql:find('synex_group_assignment_members', 1, true) then kind = 'assignments'
          elseif sql:find('synex_group_delegations', 1, true) then kind = 'delegations'
          end
          assert(kind ~= nil)
          queryKinds[#queryKinds + 1] = kind
          assert(#parameters == 2)
          assert(parameters[1] == 'membership_alpha_0001')
          assert(parameters[#parameters] == 9)
          return relatedRows(kind, 9)
        end,
        errorSink = function() error('unexpected control error') end,
        getApi = function() return { ownerEpoch = 7 } end,
      })
      assert(provider:register({ ControlProviders = { register = function(value)
        descriptor = value
        return { namespace = value.namespace }
      end } }))

      local context = { traceId = 'trace_groups_control_001' }
      local group = assert(descriptor.operations.inspect({
        view = 'group', id = 'group_alpha_0001', limit = 8,
      }, context))
      assert(group.counts.members == 83 and group.counts.onDuty == 21)
      assert(group.counts.grades == 6 and group.counts.roles == 12)
      assert(group.counts.subgroups == 4 and group.health.status == 'HEALTHY')
      assert(group.links.members.filters.group_id == 'group_alpha_0001')
      assert(group.links.members.requiresActor == true)

      local membership = assert(descriptor.operations.inspect({
        view = 'membership', id = 'membership_alpha_0001', limit = 25,
      }, context))
      assert(membership.character_id == 'character_alpha_0001')
      assert(table.concat(queryKinds, ',') == 'roles,duty,assignments,delegations')
      for _, name in ipairs({ 'roles', 'duty', 'assignments', 'delegations' }) do
        local section = membership[name]
        assert(#section.items == 8 and section.limit == 8)
        assert(section.hasMore == true and section.truncated == true)
      end
      assert(membership.delegations.scope == 'effective_received')
      assert(membership.links.group.id == 'group_alpha_0001')
      return true
    `);
  } finally {
    engine.global.close();
  }
  assert.ok(true);
});
