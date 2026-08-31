import { act, render, screen } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import {
  SIGNAL_ANNOUNCEMENT_COALESCE_MS,
  SIGNAL_ANNOUNCEMENT_GAP_MS,
  SIGNAL_ANNOUNCEMENT_HOLD_MS,
  SIGNAL_ANNOUNCEMENT_MAX_HISTORY,
  SIGNAL_ANNOUNCEMENT_MAX_PENDING,
  SignalAnnouncer,
} from '../runtime/src/signalAnnouncements';
import type { RuntimeSignal } from '../runtime/src/protocol';

function signal(overrides: Partial<RuntimeSignal> = {}): RuntimeSignal {
  return {
    signalId: 'notify.announcement',
    revision: 1,
    kind: 'toast',
    tone: 'info',
    priority: 'normal',
    title: 'Framework ready',
    message: 'The runtime can accept work.',
    actions: [],
    createdAt: 1_725_000_000_000,
    position: 'top-right',
    ownerResource: 'synex_notify',
    ownerEpoch: 7,
    ...overrides,
  };
}

function advance(milliseconds: number) {
  act(() => vi.advanceTimersByTime(milliseconds));
}

describe('Signal announcement queue', () => {
  afterEach(() => {
    vi.useRealTimers();
  });

  it('serializes polite announcements by priority and preserves FIFO order within a priority', () => {
    vi.useFakeTimers();
    render(<SignalAnnouncer signals={[
      signal({ signalId: 'normal-first', title: 'Normal first' }),
      signal({ signalId: 'high', title: 'High priority', priority: 'high' }),
      signal({ signalId: 'normal-second', title: 'Normal second' }),
    ]} />);

    const polite = screen.getByRole('status');
    expect(polite).toHaveAttribute('aria-live', 'polite');
    expect(polite).toBeEmptyDOMElement();
    advance(SIGNAL_ANNOUNCEMENT_COALESCE_MS);
    expect(polite).toHaveTextContent('High priority');

    advance(SIGNAL_ANNOUNCEMENT_HOLD_MS);
    expect(polite).toBeEmptyDOMElement();
    advance(SIGNAL_ANNOUNCEMENT_GAP_MS);
    expect(polite).toHaveTextContent('Normal first');

    advance(SIGNAL_ANNOUNCEMENT_HOLD_MS + SIGNAL_ANNOUNCEMENT_GAP_MS);
    expect(polite).toHaveTextContent('Normal second');
  });

  it('coalesces a grouped burst inside one anchored bounded window', () => {
    vi.useFakeTimers();
    const view = render(<SignalAnnouncer signals={[signal({ count: 2 })]} />);
    advance(40);
    view.rerender(<SignalAnnouncer signals={[signal({ revision: 2, count: 8 })]} />);
    advance(40);
    view.rerender(<SignalAnnouncer signals={[signal({ revision: 3, count: 20 })]} />);
    advance(39);
    expect(screen.getByRole('status')).toBeEmptyDOMElement();
    advance(1);
    expect(screen.getByRole('status')).toHaveTextContent('Grouped notification count: 20');
    expect(screen.getByRole('status')).not.toHaveTextContent('count: 2.');
    expect(screen.getByRole('status')).not.toHaveTextContent('count: 8.');
  });

  it('announces a critical signal assertively before queued normal signals without dropping them', () => {
    vi.useFakeTimers();
    render(<SignalAnnouncer signals={[
      signal({ signalId: 'normal-a', title: 'Normal A' }),
      signal({ signalId: 'normal-b', title: 'Normal B' }),
      signal({ signalId: 'critical', title: '<strong>Critical</strong>', priority: 'critical' }),
    ]} />);
    const activeBefore = document.activeElement;

    advance(SIGNAL_ANNOUNCEMENT_COALESCE_MS);
    const assertive = screen.getByRole('alert');
    expect(assertive).toHaveAttribute('aria-live', 'assertive');
    expect(assertive).toHaveTextContent('<strong>Critical</strong>');
    expect(assertive.querySelector('strong')).toBeNull();
    expect(screen.getByRole('status')).toBeEmptyDOMElement();
    expect(document.activeElement).toBe(activeBefore);

    advance(SIGNAL_ANNOUNCEMENT_HOLD_MS + SIGNAL_ANNOUNCEMENT_GAP_MS);
    expect(assertive).toBeEmptyDOMElement();
    expect(screen.getByRole('status')).toHaveTextContent('Normal A');
    advance(SIGNAL_ANNOUNCEMENT_HOLD_MS + SIGNAL_ANNOUNCEMENT_GAP_MS);
    expect(screen.getByRole('status')).toHaveTextContent('Normal B');
  });

  it('does not announce an unchanged projection twice, even at a newer revision', () => {
    vi.useFakeTimers();
    const initial = signal();
    const view = render(<SignalAnnouncer signals={[initial]} />);
    advance(SIGNAL_ANNOUNCEMENT_COALESCE_MS);
    const polite = screen.getByRole('status');
    expect(polite).toHaveAttribute('data-sx-announcement-sequence', '1');
    advance(SIGNAL_ANNOUNCEMENT_HOLD_MS + SIGNAL_ANNOUNCEMENT_GAP_MS);
    expect(polite).toBeEmptyDOMElement();

    view.rerender(<SignalAnnouncer signals={[{ ...initial, revision: 2 }]} />);
    advance(SIGNAL_ANNOUNCEMENT_COALESCE_MS + SIGNAL_ANNOUNCEMENT_HOLD_MS + SIGNAL_ANNOUNCEMENT_GAP_MS);
    expect(polite).toBeEmptyDOMElement();
    expect(polite).not.toHaveAttribute('data-sx-announcement-sequence');
    expect(vi.getTimerCount()).toBe(0);
  });

  it('cleans its bounded queue and timers on unmount', () => {
    vi.useFakeTimers();
    expect(SIGNAL_ANNOUNCEMENT_MAX_PENDING).toBe(32);
    expect(SIGNAL_ANNOUNCEMENT_MAX_HISTORY).toBe(64);
    const view = render(<SignalAnnouncer signals={Array.from({ length: 40 }, (_, index) => signal({
      signalId: `bounded-${index}`,
      title: `Bounded ${index}`,
    }))} />);
    expect(vi.getTimerCount()).toBe(1);
    advance(SIGNAL_ANNOUNCEMENT_COALESCE_MS);
    expect(vi.getTimerCount()).toBe(1);
    view.unmount();
    expect(vi.getTimerCount()).toBe(0);
  });
});
