import assert from 'node:assert/strict';
import test from 'node:test';
import { LuaFactory } from 'wasmoon';
import { bootstrapControlLua } from '../control/helpers.js';

test('Synex Control masks Accounts identifiers without changing financial read values', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrapControlLua(engine);
    const result = await engine.doString(`
      local transactionId = '11111111-1111-4111-8111-111111111111'
      local value, report = SynexControlSanitizer.sanitize({
        transaction = {
          transaction_id = transactionId,
          currency_id = '22222222-2222-4222-8222-222222222222',
          caller_principal_ref = 'character:private-owner-0001',
          reference_id = 'group:private-reference-0001',
          entry_count = '16', amount_minor = '9007199254740991',
          available_minor = '-125', currency_code = 'credits',
        },
        entries = { items = {{
          entry_id = '33333333-3333-4333-8333-333333333333',
          account_id = '44444444-4444-4444-8444-444444444444',
          owner_ref = 'character:private-owner-0001', amount_minor = '-125',
        }}},
        refunds = { items = {{
          original_transaction_id = transactionId,
          refund_transaction_id = '55555555-5555-4555-8555-555555555555',
          cumulative_refunded_minor = '125',
        }}},
        connection_string = 'mysql://private',
      })
      assert(value.transaction.transaction_id == '1111...1111')
      assert(value.transaction.currency_id == '22222222-2222-4222-8222-222222222222')
      assert(value.transaction.caller_principal_ref == 'char...0001')
      assert(value.transaction.reference_id == 'grou...0001')
      assert(value.entries.items[1].entry_id == '3333...3333')
      assert(value.entries.items[1].account_id == '4444...4444')
      assert(value.entries.items[1].owner_ref == 'char...0001')
      assert(value.refunds.items[1].original_transaction_id == '1111...1111')
      assert(value.refunds.items[1].refund_transaction_id == '5555...5555')
      assert(value.transaction.entry_count == '16')
      assert(value.transaction.amount_minor == '9007199254740991')
      assert(value.transaction.available_minor == '-125')
      assert(value.entries.items[1].amount_minor == '-125')
      assert(value.refunds.items[1].cumulative_refunded_minor == '125')
      assert(value.connection_string == '[REDACTED]')
      assert(report.masked == 8 and report.redactions == 1)
      return value.transaction.amount_minor
    `);
    assert.equal(result, '9007199254740991');
  } finally {
    engine.global.close();
  }
});

test('identifier ACE projection reveals identifiers but never Accounts secrets', async () => {
  const engine = await new LuaFactory().createEngine();
  try {
    await bootstrapControlLua(engine);
    const result = await engine.doString(`
      local value = SynexControlSanitizer.sanitize({
        account_id = '44444444-4444-4444-8444-444444444444',
        transaction_id = '11111111-1111-4111-8111-111111111111',
        api_key = 'private-api-value',
        password_hash = 'private-hash',
      }, { revealIdentifiers = true })
      assert(value.account_id == '44444444-4444-4444-8444-444444444444')
      assert(value.transaction_id == '11111111-1111-4111-8111-111111111111')
      assert(value.api_key == '[REDACTED]')
      assert(value.password_hash == '[REDACTED]')
      return value.account_id
    `);
    assert.equal(result, '44444444-4444-4444-8444-444444444444');
  } finally {
    engine.global.close();
  }
});
