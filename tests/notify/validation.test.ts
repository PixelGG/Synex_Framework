import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory, type LuaEngine } from 'wasmoon';

const root = process.cwd();

async function load(engine: LuaEngine, relativePath: string): Promise<void> {
  await engine.doString(await readFile(path.join(root, relativePath), 'utf8'));
}

async function notifyLua(): Promise<LuaEngine> {
  const engine = await new LuaFactory().createEngine();
  await load(engine, 'resources/synex_notify/shared/limits.lua');
  await load(engine, 'resources/synex_notify/shared/validation.lua');
  return engine;
}

test('notify validation accepts only inert Cfx JSON containers and canonical local origin', async () => {
  const engine = await notifyLua();
  try {
    const result = await engine.doString(`
      local objectMeta = { __jsontype = 'object' }
      local arrayMeta = { __jsontype = 'array' }
      local action = setmetatable({
        id = 'accept', label = 'Accept', style = 'primary', ttlMs = 2500,
      }, objectMeta)
      local request = setmetatable({
        title = 'Bounded',
        actions = setmetatable({ action }, arrayMeta),
      }, objectMeta)
      local canonical = assert(SynexNotifyValidation.canonicalNotification(request, {
        authority = 'CLIENT', ownerResource = 'external.consumer', now = 1000,
      }))
      assert(canonical.origin == 'LOCAL')
      assert(canonical.actions[1].ttlMs == 2500)
      local capped = assert(SynexNotifyValidation.canonicalNotification({
        title = 'Long', message = ('content '):rep(20), maxLifetimeMs = 3000,
      }, { authority = 'CLIENT' }))
      assert(capped.durationMs == 3000)
      assert(SynexNotifyValidation.resourceName('external.consumer-1'))
      assert(not SynexNotifyValidation.resourceName('bad/resource'))

      local arbitrary = setmetatable({ title = 'No' }, { __index = function() return true end })
      local decorated = setmetatable({ title = 'No' }, {
        __jsontype = 'object', __index = function() return true end,
      })
      local arbitraryValue, arbitraryError =
        SynexNotifyValidation.canonicalNotification(arbitrary, { authority = 'CLIENT' })
      local decoratedValue, decoratedError =
        SynexNotifyValidation.canonicalNotification(decorated, { authority = 'CLIENT' })
      assert(arbitraryValue == nil and arbitraryError.code == 'NOTIFY_INVALID_REQUEST')
      assert(decoratedValue == nil and decoratedError.code == 'NOTIFY_INVALID_REQUEST')
      assert(SynexNotifyValidation.copy({ callback = function() end }) == nil)
      assert(SynexNotifyValidation.copy({ value = 0 / 0 }) == nil)

      local copied = assert(SynexNotifyValidation.copy(request))
      assert(getmetatable(copied).__jsontype == 'object')
      assert(getmetatable(copied.actions).__jsontype == 'array')
      return canonical.origin .. ':' .. canonical.actions[1].id
    `);
    assert.equal(result, 'LOCAL:accept');
  } finally {
    engine.global.close();
  }
});

test('notify validation rejects privileged local surfaces and transport-shaped input fields', async () => {
  const engine = await notifyLua();
  try {
    const result = await engine.doString(`
      local banner, bannerError = SynexNotifyValidation.canonicalNotification({
        kind = 'banner', title = 'Denied',
      }, { authority = 'CLIENT' })
      local critical, criticalError = SynexNotifyValidation.canonicalNotification({
        title = 'Denied', priority = 'critical',
      }, { authority = 'CLIENT' })
      local origin, originError = SynexNotifyValidation.canonicalNotification({
        title = 'Denied', origin = 'SYSTEM',
      }, { authority = 'CLIENT' })
      local url, urlError = SynexNotifyValidation.canonicalNotification({
        title = 'Denied', iconUrl = 'https://invalid.example/icon.svg',
      }, { authority = 'CLIENT' })
      assert(banner == nil and bannerError.code == 'NOTIFY_PRIORITY_DENIED')
      assert(critical == nil and criticalError.code == 'NOTIFY_PRIORITY_DENIED')
      assert(origin == nil and originError.code == 'NOTIFY_INVALID_REQUEST')
      assert(url == nil and urlError.code == 'NOTIFY_INVALID_REQUEST')

      local presentation = assert(SynexNotifyValidation.canonicalPresentation({
        notificationId = 'server-notification-1', revision = 1,
        kind = 'toast', tone = 'info', priority = 'normal', title = 'Server',
        createdAt = 1000, position = 'top-right', origin = 'SERVER',
        actions = {{ token = 'opaque-server-token', label = 'Accept', ttlMs = 30000 }},
      }, { authority = 'SERVER', ownerResource = 'external.consumer' }))
      assert(presentation.origin == 'SERVER')
      assert(presentation.actions[1].token == 'opaque-server-token')
      assert(presentation.actions[1].ttlMs == 30000)
      return table.concat({ bannerError.code, criticalError.code, presentation.origin }, ':')
    `);
    assert.equal(result, 'NOTIFY_PRIORITY_DENIED:NOTIFY_PRIORITY_DENIED:SERVER');
  } finally {
    engine.global.close();
  }
});
