import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';

const root = process.cwd();

test('player presentation preferences govern placement, duration, sound, and history', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    for (const relativePath of [
      'resources/synex_notify/shared/limits.lua',
      'resources/synex_notify/shared/validation.lua',
      'resources/synex_notify/client/engine.lua',
    ]) {
      await engine.doString(await readFile(path.join(root, relativePath), 'utf8'));
    }
    const result = await engine.doString(`
      local clock, rendered, sounds = 1000, {}, {}
      local notify = SynexNotifyEngine.create({
        now = function() return clock end,
        upsertSignal = function(descriptor)
          rendered[#rendered + 1] = SynexNotifyValidation.copy(descriptor)
          return { signal = descriptor }
        end,
        removeSignal = function() return true end,
        playSound = function(tone, volume)
          sounds[#sounds + 1] = { tone = tone, volume = volume }
          return true
        end,
      })
      local invalid, invalidError = notify.setPresentationPreferences({
        position = 'middle', durationScale = 10,
      })
      assert(invalid == nil and invalidError.code == 'NOTIFY_INVALID_REQUEST')
      assert(notify.setPresentationPreferences({
        position = 'bottom-center', durationScale = 50,
        soundEnabled = true, soundVolume = 25,
        muteNonCriticalSounds = true, history = false,
      }))
      local localValue = assert(SynexNotifyValidation.canonicalNotification({
        title = 'Preference governed', position = 'top-left', durationMs = 4000,
        maxLifetimeMs = 10000, sound = true,
      }, { authority = 'CLIENT', ownerResource = 'preference.owner', now = clock }))
      local localHandle = assert(notify.show('preference.owner', 1, localValue))
      assert(rendered[#rendered].position == 'bottom-center')
      assert(rendered[#rendered].expiresAt == clock + 2000)
      assert(#sounds == 0)
      assert(notify.dismiss(localHandle))
      assert(#notify.history(nil, 10) == 0)

      local critical = assert(SynexNotifyValidation.canonicalNotification({
        title = 'Critical preference sound', priority = 'critical', sound = true,
      }, { authority = 'SERVER', ownerResource = 'system.owner', now = clock }))
      critical.notificationId = 'critical-preference-sound'
      critical.revision = 1
      critical.createdAt = clock
      critical.origin = 'SERVER'
      critical = assert(SynexNotifyValidation.canonicalPresentation(critical, {
        authority = 'SERVER', ownerResource = 'system.owner',
      }))
      assert(notify.applyServer('system.owner', 1, critical, 'show'))
      assert(#sounds == 1 and sounds[1].tone == 'critical' and sounds[1].volume == 25)

      local snapshot = notify.presentationSnapshot()
      assert(snapshot.preferences.position == 'bottom-center')
      assert(snapshot.preferences.durationScale == 50)
      assert(snapshot.preferences.soundVolume == 25)
      assert(snapshot.preferences.muteNonCriticalSounds == true)
      assert(snapshot.preferences.history == false)
      return table.concat({ rendered[1].position, rendered[1].expiresAt,
        #sounds, sounds[1].volume, #notify.history(nil, 10) }, ':')
    `);
    assert.equal(result, 'bottom-center:3000:1:25:0');
  } finally {
    engine.global.close();
  }
});

test('client diagnostics measure validation, dispatch, and browser visibility acknowledgement', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    for (const relativePath of [
      'resources/synex_notify/shared/limits.lua',
      'resources/synex_notify/shared/validation.lua',
      'resources/synex_notify/client/engine.lua',
    ]) {
      await engine.doString(await readFile(path.join(root, relativePath), 'utf8'));
    }
    const result = await engine.doString(`
      local clock, observed = 5000, {}
      local notify = SynexNotifyEngine.create({
        now = function() return clock end,
        upsertSignal = function(descriptor)
          clock = clock + 2
          return { signal = descriptor }
        end,
        removeSignal = function() return true end,
        observe = function(name, amount)
          observed[name] = (observed[name] or 0) + (amount or 1)
        end,
      })
      local value = assert(SynexNotifyValidation.canonicalNotification({
        title = 'Measured signal',
      }, { authority = 'CLIENT', ownerResource = 'metric.owner', now = clock }))
      assert(notify.show('metric.owner', 1, value))
      local descriptorRevision = 1
      clock = clock + 18
      assert(notify.confirmVisibility({
        generation = 1, visibilityGeneration = 1, visibilityRevision = 1,
        signals = {{ signalId = 'local:00000001:00000001',
          revision = descriptorRevision, visible = true }},
      }))
      assert(observed.render_dispatch_samples == 1)
      assert(observed.render_dispatch_time_ms == 2)
      assert(observed.render_ack_samples == 1)
      assert(observed.render_ack_time_ms == 20)
      return table.concat({ observed.render_dispatch_samples,
        observed.render_dispatch_time_ms, observed.render_ack_samples,
        observed.render_ack_time_ms }, ':')
    `);
    assert.equal(result, '1:2:1:20');
  } finally {
    engine.global.close();
  }
});
