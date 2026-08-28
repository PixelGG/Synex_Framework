import { describe, expect, it } from 'vitest';
import {
  UI_LIMITS,
  createBrowserBootId,
  isBoundedPayload,
  parseGameEnvelope,
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
