import { describe, expect, it, vi } from 'vitest';
import { createNuiTransport, type CallbackRoute } from '../runtime/src/transport';

describe('NUI transport', () => {
  it('posts only to the fixed resource and callback route', async () => {
    const fetchImplementation = vi.fn<typeof fetch>().mockResolvedValue(new Response(JSON.stringify({ ok: true, data: { ready: true } }), {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    }));
    const transport = createNuiTransport({ resourceName: 'synex_ui', fetchImplementation });
    const result = await transport.post<{ ready: boolean }>('runtime:ready', { requestId: 'ready_1' });
    expect(result).toEqual({ ok: true, data: { ready: true } });
    expect(fetchImplementation).toHaveBeenCalledWith('https://synex_ui/runtime:ready', expect.objectContaining({ method: 'POST' }));
  });

  it('rejects a route outside the static allowlist before issuing fetch', async () => {
    const fetchImplementation = vi.fn<typeof fetch>();
    const transport = createNuiTransport({ fetchImplementation });
    const result = await transport.post('https://attacker.invalid' as CallbackRoute, { requestId: 'bad_1' });
    expect(result).toMatchObject({ ok: false, error: { code: 'UI_REQUEST_INVALID' } });
    expect(fetchImplementation).not.toHaveBeenCalled();
  });

  it('normalizes malformed callback responses', async () => {
    const transport = createNuiTransport({
      fetchImplementation: vi.fn<typeof fetch>().mockResolvedValue(new Response('[]', {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      })),
    });
    await expect(transport.post('runtime:error', { requestId: 'error_1' }))
      .resolves.toMatchObject({ ok: false, error: { code: 'NUI_RESPONSE_INVALID' } });
  });

  it('rejects unknown callback error codes and unsafe resource overrides', async () => {
    const fetchImplementation = vi.fn<typeof fetch>().mockResolvedValue(new Response(JSON.stringify({
      ok: false,
      error: { code: 'EXECUTE_ARBITRARY_CODE' },
    }), { status: 200, headers: { 'Content-Type': 'application/json' } }));
    const transport = createNuiTransport({ resourceName: 'bad/path', fetchImplementation });
    await expect(transport.post('runtime:error', { requestId: 'error_2' }))
      .resolves.toMatchObject({ ok: false, error: { code: 'NUI_RESPONSE_INVALID' } });
    expect(fetchImplementation).toHaveBeenCalledWith('https://synex_ui/runtime:error', expect.any(Object));
  });

  it('aborts timed-out callbacks and releases pending capacity', async () => {
    vi.useFakeTimers();
    const transport = createNuiTransport({
      timeoutMs: 250,
      fetchImplementation: vi.fn<typeof fetch>().mockImplementation((_url, init) => new Promise((_resolve, reject) => {
        init?.signal?.addEventListener('abort', () => reject(new DOMException('Aborted', 'AbortError')));
      })),
    });
    const request = transport.post('runtime:ready', { requestId: 'slow_1' });
    await vi.advanceTimersByTimeAsync(251);
    await expect(request).resolves.toMatchObject({ ok: false, error: { code: 'UI_REQUEST_TIMEOUT' } });
    expect(transport.pending()).toBe(0);
    vi.useRealTimers();
  });

  it('distinguishes caller cancellation from an internal timeout', async () => {
    const controller = new AbortController();
    const transport = createNuiTransport({
      fetchImplementation: vi.fn<typeof fetch>().mockImplementation((_url, init) => new Promise((_resolve, reject) => {
        init?.signal?.addEventListener('abort', () => reject(new DOMException('Aborted', 'AbortError')));
      })),
    });
    const request = transport.post('runtime:ready', { requestId: 'cancelled_1' }, controller.signal);
    controller.abort();
    await expect(request).resolves.toMatchObject({ ok: false, error: { code: 'UI_REQUEST_CANCELLED' } });
    expect(transport.pending()).toBe(0);
  });
});
