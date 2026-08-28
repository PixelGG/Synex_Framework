# Third-party notices

This file records the upstream projects used to build or run `@synex/ui`. The
versions below match `libraries/synex_ui/package.json`. The Synex repository's
license does not replace the upstream licenses.

## Runtime libraries

| Project | Package/version | License | Source |
| --- | --- | --- | --- |
| React | `react` 19.2.8 and `react-dom` 19.2.8 | MIT | <https://github.com/facebook/react> |

React and React DOM are peer dependencies for build-time package consumers and
development dependencies for the Synex runtime build.

## Build tooling

| Project | Package/version | License | Source |
| --- | --- | --- | --- |
| Vite | `vite` 8.2.2 | MIT | <https://github.com/vitejs/vite> |
| Vite React plugin | `@vitejs/plugin-react` 6.1.1 | MIT | <https://github.com/vitejs/vite-plugin-react> |

## Fonts

| Font | Package/version | Font license | Source |
| --- | --- | --- | --- |
| IBM Plex Sans | `@fontsource-variable/ibm-plex-sans` 5.3.0 | SIL Open Font License 1.1 | <https://github.com/IBM/plex> |
| JetBrains Mono | `@fontsource-variable/jetbrains-mono` 5.3.0 | SIL Open Font License 1.1 | <https://github.com/JetBrains/JetBrainsMono> |

The font packages are supplied by Fontsource. Fontsource package tooling is MIT
licensed: <https://github.com/fontsource/fontsource>.

Complete dependency metadata and transitive versions are recorded in the root
`package-lock.json`. Upstream license files distributed by npm remain the
authoritative license texts for installed packages.
