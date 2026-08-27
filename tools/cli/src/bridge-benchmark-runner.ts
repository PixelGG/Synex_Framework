import { readFile } from "node:fs/promises";
import { basename, dirname, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

import { LuaFactory } from "wasmoon";

interface RawLuaMeasurement {
  samplesMilliseconds: number[];
  checksum: number;
}

export interface RawBridgeLuaReport {
  measurements: Record<string, RawLuaMeasurement>;
  checksum: number;
}

const moduleRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");
const repositoryRoot = basename(moduleRoot) === ".build" ? resolve(moduleRoot, "..") : moduleRoot;

const modules = [
  "foundation.lua",
  "catalogs.lua",
  "mappings.lua",
  "telemetry.lua",
  "resolver.lua",
  "runtime.lua",
] as const;

export async function runBridgeLuaBenchmark(
  iterations: number,
  samples: number,
  seed: number,
): Promise<RawBridgeLuaReport> {
  if (!Number.isInteger(iterations) || iterations < 1 || iterations > 100_000
    || !Number.isInteger(samples) || samples < 1 || samples > 20
    || !Number.isInteger(seed) || seed < 0 || seed > 0xffff_ffff) {
    throw new Error("Bridge Lua benchmark parameters are outside supported bounds.");
  }

  const engine = await new LuaFactory().createEngine();
  try {
    for (const moduleName of modules) {
      const relativePath = `libraries/synex_bridge/kernel/${moduleName}`;
      await engine.doString(await readFile(resolve(repositoryRoot, relativePath), "utf8"));
    }

    return await engine.doString(`
      local Foundation = SynexBridgeKernel.Foundation
      local mappingCount = 64
      local mappings = SynexBridgeKernel.Mappings.create({ limits = {
        maximumEntries = 256,
        maximumEntriesPerOwner = 256,
        maximumOwners = 1,
      } })
      for number = 0, mappingCount - 1 do
        local alias = string.format('cash_%03d', number)
        assert(mappings.accounts:register('synex_bridge', 1, {
          id = 'qb.account.' .. alias,
          version = '1.0.0',
          provider = 'qb',
          alias = alias,
          currencyCode = 'usd',
          accountKey = string.format('account_%03d', number),
          accountRole = 'asset',
          minorUnit = 2,
          status = 'PARTIAL',
          fundingPolicy = { kind = 'deny' },
          sinkPolicy = { kind = 'deny' },
        }))
      end

      local projection = {
        source = 42,
        character = {
          id = 'character_benchmark_0001', slot = 1,
          firstName = 'Synex', lastName = 'Benchmark', dateOfBirth = '2000-01-01',
        },
        identity = { citizenid = 'legacy_benchmark_0001' },
        money = { cash = 125000, bank = 875000 },
        groups = {
          job = { name = 'unemployed', grade = 0, onduty = false },
          gang = { name = 'none', grade = 0 },
        },
        metadata = { hunger = 80, thirst = 75, isdead = false },
        metadataVersions = { hunger = 3, thirst = 4, isdead = 1 },
        fence = {
          sessionId = 'session_benchmark_0001', sourceGeneration = 7,
          characterId = 'character_benchmark_0001',
        },
        revision = 11,
      }
      local callbackArguments = {
        'fixture.action',
        { amount = 75, metadata = { reason = 'benchmark', approved = true } },
        true,
      }

      local runtime = SynexBridgeKernel.Runtime.create()
      assert(runtime.adapters:register('synex_bridge_qb', 1, {
        name = 'qb.player', version = '1.0.0', provider = 'qb', domain = 'identity',
        status = 'PARTIAL', operations = { 'read' },
      }, { read = function(value) return value + 1 end }))
      assert(runtime.resolver:configure('synex_bridge', 1, {
        defaultMode = 'compat',
        providers = { qb = true },
        profiles = { {
          id = 'qb.benchmark', version = '1.0.0', provider = 'qb',
          status = 'PARTIAL', mode = 'compat', failurePolicy = 'fail_start',
          providerVersion = '0.1.0', targetFrameworkApiRange = '^7.0.0',
          script = { name = 'legacy_benchmark' },
          evidence = {
            tests = { 'compatibility/evidence/qb-benchmark.test.json' },
            sourceUrls = { 'https://example.invalid/qb-benchmark' },
          },
          requiredSurfaces = { {
            name = 'QBCore.Functions.GetPlayer', acceptedStatuses = { 'PARTIAL' },
          } },
          requiredAdapters = { { name = 'qb.player', versionRange = '^1.0.0' } },
          requiredCatalogs = {},
        } },
        surfaces = { {
          name = 'QBCore.Functions.GetPlayer', provider = 'qb', status = 'PARTIAL',
          modes = { 'compat' }, deprecated = false,
          requiredCapability = 'synex.compat.qb.read', requiredAdapter = 'qb.player',
          adapterOperations = { {
            name = 'read', nativeCapabilities = { 'synex.identity.read' },
          } },
          catalogOperations = {},
        } },
        consumers = { {
          resource = 'legacy_benchmark', provider = 'qb', mode = 'compat',
          profileId = 'qb.benchmark', failurePolicy = 'fail_start', enabled = true,
        } },
      }))

      local telemetry = SynexBridgeKernel.Telemetry.create({
        maximumOwners = 1,
        maximumSeries = 1,
        maximumSeriesPerOwner = 1,
        maximumWarningKeys = 1,
      })

      local workloads = {
        bridge_projection_copy = function()
          local copied, copyError = Foundation.copyDto(projection, {
            root = 'object', maximumDepth = 10, maximumEntries = 2048,
            maximumBytes = 262144, maximumStringBytes = 4096,
            maximumArrayItems = 128, maximumObjectProperties = 128,
          })
          assert(copied and not copyError and copied ~= projection)
          return copied.money.cash + copied.revision
        end,
        bridge_callback_argument_validation = function()
          local copied, copyError = Foundation.copyDto(callbackArguments, {
            root = 'array', maximumDepth = 6, maximumEntries = 192,
            maximumBytes = 16384, maximumStringBytes = 1024,
            maximumArrayItems = 16, maximumObjectProperties = 192,
          })
          assert(copied and not copyError and #copied == 3)
          return #copied + copied[2].amount
        end,
        bridge_account_mapping_resolve = function(index)
          local alias = string.format('cash_%03d', (index + ${seed}) % mappingCount)
          local mapping, mappingError = mappings:resolveAccount('qb', alias)
          assert(mapping and not mappingError and mapping.alias == alias)
          return mapping.minorUnit + #mapping.accountKey
        end,
        bridge_surface_resolve = function(index)
          local resolution, resolveError = runtime.resolver:resolve(
            'legacy_benchmark', 'QBCore.Functions.GetPlayer', 'read')
          assert(resolution and not resolveError and resolution.provider == 'qb')
          return resolution.handler(index & 0xffff) + #resolution.surface.name
        end,
        bridge_telemetry_record = function(index)
          local recorded, recordError = telemetry:record(
            'legacy_benchmark', 1, 'QBCore.Functions.GetPlayer',
            index % 8 == 0 and 'error' or 'success', index % 32)
          assert(recorded and not recordError)
          return 1
        end,
      }
      local names = {
        'bridge_projection_copy',
        'bridge_callback_argument_validation',
        'bridge_account_mapping_resolve',
        'bridge_surface_resolve',
        'bridge_telemetry_record',
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

      local snapshot = assert(telemetry:snapshot('legacy_benchmark', 1))
      assert(snapshot.count == 1 and snapshot.series[1].count > 0
        and snapshot.truncated == false)
      return report
    `) as RawBridgeLuaReport;
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
    const report = await runBridgeLuaBenchmark(iterations, samples, seed);
    process.stdout.write(JSON.stringify(report));
  } catch (error) {
    process.stderr.write(error instanceof Error ? error.message : "Bridge Lua benchmark failed.");
    process.exitCode = 1;
  }
}
