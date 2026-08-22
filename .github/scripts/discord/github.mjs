import { readFile } from "node:fs/promises";
import { COMPONENTS } from "./config.mjs";
import { safeHttpsUrl, sanitizeUntrusted, truncate } from "./utils.mjs";

const SCOPE_TO_COMPONENT = Object.freeze({
  core: "synex_core",
  character: "synex_character",
  identity: "synex_identity",
  inventory: "synex_inventory",
  banking: "synex_banking",
  phone: "synex_phone",
  radio: "synex_radio",
  jobs: "synex_jobs",
  shops: "synex_shops",
  vehicles: "synex_vehicles",
  garages: "synex_garages",
  ui: "synex_ui",
  bridge: "synex_bridge",
  docs: "Repository",
  readme: "Repository",
  branding: "Repository",
  repo: "Repository",
  ci: "Repository",
});

const TYPE_LABELS = Object.freeze({
  feat: "Feature",
  fix: "Fix",
  refactor: "Refactor",
  perf: "Performance",
  docs: "Documentation",
  test: "Tests",
  build: "Build",
  ci: "CI",
  chore: "Maintenance",
  style: "Style",
  revert: "Revert",
});

export async function readGitHubEvent(eventPath = process.env.GITHUB_EVENT_PATH) {
  if (!eventPath) throw new Error("GITHUB_EVENT_PATH is not available.");

  try {
    return JSON.parse(await readFile(eventPath, "utf8"));
  } catch {
    throw new Error("GitHub event payload could not be read.");
  }
}

function validRepositorySlug(value) {
  return typeof value === "string" && /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/u.test(value);
}

export function createGitHubContext(environment = process.env, event = {}) {
  const eventRepository = event.repository?.full_name;
  const repository = validRepositorySlug(environment.GITHUB_REPOSITORY)
    ? environment.GITHUB_REPOSITORY
    : validRepositorySlug(eventRepository)
      ? eventRepository
      : "PixelGG/Synex_Framework";

  const serverUrl = safeHttpsUrl(environment.GITHUB_SERVER_URL ?? "https://github.com") ?? "https://github.com/";
  const repositoryUrl = safeHttpsUrl(event.repository?.html_url) ?? new URL(repository, serverUrl).toString();

  return {
    actor: sanitizeUntrusted(environment.GITHUB_ACTOR ?? event.sender?.login ?? "GitHub", { limit: 80, maxLines: 1 }),
    refName: sanitizeUntrusted(environment.GITHUB_REF_NAME ?? "", { limit: 160, maxLines: 1 }),
    repositoryUrl,
    timestamp: new Date().toISOString(),
  };
}

export function shortSha(value) {
  const sha = typeof value === "string" ? value.trim() : "";
  return /^[a-f0-9]{7,64}$/iu.test(sha) ? sha.slice(0, 7) : "unknown";
}

export function branchFromRef(ref, fallback = "unknown") {
  const value = typeof ref === "string" ? ref.replace(/^refs\/heads\//u, "") : "";
  return sanitizeUntrusted(value || fallback, { limit: 160, maxLines: 1 });
}

export function parseConventionalCommit(message) {
  const firstLine = String(message ?? "").split(/\r?\n/u, 1)[0].trim();
  const match = /^(?<type>[a-z]+)(?:\((?<scope>[^)]+)\))?!?:\s*(?<summary>.+)$/iu.exec(firstLine);
  if (!match?.groups) return null;

  const type = match.groups.type.toLowerCase();
  const scope = match.groups.scope
    ? sanitizeUntrusted(match.groups.scope.trim().toLowerCase(), { limit: 48, maxLines: 1 })
    : null;
  return {
    component: scope && Object.hasOwn(SCOPE_TO_COMPONENT, scope) ? SCOPE_TO_COMPONENT[scope] : null,
    scope,
    summary: sanitizeUntrusted(match.groups.summary, { limit: 180, maxLines: 1 }),
    type,
    typeLabel: Object.hasOwn(TYPE_LABELS, type) ? TYPE_LABELS[type] : null,
  };
}

function filesForCommit(commit) {
  return [commit?.added, commit?.modified, commit?.removed]
    .flat()
    .filter((value) => typeof value === "string");
}

function componentsFromPaths(commits) {
  const matched = new Set();
  const components = Object.entries(COMPONENTS).filter(([, definition]) => definition.path);

  for (const path of commits.flatMap(filesForCommit)) {
    for (const [name, definition] of components) {
      if (path.startsWith(definition.path)) matched.add(name);
    }
  }

  return matched;
}

export function inferCommitComponent(commits) {
  const normalizedCommits = Array.isArray(commits) ? commits : [];
  const conventional = normalizedCommits
    .map((commit) => parseConventionalCommit(commit?.message))
    .filter(Boolean);
  const matchedComponents = new Set(
    conventional.map((entry) => entry.component).filter((entry) => entry && entry !== "Repository"),
  );
  for (const component of componentsFromPaths(normalizedCommits)) matchedComponents.add(component);

  if (matchedComponents.size > 1) return "Multiple components";
  const component = matchedComponents.size === 1 ? [...matchedComponents][0] : null;

  if (!component) {
    const repositoryLabels = new Set(
      conventional
        .map((entry) => {
          if (entry.type === "docs" || ["docs", "readme"].includes(entry.scope)) return "Documentation";
          if (entry.scope === "branding") return "Branding";
          if (entry.type === "ci" || entry.scope === "ci") return "CI";
          return null;
        })
        .filter(Boolean),
    );
    return repositoryLabels.size === 1 ? [...repositoryLabels][0] : "Repository Update";
  }

  const definition = COMPONENTS[component];
  const typeLabels = new Set(conventional.map((entry) => entry.typeLabel).filter(Boolean));
  return typeLabels.size === 1 ? `${definition.label} \u2022 ${[...typeLabels][0]}` : definition.label;
}

export function commitSummary(message, maximum = 180) {
  const parsed = parseConventionalCommit(message);
  if (parsed) {
    const scope = parsed.scope ? `(${parsed.scope})` : "";
    return truncate(`${parsed.type}${scope}: ${parsed.summary}`, maximum);
  }

  return sanitizeUntrusted(String(message ?? "").split(/\r?\n/u, 1)[0], { limit: maximum, maxLines: 1 }) || "No commit summary";
}

export function githubObjectUrl(context, path) {
  const base = context.repositoryUrl?.replace(/\/$/u, "");
  if (!base || typeof path !== "string" || !path.startsWith("/")) return null;
  return safeHttpsUrl(`${base}${path}`);
}
