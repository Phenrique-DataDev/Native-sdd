# Agent-routing — avançado (carga SOB DEMANDA, fora do always-on)

> **Este arquivo NÃO é carregado automaticamente.** Ele vive em `.claude/postures/` de propósito: o
> harness varre `.claude/rules/`, **não** esta pasta — então estas seções custam **0 token** até
> alguém lê-las. O **núcleo** do roteamento (catálogo de experts, seleção, política de modelo)
> continua always-on em [`../rules/agent-routing.md`](../rules/agent-routing.md), porque a escolha do
> expert acontece **sem porta**: a qualquer momento, sem um command que a anteceda.
>
> **Quem carrega isto — o mecanismo, não um link decorativo:**
>
> | Quem | Quando |
> |------|--------|
> | [`/max`](../commands/max.md) | Passo 0 — opera como hub do grafo |
> | [`/orchestrate`](../commands/orchestrate.md) | ao montar o pacote de contexto da task |
>
> As três seções abaixo só valem **depois** que se decidiu orquestrar/operar no máximo — nunca na
> decisão de *"a quem delego esta tarefa"*, que é justamente o que fica no núcleo always-on.

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

