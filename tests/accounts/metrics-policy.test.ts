import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';

const root = process.cwd();

interface ResourceManifest {
  capabilities: {
    request: string[];
  };
}

interface CapabilityPolicy {
  default: {
    allow: string[];
    deny: string[];
  };
  resources: Record<string, {
    allow: string[];
    deny: string[];
  }>;
}

test('Accounts capability requests and Core grants stay in exact parity', async () => {
  const [manifestRaw, policyRaw, securitySource] = await Promise.all([
    readFile(path.join(root, 'resources/synex_accounts/synex.resource.json'), 'utf8'),
    readFile(path.join(root, 'core/synex_core/config/capabilities.json'), 'utf8'),
    readFile(path.join(root, 'core/synex_core/server/security.lua'), 'utf8'),
  ]);
  const manifest = JSON.parse(manifestRaw) as ResourceManifest;
  const policy = JSON.parse(policyRaw) as CapabilityPolicy;
  const requested = manifest.capabilities.request;
  const granted = policy.resources.synex_accounts?.allow ?? [];
  const denied = policy.resources.synex_accounts?.deny ?? [];

  assert.equal(requested.filter((entry) => entry === 'synex.metrics.write').length, 1);
  assert.equal(granted.filter((entry) => entry === 'synex.metrics.write').length, 1);
  assert.ok(!denied.includes('synex.metrics.write'));
  assert.ok(!policy.default.deny.includes('synex.metrics.write'));
  assert.deepEqual([...new Set(requested)].sort(), [...new Set(granted)].sort());
  assert.equal(new Set(requested).size, requested.length);
  assert.equal(new Set(granted).size, granted.length);
  assert.match(
    securitySource,
    /\['synex\.metrics\.write'\]\s*=\s*'sensitive'/u,
  );
  assert.ok(policy.default.deny.includes('synex.accounts.outbox.retry'));
  assert.match(
    securitySource,
    /\['synex\.accounts\.outbox\.retry'\]\s*=\s*'privileged'/u,
  );
});

test('idempotency conflicts are counted only at the persistence decision point', async () => {
  const [main, persistence, engine] = await Promise.all([
    readFile(path.join(root, 'resources/synex_accounts/server/main.lua'), 'utf8'),
    readFile(path.join(root, 'resources/synex_accounts/server/persistence.lua'), 'utf8'),
    readFile(path.join(
      root,
      'resources/synex_accounts/server/persistence/engine_shared.lua',
    ), 'utf8'),
  ]);

  assert.doesNotMatch(main, /code == 'IDEMPOTENCY_CONFLICT'/u);
  assert.match(persistence, /synex_accounts_idempotency_conflicts_total/u);
  assert.match(engine, /synex_accounts_idempotency_conflicts_total/u);
});
