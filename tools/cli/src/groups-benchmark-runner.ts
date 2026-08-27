import { readFile } from "node:fs/promises";
import { basename, dirname, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

import { LuaFactory, type LuaEngine } from "wasmoon";

interface RawLuaMeasurement {
  samplesMilliseconds: number[];
  checksum: number;
}

export interface RawGroupsLuaReport {
  measurements: Record<string, RawLuaMeasurement>;
  checksum: number;
}

const moduleRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");
const repositoryRoot = basename(moduleRoot) === ".build" ? resolve(moduleRoot, "..") : moduleRoot;

const modules = [
  ["server.foundation", "resources/synex_groups/server/foundation.lua"],
  ["server.domain.constants", "resources/synex_groups/server/domain/constants.lua"],
  ["server.domain.lifecycle", "resources/synex_groups/server/domain/lifecycle.lua"],
  ["server.domain.capabilities", "resources/synex_groups/server/domain/capabilities.lua"],
  ["server.persistence.organizations_shared", "resources/synex_groups/server/persistence/organizations_shared.lua"],
  ["server.persistence.organizations_read", "resources/synex_groups/server/persistence/organizations_read.lua"],
  ["server.persistence.memberships_shared", "resources/synex_groups/server/persistence/memberships_shared.lua"],
  ["server.persistence.memberships_read", "resources/synex_groups/server/persistence/memberships_read.lua"],
  ["server.persistence.definition_cache", "resources/synex_groups/server/persistence/definition_cache.lua"],
  ["server.persistence.capability_access", "resources/synex_groups/server/persistence/capability_access.lua"],
  ["server.persistence.governance_shared", "resources/synex_groups/server/persistence/governance_shared.lua"],
  ["server.persistence.governance_policies", "resources/synex_groups/server/persistence/governance_policies.lua"],
  ["server.runtime_index", "resources/synex_groups/server/runtime_index.lua"],
] as const;

async function preload(engine: LuaEngine, name: string, relativePath: string): Promise<void> {
  const source = await readFile(resolve(repositoryRoot, relativePath), "utf8");
  await engine.doString(
    `package.preload[${JSON.stringify(name)}] = assert(load(${JSON.stringify(source)}, ${JSON.stringify(`@${relativePath}`)}))`,
  );
}

export async function runGroupsLuaBenchmark(
  iterations: number,
  samples: number,
  seed: number,
): Promise<RawGroupsLuaReport> {
  if (!Number.isInteger(iterations) || iterations < 1 || iterations > 100_000
    || !Number.isInteger(samples) || samples < 1 || samples > 20
    || !Number.isInteger(seed) || seed < 0 || seed > 0xffff_ffff) {
    throw new Error("Groups Lua benchmark parameters are outside supported bounds.");
  }
  const engine = await new LuaFactory().createEngine();
  try {
    for (const [name, relativePath] of modules) await preload(engine, name, relativePath);
    return await engine.doString(`
      local Foundation = require 'server.foundation'
      local Organizations = require('server.persistence.organizations_read')(Foundation)
      local Memberships = require('server.persistence.memberships_read')(Foundation)
      local Capabilities = require 'server.domain.capabilities'
      local DefinitionCache = require('server.persistence.definition_cache')(Foundation)
      local CapabilityAccess = require('server.persistence.capability_access')(Foundation)
      local Policies = require('server.persistence.governance_policies')(Foundation)
      local RuntimeIndex = require('server.runtime_index')(Foundation)

      local groupRows = {}
      for number = 0, 1023 do
        local groupId = string.format('group_benchmark_%04d', number)
        groupRows[groupId] = {
          group_public_id = groupId,
          display_name = 'Benchmark Group ' .. tostring(number),
          status = 'active',
          version = (number % 17) + 1,
          created_at = '2026-01-01T00:00:00.000000Z',
          updated_at = '2026-01-01T00:00:00.000000Z',
          type_key = number % 2 == 0 and 'government' or 'business',
          slug = string.format('benchmark-group-%04d', number),
          name = 'benchmark_group_' .. tostring(number),
          label = 'Benchmark Group ' .. tostring(number),
          description = 'Local benchmark fixture.',
          dynamic = 0,
          visibility = 'public',
          lifecycle_state = 'ACTIVE'
        }
      end
      local groupTx = {
        one = function(_, parameters) return groupRows[parameters[1]] end
      }

      local membershipRows = {}
      for number = 0, 2047 do
        local membershipId = string.format('membership_benchmark_%04d', number)
        membershipRows[membershipId] = {
          membership_id = membershipId,
          group_id = string.format('group_benchmark_%04d', number % 64),
          character_id = string.format('character_benchmark_%04d', number),
          grade_id = string.format('grade_benchmark_%02d', number % 32),
          status = 'ACTIVE',
          visibility = 'members',
          joined_at = '2026-01-01T00:00:00Z',
          version = (number % 13) + 1
        }
      end
      local membershipTx = {
        one = function(_, parameters) return membershipRows[parameters[1]] end
      }

      local capabilityEvaluator = Capabilities.create({
        now = function() return 1767225600 end,
        maximumRules = 64,
        maximumRoles = 8,
        maximumDelegations = 8,
        evaluateRules = function(permission, rules)
          local matches, allowed, denied = {}, false, false
          for index, rule in ipairs(rules) do
            local pattern = rule.permission
            local matched = pattern == permission
            if not matched and type(pattern) == 'string' and pattern:sub(-2) == '.*' then
              local prefix = pattern:sub(1, -3)
              matched = permission:sub(1, #prefix + 1) == prefix .. '.'
            end
            if matched then
              matches[#matches + 1] = {
                index = index,
                permission = pattern,
                effect = rule.effect
              }
              if rule.effect == 'deny' then denied = true else allowed = true end
            end
          end
          return {
            matches = matches,
            denied = denied,
            allowed = allowed and not denied
          }, nil
        end
      })
      local capabilityTx = {
        one = function(sql, parameters)
          if sql:find('FROM synex_group_memberships AS membership', 1, true) then
            local characterId = parameters[2]
            local number = tonumber(characterId:match('(%d+)$')) or 0
            return {
              id = number + 1,
              public_id = string.format('membership_capability_%02d', number),
              version = 1,
              lifecycle_state = 'ACTIVE',
              group_internal_id = 1,
              definition_revision = 1,
              grade_internal_id = number + 1,
              grade_public_id = string.format('grade_capability_%02d', number)
            }
          end
          if sql:find('FROM synex_group_read_model_versions', 1, true) then
            return { model_version = 1 }
          end
          error('unexpected capability benchmark scalar query')
        end,
        many = function(sql, parameters)
          if sql:find('FROM synex_group_default_capabilities', 1, true) then
            return {{
              id = 1,
              capability_pattern = 'synex.groups.common.read',
              effect = 'allow',
              scope_kind = 'group',
              scope_ref = '',
              delegable = 0
            }}
          end
          if sql:find('FROM synex_group_grade_capabilities', 1, true) then
            local number = parameters[1] - 1
            return {{
              id = number + 1,
              capability_pattern = string.format(
                'synex.groups.grade_%d.read', number),
              effect = 'allow',
              scope_kind = 'group',
              scope_ref = '',
              delegable = 1
            }}
          end
          if sql:find('FROM synex_group_membership_roles', 1, true)
            or sql:find('FROM synex_group_delegations', 1, true)
            or sql:find('FROM synex_group_membership_capabilities', 1, true) then
            return {}
          end
          error('unexpected capability benchmark row query')
        end
      }
      local capabilityAccess = CapabilityAccess({
        evaluator = capabilityEvaluator,
        getStoredPolicyEvaluator = function() return nil end,
        getRuntime = function() return {} end,
        definitionCache = DefinitionCache({ maximum = 256 })
      })
      for number = 0, 31 do
        local capability = string.format('synex.groups.grade_%d.read', number)
        local value, valueError = capabilityAccess.evaluateCharacter(
          capabilityTx,
          'group_benchmark_authority',
          string.format('character_capability_%02d', number),
          capability,
          'group',
          false)
        assert(value and not valueError and value.allowed)
      end

      local runtimeContexts = {}
      for number = 1, 2048 do
        local suffix = string.format('%04d', number)
        local groupNumber = ((number - 1) % 64) + 1
        local memberNumber = math.floor((number - 1) / 64)
        runtimeContexts[number] = {
          characterId = 'character_runtime_' .. suffix,
          memberships = {{
            membershipId = 'membership_runtime_' .. suffix,
            groupId = string.format('group_runtime_%02d', groupNumber),
            characterId = 'character_runtime_' .. suffix,
            lifecycleState = 'ACTIVE',
            dutySession = {
              sessionId = 'duty_runtime_' .. suffix,
              state = 'available',
              countsAsOnDuty = memberNumber % 4 == 0,
              version = 1
            }
          }}
        }
      end
      local runtimeIndex = RuntimeIndex({
        maximumCharacters = 4096,
        maximumMemberships = 8192,
        maximumMembershipsPerCharacter = 4
      })
      assert(runtimeIndex:rebuild(runtimeContexts))

      local policyRules = {}
      for number = 1, 16 do
        policyRules[number] = {
          rule_key = string.format('benchmark_rule_%02d', number),
          priority = 17 - number,
          effect = number == 16 and 'allow' or 'deny',
          action_pattern = number == 16
            and 'membership.transition'
            or string.format('membership.action_%d', number),
          subject_kind = 'character',
          scope_kind = 'group',
          scope_ref = '',
          condition_json = nil
        }
      end
      local policyTx = {
        one = function(sql)
          if sql:find('SELECT version FROM synex_group_policies', 1, true) then
            return { version = 1 }
          end
          if sql:find('FROM synex_group_policies', 1, true) then
            return {
              id = 1,
              public_id = 'policy_benchmark_transition',
              default_effect = 'deny',
              version = 1
            }
          end
          error('unexpected policy benchmark query')
        end,
        many = function() return policyRules end
      }
      local policyRuntime = {
        definitionCache = DefinitionCache({ maximum = 256 }),
        requireGroup = function()
          return { id = 1, status = 'active', lifecycle_state = 'ACTIVE' }, nil
        end,
        jsonDecode = function() error('policy benchmark conditions are not encoded') end
      }
      local policyInput = {
        group_id = 'group_benchmark_authority',
        action = 'membership.transition',
        actor_membership = { id = 1 },
        parameters = {},
        scope = 'group'
      }
      local primedPolicy, primeError = Policies.evaluateStoredPolicy(
        policyTx, policyInput, policyRuntime)
      assert(primedPolicy and not primeError and primedPolicy.decision == 'ALLOW')

      local workloads = {
        groups_group_lookup = function(index)
          local groupId = string.format('group_benchmark_%04d', (index + ${seed}) & 1023)
          local value, valueError = Organizations.read.get(
            groupTx, { group_id = groupId }, {})
          assert(value and not valueError)
          return value.version
        end,
        groups_membership_lookup = function(index)
          local membershipId = string.format(
            'membership_benchmark_%04d', (index + ${seed}) & 2047)
          local value, valueError = Memberships.read.members_get(
            membershipTx, { membership_id = membershipId })
          assert(value and not valueError)
          return value.version
        end,
        groups_effective_capability_lookup = function(index)
          local number = (index + ${seed}) % 32
          local capability = string.format('synex.groups.grade_%d.read', number)
          local value, valueError = capabilityAccess.evaluateCharacter(
            capabilityTx,
            'group_benchmark_authority',
            string.format('character_capability_%02d', number),
            capability,
            'group',
            false)
          assert(value and not valueError and value.allowed)
          return value.evaluatedRules
        end,
        groups_online_members_lookup = function(index)
          local groupId = string.format(
            'group_runtime_%02d', ((index + ${seed}) % 64) + 1)
          return runtimeIndex:countOnlineMembers(groupId)
        end,
        groups_on_duty_members_lookup = function(index)
          local groupId = string.format(
            'group_runtime_%02d', ((index + ${seed}) % 64) + 1)
          return runtimeIndex:countActiveDutyMembers(groupId)
        end,
        groups_policy_evaluation = function()
          local value, valueError = Policies.evaluateStoredPolicy(
            policyTx, policyInput, policyRuntime)
          assert(value and not valueError and value.decision == 'ALLOW')
          return #value.trace + 1
        end
      }

      local names = {
        'groups_group_lookup',
        'groups_membership_lookup',
        'groups_effective_capability_lookup',
        'groups_online_members_lookup',
        'groups_on_duty_members_lookup',
        'groups_policy_evaluation'
      }
      local report = { measurements = {}, checksum = 0 }
      local warmup = math.min(${iterations}, 1000)
      for _, name in ipairs(names) do
        local operation = workloads[name]
        local workloadChecksum = 0
        for index = 0, warmup - 1 do
          workloadChecksum = (workloadChecksum + operation(index)) & 0xffffffff
        end
        local elapsed = {}
        for sample = 1, ${samples} do
          local started = os.clock()
          for index = 0, ${iterations} - 1 do
            workloadChecksum = (workloadChecksum + operation(index)) & 0xffffffff
          end
          elapsed[sample] = math.max(0, (os.clock() - started) * 1000)
        end
        report.measurements[name] = {
          samplesMilliseconds = elapsed,
          checksum = workloadChecksum
        }
        report.checksum = (report.checksum + workloadChecksum) & 0xffffffff
      end
      return report
    `) as RawGroupsLuaReport;
  } finally {
    engine.global.close();
  }
}

const invoked = process.argv[1]
  ? pathToFileURL(resolve(process.argv[1])).href === import.meta.url
  : false;

if (invoked) {
  const iterations = Number(process.argv[2]);
  const samples = Number(process.argv[3]);
  const seed = Number(process.argv[4]);
  try {
    const report = await runGroupsLuaBenchmark(iterations, samples, seed);
    process.stdout.write(JSON.stringify(report));
  } catch (error) {
    process.stderr.write(error instanceof Error ? error.message : "Groups Lua benchmark failed.");
    process.exitCode = 1;
  }
}
