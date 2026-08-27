import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';

const root = process.cwd();

test('resource-stop cleanup captures and forwards one immutable owner epoch', async () => {
  const [main, runtimeRegistration, persistence] = await Promise.all([
    readFile(path.join(root, 'resources/synex_groups/server/main.lua'), 'utf8'),
    readFile(path.join(root, 'resources/synex_groups/server/runtime_registration.lua'), 'utf8'),
    readFile(path.join(root, 'resources/synex_groups/server/persistence.lua'), 'utf8'),
  ]);

  assert.match(
    runtimeRegistration,
    /local function scheduleExtensionOwnerCleanup\(resourceName, stoppedEpoch, generation, attempt\)/u,
  );
  assert.match(
    runtimeRegistration,
    /extensionRegistries:disableOwner\(\s*resourceName, stoppedEpoch\)/u,
  );
  assert.match(
    runtimeRegistration,
    /scheduleExtensionOwnerCleanup\(\s*resourceName, stoppedEpoch, generation, exponent \+ 1\)/u,
  );
  assert.match(
    runtimeRegistration,
    /local stoppedEpoch = observedExtensionOwnerEpochs\[resourceName\][\s\S]*?observedExtensionOwnerEpochs\[resourceName\] = nil/u,
  );
  assert.match(
    main,
    /observeRegistryOwner = function\(owner, epoch\)[\s\S]*?observedExtensionOwnerEpochs\[owner\] = epoch/u,
  );
  assert.match(
    runtimeRegistration,
    /stoppedExtensionOwnerEpochHighWater\[resourceName\] = stoppedEpoch[\s\S]*?scheduleExtensionOwnerCleanup\(resourceName, stoppedEpoch, generation, 0\)/u,
  );
  assert.match(
    main,
    /isRegistryOwnerEpochActive = function\(owner, epoch\)[\s\S]*?epoch > stoppedEpoch/u,
  );
  assert.match(
    persistence,
    /operation == 'registries_begin'[\s\S]*?observeRegistryOwner\([\s\S]*?context and context\.callerEpoch/u,
  );
  assert.match(
    persistence,
    /registryMutationOperations\[operation\][\s\S]*?runtime\.requireRegistryOwnerEpoch\([\s\S]*?executionContext\.callerEpoch/u,
  );
  assert.doesNotMatch(
    `${main}\n${runtimeRegistration}`,
    /scheduleExtensionOwnerCleanup\(resourceName, generation,/u,
  );
});
