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
- [`workflow-sdd.md`](.claude/rules/workflow-sdd.md) — as 5 fases SDD e quando entrar em cada uma
- [`cli-first.md`](.claude/rules/cli-first.md) — verificar CLIs antes de implementar na mão
- [`docs-first.md`](.claude/rules/docs-first.md) — doc atual (context7) antes da memória do modelo
- [`tooling.md`](.claude/rules/tooling.md) — resolver a camada `tools/` (`$toolsRoot`) antes de dot-source
- [`agent-routing.md`](.claude/rules/agent-routing.md) — a quem delegar: catálogo de experts + política de modelo
- [`artifact-first.md`](.claude/rules/artifact-first.md) — comparar variantes num Artifact antes de construir
- [`semantic-search.md`](.claude/rules/semantic-search.md) — busca por significado na KB/docs; opt-in, degrada sozinha
- [`kb-taxonomy.md`](.claude/rules/kb-taxonomy.md) — KB em 4 camadas (`.claude/kb/`)
- [`project-context.md`](.claude/rules/project-context.md) — stack/convenções deste projeto (`/setup`)
- [`complementary-repos.md`](.claude/rules/complementary-repos.md) — outros repos como referência read-only (`/complementary-repos`)
<!-- sync-context:end:rules -->

> Sumário (1 linha por regra), regenerado por `/sync-context` — a regra é o arquivo, não esta lista.
> No Claude Code eles **já estão no contexto**; a lista serve aos harnesses que não varrem o diretório.

## Posturas sob demanda — **não** carregadas automaticamente

Custam **0 token** até serem lidas. Só valem quando acionadas — pagar por elas em toda sessão seria
desperdício. Vivem em dois lugares, conforme o número de leitores:

### No próprio command — o command **é** a postura

O corpo de um slash command só entra no contexto **quando ele é invocado** (só a `description` é
always-on). Postura com **um único** leitor mora **dentro** dele: fonte única, sem arquivo separado e
sem duas cópias para divergir. **Estas não têm rule em `.claude/rules/`** — o gatilho abaixo é o que
você precisa saber sempre; o protocolo chega junto com o command:

| Postura | Command (fonte única) | Gatilho — o sinal que a aciona |
|---------|----------------------|--------------------------------|
| Dúvida adversarial *in-flight* | [`/doubt`](.claude/commands/doubt.md) | decisão **cara de reverter**: arquitetura, schema, contrato público, dependência |
| Simular antes de aplicar | [`/simulate`](.claude/commands/simulate.md) | mudança de **alto risco**/blast-radius incerto (exige simulador de domínio) |
| Laço bounded "até o verde" | [`/iterate`](.claude/commands/iterate.md) | meta **verificável por máquina** (lint, suíte, type-fix) |
| Promover lição recorrente à KB | [`/learn`](.claude/commands/learn.md) | o hook `curation-nudge` avisa: candidatas novas no `SHIPPED` |
| Consolidar/compactar a KB | [`/reflect`](.claude/commands/reflect.md) | o hook `curation-nudge` avisa: KB acima do budget |

### Em `.claude/postures/` — arquivo próprio (≥1 command a lê)

| Postura | Quem a carrega (o mecanismo) |
|---------|------------------------------|
| [`max-mode.md`](.claude/postures/max-mode.md) — modo de operação máxima | `/max`, no Passo 0 — **aborta** se o arquivo sumir |
| [`agent-routing-advanced.md`](.claude/postures/agent-routing-advanced.md) — grafo unificado, hub, `ultracode` | `/max` e `/orchestrate` |

> **O link não carrega nada** — quem carrega é o `Read` do command (postura em `postures/`) ou a
> própria invocação (postura no command). Postura em `postures/` que nenhum command lê é **regra sem
> mecanismo**: não existe na prática (o CI reprova).
>
> O **núcleo** do roteamento fica em `rules/` de propósito: a escolha do expert acontece **sem porta**
> — não há command que a anteceda para carregá-la a tempo.

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
