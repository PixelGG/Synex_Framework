import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import test from 'node:test';

const root = process.cwd();

async function source(relativePath: string): Promise<string> {
  return readFile(path.join(root, relativePath), 'utf8');
}

async function webModule<T>(relativePath: string): Promise<T> {
  return import(pathToFileURL(path.join(root, relativePath)).href) as Promise<T>;
}

test('Control browser protocol rejects malformed, cyclic, oversized, and unknown-presentation data', async () => {
  const protocol = await webModule<{
    LOOKUP_IDENTIFIER: RegExp;
    MAX_RESPONSE_BYTES: number;
    normalizeViewInput: (value: unknown, operation: string) => { fields: unknown[] } | null;
    normalizeProviders: (value: unknown) => Array<{
      namespace: string;
      views: Array<{
        primitive: string;
        input?: { fields: Array<{ format: string }> } | null;
        search?: { kinds: Array<{ id: string; modes: string[]; authorized: boolean }> } | null;
      }>;
    }>;
    validateMessage: (value: unknown) => unknown;
  }>('resources/synex_control/web/core/protocol.js');

  assert.equal(protocol.validateMessage({
    type: 'control:response', version: 1,
    response: { requestId: 'request-valid-01', ok: true, data: { status: 'HEALTHY' } },
  }) !== null, true);
  assert.equal(protocol.validateMessage({
    type: 'control:response', version: 2,
    response: { requestId: 'request-valid-01', ok: true, data: {} },
  }), null);
  assert.equal(protocol.validateMessage({
    type: 'control:response', version: 1,
    response: { requestId: 'short', ok: true, data: {} },
  }), null);
  assert.deepEqual(protocol.validateMessage({
    type: 'control:invalidate', version: 1,
    payload: {
      reason: 'RESOURCE_STATE_CHANGED', resource: 'synex_entities', state: 'stopped',
    },
  }), {
    type: 'control:invalidate',
    payload: {
      reason: 'RESOURCE_STATE_CHANGED', resource: 'synex_entities', state: 'stopped',
    },
  });
  assert.equal(protocol.validateMessage({
    type: 'control:invalidate', version: 1,
    payload: {
      reason: 'RESOURCE_STATE_CHANGED', resource: '../entities', state: 'stopped',
    },
  }), null);
  assert.equal(protocol.validateMessage({
    type: 'control:response', version: 1,
    response: {
      requestId: 'request-oversized-01', ok: true,
      data: { value: 'x'.repeat(protocol.MAX_RESPONSE_BYTES) },
    },
  }), null);
  const cyclic: Record<string, unknown> = {};
  cyclic.self = cyclic;
  assert.equal(protocol.validateMessage({
    type: 'control:response', version: 1,
    response: { requestId: 'request-cyclic-01', ok: true, data: cyclic },
  }), null);

  const providers = protocol.normalizeProviders([{
    namespace: 'entities', label: 'Entities', resource: 'synex_entities',
    version: '1.0.0', health: 'HEALTHY', operations: ['list'],
    views: [{
      id: 'entities', label: 'Entities', operation: 'list', presentation: 'provider-html',
      accessClass: 'general',
    }],
  }]);
  assert.equal(providers.length, 1);
  assert.equal(providers[0]?.namespace, 'entities');
  assert.equal(providers[0]?.views[0]?.primitive, 'key-value');
  const searchable = protocol.normalizeProviders([{
    namespace: 'future_provider', label: 'Future', resource: 'synex_future',
    version: '1.0.0', health: 'HEALTHY', operations: ['search'],
    views: [{
      id: 'lookup', label: 'Lookup', operation: 'search', presentation: 'table',
      accessClass: 'general', search: {
        kinds: [{ id: 'future_kind', modes: ['exact'], accessClass: 'general', authorized: true }],
      },
    }],
  }]);
  assert.equal(searchable[0]?.views[0]?.search?.kinds[0]?.id, 'future_kind');
  assert.deepEqual(searchable[0]?.views[0]?.search?.kinds[0]?.modes, ['exact']);
  assert.equal(protocol.LOOKUP_IDENTIFIER.test('synex.service@1'), true);
  assert.equal(protocol.LOOKUP_IDENTIFIER.test('synex.capability.*'), true);
  assert.equal(protocol.normalizeViewInput({ fields: [{
    key: 'id', label: 'Contract name', source: 'id', type: 'string', format: 'lookup',
    required: true, minLength: 1, maxLength: 128,
  }] }, 'inspect')?.fields.length, 1);
  assert.equal(protocol.normalizeViewInput({ fields: [{
    key: 'id', label: 'Unsafe', source: 'id', type: 'string', format: 'lookup', required: false,
  }] }, 'inspect'), null);
});

test('Control store correlates responses, rejects stale results, tracks cursors, and purges state on close', async () => {
  const cleared: unknown[] = [];
  const previousWindow = Object.getOwnPropertyDescriptor(globalThis, 'window');
  Object.defineProperty(globalThis, 'window', {
    configurable: true,
    value: { clearTimeout: (identifier: unknown) => cleared.push(identifier) },
  });
  try {
    const storeModule = await webModule<{
      createControlStore: () => {
        begin: (request: Record<string, unknown>, route: Record<string, string>, timeout: number) => void;
        close: (reason?: string) => void;
        hasPrevious: (route: Record<string, string>) => boolean;
        navigate: (route: Record<string, string>) => void;
        open: () => void;
        popCursor: (route: Record<string, string>) => string | null | undefined;
        pushCursor: (route: Record<string, string>, cursor: string | null) => void;
        resolve: (response: Record<string, unknown>) => { accepted: boolean; reason?: string };
        snapshot: () => {
          activeView: { data?: unknown; status: string } | null;
          lifecycle: string;
          providers: unknown[];
          staleResponses: number;
        };
      };
    }>('resources/synex_control/web/store/control-store.js');
    const store = storeModule.createControlStore();
    const route = { kind: 'view', provider: 'entities', view: 'entities' };
    store.open();
    store.navigate(route);
    store.begin({ requestId: 'request-page-old', operation: 'page' }, route, 1);
    store.begin({ requestId: 'request-page-new', operation: 'page' }, route, 2);

    const stale = store.resolve({
      requestId: 'request-page-old', ok: true, data: { value: { private: 'old' } },
    });
    assert.deepEqual(stale, { accepted: false, reason: 'STALE_RESPONSE' });
    assert.equal(store.snapshot().staleResponses, 1);

    const current = store.resolve({
      requestId: 'request-page-new', ok: true,
      data: { primitive: 'table', value: { items: [{ entityId: 'entity_01' }] } },
    });
    assert.equal(current.accepted, true);
    assert.equal(store.snapshot().activeView?.status, 'ready');

    store.pushCursor(route, null);
    store.pushCursor(route, 'entity_01');
    assert.equal(store.hasPrevious(route), true);
    assert.equal(store.popCursor(route), 'entity_01');
    assert.equal(store.popCursor(route), null);

    store.begin({ requestId: 'request-pending-close', operation: 'page' }, route, 3);
    store.close('access_revoked');
    const snapshot = store.snapshot();
    assert.equal(snapshot.lifecycle, 'revoked');
    assert.equal(snapshot.activeView, null);
    assert.deepEqual(snapshot.providers, []);
    assert.ok(cleared.includes(1) && cleared.includes(2) && cleared.includes(3));
  } finally {
    if (previousWindow) Object.defineProperty(globalThis, 'window', previousWindow);
    else delete (globalThis as unknown as { window?: unknown }).window;
  }
});

test('Control render projections flatten bounded Core metrics, tables, and timelines safely', async () => {
  const renderers = await webModule<{
    projectDetail: (value: unknown) => Array<{ label: string; value: unknown }>;
    projectFindings: (value: unknown) => Array<{
      metadata: string; severity: string; summary: string; title: string;
    }>;
    projectMetrics: (value: unknown) => Array<{
      detail?: string;
      label: string;
      severity?: string;
      value: unknown;
    }>;
    projectTable: (value: unknown) => {
      columns: Array<{ key: string; label: string }>;
      items: Array<Record<string, unknown>>;
    };
    projectTimeline: (value: unknown) => Array<{
      detail: string;
      label: string;
      severity?: string;
      status: string;
      timestamp: string;
    }>;
  }>('resources/synex_control/web/components/renderers.js');

  const detail = renderers.projectDetail({
    resource: 'synex_core',
    health: { state: 'HEALTHY', workers: { active: 4 } },
    manifest: { version: '1.0.0', dependencies: ['oxmysql'] },
  });
  assert.ok(detail.some((item) => item.label.includes('Health')
    && item.label.includes('State') && item.value === 'HEALTHY'));
  assert.ok(detail.some((item) => item.label.includes('Manifest')
    && item.label.includes('Dependencies') && item.value === 'oxmysql'));
  assert.doesNotMatch(JSON.stringify(detail), /\[STRUCTURED DATA\]/u);
  const findings = renderers.projectFindings({ items: [
    { severity: 'WARNING', resource: 'synex_core', capability: 'synex.runtime.read', reason: 'denied' },
    { severity: 'DEGRADED', code: 'PROVIDER_TIMEOUTS_OBSERVED', count: 3 },
  ] });
  assert.equal(findings[0]?.title, 'synex.runtime.read');
  assert.equal(findings[0]?.summary, 'denied');
  assert.match(findings[0]?.metadata || '', /Resource: synex_core.*Capability: synex\.runtime\.read/u);
  assert.equal(findings[1]?.title, 'PROVIDER_TIMEOUTS_OBSERVED');
  assert.match(findings[1]?.metadata || '', /Count: 3/u);

  const metrics = renderers.projectMetrics({
    status: 'HEALTHY',
    counters: { providers: 4, failures: 1 },
    provider: { duration: { maximumMs: 27 } },
    beyond: { first: { second: { third: { ignored: 99 } } } },
  });
  assert.ok(metrics.some((item) => item.label === 'Status'
    && item.value === 'HEALTHY' && item.severity === 'HEALTHY'));
  assert.ok(metrics.some((item) => item.label === 'Counters · Providers' && item.value === 4));
  assert.ok(metrics.some((item) => item.label === 'Provider · Duration · Maximum Ms'
    && item.value === 27));
  assert.equal(metrics.some((item) => item.label.includes('Ignored')), false);
  assert.doesNotMatch(JSON.stringify(metrics), /\[STRUCTURED DATA\]/u);
  const histogramMetrics = renderers.projectMetrics({
    metrics: {
      histograms: { providerDurationMaximumMs: { count: 2, maximum: 27 } },
    },
  });
  assert.ok(histogramMetrics.some((item) => item.label
    === 'Histograms · Provider Duration Maximum Ms · Maximum' && item.value === 27));

  const manyMetrics = Object.fromEntries(Array.from(
    { length: 80 }, (_, index) => [`counter_${String(index).padStart(2, '0')}`, index],
  ));
  assert.equal(renderers.projectMetrics(manyMetrics).length, 48);

  const wideRows = Array.from({ length: 140 }, (_, row) => Object.fromEntries(Array.from(
    { length: 15 }, (_, column) => [`column_${String(column).padStart(2, '0')}`, row + column],
  )));
  const itemTable = renderers.projectTable({ items: wideRows });
  assert.equal(itemTable.items.length, 100);
  assert.equal(itemTable.columns.length, 12);

  const snapshotTable = renderers.projectTable({
    snapshot: { resources: [{ resource: 'synex_core', applied: 27 }] },
  });
  assert.deepEqual(snapshotTable.items, [{ applied: 27, resource: 'synex_core' }]);
  const summaryTable = renderers.projectTable({
    summary: { activeSessions: 3, states: { ACTIVE: 2, AUTHENTICATED: 1 } },
  });
  assert.equal(summaryTable.items.length, 2);
  assert.ok(summaryTable.items.some((row) => row.field === 'Active Sessions' && row.value === '3'));
  assert.ok(summaryTable.items.some((row) => row.field === 'States'
    && typeof row.value === 'string' && row.value.includes('ACTIVE')));
  const cacheTable = renderers.projectTable({ cache: { entries: 4, maximum: 128 } });
  assert.equal(cacheTable.items.length, 2);
  const deprecationTable = renderers.projectTable({
    deprecations: [{ name: 'legacy.call', uses: 2 }],
  });
  assert.deepEqual(deprecationTable.items, [{ name: 'legacy.call', uses: 2 }]);
  const genericTable = renderers.projectTable({
    state: 'READY', counters: { healthy: 4, stale: 1 },
  });
  assert.equal(genericTable.items.length, 2);
  assert.doesNotMatch(JSON.stringify(genericTable), /\[STRUCTURED DATA\]/u);

  const timeline = renderers.projectTimeline({ items: [{
    occurredAt: '2026-08-26T12:00:00Z',
    action: 'resource.started',
    traceId: 'trace-fixture-01',
    actor: { type: 'resource', reference: 'synex_core' },
    target: { type: 'resource', reference: 'synex_control' },
    status: 'HEALTHY',
  }] });
  assert.equal(timeline[0]?.timestamp, '2026-08-26T12:00:00Z');
  assert.equal(timeline[0]?.label, 'resource.started');
  assert.match(timeline[0]?.detail ?? '', /Trace: trace-fixture-01/u);
  assert.match(timeline[0]?.detail ?? '', /Actor:/u);
  assert.match(timeline[0]?.detail ?? '', /Target:/u);
  const traceTimeline = renderers.projectTimeline({ items: [{
    timestamp: '2026-08-26T12:01:00Z',
    traceId: 'trace-runtime-01', spanId: 'span-parent',
    parentSpanId: 'span-root', childSpanIds: ['span-child-a', 'span-child-b'],
    resource: 'synex_accounts', operation: 'accounts.inspect',
    durationMs: 327, status: 'ERROR', errorCode: 'DATABASE_ERROR',
  }] });
  assert.equal(traceTimeline[0]?.label, 'accounts.inspect');
  assert.match(traceTimeline[0]?.detail ?? '', /Resource: synex_accounts/u);
  assert.match(traceTimeline[0]?.detail ?? '', /Duration: 327 ms/u);
  assert.match(traceTimeline[0]?.detail ?? '', /Parent: span-root/u);
  assert.match(traceTimeline[0]?.detail ?? '', /Children: span-child-a, span-child-b/u);
  assert.match(traceTimeline[0]?.detail ?? '', /Error: DATABASE_ERROR/u);
  const unavailable = renderers.projectTimeline({
    status: 'UNAVAILABLE', reason: 'SPAN_STORE_UNAVAILABLE',
  });
  assert.equal(unavailable.length, 1);
  assert.equal(unavailable[0]?.severity, 'UNAVAILABLE');
  assert.match(unavailable[0]?.detail ?? '', /SPAN_STORE_UNAVAILABLE/u);
  assert.equal(renderers.projectTimeline({
    items: Array.from({ length: 120 }, (_, index) => ({ action: `event.${index}` })),
  }).length, 100);
});

test('Control UI has an empty closed DOM, visible-only adaptive refresh, safe rendering, and accessible navigation', async () => {
  const [html, css, app, store, protocol, renderers] = await Promise.all([
    source('resources/synex_control/web/index.html'),
    source('resources/synex_control/web/styles.css'),
    source('resources/synex_control/web/app.js'),
    source('resources/synex_control/web/store/control-store.js'),
    source('resources/synex_control/web/core/protocol.js'),
    source('resources/synex_control/web/components/renderers.js'),
  ]);

  assert.match(html, /<div id="root"><\/div>/u);
  assert.match(css, /html,\s*body,\s*#root\s*\{[\s\S]*background:\s*transparent\s*!important/u);
  assert.match(css, /html,\s*body,\s*#root\s*\{[\s\S]*pointer-events:\s*none/u);
  assert.match(app, /root\.replaceChildren\(\)/u);
  assert.match(app, /delete document\.body\.dataset\.open/u);
  assert.match(store, /pending\.clear\(\)/u);
  assert.match(store, /views\.clear\(\)/u);
  assert.match(store, /cursorHistory\.clear\(\)/u);

  assert.match(protocol, /OVERVIEW_REFRESH_MS\s*=\s*10000/u);
  assert.match(protocol, /VIEW_REFRESH_MS\s*=\s*30000/u);
  assert.match(app, /snapshot\.lifecycle !== 'open' \|\| document\.hidden/u);
  assert.match(app, /snapshot\.activeView\?\.cursor\) return/u);
  assert.match(app, /visibilitychange/u);
  assert.match(app, /route\.kind === 'simulate'\) return 'simulate'/u);
  assert.match(app, /operation === 'inspect' \|\| operation === 'search' \|\| operation === 'simulate'/u);
  assert.match(app, /view\.operation === 'simulate' \? 'simulate' : 'provider'/u);
  assert.doesNotMatch(`${app}\n${store}`, /setInterval/u);

  assert.match(app, /pushCursor/u);
  assert.match(app, /popCursor/u);
  assert.match(app, /snapshot\.activeRoute\.kind === 'inspect'\) return null/u);
  assert.match(app, /snapshot\.activeRoute\.kind === 'search' \? 'search' : 'page'/u);
  assert.doesNotMatch(app, /snapshot\.activeRoute\.kind === 'inspect' \? 'inspect'/u);
  assert.match(app, /requestData\(snapshot\.activeRoute, \{\s*operation,\s*cursor/u);
  assert.match(app, /query:\s*\{\s*kind:\s*choice\.kind,\s*value,\s*mode:\s*mode\.value\s*\}/u);
  assert.match(app, /route\.provider && operation !== 'overview' && operation !== 'providers'[\s\S]*\{ provider: route\.provider \}/u);
  assert.match(app, /route\.view && operation !== 'overview' && operation !== 'providers'[\s\S]*\{ view: route\.view \}/u);
  assert.match(app, /snapshot\.providers\.filter/u);
  assert.match(app, /provider\.views/u);
  assert.match(app, /message\.type === 'control:invalidate'/u);
  assert.match(app, /refreshProviderCatalog\(\)/u);
  assert.match(app, /refreshActive\(\)/u);
  assert.match(app, /view\?\.input\?\.fields/u);
  assert.match(app, /buildInputForm/u);
  assert.doesNotMatch(app, /groups:relationship|groups:capability|entities:bucket|policy_simulation/u);

  for (const primitive of [
    'metrics', 'key-value', 'table', 'detail', 'timeline', 'graph', 'findings',
  ]) assert.ok(protocol.includes(`'${primitive}'`), primitive);
  assert.match(renderers, /textContent/u);
  assert.doesNotMatch(`${app}\n${renderers}`, /innerHTML|outerHTML|insertAdjacentHTML|eval\s*\(/u);
  assert.doesNotMatch(css, /backdrop-filter/u);

  assert.match(app, /aria-current/u);
  assert.match(app, /aria-selected/u);
  assert.match(app, /setAttribute\('role', 'search'\)/u);
  assert.match(css, /:focus-visible/u);
  assert.match(css, /prefers-reduced-motion/u);
  assert.match(css, /@media \(max-width:\s*600px\)/u);
});
