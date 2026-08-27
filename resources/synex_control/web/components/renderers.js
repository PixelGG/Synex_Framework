import { SEVERITIES } from '../core/protocol.js';

const MAX_METRIC_CARDS = 48;
const MAX_TABLE_ROWS = 100;
const MAX_TABLE_COLUMNS = 12;
const MAX_TIMELINE_ITEMS = 100;
const MAX_PROJECTION_DEPTH = 3;
const MAX_COMPACT_TEXT = 384;

function isObject(value) {
  return Boolean(value) && typeof value === 'object' && !Array.isArray(value);
}

function isScalar(value) {
  return value === null || ['string', 'number', 'boolean'].includes(typeof value);
}

function humanize(value) {
  return String(value)
    .replace(/([a-z0-9])([A-Z])/gu, '$1 $2')
    .replace(/[_.-]+/gu, ' ')
    .replace(/\s+/gu, ' ')
    .trim()
    .replace(/^./u, (character) => character.toUpperCase()) || 'Value';
}

function boundedText(value, maximum = MAX_COMPACT_TEXT) {
  return String(value).slice(0, maximum);
}

function compactText(value, depth = 0, seen = new WeakSet()) {
  if (value === null || value === undefined) return 'UNAVAILABLE';
  if (typeof value === 'string') return boundedText(value);
  if (typeof value === 'number') return Number.isFinite(value) ? String(value) : 'UNAVAILABLE';
  if (typeof value === 'boolean') return String(value);
  if (typeof value !== 'object') return 'UNAVAILABLE';
  if (seen.has(value)) return 'UNAVAILABLE';
  seen.add(value);
  let output;
  if (Array.isArray(value)) {
    const items = value.slice(0, 8).map((item) => compactText(item, depth + 1, seen));
    output = items.join(', ');
    if (value.length > 8) output += `, +${value.length - 8} more`;
  } else if (depth >= 2) {
    output = `${Object.keys(value).length} field(s)`;
  } else {
    const parts = Object.keys(value).sort().slice(0, 8)
      .map((key) => `${humanize(key)}: ${compactText(value[key], depth + 1, seen)}`);
    output = parts.join(' · ');
    if (Object.keys(value).length > 8) output += ` · +${Object.keys(value).length - 8} more`;
  }
  seen.delete(value);
  return boundedText(output || 'No data');
}

export function element(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined && text !== null) node.textContent = String(text);
  return node;
}

export function action(label, className, handler, accessibleLabel) {
  const node = element('button', className, label);
  node.type = 'button';
  if (accessibleLabel) node.setAttribute('aria-label', accessibleLabel);
  node.addEventListener('click', handler);
  return node;
}

export function formatValue(value) {
  if (value === null || value === undefined) return 'UNAVAILABLE';
  if (typeof value === 'string') return value;
  if (typeof value === 'number' || typeof value === 'boolean') return String(value);
  if (Array.isArray(value)) return value.map(formatValue).join(', ');
  return compactText(value);
}

export function severityBadge(value) {
  const severity = SEVERITIES.has(value) ? value : 'UNAVAILABLE';
  const badge = element('span', `severity severity-${severity.toLowerCase()}`);
  const marker = element('span', 'severity-marker');
  marker.setAttribute('aria-hidden', 'true');
  badge.append(marker, document.createTextNode(severity));
  return badge;
}

function objectEntries(value) {
  return value && typeof value === 'object' && !Array.isArray(value)
    ? Object.entries(value).sort(([left], [right]) => left.localeCompare(right))
    : [];
}

export function projectDetail(value) {
  const rows = [];
  const seen = new WeakSet();
  const append = (path, item) => {
    if (rows.length >= MAX_TABLE_ROWS) return;
    rows.push({
      label: path.length > 0 ? path.map(humanize).join(' / ') : 'Value',
      value: isScalar(item) ? item ?? 'UNAVAILABLE' : compactText(item),
    });
  };
  const visit = (item, path, depth) => {
    if (rows.length >= MAX_TABLE_ROWS) return;
    if (isScalar(item)) {
      append(path, item);
      return;
    }
    if (!item || typeof item !== 'object') {
      append(path, 'UNAVAILABLE');
      return;
    }
    if (seen.has(item)) {
      append(path, 'UNAVAILABLE');
      return;
    }
    if (depth >= MAX_PROJECTION_DEPTH) {
      append(path, item);
      return;
    }
    seen.add(item);
    if (Array.isArray(item)) {
      if (item.length === 0) append(path, 'No entries');
      for (const [index, entry] of item.slice(0, MAX_TABLE_ROWS).entries()) {
        visit(entry, [...path, String(index + 1)], depth + 1);
        if (rows.length >= MAX_TABLE_ROWS) break;
      }
    } else {
      const entries = objectEntries(item);
      if (entries.length === 0) append(path, 'No data');
      for (const [key, entry] of entries) {
        visit(entry, [...path, key], depth + 1);
        if (rows.length >= MAX_TABLE_ROWS) break;
      }
    }
    seen.delete(item);
  };
  visit(value, [], 0);
  return rows;
}

function renderKeyValue(value) {
  const list = element('dl', 'data-list');
  const rows = projectDetail(value);
  if (rows.length === 0) {
    const row = element('div', 'data-row');
    row.append(element('dt', 'data-key', 'Status'), element('dd', 'data-value', 'No data reported.'));
    list.append(row);
    return list;
  }
  for (const item of rows) {
    const row = element('div', 'data-row');
    row.append(
      element('dt', 'data-key', item.label),
      element('dd', 'data-value', formatValue(item.value)),
    );
    list.append(row);
  }
  return list;
}

export function projectMetrics(value) {
  const cards = [];
  const append = (label, metricValue, metadata = {}) => {
    if (cards.length >= MAX_METRIC_CARDS) return;
    const normalized = isScalar(metricValue) ? metricValue : compactText(metricValue);
    const severity = SEVERITIES.has(metadata.severity)
      ? metadata.severity
      : typeof normalized === 'string' && SEVERITIES.has(normalized) ? normalized : undefined;
    cards.push({
      label: boundedText(label, 128),
      value: normalized ?? 'UNAVAILABLE',
      detail: typeof metadata.detail === 'string' ? boundedText(metadata.detail) : undefined,
      severity,
    });
  };
  const visit = (entry, path, depth) => {
    if (cards.length >= MAX_METRIC_CARDS || depth > MAX_PROJECTION_DEPTH) return;
    if (isScalar(entry)) {
      append(path.map(humanize).join(' · ') || 'Metric', entry);
      return;
    }
    if (Array.isArray(entry)) {
      const scalar = entry.every(isScalar);
      append(path.map(humanize).join(' · ') || 'Metric', scalar
        ? entry.slice(0, 16).map((item) => compactText(item)).join(', ')
        : `${entry.length} entries`);
      return;
    }
    if (!isObject(entry)) return;
    const keys = Object.keys(entry).sort();
    for (const key of keys) {
      if (cards.length >= MAX_METRIC_CARDS) break;
      if (key === 'view') continue;
      const transparent = key === 'metrics';
      const nextPath = transparent ? path : [...path, key];
      visit(entry[key], nextPath, transparent ? depth : depth + 1);
    }
  };

  const items = Array.isArray(value?.items) ? value.items : Array.isArray(value) ? value : null;
  if (items) {
    for (const [index, item] of items.entries()) {
      if (cards.length >= MAX_METRIC_CARDS) break;
      if (isObject(item) && Object.hasOwn(item, 'value')) {
        const label = typeof item.label === 'string' ? item.label
          : typeof item.name === 'string' ? item.name : `Metric ${index + 1}`;
        if (isScalar(item.value)) append(label, item.value, item);
        else visit(item.value, [label], 0);
      } else visit(item, [`Metric ${index + 1}`], 0);
    }
  } else visit(value, [], 0);
  return cards;
}

function renderMetrics(value) {
  const grid = element('div', 'metric-grid');
  for (const item of projectMetrics(value)) {
    if (!item || typeof item !== 'object') continue;
    const card = element('article', 'metric-card');
    card.append(
      element('p', 'metric-label', item.label || item.name || 'Metric'),
      element('strong', 'metric-value', formatValue(item.value)),
    );
    if (typeof item.detail === 'string') card.append(element('p', 'metric-detail', item.detail));
    if (SEVERITIES.has(item.severity)) card.append(severityBadge(item.severity));
    grid.append(card);
  }
  if (!grid.hasChildNodes()) grid.append(element('p', 'empty-copy', 'No metrics reported.'));
  return grid;
}

function genericRows(value) {
  return objectEntries(value)
    .filter(([key]) => !['view', 'hasMore', 'nextCursor', 'truncated'].includes(key))
    .slice(0, MAX_TABLE_ROWS)
    .map(([key, item]) => ({ field: humanize(key), value: compactText(item) }));
}

function rowSource(value) {
  if (Array.isArray(value)) return value;
  if (!isObject(value)) return [];
  for (const key of ['items', 'entries', 'rows', 'resources', 'sessions', 'deprecations']) {
    if (Array.isArray(value[key])) return value[key];
  }
  if (Object.hasOwn(value, 'snapshot')) {
    const nested = rowSource(value.snapshot);
    return nested.length > 0 ? nested : genericRows(value.snapshot);
  }
  if (isObject(value.summary)) return genericRows(value.summary);
  if (isObject(value.cache)) return genericRows(value.cache);
  return genericRows(value);
}

export function projectTable(value) {
  const source = rowSource(value).slice(0, MAX_TABLE_ROWS);
  const items = source.map((item) => {
    if (!isObject(item)) return { value: compactText(item) };
    const row = {};
    for (const key of Object.keys(item).sort().slice(0, MAX_TABLE_COLUMNS)) {
      row[key] = isScalar(item[key]) ? item[key] : compactText(item[key]);
    }
    return row;
  });
  const keys = [];
  const observed = new Set();
  for (const item of items) {
    for (const key of Object.keys(item)) {
      if (observed.has(key)) continue;
      observed.add(key);
      keys.push(key);
      if (keys.length >= MAX_TABLE_COLUMNS) break;
    }
    if (keys.length >= MAX_TABLE_COLUMNS) break;
  }
  const declared = Array.isArray(value?.columns) ? value.columns : [];
  const columns = keys.map((key) => {
    const definition = declared.find((column) => isObject(column) && column.key === key);
    return {
      key,
      label: typeof definition?.label === 'string'
        ? boundedText(definition.label, 128) : humanize(key),
    };
  });
  return { columns, items };
}

function renderTable(value) {
  const region = element('div', 'table-region');
  region.tabIndex = 0;
  region.setAttribute('aria-label', 'Scrollable diagnostic table');
  const table = element('table', 'data-table');
  const projected = projectTable(value);
  const columns = projected.columns;
  const head = document.createElement('thead');
  const headRow = document.createElement('tr');
  for (const column of columns) headRow.append(element('th', null, column.label));
  head.append(headRow);
  table.append(head);
  const body = document.createElement('tbody');
  const items = projected.items;
  for (const item of items) {
    const row = document.createElement('tr');
    for (const column of columns) row.append(element('td', null, formatValue(item?.[column.key])));
    body.append(row);
  }
  if (items.length === 0) {
    const row = document.createElement('tr');
    const cell = element('td', 'empty-cell', 'No rows reported.');
    cell.colSpan = Math.max(columns.length, 1);
    row.append(cell);
    body.append(row);
  }
  table.append(body);
  region.append(table);
  return region;
}

function timelineSource(value) {
  if (Array.isArray(value)) return value;
  if (!isObject(value)) return [];
  for (const key of ['items', 'entries', 'events', 'recentTransitions', 'deprecations']) {
    if (Array.isArray(value[key])) return value[key];
  }
  if (value.status === 'UNAVAILABLE') return [value];
  return [];
}

export function projectTimeline(value) {
  return timelineSource(value).slice(0, MAX_TIMELINE_ITEMS).map((item) => {
    if (!isObject(item)) return {
      timestamp: 'UNAVAILABLE', status: 'INFO', label: 'Runtime event', detail: compactText(item),
    };
    const explicitUnavailable = item.status === 'UNAVAILABLE';
    const timestamp = item.timestamp ?? item.time ?? item.occurredAt ?? item.occurred_at
      ?? item.at ?? 'UNAVAILABLE';
    const transition = typeof item.from === 'string' && typeof item.to === 'string'
      ? `${item.from} to ${item.to}` : null;
    const label = item.label ?? item.name ?? item.action ?? item.operation ?? item.title ?? item.code
      ?? transition ?? (explicitUnavailable ? 'Unavailable' : 'Runtime event');
    const parts = [];
    if (typeof item.detail === 'string') parts.push(item.detail);
    else if (typeof item.summary === 'string') parts.push(item.summary);
    else if (typeof item.reason === 'string') parts.push(item.reason);
    else if (typeof item.message === 'string') parts.push(item.message);
    if (typeof item.traceId === 'string') parts.push(`Trace: ${boundedText(item.traceId, 128)}`);
    if (typeof item.resource === 'string') parts.push(`Resource: ${boundedText(item.resource, 64)}`);
    if (typeof item.durationMs === 'number') parts.push(`Duration: ${compactText(item.durationMs)} ms`);
    if (typeof item.parentSpanId === 'string') {
      parts.push(`Parent: ${boundedText(item.parentSpanId, 128)}`);
    }
    if (Array.isArray(item.childSpanIds) && item.childSpanIds.length > 0) {
      parts.push(`Children: ${item.childSpanIds.slice(0, 16).map((value) => compactText(value)).join(', ')}`);
    }
    if (typeof item.errorCode === 'string') parts.push(`Error: ${boundedText(item.errorCode, 64)}`);
    if (item.actor !== undefined) parts.push(`Actor: ${compactText(item.actor)}`);
    if (item.target !== undefined) parts.push(`Target: ${compactText(item.target)}`);
    if (typeof item.status === 'string' && item.status !== 'UNAVAILABLE') {
      parts.push(`Status: ${boundedText(item.status, 64)}`);
    }
    return {
      timestamp: boundedText(timestamp, 128),
      severity: SEVERITIES.has(item.severity) ? item.severity
        : explicitUnavailable ? 'UNAVAILABLE' : undefined,
      status: typeof item.status === 'string' ? boundedText(item.status, 64) : 'INFO',
      label: boundedText(label, 160),
      detail: boundedText(parts.join(' · ') || (explicitUnavailable
        ? 'This timeline is not available from the current provider.' : 'No additional detail.')),
    };
  });
}

function renderTimeline(value) {
  const list = element('ol', 'timeline');
  const items = projectTimeline(value);
  for (const item of items) {
    const row = element('li', 'timeline-item');
    const header = element('div', 'timeline-header');
    header.append(
      element('time', 'timeline-time', item?.timestamp || item?.time || 'UNAVAILABLE'),
      SEVERITIES.has(item?.severity) ? severityBadge(item.severity) : element('strong', null, item?.status || 'INFO'),
    );
    row.append(header, element('p', 'timeline-title', item?.label || item?.name || 'Runtime event'));
    if (item?.detail) row.append(element('p', 'timeline-detail', item.detail));
    list.append(row);
  }
  if (!list.hasChildNodes()) list.append(element('li', 'empty-copy', 'No timeline entries reported.'));
  return list;
}

export function projectFindings(value) {
  const items = Array.isArray(value?.items) ? value.items.slice(0, MAX_TABLE_ROWS) : [];
  return items.map((item) => {
    const finding = isObject(item) ? item : { summary: compactText(item) };
    const metadata = [];
    if (finding.resource !== undefined) metadata.push(`Resource: ${compactText(finding.resource)}`);
    if (finding.capability !== undefined) metadata.push(`Capability: ${compactText(finding.capability)}`);
    if (finding.count !== undefined) metadata.push(`Count: ${compactText(finding.count)}`);
    return {
      severity: SEVERITIES.has(finding.severity) ? finding.severity : 'UNAVAILABLE',
      title: boundedText(finding.title ?? finding.code ?? finding.capability ?? 'Finding', 160),
      summary: boundedText(finding.summary ?? finding.reason ?? finding.message
        ?? 'No additional finding detail.', MAX_COMPACT_TEXT),
      metadata: boundedText(metadata.join(' / '), MAX_COMPACT_TEXT),
    };
  });
}

function renderFindings(value) {
  const list = element('div', 'finding-list');
  const items = projectFindings(value);
  for (const item of items) {
    const finding = element('article', 'finding');
    const header = element('header', 'finding-header');
    header.append(severityBadge(item.severity), element('strong', null, item.title));
    finding.append(header);
    finding.append(element('p', 'finding-summary', item.summary));
    if (item.metadata) finding.append(element('p', 'finding-meta', item.metadata));
    list.append(finding);
  }
  if (!list.hasChildNodes()) list.append(element('p', 'empty-copy', 'No findings reported.'));
  return list;
}

function renderGraph(value) {
  const region = element('div', 'graph-region');
  const nodes = Array.isArray(value?.nodes) ? value.nodes.slice(0, 128) : [];
  const edges = Array.isArray(value?.edges) ? value.edges.slice(0, 256) : [];
  const nodeGrid = element('div', 'graph-nodes');
  for (const node of nodes) {
    const card = element('article', 'graph-node');
    card.append(element('strong', null, node?.label || node?.id || 'Node'));
    if (node?.type) card.append(element('span', 'graph-node-type', node.type));
    if (SEVERITIES.has(node?.health)) card.append(severityBadge(node.health));
    nodeGrid.append(card);
  }
  const edgeList = element('ul', 'graph-edges');
  for (const edge of edges) {
    edgeList.append(element('li', null,
      `${formatValue(edge?.from)} → ${formatValue(edge?.to)} · ${formatValue(edge?.type || 'depends')}`));
  }
  region.append(nodeGrid);
  if (edges.length > 0) region.append(element('h3', 'subheading', 'Relationships'), edgeList);
  if (nodes.length === 0) region.append(element('p', 'empty-copy', 'No graph nodes reported.'));
  return region;
}

export function renderPrimitive(primitive, value) {
  const renderers = {
    detail: renderKeyValue,
    findings: renderFindings,
    graph: renderGraph,
    'key-value': renderKeyValue,
    metrics: renderMetrics,
    table: renderTable,
    timeline: renderTimeline,
  };
  return (renderers[primitive] || renderKeyValue)(value);
}
