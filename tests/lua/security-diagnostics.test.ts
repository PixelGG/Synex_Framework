import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory, type LuaEngine } from 'wasmoon';

const root = process.cwd();

async function load(engine: LuaEngine, relativePath: string): Promise<void> {
  await engine.doString(await readFile(path.join(root, relativePath), 'utf8'));
}

async function securityEngine(): Promise<LuaEngine> {
  const engine = await new LuaFactory().createEngine();
  await load(engine, 'core/synex_core/shared/protocol.lua');
  await load(engine, 'core/synex_core/server/factories.lua');
  await load(engine, 'core/synex_core/server/foundation.lua');
  await load(engine, 'core/synex_core/server/security.lua');
  return engine;
}

test('security diagnostics are immutable, bounded and keyset paginated', async () => {
  const engine = await securityEngine();
  try {
    const result = await engine.doString(`
      local now = 1000
      local platform = {
        nowGame = function() return now end,
        random = function() return 1 end,
        print = function() end,
        jsonEncode = function() return '{}' end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      local security = SynexCoreFactories.security({
        platform = platform, foundation = foundation, coreResource = 'synex_core',
        securityDiagnosticsMaximum = 32
      })

      local first = nil
      for index = 1, 40 do
        local recorded = assert(security.diagnostics:record({
          category = 'contract_validation',
          severity = 'WARNING',
          code = 'CONTRACT_VALIDATION_' .. index,
          resource = 'synex_fixture',
          scope = 'synex.fixture.' .. index,
          operation = 'contract.validate',
          summary = 'Contract validation rejected.'
        }))
        if index == 1 then first = recorded end
      end
      first.summary = 'mutated outside the store'

      local snapshot = assert(security.diagnostics:snapshot(50))
      assert(snapshot.retained == 32 and snapshot.maximumRetained == 32)
      assert(snapshot.dropped == 8 and snapshot.retentionTruncated == true)
      assert(snapshot.latestId == 40 and snapshot.categories.contract_validation == 32)
      assert(#snapshot.items == 32 and snapshot.items[1].id == 40
        and snapshot.items[32].id == 9)
      assert(snapshot.items[1].summary == 'Contract validation rejected.')
      assert(snapshot.payloadsExposed == false)

      local cursor, total, previousId, previousTimestamp = nil, 0, 41, math.huge
      repeat
        local page = assert(security.diagnostics:page({ cursor = cursor, limit = 7 }))
        for _, finding in ipairs(page.items) do
          assert(finding.id < previousId and finding.timestampMs < previousTimestamp)
          assert(finding.cursor == tostring(finding.id))
          assert(finding.payload == nil and finding.traceId == nil)
          previousId, previousTimestamp = finding.id, finding.timestampMs
          total = total + 1
        end
        cursor = page.nextCursor
        if page.hasMore then assert(type(cursor) == 'string') end
      until cursor == nil
      assert(total == 32 and previousId == 9)

      local invalidPayload, payloadError = security.diagnostics:record({
        category = 'contract_validation', severity = 'WARNING', code = 'INVALID_FIXTURE',
        resource = 'synex_fixture', operation = 'contract.validate', summary = 'Rejected.',
        payload = { secret = 'must-not-enter-the-store' }
      })
      assert(invalidPayload == nil and payloadError.code == 'INVALID_SECURITY_DIAGNOSTIC_FINDING')
      local invalidSummary, summaryError = security.diagnostics:record({
        category = 'contract_validation', severity = 'WARNING', code = 'INVALID_FIXTURE',
        resource = 'synex_fixture', operation = 'contract.validate', summary = 'line one\\nline two'
      })
      assert(invalidSummary == nil and summaryError.code == 'INVALID_SECURITY_DIAGNOSTIC_FINDING')
      local invalidSecret, secretError = security.diagnostics:record({
        category = 'contract_validation', severity = 'WARNING', code = 'INVALID_FIXTURE',
        resource = 'synex_fixture', operation = 'contract.validate',
        summary = 'Rejected cfxk_123456789012345678901234567890.'
      })
      assert(invalidSecret == nil and secretError.code == 'INVALID_SECURITY_DIAGNOSTIC_FINDING')
      local invalidCursor, cursorError = security.diagnostics:page({ cursor = '42', limit = 1 })
      assert(invalidCursor == nil and cursorError.code == 'INVALID_CURSOR')
      local invalidLimit, limitError = security.diagnostics:snapshot(51)
      assert(invalidLimit == nil and limitError.code == 'INVALID_ARGUMENT')

      return table.concat({ snapshot.retained, snapshot.dropped, total,
        snapshot.latestId, previousId }, ':')
    `);
    assert.equal(result, '32:8:32:40:9');
  } finally {
    engine.global.close();
  }
});

test('security diagnostics capture only runtime denials produced by security', async () => {
  const engine = await securityEngine();
  try {
    const result = await engine.doString(`
      local now = 2000
      local platform = {
        nowGame = function() return now end,
        random = function() return 1 end,
        print = function() end,
        jsonEncode = function() return '{}' end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      local security = SynexCoreFactories.security({
        platform = platform, foundation = foundation, coreResource = 'synex_core',
        rateLimiterMaximum = 64,
        policy = {
          default = { allow = {}, deny = { 'synex.blocked' } },
          resources = { synex_fixture = { allow = {}, deny = {} } }
        }
      })

      local value, failure = security.capabilities:check('synex_missing',
        'synex.runtime.read', { operation = 'runtime.read', traceId = 'trace-secret' })
      assert(value == nil and failure.code == 'RESOURCE_NOT_REGISTERED')
      assert(security.capabilities:registerManifest('synex_fixture', {
        capabilities = { request = { 'synex.blocked' } },
        events = {
          publish = { 'synex.fixture.allowed' },
          subscribe = { 'synex.external.allowed' }
        },
        hooks = {
          register = { 'synex.fixture.allowed' },
          run = { 'synex.fixture.allowed' }
        }
      }))
      value, failure = security.capabilities:check('synex_fixture',
        'synex.unlisted', { operation = 'fixture.undeclared' })
      assert(value == nil and failure.code == 'CAPABILITY_UNDECLARED')
      value, failure = security.capabilities:check('synex_fixture',
        'synex.blocked', { operation = 'fixture.denied' })
      assert(value == nil and failure.code == 'CAPABILITY_DENIED')

      value, failure = security.capabilities:canPublishEvent('synex_fixture', 'synex.other.topic')
      assert(value == nil and failure.code == 'EVENT_TOPIC_FORBIDDEN')
      value, failure = security.capabilities:canPublishEvent('synex_fixture', 'synex.fixture.other')
      assert(value == nil and failure.code == 'EVENT_PUBLISH_UNDECLARED')
      value, failure = security.capabilities:canRunHook('synex_fixture', 'synex.other.hook')
      assert(value == nil and failure.code == 'HOOK_NAME_FORBIDDEN')
      value, failure = security.capabilities:canRegisterHook('synex_fixture', 'synex.fixture.other')
      assert(value == nil and failure.code == 'HOOK_REGISTER_UNDECLARED')

      assert(security.rateLimiter:consume('rpc:fixture', 1, 1, 1))
      value, failure = security.rateLimiter:consume('rpc:fixture', 1, 1, 1)
      assert(value == nil and failure.code == 'RATE_LIMITED')
      for index = 1, 63 do
        assert(security.rateLimiter:consume('fixture:' .. index, 1, 1, 1))
      end
      value, failure = security.rateLimiter:consume('fixture:overflow', 1, 1, 1)
      assert(value == nil and failure.code == 'RATE_LIMITED')

      local snapshot = assert(security.diagnostics:snapshot(50))
      assert(snapshot.retained == 9 and snapshot.dropped == 0)
      assert(snapshot.categories.capability_denial == 3)
      assert(snapshot.categories.event_authorization == 2)
      assert(snapshot.categories.hook_authorization == 2)
      assert(snapshot.categories.rate_limit_rejection == 2)

      local expectedCodes = {
        RESOURCE_NOT_REGISTERED = true, CAPABILITY_UNDECLARED = true,
        CAPABILITY_DENIED = true, EVENT_TOPIC_FORBIDDEN = true,
        EVENT_PUBLISH_UNDECLARED = true, HOOK_NAME_FORBIDDEN = true,
        HOOK_REGISTER_UNDECLARED = true, RATE_LIMITED = true
      }
      for _, finding in ipairs(snapshot.items) do
        assert(expectedCodes[finding.code] == true)
        assert(finding.severity == 'WARNING' and finding.summary ~= '')
        assert(finding.traceId == nil and finding.payload == nil and finding.details == nil)
        assert(finding.resource ~= 'trace-secret' and finding.scope ~= 'trace-secret')
      end

      local firstEventPage = assert(security.diagnostics:page({
        category = 'event_authorization', limit = 1
      }))
      assert(#firstEventPage.items == 1 and firstEventPage.hasMore == true)
      local secondEventPage = assert(security.diagnostics:page({
        category = 'event_authorization', cursor = firstEventPage.nextCursor, limit = 1
      }))
      assert(#secondEventPage.items == 1 and secondEventPage.hasMore == false)
      assert(firstEventPage.items[1].id > secondEventPage.items[1].id)

      return table.concat({ snapshot.retained,
        snapshot.categories.capability_denial,
        snapshot.categories.event_authorization,
        snapshot.categories.hook_authorization,
        snapshot.categories.rate_limit_rejection }, ':')
    `);
    assert.equal(result, '9:3:2:2:2');
  } finally {
    engine.global.close();
  }
});
