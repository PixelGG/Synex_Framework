import assert from 'node:assert/strict';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';
import { bootstrapDomain } from './helpers.js';

test('signed multi-leg validation accepts balanced entries and rejects malformed financial commands', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrapDomain(engine);
    const result = await engine.doString(`
      local a = '11111111-1111-4111-8111-111111111111'
      local b = '22222222-2222-4222-8222-222222222222'
      local c = '33333333-3333-4333-8333-333333333333'
      local balanced = assert(Domain.validatePostings({
        { account_id = a, amount_minor = -75 },
        { account_id = b, amount_minor = 50 },
        { account_id = c, amount_minor = 25 }
      }))
      assert(#balanced == 3 and balanced[1].amountMinor == -75)

      local unbalanced, unbalancedError = Domain.validatePostings({
        { account_id = a, amount_minor = -75 },
        { account_id = b, amount_minor = 74 }
      })
      assert(unbalanced == nil and unbalancedError.code == 'LEDGER_UNBALANCED')

      local duplicate, duplicateError = Domain.validatePostings({
        { account_id = a, amount_minor = -10 },
        { account_id = a, amount_minor = 10 }
      })
      assert(duplicate == nil and duplicateError.code == 'VALIDATION_FAILED')

      local zero, zeroError = Domain.validatePostings({
        { account_id = a, amount_minor = 0 },
        { account_id = b, amount_minor = 0 }
      })
      assert(zero == nil and zeroError.code == 'VALIDATION_FAILED')

      local unsafe, unsafeError = Domain.validatePostings({
        { account_id = a, amount_minor = -9007199254740992 },
        { account_id = b, amount_minor = 9007199254740992 }
      })
      assert(unsafe == nil and unsafeError.code == 'VALIDATION_FAILED')
      return table.concat({ #balanced, unbalancedError.code, duplicateError.code,
        zeroError.code, unsafeError.code }, ':')
    `);
    assert.equal(
      result,
      '3:LEDGER_UNBALANCED:VALIDATION_FAILED:VALIDATION_FAILED:VALIDATION_FAILED',
    );
  } finally {
    engine.global.close();
  }
});

test('thousands of deterministic legal multi-leg commands preserve the zero-sum property', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrapDomain(engine);
    const result = await engine.doString(`
      local ids = {
        '11111111-1111-4111-8111-111111111111',
        '22222222-2222-4222-8222-222222222222',
        '33333333-3333-4333-8333-333333333333',
        '44444444-4444-4444-8444-444444444444'
      }
      local seed = 0x51a7
      local function nextValue(maximum)
        seed = (seed * 1103515245 + 12345) & 0x7fffffff
        return (seed % maximum) + 1
      end
      for iteration = 1, 5000 do
        local first = nextValue(1000000)
        local second = nextValue(1000000)
        local third = nextValue(first + second - 1)
        local postings = assert(Domain.validatePostings({
          { account_id = ids[1], amount_minor = -(first + second) },
          { account_id = ids[2], amount_minor = third },
          { account_id = ids[3], amount_minor = first + second - third }
        }))
        local total = 0
        for _, posting in ipairs(postings) do total = total + posting.amountMinor end
        assert(total == 0)
      end
      return 5000
    `);
    assert.equal(result, 5000);
  } finally {
    engine.global.close();
  }
});

test('refund validation distinguishes partial, multiple, full, and over-refund paths', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrapDomain(engine);
    const result = await engine.doString(`
      local a = '11111111-1111-4111-8111-111111111111'
      local b = '22222222-2222-4222-8222-222222222222'
      local c = '33333333-3333-4333-8333-333333333333'
      local original = {
        { accountId = a, amountMinor = -100 },
        { accountId = b, amountMinor = 80 },
        { accountId = c, amountMinor = 20 }
      }
      local partial = assert(Domain.validatePostings({
        { account_id = a, amount_minor = 20 },
        { account_id = b, amount_minor = -15 },
        { account_id = c, amount_minor = -5 }
      }))
      assert(Domain.validateRefund(original, partial, a, 20, {}))

      local multiple = assert(Domain.validatePostings({
        { account_id = a, amount_minor = 30 },
        { account_id = b, amount_minor = -25 },
        { account_id = c, amount_minor = -5 }
      }))
      assert(Domain.validateRefund(original, multiple, a, 30, {
        [a] = 20, [b] = 15, [c] = 5
      }))

      local full = Domain.invertPostings(original)
      assert(Domain.validateRefund(original, full, a, 100, {}))

      local over, overError = Domain.validateRefund(original, partial, a, 20, {
        [a] = 90, [b] = 70, [c] = 15
      })
      assert(over == nil and overError.code == 'REFUND_LIMIT_EXCEEDED')

      local wrongAnchor, anchorError = Domain.validateRefund(original, partial, b, 20, {})
      assert(wrongAnchor == nil and anchorError.code == 'REFUND_ANCHOR_INVALID')

      local invalid, invalidError = Domain.validateRefund(original, {
        { accountId = a, amountMinor = 10 },
        { accountId = b, amountMinor = 10 }
      }, a, 10, {})
      assert(invalid == nil and invalidError.code == 'REFUND_POSTING_INVALID')
      return table.concat({ overError.code, anchorError.code, invalidError.code }, ':')
    `);
    assert.equal(
      result,
      'REFUND_LIMIT_EXCEEDED:REFUND_ANCHOR_INVALID:REFUND_POSTING_INVALID',
    );
  } finally {
    engine.global.close();
  }
});

test('hold transitions implement single, partial, multiple, release, and terminal semantics', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrapDomain(engine);
    const result = await engine.doString(`
      local partial = assert(Domain.holdTransition({
        state = 'active', remaining_minor = 100, version = 1,
        capture_policy = 'multiple'
      }, 'capture', 40))
      assert(partial.state == 'partially_captured' and partial.remainingMinor == 60
        and partial.nextVersion == 2)

      local captured = assert(Domain.holdTransition({
        state = partial.state, remaining_minor = partial.remainingMinor,
        version = partial.nextVersion, capture_policy = 'multiple'
      }, 'capture', 60))
      assert(captured.state == 'captured' and captured.remainingMinor == 0
        and captured.nextVersion == 3)

      local released = assert(Domain.holdTransition({
        state = 'partially_captured', remaining_minor = 25, version = 4,
        capture_policy = 'multiple'
      }, 'release'))
      assert(released.state == 'released' and released.releasedMinor == 25
        and released.remainingMinor == 0 and released.nextVersion == 5)

      local single, singleError = Domain.holdTransition({
        state = 'active', remaining_minor = 100, version = 1,
        capture_policy = 'single'
      }, 'capture', 40)
      assert(single == nil and singleError.code == 'PARTIAL_CAPTURE_NOT_ALLOWED')

      local excessive, excessiveError = Domain.holdTransition({
        state = 'active', remaining_minor = 50, version = 1,
        capture_policy = 'multiple'
      }, 'capture', 51)
      assert(excessive == nil and excessiveError.code == 'HOLD_CAPTURE_EXCEEDS_REMAINING')

      for _, state in ipairs({ 'captured', 'released', 'expired' }) do
        local terminal, terminalError = Domain.holdTransition({
          state = state, remaining_minor = 0, version = 2,
          capture_policy = 'multiple'
        }, 'capture', 1)
        assert(terminal == nil and terminalError.code == 'HOLD_NOT_ACTIVE')
      end
      return table.concat({ partial.state, captured.state, released.state,
        singleError.code, excessiveError.code }, ':')
    `);
    assert.equal(
      result,
      'partially_captured:captured:released:PARTIAL_CAPTURE_NOT_ALLOWED:HOLD_CAPTURE_EXCEEDS_REMAINING',
    );
  } finally {
    engine.global.close();
  }
});

test('Core caller context prevents resource and system actor spoofing', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrapDomain(engine);
    const result = await engine.doString(`
      local context = { caller = 'synex_shops', traceId = 'trace_12345678', callerEpoch = 4 }
      local default = assert(Domain.context(context, {}))
      assert(default.principalKind == 'resource' and default.principalRef == 'synex_shops')

      local character = assert(Domain.context(context, {
        actor_kind = 'character', actor_ref = 'character:42'
      }))
      assert(character.principalKind == 'character' and character.principalRef == 'character:42')

      local spoofed, spoofedError = Domain.context(context, {
        actor_kind = 'resource', actor_ref = 'synex_banking'
      })
      assert(spoofed == nil and spoofedError.code == 'PRINCIPAL_SPOOFED')

      local invalid, invalidError = Domain.context({
        caller = 'synex_shops', traceId = 'short'
      }, {})
      assert(invalid == nil and invalidError.code == 'CALLER_CONTEXT_INVALID')
      return spoofedError.code .. ':' .. invalidError.code
    `);
    assert.equal(result, 'PRINCIPAL_SPOOFED:CALLER_CONTEXT_INVALID');
  } finally {
    engine.global.close();
  }
});
