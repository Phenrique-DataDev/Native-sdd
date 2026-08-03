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
ligado a todos os agentes por `:ORCHESTRATES`. No **modo MAX** (`/max`) o líder **opera como** esse
hub no máximo — o MAX **amplifica** o hub que já está no grafo, não o cria.

## Roteamento avançado — carga sob demanda (não está aqui de propósito)

Três assuntos **saíram** deste arquivo para [`../postures/agent-routing-advanced.md`](../postures/agent-routing-advanced.md),
porque **nenhum deles é consultado na hora de escolher a quem delegar** — só valem depois que já se
decidiu orquestrar/operar no máximo, e ambos os casos têm um command que os carrega:

| Assunto | Quem carrega |
|---------|--------------|
| **Consultar o grafo unificado** (`graph.json`: `:USES_SKILL`, `:PRESUPPOSES`, `:IN_DOMAIN`) | `/max`, `/orchestrate` |
| **Contrato de hub** (`:ORCHESTRATES`, adesão automática, extensibilidade) | `/max` |
| **Gatilho `ultracode`** (opt-in explícito de multiagente via `Workflow`) | `/max` |

A postura do **modo MAX** inteira mora em [`../postures/max-mode.md`](../postures/max-mode.md) — também
**fora** do always-on, carregada pelo [`/max`](../commands/max.md). Custo dessas 4 peças numa sessão que
não as usa: **0 token**.

> **O link acima não carrega nada** — ele é referência para o humano. Quem **carrega** é o command
> (`/max` faz `Read` da postura no Passo 0, e **aborta** se ela sumir). Essa distinção é a diferença
> entre um mecanismo e uma boa intenção.

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

Distinto do [`/doubt`](../commands/doubt.md) (dúvida sobre decisão **própria ainda aberta**): aqui
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

### Política de modelo (B9)

- **Default `model: inherit`** em todos os agentes base — cada um roda no **modelo da sessão** (você
  em Opus → o agente em Opus; em Sonnet → Sonnet). Sem hardcode.
- **Escalonar para `opus`** é **por-invocação**: ao delegar uma tarefa **pesada/crítica** ou sob
  **pedido explícito**, o líder passa `model: opus` na invocação (o override vence o frontmatter —
  ordem de resolução do Claude Code: env → invocação → frontmatter → sessão).
- Para **mais esforço sem trocar de modelo**, use o campo/parâmetro `effort` (`low`…`max`).

## Menção @agente

Quando o usuário escrever `@nome-do-agente` (ex.: `@code-reviewer`), invoque esse subagent
com o resto da mensagem como tarefa.

## Crescimento do catálogo

A curadoria (`/audit-agents`) analisa o projeto e **gera os agentes de domínio** faltantes
(ex.: setores técnicos, QA, dados). Ao adicionar/remover agentes, atualize o
[`AGENT_MAP.md`](../agents/AGENT_MAP.md). Mantenha o conjunto **enxuto** — só o que é usado.

O roteamento **de domínio** (gerado) mora em **`agent-routing-domain.md`**, um arquivo à parte que
**não vem do template** — o `.claude/rules/` inteiro é always-on, então ele carrega igual. **Nunca
escreva o conteúdo gerado aqui dentro:** este arquivo é entregue pelo template, e conteúdo gerado o
faria divergir para sempre — todo `nsp -Update` o marcaria `conflito` e **pararia de entregar
melhorias nele**, congelando a rule na versão do dia da curadoria.