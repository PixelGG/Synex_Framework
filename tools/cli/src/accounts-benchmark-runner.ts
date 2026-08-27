import { readFile } from "node:fs/promises";
import { basename, dirname, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

import { LuaFactory, type LuaEngine } from "wasmoon";

interface RawLuaMeasurement {
  samplesMilliseconds: number[];
  checksum: number;
}

export interface RawAccountsLuaReport {
  measurements: Record<string, RawLuaMeasurement>;
  checksum: number;
}

const moduleRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");
const repositoryRoot = basename(moduleRoot) === ".build" ? resolve(moduleRoot, "..") : moduleRoot;

const modules = [
  ["server.foundation", "resources/synex_accounts/server/foundation.lua"],
  ["server.domain", "resources/synex_accounts/server/domain.lua"],
  ["server.service_v2.runtime", "resources/synex_accounts/server/service_v2/runtime.lua"],
  ["server.service_v2.catalog_accounts", "resources/synex_accounts/server/service_v2/catalog_accounts.lua"],
  ["server.service_v2.transactions_holds", "resources/synex_accounts/server/service_v2/transactions_holds.lua"],
  ["server.service_v2.access_policy", "resources/synex_accounts/server/service_v2/access_policy.lua"],
  ["server.service_v2.integrity", "resources/synex_accounts/server/service_v2/integrity.lua"],
  ["server.service_v2.guard", "resources/synex_accounts/server/service_v2/guard.lua"],
  ["server.service_v2", "resources/synex_accounts/server/service_v2.lua"],
] as const;

async function preload(engine: LuaEngine, name: string, relativePath: string): Promise<void> {
  const source = await readFile(resolve(repositoryRoot, relativePath), "utf8");
  await engine.doString(
    `package.preload[${JSON.stringify(name)}] = assert(load(${JSON.stringify(source)}, ${JSON.stringify(`@${relativePath}`)}))`,
  );
}

export async function runAccountsLuaBenchmark(
  iterations: number,
  samples: number,
  seed: number,
): Promise<RawAccountsLuaReport> {
  if (!Number.isInteger(iterations) || iterations < 1 || iterations > 100_000
    || !Number.isInteger(samples) || samples < 1 || samples > 20
    || !Number.isInteger(seed) || seed < 0 || seed > 0xffff_ffff) {
    throw new Error("Accounts Lua benchmark parameters are outside supported bounds.");
  }
  const engine = await new LuaFactory().createEngine();
  try {
    for (const [name, relativePath] of modules) await preload(engine, name, relativePath);
    return await engine.doString(`
      local Foundation = require 'server.foundation'
      local Domain = require('server.domain')(Foundation)
      local createService = require('server.service_v2')(Foundation, Domain)

      local function encodePrimitive(value)
        if type(value) == 'string' then
          return string.format('%q', value)
        end
        if type(value) == 'boolean' then return value and 'true' or 'false' end
        if type(value) == 'number' then return tostring(value) end
        if value == nil then return 'null' end
        error('benchmark encoder received a non-primitive value')
      end

      local accountId = '11111111-1111-4111-8111-111111111111'
      local destinationId = '22222222-2222-4222-8222-222222222222'
      local holdId = '33333333-3333-4333-8333-333333333333'
      local transactionId = '44444444-4444-4444-8444-444444444444'
      local runId = '55555555-5555-4555-8555-555555555555'
      local authority = 'synex_benchmark'
      local auditCount = 0
      local db = {}

      function db:getAccount()
        return { account_id = accountId, status = 'active', booked_minor = 100000,
          reserved_minor = 25000, available_minor = 75000, version = 7 }, nil
      end
      function db:checkAccess(command)
        return { accountId = command.accountId, principalKind = command.principalKind,
          principalRef = command.principalRef, permission = command.permission,
          accountState = 'active', resourceCapability = true, owner = true,
          grantActive = false, permissionGranted = true, allowed = true,
          reason = 'OWNER', bookedMinor = 100000, reservedMinor = 25000,
          availableMinor = 75000 }, nil
      end
      function db:postTransaction(command)
        return { transaction_id = transactionId, transaction_kind = command.kind,
          entry_count = #command.entries, status = 'posted' }, nil
      end
      function db:createHoldV2(command)
        return { hold_id = holdId, account_id = command.accountId,
          capture_account_id = command.captureAccountId, state = 'active',
          amount_minor = command.amountMinor, captured_minor = 0,
          released_minor = 0, remaining_minor = command.amountMinor,
          capture_policy = command.capturePolicy, version = 1 }, nil
      end
      function db:captureHoldV2(command)
        return { hold_id = holdId, state = 'partially_captured',
          amount_minor = 1000, captured_minor = command.amountMinor,
          released_minor = 0, remaining_minor = 1000 - command.amountMinor,
          transaction_id = transactionId, version = 2 }, nil
      end
      function db:runReconciliationV2()
        return { run_id = runId, currency_code = 'credits', status = 'healthy',
          finding_count = 0, transaction_count = '1024', entry_count = '2048' }, nil
      end

      local service = createService({
        db = db,
        jsonEncode = encodePrimitive,
        jsonDecode = function() return {} end,
        hooks = { run = function(_, value) return value, nil end },
        audit = { append = function() auditCount = auditCount + 1 return true, nil end },
        checkResourceCapability = function() return true, nil end,
        errorSink = function(event) error(event.code or 'benchmark service failure') end,
      })
      local context = {
        caller = authority,
        callerEpoch = 1,
        traceId = 'trace_accounts_benchmark_0001',
        version = '1.0.0',
      }
      local principal = { actor_kind = 'resource', actor_ref = authority }
      local balanceRequest = {
        account_id = accountId,
        actor_kind = principal.actor_kind,
        actor_ref = principal.actor_ref,
      }
      local accessRequest = {
        account_id = accountId,
        principal_kind = 'resource',
        principal_ref = authority,
        permission = 'transfer',
        actor_kind = principal.actor_kind,
        actor_ref = principal.actor_ref,
      }
      local transferRequest = {
        idempotency_key = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        source_account_id = accountId,
        destination_account_id = destinationId,
        amount_minor = 500,
        reason_code = 'synex_benchmark.transfer',
        actor_kind = principal.actor_kind,
        actor_ref = principal.actor_ref,
      }
      local postRequest = {
        idempotency_key = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
        currency_code = 'credits',
        postings = {
          { account_id = accountId, amount_minor = -500 },
          { account_id = destinationId, amount_minor = 500 },
        },
        reason_code = 'synex_benchmark.post',
        actor_kind = principal.actor_kind,
        actor_ref = principal.actor_ref,
      }
      local holdCreateRequest = {
        idempotency_key = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
        account_id = accountId,
        capture_account_id = destinationId,
        amount_minor = 1000,
        expires_in_seconds = 300,
        capture_policy = 'multiple',
        reason_code = 'synex_benchmark.hold',
        actor_kind = principal.actor_kind,
        actor_ref = principal.actor_ref,
      }
      local holdCaptureRequest = {
        idempotency_key = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
        hold_id = holdId,
        amount_minor = 400,
        expected_version = 1,
        reason_code = 'synex_benchmark.capture',
        actor_kind = principal.actor_kind,
        actor_ref = principal.actor_ref,
      }
      local reconciliationRequest = {
        idempotency_key = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',
        currency_code = 'credits',
        actor_kind = principal.actor_kind,
        actor_ref = principal.actor_ref,
      }

      local workloads = {
        accounts_balance_lookup = function()
          local value, valueError = service.balance_get(balanceRequest, context)
          assert(value and not valueError)
          return value.booked_minor
        end,
        accounts_available_balance_lookup = function()
          local value, valueError = service.balance_get(balanceRequest, context)
          assert(value and not valueError)
          return value.available_minor
        end,
        accounts_access_check = function()
          local value, valueError = service.access_check(accessRequest, context)
          assert(value and not valueError and value.allowed)
          return value.available_minor
        end,
        accounts_transfer = function()
          local value, valueError = service.transfer_v2(transferRequest, context)
          assert(value and not valueError and value.transaction_id == transactionId)
          return value.entry_count
        end,
        accounts_multileg_post = function()
          local value, valueError = service.post(postRequest, context)
          assert(value and not valueError and value.entry_count == 2)
          return value.entry_count
        end,
        accounts_hold_create = function()
          local value, valueError = service.hold_create(holdCreateRequest, context)
          assert(value and not valueError and value.state == 'active')
          return value.remaining_minor
        end,
        accounts_hold_capture = function()
          local value, valueError = service.hold_capture(holdCaptureRequest, context)
          assert(value and not valueError and value.version == 2)
          return value.remaining_minor
        end,
        accounts_reconciliation_query = function()
          local value, valueError = service.integrity_reconcile(reconciliationRequest, context)
          assert(value and not valueError and value.status == 'healthy')
          return tonumber(value.transaction_count) + tonumber(value.entry_count)
        end,
      }

      local names = {
        'accounts_balance_lookup',
        'accounts_available_balance_lookup',
        'accounts_access_check',
        'accounts_transfer',
        'accounts_multileg_post',
        'accounts_hold_create',
        'accounts_hold_capture',
        'accounts_reconciliation_query',
      }
      local report = { measurements = {}, checksum = 0 }
      local warmup = math.min(${iterations}, 1000)
      for _, name in ipairs(names) do
        local operation = workloads[name]
        local workloadChecksum = 0
        for index = 0, warmup - 1 do
          workloadChecksum = (workloadChecksum + operation(index + ${seed})) & 0xffffffff
        end
        local elapsed = {}
        for sample = 1, ${samples} do
          local started = os.clock()
          for index = 0, ${iterations} - 1 do
            workloadChecksum = (workloadChecksum + operation(index + ${seed})) & 0xffffffff
          end
          elapsed[sample] = math.max(0, (os.clock() - started) * 1000)
        end
        report.measurements[name] = {
          samplesMilliseconds = elapsed,
          checksum = workloadChecksum,
        }
        report.checksum = (report.checksum + workloadChecksum) & 0xffffffff
      end
      report.checksum = (report.checksum + auditCount) & 0xffffffff
      return report
    `) as RawAccountsLuaReport;
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
    const report = await runAccountsLuaBenchmark(iterations, samples, seed);
    process.stdout.write(JSON.stringify(report));
  } catch (error) {
    process.stderr.write(error instanceof Error ? error.message : "Accounts Lua benchmark failed.");
    process.exitCode = 1;
  }
}
