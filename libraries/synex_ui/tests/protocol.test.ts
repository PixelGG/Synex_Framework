import { describe, expect, it } from 'vitest';
import {
  UI_LIMITS,
  createBrowserBootId,
  isBoundedPayload,
  parseGameEnvelope,
  parseInteractionDescriptor,
  parseSignalDescriptor,
  parseSignalSoundPayload,
  parseSurfaceDescriptor,
} from '../runtime/src/protocol';

const descriptor = {
  requestId: 'request_restart_01',
  instanceId: 'instance_restart_01',
  surfaceId: 'confirm_restart',
  kind: 'confirm',
  title: 'Restart resource?',
  description: '<script>alert(1)</script> is rendered as ordinary text.',
  tone: 'warning',
  dismissible: true,
  confirmLabel: 'Restart',
  cancelLabel: 'Keep running',
};

const signalDescriptor = {
  signalId: 'notify.download',
  revision: 3,
  kind: 'progress',
  tone: 'info',
  priority: 'normal',
  title: 'Downloading vehicle assets',
  message: '12 of 20 bundles are ready.',
  iconKey: 'signal',
  count: 2,
  progress: { state: 'RUNNING', mode: 'determinate', value: 12, maximum: 20 },
  actions: [{ token: 'cancel', label: 'Cancel', hint: 'B', style: 'danger' }],
  createdAt: 1_725_000_000_000,
  expiresAt: 1_725_000_030_000,
  position: 'top-right',
};

const interactionCue = {
  interactionId: 'intent.vehicle.trunk',
  revision: 4,
  mode: 'cue',
  label: 'Open trunk',
  targetLabel: 'Sultan RS',
  projection: { visible: true, behindCamera: false, x: 0.52, y: 0.61 },
  intents: [{ intentId: 'vehicle.trunk.open', label: 'Open trunk', iconKey: 'command' }],
  selectedIntentId: 'vehicle.trunk.open',
  moreCount: 2,
  pointer: false,
  input: {
    primary: { keyboard: 'E', gamepad: 'A' },
    more: { keyboard: 'Left Alt', gamepad: 'D-pad Up' },
  },
  cancellable: false,
};

describe('runtime protocol', () => {
  it('accepts a bounded, typed surface descriptor without interpreting text as markup', () => {
    const parsed = parseSurfaceDescriptor(descriptor);
    expect(parsed).toMatchObject({
      surfaceId: 'confirm_restart',
      requestId: 'request_restart_01',
      instanceId: 'instance_restart_01',
      kind: 'confirm',
      description: descriptor.description,
      fields: [],
      options: [],
      sections: [],
    });
  });

  it('rejects active content and URL-bearing payload fields', () => {
    expect(parseSurfaceDescriptor({ ...descriptor, html: '<strong>unsafe</strong>' })).toBeNull();
    expect(parseSurfaceDescriptor({ ...descriptor, svg: '<svg onload="alert(1)" />' })).toBeNull();
    expect(parseSurfaceDescriptor({ ...descriptor, url: 'https://example.invalid' })).toBeNull();
  });

  it('rejects duplicate field, option, and section identifiers', () => {
    const option = { id: 'same', label: 'Same option' };
    expect(parseSurfaceDescriptor({ ...descriptor, kind: 'select', options: [option, option] })).toBeNull();
    const field = { id: 'same', type: 'text', label: 'Same field' };
    expect(parseSurfaceDescriptor({ ...descriptor, kind: 'form', fields: [field, field] })).toBeNull();
    const section = { id: 'same', items: [option] };
    expect(parseSurfaceDescriptor({ ...descriptor, kind: 'menu', sections: [section, section] })).toBeNull();
  });

  it('enforces field value types and exact nested schemas', () => {
    expect(parseSurfaceDescriptor({
      ...descriptor,
      kind: 'input',
      fields: [{ id: 'enabled', type: 'checkbox', label: 'Enabled', value: 'yes' }],
    })).toBeNull();
    expect(parseSurfaceDescriptor({
      ...descriptor,
      kind: 'menu',
      sections: [{ id: 'actions', unexpected: true, items: [{ id: 'inspect', label: 'Inspect' }] }],
    })).toBeNull();
    expect(parseSurfaceDescriptor({
      ...descriptor,
      kind: 'menu',
      sections: [{ id: 'actions', items: [{ id: 'empty', label: 'Empty', options: [] }] }],
    })).toBeNull();
    expect(parseSurfaceDescriptor({
      ...descriptor,
      kind: 'contextMenu',
      sections: [{ id: 'actions', items: [{ id: 'inspect', label: 'Inspect' }] }],
      anchor: { x: 0.5, y: 0.5, href: 'https://example.invalid' },
    })).toBeNull();
  });

  it('parses searchable multi-selection and normalized context anchors', () => {
    const options = [{ id: 'one', label: 'One' }, { id: 'two', label: 'Two' }];
    expect(parseSurfaceDescriptor({
      ...descriptor,
      kind: 'select',
      options,
      multiple: true,
      searchable: true,
      placeholder: 'Choose values',
    })).toMatchObject({ multiple: true, searchable: true, placeholder: 'Choose values' });
    const context = parseSurfaceDescriptor({
      ...descriptor,
      kind: 'contextMenu',
      sections: [{ id: 'actions', items: [{ ...options[0], metadata: { entityId: 'vehicle_42', networkId: 17 } }, options[1]] }],
      anchor: { x: 0.75, y: 0.25 },
    });
    expect(context).toMatchObject({ anchor: { x: 0.75, y: 0.25 } });
    expect(context?.sections[0]?.items[0]?.metadata).toEqual({ entityId: 'vehicle_42', networkId: 17 });
    expect(parseSurfaceDescriptor({
      ...descriptor,
      kind: 'contextMenu',
      sections: [{ id: 'actions', items: [{ id: 'unsafe', label: 'Unsafe', metadata: { url: 'https://example.invalid' } }] }],
      anchor: { x: 0.75, y: 0.25 },
    })).toBeNull();
  });

  it('accepts bounded menu subtrees and rejects unknown or over-deep surface data', () => {
    const menu = {
      ...descriptor,
      kind: 'menu',
      sections: [{ id: 'actions', items: [{ id: 'one', label: 'One', options: [{ id: 'two', label: 'Two', options: [{ id: 'three', label: 'Three' }] }] }] }],
    };
    expect(parseSurfaceDescriptor(menu)).not.toBeNull();
    expect(parseSurfaceDescriptor({ ...menu, unexpectedRoute: 'unsafe' })).toBeNull();
    expect(parseSurfaceDescriptor({
      ...menu,
      sections: [{ id: 'actions', items: [{ id: 'one', label: 'One', options: [{ id: 'two', label: 'Two', options: [{ id: 'three', label: 'Three', options: [{ id: 'four', label: 'Four' }] }] }] }] }],
    })).toBeNull();
  });

  it('rejects depth, entry, string, and byte limit violations', () => {
    let deep: Record<string, unknown> = {};
    for (let index = 0; index <= UI_LIMITS.maxDepth; index += 1) deep = { next: deep };
    expect(isBoundedPayload(deep)).toBe(false);
    expect(isBoundedPayload({ value: 'x'.repeat(UI_LIMITS.maxStringLength + 1) })).toBe(false);
    expect(isBoundedPayload(Array.from({ length: UI_LIMITS.maxEntries + 1 }, () => 1))).toBe(false);
    expect(isBoundedPayload({ value: 'x'.repeat(UI_LIMITS.maxPayloadBytes) })).toBe(false);
  });

  it('reconstructs the strict passive signal DTO and display-only action hints', () => {
    expect(parseSignalDescriptor(signalDescriptor)).toEqual(signalDescriptor);
    const { actions: _actions, ...signalWithoutActions } = signalDescriptor;
    expect(parseSignalDescriptor({
      ...signalWithoutActions,
      signalId: 'notify.waiting',
      revision: 1,
      progress: { state: 'PENDING', mode: 'indeterminate' },
    })).toMatchObject({ actions: [], progress: { state: 'PENDING', mode: 'indeterminate' } });
  });

  it('rejects signal ownership injection, executable actions, and malformed progress', () => {
    expect(parseSignalDescriptor({ ...signalDescriptor, ownerResource: 'synex_notify' })).toBeNull();
    expect(parseSignalDescriptor({
      ...signalDescriptor,
      actions: [{ token: 'execute', label: 'Execute', callback: 'arbitrary:event' }],
    })).toBeNull();
    expect(parseSignalDescriptor({
      ...signalDescriptor,
      actions: [signalDescriptor.actions[0], signalDescriptor.actions[0]],
    })).toBeNull();
    expect(parseSignalDescriptor({
      ...signalDescriptor,
      progress: { state: 'RUNNING', mode: 'indeterminate', value: 12 },
    })).toBeNull();
    expect(parseSignalDescriptor({
      ...signalDescriptor,
      progress: { state: 'RUNNING', mode: 'determinate', value: 21, maximum: 20 },
    })).toBeNull();
    expect(parseSignalDescriptor({ ...signalDescriptor, message: 'unsafe\u0000copy' })).toBeNull();
    expect(parseSignalDescriptor({ ...signalDescriptor, expiresAt: signalDescriptor.createdAt })).toBeNull();
  });

  it('enforces the canonical notify text and action boundaries exactly', () => {
    const maximumAction = {
      token: 'a'.repeat(96),
      label: 'L'.repeat(64),
      hint: 'H'.repeat(24),
    };
    expect(parseSignalDescriptor({
      ...signalDescriptor,
      title: 'T'.repeat(120),
      message: 'M'.repeat(720),
      actions: [maximumAction],
    })).not.toBeNull();
    expect(parseSignalDescriptor({ ...signalDescriptor, title: 'T'.repeat(121) })).toBeNull();
    expect(parseSignalDescriptor({ ...signalDescriptor, message: 'M'.repeat(721) })).toBeNull();
    expect(parseSignalDescriptor({ ...signalDescriptor, actions: [{ ...maximumAction, token: 'a'.repeat(97) }] })).toBeNull();
    expect(parseSignalDescriptor({ ...signalDescriptor, actions: [{ ...maximumAction, label: 'L'.repeat(65) }] })).toBeNull();
    expect(parseSignalDescriptor({ ...signalDescriptor, actions: [{ ...maximumAction, hint: 'H'.repeat(25) }] })).toBeNull();
  });

  it('reconstructs a bounded semantic interaction cue without authority data', () => {
    expect(parseInteractionDescriptor(interactionCue)).toEqual(interactionCue);
    expect(parseInteractionDescriptor({
      interactionId: 'graph.repair.progress',
      revision: 8,
      mode: 'progress',
      label: 'Repairing vehicle',
      projection: { visible: true, behindCamera: false, x: 0.5, y: 0.64 },
      intents: [],
      pointer: false,
      input: { cancel: { keyboard: 'X', gamepad: 'B' } },
      progress: { mode: 'timed', elapsedMs: 1_250, durationMs: 5_000 },
      cancellable: true,
    })).toMatchObject({ progress: { mode: 'timed', elapsedMs: 1_250, durationMs: 5_000 } });
  });

  it('enforces bloom relevance bounds, strict fields, and passive cue/progress focus', () => {
    const { moreCount: _moreCount, ...cueWithoutMore } = interactionCue;
    const bloom = {
      ...cueWithoutMore,
      mode: 'bloom',
      label: 'Vehicle actions',
      intents: [
        { intentId: 'vehicle.trunk.open', label: 'Open trunk' },
        { intentId: 'vehicle.inspect', label: 'Inspect', disabled: true },
      ],
      selectedIntentId: 'vehicle.trunk.open',
      pointer: true,
      input: {
        primary: { keyboard: 'Enter', gamepad: 'A', mouse: 'Left Click' },
        cancel: { keyboard: 'Esc', gamepad: 'B', mouse: 'Right Click' },
      },
      cancellable: true,
    };
    expect(parseInteractionDescriptor(bloom)).not.toBeNull();
    expect(parseInteractionDescriptor({ ...bloom, execute: 'arbitrary:event' })).toBeNull();
    expect(parseInteractionDescriptor({ ...bloom, ownerResource: 'synex_interact' })).toBeNull();
    expect(parseInteractionDescriptor({ ...bloom, intents: Array.from({ length: 7 }, (_, index) => ({
      intentId: `intent.${index}`, label: `Intent ${index}`,
    })) })).toBeNull();
    expect(parseInteractionDescriptor({ ...bloom, selectedIntentId: 'vehicle.inspect' })).toBeNull();
    expect(parseInteractionDescriptor({ ...interactionCue, pointer: true })).toBeNull();
    expect(parseInteractionDescriptor({
      interactionId: 'progress.bad', revision: 1, mode: 'progress', label: 'Working', intents: [],
      pointer: false, input: {}, progress: { mode: 'timed', elapsedMs: 5_001, durationMs: 5_000 },
      cancellable: false,
    })).toBeNull();
  });

  it('accepts interaction envelopes only from synex_interact with a strict generation', () => {
    const envelope = {
      protocolVersion: 1,
      messageId: 'message_interaction_01',
      type: 'interaction:upsert',
      ownerResource: 'synex_interact',
      ownerEpoch: 3,
      revision: interactionCue.revision,
      payload: { ...interactionCue, generation: 7 },
    };
    expect(parseGameEnvelope(envelope)).not.toBeNull();
    expect(parseGameEnvelope({ ...envelope, ownerResource: 'foreign_target' })).toBeNull();
    expect(parseGameEnvelope({ ...envelope, payload: { ...envelope.payload, generation: 0 } })).toBeNull();
    expect(parseGameEnvelope({ ...envelope, payload: { ...envelope.payload, callback: 'unsafe:event' } })).toBeNull();
    expect(parseGameEnvelope({
      ...envelope,
      type: 'interaction:remove',
      revision: 5,
      payload: { interactionId: interactionCue.interactionId, generation: 8 },
    })).not.toBeNull();
  });

  it('accepts only the closed notification sound payload and trusted owner envelope', () => {
    const browserBootId = 'ui_test_boot_01';
    for (const tone of ['neutral', 'info', 'success', 'warning', 'danger', 'critical']) {
      expect(parseSignalSoundPayload({ tone, volume: 50, browserBootId })).toEqual({ tone, volume: 50, browserBootId });
    }
    for (const volume of [0, 1.5, 101, Number.NaN, Number.POSITIVE_INFINITY]) {
      expect(parseSignalSoundPayload({ tone: 'info', volume, browserBootId })).toBeNull();
    }
    expect(parseSignalSoundPayload({ tone: 'accent', volume: 50, browserBootId })).toBeNull();
    expect(parseSignalSoundPayload({ tone: 'info', volume: 50 })).toBeNull();
    expect(parseSignalSoundPayload({ tone: 'info', volume: 50, browserBootId: 'invalid id' })).toBeNull();
    expect(parseSignalSoundPayload({ tone: 'info', volume: 50, browserBootId, url: 'https://example.invalid' })).toBeNull();

    const soundEnvelope = {
      protocolVersion: 1,
      messageId: 'message_sound_01',
      type: 'signal:sound',
      ownerResource: 'synex_notify',
      ownerEpoch: 1,
      revision: 0,
      payload: { tone: 'critical', volume: 100, browserBootId },
    };
    expect(parseGameEnvelope(soundEnvelope)).toEqual(soundEnvelope);
    expect(parseGameEnvelope({ ...soundEnvelope, ownerResource: 'foreign_resource' })).toBeNull();
    expect(parseGameEnvelope({ ...soundEnvelope, revision: 1 })).toBeNull();
    expect(parseGameEnvelope({ ...soundEnvelope, payload: {
      tone: 'critical', volume: 100, browserBootId, replay: true,
    } })).toBeNull();
  });

  it('requires the supported version, message type, owner epoch, and revision', () => {
    const envelope = {
      protocolVersion: 1,
      messageId: 'msg_01',
      type: 'surface:open',
      ownerResource: 'synex_inventory',
      ownerEpoch: 2,
      revision: 1,
      payload: descriptor,
    };
    expect(parseGameEnvelope(envelope)).not.toBeNull();
    expect(parseGameEnvelope({ ...envelope, type: 'signal:upsert', payload: signalDescriptor })).not.toBeNull();
    expect(parseGameEnvelope({ ...envelope, protocolVersion: 2 })).toBeNull();
    expect(parseGameEnvelope({ ...envelope, type: 'runtime:execute' })).toBeNull();
    expect(parseGameEnvelope({ ...envelope, ownerEpoch: 0 })).toBeNull();
    expect(parseGameEnvelope({ ...envelope, ownerEpoch: -1 })).toBeNull();
    expect(parseGameEnvelope({ ...envelope, revision: 1.5 })).toBeNull();
    expect(parseGameEnvelope({ ...envelope, unexpected: true })).toBeNull();
  });

  it('creates opaque browser boot identifiers', () => {
    const first = createBrowserBootId();
    const second = createBrowserBootId();
    expect(first).toMatch(/^ui_[a-f0-9]{24}$/);
    expect(second).not.toBe(first);
  });
});
