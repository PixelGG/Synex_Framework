import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { normalizeWebhookUrl, runMain, sendWebhook, WebhookDeliveryError } from "../send.mjs";

const webhookId = "123456789012345678";
const webhookToken = ["abcdefghijklmnopqrstuvwxyz", "_ABCDEF-012345"].join("");
const webhookPath = ["", "api", "webhooks", webhookId, webhookToken].join("/");
const webhook = new URL(webhookPath, "https://discord.com").toString();
const payload = { allowed_mentions: { parse: [] }, embeds: [{ title: "Test", fields: [] }] };

async function withEventFile(event, callback) {
  const directory = await mkdtemp(join(tmpdir(), "synex-notification-test-"));
  const eventPath = join(directory, "event.json");
  await writeFile(eventPath, JSON.stringify(event), "utf8");

  try {
    return await callback(eventPath);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
}

function pushEvent() {
  return {
    ref: "refs/heads/main",
    size: 1,
    compare: "https://github.com/PixelGG/Synex_Framework/compare/a...b",
    commits: [{ id: "a".repeat(40), message: "feat(core): add lifecycle", modified: ["core/synex_core/.gitkeep"] }],
    head_commit: { timestamp: "2026-08-22T12:00:00Z" },
    repository: { full_name: "PixelGG/Synex_Framework", html_url: "https://github.com/PixelGG/Synex_Framework" },
    sender: { login: "PixelGG" },
  };
}

test("webhook URLs are normalized to API v10 with wait=true", () => {
  const normalized = new URL(normalizeWebhookUrl(`${webhook}?wait=false`));
  assert.equal(normalized.origin, "https://discord.com");
  assert.equal(normalized.pathname, ["", "api", "v10", "webhooks", webhookId, webhookToken].join("/"));
  assert.equal(normalized.searchParams.get("wait"), "true");
  assert.equal([...normalized.searchParams.keys()].filter((key) => key === "wait").length, 1);
});

test("webhook validation rejects arbitrary hosts, suffixes, and ambiguous queries", () => {
  const invalid = [
    webhook.replace("https://", "http://"),
    webhook.replace("discord.com", "discord.com.example.org"),
    `${webhook}/github`,
    `${webhook}?redirect=https://example.com`,
    `${webhook}?wait=false&wait=true`,
  ];

  for (const value of invalid) {
    assert.throws(() => normalizeWebhookUrl(value), WebhookDeliveryError);
  }
});

test("confirmed and documented no-content responses are accepted", async () => {
  for (const status of [200, 204]) {
    let request;
    const result = await sendWebhook(payload, webhook, {
      fetchImpl: async (url, options) => {
        request = { url, options };
        return new Response(status === 204 ? null : "{}", { status });
      },
    });

    assert.equal(result.status, status);
    assert.match(request.url, /wait=true/u);
    assert.equal(request.options.redirect, "manual");
    assert.equal(request.options.headers["Content-Type"], "application/json");
    assert.deepEqual(JSON.parse(request.options.body).allowed_mentions, { parse: [] });
  }
});

test("HTTP 429 honors retry_after before retrying", async () => {
  const delays = [];
  let calls = 0;
  const result = await sendWebhook(payload, webhook, {
    fetchImpl: async () => {
      calls += 1;
      if (calls === 1) {
        return new Response(JSON.stringify({ retry_after: 0.25 }), {
          status: 429,
          headers: { "content-type": "application/json", "retry-after": "0.1" },
        });
      }
      return new Response("{}", { status: 200 });
    },
    sleep: async (milliseconds) => delays.push(milliseconds),
    random: () => 0,
  });

  assert.equal(result.attempts, 2);
  assert.deepEqual(delays, [250]);
});

test("transient server and network failures retry with bounded backoff", async () => {
  const delays = [];
  let calls = 0;
  const result = await sendWebhook(payload, webhook, {
    fetchImpl: async () => {
      calls += 1;
      if (calls === 1) throw new TypeError("temporary network error");
      if (calls === 2) return new Response("", { status: 502 });
      return new Response("{}", { status: 200 });
    },
    sleep: async (milliseconds) => delays.push(milliseconds),
    random: () => 0,
  });

  assert.equal(result.attempts, 3);
  assert.deepEqual(delays, [500, 1000]);
});

test("permanent failures do not retry or reveal the webhook", async () => {
  let calls = 0;
  await assert.rejects(
    sendWebhook(payload, webhook, {
      fetchImpl: async () => {
        calls += 1;
        return new Response("not found", { status: 404 });
      },
      sleep: async () => assert.fail("Permanent failures must not sleep."),
    }),
    (error) => {
      assert.equal(error.status, 404);
      assert.ok(!error.message.includes(webhookId));
      assert.ok(!error.message.includes(webhookToken));
      return true;
    },
  );
  assert.equal(calls, 1);
});

test("runner uses a category webhook first and the default as fallback", async () => {
  const categoryToken = ["category_token_", "ABCDEFGHIJKLMNOPQRSTUVWXYZ"].join("");
  const categoryWebhook = webhook.replace(webhookToken, categoryToken);

  await withEventFile(pushEvent(), async (eventPath) => {
    const deliveredUrls = [];
    const baseEnvironment = {
      GITHUB_EVENT_PATH: eventPath,
      GITHUB_REPOSITORY: "PixelGG/Synex_Framework",
      GITHUB_SERVER_URL: "https://github.com",
      GITHUB_ACTOR: "PixelGG",
      DISCORD_WEBHOOK_DEFAULT: webhook,
    };

    await runMain({
      argumentsList: ["--type", "push"],
      environment: baseEnvironment,
      fetchImpl: async (url) => {
        deliveredUrls.push(url);
        return new Response("{}", { status: 200 });
      },
    });

    await runMain({
      argumentsList: ["--type", "push"],
      environment: { ...baseEnvironment, DISCORD_WEBHOOK_COMMITS: categoryWebhook },
      fetchImpl: async (url) => {
        deliveredUrls.push(url);
        return new Response("{}", { status: 200 });
      },
    });

    assert.ok(deliveredUrls[0].includes(webhookToken));
    assert.ok(deliveredUrls[1].includes(categoryToken));
  });
});

test("runner skips automatic feeds without a webhook", async () => {
  await withEventFile(pushEvent(), async (eventPath) => {
    const result = await runMain({
      argumentsList: ["--type", "push"],
      environment: {
        GITHUB_EVENT_PATH: eventPath,
        GITHUB_REPOSITORY: "PixelGG/Synex_Framework",
        GITHUB_SERVER_URL: "https://github.com",
      },
      fetchImpl: async () => assert.fail("Missing-webhook skip must not call fetch."),
    });

    assert.deepEqual(result, { status: "skipped", reason: "missing-webhook" });
  });
});

test("progress dry runs need no webhook but real publishes do", async () => {
  const event = {
    inputs: {
      title: "Core Architecture",
      component: "synex_core",
      status: "In Development",
      progress: "80",
      summary: "Player session lifecycle.",
      dry_run: true,
    },
    repository: { full_name: "PixelGG/Synex_Framework", html_url: "https://github.com/PixelGG/Synex_Framework" },
    sender: { login: "PixelGG" },
  };

  await withEventFile(event, async (eventPath) => {
    const environment = {
      GITHUB_EVENT_PATH: eventPath,
      GITHUB_REPOSITORY: "PixelGG/Synex_Framework",
      GITHUB_SERVER_URL: "https://github.com",
      GITHUB_ACTOR: "PixelGG",
    };
    const result = await runMain({
      argumentsList: ["--type", "progress"],
      environment,
      fetchImpl: async () => assert.fail("Dry run must not call fetch."),
    });
    assert.deepEqual(result, { status: "dry-run" });

    await writeFile(eventPath, JSON.stringify({ ...event, inputs: { ...event.inputs, dry_run: false } }), "utf8");
    await assert.rejects(
      runMain({ argumentsList: ["--type", "progress"], environment }),
      /no webhook is configured/u,
    );
  });
});

test("successful CI notifications remain opt-in", async () => {
  const event = {
    workflow_run: {
      id: 123,
      name: "Synex Notification CI",
      conclusion: "success",
      head_branch: "main",
      head_sha: "a".repeat(40),
      run_number: 8,
      run_attempt: 1,
      run_started_at: "2026-08-22T12:00:00Z",
      updated_at: "2026-08-22T12:00:05Z",
      html_url: "https://github.com/PixelGG/Synex_Framework/actions/runs/123",
      actor: { login: "PixelGG" },
    },
    repository: { full_name: "PixelGG/Synex_Framework", html_url: "https://github.com/PixelGG/Synex_Framework" },
  };

  await withEventFile(event, async (eventPath) => {
    const result = await runMain({
      argumentsList: ["--type", "ci"],
      environment: {
        GITHUB_EVENT_PATH: eventPath,
        GITHUB_REPOSITORY: "PixelGG/Synex_Framework",
        GITHUB_SERVER_URL: "https://github.com",
        DISCORD_WEBHOOK_CI: webhook,
      },
      fetchImpl: async () => assert.fail("Disabled CI success must not call fetch."),
    });

    assert.deepEqual(result, { status: "skipped", reason: "ci-success-disabled" });
  });
});
