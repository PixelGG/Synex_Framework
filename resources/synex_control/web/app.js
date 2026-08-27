import {
  OVERVIEW_REFRESH_MS,
  LOOKUP_IDENTIFIER,
  PROTOCOL_VERSION,
  REQUEST_TIMEOUT_MS,
  VIEW_REFRESH_MS,
  createRequestId,
  validateMessage,
} from './core/protocol.js';
import { action, element, renderPrimitive, severityBadge } from './components/renderers.js';
import { createControlStore } from './store/control-store.js';
import { callbackCode, postNui } from './transport/nui.js';

const root = document.getElementById('root');
const resourceName = GetParentResourceName();
const messageOrigins = new Set([
  window.location.origin,
  'https://nui-game-internal',
  `https://cfx-nui-${resourceName}`,
]);

const TITLES = {
  overview: 'Overview', runtime: 'Runtime', resources: 'Resources', dependencies: 'Dependencies',
  contracts: 'Contracts', capabilities: 'Capabilities', rpc: 'RPC & Services', hooks: 'Hooks',
  database: 'Database', migrations: 'Migrations', sessions: 'Sessions', characters: 'Characters',
  groups: 'Groups', accounts: 'Accounts', ledger: 'Ledger', transactions: 'Transactions',
  holds: 'Holds', access: 'Access', integrity: 'Integrity', reconciliation: 'Reconciliation',
  anomalies: 'Anomalies', economy: 'Economy', outbox: 'Outbox', entities: 'Entities', audit: 'Audit',
  tracing: 'Tracing', investigation: 'Investigation', performance: 'Performance',
  security: 'Security', compatibility: 'Compatibility', services: 'Services',
  persistent: 'Persistent', bindings: 'Bindings', owners: 'Owners', buckets: 'Buckets',
  drift: 'Drift', components: 'Components', state: 'State', quotas: 'Quotas', health: 'Health',
  recovery: 'Recovery inspector',
};

const CORE_GROUPS = [
  {
    label: 'Platform',
    views: ['runtime', 'resources', 'dependencies', 'contracts', 'capabilities', 'rpc', 'hooks', 'services'],
  },
  {
    label: 'Operations',
    views: ['database', 'migrations', 'sessions', 'characters'],
  },
  {
    label: 'Observability',
    views: ['tracing', 'audit', 'performance', 'security', 'compatibility'],
  },
];

const ERROR_COPY = {
  ACCESS_DENIED: 'Access to this diagnostic surface was denied.',
  ACCESS_REVOKED: 'Your diagnostic permission was revoked.',
  CLOSED: 'Synex Control is closed.',
  CORE_UNAVAILABLE: 'Synex Core is currently unavailable.',
  INVALID_ARGUMENT: 'The diagnostic request contains an invalid value.',
  INVALID_CURSOR: 'The cursor is invalid or stale. Return to the first page.',
  INVALID_LIMIT: 'The requested page size is outside the supported boundary.',
  INVALID_PROVIDER: 'The selected search type does not belong to that provider.',
  INVALID_REQUEST: 'The diagnostic request is invalid.',
  NOT_EXPOSED: 'The running provider does not expose this read model.',
  NOT_FOUND: 'No matching diagnostic object was found.',
  PAYLOAD_LIMIT: 'The provider response exceeded the safe payload boundary.',
  PAYLOAD_TOO_LARGE: 'The provider response exceeded the safe payload boundary.',
  PROVIDER_INVALID: 'The provider returned an invalid diagnostic response.',
  PROVIDER_BUSY: 'The provider is already serving a bounded diagnostic request.',
  PROVIDER_RESTARTED: 'The provider restarted while the request was in flight.',
  PROVIDER_RESPONSE_INVALID: 'The provider returned an invalid diagnostic response.',
  PROVIDER_UNAVAILABLE: 'The diagnostic provider is currently unavailable.',
  PROVIDER_TIMEOUT: 'The provider did not answer within its diagnostic deadline.',
  RATE_LIMITED: 'The request rate is temporarily limited.',
  REQUEST_TOO_LARGE: 'The diagnostic request exceeded the safe transport boundary.',
  STALE_ENTITY: 'The requested entity generation is no longer current.',
  TIMEOUT: 'The diagnostic request timed out.',
  UNAVAILABLE: 'No verified diagnostic data is currently available.',
  VIEW_UNAVAILABLE: 'The requested diagnostic view is currently unavailable.',
};

const store = createControlStore();
let snapshot = store.snapshot();
let refreshTimer = null;
let focusFrame = null;

function errorCopy(code) {
  return ERROR_COPY[code] || ERROR_COPY.UNAVAILABLE;
}

function stopRefresh() {
  if (refreshTimer !== null) window.clearTimeout(refreshTimer);
  refreshTimer = null;
}

function reportError(code, view) {
  postNui('reportError', { code, view }).catch(() => {});
}

function routeOperation(route) {
  if (route.kind === 'overview') return 'overview';
  if (route.kind === 'search') return 'search';
  if (route.kind === 'inspect') return 'inspect';
  if (route.kind === 'simulate') return 'simulate';
  return 'section';
}

async function requestData(route, options = {}) {
  if (snapshot.lifecycle !== 'open' || document.hidden) return;
  const operation = options.operation || routeOperation(route);
  const requestId = createRequestId();
  const request = {
    requestId,
    operation,
    ...(route.provider && operation !== 'overview' && operation !== 'providers'
      ? { provider: route.provider }
      : {}),
    ...(route.view && operation !== 'overview' && operation !== 'providers'
      ? { view: route.view }
      : {}),
    ...(route.id ? { id: route.id } : {}),
    ...(options.cursor ? { cursor: options.cursor } : {}),
    limit: options.limit || 25,
    ...(options.filters || route.filters ? { filters: options.filters || route.filters } : {}),
    ...(options.sort ? { sort: options.sort } : {}),
    ...(route.query ? { query: route.query } : {}),
  };
  if (operation === 'overview') delete request.limit;

  const timeoutId = window.setTimeout(() => {
    store.rejectLocal(requestId, 'TIMEOUT');
    reportError('REQUEST_TIMEOUT', operation);
  }, REQUEST_TIMEOUT_MS);
  store.begin(request, route, timeoutId);
  const response = await postNui('request', request);
  const error = callbackCode(response);
  if (error) store.rejectLocal(requestId, error);
}

function refreshActive() {
  if (snapshot.lifecycle !== 'open' || document.hidden) return;
  if (snapshot.activeView?.status === 'loading' || snapshot.activeView?.status === 'refreshing') return;
  if (snapshot.activeView?.cursor) return;
  requestData(snapshot.activeRoute, { operation: routeOperation(snapshot.activeRoute) });
}

function refreshProviderCatalog() {
  requestData({ kind: 'catalog', provider: 'core', view: 'providers' }, {
    operation: 'providers',
    limit: 12,
  });
}

function scheduleRefresh() {
  stopRefresh();
  if (snapshot.lifecycle !== 'open' || document.hidden) return;
  const operation = routeOperation(snapshot.activeRoute);
  if (operation === 'inspect' || operation === 'search' || operation === 'simulate') return;
  const delay = snapshot.activeRoute.kind === 'overview' ? OVERVIEW_REFRESH_MS : VIEW_REFRESH_MS;
  refreshTimer = window.setTimeout(() => {
    refreshTimer = null;
    refreshActive();
    scheduleRefresh();
  }, delay);
}

function passiveRoute(route) {
  return route.kind === 'input-form' || route.kind === 'search-form';
}

function navigate(route) {
  store.navigate(route);
  store.resetCursor(route);
  if (passiveRoute(route)) {
    stopRefresh();
    return;
  }
  requestData(route);
  scheduleRefresh();
}

function providerViewRoute(provider, view) {
  const kind = view?.operation === 'search' ? 'search-form'
    : Array.isArray(view?.input?.fields) && view.input.fields.length > 0 ? 'input-form'
        : provider.namespace === 'core' ? 'section' : 'provider';
  return { kind, provider: provider.namespace, view: view?.id || 'overview' };
}

function requestClose() {
  postNui('close', {}).catch(() => {});
}

function searchChoices() {
  const choices = [];
  for (const provider of snapshot.providers) {
    if (!provider.authorized) continue;
    for (const view of provider.views) {
      if (!view.authorized || view.operation !== 'search' || !Array.isArray(view.search?.kinds)) continue;
      for (const kind of view.search.kinds) {
        if (kind.authorized === false || !Array.isArray(kind.modes) || kind.modes.length === 0) continue;
        choices.push({ provider: provider.namespace, view: view.id, kind: kind.id, modes: kind.modes });
      }
    }
  }
  return choices.sort((left, right) => left.kind.localeCompare(right.kind)
    || left.provider.localeCompare(right.provider));
}

function buildGlobalSearch() {
  const form = element('form', 'global-search');
  form.setAttribute('role', 'search');
  const choices = searchChoices();
  const kindLabel = element('label', 'sr-only', 'Search type');
  kindLabel.htmlFor = 'control-search-kind';
  const kind = element('select', 'field search-kind');
  kind.id = 'control-search-kind';
  kind.dataset.focusKey = 'global-search-kind';
  for (const [index, choice] of choices.entries()) {
    const option = element('option', null, `${choice.kind} / ${choice.provider}`);
    option.value = String(index);
    kind.append(option);
  }
  if (choices.length === 0) {
    const option = element('option', null, 'Search metadata unavailable');
    option.value = '';
    kind.append(option);
    kind.disabled = true;
  } else if (snapshot.activeRoute.kind === 'search-form' || snapshot.activeRoute.kind === 'search') {
    const preferred = choices.findIndex((choice) => choice.provider === snapshot.activeRoute.provider
      && choice.view === snapshot.activeRoute.view);
    if (preferred >= 0) kind.value = String(preferred);
  }
  const modeLabel = element('label', 'sr-only', 'Search matching mode');
  modeLabel.htmlFor = 'control-search-mode';
  const mode = element('select', 'field search-mode');
  mode.id = 'control-search-mode';
  mode.dataset.focusKey = 'global-search-mode';
  const populateModes = () => {
    const previous = mode.value;
    mode.replaceChildren();
    const choice = choices[Number(kind.value)];
    for (const value of choice?.modes || []) {
      const option = element('option', null, value === 'exact' ? 'Exact' : 'Prefix');
      option.value = value;
      mode.append(option);
    }
    if ([...mode.options].some((option) => option.value === previous)) mode.value = previous;
    mode.disabled = mode.options.length < 2;
  };
  kind.addEventListener('change', populateModes);
  populateModes();
  if (snapshot.activeRoute.kind === 'search'
    && choices[Number(kind.value)]?.modes.includes(snapshot.activeRoute.query?.mode)) {
    mode.value = snapshot.activeRoute.query.mode;
  }
  const queryLabel = element('label', 'sr-only', 'Exact Synex identifier or resource name');
  queryLabel.htmlFor = 'control-search-query';
  const query = element('input', 'field search-query');
  query.id = 'control-search-query';
  query.dataset.focusKey = 'global-search-query';
  query.type = 'search';
  query.minLength = 1;
  query.maxLength = 128;
  query.autocomplete = 'off';
  query.spellcheck = false;
  query.placeholder = 'Search Synex by exact ID or prefix';
  if (snapshot.activeRoute.kind === 'search') query.value = snapshot.activeRoute.query?.value || '';
  const submit = action('Search', 'action action-primary', () => {});
  submit.type = 'submit';
  submit.disabled = choices.length === 0;
  form.addEventListener('submit', (event) => {
    event.preventDefault();
    const choice = choices[Number(kind.value)];
    if (!choice || !choice.modes.includes(mode.value)) return;
    const value = query.value.trim();
    query.minLength = mode.value === 'prefix' ? 2 : 1;
    if (!query.reportValidity() || !LOOKUP_IDENTIFIER.test(value)) return;
    navigate({
      kind: 'search',
      provider: choice.provider,
      view: choice.view,
      query: { kind: choice.kind, value, mode: mode.value },
    });
  });
  form.append(kindLabel, kind, modeLabel, mode, queryLabel, query, submit);
  return form;
}

function navButton(label, route, active, health, disabled = false) {
  const button = action(label, active ? 'nav-item active' : 'nav-item', () => navigate(route));
  button.dataset.focusKey = `nav-${route.provider}-${route.view}`;
  if (active) button.setAttribute('aria-current', 'page');
  const marker = element('span', `nav-marker nav-marker-${String(health || 'INFO').toLowerCase()}`);
  marker.setAttribute('aria-hidden', 'true');
  button.prepend(marker);
  button.disabled = disabled;
  if (disabled) button.title = 'Additional diagnostic permission required';
  return button;
}

function sameRoute(left, right) {
  return left.kind === right.kind && left.provider === right.provider && left.view === right.view;
}

function buildSidebar() {
  const sidebar = element('aside', 'sidebar');
  const brand = element('div', 'brand');
  const mark = element('span', 'brand-mark', 'S');
  mark.setAttribute('aria-hidden', 'true');
  const text = element('div');
  text.append(element('h1', null, 'Synex Control'), element('p', null, 'Read-only diagnostics'));
  brand.append(mark, text);

  const navigation = element('nav', 'navigation');
  navigation.setAttribute('aria-label', 'Control plane sections');
  const overview = { kind: 'overview', provider: 'core', view: 'overview' };
  navigation.append(navButton('Overview', overview, sameRoute(snapshot.activeRoute, overview), 'INFO'));

  const coreProvider = snapshot.providers.find((provider) => provider.namespace === 'core');
  for (const group of CORE_GROUPS) {
    const section = element('section', 'nav-group');
    section.append(element('h2', 'nav-heading', group.label));
    for (const view of group.views) {
      const metadata = coreProvider?.views.find((candidate) => candidate.id === view);
      const route = metadata ? providerViewRoute(coreProvider, metadata)
        : { kind: 'section', provider: 'core', view };
      section.append(navButton(
        TITLES[view] || view,
        route,
        sameRoute(snapshot.activeRoute, route),
        coreProvider?.health || 'INFO',
        metadata?.authorized === false,
      ));
    }
    navigation.append(section);
  }

  if (snapshot.providers.length > 0) {
    const section = element('section', 'nav-group');
    section.append(element('h2', 'nav-heading', 'Providers'));
    for (const provider of snapshot.providers.filter((candidate) => candidate.namespace !== 'core')) {
      const defaultView = provider.views.find((candidate) => candidate.authorized
        && !['inspect', 'search', 'simulate'].includes(candidate.operation))
        || provider.views.find((candidate) => candidate.authorized)
        || provider.views[0];
      const route = providerViewRoute(provider, defaultView);
      section.append(navButton(
        provider.authorized ? provider.label : `${provider.label} · Restricted`,
        route,
        sameRoute(snapshot.activeRoute, route),
        provider.health,
        !provider.authorized || !provider.views.some((candidate) => candidate.authorized),
      ));
    }
    navigation.append(section);
  }

  sidebar.append(brand, navigation);
  return sidebar;
}

function activeProvider() {
  return snapshot.providers.find((provider) => provider.namespace === snapshot.activeRoute.provider) || null;
}

function buildViewTabs(provider) {
  if (!provider || provider.views.length < 2) return null;
  const tabs = element('div', 'view-tabs');
  tabs.setAttribute('role', 'tablist');
  tabs.setAttribute('aria-label', `${provider.label} diagnostic views`);
  for (const view of provider.views) {
    const selected = snapshot.activeRoute.view === view.id;
    const tab = action(view.label, selected ? 'view-tab active' : 'view-tab', () => {
      navigate(providerViewRoute(provider, view));
    });
    tab.setAttribute('role', 'tab');
    tab.setAttribute('aria-selected', String(selected));
    tab.disabled = !view.authorized;
    tabs.append(tab);
  }
  return tabs;
}

const INPUT_PATTERNS = {
  identifier: /^[A-Za-z0-9][A-Za-z0-9_.:%-]*$/u,
  lookup: LOOKUP_IDENTIFIER,
  uuid: /^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$/u,
  resource: /^[a-z][a-z0-9_.-]*$/u,
  capability: /^[a-z][a-z0-9._*-]*$/u,
  action: /^[a-z][a-z0-9._-]*$/u,
  integer: /^-?[0-9]+$/u,
  'numeric-string': /^[0-9]+$/u,
  boolean: /^(?:true|false)$/u,
  text: /^[^\u0000-\u001F\u007F]*$/u,
};

function readInputField(definition, field) {
  field.setCustomValidity('');
  if (definition.type === 'boolean') {
    return { present: definition.required || field.checked, value: field.checked };
  }
  const raw = field.value.trim();
  if (!raw) {
    if (definition.required) field.setCustomValidity('This field is required.');
    return { present: false, value: null };
  }
  if (definition.type === 'integer') {
    const value = Number(raw);
    if (!INPUT_PATTERNS.integer.test(raw) || !Number.isSafeInteger(value)
      || definition.minimum !== undefined && value < definition.minimum
      || definition.maximum !== undefined && value > definition.maximum) {
      field.setCustomValidity('Enter an integer within the declared boundary.');
      return { present: false, value: null };
    }
    return { present: true, value };
  }
  const pattern = INPUT_PATTERNS[definition.format];
  if (definition.minLength !== undefined && raw.length < definition.minLength
    || definition.maxLength !== undefined && raw.length > definition.maxLength
    || pattern && !pattern.test(raw)) {
    field.setCustomValidity('Enter a value matching the declared diagnostic format.');
    return { present: false, value: null };
  }
  return { present: true, value: raw };
}

function buildInputForm(provider) {
  const view = provider?.views.find((candidate) => candidate.id === snapshot.activeRoute.view);
  const definitions = view?.input?.fields;
  if (!provider || !provider.authorized || view?.authorized === false
    || !Array.isArray(definitions) || definitions.length < 1) return null;
  const form = element('form', definitions.length > 1
    ? 'inspector-form multi-inspector-form' : 'inspector-form');
  const fields = new Map();
  for (const definition of definitions) {
    const label = element('label', null, definition.label);
    const field = element('input', 'field');
    field.name = definition.key;
    field.required = definition.required;
    field.type = definition.type === 'boolean' ? 'checkbox' : 'text';
    field.autocomplete = 'off';
    field.spellcheck = false;
    if (definition.type === 'integer') field.inputMode = 'numeric';
    if (definition.type === 'string') {
      if (definition.minLength !== undefined) field.minLength = definition.minLength;
      if (definition.maxLength !== undefined) field.maxLength = definition.maxLength;
      const pattern = INPUT_PATTERNS[definition.format];
      if (pattern) field.pattern = pattern.source;
    }
    const current = definition.source === 'id'
      ? snapshot.activeRoute.id
      : snapshot.activeRoute.filters?.[definition.key];
    if (definition.type === 'boolean') field.checked = current === true;
    else field.value = current ?? '';
    label.append(field);
    fields.set(definition.key, { definition, field });
    form.append(label);
  }
  const submitLabels = { inspect: 'Inspect', simulate: 'Simulate', list: 'Apply filters' };
  const submit = action(submitLabels[view.operation] || 'Run read query', 'action action-primary', () => {});
  submit.type = 'submit';
  form.addEventListener('submit', (event) => {
    event.preventDefault();
    const filters = Object.create(null);
    let id;
    for (const { definition, field } of fields.values()) {
      const parsed = readInputField(definition, field);
      if (!parsed.present) continue;
      if (definition.source === 'id') id = parsed.value;
      else filters[definition.key] = parsed.value;
    }
    if (!form.reportValidity()) return;
    navigate({
      kind: view.operation === 'inspect' ? 'inspect'
        : view.operation === 'simulate' ? 'simulate' : 'provider',
      provider: provider.namespace,
      view: view.id,
      ...(id !== undefined ? { id } : {}),
      ...(Object.keys(filters).length > 0 ? { filters } : {}),
    });
  });
  form.append(submit);
  return form;
}

function renderOverview(container, view) {
  const data = view?.data && typeof view.data === 'object' ? view.data : {};
  const core = data.summaries?.core && typeof data.summaries.core === 'object'
    ? data.summaries.core
    : {};
  const counts = data.severityCounts && typeof data.severityCounts === 'object'
    ? data.severityCounts
    : {};
  const sampling = data.sampling && typeof data.sampling === 'object' ? data.sampling : {};
  const metrics = {
    items: [
      {
        label: 'Runtime',
        value: core.runtime?.state || core.status || 'UNAVAILABLE',
        severity: core.status || 'UNAVAILABLE',
      },
      {
        label: 'Admission',
        value: typeof core.runtime?.playerAdmission === 'boolean'
          ? core.runtime.playerAdmission ? 'OPEN' : 'CLOSED'
          : 'UNAVAILABLE',
      },
      { label: 'Providers', value: sampling.providers ?? snapshot.providers.length },
      { label: 'Sampled', value: sampling.sampled ?? 0 },
      { label: 'Warnings', value: (counts.WARNING || 0) + (counts.DEGRADED || 0) },
      { label: 'Critical', value: (counts.CRITICAL || 0) + (counts.ERROR || 0) },
    ],
  };
  container.append(renderPrimitive('metrics', metrics));
  if (snapshot.providers.length > 0) {
    container.append(element('h3', 'subheading', 'Foundation and providers'));
    const providerGrid = element('div', 'provider-grid');
    for (const provider of snapshot.providers) {
      const card = element('article', 'provider-card');
      card.append(
        element('strong', null, provider.label),
        element('span', 'provider-resource', provider.resource),
        severityBadge(provider.authorized ? provider.health : 'UNAVAILABLE'),
      );
      const summary = data.summaries?.[provider.namespace];
      if (summary && typeof summary === 'object') {
        const summaryStatus = summary.status || summary.health || summary.state;
        if (typeof summaryStatus === 'string') card.append(element('span', 'provider-summary', summaryStatus));
      }
      if (provider.metrics && Number.isFinite(provider.metrics.calls)) {
        card.append(element('span', 'provider-summary',
          `${provider.metrics.calls} calls · ${provider.metrics.maximumDurationMs || 0} ms max`));
      }
      providerGrid.append(card);
    }
    container.append(providerGrid);
  }
  if (data.attention) {
    container.append(
      element('h3', 'subheading', 'Attention'),
      renderPrimitive('findings', { items: Array.isArray(data.attention) ? data.attention : [] }),
    );
  }
}

function renderState(container, view) {
  if (!view || view.status === 'loading') {
    const state = element('div', 'state-card loading-state');
    state.setAttribute('role', 'status');
    state.append(element('span', 'loading-indicator'), element('strong', null, 'Loading diagnostics'));
    container.append(state);
    return false;
  }
  if (view.status === 'timeout' || view.status === 'unavailable' || view.status === 'error') {
    const state = element('div', 'state-card error-state');
    state.setAttribute('role', 'alert');
    state.append(
      severityBadge(view.status === 'timeout' ? 'WARNING' : 'UNAVAILABLE'),
      element('strong', null, view.error || 'UNAVAILABLE'),
      element('p', null, errorCopy(view.error)),
      action('Retry', 'action', refreshActive),
    );
    container.append(state);
    return false;
  }
  if (view.status === 'stale') {
    const warning = element('div', 'inline-warning');
    warning.setAttribute('role', 'status');
    warning.append(severityBadge('WARNING'), document.createTextNode(errorCopy(view.error)));
    container.append(warning);
  }
  return Boolean(view.data);
}

function buildPagination(view) {
  // Inspect is an exact, single-object contract. The server rejects cursors on
  // inspect requests, so provider detail truncation must never create a broken
  // Next action in the NUI.
  if (snapshot.activeRoute.kind === 'inspect') return null;
  if (!view || (!view.hasMore && !store.hasPrevious(snapshot.activeRoute))) return null;
  const controls = element('nav', 'pagination');
  controls.setAttribute('aria-label', 'Diagnostic result pages');
  const operation = snapshot.activeRoute.kind === 'search' ? 'search' : 'page';
  const previous = action('Previous', 'action', () => {
    const cursor = store.popCursor(snapshot.activeRoute);
    if (cursor === undefined) return;
    requestData(snapshot.activeRoute, {
      operation,
      cursor,
    });
  });
  previous.disabled = !store.hasPrevious(snapshot.activeRoute);
  const next = action('Next', 'action action-primary', () => {
    if (!view.nextCursor) return;
    store.pushCursor(snapshot.activeRoute, view.cursor);
    requestData(snapshot.activeRoute, {
      operation,
      cursor: view.nextCursor,
    });
  });
  next.disabled = !view.hasMore || !view.nextCursor;
  controls.append(previous, element('span', 'pagination-state', 'Cursor pagination'), next);
  return controls;
}

function buildContent() {
  const content = element('section', 'content');
  const provider = activeProvider();
  const header = element('header', 'section-header');
  const titles = element('div');
  titles.append(
    element('p', 'eyebrow', snapshot.activeRoute.kind === 'overview' ? 'Operations snapshot' : 'Runtime observation'),
    element('h2', null, snapshot.activeRoute.kind === 'overview'
      ? 'Overview'
      : provider?.views.find((view) => view.id === snapshot.activeRoute.view)?.label
        || TITLES[snapshot.activeRoute.view]
        || snapshot.activeRoute.view),
  );
  const viewStatus = snapshot.activeView?.status === 'ready' ? 'HEALTHY'
    : snapshot.activeView?.status === 'stale' ? 'WARNING'
      : snapshot.activeView?.status === 'loading' || snapshot.activeView?.status === 'refreshing' ? 'INFO'
        : 'UNAVAILABLE';
  header.append(titles, severityBadge(viewStatus));
  content.append(header);

  const tabs = buildViewTabs(provider);
  if (tabs) content.append(tabs);
  const inputForm = buildInputForm(provider);
  if (inputForm) content.append(inputForm);
  if (provider?.namespace === 'entities') {
    const boundary = element('aside', 'boundary-note');
    boundary.setAttribute('role', 'note');
    boundary.append(
      element('strong', null, 'Network owner = transport only'),
      element('p', null, 'Observed network ownership is never Synex authorization; bounded stored values stay private.'),
    );
    content.append(boundary);
  }
  if (snapshot.activeRoute.kind === 'search-form' && !snapshot.activeView) {
    const guidance = element('div', 'state-card');
    guidance.append(
      severityBadge('INFO'),
      element('strong', null, 'Use Search Synex'),
      element('p', null, 'Choose a supported identifier type in the global search above.'),
    );
    content.append(guidance);
  } else if (snapshot.activeRoute.kind === 'input-form' && !snapshot.activeView) {
    const guidance = element('div', 'state-card');
    guidance.append(
      severityBadge('INFO'),
      element('strong', null, 'Enter the bounded diagnostic inputs'),
      element('p', null, 'Nothing is queried until the form is submitted.'),
    );
    content.append(guidance);
  } else if (renderState(content, snapshot.activeView)) {
    if (snapshot.activeRoute.kind === 'overview') renderOverview(content, snapshot.activeView);
    else {
      const selectedView = provider?.views.find((view) => view.id === snapshot.activeRoute.view);
      const primitive = selectedView?.primitive || snapshot.activeView.primitive;
      content.append(renderPrimitive(primitive,
        snapshot.activeView.data));
    }
    const pagination = buildPagination(snapshot.activeView);
    if (pagination) content.append(pagination);
  }
  return content;
}

function render() {
  if (focusFrame !== null) window.cancelAnimationFrame(focusFrame);
  focusFrame = null;
  const previousFocus = document.activeElement?.dataset?.focusKey || null;
  root.replaceChildren();
  if (snapshot.lifecycle !== 'open') {
    delete document.body.dataset.open;
    document.body.removeAttribute('aria-busy');
    return;
  }
  document.body.dataset.open = 'true';

  const surface = element('main', 'surface');
  surface.setAttribute('aria-label', 'Synex read-only control plane');
  const panel = element('section', 'panel');
  const workspace = element('div', 'workspace');
  const toolbar = element('header', 'toolbar');
  toolbar.append(buildGlobalSearch());
  const actions = element('div', 'actions');
  const refresh = action('Refresh', 'action', refreshActive);
  refresh.dataset.focusKey = 'refresh';
  const close = action('Close', 'action', requestClose);
  close.dataset.focusKey = 'close';
  actions.append(refresh, close);
  toolbar.append(actions);
  workspace.append(toolbar, buildContent());
  panel.append(buildSidebar(), workspace);
  surface.append(panel);
  root.append(surface);

  if (previousFocus) {
    focusFrame = window.requestAnimationFrame(() => {
      focusFrame = null;
      if (snapshot.lifecycle !== 'open') return;
      const candidate = [...document.querySelectorAll('[data-focus-key]')]
        .find((node) => node.dataset.focusKey === previousFocus);
      candidate?.focus({ preventScroll: true });
    });
  }
}

store.subscribe((value) => {
  snapshot = value;
  render();
});

window.addEventListener('message', (event) => {
  if (!messageOrigins.has(event.origin)) return;
  const message = validateMessage(event.data);
  if (!message) {
    reportError('MESSAGE_INVALID', 'transport');
    return;
  }
  try {
    if (message.type === 'control:visibility') {
      if (!message.payload.open) {
        stopRefresh();
        store.close(message.payload.reason);
        return;
      }
      store.open();
      refreshProviderCatalog();
      requestData({ kind: 'overview', provider: 'core', view: 'overview' });
      scheduleRefresh();
      return;
    }
    if (message.type === 'control:access-revoked') {
      stopRefresh();
      store.close('access_revoked');
      return;
    }
    if (message.type === 'control:invalidate') {
      refreshProviderCatalog();
      refreshActive();
      return;
    }
    const result = store.resolve(message.response);
    if (result.accepted && !result.error && result.item?.request?.operation === 'providers'
      && message.response.data?.hasMore === true
      && typeof message.response.data?.nextCursor === 'string') {
      requestData({ kind: 'catalog', provider: 'core', view: 'providers' }, {
        operation: 'providers', cursor: message.response.data.nextCursor, limit: 12,
      });
    }
    if (!result.accepted && result.reason === 'STALE_RESPONSE') {
      reportError('STALE_RESPONSE', 'transport');
    }
  } catch {
    reportError('RENDER_FAILURE', 'message');
    requestClose();
  }
});

window.addEventListener('keydown', (event) => {
  if (snapshot.lifecycle !== 'open') return;
  if (event.key === 'Escape') {
    event.preventDefault();
    requestClose();
    return;
  }
  if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === 'k') {
    event.preventDefault();
    document.getElementById('control-search-query')?.focus();
  }
});

document.addEventListener('visibilitychange', () => {
  if (document.hidden) {
    stopRefresh();
    return;
  }
  if (snapshot.lifecycle === 'open') {
    refreshActive();
    scheduleRefresh();
  }
});

window.addEventListener('error', () => reportError('UNCAUGHT_ERROR', 'browser'));
window.addEventListener('unhandledrejection', () => reportError('UNHANDLED_REJECTION', 'browser'));

render();
postNui('ready', { version: PROTOCOL_VERSION }).then((response) => {
  if (callbackCode(response)) reportError('READY_REJECTED', 'lifecycle');
});
