import { useEffect, useRef, useState } from 'react';
import type { RuntimeSignal, SignalPriority } from './protocol';

export const SIGNAL_ANNOUNCEMENT_COALESCE_MS = 120;
export const SIGNAL_ANNOUNCEMENT_HOLD_MS = 800;
export const SIGNAL_ANNOUNCEMENT_GAP_MS = 80;
export const SIGNAL_ANNOUNCEMENT_MAX_PENDING = 32;
export const SIGNAL_ANNOUNCEMENT_MAX_HISTORY = 64;

const priorityWeight: Record<SignalPriority, number> = {
  low: 0,
  normal: 1,
  high: 2,
  critical: 3,
};

const progressStateLabel = {
  PENDING: 'Pending',
  RUNNING: 'Running',
  SUCCESS: 'Complete',
  FAILED: 'Failed',
  CANCELLED: 'Cancelled',
} as const;

const terminalPunctuation = /[.!?]$/u;

interface AnnouncementCandidate {
  key: string;
  revision: number;
  priority: SignalPriority;
  politeness: 'polite' | 'assertive';
  text: string;
  signature: string;
  sequence: number;
  readyAt: number;
}

interface DeliveredAnnouncement {
  revision: number;
  signature: string;
}

interface ActiveAnnouncement {
  politeness: AnnouncementCandidate['politeness'];
  sequence: number;
  text: string;
}

function signalIdentity(signal: RuntimeSignal): string {
  return `${signal.ownerResource}\u0000${signal.ownerEpoch}\u0000${signal.signalId}`;
}

function progressAnnouncement(signal: RuntimeSignal): string | undefined {
  const progress = signal.progress;
  if (!progress) return undefined;
  const state = progressStateLabel[progress.state];
  if (progress.mode !== 'determinate' || progress.value === undefined || progress.maximum === undefined) {
    return state;
  }
  return `${state}, ${Math.round((progress.value / progress.maximum) * 100)}%`;
}

/** Creates plain text only; React escapes caller content before it reaches either live region. */
export function signalAnnouncementText(signal: RuntimeSignal): string {
  const parts = [signal.title];
  if (signal.message) parts.push(signal.message);
  if (signal.count && signal.count > 1) parts.push(`Grouped notification count: ${signal.count}`);
  const progress = progressAnnouncement(signal);
  if (progress) parts.push(progress);
  if (signal.actions.length === 1) parts.push(`Action: ${signal.actions[0]?.label ?? ''}`);
  if (signal.actions.length > 1) parts.push(`Actions: ${signal.actions.map((action) => action.label).join('; ')}`);
  return parts.map((part) => terminalPunctuation.test(part) ? part : `${part}.`).join(' ');
}

function compareAnnouncements(left: AnnouncementCandidate, right: AnnouncementCandidate): number {
  const priority = priorityWeight[right.priority] - priorityWeight[left.priority];
  return priority !== 0 ? priority : left.sequence - right.sequence;
}

class SignalAnnouncementController {
  private active = false;
  private activeKeys = new Set<string>();
  private current: AnnouncementCandidate | null = null;
  private delivered = new Map<string, DeliveredAnnouncement>();
  private flushTimer: ReturnType<typeof setTimeout> | undefined;
  private playbackTimer: ReturnType<typeof setTimeout> | undefined;
  private queue: AnnouncementCandidate[] = [];
  private sequence = 0;
  private staged = new Map<string, AnnouncementCandidate>();

  constructor(private readonly publish: (announcement: ActiveAnnouncement | null) => void) {}

  start() {
    this.active = true;
    this.publish(null);
  }

  stop() {
    this.active = false;
    if (this.flushTimer !== undefined) clearTimeout(this.flushTimer);
    if (this.playbackTimer !== undefined) clearTimeout(this.playbackTimer);
    this.flushTimer = undefined;
    this.playbackTimer = undefined;
    this.activeKeys.clear();
    this.current = null;
    this.delivered.clear();
    this.queue = [];
    this.sequence = 0;
    this.staged.clear();
  }

  reconcile(signals: readonly RuntimeSignal[]) {
    if (!this.active) return;
    const newestByKey = new Map<string, RuntimeSignal>();
    for (const signal of signals) {
      const key = signalIdentity(signal);
      const existing = newestByKey.get(key);
      if (!existing || signal.revision > existing.revision) newestByKey.set(key, signal);
    }

    this.activeKeys = new Set(newestByKey.keys());
    for (const key of this.staged.keys()) {
      if (!this.activeKeys.has(key)) this.staged.delete(key);
    }
    this.queue = this.queue.filter((entry) => this.activeKeys.has(entry.key));

    for (const [key, signal] of newestByKey) {
      this.reconcileSignal(key, signal);
    }
    this.queue.sort(compareAnnouncements);
    this.scheduleFlush();
    this.pump();
  }

  private reconcileSignal(key: string, signal: RuntimeSignal) {
    const text = signalAnnouncementText(signal);
    const politeness = signal.priority === 'critical' ? 'assertive' : 'polite';
    const signature = `${politeness}\u0000${text}`;
    if (this.current?.key === key
      && this.current.revision >= signal.revision
      && this.current.signature === signature) return;

    const staged = this.staged.get(key);
    if (staged) {
      if (signal.revision < staged.revision) return;
      this.staged.set(key, {
        ...staged,
        revision: signal.revision,
        priority: signal.priority,
        politeness,
        text,
        signature,
      });
      return;
    }

    const queuedIndex = this.queue.findIndex((entry) => entry.key === key);
    if (queuedIndex >= 0) {
      const queued = this.queue[queuedIndex];
      if (!queued || signal.revision < queued.revision) return;
      this.queue[queuedIndex] = {
        ...queued,
        revision: signal.revision,
        priority: signal.priority,
        politeness,
        text,
        signature,
      };
      return;
    }

    const delivered = this.delivered.get(key);
    if (delivered && signal.revision < delivered.revision) return;
    if (delivered?.signature === signature) {
      if (signal.revision > delivered.revision) this.rememberDelivered(key, signal.revision, signature);
      return;
    }

    const candidate: AnnouncementCandidate = {
      key,
      revision: signal.revision,
      priority: signal.priority,
      politeness,
      text,
      signature,
      sequence: ++this.sequence,
      readyAt: Date.now() + SIGNAL_ANNOUNCEMENT_COALESCE_MS,
    };
    this.admit(candidate);
  }

  private admit(candidate: AnnouncementCandidate) {
    if (this.staged.size + this.queue.length < SIGNAL_ANNOUNCEMENT_MAX_PENDING) {
      this.staged.set(candidate.key, candidate);
      return;
    }

    const pending = [...this.staged.values(), ...this.queue];
    pending.sort((left, right) => {
      const priority = priorityWeight[left.priority] - priorityWeight[right.priority];
      return priority !== 0 ? priority : right.sequence - left.sequence;
    });
    const replace = pending[0];
    if (!replace || priorityWeight[candidate.priority] <= priorityWeight[replace.priority]) return;
    if (this.staged.delete(replace.key)) {
      this.staged.set(candidate.key, candidate);
      return;
    }
    this.queue = this.queue.filter((entry) => entry !== replace);
    this.staged.set(candidate.key, candidate);
  }

  private scheduleFlush() {
    if (this.flushTimer !== undefined) clearTimeout(this.flushTimer);
    this.flushTimer = undefined;
    if (!this.active || this.staged.size === 0) return;
    let earliest = Number.POSITIVE_INFINITY;
    for (const entry of this.staged.values()) earliest = Math.min(earliest, entry.readyAt);
    this.flushTimer = setTimeout(() => {
      this.flushTimer = undefined;
      this.flushReady();
    }, Math.max(0, earliest - Date.now()));
  }

  private flushReady() {
    if (!this.active) return;
    const now = Date.now();
    for (const [key, entry] of this.staged) {
      if (entry.readyAt > now) continue;
      this.staged.delete(key);
      if (this.activeKeys.has(key)) this.queue.push(entry);
    }
    this.queue.sort(compareAnnouncements);
    this.scheduleFlush();
    this.pump();
  }

  private pump() {
    if (!this.active || this.current || this.playbackTimer !== undefined) return;
    let next = this.queue.shift();
    while (next && !this.activeKeys.has(next.key)) next = this.queue.shift();
    if (!next) return;

    this.current = next;
    this.rememberDelivered(next.key, next.revision, next.signature);
    this.publish({ politeness: next.politeness, sequence: next.sequence, text: next.text });
    this.playbackTimer = setTimeout(() => {
      this.playbackTimer = undefined;
      this.current = null;
      if (!this.active) return;
      this.publish(null);
      this.playbackTimer = setTimeout(() => {
        this.playbackTimer = undefined;
        this.pump();
      }, SIGNAL_ANNOUNCEMENT_GAP_MS);
    }, SIGNAL_ANNOUNCEMENT_HOLD_MS);
  }

  private rememberDelivered(key: string, revision: number, signature: string) {
    this.delivered.delete(key);
    this.delivered.set(key, { revision, signature });
    while (this.delivered.size > SIGNAL_ANNOUNCEMENT_MAX_HISTORY) {
      const oldest = this.delivered.keys().next().value as string | undefined;
      if (oldest === undefined) break;
      this.delivered.delete(oldest);
    }
  }
}

export function SignalAnnouncer({ signals }: { signals: readonly RuntimeSignal[] }) {
  const [announcement, setAnnouncement] = useState<ActiveAnnouncement | null>(null);
  const controllerRef = useRef<SignalAnnouncementController | null>(null);
  if (controllerRef.current === null) {
    controllerRef.current = new SignalAnnouncementController(setAnnouncement);
  }
  const controller = controllerRef.current;

  useEffect(() => {
    controller.start();
    return () => controller.stop();
  }, [controller]);

  useEffect(() => {
    controller.reconcile(signals);
  }, [controller, signals]);

  return (
    <div className="sx-visually-hidden" data-sx-signal-announcer="true">
      <div
        role="status"
        aria-live="polite"
        aria-atomic="true"
        data-sx-announcement-sequence={announcement?.politeness === 'polite' ? announcement.sequence : undefined}
      >
        {announcement?.politeness === 'polite' ? announcement.text : ''}
      </div>
      <div
        role="alert"
        aria-live="assertive"
        aria-atomic="true"
        data-sx-announcement-sequence={announcement?.politeness === 'assertive' ? announcement.sequence : undefined}
      >
        {announcement?.politeness === 'assertive' ? announcement.text : ''}
      </div>
    </div>
  );
}
