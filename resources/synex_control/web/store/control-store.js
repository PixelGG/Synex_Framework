import { normalizePage, normalizeProviders } from '../core/protocol.js';

const overviewRoute = Object.freeze({ kind: 'overview', provider: 'core', view: 'overview' });

function routeKey(route) {
  return `${route.kind}:${route.provider || 'core'}:${route.view || 'overview'}`;
}

export function createControlStore() {
  const listeners = new Set();
  const views = new Map();
  const pending = new Map();
  const cursorHistory = new Map();
  let state = {
    lifecycle: 'closed',
    closeReason: 'boot',
    activeRoute: overviewRoute,
    providers: [],
    lastError: null,
    staleResponses: 0,
  };

  function emit() {
    for (const listener of listeners) listener(snapshot());
  }

  function snapshot() {
    return {
      ...state,
      activeView: views.get(routeKey(state.activeRoute)) || null,
    };
  }

  function close(reason = 'runtime') {
    for (const item of pending.values()) window.clearTimeout(item.timeoutId);
    pending.clear();
    views.clear();
    cursorHistory.clear();
    state = {
      lifecycle: reason === 'access_revoked' ? 'revoked' : 'closed',
      closeReason: reason,
      activeRoute: overviewRoute,
      providers: [],
      lastError: reason === 'access_revoked' ? 'ACCESS_REVOKED' : null,
      staleResponses: 0,
    };
    emit();
  }

  function open() {
    if (state.lifecycle === 'open') return;
    state = { ...state, lifecycle: 'open', closeReason: null, lastError: null };
    emit();
  }

  function navigate(route) {
    state = { ...state, activeRoute: Object.freeze({ ...route }), lastError: null };
    emit();
  }

  function begin(request, route, timeoutId) {
    const key = routeKey(route);
    const previous = views.get(key);
    pending.set(request.requestId, { request, route, key, timeoutId });
    views.set(key, {
      ...(previous || {}),
      status: previous?.data ? 'refreshing' : 'loading',
      latestRequestId: request.requestId,
      error: null,
    });
    emit();
  }

  function rejectLocal(requestId, code) {
    const item = pending.get(requestId);
    if (!item) return;
    window.clearTimeout(item.timeoutId);
    pending.delete(requestId);
    const previous = views.get(item.key) || {};
    if (previous.latestRequestId !== requestId) {
      state = { ...state, staleResponses: state.staleResponses + 1 };
      emit();
      return;
    }
    views.set(item.key, {
      ...previous,
      status: previous.data ? 'stale' : code === 'TIMEOUT' ? 'timeout' : 'error',
      error: code,
    });
    state = { ...state, lastError: code };
    emit();
  }

  function resolve(response) {
    const item = pending.get(response.requestId);
    if (!item) {
      state = { ...state, staleResponses: state.staleResponses + 1 };
      emit();
      return { accepted: false, reason: 'STALE_RESPONSE' };
    }
    window.clearTimeout(item.timeoutId);
    pending.delete(response.requestId);
    const current = views.get(item.key);
    if (current?.latestRequestId !== response.requestId) {
      state = { ...state, staleResponses: state.staleResponses + 1 };
      emit();
      return { accepted: false, reason: 'STALE_RESPONSE' };
    }
    if (!response.ok) {
      views.set(item.key, {
        ...(current || {}),
        status: current?.data ? 'stale' : 'unavailable',
        error: response.error,
      });
      state = { ...state, lastError: response.error };
      emit();
      return { accepted: true, error: response.error, item };
    }

    const page = normalizePage(response.data);
    views.set(item.key, {
      status: 'ready',
      error: null,
      data: page.value,
      primitive: page.primitive,
      generatedAt: page.generatedAt,
      cursor: item.request.cursor || null,
      nextCursor: page.nextCursor,
      hasMore: page.hasMore,
      latestRequestId: response.requestId,
    });
    if (item.request.operation === 'providers'
      || item.request.operation === 'overview' && state.providers.length === 0) {
      const providerSource = Array.isArray(response.data?.providers)
        ? response.data.providers
        : Array.isArray(page.value?.providers)
          ? page.value.providers
          : [];
      if (providerSource.length > 0 || item.request.operation === 'providers') {
        const normalized = normalizeProviders(providerSource);
        const merged = item.request.operation === 'providers' && item.request.cursor
          ? [...state.providers, ...normalized]
          : normalized;
        const byNamespace = new Map(merged.map((provider) => [provider.namespace, provider]));
        state = {
          ...state,
          providers: [...byNamespace.values()].sort((left, right) => left.namespace.localeCompare(right.namespace)),
          lastError: null,
        };
      }
    }
    emit();
    return { accepted: true, item };
  }

  function historyFor(route) {
    const key = routeKey(route);
    if (!cursorHistory.has(key)) cursorHistory.set(key, []);
    return cursorHistory.get(key);
  }

  function pushCursor(route, cursor) {
    historyFor(route).push(cursor || null);
  }

  function popCursor(route) {
    const history = historyFor(route);
    return history.length > 0 ? history.pop() : undefined;
  }

  function resetCursor(route) {
    cursorHistory.delete(routeKey(route));
  }

  return {
    begin,
    close,
    getRouteKey: routeKey,
    hasPrevious: (route) => historyFor(route).length > 0,
    navigate,
    open,
    popCursor,
    pushCursor,
    rejectLocal,
    resetCursor,
    resolve,
    snapshot,
    subscribe(listener) {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
  };
}
