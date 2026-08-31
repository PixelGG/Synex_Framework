import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';

const root = process.cwd();

test('notify client remains focusless, event-fenced, and bounded-retry driven', async () => {
  const [runtime, manifest] = await Promise.all([
    readFile(path.join(root, 'resources/synex_notify/client/runtime.lua'), 'utf8'),
    readFile(path.join(root, 'resources/synex_notify/fxmanifest.lua'), 'utf8'),
  ]);
  assert.doesNotMatch(runtime, /SetNuiFocus|SetNuiFocusKeepInput|DisableControlAction|CreateThread/u);
  assert.doesNotMatch(runtime, /IsUsingKeyboard/u);
  assert.match(runtime, /uiCall\('reportInputDevice', 'keyboard'\)/u);
  assert.match(runtime, /uiCall\('reportInputDevice', 'gamepad'\)/u);
  assert.doesNotMatch(manifest, /ui_page/u);
  assert.match(runtime, /source ~= 65535/u);
  assert.match(runtime, /synex_notify:client:command:v1/u);
  assert.match(runtime, /exports\.synex_core:Call\('synex\.notify\.command\.pull', '1\.0\.0'/u);
  assert.match(runtime, /schemaVersion = true, commandId = true/u);
  assert.match(runtime, /UI_RETRY_DELAYS_MS = \{ 0, 50, 150, 400, 1000, 2000, 4000 \}/u);
  assert.match(runtime, /engine\.reconcile\(snapshot\)/u);
  assert.match(runtime, /engine\.setUiPreferences\(preferences\)/u);
  assert.match(runtime, /exports\.synex_core:Call\('synex\.notify\.action\.invoke', '1\.0\.0'/u);
  assert.match(runtime, /api\.notify = api\.show/u);
  assert.match(runtime, /api\.setPresentationContext/u);
  assert.match(runtime, /api\.clearPresentationContext/u);
  assert.match(runtime, /engine\.setPresentationPreferences/u);
  assert.match(runtime,
    /state\.actionTokens <= 0 and state\.pendingVisibilityAcks <= 0/u);
});

test('UI projection exposes only canonical signal fields and presentation action tokens', async () => {
  const engine = await readFile(
    path.join(root, 'resources/synex_notify/client/engine.lua'), 'utf8',
  );
  const projectionStart = engine.indexOf('local function signalDescriptor');
  const projectionEnd = engine.indexOf('local function render', projectionStart);
  assert.ok(projectionStart >= 0 && projectionEnd > projectionStart);
  const projection = engine.slice(projectionStart, projectionEnd);
  for (const field of [
    'signalId', 'revision', 'kind', 'tone', 'priority', 'title', 'createdAt',
    'position', 'message', 'iconKey', 'count', 'progress', 'expiresAt', 'actions',
  ]) {
    assert.match(projection, new RegExp(`\\b${field}\\b`, 'u'));
  }
  assert.doesNotMatch(projection, /ownerResource|ownerEpoch|sourceNotificationId|ttlMs/u);
  assert.match(projection, /token = utf8Prefix\(action\.displayToken, UI_ACTION_TOKEN_BYTES\)/u);
  assert.doesNotMatch(projection, /token = action\.token/u);
});
