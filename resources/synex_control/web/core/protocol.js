export const PROTOCOL_VERSION = 1;
export const REQUEST_TIMEOUT_MS = 12000;
export const OVERVIEW_REFRESH_MS = 10000;
export const VIEW_REFRESH_MS = 30000;
export const MAX_RESPONSE_BYTES = 32768;
export const MAX_DEPTH = 10;
export const MAX_ENTRIES = 2048;
export const MAX_STRING_LENGTH = 512;
export const MAX_KEY_LENGTH = 96;
export const MAX_PAGE_LIMIT = 100;

export const OPERATIONS = new Set([
  'inspect',
  'overview',
  'page',
  'providers',
  'search',
  'section',
]);

export const PRIMITIVES = new Set([
  'metrics',
  'key-value',
  'table',
  'detail',
  'timeline',
  'graph',
  'findings',
]);

export const SEVERITIES = new Set([
  'HEALTHY',
  'INFO',
  'WARNING',
  'DEGRADED',
  'ERROR',
  'CRITICAL',
  'UNAVAILABLE',
]);

const IDENTIFIER = /^[A-Za-z0-9][A-Za-z0-9_.:%-]*$/u;
export const LOOKUP_IDENTIFIER = /^[A-Za-z0-9][A-Za-z0-9_.:@*%-]*$/u;
const NAMESPACE = /^[a-z][a-z0-9_.-]*$/u;
const PROVIDER_OPERATIONS = new Set([
  'findings', 'health', 'inspect', 'list', 'metrics', 'search', 'simulate', 'summary',
]);
const INPUT_SOURCES = new Set(['id', 'filter']);
const INPUT_TYPES = new Set(['string', 'integer', 'boolean']);
const INPUT_FORMATS = new Set([
  'identifier', 'lookup', 'uuid', 'resource', 'capability', 'action', 'integer',
  'numeric-string', 'boolean', 'text',
]);
const ACCESS_CLASSES = new Set(['general', 'audit', 'security', 'financial', 'identifiers']);

function encodedLength(value) {
  try {
    return new TextEncoder().encode(JSON.stringify(value)).byteLength;
  } catch {
    return Number.POSITIVE_INFINITY;
  }
}

function isPlainObject(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return false;
  const prototype = Object.getPrototypeOf(value);
  return prototype === Object.prototype || prototype === null;
}

function boundedString(value, maximum = MAX_STRING_LENGTH, pattern) {
  return typeof value === 'string' && value.length > 0 && value.length <= maximum
    && (!pattern || pattern.test(value));
}

function sanitizeValue(value, state, depth = 0) {
  if (depth > MAX_DEPTH || state.entries > MAX_ENTRIES) throw new Error('PAYLOAD_LIMIT');
  if (value === null || typeof value === 'boolean') return value;
  if (typeof value === 'number') {
    if (!Number.isFinite(value)) throw new Error('INVALID_NUMBER');
    return value;
  }
  if (typeof value === 'string') {
    if (value.length > MAX_STRING_LENGTH) throw new Error('STRING_LIMIT');
    return value;
  }
  if (Array.isArray(value)) {
    const output = [];
    for (const item of value) {
      state.entries += 1;
      output.push(sanitizeValue(item, state, depth + 1));
    }
    return output;
  }
  if (!isPlainObject(value)) throw new Error('INVALID_OBJECT');
  const output = Object.create(null);
  for (const [key, item] of Object.entries(value)) {
    state.entries += 1;
    if (!boundedString(key, MAX_KEY_LENGTH)) throw new Error('INVALID_KEY');
    output[key] = sanitizeValue(item, state, depth + 1);
  }
  return output;
}

function sanitizePayload(value) {
  return sanitizeValue(value, { entries: 0 });
}

function validRequestId(value) {
  return boundedString(value, 64, IDENTIFIER) && value.length >= 8;
}

function validProvider(value) {
  return boundedString(value, 64, NAMESPACE);
}

function normalizeError(value) {
  const code = typeof value === 'string'
    ? value
    : isPlainObject(value) && typeof value.code === 'string'
      ? value.code
      : 'UNAVAILABLE';
  return /^[A-Z][A-Z0-9_]{0,63}$/u.test(code) ? code : 'UNAVAILABLE';
}

export function normalizeViewInput(input, operation) {
  if (!isPlainObject(input) || !Array.isArray(input.fields)
    || input.fields.length < 1 || input.fields.length > 8) return null;
  const fields = [];
  const seen = new Set();
  let idFields = 0;
  for (const candidate of input.fields) {
    if (!isPlainObject(candidate) || !boundedString(candidate.key, 48)
      || !/^[a-z][a-z0-9_]*$/u.test(candidate.key) || seen.has(candidate.key)
      || !boundedString(candidate.label, 64) || !INPUT_SOURCES.has(candidate.source)
      || !INPUT_TYPES.has(candidate.type) || !INPUT_FORMATS.has(candidate.format)
      || typeof candidate.required !== 'boolean') return null;
    if (candidate.source === 'id') {
      idFields += 1;
      if (operation !== 'inspect' || candidate.key !== 'id'
        || candidate.required !== true || idFields > 1) return null;
    }
    const minLength = candidate.minLength;
    const maxLength = candidate.maxLength;
    const minimum = candidate.minimum;
    const maximum = candidate.maximum;
    if (candidate.type === 'string') {
      if (candidate.format === 'integer' || minimum !== undefined || maximum !== undefined
        || minLength !== undefined && (!Number.isInteger(minLength) || minLength < 1 || minLength > 128)
        || maxLength !== undefined && (!Number.isInteger(maxLength) || maxLength < 1 || maxLength > 128)
        || minLength !== undefined && maxLength !== undefined && minLength > maxLength) return null;
    } else if (candidate.type === 'integer') {
      if (candidate.format !== 'integer' || minLength !== undefined || maxLength !== undefined
        || minimum !== undefined && (!Number.isSafeInteger(minimum) || minimum < -2147483648
          || minimum > 2147483647)
        || maximum !== undefined && (!Number.isSafeInteger(maximum) || maximum < -2147483648
          || maximum > 2147483647)
        || minimum !== undefined && maximum !== undefined && minimum > maximum) return null;
    } else if (candidate.format !== 'boolean' || minLength !== undefined || maxLength !== undefined
      || minimum !== undefined || maximum !== undefined) return null;
    seen.add(candidate.key);
    fields.push({
      key: candidate.key,
      label: candidate.label,
      source: candidate.source,
      type: candidate.type,
      format: candidate.format,
      required: candidate.required,
      ...(minLength !== undefined ? { minLength } : {}),
      ...(maxLength !== undefined ? { maxLength } : {}),
      ...(minimum !== undefined ? { minimum } : {}),
      ...(maximum !== undefined ? { maximum } : {}),
    });
  }
  return { fields };
}

export function normalizeViewSearch(search, operation) {
  if (operation !== 'search' || !isPlainObject(search) || !Array.isArray(search.kinds)
    || search.kinds.length < 1 || search.kinds.length > 16) return null;
  const kinds = [];
  const seen = new Set();
  for (const candidate of search.kinds) {
    if (!isPlainObject(candidate) || !boundedString(candidate.id, 32)
      || !/^[a-z][a-z0-9]*(?:[_-][a-z0-9]+)*$/u.test(candidate.id)
      || seen.has(candidate.id) || !Array.isArray(candidate.modes)
      || candidate.modes.length < 1 || candidate.modes.length > 2
      || !ACCESS_CLASSES.has(candidate.accessClass)) return null;
    const modes = [...new Set(candidate.modes)];
    if (modes.length !== candidate.modes.length
      || modes.some((mode) => mode !== 'exact' && mode !== 'prefix')) return null;
    seen.add(candidate.id);
    kinds.push({
      id: candidate.id,
      modes,
      accessClass: candidate.accessClass,
      authorized: candidate.authorized !== false,
    });
  }
  return { kinds };
}

function normalizeView(view) {
  if (!isPlainObject(view) || !boundedString(view.id, 64, NAMESPACE)
    || !ACCESS_CLASSES.has(view.accessClass)) return null;
  const presentation = view.primitive || view.presentation;
  const primitive = PRIMITIVES.has(presentation) ? presentation : 'key-value';
  const operation = PROVIDER_OPERATIONS.has(view.operation) ? view.operation : 'list';
  const input = view.input == null ? null : normalizeViewInput(view.input, operation);
  if (view.input != null && input == null) return null;
  const search = view.search == null ? null : normalizeViewSearch(view.search, operation);
  if ((operation === 'search' && search == null)
    || (operation !== 'search' && view.search != null)) return null;
  return {
    id: view.id,
    label: boundedString(view.label, 64) ? view.label : view.id,
    primitive,
    operation,
    order: Number.isInteger(view.order) && view.order >= 0 && view.order <= 1000
      ? view.order
      : 1000,
    description: boundedString(view.description, 160) ? view.description : null,
    inspectable: view.inspectable === true || view.operation === 'inspect',
    authorized: view.authorized !== false,
    accessClass: view.accessClass,
    input,
    search,
  };
}

export function normalizeProviders(value) {
  if (!Array.isArray(value)) return [];
  const providers = [];
  const seen = new Set();
  for (const candidate of value.slice(0, 32)) {
    if (!isPlainObject(candidate) || !validProvider(candidate.namespace)
      || seen.has(candidate.namespace)) continue;
    seen.add(candidate.namespace);
    const views = Array.isArray(candidate.views)
      ? candidate.views.map(normalizeView).filter(Boolean).slice(0, 32)
      : [];
    views.sort((left, right) => left.order - right.order || left.label.localeCompare(right.label));
    const operationSource = Array.isArray(candidate.operations)
      ? candidate.operations
      : isPlainObject(candidate.operations)
        ? Object.entries(candidate.operations).filter(([, enabled]) => enabled === true).map(([name]) => name)
        : [];
    const health = typeof candidate.health === 'string'
      ? candidate.health
      : isPlainObject(candidate.health)
        ? candidate.health.status || candidate.health.state
        : null;
    const metrics = Object.create(null);
    for (const key of [
      'calls', 'successes', 'failures', 'rejections', 'timeouts', 'busy',
      'lastDurationMs', 'maximumDurationMs', 'lastResponseBytes',
    ]) {
      const metric = candidate.metrics?.[key];
      if (Number.isSafeInteger(metric) && metric >= 0) metrics[key] = metric;
    }
    providers.push({
      namespace: candidate.namespace,
      label: boundedString(candidate.label, 64) ? candidate.label : candidate.namespace,
      resource: boundedString(candidate.resource, 64, NAMESPACE) ? candidate.resource : candidate.namespace,
      version: boundedString(candidate.version, 32) ? candidate.version : 'UNAVAILABLE',
      health: SEVERITIES.has(health) ? health : 'UNAVAILABLE',
      authorized: candidate.authorized !== false,
      operations: operationSource
        .filter((item) => typeof item === 'string' && /^[A-Za-z][A-Za-z0-9_]{0,31}$/u.test(item))
        .slice(0, 16),
      metrics,
      views: views.length > 0 ? views : [{
        id: 'summary', label: 'Summary', primitive: 'key-value', inspectable: false, authorized: true,
      }],
    });
  }
  return providers.sort((left, right) => left.label.localeCompare(right.label));
}

export function validateMessage(message) {
  if (!isPlainObject(message) || message.version !== PROTOCOL_VERSION
    || encodedLength(message) > MAX_RESPONSE_BYTES) return null;
  if (message.type === 'control:visibility') {
    if (!isPlainObject(message.payload) || typeof message.payload.open !== 'boolean') return null;
    return {
      type: message.type,
      payload: {
        open: message.payload.open,
        reason: typeof message.payload.reason === 'string'
          ? message.payload.reason.slice(0, 64)
          : 'runtime',
      },
    };
  }
  if (message.type === 'control:access-revoked') {
    return {
      type: message.type,
      payload: { code: normalizeError(message.payload?.code) },
    };
  }
  if (message.type === 'control:invalidate') {
    const payload = message.payload;
    if (!isPlainObject(payload) || payload.reason !== 'RESOURCE_STATE_CHANGED'
      || !boundedString(payload.resource, 64, /^[a-z][a-z0-9_-]*$/u)
      || (payload.state !== 'started' && payload.state !== 'stopped')) return null;
    return {
      type: message.type,
      payload: {
        reason: payload.reason,
        resource: payload.resource,
        state: payload.state,
      },
    };
  }
  if (message.type !== 'control:response' || !isPlainObject(message.response)
    || !validRequestId(message.response.requestId)
    || typeof message.response.ok !== 'boolean') return null;
  if (!message.response.ok) {
    return {
      type: message.type,
      response: {
        requestId: message.response.requestId,
        ok: false,
        error: normalizeError(message.response.error),
      },
    };
  }
  try {
    return {
      type: message.type,
      response: {
        requestId: message.response.requestId,
        ok: true,
        data: sanitizePayload(message.response.data ?? Object.create(null)),
      },
    };
  } catch {
    return null;
  }
}

export function createRequestId() {
  const bytes = new Uint32Array(2);
  crypto.getRandomValues(bytes);
  return `request_${Date.now().toString(36)}_${bytes[0].toString(36)}${bytes[1].toString(36)}`;
}

export function normalizePage(data) {
  const container = isPlainObject(data?.page) ? data.page : data;
  const nextCursor = typeof container?.nextCursor === 'string' && container.nextCursor.length <= 256
    ? container.nextCursor
    : null;
  return {
    primitive: PRIMITIVES.has(container?.primitive) ? container.primitive : 'key-value',
    value: container?.value ?? container?.data ?? container ?? Object.create(null),
    nextCursor,
    hasMore: container?.hasMore === true || container?.truncated === true && nextCursor !== null,
    generatedAt: typeof data?.generatedAt === 'string' ? data.generatedAt.slice(0, 64) : null,
  };
}
