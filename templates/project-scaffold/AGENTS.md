# AGENTS.md

Contrato operacional **canônico** para qualquer agente de IA neste repositório — Claude
Code, Codex, Cursor e afins. Ferramentas específicas (ex.: [`CLAUDE.md`](CLAUDE.md))
**apontam para este arquivo** e só adicionam o que é particular delas.

> Precedência: regras de **projeto** (este arquivo + `.claude/rules/`) vencem as
> configurações globais do agente em caso de conflito.

## Antes de qualquer tarefa

Verifique [`.claude/rules/project-context.md`](.claude/rules/project-context.md):

- `status: template` ou placeholders `<...>` → projeto **não inicializado**. Instrua o
  usuário a rodar a inicialização (**`/setup`** no Claude Code) antes de executar trabalho.
- `status: active` → use stack, domínio e convenções de lá como **fonte de verdade**.

## O que é este repositório

Projeto que usa **Spec-Driven Development (SDD)**: features maiores passam por 5 fases
sequenciais; tarefas pequenas usam o atalho **Dev Loop**.

## Workflow SDD (sempre aplicado)

Cinco fases sequenciais — **nunca pule fases** sem autorização explícita. Cada fase
consome o artefato da anterior. Detalhes em
[`.claude/rules/workflow-sdd.md`](.claude/rules/workflow-sdd.md).

| Fase | Artefato gerado |
|------|-----------------|
| 0. Brainstorm | `.claude/sdd/features/BRAINSTORM_<FEATURE>.md` |
| 1. Define | `.claude/sdd/features/DEFINE_<FEATURE>.md` |
| 2. Design | `.claude/sdd/features/DESIGN_<FEATURE>.md` |
| 3. Build | código + `.claude/sdd/reports/BUILD_REPORT_<FEATURE>.md` |
| 4. Ship | `.claude/sdd/archive/<FEATURE>/SHIPPED_<DATE>.md` |

> No **Claude Code**, cada fase tem um slash command dedicado — ver [`CLAUDE.md`](CLAUDE.md).
> Em outras ferramentas, execute a fase manualmente seguindo o template correspondente em
> `.claude/sdd/templates/`.

## Regras sempre aplicadas (`.claude/rules/`)

<!-- sync-context:start:rules -->
- [`workflow-sdd.md`](.claude/rules/workflow-sdd.md) — as 5 fases e quando entrar em cada uma
- [`cli-first.md`](.claude/rules/cli-first.md) — **verificar CLIs antes de agir** (otimização)
- [`docs-first.md`](.claude/rules/docs-first.md) — **doc atual via context7** para libs versionáveis (camada `tools/`)
- [`tooling.md`](.claude/rules/tooling.md) — **resolver a camada `tools/`** (cascata `$toolsRoot`) antes de dot-source
- [`agent-routing.md`](.claude/rules/agent-routing.md) — roteamento de subagents
- [`doubt-driven.md`](.claude/rules/doubt-driven.md) — **dúvida adversarial *in-flight*** antes de firmar decisão arriscada (`/doubt`)
- [`reflection.md`](.claude/rules/reflection.md) — **consolidar/compactar a KB** quando cresce, preservando regras+casos (`/reflect`)
- [`simulation.md`](.claude/rules/simulation.md) — **simular uma mudança antes de aplicar** (isolado, nunca-destrutivo) (`/simulate`)
- [`lessons.md`](.claude/rules/lessons.md) — **promover a lição recorrente** do acervo de `SHIPPED` à KB `operations` (`/learn`)
- [`max-mode.md`](.claude/rules/max-mode.md) — **modo de operação máxima** sob demanda (contexto total + potência recomendada + orquestrador-mestre), **permissão-só, guardas mantidos** (`/max`)
- [`iterative-loop.md`](.claude/rules/iterative-loop.md) — **laço bounded "até o verde"** (loop-until-green) só na classe segura, em sandbox (`worktree`), com circuit-breakers e fronteira intacta (`/iterate`)
- [`kb-taxonomy.md`](.claude/rules/kb-taxonomy.md) — KB em 4 camadas, em `.claude/kb/`
- [`project-context.md`](.claude/rules/project-context.md) — stack/convenções (`/setup`)
<!-- sync-context:end:rules -->

> A lista acima é regenerada por `/sync-context` (G4). Edite os arquivos de regra, não esta lista.

## Documentação do projeto (`docs/`)

Documentação humano×LLM que **não entra na KB** (doc de código, ADR, runbook, registros de
acontecimentos, notas) vive em **`docs/`** — índice em [`docs/_index.md`](docs/_index.md) (gerado por
`/sync-context`). Disciplina em [`.claude/rules/documentation.md`](.claude/rules/documentation.md);
produzida pelo subagent `documenter` (proativo) ou por `/document`. Distinta da KB (`.claude/kb/`,
curada/agente-facing) e do `inbox/` (insumo que chega).

## Domínios da KB

<!-- sync-context:start:kb -->
_(vazio — povoado por `/train-kb` e indexado por `/sync-context`; ver `.claude/kb/_index.yaml`)_
<!-- sync-context:end:kb -->

## CLI-first (resumo)

Antes de implementar algo na mão, verifique se uma CLI já instalada resolve (`gh`, `jq`,
`yq`, `rg`, `uv`, `git`…). Regra completa em
[`.claude/rules/cli-first.md`](.claude/rules/cli-first.md).

## Subagents

Use subagents quando uma tarefa for **independente e focada** o suficiente para se
beneficiar de contexto próprio (investigação, testes, exploração). Quando não há subagent
dedicado, a lógica da fase é **auto-contida**.

- Catálogo genérico de **experts de papel** em [`.claude/agents/`](.claude/agents/): `explorer`,
  `code-reviewer`, `test-writer`, `git-workflow`, `security-reviewer`, `debugger`, `validator`,
  `documenter`, `external-observer`, `designer`, `tracker`. Fonte de verdade do roteamento e gatilhos:
  [`.claude/rules/agent-routing.md`](.claude/rules/agent-routing.md); mapa de relações (gerado) em
  [`.claude/agents/AGENT_MAP.md`](.claude/agents/AGENT_MAP.md).
- Agentes **de domínio** não vêm no scaffold — surgem na curadoria (`/audit-agents`).

## Convenções

- **Conventional Commits** (`feat:`, `fix:`, `chore:`, `docs:`…), mensagens em pt-BR.
- `main` protegida: trabalho em branch de feature; merge só com confirmação explícita.
- **Não inventar dados** (usar só o que se pode verificar); **não versionar segredos**.
- **Qualidade verificável:** nada é "pronto" sem verificação real (lint, testes, critérios
  de aceite).
