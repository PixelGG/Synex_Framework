import assert from 'node:assert/strict';
import test from 'node:test';

import { extractSynexSqlTableReferences } from '../../tools/cli/src/operations.ts';

test('certification distinguishes Synex table references from similarly named columns', () => {
  const sql = `
    SELECT identity.\`synex_character_id\`
    FROM \`synex_compatibility_identities\` AS identity
    JOIN \`synex_compatibility_metadata\` AS metadata
      ON metadata.\`synex_character_id\` = identity.\`synex_character_id\`
    WHERE identity.\`synex_character_id\` = ?
  `;

  assert.deepEqual(extractSynexSqlTableReferences(sql), [
    'synex_compatibility_identities',
    'synex_compatibility_metadata',
  ]);
});

test('certification recognizes bounded table positions across write statements', () => {
  const sql = `
    INSERT INTO \`synex_first\` (\`synex_column\`) VALUES (?);
    UPDATE \`synex_second\` SET \`synex_column\` = ?;
    DELETE FROM \`synex_third\` WHERE \`synex_column\` = ?;
    CREATE TABLE \`synex_fourth\` (\`synex_column\` INT NOT NULL);
  `;

  assert.deepEqual(extractSynexSqlTableReferences(sql), [
    'synex_first',
    'synex_fourth',
    'synex_second',
    'synex_third',
  ]);
});
