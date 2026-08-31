import { act, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import {
  InteractionSurface,
  containInteractionOffset,
  resolveInteractionPoint,
  stabilizeInteractionPoint,
} from '../runtime/src/InteractionSurface';
import type { RuntimeInteraction, ScreenMetrics } from '../runtime/src/protocol';
import type { NuiTransport } from '../runtime/src/transport';

const testScreen: ScreenMetrics = {
  width: 1920,
  height: 1080,
  aspectRatio: 16 / 9,
  safeLeft: 24,
  safeRight: 24,
  safeTop: 12,
  safeBottom: 12,
};

const cue: RuntimeInteraction = {
  interactionId: 'vehicle.trunk.open',
  revision: 3,
  mode: 'cue',
  label: 'Open trunk',
  targetLabel: 'Sultan RS',
  projection: { visible: true, behindCamera: false, x: 0.5, y: 0.62 },
  intents: [{ intentId: 'trunk.open', label: 'Open trunk' }],
  selectedIntentId: 'trunk.open',
  moreCount: 3,
  pointer: false,
  input: {
    primary: { keyboard: 'E', gamepad: 'A' },
    more: { keyboard: 'Left Alt', gamepad: 'D-pad Up' },
  },
  cancellable: false,
  ownerResource: 'synex_interact',
  ownerEpoch: 5,
};

function transport(response: { ok: true; data?: unknown } | { ok: false; error: { code: 'UI_REQUEST_STALE' } } = { ok: true }) {
  return {
    post: vi.fn(async () => response),
    pending: () => 0,
    resourceName: 'synex_ui',
  } as unknown as NuiTransport;
}

function renderInteraction(
  interaction: RuntimeInteraction,
  options: { inputDevice?: 'keyboard' | 'mouse' | 'gamepad'; assist?: boolean; transport?: NuiTransport } = {},
) {
  const nuiTransport = options.transport ?? transport();
  const view = render(
    <InteractionSurface
      interaction={interaction}
      inputDevice={options.inputDevice ?? 'keyboard'}
      screen={testScreen}
      reducedMotion={false}
      interactionAssist={options.assist ?? false}
      transport={nuiTransport}
      browserBootId="ui_interaction_test"
    />,
  );
  return { ...view, nuiTransport };
}

describe('interaction projection', () => {
  it('hides behind-camera and explicitly invisible targets', () => {
    expect(resolveInteractionPoint({ visible: false, behindCamera: false, x: 0.5, y: 0.5 }, testScreen)).toBeNull();
    expect(resolveInteractionPoint({ visible: true, behindCamera: true, x: 0.5, y: 0.5 }, testScreen)).toBeNull();
  });

  it('keeps projected cues inside safe screen bounds', () => {
    expect(resolveInteractionPoint({ visible: true, behindCamera: false, x: 0, y: 1 }, testScreen)).toEqual({
      x: 44,
      y: 1048,
    });
  });

  it('uses a dead zone, bounded smoothing, and an immediate reduced-motion path', () => {
    const previous = { x: 500, y: 500 };
    expect(stabilizeInteractionPoint(previous, { x: 501, y: 501 })).toBe(previous);
    expect(stabilizeInteractionPoint(previous, { x: 600, y: 500 })).toEqual({ x: 534, y: 500 });
    expect(stabilizeInteractionPoint(previous, { x: 600, y: 500 }, true)).toEqual({ x: 600, y: 500 });
  });

  it('contains the complete rendered surface inside safe screen edges', () => {
    expect(containInteractionOffset({
      left: -132,
      right: 220,
      top: -30,
      bottom: 50,
      width: 352,
      height: 80,
    }, { x: 0, y: 0 }, testScreen)).toEqual({ x: 176, y: 62 });
    expect(containInteractionOffset({
      left: 700,
      right: 1_052,
      top: 980,
      bottom: 1_060,
      width: 352,
      height: 80,
    }, { x: 0, y: 0 }, testScreen)).toEqual({ x: 0, y: -12 });
  });
});

describe('interaction surface', () => {
  it('renders a passive, input-aware cue without focusable controls', () => {
    const { container } = renderInteraction(cue, { inputDevice: 'gamepad', assist: true });
    expect(screen.getByText('Open trunk')).toBeInTheDocument();
    expect(screen.getByText('Sultan RS')).toBeInTheDocument();
    expect(screen.getByText('A')).toBeInTheDocument();
    expect(screen.getByText('D-pad Up')).toBeInTheDocument();
    expect(screen.getByText('+3')).toBeInTheDocument();
    expect(container.querySelector('button, [tabindex]')).toBeNull();
    expect(container.querySelector('.sx-interaction')).toHaveAttribute('data-sx-pointer', 'false');
    expect(container.querySelector('.sx-interaction')).toHaveAttribute('data-sx-assist', 'true');
  });

  it('hides a cue when the target projection moves behind the camera', () => {
    const hidden = { ...cue, projection: { visible: true, behindCamera: true, x: 0.5, y: 0.5 } };
    const { container } = renderInteraction(hidden);
    expect(container).toBeEmptyDOMElement();
  });

  it('renders passive timed progress without taking pointer or keyboard focus', () => {
    const progress: RuntimeInteraction = {
      interactionId: 'vehicle.repair.progress',
      revision: 7,
      mode: 'progress',
      label: 'Repairing vehicle',
      intents: [],
      pointer: false,
      input: { cancel: { keyboard: 'X', gamepad: 'B' } },
      progress: { mode: 'timed', elapsedMs: 1_000, durationMs: 4_000 },
      cancellable: true,
      ownerResource: 'synex_interact',
      ownerEpoch: 5,
    };
    const { container } = renderInteraction(progress);
    expect(screen.getByRole('progressbar')).toHaveAttribute('aria-valuenow', '25');
    expect(screen.getByText('25%')).toBeInTheDocument();
    expect(screen.getByText('X')).toBeInTheDocument();
    expect(container.querySelector('button, [tabindex]')).toBeNull();
  });

  it('advances timed progress monotonically, caps at completion, and releases its timer', () => {
    vi.useFakeTimers();
    try {
      const progress: RuntimeInteraction = {
        interactionId: 'vehicle.repair.timer',
        revision: 8,
        mode: 'progress',
        label: 'Repairing vehicle',
        intents: [],
        pointer: false,
        input: {},
        progress: { mode: 'timed', elapsedMs: 100, durationMs: 1_000 },
        cancellable: false,
        ownerResource: 'synex_interact',
        ownerEpoch: 5,
      };
      const view = renderInteraction(progress);
      expect(screen.getByRole('progressbar')).toHaveAttribute('aria-valuenow', '10');
      act(() => vi.advanceTimersByTime(400));
      expect(screen.getByRole('progressbar')).toHaveAttribute('aria-valuenow', '50');
      vi.setSystemTime(new Date(0));
      act(() => vi.advanceTimersByTime(1_500));
      expect(screen.getByRole('progressbar')).toHaveAttribute('aria-valuenow', '100');
      expect(vi.getTimerCount()).toBe(0);
      view.unmount();
      expect(vi.getTimerCount()).toBe(0);
    } finally {
      vi.useRealTimers();
    }
  });

  it('releases an active timed-progress timer when the surface unmounts early', () => {
    vi.useFakeTimers();
    try {
      const progress: RuntimeInteraction = {
        interactionId: 'vehicle.repair.aborted',
        revision: 9,
        mode: 'progress',
        label: 'Repairing vehicle',
        intents: [],
        pointer: false,
        input: {},
        progress: { mode: 'timed', elapsedMs: 0, durationMs: 10_000 },
        cancellable: true,
        ownerResource: 'synex_interact',
        ownerEpoch: 5,
      };
      const view = renderInteraction(progress);
      expect(vi.getTimerCount()).toBe(1);
      view.unmount();
      expect(vi.getTimerCount()).toBe(0);
    } finally {
      vi.useRealTimers();
    }
  });

  it('renders declared determinate value and maximum without inventing time progress', () => {
    const progress: RuntimeInteraction = {
      interactionId: 'terminal.scan.progress',
      revision: 8,
      mode: 'progress',
      label: 'Scanning records',
      intents: [],
      pointer: false,
      input: {},
      progress: { mode: 'determinate', value: 7, maximum: 20 },
      cancellable: false,
      ownerResource: 'synex_interact',
      ownerEpoch: 5,
    };
    renderInteraction(progress);
    expect(screen.getByRole('progressbar')).toHaveAttribute('aria-valuenow', '35');
    expect(screen.getByText('35%')).toBeInTheDocument();
  });

  it('renders a 2–6 intent bloom and posts only the selected intent through the fixed route', async () => {
    const bloom: RuntimeInteraction = {
      interactionId: 'vehicle.actions',
      revision: 9,
      mode: 'bloom',
      label: 'Vehicle actions',
      targetLabel: 'Sultan RS',
      intents: [
        { intentId: 'trunk.open', label: 'Open trunk' },
        { intentId: 'vehicle.inspect', label: 'Inspect' },
        { intentId: 'vehicle.repair', label: 'Repair', disabled: true },
      ],
      selectedIntentId: 'trunk.open',
      pointer: true,
      input: {
        primary: { keyboard: 'Enter', gamepad: 'A', mouse: 'Left Click' },
        cancel: { keyboard: 'Esc', gamepad: 'B', mouse: 'Right Click' },
      },
      cancellable: true,
      ownerResource: 'synex_interact',
      ownerEpoch: 5,
    };
    const nuiTransport = transport();
    renderInteraction(bloom, { inputDevice: 'mouse', transport: nuiTransport });
    expect(screen.getAllByRole('menuitem')).toHaveLength(3);
    expect(screen.getByRole('menuitem', { name: 'Repair' })).toBeDisabled();
    expect(screen.getByText('Left Click')).toBeInTheDocument();
    const inspect = screen.getByRole('menuitem', { name: 'Inspect' });
    fireEvent.click(inspect);
    fireEvent.click(inspect);
    await waitFor(() => expect(nuiTransport.post).toHaveBeenCalledWith('runtime:interaction', {
      requestId: 'interaction_9',
      browserBootId: 'ui_interaction_test',
      interactionId: 'vehicle.actions',
      ownerEpoch: 5,
      revision: 9,
      action: 'activate',
      device: 'mouse',
      intentId: 'vehicle.inspect',
    }));
    expect(nuiTransport.post).toHaveBeenCalledTimes(1);
  });

  it('maps pointer cancellation to the fixed interaction callback without exposing a domain action', async () => {
    const bloom = {
      ...cue,
      interactionId: 'vehicle.actions.cancel',
      revision: 10,
      mode: 'bloom' as const,
      intents: [
        { intentId: 'trunk.open', label: 'Open trunk' },
        { intentId: 'vehicle.inspect', label: 'Inspect' },
      ],
      selectedIntentId: 'trunk.open',
      moreCount: undefined,
      pointer: true,
      input: {
        primary: { keyboard: 'Enter', gamepad: 'A', mouse: 'Left Click' },
        cancel: { keyboard: 'Esc', gamepad: 'B', mouse: 'Right Click' },
      },
      cancellable: true,
    } satisfies RuntimeInteraction;
    const nuiTransport = transport();
    renderInteraction(bloom, { inputDevice: 'mouse', transport: nuiTransport });
    fireEvent.contextMenu(screen.getByRole('menu'));
    await waitFor(() => expect(nuiTransport.post).toHaveBeenCalledWith('runtime:interaction', {
      requestId: 'interaction_10',
      browserBootId: 'ui_interaction_test',
      interactionId: 'vehicle.actions.cancel',
      ownerEpoch: 5,
      revision: 10,
      action: 'cancel',
      device: 'mouse',
    }));
  });

  it('uses roving keyboard focus, skips disabled intents, and activates only the focused intent', async () => {
    const bloom: RuntimeInteraction = {
      interactionId: 'vehicle.actions.keyboard',
      revision: 11,
      mode: 'bloom',
      label: 'Vehicle actions',
      intents: [
        { intentId: 'trunk.open', label: 'Open trunk' },
        { intentId: 'vehicle.repair', label: 'Repair', disabled: true },
        { intentId: 'vehicle.inspect', label: 'Inspect' },
      ],
      selectedIntentId: 'trunk.open',
      pointer: true,
      input: {
        primary: { keyboard: 'Enter', gamepad: 'Confirm', mouse: 'Left click' },
        cancel: { keyboard: 'Esc', gamepad: 'Back', mouse: 'Right click' },
      },
      cancellable: true,
      ownerResource: 'synex_interact',
      ownerEpoch: 5,
    };
    const nuiTransport = transport();
    renderInteraction(bloom, { transport: nuiTransport });
    const menu = screen.getByRole('menu');
    const open = screen.getByRole('menuitem', { name: 'Open trunk' });
    const inspect = screen.getByRole('menuitem', { name: 'Inspect' });
    expect(open).toHaveFocus();
    expect(open).toHaveAttribute('tabindex', '0');

    fireEvent.keyDown(menu, { key: 'ArrowDown' });
    expect(inspect).toHaveFocus();
    expect(screen.getByRole('menuitem', { name: 'Repair' })).toBeDisabled();
    fireEvent.keyDown(menu, { key: 'Home' });
    expect(open).toHaveFocus();
    fireEvent.keyDown(menu, { key: 'w' });
    expect(inspect).toHaveFocus();
    fireEvent.keyDown(menu, { key: 'End' });
    fireEvent.keyDown(menu, { key: 'Enter' });

    await waitFor(() => expect(nuiTransport.post).toHaveBeenCalledWith('runtime:interaction', {
      requestId: 'interaction_11',
      browserBootId: 'ui_interaction_test',
      interactionId: 'vehicle.actions.keyboard',
      ownerEpoch: 5,
      revision: 11,
      action: 'activate',
      device: 'keyboard',
      intentId: 'vehicle.inspect',
    }));
    expect(nuiTransport.post).toHaveBeenCalledTimes(1);
  });

  it('keeps a non-pointer bloom display-only while exposing selected and disabled state without color alone', () => {
    const bloom = {
      ...cue,
      mode: 'bloom' as const,
      label: 'Relevant actions',
      intents: [
        { intentId: 'trunk.open', label: 'Open trunk' },
        { intentId: 'vehicle.inspect', label: 'Inspect', disabled: true },
      ],
      selectedIntentId: 'trunk.open',
      moreCount: undefined,
      input: {
        primary: { keyboard: 'Enter', gamepad: 'A' },
        cancel: { keyboard: 'Esc', gamepad: 'B' },
      },
      cancellable: true,
    } satisfies RuntimeInteraction;
    const { container } = renderInteraction(bloom);
    expect(screen.getAllByRole('listitem')).toHaveLength(2);
    expect(screen.getByText('Inspect').closest('[role="listitem"]')).toHaveAttribute('aria-disabled', 'true');
    expect(screen.getByText('Open trunk').closest('[role="listitem"]')).toHaveAttribute('aria-current', 'true');
    expect(container.querySelector('button, [tabindex]')).toBeNull();
  });
});
