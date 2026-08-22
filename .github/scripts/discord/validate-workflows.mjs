import { readdir, readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { CI_WORKFLOW_NAME, COMPONENTS } from "./config.mjs";

const WORKFLOW_DIRECTORY = ".github/workflows";
const EXPECTED_WORKFLOWS = Object.freeze([
  "ci.yml",
  "discord-ci.yml",
  "discord-commits.yml",
  "discord-progress.yml",
  "discord-pull-requests.yml",
  "discord-releases.yml",
]);

const ACTION_PINS = Object.freeze({
  "actions/checkout": "3d3c42e5aac5ba805825da76410c181273ba90b1",
  "actions/setup-node": "820762786026740c76f36085b0efc47a31fe5020",
});

const EXPECTED_NOTIFICATION_TYPES = Object.freeze({
  "discord-ci.yml": "ci",
  "discord-commits.yml": "push",
  "discord-progress.yml": "progress",
  "discord-pull-requests.yml": "pull_request",
  "discord-releases.yml": "release",
});

const EXPECTED_CATEGORY_SECRETS = Object.freeze({
  "discord-ci.yml": "DISCORD_WEBHOOK_CI",
  "discord-commits.yml": "DISCORD_WEBHOOK_COMMITS",
  "discord-progress.yml": "DISCORD_WEBHOOK_PROGRESS",
  "discord-pull-requests.yml": "DISCORD_WEBHOOK_PRS",
  "discord-releases.yml": "DISCORD_WEBHOOK_RELEASES",
});

function requirePattern(errors, text, pattern, message) {
  if (!pattern.test(text)) errors.push(message);
}

function rejectPattern(errors, text, pattern, message) {
  if (pattern.test(text)) errors.push(message);
}

function validateBasicYamlShape(name, text, errors) {
  rejectPattern(errors, text, /\t/u, `${name}: tabs are not allowed.`);
  rejectPattern(errors, text, /[ \t]+$/gmu, `${name}: trailing whitespace is not allowed.`);
  if (!text.endsWith("\n")) errors.push(`${name}: file must end with a newline.`);

  for (const [index, line] of text.split("\n").entries()) {
    if (/^ +/u.test(line) && line.match(/^ */u)[0].length % 2 !== 0) {
      errors.push(`${name}:${index + 1}: indentation must use multiples of two spaces.`);
    }
  }

  const topLevelKeys = text
    .split("\n")
    .map((line) => /^([A-Za-z_][A-Za-z0-9_-]*):(?:\s|$)/u.exec(line)?.[1])
    .filter(Boolean);

  for (const required of ["name", "on", "permissions", "jobs"]) {
    const count = topLevelKeys.filter((key) => key === required).length;
    if (count !== 1) errors.push(`${name}: top-level ${required} key must appear exactly once.`);
  }
}

function validateActionPins(name, text, errors) {
  const uses = [...text.matchAll(/^\s*-?\s*uses:\s*([^\s#]+)(?:\s+#.*)?$/gmu)].map((match) => match[1]);
  if (uses.length === 0) errors.push(`${name}: workflow must use pinned repository setup actions.`);

  for (const reference of uses) {
    const match = /^([^@]+)@([a-f0-9]{40})$/u.exec(reference);
    if (!match) {
      errors.push(`${name}: action reference must use a full commit SHA.`);
      continue;
    }

    const expected = ACTION_PINS[match[1]];
    if (!expected || match[2] !== expected) errors.push(`${name}: action reference is not an approved pin.`);
  }

  requirePattern(errors, text, /persist-credentials:\s*false/u, `${name}: checkout credentials must not persist.`);
  requirePattern(errors, text, /node-version:\s*"24"/u, `${name}: Node.js 24 must be explicit.`);
  requirePattern(errors, text, /package-manager-cache:\s*false/u, `${name}: package-manager cache must remain disabled.`);
}

function validateCommonSecurity(name, text, errors) {
  requirePattern(errors, text, /^permissions:\n  contents:\s*read$/mu, `${name}: permissions must be read-only.`);
  rejectPattern(errors, text, /(?:write-all|:\s*write\b)/iu, `${name}: write permissions are not allowed.`);
  rejectPattern(errors, text, /run:[^\n]*\$\{\{\s*(?:github\.event|inputs\.)/iu, `${name}: untrusted contexts must not be interpolated into run commands.`);
  rejectPattern(errors, text, /https:\/\/(?:discord\.com|discordapp\.com)\/api\/webhooks\//iu, `${name}: webhook URLs must never be committed.`);
  rejectPattern(errors, text, /(?:npm|pnpm|yarn)\s+(?:install|ci)\b/iu, `${name}: privileged notification jobs must not install dependencies.`);
  validateActionPins(name, text, errors);
}

function validateNotificationWorkflow(name, text, errors) {
  const expectedType = EXPECTED_NOTIFICATION_TYPES[name];
  const senderStepMarker = "      - name: Render and deliver notification";
  const senderStepIndex = text.indexOf(senderStepMarker);
  if (senderStepIndex < 0) errors.push(`${name}: fixed sender step is missing.`);
  else if (/\bsecrets\./u.test(text.slice(0, senderStepIndex))) errors.push(`${name}: secrets may exist only in the final sender step.`);

  const runDirectives = [...text.matchAll(/^\s+run:\s*.+$/gmu)].map((match) => match[0].trim());
  if (runDirectives.length !== 1) errors.push(`${name}: privileged bridge must contain exactly one fixed run command.`);
  requirePattern(errors, text, new RegExp(`run: node \\.github/scripts/discord/send\\.mjs --type ${expectedType}\\s*$`, "mu"), `${name}: sender type does not match workflow.`);
  requirePattern(errors, text, /github\.run_attempt\s*==\s*'1'/u, `${name}: notification reruns must be suppressed.`);
  requirePattern(errors, text, /DISCORD_WEBHOOK_DEFAULT:\s*\$\{\{\s*secrets\.DISCORD_WEBHOOK_DEFAULT\s*\}\}/u, `${name}: default webhook fallback is missing.`);

  const actionReferences = [...text.matchAll(/^\s+uses:\s*([^\s#]+)/gmu)].map((match) => match[1]);
  if (actionReferences.length !== 2 || !actionReferences[0].startsWith("actions/checkout@") || !actionReferences[1].startsWith("actions/setup-node@")) {
    errors.push(`${name}: privileged bridge may only run approved checkout and Node setup actions.`);
  }

  const secrets = [...text.matchAll(/secrets\.([A-Z0-9_]+)/gu)].map((match) => match[1]).sort();
  const expectedSecrets = ["DISCORD_WEBHOOK_DEFAULT", EXPECTED_CATEGORY_SECRETS[name]].sort();
  if (JSON.stringify(secrets) !== JSON.stringify(expectedSecrets)) {
    errors.push(`${name}: secret references do not match the approved category and fallback webhooks.`);
  }
  requirePattern(
    errors,
    text,
    new RegExp(`${EXPECTED_CATEGORY_SECRETS[name]}:\\s*\\$\\{\\{\\s*secrets\\.${EXPECTED_CATEGORY_SECRETS[name]}\\s*\\}\\}`, "u"),
    `${name}: category webhook must use its matching environment key.`,
  );

  const variables = new Set([...text.matchAll(/vars\.([A-Z0-9_]+)/gu)].map((match) => match[1]));
  const allowedVariables = new Set(["DISCORD_WEBHOOK_NAME", "DISCORD_BRAND_ICON_URL"]);
  if (name === "discord-ci.yml") allowedVariables.add("DISCORD_NOTIFY_CI_SUCCESS");
  if ([...variables].some((variable) => !allowedVariables.has(variable))) {
    errors.push(`${name}: repository variable reference is not approved for notification branding.`);
  }
}

function validatePullRequestBridge(text, errors) {
  requirePattern(errors, text, /^  pull_request_target:$/mu, "discord-pull-requests.yml: metadata bridge trigger is missing.");
  requirePattern(errors, text, /ref:\s*\$\{\{\s*github\.event\.pull_request\.base\.sha\s*\}\}/u, "discord-pull-requests.yml: trusted base checkout is required.");
  rejectPattern(errors, text, /(?:pull_request\.head|head\.sha|head\.repo|download-artifact|actions\/cache|merge_commit_sha)/iu, "discord-pull-requests.yml: untrusted PR code or artifacts must never be used.");
}

function validateCiBridge(text, errors) {
  requirePattern(errors, text, new RegExp(`workflows:\\s*\\["${CI_WORKFLOW_NAME}"\\]`, "u"), "discord-ci.yml: exact upstream workflow name is required.");
  rejectPattern(errors, text, /^    branches:/mu, "discord-ci.yml: workflow_run must not filter out PR source branches.");
  requirePattern(errors, text, /ref:\s*main/u, "discord-ci.yml: trusted main checkout is required.");
  requirePattern(errors, text, /github\.run_attempt\s*==\s*'1'/u, "discord-ci.yml: bridge reruns must be suppressed.");
  requirePattern(errors, text, /workflow_run\.id\s*\}\}-\$\{\{\s*github\.event\.workflow_run\.run_attempt/u, "discord-ci.yml: upstream attempts need a stable concurrency identity.");
  rejectPattern(errors, text, /(?:head_sha|download-artifact|upload-artifact|actions\/cache)/iu, "discord-ci.yml: upstream code, artifacts, and caches must not be consumed.");
}

function validateProgressChoices(text, errors) {
  const expected = Object.keys(COMPONENTS);
  const componentSection = /      component:\n(?<body>[\s\S]*?)\n      status:/u.exec(text)?.groups?.body ?? "";
  const options = [...componentSection.matchAll(/^          - (.+)$/gmu)].map((match) => match[1].trim());

  if (JSON.stringify(options) !== JSON.stringify(expected)) {
    errors.push("discord-progress.yml: component choices must match the repository component registry.");
  }

  requirePattern(errors, text, /dry_run:[\s\S]*?default:\s*true[\s\S]*?type:\s*boolean/u, "discord-progress.yml: safe dry-run default is required.");
  requirePattern(errors, text, /github\.ref\s*==\s*'refs\/heads\/main'/u, "discord-progress.yml: dispatches must execute from main.");
}

function validateSecretlessCi(text, errors) {
  requirePattern(errors, text, new RegExp(`^name:\\s*${CI_WORKFLOW_NAME}$`, "mu"), "ci.yml: workflow name must remain stable for workflow_run.");
  requirePattern(errors, text, /^  pull_request:$/mu, "ci.yml: pull request validation is required.");
  requirePattern(errors, text, /^  push:$/mu, "ci.yml: main-branch validation is required.");
  rejectPattern(errors, text, /\bsecrets\./u, "ci.yml: validation workflow must remain secretless.");
}

export function validateWorkflowText(name, text) {
  const errors = [];
  validateBasicYamlShape(name, text, errors);
  validateCommonSecurity(name, text, errors);

  if (name in EXPECTED_NOTIFICATION_TYPES) validateNotificationWorkflow(name, text, errors);
  if (name === "discord-pull-requests.yml") validatePullRequestBridge(text, errors);
  if (name === "discord-ci.yml") validateCiBridge(text, errors);
  if (name === "discord-progress.yml") validateProgressChoices(text, errors);
  if (name === "ci.yml") validateSecretlessCi(text, errors);

  return errors;
}

export async function validateRepositoryWorkflows(directory = WORKFLOW_DIRECTORY) {
  const files = (await readdir(directory)).filter((name) => /\.ya?ml$/u.test(name)).sort();
  const errors = [];

  const missing = EXPECTED_WORKFLOWS.filter((name) => !files.includes(name));
  if (missing.length > 0) errors.push(`Missing notification workflows: ${missing.join(", ")}.`);

  const validated = EXPECTED_WORKFLOWS.filter((entry) => files.includes(entry));
  for (const name of validated) {
    const text = await readFile(resolve(directory, name), "utf8");
    errors.push(...validateWorkflowText(name, text));
  }

  if (errors.length > 0) throw new Error(`Workflow policy validation failed:\n- ${errors.join("\n- ")}`);
  return validated;
}

const invokedDirectly = process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href;
if (invokedDirectly) {
  validateRepositoryWorkflows()
    .then((files) => console.log(`Validated ${files.length} GitHub workflows.`))
    .catch((error) => {
      console.error(error instanceof Error ? error.message : "Workflow policy validation failed.");
      process.exitCode = 1;
    });
}
