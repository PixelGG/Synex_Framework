import test from "node:test";
import assert from "node:assert/strict";
import {
  branchFromRef,
  commitSummary,
  createGitHubContext,
  inferCommitComponent,
  parseConventionalCommit,
  shortSha,
} from "../github.mjs";

test("Conventional Commits map only verified Synex scopes", () => {
  assert.deepEqual(parseConventionalCommit("feat(core): add lifecycle"), {
    component: "synex_core",
    scope: "core",
    summary: "add lifecycle",
    type: "feat",
    typeLabel: "Feature",
  });

  const unknown = parseConventionalCommit("fix(unknown): repair behavior");
  assert.equal(unknown.component, null);
  assert.equal(inferCommitComponent([{ message: "fix(unknown): repair behavior" }]), "Repository Update");
  assert.equal(inferCommitComponent([{ message: "docs(readme): update ecosystem" }]), "Documentation");
});

test("commit formatting sanitizes an untrusted scope and first line", () => {
  const summary = commitSummary("feat(core**): notify @everyone [click](https://example.com)\nbody");
  assert.doesNotMatch(summary, /@everyone|\]\(|\*\*/u);
  assert.match(summary, /^feat\(core/u);
});

test("component inference combines scopes and changed paths defensively", () => {
  assert.equal(
    inferCommitComponent([
      {
        message: "feat(core): add lifecycle",
        modified: ["core/synex_core/.gitkeep"],
      },
    ]),
    "Core \u2022 Feature",
  );

  assert.equal(
    inferCommitComponent([
      {
        message: "feat(core): add lifecycle",
        modified: ["libraries/synex_ui/.gitkeep"],
      },
    ]),
    "Multiple components",
  );

  assert.equal(
    inferCommitComponent([{ message: "update layout", modified: ["resources/synex_phone/.gitkeep"] }]),
    "Phone",
  );
});

test("GitHub context and identifiers use safe repository metadata", () => {
  const context = createGitHubContext(
    {
      GITHUB_REPOSITORY: "PixelGG/Synex_Framework",
      GITHUB_SERVER_URL: "https://github.com",
      GITHUB_ACTOR: "PixelGG",
    },
    { repository: { html_url: "https://github.com/PixelGG/Synex_Framework" } },
  );

  assert.equal(context.repositoryUrl, "https://github.com/PixelGG/Synex_Framework");
  assert.equal(branchFromRef("refs/heads/main"), "main");
  assert.equal(shortSha("a".repeat(40)), "aaaaaaa");
  assert.equal(shortSha("not-a-sha"), "unknown");
});
