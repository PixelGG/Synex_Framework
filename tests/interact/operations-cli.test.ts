import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import test from 'node:test';

import {
  interactBundleFactory,
  interactServerFiles,
  runInteractLua,
} from './helpers.js';

test('Interact diagnostic service inspection is exact, bounded, and payload-free', async () => {
  const result = await runInteractLua<{
    objectKind: string;
    slotCount: number;
    graphKind: string;
    nodeCount: number;
    requestHidden: boolean;
    missing: string;
    traceFrames: number;
    ownerBound: boolean;
    inviteOwnerBound: boolean;
    renewOwnerBound: boolean;
    invalidRenew: string;
  }>(`${interactBundleFactory}
    local registry = SynexInteractRegistry.create({ compiler = SynexInteractCompiler,
      isOwnerCurrent = function(owner, epoch)
        return owner == 'fixture' and epoch == 1
      end })
    assert(registry.register('fixture', 1, __interactBundle()))
    local service = SynexInteractService.create({
      foundation = SynexInteractFoundation,
      registry = registry,
      authority = { reconcileSlots = function() end, revokeOwner = function() end,
        inviteSession = function(request, owner, epoch)
          return { invitationId = request.sessionId,
            ownerBound = owner == 'fixture' and epoch == 1 }
        end,
        renewLease = function(leaseId, extensionMs, context, owner, epoch)
          return { ownerBound = leaseId == 'lease-0001' and extensionMs == 500
            and context == nil and owner == 'fixture' and epoch == 1 }
        end },
      entityProjection = { snapshot = function() return { entities = {} } end },
      graph = {}, observability = { replay = function(traceId, limit)
        assert(traceId == 'trace_fixture_0001' and limit == 4)
        return { frames = {{ phase = 'graph_started' }}, total = 1,
          retained = 1, hasMore = false, truncated = false }
      end },
      resolveOwnerEpoch = function(owner, epoch)
        assert(owner == 'fixture')
        return epoch
      end,
    })
    local provider = assert(service.registerProvider({
      definition = { key = 'fixture:nearby', timeoutMs = 16 },
      handler = function() return {} end,
    }, { caller = 'fixture', callerEpoch = 1 }))
    local object = assert(service.inspect({ key = 'fixture:terminal' }))
    local graph = assert(service.inspect({ key = 'fixture:inspect_graph', kind = 'graph' }))
    local _, missing = service.inspect({ key = 'fixture:missing' })
    local replay = assert(service.replayTrace({ traceId = 'trace_fixture_0001', limit = 4 }))
    local invitation = assert(service.inviteParticipant({
      sessionId = 'session-0001', role = 'assistant', source = 11,
    }, { caller = 'fixture', callerEpoch = 1 }))
    local renewal = assert(service.renewLease({
      leaseId = 'lease-0001', extensionMs = 500,
    }, { caller = 'fixture', callerEpoch = 1 }))
    local _, invalidRenew = service.renewLease({
      leaseId = 'lease-0001', extensionMs = 500, extra = true,
    }, { caller = 'fixture', callerEpoch = 1 })
    return {
      objectKind = object.kind, slotCount = #object.slots,
      graphKind = graph.kind, nodeCount = #graph.nodes,
      requestHidden = graph.nodes[1].request == nil,
      missing = missing.code,
      traceFrames = #replay.frames,
      ownerBound = provider.key == 'fixture:nearby',
      inviteOwnerBound = invitation.ownerBound == true,
      renewOwnerBound = renewal.ownerBound == true,
      invalidRenew = invalidRenew.code,
    }
  `, [...interactServerFiles, 'resources/synex_interact/server/service.lua']);

  assert.deepEqual(result, {
    objectKind: 'object',
    slotCount: 1,
    graphKind: 'graph',
    nodeCount: 2,
    requestHidden: true,
    missing: 'INTERACT_TARGET_INVALID',
    traceFrames: 1,
    ownerBound: true,
    inviteOwnerBound: true,
    renewOwnerBound: true,
    invalidRenew: 'INTERACT_INVALID_REQUEST',
  });
});

test('Core runtime CLI exposes only read-only Interact status, doctor, inspection, and trace replay', async () => {
  const commands = await readFile(join(
    process.cwd(),
    'core/synex_core/server/commands.lua',
  ), 'utf8');

  assert.match(commands, /registry\.interact\s*=\s*\{/u);
  assert.match(commands, /serviceSummary\('synex\.interact', 'summary', 'synex_interact'\)/u);
  assert.match(commands, /serviceSummary\('synex\.interact', 'doctor', 'synex_interact'/u);
  assert.match(commands, /serviceSummary\('synex\.interact', 'inspect', 'synex_interact'/u);
  assert.match(commands, /serviceSummary\('synex\.interact', 'replay_trace', 'synex_interact'/u);
  assert.match(commands,
    /usage: synex interact <status\|doctor\|inspect <namespaced-key>\|trace <trace-id>>/u);
});
