# project-scaffold · Scaffold SDD por projeto

> O `.claude/` que **cada projeto novo** recebe — pronto para rodar **Spec-Driven Development
> (SDD)** com Claude Code. Sai **genérico** (sem contexto de tarefa) e **se especializa** na
> inicialização (`/init`).

## Como usar

```powershell
# criar um projeto já equipado (copia este scaffold; -Git inicializa o repo)
onboarding/new-project.ps1 -Path <dir>      # ou o atalho: New-SddProject <dir>
```

1. Abra o Claude Code no projeto e rode **`/setup`** para preencher o contexto.
2. **`/init`** especializa o scaffold (cura agentes + treina a KB + sincroniza índices).
3. Trabalhe em fases: `/brainstorm` → `/define` → `/design` → `/build` → `/ship`.
   Para tarefas pequenas, use `/dev`. Projeto já existente? Use `/adapt`.

## Estrutura

```
AGENTS.md                    (raiz — contrato canônico p/ qualquer agente: Claude, Codex…)
CLAUDE.md                    (raiz — aponta p/ AGENTS.md + específico do Claude Code)
inbox/                       entrada: specs/planilhas/solicitações que chegam (triar daqui)
└── _ABOUT.md                o que é o inbox e o que NÃO é (vs .claude/sdd e a raiz)
.claude/
├── settings.json            registra os hooks curation-nudge + peer-heartbeat (SessionStart + PostToolUse)
├── rules/                   15 regras SEMPRE aplicadas (contexto ativo)
│   ├── workflow-sdd · cli-first · docs-first · tooling                    fluxo SDD + otimizações
│   ├── agent-routing · orchestration · max-mode                           roteamento + orquestração + modo MAX
│   ├── doubt-driven · reflection · simulation · lessons · iterative-loop  posturas opt-in (/doubt /reflect /simulate /learn /iterate)
│   ├── documentation · kb-taxonomy                                        docs (fora da KB) + KB em 4 camadas
│   └── project-context.md   stack/convenções — preenchido via /setup
├── commands/                29 slash commands auto-contidos (tabela completa no CLAUDE.md)
│   ├── setup · init · adapt · audit-agents · train-kb · sync-context · update-skills · skill-gap · supplements   onboarding + curadoria
│   ├── brainstorm · define · design · build · ship             (5 fases SDD)
│   ├── dev · review · doubt · orchestrate · iterate            execução + revisão + orquestração
│   └── reflect · learn · document · simulate · telemetry · status · check · doctor · max · peers   KB + docs + observabilidade + MAX + coordenação
├── hooks/                   read-only / fail-safe (pares .ps1 + .sh)
│   ├── curation-nudge       avisa staleness da curadoria (nunca altera nada)
│   └── peer-heartbeat       presença p/ coordenação entre sessões (/peers)
├── agents/                  9 experts de papel genéricos + mapa
│   ├── code-reviewer · explorer · test-writer · debugger · validator
│   ├── git-workflow · security-reviewer · documenter · external-observer
│   └── AGENT_MAP.md         grafo Mermaid (gerado por /sync-context)
├── kb/                      base de conhecimento — 4 camadas, começa vazia
│   ├── _ABOUT.md · _TEMPLATE.md
│   └── business/ · tools/ · implementation/ · operations/
└── sdd/
    ├── templates/           templates das 5 fases
    ├── features/            BRAINSTORM/DEFINE/DESIGN gerados
    ├── reports/             BUILD_REPORT gerados
    └── archive/             features encerradas via /ship
```

## Conceitos

| Peça | Papel |
|------|-------|
| **Rules** | Contexto sempre ativo — não precisa abrir à mão |
| **Commands** | Slash commands auto-contidos; catálogo e roteamento em `rules/agent-routing.md` |
| **Agents** | **9 experts de papel** genéricos; os de **domínio** surgem via `/audit-agents` |
| **KB** | 4 camadas (`business`/`tools`/`implementation`/`operations`); povoada por `/train-kb` |
| **Hooks** | `curation-nudge` (staleness da curadoria) + `peer-heartbeat` (presença p/ `/peers`) — read-only e fail-safe |
| **inbox/** | Entrada do que chega de fora (specs/planilhas/solicitações); triar daqui — ver `inbox/_ABOUT.md` |

> **Onde fica o trabalho:** a **raiz do projeto é o seu workspace** — código, dados e docs
> ficam na estrutura que a sua stack pedir (`src/`, `tests/`, `models/`, `data/`…), **derivada
> da stack, não fixa** (o scaffold é *context-free*). O `.claude/` é a meta-camada (*como
> trabalhar*); o `inbox/` é a antessala do que ainda vai ser triado. Insumos que chegam → `inbox/`;
> artefatos SDD gerados → `.claude/sdd/`; conhecimento curado → `.claude/kb/`.

> **Nota:** `AGENTS.md` e `CLAUDE.md` vão para a **raiz** do projeto; o resto vai dentro de
> `.claude/`. O `new-project.ps1` cuida disso por descoberta dinâmica e **ignora este `README.md`**
> (ele descreve o scaffold, não o projeto). Agentes de domínio **não** vêm no scaffold — são gerados
> na curadoria. Mantenha o conjunto **enxuto**: só o que é usado.
