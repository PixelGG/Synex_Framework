import { appendFile } from "node:fs/promises";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { NOTIFICATION_TYPES, parseBoolean, resolveWebhook } from "./config.mjs";
import { createGitHubContext, readGitHubEvent } from "./github.mjs";
import { createDiscordPayload, notificationPreview, renderNotification } from "./templates.mjs";

const MAX_ATTEMPTS = 4;
const REQUEST_TIMEOUT_MS = 15_000;
const USER_AGENT = "Synex-Framework-Notifications/1.0";
const ALLOWED_QUERY_PARAMETERS = new Set(["wait", "thread_id", "with_components"]);

export class WebhookDeliveryError extends Error {
  constructor(message, status = null) {
    super(message);
    this.name = "WebhookDeliveryError";
    this.status = status;
  }
}

export function normalizeWebhookUrl(value) {
  if (typeof value !== "string" || value.trim() === "") {
    throw new WebhookDeliveryError("Discord webhook is not configured correctly.");
  }

  let url;
  try {
    url = new URL(value.trim());
  } catch {
    throw new WebhookDeliveryError("Discord webhook is not configured correctly.");
  }

  if (
    url.protocol !== "https:" ||
    url.hostname.toLowerCase() !== "discord.com" ||
    url.port ||
    url.username ||
    url.password ||
    url.hash
  ) {
    throw new WebhookDeliveryError("Discord webhook is not configured correctly.");
  }

  const match = /^\/api(?:\/v10)?\/webhooks\/(\d{17,20})\/([^/]+)\/?$/u.exec(url.pathname);
  if (!match || /%2f/iu.test(match[2])) {
    throw new WebhookDeliveryError("Discord webhook is not configured correctly.");
  }

  const seenQueryParameters = new Set();
  for (const key of url.searchParams.keys()) {
    if (!ALLOWED_QUERY_PARAMETERS.has(key)) {
      throw new WebhookDeliveryError("Discord webhook is not configured correctly.");
    }
    if (seenQueryParameters.has(key)) {
      throw new WebhookDeliveryError("Discord webhook is not configured correctly.");
    }
    seenQueryParameters.add(key);
  }

  if (url.searchParams.has("thread_id") && !/^\d{17,20}$/u.test(url.searchParams.get("thread_id"))) {
    throw new WebhookDeliveryError("Discord webhook is not configured correctly.");
  }

  if (url.searchParams.has("with_components") && !/^(?:true|false)$/u.test(url.searchParams.get("with_components"))) {
    throw new WebhookDeliveryError("Discord webhook is not configured correctly.");
  }

  url.pathname = `/api/v10/webhooks/${match[1]}/${match[2]}`;
  url.searchParams.set("wait", "true");
  return url.toString();
}

function secondsToMilliseconds(value) {
  if (value === null || value === undefined || value === "") return null;
  const seconds = Number(value);
  return Number.isFinite(seconds) && seconds >= 0 ? Math.ceil(seconds * 1000) : null;
}

async function retryAfterMilliseconds(response) {
  const candidates = [
    secondsToMilliseconds(response.headers.get("retry-after")),
    secondsToMilliseconds(response.headers.get("x-ratelimit-reset-after")),
  ].filter((value) => value !== null);

  if (response.status === 429) {
    try {
      const body = await response.json();
      const bodyDelay = secondsToMilliseconds(body?.retry_after);
      if (bodyDelay !== null) candidates.push(bodyDelay);
    } catch {
      // Discord may return an empty or non-JSON error body. Header values remain authoritative.
    }
  }

  return candidates.length > 0 ? Math.max(...candidates) : null;
}

function exponentialBackoff(attempt, random) {
  const base = Math.min(8000, 500 * 2 ** (attempt - 1));
  return base + Math.floor(random() * 250);
}

function defaultSleep(milliseconds) {
  return new Promise((resolvePromise) => setTimeout(resolvePromise, milliseconds));
}

export async function sendWebhook(payload, webhookValue, options = {}) {
  const webhookUrl = normalizeWebhookUrl(webhookValue);
  const fetchImpl = options.fetchImpl ?? globalThis.fetch;
  const sleep = options.sleep ?? defaultSleep;
  const random = options.random ?? Math.random;
  const maxAttempts = options.maxAttempts ?? MAX_ATTEMPTS;

  if (typeof fetchImpl !== "function") throw new WebhookDeliveryError("HTTP client is not available.");
  if (!Number.isInteger(maxAttempts) || maxAttempts < 1 || maxAttempts > MAX_ATTEMPTS) {
    throw new WebhookDeliveryError("Discord retry configuration is invalid.");
  }

  for (let attempt = 1; attempt <= maxAttempts; attempt += 1) {
    let response;

    try {
      response = await fetchImpl(webhookUrl, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "User-Agent": USER_AGENT,
        },
        body: JSON.stringify(payload),
        redirect: "manual",
        signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
      });
    } catch {
      if (attempt === maxAttempts) {
        throw new WebhookDeliveryError(`Discord webhook request failed after ${maxAttempts} attempts.`);
      }

      await sleep(exponentialBackoff(attempt, random));
      continue;
    }

    if (response.status >= 200 && response.status < 300) return { status: response.status, attempts: attempt };

    const retryable = response.status === 429 || response.status >= 500;
    if (!retryable || attempt === maxAttempts) {
      throw new WebhookDeliveryError(`Discord webhook request failed with HTTP ${response.status}.`, response.status);
    }

    const serverDelay = await retryAfterMilliseconds(response);
    const backoff = exponentialBackoff(attempt, random);
    await sleep(response.status === 429 ? (serverDelay ?? backoff) : Math.max(serverDelay ?? 0, backoff));
  }

  throw new WebhookDeliveryError("Discord webhook request failed.");
}

function commandType(argumentsList) {
  const typeIndex = argumentsList.indexOf("--type");
  const type = typeIndex >= 0 ? argumentsList[typeIndex + 1] : null;
  if (!type || !NOTIFICATION_TYPES.includes(type)) throw new Error("A supported notification type is required.");
  return type;
}

function summaryCell(value) {
  return String(value ?? "")
    .replace(/\|/gu, "\\|")
    .replace(/[<>]/gu, "")
    .replace(/\r?\n/gu, " ")
    .slice(0, 200);
}

export async function writeStepSummary(rendered, deliveryStatus, environment = process.env) {
  const summaryPath = environment.GITHUB_STEP_SUMMARY;
  if (!summaryPath) return;

  const preview = notificationPreview(rendered);
  const markdown = [
    "## Discord Notification",
    "",
    "| Property | Value |",
    "| --- | --- |",
    `| Type | ${summaryCell(preview.type)} |`,
    `| Status | ${summaryCell(deliveryStatus)} |`,
    `| Component | ${summaryCell(preview.component)} |`,
    `| Embed sections | ${summaryCell(preview.fields.join(", ") || "None")} |`,
    "",
  ].join("\n");

  try {
    await appendFile(summaryPath, markdown, "utf8");
  } catch {
    console.warn("GitHub step summary could not be written.");
  }
}

export async function runMain({
  argumentsList = process.argv.slice(2),
  environment = process.env,
  fetchImpl = globalThis.fetch,
  sleep,
  random,
} = {}) {
  const type = commandType(argumentsList);
  const event = await readGitHubEvent(environment.GITHUB_EVENT_PATH);
  const context = createGitHubContext(environment, event);
  const rendered = renderNotification(type, event, context);
  const payload = createDiscordPayload(rendered, environment);

  if (type === "ci" && rendered.conclusion === "success" && !parseBoolean(environment.DISCORD_NOTIFY_CI_SUCCESS)) {
    await writeStepSummary(rendered, "Skipped (successful CI notifications disabled)", environment);
    console.log("Discord notification skipped: successful CI notifications are disabled.");
    return { status: "skipped", reason: "ci-success-disabled" };
  }

  if (rendered.dryRun) {
    await writeStepSummary(rendered, "Validated (dry run)", environment);
    console.log("Discord notification validated: dry run completed without delivery.");
    return { status: "dry-run" };
  }

  const webhook = resolveWebhook(type, environment);
  if (!webhook) {
    if (type === "progress") {
      throw new WebhookDeliveryError("Discord notification cannot be published: no webhook is configured.");
    }

    await writeStepSummary(rendered, "Skipped (no webhook configured)", environment);
    console.log("Discord notification skipped: no webhook configured.");
    return { status: "skipped", reason: "missing-webhook" };
  }

  const delivery = await sendWebhook(payload, webhook.value, { fetchImpl, sleep, random });
  await writeStepSummary(rendered, "Delivered", environment);
  console.log("Discord notification delivered.");
  return { status: "delivered", delivery };
}

const invokedDirectly = process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href;
if (invokedDirectly) {
  runMain().catch((error) => {
    const message = error instanceof Error ? error.message : "Discord notification failed.";
    console.error(message);
    process.exitCode = 1;
  });
}
