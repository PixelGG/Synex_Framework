export const BRAND = Object.freeze({
  name: "Synex Framework",
  webhookName: "Synex Development",
  feedFooter: "Synex Framework \u2022 Development Feed",
  progressFooter: "Synex Framework \u2022 Development Progress",
  releaseFooter: "Synex Framework \u2022 Release",
  ciFooter: "Synex Framework \u2022 CI",
});

export const COLORS = Object.freeze({
  brand: 0x4b94ff,
  success: 0x3fb950,
  warning: 0xd29922,
  error: 0xf85149,
  neutral: 0x6e7681,
});

export const DISCORD_LIMITS = Object.freeze({
  username: 80,
  title: 256,
  description: 4096,
  fields: 25,
  fieldName: 256,
  fieldValue: 1024,
  footer: 2048,
  author: 256,
  embeds: 10,
  embedTotal: 6000,
});

export const COMPONENTS = Object.freeze({
  Repository: { label: "Repository", path: null },
  synex_core: { label: "Core", path: "core/synex_core/" },
  synex_character: { label: "Character", path: "resources/synex_character/" },
  synex_identity: { label: "Identity", path: "resources/synex_identity/" },
  synex_inventory: { label: "Inventory", path: "resources/synex_inventory/" },
  synex_banking: { label: "Banking", path: "resources/synex_banking/" },
  synex_phone: { label: "Phone", path: "resources/synex_phone/" },
  synex_radio: { label: "Radio", path: "resources/synex_radio/" },
  synex_jobs: { label: "Jobs", path: "resources/synex_jobs/" },
  synex_shops: { label: "Shops", path: "resources/synex_shops/" },
  synex_vehicles: { label: "Vehicles", path: "resources/synex_vehicles/" },
  synex_garages: { label: "Garages", path: "resources/synex_garages/" },
  synex_ui: { label: "UI", path: "libraries/synex_ui/" },
  synex_bridge: { label: "Bridge", path: "libraries/synex_bridge/" },
});

export const PROGRESS_STATUSES = Object.freeze({
  Planning: { color: COLORS.neutral, label: "Planning" },
  "In Development": { color: COLORS.brand, label: "In Development" },
  Testing: { color: COLORS.warning, label: "Testing" },
  Blocked: { color: COLORS.error, label: "Blocked" },
  Ready: { color: COLORS.success, label: "Ready" },
  Completed: { color: COLORS.success, label: "Completed" },
});

export const WEBHOOK_ENV_BY_TYPE = Object.freeze({
  push: "DISCORD_WEBHOOK_COMMITS",
  pull_request: "DISCORD_WEBHOOK_PRS",
  progress: "DISCORD_WEBHOOK_PROGRESS",
  release: "DISCORD_WEBHOOK_RELEASES",
  ci: "DISCORD_WEBHOOK_CI",
});

export const NOTIFICATION_TYPES = Object.freeze(Object.keys(WEBHOOK_ENV_BY_TYPE));
export const CI_WORKFLOW_NAME = "Synex Notification CI";

export function parseBoolean(value, fallback = false) {
  if (typeof value === "boolean") return value;
  if (typeof value !== "string") return fallback;

  const normalized = value.trim().toLowerCase();
  if (["1", "true", "yes", "on"].includes(normalized)) return true;
  if (["0", "false", "no", "off", ""].includes(normalized)) return false;
  return fallback;
}

export function resolveWebhook(type, environment = process.env) {
  if (!Object.hasOwn(WEBHOOK_ENV_BY_TYPE, type)) throw new Error("Unsupported notification type.");
  const categoryName = WEBHOOK_ENV_BY_TYPE[type];

  const categoryWebhook = environment[categoryName]?.trim();
  const defaultWebhook = environment.DISCORD_WEBHOOK_DEFAULT?.trim();

  if (categoryWebhook) return { value: categoryWebhook, source: categoryName };
  if (defaultWebhook) return { value: defaultWebhook, source: "DISCORD_WEBHOOK_DEFAULT" };
  return null;
}
