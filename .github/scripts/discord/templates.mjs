import { BRAND, CI_WORKFLOW_NAME, COLORS, COMPONENTS, DISCORD_LIMITS, PROGRESS_STATUSES } from "./config.mjs";
import {
  branchFromRef,
  commitSummary,
  githubObjectUrl,
  inferCommitComponent,
  shortSha,
} from "./github.mjs";
import {
  bulletList,
  codePointLength,
  finalizeEmbed,
  formatDuration,
  parseMultilineList,
  parseProgress,
  progressBar,
  safeHttpsUrl,
  safeMarkdownLink,
  safePublicHttpsUrl,
  sanitizeUntrusted,
  truncate,
  validatePayload,
} from "./utils.mjs";

function field(name, value, inline = false) {
  return value ? { name, value: String(value), inline } : null;
}

function compactFields(fields) {
  return fields.filter(Boolean);
}

function positiveInteger(value, fallback = 0) {
  const number = Number(value);
  return Number.isInteger(number) && number >= 0 ? number : fallback;
}

function eventTimestamp(value, context) {
  return value && !Number.isNaN(Date.parse(value)) ? value : context.timestamp;
}

function detailsField(label, url) {
  const link = safeMarkdownLink(label, url);
  return link ? field("DETAILS", link) : null;
}

function baseEmbed({ title, description, color, url, fields, footer, timestamp }) {
  return finalizeEmbed({
    author: { name: "SYNEX FRAMEWORK" },
    title,
    description,
    color,
    url,
    fields: compactFields(fields),
    footer: { text: footer },
    timestamp,
  });
}

function commitLine(commit, context, maximum) {
  const sha = shortSha(commit?.id);
  const commitUrl = sha === "unknown" ? null : githubObjectUrl(context, `/commit/${commit.id}`);
  const plainPrefix = `\u02cb${sha}\u02cb`;
  const linkedPrefix = commitUrl ? "[`" + sha + "`](" + commitUrl + ")" : null;
  const prefix = linkedPrefix && codePointLength(linkedPrefix) + 4 < maximum ? linkedPrefix : plainPrefix;
  const messageLimit = Math.max(1, maximum - codePointLength(prefix) - 2);
  return `${prefix}  ${commitSummary(commit?.message, messageLimit)}`;
}

export function renderPush(event, context) {
  const commits = Array.isArray(event.commits) ? event.commits : [];
  const total = Math.max(positiveInteger(event.size, commits.length), commits.length);
  const branch = branchFromRef(event.ref, context.refName || "unknown");
  const component = inferCommitComponent(commits);
  const compareUrl = safeHttpsUrl(event.compare);
  const timestamp = eventTimestamp(event.head_commit?.timestamp, context);

  if (total === 1 && commits.length === 1) {
    const commit = commits[0];
    const sha = shortSha(commit.id);
    const commitUrl = sha === "unknown" ? compareUrl : githubObjectUrl(context, `/commit/${commit.id}`);
    const summary = commitSummary(commit.message, 360);

    return {
      embed: baseEmbed({
        title: "Code Update",
        description: `${summary}\n\nA change was published to \u02cb${branch}\u02cb.`,
        color: COLORS.brand,
        url: commitUrl,
        fields: [
          field("BRANCH", branch, true),
          field("COMMIT", sha, true),
          field("COMPONENT", component, true),
          field("AUTHOR", context.actor, true),
          detailsField("View commit \u2192", commitUrl),
        ],
        footer: BRAND.feedFooter,
        timestamp,
      }),
      metadata: { type: "Code Update", status: "Delivered", component },
    };
  }

  const shown = commits.slice(-5);
  const additional = Math.max(0, total - shown.length);
  const additionalLine = additional > 0 ? `+ ${additional} additional commit${additional === 1 ? "" : "s"}` : null;
  const renderedLineCount = shown.length + (additionalLine ? 1 : 0);
  const separatorBudget = Math.max(0, renderedLineCount - 1);
  const additionalBudget = codePointLength(additionalLine);
  const commitLineBudget = shown.length > 0
    ? Math.floor((DISCORD_LIMITS.fieldValue - separatorBudget - additionalBudget) / shown.length)
    : DISCORD_LIMITS.fieldValue;
  const recentChanges = shown.map((commit) => commitLine(commit, context, commitLineBudget));
  if (additionalLine) recentChanges.push(additionalLine);
  if (recentChanges.length === 0) recentChanges.push("No commit details were included in the event payload.");

  return {
    embed: baseEmbed({
      title: "Code Update",
      description: `${total} commit${total === 1 ? " was" : "s were"} published to \u02cb${branch}\u02cb.`,
      color: COLORS.brand,
      url: compareUrl,
      fields: [
        field("BRANCH", branch, true),
        field("COMMITS", String(total), true),
        field("COMPONENT", component, true),
        field("RECENT CHANGES", recentChanges.join("\n")),
        field("PUBLISHED BY", context.actor, true),
        detailsField("View comparison \u2192", compareUrl),
      ],
      footer: BRAND.feedFooter,
      timestamp,
    }),
    metadata: { type: "Code Update", status: "Delivered", component },
  };
}

function pullRequestState(event) {
  const pullRequest = event.pull_request ?? {};

  if (event.action === "closed" && pullRequest.merged) {
    return { title: "Pull Request Merged", status: "Merged", color: COLORS.success, link: "View changes \u2192" };
  }
  if (event.action === "closed") {
    return { title: "Pull Request Closed", status: "Closed", color: COLORS.neutral, link: "View pull request \u2192" };
  }
  if (event.action === "ready_for_review") {
    return { title: "Pull Request Ready for Review", status: "Ready for Review", color: COLORS.warning, link: "View pull request \u2192" };
  }
  if (event.action === "converted_to_draft") {
    return { title: "Pull Request Drafted", status: "Draft", color: COLORS.neutral, link: "View pull request \u2192" };
  }
  if (event.action === "reopened") {
    return { title: "Pull Request Reopened", status: pullRequest.draft ? "Draft" : "Review Requested", color: pullRequest.draft ? COLORS.neutral : COLORS.brand, link: "View pull request \u2192" };
  }
  if (event.action === "opened") {
    return { title: "Pull Request Opened", status: pullRequest.draft ? "Draft" : "Review Requested", color: pullRequest.draft ? COLORS.neutral : COLORS.brand, link: "View pull request \u2192" };
  }

  throw new Error("Unsupported pull request action.");
}

export function renderPullRequest(event, context) {
  const pullRequest = event.pull_request;
  if (!pullRequest || !Number.isInteger(pullRequest.number)) {
    throw new Error("Pull request event is missing required metadata.");
  }

  const state = pullRequestState(event);
  const number = pullRequest.number;
  const url = githubObjectUrl(context, `/pull/${number}`) ?? safeHttpsUrl(pullRequest.html_url);
  const source = sanitizeUntrusted(pullRequest.head?.ref ?? "unknown", { limit: 160, maxLines: 1 });
  const target = sanitizeUntrusted(pullRequest.base?.ref ?? "unknown", { limit: 160, maxLines: 1 });
  const author = sanitizeUntrusted(pullRequest.user?.login ?? context.actor, { limit: 80, maxLines: 1 });
  const title = sanitizeUntrusted(pullRequest.title ?? `Pull request #${number}`, { limit: 500, maxLines: 2 });
  const timestamp = eventTimestamp(pullRequest.merged_at ?? pullRequest.closed_at ?? pullRequest.updated_at, context);

  return {
    embed: baseEmbed({
      title: state.title,
      description: title,
      color: state.color,
      url,
      fields: [
        field("PULL REQUEST", `#${number}`, true),
        field("STATUS", state.status, true),
        field("AUTHOR", author, true),
        field("SOURCE", source, true),
        field("TARGET", target, true),
        pullRequest.merged ? field("COMMITS", String(positiveInteger(pullRequest.commits)), true) : null,
        detailsField(state.link, url),
      ],
      footer: BRAND.feedFooter,
      timestamp,
    }),
    metadata: { type: state.title, status: state.status, component: "Repository" },
  };
}

export function renderRelease(event, context) {
  const release = event.release;
  if (!release || typeof release.tag_name !== "string") {
    throw new Error("Release event is missing required metadata.");
  }

  const version = sanitizeUntrusted(release.tag_name, { limit: 120, maxLines: 1 });
  const name = sanitizeUntrusted(release.name || release.tag_name, { limit: 500, maxLines: 2 });
  const url = safeHttpsUrl(release.html_url) ?? githubObjectUrl(context, `/releases/tag/${encodeURIComponent(release.tag_name)}`);
  const highlights = parseMultilineList(release.body, { maxItems: 6, itemLimit: 180 });
  const releaseType = release.prerelease ? "Pre-release" : "Stable";
  const publisher = sanitizeUntrusted(release.author?.login ?? context.actor, { limit: 80, maxLines: 1 });

  return {
    embed: baseEmbed({
      title: "New Release",
      description: `${name}\n\nA new Synex release is available.`,
      color: COLORS.success,
      url,
      fields: [
        field("VERSION", version, true),
        field("TYPE", releaseType, true),
        field("PUBLISHED BY", publisher, true),
        highlights.length > 0 ? field("HIGHLIGHTS", bulletList(highlights)) : null,
        detailsField("View release \u2192", url),
      ],
      footer: BRAND.releaseFooter,
      timestamp: eventTimestamp(release.published_at, context),
    }),
    metadata: { type: "New Release", status: releaseType, component: "Repository" },
  };
}

export function renderProgress(event, context) {
  const inputs = event.inputs ?? {};
  const title = sanitizeUntrusted(inputs.title, { limit: 500, maxLines: 2 });
  if (!title) throw new Error("Progress title is required.");

  const componentName = typeof inputs.component === "string" ? inputs.component : "";
  if (!Object.hasOwn(COMPONENTS, componentName)) throw new Error("Progress component is not part of the Synex repository.");
  const component = COMPONENTS[componentName];

  const statusName = typeof inputs.status === "string" ? inputs.status : "";
  if (!Object.hasOwn(PROGRESS_STATUSES, statusName)) throw new Error("Progress status is not supported.");
  const status = PROGRESS_STATUSES[statusName];

  const progress = parseProgress(inputs.progress);
  const summary = sanitizeUntrusted(inputs.summary, { limit: 900, maxLines: 8 });
  if (!summary) throw new Error("Progress summary is required.");

  const highlights = parseMultilineList(inputs.highlights, { maxItems: 6, itemLimit: 180 });
  const nextSteps = parseMultilineList(inputs.next_steps, { maxItems: 6, itemLimit: 180 });
  const target = sanitizeUntrusted(inputs.target, { limit: 160, maxLines: 1 });

  return {
    embed: baseEmbed({
      title: "Development Progress",
      description: `${title}\n\n${progressBar(progress)}`,
      color: status.color,
      url: context.repositoryUrl,
      fields: [
        field("STATUS", status.label, true),
        field("COMPONENT", componentName === "Repository" ? component.label : componentName, true),
        field("CURRENT FOCUS", summary),
        highlights.length > 0 ? field("HIGHLIGHTS", bulletList(highlights)) : null,
        nextSteps.length > 0 ? field("NEXT", bulletList(nextSteps)) : null,
        target ? field("TARGET", target, true) : null,
        field("PUBLISHED BY", context.actor, true),
      ],
      footer: BRAND.progressFooter,
      timestamp: context.timestamp,
    }),
    metadata: { type: "Development Progress", status: status.label, component: componentName },
    dryRun: inputs.dry_run === true || String(inputs.dry_run).toLowerCase() === "true",
  };
}

function ciState(conclusion) {
  const states = {
    success: { title: "Validation Passed", color: COLORS.success, description: "The workflow completed successfully." },
    failure: { title: "Validation Failed", color: COLORS.error, description: "The workflow did not complete successfully." },
    timed_out: { title: "Validation Timed Out", color: COLORS.error, description: "The workflow exceeded its allowed execution time." },
    startup_failure: { title: "Validation Failed to Start", color: COLORS.error, description: "The workflow could not start successfully." },
    action_required: { title: "Validation Needs Attention", color: COLORS.warning, description: "The workflow requires a maintainer action." },
    cancelled: { title: "Validation Cancelled", color: COLORS.neutral, description: "The workflow was cancelled before completion." },
    skipped: { title: "Validation Skipped", color: COLORS.neutral, description: "The workflow did not run its validation jobs." },
    neutral: { title: "Validation Completed", color: COLORS.neutral, description: "The workflow completed with a neutral conclusion." },
    stale: { title: "Validation Stale", color: COLORS.neutral, description: "The workflow run is no longer current." },
  };

  return Object.hasOwn(states, conclusion)
    ? states[conclusion]
    : { title: "Validation Completed", color: COLORS.neutral, description: "The workflow completed without a recognized conclusion." };
}

export function renderCi(event, context) {
  const run = event.workflow_run;
  if (!run || !Number.isInteger(run.id)) throw new Error("Workflow run event is missing required metadata.");
  if (run.name !== CI_WORKFLOW_NAME) throw new Error("Workflow run is not an approved CI source.");

  const conclusion = sanitizeUntrusted(run.conclusion ?? "unknown", { limit: 40, maxLines: 1 }).toLowerCase();
  const state = ciState(conclusion);
  const workflow = CI_WORKFLOW_NAME;
  const branch = sanitizeUntrusted(run.head_branch ?? "unknown", { limit: 160, maxLines: 1 });
  const actor = sanitizeUntrusted(run.actor?.login ?? context.actor, { limit: 80, maxLines: 1 });
  const url = safeHttpsUrl(run.html_url) ?? githubObjectUrl(context, `/actions/runs/${run.id}`);
  const attempt = positiveInteger(run.run_attempt, 1);

  return {
    embed: baseEmbed({
      title: state.title,
      description: state.description,
      color: state.color,
      url,
      fields: [
        field("WORKFLOW", workflow),
        field("STATUS", conclusion.replace(/_/gu, " ").replace(/\b\w/gu, (character) => character.toUpperCase()), true),
        field("BRANCH", branch, true),
        field("COMMIT", shortSha(run.head_sha), true),
        field("RUN", `#${positiveInteger(run.run_number)}`, true),
        attempt > 1 ? field("ATTEMPT", String(attempt), true) : null,
        field("DURATION", formatDuration(run.run_started_at ?? run.created_at, run.updated_at), true),
        field("TRIGGERED BY", actor, true),
        detailsField("View workflow run \u2192", url),
      ],
      footer: BRAND.ciFooter,
      timestamp: eventTimestamp(run.updated_at, context),
    }),
    metadata: { type: state.title, status: conclusion, component: "Notification Infrastructure" },
    conclusion,
  };
}

export function renderNotification(type, event, context) {
  const renderers = {
    push: renderPush,
    pull_request: renderPullRequest,
    progress: renderProgress,
    release: renderRelease,
    ci: renderCi,
  };

  if (!Object.hasOwn(renderers, type)) throw new Error("Unsupported notification type.");
  const renderer = renderers[type];
  return renderer(event, context);
}

export function createDiscordPayload(rendered, environment = process.env) {
  const configuredName = typeof environment.DISCORD_WEBHOOK_NAME === "string" ? environment.DISCORD_WEBHOOK_NAME.trim() : "";
  const username = sanitizeUntrusted(configuredName || BRAND.webhookName, {
    limit: DISCORD_LIMITS.username,
    maxLines: 1,
  });
  const avatarUrl = safePublicHttpsUrl(environment.DISCORD_BRAND_ICON_URL);

  const payload = {
    username,
    allowed_mentions: { parse: [] },
    embeds: [rendered.embed],
  };

  if (avatarUrl) payload.avatar_url = avatarUrl;
  validatePayload(payload);
  return payload;
}

export function notificationPreview(rendered) {
  return {
    type: truncate(rendered.metadata.type, 120),
    status: truncate(rendered.metadata.status, 120),
    component: truncate(rendered.metadata.component, 160),
    title: truncate(rendered.embed.title, 120),
    fields: rendered.embed.fields.map((entry) => entry.name).slice(0, 12),
  };
}
