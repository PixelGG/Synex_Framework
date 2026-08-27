import assert from 'node:assert/strict';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';
import { bootstrapControlLua } from './helpers.js';

test('Control sanitizer redacts composed secrets and masks identifiers by default', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrapControlLua(engine);
    const result = await engine.doString(`
      local value, report = SynexControlSanitizer.sanitize({
        api_key = 'api-secret-value',
        accessToken = 'access-secret-value',
        refresh_token = 'refresh-secret-value',
        private_key = 'private-secret-value',
        auth_token = 'auth-secret-value',
        session_token = 'session-secret-value',
        nested = { connectionString = 'mysql://private', password_hash = 'hash' },
        account_id = '11111111-1111-4111-8111-111111111111',
        source_account_id = '22222222-2222-4222-8222-222222222222',
        actor_character_id = 'character_private_actor',
        parent_group_id = 'group_private_parent',
        entityId = 'entity_private_0001',
        amountMinor = '9007199254740991',
      })
      assert(value.api_key == '[REDACTED]')
      assert(value.accessToken == '[REDACTED]')
      assert(value.refresh_token == '[REDACTED]')
      assert(value.private_key == '[REDACTED]')
      assert(value.auth_token == '[REDACTED]')
      assert(value.session_token == '[REDACTED]')
      assert(value.nested.connectionString == '[REDACTED]')
      assert(value.nested.password_hash == '[REDACTED]')
      assert(value.account_id == '1111...1111')
      assert(value.source_account_id == '2222...2222')
      assert(value.actor_character_id == 'char...ctor')
      assert(value.parent_group_id == 'grou...rent')
      assert(value.entityId == 'enti...0001')
      assert(value.amountMinor == '9007199254740991')
      assert(report.redactions == 8)
      assert(report.masked == 5)
      return value.account_id .. ':' .. value.entityId
    `);
    assert.equal(result, '1111...1111:enti...0001');
  } finally {
    engine.global.close();
  }
});

test('Control sanitizer never reveals secrets when identifier permission is enabled', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrapControlLua(engine);
    const result = await engine.doString(`
      local value = SynexControlSanitizer.sanitize({
        characterId = 'character_private_0001',
        license = 'license:private-player',
        license_key = 'commercial-secret',
        webhook_url = 'https://private.invalid/hook',
        callback_url = 'https://discord.com/api/webhooks/123/private',
        endpoint = 'mysql://operator:password@database.example/synex',
      }, { revealIdentifiers = true })
      assert(value.characterId == 'character_private_0001')
      assert(value.license == '[REDACTED]')
      assert(value.license_key == '[REDACTED]')
      assert(value.webhook_url == '[REDACTED]')
      assert(value.callback_url == '[REDACTED]')
      assert(value.endpoint == '[REDACTED]')
      return value.characterId
    `);
    assert.equal(result, 'character_private_0001');
  } finally {
    engine.global.close();
  }
});

test('Control sanitizer rejects secret-shaped values under otherwise innocent keys', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrapControlLua(engine);
    const result = await engine.doString(`
      local secrets = {
        message = 'request failed: Bearer eyJhbGciOiJIUzI1NiJ9.private.signature',
        detail = 'mysql://operator:password@database.example/synex',
        note = 'github_pat_abcdefghijklmnopqrstuvwxyz1234567890',
        reason = 'ghp_abcdefghijklmnopqrstuvwxyz1234567890',
        endpoint = 'https://example.invalid/callback?access_token=private-token-value',
        licenseHint = 'cfxk_abcdefghijklmnopqrstuvwxyz1234567890',
        awsHint = 'AKIA1234567890ABCDEF',
        block = '-----BEGIN PRIVATE KEY-----private-----END PRIVATE KEY-----',
      }
      for _, revealIdentifiers in ipairs({ false, true }) do
        local value, report = SynexControlSanitizer.sanitize(secrets, {
          revealIdentifiers = revealIdentifiers,
        })
        for key in pairs(secrets) do assert(value[key] == '[REDACTED]', key) end
        assert(report.redactions == 8)
      end
      return 'redacted'
    `);
    assert.equal(result, 'redacted');
  } finally {
    engine.global.close();
  }
});

test('Control sanitizer redacts secret-shaped identifier values before masking', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrapControlLua(engine);
    const result = await engine.doString(`
      local secrets = {
        id = 'github_pat_abcdefghijklmnopqrstuvwxyz1234567890',
        account_id = 'ghp_abcdefghijklmnopqrstuvwxyz1234567890',
        entityId = 'mysql://operator:password@database.example/synex',
      }
      for _, revealIdentifiers in ipairs({ false, true }) do
        local value, report = SynexControlSanitizer.sanitize(secrets, {
          revealIdentifiers = revealIdentifiers,
        })
        assert(value.id == '[REDACTED]')
        assert(value.account_id == '[REDACTED]')
        assert(value.entityId == '[REDACTED]')
        assert(report.redactions == 3 and report.masked == 0)
      end
      return 'identifier-secrets-redacted'
    `);
    assert.equal(result, 'identifier-secrets-redacted');
  } finally {
    engine.global.close();
  }
});

test('Control sanitizer preserves navigation IDs only inside a trusted provider metadata envelope', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrapControlLua(engine);
    const result = await engine.doString(`
      local value, report = SynexControlSanitizer.sanitize({
        data = {
          id = 'session_private_0001',
          public_id = 'entity_public_private_0002',
          graph = { edges = {{ from = 'node_private_from', to = 'node_private_to' }} },
          providers = {{
            namespace = 'core',
            views = {{
              id = 'service_detail', label = 'Service Inspector',
              search = { kinds = {{ id = 'future_kind', modes = {{ 'exact' }} }} },
            }},
          }},
          instanceId = 'instance_private_0001',
          playerSource = 42,
        },
      })
      assert(value.data.id == 'sess...0001')
      assert(value.data.public_id == 'enti...0002')
      assert(value.data.graph.edges[1].from == 'node...from',
        'from=' .. tostring(value.data.graph.edges[1].from))
      assert(value.data.graph.edges[1].to == 'node...e_to',
        'to=' .. tostring(value.data.graph.edges[1].to))
      assert(value.data.providers[1].views[1].id == 'serv...tail')
      assert(value.data.providers[1].views[1].search.kinds[1].id == 'futu...kind',
        'kind=' .. tostring(value.data.providers[1].views[1].search.kinds[1].id))
      assert(value.data.instanceId == 'inst...0001')
      assert(value.data.playerSource == '[MASKED]')
      assert(report.masked == 8)

      local trusted, trustedReport, trustedError =
        SynexControlSanitizer.encodeProviderMetadataEnvelope({
          schemaVersion = 1,
          data = {
            providers = {{
              namespace = 'core',
              views = {{
                id = 'service_detail', label = 'Service Inspector',
                search = { kinds = {{ id = 'future_kind', modes = {{ 'exact' }} }} },
              }},
            }},
          },
        })
      assert(trustedError == nil)
      assert(trusted.data.providers[1].views[1].id == 'service_detail')
      assert(trusted.data.providers[1].views[1].search.kinds[1].id == 'future_kind')
      assert(trustedReport.masked == 0)
      return trusted.data.providers[1].views[1].search.kinds[1].id
    `);
    assert.equal(result, 'future_kind');
  } finally {
    engine.global.close();
  }
});

test('Control sanitizer contains cycles, depth, huge values, callables, and non-finite numbers', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrapControlLua(engine);
    const result = await engine.doString(`
      local cyclic = { safe = true }
      cyclic.self = cyclic
      local deep = 'outside'
      for _ = 1, 9 do deep = { value = deep } end
      local value, report = SynexControlSanitizer.sanitize({
        cyclic = cyclic,
        deep = deep,
        positive = math.huge,
        negative = -math.huge,
        nan = 0 / 0,
        callback = function() return true end,
        long = string.rep('x', SynexControlLimits.maximumStringBytes + 100),
      })
      assert(value.cyclic.self == '[CYCLE]')
      assert(value.positive == '[NON_FINITE]')
      assert(value.negative == '[NON_FINITE]')
      assert(value.nan == '[NON_FINITE]')
      assert(value.callback == '[CALLABLE]')
      assert(#value.long == SynexControlLimits.maximumStringBytes)
      assert(report.truncated == true)
      assert(report.replacements >= 5)
      return report.replacements
    `);
    assert.ok(Number(result) >= 5);
  } finally {
    engine.global.close();
  }
});

test('Control sanitizer normalizes invalid UTF-8, preserves codepoint boundaries, and contains foreign shapes', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrapControlLua(engine);
    const result = await engine.doString(`
      assert(type(io.stdout) == 'userdata')
      local weird = { safe = true }
      weird[{}] = 'table-key'
      weird[false] = 'boolean-key'
      weird['invalid' .. string.char(0xff) .. 'key'] = 'kept'
      local value, report = SynexControlSanitizer.sanitize({
        invalid = 'before' .. string.char(0xff, 0xfe) .. 'after',
        multibyte = string.rep(string.char(0xc3, 0xa9), 300),
        foreign = io.stdout,
        weird = weird,
      })
      assert(utf8.len(value.invalid) ~= nil)
      assert(value.invalid:find(string.char(0xef, 0xbf, 0xbd), 1, true) ~= nil)
      assert(utf8.len(value.multibyte) ~= nil)
      assert(#value.multibyte <= SynexControlLimits.maximumStringBytes)
      assert(value.multibyte:sub(-3) == '...')
      assert(value.foreign == '[USERDATA]')
      local retainedKey
      for key in pairs(value.weird) do
        assert(type(key) == 'string' and utf8.len(key) ~= nil)
        if key:find('invalid', 1, true) then retainedKey = key end
      end
      assert(retainedKey ~= nil)
      local encoded = json.encode(value)
      assert(type(encoded) == 'string' and #encoded > 0)
      assert(report.truncated == true and report.replacements >= 5)
      return 'utf8-contained'
    `);
    assert.equal(result, 'utf8-contained');
  } finally {
    engine.global.close();
  }
});

test('Control sanitizer enforces the final serialized response byte ceiling', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrapControlLua(engine);
    const result = await engine.doString(`
      local _, _, errorCode = SynexControlSanitizer.encode({
        rows = { string.rep('a', 400), string.rep('b', 400) }
      }, { maximumBytes = 64 })
      return errorCode
    `);
    assert.equal(result, 'PAYLOAD_TOO_LARGE');
  } finally {
    engine.global.close();
  }
});

test('Control sanitizer truncates a huge logical collection at its entry ceiling', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrapControlLua(engine);
    const result = await engine.doString(`
      local logical = {}
      for index = 1, 10000 do logical[index] = { id = ('row_%05d'):format(index) } end
      local value, report = SynexControlSanitizer.sanitize(logical)
      assert(report.truncated == true)
      assert(#value <= SynexControlLimits.maximumEntriesPerResponse + 1)
      assert(#value < #logical)
      assert(value[1].id ~= 'row_00001')
      assert(report.masked > 0)
      return table.concat({#logical, #value, report.truncated and 'truncated' or 'full'}, ':')
    `);
    assert.match(String(result), /^10000:\d+:truncated$/u);
  } finally {
    engine.global.close();
  }
});
