# Security policy

Synex accepts responsible security reports for the current `synex_core` development line. The project has not yet published a production-stable release, and no response-time or backport service-level agreement is offered.

## Supported scope

| Surface | Security status |
| --- | --- |
| Current `synex_core` `0.1.x` development line | Reports accepted; fixes are made on the latest maintained revision |
| Earlier commits, forks, and modified distributions | No guaranteed backports or support |
| `synex_groups` Organizations Engine | Experimental Alpha; reports accepted, but no production support, stable-API, or Core Production-Beta certification |
| `synex_accounts` Financial Engine | Experimental Alpha; reports accepted, but no production support, stable-API, or Core Production-Beta certification |
| `synex_entities` Entity Authority Engine | Development / Experimental Alpha; reports accepted, but no production support, live-runtime acceptance, stable-API, or Core Production-Beta certification |
| Other non-Core resources and libraries | Experimental rework snapshots or scaffolds; not supported as part of the Core Production-Beta target |
| Planned resource directories and scaffolds | Not runnable and not supported |

Security reports about any repository-owned code are still welcome even when that code is outside the supported deployment scope. The status above describes deployment support, not whether a vulnerability matters.

## Report a vulnerability privately

Use GitHub's private vulnerability reporting for this repository:

1. Open the repository's **Security** tab.
2. Select **Advisories**.
3. Select **Report a vulnerability**.

Direct link: [Privately report a Synex vulnerability](https://github.com/PixelGG/Synex_Framework/security/advisories/new).

If GitHub does not show that option, do not publish exploit details, credentials, player identifiers, database content, or private server information in a public issue. Open a minimal public issue asking the maintainer to enable a private reporting channel, without including technical vulnerability details.

Include only the information needed to reproduce and assess the problem:

- affected commit, tag, resource, and file;
- deployment versions for FXServer, oxmysql, and the database;
- impact and required attacker access;
- minimal reproduction steps or a small proof of concept;
- relevant redacted logs;
- any known workaround.

Never attach real license keys, database credentials, webhook URLs, access tokens, raw identifiers, database dumps, or private endpoints.

## Coordinated disclosure

Give the maintainer a reasonable opportunity to reproduce, fix, and publish guidance before public disclosure. A report may be closed as out of scope when it depends on unsupported code changes, an already-compromised host, leaked operator credentials, or a deployment that bypasses the documented security boundary. Configuration mistakes can still justify documentation hardening even when they are not a Core vulnerability.

## Operator responsibility

Synex is provided without warranty under the repository license. Operators remain responsible for host hardening, database access control, Cfx keys, secrets, backups, firewall policy, dependency patching, privacy obligations, and testing the exact deployment revision. See the [security model](docs/security/README.md), [known limitations](docs/known-limitations.md), and [release-readiness gate](docs/release-readiness.md).
