import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import {
  explainCompatibility,
  loadCompatibilityCatalog,
  scanCompatibility,
} from "../../tools/cli/src/compatibility.js";

async function scanFixture(root: string, name: string, source: string) {
  const resource = join(root, name);
  await mkdir(resource, { recursive: true });
  await writeFile(join(resource, "server.lua"), source, "utf8");
  return scanCompatibility(root, resource);
}

test("compatibility scanner resolves implemented QB, Qbox, and ESX surface calls", async (context) => {
  const root = await mkdtemp(join(tmpdir(), "synex-compat-surfaces-"));
  context.after(async () => rm(root, { recursive: true, force: true }));

  const qb = await scanFixture(root, "qb", [
    "local QBCore = exports['qb-core']:GetCoreObject()",
    "local online = QBCore.Functions.GetPlayerByCitizenId(citizenId)",
    "local sources = QBCore.Functions.GetPlayers()",
    "local players = QBCore.Functions.GetQBPlayers()",
    "local allowed = QBCore.Functions.HasPermission(source, 'admin')",
    "local permissions = QBCore.Functions.GetPermission(source)",
    "player.Functions.SetJob('police', 2)",
    "player.Functions:SetGang('ballas', 1)",
    "player.Functions.SetJobDuty(true)",
    "player.Functions.SetMetaData('hunger', 80)",
    "local direct = exports['qb-core']:GetPlayerByCitizenId(citizenId)",
  ].join("\n"));
  assert.deepEqual(qb.surfaces, [
    "qb.player.duty_mutation",
    "qb.player.group_mutation",
    "qb.player.metadata_mutation",
    "qb.server.core_object",
    "qb.server.identifier_player_lookup",
    "qb.server.permission_view",
    "qb.server.player_enumeration",
  ]);

  const qbx = await scanFixture(root, "qbx", [
    "local online = exports.qbx_core:GetPlayerByCitizenId(citizenId)",
    "local offline = exports['qbx_core']:GetOfflinePlayer(citizenId)",
    "local groups = exports.qbx_core:GetGroups(source)",
    "local member = exports.qbx_core:HasGroup(source, 'police')",
    "local primary = exports.qbx_core:HasPrimaryGroup(source, 'police')",
    "exports.qbx_core:SetPlayerPrimaryJob(citizenId, 'police')",
    "exports.qbx_core.SetPlayerPrimaryGang(citizenId, 'ballas')",
    "exports.qbx_core:SetJob(citizenId, 'police', 2)",
    "exports.qbx_core:SetGang(citizenId, 'ballas', 1)",
    "exports.qbx_core:SetJobDuty(citizenId, true)",
    "local metadata = exports.qbx_core:GetMetadata(citizenId, 'hunger')",
    "exports.qbx_core:SetMetadata(citizenId, 'hunger', 80)",
    "qbxPlayer.Functions.SetJob('police', 3)",
    "qbxPlayer.Functions.SetJobDuty(false)",
    "local state = qbxPlayer.Functions.GetMetaData('hunger')",
    "qbxPlayer.Functions.SetMetaData('hunger', 90)",
  ].join("\n"));
  assert.deepEqual(qbx.surfaces, [
    "qbx.player.metadata_mutation",
    "qbx.server.duty_mutation",
    "qbx.server.group_mutation",
    "qbx.server.groups_read",
    "qbx.server.identifier_player_lookup",
    "qbx.server.metadata_read",
    "qbx.server.offline_player_lookup",
    "qbx.server.primary_group_mutation",
  ]);

  const esx = await scanFixture(root, "esx", [
    "local ESX = exports.es_extended:getSharedObject()",
    "local online = ESX.GetPlayerFromIdentifier(identifier)",
    "local source = exports['es_extended']:GetPlayerIdFromIdentifier(identifier)",
    "local sources = ESX.GetPlayers()",
    "local players = exports.es_extended:GetExtendedPlayers('job', 'police')",
    "local account = xPlayer.getAccount('bank')",
    "local accounts = activeXPlayer:getAccounts(true)",
    "local group = xPlayer.getGroup()",
    "xPlayer.addAccountMoney('black_money', 100, 'test')",
    "activeXPlayer:removeAccountMoney('black_money', 25, 'test')",
    "xPlayer.setAccountMoney('black_money', 0, 'test')",
  ].join("\n"));
  assert.deepEqual(esx.surfaces, [
    "esx.server.identifier_player_lookup",
    "esx.server.player_enumeration",
    "esx.server.shared_object",
    "esx.xplayer.accounts_read",
    "esx.xplayer.custom_accounts",
    "esx.xplayer.money_mutation",
    "esx.xplayer.permission_group",
  ]);

  const catalog = await loadCompatibilityCatalog(process.cwd());
  assert.equal(catalog.available, true);
  const cataloged = new Set(catalog.surfaces.map((surface) => surface.name));
  for (const report of [qb, qbx, esx]) {
    assert.equal(report.surfaces.every((surface) => cataloged.has(surface)), true);
    const explanation = explainCompatibility(report, catalog);
    assert.equal(explanation.unresolved.length, 0);
  }
});

test("compatibility scanner does not classify unrelated methods from a framework-only file signal", async (context) => {
  const root = await mkdtemp(join(tmpdir(), "synex-compat-negative-"));
  context.after(async () => rm(root, { recursive: true, force: true }));

  const qb = await scanFixture(root, "qb", [
    "local framework = 'qb-core'",
    "cache.GetPlayers()",
    "permissions.HasPermission(source, 'admin')",
    "settings.SetMetaData('theme', 'dark')",
    "role.SetJobDuty(true)",
  ].join("\n"));
  const qbx = await scanFixture(root, "qbx", [
    "local framework = 'qbx_core'",
    "cache.GetGroups(source)",
    "permissions.HasGroup(source, 'admin')",
    "organization.SetJob(source, 'police')",
    "settings.GetMetadata(source, 'theme')",
  ].join("\n"));
  const esx = await scanFixture(root, "esx", [
    "local framework = 'es_extended'",
    "cache.GetPlayers()",
    "bank.getAccount('bank')",
    "permissions.getGroup(source)",
    "profile.addAccountMoney('bank', 100)",
  ].join("\n"));

  assert.deepEqual(qb.surfaces, []);
  assert.deepEqual(qbx.surfaces, []);
  assert.deepEqual(esx.surfaces, []);
});
