import assert from 'node:assert/strict';
import test from 'node:test';
import { runInteractLua } from './helpers.ts';

test('action graph validates and executes deterministic bounded branches', async () => {
  const result = await runInteractLua<string>(String.raw`
    local calls = 0
    local engine = SynexInteractActionGraph.create({
      wait = function() end,
      handlers = {
        call = function(node, context)
          calls = calls + 1
          return { accepted = context.payload.allow == true }
        end,
        emit = function() return true end,
        branch = function(node, context)
          return context.lastResult[node.field] == node.equals
        end
      }
    })
    local graph = {
      entry = 'request',
      nodes = {
        request = { type = 'call', service = 'synex.example', method = 'request',
          capability = 'synex.example.use', next = 'decision' },
        decision = { type = 'branch', field = 'accepted', equals = true,
          whenTrue = 'done', whenFalse = 'denied' },
        done = { type = 'complete', result = { code = 'OK' } },
        denied = { type = 'fail', code = 'INTERACT_ACTION_FAILED', message = 'Denied' }
      }
    }
    assert(SynexInteractActionGraph.validate(graph))
    local success = assert(engine.execute(graph, { payload = { allow = true } }))
    assert(success.state == 'COMPLETED' and success.result.code == 'OK')
    local _, denied = engine.execute(graph, { payload = { allow = false } })
    assert(denied.code == 'INTERACT_ACTION_FAILED')
    assert(calls == 2)
    return success.state .. ':' .. denied.code
  `);
  assert.equal(result, 'COMPLETED:INTERACT_ACTION_FAILED');
});

test('action graph rejects invalid entry and execution depth overflow', async () => {
  const result = await runInteractLua<string>(String.raw`
    local _, invalid = SynexInteractActionGraph.validate({
      entry = 'missing', nodes = { done = { type = 'complete' } }
    })
    assert(invalid.code == 'INTERACT_GRAPH_INVALID')
    local nodes = {}
    for index = 1, SynexInteractLimits.maximumGraphDepth + 2 do
      local name = 'n' .. tostring(index)
      nodes[name] = { type = 'wait', milliseconds = 0,
        next = index < SynexInteractLimits.maximumGraphDepth + 2 and ('n' .. tostring(index + 1)) or 'done' }
    end
    nodes.done = { type = 'complete' }
    local engine = SynexInteractActionGraph.create({ wait = function() end, handlers = {} })
    local _, depthError = engine.execute({ entry = 'n1', nodes = nodes }, {})
    assert(depthError.code == 'INTERACT_GRAPH_LIMIT')
    return invalid.code .. ':' .. depthError.code
  `);
  assert.equal(result, 'INTERACT_GRAPH_INVALID:INTERACT_GRAPH_LIMIT');
});

test('action graph rejects call nodes without delegated capability', async () => {
  const code = await runInteractLua<string>(String.raw`
    local _, operationError = SynexInteractActionGraph.validate({
      entry = 'call',
      nodes = {
        call = { type = 'call', service = 'synex.example', method = 'mutate', next = 'done' },
        done = { type = 'complete' }
      }
    })
    return operationError.code
  `);
  assert.equal(code, 'INTERACT_GRAPH_INVALID');
});
