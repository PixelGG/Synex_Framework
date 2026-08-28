import { describe, expect, it } from 'vitest';
import { createInitialRuntimeState, runtimeReducer } from '../runtime/src/store';
import type { GameEnvelope } from '../runtime/src/protocol';

const openEnvelope: GameEnvelope = {
  protocolVersion: 1,
  messageId: 'msg_open',
  type: 'surface:open',
  ownerResource: 'synex_inventory',
  ownerEpoch: 4,
  revision: 1,
  payload: {
    requestId: 'request_surface_one',
    instanceId: 'instance_surface_one',
    surfaceId: 'surface_one',
    kind: 'confirm',
    title: 'Confirm action',
  },
};

describe('runtime state', () => {
  it('starts closed with no mounted surface state', () => {
    const state = createInitialRuntimeState('ui_test');
    expect(state.surfaces).toEqual([]);
    expect(state.ready).toBe(false);
    expect(state.health).toBe('DEGRADED');
  });

  it('opens, updates, and closes only the correlated owner surface', () => {
    let state = createInitialRuntimeState('ui_test');
    state = runtimeReducer(state, { type: 'message', envelope: openEnvelope });
    expect(state.surfaces).toHaveLength(1);
    state = runtimeReducer(state, {
      type: 'message',
      envelope: {
        ...openEnvelope,
        messageId: 'msg_update',
        type: 'surface:update',
        revision: 2,
        payload: { ...openEnvelope.payload, title: 'Updated action' },
      },
    });
    expect(state.surfaces[0]?.title).toBe('Updated action');
    state = runtimeReducer(state, {
      type: 'message',
      envelope: {
        ...openEnvelope,
        messageId: 'msg_close',
        type: 'surface:close',
        revision: 3,
        payload: { surfaceId: 'surface_one' },
      },
    });
    expect(state.surfaces).toEqual([]);
  });

  it('fails closed on a duplicate surface id owned by another resource', () => {
    let state = runtimeReducer(createInitialRuntimeState('ui_test'), { type: 'message', envelope: openEnvelope });
    state = runtimeReducer(state, {
      type: 'message',
      envelope: { ...openEnvelope, messageId: 'msg_conflict', ownerResource: 'synex_banking' },
    });
    expect(state.surfaces).toHaveLength(1);
    expect(state.surfaces[0]?.ownerResource).toBe('synex_inventory');
    expect(state.health).toBe('DEGRADED');
  });

  it('rejects duplicated ownership metadata that disagrees with the envelope', () => {
    const state = runtimeReducer(createInitialRuntimeState('ui_test'), {
      type: 'message',
      envelope: {
        ...openEnvelope,
        payload: { ...openEnvelope.payload, ownerResource: 'synex_banking' },
      },
    });
    expect(state.surfaces).toEqual([]);
    expect(state.health).toBe('DEGRADED');
  });

  it('ignores stale revisions and rejects an update without an open surface', () => {
    let state = runtimeReducer(createInitialRuntimeState('ui_test'), { type: 'message', envelope: openEnvelope });
    state = runtimeReducer(state, {
      type: 'message',
      envelope: {
        ...openEnvelope,
        messageId: 'msg_current',
        type: 'surface:update',
        revision: 3,
        payload: { ...openEnvelope.payload, title: 'Current title' },
      },
    });
    state = runtimeReducer(state, {
      type: 'message',
      envelope: {
        ...openEnvelope,
        messageId: 'msg_stale',
        type: 'surface:update',
        revision: 2,
        payload: { ...openEnvelope.payload, title: 'Stale title' },
      },
    });
    expect(state.surfaces[0]?.title).toBe('Current title');
    expect(state.health).toBe('DEGRADED');

    const missing = runtimeReducer(createInitialRuntimeState('ui_test'), {
      type: 'message',
      envelope: { ...openEnvelope, messageId: 'msg_missing', type: 'surface:update', revision: 2 },
    });
    expect(missing.surfaces).toEqual([]);
    expect(missing.health).toBe('DEGRADED');
  });

  it('clears every surface on runtime shutdown', () => {
    let state = runtimeReducer(createInitialRuntimeState('ui_test'), { type: 'message', envelope: openEnvelope });
    state = runtimeReducer(state, {
      type: 'message',
      envelope: {
        ...openEnvelope,
        messageId: 'msg_shutdown',
        type: 'runtime:shutdown',
        payload: {},
      },
    });
    expect(state.surfaces).toEqual([]);
    expect(state.ready).toBe(false);
    expect(state.health).toBe('UNHEALTHY');
  });

  it('merges a partial screen sync without closing active surfaces', () => {
    let state = runtimeReducer(createInitialRuntimeState('ui_test'), { type: 'message', envelope: openEnvelope });
    state = runtimeReducer(state, {
      type: 'message',
      envelope: {
        ...openEnvelope,
        messageId: 'msg_screen_sync',
        type: 'runtime:sync',
        revision: 2,
        payload: {
          screen: {
            width: 3440,
            height: 1440,
            aspectRatio: 3440 / 1440,
            safeLeft: 24,
            safeRight: 24,
            safeTop: 12,
            safeBottom: 12,
          },
        },
      },
    });
    expect(state.surfaces).toHaveLength(1);
    expect(state.surfaces[0]?.surfaceId).toBe('surface_one');
    expect(state.screen.width).toBe(3440);
  });

  it('retains the bounded health state reported by Lua during runtime sync', () => {
    let state = runtimeReducer(createInitialRuntimeState('ui_test'), {
      type: 'message',
      envelope: {
        ...openEnvelope,
        messageId: 'msg_degraded_sync',
        type: 'runtime:sync',
        payload: { health: 'DEGRADED' },
      },
    });
    expect(state.health).toBe('DEGRADED');

    state = runtimeReducer(state, {
      type: 'message',
      envelope: {
        ...openEnvelope,
        messageId: 'msg_unhealthy_sync',
        type: 'runtime:sync',
        payload: { health: 'UNHEALTHY' },
      },
    });
    expect(state.health).toBe('UNHEALTHY');

    state = runtimeReducer(state, {
      type: 'message',
      envelope: {
        ...openEnvelope,
        messageId: 'msg_invalid_health_sync',
        type: 'runtime:sync',
        payload: { health: 'UNKNOWN' },
      },
    });
    expect(state.health).toBe('UNHEALTHY');
  });

  it('does not overwrite an authoritative health sync when browser readiness resolves late', () => {
    const synchronized = runtimeReducer(createInitialRuntimeState('ui_test'), {
      type: 'message',
      envelope: {
        ...openEnvelope,
        messageId: 'msg_health_before_ready',
        type: 'runtime:sync',
        payload: { health: 'DEGRADED' },
      },
    });

    const ready = runtimeReducer(synchronized, { type: 'browser-ready', browserBootId: 'ui_test' });
    expect(ready.ready).toBe(true);
    expect(ready.health).toBe('DEGRADED');
  });
});
