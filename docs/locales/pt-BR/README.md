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
  <img alt="Maturidade: experimental" src="https://img.shields.io/badge/maturity-experimental-8b73ff?style=flat-square&amp;labelColor=111827">
  <a href="https://github.com/PixelGG/Synex_Framework/actions/workflows/framework-ci.yml?query=branch%3Amain"><img alt="Framework CI" src="https://github.com/PixelGG/Synex_Framework/actions/workflows/framework-ci.yml/badge.svg?branch=main"></a>
  <a href="../../../LICENSE"><img alt="Licença: AGPL-3.0-only" src="https://img.shields.io/badge/license-AGPL--3.0--only-45c9a5?style=flat-square&amp;labelColor=111827"></a>
</p>

<p align="center">
  <img src="../../../.github/assets/readme/runtime-flow.svg" width="1200" alt="Fluxo modular do runtime Synex">
</p>

> [!CAUTION]
> **Candidato Production-Beta do Core — IN PROGRESS / NO-GO.** Synex `0.1.0` continua sendo um release de código experimental. Somente `synex_core` está sendo avaliado para o primeiro perfil Production-Beta, e o candidato exato atual ainda não concluiu todos os gates obrigatórios. Os contracts públicos permanecem `experimental`; não existe release estável nem garantia de suporte em produção para o framework inteiro.

## Estado atual da validação

Execuções de desenvolvimento já cobriram os gates do repositório, a cadeia MariaDB com 26 migrations, boot isolado do FXServer, APIs públicas do Core, caminhos de recuperação e uma sequência de join/disconnect/reconnect com cliente real. Essa evidência não certifica outra revisão. A decisão permanece NO-GO até a aceitação completa ser mantida para um único candidato limpo e imutável.

- **VERIFICADO DURANTE O DESENVOLVIMENTO.** Geração, validação, suites headless, análise estática de segurança, auditoria de dependências, regressões reais com MariaDB e etapas anteriores de FXServer/cliente passaram.
- **IMPLEMENTADO; RETESTE AO VIVO PENDENTE.** O circuito de saúde do banco de dados leva o Core a um `DEGRADED` recuperável com `operational = true` e admissão fechada após falha retornada, exceção do adaptador ou expiração do watchdog fail-closed fixo de cinco segundos. Ele suspende os workers comuns dependentes do banco, enquanto mantém deliberadamente ativo o heartbeat limitado de conexões para a limpeza, e exige dois probes bem-sucedidos mais reconciliação antes de retomar o trabalho e a admissão. Há cobertura headless e de corrotinas semelhante ao Cfx, mas isso não é um PASS ao vivo até o candidato exato concluir o gate.
- **IN PROGRESS.** Instalação limpa, upgrade, backup/restore, recuperação após restart ou crash, falha e recuperação do banco de dados, load/soak limitado, revisão de segurança, auditoria da documentação e sequência completa do cliente devem passar na mesma revisão.
- **NÃO CERTIFICADO.** MySQL e operação multi-instância, incluindo `kick_old`, ficam fora do primeiro perfil candidato.
- **FORA DO ESCOPO.** Cada resource, library, bridge e exemplo depois de `synex_core` é um snapshot de rework experimental ou scaffold e não faz parte da certificação do Core.

[Gate de release](../../release-readiness.md) &middot; [Cobertura de testes](../../testing.md) &middot; [Limitações conhecidas](../../known-limitations.md)

### Primeiro perfil-alvo de aceitação

| Limite | Valor candidato |
| --- | --- |
| Produto | somente `synex_core` |
| Host | Windows |
| Runtime | FXServer build `35245` |
| Adaptador de banco de dados | `oxmysql 2.14.1` |
| Banco de dados | MariaDB `11.8.8`, horário de sessão UTC |
| Topologia | uma instância Core ativa |
| Política de produção | `synex_environment "production"`, `synex_strict "1"`, `synex_duplicate_policy "deny_new"` |

Esses valores definem o candidato; ainda não representam um PASS.

## Escopo da beta do Core

| Área | Caminho | Função atual |
| --- | --- | --- |
| Candidato runtime | [`synex_core`](../../../core/synex_core/) | Boot, conexões, ciclos de sessão/personagem, contracts, RPC, events, hooks, services, capabilities, política de acesso persistente, state, confiabilidade, auditoria, métricas, health e migrations próprias |
| Pipeline de contracts | [`packages/contracts`](../../../packages/contracts/) | Entradas canônicas e artefatos de runtime/referência gerados deterministicamente para desenvolver o Core |
| SDKs e ferramentas | [`packages`](../../../packages/) / [`tools`](../../../tools/) | Clients/types gerados, validação, migration, segurança, certificação e testes; não são recursos de servidor certificados separadamente |

Somente `core/synex_core` pode chegar a Production-Beta-ready no ciclo atual. A API pública do Core continua experimental mesmo se o gate beta passar.

### Limite de rework downstream

`synex_groups`, `synex_accounts`, `synex_entities`, `synex_control`, todos os demais diretórios em `resources/`, todas as libraries e bridges em `libraries/` (incluindo `synex_bridge`), e os exemplos executáveis são **snapshots de rework experimentais ou scaffolds**. Eles não são suportados pela beta do Core e não devem ser iniciados, empacotados ou anunciados como componentes certificados. O comportamento downstream que depende de OneSync também fica fora deste perfil Core-only.

Isso também inclui `synex_character`, `synex_identity`, `synex_inventory`, `synex_banking`, `synex_phone`, `synex_radio`, `synex_jobs`, `synex_shops`, `synex_vehicles`, `synex_garages` e `synex_ui`. A presença de um diretório não comprova uma funcionalidade concluída. O ciclo de personagem/sessão existente pertence ao `synex_core`.

## Primeiros passos

O primeiro perfil candidato exige Windows, FXServer build `35245`, `oxmysql 2.14.1`, MariaDB `11.8.8`, um `synex_instance_id` estável e único, modo de produção estrito e `deny_new`. Node.js `>=22.12.0` com npm `>=10.0.0` é usado pelas ferramentas e testes do repositório, não pelo runtime Lua.

```bash
git clone https://github.com/PixelGG/Synex_Framework.git
cd Synex_Framework
npm ci
npm run check
npm test
npm run security
npm run certify
```

Esses comandos são gates de desenvolvimento e, sozinhos, não provam uma Production-Beta. O repositório continua sendo um monorepo de desenvolvimento, não um pacote de servidor pronto para copiar. Para o primeiro candidato, faça deploy somente de `oxmysql` e `synex_core`. Consulte o [guia de início](../../getting-started.md), o [exemplo de configuração do Core](../../../examples/server.cfg.example) e o [gate de release](../../release-readiness.md).

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
