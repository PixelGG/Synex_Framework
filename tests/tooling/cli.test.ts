import assert from "node:assert/strict";
import { mkdtemp, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import {
  CliError,
  createResource,
  resolveWithin,
  runBenchmark,
  runCli,
  satisfiesVersionRange,
} from "../../tools/cli/src/cli.js";

test("version range checks handle exact, caret, tilde, and comparator ranges", () => {
  assert.equal(satisfiesVersionRange("1.4.2", "^1.2.0"), true);
  assert.equal(satisfiesVersionRange("2.0.0", "^1.2.0"), false);
  assert.equal(satisfiesVersionRange("0.2.7", "^0.2.1"), true);
  assert.equal(satisfiesVersionRange("0.3.0", "^0.2.1"), false);
  assert.equal(satisfiesVersionRange("1.2.9", "~1.2.3"), true);
  assert.equal(satisfiesVersionRange("1.3.0", "~1.2.3"), false);
  assert.equal(satisfiesVersionRange("1.5.0", ">=1.0.0 <2.0.0"), true);
  assert.equal(satisfiesVersionRange("1.1.0-beta.1", "^1.0.0"), false);
  assert.equal(satisfiesVersionRange("1.1.0-beta.02", "^1.0.0"), false);
});

test("path resolution rejects traversal outside the repository boundary", () => {
  const root = join(tmpdir(), "synex-path-root");
  assert.throws(() => resolveWithin(root, "../outside"), CliError);
  assert.equal(resolveWithin(root, "resources"), join(root, "resources"));
});

test("resource creation refuses an existing target", async (context) => {
  const root = await mkdtemp(join(tmpdir(), "synex-create-"));
  context.after(async () => rm(root, { recursive: true, force: true }));
  await writeFile(
    join(root, "package.json"),
    `${JSON.stringify({ name: "synex-test", version: "0.1.0", synex: { apiVersion: "1.0.0" } })}\n`,
    "utf8",
  );
  const created = await createResource(root, "example", "resources");
  assert.equal(created.every((path) => path.startsWith("resources/synex_example/")), true);
  await assert.rejects(createResource(root, "synex_example", "resources"), CliError);
});

test("resource creation rejects a parent symlink before writing outside the repository", async (context) => {
  const root = await mkdtemp(join(tmpdir(), "synex-create-link-"));
  const outside = await mkdtemp(join(tmpdir(), "synex-create-outside-"));
  context.after(async () => {
    await rm(root, { recursive: true, force: true });
    await rm(outside, { recursive: true, force: true });
  });
  await writeFile(
    join(root, "package.json"),
    `${JSON.stringify({ name: "synex-test", version: "0.1.0", synex: { apiVersion: "1.0.0" } })}\n`,
    "utf8",
  );
  await symlink(outside, join(root, "resources"), "junction");
  await assert.rejects(
    createResource(root, "escaped", "resources"),
    /must not traverse symbolic links/u,
  );
});

test("benchmark is bounded and labels itself as a local microbenchmark", () => {
  const report = runBenchmark(10);
  assert.equal(report.iterations, 10);
  assert.match(report.disclaimer, /not a FiveM runtime or production performance claim/u);
  assert.throws(() => runBenchmark(0), CliError);
  assert.throws(() => runBenchmark(100_001), CliError);
});

test("CLI exposes help and a real benchmark command", async () => {
  const output: string[] = [];
  const errors: string[] = [];
  const io = { log: (message: string) => output.push(message), error: (message: string) => errors.push(message) };

  assert.equal(await runCli(["--help"], io), 0);
  assert.match(output.join("\n"), /contract generate/u);
  assert.match(output.join("\n"), /live-test prepare --probe/u);
  output.length = 0;

  assert.equal(await runCli(["benchmark", "--iterations", "1", "--root", process.cwd()], io), 0);
  assert.match(output.join("\n"), /headless microbenchmark/u);
  assert.deepEqual(errors, []);
});
