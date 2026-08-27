import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory, type LuaEngine } from 'wasmoon';

const root = process.cwd();
const domainModules = [
  'constants',
  'lifecycle',
  'graph',
  'capabilities',
  'policy',
  'registry',
] as const;

async function bootstrapDomain(engine: LuaEngine): Promise<void> {
  for (const name of domainModules) {
    const relativePath = `resources/synex_groups/server/domain/${name}.lua`;
    const source = await readFile(path.join(root, relativePath), 'utf8');
    await engine.doString(
      `package.preload[${JSON.stringify(`server.domain.${name}`)}] = assert(load(${JSON.stringify(source)}, ${JSON.stringify(`@${relativePath}`)}))`,
    );
  }
  await engine.doString(`
    function SYNEX_GROUPS_TEST_RULE_EVALUATOR(permission, rules)
      local matches, allows, denies = {}, 0, 0
      for index, rule in ipairs(rules) do
        local pattern = rule.permission
        local matched = pattern == permission
        if not matched and pattern:sub(-2) == '.*' then
          local prefix = pattern:sub(1, -3)
          matched = permission:sub(1, #prefix + 1) == prefix .. '.'
        end
        if matched then
          matches[#matches + 1] = {
            index = index, permission = pattern, effect = rule.effect
          }
          if rule.effect == 'deny' then denies = denies + 1 else allows = allows + 1 end
        end
      end
      return {
        permission = permission, matches = matches,
        matchedAllows = allows, matchedDenies = denies,
        denied = denies > 0, allowed = allows > 0 and denies == 0
      }, nil
    end
  `);
}

test('organization domain modules are pure Lua without runtime, SQL, or network coupling', async () => {
  for (const name of domainModules) {
    const source = await readFile(
      path.join(root, 'resources', 'synex_groups', 'server', 'domain', `${name}.lua`),
      'utf8',
    );
    assert.doesNotMatch(source, /\bMySQL\b|oxmysql|RegisterNetEvent|RegisterServerEvent|TriggerClientEvent/u, name);
    assert.doesNotMatch(source, /PerformHttpRequest|Citizen\.|CreateThread|Wait\s*\(/u, name);
    assert.doesNotMatch(source, /\b(?:load|loadstring|dofile)\s*\(/u, name);
  }
});

test('all organization lifecycles expose explicit forward-only transitions and terminal states', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrapDomain(engine);
    const result = await engine.doString(`
      local Constants = require 'server.domain.constants'
      local Lifecycle = require 'server.domain.lifecycle'
      local expected = {
        group = { 'active', 'suspended', false },
        membership = { 'DRAFT', 'INVITED', false },
        invite = { 'pending', 'accepted', true },
        application = { 'submitted', 'reviewing', false },
        duty = { 'open', 'closed', true },
        assignment = { 'active', 'completed', true },
        proposal = { 'pending', 'approved', false }
      }
      local entityCount = 0
      for entity, transition in pairs(expected) do
        entityCount = entityCount + 1
        local changed, failure = Lifecycle.transition(entity, transition[1], transition[2])
        assert(failure == nil and changed.entity == entity)
        assert(changed.from == transition[1] and changed.to == transition[2])
        assert(changed.terminal == transition[3])
      end
      assert(entityCount == 7 and #Constants.entities() == 7)
      local bypass, bypassError = Lifecycle.transition('membership', 'DRAFT', 'ACTIVE')
      assert(bypass == nil and bypassError.code == 'LIFECYCLE_TRANSITION_DENIED')
      bypass, bypassError = Lifecycle.transition('membership', 'APPLICANT', 'ACTIVE')
      assert(bypass == nil and bypassError.code == 'LIFECYCLE_TRANSITION_DENIED')

      local schemaStates = {
        group = {
          draft = true, active = true, suspended = true,
          archived = true, dissolving = true, deleted = true
        },
        membership = {
          DRAFT = true, INVITED = true, APPLICANT = true, UNDER_REVIEW = true,
          APPROVED = true, PROBATION = true, ACTIVE = true, SUSPENDED = true,
          LEAVE = true, INACTIVE = true, TERMINATED = true, BANNED = true,
          LEFT = true, ARCHIVED = true
        },
        invite = { pending = true, accepted = true, declined = true, revoked = true, expired = true },
        application = {
          submitted = true, reviewing = true, approved = true, rejected = true,
          withdrawn = true, expired = true
        },
        duty = { open = true, closed = true },
        assignment = { active = true, completed = true, cancelled = true, expired = true },
        proposal = {
          pending = true, approved = true, rejected = true,
          executed = true, cancelled = true, expired = true
        }
      }
      for entity, expectedStates in pairs(schemaStates) do
        local states = assert(Constants.states(entity))
        local expectedCount = 0
        for _ in pairs(expectedStates) do expectedCount = expectedCount + 1 end
        assert(#states == expectedCount)
        for _, state in ipairs(states) do assert(expectedStates[state] == true, entity .. ':' .. state) end
      end

      assert(Constants.canTransition('group', 'draft', 'active') == true)
      assert(Constants.canTransition('group', 'archived', 'dissolving') == true)
      assert(Constants.canTransition('group', 'dissolving', 'deleted') == true)
      assert(Constants.canTransition('group', 'archived', 'deleted') == false)
      assert(Constants.isTerminal('group', 'deleted') == true)

      local matrixChecks = 0
      for _, entity in ipairs(Constants.entities()) do
        local states = assert(Constants.states(entity))
        for _, current in ipairs(states) do
          local targets = assert(Constants.targets(entity, current))
          local expectedTargets = {}
          for _, target in ipairs(targets) do expectedTargets[target] = true end
          assert(Constants.isTerminal(entity, current) == (#targets == 0))
          for _, target in ipairs(states) do
            local allowed, transitionError = Lifecycle.canTransition(entity, current, target)
            if expectedTargets[target] then
              assert(allowed == true and transitionError == nil)
            elseif target == current then
              assert(allowed == false and transitionError.code == 'LIFECYCLE_NO_CHANGE')
            else
              assert(allowed == false and transitionError.code == 'LIFECYCLE_TRANSITION_DENIED')
            end
            matrixChecks = matrixChecks + 1
          end
        end
      end
      assert(matrixChecks > 100)

      local terminal = assert(Lifecycle.transition('proposal', 'approved', 'executed'))
      assert(terminal.terminal == true)
      assert(Lifecycle.transition('membership', 'APPLICANT', 'UNDER_REVIEW'))
      assert(Lifecycle.transition('membership', 'APPROVED', 'PROBATION'))
      assert(Lifecycle.transition('membership', 'ACTIVE', 'LEAVE'))
      local applicationExpired = assert(
        Lifecycle.transition('application', 'submitted', 'expired'))
      assert(applicationExpired.terminal == true)
      assert(Lifecycle.transition('application', 'reviewing', 'approved'))
      local directApproval, directApprovalError =
        Lifecycle.transition('application', 'submitted', 'approved')
      assert(directApproval == nil
        and directApprovalError.code == 'LIFECYCLE_TRANSITION_DENIED')
      local banned = assert(Lifecycle.transition('membership', 'ACTIVE', 'BANNED'))
      assert(banned.terminal == true)
      local impossible, impossibleError = Lifecycle.transition('invite', 'accepted', 'pending')
      assert(impossible == nil and impossibleError.code == 'LIFECYCLE_TRANSITION_DENIED')
      local unchanged, unchangedError = Lifecycle.transition('group', 'active', 'active')
      assert(unchanged == nil and unchangedError.code == 'LIFECYCLE_NO_CHANGE')
      local unknown, unknownError = Lifecycle.transition('unknown', 'active', 'archived')
      assert(unknown == nil and unknownError.code == 'LIFECYCLE_ENTITY_INVALID')
      local targets = assert(Lifecycle.allowedTargets('group', 'active'))
      assert(#targets == 2 and targets[1] == 'archived' and targets[2] == 'suspended')
      targets[1] = 'tampered'
      local freshTargets = assert(Lifecycle.allowedTargets('group', 'active'))
      assert(freshTargets[1] == 'archived')
      return table.concat({ entityCount, terminal.to, impossibleError.code, freshTargets[1] }, ':')
    `);
    assert.equal(result, '7:executed:LIFECYCLE_TRANSITION_DENIED:archived');
  } finally {
    engine.global.close();
  }
});

test('group-parent graph detection rejects cycles, self-parenting, and oversized graphs', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrapDomain(engine);
    const result = await engine.doString(`
      local Graph = require 'server.domain.graph'
      local tree = { group_a = 'group_b', group_b = 'group_c' }
      local clean = assert(Graph.detectGroupParents(tree))
      assert(clean.cyclic == false and clean.nodes == 3 and #clean.cycle == 0)
      local proposed = assert(Graph.wouldCreateGroupParentCycle(tree, 'group_c', 'group_a'))
      assert(proposed.cyclic == true and proposed.cycle[1] == proposed.cycle[#proposed.cycle])
      local selfCycle = assert(Graph.wouldCreateGroupParentCycle({}, 'group_a', 'group_a'))
      assert(selfCycle.cyclic == true and #selfCycle.cycle == 2)
      local removed = assert(Graph.wouldCreateGroupParentCycle({ group_a = 'group_b', group_b = 'group_a' }, 'group_b', nil))
      assert(removed.cyclic == false)
      local tooLarge, limitError = Graph.detectGroupParents(tree, { maximumNodes = 2 })
      assert(tooLarge == nil and limitError.code == 'GRAPH_TOO_LARGE')
      local trapCalls = 0
      local hostile = setmetatable({}, {
        __metatable = 'protected',
        __pairs = function() trapCalls = trapCalls + 1 error('must not iterate') end
      })
      local rejected, rejectedError = Graph.detectGroupParents(hostile)
      assert(rejected == nil and rejectedError.code == 'GRAPH_INVALID' and trapCalls == 0)
      return table.concat({ clean.nodes, tostring(proposed.cyclic), tostring(selfCycle.cyclic), limitError.code, trapCalls }, ':')
    `);
    assert.equal(result, '3:true:true:GRAPH_TOO_LARGE:0');
  } finally {
    engine.global.close();
  }
});

test('reports-to graph detection is deterministic and catches proposed indirect cycles', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrapDomain(engine);
    const result = await engine.doString(`
      local Graph = require 'server.domain.graph'
      local hierarchy = { member_c = 'member_b', member_b = 'member_a' }
      local clean = assert(Graph.detectReportsTo(hierarchy))
      assert(clean.cyclic == false and clean.nodes == 3)
      local cycle = assert(Graph.wouldCreateReportsToCycle(hierarchy, 'member_a', 'member_c'))
      assert(cycle.cyclic == true)
      assert(table.concat(cycle.cycle, ',') == 'member_a,member_c,member_b,member_a')
      local invalid, invalidError = Graph.wouldCreateReportsToCycle(hierarchy, 'bad member', 'member_a')
      assert(invalid == nil and invalidError.code == 'GRAPH_NODE_INVALID')
      return table.concat({ clean.nodes, table.concat(cycle.cycle, '>'), invalidError.code }, ':')
    `);
    assert.equal(result, '3:member_a>member_c>member_b>member_a:GRAPH_NODE_INVALID');
  } finally {
    engine.global.close();
  }
});

test('capability composition applies every layer, exact scope, wildcard boundaries, and deny-wins', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrapDomain(engine);
    const result = await engine.doString(`
      local Capabilities = require 'server.domain.capabilities'
      local evaluator = Capabilities.create({
        now = function() return 1000 end,
        evaluateRules = SYNEX_GROUPS_TEST_RULE_EVALUATOR
      })
      local decision = assert(evaluator:evaluate({
        capability = 'synex.groups.members.invite',
        scope = { groupId = 'group-a', departmentId = 'ops' },
        defaults = {
          { id = 'default-read', capability = 'synex.groups.*', effect = 'allow', scope = { groupId = 'group-a' } },
          { id = 'boundary', capability = 'synex.group.*', effect = 'deny' }
        },
        grade = { id = 'grade-chief', rules = {
          { id = 'grade-allow', capability = 'synex.groups.members.invite', effect = 'allow',
            scope = { groupId = 'group-a', departmentId = '*' } }
        } },
        roles = {{ id = 'role-auditor', rules = {
          { id = 'role-deny', capability = 'synex.groups.members.*', effect = 'deny', scope = { groupId = 'group-a' } }
        } }},
        membership = { id = 'membership-a', rules = {
          { id = 'member-other', capability = 'synex.groups.assignments.read', effect = 'allow' }
        } },
        delegations = {{ id = 'delegation-a', validFrom = 900, validUntil = 1100, rules = {
          { id = 'delegated-allow', capability = 'synex.groups.members.invite', effect = 'allow',
            scope = { groupId = 'group-a' } }
        } }}
      }))
      assert(decision.decision == 'DENY' and decision.denied == true and decision.allowed == false)
      assert(decision.matchedAllows == 3 and decision.matchedDenies == 1)
      assert(decision.evaluatedRules == 6 and #decision.trace == 6)
      assert(decision.trace[1].layer == 'defaults' and decision.trace[1].reason == 'MATCHED')
      assert(decision.trace[2].reason == 'CAPABILITY_MISMATCH')
      assert(decision.trace[4].layer == 'role' and decision.trace[4].effect == 'deny')

      local wrongScope = assert(evaluator:evaluate({
        capability = 'synex.groups.members.invite', scope = { groupId = 'group-b' },
        defaults = {{ capability = 'synex.groups.*', effect = 'allow', scope = { groupId = 'group-a' } }}
      }))
      assert(wrongScope.allowed == false and wrongScope.trace[1].reason == 'SCOPE_MISMATCH')
      return table.concat({ decision.decision, decision.matchedAllows, decision.matchedDenies,
        decision.trace[2].reason, wrongScope.reason }, ':')
    `);
    assert.equal(result, 'DENY:3:1:CAPABILITY_MISMATCH:NO_MATCHING_ALLOW');
  } finally {
    engine.global.close();
  }
});

test('capability time windows and revoked sources use the injected clock and fail closed', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrapDomain(engine);
    const result = await engine.doString(`
      local Capabilities = require 'server.domain.capabilities'
      local clockCalls = 0
      local evaluator = Capabilities.create({
        now = function() clockCalls = clockCalls + 1 return 200 end,
        evaluateRules = SYNEX_GROUPS_TEST_RULE_EVALUATOR
      })
      local decision = assert(evaluator:evaluate({
        capability = 'synex.groups.duty.start',
        roles = {{ id = 'future-role', validFrom = 201, rules = {
          { capability = 'synex.groups.duty.start', effect = 'deny' }
        } }},
        membership = { id = 'expired-membership', rules = {
          { capability = 'synex.groups.duty.start', effect = 'deny', validUntil = 200 }
        } },
        delegations = {
          { id = 'active-delegation', validFrom = 100, validUntil = 201, rules = {
            { capability = 'synex.groups.duty.start', effect = 'allow' }
          } },
          { id = 'revoked-delegation', revoked = true, rules = {
            { capability = 'synex.groups.duty.start', effect = 'deny' }
          } }
        }
      }))
      assert(clockCalls == 1 and decision.allowed == true and decision.denied == false)
      assert(decision.trace[1].reason == 'SOURCE_NOT_YET_VALID')
      assert(decision.trace[2].reason == 'RULE_EXPIRED')
      assert(decision.trace[3].reason == 'MATCHED')
      assert(decision.trace[4].reason == 'SOURCE_REVOKED')
      local boundary = assert(evaluator:evaluate({
        capability = 'synex.groups.duty.start', at = 201,
        delegations = {{ id = 'expired', validUntil = 201, rules = {
          { capability = 'synex.groups.duty.start', effect = 'allow' }
        } }}
      }))
      assert(clockCalls == 1 and boundary.allowed == false and boundary.trace[1].reason == 'SOURCE_EXPIRED')
      local brokenClock = Capabilities.create({
        now = function() error('private clock detail') end,
        evaluateRules = SYNEX_GROUPS_TEST_RULE_EVALUATOR
      })
      local failed, clockError = brokenClock:evaluate({ capability = 'synex.groups.read' })
      assert(failed == nil and clockError.code == 'CAPABILITY_CLOCK_FAILED')
      return table.concat({ decision.decision, decision.trace[1].reason,
        decision.trace[4].reason, boundary.trace[1].reason, clockError.code }, ':')
    `);
    assert.equal(
      result,
      'ALLOW:SOURCE_NOT_YET_VALID:SOURCE_REVOKED:SOURCE_EXPIRED:CAPABILITY_CLOCK_FAILED',
    );
  } finally {
    engine.global.close();
  }
});

test('capability delegation evidence is explicit, deny-wins, and never inherited from delegations', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrapDomain(engine);
    const result = await engine.doString(`
      local Capabilities = require 'server.domain.capabilities'
      local evaluator = Capabilities.create({
        now = function() return 1000 end,
        evaluateRules = SYNEX_GROUPS_TEST_RULE_EVALUATOR
      })
      local allowed = assert(evaluator:evaluate({
        capability = 'synex.groups.members.invite',
        defaults = {{ capability = 'synex.groups.members.*', effect = 'allow', delegable = true }},
        roles = {{ id = 'role-reader', rules = {{
          capability = 'synex.groups.members.invite', effect = 'allow', delegable = false
        }} }}
      }))
      assert(allowed.allowed == true and allowed.delegable == true
        and allowed.matchedDelegableAllows == 1)
      assert(allowed.trace[1].delegable == true and allowed.trace[2].delegable == false)

      local denied = assert(evaluator:evaluate({
        capability = 'synex.groups.members.invite',
        defaults = {{ capability = 'synex.groups.members.*', effect = 'allow', delegable = true }},
        membership = { id = 'member-deny', rules = {{
          capability = 'synex.groups.members.invite', effect = 'deny'
        }} }
      }))
      assert(denied.denied == true and denied.delegable == false)

      local invalid, invalidError = evaluator:evaluate({
        capability = 'synex.groups.members.invite',
        defaults = {{
          capability = 'synex.groups.members.invite', effect = 'deny', delegable = true
        }}
      })
      assert(invalid == nil and invalidError.code == 'CAPABILITY_RULE_INVALID')
      return table.concat({ tostring(allowed.delegable), tostring(denied.delegable),
        invalidError.code }, ':')
    `);
    assert.equal(result, 'true:false:CAPABILITY_RULE_INVALID');
  } finally {
    engine.global.close();
  }
});

test('capability validation rejects smuggled fields, sparse collections, hostile scope, and rule overflow', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrapDomain(engine);
    const result = await engine.doString(`
      local Capabilities = require 'server.domain.capabilities'
      local evaluator = Capabilities.create({
        now = function() return 1 end, maximumRules = 2,
        evaluateRules = SYNEX_GROUPS_TEST_RULE_EVALUATOR
      })
      local smuggled, smuggledError = evaluator:evaluate({
        capability = 'synex.groups.read', defaults = {{
          capability = 'synex.groups.read', effect = 'allow', execute = true
        }}
      })
      assert(smuggled == nil and smuggledError.code == 'CAPABILITY_RULE_INVALID')
      local sparse, sparseError = evaluator:evaluate({
        capability = 'synex.groups.read', roles = {
          [2] = { id = 'role-a', rules = {} }
        }
      })
      assert(sparse == nil and sparseError.code == 'CAPABILITY_REQUEST_INVALID')
      local trapCalls = 0
      local hostileScope = setmetatable({}, {
        __metatable = 'protected', __pairs = function() trapCalls = trapCalls + 1 error('trap') end
      })
      local hostile, hostileError = evaluator:evaluate({ capability = 'synex.groups.read', scope = hostileScope })
      assert(hostile == nil and hostileError.code == 'CAPABILITY_SCOPE_INVALID' and trapCalls == 0)
      local overflow, overflowError = evaluator:evaluate({
        capability = 'synex.groups.read',
        defaults = {
          { capability = 'synex.groups.read', effect = 'allow' },
          { capability = 'synex.groups.write', effect = 'allow' },
          { capability = 'synex.groups.manage', effect = 'deny' }
        }
      })
      assert(overflow == nil and overflowError.code == 'CAPABILITY_REQUEST_INVALID')
      local wildcard, wildcardError = evaluator:evaluate({ capability = 'synex.groups.*.read' })
      assert(wildcard == nil and wildcardError.code == 'CAPABILITY_REQUEST_INVALID')
      return table.concat({ smuggledError.code, sparseError.code, hostileError.code,
        overflowError.code, wildcardError.code, trapCalls }, ':')
    `);
    assert.equal(
      result,
      'CAPABILITY_RULE_INVALID:CAPABILITY_REQUEST_INVALID:CAPABILITY_SCOPE_INVALID:'
        + 'CAPABILITY_REQUEST_INVALID:CAPABILITY_REQUEST_INVALID:0',
    );
  } finally {
    engine.global.close();
  }
});

test('policy produces stable ALLOW or DENY reasons and short-circuits failed authority gates', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrapDomain(engine);
    const result = await engine.doString(`
      local Capabilities = require 'server.domain.capabilities'
      local Policy = require 'server.domain.policy'
      local evaluator = Capabilities.create({
        now = function() return 500 end,
        evaluateRules = SYNEX_GROUPS_TEST_RULE_EVALUATOR
      })
      local policy = Policy.create({ capabilities = evaluator })
      local blocked = assert(policy:decide({
        capability = 'synex.groups.members.remove',
        gates = {
          { name = 'resource_capability', allowed = false, reason = 'RESOURCE_CAPABILITY_DENIED' },
          { name = 'actor_membership', allowed = true }
        },
        defaults = {{ capability = 'synex.groups.*', effect = 'allow' }}
      }))
      assert(blocked.decision == 'DENY' and blocked.reason == 'RESOURCE_CAPABILITY_DENIED')
      assert(#blocked.trace.gates == 2 and #blocked.trace.capabilities == 0)

      local allowed = assert(policy:decide({
        capability = 'synex.groups.members.remove',
        gates = {
          { name = 'resource_capability', allowed = true },
          { name = 'actor_membership', allowed = true }
        },
        defaults = {{ capability = 'synex.groups.*', effect = 'allow' }}
      }))
      assert(allowed.decision == 'ALLOW' and allowed.reason == 'CAPABILITY_GRANTED')
      assert(allowed.evaluatedAt == 500 and #allowed.trace.gates == 2)

      local denied = assert(policy:decide({
        capability = 'synex.groups.members.remove',
        defaults = {
          { capability = 'synex.groups.*', effect = 'allow' },
          { capability = 'synex.groups.members.remove', effect = 'deny' }
        }
      }))
      assert(denied.decision == 'DENY' and denied.reason == 'CAPABILITY_EXPLICITLY_DENIED')
      local absent = assert(policy:decide({ capability = 'synex.groups.members.remove' }))
      assert(absent.decision == 'DENY' and absent.reason == 'CAPABILITY_NOT_GRANTED')
      local invalid, invalidError = policy:decide({
        capability = 'synex.groups.members.remove',
        gates = {
          { name = 'resource_capability', allowed = false },
          { name = 'invalid', allowed = true, execute = true }
        }
      })
      assert(invalid == nil and invalidError.code == 'POLICY_GATE_INVALID')
      return table.concat({ blocked.reason, allowed.decision, denied.reason, absent.reason }, ':')
    `);
    assert.equal(
      result,
      'RESOURCE_CAPABILITY_DENIED:ALLOW:CAPABILITY_EXPLICITLY_DENIED:CAPABILITY_NOT_GRANTED',
    );
  } finally {
    engine.global.close();
  }
});

test('owner registry enforces global and per-epoch bounds and cleanup cannot remove a newer owner epoch', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrapDomain(engine);
    const result = await engine.doString(`
      local Registry = require 'server.domain.registry'
      local registry = Registry.create({ maximumEntries = 3, maximumPerOwner = 2 })
      local first = assert(registry:register('resource_a', 1, 'type.alpha', { value = 'a' }))
      local second = assert(registry:register('resource_a', 1, 'type.beta', { value = 'b' }))
      assert(first.token ~= second.token)
      local duplicate, duplicateError = registry:register('resource_b', 1, 'type.alpha', {})
      assert(duplicate == nil and duplicateError.code == 'REGISTRY_KEY_EXISTS')
      local ownerFull, ownerError = registry:register('resource_a', 1, 'type.gamma', {})
      assert(ownerFull == nil and ownerError.code == 'REGISTRY_OWNER_CAPACITY_EXCEEDED')
      assert(registry:register('resource_b', 1, 'type.gamma', { value = 'c' }))
      local full, fullError = registry:register('resource_c', 1, 'type.delta', {})
      assert(full == nil and fullError.code == 'REGISTRY_CAPACITY_EXCEEDED')
      local value, valueError, metadata = registry:get('type.alpha')
      assert(valueError == nil and value.value == 'a' and metadata.owner == 'resource_a')
      local stale, staleError = registry:remove('resource_a', 2, 'type.alpha', first.token)
      assert(stale == nil and staleError.code == 'REGISTRY_OWNER_MISMATCH')
      local listed = assert(registry:listOwner('resource_a', 1))
      assert(#listed == 2 and listed[1].key == 'type.alpha' and listed[2].key == 'type.beta')
      assert(registry:cleanupOwner('resource_a', 1) == 2)
      local missing, missingError = registry:get('type.alpha')
      assert(missing == nil and missingError.code == 'REGISTRY_KEY_NOT_FOUND')
      local current = assert(registry:register('resource_a', 2, 'type.alpha', { value = 'new' }))
      assert(registry:cleanupOwner('resource_a', 1) == 0)
      local currentValue = assert(registry:get('type.alpha'))
      assert(currentValue.value == 'new')
      local tokenMismatch, tokenError = registry:remove('resource_a', 2, 'type.alpha', current.token + 1)
      assert(tokenMismatch == nil and tokenError.code == 'REGISTRY_OWNER_MISMATCH')
      assert(registry:cleanupOwner('resource_a') == 1)
      local stats = registry:stats()
      assert(stats.entries == 1 and stats.ownerEpochs == 1)
      return table.concat({ duplicateError.code, ownerError.code, fullError.code, staleError.code,
        missingError.code, tokenError.code, stats.entries }, ':')
    `);
    assert.equal(
      result,
      'REGISTRY_KEY_EXISTS:REGISTRY_OWNER_CAPACITY_EXCEEDED:REGISTRY_CAPACITY_EXCEEDED:REGISTRY_OWNER_MISMATCH:'
        + 'REGISTRY_KEY_NOT_FOUND:REGISTRY_OWNER_MISMATCH:1',
    );
  } finally {
    engine.global.close();
  }
});
