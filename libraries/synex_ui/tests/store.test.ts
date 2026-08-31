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

const signalEnvelope: GameEnvelope = {
  protocolVersion: 1,
  messageId: 'msg_signal_1',
  type: 'signal:upsert',
  ownerResource: 'synex_notify',
  ownerEpoch: 7,
  revision: 1,
  payload: {
    signalId: 'notify.queue',
    revision: 1,
    kind: 'progress',
    tone: 'info',
    priority: 'normal',
    title: 'Queue processing',
    progress: { state: 'RUNNING', mode: 'determinate', value: 25, maximum: 100 },
    actions: [{ token: 'cancel', label: 'Cancel', hint: 'B' }],
    createdAt: 1_725_000_000_000,
    position: 'top-right',
    generation: 1,
  },
};

const soundEnvelope: GameEnvelope = {
  protocolVersion: 1,
  messageId: 'msg_sound_1',
  type: 'signal:sound',
  ownerResource: 'synex_notify',
  ownerEpoch: 7,
  revision: 0,
  payload: { tone: 'success', volume: 65, browserBootId: 'ui_test' },
};

const interactionEnvelope: GameEnvelope = {
  protocolVersion: 1,
  messageId: 'msg_interaction_1',
  type: 'interaction:upsert',
  ownerResource: 'synex_interact',
  ownerEpoch: 11,
  revision: 1,
  payload: {
    interactionId: 'world.terminal.inspect',
    revision: 1,
    mode: 'cue',
    label: 'Inspect terminal',
    intents: [{ intentId: 'terminal.inspect', label: 'Inspect terminal' }],
    selectedIntentId: 'terminal.inspect',
    moreCount: 0,
    pointer: false,
    input: { primary: { keyboard: 'E', gamepad: 'A' } },
    cancellable: false,
    generation: 1,
  },
};

describe('runtime state', () => {
  it('starts closed with no mounted surface state', () => {
    const state = createInitialRuntimeState('ui_test');
    expect(state.surfaces).toEqual([]);
    expect(state.signals).toEqual([]);
    expect(state.signalGeneration).toBe(0);
    expect(state.signalRevisions).toEqual({});
    expect(state.interaction).toBeNull();
    expect(state.interactionGeneration).toBe(0);
    expect(state.interactionRevisions).toEqual({});
    expect(state.ready).toBe(false);
    expect(state.health).toBe('DEGRADED');
  });

  it('never retains one-shot sound effects in reducer state', () => {
    const state = createInitialRuntimeState('ui_test');
    expect(runtimeReducer(state, { type: 'message', envelope: soundEnvelope })).toBe(state);
  });

  it('keeps one generation-fenced semantic interaction independently of notifications and modals', () => {
    let state = runtimeReducer(createInitialRuntimeState('ui_test'), {
      type: 'message', envelope: interactionEnvelope,
    });
    expect(state.interaction).toMatchObject({
      interactionId: 'world.terminal.inspect',
      ownerResource: 'synex_interact',
      ownerEpoch: 11,
    });
    expect(state.interactionGeneration).toBe(1);
    expect(state.signals).toEqual([]);
    expect(state.surfaces).toEqual([]);

    state = runtimeReducer(state, {
      type: 'message',
      envelope: {
        ...interactionEnvelope,
        messageId: 'msg_interaction_2',
        revision: 2,
        payload: {
          ...interactionEnvelope.payload,
          revision: 2,
          label: 'Use terminal',
          generation: 2,
        },
      },
    });
    expect(state.interaction?.label).toBe('Use terminal');

    const stale = runtimeReducer(state, {
      type: 'message',
      envelope: { ...interactionEnvelope, messageId: 'msg_interaction_stale', payload: {
        ...interactionEnvelope.payload, generation: 3,
      } },
    });
    expect(stale.interaction?.label).toBe('Use terminal');
    expect(stale.interactionGeneration).toBe(2);
    expect(stale.health).toBe('DEGRADED');
  });

  it('applies a correlated interaction removal and blocks stale resurrection', () => {
    let state = runtimeReducer(createInitialRuntimeState('ui_test'), {
      type: 'message', envelope: interactionEnvelope,
    });
    state = runtimeReducer(state, {
      type: 'message',
      envelope: {
        ...interactionEnvelope,
        messageId: 'msg_interaction_remove',
        type: 'interaction:remove',
        revision: 2,
        payload: { interactionId: 'world.terminal.inspect', generation: 2 },
      },
    });
    expect(state.interaction).toBeNull();
    expect(state.interactionGeneration).toBe(2);

    const stale = runtimeReducer(state, {
      type: 'message', envelope: { ...interactionEnvelope, messageId: 'msg_interaction_resurrection', payload: {
        ...interactionEnvelope.payload, generation: 3,
      } },
    });
    expect(stale.interaction).toBeNull();
    expect(stale.interactionGeneration).toBe(2);
    expect(stale.health).toBe('DEGRADED');
  });

  it('accepts an exact interaction snapshot and rejects owner injection atomically', () => {
    const runtimeInteraction = { ...interactionEnvelope.payload, ownerResource: 'synex_interact', ownerEpoch: 11 };
    delete (runtimeInteraction as { generation?: number }).generation;
    let state = runtimeReducer(createInitialRuntimeState('ui_test'), {
      type: 'message',
      envelope: {
        ...interactionEnvelope,
        messageId: 'msg_interaction_sync',
        type: 'runtime:sync',
        revision: 0,
        payload: { interaction: runtimeInteraction, interactionGeneration: 5 },
      },
    });
    expect(state.interaction?.interactionId).toBe('world.terminal.inspect');
    expect(state.interactionGeneration).toBe(5);

    state = runtimeReducer(state, {
      type: 'message',
      envelope: {
        ...interactionEnvelope,
        messageId: 'msg_interaction_bad_sync',
        type: 'runtime:sync',
        revision: 0,
        payload: {
          interaction: { ...runtimeInteraction, ownerResource: 'foreign_target' },
          interactionGeneration: 6,
        },
      },
    });
    expect(state.interaction?.ownerResource).toBe('synex_interact');
    expect(state.interactionGeneration).toBe(5);
    expect(state.health).toBe('DEGRADED');
  });

  it('keeps passive signals separate from modal surfaces and fences stale upserts', () => {
    let state = runtimeReducer(createInitialRuntimeState('ui_test'), {
      type: 'message',
      envelope: signalEnvelope,
    });
    expect(state.signals).toHaveLength(1);
    expect(state.surfaces).toEqual([]);
    expect(state.interaction).toBeNull();
    expect(state.signalGeneration).toBe(1);

    state = runtimeReducer(state, {
      type: 'message',
      envelope: {
        ...signalEnvelope,
        messageId: 'msg_signal_2',
        revision: 2,
        payload: {
          ...signalEnvelope.payload,
          revision: 2,
          title: 'Queue almost complete',
          generation: 2,
        },
      },
    });
    expect(state.signals[0]?.title).toBe('Queue almost complete');

    const stale = runtimeReducer(state, {
      type: 'message',
      envelope: {
        ...signalEnvelope,
        messageId: 'msg_signal_stale',
        payload: { ...signalEnvelope.payload, generation: 3 },
      },
    });
    expect(stale.signals[0]?.title).toBe('Queue almost complete');
    expect(stale.signalGeneration).toBe(2);
    expect(stale.health).toBe('DEGRADED');
  });

  it('applies a generation-fenced signal removal without touching an active modal', () => {
    let state = runtimeReducer(createInitialRuntimeState('ui_test'), { type: 'message', envelope: openEnvelope });
    state = runtimeReducer(state, { type: 'message', envelope: signalEnvelope });
    state = runtimeReducer(state, {
      type: 'message',
      envelope: {
        ...signalEnvelope,
        messageId: 'msg_signal_remove',
        type: 'signal:remove',
        revision: 2,
        payload: { signalId: 'notify.queue', generation: 2 },
      },
    });
    expect(state.signals).toEqual([]);
    expect(state.signalGeneration).toBe(2);
    expect(state.surfaces).toHaveLength(1);

    const staleResurrection = runtimeReducer(state, {
      type: 'message',
      envelope: {
        ...signalEnvelope,
        messageId: 'msg_signal_stale_resurrection',
        payload: { ...signalEnvelope.payload, generation: 3 },
      },
    });
    expect(staleResurrection.signals).toEqual([]);
    expect(staleResurrection.signalGeneration).toBe(2);
    expect(staleResurrection.health).toBe('DEGRADED');
  });

  it('accepts an exact signal snapshot and rejects a malformed replacement atomically', () => {
    const runtimeSignal = {
      ...signalEnvelope.payload,
      ownerResource: 'synex_notify',
      ownerEpoch: 7,
    };
    delete (runtimeSignal as { generation?: number }).generation;
    let state = runtimeReducer(createInitialRuntimeState('ui_test'), {
      type: 'message',
      envelope: {
        ...signalEnvelope,
        messageId: 'msg_signal_snapshot',
        type: 'runtime:sync',
        revision: 0,
        payload: { signals: [runtimeSignal], signalGeneration: 4 },
      },
    });
    expect(state.signals).toHaveLength(1);
    expect(state.signalGeneration).toBe(4);

    state = runtimeReducer(state, {
      type: 'message',
      envelope: {
        ...signalEnvelope,
        messageId: 'msg_signal_bad_snapshot',
        type: 'runtime:sync',
        revision: 0,
        payload: {
          signals: [{ ...runtimeSignal, ownerResource: '../attacker' }],
          signalGeneration: 5,
        },
      },
    });
    expect(state.signals).toHaveLength(1);
    expect(state.signalGeneration).toBe(4);
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
