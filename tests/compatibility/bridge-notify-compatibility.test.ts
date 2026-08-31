import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';

const root = process.cwd();
const providers = ['qb', 'qbx', 'esx'] as const;

async function providerClient(provider: typeof providers[number]): Promise<string> {
  const [normalizer, client] = await Promise.all([
    readFile(path.join(root, 'libraries', 'synex_bridge', 'compatibility_notify.lua'), 'utf8'),
    readFile(path.join(root, 'resources', `synex_bridge_${provider}`, 'client.lua'), 'utf8'),
  ]);
  return `${normalizer}\n${client}`;
}

test('legacy notification catalogs remain pinned, partial, and event-honest', async () => {
  for (const provider of providers) {
    const catalog = JSON.parse(await readFile(path.join(
      root, 'libraries', 'synex_bridge', 'compatibility', 'surfaces', `${provider}.json`,
    ), 'utf8')) as {
      upstream: { revision: string; sources: Array<{ path: string; sha256: string }> };
      surfaces: Array<{
        name: string; status: string; nativeMapping: string | null;
        requiredCapability: string | null; tests: string[];
      }>;
    };
    assert.match(catalog.upstream.revision, /^[0-9a-f]{40}$/u);
    assert.ok(catalog.upstream.sources.some((source) => source.path.includes('client/')));
    assert.ok(catalog.upstream.sources.every((source) => /^[0-9a-f]{64}$/u.test(source.sha256)));

    const supported = catalog.surfaces.find((surface) =>
      surface.name === `${provider}.client.notification`);
    assert.equal(supported?.status, 'PARTIAL');
    assert.equal(supported?.nativeMapping, 'synex.notify.compatibility@1');
    assert.equal(supported?.requiredCapability, `synex.compat.${provider}.read`);
    assert.ok(supported?.tests.includes(
      'tests/compatibility/bridge-notify-compatibility.test.ts'));

    const unsupportedEvent = catalog.surfaces.find((surface) =>
      surface.name === `${provider}.client.notification_event`
      || surface.name === `${provider}.client.notification_events`);
    assert.equal(unsupportedEvent?.status, 'UNSUPPORTED');
    assert.equal(unsupportedEvent?.nativeMapping, null);

    const descriptor = JSON.parse(await readFile(path.join(
      root, 'resources', `synex_bridge_${provider}`, 'synex.resource.json',
    ), 'utf8')) as { dependencies: { optional: Array<{ name: string; version: string }> } };
    assert.deepEqual(descriptor.dependencies.optional, [
      { name: 'synex_notify', version: '>=0.1.0' },
    ]);
    const manifest = await readFile(path.join(
      root, 'resources', `synex_bridge_${provider}`, 'fxmanifest.lua',
    ), 'utf8');
    assert.match(manifest, /@synex_bridge\/compatibility_notify\.lua/u);
    const client = await readFile(path.join(
      root, 'resources', `synex_bridge_${provider}`, 'client.lua',
    ), 'utf8');
    assert.doesNotMatch(client,
      /RegisterNetEvent\(['"](?:QBCore:Notify|QBCore:Client:Notify|qbx_core:client:notify|esx:showNotification|esx:showAdvancedNotification)/u);
  }

  const qbFacade = await readFile(path.join(
    root, 'compat', 'facades', 'qb-core', 'client.lua',
  ), 'utf8');
  const qbxFacade = await readFile(path.join(
    root, 'compat', 'facades', 'qbx_core', 'client.lua',
  ), 'utf8');
  assert.match(qbFacade, /NotifyForConsumer/u);
  assert.match(qbxFacade, /NotifyForConsumer/u);
});

for (const provider of providers) {
  test(`${provider.toUpperCase()} legacy notifications stay consumer-bound and canonical`, async () => {
    const engine = await new LuaFactory().createEngine();
    try {
      await engine.doString(String.raw`
        invoking, source, notifyState = 'authorized_a', 65535, 'started'
        registered, handlers, notifyCalls, apiCalls = {}, {}, {}, {}
        local transport = {}
        function transport:triggerCallback() return true end
        SynexBridgeClient = { create = function() return transport end }
        local notifyResource = {}
        function notifyResource:GetCompatibilityAPI(consumer, requestedProvider)
          apiCalls[#apiCalls + 1] = {
            consumer = consumer, provider = requestedProvider,
          }
          return { notify = function(request)
            notifyCalls[#notifyCalls + 1] = {
              consumer = consumer, provider = requestedProvider, request = request,
            }
            return { accepted = true }
          end }
        end
        exports = setmetatable({ synex_notify = notifyResource }, {
          __call = function(_, name, handler) registered[name] = handler end,
        })
        RegisterNetEvent = function(name, handler) handlers[name] = handler end
        GetInvokingResource = function() return invoking end
        GetResourceState = function(name)
          assert(name == 'synex_notify')
          return notifyState
        end
      `);
      await engine.doString(await providerClient(provider));
      const result = await engine.doString(String.raw`
        local projection = handlers['synex_bridge_${provider}:client:projection']
        projection('replace', {}, {
          playerData = {}, callbacks = {}, notifications = { 'authorized_a' },
        })

        local function exactCanonical(entry, expectedTone, expectedTitle,
            expectedDuration)
          assert(entry.consumer == 'authorized_a'
            and entry.provider == '${provider}')
          local request = entry.request
          local allowed = {
            kind = true, tone = true, priority = true, title = true,
            message = true, durationMs = true,
          }
          for key in next, request do assert(allowed[key] == true) end
          assert(request.kind == 'toast' and request.priority == 'normal')
          assert(request.tone == expectedTone and request.title == expectedTitle)
          assert(request.durationMs == expectedDuration)
          assert(request.origin == nil and request.target == nil
            and request.actions == nil and request.iconKey == nil)
        end

        local retained
        if '${provider}' == 'qb' then
          local core = assert(registered.GetCoreObject())
          assert(core.Functions.GetPlayerData == nil)
          retained = assert(core.Functions.Notify)
          assert(retained({ text = '~r~Body', caption = 'Caption' },
            'error', 250, 'ignored'))
          exactCanonical(notifyCalls[1], 'danger', 'Caption', 1500)
          assert(notifyCalls[1].request.message == 'Body')
          assert(registered.Notify('<b>unsafe</b>', 'success', 5000) == nil)
          assert(registered.Notify({ text = 'safe', extra = 'forged' }) == nil)
        elseif '${provider}' == 'qbx' then
          retained = assert(registered.Notify)
          assert(retained('Body', 'custom-tone', 999999, 'Subtitle', 'center',
            { hostile = true }, '<svg>', '#fff'))
          exactCanonical(notifyCalls[1], 'neutral', 'Subtitle', 30000)
          assert(notifyCalls[1].request.message == 'Body')
          assert(retained('<script>x</script>', 'error', 5000) == nil)
        else
          local shared = assert(registered.getSharedObject())
          assert(shared.GetPlayerData == nil)
          retained = assert(shared.ShowNotification)
          assert(retained('Body', 'success', 5000, 'Title', 'top'))
          exactCanonical(notifyCalls[1], 'success', 'Title', 5000)
          assert(shared.ShowAdvancedNotification('Dispatch', 'Update', 'Ready',
            'texture', 9, true, true, 255))
          exactCanonical(notifyCalls[2], 'info', 'Dispatch - Update', nil)
          assert(shared.ShowAdvancedNotification('<b>sender</b>', 'Update',
            'Ready') == nil)
        end

        local accepted = #notifyCalls
        invoking = 'denied_b'
        if '${provider}' == 'qb' then
          assert(registered.Notify('forged') == nil)
        elseif '${provider}' == 'qbx' then
          assert(registered.Notify('forged') == nil)
        else
          assert(registered.getSharedObject() == nil)
        end
        assert(#notifyCalls == accepted)

        source = 1
        projection('replace', {}, {
          playerData = {}, callbacks = {}, notifications = { 'denied_b' },
        })
        source = 65535
        invoking = 'authorized_a'
        assert(retained('foreign projection') ~= nil)
        assert(#notifyCalls == accepted + 1)

        projection('clear')
        assert(retained('stale closure') == nil and #notifyCalls == accepted + 1)
        notifyState = 'missing'
        projection('replace', {}, {
          playerData = {}, callbacks = {}, notifications = { 'authorized_a' },
        })
        assert(retained('missing notify') == nil and #notifyCalls == accepted + 1)
        return table.concat({ '${provider}', #notifyCalls, #apiCalls }, ':')
      `);
      const expectedCalls = provider === 'esx' ? 3 : 2;
      assert.equal(result, `${provider}:${expectedCalls}:${expectedCalls}`);
    } finally {
      engine.global.close();
    }
  });
}

test('client notification projection is operator-governed and requires native Notify authority', async () => {
  const coordinator = await readFile(path.join(
    root, 'libraries', 'synex_bridge', 'server.lua',
  ), 'utf8');
  const native = await readFile(path.join(
    root, 'libraries', 'synex_bridge', 'native_server.lua',
  ), 'utf8');
  for (const source of [coordinator, native]) {
    assert.match(source, /client\.notification\.send/u);
    assert.match(source, /synex\.notify\.send/u);
    assert.match(source, /notifications/u);
  }
});

test('QB and Qbox client facades forward only their immediate Cfx caller', async () => {
  for (const fixture of [
    { facade: 'qb-core', provider: 'synex_bridge_qb' },
    { facade: 'qbx_core', provider: 'synex_bridge_qbx' },
  ] as const) {
    const engine = await new LuaFactory().createEngine();
    try {
      await engine.doString(String.raw`
        invoking, registered, providerCalls = 'real_consumer', {}, {}
        local provider = {}
        provider.NotifyForConsumer = function(_, consumer, ...)
          providerCalls[#providerCalls + 1] = {
            name = 'NotifyForConsumer', consumer = consumer,
            arguments = table.pack(...),
          }
          return true
        end
        exports = setmetatable({}, {
          __call = function(_, name, handler) registered[name] = handler end,
          __index = function(_, resource)
            assert(resource == '${fixture.provider}')
            return provider
          end,
        })
        GetInvokingResource = function() return invoking end
      `);
      await engine.doString(await readFile(path.join(
        root, 'compat', 'facades', fixture.facade, 'client.lua',
      ), 'utf8'));
      const result = await engine.doString(String.raw`
        assert(registered.Notify('Body', 'success', 5000))
        assert(#providerCalls == 1, 'unexpected provider call count: '
          .. tostring(#providerCalls))
        assert(providerCalls[1].name == 'NotifyForConsumer',
          'unexpected provider method: ' .. tostring(providerCalls[1].name))
        assert(providerCalls[1].consumer == 'real_consumer',
          'unexpected bound consumer: ' .. tostring(providerCalls[1].consumer))
        invoking = 'x'
        assert(registered.Notify('forged') == nil and #providerCalls == 1)
        return providerCalls[1].consumer
      `);
      assert.equal(result, 'real_consumer');
    } finally {
      engine.global.close();
    }
  }
});
