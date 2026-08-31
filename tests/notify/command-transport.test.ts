import assert from 'node:assert/strict';
import test from 'node:test';
import { notifyServerHarness, runNotifyLua } from './helpers.js';

test('server transport emits opaque wakes and command pulls are session-fenced single-consumer', async () => {
  const result = await runNotifyLua<string>(`${notifyServerHarness}
    __notifyTest.resourceStates['consumer.transport'] = 'started'
    __notifyTest.addSession(51, 4)
    __notifyTest.addSession(52, 1)
    local registry = __notifyTest.makeRegistry()
    local handle = assert(registry.send('consumer.transport', 1,
      __notifyTest.target(51), { title = 'Opaque transport' }, {
        operation = 'notify.send',
      }))
    local delivery = assert(__notifyTest.lastDelivery())
    assert(SynexNotifyValidation.exactObject(delivery.envelope, {
      schemaVersion = true, commandId = true,
    }))
    assert(delivery.envelope.schemaVersion == 1)
    assert(SynexNotifyValidation.identifier(delivery.envelope.commandId, 16, 96))
    assert(delivery.envelope.command == nil and delivery.envelope.target == nil
      and delivery.envelope.payload == nil)

    local wrongSession = __notifyTest.sessions[52]
    local _, wrongError = registry.pullCommand({
      commandId = delivery.envelope.commandId,
    }, {
      source = wrongSession.source,
      sourceGeneration = wrongSession.sourceGeneration,
      session = wrongSession,
    })
    assert(wrongError.code == 'NOTIFY_TARGET_STALE')
    assert(registry.snapshot().pendingCommands == 1)

    local targetSession = __notifyTest.sessions[51]
    local command = assert(registry.pullCommand({
      commandId = delivery.envelope.commandId,
    }, {
      source = targetSession.source,
      sourceGeneration = targetSession.sourceGeneration,
      session = targetSession,
    }))
    assert(command.command == 'show' and command.commandId == delivery.envelope.commandId)
    assert(command.notificationId == handle.notificationId)
    assert(command.target.source == 51 and command.target.sourceGeneration == 4)
    assert(command.payload.title == 'Opaque transport')
    assert(registry.snapshot().pendingCommands == 0)

    command.target.sourceGeneration = 9007199254740991
    command.payload.title = 'Detached mutation'
    local _, replayError = registry.pullCommand({
      commandId = delivery.envelope.commandId,
    }, {
      source = targetSession.source,
      sourceGeneration = targetSession.sourceGeneration,
      session = targetSession,
    })
    local _, fakeError = registry.pullCommand({
      commandId = 'notify-command-fake-opaque-id',
    }, {
      source = targetSession.source,
      sourceGeneration = targetSession.sourceGeneration,
      session = targetSession,
    })
    assert(replayError.code == 'NOTIFY_COMMAND_NOT_FOUND')
    assert(fakeError.code == 'NOTIFY_COMMAND_NOT_FOUND')
    return table.concat({ wrongError.code, replayError.code, fakeError.code,
      command.command }, ':')
  `);
  assert.equal(
    result,
    'NOTIFY_TARGET_STALE:NOTIFY_COMMAND_NOT_FOUND:NOTIFY_COMMAND_NOT_FOUND:show',
  );
});

test('pending commands expire and are removed on owner cleanup, player drop, and shutdown', async () => {
  const result = await runNotifyLua<string>(`${notifyServerHarness}
    __notifyTest.resourceStates['consumer.cleanup'] = 'started'
    __notifyTest.addSession(61, 2)
    local registry = __notifyTest.makeRegistry()

    assert(registry.send('consumer.cleanup', 1, __notifyTest.target(61), {
      title = 'Expires without a pull',
    }, { operation = 'notify.send' }))
    local expiredId = __notifyTest.lastDelivery().envelope.commandId
    __notifyTest.now = __notifyTest.now + SynexNotifyLimits.pendingCommandTtlMs
    local expired = registry.expire()
    assert(expired.commands == 1 and registry.snapshot().pendingCommands == 0)

    assert(registry.send('consumer.cleanup', 1, __notifyTest.target(61), {
      title = 'Owner cleanup',
    }, { operation = 'notify.send' }))
    local ownerWake = __notifyTest.lastDelivery()
    assert(registry.cleanupOwner('consumer.cleanup', 1).removed == 2)
    local session = __notifyTest.sessions[61]
    local _, cleanedError = registry.pullCommand({
      commandId = ownerWake.envelope.commandId,
    }, { source = 61, sourceGeneration = 2, session = session })
    assert(cleanedError.code == 'NOTIFY_COMMAND_NOT_FOUND')
    local stopCommand = __notifyTest.lastCommand()
    assert(stopCommand.command == 'owner_stop')

    __notifyTest.resourceStates['consumer.drop'] = 'started'
    assert(registry.send('consumer.drop', 1, __notifyTest.target(61), {
      title = 'Player drop cleanup',
    }, { operation = 'notify.send' }))
    local dropId = __notifyTest.lastDelivery().envelope.commandId
    assert(registry.playerDropped(61) == 1)
    local _, dropError = registry.pullCommand({ commandId = dropId }, {
      source = 61, sourceGeneration = 2, session = session,
    })
    assert(dropError.code == 'NOTIFY_COMMAND_NOT_FOUND')

    assert(registry.send('consumer.drop', 1, __notifyTest.target(61), {
      title = 'Shutdown cleanup',
    }, { operation = 'notify.send' }))
    assert(registry.clearPendingCommands() == 1)
    assert(registry.snapshot().pendingCommands == 0)
    return table.concat({ expired.commands, cleanedError.code, stopCommand.command,
      dropError.code, registry.snapshot().pendingCommands }, ':')
  `);
  assert.equal(
    result,
    '1:NOTIFY_COMMAND_NOT_FOUND:owner_stop:NOTIFY_COMMAND_NOT_FOUND:0',
  );
});

test('doctor reports bounded pending-command pressure', async () => {
  const result = await runNotifyLua<string>(`${notifyServerHarness}
    SynexNotifyLimits.maximumPendingCommands = 5
    SynexNotifyLimits.maximumPendingCommandsPerSource = 5
    __notifyTest.resourceStates['consumer.pressure'] = 'started'
    __notifyTest.addSession(71, 1)
    local registry = __notifyTest.makeRegistry()
    for index = 1, 4 do
      assert(registry.send('consumer.pressure', 1, __notifyTest.target(71), {
        title = 'Pending pressure ' .. index,
      }, { operation = 'notify.send' }))
    end
    local report = registry.doctor(50)
    local found = false
    for _, finding in ipairs(report.findings) do
      if finding.code == 'COMMAND_BACKLOG' and finding.scope == 'transport' then
        found = true
      end
    end
    assert(found and report.status == 'DEGRADED')
    return table.concat({ registry.snapshot().pendingCommands,
      registry.snapshot().maximumPendingCommands, report.status }, ':')
  `);
  assert.equal(result, '4:5:DEGRADED');
});
