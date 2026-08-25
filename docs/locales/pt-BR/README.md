<p align="center">
  <img src="../../../.github/assets/branding/synex-mark.svg" width="96" height="96" alt="Marca Synex">
</p>

<h1 align="center">Synex</h1>

<p align="center">
  <strong>Um Core FiveM contract-first com responsabilidades explícitas e limites fail-closed.</strong>
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
  <img alt="Maturidade do Core: Production Beta" src="https://img.shields.io/badge/core-Production--Beta-8b73ff?style=flat-square&amp;labelColor=111827">
  <a href="https://github.com/PixelGG/Synex_Framework/actions/workflows/framework-ci.yml?query=branch%3Amain"><img alt="Framework CI" src="https://github.com/PixelGG/Synex_Framework/actions/workflows/framework-ci.yml/badge.svg?branch=main"></a>
  <a href="../../../LICENSE"><img alt="Licença: AGPL-3.0-only" src="https://img.shields.io/badge/license-AGPL--3.0--only-45c9a5?style=flat-square&amp;labelColor=111827"></a>
</p>

<p align="center">
  <img src="../../../.github/assets/readme/runtime-flow.svg" width="1200" alt="Fluxo modular do runtime Synex">
</p>

> [!IMPORTANT]
> **Synex Core — PRODUCTION BETA.** O candidato exato do `synex_core` passou pelo primeiro perfil Production-Beta limitado ao Core. O Synex `0.1.0` continua sendo um release de código experimental, com contracts públicos marcados como `experimental`. Isso não é um release Stable/1.0, uma declaração de prontidão de todo o framework nem uma garantia geral de suporte em produção.

## Estado atual da validação

`synex_core` passou pela linha de aceitação Production-Beta congelada em **25-08-2026** para o perfil exato abaixo. A decisão se aplica somente ao commit do Core `7ad4b72ee9bcd0a2a0481cfacfe5f807eb1b3ec5` e à árvore do Core `9f0960f1e27fe43195ae4602cb2ef447cbc0509b`.

| Item de encerramento | Estado atual |
| --- | --- |
| Teste final de falha e recuperação do banco de dados | PASS |
| Execução automatizada completa de encerramento | PASS — `npm run check`; 416 aprovados, 0 falhas, 19 skips live-DB esperados; segurança: 0 findings; audit: 0 vulnerabilidades |
| Sincronização de toda a documentação do repositório | PASS |
| Smoke test do cliente: conectar, desconectar e reconectar | PASS — pipeline de conexão ordenado em nove etapas, desconexão limpa, reconexão e cleanup final |
| Revisão final do diff e secrets; commit e publicação na `main` | PASS |

- **PRODUCTION-BETA ACEITA.** A recuperação após falha do banco de dados, a execução automatizada de encerramento, a sincronização da documentação, o smoke test do cliente, a revisão final e os gates de publicação passaram para o perfil exato limitado ao Core.
- **CLIENTE REAL VERIFICADO.** A conexão concluiu as nove etapas na ordem prevista, seguida por uma desconexão limpa e uma reconexão bem-sucedida. O Doctor retornou `PASS`, todas as 26 migrations foram aplicadas e o cleanup final deixou 3 sessões fechadas, 0 sessões abertas e 0 leases ativos de sessão ou admissão.
- **MATURIDADE LIMITADA.** Esta aceitação não torna o Synex Stable/1.0, não certifica o framework inteiro e não altera os contracts públicos do Core de `experimental`.
- **NÃO CERTIFICADO.** MySQL e operação multi-instância, incluindo `kick_old`, ficam fora do perfil Production-Beta aceito.
- **FORA DO ESCOPO.** Cada resource, library, bridge e exemplo depois de `synex_core` é um snapshot de rework experimental ou scaffold e não faz parte da certificação do Core.

<details>
<summary>Hardening pós-beta — explicitamente fora deste gate de aceitação</summary>

- soak de 125 minutos
- runner permanente de evidências
- ensaio histórico de upgrade
- ensaio ampliado de backup e restore
- testes ABI não críticos adicionais

Essas verificações fazem parte do trabalho necessário para sair da beta posteriormente. Elas não ampliam a linha de encerramento Production-Beta congelada.

</details>

[Gate de release](../../release-readiness.md) &middot; [Cobertura de testes](../../testing.md) &middot; [Limitações conhecidas](../../known-limitations.md)

### Perfil Production-Beta aceito

| Limite | Valor aceito |
| --- | --- |
| Produto | somente `synex_core` |
| Host | Windows |
| Runtime | FXServer build `35245` |
| Adaptador de banco de dados | `oxmysql 2.14.1` |
| Banco de dados | MariaDB `11.8.8`, horário de sessão UTC |
| Topologia | uma instância Core ativa |
| Política de produção | `synex_environment "production"`, `synex_strict "1"`, `synex_duplicate_policy "deny_new"` |

A decisão Production-Beta é válida somente dentro desses limites. Outras plataformas, versões de dependências, topologias ou políticas exigem evidências de aceitação próprias.

## Escopo da beta do Core

| Área | Caminho | Função atual |
| --- | --- | --- |
| Runtime do Core aceito | [`synex_core`](../../../core/synex_core/) | Boot, conexões, ciclos de sessão/personagem, contracts, RPC, events, hooks, services, capabilities, política de acesso persistente, state, confiabilidade, auditoria, métricas, health e migrations próprias |
| Pipeline de contracts | [`packages/contracts`](../../../packages/contracts/) | Entradas canônicas e artefatos de runtime/referência gerados deterministicamente para desenvolver o Core |
| SDKs e ferramentas | [`packages`](../../../packages/) / [`tools`](../../../tools/) | Clients/types gerados, validação, migration, segurança, certificação e testes; não são recursos de servidor certificados separadamente |

Somente `core/synex_core` está aceito como Production-Beta-ready para o perfil exato acima. A API pública do Core continua experimental.

### Limite de rework downstream

`synex_groups`, `synex_accounts`, `synex_entities`, `synex_control`, todos os diretórios posteriores ou independentes em `resources/`, todas as libraries e bridges em `libraries/` (incluindo `synex_bridge`) e os exemplos executáveis estão **pendentes de rework**; o conteúdo atual é formado por snapshots experimentais ou scaffolds. Eles estão totalmente excluídos da beta do Core e não devem ser iniciados, empacotados ou anunciados como componentes certificados. O comportamento downstream que depende de OneSync também fica fora deste perfil Core-only.

Isso também inclui `synex_character`, `synex_identity`, `synex_inventory`, `synex_banking`, `synex_phone`, `synex_radio`, `synex_jobs`, `synex_shops`, `synex_vehicles`, `synex_garages` e `synex_ui`. A presença de um diretório não comprova uma funcionalidade concluída. O ciclo de personagem/sessão existente pertence ao `synex_core`.

## Primeiros passos

O perfil Production-Beta aceito exige Windows, FXServer build `35245`, `oxmysql 2.14.1`, MariaDB `11.8.8`, um `synex_instance_id` estável e único, modo de produção estrito e `deny_new`. Node.js `>=22.12.0` com npm `>=10.0.0` é usado pelas ferramentas e testes do repositório, não pelo runtime Lua.

```bash
git clone https://github.com/PixelGG/Synex_Framework.git
cd Synex_Framework
npm ci
npm run check
npm test
npm run security
npm run certify
```

Esses comandos são gates de desenvolvimento e, sozinhos, não provam uma Production-Beta. O repositório continua sendo um monorepo de desenvolvimento, não um pacote de servidor pronto para copiar. Para o perfil aceito, faça deploy somente de `oxmysql` e `synex_core`. Consulte o [guia de início](../../getting-started.md), o [exemplo de configuração do Core](../../../examples/server.cfg.example) e o [gate de release](../../release-readiness.md).

## Documentação

O inglês é a fonte técnica canônica.

- [Índice da documentação](../../README.md)
- [Gate Production-Beta do Core](../../release-readiness.md)
- [Limitações conhecidas](../../known-limitations.md)
- [Backup e restore](../../backup-and-restore.md)
- [Arquitetura](../../architecture/README.md)
- [API pública](../../api/README.md)
- [Segurança](../../security/README.md)
- [Política de segurança](../../../SECURITY.md)
- [Operações](../../operations.md)
- [Testes e CI](../../testing.md)

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
