# Tutorial: monte seu primeiro projeto SDD curado, do zero

> Estrutura: The Good Docs Project (tutorial template, via a skill `gerador-de-manuais`). Este
> tutorial é o **caminho único, passo a passo** — para a referência completa de flags/opções,
> veja [`USO.md`](USO.md); para o porquê do design, [`VISAO.md`](VISAO.md).

## Overview
- **O que você vai construir:** uma máquina pronta para o framework e um **primeiro projeto** com
  o scaffold SDD já **especializado** (agentes de domínio + KB treinada) — pronto pra sua primeira
  feature de verdade.
- **Público-alvo:** nunca usou este framework antes; sabe o básico de PowerShell/git.
- **Tempo estimado:** ~20 min (a maior parte é o instalador baixando dependências via winget).

## Background
O framework separa **onboarding** (preparar a máquina, uma vez) de **scaffold** (o `.claude/` que
cada projeto recebe, genérico) e **curadoria** (a especialização desse scaffold ao domínio real do
projeto, feita no `/init`). Você vai passar pelas três camadas nesta ordem — é o mesmo fluxo que o
[`README`](../README.md) resume em "Início rápido", só que aqui cada passo tem o resultado esperado
explícito.

## Antes de começar
- [ ] Windows 10/11 (com `winget`), Linux (Ubuntu/Fedora/Arch) **ou** macOS 14+ (Apple Silicon ou
      Intel; o instalador põe o Homebrew se faltar e pede a senha de admin uma vez).
- [ ] `git` instalado (o instalador cuida disso se faltar, no Windows).
- [ ] Claude Code (CLI ou desktop) — o instalador também garante isso.

## Passos

1. **Prepare a máquina**
   ```powershell
   # Windows
   .\onboarding\install.ps1
   ```
   ```bash
   # Linux
   ./onboarding/install.sh
   ```
   Resultado esperado: uma lista de passos `OK`/`SKIP` no terminal (CLIs, `~/.claude`, statusline);
   ao final, **feche e reabra o terminal** — é o que carrega o `New-SddProject`/`nsp` no seu `$PROFILE`.

2. **Crie o primeiro projeto**
   ```powershell
   New-SddProject C:\dev\meu-primeiro-projeto -Git -Open
   ```
   Resultado esperado: a pasta nasce com `AGENTS.md`/`CLAUDE.md` na raiz e `.claude/` (rules,
   commands, agents, kb, sdd) dentro; o VS Code abre nela sozinho (por causa do `-Open`).

3. **Configure o contexto do projeto**
   Dentro do Claude Code, na pasta do projeto:
   ```text
   /setup
   ```
   Resultado esperado: um wizard pergunta stack/domínio/convenções e preenche
   `.claude/rules/project-context.md` — o marcador vira `status: active` (antes era `template`).

4. **Especialize o scaffold**
   ```text
   /init
   ```
   Resultado esperado: a curadoria roda em etapas com sua aprovação (`/audit-agents` →
   `/train-kb` → `/sync-context`); ao final, `.claude/agents/domain/` pode ter agentes novos e
   `.claude/kb/` deixa de estar vazia.

5. **Confira o estado**
   ```text
   /status
   ```
   Resultado esperado: um painel read-only — git, fase SDD, curadoria, memória — terminando numa
   recomendação do **próximo passo** (é o comando certo pra começar qualquer sessão futura).

6. **Rode uma tarefa pequena (Dev Loop)**
   ```text
   /dev adiciona um script que lista os arquivos .md de docs/
   ```
   Resultado esperado: o código sai direto, **sem** os artefatos de fase — é o atalho pra algo
   pequeno demais pra merecer o ciclo completo.

7. **Comece sua primeira feature de verdade**
   ```text
   /brainstorm <sua ideia real>
   ```
   Resultado esperado: `.claude/sdd/features/BRAINSTORM_<FEATURE>.md` é criado — o 1º dos 5
   artefatos do ciclo SDD (`/brainstorm → /define → /spec → /build → /ship`).

## Resumo
Você preparou a máquina uma única vez, criou um projeto que nasceu genérico e **se especializou**
sozinho no `/init`, e já viu os dois modos de trabalho do dia a dia: o **Dev Loop** (`/dev`, direto
ao código) e o **ciclo SDD completo** (5 fases, uma por vez, cada uma com seu artefato).

## Próximos passos
- [`USO.md`](USO.md) — referência completa: flags (`-Check`/`-DryRun`/`-SkipClis`), brownfield
  (`/adapt`), hierarquia de config, subagents.
- [`VISAO.md`](VISAO.md) — o porquê por trás da curadoria e do design "genérico e sem contexto".
- `/max` quando o próximo bloco de trabalho for denso ou autônomo; `/peers` se abrir uma 2ª sessão
  no mesmo projeto.
