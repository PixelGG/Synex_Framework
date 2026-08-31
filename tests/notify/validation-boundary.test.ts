import assert from 'node:assert/strict';
import test from 'node:test';
import { notifySharedFiles, runNotifyLua } from './helpers.js';

test('canonical text accepts valid Unicode as inert content and rejects malformed or controlled bytes', async () => {
  const result = await runNotifyLua<string>(`
    local markup = '<script>alert("not executable")</script> & <b>text</b>'
    local euro = string.char(0xe2, 0x82, 0xac)
    local valid = assert(SynexNotifyValidation.canonicalNotification({
      title = euro:rep(40),
      message = markup .. string.char(10) .. 'second line',
    }, { authority = 'CLIENT' }))
    assert(valid.title == euro:rep(40))
    assert(valid.message == markup .. string.char(10) .. 'second line')

    local _, titleBoundError = SynexNotifyValidation.canonicalNotification({
      title = euro:rep(41),
    }, { authority = 'CLIENT' })
    local _, malformedError = SynexNotifyValidation.canonicalNotification({
      title = 'Malformed ' .. string.char(0xc3, 0x28),
    }, { authority = 'CLIENT' })
    local _, nulError = SynexNotifyValidation.canonicalNotification({
      title = 'Controlled' .. string.char(0),
    }, { authority = 'CLIENT' })
    local _, deleteError = SynexNotifyValidation.canonicalNotification({
      title = 'Controlled' .. string.char(127),
    }, { authority = 'CLIENT' })
    assert(titleBoundError.code == 'NOTIFY_INVALID_REQUEST')
    assert(malformedError.code == 'NOTIFY_INVALID_REQUEST')
    assert(nulError.code == 'NOTIFY_INVALID_REQUEST')
    assert(deleteError.code == 'NOTIFY_INVALID_REQUEST')
    return table.concat({ #valid.title, titleBoundError.code,
      malformedError.code, nulError.code, deleteError.code }, ':')
  `, notifySharedFiles);
  assert.equal(
    result,
    '120:NOTIFY_INVALID_REQUEST:NOTIFY_INVALID_REQUEST:'
      + 'NOTIFY_INVALID_REQUEST:NOTIFY_INVALID_REQUEST',
  );
});

test('action, progress, dedupe, duration, and exact-object boundaries reject structural ambiguity', async () => {
  const result = await runNotifyLua<string>(`
    local failures = {}
    local function rejected(request)
      local value, operationError = SynexNotifyValidation.canonicalNotification(
        request, { authority = 'SERVER' })
      assert(value == nil and operationError.code == 'NOTIFY_INVALID_REQUEST')
      failures[#failures + 1] = operationError.code
    end
    rejected({ title = 'Sparse actions', actions = {
      [1] = { id = 'one', label = 'One' },
      [3] = { id = 'three', label = 'Three' },
    } })
    rejected({ title = 'Duplicate actions', actions = {
      { id = 'same', label = 'One' }, { id = 'same', label = 'Two' },
    } })
    rejected({ title = 'Too many actions', actions = {
      { id = 'one', label = 'One' }, { id = 'two', label = 'Two' },
      { id = 'three', label = 'Three' },
    } })
    rejected({ title = 'Indeterminate values', kind = 'progress', progress = {
      state = 'RUNNING', mode = 'indeterminate', value = 1,
    } })
    rejected({ title = 'Overflow progress', kind = 'progress', progress = {
      state = 'RUNNING', mode = 'determinate', value = 11, maximum = 10,
    } })
    rejected({ title = 'Dedupe policy without key', dedupePolicy = 'replace' })
    rejected({ title = 'Refresh cap without refresh', maxRefreshCount = 2 })
    rejected({ title = 'Refresh cap overflow', dedupeKey = 'refresh',
      dedupePolicy = 'refresh', maxRefreshCount = 33 })
    rejected({ title = 'Lifetime below duration', durationMs = 5000, maxLifetimeMs = 3000 })
    rejected({ title = 'Unknown field', execute = 'arbitrary code' })

    local bounded = assert(SynexNotifyValidation.canonicalNotification({
      title = 'Auto duration', message = ('long readable content '):rep(20),
      maxLifetimeMs = 3000,
    }, { authority = 'SERVER' }))
    assert(bounded.durationMs == 3000)
    local refresh = assert(SynexNotifyValidation.canonicalNotification({
      title = 'Bounded refresh', dedupeKey = 'refresh',
      dedupePolicy = 'refresh', maxRefreshCount = 2,
    }, { authority = 'SERVER' }))
    assert(refresh.maxRefreshCount == 2)
    assert(#failures == 10)
    return #failures .. ':' .. bounded.durationMs .. ':' .. refresh.maxRefreshCount
  `, notifySharedFiles);
  assert.equal(result, '10:3000:2');
});

test('notification copies reject cycles, executable values, non-finite numbers, and active metatables', async () => {
  const result = await runNotifyLua<string>(`
    local cycle = {}
    cycle.self = cycle
    local callable = setmetatable({}, { __call = function() return true end })
    local activeJson = setmetatable({}, {
      __jsontype = 'object',
      __index = function() return 'active' end,
    })
    assert(SynexNotifyValidation.copy(cycle) == nil)
    assert(SynexNotifyValidation.copy({ callback = function() end }) == nil)
    assert(SynexNotifyValidation.copy({ coroutine = coroutine.create(function() end) }) == nil)
    assert(SynexNotifyValidation.copy({ value = math.huge }) == nil)
    assert(SynexNotifyValidation.copy({ value = 0 / 0 }) == nil)
    assert(SynexNotifyValidation.copy(callable) == nil)
    assert(SynexNotifyValidation.copy(activeJson) == nil)
    local safe = assert(SynexNotifyValidation.copy(setmetatable({
      nested = setmetatable({}, { __jsontype = 'array' }),
    }, { __jsontype = 'object' })))
    assert(getmetatable(safe).__jsontype == 'object')
    assert(getmetatable(safe.nested).__jsontype == 'array')
    return 'copy-boundaries-pass'
  `, notifySharedFiles);
  assert.equal(result, 'copy-boundaries-pass');
});

test('canonical notifications and patches enforce the encoded payload byte ceiling', async () => {
  const result = await runNotifyLua<string>(`
    local request = {
      title = 'Escaped payload',
      message = ('\\\\'):rep(120),
      actions = {{ id = 'accept', label = ('\\\\'):rep(32) }},
    }
    local canonical = assert(SynexNotifyValidation.canonicalNotification(
      request, { authority = 'CLIENT' }))
    local requestBytes = assert(SynexNotifyValidation.payloadBytes(canonical))
    SynexNotifyLimits.maximumPayloadBytes = requestBytes
    assert(SynexNotifyValidation.canonicalNotification(
      request, { authority = 'CLIENT' }))
    SynexNotifyLimits.maximumPayloadBytes = requestBytes - 1
    local rejected, requestError = SynexNotifyValidation.canonicalNotification(
      request, { authority = 'CLIENT' })
    assert(rejected == nil and requestError.code == 'NOTIFY_PAYLOAD_TOO_LARGE')

    SynexNotifyLimits.maximumPayloadBytes = 4096
    local patch = assert(SynexNotifyValidation.notificationPatch({
      message = ('\\\\'):rep(120),
      actions = {{ id = 'replace', label = ('\\\\'):rep(32) }},
    }, { authority = 'CLIENT' }))
    local patchBytes = assert(SynexNotifyValidation.payloadBytes(patch))
    SynexNotifyLimits.maximumPayloadBytes = patchBytes - 1
    local patchRejected, patchError = SynexNotifyValidation.notificationPatch({
      message = ('\\\\'):rep(120),
      actions = {{ id = 'replace', label = ('\\\\'):rep(32) }},
    }, { authority = 'CLIENT' })
    assert(patchRejected == nil and patchError.code == 'NOTIFY_PAYLOAD_TOO_LARGE')
    return requestError.code .. ':' .. patchError.code
  `, notifySharedFiles);
  assert.equal(result, 'NOTIFY_PAYLOAD_TOO_LARGE:NOTIFY_PAYLOAD_TOO_LARGE');
});
