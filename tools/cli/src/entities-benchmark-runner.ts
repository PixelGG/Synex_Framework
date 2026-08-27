import { readFile } from "node:fs/promises";
import { basename, dirname, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

import { LuaFactory, type LuaEngine } from "wasmoon";

interface RawLuaMeasurement {
  samplesMilliseconds: number[];
  checksum: number;
}

export interface RawEntitiesLuaReport {
  measurements: Record<string, RawLuaMeasurement>;
  checksum: number;
}

const moduleRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");
const repositoryRoot = basename(moduleRoot) === ".build" ? resolve(moduleRoot, "..") : moduleRoot;

const modules = [
  ["shared.validation", "resources/synex_entities/shared/validation.lua"],
  ["server.ordered_index", "resources/synex_entities/server/ordered_index.lua"],
  ["server.spatial_index", "resources/synex_entities/server/spatial_index.lua"],
  ["server.registry", "resources/synex_entities/server/registry.lua"],
  ["server.extension_repository", "resources/synex_entities/server/extension_repository.lua"],
] as const;

async function preload(engine: LuaEngine, name: string, relativePath: string): Promise<void> {
  const source = await readFile(resolve(repositoryRoot, relativePath), "utf8");
  await engine.doString(
    `package.preload[${JSON.stringify(name)}] = assert(load(${JSON.stringify(source)}, ${JSON.stringify(`@${relativePath}`)}))`,
  );
}

export async function runEntitiesLuaBenchmark(
  iterations: number,
  samples: number,
  seed: number,
): Promise<RawEntitiesLuaReport> {
  if (!Number.isInteger(iterations) || iterations < 1 || iterations > 100_000
    || !Number.isInteger(samples) || samples < 1 || samples > 20
    || !Number.isInteger(seed) || seed < 0 || seed > 0xffff_ffff) {
    throw new Error("Entities Lua benchmark parameters are outside supported bounds.");
  }
  const engine = await new LuaFactory().createEngine();
  try {
    for (const [name, relativePath] of modules) await preload(engine, name, relativePath);
    return await engine.doString(`
      require 'shared.validation'
      require 'server.ordered_index'
      require 'server.spatial_index'
      require 'server.registry'
      require 'server.extension_repository'

      local fixtureCount = 1024
      local resourceOwner = 'synex_benchmark'
      local registry = SynexEntityRegistry.new({
        spatial = {
          cellSize = 32,
          maximumEntries = 2048,
          maximumRadius = 256,
          maximumResults = 32,
          maximumScannedCells = 1024,
          maximumCandidates = 512,
        }
      })
      local records = {}
      local stateRows = {}
      local stateKey = 'synex_benchmark.health'

      for number = 0, fixtureCount - 1 do
        local entityId = string.format('entity_benchmark_%04d', number)
        local bucket = (number % 64) + 1
        local ownerId = string.format('character_benchmark_%03d', number % 128)
        local record = {
          entityId = entityId,
          generation = 1,
          resourceOwner = resourceOwner,
          netId = number + 1,
          handle = number + 10001,
          bucket = bucket,
          owner = { type = 'character', id = ownerId },
          position = {
            x = (bucket - 1) * 128 + ((number // 64) % 4) * 8,
            y = (number // 256) * 8,
            z = 20,
          },
          binding = {
            namespace = 'synex_benchmark.entities',
            ref = string.format('binding_%04d', number),
          },
          status = 'active',
          version = (number % 17) + 1,
        }
        local inserted, insertError = registry.insert(record)
        assert(inserted and not insertError)
        records[number + 1] = inserted
        stateRows[entityId] = {
          state_key = stateKey,
          owner_resource = resourceOwner,
          schema_version = 1,
          authority_mode = 'server',
          replication_mode = 'scoped',
          value_json = string.format('{"fixture":%d}', number),
          version = (number % 23) + 1,
          updated_at = '2026-01-01 00:00:00.000000',
        }
      end

      local database = {
        query = function(_, parameters)
          local row = stateRows[parameters[1]]
          if not row or parameters[2] ~= stateKey then return {} end
          return { row }
        end,
      }
      local foundation = {
        failure = function(code, message, retryable, context)
          return nil, {
            code = code,
            message = message,
            retryable = retryable == true,
            traceId = context and context.traceId or nil,
          }
        end,
        reportUnexpected = function(_, caught) error(caught) end,
      }
      local health = {}
      local extensionRepository = SynexEntityExtensionRepository.create({
        database = database,
        foundation = foundation,
        health = health,
      })
      local context = { traceId = 'trace_entities_benchmark_0001' }
      local spawnRequest = {
        entityType = 'object',
        model = 123456789,
        position = { x = 100.25, y = -200.5, z = 30.75 },
        heading = 90.0,
        bucket = 0,
        bucketGeneration = 0,
        owner = { type = 'resource', id = resourceOwner },
        persistencePolicy = 'temporary',
        recoveryPolicy = 'none',
        reasonCode = 'synex_benchmark.spawn',
      }

      local function fixture(index)
        return records[((index + ${seed}) % fixtureCount) + 1]
      end

      local workloads = {
        entities_entity_ref_lookup = function(index)
          local expected = fixture(index)
          local value, valueError = registry.resolveRef({
            entityId = expected.entityId,
            generation = expected.generation,
          }, resourceOwner)
          assert(value and not valueError)
          return value.version
        end,
        entities_net_id_resolve = function(index)
          local expected = fixture(index)
          local value, generation = registry.byNetId(expected.netId)
          assert(value and generation == expected.generation)
          return value.version
        end,
        entities_binding_lookup = function(index)
          local expected = fixture(index)
          local value, valueError = registry.byBinding(
            expected.binding.namespace, expected.binding.ref, resourceOwner)
          assert(value and not valueError)
          return value.version
        end,
        entities_owner_lookup = function(index)
          local expected = fixture(index)
          local values = registry.forLogicalOwner(expected.owner.type, expected.owner.id)
          assert(#values == 8)
          return values[1].version + #values
        end,
        entities_spawn_validation = function()
          local value, valueError = SynexEntityValidation.validateSpawn(spawnRequest)
          assert(value and not valueError)
          return value.model & 0xffff
        end,
        entities_state_lookup = function(index)
          local expected = fixture(index)
          local value, valueError = extensionRepository.getState(
            expected.entityId, stateKey, context)
          assert(value and not valueError and value.key == stateKey)
          return value.version
        end,
        entities_bucket_lookup = function(index)
          local expected = fixture(index)
          local values = registry.forBucket(expected.bucket)
          assert(#values == 16)
          return values[1].version + #values
        end,
        entities_nearby_query = function(index)
          local expected = fixture(index)
          local values, query = registry.nearby(
            expected.position, 24, expected.bucket, 16)
          assert(values and query and #values >= 1)
          return #values + query.candidates + query.scannedCells
        end,
      }

      local names = {
        'entities_entity_ref_lookup',
        'entities_net_id_resolve',
        'entities_binding_lookup',
        'entities_owner_lookup',
        'entities_spawn_validation',
        'entities_state_lookup',
        'entities_bucket_lookup',
        'entities_nearby_query',
      }
      local report = { measurements = {}, checksum = 0 }
      local warmup = math.min(${iterations}, 1000)
      for _, name in ipairs(names) do
        local operation = workloads[name]
        local workloadChecksum = 0
        for index = 0, warmup - 1 do
          workloadChecksum = (workloadChecksum + operation(index)) & 0xffffffff
        end
        local elapsed = {}
        for sample = 1, ${samples} do
          local started = os.clock()
          for index = 0, ${iterations} - 1 do
            workloadChecksum = (workloadChecksum + operation(index)) & 0xffffffff
          end
          elapsed[sample] = math.max(0, (os.clock() - started) * 1000)
        end
        report.measurements[name] = {
          samplesMilliseconds = elapsed,
          checksum = workloadChecksum,
        }
        report.checksum = (report.checksum + workloadChecksum) & 0xffffffff
      end
      return report
    `) as RawEntitiesLuaReport;
  } finally {
    engine.global.close();
  }
}

const invoked = process.argv[1]
  ? pathToFileURL(resolve(process.argv[1])).href === import.meta.url
  : false;

if (invoked) {
  const iterations = Number(process.argv[2]);
  const samples = Number(process.argv[3]);
  const seed = Number(process.argv[4]);
  try {
    const report = await runEntitiesLuaBenchmark(iterations, samples, seed);
    process.stdout.write(JSON.stringify(report));
  } catch (error) {
    process.stderr.write(error instanceof Error ? error.message : "Entities Lua benchmark failed.");
    process.exitCode = 1;
  }
}
