import test from "node:test";
import assert from "node:assert/strict";
import { COLORS, DISCORD_LIMITS, PROGRESS_STATUSES } from "../config.mjs";
import {
  createDiscordPayload,
  renderCi,
  renderProgress,
  renderPullRequest,
  renderPush,
  renderRelease,
} from "../templates.mjs";
import { embedTextLength } from "../utils.mjs";

const context = Object.freeze({
  actor: "PixelGG",
  refName: "main",
  repositoryUrl: "https://github.com/PixelGG/Synex_Framework",
  timestamp: "2026-08-22T12:00:00.000Z",
});

function commit(index, message = `feat(core): change ${index}`) {
  const hex = index.toString(16).padStart(40, "a").slice(-40);
  return {
    id: hex,
    message,
    timestamp: context.timestamp,
    modified: ["core/synex_core/.gitkeep"],
  };
}

test("multi-commit pushes render one bounded digest", () => {
  const rendered = renderPush(
    {
      ref: "refs/heads/main",
      size: 8,
      compare: "https://github.com/PixelGG/Synex_Framework/compare/a...b",
      commits: Array.from({ length: 8 }, (_, index) => commit(index + 1, `feat(core): ${"long change ".repeat(1000)}${index}`)),
      head_commit: { timestamp: context.timestamp },
    },
    context,
  );

  const changes = rendered.embed.fields.find((field) => field.name === "RECENT CHANGES");
  assert.equal(rendered.embed.title, "Code Update");
  assert.match(changes.value, /\+ 3 additional commits/u);
  assert.equal((changes.value.match(/https:\/\/github\.com/gu) ?? []).length, 5);
  assert.equal(changes.value.split("\n").length, 6);
  assert.equal((changes.value.match(/\]\(https:\/\/github\.com[^)]+\)/gu) ?? []).length, 5);
  assert.ok(changes.value.length <= DISCORD_LIMITS.fieldValue);
  assert.ok(embedTextLength(rendered.embed) <= DISCORD_LIMITS.embedTotal);
});

test("huge and mention-bearing commit messages remain safe", () => {
  const rendered = renderPush(
    {
      ref: "refs/heads/main",
      size: 1,
      compare: "https://github.com/PixelGG/Synex_Framework/compare/a...b",
      commits: [commit(1, `feat(core): @everyone <@123456789012345678> ${"x".repeat(10_000)}`)],
      head_commit: { timestamp: context.timestamp },
    },
    context,
  );
  const payload = createDiscordPayload(rendered, {});

  assert.deepEqual(payload.allowed_mentions, { parse: [] });
  assert.doesNotMatch(rendered.embed.description, /@everyone|<@/u);
  assert.ok(embedTextLength(rendered.embed) <= DISCORD_LIMITS.embedTotal);
});

test("release notes are shortened to six highlights", () => {
  const body = Array.from({ length: 100 }, (_, index) => `- ${"release note ".repeat(30)}${index}`).join("\n");
  const rendered = renderRelease(
    {
      release: {
        tag_name: "v0.4.0",
        name: "Synex v0.4.0",
        prerelease: false,
        body,
        html_url: "https://github.com/PixelGG/Synex_Framework/releases/tag/v0.4.0",
        author: { login: "PixelGG" },
        published_at: context.timestamp,
      },
    },
    context,
  );

  const highlights = rendered.embed.fields.find((field) => field.name === "HIGHLIGHTS");
  assert.equal((highlights.value.match(/^\u2022 /gmu) ?? []).length, 6);
  assert.ok(highlights.value.length <= DISCORD_LIMITS.fieldValue);
  assert.ok(embedTextLength(rendered.embed) <= DISCORD_LIMITS.embedTotal);
});

test("progress renderer omits empty optional fields", () => {
  const rendered = renderProgress(
    {
      inputs: {
        title: "Core Architecture",
        component: "synex_core",
        status: "In Development",
        progress: "80",
        summary: "Player session lifecycle and callback architecture.",
        highlights: "",
        next_steps: "",
        target: "",
        dry_run: true,
      },
    },
    context,
  );

  assert.equal(rendered.dryRun, true);
  assert.match(rendered.embed.description, /80%/u);
  assert.deepEqual(
    rendered.embed.fields.map((field) => field.name),
    ["STATUS", "COMPONENT", "CURRENT FOCUS", "PUBLISHED BY"],
  );
});

test("progress statuses use the central semantic color mapping", () => {
  for (const [status, style] of Object.entries(PROGRESS_STATUSES)) {
    const rendered = renderProgress(
      {
        inputs: {
          title: "Status check",
          component: "Repository",
          status,
          progress: "50",
          summary: "Verifying notification state.",
        },
      },
      context,
    );
    assert.equal(rendered.embed.color, style.color);
  }

  assert.throws(
    () => renderProgress({ inputs: { title: "Invalid", component: "fake_module", status: "Planning", progress: 0, summary: "x" } }, context),
    /not part of the Synex repository/u,
  );
  assert.throws(
    () => renderProgress({ inputs: { title: "Invalid", component: "__proto__", status: "Planning", progress: 0, summary: "x" } }, context),
    /not part of the Synex repository/u,
  );
  assert.throws(
    () => renderProgress({ inputs: { title: "Invalid", component: "Repository", status: "__proto__", progress: 0, summary: "x" } }, context),
    /status is not supported/u,
  );
});

test("pull request lifecycle maps every configured transition", () => {
  const base = {
    number: 24,
    title: "Improve player lifecycle handling",
    draft: false,
    user: { login: "PixelGG" },
    head: { ref: "feat/session-lifecycle" },
    base: { ref: "main" },
    commits: 5,
    updated_at: context.timestamp,
  };

  const cases = [
    ["opened", false, "Pull Request Opened", COLORS.brand],
    ["reopened", false, "Pull Request Reopened", COLORS.brand],
    ["ready_for_review", false, "Pull Request Ready for Review", COLORS.warning],
    ["converted_to_draft", false, "Pull Request Drafted", COLORS.neutral],
    ["closed", true, "Pull Request Merged", COLORS.success],
    ["closed", false, "Pull Request Closed", COLORS.neutral],
  ];

  for (const [action, merged, title, color] of cases) {
    const rendered = renderPullRequest(
      {
        action,
        pull_request: {
          ...base,
          merged,
          merged_at: merged ? context.timestamp : null,
          closed_at: action === "closed" ? context.timestamp : null,
        },
      },
      context,
    );
    assert.equal(rendered.embed.title, title);
    assert.equal(rendered.embed.color, color);
  }
});

test("CI renderer is fail-closed to the approved workflow and labels rerun attempts", () => {
  const run = {
    id: 123,
    name: "Synex Notification CI",
    conclusion: "failure",
    head_branch: "feature/test",
    head_sha: "b".repeat(40),
    run_number: 18,
    run_attempt: 2,
    run_started_at: "2026-08-22T12:00:00Z",
    updated_at: "2026-08-22T12:01:42Z",
    html_url: "https://github.com/PixelGG/Synex_Framework/actions/runs/123",
    actor: { login: "PixelGG" },
  };
  const rendered = renderCi({ workflow_run: run }, context);

  assert.equal(rendered.embed.color, COLORS.error);
  assert.equal(rendered.embed.fields.find((field) => field.name === "ATTEMPT").value, "2");
  assert.equal(rendered.embed.fields.find((field) => field.name === "DURATION").value, "1m 42s");
  assert.throws(() => renderCi({ workflow_run: { ...run, name: "Discord - CI Status" } }, context), /approved CI source/u);
});
