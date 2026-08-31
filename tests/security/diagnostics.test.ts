import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';

import { LuaFactory } from 'wasmoon';

const files = [
  'resources/synex_security/shared/limits.lua',
  'resources/synex_security/shared/validation.lua',
  'resources/synex_security/server/diagnostics.lua',
] as const;

async function run<T>(source: string): Promise<T> {
  const engine = await new LuaFactory().createEngine();
  try {
    for (const file of files) {
      await engine.doString(await readFile(path.join(process.cwd(), file), 'utf8'));
    }
    return await engine.doString(source) as T;
  } finally {
    engine.global.close();
  }
}

test('doctor ignores hardening checks that are already satisfied', async () => {
  const result = await run<{
    healthy: string;
    healthyItems: number;
    advisory: string;
    advisoryItems: number;
  }>(`
    local findings = {}
    local hardeningItems = {{ status = 'OK', severity = 'INFO',
      code = 'SECURITY_CFX_HARDENING_OK', summary = 'Configured safely.' }}
    local diagnostics = SynexSecurityDiagnostics.create({
      summary = function() return {} end,
      health = function() return { state = 'READY', reasons = {
        persistence = 'READY', core = 'READY', cfx = 'READY', sentinel = 'READY',
        detector = 'READY', pipeline = 'READY', coreSignals = 'READY',
        access = 'READY' } } end,
      listCases = function() return { items = {}, total = 0 } end,
      getCase = function() return {} end,
      getAssessment = function() return {} end,
      listExpectations = function() return { items = {}, total = 0 } end,
      listDetectors = function() return { items = {}, total = 0 } end,
      inspectSubject = function() return { cases = {}, enforcements = {} } end,
      observability = {
        snapshot = function() return {} end,
        listFindings = function() return { items = findings, total = #findings } end,
      },
      hardening = { inspect = function() return { items = hardeningItems } end },
      checks = function() return {{ id = 'runtime', status = 'PASS',
        code = 'READY', summary = 'Runtime checks passed.' }} end,
    })
    local healthy = assert(diagnostics.doctor(50))
    hardeningItems = {{ status = 'ADVISORY', severity = 'MEDIUM',
      code = 'SECURITY_CFX_HARDENING_RECOMMENDED',
      summary = 'A hardening recommendation remains.' }}
    local advisory = assert(diagnostics.doctor(50))
    return { healthy = healthy.status, healthyItems = #healthy.items,
      advisory = advisory.status, advisoryItems = #advisory.items }
  `);

  assert.deepEqual(result, {
    healthy: 'PASS',
    healthyItems: 0,
    advisory: 'ADVISORY',
    advisoryItems: 1,
  });
});
