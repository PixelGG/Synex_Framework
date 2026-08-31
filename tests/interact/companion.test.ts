import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import test from 'node:test';

async function readJson(path: string): Promise<Record<string, unknown>> {
  return JSON.parse(await readFile(join(process.cwd(), path), 'utf8')) as Record<string, unknown>;
}

test('synex_interact_companion keeps its World and Interaction references closed and side-effect free', async () => {
  const root = 'examples/synex_interact_companion';
  const manifest = await readJson(`${root}/synex.resource.json`);
  const world = await readJson(`${root}/world/terminal.world.json`);
  const interaction = await readJson(`${root}/interactions/terminal.interact.json`);

  assert.equal(manifest.name, 'synex_interact_companion');
  assert.deepEqual((manifest.capabilities as { request: string[] }).request, [
    'synex.interact.bundle.register',
    'synex.world.bundle.register',
  ]);

  const worldObjects = world.objects as Array<{ kind: string; key: string }>;
  const anchor = worldObjects.find((entry) => entry.kind === 'anchor');
  const smartObjects = interaction.smartObjects as Array<{
    binding: { type: string; key: string };
    activities: string[];
  }>;
  const intents = interaction.intents as Array<{
    key: string;
    actionGraphRef: string;
  }>;
  const graphs = interaction.graphs as Array<{
    key: string;
    nodes: Array<{ type: string }>;
  }>;

  assert.equal(smartObjects[0]?.binding.type, 'worldAnchor');
  assert.equal(smartObjects[0]?.binding.key, anchor?.key);
  assert.equal(smartObjects[0]?.activities[0], intents[0]?.key);
  assert.equal(intents[0]?.actionGraphRef, graphs[0]?.key);
  assert.equal(graphs[0]?.nodes.some((node) =>
    node.type === 'serviceCall' || node.type === 'contractCall' || node.type === 'commit'
  ), false);
});
