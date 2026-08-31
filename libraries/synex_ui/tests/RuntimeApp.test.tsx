import { act, fireEvent, render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { focusByIntent, OpenSurfaceBoundary, RuntimeApp } from '../runtime/src/RuntimeApp';
import type { GameEnvelope, RuntimeSurface } from '../runtime/src/protocol';
import type { NuiTransport } from '../runtime/src/transport';

function createFetchMock() {
  return vi.fn<typeof fetch>().mockImplementation(async () => new Response(JSON.stringify({ ok: true, data: { ready: true } }), {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    }));
}

function envelope(overrides: Partial<GameEnvelope> = {}): GameEnvelope {
  return {
    protocolVersion: 1,
    messageId: 'message_open_01',
    type: 'surface:open',
    ownerResource: 'synex_inventory',
    ownerEpoch: 42,
    revision: 7,
    payload: {
      requestId: 'request_original_01',
      instanceId: 'instance_original_01',
      surfaceId: 'surface_confirm_01',
      kind: 'confirm',
      title: 'Confirm owner action',
      tone: 'warning',
      dismissible: true,
      confirmLabel: 'Continue',
      cancelLabel: 'Cancel',
    },
    ...overrides,
  };
}

function signalEnvelope(overrides: Partial<GameEnvelope> = {}): GameEnvelope {
  return {
    protocolVersion: 1,
    messageId: 'message_signal_01',
    type: 'signal:upsert',
    ownerResource: 'synex_notify',
    ownerEpoch: 9,
    revision: 1,
    payload: {
      signalId: 'notify.passive',
      revision: 1,
      kind: 'toast',
      tone: 'success',
      priority: 'normal',
      title: 'Vehicle stored',
      message: 'Sultan RS moved to Pillbox Garage.',
      actions: [{ token: 'undo', label: 'Undo', hint: 'U' }],
      createdAt: 1_725_000_000_000,
      position: 'top-right',
      generation: 1,
    },
    ...overrides,
  };
}

function interactionEnvelope(overrides: Partial<GameEnvelope> = {}): GameEnvelope {
  return {
    protocolVersion: 1,
    messageId: 'message_interaction_01',
    type: 'interaction:upsert',
    ownerResource: 'synex_interact',
    ownerEpoch: 12,
    revision: 1,
    payload: {
      interactionId: 'vehicle.trunk.open',
      revision: 1,
      mode: 'cue',
      label: 'Open trunk',
      projection: { visible: true, behindCamera: false, x: 0.5, y: 0.62 },
      intents: [{ intentId: 'trunk.open', label: 'Open trunk' }],
      selectedIntentId: 'trunk.open',
      moreCount: 0,
      pointer: false,
      input: { primary: { keyboard: 'E', gamepad: 'A' } },
      cancellable: false,
      generation: 1,
    },
    ...overrides,
  };
}

function mountRuntime(fetchMock: ReturnType<typeof vi.fn>) {
  const root = document.createElement('div');
  root.id = 'root';
  document.body.replaceChildren(root);
  Object.defineProperty(window, 'fetch', { configurable: true, writable: true, value: fetchMock });
  return render(<RuntimeApp />, { container: root });
}

function send(data: unknown, origin = window.location.origin) {
  window.dispatchEvent(new MessageEvent('message', { data, origin }));
}

async function readBrowserBootId(fetchMock: ReturnType<typeof vi.fn>): Promise<string> {
  await waitFor(() => expect(fetchMock).toHaveBeenCalled());
  const call = fetchMock.mock.calls.find(([input]) => String(input).endsWith('/runtime:ready'));
  const request = call?.[1] as RequestInit | undefined;
  const body = typeof request?.body === 'string' ? JSON.parse(request.body) as Record<string, unknown> : null;
  if (!body || typeof body.browserBootId !== 'string') throw new Error('runtime:ready browser boot id missing');
  return body.browserBootId;
}

describe('shared runtime browser lifecycle', () => {
  beforeEach(() => {
    document.documentElement.removeAttribute('data-sx-quality');
    document.body.removeAttribute('data-sx-open');
    document.body.removeAttribute('data-sx-visible');
    document.body.removeAttribute('data-sx-interactive');
  });

  it('starts with an empty, transparent and aria-hidden root', async () => {
    const fetchMock = createFetchMock();
    const { container } = mountRuntime(fetchMock);
    expect(container).toBeEmptyDOMElement();
    await waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(1));
    expect(container).toHaveAttribute('aria-hidden', 'true');
    expect(document.body.dataset.sxOpen).toBe('false');
  });

  it('ignores messages from an untrusted origin', async () => {
    const fetchMock = createFetchMock();
    mountRuntime(fetchMock);
    send(envelope(), 'https://attacker.invalid');
    await waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(1));
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument();
  });

  it('consumes a sound envelope once without visibility, focus, or reducer replay', async () => {
    const originalAudioContext = window.AudioContext;
    let currentTimeMs = 0;
    const now = vi.spyOn(performance, 'now').mockImplementation(() => currentTimeMs);
    const start = vi.fn();
    const close = vi.fn(async () => undefined);
    const audioContext = {
      state: 'running',
      currentTime: 5,
      destination: {},
      resume: vi.fn(async () => undefined),
      close,
      createOscillator: vi.fn(() => ({
        type: 'sine',
        frequency: { setValueAtTime: vi.fn(), exponentialRampToValueAtTime: vi.fn() },
        connect: vi.fn(),
        disconnect: vi.fn(),
        addEventListener: vi.fn(),
        start,
        stop: vi.fn(),
      })),
      createGain: vi.fn(() => ({
        gain: { setValueAtTime: vi.fn(), exponentialRampToValueAtTime: vi.fn() },
        connect: vi.fn(),
        disconnect: vi.fn(),
      })),
    } as unknown as AudioContext;
    const Constructor = vi.fn(function AudioContextFixture() { return audioContext; });
    Object.defineProperty(window, 'AudioContext', { configurable: true, value: Constructor });

    try {
      const fetchMock = createFetchMock();
      const view = mountRuntime(fetchMock);
      const browserBootId = await readBrowserBootId(fetchMock);
      const activeBefore = document.activeElement;
      const sound = {
        protocolVersion: 1,
        messageId: 'message_sound_01',
        type: 'signal:sound',
        ownerResource: 'synex_notify',
        ownerEpoch: 9,
        revision: 0,
        payload: { tone: 'success', volume: 65, browserBootId },
      };
      send(sound);
      await waitFor(() => expect(start).toHaveBeenCalledTimes(1));
      expect(view.container).toBeEmptyDOMElement();
      expect(document.body.dataset.sxVisible).toBe('false');
      expect(document.body.dataset.sxInteractive).toBe('false');
      expect(document.activeElement).toBe(activeBefore);

      currentTimeMs += 50;
      send(sound);
      send({ ...sound, messageId: 'message_sound_wrong_boot', payload: {
        tone: 'success', volume: 65, browserBootId: 'ui_wrong_boot',
      } });
      await act(async () => { await Promise.resolve(); });
      expect(start).toHaveBeenCalledTimes(1);

      send({ ...sound, messageId: 'message_sound_new_epoch', ownerEpoch: 10 });
      await waitFor(() => expect(start).toHaveBeenCalledTimes(2));
      currentTimeMs += 50;
      send({ ...sound, messageId: 'message_sound_stale_epoch', ownerEpoch: 9 });
      await act(async () => { await Promise.resolve(); });
      expect(start).toHaveBeenCalledTimes(2);

      view.rerender(<RuntimeApp />);
      send(envelope({
        messageId: 'message_sync_after_sound_01',
        type: 'runtime:sync',
        ownerResource: 'synex_ui',
        ownerEpoch: 1,
        revision: 0,
        payload: {},
      }));
      await act(async () => { await Promise.resolve(); });
      expect(start).toHaveBeenCalledTimes(2);

      send(envelope({
        messageId: 'message_shutdown_after_sound_01',
        type: 'runtime:shutdown',
        ownerResource: 'synex_ui',
        ownerEpoch: 1,
        revision: 0,
        payload: {},
      }));
      await waitFor(() => expect(close).toHaveBeenCalledTimes(2));
    } finally {
      now.mockRestore();
      if (originalAudioContext) {
        Object.defineProperty(window, 'AudioContext', { configurable: true, value: originalAudioContext });
      } else {
        Reflect.deleteProperty(window, 'AudioContext');
      }
    }
  });

  it('stops active sound nodes and closes audio when the runtime unmounts', async () => {
    const originalAudioContext = window.AudioContext;
    const start = vi.fn();
    const stop = vi.fn();
    const oscillatorDisconnect = vi.fn();
    const gainDisconnect = vi.fn();
    const close = vi.fn(async () => undefined);
    const audioContext = {
      state: 'running',
      currentTime: 5,
      destination: {},
      resume: vi.fn(async () => undefined),
      close,
      createOscillator: vi.fn(() => ({
        type: 'sine',
        frequency: { setValueAtTime: vi.fn(), exponentialRampToValueAtTime: vi.fn() },
        connect: vi.fn(),
        disconnect: oscillatorDisconnect,
        addEventListener: vi.fn(),
        start,
        stop,
      })),
      createGain: vi.fn(() => ({
        gain: { setValueAtTime: vi.fn(), exponentialRampToValueAtTime: vi.fn() },
        connect: vi.fn(),
        disconnect: gainDisconnect,
      })),
    } as unknown as AudioContext;
    const Constructor = vi.fn(function AudioContextFixture() { return audioContext; });
    Object.defineProperty(window, 'AudioContext', { configurable: true, value: Constructor });

    try {
      const fetchMock = createFetchMock();
      const view = mountRuntime(fetchMock);
      const browserBootId = await readBrowserBootId(fetchMock);
      send({
        protocolVersion: 1,
        messageId: 'message_sound_unmount_01',
        type: 'signal:sound',
        ownerResource: 'synex_notify',
        ownerEpoch: 11,
        revision: 0,
        payload: { tone: 'neutral', volume: 40, browserBootId },
      });
      await waitFor(() => expect(start).toHaveBeenCalledTimes(1));
      view.unmount();
      await waitFor(() => expect(close).toHaveBeenCalledTimes(1));
      expect(stop).toHaveBeenCalledTimes(2);
      expect(oscillatorDisconnect).toHaveBeenCalledTimes(1);
      expect(gainDisconnect).toHaveBeenCalledTimes(1);
    } finally {
      if (originalAudioContext) {
        Object.defineProperty(window, 'AudioContext', { configurable: true, value: originalAudioContext });
      } else {
        Reflect.deleteProperty(window, 'AudioContext');
      }
    }
  });

  it('shows passive signals while the document remains pointer-free and non-interactive', async () => {
    const fetchMock = createFetchMock();
    const { container } = mountRuntime(fetchMock);
    send(signalEnvelope());
    expect(await screen.findByRole('group', { name: 'Vehicle stored' })).toHaveTextContent('Vehicle stored');
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument();
    expect(document.body.dataset.sxVisible).toBe('true');
    expect(document.body.dataset.sxInteractive).toBe('false');
    expect(document.body.dataset.sxOpen).toBe('false');
    expect(container).toHaveAttribute('aria-hidden', 'false');
    expect(screen.queryByRole('button', { name: 'Undo' })).not.toBeInTheDocument();

    send(signalEnvelope({
      messageId: 'message_signal_remove_01',
      type: 'signal:remove',
      revision: 2,
      payload: { signalId: 'notify.passive', generation: 2 },
    }));
    await waitFor(() => {
      expect(container.querySelector('[data-sx-phase="dismissing"]')).toBeInTheDocument();
      expect(document.body.dataset.sxVisible).toBe('true');
    });
    await waitFor(() => expect(container).toBeEmptyDOMElement());
    expect(document.body.dataset.sxVisible).toBe('false');
    expect(document.body.dataset.sxInteractive).toBe('false');
    expect(container).toHaveAttribute('aria-hidden', 'true');
  });

  it('updates passive signal hints from an event-synchronized gamepad report', async () => {
    const fetchMock = createFetchMock();
    mountRuntime(fetchMock);
    const passive = signalEnvelope();
    send({
      ...passive,
      messageId: 'message_signal_input_hint_01',
      payload: {
        ...passive.payload,
        actions: [{ token: 'undo', label: 'Undo' }],
      },
    });
    expect(await screen.findByRole('group', { name: 'Vehicle stored' })).toHaveTextContent('F9');
    const inputReportsBefore = fetchMock.mock.calls.filter(([url]) => (
      String(url).endsWith('/runtime:input')
    )).length;

    send(envelope({
      messageId: 'message_passive_input_gamepad_01',
      type: 'runtime:sync',
      ownerResource: 'synex_ui',
      ownerEpoch: 1,
      revision: 0,
      payload: { inputDevice: 'gamepad' },
    }));
    await waitFor(() => expect(screen.getByRole('group', { name: 'Vehicle stored' })).toHaveTextContent('D-pad Left'));
    expect(screen.getByRole('group', { name: 'Vehicle stored' })).not.toHaveTextContent('F9');
    expect(document.body.dataset.sxInteractive).toBe('false');
    const inputReportsAfter = fetchMock.mock.calls.filter(([url]) => (
      String(url).endsWith('/runtime:input')
    )).length;
    expect(inputReportsAfter).toBe(inputReportsBefore);
  });

  it('mounts a passive interaction cue without opening focus or pointer handling', async () => {
    const fetchMock = createFetchMock();
    const { container } = mountRuntime(fetchMock);
    const activeBefore = document.activeElement;
    send(interactionEnvelope());
    expect(await screen.findByText('Open trunk')).toBeInTheDocument();
    expect(document.body.dataset.sxVisible).toBe('true');
    expect(document.body.dataset.sxInteractive).toBe('false');
    expect(document.body.dataset.sxOpen).toBe('false');
    expect(container.querySelector('button, [tabindex]')).toBeNull();
    expect(document.activeElement).toBe(activeBefore);

    send(envelope({
      messageId: 'message_interaction_preferences_01',
      type: 'preferences:sync',
      ownerResource: 'synex_ui',
      ownerEpoch: 1,
      revision: 0,
      payload: {
        schemaVersion: 1,
        quality: 'BALANCED',
        scale: 125,
        density: 'comfortable',
        reducedMotion: true,
        reducedTransparency: false,
        highContrast: true,
        interactionAssist: true,
      },
    }));
    await waitFor(() => expect(container.querySelector('.sx-interaction')).toHaveAttribute('data-sx-assist', 'true'));
    expect(document.documentElement.dataset.sxReducedMotion).toBe('true');
    expect(document.documentElement.dataset.sxHighContrast).toBe('true');
    expect(document.documentElement.style.getPropertyValue('--synex-ui-scale')).toBe('1.25');
    expect(document.body.dataset.sxInteractive).toBe('false');

    send(interactionEnvelope({
      messageId: 'message_interaction_remove_01',
      type: 'interaction:remove',
      revision: 2,
      payload: { interactionId: 'vehicle.trunk.open', generation: 2 },
    }));
    await waitFor(() => expect(container).toBeEmptyDOMElement());
    expect(document.body.dataset.sxVisible).toBe('false');
    expect(document.body.dataset.sxInteractive).toBe('false');
  });

  it('marks only an explicitly pointer-enabled bloom as interactive shared UI', async () => {
    const fetchMock = createFetchMock();
    mountRuntime(fetchMock);
    send(interactionEnvelope({
      messageId: 'message_interaction_bloom_01',
      revision: 2,
      payload: {
        interactionId: 'vehicle.actions',
        revision: 2,
        mode: 'bloom',
        label: 'Vehicle actions',
        intents: [
          { intentId: 'trunk.open', label: 'Open trunk' },
          { intentId: 'vehicle.inspect', label: 'Inspect' },
        ],
        selectedIntentId: 'trunk.open',
        pointer: true,
        input: {
          primary: { keyboard: 'Enter', gamepad: 'A', mouse: 'Left Click' },
          cancel: { keyboard: 'Esc', gamepad: 'B', mouse: 'Right Click' },
        },
        cancellable: true,
        generation: 1,
      },
    }));
    expect(await screen.findByRole('menu')).toBeInTheDocument();
    expect(document.body.dataset.sxVisible).toBe('true');
    expect(document.body.dataset.sxInteractive).toBe('true');
    expect(document.body.dataset.sxOpen).toBe('true');
    expect(screen.getAllByRole('menuitem')).toHaveLength(2);
  });

  it('retries visibility reports and coalesces superseded retries with monotonic presentation revisions', async () => {
    vi.useFakeTimers();
    try {
      let visibilityAttempts = 0;
      const fetchMock = vi.fn<typeof fetch>().mockImplementation(async (input) => {
        const isVisibilityReport = String(input).endsWith('/runtime:signals:visible');
        if (isVisibilityReport) visibilityAttempts += 1;
        const body = isVisibilityReport && visibilityAttempts <= 2
          ? { ok: false, error: { code: 'UI_REQUEST_STALE' } }
          : { ok: true, data: { ready: true } };
        return new Response(JSON.stringify(body), {
          status: 200,
          headers: { 'Content-Type': 'application/json' },
        });
      });
      mountRuntime(fetchMock);

      await act(async () => {
        send(signalEnvelope());
        await Promise.resolve();
        await Promise.resolve();
      });
      let reports = fetchMock.mock.calls.filter(([url]) => (
        String(url).endsWith('/runtime:signals:visible')
      ));
      expect(reports).toHaveLength(1);

      await act(async () => {
        await vi.advanceTimersByTimeAsync(150);
      });
      reports = fetchMock.mock.calls.filter(([url]) => (
        String(url).endsWith('/runtime:signals:visible')
      ));
      expect(reports).toHaveLength(2);

      await act(async () => {
        send(signalEnvelope({
          messageId: 'message_signal_02',
          revision: 2,
          payload: {
            ...signalEnvelope().payload,
            revision: 2,
            title: 'Vehicle stored safely',
            generation: 2,
          },
        }));
        await Promise.resolve();
        await Promise.resolve();
      });
      reports = fetchMock.mock.calls.filter(([url]) => (
        String(url).endsWith('/runtime:signals:visible')
      ));
      expect(reports).toHaveLength(4);

      const payloads = reports.map(([, init]) => (
        JSON.parse(String((init as RequestInit | undefined)?.body)) as {
          generation: number;
          presentationRevision: number;
          capacity: number;
          signals: Array<{ revision: number }>;
        }
      ));
      expect(payloads.map(({ generation, presentationRevision }) => ({
        generation,
        presentationRevision,
      }))).toEqual([
        { generation: 1, presentationRevision: 1 },
        { generation: 1, presentationRevision: 2 },
        { generation: 2, presentationRevision: 3 },
        { generation: 2, presentationRevision: 4 },
      ]);
      expect(payloads[2]?.signals).toEqual([
        expect.objectContaining({ revision: 1 }),
      ]);
      expect(payloads[3]?.signals).toEqual([
        expect.objectContaining({ revision: 2 }),
      ]);
      expect(payloads.every(({ capacity }) => capacity === 4)).toBe(true);

      await act(async () => {
        await vi.advanceTimersByTimeAsync(500);
      });
      expect(fetchMock.mock.calls.filter(([url]) => (
        String(url).endsWith('/runtime:signals:visible')
      ))).toHaveLength(4);
    } finally {
      vi.useRealTimers();
    }
  });

  it('renders active-content-shaped strings as text and reports unknown messages', async () => {
    const fetchMock = createFetchMock();
    const { container } = mountRuntime(fetchMock);
    const hostileText = '<img src=x onerror=alert(1)><svg onload=alert(1) />';
    send(envelope({ payload: {
      requestId: 'request_text_01',
      instanceId: 'instance_text_01',
      surfaceId: 'surface_text_01',
      kind: 'alert',
      title: 'Literal content',
      description: hostileText,
    } }));
    expect(await screen.findByText(hostileText)).toBeInTheDocument();
    expect(container.querySelector('img, svg')).toBeNull();

    send({ ...envelope(), messageId: 'message_unknown_01', type: 'runtime:execute' });
    await waitFor(() => expect(fetchMock.mock.calls.some(([url]) => url === 'https://synex_ui/runtime:error')).toBe(true));
  });

  it('echoes the original request correlation when responding', async () => {
    const fetchMock = createFetchMock();
    mountRuntime(fetchMock);
    await waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(1));
    const readyBody = JSON.parse(String((fetchMock.mock.calls[0]?.[1] as RequestInit | undefined)?.body)) as Record<string, unknown>;
    send(envelope());
    const dialog = await screen.findByRole('dialog', { name: 'Confirm owner action' });
    expect(dialog).toBeInTheDocument();
    expect(document.body.dataset.sxOpen).toBe('true');
    await userEvent.click(screen.getByRole('button', { name: 'Continue' }));
    await waitFor(() => expect(fetchMock.mock.calls.some(([url]) => url === 'https://synex_ui/runtime:respond')).toBe(true));
    const responseCall = fetchMock.mock.calls.find(([url]) => url === 'https://synex_ui/runtime:respond');
    expect(responseCall).toBeDefined();
    const body = JSON.parse(String((responseCall?.[1] as RequestInit | undefined)?.body)) as Record<string, unknown>;
    expect(body).toMatchObject({
      protocolVersion: 1,
      requestId: 'request_original_01',
      instanceId: 'instance_original_01',
      surfaceId: 'surface_confirm_01',
      ownerEpoch: 42,
      revision: 7,
      action: 'confirmed',
      browserBootId: readyBody.browserBootId,
    });
  });

  it('removes the entire visible tree after a correlated close message', async () => {
    const fetchMock = createFetchMock();
    const { container } = mountRuntime(fetchMock);
    send(envelope());
    await screen.findByRole('dialog');
    send(envelope({
      messageId: 'message_close_01',
      type: 'surface:close',
      revision: 8,
      payload: { surfaceId: 'surface_confirm_01' },
    }));
    await waitFor(() => expect(screen.queryByRole('dialog')).not.toBeInTheDocument());
    expect(container).toBeEmptyDOMElement();
    expect(container).toHaveAttribute('aria-hidden', 'true');
    expect(document.body.dataset.sxOpen).toBe('false');
  });

  it('executes a bounded nested menu option through the original surface request', async () => {
    const fetchMock = createFetchMock();
    mountRuntime(fetchMock);
    send(envelope({ payload: {
      requestId: 'request_original_01',
      instanceId: 'instance_original_01',
      surfaceId: 'surface_confirm_01',
      kind: 'menu',
      title: 'Owner actions',
      sections: [{ id: 'primary', items: [{ id: 'more', label: 'More actions', options: [{ id: 'release', label: 'Release owner' }] }] }],
    } }));
    await userEvent.click(await screen.findByRole('menuitem', { name: /More actions/ }));
    await userEvent.click(screen.getByRole('menuitem', { name: /Release owner/ }));
    await waitFor(() => expect(fetchMock.mock.calls.some(([url]) => url === 'https://synex_ui/runtime:respond')).toBe(true));
    const responseCall = fetchMock.mock.calls.find(([url]) => url === 'https://synex_ui/runtime:respond');
    const body = JSON.parse(String((responseCall?.[1] as RequestInit | undefined)?.body)) as Record<string, unknown>;
    expect(body).toMatchObject({ requestId: 'request_original_01', action: 'selected', data: { id: 'release' } });
  });

  it('returns a multi-selection and applies a normalized context anchor', async () => {
    const fetchMock = createFetchMock();
    mountRuntime(fetchMock);
    send(envelope({ payload: {
      requestId: 'request_original_01',
      instanceId: 'instance_original_01',
      surfaceId: 'surface_confirm_01',
      kind: 'select',
      title: 'Select owners',
      multiple: true,
      options: [{ id: 'alpha', label: 'Alpha' }, { id: 'bravo', label: 'Bravo' }],
    } }));
    await userEvent.click(await screen.findByRole('button', { name: 'Select owners' }));
    await userEvent.click(screen.getByRole('checkbox', { name: /Alpha/ }));
    await userEvent.click(screen.getByRole('button', { name: 'Select' }));
    await waitFor(() => expect(fetchMock.mock.calls.some(([url]) => url === 'https://synex_ui/runtime:respond')).toBe(true));
    const responseCall = fetchMock.mock.calls.find(([url]) => url === 'https://synex_ui/runtime:respond');
    const body = JSON.parse(String((responseCall?.[1] as RequestInit | undefined)?.body)) as Record<string, unknown>;
    expect(body).toMatchObject({ action: 'selected', data: { ids: ['alpha'] } });

    send(envelope({
      messageId: 'message_context_01',
      ownerEpoch: 43,
      payload: {
        requestId: 'request_context_01',
        instanceId: 'instance_context_01',
        surfaceId: 'surface_context_01',
        kind: 'contextMenu',
        title: 'Context actions',
        sections: [{ id: 'context', items: [{ id: 'inspect', label: 'Inspect' }] }],
        anchor: { x: 0.75, y: 0.25 },
      },
    }));
    const context = await screen.findByRole('dialog', { name: 'Context actions' });
    expect(context).toHaveStyle({ '--sx-runtime-anchor-x': '75vw', '--sx-runtime-anchor-y': '25vh' });
  });

  it('provides an accessible name for a searchable runtime select', async () => {
    const fetchMock = createFetchMock();
    mountRuntime(fetchMock);
    send(envelope({ payload: {
      requestId: 'request_search_01',
      instanceId: 'instance_search_01',
      surfaceId: 'surface_search_01',
      kind: 'select',
      title: 'Select active owner',
      searchable: true,
      options: [{ id: 'alpha', label: 'Alpha owner' }],
    } }));
    expect(await screen.findByRole('combobox', { name: 'Select active owner' })).toBeInTheDocument();
  });

  it('renders a one-shot select as an honest button group and accepts keyboard activation', async () => {
    const fetchMock = createFetchMock();
    mountRuntime(fetchMock);
    send(envelope({ payload: {
      requestId: 'request_button_select_01',
      instanceId: 'instance_button_select_01',
      surfaceId: 'surface_button_select_01',
      kind: 'select',
      title: 'Choose focus owner',
      options: [
        { id: 'alpha', label: 'Alpha owner', metadata: { source: 'runtime' } },
        { id: 'bravo', label: 'Bravo owner' },
      ],
    } }));
    expect(await screen.findByRole('group', { name: 'Choose focus owner' })).toBeInTheDocument();
    expect(screen.queryByRole('listbox')).not.toBeInTheDocument();
    expect(screen.queryByRole('option')).not.toBeInTheDocument();
    const option = screen.getByRole('button', { name: 'Alpha owner' });
    option.focus();
    await userEvent.keyboard('{Enter}');
    await waitFor(() => expect(fetchMock.mock.calls.some(([url]) => url === 'https://synex_ui/runtime:respond')).toBe(true));
    const responseCall = fetchMock.mock.calls.find(([url]) => url === 'https://synex_ui/runtime:respond');
    const body = JSON.parse(String((responseCall?.[1] as RequestInit | undefined)?.body)) as Record<string, unknown>;
    expect(body).toMatchObject({
      requestId: 'request_button_select_01',
      action: 'selected',
      data: { id: 'alpha', metadata: { source: 'runtime' } },
    });
  });

  it('preserves local form state while a higher surface suspends and releases it', async () => {
    const fetchMock = createFetchMock();
    mountRuntime(fetchMock);
    send(envelope({ payload: {
      requestId: 'request_form_01',
      instanceId: 'instance_form_01',
      surfaceId: 'surface_form_01',
      kind: 'form',
      title: 'Owner configuration',
      fields: [{ id: 'reason', type: 'text', label: 'Reason', value: 'Initial value' }],
    } }));
    const input = await screen.findByRole('textbox', { name: /Reason/ });
    await userEvent.clear(input);
    await userEvent.type(input, 'Preserved draft');

    send(envelope({
      messageId: 'message_alert_02',
      revision: 1,
      payload: {
        requestId: 'request_alert_02',
        instanceId: 'instance_alert_02',
        surfaceId: 'surface_alert_02',
        kind: 'alert',
        title: 'Higher-priority alert',
      },
    }));
    expect(await screen.findByRole('dialog', { name: 'Higher-priority alert' })).toBeInTheDocument();
    expect(screen.queryByRole('dialog', { name: 'Owner configuration' })).not.toBeInTheDocument();

    send(envelope({
      messageId: 'message_alert_close_02',
      type: 'surface:close',
      revision: 2,
      payload: { surfaceId: 'surface_alert_02' },
    }));
    expect(await screen.findByRole('dialog', { name: 'Owner configuration' })).toBeInTheDocument();
    expect(screen.getByRole('textbox', { name: /Reason/ })).toHaveValue('Preserved draft');
  });

  it('keeps synthetic navigation intents classified as gamepad across device switches', async () => {
    const fetchMock = createFetchMock();
    mountRuntime(fetchMock);
    send(envelope());
    await screen.findByRole('dialog', { name: 'Confirm owner action' });

    fireEvent.pointerMove(window);
    await waitFor(() => expect(document.documentElement.dataset.sxInput).toBe('mouse'));
    send(envelope({
      messageId: 'message_intent_01',
      type: 'input:intent',
      revision: 8,
      payload: { intent: 'DOWN' },
    }));
    await waitFor(() => expect(document.documentElement.dataset.sxInput).toBe('gamepad'));
    expect(screen.getByLabelText('Current input: gamepad')).toHaveTextContent('AConfirm');

    fireEvent.keyDown(window, { key: 'a' });
    await waitFor(() => expect(document.documentElement.dataset.sxInput).toBe('keyboard'));
    fireEvent.pointerDown(window);
    await waitFor(() => expect(document.documentElement.dataset.sxInput).toBe('mouse'));

    const devices = fetchMock.mock.calls
      .filter(([url]) => url === 'https://synex_ui/runtime:input')
      .map(([, init]) => (JSON.parse(String((init as RequestInit | undefined)?.body)) as { device: string }).device);
    expect(devices).toEqual(['mouse', 'gamepad', 'keyboard', 'mouse']);
  });
});

describe('gamepad navigation intent mapping', () => {
  it('maps every semantic intent without generating an unrelated action', () => {
    const target = document.createElement('button');
    target.id = 'target';
    target.textContent = 'Target';
    const other = document.createElement('button');
    other.id = 'other';
    other.textContent = 'Other';
    document.body.replaceChildren(target, other);
    const received: string[] = [];
    target.addEventListener('keydown', (event) => {
      received.push(event.key);
      event.preventDefault();
    });
    target.focus();

    for (const intent of ['UP', 'DOWN', 'LEFT', 'RIGHT', 'PAGE_UP', 'PAGE_DOWN', 'BACK'] as const) {
      focusByIntent(intent);
    }
    expect(received).toEqual(['ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight', 'PageUp', 'PageDown', 'Escape']);

    const click = vi.fn();
    target.addEventListener('click', click);
    focusByIntent('CONFIRM');
    expect(click).toHaveBeenCalledTimes(1);

    target.setAttribute('role', 'tab');
    target.setAttribute('aria-selected', 'true');
    focusByIntent('NEXT_TAB');
    focusByIntent('PREVIOUS_TAB');
    expect(received.slice(-2)).toEqual(['ArrowRight', 'ArrowLeft']);
  });
});

describe('open-surface render isolation', () => {
  const baseSurface: RuntimeSurface = {
    requestId: 'request_boundary_01',
    instanceId: 'instance_boundary_01',
    surfaceId: 'surface_boundary_01',
    kind: 'alert',
    title: 'Boundary surface',
    tone: 'neutral',
    dismissible: true,
    fields: [],
    options: [],
    sections: [],
    ownerResource: 'synex_ui_probe',
    ownerEpoch: 1,
    revision: 1,
  };

  it('recovers when the failed top correlation is replaced by a healthy surface', async () => {
    const consoleError = vi.spyOn(console, 'error').mockImplementation(() => undefined);
    const transport = {
      post: vi.fn(async () => ({ ok: true as const })),
      pending: () => 0,
      resourceName: 'synex_ui',
    } as NuiTransport;
    function BrokenSurface(): never { throw new Error('synthetic render failure'); }

    const view = render(
      <OpenSurfaceBoundary open surface={baseSurface} transport={transport} browserBootId="browser_boundary_01">
        <BrokenSurface />
      </OpenSurfaceBoundary>,
    );
    expect(screen.getByRole('alert')).toHaveTextContent('This surface could not be rendered.');

    const restoredSurface = {
      ...baseSurface,
      requestId: 'request_boundary_02',
      instanceId: 'instance_boundary_02',
      surfaceId: 'surface_boundary_02',
      revision: 2,
    };
    view.rerender(
      <OpenSurfaceBoundary open surface={restoredSurface} transport={transport} browserBootId="browser_boundary_01">
        <span>Healthy underlying surface</span>
      </OpenSurfaceBoundary>,
    );
    await waitFor(() => expect(screen.getByText('Healthy underlying surface')).toBeInTheDocument());
    expect(screen.queryByRole('alert')).not.toBeInTheDocument();
    consoleError.mockRestore();
  });
});
