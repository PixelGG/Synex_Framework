# Synex Development Feed

Synex uses a small, dependency-free Node.js layer to turn GitHub event data into consistent Discord Rich Embeds. GitHub Actions selects the event and credentials; the event adapter validates and sanitizes external values; the renderer owns presentation; the sender owns Discord delivery.

```text
GitHub event
    -> trusted event adapter
    -> Synex embed renderer
    -> payload validation
    -> Discord Webhook API
```

## Notifications

| Feed | Trigger | Delivery behavior |
| --- | --- | --- |
| Code updates | Push to `main` | One digest per push, with at most five visible commits |
| Pull requests | Opened, reopened, ready, drafted, merged, or closed | Metadata-only notification; fork code is never executed |
| Development progress | Manual `workflow_dispatch` on `main` | Validated form inputs with a 20-segment progress bar and optional dry run |
| Releases | Published GitHub release | Stable or pre-release metadata with shortened release highlights |
| CI status | Completion of `Synex Notification CI` | Non-success results are sent; success is opt-in |

The feed reports repository and workflow facts only. Manual progress values come directly from the submitted workflow inputs.

## Configure Discord delivery

Create an Incoming Webhook for the intended Discord channel, then add its copied webhook URL as a GitHub Actions repository secret under **Settings -> Secrets and variables -> Actions**. Start with only:

```text
DISCORD_WEBHOOK_DEFAULT
```

That secret is the fallback for every feed. Category-specific secrets can be added later to route notifications to separate channels:

| Repository secret | Used by |
| --- | --- |
| `DISCORD_WEBHOOK_DEFAULT` | Optional fallback for every category |
| `DISCORD_WEBHOOK_COMMITS` | Push digests |
| `DISCORD_WEBHOOK_PRS` | Pull request lifecycle |
| `DISCORD_WEBHOOK_PROGRESS` | Manual progress updates |
| `DISCORD_WEBHOOK_RELEASES` | Published releases |
| `DISCORD_WEBHOOK_CI` | CI conclusions |

For example, the commit feed uses `DISCORD_WEBHOOK_COMMITS` when present and otherwise uses `DISCORD_WEBHOOK_DEFAULT`. Webhook URLs belong in **Secrets**, never repository variables, workflow files, source files, or logs.

Optional repository variables:

| Repository variable | Default | Purpose |
| --- | --- | --- |
| `DISCORD_WEBHOOK_NAME` | `Synex Development` | Display name used for webhook messages |
| `DISCORD_BRAND_ICON_URL` | Not set | Maintainer-provided public HTTPS URL for a real Synex icon; the configured Discord webhook avatar is used when omitted |
| `DISCORD_NOTIFY_CI_SUCCESS` | `false` | Set to `true` to publish successful CI conclusions |

The icon variable rejects non-HTTPS, local, and IP-literal URLs. A maintainer must still verify that it points to a publicly reachable, project-owned Synex asset; ownership and reachability cannot be proven from URL syntax. Omit the variable when no such asset is available. No image is synthesized or uploaded by the workflow.

## First activation

GitHub evaluates `pull_request_target` and `workflow_run` workflows only after their workflow files exist on the default branch. The pull request that introduces this system therefore does not notify itself through those two bridges.

After the files reach `main`:

1. Run **Synex Notification CI** once with `workflow_dispatch`.
2. Run **Discord - Development Progress** with `dry_run=true`.
3. Confirm the metadata-only step summaries.
4. Configure the webhook secret and perform a deliberate progress publish with `dry_run=false`.

## Publish a progress update

1. Open **Actions -> Discord - Development Progress -> Run workflow**.
2. Keep the selected branch on `main`.
3. Select an existing Synex component and status.
4. Enter a whole-number progress value from `0` through `100`.
5. Add a concise summary; enter highlights and next steps one item per line when needed.
6. Leave `dry_run` enabled for validation. The workflow writes a metadata-only preview to the GitHub step summary and sends nothing.
7. Disable `dry_run` only when the update is ready to publish.

A real publish fails clearly if neither `DISCORD_WEBHOOK_PROGRESS` nor `DISCORD_WEBHOOK_DEFAULT` is configured. Automatic feeds skip cleanly when their category and fallback webhooks are both absent.

## CI behavior

`Synex Notification CI` is a secretless validation workflow. It checks the notification JavaScript, tests the renderer and sender, and enforces reviewed workflow security invariants. It runs for relevant pull requests and pushes to `main`.

`Discord - CI Status` listens only for that exact workflow name. It checks out `main`, reads only the `workflow_run` event payload, and never downloads code, caches, or artifacts from the upstream run. CI failures and other non-success conclusions are published by default. Successful conclusions require `DISCORD_NOTIFY_CI_SUCCESS=true`.

Rerunning a Discord bridge itself is suppressed with `github.run_attempt`. An upstream CI rerun is treated as a new attempt and is labeled with its attempt number. Discord Incoming Webhooks do not provide an idempotency key, so exact-once delivery cannot be guaranteed without external state.

## Security model

- Every workflow has explicit `contents: read` permissions and no write permission.
- `actions/checkout` and `actions/setup-node` are official actions pinned to reviewed full commit SHAs.
- Webhook secrets exist only in the final sender step environment.
- Pull request notifications use `pull_request_target` strictly as a metadata bridge and check out the trusted PR base SHA. PR head code, merge commits, artifacts, caches, and dependency installation are excluded.
- The `workflow_run` bridge executes only the sender from `main` and verifies the upstream workflow name again in code.
- Event values are parsed from `GITHUB_EVENT_PATH`; they are never interpolated into shell commands.
- Every payload includes `allowed_mentions: { parse: [] }`. Untrusted mentions, control characters, directional controls, headings, code fences, masked Markdown links, and formatting controls are neutralized.
- Discord title, description, author, footer, field, count, and combined 6,000-character limits are enforced centrally before delivery.
- Webhook validation accepts only HTTPS URLs on `discord.com` with the official webhook path. The URL, webhook ID, token, response body, and payload are never written to logs or step summaries.

## Delivery and retries

The sender uses Discord API v10 with `wait=true`. HTTP `429`, transient `5xx`, and network failures are retried at most four times. Discord's `retry_after` or rate-limit reset header is honored when present; ordinary `4xx` responses, including an invalid or deleted webhook, are not retried.

Webhook execution creates messages without an idempotency key. If Discord accepts a message but the response is lost or returns a transient failure, a bounded retry can create a duplicate. This is the intentional at-least-once tradeoff for recovering from temporary delivery failures.

If a webhook URL is ever exposed in a log, commit, screenshot, or message, delete or regenerate that webhook in Discord immediately and replace the corresponding GitHub secret.

## Local validation

Node.js 24 is the CI runtime. No package installation is required.

```bash
node .github/scripts/discord/validate-workflows.mjs
node --test .github/scripts/discord/tests/github.test.mjs .github/scripts/discord/tests/send.test.mjs .github/scripts/discord/tests/templates.test.mjs .github/scripts/discord/tests/utils.test.mjs
```

The workflow policy script is a focused guardrail for the reviewed notification files, not a general-purpose YAML parser. GitHub performs the authoritative workflow-schema validation when the files are published.

## Source layout

```text
.github/
├── scripts/discord/
│   ├── config.mjs
│   ├── github.mjs
│   ├── send.mjs
│   ├── templates.mjs
│   ├── utils.mjs
│   ├── validate-workflows.mjs
│   └── tests/
└── workflows/
    ├── ci.yml
    ├── discord-ci.yml
    ├── discord-commits.yml
    ├── discord-progress.yml
    ├── discord-pull-requests.yml
    └── discord-releases.yml
```

## Official references

- [Discord: Execute Webhook](https://docs.discord.com/developers/resources/webhook#execute-webhook)
- [Discord: Embed limits](https://docs.discord.com/developers/resources/message#embed-limits)
- [Discord: Allowed mentions](https://docs.discord.com/developers/resources/message#allowed-mentions-object)
- [Discord: Rate limits](https://docs.discord.com/developers/topics/rate-limits)
- [GitHub Actions: Events that trigger workflows](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows)
- [GitHub Actions: Secure use](https://docs.github.com/en/actions/reference/security/secure-use)
- [GitHub Actions: Preventing script injection](https://docs.github.com/en/actions/concepts/security/script-injections)
- [GitHub Actions: Using secrets](https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/use-secrets)
