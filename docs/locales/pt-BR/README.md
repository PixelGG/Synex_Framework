<p align="center">
  <img src="../../../.github/assets/branding/synex-mark.svg" width="88" height="88" alt="Marca Synex">
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
  <img alt="Versão: 0.1.0 experimental" src="https://img.shields.io/badge/release-0.1.0%20experimental-8b73ff?style=flat-square&amp;labelColor=111827">
</p>

<p align="center">
  <img src="../../../.github/assets/readme/hero.webp" width="1200" alt="Ilustração abstrata da rede modular Synex">
</p>

> [!CAUTION]
> **Release de código experimental.** Synex `0.1.0` contém resources de fundação executáveis, contracts gerados, migrations, testes e ferramentas. Todos os contracts públicos ainda estão marcados como `experimental`; não há release estável, instalador empacotado ou garantia de suporte em produção.

## Fundação implementada

| Área | Módulo | Responsabilidade realmente presente | Status |
| --- | --- | --- | --- |
| Kernel | [`synex_core`](../../../core/synex_core/) | Ciclo de boot/sessão/personagem, contracts, RPC, events, hooks, services, capabilities, RBAC/acesso persistente, state, confiabilidade, auditoria, métricas e health | Experimental |
| Grupos | [`synex_groups`](../../../resources/synex_groups/) | Grupos, grades, regras de capability, seleção primária e memberships versionadas | Experimental |
| Contas | [`synex_accounts`](../../../resources/synex_accounts/) | Moedas, contas de dupla entrada, holds, papéis de acesso, reversões e modelos de integridade | Experimental |
| Entidades | [`synex_entities`](../../../resources/synex_entities/) | Identidade de entidade autoritativa no servidor, resolução persistente e routing buckets | Experimental |
| Operações | [`synex_control`](../../../resources/synex_control/) | NUI in-game somente leitura com visões Core/domínio limitadas, busca exata de auditoria e estado fechado transparente | Experimental |
| Compatibilidade | [`synex_bridge`](../../../libraries/synex_bridge/) | Adaptadores QB/QBX/ESX opcionais vinculados ao consumidor, com callbacks limitados, transferências cash/bank e importação revisada | Experimental / transição |
| Desenvolvimento | [`packages`](../../../packages/) / [`tools`](../../../tools/) | SDKs Lua/TypeScript gerados, CLI, analisadores, certificação e testes | Experimental |

Os adaptadores de compatibilidade não expõem objetos mutáveis de jogador legacy. Mudanças de dinheiro passam somente por transferências Synex equilibradas usando contas de contrapartida configuradas; contas ausentes ou ambíguas falham de forma fechada.

Synex vincula cada fachada de API ao resource chamador real e ao seu epoch de inicialização. Contracts JSON definem versão, schema, capability e direção de rede. Cada migration e tabela tem um único dono de domínio. Entradas de cliente e NUI não são confiáveis.

### Limites apenas reservados

`synex_character`, `synex_identity`, `synex_inventory`, `synex_banking`, `synex_phone`, `synex_radio`, `synex_jobs`, `synex_shops`, `synex_vehicles`, `synex_garages` e `synex_ui` contêm apenas scaffolds e **não são funcionalidades executáveis**. O ciclo de personagem/sessão existente fica em `synex_core`.

## Primeiros passos

São necessários um FXServer atual, MariaDB/MySQL via `oxmysql >= 2.14.1` (e `< 3.0.0` quando `synex_entities` estiver ativado), um `synex_instance_id` estável em produção estrita e OneSync `on` para `synex_entities`. Node.js é usado pelas ferramentas e testes do repositório, não pelo runtime Lua.

```bash
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

---

<p align="center"><sub>Synex Framework &middot; Contracts explícitos. State com proprietário. Limites honestos.</sub></p>
