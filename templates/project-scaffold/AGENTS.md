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
>
> **No Codex** há um caminho melhor que o manual: `Export-CodexHarness -ProjectRoot .`
> (`$env:SDD_WORKFLOW_HOME/tools/harness-export.ps1`) gera `.agents/skills/` a partir dos commands,
> e o Codex descobre as skills sozinho. Opt-in; reexporte se mexer nos commands.

## Regras sempre aplicadas (`.claude/rules/`)

<!-- sync-context:start:rules -->
- [`workflow-sdd.md`](.claude/rules/workflow-sdd.md) — as 5 fases SDD e quando entrar em cada uma
- [`cli-first.md`](.claude/rules/cli-first.md) — verificar CLIs antes de implementar na mão
- [`docs-first.md`](.claude/rules/docs-first.md) — doc atual (context7) antes da memória do modelo
- [`tooling.md`](.claude/rules/tooling.md) — resolver a camada `tools/` (`$toolsRoot`) antes de dot-source
- [`agent-routing.md`](.claude/rules/agent-routing.md) — a quem delegar: catálogo de experts + política de modelo
- [`orchestration.md`](.claude/rules/orchestration.md) — **predicado**: o trabalho pede regime `completo`? protocolo em `postures/`
- [`artifact-first.md`](.claude/rules/artifact-first.md) — comparar variantes num Artifact antes de construir
- [`semantic-search.md`](.claude/rules/semantic-search.md) — **predicado**: pergunta é paráfrase sobre prosa? catálogo primeiro; disciplina em `postures/`
- [`kb-taxonomy.md`](.claude/rules/kb-taxonomy.md) — KB em 4 camadas (`.claude/kb/`); contrato de **escrita** em `postures/`
- [`documentation.md`](.claude/rules/documentation.md) — o resíduo documentável vai para `docs/`, não para a KB
- [`project-context.md`](.claude/rules/project-context.md) — stack/convenções deste projeto (`/setup`)
- [`complementary-repos.md`](.claude/rules/complementary-repos.md) — **predicado**: o registro existe? disciplina em `postures/`
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

### Em `.claude/postures/` — arquivo próprio (≥1 command **ou rule** a carrega)

| Postura | Quem a carrega (o mecanismo) |
|---------|------------------------------|
| [`max-mode.md`](.claude/postures/max-mode.md) — modo de operação máxima | `/max`, no Passo 0 — **aborta** se o arquivo sumir |
| [`agent-routing-advanced.md`](.claude/postures/agent-routing-advanced.md) — grafo unificado, hub, `ultracode` | `/max` e `/orchestrate` |
| [`orchestration.md`](.claude/postures/orchestration.md) — protocolo do líder: ciclo, gate, checkpoint, paralelismo, STATE | `/orchestrate`, no Passo 0 — **aborta** se sumir |
| [`kb-writing.md`](.claude/postures/kb-writing.md) — contrato de **escrita** na KB: frontmatter, proveniência, orçamento | `/train-kb`, `/learn`, `/reflect` |
| [`complementary-repos.md`](.claude/postures/complementary-repos.md) — ciclo CONSULTAR→RESOLVER→LER→ADAPTAR, boundary read-only | `/complementary-repos` + a rule (se o registro existe) |
| [`semantic-search.md`](.claude/postures/semantic-search.md) — achar prosa por significado: catálogo primeiro, `Grep` depois | a rule (se a pergunta é em linguagem natural, sem o termo exato) |

> **Rules condicionais (2026-08-10).** Quatro rules deixaram de carregar a disciplina inteira em toda
> sessão: elas guardam um **predicado observável** (o registro existe? a pergunta é paráfrase sobre
> prosa? a KB tem entradas? vou orquestrar?) e mandam ler a postura quando ele é verdadeiro. Always-on medido:
> **~40 900 → ~31 800 tok**. Nada foi removido — foi movido para quem usa. Uma rule é porta legítima
> justamente por ser always-on: a instrução de ler chega em toda sessão, o conteúdo só quando serve.
>
> **O link não carrega nada** — quem carrega é o `Read` do command (postura em `postures/`) ou a
> própria invocação (postura no command). Postura em `postures/` que nenhum command lê é **regra sem
> mecanismo**: não existe na prática (o CI reprova).
>
> O **núcleo** do roteamento fica em `rules/` de propósito: a escolha do expert acontece **sem porta**
> — não há command que a anteceda para carregá-la a tempo.

## Fila de trabalho (`BACKLOG.md`)

O que está identificado e ainda não foi feito vive em [`BACKLOG.md`](BACKLOG.md), na raiz. Ele tem um
**critério de entrada** de 3 perguntas — *dor observada · causa conferida no código · pronto
verificável* — e um item só entra no **Aberto** com as três respondidas **dentro dele**; sem isso,
fica no `inbox/`. Item fechado **não é apagado**: vira riscado com o que a medição disse, e decisão de
*NÃO fazer* carrega o **gatilho de reabertura**. O `/status` conta a fila e, quando não há feature
aberta nem `inbox/` pendente, aponta o topo dela como próximo passo.

> **Não invente item para preencher o backlog** — um backlog vazio é o resultado, não um problema a
> resolver. E o relato que abre um item é evidência forte de *que* dói, fraca sobre *por quê*: a causa
> se estabelece lendo o código.

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

- **Conventional Commits** (`feat:`, `fix:`, `chore:`, `docs:`…), mensagens em **pt-BR por default**.
  pt-BR é o default do scaffold, **não uma imposição** — se o seu time trabalha em outro idioma,
  troque **esta linha**: é ela que o [`git-workflow`](.claude/agents/git-workflow.md) consulta antes
  de escrever a mensagem, e não há campo de idioma em nenhum outro lugar do projeto.
- `main` protegida: trabalho em branch de feature; merge só com confirmação explícita.
- **Não inventar dados** (usar só o que se pode verificar); **não versionar segredos**.
- **Qualidade verificável:** nada é "pronto" sem verificação real (lint, testes, critérios
  de aceite).
