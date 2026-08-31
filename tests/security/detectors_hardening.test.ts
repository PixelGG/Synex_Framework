import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';

const root = process.cwd();
const files = [
  'resources/synex_security/shared/limits.lua',
  'resources/synex_security/shared/validation.lua',
  'resources/synex_security/server/hardening.lua',
] as const;

async function run<T>(source: string): Promise<T> {
  const engine = await new LuaFactory().createEngine();
  try {
    for (const file of files) {
      await engine.doString(await readFile(path.join(root, file), 'utf8'));
    }
    return await engine.doString(source) as T;
  } finally {
    engine.global.close();
  }
}

test('Hardening advisor is read-only and preserves current Cfx mode semantics', async () => {
  const result = await run<{
    readOnly: boolean;
    modeMinusOne: boolean;
    modeFour: boolean;
    lockdownNoDummy: boolean;
    fullIsCurrent: boolean;
    fullWarning: boolean;
    requestStatus: string;
    replayImpact: boolean;
    writes: number;
  }>(`
    local writes = 0
    local values = {
      sv_filterRequestControl = '0', sv_pureLevel = '1',
      sv_pure_verify_client_settings = 'true', sv_disableClientReplays = 'false',
      sv_stateBagStrictMode = 'false', sv_entityLockdown = 'inactive',
    }
    local advisor = SynexSecurityHardening.create({
      getConvar = function(name, fallback)
        return values[name] == nil and fallback or values[name]
      end,
      setConvar = function() writes = writes + 1 end,
      getBuckets = function()
        return { { id = 4, mode = 'strict', controlled = true },
          { id = 5, mode = 'no_dummy', controlled = false } }
      end,
    })
    local semantics, findings, requestStatus, replayImpact, fullWarning =
      advisor.semantics(), advisor.list(), '', false, false
    for _, item in ipairs(findings) do
      if item.setting == 'sv_filterRequestControl' then requestStatus = item.status end
      if item.setting == 'sv_disableClientReplays' then
        replayImpact = item.compatibilityImpact:find('Rockstar Editor', 1, true) ~= nil
      end
      if item.setting == 'routingBucket.5.entityLockdown' then
        fullWarning = item.status == 'COMPATIBILITY_RISK'
          and item.compatibilityImpact:find('Enhanced', 1, true) ~= nil
      end
      assert(item.mutatesConfig == false)
    end
    local snapshot = advisor.snapshot()
    return { readOnly = snapshot.readOnly,
      modeMinusOne = semantics.requestControl['-1'] ~= nil,
      modeFour = semantics.requestControl['4'] ~= nil,
      lockdownNoDummy = semantics.entityLockdown.no_dummy ~= nil,
      fullIsCurrent = semantics.entityLockdown.full ~= nil
        and semantics.lockdownDocumentationMismatch.liveVerificationRequired,
      fullWarning = fullWarning, requestStatus = requestStatus,
      replayImpact = replayImpact, writes = writes }
  `);

  assert.deepEqual(result, {
    readOnly: true,
    modeMinusOne: true,
    modeFour: true,
    lockdownNoDummy: true,
    fullIsCurrent: true,
    fullWarning: true,
    requestStatus: 'ACTION_RECOMMENDED',
    replayImpact: true,
    writes: 0,
  });
});
