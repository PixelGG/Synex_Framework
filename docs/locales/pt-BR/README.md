<p align="center">
  <img src="../../../.github/assets/branding/synex-mark.svg" width="96" height="96" alt="Marca Synex">
</p>

<h1 align="center">Synex</h1>

<p align="center">
  <strong>Um runtime FiveM contract-first e uma fundação para resources com responsabilidades independentes.</strong>
</p>

<p align="center">
  <a href="../../../README.md">EN</a>
  &nbsp;&middot;&nbsp;
  <a href="../de/README.md">DE</a>
  &nbsp;&middot;&nbsp;
  <a href="../fr/README.md">FR</a>
  &nbsp;&middot;&nbsp;
  <a href="../es/README.md">ES</a>
  &nbsp;&middot;&nbsp;
  <strong>PT-BR</strong>
</p>

<p align="center">
  <img alt="Alvo: FiveM" src="https://img.shields.io/badge/target-FiveM-5ed7ff?style=flat-square&amp;labelColor=111827">
  <img alt="Versão: 0.1.0" src="https://img.shields.io/badge/version-0.1.0-4b94ff?style=flat-square&amp;labelColor=111827">
  <img alt="Maturidade: experimental" src="https://img.shields.io/badge/maturity-experimental-8b73ff?style=flat-square&amp;labelColor=111827">
  <a href="https://github.com/PixelGG/Synex_Framework/actions/workflows/framework-ci.yml?query=branch%3Amain"><img alt="Framework CI" src="https://github.com/PixelGG/Synex_Framework/actions/workflows/framework-ci.yml/badge.svg?branch=main"></a>
  <a href="../../../LICENSE"><img alt="Licença: AGPL-3.0-only" src="https://img.shields.io/badge/license-AGPL--3.0--only-45c9a5?style=flat-square&amp;labelColor=111827"></a>
</p>

<p align="center">
  <img src="../../../.github/assets/readme/runtime-flow.svg" width="1200" alt="Fluxo modular do runtime Synex">
</p>

> [!CAUTION]
> **Release de código experimental.** Synex `0.1.0` contém resources de fundação executáveis, contracts gerados, migrations, testes e ferramentas. Todos os contracts públicos ainda estão marcados como `experimental`; não há release estável, instalador empacotado ou garantia de suporte em produção.

## Estado atual da validação

O runtime do Core no commit `510053e` concluiu seu caminho de validação no lado do servidor em 24/08/2026. Isso é evidência para a revisão testada, não uma declaração de estabilidade ou prontidão para produção.

- **PASS — Verificações do repositório.** Geração, validação, suites headless, análise estática de segurança e auditoria de dependências.
- **PASS — Banco de dados real.** Baseline MariaDB 11.8 e todas as 25 migrations do Core.
- **PASS — FXServer no lado do servidor.** `READY`, APIs vinculadas ao chamador, execução persistida de Sagas, restart da probe, restart preparado do Core e recuperação no próximo boot.
- **PENDING — Ciclo de vida do cliente FiveM real.** Join, disconnect, reconnect e limpeza de player/session/lease ainda exigem um cliente real.

[Cobertura exata e sequência restante do cliente](../../testing.md)

## Fundação implementada

| Área | Módulo | Responsabilidade realmente presente |
| --- | --- | --- |
| Kernel | [`synex_core`](../../../core/synex_core/) | Ciclo de boot/sessão/personagem, contracts, RPC, events, hooks, services, capabilities, RBAC/acesso persistente, state, confiabilidade, auditoria, métricas e health |
| Grupos | [`synex_groups`](../../../resources/synex_groups/) | Grupos, grades, regras de capability, seleção primária e memberships versionadas |
| Contas | [`synex_accounts`](../../../resources/synex_accounts/) | Moedas, contas de dupla entrada, holds, papéis de acesso, reversões e modelos de integridade |
| Entidades | [`synex_entities`](../../../resources/synex_entities/) | Identidade de entidade autoritativa no servidor, resolução persistente e routing buckets |
| Operações | [`synex_control`](../../../resources/synex_control/) | NUI in-game somente leitura com visões Core/domínio limitadas, busca exata de auditoria e estado fechado transparente |
| Compatibilidade | [`synex_bridge`](../../../libraries/synex_bridge/) | Adaptadores QB/QBX/ESX opcionais vinculados ao consumidor, com callbacks limitados, transferências cash/bank e importação revisada |
| Desenvolvimento | [`packages`](../../../packages/) / [`tools`](../../../tools/) | SDKs Lua/TypeScript gerados, CLI, analisadores, certificação e testes |

Todas as fundações implementadas continuam experimentais. O caminho de compatibilidade também está deprecated para projetos novos.

Os adaptadores de compatibilidade não expõem objetos mutáveis de jogador legacy. Mudanças de dinheiro passam somente por transferências Synex equilibradas usando contas de contrapartida configuradas; contas ausentes ou ambíguas falham de forma fechada.

Synex vincula cada fachada de API ao resource chamador real e ao seu epoch de inicialização. Contracts JSON definem versão, schema, capability e direção de rede. Cada migration e tabela tem um único dono de domínio. Entradas de cliente e NUI não são confiáveis.

### Limites apenas reservados

`synex_character`, `synex_identity`, `synex_inventory`, `synex_banking`, `synex_phone`, `synex_radio`, `synex_jobs`, `synex_shops`, `synex_vehicles`, `synex_garages` e `synex_ui` contêm apenas scaffolds e **não são funcionalidades executáveis**. O ciclo de personagem/sessão existente fica em `synex_core`.

## Primeiros passos

São necessários um FXServer atual, MariaDB 11.8 ou MySQL 8.4 via `oxmysql >= 2.14.1` (e `< 3.0.0` quando `synex_entities` estiver ativado), um `synex_instance_id` estável em produção estrita e OneSync `on` para `synex_entities`. Node.js é usado pelas ferramentas e testes do repositório, não pelo runtime Lua.

```bash
git clone https://github.com/PixelGG/Synex_Framework.git
cd Synex_Framework
npm ci
npm run check
npm test
npm run security
npm run certify
```

Este repositório é um monorepo de desenvolvimento, não um pacote de servidor pronto para copiar. O [guia de início](../../getting-started.md) cobre posicionamento, configuração, migrations, ordem de inicialização e limites.

## Documentação

O inglês é a fonte técnica canônica.

- [Índice da documentação](../../README.md)
- [Arquitetura](../../architecture/README.md)
- [API pública](../../api/README.md)
- [Segurança](../../security/README.md)
- [Operações](../../operations.md)
- [Testes e CI](../../testing.md)
- [Compatibilidade](../../compatibility/README.md)

## Comunidade

Discussões de desenvolvimento, feedback de implementação e atualizações do framework estão disponíveis na comunidade oficial do Synex.

<p align="center">
  <a href="https://discord.gg/heJU5t2Hfa">
    <img src="../../../.github/assets/readme/discord-community.svg" width="720" alt="Entrar no Discord oficial do Synex">
  </a>
</p>

## Licença

Copyright &copy; 2026 PixelGG. Synex é distribuído exclusivamente sob a [GNU Affero General Public License v3.0](../../../LICENSE).

---

<p align="center"><sub>Synex Framework &middot; Contracts explícitos. State com proprietário. Limites honestos.</sub></p>
