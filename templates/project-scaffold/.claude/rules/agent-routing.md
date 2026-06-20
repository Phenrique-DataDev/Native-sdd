# Roteamento de agentes

> Catálogo enxuto de subagents **genéricos** em `.claude/agents/`. O mapa de relações está
> em [`../agents/AGENT_MAP.md`](../agents/AGENT_MAP.md). Agentes **de domínio** não vêm no
> scaffold — são criados sob demanda pela curadoria (`/audit-agents`, feature **G2**).

## Princípio

Use a ferramenta `Agent` (subagents) quando uma tarefa for **independente e focada** o
suficiente para se beneficiar de um contexto próprio — investigações paralelas, geração de
testes, exploração de codebase desconhecida. Tarefas independentes podem rodar em paralelo
(várias chamadas `Agent` na mesma mensagem).

Quando **não** há subagent dedicado, o slash command da fase é **auto-contido**: carrega a
própria lógica e gera o artefato diretamente. Por isso as 5 fases SDD **não** têm um agente
por fase — evita duplicar o que o command já faz.

## Catálogo genérico (experts de papel)

Subagents de **papel/disciplina** — universais (agnósticos de stack). Stack/domínio é gerado pelo
`/audit-agents` (G2) em `.claude/agents/domain/`, **não** entra aqui. O papel `simulation` é o único
**instanciado no domínio** (simulador gerado pela curadoria); os demais são universais do base.

| Subagent | `role` | Quando usar | Modo |
|----------|--------|-------------|------|
| `explorer` | search | Localizar código / entender arquitetura de codebase desconhecida antes de implementar | read-only |
| `code-reviewer` | review | Revisar diff/PR **amplo** (bugs, segurança, aderência, simplicidade) — usado pelo `/review` e ao fim do `/build` | read-only |
| `test-writer` | testing | Gerar/completar testes cobrindo os Acceptance Tests do DEFINE | escreve + roda |
| `git-workflow` | vcs | Higiene de repo: estrutura, conventional commits, branches, PRs, `.gitignore`, do's/don'ts (`git`/`gh`) | roda git/gh |
| `security-reviewer` | security | **Profundidade no eixo segurança**: segredos, injeção, authn/authz, deps/supply-chain, config insegura | read-only |
| `debugger` | debug | A partir de falha/stacktrace/flaky: isolar **causa-raiz** e propor o fix mínimo | roda p/ reproduzir |
| `validator` | validation | Verificar **conformidade do resultado** à spec/AT do DEFINE (roda e observa o comportamento) | read-only |
| `documenter` | documentation | Documentar/registrar em `docs/` (humano×LLM, **fora da KB**): doc de código/ADR, runbook/onboarding, acontecimentos (append-only) | escreve em `docs/` |
| `external-observer` | observation | Observar **alvo externo/opaco** (site/API/app rodando) e confrontá-lo com referência (**VALIDAR**) ou inferir sua lógica (**MAPEAR**) — gera relatório, nunca clona | read-only / **outward** (browser/web = confirmar) |

## Seleção de executor

O líder escolhe o expert (ou a cadeia) pelo **tipo de tarefa**, reusando o `Agent` nativo (e
`/orchestrate` quando há encadeamento) — **sem motor próprio**. Os agentes declaram `connects_to` no
frontmatter (grafo de quem costuma encadear com quem; base p/ um grafo consultável futuro — H4).

O **hub orquestrador-mestre** (`:Hub`, nó `max`) é o **ápice permanente** do grafo: ligado a **todos** os
agentes por `:ORCHESTRATES`, ele é o líder que delega aos experts. Está **sempre** no `graph.json` (não é
opt-in). No **modo MAX** (`/max`, ver [`max-mode.md`](max-mode.md)) o líder **opera como** esse hub no
máximo — delega via `/orchestrate`, consulta `role`/`connects_to` p/ encadear e **ativa todas as conexões**
do arsenal; o MAX **amplifica** o hub que já está no grafo, não o cria.

### Consultar o grafo unificado (H9) — fonte de "o que conecta com quê"

Antes de **rotear / orquestrar / planejar**, **consulte o grafo unificado** em
[`../agents/graph.json`](../agents/graph.json) (gerado por `/sync-context`): ele mapeia
`agente ↔ skill ↔ KB ↔ domínio` num só lugar — escolha o **expert/skill/conhecimento certo** a partir
dele, em vez de improvisar. Use-o para responder, sem varrer arquivos: *quem encadeia com quem*
(`:CONNECTS_TO`), *que skill um domínio pressupõe* (`:PRESUPPOSES`), *que skill um agente usa*
(`:USES_SKILL`), *que conhecimento existe num domínio* (`:IN_DOMAIN`/`:KbEntry`).

| Disciplina de custo | Detalhe |
|---------------------|---------|
| **On-demand, não always-on** | leia o `graph.json` **quando** for rotear/planejar — **nunca** o despeje no contexto sempre-ativo (esta instrução é o ponteiro; o dado é sob demanda — footprint G8 controlado) |
| **Ponteiro, não motor** | é postura (igual `docs-first`/`cli-first` apontam fontes); o grafo é dado, não um engine de query |
| **`skills_used` (opcional)** | um agente pode declarar `skills_used: [skill-a, skill-b]` no frontmatter p/ ligar-se a skills **fora do seu domínio** (override do elo derivado). `agent-lint` avisa (warn) se a skill não existe — **não barra** |

> O grafo é **gerado** (não editar à mão); rode `/sync-context` após curar agentes/KB/skills. O hub do
> modo MAX consulta o mesmo grafo ao montar o pacote de uma task (ver [`max-mode.md`](max-mode.md)).

### Contrato de hub (exclusivo) — conectado a todos, extensível

O hub MAX alcança **qualquer** agente do grafo por uma relação **dedicada `:ORCHESTRATES`** (hub→agente),
**distinta** das arestas peer `connects_to` (`:CONNECTS_TO`, que ligam experts entre si). Esse é o
**contrato de hub exclusivo**:

- **Adesão automática:** um agente é orquestrável pelo hub **iff** é um **nó válido** do grafo — declara
  `role` (enum) + `connects_to` (bem-formado), o que o [`agent-lint`](../../../tools/agent-lint.ps1) já
  exige. Nada mais a marcar.
- **Extensível sem editar lista:** adicionar um agente — base **ou** de domínio gerado pelo `/audit-agents`
  (G2) — cria um novo nó → o hub passa a alcançá-lo **automaticamente** (a aresta `:ORCHESTRATES` é
  gerada). Não há lista hardcoded de "quem o hub conhece".
- **Verificação determinística:** `tools/graph-export.ps1` `Get-HubGraph` adiciona o nó `:Hub` + as arestas
  `:ORCHESTRATES` p/ todos; `Test-HubReachability` exige **0 agente órfão** do hub.
- **Base pronta p/ o neo4j (H4):** o nó `:Hub` e a relação `:ORCHESTRATES` **exportam** p/ `graph.cypher`
  (`ConvertTo-GraphCypher`/`Invoke-GraphExport -WithHub`) — quando o volume justificar, o hub sobe
  consultável (`cypher-shell < graph.cypher`). O **servidor segue adiado**; aqui entregamos a **base**.

**Uso da KB pelo hub:** ao montar o **pacote de contexto** de uma task, o hub **consulta a KB do domínio**
e injeta as entradas relevantes (por default `operations`+`implementation`; reusa `Build-KbIndex`) — aterra
o subagente no conhecimento curado em vez de improvisar. Ver [`max-mode.md`](max-mode.md) (seção KB).

| Tipo de tarefa | Expert / cadeia |
|----------------|-----------------|
| "Onde fica X / como conecta" | `explorer` |
| Revisão de mudança pronta | `code-reviewer` → (se toca superfície sensível) `security-reviewer` |
| Mudança em superfície de segurança | `security-reviewer` (profundidade) + `code-reviewer` (amplitude) |
| Algo quebrou / teste falhando | `debugger` → `test-writer` (teste de regressão) |
| Falta cobertura de teste | `test-writer` → `validator` (conformidade aos AT) |
| "Isto cumpre o DEFINE?" (fim de build / pré-ship) | `validator` |
| Preparar commit/branch/PR | `git-workflow` |
| Documentar/registrar o que mudou ou como funciona (fora da KB) | `documenter` (proativo; ou `/document` em lote) |
| Validar runtime de um alvo externo / mapear um produto sem o fonte | `external-observer` (caixa-preta, read-only; ação **outward** = confirmar a cada uso). Distinto do `validator` (caixa-branca, build próprio vs AT) |

### Política de modelo (B9)

- **Default `model: inherit`** em todos os agentes base — cada um roda no **modelo da sessão** (você
  em Opus → o agente em Opus; em Sonnet → Sonnet). Sem hardcode.
- **Escalonar para `opus`** é **por-invocação**: ao delegar uma tarefa **pesada/crítica** ou sob
  **pedido explícito**, o líder passa `model: opus` na invocação (o override vence o frontmatter —
  ordem de resolução do Claude Code: env → invocação → frontmatter → sessão).
- Para **mais esforço sem trocar de modelo**, use o campo/parâmetro `effort` (`low`…`max`).

## Workflow SDD → command

| Intenção | Command (auto-contido) | Delega a |
|----------|------------------------|----------|
| Explorar ideia | `/brainstorm` | — |
| Capturar requisitos | `/define` | — |
| Arquitetura/spec | `/design` | `explorer` (quando precisa mapear o código) |
| Implementar | `/build` | `test-writer`, `code-reviewer` |
| Encerrar feature | `/ship` | `code-reviewer` |
| Tarefa pequena | `/dev` | — |
| Revisar PR/diff | `/review` | `code-reviewer` |
| Duvidar de decisão in-flight (antes de firmar) | `/doubt` | revisor adversarial **fresh-context** (`Agent`, cego à conclusão) — devolve **dúvidas**, não veredito; postura na regra `doubt-driven.md`. Distinto do `/review` (post-hoc) |
| Telemetria por fase (iterações) | `/telemetry` | lê `.claude/sdd/telemetry.jsonl` e imprime o painel (`Format-PhaseReport`); cada fase SDD grava via `Add-PhaseIteration` (passo opcional) — `tools/telemetry.ps1`, read-only |
| "Onde estamos?" (visão geral do projeto) | `/status` | painel **read-only** (curadoria + fase SDD em andamento + `inbox/` pendente); reusa `Get-CurationStatus` + `Get-SddFeatureStatus`/`Get-InboxItems` — `tools/status.ps1`. Pull on-demand (distinto do `curation-nudge`, reativo) |
| "Está conforme?" (validar os artefatos curados) | `/check` | painel **read-only** de **conformidade**: roda `kb-lint`/`agent-lint`/`config-lint` sobre `.claude/kb`/`agents`/`settings*.json` e dá veredito (`ok`/`warnings`/`issues`); reusa `Get-KbInventory`/`Invoke-*Lint` — `tools/project-check.ps1`. Seção sem alvo → `n/a`. Distinto do `/status` (estado), do `curation-nudge` (aviso reativo) e do `tools/check.ps1` (runner do framework) |
| Povoar a KB | `/train-kb` | um **subagente por onda** (ex.: `explorer`); camada `tools/` aplica `docs-first` (context7) |
| Ressincronizar índices | `/sync-context` | regenera `AGENT_MAP.md` + `kb/_index.yaml` e ponteiros (reusa `Get-AgentInventory`/`Get-KbInventory`) |
| Especializar o scaffold (curadoria) | `/init` | **orquestra** a cadeia `/setup`? → `/audit-agents` → `/train-kb` → `/sync-context`, com gate entre etapas (reusa `Get-CurationStatus`) |
| Adotar projeto existente (brownfield) | `/adapt` | **detecta** stack + higiene (testes/CI/docs), propõe contexto + retro-ondas e **delega ao `/init`** (reusa `Get-StackSignals`/`Get-ProjectHygiene`) |
| Higiene de skills (inventário + update) | `/update-skills` | **inventaria** os 2 escopos (global+projeto), diagnostica saúde (valid/stale/orphan/malformed) e **aplica update** do baseline sob confirmação, preservando custom (reusa `Get-SkillInventory`/`Install-BaselineItem`) |
| Fechar lacuna de skill (skill-gap killer) | `/skill-gap` | **detecta** o gap (skills `skills_needed` das ondas × inventário do `/update-skills`) e **gera** a skill faltante (esqueleto `scaffolded` + conteúdo do LLM) em `.claude/skills/`; referenciado pelo `/train-kb` (reusa `Get-SkillInventory`/`Get-SkillGap`) |
| Orquestrar objetivo/plano aprovado (líder→subagentes) | `/orchestrate` | **decompõe** o objetivo em tasks (STATE resumível), dá contexto e **invoca** subagentes via `Agent` nativo, **valida** cada resultado num gate (`Test-TaskGate` determinístico + `code-reviewer` semântico opcional) e encadeia/paraleliza (`ReadyTasks`). Protocolo na regra `orchestration.md`; sem engine (reusa o padrão do `/init`) |
| Consolidar/compactar a KB (quando cresce) | `/reflect` | **gatilho** determinístico (`Test-KbOverBudget`, reusa `kb-lint`/B7) → **fan-out** por camada×domínio via `Agent` (MERGE/COMPRESS/PRUNE preservando regras+casos) → **plano→aprova→aplica** com backup + proveniência (`consolidates`/`supersedes`) → **verifica** (`Test-ReflectProvenance`) → reindexa (`/sync-context`). Protocolo na regra `reflection.md`; nunca-destrutivo, sem engine |
| Simular uma mudança/fix antes de aplicar | `/simulate` | **capacidade** (`Get-SimulationCapability`) → sem simulador degrada (`/audit-agents`); senão **fan-out** p/ o simulador de domínio (`role: simulation`) via `Agent`. Ciclo PROPOR→SIMULAR (isolado)→COMPARAR (vs baseline)→REPORTAR→DECIDIR; **nunca aplica, nunca toca produção**; conformidade do relatório de 6 seções (`Test-SimulationReportConforms`). Protocolo na regra `simulation.md`; sem engine |
| Promover lição recorrente do uso à KB | `/learn` | **gatilho** determinístico (`Test-LessonsReady`: candidatas `[candidata]` não-promovidas ≥ limiar; reusa `kb-lint`/B7) → **fan-out** por domínio via `Agent` (detecta a lição que se repete em ≥2 features) → **plano→aprova→aplica** com backup + proveniência (`promoted_from`) → **verifica** (`Test-LessonProvenance`) → reindexa (`/sync-context`). Destino KB `operations`; protocolo na regra `lessons.md`; nunca-destrutivo, sem engine. Distinto do `/reflect` (consolida o que já está na KB) |
| Operação máxima sob demanda (orquestrador-mestre / hub) | `/max` · `/max off` | liga a postura `max-mode.md`: **bootstrap de contexto** (reusa `/status`/inventários; G8 silenciado) + **recomenda** potência (B9, não seta) + aciona **`/orchestrate`** + **reduz a fricção do não-crítico** (via modo `auto`), **mantendo TODOS os guardas** e a verificação de qualidade. Estado fail-closed/session-bound em `tools/max.ps1`. **Permissão-só, sem engine, não toca hooks/settings** |

## Menção @agente

Quando o usuário escrever `@nome-do-agente` (ex.: `@code-reviewer`), invoque esse subagent
com o resto da mensagem como tarefa.

## Crescimento do catálogo

A curadoria (`/audit-agents`) analisa o projeto e **gera os agentes de domínio** faltantes
(ex.: setores técnicos, QA, dados). Ao adicionar/remover agentes, atualize o
[`AGENT_MAP.md`](../agents/AGENT_MAP.md). Mantenha o conjunto **enxuto** — só o que é usado.
