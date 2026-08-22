import test from "node:test";
import assert from "node:assert/strict";
import { DISCORD_LIMITS } from "../config.mjs";
import {
  codePointLength,
  embedTextLength,
  finalizeEmbed,
  parseMultilineList,
  parseProgress,
  progressBar,
  safePublicHttpsUrl,
  sanitizeUntrusted,
  truncate,
  validatePayload,
} from "../utils.mjs";

test("progress values and 20-segment bars cover the full range", () => {
  const cases = new Map([
    [0, 0],
    [5, 1],
    [25, 5],
    [50, 10],
    [75, 15],
    [95, 19],
    [100, 20],
  ]);

  for (const [percentage, expectedFilled] of cases) {
    assert.equal(parseProgress(String(percentage)), percentage);
    const bar = progressBar(percentage);
    assert.equal([...bar.matchAll(/\u25b0/gu)].length, expectedFilled);
    assert.equal([...bar.matchAll(/\u25b1/gu)].length, 20 - expectedFilled);
    assert.match(bar, new RegExp(`\\*\\*${percentage}%\\*\\*$`, "u"));
  }

  assert.throws(() => parseProgress(-1), /0 to 100/u);
  assert.throws(() => parseProgress(101), /0 to 100/u);
  assert.throws(() => parseProgress(12.5), /whole number/u);
});

test("truncation counts Unicode code points and keeps the exact limit", () => {
  const result = truncate("\ud83d\ude80".repeat(300), 256);
  assert.equal(codePointLength(result), 256);
  assert.ok(result.endsWith("\u2026"));
});

test("untrusted text neutralizes mentions, links, headings, code fences, and controls", () => {
  const result = sanitizeUntrusted(
    "# Heading\n@everyone @here <@123456789012345678> [masked](https://example.com) ``` **bold** > quote\u0000",
    { limit: 500 },
  );

  assert.doesNotMatch(result, /@everyone|@here|<@|\]\(|`|\u0000/u);
  assert.doesNotMatch(result, /\*\*/u);
  assert.match(result, /^Heading/mu);
  assert.match(result, /\uff20everyone/u);
  assert.match(result, /\u2039\uff20123456789012345678\u203a/u);
});

test("multiline input becomes a bounded clean list", () => {
  const result = parseMultilineList("- first\n* second\n3. third\n\n# fourth\n- fifth", { maxItems: 4 });
  assert.deepEqual(result, ["first", "second", "third", "fourth"]);
});

test("empty optional fields are removed from finalized embeds", () => {
  const embed = finalizeEmbed({
    title: "Status",
    fields: [
      { name: "PRESENT", value: "value" },
      { name: "EMPTY", value: "" },
      { name: "", value: "value" },
    ],
  });

  assert.deepEqual(embed.fields, [{ name: "PRESENT", value: "value", inline: false }]);
});

test("individual and combined Discord embed limits are enforced", () => {
  const embed = finalizeEmbed({
    title: "T".repeat(1000),
    description: "D".repeat(10_000),
    author: { name: "A".repeat(1000) },
    footer: { text: "F".repeat(4000) },
    fields: Array.from({ length: 40 }, (_, index) => ({
      name: `Field ${index} ${"N".repeat(400)}`,
      value: "V".repeat(3000),
    })),
  });

  assert.equal(codePointLength(embed.title), DISCORD_LIMITS.title);
  assert.ok(codePointLength(embed.description) <= DISCORD_LIMITS.description);
  assert.equal(embed.fields.length, DISCORD_LIMITS.fields);
  assert.ok(embed.fields.every((field) => codePointLength(field.name) <= DISCORD_LIMITS.fieldName));
  assert.ok(embed.fields.every((field) => codePointLength(field.value) <= DISCORD_LIMITS.fieldValue));
  assert.ok(embedTextLength(embed) <= DISCORD_LIMITS.embedTotal);

  assert.equal(validatePayload({ allowed_mentions: { parse: [] }, embeds: [embed] }), true);

  const largeEmbed = { title: "A".repeat(100), description: "D".repeat(3000), fields: [] };
  assert.throws(
    () => validatePayload({ allowed_mentions: { parse: [] }, embeds: [largeEmbed, largeEmbed] }),
    /combined text limit/u,
  );
});

test("mention suppression must be exact", () => {
  const embed = finalizeEmbed({ title: "Safe", fields: [] });
  assert.throws(
    () => validatePayload({ allowed_mentions: { parse: [], users: [] }, embeds: [embed] }),
    /suppress all automatic mentions/u,
  );
});

test("brand icon URLs reject local and IP-literal hosts", () => {
  assert.equal(safePublicHttpsUrl("https://127.0.0.1/synex.png"), null);
  assert.equal(safePublicHttpsUrl("https://localhost/synex.png"), null);
  assert.equal(safePublicHttpsUrl("https://localhost./synex.png"), null);
  assert.equal(safePublicHttpsUrl("https://assets.internal./synex.png"), null);
  assert.equal(safePublicHttpsUrl("https://assets.example.com/synex.png"), "https://assets.example.com/synex.png");
});
