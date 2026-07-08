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
| `designer` | design | Criar/revisar/refinar **UI/frontend** — shape→craft→audit (a11y, anti-slop, motion, static-first); aponta p/ a skill `impeccable` quando instalada, sem carregar paleta/decisões fixas de projeto | escreve UI |
| `tracker` | tracking | Instrumentar/revisar **tráfego e traqueamento** — plano de medição→instrumentação→dedup→consentimento→QA (Consent Mode negado por default, first-party/server-side, dedup por `event_id`, PII hasheada, UTM/atribuição, static-first); sem carregar IDs/eventos fixos de projeto | escreve tags/dataLayer |

## Seleção de executor

O líder escolhe o expert (ou a cadeia) pelo **tipo de tarefa**, reusando o `Agent` nativo (e
`/orchestrate` quando há encadeamento) — **sem motor próprio**. Os agentes declaram `connects_to` no
frontmatter (grafo de quem costuma encadear com quem; base p/ um grafo consultável futuro — H4).

O **hub orquestrador-mestre** (`:Hub`, nó `max`) é o **ápice permanente** do grafo — sempre presente,
ligado a todos os agentes por `:ORCHESTRATES` (contrato completo abaixo, em "Contrato de hub"). No
**modo MAX** (`/max`, ver [`max-mode.md`](max-mode.md)) o líder **opera como** esse hub no máximo — o
MAX **amplifica** o hub que já está no grafo, não o cria.

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

**Entrega automática do grafo de pares (hook, não só instrução).** Ler o `graph.json` "antes de rotear"
depende do líder lembrar — confiança de prompt, não mecanismo. O hook **`agent-graph-context`**
(`SubagentStart`) fecha a lacuna **só** para `role`/`connects_to`: a cada subagente iniciado, injeta os
dois via `additionalContext`, determinístico. O grafo **unificado** (KB/skills/domínio) continua sendo
consulta sob demanda do líder — o hook não o injeta.

**Sem backstop automático de staleness.** Nada verifica automaticamente se `graph.json` está
sincronizado com o frontmatter dos agentes (o `resync-lint` saiu do CI na postura low-friction,
2026-06-20) — rodar `/sync-context` após curar é responsabilidade de quem cura. `agent-lint` só checa
integridade referencial (`connects_to` aponta a agente existente), não staleness.

### Refino de pedido (opt-in) — afiar o pedido e mapear o arsenal antes de agir

Ao receber um pedido **vago, curto ou informal**, vale **afiá-lo** antes de executar, em vez de
adivinhar. É **postura opt-in** — o usuário pede ("refina/melhora isto antes de fazer") **ou** você
julga que a ambiguidade custa retrabalho — **não** um passo obrigatório em todo turno:

1. **Devolva sua leitura técnica** do pedido (o que entendeu, em termos concretos) e exponha as premissas.
2. **Consulte o `graph.json`** (H9) e liste o **arsenal aplicável** — agentes/skills/KB/MCP que encaixam.
3. **Espere o OK** do usuário antes de agir (ou ele corrige a sua leitura).

Molde `docs-first`/`cli-first` (aponta a fonte/arsenal; **sem motor, sem command novo**). Reusa a
consulta ao grafo já descrita acima. **Distinto** do [`/doubt`](../commands/doubt.md) (dúvida
adversarial sobre decisão **já formada**) e do `/brainstorm` (fase SDD de explorar uma **feature**):
aqui só se **clarifica o pedido** e se **mapeia o arsenal** antes de começar.

> **Não** reescreva o pedido **no lugar do** usuário, nem rode isto em todo turno — é opt-in, sob sinal
> de ambiguidade. Pedido trivial/claro → siga direto.

### Reagindo a review recebida

Distinto do [`doubt-driven.md`](doubt-driven.md) (dúvida sobre decisão **própria ainda aberta**): aqui
a decisão **já foi tomada** e um revisor (`code-reviewer`, humano, ou terceiro) **já devolveu** um
veredito/sugestão. O ponto é como o líder **reage**, antes de implementar.

| Não faça | Faça |
|----------|------|
| Concordância performática ("Você está certo!", "Ótimo ponto!") antes de verificar | Verifique a sugestão contra o código real primeiro; só então aja |
| Implementar tudo de uma vez quando parte do feedback ficou ambígua | Esclareça os itens ambíguos **antes** de implementar qualquer um — itens podem estar relacionados |
| Aceitar "implementar isso direito" sem checar se é usado | `grep` por uso real primeiro — sem uso, é candidato a **não** implementar (YAGNI), não a "fazer certo" |

**Antes de implementar uma sugestão de revisor, responda:**
1. Isso quebra algo que já funciona?
2. O revisor tem o contexto completo (motivo do código atual, compat legada)?
3. É YAGNI — o trecho sinalizado tem uso real no projeto?

Se a resposta apontar problema, **discorde com razão técnica** (não implemente cego, não ignore
silenciosamente). Se a sugestão estava certa, só **corrija e diga o que mudou** — sem agradecimento
performático; a ação já demonstra que o feedback foi ouvido.

### Contrato de hub (exclusivo) — conectado a todos, extensível

O hub MAX alcança **qualquer** agente do grafo por uma relação **dedicada `:ORCHESTRATES`** (hub→agente),
**distinta** das arestas peer `connects_to` (`:CONNECTS_TO`, que ligam experts entre si). Esse é o
**contrato de hub exclusivo**:

- **Adesão automática:** agente é orquestrável pelo hub **iff** for um nó válido do grafo (`role` +
  `connects_to`, já exigido pelo [`agent-lint`](../../../tools/agent-lint.ps1)) — nada mais a marcar.
- **Extensível sem editar lista:** novo agente (base ou de domínio via `/audit-agents`) vira nó → o hub
  o alcança **automaticamente**; sem lista hardcoded.
- **Verificação:** `Get-HubGraph`/`Test-HubReachability` (`tools/graph-export.ps1`) exigem **0 agente
  órfão** do hub.
- **Base pronta p/ neo4j (H4, adiado):** `:Hub`/`:ORCHESTRATES` já exportam p/ `graph.cypher`.

**Uso da KB pelo hub:** ao montar o **pacote de contexto** de uma task, o hub **consulta a KB do domínio**
e injeta as entradas relevantes (por default `operations`+`implementation`; reusa `Build-KbIndex`) — aterra
o subagente no conhecimento curado em vez de improvisar. Ver [`max-mode.md`](max-mode.md) (seção KB).

### Gatilho `ultracode` (opt-in de multiagente)

Quando o pedido do usuário inclui a palavra **`ultracode`**, é o mesmo opt-in explícito que o próprio
Claude Code reconhece para acionar a ferramenta `Workflow` — o hub deve tratá-lo como sinal para
**preferir `Workflow`** sobre `/orchestrate`/cadeia simples de `Agent` ao escolher o executor, mesmo em
objetivo pequeno que caberia num expert único. Definição do gatilho e como o hub reage em
[`max-mode.md`](max-mode.md) §(a) (fonte única — esta linha só aponta o reconhecimento no roteamento).

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
| Criar/revisar/refinar interface (UI/frontend) | `designer` → aponta p/ a skill `impeccable` (`/supplements design`) quando instalada; sem ela, aplica a disciplina genérica direto |
| Instrumentar/revisar tracking (analytics, pixels, dataLayer, GTM, CAPI, UTM) | `tracker` (consent-first, dedup por `event_id`, PII hasheada) → `security-reviewer` (PII/segredos) + `external-observer` (validar disparo em runtime) |

### Política de modelo (B9)

- **Default `model: inherit`** em todos os agentes base — cada um roda no **modelo da sessão** (você
  em Opus → o agente em Opus; em Sonnet → Sonnet). Sem hardcode.
- **Escalonar para `opus`** é **por-invocação**: ao delegar uma tarefa **pesada/crítica** ou sob
  **pedido explícito**, o líder passa `model: opus` na invocação (o override vence o frontmatter —
  ordem de resolução do Claude Code: env → invocação → frontmatter → sessão).
- Para **mais esforço sem trocar de modelo**, use o campo/parâmetro `effort` (`low`…`max`).

## Workflow SDD → command

> Detalhe/protocolo de cada um vive na própria regra referenciada — não repita aqui.

| Intenção | Command | Delega a / regra |
|----------|---------|-------------------|
| Explorar ideia | `/brainstorm` | — |
| Capturar requisitos | `/define` | — |
| Arquitetura/spec | `/design` | `explorer` (mapear código) |
| Implementar | `/build` | `test-writer`, `code-reviewer` |
| Encerrar feature | `/ship` | `code-reviewer` |
| Tarefa pequena | `/dev` | — |
| Revisar PR/diff | `/review` | `code-reviewer` |
| Duvidar de decisão in-flight (antes de firmar) | `/doubt` | revisor adversarial fresh-context, cego à conclusão — devolve dúvidas, não veredito (`doubt-driven.md`). Distinto do `/review` (post-hoc) |
| Telemetria por fase | `/telemetry` | lê `.claude/sdd/telemetry.jsonl`, read-only (`tools/telemetry.ps1`) |
| Visão geral do projeto | `/status` | painel read-only: curadoria + fase SDD + `inbox/` (`tools/status.ps1`) |
| Conformidade dos artefatos curados | `/check` | veredito read-only via `kb-lint`/`agent-lint`/`config-lint` (`tools/project-check.ps1`) |
| Sessões concorrentes | `/peers` | quadro file-based (branch/summary/heartbeat), sem daemon (`tools/peers.ps1`) |
| Povoar a KB | `/train-kb` | 1 subagente por onda; camada `tools/` aplica `docs-first` (context7) |
| Ressincronizar índices | `/sync-context` | regenera `AGENT_MAP.md`+`kb/_index.yaml`+ponteiros |
| Especializar o scaffold | `/init` | orquestra `/setup`?→`/audit-agents`→`/train-kb`→`/sync-context`, gate entre etapas |
| Adotar projeto existente (brownfield) | `/adapt` | detecta stack+higiene, delega ao `/init` |
| Higiene de skills | `/update-skills` | inventaria os 2 escopos, diagnostica, atualiza sob confirmação |
| Fechar lacuna de skill | `/skill-gap` | detecta gap (`skills_needed` × inventário) e gera a skill faltante |
| Orquestrar objetivo/plano aprovado | `/orchestrate` | decompõe em tasks (STATE), invoca subagentes, valida em gate (`orchestration.md`) |
| Iterar meta verificável até o verde | `/iterate` | loop-until-green só na classe segura, sandbox `worktree` (`iterative-loop.md`). Distinto do `/orchestrate` (DAG, `MaxAttempts=2`) |
| Consolidar/compactar a KB | `/reflect` | MERGE/COMPRESS/PRUNE por camada×domínio, nunca-destrutivo (`reflection.md`) |
| Simular mudança antes de aplicar | `/simulate` | PROPOR→SIMULAR→COMPARAR→REPORTAR→DECIDIR, nunca aplica (`simulation.md`) |
| Promover lição recorrente à KB | `/learn` | detecta lição em ≥2 features, promove com proveniência (`lessons.md`). Distinto do `/reflect` (consolida o que já está na KB) |
| Operação máxima sob demanda | `/max` · `/max off` | bootstrap de contexto + potência recomendada + orquestrador-mestre, permissão-só (`max-mode.md`) |

## Menção @agente

Quando o usuário escrever `@nome-do-agente` (ex.: `@code-reviewer`), invoque esse subagent
com o resto da mensagem como tarefa.

## Crescimento do catálogo

A curadoria (`/audit-agents`) analisa o projeto e **gera os agentes de domínio** faltantes
(ex.: setores técnicos, QA, dados). Ao adicionar/remover agentes, atualize o
[`AGENT_MAP.md`](../agents/AGENT_MAP.md). Mantenha o conjunto **enxuto** — só o que é usado.
