import assert from 'node:assert/strict';
import { readFile, readdir } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';

const resource = path.join(process.cwd(), 'resources', 'synex_entities');

async function source(relativePath: string): Promise<string> {
  return readFile(path.join(resource, relativePath), 'utf8');
}

test('authority service delegates lifecycle behavior without changing its public surface', async () => {
  const [authority, lifecycle, manifest] = await Promise.all([
    source('server/authority_service.lua'),
    source('server/authority_lifecycle.lua'),
    source('fxmanifest.lua'),
  ]);
  const lifecycleMethods = [
    'initialize',
    'authoritySnapshot',
    'materialize',
    'dematerialize',
    'heartbeat',
    'releaseAuthority',
    'recoverOne',
    'runRecovery',
    'entityRemoved',
  ];
  assert.match(authority, /SynexEntityAuthorityLifecycle\.attach\(service,/u);
  for (const method of lifecycleMethods) {
    assert.match(lifecycle, new RegExp(`function service\\.${method}\\(`, 'u'));
  }
  for (const method of ['spawn', 'checkpoint', 'delete', 'ownerSet', 'bindingGet']) {
    assert.match(authority, new RegExp(`function service\\.${method}\\(`, 'u'));
  }
  assert.ok(manifest.indexOf("'server/authority_lifecycle.lua'")
    < manifest.indexOf("'server/authority_service.lua'"));
});

test('entity Lua modules respect cohesion limits after the authority split', async () => {
  const directory = path.join(resource, 'server');
  const files = (await readdir(directory)).filter((name) => name.endsWith('.lua'));
  for (const name of files) {
    const contents = await readFile(path.join(directory, name), 'utf8');
    const lines = contents.replace(/\r?\n$/u, '').split(/\r?\n/u).length;
    assert.ok(lines <= 700, `${name} has ${lines} lines; limit is 700`);
  }
  const serverContents = await source('server/server.lua');
  const serverLines = serverContents.replace(/\r?\n$/u, '').split(/\r?\n/u).length;
  assert.ok(serverLines <= 250, `server.lua has ${serverLines} lines; limit is 250`);
});

test('authority split and security integration modules compile in Lua', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await engine.doString(await source('server/authority_lifecycle.lua'));
    await engine.doString(await source('server/authority_service.lua'));
    await engine.doString(await source('server/security_reporting.lua'));
    assert.equal(await engine.doString(String.raw`
      return type(SynexEntityAuthorityLifecycle.attach) == 'function'
        and type(SynexEntityAuthorityService.create) == 'function'
        and type(SynexEntitySecurityReporting.create) == 'function'
    `), true);
  } finally {
    engine.global.close();
  }
});
