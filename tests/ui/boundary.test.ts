import assert from 'node:assert/strict';
import { readFile, stat } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';

const root = process.cwd();
const read = (relative: string) => readFile(path.join(root, relative), 'utf8');

test('synex_ui is a client-only hybrid package/resource with strict local NUI assets', async () => {
  const [manifest, resourceManifest, packageJson] = await Promise.all([
    read('libraries/synex_ui/fxmanifest.lua'),
    read('libraries/synex_ui/synex.resource.json'),
    read('libraries/synex_ui/package.json'),
  ]);
  assert.match(manifest, /dependency\s+['"]synex_core['"]/);
  assert.match(manifest, /client_script\s+['"]client\/client\.lua['"]/);
  assert.match(manifest, /ui_page\s+['"]web\/dist\/index\.html['"]/);
  assert.match(manifest, /nui_callback_strict_mode\s+['"]true['"]/);
  assert.doesNotMatch(manifest, /server_script/);
  assert.doesNotMatch(manifest, /shared_script/);

  const descriptor = JSON.parse(resourceManifest) as Record<string, unknown>;
  assert.deepEqual(descriptor.migrations, []);
  assert.deepEqual(descriptor.dataOwnership, { tables: [], characterDelete: 'none' });
  assert.deepEqual(descriptor.capabilities, { request: [] });

  const packageDescriptor = JSON.parse(packageJson) as { name: string; exports: Record<string, unknown>; dependencies?: Record<string, string> };
  assert.equal(packageDescriptor.name, '@synex/ui');
  assert.ok(packageDescriptor.exports['.']);
  assert.equal(packageDescriptor.exports['./styles.css'], './dist/styles.css');
  assert.deepEqual(packageDescriptor.dependencies ?? {}, {});
});

test('synex_control remains runtime-independent from synex_ui', async () => {
  const files = await Promise.all([
    read('resources/synex_control/fxmanifest.lua'),
    read('resources/synex_control/synex.resource.json'),
    read('resources/synex_control/client/client.lua'),
    read('resources/synex_control/server/server.lua'),
  ]);
  for (const source of files) assert.doesNotMatch(source, /synex_ui/);
});

test('the UI runtime exposes only fixed local callbacks and no domain or network authority', async () => {
  const source = await read('libraries/synex_ui/client/client.lua');
  const callbacks = [...source.matchAll(/registerNuiRoute\('([^']+)'/g)].map((match) => match[1]).sort();
  assert.deepEqual(callbacks, [
    'runtime:close',
    'runtime:error',
    'runtime:input',
    'runtime:interaction',
    'runtime:preferences',
    'runtime:ready',
    'runtime:respond',
    'runtime:signals:visible',
  ]);
  for (const forbidden of [
    /RegisterNetEvent/,
    /TriggerServerEvent/,
    /TriggerLatentServerEvent/,
    /PerformHttpRequest/,
    /MySQL/,
    /exports\[['"]/,
    /ExecuteCommand/,
    /LoadResourceFile/,
    /SaveResourceFile/,
  ]) assert.doesNotMatch(source, forbidden);
  for (const method of [
    'acquireFocus', 'getFocusLease', 'releaseFocus', 'alert', 'confirm', 'input', 'form',
    'select', 'menu', 'contextMenu', 'closeOwner', 'getPreferences', 'setPreferences',
    'getHealth', 'getDiagnostics',
  ]) assert.match(source, new RegExp(`api\\.${method}\\s*=\\s*function`));
  for (const method of ['bindSignalCapacity', 'reportInputDevice', 'playSignalSound']) {
    assert.match(source, new RegExp(
      `if owner == SIGNAL_TRANSPORT_OWNER then[\\s\\S]*?api\\.${method}\\s*=\\s*function`, 'u',
    ));
  }
  assert.match(source, /\['signal:sound'\]\s*=\s*true/u);
  assert.doesNotMatch(source, /PlaySoundFrontend/u);
});

test('notification sound is a local one-shot browser effect outside retained UI state', async () => {
  const [protocol, app, store, sound] = await Promise.all([
    read('libraries/synex_ui/runtime/src/protocol.ts'),
    read('libraries/synex_ui/runtime/src/RuntimeApp.tsx'),
    read('libraries/synex_ui/runtime/src/store.ts'),
    read('libraries/synex_ui/runtime/src/signalSound.ts'),
  ]);
  assert.match(protocol, /type SignalSoundTone = SignalTone \| 'critical'/u);
  assert.match(protocol, /ownerResource !== 'synex_notify' \|\| revision !== 0/u);
  assert.match(app, /if \(envelope\.type === 'signal:sound'\)[\s\S]*?soundIngress\.accept[\s\S]*?playSignalSound\([\s\S]*?return;/u);
  assert.match(sound, /maximumRememberedMessages:\s*64/u);
  assert.match(sound, /maximumSoundsPerWindow:\s*8/u);
  assert.match(sound, /maximumActiveVoices:\s*4/u);
  assert.match(store, /if \(envelope\.type === 'signal:sound'\) return state;/u);
  assert.match(sound, /createOscillator\(\)/u);
  assert.match(sound, /createGain\(\)/u);
  assert.match(sound, /Math\.pow\(normalizedVolume, 1\.6\)/u);
  assert.doesNotMatch(sound, /fetch\(|XMLHttpRequest|setInterval|requestAnimationFrame/u);
  assert.doesNotMatch(sound, /document\.|focus\(|visibility/u);
});

test('browser transport is static, text-only, and bounded', async () => {
  const [protocol, transport, app, document] = await Promise.all([
    read('libraries/synex_ui/runtime/src/protocol.ts'),
    read('libraries/synex_ui/runtime/src/transport.ts'),
    read('libraries/synex_ui/runtime/src/RuntimeApp.tsx'),
    read('libraries/synex_ui/runtime/index.html'),
  ]);
  assert.match(protocol, /maxPayloadBytes:\s*32\s*\*\s*1024/);
  assert.match(protocol, /maxPendingRequests:\s*64/);
  assert.match(protocol, /forbiddenPayloadKeys\s*=\s*new Set\(\['html', 'svg', 'url', 'href', 'src', 'iframe', 'script'\]\)/);
  assert.match(transport, /const routes = new Set<CallbackRoute>/);
  assert.match(transport, /`https:\/\/\$\{resourceName\}\/\$\{route\}`/);
  // Cfx requires an absolute callback URL, while an underscore resource name is invalid in a CSP host-source.
  assert.match(document, /connect-src 'self' https:/);
  assert.doesNotMatch(document, /connect-src[^"\n]*https:\/\/synex_ui/);
  for (const source of [protocol, transport, app]) {
    assert.doesNotMatch(source, /dangerouslySetInnerHTML/);
    assert.doesNotMatch(source, /\.innerHTML\s*=/);
    assert.doesNotMatch(source, /\beval\s*\(/);
    assert.doesNotMatch(source, /new Function\s*\(/);
  }
});

test('every required component family is exported and represented in the Design Lab', async () => {
  const [index, specimens] = await Promise.all([
    read('libraries/synex_ui/src/index.ts'),
    read('libraries/synex_ui/playground/src/specimens.tsx'),
  ]);
  for (const module of ['foundation', 'actions', 'forms', 'selection', 'navigation', 'overlays', 'menus', 'feedback', 'data', 'utilities', 'advanced/index']) {
    assert.match(index, new RegExp(`export \\* from ["']\\./${module}\\.js["']`));
  }
  for (const component of [
    'Surface', 'Stack', 'Inline', 'Grid', 'Container', 'Divider', 'ScrollArea', 'Spacer', 'AspectBox',
    'Button', 'IconButton', 'SplitButton', 'ActionRow', 'Input', 'TextArea', 'NumberInput', 'SearchInput',
    'PasswordInput', 'Checkbox', 'Radio', 'Switch', 'Slider', 'Field', 'FieldGroup', 'ValidationMessage',
    'Select', 'Combobox', 'SearchSelect', 'MultiSelect', 'SegmentedControl', 'Tabs', 'Breadcrumb',
    'Pagination', 'Stepper', 'SideNav', 'Dialog', 'AlertDialog', 'Popover', 'Drawer', 'Sheet', 'Modal',
    'Menu', 'ContextMenu', 'Dropdown', 'ActionMenu', 'Spinner', 'Skeleton', 'ProgressBar', 'ProgressRing',
    'LoadingOverlay', 'EmptyState', 'Toast', 'Table', 'DataList', 'KeyValueList', 'Badge', 'StatusBadge',
    'Stat', 'Metric', 'Avatar', 'ListItem', 'Tooltip', 'KeyHint', 'Shortcut', 'SynexIcon', 'VisuallyHidden',
    'CommandPalette', 'VirtualList', 'VirtualGrid', 'SearchList', 'Tree', 'DataGrid', 'ReorderList',
  ]) assert.match(specimens, new RegExp(`<${component}(?:\\s|>)`), `${component} is absent from Design Lab`);
});

test('tracked runtime and package build artifacts exist after the build gate', async () => {
  for (const relative of [
    'libraries/synex_ui/dist/index.js',
    'libraries/synex_ui/dist/index.d.ts',
    'libraries/synex_ui/dist/styles.css',
  ]) assert.equal((await stat(path.join(root, relative))).isFile(), true);
});
