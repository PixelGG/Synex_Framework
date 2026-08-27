import { readFile } from 'node:fs/promises';
import path from 'node:path';

import type { Connection, ResultSetHeader, RowDataPacket } from 'mysql2/promise';
import { LuaFactory, type LuaEngine } from 'wasmoon';

const root = process.cwd();

export interface GroupsLiveServiceInput {
  actorCharacterId: string;
  groupId: string;
  expectedVersion: number;
  idempotencyKey: string;
  nextLabel: string;
  traceId: string;
  eventSuffix: string;
}

export interface GroupsLiveServiceResult {
  audit: {
    action: string;
    eventId: string;
    targetId: string;
    traceId: string;
  };
  databaseCalls: {
    reads: number;
    transactions: number;
    writes: number;
  };
  mutation: {
    entity_id: string;
    entity_type: string;
    replayed: boolean;
    status: string;
    version: number;
  };
  published: {
    aggregateId: string;
    eventId: string;
    eventType: string;
    payloadEventId: string;
    traceId: string;
  };
  read: {
    group_id: string;
    label: string;
    version: number;
  };
  report: {
    claimed: number;
    published: number;
  };
  runtimeEffects: number;
}

export type GroupsLiveRaceOperation =
  | 'members_accept'
  | 'members_set_grade'
  | 'members_transition'
  | 'policies_set'
  | 'roles_assign';

export interface GroupsLiveRaceResult {
  auditEntries: number;
  error?: {
    code?: string;
    details?: Record<string, unknown>;
    message?: string;
    retryable?: boolean;
  };
  ok: boolean;
  operation: GroupsLiveRaceOperation;
  runtimeEffects: number;
  unexpectedErrors: number;
  value?: {
    entity_id?: string;
    entity_type?: string;
    replayed?: boolean;
    status?: string;
    version?: number;
  };
}

export interface GroupsLiveRaceClient {
  close(): void;
  invoke(input: {
    operation: GroupsLiveRaceOperation;
    request: Record<string, unknown>;
    traceId: string;
  }): Promise<GroupsLiveRaceResult>;
}

async function preload(engine: LuaEngine, name: string, relativePath: string): Promise<void> {
  const source = await readFile(path.join(root, relativePath), 'utf8');
  await engine.doString(
    `package.preload[${JSON.stringify(name)}] = assert(load(${JSON.stringify(source)}, ${JSON.stringify(`@${relativePath}`)}))`,
  );
}

function plainDatabaseResult(value: RowDataPacket[] | RowDataPacket[][] | ResultSetHeader): unknown {
  if (Array.isArray(value)) {
    return value.map((row) => Object.fromEntries(
      Object.entries(row).filter(([, child]) => child !== null),
    ));
  }
  return {
    affectedRows: Number(value.affectedRows),
    changedRows: Number(value.changedRows),
    insertId: Number(value.insertId),
    warningStatus: Number(value.warningStatus),
  };
}

function objectEntries(value: object): Array<[string, unknown]> {
  return Object.keys(value).map((key) => [key, (value as Record<string, unknown>)[key]]);
}

function fromLua(value: unknown, seen = new Set<object>()): unknown {
  if (value === null || typeof value !== 'object') return value;
  if (seen.has(value)) throw new TypeError('cyclic Lua value');
  seen.add(value);
  try {
    if (Array.isArray(value)) return value.map((child) => fromLua(child, seen));
    if ((value as { __synex_database_null?: unknown }).__synex_database_null === true) {
      return null;
    }
    const entries = objectEntries(value);
    const numeric = entries.every(([key]) => /^[1-9][0-9]*$/u.test(key));
    if (numeric) {
      const sorted = entries
        .map(([key, child]) => [Number(key), child] as const)
        .sort(([left], [right]) => left - right);
      if (sorted.every(([key], index) => key === index + 1)) {
        return sorted.map(([, child]) => fromLua(child, seen));
      }
    }
    return Object.fromEntries(entries.map(([key, child]) => [key, fromLua(child, seen)]));
  } finally {
    seen.delete(value);
  }
}

function parametersFromLua(value: unknown): unknown[] {
  const converted = fromLua(value);
  if (!Array.isArray(converted)) {
    throw new TypeError('Groups live database parameters must be a positional array');
  }
  return converted;
}

function databaseCode(error: unknown): string {
  if (!error || typeof error !== 'object' || !('code' in error)
    || typeof error.code !== 'string') return 'UNKNOWN_DATABASE_ERROR';
  return error.code;
}

async function bootstrap(engine: LuaEngine): Promise<void> {
  const modules = [
    ['server.foundation', 'resources/synex_groups/server/foundation.lua'],
    ['server.validation', 'resources/synex_groups/server/validation.lua'],
    ['server.database_adapter', 'resources/synex_groups/server/database_adapter.lua'],
    ['server.persistence.effects', 'resources/synex_groups/server/persistence/effects.lua'],
    ['server.persistence.approved_operations',
      'resources/synex_groups/server/persistence/approved_operations.lua'],
    ['server.persistence', 'resources/synex_groups/server/persistence.lua'],
    ['server.persistence.definition_cache',
      'resources/synex_groups/server/persistence/definition_cache.lua'],
    ['server.persistence.capability_access',
      'resources/synex_groups/server/persistence/capability_access.lua'],
    ['server.persistence.memberships_shared',
      'resources/synex_groups/server/persistence/memberships_shared.lua'],
    ['server.persistence.memberships_invitations',
      'resources/synex_groups/server/persistence/memberships_invitations.lua'],
    ['server.persistence.memberships_lifecycle',
      'resources/synex_groups/server/persistence/memberships_lifecycle.lua'],
    ['server.persistence.membership_transition_policies',
      'resources/synex_groups/server/persistence/membership_transition_policies.lua'],
    ['server.persistence.memberships_access',
      'resources/synex_groups/server/persistence/memberships_access.lua'],
    ['server.persistence.governance_shared',
      'resources/synex_groups/server/persistence/governance_shared.lua'],
    ['server.persistence.governance_attribute_values',
      'resources/synex_groups/server/persistence/governance_attribute_values.lua'],
    ['server.persistence.governance_attribute_activation',
      'resources/synex_groups/server/persistence/governance_attribute_activation.lua'],
    ['server.persistence.governance_policies',
      'resources/synex_groups/server/persistence/governance_policies.lua'],
    ['server.persistence.organizations_shared',
      'resources/synex_groups/server/persistence/organizations_shared.lua'],
    ['server.persistence.organizations_read',
      'resources/synex_groups/server/persistence/organizations_read.lua'],
    ['server.persistence.organizations_lifecycle',
      'resources/synex_groups/server/persistence/organizations_lifecycle.lua'],
    ['server.persistence.workers', 'resources/synex_groups/server/persistence/workers.lua'],
    ['server.domain.constants', 'resources/synex_groups/server/domain/constants.lua'],
    ['server.domain.lifecycle', 'resources/synex_groups/server/domain/lifecycle.lua'],
    ['server.domain.capabilities', 'resources/synex_groups/server/domain/capabilities.lua'],
    ['server.domain.policy', 'resources/synex_groups/server/domain/policy.lua'],
    ['server.cache', 'resources/synex_groups/server/cache.lua'],
    ['server.service', 'resources/synex_groups/server/service.lua'],
    ['server.outbox', 'resources/synex_groups/server/outbox.lua'],
    ['tests.groups.live_service_runtime', 'tests/groups/live-service-runtime.lua'],
  ] as const;
  for (const [name, relativePath] of modules) await preload(engine, name, relativePath);
}

function installLiveDatabaseBridge(engine: LuaEngine, connection: Connection): void {
  engine.global.set('LiveDatabaseBegin', async () => {
    await connection.beginTransaction();
    return true;
  });
  engine.global.set('LiveDatabaseCommit', async () => {
    await connection.commit();
    return true;
  });
  engine.global.set('LiveDatabaseRollback', async () => {
    await connection.rollback();
    return true;
  });
  engine.global.set('LiveDatabaseRead', async (sql: unknown, rawParameters: unknown) => {
    if (typeof sql !== 'string') throw new TypeError('Groups live read SQL must be a string');
    try {
      const [result] = await connection.query<RowDataPacket[][] | RowDataPacket[]>(
        sql,
        parametersFromLua(rawParameters),
      );
      return plainDatabaseResult(result);
    } catch (error) {
      return {
        __synex_live_database_error: true,
        code: databaseCode(error),
      };
    }
  });
  engine.global.set('LiveDatabaseWrite', async (sql: unknown, rawParameters: unknown) => {
    if (typeof sql !== 'string') throw new TypeError('Groups live write SQL must be a string');
    try {
      const [result] = await connection.query<ResultSetHeader>(
        sql,
        parametersFromLua(rawParameters),
      );
      return plainDatabaseResult(result);
    } catch (error) {
      return {
        __synex_live_database_error: true,
        code: databaseCode(error),
      };
    }
  });
  engine.global.set('LiveDatabaseQuery', async (sql: unknown, rawParameters: unknown) => {
    if (typeof sql !== 'string') {
      throw new TypeError('Groups live transaction SQL must be a string');
    }
    try {
      const [result] = await connection.query<
        RowDataPacket[][] | RowDataPacket[] | ResultSetHeader
      >(sql, parametersFromLua(rawParameters));
      return plainDatabaseResult(result);
    } catch (error) {
      return {
        __synex_live_database_error: true,
        code: databaseCode(error),
      };
    }
  });
  engine.global.set('LiveJsonEncode', (value: unknown) => JSON.stringify(fromLua(value)));
  engine.global.set('LiveJsonDecode', (value: unknown) => {
    if (typeof value !== 'string') throw new TypeError('Groups live JSON input must be a string');
    return JSON.parse(value) as unknown;
  });
}

export async function createGroupsLiveRaceClient(
  connection: Connection,
  suffix: string,
): Promise<GroupsLiveRaceClient> {
  if (!/^[a-z][a-z0-9_]{7,31}$/u.test(suffix)) {
    throw new TypeError('Groups live race suffix must be a bounded lowercase identifier');
  }
  const engine = await new LuaFactory().createEngine({ enableProxy: false });
  try {
    await bootstrap(engine);
    installLiveDatabaseBridge(engine, connection);
    await engine.doString(`
      SynexGroupsLiveRace = require('tests.groups.live_service_runtime')({
        suffix = ${JSON.stringify(suffix)}
      })
    `);
  } catch (error) {
    engine.global.close();
    throw error;
  }

  return {
    close() {
      engine.global.close();
    },
    async invoke(input) {
      const idempotencyKey = input.request.idempotency_key;
      if (typeof idempotencyKey !== 'string') {
        throw new TypeError('Groups live race mutations require an idempotency key');
      }
      const requestJson = JSON.stringify(input.request);
      const contextJson = JSON.stringify({
        caller: 'synex_groups_live_race',
        callerEpoch: 1,
        idempotencyKey,
        traceId: input.traceId,
      });
      const raw = await engine.doString(`
        return SynexGroupsLiveRace.invoke(
          ${JSON.stringify(input.operation)},
          SynexGroupsLiveRace.decode(${JSON.stringify(requestJson)}),
          SynexGroupsLiveRace.decode(${JSON.stringify(contextJson)})
        )
      `);
      const converted = fromLua(raw);
      if (!converted || typeof converted !== 'object' || Array.isArray(converted)) {
        throw new TypeError('Groups live race returned an invalid result');
      }
      return converted as GroupsLiveRaceResult;
    },
  };
}

export async function runGroupsLiveServiceScenario(
  connection: Connection,
  input: GroupsLiveServiceInput,
): Promise<GroupsLiveServiceResult> {
  const counters = { reads: 0, transactions: 0, writes: 0 };
  const engine = await new LuaFactory().createEngine({ enableProxy: false });
  try {
    await bootstrap(engine);
    engine.global.set('LiveDatabaseBegin', async () => {
      counters.transactions += 1;
      await connection.beginTransaction();
      return true;
    });
    engine.global.set('LiveDatabaseCommit', async () => {
      await connection.commit();
      return true;
    });
    engine.global.set('LiveDatabaseRollback', async () => {
      await connection.rollback();
      return true;
    });
    engine.global.set('LiveDatabaseRead', async (sql: unknown, rawParameters: unknown) => {
      if (typeof sql !== 'string') throw new TypeError('Groups live read SQL must be a string');
      counters.reads += 1;
      const [result] = await connection.query<RowDataPacket[][] | RowDataPacket[]>(
        sql,
        parametersFromLua(rawParameters),
      );
      return plainDatabaseResult(result);
    });
    engine.global.set('LiveDatabaseWrite', async (sql: unknown, rawParameters: unknown) => {
      if (typeof sql !== 'string') throw new TypeError('Groups live write SQL must be a string');
      counters.writes += 1;
      const [result] = await connection.query<ResultSetHeader>(
        sql,
        parametersFromLua(rawParameters),
      );
      return plainDatabaseResult(result);
    });
    engine.global.set('LiveDatabaseQuery', async (sql: unknown, rawParameters: unknown) => {
      if (typeof sql !== 'string') throw new TypeError('Groups live transaction SQL must be a string');
      const [result] = await connection.query<RowDataPacket[][] | RowDataPacket[] | ResultSetHeader>(
        sql,
        parametersFromLua(rawParameters),
      );
      return plainDatabaseResult(result);
    });
    engine.global.set('LiveJsonEncode', (value: unknown) => JSON.stringify(fromLua(value)));
    engine.global.set('LiveJsonDecode', (value: unknown) => {
      if (typeof value !== 'string') throw new TypeError('Groups live JSON input must be a string');
      return JSON.parse(value) as unknown;
    });

    const result = await engine.doString(`
      local Foundation = require 'server.foundation'
      local Validation = require('server.validation')(Foundation)

      local function externalPlain(value, active)
        local valueType = type(value)
        if valueType ~= 'table' and valueType ~= 'userdata' then return value end
        active = active or {}
        if active[value] then error('cyclic external value', 0) end
        active[value] = true
        local copied = {}
        local length = valueType == 'userdata' and #value or 0
        if length > 0 then
          for index = 1, length do
            copied[index] = externalPlain(value[index], active)
          end
          active[value] = nil
          return copied
        end
        local iterable, iterator, state, first = pcall(pairs, value)
        if iterable then
          for key, child in iterator, state, first do
            if key ~= 'length' then
              copied[key] = externalPlain(child, active)
            end
          end
        end
        active[value] = nil
        return copied
      end

      local function databaseResult(promise)
        return externalPlain(promise:await())
      end

      local function transactionView()
        local transaction = {}
        function transaction.query(_, sql, parameters)
          return databaseResult(LiveDatabaseQuery(sql, parameters)), nil
        end
        function transaction.many(_, sql, parameters)
          return databaseResult(LiveDatabaseQuery(sql, parameters)), nil
        end
        function transaction.one(_, sql, parameters)
          local rows = databaseResult(LiveDatabaseQuery(sql, parameters))
          return rows[1], nil
        end
        function transaction.affected(_, sql, parameters)
          local result = databaseResult(LiveDatabaseQuery(sql, parameters))
          return tonumber(result.affectedRows), nil
        end
        function transaction.insert(_, sql, parameters)
          local result = databaseResult(LiveDatabaseQuery(sql, parameters))
          return tonumber(result.insertId), nil
        end
        return transaction
      end

      local CoreDatabase = {}
      function CoreDatabase.null()
        return { __synex_database_null = true }
      end
      function CoreDatabase.read(request)
        return databaseResult(LiveDatabaseRead(request.sql, request.parameters)), nil
      end
      function CoreDatabase.write(request)
        return databaseResult(LiveDatabaseWrite(request.sql, request.parameters)), nil
      end
      function CoreDatabase.transaction(_, handler)
        LiveDatabaseBegin():await()
        local called, value, operationError = pcall(handler, transactionView())
        if not called or value == nil then
          LiveDatabaseRollback():await()
          if called then return nil, operationError end
          return nil, type(value) == 'table' and value
            or Foundation.domainError('DATABASE_ERROR', 'Live transaction handler failed.', true)
        end
        LiveDatabaseCommit():await()
        return value, operationError, { replayed = false }
      end
      function CoreDatabase.maintenance(_, handler)
        LiveDatabaseBegin():await()
        local called, value, operationError = pcall(handler, transactionView())
        if not called or value == nil then
          LiveDatabaseRollback():await()
          if called then return nil, operationError end
          return nil, type(value) == 'table' and value
            or Foundation.domainError('DATABASE_ERROR', 'Live maintenance handler failed.', true)
        end
        LiveDatabaseCommit():await()
        return value, operationError
      end

      local function jsonEncode(value)
        return LiveJsonEncode(value)
      end
      local function jsonDecode(value)
        return externalPlain(LiveJsonDecode(value))
      end
      local function evaluateRules(permission, rules)
        local matches, allows, denies = {}, 0, 0
        for index, rule in ipairs(rules) do
          local pattern = rule.permission
          local matched = pattern == permission
          if not matched and type(pattern) == 'string' and pattern:sub(-2) == '.*' then
            local prefix = pattern:sub(1, -3)
            matched = permission:sub(1, #prefix + 1) == prefix .. '.'
          end
          if matched then
            matches[#matches + 1] = {
              index = index, permission = pattern, effect = rule.effect
            }
            if rule.effect == 'deny' then denies = denies + 1 else allows = allows + 1 end
          end
        end
        return {
          permission = permission, matches = matches,
          matchedAllows = allows, matchedDenies = denies,
          denied = denies > 0, allowed = allows > 0 and denies == 0,
          evaluatedRules = #rules
        }, nil
      end

      local createAdapter = require('server.database_adapter')(Foundation)
      local coreDataPort = createAdapter(CoreDatabase)
      local Capabilities = require 'server.domain.capabilities'
      local capabilityEvaluator = Capabilities.create({
        now = function() return os.time() end,
        maximumRules = 256,
        maximumRoles = 32,
        maximumDelegations = 64,
        maximumScopeKeys = 16,
        evaluateRules = evaluateRules
      })
      local Policy = require 'server.domain.policy'
      local policyEngine = Policy.create({
        capabilities = capabilityEvaluator, maximumGates = 16
      })
      local cache = require('server.cache')(Foundation)({ maximum = 128, ttlMs = 5000 })
      local idSequence = 0
      local function nextId(namespace)
        idSequence = idSequence + 1
        return namespace .. '_${input.eventSuffix}_' .. string.format('%04d', idSequence)
      end
      local registry = {
        get = function() return nil, { code = 'REGISTRY_KEY_NOT_FOUND' } end,
        replace = function() return true end,
        stats = function()
          return { entries = 0, maximumEntries = 64, maximumPerOwner = 64 }
        end,
        listOwner = function() return {} end
      }
      local modules = {
        effects = require 'server.persistence.effects',
        approved_operations = require 'server.persistence.approved_operations',
        capability_access = require 'server.persistence.capability_access',
        organizations_read = require 'server.persistence.organizations_read',
        organizations_lifecycle = require 'server.persistence.organizations_lifecycle',
        workers = require 'server.persistence.workers'
      }
      local createPersistence = require('server.persistence')(Foundation, modules)
      local repository = createPersistence({
        dataPort = coreDataPort,
        jsonEncode = jsonEncode,
        jsonDecode = jsonDecode,
        nextId = nextId,
        capabilityEvaluator = capabilityEvaluator,
        policyEngine = policyEngine,
        cache = cache,
        registries = {
          groupTypes = registry, relationTypes = registry,
          attributeSchemas = registry, dutyStates = registry
        },
        applicationSchemas = {
          validateSchema = function() return true end,
          validateData = function() return true end
        },
        validateOperation = Validation.operation,
        runtimeIndex = { snapshot = function()
          return { characters = 0, memberships = 0, dutySessions = 0 }
        end },
        checkCorePermission = function() return true end,
        applyRegistryMutation = function() return true end,
        refreshRegistry = function() return true end
      })

      local auditEntries, runtimeEffects, errors = {}, 0, {}
      local service = require('server.service')(Foundation)({
        repository = repository,
        characters = { get = function(characterId) return { id = characterId }, nil end },
        hooks = { run = function(_, value) return value, nil end },
        audit = { append = function(entry)
          local eventId = 'core_audit_${input.eventSuffix}'
          auditEntries[#auditEntries + 1] = {
            action = entry.action, eventId = eventId, targetId = entry.targetId,
            traceId = entry.traceId
          }
          return { eventId = eventId }, nil
        end },
        runtimeEffects = { apply = function()
          runtimeEffects = runtimeEffects + 1
          return true, nil
        end },
        cache = cache,
        jsonEncode = jsonEncode,
        errorSink = function(event) errors[#errors + 1] = event end
      })
      local context = {
        traceId = ${JSON.stringify(input.traceId)},
        caller = 'synex_groups_live_probe',
        callerEpoch = 1,
        idempotencyKey = ${JSON.stringify(input.idempotencyKey)}
      }
      local mutation, mutationError = service.update({
        idempotency_key = ${JSON.stringify(input.idempotencyKey)},
        actor_character_id = ${JSON.stringify(input.actorCharacterId)},
        group_id = ${JSON.stringify(input.groupId)},
        expected_version = ${input.expectedVersion},
        label = ${JSON.stringify(input.nextLabel)},
        reason = 'live_service_update'
      }, context)
      assert(mutation, mutationError and mutationError.code or 'mutation failed')
      assert(#auditEntries == 1 and runtimeEffects == 1 and #errors == 0)

      local read, readError = service.get({
        group_id = ${JSON.stringify(input.groupId)}
      }, context)
      assert(read, readError and readError.code or 'read failed')

      local published = {}
      local dispatcher = require('server.outbox')(Foundation)({
        update = function(sql, parameters)
          local result = coreDataPort:writeOrError(sql, parameters, { timeoutMs = 15000 })
          return tonumber(result.affectedRows)
        end,
        query = function(sql, parameters)
          return coreDataPort:readOrError(sql, parameters, {
            maximumRows = 256, maximumResultBytes = 1048576, timeoutMs = 15000
          })
        end,
        jsonDecode = jsonDecode
      })
      local report, dispatchError = dispatcher:dispatchBatch(
        'live_claim_${input.eventSuffix}',
        function(eventType, payload, eventContext)
          if eventContext.traceId == ${JSON.stringify(input.traceId)} then
            published[#published + 1] = {
              eventType = eventType,
              eventId = eventContext.eventId,
              aggregateId = eventContext.aggregateId,
              traceId = eventContext.traceId,
              payloadEventId = payload.event_id
            }
          end
          return { delivered = 1, failed = 0 }, nil
        end,
        { maximum = 50 })
      assert(report, dispatchError and dispatchError.code or 'outbox dispatch failed')
      assert(#published == 1)

      return {
        audit = auditEntries[1], mutation = mutation, published = published[1],
        read = read, report = report, runtimeEffects = runtimeEffects
      }
    `) as Omit<GroupsLiveServiceResult, 'databaseCalls'>;
    return { ...result, databaseCalls: counters };
  } finally {
    engine.global.close();
  }
}
