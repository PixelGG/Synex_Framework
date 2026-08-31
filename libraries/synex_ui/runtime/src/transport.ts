import {
  UI_LIMITS,
  UI_ERROR_CODES,
  UI_PROTOCOL_VERSION,
  type NuiResponse,
  type UiErrorCode,
  isBoundedPayload,
  isPlainRecord,
} from './protocol';

export type CallbackRoute =
  | 'runtime:ready'
  | 'runtime:respond'
  | 'runtime:close'
  | 'runtime:input'
  | 'runtime:signals:visible'
  | 'runtime:interaction'
  | 'runtime:preferences'
  | 'runtime:error';

export interface NuiTransportOptions {
  resourceName?: string;
  fetchImplementation?: typeof fetch;
  timeoutMs?: number;
}

const routes = new Set<CallbackRoute>([
  'runtime:ready',
  'runtime:respond',
  'runtime:close',
  'runtime:input',
  'runtime:signals:visible',
  'runtime:interaction',
  'runtime:preferences',
  'runtime:error',
]);
const errorCodes = new Set<string>(UI_ERROR_CODES);
const resourceNamePattern = /^[A-Za-z0-9_-]{1,64}$/;

function parentResourceName(): string {
  const candidate = (window as Window & { GetParentResourceName?: () => string }).GetParentResourceName?.();
  return typeof candidate === 'string' && resourceNamePattern.test(candidate) ? candidate : 'synex_ui';
}

function normalizeResponse<T>(value: unknown): NuiResponse<T> {
  if (!isPlainRecord(value) || !isBoundedPayload(value) || typeof value.ok !== 'boolean') {
    return { ok: false, error: { code: 'NUI_RESPONSE_INVALID' } };
  }
  if (value.ok === true) return value.data === undefined ? { ok: true } : { ok: true, data: value.data as T };
  const rawError = isPlainRecord(value.error) ? value.error : Object.create(null) as Record<string, unknown>;
  const code = typeof rawError.code === 'string' && errorCodes.has(rawError.code)
    ? rawError.code as UiErrorCode
    : 'NUI_RESPONSE_INVALID';
  const message = typeof rawError.message === 'string' ? rawError.message.slice(0, 256) : undefined;
  const error: { code: UiErrorCode | 'NUI_HTTP_ERROR' | 'NUI_RESPONSE_INVALID' | 'NUI_UNAVAILABLE'; message?: string } = {
    code,
  };
  if (message) error.message = message;
  return { ok: false, error };
}

export function createNuiTransport(options: NuiTransportOptions = {}) {
  const resourceName = options.resourceName !== undefined && resourceNamePattern.test(options.resourceName)
    ? options.resourceName
    : parentResourceName();
  const fetchImplementation = options.fetchImplementation ?? window.fetch.bind(window);
  const timeoutMs = Math.min(Math.max(options.timeoutMs ?? 5_000, 250), 15_000);
  let pending = 0;

  async function post<T>(route: CallbackRoute, payload: Record<string, unknown>, signal?: AbortSignal): Promise<NuiResponse<T>> {
    if (!routes.has(route) || !isBoundedPayload(payload)) {
      return { ok: false, error: { code: 'UI_REQUEST_INVALID' } };
    }
    if (pending >= UI_LIMITS.maxPendingRequests) {
      return { ok: false, error: { code: 'UI_REQUEST_TIMEOUT', message: 'UI request pressure limit reached.' } };
    }
    pending += 1;
    const controller = new AbortController();
    let abortReason: 'external' | 'timeout' | null = null;
    const abort = () => {
      if (controller.signal.aborted) return;
      abortReason = 'external';
      controller.abort();
    };
    if (signal?.aborted) abort();
    else signal?.addEventListener('abort', abort, { once: true });
    const timeout = window.setTimeout(() => {
      if (controller.signal.aborted) return;
      abortReason = 'timeout';
      controller.abort();
    }, timeoutMs);
    try {
      const response = await fetchImplementation(`https://${resourceName}/${route}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json; charset=UTF-8' },
        body: JSON.stringify({ protocolVersion: UI_PROTOCOL_VERSION, ...payload }),
        signal: controller.signal,
      });
      if (!response.ok) return { ok: false, error: { code: 'NUI_HTTP_ERROR' } };
      return normalizeResponse<T>(await response.json());
    } catch {
      return {
        ok: false,
        error: { code: abortReason === 'timeout' ? 'UI_REQUEST_TIMEOUT' : controller.signal.aborted ? 'UI_REQUEST_CANCELLED' : 'NUI_UNAVAILABLE' },
      };
    } finally {
      window.clearTimeout(timeout);
      signal?.removeEventListener('abort', abort);
      pending -= 1;
    }
  }

  return { post, pending: () => pending, resourceName };
}

export type NuiTransport = ReturnType<typeof createNuiTransport>;
