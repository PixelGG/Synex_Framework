import { fireEvent, render, screen, waitFor } from '@testing-library/react';
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

describe('shared runtime browser lifecycle', () => {
  beforeEach(() => {
    document.documentElement.removeAttribute('data-sx-quality');
    document.body.removeAttribute('data-sx-open');
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
