import { act, render, screen, within } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import {
  SIGNAL_EXIT_MS,
  SignalRail,
  SignalSurface,
  resolveVisibleSignalCapacity,
  selectVisibleSignals,
} from '../runtime/src/SignalSurface';
import type { RuntimeSignal } from '../runtime/src/protocol';

function signal(overrides: Partial<RuntimeSignal> = {}): RuntimeSignal {
  return {
    signalId: 'notify.queue',
    revision: 1,
    kind: 'progress',
    tone: 'info',
    priority: 'normal',
    title: 'Queue processing',
    message: 'Assets are being prepared.',
    count: 3,
    progress: { state: 'RUNNING', mode: 'determinate', value: 25, maximum: 100 },
    actions: [{ token: 'cancel', label: 'Cancel', hint: 'B', style: 'danger' }],
    createdAt: 1_725_000_000_000,
    position: 'top-right',
    ownerResource: 'synex_notify',
    ownerEpoch: 7,
    ...overrides,
  };
}

describe('Signal Surface', () => {
  it('renders progress, group count, and passive action hints without controls', () => {
    const { container } = render(<SignalSurface signal={signal()} />);
    const card = screen.getByRole('group', { name: 'Queue processing' });
    expect(card).toHaveTextContent('Queue processing');
    expect(card).toHaveTextContent('\u00d73');
    expect(card).toHaveTextContent('Grouped notification count: 3');
    expect(container.querySelector('.sx-signal-surface__meta')).toBeNull();
    expect(card).toHaveTextContent('Cancel');
    expect(within(card).getByRole('progressbar', { name: 'Queue processing' }))
      .toHaveAttribute('aria-valuenow', '25');
    expect(within(card).getByRole('progressbar', { name: 'Queue processing' }))
      .toHaveAttribute('aria-valuetext', 'Running, 25%');
    expect(card).toHaveTextContent('Running \u00b7 25%');
    expect(within(card).queryByRole('button')).not.toBeInTheDocument();
    expect(container.querySelector('[data-sx-style="danger"]')).toHaveTextContent('Cancel');
    expect(container.querySelector('.sx-signal-locator__index')).toBeNull();
  });

  it('derives default action hints from the central UI input device', () => {
    const withoutHint = signal({
      actions: [{ token: 'cancel', label: 'Cancel', style: 'danger' }],
    });
    const view = render(<SignalSurface signal={withoutHint} inputDevice="keyboard" />);
    expect(screen.getByRole('group', { name: 'Queue processing' })).toHaveTextContent('F9');
    view.rerender(<SignalSurface signal={withoutHint} inputDevice="gamepad" />);
    expect(screen.getByRole('group', { name: 'Queue processing' })).toHaveTextContent('D-pad Left');
    expect(screen.getByRole('group', { name: 'Queue processing' })).not.toHaveTextContent('F9');
  });

  it('exposes terminal indeterminate state without presenting an active value', () => {
    render(<SignalSurface signal={signal({
      signalId: 'failed-progress',
      progress: { state: 'FAILED', mode: 'indeterminate' },
    })} />);
    const progressbar = screen.getByRole('progressbar', { name: 'Queue processing' });
    expect(progressbar).toHaveAttribute('aria-valuetext', 'Failed');
    expect(progressbar).not.toHaveAttribute('aria-valuenow');
    expect(progressbar.closest('.sx-signal-progress')).toHaveAttribute('data-sx-state', 'FAILED');
  });

  it('keeps visual cards out of live regions while retaining their accessible group', () => {
    const { container } = render(<SignalSurface signal={signal({ signalId: 'critical', priority: 'critical' })} />);
    expect(screen.getByRole('group', { name: 'Queue processing' })).toBeInTheDocument();
    expect(container.querySelector('[aria-live], [role="alert"], [role="status"]')).toBeNull();
  });

  it('caps the rail at four signals and prioritizes critical/newer entries', () => {
    const signals = [
      signal({ signalId: 'low-old', priority: 'low', createdAt: 1 }),
      signal({ signalId: 'normal-new', priority: 'normal', createdAt: 5 }),
      signal({ signalId: 'high-old', priority: 'high', createdAt: 2 }),
      signal({ signalId: 'critical-old', priority: 'critical', createdAt: 1 }),
      signal({ signalId: 'high-new', priority: 'high', createdAt: 4 }),
    ];
    expect(selectVisibleSignals(signals).map((entry) => entry.signalId)).toEqual([
      'critical-old', 'high-new', 'high-old', 'normal-new',
    ]);
    const { container } = render(<SignalRail signals={signals} />);
    expect(container.querySelectorAll('[data-sx-signal-id]')).toHaveLength(4);
    expect(container.querySelector('[data-sx-signal-id="low-old"]')).toBeNull();
  });

  it('derives a deterministic capacity from safe viewport, scale, density, and maximum surface size', () => {
    const constrained = {
      width: 1280,
      height: 720,
      aspectRatio: 16 / 9,
      safeLeft: 0,
      safeRight: 0,
      safeTop: 0,
      safeBottom: 0,
    };
    expect(resolveVisibleSignalCapacity(constrained, 125, 'comfortable')).toBe(3);
    expect(resolveVisibleSignalCapacity(constrained, 125, 'compact')).toBe(4);
    expect(resolveVisibleSignalCapacity({ ...constrained, height: 480 }, 100, 'comfortable')).toBe(2);
    expect(resolveVisibleSignalCapacity({
      ...constrained,
      width: 320,
      height: 680,
      aspectRatio: 320 / 680,
    }, 100, 'comfortable')).toBe(3);
    expect(resolveVisibleSignalCapacity({
      ...constrained,
      safeTop: 80,
      safeBottom: 80,
    }, 100, 'comfortable')).toBe(3);
    expect(resolveVisibleSignalCapacity({
      ...constrained,
      width: 320,
      height: 240,
      aspectRatio: 4 / 3,
    }, 100, 'comfortable')).toBe(1);
    expect(resolveVisibleSignalCapacity({
      ...constrained,
      width: 3840,
      height: 2160,
      aspectRatio: 16 / 9,
      safeTop: 100,
      safeBottom: 100,
    }, 125, 'comfortable')).toBe(4);
  });

  it('renders and reports only the responsive capacity while preserving the hard maximum', () => {
    const onVisibleChange = vi.fn();
    const signals = Array.from({ length: 4 }, (_, index) => signal({
      signalId: `adaptive-${index}`,
      createdAt: index,
    }));
    const screenMetrics = {
      width: 1280,
      height: 720,
      aspectRatio: 16 / 9,
      safeLeft: 0,
      safeRight: 0,
      safeTop: 0,
      safeBottom: 0,
    };
    const view = render(<SignalRail
      signals={signals}
      screen={screenMetrics}
      scale={125}
      density="comfortable"
      reducedMotion
      onVisibleChange={onVisibleChange}
    />);
    expect(view.container.querySelectorAll('[data-sx-signal-id]')).toHaveLength(3);
    expect(view.container.querySelector('.sx-signal-rail')).toHaveAttribute('data-sx-capacity', '3');
    expect(onVisibleChange).toHaveBeenLastCalledWith(expect.any(Array), 3);

    view.rerender(<SignalRail
      signals={signals}
      screen={screenMetrics}
      scale={125}
      density="compact"
      reducedMotion
      onVisibleChange={onVisibleChange}
    />);
    expect(view.container.querySelectorAll('[data-sx-signal-id]')).toHaveLength(4);
    expect(onVisibleChange).toHaveBeenLastCalledWith(expect.any(Array), 4);
  });

  it('groups visible signals into position-specific passive rails', () => {
    const { container } = render(<SignalRail signals={[
      signal({ signalId: 'top', title: 'Top signal', position: 'top-right' }),
      signal({ signalId: 'bottom', title: 'Bottom signal', position: 'bottom-center' }),
    ]} />);
    expect(container.querySelector('[data-sx-position="top-right"]')).toHaveTextContent('Top signal');
    expect(container.querySelector('[data-sx-position="bottom-center"]')).toHaveTextContent('Bottom signal');
  });

  it('reports only the exact globally visible signal set', () => {
    const onVisibleChange = vi.fn();
    const signals = [
      signal({ signalId: 'low-hidden', priority: 'low', createdAt: 1 }),
      signal({ signalId: 'normal', priority: 'normal', createdAt: 2 }),
      signal({ signalId: 'high-a', priority: 'high', createdAt: 3 }),
      signal({ signalId: 'high-b', priority: 'high', createdAt: 4 }),
      signal({ signalId: 'critical', priority: 'critical', createdAt: 5 }),
    ];
    render(<SignalRail signals={signals} reducedMotion onVisibleChange={onVisibleChange} />);
    expect(onVisibleChange).toHaveBeenLastCalledWith(expect.arrayContaining([
      expect.objectContaining({ signalId: 'critical' }),
      expect.objectContaining({ signalId: 'high-a' }),
      expect.objectContaining({ signalId: 'high-b' }),
      expect.objectContaining({ signalId: 'normal' }),
    ]), 4);
    const reported = onVisibleChange.mock.lastCall?.[0] as RuntimeSignal[];
    expect(reported).toHaveLength(4);
    expect(reported.some((entry) => entry.signalId === 'low-hidden')).toBe(false);
  });

  it('reports active presentation phases instead of the planned replacement during exit', () => {
    vi.useFakeTimers();
    try {
      const onVisibleChange = vi.fn();
      const initial = [
        signal({ signalId: 'critical', priority: 'critical', createdAt: 4 }),
        signal({ signalId: 'high', priority: 'high', createdAt: 3 }),
        signal({ signalId: 'normal', priority: 'normal', createdAt: 2 }),
        signal({ signalId: 'low', priority: 'low', createdAt: 1 }),
      ];
      const replacement = signal({ signalId: 'replacement', priority: 'low', createdAt: 0 });
      const view = render(
        <SignalRail signals={initial} onVisibleChange={onVisibleChange} />,
      );

      view.rerender(
        <SignalRail signals={[...initial.slice(1), replacement]} onVisibleChange={onVisibleChange} />,
      );

      expect(view.container.querySelector('[data-sx-signal-id="critical"]'))
        .toHaveAttribute('data-sx-phase', 'dismissing');
      let reported = onVisibleChange.mock.lastCall?.[0] as RuntimeSignal[];
      expect(reported.map((entry) => entry.signalId)).toEqual(['high', 'normal', 'low']);
      expect(reported.some((entry) => entry.signalId === 'replacement')).toBe(false);

      act(() => vi.advanceTimersByTime(SIGNAL_EXIT_MS - 1));
      reported = onVisibleChange.mock.lastCall?.[0] as RuntimeSignal[];
      expect(reported.map((entry) => entry.signalId)).toEqual(['high', 'normal', 'low']);

      act(() => vi.advanceTimersByTime(1));
      reported = onVisibleChange.mock.lastCall?.[0] as RuntimeSignal[];
      expect(reported.map((entry) => entry.signalId)).toEqual([
        'high', 'normal', 'low', 'replacement',
      ]);
      expect(view.container.querySelector('[data-sx-signal-id="critical"]')).toBeNull();
      expect(view.container.querySelector('[data-sx-signal-id="replacement"]'))
        .toHaveAttribute('data-sx-phase', 'active');
    } finally {
      vi.useRealTimers();
    }
  });

  it('retains a removed signal for the bounded dismiss transition', () => {
    vi.useFakeTimers();
    try {
      expect(SIGNAL_EXIT_MS).toBe(140);
      const view = render(<SignalRail signals={[signal()]} />);
      view.rerender(<SignalRail signals={[]} />);
      expect(view.container.querySelector('[data-sx-phase="dismissing"]')).toBeInTheDocument();
      act(() => vi.advanceTimersByTime(SIGNAL_EXIT_MS - 1));
      expect(screen.getByRole('group', { name: 'Queue processing' })).toBeInTheDocument();
      act(() => vi.advanceTimersByTime(1));
      expect(screen.queryByRole('group', { name: 'Queue processing' })).not.toBeInTheDocument();
    } finally {
      vi.useRealTimers();
    }
  });

  it('cancels an exit race when the same signal returns before 140 ms', () => {
    vi.useFakeTimers();
    try {
      const view = render(<SignalRail signals={[signal()]} />);
      view.rerender(<SignalRail signals={[]} />);
      expect(view.container.querySelector('[data-sx-phase="dismissing"]')).toBeInTheDocument();

      act(() => vi.advanceTimersByTime(SIGNAL_EXIT_MS - 1));
      view.rerender(<SignalRail signals={[signal({ revision: 2, title: 'Queue resumed' })]} />);
      expect(view.container.querySelector('[data-sx-signal-id="notify.queue"]'))
        .toHaveAttribute('data-sx-phase', 'active');

      act(() => vi.advanceTimersByTime(SIGNAL_EXIT_MS));
      expect(screen.getByRole('group', { name: 'Queue resumed' })).toHaveTextContent('Queue resumed');
      expect(view.container.querySelector('[data-sx-phase="dismissing"]')).toBeNull();
    } finally {
      vi.useRealTimers();
    }
  });

  it('removes immediately when reduced motion is active', () => {
    const view = render(<SignalRail signals={[signal()]} reducedMotion />);
    view.rerender(<SignalRail signals={[]} reducedMotion />);
    expect(screen.queryByRole('group', { name: 'Queue processing' })).not.toBeInTheDocument();
  });
});
