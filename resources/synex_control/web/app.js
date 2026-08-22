const root = document.getElementById('root');
const resourceName = GetParentResourceName();
const messageOrigins = new Set([
  window.location.origin,
  'https://nui-game-internal',
  `https://cfx-nui-${resourceName}`,
]);
let currentSnapshot = null;
let activeSection = 'overview';

const TITLES = {
  overview: 'Overview', runtime: 'Runtime', resources: 'Resources', dependencies: 'Dependencies',
  contracts: 'Contracts', capabilities: 'Capabilities', rpc: 'RPC & Services', hooks: 'Hooks',
  database: 'Database', migrations: 'Migrations', sessions: 'Sessions', characters: 'Characters',
  groups: 'Groups', accounts: 'Accounts', ledger: 'Ledger', entities: 'Entities', audit: 'Audit',
  tracing: 'Tracing', performance: 'Performance', security: 'Security', compatibility: 'Compatibility',
};

async function post(name, payload = {}) {
  try {
    const response = await fetch(`https://${resourceName}/${name}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json; charset=UTF-8' },
      body: JSON.stringify(payload),
    });
    return await response.json();
  } catch {
    return { ok: false, error: 'NUI_UNAVAILABLE' };
  }
}

function stringify(value) {
  if (value === null) return 'null';
  if (typeof value === 'string') return value;
  if (typeof value === 'number' || typeof value === 'boolean') return String(value);
  try { return JSON.stringify(value, null, 2); } catch { return '[UNAVAILABLE]'; }
}

function button(label, className, handler) {
  const element = document.createElement('button');
  element.type = 'button';
  element.className = className;
  element.textContent = label;
  element.addEventListener('click', handler);
  return element;
}

function availabilityBadge(result) {
  const badge = document.createElement('span');
  badge.className = result?.available ? 'availability' : 'availability unavailable';
  badge.textContent = result?.available ? 'LIVE' : 'UNAVAILABLE';
  return badge;
}

function appendRow(list, key, value) {
  const row = document.createElement('div');
  row.className = 'data-row';
  const term = document.createElement('dt');
  term.className = 'data-key';
  term.textContent = key;
  const description = document.createElement('dd');
  description.className = 'data-value';
  description.textContent = stringify(value);
  row.append(term, description);
  list.append(row);
}

function renderSearch(container) {
  const form = document.createElement('form');
  form.className = 'search-form';
  const kind = document.createElement('select');
  kind.className = 'field';
  kind.setAttribute('aria-label', 'Search field');
  for (const value of ['trace', 'character', 'transaction', 'resource']) {
    const option = document.createElement('option');
    option.value = value;
    option.textContent = value;
    kind.append(option);
  }
  const query = document.createElement('input');
  query.className = 'field search-input';
  query.type = 'text';
  query.minLength = 2;
  query.maxLength = 96;
  query.autocomplete = 'off';
  query.spellcheck = false;
  query.placeholder = 'Exact identifier or resource name';
  query.setAttribute('aria-label', 'Exact search value');
  const submit = button('Search', 'action primary', () => {});
  submit.type = 'submit';
  const feedback = document.createElement('p');
  feedback.className = 'search-feedback';
  form.addEventListener('submit', async (event) => {
    event.preventDefault();
    const value = query.value.trim();
    if (value.length < 2) {
      feedback.textContent = 'Enter at least two characters.';
      return;
    }
    submit.disabled = true;
    const result = await post('search', { kind: kind.value, value });
    submit.disabled = false;
    feedback.textContent = result?.ok ? 'Search requested.' : (result?.error || 'Search unavailable.');
  });
  form.append(kind, query, submit, feedback);
  container.append(form);
}

function renderSection(container, name, result) {
  const header = document.createElement('header');
  header.className = 'section-header';
  const titleGroup = document.createElement('div');
  const eyebrow = document.createElement('p');
  eyebrow.className = 'eyebrow';
  eyebrow.textContent = 'Runtime observation';
  const title = document.createElement('h2');
  title.textContent = TITLES[name] || name;
  titleGroup.append(eyebrow, title);
  header.append(titleGroup, availabilityBadge(result));
  container.append(header);

  if (name === 'tracing') renderSearch(container);
  if (!result?.available) {
    const message = document.createElement('div');
    message.className = 'empty-state';
    const code = document.createElement('strong');
    code.textContent = result?.error || 'UNAVAILABLE';
    const detail = document.createElement('p');
    detail.textContent = result?.error === 'NOT_EXPOSED'
      ? 'The running framework does not expose this read model.'
      : result?.error === 'SEARCH_REQUIRED'
        ? 'Submit an exact search to request this view.'
        : 'No verified runtime data is available for this section.';
    message.append(code, detail);
    container.append(message);
    return;
  }

  const value = result.value;
  const list = document.createElement('dl');
  list.className = 'data-list';
  if (value && typeof value === 'object' && !Array.isArray(value)) {
    const entries = Object.entries(value).sort(([left], [right]) => left.localeCompare(right));
    if (entries.length === 0) appendRow(list, 'status', 'No entries reported by the runtime.');
    else for (const [key, item] of entries) appendRow(list, key, item);
  } else if (Array.isArray(value)) {
    if (value.length === 0) appendRow(list, 'status', 'No entries reported by the runtime.');
    else value.forEach((item, index) => appendRow(list, String(index + 1), item));
  } else {
    appendRow(list, 'value', value);
  }
  container.append(list);
}

function render(snapshot) {
  if (!snapshot || typeof snapshot !== 'object' || typeof snapshot.sections !== 'object') return;
  currentSnapshot = snapshot;
  const order = Array.isArray(snapshot.sectionOrder)
    ? snapshot.sectionOrder.filter((name) => typeof name === 'string' && snapshot.sections[name])
    : Object.keys(snapshot.sections);
  if (!snapshot.sections[activeSection]) activeSection = order[0] || 'overview';
  root.replaceChildren();

  const surface = document.createElement('main');
  surface.className = 'surface';
  surface.setAttribute('aria-label', 'Synex read-only control plane');
  const panel = document.createElement('section');
  panel.className = 'panel';

  const sidebar = document.createElement('aside');
  sidebar.className = 'sidebar';
  const brand = document.createElement('div');
  brand.className = 'brand';
  const brandMark = document.createElement('span');
  brandMark.className = 'brand-mark';
  brandMark.textContent = 'S';
  const brandText = document.createElement('div');
  const brandTitle = document.createElement('h1');
  brandTitle.textContent = 'Synex Control';
  const brandSub = document.createElement('p');
  brandSub.textContent = 'Read-only';
  brandText.append(brandTitle, brandSub);
  brand.append(brandMark, brandText);

  const nav = document.createElement('nav');
  nav.className = 'navigation';
  nav.setAttribute('aria-label', 'Control plane sections');
  for (const name of order) {
    const result = snapshot.sections[name];
    const item = button(TITLES[name] || name, name === activeSection ? 'nav-item active' : 'nav-item', () => {
      activeSection = name;
      render(currentSnapshot);
    });
    const dot = document.createElement('span');
    dot.className = result?.available ? 'status-dot' : 'status-dot unavailable';
    item.prepend(dot);
    nav.append(item);
  }
  sidebar.append(brand, nav);

  const workspace = document.createElement('div');
  workspace.className = 'workspace';
  const toolbar = document.createElement('header');
  toolbar.className = 'toolbar';
  const meta = document.createElement('p');
  meta.className = 'meta';
  meta.textContent = `Snapshot ${snapshot.generatedAt || 'UNAVAILABLE'} · verified runtime data only`;
  const actions = document.createElement('div');
  actions.className = 'actions';
  actions.append(
    button('Refresh', 'action primary', () => post('refresh')),
    button('Close', 'action', () => post('close')),
  );
  toolbar.append(meta, actions);
  const content = document.createElement('section');
  content.className = 'content';
  renderSection(content, activeSection, snapshot.sections[activeSection]);
  workspace.append(toolbar, content);

  panel.append(sidebar, workspace);
  surface.append(panel);
  root.append(surface);
  document.body.dataset.open = 'true';
}

function close() {
  currentSnapshot = null;
  activeSection = 'overview';
  root.replaceChildren();
  delete document.body.dataset.open;
}

window.addEventListener('message', (event) => {
  if (!messageOrigins.has(event.origin)) return;
  const message = event.data;
  if (!message || typeof message !== 'object') return;
  if (message.type === 'close') close();
  else if ((message.type === 'open' || message.type === 'snapshot') && message.snapshot) {
    render(message.snapshot);
  }
});

window.addEventListener('keydown', (event) => {
  if (event.key === 'Escape' && currentSnapshot) post('close');
});

close();
