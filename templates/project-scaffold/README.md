# project-scaffold · Scaffold SDD por projeto

> O `.claude/` que **cada projeto novo** recebe — pronto para rodar **Spec-Driven Development
> (SDD)** com Claude Code. Sai **genérico** (sem contexto de tarefa) e **se especializa** na
> inicialização (`/curate`).

## Como usar

```powershell
# criar um projeto já equipado (copia este scaffold; -Git inicializa o repo)
onboarding/new-project.ps1 -Path <dir>      # ou o atalho: New-SddProject <dir>
```

1. Abra o Claude Code no projeto e rode **`/setup`** para preencher o contexto.
2. **`/curate`** especializa o scaffold (cura agentes + treina a KB + sincroniza índices).
3. Trabalhe em fases: `/brainstorm` → `/define` → `/spec` → `/build` → `/ship`.
   Para tarefas pequenas, use `/dev`. Projeto já existente? Use `/adapt`.

## Estrutura

```
AGENTS.md                    (raiz — contrato canônico p/ qualquer agente: Claude, Codex…)
CLAUDE.md                    (raiz — aponta p/ AGENTS.md + específico do Claude Code)
BACKLOG.md                   fila de trabalho do projeto, com critério de entrada
inbox/                       entrada: specs/planilhas/solicitações que chegam (triar daqui)
└── _ABOUT.md                o que é o inbox e o que NÃO é (vs .claude/sdd e a raiz)
docs/                        documentação do projeto (fora da KB) — _ABOUT.md · _index.md
.githooks/                   pre-commit anti-segredo (secret-scan .ps1/.sh) — entra nos DOIS perfis
.claude/
├── settings.json            registra os 4 hooks abaixo (o mvp poda as entradas dos que não entrega)
├── rules/                   12 regras: 10 SEMPRE aplicadas (imposto de token em toda sessão) + 2 de área
│   ├── workflow-sdd · project-context · cli-first · tooling · complementary-repos   núcleo — as 5 que o mvp entrega
│   ├── agent-routing · orchestration                                                roteamento + gatilho da orquestração
│   ├── artifact-first · semantic-search · documentation                             porta do Artifact · busca por significado · docs fora da KB
│   └── docs-first · kb-taxonomy                                                     de área (`paths:`) — só entram ao ler arquivo da área
├── postures/                8, NÃO carregadas automaticamente — 0 token até um command ou rule lê-las
│   ├── max-mode · orchestration · agent-routing-advanced   lidas pelo /max e /orchestrate (fora do mvp)
│   └── complementary-repos · kb-writing · path-rules · semantic-search · tooling   detalhe das rules homônimas
├── commands/                30 slash commands auto-contidos (tabela completa no CLAUDE.md)
│   ├── setup · adapt · curate · audit-agents · train-kb · sync-context · update-skills · skill-gap · supplements   onboarding + curadoria
│   ├── brainstorm · define · spec · build · ship               (5 fases SDD)
│   ├── dev · review-diff · doubt · iterate · orchestrate · max · peers   execução + revisão + orquestração
│   ├── reflect · learn · document · simulate · telemetry · status · check · guards-check   KB + docs + observabilidade
│   └── complementary-repos                                     repos complementares de referência (add/list/remove)
├── skills/                  decision-preview · grill-me · handoff · page-to-markdown · visual-check
├── hooks/                   read-only ou ask-only / fail-safe (pares .ps1 + .sh)
│   ├── curation-nudge          avisa staleness da curadoria (nunca altera nada)
│   ├── peer-heartbeat          presença p/ coordenação entre sessões (/peers) — fora do mvp
│   ├── complementary-repo-guard  ask se Write/Edit mirar um repo complementar registrado (PreToolUse)
│   └── supplement-hint         lembra o /supplements quando o prompt toca o tema (+ .triggers)
├── agents/                  11 experts de papel genéricos + mapa
│   ├── code-reviewer · explorer · test-writer · debugger · validator
│   ├── git-workflow · security-reviewer · documenter · external-observer
│   ├── designer · tracker
│   └── AGENT_MAP.md · graph.json   grafo (gerado por /sync-context)
├── checklists/              review-repertoire.md
├── kb/                      base de conhecimento — 4 camadas, começa vazia
│   ├── _ABOUT.md · _TEMPLATE.md · _index.yaml
│   └── business/ · tools/ · implementation/ · operations/
└── sdd/
    ├── templates/           templates das 5 fases
    ├── features/            BRAINSTORM/DEFINE/DESIGN gerados
    ├── reports/             BUILD_REPORT gerados
    └── archive/             features encerradas via /ship
```

> **Perfis:** `new-project.ps1 -Profile mvp` (**default**) entrega as 5 rules do núcleo e as 2 de área (`docs-first`, `kb-taxonomy`, 0 token de always-on) e não
> entrega `/orchestrate`, `/max`, `/peers`, as 3 posturas da orquestração nem o `peer-heartbeat`;
> `-Profile full` entrega tudo acima. Detalhe e medições em `new-project.ps1 -Help`.

## Conceitos

| Peça | Papel |
|------|-------|
| **Rules** | Contexto sempre ativo — não precisa abrir à mão; rule com `paths:` (de área) entra ao ler arquivo da área |
| **Commands** | Slash commands auto-contidos; catálogo e roteamento em `rules/agent-routing.md` |
| **Agents** | **11 experts de papel** genéricos; os de **domínio** surgem via `/audit-agents` |
| **KB** | 4 camadas (`business`/`tools`/`implementation`/`operations`); povoada por `/train-kb` |
| **Hooks** | `curation-nudge` (staleness da curadoria) + `peer-heartbeat` (presença p/ `/peers`) + `complementary-repo-guard` (ask no `PreToolUse` se mirar um repo complementar) + `supplement-hint` (lembra o `/supplements`) — read-only/ask-only e fail-safe |
| **inbox/** | Entrada do que chega de fora (specs/planilhas/solicitações); triar daqui — ver `inbox/_ABOUT.md` |

> **Onde fica o trabalho:** a **raiz do projeto é o seu workspace** — código, dados e docs
> ficam na estrutura que a sua stack pedir (`src/`, `tests/`, `models/`, `data/`…), **derivada
> da stack, não fixa** (o scaffold é *context-free*). O `.claude/` é a meta-camada (*como
> trabalhar*); o `inbox/` é a antessala do que ainda vai ser triado. Insumos que chegam → `inbox/`;
> artefatos SDD gerados → `.claude/sdd/`; conhecimento curado → `.claude/kb/`.

> **No Codex:** `Export-CodexHarness -ProjectRoot .` (`$env:SDD_WORKFLOW_HOME/tools/harness-export.ps1`)
> gera `.agents/skills/` a partir dos commands e das skills de `.claude/skills/`, e o Codex descobre as
> skills sozinho. Opt-in; reexporte se mexer neles.

> **Nota:** `AGENTS.md` e `CLAUDE.md` vão para a **raiz** do projeto; o resto vai dentro de
> `.claude/`. O `new-project.ps1` cuida disso por descoberta dinâmica e **ignora este `README.md`**
> (ele descreve o scaffold, não o projeto). Agentes de domínio **não** vêm no scaffold — são gerados
> na curadoria. Mantenha o conjunto **enxuto**: só o que é usado.
