import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory, type LuaEngine } from 'wasmoon';

import { runDeterministicBenchmark } from '../../tools/cli/src/benchmark.ts';

const root = process.cwd();

async function preload(engine: LuaEngine, name: string, relativePath: string): Promise<void> {
  const source = await readFile(path.join(root, relativePath), 'utf8');
  await engine.doString(
    `package.preload[${JSON.stringify(name)}] = assert(load(${JSON.stringify(source)}, ${JSON.stringify(`@${relativePath}`)}))`,
  );
}

test('cache and registry hot-key reads do not enumerate unrelated entries', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await preload(engine, 'server.persistence.cache', 'resources/synex_groups/server/cache.lua');
    await preload(engine, 'server.domain.registry', 'resources/synex_groups/server/domain/registry.lua');
    const result = await engine.doString(`
      local Foundation = {
        copyPlain = function(value) return value end,
        domainError = function(code, message)
          return { code = code, message = message, retryable = false }
        end
      }
      local Cache = require('server.persistence.cache')(Foundation)
      local Registry = require 'server.domain.registry'
      local cache = Cache({ maximum = 256, ttlMs = 5000, now = function() return 100 end })
      local registry = Registry.create({ maximumEntries = 256, maximumPerOwner = 256 })
      for index = 1, 256 do
        assert(cache:put('group:' .. index, 'value:' .. index))
        assert(registry:register('synex_test', 1, 'type.' .. index, 'value:' .. index))
      end

      local originalPairs, enumerations = pairs, 0
      pairs = function(value)
        enumerations = enumerations + 1
        return originalPairs(value)
      end
      local cached = cache:get('group:128')
      local registered = assert(registry:get('type.128'))
      pairs = originalPairs

      local snapshot = cache:snapshot()
      assert(cached == 'value:128' and registered == 'value:128')
      assert(enumerations == 0)
      assert(snapshot.size == 256 and snapshot.hits == 1 and snapshot.evictions == 0)
      return table.concat({ cached, registered, enumerations, snapshot.size }, ':')
    `);
    assert.equal(result, 'value:128:value:128:0:256');
  } finally {
    engine.global.close();
  }
});

test('effective capability evaluation performs one bounded Core rule pass', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await preload(engine, 'server.domain.constants',
      'resources/synex_groups/server/domain/constants.lua');
    await preload(engine, 'server.domain.capabilities',
      'resources/synex_groups/server/domain/capabilities.lua');
    const result = await engine.doString(`
      local Capabilities = require 'server.domain.capabilities'
      local coreCalls, observedRules = 0, 0
      local evaluator = Capabilities.create({
        now = function() return 100 end,
        maximumRules = 256,
        evaluateRules = function(permission, rules)
          coreCalls = coreCalls + 1
          observedRules = #rules
          local matches = {}
          for index, rule in ipairs(rules) do
            if rule.permission == permission then
              matches[#matches + 1] = {
                index = index, permission = rule.permission, effect = rule.effect
              }
            end
          end
          return {
            permission = permission, matches = matches,
            matchedAllows = #matches, matchedDenies = 0,
            denied = false, allowed = #matches > 0
          }, nil
        end
      })
      local rules = {}
      for index = 1, 256 do
        rules[index] = { capability = 'police.records.read', effect = 'allow' }
      end
      local allowed = assert(evaluator:evaluate({
        capability = 'police.records.read', defaults = rules
      }))
      assert(allowed.allowed == true and allowed.evaluatedRules == 256)
      assert(coreCalls == 1 and observedRules == 256)

      rules[257] = { capability = 'police.records.read', effect = 'allow' }
      local overflow, overflowError = evaluator:evaluate({
        capability = 'police.records.read', defaults = rules
      })
      assert(overflow == nil and overflowError.code == 'CAPABILITY_REQUEST_INVALID')
      assert(coreCalls == 1)
      return table.concat({ allowed.evaluatedRules, coreCalls, observedRules,
        overflowError.code }, ':')
    `);
    assert.equal(result, '256:1:256:CAPABILITY_REQUEST_INVALID');
  } finally {
    engine.global.close();
  }
});

test('capability and policy persistence reads retain explicit overflow sentinels', async () => {
  const capabilityAccess = await readFile(path.join(
    root, 'resources/synex_groups/server/persistence/capability_access.lua',
  ), 'utf8');
  const policies = await readFile(path.join(
    root, 'resources/synex_groups/server/persistence/governance_policies.lua',
  ), 'utf8');

  assert.equal(capabilityAccess.match(/LIMIT 257/gu)?.length, 4);
  assert.equal(capabilityAccess.match(/LIMIT 65/gu)?.length, 1);
  for (const sentinel of [
    'group-default capability model exceeds',
    'grade capability model exceeds',
    'role capability model exceeds',
    'delegation model exceeds',
    'membership capability model exceeds',
  ]) {
    assert.ok(capabilityAccess.includes(sentinel), sentinel);
  }
  assert.match(policies, /ORDER BY priority DESC, effect ASC, rule_key ASC LIMIT 65/u);
  assert.match(policies, /#rules > 64/u);
});

test('deterministic benchmark covers every required Groups hot path without production claims', () => {
  const report = runDeterministicBenchmark(10);
  assert.deepEqual(report.thresholds, {
    minimumIterations: 1,
    maximumIterations: 100_000,
    regressionDecreasePercent: 25,
  });
  const required = [
    'groups_group_lookup',
    'groups_membership_lookup',
    'groups_effective_capability_lookup',
    'groups_online_members_lookup',
    'groups_on_duty_members_lookup',
    'groups_policy_evaluation',
  ];
  for (const name of required) {
    const measurement = report.benchmarks[name];
    assert.ok(measurement, name);
    assert.equal(measurement.execution, 'synex_groups_lua', name);
    assert.match(measurement.workload, /Actual server\./u, name);
    assert.equal(measurement.samplesMilliseconds.length, report.samples, name);
    assert.ok(measurement.operationsPerSecond > 0, name);
  }
  assert.match(report.disclaimer, /deterministic in-memory adapters/u);
  assert.match(report.disclaimer, /exclude FXServer, Cfx networking, and MariaDB I\/O/u);
  assert.match(report.disclaimer, /not a FiveM runtime or production performance claim/u);
});
