import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';

const bridgeRoot = path.join(process.cwd(), 'libraries', 'synex_bridge');

test('runtime certification requires exact PASS checks, tracked hashes, bindings, and fingerprint', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await engine.doString('SynexBridgeKernel = {}');
    await engine.doString(await readFile(path.join(bridgeRoot, 'kernel', 'foundation.lua'), 'utf8'));
    await engine.doString(await readFile(path.join(bridgeRoot, 'kernel', 'certification.lua'), 'utf8'));
    const result = await engine.doString(String.raw`
      local F = SynexBridgeKernel.Foundation
      local C = SynexBridgeKernel.Certification
      local files = {
        ['compatibility/profiles.json'] = 'profiles-v1',
        ['compatibility/surfaces/qb.json'] = 'surfaces-qb-v1',
        ['compatibility/consumers.json'] = 'consumers-v1',
        ['compatibility/money-policies.json'] = 'money-policies-v1',
        ['compatibility/review-lock.json'] = 'review-lock-v1',
        ['compatibility/schemas/certification.schema.json'] = 'certification-schema-v1',
        ['compatibility/schemas/consumers.schema.json'] = 'consumers-schema-v1',
        ['compatibility/schemas/mappings.schema.json'] = 'mappings-schema-v1',
        ['compatibility/schemas/money-policies.schema.json'] = 'money-policies-schema-v1',
        ['compatibility/schemas/profiles.schema.json'] = 'profiles-schema-v1',
        ['compatibility/schemas/review-lock.schema.json'] = 'review-lock-schema-v1',
        ['compatibility/schemas/runtime-evidence.schema.json'] = 'runtime-schema-v1',
        ['compatibility/schemas/surfaces.schema.json'] = 'surfaces-schema-v1',
      }
      local function binding(repositoryPath)
        local resourcePath = repositoryPath:gsub('^libraries/synex_bridge/', '')
        return { path = repositoryPath, sha256 = F.sha256(files[resourcePath]), tracked = true }
      end
      local profile = {
        id = 'qb.fixture', version = '1.0.0', provider = 'qb',
        mode = 'compat',
        providerVersion = '0.1.0', targetFrameworkApiRange = '^7.0.0',
        status = 'CERTIFIED',
        certificationArtifact = 'compatibility/certifications/qb.fixture.json',
        script = { name = 'legacy_consumer', testedVersion = '2.0.0' },
        requiredSurfaces = {{
          name = 'qb.server.player_lookup', acceptedStatuses = { 'PARTIAL' },
        }},
        evidence = {
          tests = { 'tests/compatibility/qb-fixture.test.ts' },
          sourceUrls = { 'https://example.invalid/qb-fixture' },
        },
      }
      local surface = {
        provider = 'qb', providerResource = 'synex_bridge_qb',
        providerVersion = '0.1.0', targetFrameworkApiRange = '^7.0.0',
        surfaces = {{
          name = 'qb.server.player_lookup', status = 'PARTIAL',
          tests = { 'tests/compatibility/qb-fixture.test.ts' },
        }},
      }
      local certificate = {
        schema = 1, kind = 'synex-compatibility-certificate',
        profileId = profile.id, profileVersion = profile.version,
        provider = 'qb', providerResource = 'synex_bridge_qb',
        providerVersion = '0.1.0', targetFrameworkApiRange = '^7.0.0',
        script = { name = 'legacy_consumer', version = '2.0.0' },
        tests = {{
          path = 'tests/compatibility/qb-fixture.test.ts',
          sha256 = ('a'):rep(64), status = 'PASS', tracked = true,
        }},
        sourceUrls = { 'https://example.invalid/qb-fixture' },
        bindings = {
          profileCatalog = binding('libraries/synex_bridge/compatibility/profiles.json'),
          surfaceCatalog = binding('libraries/synex_bridge/compatibility/surfaces/qb.json'),
          consumerCatalog = binding('libraries/synex_bridge/compatibility/consumers.json'),
          moneyPolicyCatalog = binding('libraries/synex_bridge/compatibility/money-policies.json'),
          reviewLock = binding('libraries/synex_bridge/compatibility/review-lock.json'),
          schemas = {
            binding('libraries/synex_bridge/compatibility/schemas/certification.schema.json'),
            binding('libraries/synex_bridge/compatibility/schemas/consumers.schema.json'),
            binding('libraries/synex_bridge/compatibility/schemas/mappings.schema.json'),
            binding('libraries/synex_bridge/compatibility/schemas/money-policies.schema.json'),
            binding('libraries/synex_bridge/compatibility/schemas/profiles.schema.json'),
            binding('libraries/synex_bridge/compatibility/schemas/review-lock.schema.json'),
            binding('libraries/synex_bridge/compatibility/schemas/runtime-evidence.schema.json'),
            binding('libraries/synex_bridge/compatibility/schemas/surfaces.schema.json'),
          },
        },
      }
      local checkIds = {
        'adapters.exact', 'catalog.consumers-tracked', 'catalog.money-policies-tracked',
        'catalog.profile-tracked', 'catalog.review-lock',
        'catalog.schemas-tracked', 'catalog.surface-tracked', 'evidence.unique',
        'profile.effective-status', 'profile.exists', 'profile.version',
        'provider.exact', 'provider.version-exact', 'runtime.complete',
        'runtime.health', 'runtime.provided', 'runtime.provider-version',
        'script.name', 'script.version', 'target-framework-api.range-exact',
        'target-framework-api.range-reviewed', 'tests.exact-set',
        'test:tests/compatibility/qb-fixture.test.ts',
      }
      local checks = {}
      for index, id in ipairs(checkIds) do
        checks[index] = { id = id, status = 'PASS', message = 'verified' }
      end
      certificate.fingerprint = C.fingerprint(certificate, checkIds)
      local report = {
        schema = 1, artifactKind = 'synex-compatibility-certification',
        status = 'CERTIFIED', certified = true, profileId = profile.id,
        checks = checks, certificate = certificate, disclaimer = 'bounded fixture',
      }
      local decoded = { ['cli-certificate'] = report, ['handwritten'] = {} }
      files[profile.certificationArtifact] = 'cli-certificate'
      local function verify()
        return C.verify({
          profile = profile, surfaceDocument = surface,
          loadFile = function(path) return files[path] end,
          decode = function(raw) return decoded[raw] end,
        })
      end
      assert(verify() == true)
      files['compatibility/consumers.json'] = 'consumers-v2'
      assert(verify() == false)
      files['compatibility/consumers.json'] = 'consumers-v1'
      files['compatibility/money-policies.json'] = 'money-policies-v2'
      assert(verify() == false)
      files['compatibility/money-policies.json'] = 'money-policies-v1'
      assert(verify() == true)
      surface.surfaces[1].tests = { 'tests/compatibility/unrelated.test.ts' }
      assert(verify() == false)
      surface.surfaces[1].tests = { 'tests/compatibility/qb-fixture.test.ts' }
      surface.surfaces[1].status = 'UNSUPPORTED'
      profile.requiredSurfaces[1].acceptedStatuses = { 'UNSUPPORTED' }
      assert(verify() == false)
      surface.surfaces[1].status = 'UNKNOWN'
      profile.requiredSurfaces[1].acceptedStatuses = { 'UNKNOWN' }
      assert(verify() == false)
      surface.surfaces[1].status = 'PARTIAL'
      profile.requiredSurfaces[1].acceptedStatuses = { 'PARTIAL', 'UNKNOWN' }
      assert(verify() == false)
      profile.requiredSurfaces[1].acceptedStatuses = { 'PARTIAL' }
      assert(verify() == true)
      checks[1].status = 'FAIL'
      assert(verify() == false)
      checks[1].status = 'PASS'
      files[profile.certificationArtifact] = 'handwritten'
      assert(verify() == false)
      files[profile.certificationArtifact] = 'cli-certificate'
      certificate.tests[1].sha256 = ('b'):rep(64)
      assert(verify() == false)
      return certificate.fingerprint
    `);
    assert.match(result as string, /^[0-9a-f]{64}$/u);
  } finally {
    engine.global.close();
  }
});
