import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';

const serverRoot = path.join(process.cwd(), 'resources', 'synex_entities', 'server');

test('entity duration instrumentation and required metric surface use bounded labels', async () => {
  const [service, lifecycle, authority, admission, bucket] = await Promise.all([
    readFile(path.join(serverRoot, 'service.lua'), 'utf8'),
    readFile(path.join(serverRoot, 'authority_lifecycle.lua'), 'utf8'),
    readFile(path.join(serverRoot, 'authority_service.lua'), 'utf8'),
    readFile(path.join(serverRoot, 'spawn_admission.lua'), 'utf8'),
    readFile(path.join(serverRoot, 'bucket_service.lua'), 'utf8'),
  ]);
  for (const metric of [
    'entity_spawn_duration_ms',
    'entity_delete_duration_ms',
    'entity_checkpoint_duration_ms',
    'entity_materialize_duration_ms',
    'entity_dematerialize_duration_ms',
  ]) assert.match(service, new RegExp(`'${metric}'`, 'u'));
  assert.match(lifecycle, /finish\('entity_recovery_duration_ms', \{/u);
  assert.match(service, /local labels = \{[\s\S]*?code = code,[\s\S]*?entityType = entityType,[\s\S]*?result =/u);
  assert.match(service, /local elapsed = finish\(metricName, labels\)/u);
  assert.doesNotMatch(service.slice(
    service.indexOf('local durationMetrics'),
    service.indexOf('function service.runDriftDetection'),
  ), /entityId|netId|resourceOwner/u);
  assert.match(service, /gauge\('managed_entity_count'/u);
  assert.match(service, /gauge\('orphan_count'/u);
  const metricSource = `${service}\n${lifecycle}\n${authority}\n${admission}`;
  for (const metric of [
    'entity_live_total', 'entity_spawn_total', 'entity_spawn_duration',
    'entity_delete_total', 'entity_delete_failures', 'entity_orphaned_total',
    'entity_recovered_total', 'entity_recovery_failed_total',
    'entity_generation_changes', 'entity_component_count', 'bucket_live_total',
    'bucket_player_count', 'bucket_entity_count', 'quota_denials',
    'spawn_rate_denials', 'drift_findings', 'authority_lease_conflicts',
  ]) assert.match(metricSource, new RegExp(`'${metric}'`, 'u'));
  const auditSource = `${metricSource}\n${bucket}`;
  for (const action of [
    'created', 'spawned', 'materialized', 'dematerialized', 'checkpointed',
    'owner_changed', 'binding_changed', 'bucket_changed', 'orphaned',
    'recovered', 'recovery_failed', 'deleted', 'quota_denied',
    'foreign_resource_access', 'stale_entity_access',
  ]) assert.match(auditSource, new RegExp(`'entities\\.${action}'|'${action}'`, 'u'));
});

test('monotonic duration timer handles Cfx timer wrap and emits one observation', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await engine.doString(await readFile(path.join(serverRoot, 'observability.lua'), 'utf8'));
    const result = await engine.doString(String.raw`
      local ticks, index = { 4294967290, 12 }, 0
      local observations = 0
      local observedName, observedValue
      local metrics = {
        observe = function(name, labels, value)
          observations = observations + 1
          observedName, observedValue = name, value
          assert(labels.result == 'success' and labels.entityType == 'vehicle')
          return true
        end,
      }
      local service = SynexEntityObservability.create({
        coreRef = { value = { Metrics = metrics } },
        foundation = {
          isCallable = function(value) return type(value) == 'function' end,
          protect = function(_, handler, _, ...)
            return true, handler(...)
          end,
        },
        ports = {
          getGameTimer = function()
            index = index + 1
            return ticks[index]
          end,
        },
        resourceName = 'synex_entities',
      })
      local finish = service.timer()
      local elapsed = finish('entity_spawn_duration_ms', {
        code = 'OK', entityType = 'vehicle', result = 'success',
      })
      assert(elapsed == 18 and observations == 1)
      assert(observedName == 'synex_entities_entity_spawn_duration_ms')
      assert(observedValue == 18)
      return observedName .. ':' .. observedValue
    `) as string;
    assert.equal(result, 'synex_entities_entity_spawn_duration_ms:18');
  } finally {
    engine.global.close();
  }
});

test('unavailable Entity event, audit, and metric writers degrade observability health', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await engine.doString(await readFile(path.join(serverRoot, 'observability.lua'), 'utf8'));
    const result = await engine.doString(String.raw`
      local reasons = {}
      local service = SynexEntityObservability.create({
        coreRef = { value = {} },
        foundation = {
          isCallable = function(value) return type(value) == 'function' end,
          protect = function(_, handler, _, ...)
            return true, handler(...)
          end,
          setHealth = function(status, reason)
            assert(status == 'DEGRADED')
            reasons[#reasons + 1] = reason
          end,
        },
        ports = { getGameTimer = function() return 1 end },
        resourceName = 'synex_entities',
      })
      assert(service.event('synex.entities.deleted', {}, {}) == false)
      assert(service.audit('entities.deleted', 'entity', 'ENT-test', {}, {}) == false)
      assert(service.increment('entity_delete_total', {}, 1) == false)
      assert(#reasons == 3)
      for _, reason in ipairs(reasons) do assert(reason == 'OBSERVABILITY_UNAVAILABLE') end
      assert(#service.snapshot() == 0)
      return #reasons
    `) as number;
    assert.equal(result, 3);
  } finally {
    engine.global.close();
  }
});
