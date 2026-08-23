import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory, type LuaEngine } from 'wasmoon';

const root = process.cwd();

async function load(engine: LuaEngine, relativePath: string): Promise<void> {
  await engine.doString(await readFile(path.join(root, relativePath), 'utf8'));
}

test('contract gateway rejects aggregate request and response bytes before downstream work', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await load(engine, 'core/synex_core/shared/protocol.lua');
    await load(engine, 'core/synex_core/server/factories.lua');
    for (const module of ['foundation', 'registries', 'contracts', 'messaging']) {
      await load(engine, `core/synex_core/server/${module}.lua`);
    }

    const result = await engine.doString(`
      local oversizedRequest, oversizedOutput = {}, {}
      for index = 1, 64 do
        oversizedRequest['request_' .. index] = string.rep('r', 32)
        oversizedOutput['response_' .. index] = string.rep('s', 32)
      end
      local requestEncodes, outputEncodes = 0, 0
      local platform = {
        nowGame = function() return 1000 end,
        random = function() return 1 end,
        print = function() end,
        jsonEncode = function(value)
          if value == oversizedRequest then requestEncodes = requestEncodes + 1 end
          if value == oversizedOutput then outputEncodes = outputEncodes + 1 end
          return '{}'
        end
      }
      local foundation = SynexCoreFactories.foundation({ platform = platform })
      foundation.configureIds('messaging-contract-transport')
      local registries = SynexCoreFactories.registries({ foundation = foundation })
      local owners = registries.owners
      local providerEpoch = owners:activate('synex_provider')
      local callerEpoch = owners:activate('synex_caller')
      local contracts = SynexCoreFactories.contracts({
        foundation = foundation, protocol = SynexProtocol
      })
      local messaging = SynexCoreFactories.messaging({
        platform = platform, foundation = foundation, contracts = contracts,
        security = { capabilities = { check = function() return true, nil end } },
        owners = owners, players = registries.players,
        lifecycle = { core = { isOperational = function() return true end } },
        protocol = SynexProtocol, config = { maximumPayloadBytes = 1024 },
        coreResource = 'synex_core'
      })
      local handlerCalls = 0
      assert(messaging.gateway:register('synex_provider', providerEpoch, {
        name = 'synex.fixture.transport_bounds', version = '1.0.0',
        provider = 'synex_provider', kind = 'rpc', stability = 'experimental',
        network = 'none', errors = {}, input = { type = 'object' },
        output = { type = 'object' }
      }, function()
        handlerCalls = handlerCalls + 1
        return oversizedOutput, nil
      end))

      local resolveCalls, requestCopies, outputCopies, outputValidations = 0, 0, 0, 0
      local originalResolve = contracts.registry.resolve
      contracts.registry.resolve = function(self, ...)
        resolveCalls = resolveCalls + 1
        return originalResolve(self, ...)
      end
      local originalValidateOutput = contracts.registry.validateOutput
      contracts.registry.validateOutput = function(self, contract, value)
        if value == oversizedOutput then outputValidations = outputValidations + 1 end
        return originalValidateOutput(self, contract, value)
      end
      local originalCopy = foundation.copy
      foundation.copy = function(value)
        if value == oversizedRequest then requestCopies = requestCopies + 1 end
        if value == oversizedOutput then outputCopies = outputCopies + 1 end
        return originalCopy(value)
      end

      local rejectedRequest, requestError = messaging.gateway:invoke(
        'synex_caller', callerEpoch, 'synex.fixture.transport_bounds', '1.0.0',
        oversizedRequest, {})
      assert(rejectedRequest == nil and requestError.code == 'PAYLOAD_TOO_LARGE')
      assert(requestEncodes == 0 and resolveCalls == 0 and handlerCalls == 0
        and requestCopies == 0,
        'request byte preflight must precede encoding, resolution, handling, and copying')

      local rejectedOutput, outputError = messaging.gateway:invoke(
        'synex_caller', callerEpoch, 'synex.fixture.transport_bounds', '1.0.0', {}, {})
      assert(rejectedOutput == nil and outputError.code == 'RESPONSE_TOO_LARGE')
      assert(resolveCalls == 1 and handlerCalls == 1)
      assert(outputEncodes == 0 and outputValidations == 0 and outputCopies == 0,
        'response byte preflight must precede encoding, schema validation, and copying')
      return table.concat({requestError.code, outputError.code, requestEncodes,
        resolveCalls, handlerCalls, outputCopies}, ':')
    `);

    assert.equal(result, 'PAYLOAD_TOO_LARGE:RESPONSE_TOO_LARGE:0:1:1:0');
  } finally {
    engine.global.close();
  }
});
