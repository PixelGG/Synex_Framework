import { readFile } from "node:fs/promises";
import { basename, dirname, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

import { LuaFactory, type LuaEngine } from "wasmoon";

interface RawLuaMeasurement {
  samplesMilliseconds: number[];
  checksum: number;
}

export interface RawWorldLuaReport {
  measurements: Record<string, RawLuaMeasurement>;
  checksum: number;
  fixture: {
    anchors: number;
    zones: number;
    doors: number;
    locations: number;
    total: number;
  };
}

const moduleRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");
const repositoryRoot = basename(moduleRoot) === ".build" ? resolve(moduleRoot, "..") : moduleRoot;

const modules = [
  "resources/synex_world/shared/limits.lua",
  "resources/synex_world/shared/validation.lua",
  "resources/synex_world/server/geometry.lua",
  "resources/synex_world/server/spatial_index.lua",
  "resources/synex_world/server/graph.lua",
  "resources/synex_world/server/compiler.lua",
  "resources/synex_world/server/registry.lua",
  "resources/synex_world/server/context.lua",
  "resources/synex_world/server/access.lua",
] as const;

async function loadModule(engine: LuaEngine, relativePath: string): Promise<void> {
  const source = await readFile(resolve(repositoryRoot, relativePath), "utf8");
  await engine.doString(source);
}

export async function runWorldLuaBenchmark(
  iterations: number,
  samples: number,
  seed: number,
): Promise<RawWorldLuaReport> {
  if (!Number.isInteger(iterations) || iterations < 1 || iterations > 5_000
    || !Number.isInteger(samples) || samples < 1 || samples > 20
    || !Number.isInteger(seed) || seed < 0 || seed > 0xffff_ffff) {
    throw new Error("World Lua benchmark parameters are outside supported bounds.");
  }
  const engine = await new LuaFactory().createEngine();
  try {
    for (const relativePath of modules) await loadModule(engine, relativePath);
    return await engine.doString(`
      local fixtureCounts = {
        anchors = 50000, zones = 10000, doors = 5000, locations = 1000,
      }
      fixtureCounts.total = fixtureCounts.anchors + fixtureCounts.zones
        + fixtureCounts.doors + fixtureCounts.locations

      local spatial = SynexWorldSpatialIndex.create({
        maximumQueryCandidates = 4096,
        maximumCellsPerObject = 64,
        maximumGlobalObjects = 128,
      })
      local scaleObjects = {}
      local function insertFixtures(kind, amount, spacing, radius)
        local columns = math.max(1, math.min(500, math.floor(38000 / spacing)))
        for current = 1, amount do
          local x = ((current - 1) % columns) * spacing - 19000
          local y = math.floor((current - 1) / columns) * spacing - 19000
          local key = ('synex_benchmark:%s.%06d'):format(kind, current)
          local object = { kind = kind, key = key, revision = 1 }
          local compiled = assert(SynexWorldGeometry.compile({
            type = 'sphere', center = { x = x, y = y, z = 20 }, radius = radius,
          }))
          assert(spatial.insert(key, object, compiled))
          scaleObjects[key] = object
        end
      end
      insertFixtures('anchor', fixtureCounts.anchors, 40, 0.25)
      insertFixtures('zone', fixtureCounts.zones, 80, 12)
      insertFixtures('door', fixtureCounts.doors, 60, 2)
      insertFixtures('location', fixtureCounts.locations, 300, 80)
      assert(spatial.count() == fixtureCounts.total)

      local scaleRegistry = {
        spatial = function() return spatial end,
        currentRevision = function() return 1 end,
        objects = function() return scaleObjects end,
        ref = function(object)
          return { kind = object.kind, key = object.key, revision = object.revision }
        end,
      }
      local scaleContext = SynexWorldContext.create({ registry = scaleRegistry })

      local registry = SynexWorldRegistry.create({})
      assert(registry.registerBundle({
        schema = 1,
        key = 'synex_benchmark:runtime',
        version = '1.0.0',
        dependencies = {},
        objects = {
          {
            kind = 'location', key = 'synex_benchmark:location',
            geometry = { type = 'sphere', center = { x = 0, y = 0, z = 20 }, radius = 50 },
          },
          {
            kind = 'anchor', key = 'synex_benchmark:anchor',
            parent = 'synex_benchmark:location',
            position = { x = 1, y = 1, z = 20 }, radius = 1,
            tags = { 'synex.benchmark.anchor' },
          },
          {
            kind = 'door', key = 'synex_benchmark:door',
            parent = 'synex_benchmark:location',
            position = { x = 2, y = 2, z = 20 }, heading = 0,
            leaves = { {
              id = 'primary', model = 123456,
              position = { x = 2, y = 2, z = 20 }, heading = 0,
            } },
            defaultState = 'LOCKED', persistent = false,
            accessPolicy = {
              requiredCapability = 'synex.benchmark.enter',
              groupId = 'group_benchmark_world', scope = 'group',
            },
          },
        },
      }, 'synex_benchmark', 1))
      local anchor = assert(registry.get('synex_benchmark:anchor', 'anchor'))
      local door = assert(registry.get('synex_benchmark:door', 'door'))
      local anchorRef, doorRef = registry.ref(anchor), registry.ref(door)
      local session = {
        state = 'ACTIVE', id = 'session_benchmark_world', source = 71,
        sourceGeneration = 4, characterId = 'character_benchmark_world',
      }
      local access = SynexWorldAccess.create({
        registry = registry,
        mapRegistry = {
          objectAvailability = function() return { available = true } end,
          summary = function() return { generation = 1 } end,
        },
        getPlayer = function(source)
          assert(source == session.source)
          return session
        end,
        groupCapability = function(request)
          assert(request.character_id == session.characterId
            and request.capability == 'synex.benchmark.enter')
          return { decision = 'ALLOW', reason = 'CAPABILITY_GRANTED' }
        end,
        getState = function() error('benchmark access policy has no state gate') end,
        getDoorState = function() return { state = 'LOCKED' } end,
        getInstanceForSource = function() return nil end,
      })

      local function point(index)
        local current = ((index + ${seed}) % fixtureCounts.anchors) + 1
        return {
          x = ((current - 1) % 500) * 40 - 19000,
          y = math.floor((current - 1) / 500) * 40 - 19000,
          z = 20,
        }
      end
      local workloads = {
        world_query_at = function(index)
          local values, metadata = assert(scaleContext.queryAt(point(index), nil, 64))
          return #values + metadata.candidates
        end,
        world_query_nearby_10m = function(index)
          local values, metadata = assert(scaleContext.queryNearby(point(index), 10, nil, 64))
          return #values + metadata.candidates
        end,
        world_query_nearby_100m = function(index)
          local values, metadata = assert(scaleContext.queryNearby(point(index), 100, nil, 64))
          return #values + metadata.candidates
        end,
        world_context_resolve = function(index)
          local value = assert(scaleContext.resolve(point(index)))
          return #value.regions + #value.zones + (value.location and 1 or 0)
        end,
        world_anchor_resolve = function()
          local value = assert(registry.resolve(anchorRef, 'anchor'))
          return value.revision
        end,
        world_door_resolve = function()
          local value = assert(registry.resolve(doorRef, 'door'))
          return value.revision
        end,
        world_access_check = function()
          local decision = assert(access.check({
            targetRef = doorRef, source = session.source,
          }, { caller = 'synex_benchmark', callerEpoch = 1,
            traceId = 'trace_world_benchmark_0001' }))
          assert(decision.decision == 'ALLOW')
          return 1
        end,
      }
      local names = {
        'world_query_at',
        'world_query_nearby_10m',
        'world_query_nearby_100m',
        'world_context_resolve',
        'world_anchor_resolve',
        'world_door_resolve',
        'world_access_check',
      }
      local report = { measurements = {}, checksum = 0, fixture = fixtureCounts }
      local warmup = math.min(${iterations}, 250)
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
    `) as RawWorldLuaReport;
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
    const report = await runWorldLuaBenchmark(iterations, samples, seed);
    process.stdout.write(JSON.stringify(report));
  } catch (error) {
    process.stderr.write(error instanceof Error ? error.message : "World Lua benchmark failed.");
    process.exitCode = 1;
  }
}
